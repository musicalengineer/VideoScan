// HallieNameSuggestionTests.swift
// "Did you mean Judson Lamb?" — typo'd names become a clarification with
// the closest real people, never a silent substitution (Rick 2026-08-24).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Name suggestions — did you mean")
struct HallieNameSuggestionTests {
    private let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Judson /Lamb/
    1 SEX M
    1 BIRT
    2 DATE 1846
    0 @I2@ INDI
    1 NAME Isaac /Damon/
    1 SEX M
    1 BIRT
    2 DATE 1739
    0 @I3@ INDI
    1 NAME Joan /Smyth/
    1 SEX F
    0 @I4@ INDI
    1 NAME Judson /Lamb/
    1 SEX M
    1 BIRT
    2 DATE 1811
    0 TRLR
    """)

    @Test func transposedAndTrailingLetterTyposSuggestTheRealName() {
        let lamb = HallieNameSuggestion.suggest("Jusson Lambe", graph: graph)
        #expect(lamb.map(\.name) == ["Judson Lamb", "Judson Lamb"])   // both Judsons, labels differ
        #expect(lamb.map(\.label).contains("Judson Lamb (born 1846)"))
        let damon = HallieNameSuggestion.suggest("Issaa Damno", graph: graph)
        #expect(damon.first?.name == "Isaac Damon")
    }

    @Test func farOffNamesGetNoSuggestionAndExactMatchesAreNotSuggestions() {
        #expect(HallieNameSuggestion.suggest("Zebulon Quigley", graph: graph).isEmpty)
        #expect(HallieNameSuggestion.suggest("John Smith", graph: graph).first?.name == "Joan Smyth")   // close enough to ASK about
        #expect(HallieNameSuggestion.suggest("Isaac Damon", graph: graph).isEmpty)   // exact → resolver's job
        #expect(HallieNameSuggestion.suggest("J", graph: graph).isEmpty)
    }

    @Test func peopleTabProfilesAreSuggestedToo() {
        let s = HallieNameSuggestion.suggest(
            "Donna Breem", graph: nil,
            profiles: [(stableID: "p1", name: "Donna Breen", aliases: ["Mom"])])
        #expect(s.first?.name == "Donna Breen")
        #expect(s.first?.identity == .profile(stableID: "p1"))
    }

    @Test func editDistanceIsCappedAndCorrect() {
        #expect(HallieNameSuggestion.editDistance("jusson", "judson", limit: 2) == 1)
        #expect(HallieNameSuggestion.editDistance("lambe", "lamb", limit: 2) == 1)
        #expect(HallieNameSuggestion.editDistance("issaa", "isaac", limit: 2) == 2)
        #expect(HallieNameSuggestion.editDistance("abcdef", "xyz", limit: 2) == 3)
    }
}

@MainActor
@Suite("Clarification replies — yes picks a lone suggestion")
struct HallieSuggestionYesTests {
    /// codex #663: the suggestion limit must never split two people who
    /// share a name — offering one Judson Lamb and hiding the other would
    /// quietly resolve a real GEDCOM ambiguity.
    @Test func limitNeverSplitsASameNameGroup() {
        let crowded = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Judson /Lamb/
        1 BIRT
        2 DATE 1846
        0 @I2@ INDI
        1 NAME Judson /Lamb/
        1 BIRT
        2 DATE 1811
        0 @I3@ INDI
        1 NAME Judson /Lamb/
        1 BIRT
        2 DATE 1901
        0 @I4@ INDI
        1 NAME Judson /Lamb/
        1 BIRT
        2 DATE 1930
        0 TRLR
        """)
        let got = HallieNameSuggestion.suggest("Jusson Lambe", graph: crowded, limit: 3)
        #expect(got.count == 4, "all four Judson Lambs are offered even though the limit is 3")

        // …but bounded (codex #675): a pathological tree never becomes an
        // unreadable wall of chips.
        var text = "0 HEAD\n"
        for i in 1...40 { text += "0 @I\(i)@ INDI\n1 NAME Judson /Lamb/\n1 BIRT\n2 DATE \(1700 + i)\n" }
        text += "0 TRLR\n"
        let flood = HallieNameSuggestion.suggest("Jusson Lambe", graph: GedcomFamilyGraph(gedcomText: text), limit: 3)
        #expect(flood.count == HallieNameSuggestion.maxSuggestions)
    }

    /// codex #663: a mixed GEDCOM + People-tab list must have every chip
    /// actionable; the stage used to be taken from the first choice only.
    @Test func mixedSourceSuggestionsAreAllAcceptedByTheirStage() {
        let stage = HallieTurnExecutor.ClarificationStage.suggestedIdentity
        #expect(stage.accepts(.gedcom))
        #expect(stage.accepts(.peopleProfile))
        #expect(!stage.accepts(.cyberBrain))
        #expect(!HallieTurnExecutor.ClarificationStage.gedcomPerson.accepts(.peopleProfile),
                "the narrow stages stay narrow")
    }

    @Test func yesSelectsTheOnlyCandidate() {
        let only = [HallieTurnExecutor.Candidate(id: .gedcomPersonID("@I1@"),
                                                 canonicalName: "Judson Lamb", label: "Judson Lamb (born 1846)")]
        if case .gedcomPersonID(let id)? = HallieTurnExecutor.clarificationSelection("yes", from: only) {
            #expect(id == "@I1@")
        } else { Issue.record("yes did not select the lone candidate") }
        let two = only + [HallieTurnExecutor.Candidate(id: .gedcomPersonID("@I4@"),
                                                       canonicalName: "Judson Lamb", label: "Judson Lamb (born 1811)")]
        #expect(HallieTurnExecutor.clarificationSelection("yes", from: two) == nil)
    }
}
