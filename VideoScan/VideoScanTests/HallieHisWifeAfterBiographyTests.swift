// HallieHisWifeAfterBiographyTests.swift
// Live 2026-09-11 21:56Z and 22:00Z (Release spot test): "tell me about
// dad" → biography of Richard Harding Breen Sr (correct), then "who was
// his wife" / "who was his wife?" → route=cross, "shape=presence
// person=richard harding breen sr keyword=wife" → "I looked for videos of
// richard harding breen sr with “wife” and found nothing in the catalog."
//
// The deterministic kinship cue had a hole exactly the width of this
// sentence: the bare fragment ("his wife", "and her husband?") took a
// pronoun possessor, and the sentence form ("who was rick's wife") took a
// named possessor, but the sentence form with a PRONOUN possessor was
// claimed by neither. It fell through to the follow-up lane, whose
// pronoun rewrite hands the question to the model translator — which
// read "wife" as a search word. Pure fixture, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 12 MAR 1931
1 DEAT
2 DATE 25 JUN 2008
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 31 AUG 1930
1 FAMS @F1@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
1 MARR
2 DATE 14 JUN 1952
0 @I4@ INDI
1 NAME George /Breen/
1 SEX M
1 BIRT
2 DATE 1901
1 FAMS @F2@
0 @F2@ FAM
1 HUSB @I4@
1 CHIL @I2@
0 TRLR
"""

@Suite("\"who was his wife\" after a biography is a kinship question")
struct HallieHisWifeAfterBiographyTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    private func pre(_ q: String, memory: Exec.ConversationMemory = .init()) -> Exec.PreTranslation {
        let context = self.context
        return Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }

    // MARK: Detection — the sentence form with a pronoun possessor

    @Test func whoWasHisWifeIsAKinshipQuestionAboutHim() {
        #expect(Q.detect("who was his wife") == .kinship(person: "His", relation: .wife, side: nil))
        #expect(Q.detect("who was his wife?") == .kinship(person: "His", relation: .wife, side: nil))
        // Live 22:10Z: "who was his father?" after "tell me about David T
        // McGill" → cross search with “father” as the keyword. Same hole.
        #expect(Q.detect("who was his father?") == .kinship(person: "His", relation: .father, side: nil))
        #expect(Q.detect("who was her mother") == .kinship(person: "Her", relation: .mother, side: nil))
        #expect(Q.detect("Who is his wife?") == .kinship(person: "His", relation: .wife, side: nil))
        #expect(Q.detect("who was her husband") == .kinship(person: "Her", relation: .husband, side: nil))
        #expect(Q.detect("and who were her parents?") == .kinship(person: "Her", relation: .parents, side: nil))
        #expect(Q.detect("what are the names of his children") == .kinship(person: "His", relation: .children, side: nil))
    }

    /// "their" is NOT claimed by the sentence form (codex #1352): pronoun
    /// execution reads it as plural and declines "one person at a time"
    /// even when memory holds one referent, so claiming it would turn a
    /// question the translator could answer into a sure decline. It keeps
    /// the road it had; singular-they is deferred.
    @Test func theirKeepsItsOldRoad() {
        #expect(Q.namedKinSentenceQuestion(in: "who were their children") == nil)
        #expect(Q.namedKinSentenceQuestion(in: "who were their kids") == nil)
        #expect(Q.namedKinSentenceQuestion(in: "what are the names of their children") == nil)
        #expect(Q.detect("who were their children") == nil)
        // The bare fragment's own "their" is untouched.
        #expect(Q.detect("their children") == .kinship(person: "Their", relation: .children, side: nil))
    }

    /// The typed form always worked (live 22:02Z: "who was eileen's
    /// spouse?" answered correctly) — and the pronoun rewrite's own output
    /// parses too, suffix and all, so the hole was only the pronoun.
    @Test func theNamedFormsStillParse() {
        #expect(Q.detect("who was rick's wife") == .kinship(person: "Rick", relation: .wife, side: nil))
        #expect(Q.detect("who was richard harding breen sr's wife")
                == .kinship(person: "Richard Harding Breen Sr", relation: .wife, side: nil))
        #expect(Q.detect("who was eileen's spouse?") == .kinship(person: "Eileen", relation: .spouse, side: nil))
        #expect(Q.detect("his wife") == .kinship(person: "His", relation: .wife, side: nil))
    }

    /// Only the whole question is claimed: more words after the kin noun
    /// are a different shape and keep their old road.
    @Test func aLongerSentenceIsNotClaimed() {
        #expect(Q.detect("who was his wife in that video") == nil)
        #expect(Q.detect("who was his father in the marines") == nil)
        #expect(Q.detect("show me his wife's videos") != .kinship(person: "His", relation: .wife, side: nil))
    }

    // MARK: The live two-turn sequence, through the real pre-translation step

    private func memoryAfterBiography(of typed: String, expecting name: String) async throws -> Exec.ConversationMemory {
        let intent = Exec.Intent(
            originalQuestion: "tell me about \(typed)",
            ast: .graph(.init(people: [typed], operation: .biography)))
        let answered = try await Exec.execute(.init(intent: intent), context: context)
        #expect(answered.outcome == .answered, Comment(rawValue: answered.prose))
        #expect(answered.catalogPersonName == name)
        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: answered)
        #expect(memory.pronounReferents == [name])
        return memory
    }

    @Test func whoWasHisWifeAfterDadsBiographyNamesMa() async throws {
        let memory = try await memoryAfterBiography(of: "richard harding breen sr", expecting: "Richard Harding Breen Sr")
        for question in ["who was his wife", "who was his wife?", "Who was his wife?"] {
            guard case .run(let intent) = pre(question, memory: memory) else {
                Issue.record("\(question): expected a kinship intent, got \(pre(question, memory: memory))")
                continue
            }
            #expect(intent.ast == .graph(.init(
                people: ["Richard Harding Breen Sr"], operation: .kinship, relation: .wife, side: nil)),
                Comment(rawValue: "\(question): \(intent.ast)"))
            let result = try await Exec.execute(.init(intent: intent), context: context)
            #expect(result.route == .graph, Comment(rawValue: "\(question): \(result.prose)"))
            #expect(result.outcome == .answered, Comment(rawValue: "\(question): \(result.prose)"))
            #expect(result.prose.contains("Eileen Latta"), Comment(rawValue: "\(question): \(result.prose)"))
        }
    }

    @Test func whoWasHisFatherAfterDadsBiographyNamesGrandpa() async throws {
        let memory = try await memoryAfterBiography(of: "richard harding breen sr", expecting: "Richard Harding Breen Sr")
        guard case .run(let intent) = pre("who was his father?", memory: memory) else {
            Issue.record("expected a kinship intent, got \(pre("who was his father?", memory: memory))")
            return
        }
        #expect(intent.ast == .graph(.init(
            people: ["Richard Harding Breen Sr"], operation: .kinship, relation: .father, side: nil)))
        let result = try await Exec.execute(.init(intent: intent), context: context)
        #expect(result.route == .graph, Comment(rawValue: result.prose))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("George Breen"), Comment(rawValue: result.prose))
        #expect(result.queryDescription?.contains("keyword=") != true, Comment(rawValue: result.queryDescription ?? "nil"))
    }

    @Test func whoWasHerHusbandAfterMasBiographyNamesDad() async throws {
        let memory = try await memoryAfterBiography(of: "eileen latta", expecting: "Eileen Latta")
        guard case .run(let intent) = pre("who was her husband", memory: memory) else {
            Issue.record("expected a kinship intent, got \(pre("who was her husband", memory: memory))")
            return
        }
        #expect(intent.ast == .graph(.init(
            people: ["Eileen Latta"], operation: .kinship, relation: .husband, side: nil)))
        let result = try await Exec.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("Richard Harding Breen Sr"), Comment(rawValue: result.prose))
    }

    /// With nobody in memory the pronoun has no one to stand for: Hallie
    /// asks who, and never searches the catalog for "wife".
    @Test func withNoSubjectInMemoryHallieAsksWho() {
        guard case .answer(let result) = pre("who was his wife") else {
            Issue.record("expected a local ask, got \(pre("who was his wife"))")
            return
        }
        #expect(result.route == .graph)
        #expect(result.outcome == .declined)
        #expect(result.prose == HalliePronounContinuity.whoDoYouMean("his"))
    }
}
