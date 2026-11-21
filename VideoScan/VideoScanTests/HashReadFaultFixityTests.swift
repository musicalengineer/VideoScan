// HashReadFaultFixityTests.swift
// NEGATIVE MATRIX — the verbs that STORE a whole-file digest from one read
// (hash read seam, 2026-11-20): "Fill In Full Hashes…" (FullHashBackfillJob)
// and "Bind Fixity to Volume" (BindFixityToVolumeJob). Both hash through
// `FixityRebind.rehash` → `ArchivePromoteEngine.sha256(fd:)`.
//
//   EIO mid-file        → `unreadable`: nothing stored, the row and the
//                         summary say so, the old fixity (if any) is kept;
//   a read ending early → `unreadable` ("could not be read in full (N of M
//                         bytes)", GH #504 D1): nothing stored;
//   one flipped bit     → BIND (GH #504 D3b, FIXED 2026-11-21): a read that
//                         disagrees with the stored digest is made a second
//                         time; the new digest is stored only when the two
//                         fresh reads agree, else the stored one is kept
//                         ("read twice, disagreed").
//                         FILL IN FULL HASHES (D4, DECIDED 2026-11-21: stays
//                         one read — standard fixity practice; pinned below,
//                         still under `withKnownIssue` as a known limit): when
//                         files A and B differ in one bit, a flip on that bit
//                         while reading B stores SHA-256(A) as B's fixity,
//                         under B's own current stamp. What keeps that from
//                         costing media: Delete Duplicates re-reads a keeper
//                         once per run before trashing on its cached fixity
//                         (D4), prune re-reads both files, and Promote's
//                         "already archived" answer is a refusal to copy.
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
            // GH #504 D1 (was P3): the file did not change — it could not be
            // read in full; the engine now says so and it lands in "unreadable".
            #expect(job.totals[.unreadable] == 1 && job.totals[.changedDuringRead] == 0, "\(job.totals.line)")
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

    /// Codex r1 #2 (was P1). DECIDED 2026-11-21, GH #504 D4: a first-time
    /// digest stays ONE read; this is the known limit, pinned.
    @Test("KNOWN LIMIT (D4, decided) — BACKFILL × bit flip: files A and B differ in one bit; a flip on that bit while reading B stores A's digest as B's fixity, under B's own stamp — expected: no digest B's bytes do not have is ever stored")
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
        withKnownIssue("KNOWN LIMIT, DECIDED 2026-11-21 (GH #504 D4; was P1, Codex r1 #2): Fill In Full Hashes stores a FIRST digest from ONE read (standard fixity practice; not doubled — 'we get better incrementally'). A flip on the one bit that separates B from A stores SHA-256(A) as B's fixity under B's current stamp. What keeps it from costing media: Delete Duplicates re-reads a keeper once per run before trashing on its cached fixity (D4) and reads the file that goes twice (D3a); prune re-reads both files; Promote's 'already archived' on a stored digest is a refusal to copy. If this ever passes, a first digest is no longer stored from one read: delete this known issue.") {
            #expect(storedB.digest == trueDigest(recB.fullPath), "B carries \(storedB.digest.prefix(12))…")
            #expect(storedB.digest != storedA.digest, "B's stored digest IS A's: the catalog calls two different files identical")
        }
    }

    /// The consumer, reached (Codex r1 #2, was P1; DECIDED D4 — behaviour
    /// left, wording made true): A is in the archive.
    /// B — one bit different, never archived — carries A's digest from the
    /// faulted backfill above. Promote trusts a stamp-bound stored digest
    /// for its duplicate check and sets B aside as already archived before
    /// reading a byte of B (today at plan time; the job's own check,
    /// `trustedSourceDigestOffMain`, would do the same).
    @Test("KNOWN LIMIT (D4, decided) — CONSUMER: after the faulted backfill, Promote sets B aside as already archived without reading it; B's bytes are in no archive. The skip's words say what was compared: 'same stored fingerprint … not re-read, nothing copied, nothing removed'")
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
        // GH #504 D4 (2026-11-21) — the behaviour stays, the WORDS are true: this
        // is a refusal to COPY made from the STORED fingerprint and a stat; the
        // file was not read, and nothing is removed on it.
        let detail = model.promoteSkipDetail(recordID: recB.id, reason: .alreadyPromoted) ?? ""
        #expect(detail.contains("same stored fingerprint (sha256 \(trueDigest(urlA.path).prefix(12))…)"), "\(detail)")
        #expect(detail.contains("this file was not re-read, nothing was copied and nothing was removed"), "\(detail)")
        #expect(!detail.contains("identical bytes"), "the words claim a comparison of bytes that was not made: \(detail)")
        withKnownIssue("KNOWN LIMIT, DECIDED 2026-11-21 (GH #504 D4; was P1, Codex r1 #2): Promote treats a stamp-bound stored digest as the answer 'already archived' at plan time (promoteRefusal) before reading the source. With a false stored digest (which only a single-read FIRST digest can still supply — D2 and D3b closed the other writers), a file whose bytes are in NO archive is set aside, unread. Nothing is copied and nothing is deleted on it; the words now say it was not re-read. If this ever passes, Promote proves the source before answering: delete this known issue.") {
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
        case .shortRead: #expect(job.tally.unreadable == 1 && job.tally.changedDuringRead == 0 && job.summaryLine.contains("1 unreadable"), "\(job.summaryLine)")
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
    @Test("BIND × bit flip (was P1; D3b, fixed): one read that disagrees with the stored digest is read AGAIN; the two reads disagree → the TRUE stored digest stays, 'read twice, disagreed' is counted and said, and a clean run then binds it")
    func bindOverwritesATrueDigestOnOneDisagreeingRead() async throws {
        let r = try bindRig("flip"); defer { r.sb.cleanup() }
        // The sibling one bit away from the record's file.
        var sibling = try Data(contentsOf: URL(fileURLWithPath: r.record.fullPath))
        sibling[Self.flipAt] ^= 0x01
        let siblingDigest = SHA256.hash(data: sibling).map { String(format: "%02x", $0) }.joined()
        // A TRANSIENT flip: the first read only. (A flip that repeats on every
        // read is, to any reader, the file's content — see the test below.)
        let fault = HashReadFault(.bitFlip, pathSuffix: "test_hrf_bind.mov", atByte: Int64(Self.flipAt), onPass: 1)
        let job = await fault.run { await runBind(r) }
        #expect(fault.firedCount == 1)
        #expect(fault.passCount == 2, "the file was read a second time — \(fault.passCount)")
        print("[hash-matrix] bind-fixity | bitFlip | \(job.state) | \(job.summaryLine)")
        #expect(trueDigest(r.record.fullPath) == r.digest, "the file itself never changed")
        // Seen RED 2026-11-21: the true digest was replaced by the sibling's
        // and counted "1 held different bytes than before".
        #expect(r.record.contentFixity == r.legacy, "the stored fixity was touched: \(r.record.contentFixity?.digest.prefix(12) ?? "nil")…")
        #expect(r.record.contentFixity?.digest != siblingDigest, "the stored digest is the sibling file's")
        #expect(job.tally.readsDisagreed == 1 && job.tally.digestChanged == 0 && job.tally.bound == 0 && job.storedCount == 0, "\(job.tally)")
        #expect(job.summaryLine.contains("1 read twice, disagreed (stored digest kept)"), "\(job.summaryLine)")
        let console = await hashFaultConsole(r.model, containing: "read twice, the two reads disagreed")
        #expect(console.contains("test_hrf_bind.mov: read twice, the two reads disagreed — its stored digest was kept"), "\(console)")
        #expect(job.fractionValue == 1, "the progress ends complete although the total grew by the second read")
        // Still waiting to be bound; a clean run binds the true digest.
        #expect(r.model.fixityRebindCandidates(prefix: r.sb.sources.path).map(\.id) == [r.record.id])
        let clean = await runBind(r)
        #expect(clean.tally.bound == 1 && clean.tally.digestChanged == 0 && clean.tally.readsDisagreed == 0, "\(clean.summaryLine)")
        #expect(r.record.contentFixity?.digest == r.digest && r.record.contentFixity?.stamp.volumeUUID != nil)
    }

    /// D3b's other half: a digest that REALLY changed (the file's bytes are
    /// not what was hashed before) is still stored — after two fresh reads
    /// agree on it — and is still said. Same for a read fault that repeats
    /// identically on every read: no reader can tell it from the content.
    @Test("BIND, the bytes really changed: the first read disagrees with the stored digest, the second read agrees with the first → the new digest is stored and counted 'held different bytes than before'; two reads were made")
    func bindStoresAChangedDigestOnlyAfterTwoAgreeingReads() async throws {
        let r = try bindRig("changed"); defer { r.sb.cleanup() }
        // The stored (legacy) digest names other bytes than the file holds.
        let wrong = String(repeating: "ab", count: 32)
        let stale = ContentFixity(algorithm: r.legacy.algorithm, digest: wrong, byteCount: r.legacy.byteCount,
                                  stamp: r.legacy.stamp, computedAt: r.legacy.computedAt)
        r.record.contentFixity = stale
        let reads = HashReadFault(.eio, pathSuffix: "test_hrf_bind.mov", atByte: 1 << 40, onPass: 0)   // counts, never fires
        let job = await reads.run { await runBind(r) }
        #expect(reads.passCount == 2, "a replaced digest costs a second read — \(reads.passCount)")
        #expect(job.tally.bound == 1 && job.tally.digestChanged == 1 && job.tally.readsDisagreed == 0, "\(job.tally)")
        #expect(job.summaryLine.contains("1 held different bytes than before"), "\(job.summaryLine)")
        #expect(r.record.contentFixity?.digest == r.digest && r.record.contentFixity?.stamp.volumeUUID != nil)
        #expect(job.fractionValue == 1)
    }

    @Test("BIND × {EIO, short read} in the SECOND read (the first disagreed with the stored digest): nothing is stored, the old fixity stays, the failure is counted as what it is",
          arguments: [HashReadFault.Kind.eio, .shortRead])
    func bindKeepsTheStoredDigestWhenTheSecondReadFails(_ kind: HashReadFault.Kind) async throws {
        let r = try bindRig("second_\(kind)"); defer { r.sb.cleanup() }
        let flip = HashReadFault(.bitFlip, pathSuffix: "test_hrf_bind.mov", atByte: Int64(Self.flipAt), onPass: 1)
        let fail = HashReadFault(kind, pathSuffix: "test_hrf_bind.mov", atByte: 9_000, onPass: 2)
        // Both planners see every chunk (each counts the file's passes itself).
        let hook: ArchivePromoteEngine.ReadHook = { fd, off, n in
            let flipped = flip.hook(fd, off, n), failed = fail.hook(fd, off, n)
            return flipped ?? failed
        }
        let job = await ArchivePromoteEngine.$readHook.withValue(hook) { await runBind(r) }
        #expect(flip.firedCount == 1 && fail.firedCount == 1, "flip \(flip.firedCount), second-read fault \(fail.firedCount)")
        #expect(r.record.contentFixity == r.legacy, "\(kind): the stored fixity was touched")
        #expect(job.tally.bound == 0 && job.storedCount == 0 && job.tally.unreadable == 1 && job.tally.readsDisagreed == 0, "\(job.tally)")
    }
}
