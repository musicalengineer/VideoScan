// HashReadFaultContentCopyProofTests.swift
// NEGATIVE MATRIX — `ContentCopyProof`'s consumers under a faulted full read
// (dedupe hash read seam, 2026-11-21). `ContentCopyProof.sha256` is the ONE
// read the proof ever makes: a copy known only by a digest with no stat stamp
// (a Master Archive copy by its read-back digest; a Migrate adoption's
// destination) is hashed fresh, in full, at the moment it must vouch.
// A copy WITH a stamp-bound fixity is never read (stat only).
//
// Consumers, END TO END:
//   * the Trash "only copy" guard — ⌘⌫ `trashSelectedRecords`: file A may move
//     only if a surviving copy B is proven to hold A's bytes NOW;
//   * Relocate's adoption proof — `provenAdoptedCount` → the summary's
//     "Your files are safe / you can retire <drive>" words;
//   * Relocate's proven-BACKUP count — `provenBackupCount`: makes NO read
//     (pinned: a fault aimed at the backup never fires).
//
// MATRIX, the copy byte-identical to its source (read × fault → outcome):
//
//   consumer \ fault        EIO mid-file         premature EOF        bit flip             partial read
//   Trash only-copy guard   A HELD "…copy…not    A HELD (same)        A HELD (same)        A moves to the
//   (B = archive-only copy) proven…", nothing                                              Trash (proven)
//                           moved
//   Relocate adoption       not proven: no       not proven           not proven           proven: retire
//                           retire invitation                                              invited
//   Relocate proven backup  — no read is made; the fault never fires (stamp-bound fixities, stat only) —
//
// CODEX'S SHAPES:
//   A  the copy is the source's bytes + a tail: refused on SIZE before any
//      read (lstat ≠ expectedBytes) — closed.
//   B  the copy is ONE BIT apart and the one read flips that bit:
//        Trash only-copy guard → 🔴 P0 (parked): A goes to the Trash although
//                                 the "surviving copy" does not hold A's bytes;
//        the proof itself      → P1 (parked): `proven` is true on one faulted
//                                 read (what Relocate's adoption count and its
//                                 retire invitation would stand on).
//
// Every misbehaviour is parked under `withKnownIssue`; NOTHING IS FIXED HERE.
// Every move goes to a sandbox Trash (SandboxTrash), never the real one.
// Parallel-safe: a temp folder per test, task-local hook and log.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite("Hash read fault × ContentCopyProof — the Trash 'only copy' guard and Relocate's proofs never stand on an unproven read")
@MainActor
struct HashReadFaultContentCopyProofTests {

    typealias TrashRig = CatalogTrashOnlyCopyAtTheMoveTests.Rig
    static let at: Int64 = 1_000

    /// A (to be trashed) and B, its only other copy, known ONLY by a Master
    /// Archive read-back digest (no stamp) — so the guard hashes B fresh at
    /// the move. `copyBytes` rewrites B on disk after it was catalogued.
    private func onlyCopyRig(copyBytes: ((Data) -> Data)? = nil) throws -> (rig: TrashRig, a: VideoRecord, b: VideoRecord, bytes: Data) {
        let rig = try TrashRig()
        let a = try rig.file("test_clip_a.mov")
        let b = try rig.file("test_clip_b.mov")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: a.fullPath))
        let digest = try #require(b.contentFixity?.digest)
        b.contentFixity = nil
        b.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: b.sizeBytes)
        if let copyBytes { try copyBytes(bytes).write(to: URL(fileURLWithPath: b.fullPath)) }
        rig.model.records = [a, b]
        return (rig, a, b, bytes)
    }

    private func exists(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    // MARK: 🔴 P0 — first

    /// 🔴 P0 (parked). Codex shape B at the Trash "only copy" guard.
    /// A is selected for the Trash. Its only other copy, B, is a Master
    /// Archive copy known by its read-back digest, so the guard hashes B in
    /// full at the move. B on disk is ONE BIT different from A (rot since the
    /// read-back); the one read of B returns that bit flipped; the digest
    /// equals the one on record; A MOVES TO THE TRASH.
    /// WHERE THE MEDIA IS: A is in the Trash, intact, recoverable. If the
    /// Trash is emptied the only good copy of A's bytes is gone — B is the
    /// rotted one.
    /// HOW REAL: the wrong bit must be exactly the rotted one. Far rarer than
    /// the fault; here because "proven at the move" rests on ONE read.
    /// PROPOSED FIX: none cheap (a second read doubles the cost). Rick's call,
    /// with GH #504's "second read" question.
    @Test("🔴 P0 (parked): the surviving copy is ONE BIT apart and the guard's one read of it flips that bit → the selected file is sent to the Trash although no copy of its bytes was proven")
    func p0_aFlippedReadOfTheSurvivingCopyLetsTheLastGoodCopyGo() async throws {
        let (rig, a, b, bytes) = try onlyCopyRig { var d = $0; d[Int(Self.at)] ^= 0x01; return d }
        defer { rig.cleanup() }
        let confirmed = rig.model.catalogTrashPlan(for: [a])
        try #require(confirmed.onlyCopy.isEmpty, "the archive digest is a known copy: no only-copy warning")

        // Control: clean, the rotted copy proves nothing and A stays.
        let clean = await rig.model.trashSelectedRecords([a], confirmed: confirmed, fileOperation: rig.trash.operation)
        try #require(exists(a) && clean.refused.map(\.reason) == [VideoScanModel.copyNotProvenAtTheMoveNote])

        let fault = DedupeReadFault(.bitFlip, pathSuffix: "test_clip_b.mov", atByte: Self.at)
        let again = rig.model.catalogTrashPlan(for: [a])
        let succeeded = await fault.run {
            await rig.model.trashSelectedRecords([a], confirmed: again, fileOperation: rig.trash.operation).succeeded
        }
        #expect(fault.firedCount == 1, "the flip never reached the guard's read of B")
        print("[hash-matrix] trash only-copy guard | shape B: flip on the differing bit in the surviving copy's read | \(succeeded == 1 ? "A MOVED TO THE TRASH" : "A held")")
        withKnownIssue("🔴 P0 PARKED 2026-11-21 (⌘⌫ Trash, the 'only copy' guard): one flipped bit in the guard's single read of the surviving archive-only copy makes a copy that is one bit apart 'proven' → the selected file moves to the Trash (recoverable) with no copy of its bytes proven. ContentCopyProof.Claim.holdsNow hashes once and compares with the digest on record. Proposed (Rick's call — the cost of a second read): a second fresh read must agree before a stamp-less copy vouches for a removal.") {
            #expect(exists(a), "A IS IN THE TRASH on one faulted read of its only other copy")
            #expect(succeeded == 0 && rig.trash.attempts.isEmpty, "\(rig.trash.attempts)")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: b.fullPath)) != bytes, "B never held A's bytes")
    }

    // MARK: The Trash guard matrix

    @Test("MATRIX, the Trash 'only copy' guard: EIO, a premature EOF or a flipped bit in the read of the surviving copy → A is HELD ('copy not proven'), nothing is handed to the Trash, and the log says so; a partial read proves the copy and A moves",
          arguments: DedupeFaultKind.allCases)
    func theGuardHoldsOnAnUnprovenRead(_ kind: DedupeFaultKind) async throws {
        let (rig, a, b, bytes) = try onlyCopyRig(); defer { rig.cleanup() }
        let confirmed = rig.model.catalogTrashPlan(for: [a])
        try #require(confirmed.toTrash == [a.id] && confirmed.onlyCopy.isEmpty)
        let fault = DedupeReadFault(kind, pathSuffix: "test_clip_b.mov", atByte: Self.at)
        let sink = InMemoryLogSink()
        let (succeeded, reasons) = await withAppLog(sink) {
            await fault.run { () -> (Int, [String]) in
                let result = await rig.model.trashSelectedRecords([a], confirmed: confirmed, fileOperation: rig.trash.operation)
                return (result.succeeded, result.refused.map(\.reason))
            }
        }
        #expect(fault.firedCount == 1, "\(kind): the fault never reached the guard's read (passes \(fault.passCount))")
        let auditLine = sink.lines.first { $0.hasPrefix("[junk] ") && $0.contains("test_clip_a.mov") } ?? ""
        print("[hash-matrix] trash only-copy guard | \(kind) in the surviving copy's read | \(succeeded == 1 ? "moved" : "held") | \(reasons) | \(auditLine)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: b.fullPath)) == bytes, "the copy is never touched")
        #expect(b.archiveFixity?.digest == sha(bytes) && b.contentFixity == nil, "nothing is recorded from the guard's read")

        if kind == .partialRead {
            #expect(succeeded == 1 && !exists(a) && rig.trash.attempts.count == 1, "\(kind): \(reasons)")
            #expect(a.purgedAt != nil)
            return
        }
        #expect(exists(a), "\(kind): A MOVED on an unproven read of its only other copy")
        #expect(try Data(contentsOf: URL(fileURLWithPath: a.fullPath)) == bytes)
        #expect(rig.trash.attempts.isEmpty, "\(kind): something was handed to the Trash")
        #expect(succeeded == 0 && a.purgedAt == nil && a.removal == nil)
        #expect(reasons == [VideoScanModel.copyNotProvenAtTheMoveNote], "\(kind): \(reasons)")
        #expect(auditLine.hasPrefix("[junk] held ") && auditLine.contains(VideoScanModel.copyNotProvenAtTheMoveNote), "\(kind): \(sink.joined)")
        #expect(sink.lines.contains { $0.contains("OUTCOME") && $0.contains("held 1") }, "\(kind): \(sink.joined)")

        // The hold was the fault's: the same move, clean, goes through.
        let again = rig.model.catalogTrashPlan(for: [a])
        let clean = await rig.model.trashSelectedRecords([a], confirmed: again, fileOperation: rig.trash.operation)
        #expect(clean.succeeded == 1 && !exists(a), "\(kind): the clean re-run: \(clean.refused.map(\.reason))")
    }

    @Test("Codex shape A at the guard (CLOSED): the surviving copy is A's bytes + a tail → refused on size before any read; A is held")
    func shapeA_aLongerCopyIsNeverReadAndNeverProves() async throws {
        let (rig, a, _, _) = try onlyCopyRig { $0 + Data(repeating: 0x5A, count: 512) }
        defer { rig.cleanup() }
        let confirmed = rig.model.catalogTrashPlan(for: [a])
        let fault = DedupeReadFault(.prematureEOF, pathSuffix: "test_clip_b.mov", atByte: a.sizeBytes, onPass: 0)
        let reasons = await fault.run {
            await rig.model.trashSelectedRecords([a], confirmed: confirmed, fileOperation: rig.trash.operation).refused.map(\.reason)
        }
        #expect(fault.passCount == 0, "the longer copy was read")
        #expect(exists(a) && rig.trash.attempts.isEmpty)
        #expect(reasons == [VideoScanModel.copyNotProvenAtTheMoveNote], "\(reasons)")
    }

    // MARK: The proof itself (what Relocate's counts call)

    @Test("the proof, Codex shape B (P1, parked): a stamp-less copy ONE BIT apart whose one read flips that bit is 'proven'; with a stamp-bound copy no read is made at all")
    func shapeB_theProofStandsOnOneRead() throws {
        let dir = dedupeSeamTempDir("proofB"); defer { try? FileManager.default.removeItem(at: dir) }
        let data = hashSeamBlob(bytes: 300_000, seed: 31)
        var other = data; other[Int(Self.at)] ^= 0x01
        let source = dir.appendingPathComponent("test_source.mov"), copy = dir.appendingPathComponent("test_copy.mov")
        try data.write(to: source)
        try other.write(to: copy)
        let fixity = try #require(ContentFixity.captured(path: source.path, digest: sha(data), byteCount: Int64(data.count)))
        let sourceClaim = ContentCopyProof.Claim(path: source.path, fixity: fixity)
        let copyClaim = ContentCopyProof.Claim(path: copy.path, digest: sha(data), byteCount: Int64(data.count))
        #expect(!ContentCopyProof.proven(source: sourceClaim, copies: [copyClaim]), "control: clean, one bit apart is not proven")

        let fault = DedupeReadFault(.bitFlip, pathSuffix: "test_copy.mov", atByte: Self.at)
        let proven = fault.runSync { ContentCopyProof.proven(source: sourceClaim, copies: [copyClaim]) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] ContentCopyProof.proven | shape B: flip on the differing bit in the copy's read | proven = \(proven)")
        withKnownIssue("PARKED 2026-11-21 (P1 truth, GH #504 root cause B): ContentCopyProof.proven is true for a stamp-less copy one bit apart when its single fresh read flips that bit. Relocate's adoption count (provenAdoptedCount) stands on this call, and with it the summary's 'Your files are safe — you can retire <drive>'. No media moves on the count itself; retiring a drive is Rick's own act. Proposed: with the Trash guard's P0 — a second fresh read must agree before a stamp-less copy vouches.") {
            #expect(!proven)
        }

        // A stamp-bound copy is never read: stat only (the persistent digest policy).
        let stamped = ContentCopyProof.Claim(path: copy.path, fixity: try #require(
            ContentFixity.captured(path: copy.path, digest: sha(data), byteCount: Int64(data.count))))
        let reads = DedupeReadCounter(where: { $0.hasSuffix("test_copy.mov") || $0.hasSuffix("test_source.mov") })
        let trusted = ArchivePromoteEngine.$readHook.withValue(reads.hook) {
            ContentCopyProof.proven(source: sourceClaim, copies: [stamped])
        }
        #expect(trusted && reads.passCount == 0,
                "PINNED: a FALSE but stamp-valid stored digest vouches with no read (the same trust as Delete Duplicates' cached keeper, shape C)")
    }

    // MARK: Relocate

    @Test("MATRIX, Relocate's adoption proof (a real Migrate): EIO, a premature EOF or a flipped bit in the fresh read of the adopted destination file → the adoption is NOT proven and the summary does not invite retiring the drive; a partial read proves it",
          .timeLimit(.minutes(2)), arguments: DedupeFaultKind.allCases)
    func theAdoptionProofUnderEachFault(_ kind: DedupeFaultKind) async throws {
        let fault = DedupeReadFault(kind, where: { $0.contains("/dest/") && $0.hasSuffix("/a.mov") }, atByte: Self.at, onPass: 0)
        let (adopted, proven, invites, headline) = try await fault.run { () -> (Int, Int, Bool, String) in
            let s = try await RelocateSummaryProofTests().migrateAdoption { _ in }
            let h = RelocateSummaryHeadline(s)
            return (s.adoptedCount, s.provenAdoptedCount, h.invitesRetire, h.title)
        }
        try #require(adopted == 1, "the fixture must adopt the destination file")
        #expect(fault.firedCount >= 1, "\(kind): the fault never reached the adoption proof's read (passes \(fault.passCount)) — is the hop to Task.detached still carrying the hook?")
        print("[hash-matrix] relocate adoption proof | \(kind) in the adopted file's read | proven \(proven) of \(adopted) | \"\(headline)\" | invites retire \(invites) | full reads through the seam \(fault.passCount)")
        if kind == .partialRead {
            #expect(proven == 1 && invites)
        } else {
            #expect(proven == 0, "\(kind): an adoption was counted as proven on an unproven read")
            #expect(!invites, "\(kind): the summary invites retiring the drive: \(headline)")
        }
    }

    @Test("REACH (pinned): Relocate's proven-BACKUP count makes no read — a fault aimed at the backup never fires and the count stands on the stored stamp-bound fixities")
    func theProvenBackupCountReadsNothing() async throws {
        let fault = DedupeReadFault(.eio, where: { $0.hasSuffix("/clip.mov") }, atByte: 100, onPass: 0)
        let invites = try await fault.run {
            RelocateSummaryHeadline(try await RelocateSummaryProofTests().migrate(trust: .reliable)).invitesRetire
        }
        #expect(fault.passCount == 0 && fault.firedCount == 0, "the backup proof now reads: give it a fault matrix")
        #expect(invites)
    }
}
