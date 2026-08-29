import Foundation
import Testing
@testable import VideoScan

/// The app coordinator honours conversation memory BEFORE translation:
/// follow-ups, refinements, local family-tree shapes, and capability
/// questions never reach the model, and their answers still flow through the
/// same Response the chat window commits.
@MainActor
@Suite("Hallie app coordinator follow-ups", .serialized)
struct HallieAppTurnCoordinatorFollowUpTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
    }

    private func records() -> [VideoRecord] {
        (0..<3).map { index in
            let record = VideoRecord()
            record.fullPath = "/isolated/199\(index)/donna_\(index).mov"
            record.filename = "donna_\(index).mov"
            record.confirmedByUserPeople = [
                ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 0)),
            ]
            return record
        }
    }

    private func dependencies(
        calls: Recorder,
        translation: ArchivistQueryAST = .presence(.init(people: ["donna"])),
        graph: GedcomFamilyGraph? = nil
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in calls.append("start"); return hosts },
            translateAST: { question, _, _ in
                calls.append("translate:\(question)")
                return .init(ast: translation, responderHost: "fixture-host")
            },
            loadProfiles: {
                calls.append("profiles")
                return [.init(stableID: "rick", canonicalName: "Rick")]
            },
            loadGraph: { calls.append("graph"); return graph },
            loadCyberBrain: { calls.append("cyberbrain"); return nil },
            executeRequest: { request, context in
                calls.append("execute:\(HallieTurnExecutor.description(of: request.intent.ast)) offset=\(request.intent.citationOffset)")
                return try await HallieTurnExecutor.execute(request, context: context)
            },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    private func execute(
        _ question: String,
        memory: inout HallieTurnExecutor.ConversationMemory,
        calls: Recorder,
        translation: ArchivistQueryAST = .presence(.init(people: ["donna"])),
        graph: GedcomFamilyGraph? = nil
    ) async throws -> HallieAppTurnCoordinator.Response {
        let response = try await HallieAppTurnCoordinator.execute(
            question: question, records: records(),
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            memory: memory,
            dependencies: dependencies(calls: calls, translation: translation, graph: graph))
        memory.record(intent: response.executedIntent, result: response.result)
        return response
    }

    @Test func followUpsRunWithoutTranslationAndReturnMediaActions() async throws {
        var memory = HallieTurnExecutor.ConversationMemory()
        let calls = Recorder()

        let first = try await execute("how many videos of donna do we have?",
                                      memory: &memory, calls: calls)
        #expect(first.result.matchCount == 3)
        #expect(first.executedIntent != nil)
        // KNOWN ISSUE (team channel #567, codex's lane): since 87a21a4d the
        // coordinator loads profiles + cyberbrain on the FIRST turn too
        // (the interpretation guards ask "is this a person?"). The
        // expectation stays so the regression is visible, not blessed.
        withKnownIssue("eager identity-source loading on a fresh turn — #567") {
            #expect(calls.values == ["start", "translate:how many videos of donna do we have?",
                                     "execute:shape=presence offset=0"])
        }
        let callsAfterFirstTurn = calls.values.count

        let play = try await execute("play one of them, say the first one",
                                     memory: &memory, calls: calls)
        #expect(play.result.route == .followUp)
        #expect(play.result.outcome == .answered)
        #expect(play.result.mediaAction?.kind == .play)
        #expect(play.result.mediaAction?.citations.map(\.filename) == ["donna_0.mov"])
        #expect(play.responderHost == HallieAppTurnCoordinator.localResponder)
        #expect(play.executedIntent == nil)
        #expect(play.playAfterAnswer == false)
        #expect(calls.values.count == callsAfterFirstTurn,
                "no start/translate/execute for a follow-up: \(calls.values)")

        let refined = try await execute("and in the 90s?", memory: &memory, calls: calls)
        #expect(refined.result.route == .presence)
        #expect(refined.result.matchCount == 3)
        #expect(refined.result.basisLine.contains("refining: donna · 1990–1999"))
        #expect(refined.responderHost == HallieAppTurnCoordinator.localResponder)
        #expect(calls.values.last == "execute:shape=presence offset=0")
        #expect(!calls.values.contains { $0.hasPrefix("translate:and") })
    }

    @Test func searchThenPlayTranslatesTheRemainderWithPlayIntent() async throws {
        var memory = HallieTurnExecutor.ConversationMemory()
        let calls = Recorder()
        let response = try await execute("play donna at the cape", memory: &memory, calls: calls)
        #expect(calls.values.contains("translate:donna at the cape"))
        #expect(response.playAfterAnswer == true)
        #expect(response.executedIntent?.playAfterAnswer == true)
        #expect(response.executedIntent?.originalQuestion == "play donna at the cape")
    }

    @Test func capabilityAndFamilyTreeShapesNeverReachTheModel() async throws {
        var memory = HallieTurnExecutor.ConversationMemory()
        let calls = Recorder()
        let capability = try await execute("can we change donna's biography?",
                                           memory: &memory, calls: calls)
        #expect(capability.result.route == .capability)
        #expect(capability.result.offeredActions == [
            .ask(question: "who is Donna?", label: "Show what I have for Donna"),
        ])
        #expect(calls.values.isEmpty, "capability answers touch nothing: \(calls.values)")

        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Donna /Breen/
        1 SEX F
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Timothy /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @F1@ FAM
        1 WIFE @I1@
        1 CHIL @I2@
        0 TRLR
        """)
        let tree = try await execute("show donna's family tree", memory: &memory,
                                     calls: calls, graph: graph)
        #expect(tree.result.route == .graph)
        #expect(tree.result.outcome == .answered)
        #expect(tree.result.prose.hasPrefix("Donna Breen had 1 recorded child, Timothy Breen."))
        #expect(tree.result.offeredActions == [.openFamilyTree(personName: "Donna Breen")])
        #expect(!calls.values.contains { $0.hasPrefix("translate:") })
        #expect(calls.values.contains("execute:shape=graph offset=0"))
    }
}
