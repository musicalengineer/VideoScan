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
// WHY THE VERDICT AND NOT THE JOB: `pruneOneCopy` runs both reads inside
// `Task.detached` (VideoScanModel+PruneApply.swift), and a detached task does
// not inherit task-locals — a fault bound around the job never reaches its
// reads. That is pinned (and parked) by `theJobsReadsAreOutOfReach` below;
// changing that hop is a change to a delete path and is Rick's and Codex's
// call (rule 10).
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

    /// The seam's reach, pinned: the prune JOB reads inside `Task.detached`,
    /// so a fault bound around it never fires and both copies go (correctly —
    /// their reads were clean). When those two hops stay in the task tree
    /// (a `@concurrent` function instead of `Task.detached`) this known issue will report "unexpectedly passed" —
    /// promote the matrix above to the job then.
    @Test("REACH (parked): a fault bound around PruneApplyJob does not reach its reads — they run in Task.detached")
    func theJobsReadsAreOutOfReach() async throws {
        let f = try await PruneApplyTests.fixture("hrf_reach"); defer { f.sb.cleanup() }
        let shown = await f.model.prunePlan(batch: f.batch).shown()
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        let job = PruneApplyJob(model: f.model, shown: shown, selected: [f.copy.id], batch: f.batch,
                                batchID: "hrf-reach", hooks: PruneApplyTests.hooks(mover))
        let fault = HashReadFault(.eio, pathSuffix: "copies/test_prune_a.mov", atByte: 9_000, onPass: 0)
        await fault.run {
            job.start()
            await job.task?.value
        }
        withKnownIssue("PARKED 2026-11-20 (test reach, no product defect): pruneOneCopy / pruneArchiveReading hash inside Task.detached (VideoScanModel+PruneApply.swift), which drops the task-local read hook. Proposed (2 sites): hop off the main actor with a `@concurrent nonisolated static` function, as Promote / Verify / Bind Fixity do — it stays in the task tree, so the hook (and cancellation) reach the read, and nothing in the app has to bind the hook.") {
            #expect(fault.firedCount == 1)
            #expect(job.rows.first?.status == .held && mover.paths.isEmpty)
        }
    }
}
