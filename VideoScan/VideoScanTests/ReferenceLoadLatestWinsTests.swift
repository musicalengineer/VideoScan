import Testing
import Foundation
@testable import VideoScan

// MARK: - Reference loads: newest selection wins (2026-10-04)
//
// Rick arrowed through the People gallery; every card selection started a
// reference load that was never cancelled. ~17 ran at once, each blocking a
// Swift cooperative thread inside Vision, until the pool was exhausted and
// Vision deadlocked — Quit hung. Loads are now serial on their own queue and
// a superseded one stops between photos and is discarded. These pin both
// halves: the stop, and the "only the newest counts" counter.

@Suite("Reference load — latest wins")
struct ReferenceLoadLatestWinsTests {

    @Test func supersededLoadStopsBeforeTouchingAnyPhoto() {
        let dir = (EngineSmokTests.referencePhotoPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { return }

        var asked = 0
        let (faces, failures, error) = pfLoadReferencePhotos(
            from: dir, largestFaceOnly: true,
            shouldContinue: { asked += 1; return false })

        #expect(asked == 1, "checked once, before the first photo")
        #expect(faces.isEmpty, "a superseded load must not produce faces")
        #expect(failures.isEmpty, "and must not report per-photo failures")
        // `error` may say "no faces" — harmless: the model drops a
        // superseded load's whole result before touching any state.
        _ = error
    }

    @Test func defaultStillLoadsEverything() {
        let dir = (EngineSmokTests.referencePhotoPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { return }

        let (faces, _, error) = pfLoadReferencePhotos(from: dir, largestFaceOnly: true)
        #expect(error == nil)
        #expect(!faces.isEmpty, "callers that pass no shouldContinue are unchanged")
    }

    @Test func onlyTheNewestGenerationIsCurrent() {
        let gen = ReferenceLoadGeneration()
        let first = gen.next()
        let second = gen.next()
        #expect(!gen.isCurrent(first), "an older selection is stale")
        #expect(gen.isCurrent(second))
    }

    /// Sensor: the model must not go back to running the blocking Vision
    /// load on the Swift cooperative pool (Task.detached), which is what
    /// exhausted it.
    @Test func modelLoadsOnItsOwnQueueNotTheCooperativePool() throws {
        let source = try SourceTree.appSource(named: "PersonFinderModel.swift")
        let start = try #require(source.range(of: "func loadReference(from path: String? = nil) async {"))
        let body = String(source[start.upperBound...].prefix(2500))
        #expect(body.contains("Self.referenceLoadQueue.async"))
        #expect(body.contains("Self.referenceLoadGeneration.isCurrent(generation)"))
        #expect(!body.contains("Task.detached"))
    }
}
