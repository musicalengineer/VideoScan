// HashReadFaultFixityTests.swift
// NEGATIVE MATRIX — the verbs that STORE a whole-file digest from one read
// (hash read seam, 2026-11-20): "Fill In Full Hashes…" (FullHashBackfillJob)
// and "Bind Fixity to Volume" (BindFixityToVolumeJob). Both hash through
// `FixityRebind.rehash` → `ArchivePromoteEngine.sha256(fd:)`.
//
//   EIO mid-file        → `unreadable`: nothing stored, the row and the
//                         summary say so, the old fixity (if any) is kept;
//   a read ending early → refused ("read N bytes, the file has M"): nothing
//                         stored;
//   one flipped bit     → P1, PARKED (Codex r1 #2). A single read with no
//                         second read cannot see it, and the digest stored
//                         need not be a digest of "nothing": when files A
//                         and B differ in one bit, a flip on that bit while
//                         reading B stores SHA-256(A) as B's fixity, under
//                         B's own current stamp. Bind does the same AND
//                         overwrites the true digest it held. No collision
//                         is needed.
//
// What then believes the false digest WITHOUT reading the file:
//   * Promote — pinned RED below: B is set aside as already archived on the
//     strength of the stored digest, before any read of B — at plan time
//     (`promoteRefusal`); the job's own duplicate check
//     (PromoteToArchiveJob+Guards `trustedSourceDigestOffMain`) trusts the
//     same digest. B's bytes are in no archive.
//   * Delete Duplicates' tier facts — demonstrated below: B is counted as a
//     verified copy of A's bytes from its stamp alone.
//   NOT VERIFIED HERE: what Delete Duplicates EXECUTION does with a keeper
//   whose cached fixity is false (the cached-keeper contract documented at
//   VerifyArchiveCopiesJob `invalidateArchiveFixity`), and Archive Angel's
//   fixity freshness check. Those use other hashers / paths this seam does
//   not reach. Prune re-reads both files and is not affected.
//
// In every cell the file's bytes are untouched, and a clean run afterwards
// stores the true digest (EIO / short read) — the refusal blocks nothing.
//
// Parallel-safe: sandbox per test, task-local hook, no global log swap.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func trueDigest(_ path: String) -> String {
    SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
        .map { String(format: "%02x", $0) }.joined()
}

@Suite("Hash read fault × Fill In Full Hashes / Bind Fixity — no digest is stored from a read that failed")
@MainActor
struct HashReadFaultFixityTests {

    // MARK: Fill In Full Hashes

    private func runBackfill(_ model: VideoScanModel) async -> FullHashBackfillJob {
        let job = FullHashBackfillJob(model: model, marker: nil)
        job.volumeOnline = { _ in true }
        job.tickMilliseconds = 20
        job.start()
        await job.task?.value
        return job
    }

    @Test("BACKFILL × {EIO, short read}: nothing is stored for the faulted file, it is counted and named, the control file is hashed; a clean run then stores the true digest",
          .timeLimit(.minutes(2)), arguments: [HashReadFault.Kind.eio, .shortRead])
    func backfillStoresNothingFromAFailedRead(_ kind: HashReadFault.Kind) async throws {
        let sb = try ShowAgainSandbox.make("hrf_fhb_\(kind)"); defer { sb.cleanup() }
        let victim = try sb.record("test_hrf_victim.mov", bytes: 30_000, stage: .none)
        let control = try sb.record("test_hrf_control.mov", bytes: 31_000, stage: .none)
        let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: victim.fullPath))

        let fault = HashReadFault(kind, pathSuffix: "test_hrf_victim.mov", atByte: 12_000, onPass: 0)
        let job = await fault.run { await runBackfill(sb.model) }
        #expect(fault.firedCount == 1, "\(kind): the fault never reached the read")
        print("[hash-matrix] full-hash-backfill | \(kind) | \(job.state) | \(job.totals.line)")

        #expect(victim.contentFixity == nil, "\(kind): a digest was stored from a failed read")
        #expect(control.contentFixity?.digest == trueDigest(control.fullPath))
        #expect(job.totals[.hashed] == 1 && job.storedCount == 1, "\(job.totals.line)")
        switch kind {
        case .eio:
            #expect(job.totals[.unreadable] == 1 && job.totals.line.contains("1 unreadable"), "\(job.totals.line)")
        case .shortRead:
            #expect(job.totals[.changedDuringRead] == 1, "\(job.totals.line)")
            withKnownIssue("PARKED 2026-11-20 (P3, truth): a read that ENDED EARLY is counted as \"changed while it was read\" (FixityRebind.changedDuringRead); the detail \"read N bytes, the file has M\" is accurate, the bucket is not — the file did not change. Proposed: a `.unreadable(\"read N of M bytes\")` outcome for seen ≠ size when the before/after stamps agree.") {
                #expect(job.totals[.unreadable] == 1, "\(job.totals.line)")
            }
        case .bitFlip: break
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: victim.fullPath)) == bytesBefore)
        // The run is not reported as a clean success for that file.
        #expect(job.totals.line.contains("1 of 2 hashed in full"), "\(job.totals.line)")

        let clean = await runBackfill(sb.model)
        #expect(clean.totals[.hashed] == 1 && victim.contentFixity?.digest == trueDigest(victim.fullPath), "\(clean.totals.line)")
    }

    /// Two files, one bit apart at byte 12,000. A = the control; B = A with
    /// that bit inverted.
    private static let flipAt = 12_000
    private func writePair(_ a: URL, _ b: URL, bytes: Int = 30_000) throws -> (a: Data, b: Data) {
        let dataA = hashSeamBlob(bytes: bytes, seed: 0xA11CE)
        var dataB = dataA
        dataB[Self.flipAt] ^= 0x01
        try dataA.write(to: a)
        try dataB.write(to: b)
        return (dataA, dataB)
    }

    /// Codex r1 #2 (P1, parked).
    @Test("P1 (parked) — BACKFILL × bit flip: files A and B differ in one bit; a flip on that bit while reading B stores A's digest as B's fixity, under B's own stamp — expected: no digest B's bytes do not have is ever stored")
    func backfillStoresAnotherFilesDigest() async throws {
        let sb = try ShowAgainSandbox.make("hrf_fhb_flip"); defer { sb.cleanup() }
        let recA = try sb.record("test_hrf_a.mov", bytes: 30_000, stage: .none)
        let recB = try sb.record("test_hrf_b.mov", bytes: 30_000, stage: .none)
        _ = try writePair(URL(fileURLWithPath: recA.fullPath), URL(fileURLWithPath: recB.fullPath))
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_b.mov", atByte: Int64(Self.flipAt), onPass: 0)
        let job = await fault.run { await runBackfill(sb.model) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] full-hash-backfill | bitFlip (B read as A) | \(job.state) | \(job.totals.line)")
        let storedA = try #require(recA.contentFixity)
        let storedB = try #require(recB.contentFixity)
        #expect(storedA.digest == trueDigest(recA.fullPath))
        #expect(job.totals[.hashed] == 2, "the run calls both hashed in full: \(job.totals.line)")
        // The false digest sits under a stamp that describes B right now, so
        // every stamp-trusting reader believes it without reading B.
        #expect(storedB.describesFileNow(FileIdentityStamp.capture(path: recB.fullPath)))
        withKnownIssue("PARKED 2026-11-20 (P1, Codex r1 #2): Fill In Full Hashes stores the digest of ONE read. A flip on the one bit that separates B from A stores SHA-256(A) as B's fixity under B's current stamp — the catalog now says two different files are byte-identical. Proposed: do not store a first digest from a single read (read twice and require agreement), or mark single-read digests unproven so no consumer treats them as a proof.") {
            #expect(storedB.digest == trueDigest(recB.fullPath), "B carries \(storedB.digest.prefix(12))…")
            #expect(storedB.digest != storedA.digest, "B's stored digest IS A's: the catalog calls two different files identical")
        }
    }

    /// The consumer, reached (Codex r1 #2, P1, parked): A is in the archive.
    /// B — one bit different, never archived — carries A's digest from the
    /// faulted backfill above. Promote trusts a stamp-bound stored digest
    /// for its duplicate check and sets B aside as already archived before
    /// reading a byte of B (today at plan time; the job's own check,
    /// `trustedSourceDigestOffMain`, would do the same).
    @Test("P1 (parked) — CONSUMER: after the faulted backfill, Promote sets B aside as already archived without reading it; B's bytes are in no archive — expected: B is read and promoted")
    func promoteBelievesTheFalseDigest() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_consumer"); defer { sb.cleanup() }
        let urlA = sb.sources.appendingPathComponent("test_hrf_a.mov")
        let urlB = sb.sources.appendingPathComponent("test_hrf_b.mov")
        let pair = try writePair(urlA, urlB)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let recA = MasterArchiveTestSupport.makeRecord(path: urlA.path, userDate: "1991-02-03")
        let recB = MasterArchiveTestSupport.makeRecord(path: urlB.path, userDate: "1992-06-07")
        model.records = [recA, recB]
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        try #require(model.masterArchiveCopy(of: recA) != nil, "fixture: A is archived")

        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_b.mov", atByte: Int64(Self.flipAt), onPass: 0)
        _ = await fault.run { await runBackfill(model) }
        try #require(fault.firedCount == 1 && recB.contentFixity?.digest == trueDigest(urlA.path),
                     "fixture: the faulted backfill stored A's digest on B")

        // No fault from here on: a clean Promote of B.
        let reads = HashReadFault(.eio, pathSuffix: "test_hrf_b.mov", atByte: 1 << 40, onPass: 0)   // counts, never fires
        let plan = try #require(model.buildPromotePlan(recordIDs: [recB.id]))
        let job = try #require(await reads.run { await MasterArchiveTestSupport.promote(model, ids: [recB.id]) })
        await job.completionTask?.value
        let skips = plan.skipped.map { "\($0.filename): \($0.reason)" }
        let rows = job.outcomes.map { "\($0.kind): \($0.detail)" }
        print("[hash-matrix] promote after faulted backfill | B carries A's digest | plan skipped \(skips) | rows \(rows) | \(job.state) | reads of B: \(reads.passCount)")
        withKnownIssue("PARKED 2026-11-20 (P1, Codex r1 #2): Promote treats a stamp-bound stored digest as proof that a file is already archived — at plan time (promoteRefusal) and again in the job's duplicate check (trustedSourceDigestOffMain) — before reading the source. With a false stored digest, a file whose bytes are in NO archive is set aside as already archived, unread. Proposed: an \"already archived\" answer is a vouch — prove the source's current bytes first (the read Promote already does on the copy path).") {
            #expect(plan.skipped.isEmpty && plan.entries.map(\.recordID) == [recB.id], "set aside at plan time: \(skips)")
            #expect(job.outcomes.first?.kind == .promoted, "\(rows) — \(job.state)")
            #expect(reads.passCount >= 1, "B was never read")
            #expect(model.masterArchiveCopy(of: recB) != nil, "B has no archive copy")
        }
        // The truth on disk: only A's bytes are in the archive.
        let archived = MasterArchiveTestSupport.archivedFiles(sb).map { try? Data(contentsOf: sb.archiveRoot.appendingPathComponent($0)) }
        #expect(!archived.contains(pair.b), "B's bytes are in the archive")
        #expect(try Data(contentsOf: urlB) == pair.b)
    }

    /// Demonstration, not a parked defect of its own (the defect is the
    /// stored digest): Delete Duplicates' tier facts count a sibling as a
    /// verified copy of the keeper's bytes from its stamped fixity, unread —
    /// that is their documented design. With B carrying A's digest they
    /// report two verified copies of bytes only ONE file holds. What the
    /// deletion itself then does is NOT verified here.
    @Test("CONSUMER (demonstration): Delete Duplicates' tier facts count B — carrying A's digest under its own stamp — as a second verified copy of A's bytes, unread")
    func deletionTierFactsCountTheFalseCopy() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_tier"); defer { sb.cleanup() }
        let urlA = sb.sources.appendingPathComponent("test_hrf_a.mov")
        let urlB = sb.sources.appendingPathComponent("test_hrf_b.mov")
        _ = try writePair(urlA, urlB)
        let digestA = trueDigest(urlA.path)
        // Exactly what the faulted backfill stores: A's digest, B's stamp.
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_b.mov", atByte: Int64(Self.flipAt))
        guard case .bound(let falseFixity) = fault.runSync({ FixityRebind.rehash(path: urlB.path, control: .init()) }) else {
            Issue.record("fixture: the faulted read did not bind"); return
        }
        try #require(falseFixity.digest == digestA && fault.firedCount == 1)
        var c = DeletionTierCandidates()
        c.keeperLabel = "keeper"
        c.keeperPath = urlA.path
        c.otherCopies = [.init(path: urlB.path, fixity: falseFixity, label: "sibling test_hrf_b.mov")]
        let facts = DeletionTierFacts.gather(c, digest: digestA)
        print("[hash-matrix] delete-duplicates tier facts | B carries A's digest | \(facts.summary)")
        #expect(facts.remainingVerifiedCopies == 2, "\(facts.summary)")
        #expect(trueDigest(urlB.path) != digestA, "only ONE file holds those bytes")
    }

    // MARK: Bind Fixity to Volume

    private struct BindRig {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let record: VideoRecord
        let legacy: ContentFixity
        let digest: String
    }

    /// One record whose stored fixity is true but pre-UUID (no volume
    /// identity) — exactly what Bind Fixity re-reads.
    private func bindRig(_ label: String) throws -> BindRig {
        let sb = try MasterArchiveTestSupport.makeSandbox("hrf_bind_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let url = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_hrf_bind.mov"),
                                                         bytes: 30_000, seed: 77)
        let digest = trueDigest(url.path)
        let fx = try #require(ContentFixity.captured(path: url.path, digest: digest, byteCount: 30_000))
        let s = fx.stamp
        let legacy = ContentFixity(algorithm: fx.algorithm, digest: fx.digest, byteCount: fx.byteCount,
                                   stamp: FileIdentityStamp(device: s.device &+ 7, inode: s.inode, size: s.size,
                                                            mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs, volumeUUID: nil),
                                   computedAt: fx.computedAt)
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        rec.contentFixity = legacy
        model.records = [rec]
        return BindRig(sb: sb, model: model, record: rec, legacy: legacy, digest: digest)
    }

    private func runBind(_ r: BindRig) async -> BindFixityToVolumeJob {
        let job = BindFixityToVolumeJob(scopePath: r.sb.sources.path, scopeLabel: "Scratch", model: r.model)
        job.start()
        await job.task?.value
        return job
    }

    @Test("BIND × {EIO, short read}: nothing is bound, the old fixity stays exactly as it was (still untrusted), the tally and summary say why; a clean run then binds the true digest",
          .timeLimit(.minutes(2)), arguments: [HashReadFault.Kind.eio, .shortRead])
    func bindStoresNothingFromAFailedRead(_ kind: HashReadFault.Kind) async throws {
        let r = try bindRig("\(kind)"); defer { r.sb.cleanup() }
        let fault = HashReadFault(kind, pathSuffix: "test_hrf_bind.mov", atByte: 12_000, onPass: 0)
        let job = await fault.run { await runBind(r) }
        #expect(fault.firedCount == 1, "\(kind): the fault never reached the read")
        print("[hash-matrix] bind-fixity | \(kind) | \(job.state) | \(job.summaryLine)")

        #expect(r.record.contentFixity == r.legacy, "\(kind): the fixity was rewritten from a failed read")
        #expect(job.tally.bound == 0 && job.storedCount == 0 && job.tally.digestChanged == 0, "\(job.tally)")
        switch kind {
        case .eio: #expect(job.tally.unreadable == 1 && job.summaryLine.contains("1 unreadable"), "\(job.summaryLine)")
        case .shortRead: #expect(job.tally.changedDuringRead == 1 && job.summaryLine.contains("1 changed during the read"), "\(job.summaryLine)")
        case .bitFlip: break
        }
        #expect(trueDigest(r.record.fullPath) == r.digest)
        #expect(r.model.fixityRebindCandidates(prefix: r.sb.sources.path).map(\.id) == [r.record.id], "still waiting to be bound")

        let clean = await runBind(r)
        #expect(clean.tally.bound == 1 && clean.tally.digestChanged == 0, "\(clean.summaryLine)")
        #expect(r.record.contentFixity?.digest == r.digest && r.record.contentFixity?.stamp.volumeUUID != nil)
    }

    /// Codex r1 #2 (P1, parked; re-ranked from P2). Bind HAS a reference
    /// (the digest it is re-binding), and a flipped read disagrees with it —
    /// yet the job stores the new digest over the old, true one and counts
    /// the file as bound. It says so ("held different bytes than before"),
    /// but the catalog now carries, under a fresh volume-bound stamp, a
    /// digest of bytes that are not in this file — here, exactly the digest
    /// of the sibling file one bit away.
    @Test("P1 (parked) — BIND × bit flip: the one disagreeing read replaces the TRUE stored digest, and the digest stored is another file's — expected: the true digest stays")
    func bindOverwritesATrueDigestOnOneDisagreeingRead() async throws {
        let r = try bindRig("flip"); defer { r.sb.cleanup() }
        // The sibling one bit away from the record's file.
        var sibling = try Data(contentsOf: URL(fileURLWithPath: r.record.fullPath))
        sibling[Self.flipAt] ^= 0x01
        let siblingDigest = SHA256.hash(data: sibling).map { String(format: "%02x", $0) }.joined()
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_bind.mov", atByte: Int64(Self.flipAt), onPass: 0)
        let job = await fault.run { await runBind(r) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] bind-fixity | bitFlip | \(job.state) | \(job.summaryLine)")
        // It is at least SAID: the disagreement is counted and in the summary.
        #expect(job.tally.digestChanged == 1 && job.summaryLine.contains("1 held different bytes than before"), "\(job.summaryLine)")
        #expect(trueDigest(r.record.fullPath) == r.digest, "the file itself never changed")
        withKnownIssue("PARKED 2026-11-20 (P1, Codex r1 #2; was P2): Bind Fixity replaces a stored digest with the digest of ONE read that disagrees with it (applyFixityRebind → .digestChanged, still written and counted as bound). A flip on the read path overwrites a TRUE digest with a false one — which can be exactly another file's digest — under a volume-bound stamp. Proposed: on disagreement read the file a second time; store only if the two fresh reads agree, else leave the old fixity and report \"read twice, the reads disagree\".") {
            #expect(r.record.contentFixity?.digest == r.digest, "the true digest was replaced by \(r.record.contentFixity?.digest.prefix(12) ?? "nil")…")
            #expect(r.record.contentFixity?.digest != siblingDigest, "the stored digest is the sibling file's")
        }
    }
}
