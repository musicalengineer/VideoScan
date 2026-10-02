// PromoteRefusalRollbackTests.swift
// Codex review 2026-10-02, finding 4 (P2) + the coverage gaps it named.
//
// ARCH-7: every Promote refusal leaves the archive EXACTLY as it was — no
// journal intent, no new directory, no partial, no manifest row, no catalog
// link. The source-digest proof now runs before the intent (finding 1), so
// a lying stored fixity is refused with nothing written. A source that
// changes AFTER the proof — during the copy — can only be detected by the
// engine, after the intent and the directories exist; that path now rolls
// back completely: partial removed, the directories this run created
// removed (empty-only, rmdir), and this run's own journal line retracted
// (truncated back only if it is still the journal's last line — otherwise
// an `abandoned` line is appended and the refusal says so). Nothing that
// existed before the run is touched.
//
// Also pinned (codex coverage gaps): deterministic cancellation releases the
// digest claim and writes nothing; an end-to-end duplicate sensor with more
// than five distinct sources.
//
// Sandbox only (`test_*`), never /Volumes or App Support.

import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
enum ArchiveSnapshot {
    struct State: Equatable {
        let tree: [String]          // every path under the archive root, dirs included
        let journal: Data?          // nil = no journal file
        let manifest: Data?
    }

    static func take(_ sb: MasterArchiveTestSupport.Sandbox) -> State {
        let tree = ((try? FileManager.default.subpathsOfDirectory(atPath: sb.archiveRoot.path)) ?? []).sorted()
        return State(tree: tree,
                     journal: try? Data(contentsOf: sb.journalURL),
                     manifest: try? Data(contentsOf: sb.manifestURL))
    }
}

@Suite("Codex 2026-10-02 #4 — a refused Promote leaves the archive byte-for-byte as it was", .serialized)
@MainActor
struct PromoteRefusalRollbackTests {

    typealias H = PromoteIntegrityHarness

    @Test("a LYING stored fixity: journal bytes, archive tree and manifest identical before and after")
    func lyingFixityLeavesNoTrace() async throws {
        let (sb, model) = try H.setup("rb_lying")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape.mov", seed: 51)
        a.userDate = "1994"; a.userDateConfidence = UserDateConfidence.known.rawValue   // new year folders
        let stamp = try #require(FileIdentityStamp.capture(path: a.fullPath))
        let lying = ContentFixity(digest: String(repeating: "e", count: 64), byteCount: a.sizeBytes, stamp: stamp)
        try #require(lying.isUsableForVerification)
        a.contentFixity = lying
        let before = ArchiveSnapshot.take(sb)
        let job = try await H.run(model, ids: [a.id])
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .failed, "\(job.outcomes)")
        // Refused by the PRE-INTENT proof (nothing was ever written, not
        // even transiently) — not by the engine's in-copy check + rollback,
        // which is the second line of defence.
        #expect(o.detail.contains("stored fingerprint"), "\(o.detail)")
        #expect(ArchiveSnapshot.take(sb) == before, "the archive must be exactly as it was")
        #expect(model.masterArchiveCopy(of: a) == nil)
    }

    @Test("the source CHANGES after the proof, during the copy: refused and rolled back completely")
    func sourceChangedMidCopyRollsBack() async throws {
        let (sb, model) = try H.setup("rb_midcopy")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape.mov", seed: 52, bytes: 64_000)
        a.userDate = "1994"; a.userDateConfidence = UserDateConfidence.known.rawValue
        let proven = try #require(MasterArchiveTestSupport.sha256(ofFile: a.fullPath))
        let before = ArchiveSnapshot.take(sb)
        let job = try H.job(model, ids: [a.id])
        job.testHookAfterSourceProof = { rec in
            // Same size, different bytes: the stamp check alone cannot see it.
            _ = try? MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: rec.fullPath), bytes: 64_000, seed: 99)
        }
        job.start()
        await job.task?.value
        await job.completionTask?.value
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .failed && o.detail.contains("changed"), "\(o.kind) — \(o.detail)")
        #expect(ArchiveSnapshot.take(sb) == before, "journal intent, new folders and partial all rolled back")
        #expect(H.partials(sb).isEmpty)
        #expect(model.masterArchiveCopy(of: a) == nil)
        #expect(model.promoteDigestClaim(proven, root: sb.archiveRoot.path) == nil, "claim released")
    }

    @Test("ENGINE: a digest mismatch removes the partial AND the folders this call created")
    func engineRemovesCreatedFolders() throws {
        let (sb, _) = try H.setup("rb_engine")
        defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_e.mov"), bytes: 40_000, seed: 53)
        let rel = "30_Video/1990-1999/1994/1994-xx-xx_test_e.mov"
        let before = ArchiveSnapshot.take(sb)
        let h = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h.close() }
        #expect(throws: ArchivePromoteEngine.Failure.sourceChangedDuringCopy(src.path)) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h, root: sb.archiveRoot.path, relativePath: rel,
                                                       expectedSourceSHA: String(repeating: "0", count: 64))
        }
        #expect(ArchiveSnapshot.take(sb) == before)
    }

    @Test("ENGINE: a folder that EXISTED before the call is never removed by the rollback")
    func engineKeepsPreexistingFolders() throws {
        let (sb, _) = try H.setup("rb_keep")
        defer { sb.cleanup() }
        let year = sb.archiveRoot.appendingPathComponent("30_Video/1990-1999/1994", isDirectory: true)
        try FileManager.default.createDirectory(at: year, withIntermediateDirectories: true)
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_k.mov"), bytes: 40_000, seed: 54)
        let before = ArchiveSnapshot.take(sb)
        let h = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h.close() }
        _ = try? ArchivePromoteEngine.copyVerifyPublish(source: h, root: sb.archiveRoot.path,
                                                        relativePath: "30_Video/1990-1999/1994/1994-xx-xx_test_k.mov",
                                                        expectedSourceSHA: String(repeating: "0", count: 64))
        #expect(ArchiveSnapshot.take(sb) == before)
        #expect(FileManager.default.fileExists(atPath: year.path), "the pre-existing year folder stays")
    }

    // MARK: Journal retraction contract

    private func entry(_ state: ArchivePromoteJournal.Entry.State) -> ArchivePromoteJournal.Entry {
        ArchivePromoteJournal.Entry(sourceRecordID: UUID(), sourcePath: "/private/tmp/test_src.mov",
                                    destRelPath: "30_Video/Undated/xxxx-xx-xx_test.mov", state: state,
                                    sha256: nil, copyRecordID: nil, at: Date())
    }

    @Test("JOURNAL: retract restores the pre-existing journal bytes exactly")
    func retractRestoresExactBytes() throws {
        let (sb, _) = try H.setup("rb_jr_exact")
        defer { sb.cleanup() }
        try ArchivePromoteJournal.append(entry(.done), rootPath: sb.archiveRoot.path)
        let before = try Data(contentsOf: sb.journalURL)
        let r = try ArchivePromoteJournal.appendRetractable(entry(.intent), rootPath: sb.archiveRoot.path)
        #expect(!r.createdFile && r.offset == Int64(before.count))
        #expect(ArchivePromoteJournal.retract(r, rootPath: sb.archiveRoot.path))
        #expect(try Data(contentsOf: sb.journalURL) == before)
    }

    @Test("JOURNAL: retracting the append that CREATED the journal removes the file")
    func retractRemovesCreatedJournal() throws {
        let (sb, _) = try H.setup("rb_jr_created")
        defer { sb.cleanup() }
        try? FileManager.default.removeItem(at: sb.journalURL)
        let r = try ArchivePromoteJournal.appendRetractable(entry(.intent), rootPath: sb.archiveRoot.path)
        #expect(r.createdFile && r.offset == 0)
        #expect(ArchivePromoteJournal.retract(r, rootPath: sb.archiveRoot.path))
        #expect(!FileManager.default.fileExists(atPath: sb.journalURL.path))
    }

    @Test("JOURNAL: when another line was appended after ours, retract refuses and changes nothing")
    func retractRefusesWhenNotLast() throws {
        let (sb, _) = try H.setup("rb_jr_notlast")
        defer { sb.cleanup() }
        let r = try ArchivePromoteJournal.appendRetractable(entry(.intent), rootPath: sb.archiveRoot.path)
        try ArchivePromoteJournal.append(entry(.intent), rootPath: sb.archiveRoot.path)   // another job
        let before = try Data(contentsOf: sb.journalURL)
        #expect(!ArchivePromoteJournal.retract(r, rootPath: sb.archiveRoot.path))
        #expect(try Data(contentsOf: sb.journalURL) == before, "their bytes are never touched")
        // Same length, different bytes in our slot: also refused.
        let r2 = try ArchivePromoteJournal.appendRetractable(entry(.intent), rootPath: sb.archiveRoot.path)
        let forged = ArchivePromoteJournal.AppendReceipt(offset: r2.offset, bytes: Data(repeating: 0x41, count: r2.bytes.count),
                                                         createdFile: false)
        let mid = try Data(contentsOf: sb.journalURL)
        #expect(!ArchivePromoteJournal.retract(forged, rootPath: sb.archiveRoot.path))
        #expect(try Data(contentsOf: sb.journalURL) == mid)
    }

    // MARK: Coverage gaps (codex): cancellation + duplicate sensor at scale

    @Test("CANCEL at a deterministic point (after the claim, before the intent): claim released, nothing written")
    func deterministicCancelReleasesClaim() async throws {
        let (sb, model) = try H.setup("rb_cancel")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape.mov", seed: 55)
        a.userDate = "1994"; a.userDateConfidence = UserDateConfidence.known.rawValue
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: a.fullPath))
        let before = ArchiveSnapshot.take(sb)
        let job = try H.job(model, ids: [a.id])
        var claimHeldAtHook: String?
        job.testHookAfterSourceProof = { [weak job] _ in
            claimHeldAtHook = model.promoteDigestClaim(sha, root: sb.archiveRoot.path)
            job?.cancel()
        }
        job.start()
        await job.task?.value
        await job.completionTask?.value
        #expect(claimHeldAtHook != nil, "the hook ran while the claim was held")
        #expect(model.promoteDigestClaim(sha, root: sb.archiveRoot.path) == nil, "a cancelled file releases its claim")
        #expect(ArchiveSnapshot.take(sb) == before, "nothing written")
        #expect(model.masterArchiveCopy(of: a) == nil)
        // The released claim does not block a later run.
        let again = try await H.run(model, ids: [a.id])
        #expect(H.outcome(again, a.id)?.kind == .promoted, "\(again.outcomes)")
    }

    @Test("SENSOR: 12 distinct sources with twins and a triplet, promoted in mixed batches three times → 12 files, no digest twice")
    func duplicateSensorTwelveSources() async throws {
        let (sb, model) = try H.setup("rb_sensor12")
        defer { sb.cleanup() }
        var recs: [VideoRecord] = []
        for i in 0..<12 {
            let r = try H.source(sb, model, name: "test_src_\(i).mov", seed: UInt64(300 + i), bytes: 8_000 + i)
            recs.append(r)
            if i % 3 == 0 { recs.append(try H.twin(of: r, sb, model, name: "test_dup_\(i).mov", subfolder: "dups_\(i)")) }
            if i == 4 {
                recs.append(try H.twin(of: r, sb, model, name: "test_dupA_\(i).mov", subfolder: "tripA"))
                recs.append(try H.twin(of: r, sb, model, name: "test_dupB_\(i).mov", subfolder: "tripB"))
            }
        }
        #expect(recs.count == 18)
        _ = try await H.run(model, ids: recs.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.id))
        _ = try await H.run(model, ids: recs.reversed().map(\.id))
        if let plan = model.buildPromotePlan(recordIDs: recs.map(\.id)), !plan.entries.isEmpty {
            let j = PromoteToArchiveJob(plan: plan, model: model); j.start(); await j.task?.value
        }
        let digests = H.archivedDigests(sb)
        #expect(digests.count == 12, "12 distinct sources → 12 files, got \(digests.count)")
        #expect(Set(digests).count == digests.count, "no sha256 twice in the archive")
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 12)
        #expect(Set(rows.map { $0[ArchiveManifestCSV.sha256Column] }).count == rows.count, "no sha256 twice in the manifest")
        #expect(H.partials(sb).isEmpty)
    }
}
