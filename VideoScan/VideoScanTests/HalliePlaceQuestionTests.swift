// HalliePlaceQuestionTests.swift
// Rick, live 2026-09-07, four times in a row:
//
//   Q: what country was John Hastings born in?
//   A: John Hastings 3rd Earl of Pembroke was born 11 October 1372.
//
// The record HAS the place — `2 PLAC Kenilworth, Warwickshire, England` — and
// the Family Tree view draws it. The executor has a `.birthPlace` route whose
// own comment says handing back the birthday instead "is what 'where was
// Eileen Latta born' used to do". Nothing downstream was broken: the model
// chose `birth` for a sentence asking where.

import Foundation
import Testing
@testable import VideoScan

@Suite("A place question gets the place operation")
struct HalliePlaceQuestionTests {
    private let asks = ArchivistGraphQuery.asksForAPlace

    /// The exact sentences Rick typed.
    @Test func rickSentences() {
        #expect(asks("what country was John Hastings born in?"))
        #expect(asks("tell me what country was he born in?"))
        #expect(asks("where  was John Hastings born and what country?"))
        #expect(asks("what country?"))
    }

    @Test func theOtherWaysPeopleAskWhere() {
        #expect(asks("where was Eileen Latta born"))
        #expect(asks("where were my grandparents born"))
        #expect(asks("what city was he born in"))
        #expect(asks("which town did she come from"))
        #expect(asks("what was his birthplace"))
        #expect(asks("what is her place of birth"))
        #expect(asks("he was born in what country"))
        #expect(asks("where is he buried"))
        // "where" separated from its verb by the subject — the ordering case
        // this suite caught before it shipped.
        #expect(asks("tell me about where he was born"))
        #expect(asks("do you know where Mary Catherine O'Connor was born"))
    }

    /// A DATE question must not be stolen — this is the whole risk of the
    /// correction, and the reason it is narrow.
    @Test func dateQuestionsAreLeftAlone() {
        #expect(!asks("when was John Hastings born"))
        #expect(!asks("what year was he born"))
        #expect(!asks("how old was he when he died"))
        #expect(!asks("what date did she die"))
    }

    /// And an ordinary biography ask keeps its route.
    @Test func biographyQuestionsAreLeftAlone() {
        #expect(!asks("tell me about John Hastings"))
        #expect(!asks("who is Edward III of Windsor King of England"))
        #expect(!asks("how am I related to Edward III"))
        #expect(!asks("tell me about his parents"))
    }

    /// The operation actually moves — birth → birthPlace, death → deathPlace,
    /// and a biography ask that is plainly a place ask moves too.
    @Test func theOperationIsCorrected() throws {
        func operation(_ op: ArchivistQueryAST.Graph.Operation,
                       _ question: String) -> ArchivistGraphQuery.Operation {
            let payload = ArchivistQueryAST.Graph(people: ["John Hastings"], operation: op)
            return ArchivistGraphQuery(payload, question: question).operation
        }
        #expect(operation(.birth, "what country was John Hastings born in?") == .birthPlace)
        // THE REGRESSION. Rick hit this minutes after the first version
        // shipped: the model returned `.death` for a sentence containing
        // "born", and deferring to it answered with the man's death.
        #expect(operation(.death, "what country was John Hastings born in?") == .birthPlace)
        #expect(operation(.death, "where was he born?") == .birthPlace)
        #expect(operation(.deathPlace, "where was he born?") == .birthPlace)
        #expect(operation(.birth, "where is he buried?") == .deathPlace)
        #expect(operation(.biography, "where did he die?") == .deathPlace)
        // BOTH cues present: the words do not settle it, so the guard does
        // not override — the model's reading stands (codex #1181: "born
        // wins" forced birthPlace where deathPlace was asked).
        #expect(operation(.death, "where was he born before he died in France?") == .death)
        #expect(operation(.deathPlace, "where did he die after being born in France?") == .deathPlace)
        #expect(operation(.birthPlace, "where did he die after being born in France?") == .birthPlace)
        #expect(operation(.biography, "where was John Hastings born?") == .birthPlace)
        #expect(operation(.death, "what country did he die in?") == .deathPlace)
        // Unchanged without a place cue, and unchanged with no question at all.
        #expect(operation(.birth, "when was John Hastings born?") == .birth)
        #expect(operation(.biography, "tell me about John Hastings") == .biography)
        let payload = ArchivistQueryAST.Graph(people: ["x"], operation: .birth)
        #expect(ArchivistGraphQuery(payload).operation == .birth)
    }

    /// Rick, live 2026-09-07: "whom did he marry", "who was his spouse" and
    /// "who did john hastings marry?" ALL came back with the man's death.
    /// After twenty turns about a dead earl the model answered `death` for
    /// everything, and nothing deterministic disagreed.
    @Test func aRelationTheSentenceNamesIsNotLeftToTheModel() {
        let asks: (String) -> ArchivistGraphQuery.Relation? = { ArchivistGraphQuery.asksForRelation($0) }
        #expect(asks("whom did he marry") == .spouse)
        #expect(asks("who was his spouse") == .spouse)
        #expect(asks("who did john hastings marry?") == .spouse)
        #expect(asks("tell me about his parents") == .parents)
        #expect(asks("tell me about the grandparents of Nathaniel Caleb Parker") == .grandparents)
        #expect(asks("who were his children") == .children)
        #expect(asks("did he have any brothers") == .brother)
        #expect(asks("who was his mother") == .mother)
    }

    /// codex #1181: a relative MENTIONED as the subject of a field ask is not a
    /// relation REQUEST. "when was his father born?" asks a date; forcing
    /// kinship/father answered "who is his father" — the grandfather's name in
    /// place of the father's birthday. Nested subjects are left to the model.
    @Test func aRelativeAsTheSubjectOfAFieldAskIsNotForced() {
        func query(_ op: ArchivistQueryAST.Graph.Operation,
                   _ question: String) -> ArchivistGraphQuery {
            ArchivistGraphQuery(
                ArchivistQueryAST.Graph(people: ["John Hastings"], operation: op),
                question: question)
        }
        let fatherBorn = query(.birth, "when was his father born?")
        #expect(fatherBorn.operation == .birth)
        #expect(fatherBorn.relation == nil)
        let fatherWhere = query(.birth, "where was his father born")
        #expect(fatherWhere.operation == .birth, "a nested subject is not this route's to express")
        #expect(fatherWhere.relation == nil)
        #expect(query(.death, "how old was his mother when she died").relation == nil)
        // The genuine relation REQUESTS are still claimed.
        #expect(query(.death, "who was his father").relation == .father)
        #expect(query(.death, "whom did he marry").relation == .spouse)
    }

    /// Ambiguous or absent: left to the model rather than guessed at.
    @Test func twoRelationsOrNoneIsLeftAlone() {
        let asks: (String) -> ArchivistGraphQuery.Relation? = { ArchivistGraphQuery.asksForRelation($0) }
        #expect(asks("tell me about his mother and father") == nil, "two relations named")
        #expect(asks("tell me about John Hastings") == nil)
        #expect(asks("where was he born") == nil)
        #expect(asks("when did he die") == nil)
    }

    /// The operation moves to kinship and carries the relation.
    @Test func theRelationReachesTheQuery() {
        func query(_ op: ArchivistQueryAST.Graph.Operation,
                   _ question: String) -> ArchivistGraphQuery {
            ArchivistGraphQuery(
                ArchivistQueryAST.Graph(people: ["John Hastings"], operation: op),
                question: question)
        }
        let spouse = query(.death, "whom did he marry")
        #expect(spouse.operation == .kinship)
        #expect(spouse.relation == .spouse)

        let parents = query(.biography, "tell me about his parents")
        #expect(parents.operation == .kinship)
        #expect(parents.relation == .parents)

        // A place question is still a place question, not a relation.
        #expect(query(.death, "where was he born?").operation == .birthPlace)
        // And an ordinary biography ask is untouched.
        let plain = query(.biography, "tell me about John Hastings")
        #expect(plain.operation == .biography)
        #expect(plain.relation == nil)
    }

    /// Rick, live 2026-09-07: "tell me all about Edward III" came back as
    /// "has passed on and has been resting in peace since 21 June 1377". A
    /// request for the whole person had become a death notice.
    @Test func aRequestForTheWholePersonIsNotADeathNotice() {
        let asks = ArchivistGraphQuery.asksForABiography
        #expect(asks("tell me all about Edward III"))
        #expect(asks("tell me about John Hastings"))
        #expect(asks("tell me more about him"))
        #expect(asks("who is Edward III of Windsor King of England"))
        #expect(asks("who was Nathaniel Caleb Parker"))
        #expect(asks("what do you know about Donna"))
        #expect(asks("describe Stephen Parker"))
        // Not a whole-person ask.
        #expect(!asks("where was he born"))
        #expect(!asks("when did he die"))
        #expect(!asks("how am I related to Edward III"))

        func query(_ op: ArchivistQueryAST.Graph.Operation,
                   _ question: String) -> ArchivistGraphQuery {
            ArchivistGraphQuery(
                ArchivistQueryAST.Graph(people: ["Edward III"], operation: op),
                question: question)
        }
        #expect(query(.death, "tell me all about Edward III").operation == .biography)
        // The narrower guards still win their own sentences.
        #expect(query(.death, "tell me about where he was born").operation == .birthPlace)
        let parents = query(.death, "tell me about his parents")
        #expect(parents.operation == .kinship)
        #expect(parents.relation == .parents)
        // And a genuine death question is still a death question.
        #expect(query(.death, "when did he die").operation == .death)
        // devstral:24b bake-off finding, real: a whole-person opener that
        // names a FIELD is that field's question, not a biography.
        #expect(query(.death, "tell me about his death").operation == .death)
        #expect(query(.birth, "tell me about John Hastings' birth").operation == .birth)
    }
}

/// "tell me about dad" (strict replay, 2026-09-07): the model resolved the
/// subject as person=dad and chose `birth`; the relation guard then read
/// "dad" as a relation ASKED FOR and answered "Richard Harding Breen Sr's
/// father was George Breen" — dad's father, for a question about dad.
@Suite struct HallieRelationGuardSubjectTests {
    @Test func theSubjectsOwnRelativeWordIsNotARequest() {
        #expect(ArchivistGraphQuery.asksForRelation("tell me about dad", subject: ["dad"]) == nil)
        #expect(ArchivistGraphQuery.asksForRelation("tell me about my dad", subject: ["my dad"]) == nil)
        #expect(ArchivistGraphQuery.asksForRelation("tell me about mom", subject: ["mom"]) == nil)
    }

    @Test func aRelativeOfTheSubjectIsStillARequest() {
        #expect(ArchivistGraphQuery.asksForRelation("tell me about his dad", subject: ["rick"]) == .father)
        #expect(ArchivistGraphQuery.asksForRelation("who did dad marry", subject: ["dad"]) == .spouse)
        #expect(ArchivistGraphQuery.asksForRelation("tell me about his parents") == .parents)
    }

    @Test func tellMeAboutDadIsDadsBiography() {
        let q = ArchivistGraphQuery(.init(people: ["dad"], operation: .birth), question: "tell me about dad")
        #expect(q.operation == .biography)
        #expect(q.relation == nil)
    }

    /// The description names the query that ran, and keeps the model's
    /// choice beside it when a guard moved it.
    @Test func theDescriptionNamesTheResolvedQuery() {
        let payload = ArchivistQueryAST.Graph(people: ["john hastings"], operation: .birth)
        let q = ArchivistGraphQuery(payload, question: "what country was John Hastings born in?")
        let d = HallieTurnExecutor.graphQueryDescription(payload, resolved: q)
        #expect(d.contains("operation=birth-place"), Comment(rawValue: d))
        #expect(d.contains("model=birth"), Comment(rawValue: d))
        let same = HallieTurnExecutor.graphQueryDescription(payload, resolved: ArchivistGraphQuery(payload, question: "when was he born"))
        #expect(same == "shape=graph operation=birth person=john hastings", Comment(rawValue: same))
    }
}

