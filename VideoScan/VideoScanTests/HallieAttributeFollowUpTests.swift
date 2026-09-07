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
}
