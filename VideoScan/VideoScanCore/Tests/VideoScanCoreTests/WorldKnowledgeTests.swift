// WorldKnowledgeTests.swift
// The dated-world-facts table and the photography floor (Rick 2026-08-26:
// "there can be no photo of anyone who died before 1820, or certainly
// 1800"). Pure.

import Testing
@testable import VideoScanCore

struct WorldKnowledgeTests {

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
            #expect(!fact.source.trimmingCharacters(in: .whitespaces).isEmpty, "\(fact.id) source")
            #expect(!fact.spokenClause.isEmpty, "\(fact.id) spoken clause")
            #expect(!fact.statement.isEmpty, "\(fact.id) statement")
            #expect(WorldKnowledge.fact(fact.id) == fact)
        }
        #expect(WorldKnowledge.fact("nope") == nil)
    }

    @Test func photographyAnchorsOn1839() {
        #expect(WorldKnowledge.photography.year == 1839)
        #expect(WorldKnowledge.photography.firstPersonInPhotograph.years == 1838...1839)
        #expect(WorldKnowledge.photography.firstPersonInPhotograph.spokenClause == "photography begins in 1839")
    }

    // MARK: Rule boundaries

    @Test func deathYearBoundaries() {
        typealias P = WorldKnowledge.photography
        #expect(P.canHavePhotograph(birthYear: 1760, deathYear: 1838) == false)
        #expect(P.canHavePhotograph(birthYear: 1760, deathYear: 1839) == true)
        #expect(P.canHavePhotograph(birthYear: 1760, deathYear: 1840) == true)
        // A recorded death wins over an early birth (a 95-year life).
        #expect(P.canHavePhotograph(birthYear: 1750, deathYear: 1845) == true)
        #expect(P.canHavePhotograph(birthYear: nil, deathYear: 1737) == false)
    }

    @Test func unknownDeathFallsBackToBirth() {
        typealias P = WorldKnowledge.photography
        #expect(P.canHavePhotograph(birthYear: 1750, deathYear: nil) == false)
        #expect(P.canHavePhotograph(birthYear: 1759, deathYear: nil) == false)
        #expect(P.canHavePhotograph(birthYear: 1760, deathYear: nil) == true)
        #expect(P.canHavePhotograph(birthYear: 1800, deathYear: nil) == true)
        // No dates at all: never suppress on a guess.
        #expect(P.canHavePhotograph(birthYear: nil, deathYear: nil) == true)
    }

    @Test func personOverloadAndNotes() {
        let graph = GedcomFamilyGraph(gedcomText: """
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
        0 TRLR
        """)
        typealias P = WorldKnowledge.photography
        let nathaniel = graph.people["@I1@"]!
        let thankful = graph.people["@I2@"]!
        let early = graph.people["@I3@"]!
        let undated = graph.people["@I4@"]!
        #expect(P.canHavePhotograph(person: nathaniel) == false)
        #expect(P.canHavePhotograph(person: thankful) == true)
        #expect(P.canHavePhotograph(person: early) == false)
        #expect(P.canHavePhotograph(person: undated) == true)
        #expect(P.impossibilityNote(person: nathaniel) == "d. 1737")
        #expect(P.impossibilityNote(person: early) == "b. 1700")
        #expect(P.impossibilityNote(person: thankful) == nil)

        let photo = P.impossibilityLine(person: nathaniel, medium: .photograph)!
        #expect(photo == "Nathaniel Parker Sr died in 1737, about a century before photography begins in 1839 — there can’t be a photograph. If the family has a painting, engraving, or gravestone photo, put it in his People folder and I’ll show it.")
        let film = P.impossibilityLine(person: nathaniel, medium: .film)!
        #expect(film.hasPrefix("Nathaniel Parker Sr died in 1737, about a century before photography begins in 1839, and motion pictures begin in 1888 — there can’t be film of him either."))
        #expect(P.impossibilityLine(person: early, medium: .photograph)?.hasPrefix("Early Bird was born in 1700, about a century before") == true)
        #expect(P.impossibilityLine(person: early, medium: .photograph)?.contains("her People folder") == true)
        #expect(P.impossibilityLine(person: thankful, medium: .photograph) == nil)
    }
}
