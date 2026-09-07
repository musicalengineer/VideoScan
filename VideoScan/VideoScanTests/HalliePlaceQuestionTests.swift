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
        #expect(operation(.biography, "where was John Hastings born?") == .birthPlace)
        #expect(operation(.death, "what country did he die in?") == .deathPlace)
        // Unchanged without a place cue, and unchanged with no question at all.
        #expect(operation(.birth, "when was John Hastings born?") == .birth)
        #expect(operation(.biography, "tell me about John Hastings") == .biography)
        let payload = ArchivistQueryAST.Graph(people: ["x"], operation: .birth)
        #expect(ArchivistGraphQuery(payload).operation == .birth)
    }
}
