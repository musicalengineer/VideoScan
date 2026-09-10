import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Family facts never become media keywords", .serialized)
struct HalliePersonFactRoutingTests {
    private func fixture() -> HallieTurnExecutor.Context {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Ellen /Ronan/
        1 SEX F
        1 BIRT
        2 DATE 1 JAN 1880
        2 PLAC Cork, Ireland
        0 @I2@ INDI
        1 NAME Mary /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 1 JAN 1900
        2 PLAC Galway, Ireland
        0 TRLR
        """)
        return .init(profiles: [], graph: graph)
    }

    @Test func treeOnlyPeopleRouteWithoutProfilesOrVideos() async throws {
        let context = fixture()
        for (question, operation) in [
            ("tell me about ellen ronan", ArchivistQueryAST.Graph.Operation.biography),
            ("where was mary o'connor born?", .birthPlace),
            ("tell me about mary o'connor and where she was born", .biography)
        ] {
            let pre = HallieTurnExecutor.preTranslation(
                question: question, playAfterAnswer: false, memory: .init(),
                isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
            guard case .run(let intent) = pre, case .graph(let payload) = intent.ast else {
                Issue.record("Family fact went to translator: \(question)"); continue
            }
            #expect(payload.operation == operation)
            let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
            #expect(result.route == .graph)
            #expect(result.outcome == .answered)
            #expect(!result.prose.contains("videos"))
            if operation == .birthPlace { #expect(result.prose.contains("Galway")) }
        }
    }

    @Test func correctionRetriesOriginalFactNotWholeCatalog() throws {
        let context = fixture()
        var memory = HallieTurnExecutor.ConversationMemory()
        let badIntent = HallieTurnExecutor.Intent(
            originalQuestion: "where was mary o'connor born?",
            ast: .presence(.init(keywords: ["mary o'connor", "born"])))
        memory.record(intent: badIntent, result: .init(
            route: .presence, outcome: .declined, prose: "No videos", basisLine: "fixture",
            queryDescription: "shape=presence", citations: [], catalogPersonName: nil))
        let pre = HallieTurnExecutor.preTranslation(
            question: "look in the family tree", playAfterAnswer: false, memory: memory,
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
        guard case .run(let intent) = pre, case .graph(let payload) = intent.ast else {
            Issue.record("Explicit tree correction escaped graph route"); return
        }
        #expect(payload.people == ["mary o'connor"])
        #expect(payload.operation == .birthPlace)
    }

    @Test func mediaAdviceAndMultiSubjectRequestsAreNotSwallowed() {
        for question in ["show videos of Ellen Ronan", "tell me about this video",
                         "tell me about black holes", "where was Ellen Ronan born and where did Mary die?",
                         "help me think of questions to ask my grandmother"] {
            #expect(HalliePersonFactQuestion.detect(question, isKnownPerson: {
                ["ellen ronan", "mary"].contains($0.lowercased())
            }) == nil)
        }
    }
}
