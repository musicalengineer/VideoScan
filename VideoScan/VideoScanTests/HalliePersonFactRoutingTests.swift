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

    /// GH #180 (live 2026-09-10/11): "tell me about dad" answered with
    /// Dafydd ab Einion (b. ~1360). A bare kin word is the owner's relative
    /// unless it is a known person's alias ("Ma" → Eileen keeps winning).
    @Test func bareKinWordsAreTheOwnersRelatives() {
        let nobody: (String) -> Bool = { _ in false }
        #expect(HalliePersonFactQuestion.detect("tell me about dad", isKnownPerson: nobody)
                == .init(people: ["my dad"], operation: .biography))
        #expect(HalliePersonFactQuestion.detect("Where was Mom born?", isKnownPerson: nobody)
                == .init(people: ["my mom"], operation: .birthPlace))
        #expect(HalliePersonFactQuestion.detect("who was nana", isKnownPerson: nobody)
                == .init(people: ["my nana"], operation: .biography))
        #expect(HalliePersonFactQuestion.detect("tell me about my dad", isKnownPerson: nobody)
                == .init(people: ["my dad"], operation: .biography))
        // A known alias wins over the kin reading.
        #expect(HalliePersonFactQuestion.detect("tell me about ma", isKnownPerson: { $0.lowercased() == "ma" })
                == .init(people: ["ma"], operation: .biography))
        // Not a kin word and not known → still the translator's.
        #expect(HalliePersonFactQuestion.detect("tell me about dave", isKnownPerson: nobody) == nil)
        #expect(HalliePersonFactQuestion.detect("tell me about the dads", isKnownPerson: nobody) == nil)
        typealias S = HallieTurnExecutor.RelativeFactSubject
        #expect(S.parse("dad") == .init(relation: .father, side: nil))
        #expect(S.parse("papa") == .init(relation: .father, side: nil))
        #expect(S.parse("my ma") == .init(relation: .mother, side: nil))
        #expect(S.parse("nana") == .init(relation: .grandmother, side: nil))
        #expect(S.parse("my maternal grandmother") == .init(relation: .grandmother, side: .maternal))
        #expect(S.parse("gladiator") == nil)
        #expect(S.parse("dad breen") == nil, "two words without a possessive is a name")
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

    @Test func treeCorrectionVariantsAndEmptyHistoryStayInGraphDomain() {
        for question in ["look in the family tree", "look it up in the family tree",
                         "try the tree", "please check the family tree"] {
            #expect(HalliePersonFactQuestion.isTreeCorrection(question))
            let pre = HallieTurnExecutor.preTranslation(
                question: question, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false })
            guard case .run(let intent) = pre, case .graph(let payload) = intent.ast else {
                Issue.record("Tree request escaped graph routing"); continue
            }
            #expect(payload.operation == .familyTree)
        }
        #expect(!HalliePersonFactQuestion.isTreeCorrection("show videos of the family tree"))
    }
}
