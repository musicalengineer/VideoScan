import Foundation
import Testing
@testable import VideoScan

/// "who did Rick marry" → "when did they get married" (overnight cycle 5).
struct HalliePronounContinuityTests {
    typealias P = HalliePronounContinuity

    @Test func rewritesTheFirstBarePronounFromTheLastAnswersPeople() {
        let one = P.rewrite("when did they get married", lastPeople: ["Rick"])
        #expect(one?.question == "when did Rick get married")
        #expect(one?.note == "'they' = Rick (from the last answer)")
        let two = P.rewrite("When did they get married?", lastPeople: ["Rick", "Donna"])
        #expect(two?.question == "When did Rick and Donna get married?")
        #expect(P.rewrite("what was their wedding like", lastPeople: ["Rick", "Donna"])?.question
                == "what was Rick and Donna's wedding like")
        #expect(P.rewrite("where was he born", lastPeople: ["Rick"])?.question == "where was Rick born")
        #expect(P.rewrite("show me his guitar videos", lastPeople: ["Rick"])?.question == "show me Rick's guitar videos")
    }

    @Test func leavesQuestionsAloneWhenNothingApplies() {
        #expect(P.rewrite("when did they get married", lastPeople: []) == nil, "no last answer")
        #expect(P.rewrite("where was he born", lastPeople: ["Rick", "Donna"]) == nil, "he with two people is a guess")
        #expect(P.rewrite("who did Rick marry", lastPeople: ["Donna"]) == nil, "no pronoun")
        #expect(P.rewrite("is the theater open", lastPeople: ["Rick"]) == nil, "'the' is not 'they'")
        #expect(P.rewrite("when did they get married", lastPeople: ["they"]) == nil, "a pronoun cannot stand for a pronoun")
    }

    @Test func preTranslationRewritesAfterAGraphAnswer() {
        var memory = HallieTurnExecutor.ConversationMemory()
        let spouse = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "Donna Elaine Hudson is married to Richard Harding Breen Jr.",
            basisLine: "Basis: GEDCOM", queryDescription: "shape=graph",
            citations: [], catalogPersonName: nil)
        memory.record(intent: .init(originalQuestion: "who did Rick marry",
                                    ast: .graph(.init(people: ["Rick"], operation: .kinship, relation: .spouse))),
                      result: spouse)
        let pre = HallieTurnExecutor.preTranslation(
            question: "when did they get married", playAfterAnswer: false,
            memory: memory, isKnownPerson: { _ in false })
        guard case .translate(let question, _) = pre else { Issue.record("should translate"); return }
        #expect(question == "when did Rick get married")
    }

    @Test func aPronounThatReachesTheTreeRouteAsksWhoInsteadOfLookingItUp() async throws {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "when did they get married",
            ast: .graph(.init(people: ["they"], operation: .kinship, relation: .spouse)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: .init())
        #expect(result.outcome == .declined)
        #expect(result.prose == "I'm not sure who you mean by “they” — ask me by name, or ask right after a question about someone and I'll take it to mean them.")
        #expect(!result.prose.contains("tell me about"))
    }
}
