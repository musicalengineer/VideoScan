import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Hallie relative facts", .serialized)
struct HallieRelativeFactTests {
    private func context() -> HallieTurnExecutor.Context {
        .init(graph: GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @R@ INDI
        1 NAME Rick /Example/
        1 FAMC @P@
        0 @D@ INDI
        1 NAME Dad /Example/
        1 SEX M
        1 FAMC @PD@
        0 @M@ INDI
        1 NAME Mom /Example/
        1 SEX F
        1 FAMC @PM@
        0 @PG@ INDI
        1 NAME Mary /Example/
        1 SEX F
        1 BIRT
        2 PLAC London, England
        0 @MG@ INDI
        1 NAME Mary /Example/
        1 SEX F
        1 BIRT
        2 PLAC Cork, Ireland
        1 FAMC @GGM@
        0 @GG@ INDI
        1 NAME Ellen /Ronan/
        1 SEX F
        1 BIRT
        2 PLAC Galway, Ireland
        0 @P@ FAM
        1 HUSB @D@
        1 WIFE @M@
        1 CHIL @R@
        0 @PD@ FAM
        1 WIFE @PG@
        1 CHIL @D@
        0 @PM@ FAM
        1 WIFE @MG@
        1 CHIL @M@
        0 @GGM@ FAM
        1 WIFE @GG@
        1 CHIL @MG@
        0 TRLR
        """), speakers: .init(ownerName: "Rick Example", archivistName: nil))
    }

    private func ask(_ phrase: String, operation: ArchivistQueryAST.Graph.Operation = .birthPlace,
                     context: HallieTurnExecutor.Context) async throws -> HallieTurnExecutor.Result {
        let question = operation == .biography ? "Tell me about \(phrase)" : "Where was \(phrase) born?"
        let pre = HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
        guard case .run(let intent) = pre else {
            Issue.record("Relative fact escaped deterministic routing")
            throw NSError(domain: "HallieRelativeFactTests", code: 1)
        }
        return try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
    }

    @Test func grandmotherClarificationRetainsBirthplaceAndStableIdentity() async throws {
        let snapshot = context()
        let response = try await ask("my grandmother", context: snapshot)
        #expect(response.route == .graph)
        #expect(response.outcome == .needsClarification)
        let pending = try #require(response.clarification)
        #expect(pending.candidates.count == 2)
        guard case .graph(let graph) = pending.intent.ast else { Issue.record("Not graph"); return }
        #expect(graph.operation == .birthPlace)
        let maternal = try #require(pending.candidates.first { $0.id == .gedcomPersonID("@MG@") })
        #expect(maternal.label.hasPrefix("maternal grandmother:"))
        let paternal = try #require(pending.candidates.first { $0.id == .gedcomPersonID("@PG@") })
        #expect(paternal.label.hasPrefix("paternal grandmother:"))
        #expect(HallieTurnExecutor.clarificationSelection("maternal", from: pending.candidates) == maternal.id)
        #expect(HallieTurnExecutor.clarificationSelection("paternal grandmother", from: pending.candidates) == paternal.id)
        let answer = try await HallieTurnExecutor.continue(pending: pending, selecting: maternal.id, context: snapshot)
        #expect(answer.outcome == .answered)
        #expect(answer.prose.contains("Cork"))
        #expect(!answer.prose.contains("London"))
        let forged = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .gedcomPersonID("@GG@"), context: snapshot)
        #expect(forged.outcome != .answered)
    }

    @Test func sideAndGreatGrammaResolveWithoutCatalog() async throws {
        let snapshot = context()
        let paternal = try await ask("my paternal grandmother", context: snapshot)
        #expect(paternal.outcome == .answered)
        #expect(paternal.prose.contains("London"))
        let great = try await ask("my great gramma", operation: .biography, context: snapshot)
        #expect(great.route == .graph)
        #expect(great.outcome == .answered)
        #expect(great.prose.contains("Ellen"))
    }

    @Test func unknownOwnerDoesNotGuessRelative() async throws {
        let response = try await ask("my grandmother", context: .init(graph: context().graph))
        #expect(response.outcome == .declined)
        #expect(response.route == .graph)
        #expect(response.clarification == nil)
    }

    @Test func staleOwnerPinCannotFallBackToTreeRoot() async throws {
        let snapshot = HallieTurnExecutor.Context(graph: context().graph,
            speakers: .init(ownerName: "Rick Example", archivistName: nil,
                            ownerFamilySearchID: "NOT-IN-TREE"))
        let result = try await ask("my grandmother", context: snapshot)
        #expect(result.route == .graph)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("NOT-IN-TREE"))
    }

    @Test func relativeParserDoesNotStealNamedSubjects() {
        #expect(HallieTurnExecutor.RelativeFactSubject.parse("Ellen Ronan") == nil)
        #expect(HallieTurnExecutor.RelativeFactSubject.parse("my grandmother Ellen") == nil)
        #expect(HallieTurnExecutor.RelativeFactSubject.parse("my great gramma")?.relation == .greatGrandmother)
    }

    @Test func translatedWeddingDateCannotBecomeRelativeBirthDate() async throws {
        let payload = ArchivistQueryAST.Graph(people: ["my grandmother"], operation: .birth)
        let request = HallieTurnExecutor.Request(intent: .init(
            originalQuestion: "When was my grandmother married?", ast: .graph(payload)))
        let result = try await HallieTurnExecutor.executeRelativeFact(
            payload: payload, request: request, context: context(), dependencies: .production)
        #expect(result == nil)
    }
}
