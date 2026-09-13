// HallieTwoModeGateIntegrationTests.swift
// The mode gate wired into the app coordinator (design §3.4 B, the
// HallieAppV2IntegrationTests dependency pattern), and the executor-level
// cross-family fallbacks under Context.mode (design §3.4 C): a place
// question does not become a catalog cross search in tree mode, an
// unresolved aggregate anchor does not become a presence search in tree
// mode, and "search the family tree for <not a person>" is declined by
// name instead of looked up.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME John /Hastings/
1 SEX M
1 BIRT
2 DATE 11 OCT 1372
2 PLAC Kenilworth, Warwickshire, England
1 DEAT
2 DATE 30 DEC 1389
0 TRLR
"""

@MainActor
@Suite("Two-mode gate: coordinator and executor", .serialized)
struct HallieTwoModeGateIntegrationTests {
    typealias Exec = HallieTurnExecutor
    private let graph = GedcomFamilyGraph(gedcomText: tree)

    private final class Recorder: @unchecked Sendable {
        var asts: [ArchivistQueryAST] = []
        var translated: [String] = []
    }

    private func dependencies(
        translatorReturns ast: ArchivistQueryAST, recorder: Recorder
    ) -> HallieAppTurnCoordinator.Dependencies {
        let graph = self.graph
        return HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, _, _ in
                recorder.translated.append(question)
                return .init(ast: ast, responderHost: "fixture-host")
            },
            loadProfiles: { [] },
            loadGraph: { graph },
            loadCyberBrain: { nil },
            loadSpeakers: { .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil) },
            executeRequest: { request, context in
                recorder.asts.append(request.intent.ast)
                return try await Exec.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await Exec.continue(pending: clarification, selecting: selectedID, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    private var treeContext: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    // MARK: Coordinator

    /// strict-004/-015 residue, closed: a translator `presence` for a tree
    /// question in tree mode is executed as a graph biography — no keyword
    /// search — and the basis says so.
    @Test func treeModeReconcilesATranslatorPresenceIntoAGraphQuery() async throws {
        let intent = Exec.Intent(
            originalQuestion: "tell me about john hastings",
            ast: .graph(.init(people: ["john hastings"], operation: .biography)))
        let biography = try await Exec.execute(.init(intent: intent), context: treeContext)
        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: biography)
        #expect(memory.mode == .tree)

        let recorder = Recorder()
        let response = try await HallieAppTurnCoordinator.execute(
            question: "what did he do for a living?",
            records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            memory: memory,
            dependencies: dependencies(
                translatorReturns: .presence(.init(people: ["john hastings"], keywords: ["living"])),
                recorder: recorder))
        #expect(recorder.translated == ["what did John Hastings do for a living?"])
        #expect(recorder.asts == [.graph(.init(people: ["john hastings"], operation: .biography))],
                Comment(rawValue: "\(recorder.asts)"))
        #expect(response.result.route == .graph, Comment(rawValue: response.result.prose))
        #expect(response.result.outcome == .answered, Comment(rawValue: response.result.prose))
        #expect(response.result.queryDescription?.contains("keyword=") != true)
        #expect(response.result.basisLine.contains("read “what did John Hastings do for a living?” as a family-tree question about john hastings"),
                Comment(rawValue: response.result.basisLine))
        memory.record(intent: response.executedIntent, result: response.result)
        #expect(memory.mode == .tree)
    }

    /// The other direction: a translator `graph` for a play request in
    /// catalog mode is executed as a presence search.
    @Test func catalogModeReconcilesATranslatorGraphIntoAPresenceSearch() async throws {
        var memory = Exec.ConversationMemory()
        let citation = Exec.Citation(recordID: UUID(), fullPath: "/Fixture/donna_0.mov", filename: "donna_0.mov",
                                     playbackSeconds: nil, bases: [])
        memory.record(
            intent: .init(originalQuestion: "videos of donna", ast: .presence(.init(people: ["donna"]))),
            result: .init(route: .presence, outcome: .answered, prose: "One.", basisLine: "Basis: fixture.",
                          queryDescription: "shape=presence", citations: [citation], catalogPersonName: nil, matchCount: 1))
        #expect(memory.mode == .catalog)

        let recorder = Recorder()
        let response = try await HallieAppTurnCoordinator.execute(
            question: "play donna at the cape",
            records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            memory: memory,
            dependencies: dependencies(
                translatorReturns: .graph(.init(people: ["donna"], operation: .biography)),
                recorder: recorder))
        #expect(recorder.translated == ["donna at the cape"])
        #expect(recorder.asts == [.presence(.init(people: ["donna"]))], Comment(rawValue: "\(recorder.asts)"))
        #expect(response.result.route == .presence, Comment(rawValue: response.result.prose))
        #expect(response.result.basisLine.contains("read “donna at the cape” as a catalog search for donna"),
                Comment(rawValue: response.result.basisLine))
    }

    /// Unknown mode: the AST is executed as translated (today's behaviour).
    @Test func unknownModeExecutesTheASTAsTranslated() async throws {
        let recorder = Recorder()
        let response = try await HallieAppTurnCoordinator.execute(
            question: "Ireland and the UK are part of Europe aren't they?",
            records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            memory: .init(),
            dependencies: dependencies(
                translatorReturns: .presence(.init(keywords: ["europe"])),
                recorder: recorder))
        // The general lane may take it first; if it reaches the executor
        // the AST is untouched.
        if !recorder.asts.isEmpty {
            #expect(recorder.asts == [.presence(.init(keywords: ["europe"]))])
        }
        #expect(response.result.mode != .tree)
    }

    // MARK: Executor fallbacks under Context.mode

    @Test func aPlaceQuestionIsNotACatalogSearchInTreeMode() async throws {
        let intent = Exec.Intent(
            originalQuestion: "what's the story behind the westford house",
            ast: .graph(.init(people: ["the westford house"], operation: .biography)))
        let treeMode = try await Exec.execute(
            .init(intent: intent),
            context: .init(profiles: [], graph: graph, speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil), mode: .tree))
        #expect(treeMode.route == .graph, Comment(rawValue: treeMode.prose))
        #expect(treeMode.outcome == .declined)
        #expect(treeMode.mode == .tree)
        #expect(treeMode.prose.contains("not a person I know in the family tree"), Comment(rawValue: treeMode.prose))

        let unknownMode = try await Exec.execute(.init(intent: intent), context: treeContext)
        #expect(unknownMode.route == .cross, "today's road: a catalog cross search for the place word")
    }

    @Test func anUnresolvedAggregateAnchorIsNotAPresenceSearchInTreeMode() async throws {
        let intent = Exec.Intent(
            originalQuestion: "who appears with john hastings",
            ast: .aggregate(.init(operation: .coOccurrence, anchorPeople: ["john hastings"])))
        let unknownMode = try await Exec.execute(.init(intent: intent), context: treeContext)
        #expect(unknownMode.route == .presence, "GH #182: a known person anchor becomes a presence search")

        let treeMode = try await Exec.execute(
            .init(intent: intent),
            context: .init(profiles: [], graph: graph, speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil), mode: .tree))
        #expect(treeMode.route == .aggregate, Comment(rawValue: treeMode.prose))
        #expect(treeMode.outcome == .declined)
    }

    // MARK: Resolver

    @Test func theFamilyTreePersonSlotRequiresAKnownPerson() {
        typealias R = ArchivistFollowUpResolver
        #expect(R.resolve("search the family tree for a title like king", snapshot: nil) { _ in false }
                == .declineNotAKnownPerson("title like king"))
        #expect(R.resolve("show me the family tree of donna", snapshot: nil) { $0 == "donna" }
                == .localQuery(.graph(.init(people: ["donna"], operation: .familyTree))))
        #expect(R.resolve("get me the family tree for the breens", snapshot: nil) { _ in false }
                == .localQuery(.graph(.init(people: [], operation: .familyTree, surname: "breens"))),
                "a surname slot is not a person slot")
    }
}
