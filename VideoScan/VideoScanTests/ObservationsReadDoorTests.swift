// ObservationsReadDoorTests.swift — `SessionCatalogRead`, the one door the
// Observations module reads catalog.sqlite through (Observations/
// ObservationsStore.swift; docs/STATUS.md "Next" item 1: "one read door for
// a session"). The source pin that nothing else in the module names the
// session's repository is ObservationsSensorTests.theModuleReadsTheCatalogThroughOneDoor.
//
//   LOGIC      a session with no catalog open refuses in the door's words and
//              the body never runs; the body's own error passes through.
//   TRUTH      through the door = the session's own repository, one snapshot;
//              the read commits nothing.
//   CANCEL     a cancelled read never reaches the catalog.
// A fixture catalog in a temp folder.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Observations — the one read door of a session", .serialized) @MainActor
struct ObservationsReadDoorTests {

    private static let notOpen = "catalog.sqlite is not open in this session — there is nothing to read"

    @Test func aSessionWithNoCatalogOpenRefusesInTheDoorsWordsAndTheBodyNeverRuns() async throws {
        let ran = ObsCounter()
        let sandbox = try ShowAgainSandbox.make("read_door_closed")
        defer { sandbox.cleanup() }
        for door in [SessionCatalogRead(repository: { nil }), SessionCatalogRead(model: sandbox.model)] {
            do {
                _ = try await door { _ in ran.bump() }
                Issue.record("no catalog: the read must refuse")
            } catch {
                #expect(error as? Refusal == SessionCatalogRead.notOpen && FailureWords.of(error) == Self.notOpen)
            }
        }
        #expect(ran.value == 0, "nothing was read")
    }

    @Test func theDoorIsTheSessionsOwnRepositoryACancelledReadNeverReachesItAndNothingIsCommitted() async throws {
        let scene = try CutoverScene.make("read_door")
        defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        let repository = try #require(scene.model.catalogCutover.committer?.repository)
        let generation = await repository.generation
        let door = SessionCatalogRead(model: scene.model)

        let throughTheDoor = try await door { try $0.frameIndexFiles(.everything) }
        let direct = try await repository.read { try $0.frameIndexFiles(.everything) }
        #expect(throughTheDoor == direct && !throughTheDoor.isEmpty, "the same rows the session's repository gives")
        let seen = try await door { $0.generation }
        #expect(seen == generation, "the body runs inside the repository's read snapshot")

        let ran = ObsCounter()
        let cut = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try await door { _ in ran.bump() }
        }
        cut.cancel()
        await #expect(throws: CancellationError.self) { try await cut.value }
        #expect(ran.value == 0, "a read nobody wants any more does not touch the catalog")

        do {
            _ = try await door { _ -> Int in throw Refusal("the body said no") }
            Issue.record("the body's error must come back")
        } catch {
            #expect(FailureWords.of(error) == "the body said no", "the body's own error, unchanged")
        }
        #expect(await repository.generation == generation, "READ ONLY: no commit")
    }
}
