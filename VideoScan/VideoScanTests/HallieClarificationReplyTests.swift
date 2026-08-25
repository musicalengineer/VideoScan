// HallieClarificationReplyTests.swift
// Typed replies to "which one do you mean?" resolve deterministically
// (Rick, live 2026-08-25: "the one born in 1785" reached the language
// model — and the model was down).

import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Clarification replies — words resolve locally")
struct HallieClarificationReplyTests {
    private func candidate(_ id: String, _ name: String, _ label: String) -> HallieTurnExecutor.Candidate {
        .init(id: .gedcomPersonID(id), canonicalName: name, label: label)
    }
    private var parkers: [HallieTurnExecutor.Candidate] {
        [candidate("@I1@", "Nathaniel Parker", "Nathaniel Parker (born 1785, Framingham)"),
         candidate("@I2@", "Nathaniel Parker", "Nathaniel Parker (born 1651, Reading)")]
    }
    private func pick(_ reply: String) -> String? {
        if case .gedcomPersonID(let id)? = HallieTurnExecutor.clarificationSelection(reply, from: parkers) { return id }
        return nil
    }

    @Test func numbersAndExactNamesStillWork() {
        #expect(pick("2") == "@I2@")
        #expect(pick("Nathaniel Parker (born 1651, Reading)") == "@I2@")
        #expect(pick("Nathaniel Parker") == nil)   // ambiguous name → re-ask
    }

    @Test func birthYearSelects() {
        #expect(pick("the one born in 1785") == "@I1@")
        #expect(pick("1651 one") == "@I2@")
        #expect(pick("the one born in 1900") == nil)   // matches nobody
    }

    @Test func relativeAgeAndOrdinalsSelect() {
        #expect(pick("the older one") == "@I2@")
        #expect(pick("the earliest") == "@I2@")
        #expect(pick("the younger one") == "@I1@")
        #expect(pick("the first one") == "@I1@")
        #expect(pick("the last one") == "@I2@")
        #expect(pick("neither, tell me about Donna") == nil)
    }

    @Test func negatedCompetingAndMismatchedDescriptorsNeverGuess() {
        #expect(pick("not the one born in 1785") == nil)
        #expect(pick("not the first one") == nil)
        #expect(pick("older or younger") == nil)
        #expect(pick("the first or last") == nil)

        let mixedDates = [
            candidate("@B@", "Alex Parker", "Alex Parker (born 1785, died 1850)"),
            candidate("@D@", "Alex Parker", "Alex Parker (born 1750, died 1785)"),
        ]
        #expect(HallieTurnExecutor.clarificationSelection(
            "the one born in 1785", from: mixedDates) == .gedcomPersonID("@B@"))
        #expect(HallieTurnExecutor.clarificationSelection(
            "the one who died in 1785", from: mixedDates) == .gedcomPersonID("@D@"))

        let duplicateBirthYear = [
            candidate("@1@", "A Parker", "A Parker (born 1785)"),
            candidate("@2@", "B Parker", "B Parker (born 1785)"),
        ]
        #expect(HallieTurnExecutor.clarificationSelection(
            "born in 1785", from: duplicateBirthYear) == nil)
    }
}
