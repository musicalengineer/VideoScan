// HallieStrictReplayFamilyIntentTests.swift
// Codex's visible strict replay on the M4, 2026-09-13 10:19 (real model,
// 28/31): three family questions reached the catalog "cross" route with
// the intent words as search keywords —
//   strict-004  "whom did he marry"          after "where was he born?"
//               → "shape=presence person=john hastings 3rd earl of pembroke keyword=marry"
//   strict-005  "tell me all about Edward III" (fresh)
//               → "shape=presence person=edward iii keyword=all about"
//   strict-015  "tell me about his parents"  after "tell me about Nathaniel Caleb Parker"
//               → "shape=presence person=nathaniel caleb parker keyword=parents"
// Each is a hole in the deterministic pre-translation layer, not a model
// judgement: no lane claimed the sentence, so the follow-up lane's pronoun
// rewrite handed it to the translator, which read the kin word as a
// keyword. The executor's field guards (ArchivistGraphQuery.asksForRelation /
// asksForABiography, HalliePlaceQuestionTests) already know all three
// shapes but only run on a GRAPH payload — a presence payload never
// reaches them. Pure fixture, no model.

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
1 FAMS @F1@
0 @I2@ INDI
1 NAME Philippa /Mortimer/
1 SEX F
1 BIRT
2 DATE 1375
1 FAMS @F1@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 MARR
2 DATE 1385
0 @I3@ INDI
1 NAME Nathaniel Caleb /Parker/
1 SEX M
1 BIRT
2 DATE 14 JUL 1760
2 PLAC Shrewsbury, Worcester, Massachusetts
1 FAMC @F2@
0 @I4@ INDI
1 NAME Stephen /Parker/ Jr
1 SEX M
1 BIRT
2 DATE 1730
1 FAMS @F2@
0 @I5@ INDI
1 NAME Abigail /Wright/
1 SEX F
1 BIRT
2 DATE 1735
1 FAMS @F2@
0 @F2@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 CHIL @I3@
0 @I6@ INDI
1 NAME Edward III /Plantagenet/
1 SEX M
1 BIRT
2 DATE 13 NOV 1312
2 PLAC Windsor Castle, Berkshire, England
1 DEAT
2 DATE 21 JUN 1377
0 TRLR
"""

@Suite("Strict replay 2026-09-13: family intent never becomes a catalog search")
struct HallieStrictReplayFamilyIntentTests {
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

    /// Two people in memory (a presence answer about a pair): a singular
    /// pronoun has nobody definite to stand for.
    private var memoryWithTwoPeople: Exec.ConversationMemory {
        var memory = Exec.ConversationMemory()
        memory.record(
            intent: .init(originalQuestion: "videos of rick and donna",
                          ast: .presence(.init(people: ["Rick Breen", "Donna Breen"]))),
            result: .init(route: .presence, outcome: .answered, prose: "Two clips.",
                          basisLine: "fixture", queryDescription: "shape=presence",
                          citations: [], catalogPersonName: nil))
        #expect(memory.pronounReferents.count == 2)
        return memory
    }

    // MARK: strict-004 — "whom did he marry"

    @Test func whoDidHeMarryIsASpouseQuestionAboutHim() {
        for q in ["whom did he marry", "who did he marry?", "Whom did he marry?", "and who did she marry",
                  "who did he wed", "who was he married to?"] {
            let pronoun = q.lowercased().contains(" she ") ? "She" : "He"
            #expect(Q.detect(q) == .kinship(person: pronoun, relation: .spouse, side: nil), Comment(rawValue: q))
        }
        // The typed form is the same intent with a name; it no longer
        // needs the translator either.
        #expect(Q.detect("who did rick marry") == .kinship(person: "Rick", relation: .spouse, side: nil))
        #expect(Q.detect("whom did john hastings marry?") == .kinship(person: "John Hastings", relation: .spouse, side: nil))
        #expect(Q.detect("who was eileen latta married to") == .kinship(person: "Eileen Latta", relation: .spouse, side: nil))
    }

    /// Not claimed: a WHEN question (HallieMarriageDate's), a plural
    /// pronoun (codex #1352), a nested "my" subject, or a longer sentence.
    @Test func marriageSentencesThatAreNotASpouseAskKeepTheirRoad() {
        #expect(Q.detect("when did he marry") == nil)
        #expect(Q.detect("when did rick marry donna") == nil)
        #expect(Q.detect("who did they marry") == nil)
        // (HallieKinshipApposition already reads this one as "my grandmother
        // named Marry" — a pre-existing quirk, not this shape's; pinned only
        // as "not a spouse ask about a pronoun".)
        #expect(Q.detect("who did my grandmother marry") != .kinship(person: "My Grandmother", relation: .spouse, side: nil))
        #expect(Q.detect("who did he marry in that video") == nil)
        #expect(Q.detect("is rick married") == nil)
        #expect(Q.detect("did he marry") == nil)
    }

    @Test func whomDidHeMarryAfterHisBirthplaceNamesHisWife() async throws {
        let memory = try await memoryAfterBiography(of: "john hastings", expecting: "John Hastings")
        for question in ["whom did he marry", "who did he marry?"] {
            guard case .run(let intent) = pre(question, memory: memory) else {
                Issue.record("\(question): expected a kinship intent, got \(pre(question, memory: memory))")
                continue
            }
            #expect(intent.ast == .graph(.init(
                people: ["John Hastings"], operation: .kinship, relation: .spouse, side: nil)),
                Comment(rawValue: "\(question): \(intent.ast)"))
            let result = try await Exec.execute(.init(intent: intent), context: context)
            #expect(result.route == .graph, Comment(rawValue: "\(question): \(result.prose)"))
            #expect(result.outcome == .answered, Comment(rawValue: "\(question): \(result.prose)"))
            #expect(result.prose.contains("Philippa Mortimer"), Comment(rawValue: "\(question): \(result.prose)"))
            #expect(result.queryDescription?.contains("keyword=") != true, Comment(rawValue: result.queryDescription ?? "nil"))
        }
    }

    /// With nobody in memory the pronoun stands for no one: Hallie asks
    /// who, and never searches the catalog for "marry".
    @Test func whoDidHeMarryWithNoSubjectAsksWho() {
        guard case .answer(let result) = pre("who did he marry") else {
            Issue.record("expected a local ask, got \(pre("who did he marry"))")
            return
        }
        #expect(result.route == .graph)
        #expect(result.outcome == .declined)
        #expect(result.prose == HalliePronounContinuity.whoDoYouMean("he"))
    }

    // MARK: strict-005 — "tell me all about Edward III"

    @Test func tellMeAllAboutOpensTheBiographyOfATreePerson() {
        let known: (String) -> Bool = { ["edward iii", "nathaniel caleb parker"].contains($0.lowercased()) }
        for q in ["tell me all about Edward III", "tell me everything about Edward III",
                  "tell me more about Edward III", "Tell me all about Edward III.", "tell us about edward iii"] {
            #expect(HalliePersonFactQuestion.detect(q, isKnownPerson: known)
                    == .init(people: [q.contains("edward iii") ? "edward iii" : "Edward III"], operation: .biography),
                    Comment(rawValue: q))
        }
        // The remainder must be a person: "all about" is never left behind
        // as a keyword, but a non-person remainder is not claimed either.
        #expect(HalliePersonFactQuestion.detect("tell me all about the wedding video", isKnownPerson: known) == nil)
        #expect(HalliePersonFactQuestion.detect("tell me more about the archive", isKnownPerson: known) == nil)
    }

    @Test func tellMeAllAboutEdwardIIIRunsAsAGraphBiography() async throws {
        guard case .run(let intent) = pre("tell me all about Edward III") else {
            Issue.record("expected a biography intent, got \(pre("tell me all about Edward III"))")
            return
        }
        #expect(intent.ast == .graph(.init(people: ["Edward III"], operation: .biography)),
                Comment(rawValue: "\(intent.ast)"))
        let result = try await Exec.execute(.init(intent: intent), context: context)
        #expect(result.route == .graph, Comment(rawValue: result.prose))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("1312"), Comment(rawValue: result.prose))
        #expect(result.queryDescription?.contains("keyword=") != true, Comment(rawValue: result.queryDescription ?? "nil"))
    }

    /// A non-person remainder stays a catalog question for the translator,
    /// with the question untouched.
    @Test func tellMeAllAboutTheWeddingVideoStaysACatalogSearch() {
        #expect(pre("tell me all about the wedding video")
                == .translate(question: "tell me all about the wedding video", playAfterAnswer: false))
    }

    // MARK: strict-015 — "tell me about his parents"

    @Test func tellMeAboutHisKinIsAKinshipQuestionAboutHim() {
        #expect(Q.detect("tell me about his parents") == .kinship(person: "His", relation: .parents, side: nil))
        #expect(Q.detect("Tell me about his parents.") == .kinship(person: "His", relation: .parents, side: nil))
        #expect(Q.detect("tell me about her husband?") == .kinship(person: "Her", relation: .husband, side: nil))
        #expect(Q.detect("tell me all about his children") == .kinship(person: "His", relation: .children, side: nil))
        #expect(Q.detect("and tell me more about her sisters") == .kinship(person: "Her", relation: .sister, side: nil))
        #expect(Q.detect("what do you know about his father") == .kinship(person: "His", relation: .father, side: nil))
        // Pins kept: a NAMED possessor after "tell me about" is not this
        // shape (HallieLineageTests, HallieKinshipSidePhrasingTests), a
        // non-kin noun is not either, and "their" keeps its road.
        #expect(Q.detect("tell me about martha lamson's husband") == nil)
        #expect(Q.detect("tell me about rick's grandson") == nil)
        #expect(Q.detect("tell me about her again") == nil)
        #expect(Q.detect("tell me about his death") == nil)
        #expect(Q.detect("tell me about their children") == nil)
        #expect(Q.detect("tell me about his parents and where they were born") == nil)
    }

    /// The biography lane must not swallow "his parents" as a name, even
    /// with an identity oracle that would accept anything.
    @Test func theBiographyLaneDoesNotTakeAPronounKinPhraseAsAName() {
        let anything: (String) -> Bool = { _ in true }
        #expect(HalliePersonFactQuestion.detect("tell me about his parents", isKnownPerson: anything) == nil)
        #expect(HalliePersonFactQuestion.detect("tell me all about her husband", isKnownPerson: anything) == nil)
    }

    @Test func tellMeAboutHisParentsAfterNathanielsBiographyNamesThem() async throws {
        let memory = try await memoryAfterBiography(of: "nathaniel caleb parker", expecting: "Nathaniel Caleb Parker")
        guard case .run(let intent) = pre("tell me about his parents", memory: memory) else {
            Issue.record("expected a kinship intent, got \(pre("tell me about his parents", memory: memory))")
            return
        }
        #expect(intent.ast == .graph(.init(
            people: ["Nathaniel Caleb Parker"], operation: .kinship, relation: .parents, side: nil)),
            Comment(rawValue: "\(intent.ast)"))
        let result = try await Exec.execute(.init(intent: intent), context: context)
        #expect(result.route == .graph, Comment(rawValue: result.prose))
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("Abigail Wright"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("Stephen Parker"), Comment(rawValue: result.prose))
        #expect(result.queryDescription?.contains("keyword=") != true, Comment(rawValue: result.queryDescription ?? "nil"))
    }

    /// Two people in memory: "his" is ambiguous, so Hallie asks which —
    /// never a catalog search for "parents".
    @Test func tellMeAboutHisParentsWithTwoPeopleInMemoryAsksWhich() {
        let memory = memoryWithTwoPeople
        guard case .answer(let result) = pre("tell me about his parents", memory: memory) else {
            Issue.record("expected a local ask, got \(pre("tell me about his parents", memory: memory))")
            return
        }
        #expect(result.route == .graph)
        #expect(result.outcome == .declined)
        #expect(result.prose == HalliePronounContinuity.whoDoYouMean("his"))
    }
}
