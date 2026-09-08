// HallieAttributeFollowUpTests.swift
// Rick, live 2026-09-07, twice in one session:
//
//   "not in videos, in family tree"  → "I can only drop a person, not a topic
//                                       word — ask it fresh"
//   "what country?"                  → 688 videos mentioning "country"
//
// A follow-up could edit the previous query's FILTERS but could not change
// which FIELD of the same subject was being asked, so a two-word question
// about the person on screen became a catalog search.

import Foundation
import Testing
@testable import VideoScan

@Suite("A follow-up may ask a different field of the same person")
struct HallieAttributeFollowUpTests {
    private typealias Resolver = ArchivistFollowUpResolver

    private func snapshot(_ people: [String],
                          _ operation: ArchivistQueryAST.Graph.Operation = .biography)
    -> Resolver.Snapshot {
        Resolver.Snapshot(
            ast: .graph(ArchivistQueryAST.Graph(people: people, operation: operation)),
            items: [])
    }

    private func resolve(_ text: String, after people: [String] = ["John Hastings"],
                         known: @escaping (String) -> Bool = { _ in false })
    -> Resolver.Resolution? {
        Resolver.graphAttributeResolution(
            text, words: Resolver.normalizedWords(text),
            snapshot: snapshot(people), isKnownPerson: known)
    }

    private func operation(_ resolution: Resolver.Resolution?)
    -> ArchivistQueryAST.Graph.Operation? {
        guard case .localQuery(.graph(let g))? = resolution else { return nil }
        return g.operation
    }

    private func people(_ resolution: Resolver.Resolution?) -> [String]? {
        guard case .localQuery(.graph(let g))? = resolution else { return nil }
        return g.people
    }

    /// THE TURN. "what country?" keeps the subject and asks for the place.
    @Test func rickTwoWordFollowUp() {
        let r = resolve("what country?")
        #expect(operation(r) == .birthPlace)
        #expect(people(r) == ["John Hastings"], "the subject is carried, not re-asked")
    }

    @Test func theOtherFieldFollowUps() {
        #expect(operation(resolve("where was he born?")) == .birthPlace)
        #expect(operation(resolve("what city?")) == .birthPlace)
        #expect(operation(resolve("where did he die?")) == .deathPlace)
        #expect(operation(resolve("where is he buried?")) == .deathPlace)
        #expect(operation(resolve("what year was he born?")) == .birth)
        #expect(operation(resolve("when did he die?")) == .death)
    }

    /// THE FULL SUITE CAUGHT THESE. A bare time word, or any sentence naming
    /// a relation, must be left to the pronoun-continuity path, which
    /// rewrites the pronoun ("when did Rick get married") and translates —
    /// a better answer than this resolver guessing "birth" from the word
    /// "when". Both were live regressions in the first version.
    @Test func timeWordsAloneAndRelationsAreLeftToTranslation() {
        #expect(resolve("when did he get married") == nil, "married is a relation, not a date field")
        #expect(resolve("when?") == nil, "born, died, married or moved — the sentence does not say")
        #expect(resolve("what year?") == nil)
        #expect(resolve("how old was he?") == nil)
        #expect(resolve("who were his parents?") == nil, "a relation, not a field of this resolver")
        // codex #1181, inherited from 31cd14df: TWO relations made
        // asksForRelation return nil, the sentence was seven words, and it
        // was claimed as the PREVIOUS person's birthplace.
        #expect(resolve("where were his mother and father born?") == nil)
        #expect(resolve("where was his father born?") == nil)
        // And the ones it SHOULD still claim are unaffected.
        #expect(operation(resolve("where was he born?")) == .birthPlace)
        #expect(operation(resolve("what country?")) == .birthPlace)
    }

    /// NAMING SOMEONE makes it a fresh question, not a follow-up.
    @Test func aNamedPersonIsNotAFollowUp() {
        #expect(resolve("what country was Donna born in?",
                        known: { $0 == "donna" }) == nil)
    }

    /// A long sentence is a question in its own right and still translates.
    @Test func aFullSentenceStillTranslates() {
        #expect(resolve("tell me everything about where all the people in this family were born") == nil)
    }

    /// Nothing to follow up on, or a previous turn that was not about people.
    @Test func itNeedsAPriorGraphSubject() {
        #expect(Resolver.graphAttributeResolution(
            "what country?", words: Resolver.normalizedWords("what country?"),
            snapshot: nil, isKnownPerson: { _ in false }) == nil)
        let empty = Resolver.Snapshot(
            ast: .graph(ArchivistQueryAST.Graph(people: [], operation: .biography)), items: [])
        #expect(Resolver.graphAttributeResolution(
            "what country?", words: Resolver.normalizedWords("what country?"),
            snapshot: empty, isKnownPerson: { _ in false }) == nil)
    }

    /// A follow-up that asks no field at all is left to the refinement path,
    /// which is what it is for.
    @Test func aNonFieldFollowUpIsNotClaimed() {
        #expect(resolve("show more") == nil)
        #expect(resolve("play the first one") == nil)
        #expect(resolve("and in the 90s?") == nil)
    }

    /// FIRST STRICT REPLAY, 2026-09-07. "what country?" straight after a graph
    /// answer about John Hastings reached the translator with 'me' as the
    /// subject and came back as Rick's biography — the general-knowledge
    /// lane claimed the bare fragment three lanes before the follow-up
    /// resolver ran. The whole pre-translation must now yield the local
    /// graph query about the previous person.
    @Test func aBareFieldFollowUpOutranksTheGeneralLane() {
        var memory = HallieTurnExecutor.ConversationMemory()
        let born = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "John Hastings 3rd Earl of Pembroke was born 11 October 1372.",
            basisLine: "Basis: GEDCOM", queryDescription: "shape=graph operation=birth person=john hastings",
            citations: [], catalogPersonName: nil)
        memory.record(intent: .init(originalQuestion: "what country was John Hastings born in?",
                                    ast: .graph(.init(people: ["john hastings"], operation: .birth))),
                      result: born)
        let pre = HallieTurnExecutor.preTranslation(
            question: "what country?", playAfterAnswer: false,
            memory: memory, isKnownPerson: { _ in false })
        guard case .run(let intent) = pre,
              case .graph(let g) = intent.ast else {
            Issue.record("expected a local graph query, got \(pre)"); return
        }
        #expect(g.people == ["john hastings"])
        #expect(g.operation == .birthPlace)
    }
}

/// THE TREE CALLS COMMON WORDS PEOPLE (first strict replay, 2026-09-07).
/// On Rick's 39,250-person tree isKnownPerson("country") is true (the loose
/// matcher resolves it to "William Culpeper of Preston Hall"), and so are
/// "born" and "he" through narrative text stored in NAME records. A stub
/// that says the same keeps the resolver honest about which words it may
/// treat as a name.
@Suite struct HallieFollowUpJunkNameTests {
    private let junkNames: (String) -> Bool = { ["country", "born", "he", "edward"].contains($0) }
    private var snapshot: ArchivistFollowUpResolver.Snapshot {
        ArchivistFollowUpResolver.Snapshot(
            ast: .graph(.init(people: ["john hastings"], operation: .birth)),
            items: [], shownCount: 0, totalMatchCount: 0, chain: nil)
    }
    private func resolve(_ q: String) -> ArchivistFollowUpResolver.Resolution? {
        ArchivistFollowUpResolver.graphAttributeResolution(
            q, words: ArchivistFollowUpResolver.normalizedWords(q),
            snapshot: snapshot, isKnownPerson: junkNames)
    }

    @Test func aFieldWordIsNeverANameWhateverTheTreeSays() throws {
        guard case .localQuery(.graph(let g))? = resolve("what country?") else {
            Issue.record("what country? refused: \(String(describing: resolve("what country?")))"); return
        }
        #expect(g.people == ["john hastings"])
        #expect(g.operation == .birthPlace)
        guard case .localQuery(.graph(let h))? = resolve("where was he born?") else {
            Issue.record("where was he born? refused"); return
        }
        #expect(h.operation == .birthPlace)
    }

    @Test func aRealNameStillMakesAFreshQuestion() {
        #expect(resolve("where was edward born?") == nil)
    }
}

