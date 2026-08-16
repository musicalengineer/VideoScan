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
        // Task-local seam: visible only inside this closure's task tree.
        let probe = ProbeBox("UUID-A")
        try await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in probe.uuid }) {
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(model.masterArchive?.volumeUUID == "UUID-A")
        #expect(model.masterArchiveIdentityRefusal() == nil)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]

        // A different disk is now mounted at the same path.
        probe.uuid = "UUID-B"
        let refusal = try #require(model.masterArchiveIdentityRefusal())
        #expect(refusal.contains("UUID-B") && refusal.contains("UUID-A"))
        model.reresolveMasterArchiveMount()
        #expect(model.masterArchiveIdentityMismatch != nil, "re-resolve flags the mismatch")
        #expect(model.masterArchive?.volumeUUID == "UUID-A", "designation is NOT rewritten to the impostor")

        model.requestPromote(recordIDs: [rec.id])
        #expect(model.pendingPromoteRequest == nil, "requestPromote refuses")

        // A plan built earlier (before the swap) must still be refused by the job.
        probe.uuid = "UUID-A"
        let plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))
        probe.uuid = "UUID-B"
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.start(); await job.task?.value
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("NOT the Master Archive volume"), "\(msg)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)

        // The real volume is back → everything works again.
        probe.uuid = "UUID-A"
        model.reresolveMasterArchiveMount()
        #expect(model.masterArchiveIdentityMismatch == nil)
        let ok = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = ok.state else { Issue.record("\(ok.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1)
        }
    }

    @Test("1b: a volume that stops reporting a UUID is also refused (unknown ≠ same)")
    func missingUUIDIsRefused() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("uuidnil")
        defer { sb.cleanup() }
        let probe = ProbeBox("UUID-A")
        try MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in probe.uuid }) {
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        probe.uuid = nil
        #expect(model.masterArchiveIdentityRefusal() != nil)
        }
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
        let box = BarrierBox()
        try ArchivePromoteEngine.$barriers.withValue(box.barriers) {
        let rel = "30_Video/Undated/xxxx-xx-xx_f.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel).path

        box.reset(); box.failFullFsync = true
        let h1 = try ArchivePromoteEngine.openSource(path: src.path)
        #expect(throws: ArchivePromoteEngine.Failure.durabilityBarrierFailed("F_FULLFSYNC on xxxx-xx-xx_f.mov.partial")) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h1, root: sb.archiveRoot.path, relativePath: rel)
        }
        h1.close()
        #expect(!FileManager.default.fileExists(atPath: dest))
        #expect(!FileManager.default.fileExists(atPath: dest + ".partial"))

        box.reset(); box.failFsync = true
        let h2 = try ArchivePromoteEngine.openSource(path: src.path)
        #expect(throws: ArchivePromoteEngine.Failure.self) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h2, root: sb.archiveRoot.path, relativePath: rel)
        }
        h2.close()
        #expect(!FileManager.default.fileExists(atPath: dest), "name withdrawn when the directory barrier failed")
        #expect(!FileManager.default.fileExists(atPath: dest + ".partial"))

        box.reset()
        let h3 = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h3.close() }
        _ = try ArchivePromoteEngine.copyVerifyPublish(source: h3, root: sb.archiveRoot.path, relativePath: rel)
        #expect(FileManager.default.fileExists(atPath: dest))
        }
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
        let box = BarrierBox()
        try await ArchivePromoteEngine.$barriers.withValue(box.barriers) {

        // Journal fsync failing → the intent cannot be journaled → file failed, nothing copied.
        box.reset(); box.failFsync = true
        let j1 = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed = j1.state else { Issue.record("\(j1.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)

        // Only F_FULLFSYNC (the manifest's barrier) failing → the file publishes
        // (its own F_FULLFSYNC… also fails). So make ONLY the manifest fail:
        // fullFsync fails after the first success (the partial's).
        box.reset(); box.fullFsyncFailAfterCalls = 1
        let j2 = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed(let msg) = j2.state else { Issue.record("\(j2.state)"); return }
        #expect(msg.contains("failed 1"), "\(msg)")
        #expect(j2.outcomes.first?.detail.contains("durability barrier") == true, "\(j2.outcomes.first?.detail ?? "")")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1, "the verified file stays (journal 'renamed')")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty || MasterArchiveTestSupport.manifestRows(sb).count == 1)
        #expect(model.masterArchiveCopy(of: rec) == nil, "no catalog link claimed")

        box.reset()
        let j3 = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = j3.state else { Issue.record("\(j3.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1)
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
        #expect(model.masterArchiveCopy(of: rec) != nil)
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[rec.id]?.state == .done)
        }
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
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[rec.id]?.state == .done,
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
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb2.archiveRoot.path)[rec2.id]?.state == .published)
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
        let manifestRecordID = UUID()
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: rel, sha256: sha, sizeBytes: 1,
                                            originalPath: "/Volumes/Retired/gone.mov", originalVolume: "Retired",
                                            recordID: manifestRecordID, sourceRecordID: goneID, recordDate: "1992-07-15",
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
        #expect(orphan.id == manifestRecordID, "orphan record REUSES the manifest's record_id (codex R5 major 5)")
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
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[goneID]?.state == .done)
    }

    // MARK: 8 — retired guard cannot fail open

    @Test("8: master's scan target unresolvable (removed from the list, no UUID match) → job refuses; UUID match resolves it")
    func unresolvableTargetRefuses() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("target")
        defer { sb.cleanup() }
        let probe = ProbeBox("UUID-A")
        try await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in probe.uuid }) {
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

    // MARK: R4-A — reconciliation containment

    @Test("R4-A: journal entry / manifest row with a relpath outside the root (or through a symlink) is ignored — nothing outside is removed, read, or adopted")
    func reconcileContainment() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("contain")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 2)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let recA = MasterArchiveTestSupport.makeRecord(path: src[0].path)
        let recB = MasterArchiveTestSupport.makeRecord(path: src[1].path)
        model.records = [recA, recB]
        let fm = FileManager.default

        // Evil targets OUTSIDE the archive root (two levels up = sb.root).
        let evil = sb.root.appendingPathComponent("evil.mov")
        let evilPartial = sb.root.appendingPathComponent("evil.mov.partial")
        try fm.copyItem(at: src[0], to: evil)
        try "partial".write(to: evilPartial, atomically: true, encoding: .utf8)
        let evilSHA = try #require(MasterArchiveTestSupport.sha256(ofFile: evil.path))

        // Journal: intent for recA pointing outside (would "clean" evil.mov.partial),
        // and a published entry pointing outside (would "adopt" evil.mov).
        try ArchivePromoteJournal.append(.init(sourceRecordID: recA.id, sourcePath: src[0].path,
                                               destRelPath: "../../evil.mov", state: .intent, sha256: nil,
                                               copyRecordID: nil, at: Date()), rootPath: sb.archiveRoot.path)
        let ghost = UUID()
        try ArchivePromoteJournal.append(.init(sourceRecordID: ghost, sourcePath: "/x/y.mov",
                                               destRelPath: "30_Video/../../../evil.mov", state: .published,
                                               sha256: evilSHA, copyRecordID: nil, at: Date()), rootPath: sb.archiveRoot.path)
        // Manifest row for recB pointing outside with the RIGHT digest.
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: "../../evil.mov", sha256: evilSHA, sizeBytes: 1,
                                            originalPath: src[1].path, originalVolume: "v", recordID: UUID(),
                                            sourceRecordID: recB.id, recordDate: "", dateConfidence: "", people: [], starRating: 3),
                                      rootPath: sb.archiveRoot.path)
        // A symlinked leaf INSIDE the tree pointing at the evil file.
        let linkRel = "30_Video/Undated/xxxx-xx-xx_link.mov"
        try fm.createDirectory(at: sb.archiveRoot.appendingPathComponent("30_Video/Undated"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: sb.archiveRoot.appendingPathComponent(linkRel), withDestinationURL: evil)
        let ghost2 = UUID()
        try ArchivePromoteJournal.append(.init(sourceRecordID: ghost2, sourcePath: "/x/z.mov", destRelPath: linkRel,
                                               state: .published, sha256: evilSHA, copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id, recB.id]))
        // recA is promoted normally (its bogus intent was ignored, not "cleaned");
        // recB fails (manifest row outside root) — never adopted.
        #expect(fm.fileExists(atPath: evil.path), "evil.mov untouched")
        #expect(fm.fileExists(atPath: evilPartial.path), "nothing outside the root was unlinked")
        #expect(MasterArchiveTestSupport.sha256(ofFile: evil.path) == evilSHA)
        let copies = model.records.filter { model.isArchiveCopy($0) }
        #expect(copies.allSatisfy { ArchivePathResolver.isInside(path: $0.fullPath, root: sb.archiveRoot.path) },
                "no catalog record points outside the root")
        #expect(!copies.contains { $0.derivedFrom == ghost || $0.derivedFrom == ghost2 || $0.derivedFrom == recB.id })
        #expect(model.masterArchiveCopy(of: recA) != nil)
        #expect(model.masterArchiveCopy(of: recB) == nil)
        let outB = job.outcomes.first { $0.filename == recB.filename }
        #expect(outB?.kind == .failed && outB?.detail.contains("outside the archive root") == true, "\(outB?.detail ?? "")")
        // The symlink leaf inside the tree is still a symlink, still points at evil, nothing adopted.
        let attrs = try fm.attributesOfItem(atPath: sb.archiveRoot.appendingPathComponent(linkRel).path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        // Journal: bogus entries were NOT advanced to abandoned/done by acting on them.
        let latest = ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)
        #expect(latest[ghost]?.state == .published && latest[ghost2]?.state == .published)
    }

    @Test("R4-A: engine contained-lookup helpers refuse escapes and symlinks, report absence as nil")
    func containedHelpers() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("helpers")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let root = sb.archiveRoot.path
        #expect(!ArchivePromoteEngine.isContainedRelPath("../x.mov", root: root))
        #expect(!ArchivePromoteEngine.isContainedRelPath("30_Video/../../x.mov", root: root))
        #expect(!ArchivePromoteEngine.isContainedRelPath("/abs/x.mov", root: root))
        #expect(!ArchivePromoteEngine.isContainedRelPath("x.mov", root: root), "must sit in a bucket")
        #expect(ArchivePromoteEngine.isContainedRelPath("30_Video/Undated/x.mov", root: root))
        #expect(throws: ArchivePromoteEngine.Failure.self) { _ = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: "../x.mov") }
        #expect(throws: ArchivePromoteEngine.Failure.self) { _ = try ArchivePromoteEngine.removeContainedPartial(root: root, relativePath: "../x.mov") }
        #expect(try ArchivePromoteEngine.openContainedFile(root: root, relativePath: "30_Video/Nope/x.mov") == nil)
        #expect(try ArchivePromoteEngine.openContainedFile(root: root, relativePath: "30_Video/x.mov") == nil)
        let outside = sb.root.appendingPathComponent("o.mov")
        try "o".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sb.archiveRoot.appendingPathComponent("30_Video/l.mov"), withDestinationURL: outside)
        #expect(throws: ArchivePromoteEngine.Failure.self) { _ = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: "30_Video/l.mov") }
        try "p".write(to: sb.archiveRoot.appendingPathComponent("30_Video/real.mov.partial"), atomically: true, encoding: .utf8)
        #expect(try ArchivePromoteEngine.removeContainedPartial(root: root, relativePath: "30_Video/real.mov"))
        #expect(!FileManager.default.fileExists(atPath: sb.archiveRoot.appendingPathComponent("30_Video/real.mov.partial").path))
    }

    // MARK: R4-C — CSV formula neutralization

    @Test("R4-C: fields starting with = + - @ (after leading spaces) are quoted AND prefixed with a single quote; round-trip keeps the prefix",
          arguments: ["=HYPERLINK(\"http://x\",\"click\")", "+1+1", "-2+3", "@SUM(A1)", "  =cmd|' /C calc'!A0"])
    func csvFormulaNeutralized(field: String) {
        let escaped = ArchiveManifestCSV.escape(field)
        #expect(escaped.hasPrefix("\"'"), "\(escaped)")
        let inner = String(escaped.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        #expect(inner.hasPrefix("'"))
        #expect(!ArchiveManifestCSV.escape("plain").contains("'"))
        #expect(ArchiveManifestCSV.escape("1992-07-15") == "\"1992-07-15\"", "dates keep their leading digit")
        // Whole row: a formula-shaped slug in the relpath and a formula person.
        let row = ArchiveManifestCSV.Row(promotedAt: Date(), archiveRelPath: "30_Video/Undated/xxxx-xx-xx_" + field,
                                         sha256: "s", sizeBytes: 1, originalPath: "/p", originalVolume: "v",
                                         recordID: UUID(), sourceRecordID: UUID(), recordDate: "", dateConfidence: "",
                                         people: [field], starRating: 3)
        let fields = ArchiveManifestCSV.fields(ofLine: ArchiveManifestCSV.line(for: row))
        #expect(fields[10].hasPrefix("'"))
        #expect(!fields[10].dropFirst().hasPrefix("'"), "exactly one quote added")
    }

    // MARK: R4-D — import relink

    @Test("R5-B1: source + archive copy with IDENTICAL partialMD5/size/fixity survive import into an EMPTY catalog and are relinked into a catalog that already has the source — catalog import AND bundle import",
          arguments: [false, true])
    func importKeepsArchiveCopiesAndRelinks(viaBundle: Bool) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox(viaBundle ? "relinkB" : "relinkC")
        defer { sb.cleanup() }
        // Remote catalog: source + its BYTE-IDENTICAL archive copy (same md5, size, fixity).
        let remote = MasterArchiveTestSupport.makeModel(sb)
        let remoteSource = VideoRecord()
        remoteSource.filename = "tape.mov"; remoteSource.fullPath = "/Volumes/A/tape.mov"
        remoteSource.partialMD5 = "deadbeef"; remoteSource.sizeBytes = 4_242
        let copy = VideoRecord()
        copy.filename = "1992-xx-xx_tape.mov"
        copy.fullPath = "/Volumes/Archive/Breen_Family_Archive/30_Video/1990-1999/1992/1992-xx-xx_tape.mov"
        copy.partialMD5 = "deadbeef"; copy.sizeBytes = 4_242
        copy.derivedFrom = remoteSource.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archiveFixity = ArchiveFixity(digest: "abc", verifiedAt: Date(), sizeBytes: 4_242)
        remote.records = [remoteSource, copy]

        func importInto(_ model: VideoScanModel) async throws -> (added: Int, skipped: Int) {
            if viaBundle {
                let url = sb.root.appendingPathComponent("remote.videoscanbundle")
                _ = try BundleExporter.writeBundle(records: remote.records, scanTargets: [], to: url)
                let payload = try BundleImporter.read(from: url)
                let r = await model.applyBundlePayload(payload, bundleURL: url)
                return (r.recordsAdded, r.recordsSkipped)
            } else {
                let url = sb.root.appendingPathComponent("remote_catalog.json")
                try remote.exportCatalog(to: url)
                let r = try model.importCatalog(from: url)
                return (r.added, r.skipped)
            }
        }

        // 1) Empty catalog: BOTH survive, link resolves with the remote ids.
        let empty = MasterArchiveTestSupport.makeModel(sb)
        let r1 = try await importInto(empty)
        #expect(r1.added == 2 && r1.skipped == 0, "source and copy are never deduped against each other: \(r1)")
        let c1 = try #require(empty.records.first { $0.fullPath == copy.fullPath })
        #expect(c1.derivedFrom == remoteSource.id)
        #expect(empty.promotionSource(of: c1)?.id == remoteSource.id)
        // Importing the SAME export again is a no-op (cross-catalog same-record dedup still works).
        let r1b = try await importInto(empty)
        #expect(r1b.added == 0 && r1b.skipped == 2, "\(r1b)")

        // 2) Catalog that already has the source under a DIFFERENT id: copy added + relinked.
        let sb2 = try MasterArchiveTestSupport.makeSandbox(viaBundle ? "relinkB2" : "relinkC2")
        defer { sb2.cleanup() }
        let local = MasterArchiveTestSupport.makeModel(sb2)
        let localSource = VideoRecord()
        localSource.filename = "tape.mov"; localSource.fullPath = "/Volumes/A/tape.mov"
        localSource.partialMD5 = "deadbeef"; localSource.sizeBytes = 4_242
        // A decoy with the same content identity but a different path — the
        // stand-in must be the same-path record, not this one.
        let decoy = VideoRecord()
        decoy.filename = "tape.mov"; decoy.fullPath = "/Volumes/Backup/tape.mov"
        decoy.partialMD5 = "deadbeef"; decoy.sizeBytes = 4_242
        local.records = [decoy, localSource]
        let r2 = try await importInto(local)
        #expect(r2.added == 1 && r2.skipped == 1, "\(r2)")
        let c2 = try #require(local.records.first { $0.fullPath == copy.fullPath })
        #expect(c2.derivedFrom == localSource.id, "relinked to the SAME-PATH local record, not the decoy")
        #expect(local.promotionSource(of: c2) === localSource)
        #expect(local.masterArchiveCopy(of: localSource) === c2)
        #expect(local.masterArchiveCopy(of: decoy) == nil)
    }

    @Test("R5-B1: identity keys — an archive copy keys on its archive location, never on content; sources keep content identity")
    func identityKeyForArchiveCopies() {
        let src = VideoRecord(); src.partialMD5 = "m"; src.sizeBytes = 9; src.fullPath = "/Volumes/A/x.mov"
        let cp = VideoRecord(); cp.partialMD5 = "m"; cp.sizeBytes = 9; cp.fullPath = "/Volumes/Arc/Breen_Family_Archive/30_Video/Undated/x.mov"
        cp.derivationKind = ArchivePromotion.derivationKind
        let cp2 = VideoRecord(); cp2.partialMD5 = "m"; cp2.sizeBytes = 9; cp2.fullPath = "/Volumes/Arc/Breen_Family_Archive/30_Video/Undated/x.mov/"
        cp2.derivationKind = ArchivePromotion.derivationKind
        #expect(VideoScanModel.identityKey(for: src) != VideoScanModel.identityKey(for: cp))
        #expect(VideoScanModel.identityKey(for: cp) == VideoScanModel.identityKey(for: cp2), "canonical path")
        #expect(VideoScanModel.identityKey(for: src) == "md5:m:9")
    }

    // MARK: R5-B2 — adopt-identical goes through the dirfd chain

    @Test("R5-B2: a symlinked intermediate dir whose target holds a byte-identical file is REFUSED, not adopted")
    func adoptIdenticalThroughSymlinkRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("adoptlink")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)   // undated → 30_Video/Undated/…
        model.records = [rec]
        // 30_Video/Undated → symlink to an OUTSIDE dir that already holds a
        // byte-identical file under the exact destination name.
        let outside = sb.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let identical = outside.appendingPathComponent("xxxx-xx-xx_test_src_0.mov")
        try FileManager.default.copyItem(at: src, to: identical)
        try FileManager.default.createDirectory(at: sb.archiveRoot.appendingPathComponent("30_Video"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sb.archiveRoot.appendingPathComponent("30_Video/Undated"),
                                                   withDestinationURL: outside)
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed(let msg) = job.state else { Issue.record("expected refusal, got \(job.state)"); return }
        #expect(msg.contains("failed 1"), "\(msg)")
        #expect(job.outcomes.first?.detail.contains("symlink") == true, "\(job.outcomes.first?.detail ?? "")")
        #expect(model.masterArchiveCopy(of: rec) == nil, "NOT adopted")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        #expect(model.records.count == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: outside.path))?.count == 1, "outside dir untouched")
    }
}

/// Switchable volume-UUID answer for the TASK-LOCAL probe seam. Only the
/// closure passed to `withValue` sees it — never another suite.
final class ProbeBox: @unchecked Sendable {
    var uuid: String?
    init(_ uuid: String?) { self.uuid = uuid }
}

/// Switchable barrier failures for the TASK-LOCAL `barriers` seam.
final class BarrierBox: @unchecked Sendable {
    var failFullFsync = false
    var failFsync = false
    /// After this many successful F_FULLFSYNC calls, the rest fail.
    var fullFsyncFailAfterCalls: Int?
    private(set) var fullFsyncCalls = 0
    func reset() { failFullFsync = false; failFsync = false; fullFsyncFailAfterCalls = nil; fullFsyncCalls = 0 }
    var barriers: ArchivePromoteEngine.Barriers {
        let live = ArchivePromoteEngine.Barriers.live
        return .init(
            fullFsync: { [self] fd in
                fullFsyncCalls += 1
                if failFullFsync { return -1 }
                if let n = fullFsyncFailAfterCalls, fullFsyncCalls > n { return -1 }
                return live.fullFsync(fd)
            },
            fsync: { [self] fd in failFsync ? -1 : live.fsync(fd) })
    }
}
