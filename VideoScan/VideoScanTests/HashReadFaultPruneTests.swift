// HashReadFaultPruneTests.swift
// NEGATIVE MATRIX — "Move copies to the Trash" (prune) under a faulted
// full read (hash read seam, 2026-11-20). The verdict that sends a copy to
// the Trash is two full reads agreeing: the archive file (the keeper) and
// the copy. Each of {EIO mid-file, a read that ends early, one flipped bit}
// is injected into each of those reads, AT THE VERDICT: the two functions
// that are the only makers of an archive reading and of a `PruneProof`
// (`readArchiveInFull`, `pruneCandidateProof` — PruneSensorTests pins "one
// maker"). With no proof there is nothing the mover will accept.
//
//   fault in the ARCHIVE's read → no archive reading exists, so no proof for
//                                 any copy of the family can even be asked for;
//   fault in the COPY's read    → no proof for that copy.
//
// In every cell OF THAT MATRIX the hold is named, both files are
// byte-for-byte untouched, and the same call with no fault yields the proof.
//
// GH #504 D1 (FIXED 2026-11-21, was P1 / Codex r1 #1): a read that ends
// before the file's size is a read failure in the one reader
// (`ArchivePromoteEngine.pipelinedRead`), so prune holds the copy as "could
// not be read in full" — including `aShortReadOfALongerCopyMakesAFalseProof`,
// where the copy is the archive's bytes PLUS A TAIL and the read ends at the
// archive's length (before the fix: a PruneProof was made for a file whose
// tail was never read).
//
// Outcomes (verdict level):
//   fault            copy == archive                  copy == archive + tail
//   EIO              held "could not be read in full" held
//   bit flip         held (mismatch)                  held
//   read ends early  held "could not be read in full" held "could not be read in full"
//
// THE FALSE POSITIVE (Codex r1 P0 on this branch, FIXED — GH #504 D3a at
// prune): the matrix above starts from identical files, so a flip can only
// make a mismatch. With a copy ONE BIT apart from the archive, a flip on that
// bit in the copy's one read made a PruneProof and the copy — unique bytes —
// went to the Trash. The copy is now read TWICE before a proof is made:
//   copy one bit apart, flip on that bit in read 1 → held "two reads of
//   <copy> disagreed — nothing was removed" (verdict and job);
//   identical copy, fault in read 2 → held (EIO / early end: "could not be
//   read in full"; flip: "two reads … disagreed").
// The archive side was already a stored digest confirmed by one fresh read
// per batch (`readArchiveInFull`) — the rule D4 gives Delete Duplicates'
// keeper.
//
// THE JOB TOO (2026-11-21): `pruneOneCopy` runs both reads inside
// `Task.detached` (VideoScanModel+PruneApply.swift), and a detached task does
// not inherit task-locals. The job now reads the hook before each hop and
// passes it by value, so `aFaultedReadInTheJobMovesNothing` runs the same
// matrix end to end through `PruneApplyJob` (was parked:
// `theJobsReadsAreOutOfReach`). Nothing in the app binds the hook.
//
// Fixture: PruneApplyTests.fixture (a real sandbox Promote + one
// byte-identical copy). Parallel-safe: sandbox per test, task-local hook.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

struct PruneFaultCase: Sendable, CustomStringConvertible {
    let kind: HashReadFault.Kind
    /// true = the fault is in the archive (keeper) file's read.
    let inArchiveRead: Bool
    var description: String { "\(kind) in the \(inArchiveRead ? "archive (keeper)" : "copy") read" }
    static let all: [PruneFaultCase] = HashReadFault.Kind.allCases.flatMap {
        [PruneFaultCase(kind: $0, inArchiveRead: false), PruneFaultCase(kind: $0, inArchiveRead: true)]
    }
}

@Suite("Hash read fault × Prune — no proof, so no copy goes to the Trash, on an unproven read")
@MainActor
struct HashReadFaultPruneTests {

    typealias Model = VideoScanModel

    private func item(_ f: PruneApplyTests.Fixture) -> Model.PruneItem {
        Model.PruneItem(copyID: f.copy.id, filename: f.copy.filename, path: f.copy.fullPath,
                        sizeBytes: f.copy.sizeBytes, archiveID: f.archive.id, archivePath: f.archive.fullPath,
                        archiveFilename: f.archive.filename, archiveDigest: f.digest)
    }

    @Test("MATRIX: each fault in the copy's read or the archive's read → no PruneProof is made, the hold is named, both files untouched; the same call without the fault proves the copy",
          .timeLimit(.minutes(2)), arguments: PruneFaultCase.all)
    func anUnprovenReadMakesNoProof(_ c: PruneFaultCase) async throws {
        let f = try await PruneApplyTests.fixture("hrf_\(c.kind)_\(c.inArchiveRead ? "arch" : "copy")")
        defer { f.sb.cleanup() }
        let item = item(f)
        let opens = PruneApplyTests.OpenCounter()
        var hooks = Model.PruneVerifyHooks(shouldCancel: { false })
        hooks.didOpen = { opens.add($0) }
        let archiveBytes = try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath))
        let copyBytes = try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath))
        let copyFixityBefore = f.copy.contentFixity
        let archiveFixityBefore = f.archive.archiveFixity
        let archiveName = (f.archive.fullPath as NSString).lastPathComponent

        let fault = c.inArchiveRead
            ? HashReadFault(c.kind, pathSuffix: archiveName, atByte: 9_000)
            : HashReadFault(c.kind, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000)

        var holdText = ""
        let archiveRead = fault.runSync {
            Model.readArchiveInFull(id: item.archiveID, path: item.archivePath, digest: item.archiveDigest, hooks: hooks)
        }
        switch (archiveRead, c.inArchiveRead) {
        case (.success, true):
            Issue.record("\(c): a faulted archive read produced an archive reading")
        case (.failure(let hold), true):
            // No reading ⇒ `pruneCandidateProof` cannot be called at all: it
            // takes the reading as a parameter. The family is held.
            holdText = hold.text
            #expect(opens.opens(of: f.copy.fullPath) == 0, "no copy is read against an unproven archive")
        case (.failure(let hold), false):
            Issue.record("\(c): the clean archive read failed — \(hold.text)")
        case (.success(let reading), false):
            let verdict = fault.runSync { Model.pruneCandidateProof(item, archive: reading, hooks: hooks) }
            switch verdict {
            case .success(let proof): Issue.record("\(c): a PROOF was made from a faulted read: \(proof)")
            case .failure(let hold): holdText = hold.text
            }
        }
        #expect(fault.firedCount == 1, "\(c): the fault never reached its read (opens: \(opens.all))")
        print("[hash-matrix] prune | \(c) | held | \(holdText)")

        // --- Truthful words.
        switch c.kind {
        case .eio:
            #expect(holdText.contains("could not be read in full"), "\(c): \(holdText)")
            if c.inArchiveRead { #expect(holdText.hasPrefix("its archive copy: ")) }
        case .bitFlip:
            #expect(c.inArchiveRead ? holdText.contains("archive copy changed") : holdText == PruneReason.mismatchAtMove.text,
                    "\(c): \(holdText)")
        case .shortRead:
            // D1: named for what it is — not "archive copy changed" / a mismatch.
            #expect(holdText.contains("could not be read in full"), "\(c): \(holdText)")
            if c.inArchiveRead { #expect(holdText.hasPrefix("its archive copy: ")) }
        }

        // --- Read-only: nothing on disk or in the catalog moved.
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath)) == archiveBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath)) == copyBytes)
        #expect(f.copy.contentFixity == copyFixityBefore && f.archive.archiveFixity == archiveFixityBefore)
        #expect(f.copy.removal == nil)

        // --- The hold was the fault's: the same two calls, clean, prove the copy.
        guard case .success(let reading) = Model.readArchiveInFull(id: item.archiveID, path: item.archivePath,
                                                                   digest: item.archiveDigest, hooks: hooks),
              case .success(let proof) = Model.pruneCandidateProof(item, archive: reading, hooks: hooks) else {
            Issue.record("\(c): the clean reads did not prove the copy"); return
        }
        #expect(proof.copyID == f.copy.id && proof.archiveDigest == f.digest)
    }

    /// Codex r1 #1 (was P1; FIXED by GH #504 D1, seen RED 2026-11-21). The
    /// copy is the archive's bytes followed by bytes the archive does not
    /// have — a different, longer file whose catalog digest still (wrongly)
    /// names the archive's. A full read catches it (the control below). A
    /// read that ends at the archive's length used to hash to the archive's
    /// digest and make a `PruneProof` for a file whose tail — the only copy
    /// of those bytes — was never read. Now the reader throws and the copy
    /// is held.
    @Test("a read that ENDS EARLY on a copy holding the archive's bytes PLUS A TAIL makes NO PruneProof: held, 'could not be read in full'")
    func aShortReadOfALongerCopyMakesAFalseProof() async throws {
        let f = try await PruneApplyTests.fixture("hrf_tail"); defer { f.sb.cleanup() }
        let archiveBytes = try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath))
        let tail = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        try (archiveBytes + tail).write(to: URL(fileURLWithPath: f.copy.fullPath))
        let item = Model.PruneItem(copyID: f.copy.id, filename: f.copy.filename, path: f.copy.fullPath,
                                   sizeBytes: Int64(archiveBytes.count + tail.count), archiveID: f.archive.id,
                                   archivePath: f.archive.fullPath, archiveFilename: f.archive.filename,
                                   archiveDigest: f.digest)
        let hooks = Model.PruneVerifyHooks(shouldCancel: { false })
        guard case .success(let reading) = Model.readArchiveInFull(id: item.archiveID, path: item.archivePath,
                                                                   digest: item.archiveDigest, hooks: hooks) else {
            Issue.record("fixture: the clean archive read failed"); return
        }
        // Control: read in full, the longer copy is NOT the archive's bytes.
        guard case .failure(let clean) = Model.pruneCandidateProof(item, archive: reading, hooks: hooks) else {
            Issue.record("fixture: a full read of the longer copy matched the archive"); return
        }
        #expect(clean.text == PruneReason.mismatchAtMove.text)

        let fault = HashReadFault(.shortRead, pathSuffix: "copies/test_prune_a.mov", atByte: Int64(archiveBytes.count))
        let verdict = fault.runSync { Model.pruneCandidateProof(item, archive: reading, hooks: hooks) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] prune | shortRead at the archive's length, copy = archive + tail | \(verdict)")
        switch verdict {
        case .success(let proof):
            Issue.record("a PROOF was made from a read that stopped \(tail.count) bytes short: \(proof)")
        case .failure(let hold):
            #expect(hold.text == "could not be read in full", "\(hold.text)")
        }
        // The file the proof would send to the Trash still holds the tail.
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath)).suffix(tail.count) == tail)
    }

    /// GH #504 (2026-11-21): the prune JOB reads inside `Task.detached`, which
    /// inherits no task-locals; the job now reads the hook before each hop and
    /// passes it in by value (as Delete Duplicates and Relocate do), so the
    /// matrix runs END TO END: `PruneApplyJob` → `pruneOneCopy` → the two full
    /// reads → the mover. Was parked as `theJobsReadsAreOutOfReach` (seen RED:
    /// the fault never fired and the copy went to the Trash on clean reads).
    @Test("MATRIX at the JOB: each fault in the copy's read or the archive's read → the row is HELD and named, nothing is handed to the mover, both files and the catalog are untouched; the same job, clean, moves the copy",
          .timeLimit(.minutes(2)), arguments: PruneFaultCase.all)
    func aFaultedReadInTheJobMovesNothing(_ c: PruneFaultCase) async throws {
        let f = try await PruneApplyTests.fixture("hrfjob_\(c.kind)_\(c.inArchiveRead ? "arch" : "copy")")
        defer { f.sb.cleanup() }
        let archiveBytes = try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath))
        let copyBytes = try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath))
        let copyFixityBefore = f.copy.contentFixity
        let archiveFixityBefore = f.archive.archiveFixity
        let archiveName = (f.archive.fullPath as NSString).lastPathComponent
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        func job(_ id: String) async -> PruneApplyJob {
            let shown = await f.model.prunePlan(batch: f.batch).shown()
            return PruneApplyJob(model: f.model, shown: shown, selected: [f.copy.id], batch: f.batch,
                                 batchID: id, hooks: PruneApplyTests.hooks(mover))
        }

        let fault = c.inArchiveRead
            ? HashReadFault(c.kind, pathSuffix: archiveName, atByte: 9_000)
            : HashReadFault(c.kind, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000)
        let faulted = await job("hrf-job-fault")
        await fault.run {
            faulted.start()
            await faulted.task?.value
        }
        #expect(fault.firedCount == 1, "\(c): the fault never reached the job's read — is the hop to Task.detached still carrying the hook?")
        let row = try #require(faulted.rows.first { $0.id == f.copy.id } ?? faulted.rows.first)
        print("[hash-matrix] prune job | \(c) | \(row.status) | \(row.note)")

        // --- Nothing moved; never a success.
        #expect(row.status == .held, "\(c): \(row.status) — \(row.note)")
        #expect(mover.paths.isEmpty, "\(c): something was handed to the mover: \(mover.paths)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath)) == archiveBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath)) == copyBytes, "\(c): the copy is not at its path byte for byte")
        #expect(f.copy.removal == nil && f.copy.contentFixity == copyFixityBefore && f.archive.archiveFixity == archiveFixityBefore)

        // --- Truthful words on the row.
        switch c.kind {
        case .eio, .shortRead:
            #expect(row.note.contains("could not be read in full"), "\(c): \(row.note)")
            if c.inArchiveRead { #expect(row.note.hasPrefix("its archive copy: "), "\(c): \(row.note)") }
        case .bitFlip:
            #expect(c.inArchiveRead ? row.note.contains("archive copy changed") : row.note == PruneReason.mismatchAtMove.text,
                    "\(c): \(row.note)")
        }

        // --- The hold was the fault's: the same job, clean, moves the copy.
        let clean = await job("hrf-job-clean")
        clean.start()
        await clean.task?.value
        #expect(clean.rows.first?.status == .trashed && mover.paths == [f.copy.fullPath],
                "\(c): the clean run: \(clean.rows.first.map { "\($0.status) — \($0.note)" } ?? "no row") / \(mover.paths)")
    }

    /// The read that D3a added at prune: a fault in the copy's SECOND read
    /// (identical files, the first read was clean and matched).
    @Test("VERDICT + JOB, the copy's SECOND read: EIO or a read that ends early → held 'could not be read in full'; a flipped bit → held 'two reads of <copy> disagreed — nothing was removed'; nothing is handed to the mover",
          .timeLimit(.minutes(2)), arguments: HashReadFault.Kind.allCases)
    func aFaultInTheCopysSecondReadHoldsIt(_ kind: HashReadFault.Kind) async throws {
        let f = try await PruneApplyTests.fixture("hrf_second_\(kind)"); defer { f.sb.cleanup() }
        let copyBytes = try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath))
        let expected = kind == .bitFlip ? "two reads of test_prune_a.mov disagreed — nothing was removed" : "could not be read in full"
        // Verdict.
        let item = item(f)
        let hooks = Model.PruneVerifyHooks(shouldCancel: { false })
        guard case .success(let reading) = Model.readArchiveInFull(id: item.archiveID, path: item.archivePath,
                                                                   digest: item.archiveDigest, hooks: hooks) else {
            Issue.record("fixture: the clean archive read failed"); return
        }
        let fault = HashReadFault(kind, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000, onPass: 2)
        let verdict = fault.runSync { Model.pruneCandidateProof(item, archive: reading, hooks: hooks) }
        #expect(fault.firedCount == 1 && fault.passCount == 2, "\(kind): fired \(fault.firedCount), passes \(fault.passCount)")
        switch verdict {
        case .success(let proof): Issue.record("\(kind): a PROOF was made although the second read did not confirm the first: \(proof)")
        case .failure(let hold): #expect(hold.text == expected, "\(kind): \(hold.text)")
        }
        // Job.
        let shown = await f.model.prunePlan(batch: f.batch).shown()
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        let job = PruneApplyJob(model: f.model, shown: shown, selected: [f.copy.id], batch: f.batch,
                                batchID: "hrf-job-second", hooks: PruneApplyTests.hooks(mover))
        let jobFault = HashReadFault(kind, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000, onPass: 2)
        await jobFault.run {
            job.start()
            await job.task?.value
        }
        #expect(jobFault.firedCount == 1, "\(kind): the fault never reached the job's second read")
        let row = try #require(job.rows.first)
        print("[hash-matrix] prune job | \(kind) in the copy's SECOND read | \(row.status) | \(row.note)")
        #expect(row.status == .held && row.note == expected && mover.paths.isEmpty, "\(kind): \(row.status) — \(row.note) / \(mover.paths)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath)) == copyBytes)
        #expect(f.copy.removal == nil)
    }

    // MARK: Codex r1 P0 (GH #504, D3a at prune) — the FALSE-POSITIVE cell

    /// The copy is B = the archive's bytes with ONE BIT flipped; the catalog's
    /// digest for it still names the archive's (a single-read first digest can
    /// leave exactly that — D4's known limit). Returns the fixture with the
    /// copy rewritten, its record's fixity re-stamped to the file as it is now.
    private func oneBitApart(_ label: String) async throws -> (f: PruneApplyTests.Fixture, copyBytes: Data, archiveBytes: Data) {
        let f = try await PruneApplyTests.fixture(label)
        let archiveBytes = try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath))
        var b = archiveBytes
        b[9_000] ^= 0x01
        try b.write(to: URL(fileURLWithPath: f.copy.fullPath))
        f.copy.contentFixity = ContentFixity.captured(path: f.copy.fullPath, digest: f.digest, byteCount: Int64(b.count))
        return (f, b, archiveBytes)
    }

    @Test("VERDICT, false positive (Codex r1 P0): the copy is ONE BIT apart from the archive and its first read flips that bit → NO PruneProof: the copy's second read disagrees, 'two reads of <copy> disagreed — nothing was removed'")
    func aFlippedReadOfACopyOneBitApartMakesNoProof() async throws {
        let (f, copyBytes, _) = try await oneBitApart("hrf_onebit"); defer { f.sb.cleanup() }
        let item = item(f)
        let hooks = Model.PruneVerifyHooks(shouldCancel: { false })
        guard case .success(let reading) = Model.readArchiveInFull(id: item.archiveID, path: item.archivePath,
                                                                   digest: item.archiveDigest, hooks: hooks) else {
            Issue.record("fixture: the clean archive read failed"); return
        }
        // Control: read clean, the copy is NOT the archive's bytes.
        guard case .failure(let clean) = Model.pruneCandidateProof(item, archive: reading, hooks: hooks) else {
            Issue.record("fixture: a clean read of the one-bit-different copy matched the archive"); return
        }
        #expect(clean.text == PruneReason.mismatchAtMove.text)

        let fault = HashReadFault(.bitFlip, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000, onPass: 1)
        let verdict = fault.runSync { Model.pruneCandidateProof(item, archive: reading, hooks: hooks) }
        #expect(fault.firedCount == 1)
        print("[hash-matrix] prune | bitFlip on the differing bit, copy one bit apart | \(verdict) | copy reads \(fault.passCount)")
        switch verdict {
        case .success(let proof): Issue.record("a PROOF was made from one flipped read of a different file: \(proof)")
        case .failure(let hold):
            #expect(hold.text == "two reads of test_prune_a.mov disagreed — nothing was removed", "\(hold.text)")
            #expect(fault.passCount == 2, "the copy was read a second time — \(fault.passCount)")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath)) == copyBytes)
    }

    @Test("JOB, false positive (Codex r1 P0): the same one-bit-apart copy through PruneApplyJob → the row is HELD, nothing is handed to the mover, the copy is at its path byte for byte")
    func aFlippedReadOfACopyOneBitApartMovesNothingInTheJob() async throws {
        let (f, copyBytes, archiveBytes) = try await oneBitApart("hrfjob_onebit"); defer { f.sb.cleanup() }
        let shown = await f.model.prunePlan(batch: f.batch).shown()
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        let job = PruneApplyJob(model: f.model, shown: shown, selected: [f.copy.id], batch: f.batch,
                                batchID: "hrf-job-onebit", hooks: PruneApplyTests.hooks(mover))
        let fault = HashReadFault(.bitFlip, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000, onPass: 1)
        await fault.run {
            job.start()
            await job.task?.value
        }
        try #require(fault.firedCount == 1, "fixture: the job never read the copy (was it offered? rows \(job.rows.map { "\($0.status) \($0.note)" }))")
        let row = try #require(job.rows.first)
        print("[hash-matrix] prune job | bitFlip on the differing bit, copy one bit apart | \(row.status) | \(row.note)")
        #expect(row.status == .held, "\(row.status) — \(row.note)")
        #expect(mover.paths.isEmpty, "THE COPY WAS HANDED TO THE MOVER on one flipped read: \(mover.paths)")
        #expect(row.note == "two reads of test_prune_a.mov disagreed — nothing was removed", "\(row.note)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.copy.fullPath)) == copyBytes, "the copy is not at its path byte for byte")
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.archive.fullPath)) == archiveBytes)
        #expect(f.copy.removal == nil)
    }
}
