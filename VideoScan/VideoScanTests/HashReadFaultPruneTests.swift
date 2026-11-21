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
// In every cell the hold is named, both files are byte-for-byte untouched,
// and the same call with no fault yields the proof (the hold is the fault's).
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
            #expect(!holdText.isEmpty)
            withKnownIssue("PARKED 2026-11-20 (P3, truth): prune names a read that ENDED EARLY as a content mismatch (\"archive copy changed\" / the mismatch reason) — the digest is of a prefix. The copy is held either way. Proposed: bytes consumed vs size in the reader → \"could not be read in full\".") {
                #expect(holdText.contains("could not be read in full"), "\(c): \(holdText)")
            }
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
