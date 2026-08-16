// MasterArchiveHardeningTests.swift
// Codex QA round 3 (2026-08-16) — one test per returned item:
//   1 wrong-volume identity (UUID probe seam) → refused everywhere
//   2 read-only viewer → Initialize + Promote refused, nothing on disk
//   3 descriptor-relative tree: intermediate symlink dir, manifest
//     replaced by a symlink, missing manifest → refused
//   4 durability barriers: injectable fsync failure → step not claimed
//   5 catalog convergence: PUBLISHED without a catalog link → next run
//     links it, no duplicate file; DONE only after a durable save
//   7 source-gone reconcile → self-contained archive record
//   8 retired guard cannot fail open: unresolvable target → refused
// Everything under the process temp dir; seams are restored in `defer`.

import Foundation
import Testing
@testable import VideoScan

@Suite("Master Archive — codex R3 hardening", .serialized)
@MainActor
struct MasterArchiveHardeningTests {

    private func seed(_ sb: MasterArchiveTestSupport.Sandbox, count: Int, bytes: Int = 64 * 1024) throws -> [URL] {
        try (0..<count).map { i in
            try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_src_\(i).mov"),
                                                   bytes: bytes + i, seed: UInt64(truncatingIfNeeded: UUID().hashValue) &+ UInt64(i))
        }
    }

    // MARK: 1 — wrong-volume identity

    @Test("1: designation UUID A, root exists, current volume UUID B → identity refusal at model, on re-resolve, and in job preflight; A again → OK")
    func wrongVolumeIdentityRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("uuid")
        defer { sb.cleanup() }
        let realProbe = MasterArchiveDesignation.volumeUUIDProbe
        defer { MasterArchiveDesignation.volumeUUIDProbe = realProbe }

        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-A" }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(model.masterArchive?.volumeUUID == "UUID-A")
        #expect(model.masterArchiveIdentityRefusal() == nil)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]

        // A different disk is now mounted at the same path.
        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-B" }
        let refusal = try #require(model.masterArchiveIdentityRefusal())
        #expect(refusal.contains("UUID-B") && refusal.contains("UUID-A"))
        model.reresolveMasterArchiveMount()
        #expect(model.masterArchiveIdentityMismatch != nil, "re-resolve flags the mismatch")
        #expect(model.masterArchive?.volumeUUID == "UUID-A", "designation is NOT rewritten to the impostor")

        model.requestPromote(recordIDs: [rec.id])
        #expect(model.pendingPromoteRequest == nil, "requestPromote refuses")

        // A plan built earlier (before the swap) must still be refused by the job.
        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-A" }
        let plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))
        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-B" }
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.start(); await job.task?.value
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("NOT the Master Archive volume"), "\(msg)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)

        // The real volume is back → everything works again.
        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-A" }
        model.reresolveMasterArchiveMount()
        #expect(model.masterArchiveIdentityMismatch == nil)
        let ok = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = ok.state else { Issue.record("\(ok.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1)
    }

    @Test("1b: a volume that stops reporting a UUID is also refused (unknown ≠ same)")
    func missingUUIDIsRefused() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("uuidnil")
        defer { sb.cleanup() }
        let realProbe = MasterArchiveDesignation.volumeUUIDProbe
        defer { MasterArchiveDesignation.volumeUUIDProbe = realProbe }
        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-A" }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        MasterArchiveDesignation.volumeUUIDProbe = { _ in nil }
        #expect(model.masterArchiveIdentityRefusal() != nil)
    }

    // MARK: 2 — read-only viewer

    @Test("2: isReadOnly → Initialize refused (no dirs), requestPromote refused, job preflight refused (no partial, no file, no row)")
    func readOnlyRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ro")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.isReadOnly = true
        #expect(throws: MasterArchiveError.self) { try model.initializeMasterArchive(at: sb.archiveVolume) }
        #expect(!FileManager.default.fileExists(atPath: sb.archiveRoot.path), "nothing scaffolded")
        #expect(model.masterArchive == nil)

        // Designate while writable, then flip to read-only: promote must refuse.
        model.isReadOnly = false
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        model.isReadOnly = true
        model.requestPromote(recordIDs: [rec.id])
        #expect(model.pendingPromoteRequest == nil && model.pendingPromoteWithoutMaster == nil)
        let plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.start(); await job.task?.value
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("read-only"), "\(msg)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        let partials = (try? FileManager.default.subpathsOfDirectory(atPath: sb.archiveRoot.path))?.filter { $0.hasSuffix(".partial") } ?? []
        #expect(partials.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sb.journalURL.path), "no journal intent either")
    }

    // MARK: 3 — descriptor-relative tree

    @Test("3a: an intermediate symlinked directory under the tree is refused (dirfd chain, ELOOP) — nothing lands outside")
    func intermediateSymlinkDirRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("symdir")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let outside = sb.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // 30_Video/1990-1999 → symlink to outside (the intermediate, not the leaf).
        try FileManager.default.createDirectory(at: sb.archiveRoot.appendingPathComponent("30_Video"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sb.archiveRoot.appendingPathComponent("30_Video/1990-1999"),
                                                   withDestinationURL: outside)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1992")
        model.records = [rec]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed = job.state else { Issue.record("expected failure, got \(job.state)"); return }
        #expect(job.outcomes.first?.detail.contains("symlink") == true, "\(job.outcomes.first?.detail ?? "")")
        #expect((try? FileManager.default.subpathsOfDirectory(atPath: outside.path))?.isEmpty == true, "nothing written through the link")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        #expect(model.records.count == 1)
    }

    @Test("3b: manifest replaced by a symlink → append refused, preflight refused, scaffold refuses to follow it")
    func manifestSymlinkRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("symman")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        // Swap the manifest for a symlink to a decoy with a valid header.
        let decoy = sb.root.appendingPathComponent("decoy.csv")
        try (MasterArchiveLayout.manifestHeader + "\n").write(to: decoy, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sb.manifestURL)
        try FileManager.default.createSymbolicLink(at: sb.manifestURL, withDestinationURL: decoy)

        let row = ArchiveManifestCSV.Row(promotedAt: Date(), archiveRelPath: "x", sha256: "s", sizeBytes: 1,
                                         originalPath: "/p", originalVolume: "v", recordID: UUID(),
                                         sourceRecordID: UUID(), recordDate: "", dateConfidence: "", people: [], starRating: 3)
        #expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.append(row, rootPath: sb.archiveRoot.path) }
        #expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
        #expect(throws: ArchivePromoteEngine.Failure.self) { _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot) }
        #expect(try String(contentsOf: decoy, encoding: .utf8) == MasterArchiveLayout.manifestHeader + "\n", "decoy untouched")

        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("symlink") || msg.contains("Manifest"), "\(msg)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
    }

    @Test("3c: missing manifest → preflight refuses (never created by promote); header-less manifest refused too")
    func missingManifestRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("noman")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        try FileManager.default.removeItem(at: sb.manifestURL)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("missing"), "\(msg)")
        #expect(!FileManager.default.fileExists(atPath: sb.manifestURL.path), "promote never creates the manifest")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)

        try "not,a,header\n".write(to: sb.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
        // Re-Initialize repairs a missing manifest (creates), but never rewrites a present one.
        try FileManager.default.removeItem(at: sb.manifestURL)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(throws: Never.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
    }

    // MARK: 4 — durability barriers

    @Test("4a: F_FULLFSYNC on the partial fails → not published, no partial, no name; fsync(dir) fails → the name is withdrawn")
    func barrierFailuresAreNotClaimed() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("fsync")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let src = try seed(sb, count: 1)[0]
        let live = ArchivePromoteEngine.barriers
        defer { ArchivePromoteEngine.barriers = live }
        let rel = "30_Video/Undated/xxxx-xx-xx_f.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel).path

        ArchivePromoteEngine.barriers = .init(fullFsync: { _ in -1 }, fsync: live.fsync)
        let h1 = try ArchivePromoteEngine.openSource(path: src.path)
        #expect(throws: ArchivePromoteEngine.Failure.durabilityBarrierFailed("F_FULLFSYNC on xxxx-xx-xx_f.mov.partial")) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h1, root: sb.archiveRoot.path, relativePath: rel)
        }
        h1.close()
        #expect(!FileManager.default.fileExists(atPath: dest))
        #expect(!FileManager.default.fileExists(atPath: dest + ".partial"))

        ArchivePromoteEngine.barriers = .init(fullFsync: live.fullFsync, fsync: { _ in -1 })
        let h2 = try ArchivePromoteEngine.openSource(path: src.path)
        #expect(throws: ArchivePromoteEngine.Failure.self) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h2, root: sb.archiveRoot.path, relativePath: rel)
        }
        h2.close()
        #expect(!FileManager.default.fileExists(atPath: dest), "name withdrawn when the directory barrier failed")
        #expect(!FileManager.default.fileExists(atPath: dest + ".partial"))

        ArchivePromoteEngine.barriers = live
        let h3 = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h3.close() }
        _ = try ArchivePromoteEngine.copyVerifyPublish(source: h3, root: sb.archiveRoot.path, relativePath: rel)
        #expect(FileManager.default.fileExists(atPath: dest))
    }

    @Test("4b: manifest F_FULLFSYNC / journal fsync failures throw; the job reports the file failed and the next run converges (one file, one row, one link)")
    func manifestBarrierFailureThenConverge() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("manfsync")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        let live = ArchivePromoteEngine.barriers
        defer { ArchivePromoteEngine.barriers = live }

        // Journal fsync failing → the intent cannot be journaled → file failed, nothing copied.
        ArchivePromoteEngine.barriers = .init(fullFsync: live.fullFsync, fsync: { _ in -1 })
        let j1 = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed = j1.state else { Issue.record("\(j1.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)

        // Only F_FULLFSYNC (the manifest's barrier) failing → the file publishes
        // (its own F_FULLFSYNC… also fails). So make ONLY the manifest fail:
        // fullFsync fails after the first success (the partial's).
        let calls = BarrierCallCounter()
        ArchivePromoteEngine.barriers = .init(fullFsync: { fd in
            calls.n += 1
            return calls.n == 1 ? live.fullFsync(fd) : -1
        }, fsync: live.fsync)
        let j2 = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed(let msg) = j2.state else { Issue.record("\(j2.state)"); return }
        #expect(msg.contains("failed 1"), "\(msg)")
        #expect(j2.outcomes.first?.detail.contains("durability barrier") == true, "\(j2.outcomes.first?.detail ?? "")")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1, "the verified file stays (journal 'renamed')")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty || MasterArchiveTestSupport.manifestRows(sb).count == 1)
        #expect(model.masterArchiveCopy(of: rec) == nil, "no catalog link claimed")

        ArchivePromoteEngine.barriers = live
        let j3 = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = j3.state else { Issue.record("\(j3.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1)
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
        #expect(model.masterArchiveCopy(of: rec) != nil)
        #expect(ArchivePromoteJournal.latestBySource(in: sb.journalURL)[rec.id]?.state == .done)
    }

    // MARK: 5 — catalog convergence

    @Test("5: PUBLISHED without a catalog link → next run creates the link from provenance, no duplicate file/row; DONE only after a durable save")
    func publishedWithoutLinkConverges() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("pub")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1988")
        model.records = [rec]
        // Simulate: file + manifest row + PUBLISHED journal, catalog never saved.
        let rel = "30_Video/1980-1989/1988/1988-xx-xx_test_src_0.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dest)
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: rel, sha256: sha, sizeBytes: 1,
                                            originalPath: src.path, originalVolume: "v", recordID: UUID(),
                                            sourceRecordID: rec.id, recordDate: "1988-xx-xx", dateConfidence: "user-known",
                                            people: [], starRating: 3), rootPath: sb.archiveRoot.path)
        try ArchivePromoteJournal.append(.init(sourceRecordID: rec.id, sourcePath: src.path, destRelPath: rel,
                                               state: .published, sha256: sha, copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [rel])
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.fullPath == dest.path)
        #expect(copy.archiveFixity?.digest == sha)
        #expect(ArchivePromoteJournal.latestBySource(in: sb.journalURL)[rec.id]?.state == .done,
                "durable save landed (isolated store) → done")

        // With a store that refuses to save, DONE is NOT written.
        let sb2 = try MasterArchiveTestSupport.makeSandbox("pub2")
        defer { sb2.cleanup() }
        let src2 = try seed(sb2, count: 1)[0]
        let model2 = MasterArchiveTestSupport.makeModel(sb2)
        try MasterArchiveTestSupport.initialize(model2, in: sb2)
        model2.catalogStore.isReadOnly = true      // data-layer refusal → saveNow returns false
        let rec2 = MasterArchiveTestSupport.makeRecord(path: src2.path)
        model2.records = [rec2]
        let job2 = try #require(await MasterArchiveTestSupport.promote(model2, ids: [rec2.id]))
        guard case .finished(let summary) = job2.state else { Issue.record("\(job2.state)"); return }
        #expect(summary.contains("deferred"), "\(summary)")
        #expect(ArchivePromoteJournal.latestBySource(in: sb2.journalURL)[rec2.id]?.state == .published)
        #expect(MasterArchiveTestSupport.archivedFiles(sb2).count == 1)
    }

    // MARK: 7 — source gone

    @Test("7: journal PUBLISHED + manifest row + file, source record gone → self-contained archive record (provenance, fixity, date, rating)")
    func sourceGoneStillCataloged() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("orphan")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 2)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let live = MasterArchiveTestSupport.makeRecord(path: src[1].path)   // something to run a job with
        model.records = [live]
        let goneID = UUID()
        let rel = "30_Video/1990-1999/1992/1992-07-15_gone.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src[0], to: dest)
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: src[0].path))
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: rel, sha256: sha, sizeBytes: 1,
                                            originalPath: "/Volumes/Retired/gone.mov", originalVolume: "Retired",
                                            recordID: UUID(), sourceRecordID: goneID, recordDate: "1992-07-15",
                                            dateConfidence: "user-known", people: ["Donna", "Rick"], starRating: 3),
                                      rootPath: sb.archiveRoot.path)
        try ArchivePromoteJournal.append(.init(sourceRecordID: goneID, sourcePath: "/Volumes/Retired/gone.mov",
                                               destRelPath: rel, state: .published, sha256: sha, copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [live.id]))
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let orphan = try #require(model.records.first { $0.fullPath == dest.path })
        #expect(model.isArchiveCopy(orphan))
        #expect(orphan.derivedFrom == goneID)
        #expect(orphan.originalFullPath == "/Volumes/Retired/gone.mov")
        #expect(orphan.originVolume == "Retired")
        #expect(orphan.archiveFixity?.digest == sha)
        #expect(orphan.userDate == "1992-07-15")
        #expect(orphan.userDateStatus == .known)
        #expect(orphan.detectedPeople == ["Donna", "Rick"])
        #expect(orphan.starRating == 3)
        #expect(orphan.archiveStage == .masterAssigned && orphan.lifecycleStage == .archived)
        #expect(orphan.notes.contains("no longer in the catalog"))
        #expect(model.promotionSource(of: orphan) == nil, "unresolvable source is fine")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 2, "no duplicate of the orphan; the live file was promoted")
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 2)
        #expect(ArchivePromoteJournal.latestBySource(in: sb.journalURL)[goneID]?.state == .done)
    }

    // MARK: 8 — retired guard cannot fail open

    @Test("8: master's scan target unresolvable (removed from the list, no UUID match) → job refuses; UUID match resolves it")
    func unresolvableTargetRefuses() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("target")
        defer { sb.cleanup() }
        let realProbe = MasterArchiveDesignation.volumeUUIDProbe
        defer { MasterArchiveDesignation.volumeUUIDProbe = realProbe }
        MasterArchiveDesignation.volumeUUIDProbe = { _ in "UUID-A" }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        let plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))

        // Remove the master's scan target → nothing resolvable by path; the
        // remaining targets (none) cannot match by UUID either.
        model.scanTargets.removeAll { model.isMasterArchive($0) }
        #expect(model.resolvedMasterArchiveTarget() == nil)
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.start(); await job.task?.value
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("could not be matched"), "\(msg)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)

        // A target at a DIFFERENT path but the same volume UUID resolves (rehome case) …
        let alias = CatalogScanTarget(searchPath: sb.root.path)   // reachable temp dir, probe says UUID-A
        model.scanTargets.append(alias)
        #expect(model.resolvedMasterArchiveTarget() === alias)
        // … and if THAT one is retired, promote is refused for retirement (not fail-open).
        alias.retiredAt = Date()
        let job2 = PromoteToArchiveJob(plan: plan, model: model)
        job2.start(); await job2.task?.value
        guard case .failed(let msg2) = job2.state else { Issue.record("expected refusal, got \(job2.state)"); return }
        #expect(msg2.contains("retired"), "\(msg2)")
        alias.retiredAt = nil
        let job3 = PromoteToArchiveJob(plan: plan, model: model)
        job3.start(); await job3.task?.value
        guard case .finished = job3.state else { Issue.record("\(job3.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1)
    }
}

/// Mutable call counter usable from a @Sendable barrier closure (tests are serialized).
final class BarrierCallCounter: @unchecked Sendable { var n = 0 }
