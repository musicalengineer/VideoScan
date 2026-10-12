// CleanupTrashSensorTests.swift
// Triage ▸ Cleanup v1 — SENSORS pinning the design's execution rules at the
// source level (rule 5: one engine; Trash only; rows never deleted):
//   - no Cleanup source moves, trashes, unlinks, renames or deletes a file
//     itself, nor writes the removal marker / deletes a row: only the
//     #143 engine (`deleteConfirmedJunk` → `MediaTrash.move`, `stampRemoval`)
//     may, and Cleanup reaches it;
//   - both lanes of the job go through `deleteConfirmedJunk`, and the copy
//     lane's guard runs `CleanupProof.verifyCopy` (the two full reads);
//   - the FamilyArchive waiver is lifted only by Cleanup's junk lane;
//   - no view body in the page reads `model.records`.
// Plus a behavioural sensor at catalog scale: a held file's row is never
// stamped, across a batch where most files are held.
// Fails closed: an empty or missing source read is a failure, never a pass.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Cleanup — sensors", .serialized)
@MainActor
struct CleanupTrashSensorTests {

    /// Every Cleanup source (the folder and the page), comments stripped.
    private static func cleanupSources() -> [(name: String, code: String)] {
        let files = SourceTree.appSources.filter {
            $0.relative.hasPrefix("MediaOps/Cleanup/") || $0.relative == "Catalog/CleanupPane.swift"
        }
        return files.compactMap { f in
            guard let text = try? String(contentsOf: f.url, encoding: .utf8) else { return nil }
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { return "" }
                return line.components(separatedBy: " //")[0]
            }.joined(separator: "\n")
            return (f.relative, code)
        }
    }

    @Test("the scan reads all seven Cleanup sources")
    func scanReadsTheSources() {
        let names = Set(Self.cleanupSources().map(\.name))
        #expect(names == [
            "MediaOps/Cleanup/CleanupPlan.swift", "MediaOps/Cleanup/CleanupDiskProbe.swift",
            "MediaOps/Cleanup/CleanupProof.swift", "MediaOps/Cleanup/CleanupTrashJob.swift",
            "MediaOps/Cleanup/CleanupTrashJobDetailView.swift", "MediaOps/Cleanup/VideoScanModel+Cleanup.swift",
            "Catalog/CleanupPane.swift",
        ], "a new Cleanup file must be added here (and reviewed): \(names.sorted())")
    }

    @Test("SENSOR: no Cleanup source moves, trashes, unlinks, renames or deletes a file, or stamps a row itself")
    func noDiskOrRowWritesOfItsOwn() {
        let forbidden = ["trashItem(", "removeItem(", "unlink(", "rename(", "renamex_np(", "moveItem(",
                         "replaceItem", "MediaTrash.move", ".removal =", "purgedAt =", "stampRemoval(",
                         "records.remove", "lifecycleStage = .trashed", "lifecycleStage = .deletedPermanently",
                         "O_WRONLY", "O_RDWR", "FileHandle(forWriting"]
        let sources = Self.cleanupSources()
        #expect(sources.count == 7)
        for (name, code) in sources {
            for token in forbidden {
                #expect(!code.contains(token), "\(name) contains \(token) — Cleanup must go through the #143 engine")
            }
        }
    }

    @Test("SENSOR: both lanes go through the one engine; copies through the two-file proof")
    func throughTheEngine() throws {
        let job = try #require(Self.cleanupSources().first { $0.name.hasSuffix("CleanupTrashJob.swift") }?.code)
        // One call site, one file at a time (Pause between files); both
        // lanes reach it with their own reason.
        #expect(job.components(separatedBy: "model.deleteConfirmedJunk(").count - 1 == 1, "the one engine call")
        #expect(job.contains("model.deleteConfirmedJunk([rec], mode: .toTrash, reason: reason, guard: g)"))
        #expect(job.contains("runFiles(batch, lane: .copy, reason: .duplicate, guard: g, model: model)"))
        #expect(job.contains("runFiles(batch, lane: .junk, reason: .junk, guard: g, model: model)"))
        #expect(!job.contains("Thread.sleep") && !job.contains("setPaused"), "nothing waits on a worker thread")
        #expect(job.contains("CleanupProof.verifyCopy(copy, control: control, onRead: { ledger.addBytes($0) })"))
        #expect(job.contains("CleanupProof.verifyJunk(path: path, frozen: frozen, reserved: reserved)"))
        #expect(job.contains("model.frozenJunkCatalogProblem(rec, frozenPath:"), "the Delete Junk door's own re-check")
        let proof = try #require(Self.cleanupSources().first { $0.name.hasSuffix("CleanupProof.swift") }?.code)
        #expect(proof.components(separatedBy: "read(copy.").count - 1 == 2, "BOTH files are read in full")
        #expect(proof.contains("FixityRebind.rehash(path: path, control: control)"), "the app's one fixity reader")
    }

    @Test("QA P3: the copy lane speaks in Cleanup's voice, not Delete Junk's")
    func copyLaneVoice() throws {
        #expect(RemovalReason.duplicate.doorVerb == "Cleanup")
        #expect(RemovalReason.junk.doorVerb == "Delete Confirmed Junk")
        #expect(RemovalReason.workbench.doorVerb == "Discard")
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        #expect(engine.contains("log(\"\\(reason.doorVerb): attempted="), "the engine's summary line carries the door's verb")
        #expect(!engine.contains("log(\"Delete Confirmed Junk: attempted="))
    }

    @Test("SENSOR: only Cleanup's junk lane lifts the FamilyArchive waiver")
    func waiverOnlyFromCleanup() {
        let hits = SourceTree.appSources.compactMap { f -> String? in
            guard let text = try? String(contentsOf: f.url, encoding: .utf8) else { return nil }
            return text.contains("archiveVolumeJunkWaiver =") ? f.relative : nil
        }
        #expect(hits == ["MediaOps/Cleanup/CleanupTrashJob.swift"], "\(hits)")
        #expect(SourceTree.appSources.count > 500, "the scan read the app tree")
    }

    @Test("SENSOR: the page's bodies never read the catalog (no O(records) in a view)")
    func pageNeverReadsRecords() throws {
        let page = try #require(Self.cleanupSources().first { $0.name == "Catalog/CleanupPane.swift" }?.code)
        #expect(!page.contains("model.records"), "the page reads CleanupStore only")
        #expect(!page.contains(".records."))
    }

    @Test("QA P3: the confirm sheet cancels on Esc as well as Return")
    func confirmSheetCancelsOnEscape() throws {
        let page = try #require(Self.cleanupSources().first { $0.name == "Catalog/CleanupPane.swift" }?.code)
        let sheet = try #require(page.range(of: "struct CleanupConfirmSheet").map { page[$0.lowerBound...] })
        #expect(sheet.contains(".keyboardShortcut(.defaultAction)"), "Cancel stays the default (Return)")
        #expect(sheet.contains(".onExitCommand(perform: onCancel)"), "Esc cancels")
    }

    @Test("SENSOR at scale: 300 copies, 290 of them poisoned — every held row stays unstamped", .timeLimit(.minutes(2)))
    func heldRowsNeverStamped() async throws {
        let sb = try CleanupTrashSandbox("sensor")
        defer { sb.cleanup() }
        let model = sb.model(keepFirst: ["keep", "extra"])
        var keepers: [VideoRecord] = [], extras: [VideoRecord] = []
        for i in 0..<300 {
            let good = Data("test file \(i) — ".utf8) + Data(repeating: UInt8(i % 251), count: 2_000)
            var copy = good
            if i >= 10 { copy[100] ^= 0x55 }   // 290 copies differ by one byte
            let k = try sb.write("keep/test_\(i).mov", good)
            let e = try sb.write("extra/test_\(i).mov", copy)
            keepers.append(try CleanupTrashSandbox.record(k))
            extras.append(try CleanupTrashSandbox.record(e, digest: CleanupTrashSandbox.sha256(good)))
        }
        model.records = keepers + extras
        let plan = await model.buildCleanupPlan()
        #expect(plan.copies.count == 300)
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        #expect(job.totals[.moved] == 10 && job.totals[.held] == 290, "\(job.totals.line)")
        let heldIDs = Set(job.items.filter { $0.outcome == .held }.map(\.id))
        for rec in extras where heldIDs.contains(rec.id) {
            #expect(rec.removal == nil && rec.lifecycleStage != .trashed, "\(rec.filename) was held but stamped")
            #expect(FileManager.default.fileExists(atPath: rec.fullPath))
        }
        #expect(keepers.allSatisfy { $0.removal == nil && FileManager.default.fileExists(atPath: $0.fullPath) })
        for rec in extras where rec.removal != nil { if let t = rec.removal?.trashPath { try? FileManager.default.removeItem(atPath: t) } }
    }
}
