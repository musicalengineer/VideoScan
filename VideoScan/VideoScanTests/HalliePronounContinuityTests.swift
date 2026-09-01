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

    /// Eval 2026-09-01: "and her husband?" — "her" before a kin noun is
    /// the possessive, so the translator must see "Martha Lamson's
    /// husband", not "Martha Lamson husband". As an object it stays bare.
    @Test func herBeforeAKinNounIsPossessive() {
        #expect(P.rewrite("and her husband?", lastPeople: ["Martha Lamson"])?.question == "and Martha Lamson's husband?")
        #expect(P.rewrite("who were her parents", lastPeople: ["Martha Lamson"])?.question == "who were Martha Lamson's parents")
        #expect(P.rewrite("her kids?", lastPeople: ["Donna"])?.question == "Donna's kids?")
        #expect(P.rewrite("when did her mother die", lastPeople: ["Donna"])?.question == "when did Donna's mother die")
        #expect(P.rewrite("her brothers and sisters", lastPeople: ["Donna"])?.question == "Donna's brothers and sisters")
        // A name ending in s takes the bare apostrophe.
        #expect(P.rewrite("her husband", lastPeople: ["Agnes"])?.question == "Agnes' husband")
        // Object uses are unchanged.
        #expect(P.rewrite("show me videos of her", lastPeople: ["Donna"])?.question == "show me videos of Donna")
        #expect(P.rewrite("tell me about her", lastPeople: ["Donna"])?.question == "tell me about Donna")
        #expect(P.rewrite("did she have kids", lastPeople: ["Martha Lamson"])?.question == "did Martha Lamson have kids")
        // Two people: "her" is still a guess and is left alone.
        #expect(P.rewrite("and her husband?", lastPeople: ["Rick", "Donna"]) == nil)
    }

    /// The memory side of the same eval miss: after "did she have kids"
    /// (a kinship answer listing Isaac and Patience) the reader is still
    /// talking about Martha. A kinship answer about X's relatives keeps X
    /// as the subject for "her"; the children never become the referent.
    @Test func aKinshipAnswerKeepsItsSubjectForTheNextPronoun() {
        var memory = HallieTurnExecutor.ConversationMemory()
        let bio = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "Martha Lamson was born before 13 January 1633.",
            basisLine: "Basis: GEDCOM", queryDescription: "shape=graph",
            citations: [], catalogPersonName: "Martha Lamson")
        memory.record(intent: .init(originalQuestion: "when was Martha Lamson born",
                                    ast: .graph(.init(people: ["Martha Lamson"], operation: .birth))),
                      result: bio)
        let kids = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "Martha Lamson's children: Isaac Rice, Patience Rice.",
            basisLine: "Basis: GEDCOM", queryDescription: "shape=graph operation=kinship",
            citations: [], catalogPersonName: nil)
        memory.record(intent: .init(originalQuestion: "did she have kids",
                                    ast: .graph(.init(people: ["Martha Lamson"], operation: .kinship, relation: .children))),
                      result: kids)
        #expect(memory.pronounReferents == ["Martha Lamson"])
        #expect(P.rewrite("and her husband?", lastPeople: memory.pronounReferents)?.question
                == "and Martha Lamson's husband?")
        // Through preTranslation with no tree: the follow-up refiner must
        // NOT read "husband" as a person; the fragment goes on as a kinship
        // ask for Martha's husband (the lineage shape claims it first).
        let pre = HallieTurnExecutor.preTranslation(
            question: "and her husband?", playAfterAnswer: false,
            memory: memory, isKnownPerson: { $0.lowercased() == "husband" })
        guard case .run(let intent) = pre else { Issue.record("expected a local kinship intent, got \(pre)"); return }
        #expect(intent.ast == .graph(.init(people: ["Martha Lamson"], operation: .kinship, relation: .husband)))
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
