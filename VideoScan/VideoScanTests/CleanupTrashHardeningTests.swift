// CleanupTrashHardeningTests.swift
// Triage ▸ Cleanup v1 — the cases codex named as missing in round 1
// (docs/reviews/codex/codex-review-2026-10-12-cleanup-v1.md), each on real
// files through the engine and the test host's scratch Trash:
//   - a mutation landing BETWEEN the keeper's read and the extra copy's read
//     → held (the keeper's re-stamp after the second read catches it);
//   - Stop landing AFTER a proof has passed → that file still moves and is
//     reported moved, honestly; the rest are cancelled;
//   - a blocked save stops the run in order: nothing after the failed
//     checkpoint moves;
//   - crash/reload durability: after a run through the production
//     acknowledged save, reloading the sandbox catalog from disk shows the
//     moved rows In the Trash and the others untouched.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Cleanup — hardening (codex r1 missing cases)", .serialized)
@MainActor
struct CleanupTrashHardeningTests {

    typealias S = CleanupTrashSandbox

    @Test("a keeper rewritten BETWEEN the two reads — held, the extra copy stays")
    func mutationBetweenReadsHeld() async throws {
        let sb = try S("between")
        defer { sb.cleanup() }
        let (model, extras) = try cleanupThreeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        let first = selection.copies[0]
        let job = CleanupTrashJob(model: model, selection: selection)
        job.saveCatalogForTesting = { true }
        let keeperPath = first.keeper.path
        job.betweenReadsForTesting = { path in
            guard path == first.target.path else { return }
            // Same size, different bytes, after the keeper was read.
            guard let h = FileHandle(forWritingAtPath: keeperPath) else { return }
            try? h.seek(toOffset: 16)
            try? h.write(contentsOf: Data([0xAB, 0xCD]))
            try? h.close()
        }
        job.start()
        await job.task?.value
        let byID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.id, $0) })
        #expect(byID[first.target.id]?.outcome == .held, "\(job.items.map { "\($0.outcome): \($0.reason)" })")
        #expect(byID[first.target.id]?.reason.contains("changed while this file was read") == true)
        let target = try #require(extras.first { $0.id == first.target.id })
        #expect(FileManager.default.fileExists(atPath: target.fullPath) && target.removal == nil)
        #expect(job.totals[.moved] == 2 && job.totals[.held] == 1)
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("codex r2 F1: the keeper's PARENT moved into a Trash + a directory symlink at its old spot, BETWEEN the two reads — held")
    func keeperAncestryChangedBetweenReadsHeld() async throws {
        let sb = try S("betweenancestry")
        defer { sb.cleanup() }
        let (model, extras) = try cleanupThreeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        let first = selection.copies[0]
        let job = CleanupTrashJob(model: model, selection: selection)
        job.saveCatalogForTesting = { true }
        let keepDir = sb.root.appendingPathComponent("keep", isDirectory: true)
        let trashed = sb.root.appendingPathComponent(".Trashes/501/keep", isDirectory: true)
        job.betweenReadsForTesting = { path in
            guard path == first.target.path else { return }
            // inode / size / mtime / UUID of the keeper are all unchanged —
            // only its ancestry is: it now lives in a Trash, reachable
            // through a link at the old spelling.
            try? FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: keepDir, to: trashed)
            try? FileManager.default.createSymbolicLink(at: keepDir, withDestinationURL: trashed)
        }
        job.start()
        await job.task?.value
        let byID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.id, $0) })
        #expect(byID[first.target.id]?.outcome == .held, "\(job.items.map { "\($0.outcome): \($0.reason)" })")
        #expect(byID[first.target.id]?.reason.contains("link") == true || byID[first.target.id]?.reason.contains("Trash") == true)
        let target = try #require(extras.first { $0.id == first.target.id })
        #expect(FileManager.default.fileExists(atPath: target.fullPath) && target.removal == nil,
                "the last outside-Trash copy stays")
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("codex r2 F5: the progress number never counts a read twice — samples under a concurrent writer never decrease, and the total is exact", .timeLimit(.minutes(1)))
    func progressSnapshotIsAtomicWithTransfer() async {
        let ledger = CleanupProofLedger()
        let control = FixityRebind.Control()
        let cycles = 400, size: Int64 = 1_000
        let writer = Task.detached(priority: .userInitiated) {
            for _ in 0..<cycles {
                var seen: Int64 = 0
                while seen < size {           // the hasher's progress, in steps
                    seen += 250
                    control.noteBytes(seen)
                }
                ledger.transfer(size, from: control)   // settle: total += size, in flight → 0
            }
        }
        let sampler = Task.detached(priority: .userInitiated) { () -> (decreases: Int, overs: Int, samples: Int) in
            var last: Int64 = 0, decreases = 0, overs = 0, samples = 0
            while ledger.bytesRead < Int64(cycles) * size {
                let now = ledger.progress(with: control)
                if now < last { decreases += 1 }
                if now > Int64(cycles) * size { overs += 1 }
                last = now
                samples += 1
            }
            return (decreases, overs, samples)
        }
        await writer.value
        let result = await sampler.value
        #expect(result.decreases == 0, "a read was seen in both places, then in one: \(result.decreases) of \(result.samples) samples went backwards")
        #expect(result.overs == 0, "a sample exceeded everything that will ever be read")
        #expect(ledger.bytesRead == Int64(cycles) * size)
        #expect(ledger.progress(with: control) == ledger.bytesRead, "nothing left in flight")
    }

    @Test("Stop landing AFTER a proof passed — that file moves and is reported MOVED (honestly); the rest are cancelled")
    func stopAfterProofIsReportedMoved() async throws {
        let sb = try S("postproof")
        defer { sb.cleanup() }
        let (model, extras) = try cleanupThreeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        let first = selection.copies[0]
        let job = CleanupTrashJob(model: model, selection: selection)
        job.saveCatalogForTesting = { true }
        job.proofPassedForTesting = { path in
            guard path == first.target.path else { return }
            cleanupOnMainAndWait { job.cancel() }
        }
        job.start()
        await job.task?.value
        #expect(job.items.map(\.outcome) == [.moved, .cancelled, .cancelled], "\(job.items.map { "\($0.outcome): \($0.reason)" })")
        let target = try #require(extras.first { $0.id == first.target.id })
        #expect(!FileManager.default.fileExists(atPath: target.fullPath) && target.removal?.state == .inTrash,
                "the file whose proof passed did move, and its row says so")
        #expect(job.state == .cancelled)
        #expect(job.totals[.moved] == 1 && job.totals[.cancelled] == 2)
        if let t = target.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) }
    }

    @Test("a blocked save stops the run IN ORDER: nothing after the failed checkpoint moves")
    func blockedSaveOrdering() async throws {
        let sb = try S("blockedsave")
        defer { sb.cleanup() }
        let model = sb.model(keepFirst: ["keep", "extra"])
        var extras: [VideoRecord] = []
        for i in 0..<(CleanupTrashJob.checkpointFiles + 5) {
            let payload = Data("clip \(i) ".utf8) + Data(repeating: UInt8(i % 251), count: 512)
            let k = try sb.write("keep/test_\(i).mov", payload)
            let e = try sb.write("extra/test_\(i).mov", payload)
            model.records.append(try S.record(k))
            let rec = try S.record(e)
            model.records.append(rec)
            extras.append(rec)
        }
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        let job = await runCleanupTrash(model, selection) { $0.saveCatalogForTesting = { false } }
        // Exactly the first batch moved; the first failed checkpoint stopped
        // everything after it, in the selection's order.
        let batch = Array(selection.copies.prefix(CleanupTrashJob.checkpointFiles).map(\.target.id))
        let rest = Array(selection.copies.dropFirst(CleanupTrashJob.checkpointFiles).map(\.target.id))
        let byID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.id, $0.outcome) })
        #expect(batch.allSatisfy { byID[$0] == .moved }, "\(job.totals.line)")
        #expect(rest.allSatisfy { byID[$0] == .cancelled })
        #expect(rest.allSatisfy { id in extras.first { $0.id == id }.map { FileManager.default.fileExists(atPath: $0.fullPath) && $0.removal == nil } == true })
        if case .failed = job.state {} else { Issue.record("expected Failed, got \(job.state)") }
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("durability: after a run through the production acknowledged save, the catalog reloaded from disk shows the moved rows In the Trash")
    func movedRowsSurviveReload() async throws {
        let sb = try S("reload")
        defer { sb.cleanup() }
        let (model, extras) = try cleanupThreeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [extras[2].id], includeArchiveJunk: false)
        let job = await runCleanupTrash(model, selection, productionSave: true)
        #expect(job.totals[.moved] == 2, "\(job.totals.line)")
        // A fresh store over the same folder — what the app would read after a crash.
        let reloaded = CatalogStore(directory: sb.root.appendingPathComponent("catalog", isDirectory: true)).load()
        let byID = Dictionary(uniqueKeysWithValues: reloaded.map { ($0.id, $0) })
        #expect(reloaded.count == model.records.count, "rows are never deleted")
        for rec in extras.prefix(2) {
            let saved = try #require(byID[rec.id])
            #expect(saved.removal?.state == .inTrash && saved.removal?.reason == .duplicate, "\(rec.filename): \(String(describing: saved.removal))")
            #expect(saved.removal?.trashPath == rec.removal?.trashPath)
        }
        #expect(byID[extras[2].id]?.removal == nil, "the unticked file's row is untouched on disk")
        for rec in extras { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }

    @Test("a Trash move refused by a read-only folder says so, and says the fix — not 'you don't have permission' (the 2006 DVD rip's VIDEO_TS)")
    func readOnlyFolderWording() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSLocalizedDescriptionKey: "“VTS_03_1.VOB” couldn’t be moved to the Trash because you don’t have permission to access “VIDEO_TS”."])
        let path = "/Volumes/LaCieWorkspace/Timmy 10th Bday Restored/VIDEO_TS/VTS_03_1.VOB"
        let words = VideoScanModel.JunkDeletionResult.trashFailureWords(volume: "LaCieWorkspace", path: path, error: denied, parentWritable: false)
        #expect(words.hasPrefix("its folder “VIDEO_TS” is read-only") && words.contains("chmod u+w") && words.hasSuffix("nothing was deleted"))
        // The same error with a writable folder is something else: say what the system said.
        let other = VideoScanModel.JunkDeletionResult.trashFailureWords(volume: "LaCieWorkspace", path: path, error: denied, parentWritable: true)
        #expect(other.hasPrefix("couldn't move it to the Trash on LaCieWorkspace: ") && other.contains("permission"))
        // A non-permission error in a read-only folder is not blamed on the folder.
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSLocalizedDescriptionKey: "The disk is full."])
        #expect(VideoScanModel.JunkDeletionResult.trashFailureWords(volume: "X", path: path, error: full, parentWritable: false).contains("The disk is full."))
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)
        #expect(VideoScanModel.JunkDeletionResult.trashFailureWords(volume: "X", path: path, error: posix, parentWritable: false).hasPrefix("its folder “VIDEO_TS” is read-only"))
    }
}
