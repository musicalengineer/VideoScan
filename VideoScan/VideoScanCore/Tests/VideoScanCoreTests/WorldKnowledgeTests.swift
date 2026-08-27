// WorldKnowledgeTests.swift
// The dated-world-facts table and the medium-specific feasibility rule
// (Rick 2026-08-26: "there can be no photo of anyone who died before
// 1820, or certainly 1800"; codex gate 2026-08-26: the cutoff must be
// each medium's EARLIEST year, a birth-only guess is not "can't", and a
// video ask must consult the film fact). Pure.

import Testing
@testable import VideoScanCore

struct WorldKnowledgeTests {
    typealias F = WorldKnowledge.MediumFeasibility

    // MARK: Table integrity

    @Test func tableHasNoDuplicateIDs() {
        let ids = WorldKnowledge.facts.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.isEmpty)
    }

    @Test func everyFactHasAYearSourceAndSpokenClause() {
        for fact in WorldKnowledge.facts {
            #expect((1800...2100).contains(fact.years.lowerBound), "\(fact.id) year")
            #expect(fact.years.upperBound >= fact.years.lowerBound, "\(fact.id) range")
            #expect(fact.earliestYear == fact.years.lowerBound, "\(fact.id) earliest = lower bound")
            #expect(!fact.source.trimmingCharacters(in: .whitespaces).isEmpty, "\(fact.id) source")
            #expect(!fact.spokenClause.isEmpty, "\(fact.id) spoken clause")
            #expect(!fact.statement.isEmpty, "\(fact.id) statement")
            #expect(WorldKnowledge.fact(fact.id) == fact)
        }
        #expect(WorldKnowledge.fact("nope") == nil)
    }

    @Test func eachMediumAnchorsOnItsOwnEarliestYear() {
        #expect(WorldKnowledge.Medium.photograph.earliestYear == 1838)
        #expect(WorldKnowledge.Medium.film.earliestYear == 1888)
        #expect(WorldKnowledge.Medium.soundRecording.earliestYear == 1877)
        #expect(WorldKnowledge.Medium.photograph.fact.years == 1838...1839)
        #expect(WorldKnowledge.Medium.photograph.fact.spokenClause == "photography begins in 1838")
        #expect(WorldKnowledge.Medium.film.fact.spokenClause == "motion pictures begin in 1888")
        #expect(WorldKnowledge.Medium.soundRecording.fact.spokenClause == "sound recording begins in 1877")
        // The photography namespace is a view onto the same fact.
        #expect(WorldKnowledge.photography.year == 1838)
        #expect(WorldKnowledge.photography.firstPersonInPhotograph == WorldKnowledge.Medium.photograph.fact)
    }

    // MARK: Boundaries per medium — the cutoff is the EARLIEST year

    @Test func photographBoundary() {
        let photo = WorldKnowledge.Medium.photograph.fact
        #expect(F.assess(birthYear: 1760, deathYear: 1837, medium: .photograph) == .impossible(photo))
        #expect(F.assess(birthYear: 1760, deathYear: 1838, medium: .photograph) == .possible)
        #expect(F.assess(birthYear: 1760, deathYear: 1839, medium: .photograph) == .possible)
        #expect(F.assess(birthYear: nil, deathYear: 1737, medium: .photograph) == .impossible(photo))
        // A recorded death wins over an early birth (a 95-year life).
        #expect(F.assess(birthYear: 1750, deathYear: 1845, medium: .photograph) == .possible)
    }

    @Test func filmBoundary() {
        let film = WorldKnowledge.Medium.film.fact
        #expect(F.assess(birthYear: nil, deathYear: 1850, medium: .film) == .impossible(film))
        #expect(F.assess(birthYear: nil, deathYear: 1887, medium: .film) == .impossible(film))
        #expect(F.assess(birthYear: nil, deathYear: 1888, medium: .film) == .possible)
        #expect(F.assess(birthYear: nil, deathYear: 1895, medium: .film) == .possible)
        // d. 1850: a photograph IS possible even though film is not.
        #expect(F.assess(birthYear: nil, deathYear: 1850, medium: .photograph) == .possible)
    }

    @Test func soundRecordingBoundary() {
        let sound = WorldKnowledge.Medium.soundRecording.fact
        #expect(F.assess(birthYear: nil, deathYear: 1876, medium: .soundRecording) == .impossible(sound))
        #expect(F.assess(birthYear: nil, deathYear: 1877, medium: .soundRecording) == .possible)
    }

    @Test func unknownDeathIsNeverImpossible() {
        for medium in WorldKnowledge.Medium.allCases {
            #expect(F.assess(birthYear: 1600, deathYear: nil, medium: medium) == .unknown, "\(medium)")
            #expect(F.assess(birthYear: 1750, deathYear: nil, medium: medium) == .unknown, "\(medium)")
            #expect(F.assess(birthYear: nil, deathYear: nil, medium: medium) == .unknown, "\(medium)")
            #expect(!F.assess(birthYear: 1600, deathYear: nil, medium: medium).isImpossible)
        }
        // codex #708: a birth AT OR AFTER the earliest year proves the
        // medium existed in the person's lifetime — .possible without a
        // death year; a birth before it stays .unknown.
        #expect(F.assess(birthYear: 1850, deathYear: nil, medium: .photograph) == .possible)
        #expect(F.assess(birthYear: 1838, deathYear: nil, medium: .photograph) == .possible)
        #expect(F.assess(birthYear: 1800, deathYear: nil, medium: .photograph) == .unknown)
        #expect(F.assess(birthYear: 1850, deathYear: nil, medium: .film) == .unknown, "b. 1850 < film 1888")
        #expect(F.assess(birthYear: 1888, deathYear: nil, medium: .film) == .possible)
        #expect(F.assess(birthYear: 1850, deathYear: nil, medium: .soundRecording) == .unknown)
        #expect(F.assess(birthYear: 1877, deathYear: nil, medium: .soundRecording) == .possible)
        // A death before the earliest year still wins over any birth.
        #expect(F.assess(birthYear: 1850, deathYear: 1870, medium: .film).isImpossible)
        // The legacy convenience agrees: no veto without a death year.
        #expect(WorldKnowledge.photography.canHavePhotograph(birthYear: 1600, deathYear: nil) == true)
        #expect(WorldKnowledge.photography.canHavePhotograph(birthYear: nil, deathYear: 1837) == false)
        #expect(WorldKnowledge.photography.canHavePhotograph(birthYear: nil, deathYear: 1838) == true)
    }

    // MARK: Person overload, notes and honest lines

    private static let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Nathaniel /Parker/ Sr
    1 SEX M
    1 BIRT
    2 DATE 16 MAY 1651
    1 DEAT
    2 DATE 7 DEC 1737
    0 @I2@ INDI
    1 NAME Thankful /Pratt/
    1 SEX F
    1 BIRT
    2 DATE 6 OCT 1761
    1 DEAT
    2 DATE 1 NOV 1849
    0 @I3@ INDI
    1 NAME Early /Bird/
    1 SEX F
    1 BIRT
    2 DATE ABT 1700
    0 @I4@ INDI
    1 NAME No /Dates/
    0 @I5@ INDI
    1 NAME Mid /Century/
    1 SEX F
    1 BIRT
    2 DATE 1790
    1 DEAT
    2 DATE 1850
    0 TRLR
    """)

    @Test func personOverloadAndNotes() {
        typealias P = WorldKnowledge.photography
        let nathaniel = Self.graph.people["@I1@"]!
        let thankful = Self.graph.people["@I2@"]!
        let early = Self.graph.people["@I3@"]!
        let undated = Self.graph.people["@I4@"]!
        let mid = Self.graph.people["@I5@"]!
        #expect(F.assess(person: nathaniel, medium: .photograph).isImpossible)
        #expect(F.assess(person: thankful, medium: .photograph) == .possible)
        #expect(F.assess(person: early, medium: .photograph) == .unknown)
        #expect(F.assess(person: undated, medium: .film) == .unknown)
        #expect(F.assess(person: mid, medium: .photograph) == .possible)
        #expect(F.assess(person: mid, medium: .film).isImpossible)
        #expect(F.assess(person: mid, medium: .soundRecording).isImpossible)

        #expect(P.impossibilityNote(person: nathaniel, medium: .photograph) == "d. 1737 < photograph 1838")
        #expect(P.impossibilityNote(person: nathaniel, medium: .film) == "d. 1737 < film 1888")
        #expect(P.impossibilityNote(person: mid, medium: .photograph) == nil)
        #expect(P.impossibilityNote(person: mid, medium: .film) == "d. 1850 < film 1888")
        #expect(P.impossibilityNote(person: early, medium: .photograph) == nil)
        #expect(P.impossibilityNote(person: thankful, medium: .photograph) == nil)
    }

    @Test func honestLinesCiteTheMediumsOwnFact() {
        typealias P = WorldKnowledge.photography
        let nathaniel = Self.graph.people["@I1@"]!
        let early = Self.graph.people["@I3@"]!
        let mid = Self.graph.people["@I5@"]!
        let thankful = Self.graph.people["@I2@"]!

        #expect(P.impossibilityLine(person: nathaniel, medium: .photograph)
                == "Nathaniel Parker Sr died in 1737, about a century before photography begins in 1838 — there can’t be a photograph of him. If the family has a painting, engraving, or gravestone photo, put it in his People folder and I’ll show it.")
        #expect(P.impossibilityLine(person: nathaniel, medium: .film)
                == "Nathaniel Parker Sr died in 1737, about a century before motion pictures begin in 1888 — there can’t be film of him. There can’t be a photograph either; a painting, engraving, or gravestone photo in his People folder is the best the family can do, and I’ll show it.")
        // d. 1850: film is out (decades before 1888) but a photograph is not.
        #expect(P.impossibilityLine(person: mid, medium: .film)
                == "Mid Century died in 1850, decades before motion pictures begin in 1888 — there can’t be film of her. If the family has a photograph of her, put it in her People folder and I’ll show it.")
        #expect(P.impossibilityLine(person: mid, medium: .soundRecording)
                == "Mid Century died in 1850, decades before sound recording begins in 1877 — there can’t be a recording of her. If the family has a photograph of her, put it in her People folder and I’ll show it.")
        #expect(P.impossibilityLine(person: mid, medium: .photograph) == nil)
        // Unknown death: no line for any medium.
        for medium in WorldKnowledge.Medium.allCases {
            #expect(P.impossibilityLine(person: early, medium: medium) == nil, "\(medium)")
        }
        #expect(P.impossibilityLine(person: thankful, medium: .photograph) == nil)
    }
}
