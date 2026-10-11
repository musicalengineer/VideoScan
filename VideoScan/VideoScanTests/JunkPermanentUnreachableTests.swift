// JunkPermanentUnreachableTests.swift
// Codex delete-engines review 2026-10-09, F1 (P1): "Junk permanent deletion
// remains executable" — `deleteConfirmedJunk([record], mode: .permanent)`
// with no injected operation reached `FileManager.removeItem`. "Tests only"
// was a comment, not an execution rule (design R3).
//
// The rule now: the junk engine contains NO permanent removal of its own.
// The only non-Trash mode is `.removeThroughTestSeam(op)`, whose removal is
// the operation the CALLER injects — and no production source constructs
// one (the test target's `.permanent` is that seam with a `removeItem`
// written in the test bundle). So no production caller can reach
// `FileManager.removeItem` through `deleteConfirmedJunk`.

import Foundation
import Testing
@testable import VideoScan

@Suite("Junk engine — permanent removal is unreachable in production (codex F1)")
struct JunkPermanentUnreachableTests {

    static let engineFile = "VideoScanModel+JunkDelete.swift"

    /// The engine file (comments dropped) has no removal of its own.
    @Test("sensor: the junk engine itself never calls removeItem / unlink")
    func theEngineHasNoPermanentRemoval() throws {
        let engine = try SourceTree.appCode(named: Self.engineFile)
        for banned in ["removeItem(", "unlink(", "unlinkat(", "rmdir(", "removefile("] {
            #expect(!engine.contains(banned), "\(Self.engineFile) contains \(banned)")
        }
        // Its one non-Trash mode carries the caller's operation.
        #expect(engine.contains("case removeThroughTestSeam("))
    }

    /// No production source outside the engine names the seam: nothing in
    /// the app can build the one mode that is not the Trash.
    @Test("sensor: no production source constructs the test-only removal mode")
    func noProductionCallerBuildsTheSeam() throws {
        var hits: [String] = []
        for entry in SourceTree.appSources {
            let name = (entry.relative as NSString).lastPathComponent
            guard name != Self.engineFile else { continue }
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("removeThroughTestSeam") || line.contains("JunkDeletionMode.permanent")
                    || line.contains("mode: .permanent") {
                    hits.append("\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    /// Behaviour: the production mode a caller can spell is the Trash — the
    /// file is handed to the Trash step, never unlinked (the sandbox Trash
    /// stands in for FileManager.trashItem and records the hand-off).
    @MainActor
    @Test("the one production mode moves the file to the Trash")
    func theProductionModeIsTheTrash() async throws {
        let sb = try JunkTrashSandbox("f1"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_f1.mov")
        let rec = sb.junk(url)
        model.records = [rec]
        let guardSeam = VideoScanModel.JunkDeletionGuard(authorize: { _ in nil }, beforeRemoval: { _ in nil },
                                                         remove: sb.trash.operation)
        let result = await model.deleteConfirmedJunk([rec], mode: .toTrash, guard: guardSeam)
        #expect(result.succeeded == 1)
        #expect(sb.trash.attempts == [url.path], "handed to the Trash step exactly once")
        #expect(rec.lifecycleStage == .trashed)
    }
}
