// HallieSuperlativeTests.swift
// ITEM 1 (live 2026-08-26): "the person in our family tree with the
// oldest birth year" answered with the tree SUMMARY; "the oldest photo of
// the oldest person in the tree" became a transcript search for "oldest
// photo". Superlatives are now a deterministic ranking over the graph:
// the person (ties → up to 3) with the who-is biography sentence, chips,
// and — inside a media ask — the person resolved FIRST. Pure fixture.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Rick 1959 ← Richard Sr 1929–2001 & Eileen Latta 1930–2010
///   Sr ← George 1898–1950 & Muriel Lamb 1899; George ← Patrick 1860–1930
///   (Cork, Ireland) & Hannah Ryan 1860–1940 (Cork, Ireland), married 1885
///   Eileen ← David Latta 1902–1980 (Belfast) & Mary McGill 1904–1998
///   (Glasgow, Scotland); Mary ← Agnes McGill 1880–1975 (Derry, Ireland),
///   three children. Donna 1959 (no parents); Tim 1985.
private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F5@
0 @I2@ INDI
1 NAME Richard /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
1 DEAT
2 DATE 2001
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
1 DEAT
2 DATE 3 MAR 2010
1 FAMC @F3@
1 FAMS @F1@
0 @I4@ INDI
1 NAME David /Latta/
1 SEX M
1 BIRT
2 DATE 1902
2 PLAC Belfast, Ireland
1 DEAT
2 DATE 1980
1 FAMS @F3@
0 @I5@ INDI
1 NAME Mary /McGill/
1 SEX F
1 BIRT
2 DATE 1904
2 PLAC Glasgow, Scotland
1 DEAT
2 DATE 1998
1 FAMC @F4@
1 FAMS @F3@
0 @I6@ INDI
1 NAME Agnes /McGill/
1 SEX F
1 BIRT
2 DATE 1880
2 PLAC Derry, Ireland
1 DEAT
2 DATE 1975
1 FAMS @F4@
0 @I7@ INDI
1 NAME George /Breen/
1 SEX M
1 BIRT
2 DATE 1898
1 DEAT
2 DATE 1950
1 FAMC @F6@
1 FAMS @F2@
0 @I8@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 BIRT
2 DATE 1899
1 FAMS @F2@
0 @I9@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMS @F5@
0 @I10@ INDI
1 NAME Tim /Breen/
1 SEX M
1 BIRT
2 DATE 1985
1 FAMC @F5@
0 @I11@ INDI
1 NAME Kate /McGill/
1 SEX F
1 BIRT
2 DATE 1882
1 FAMC @F4@
0 @I12@ INDI
1 NAME Bridget /McGill/
1 SEX F
1 BIRT
2 DATE 1884
1 FAMC @F4@
0 @I13@ INDI
1 NAME Patrick /Breen/
1 SEX M
1 BIRT
2 DATE 1860
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1930
1 FAMS @F6@
0 @I14@ INDI
1 NAME Hannah /Ryan/
1 SEX F
1 BIRT
2 DATE 1860
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1940
1 FAMS @F6@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 MARR
2 DATE 1955
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 WIFE @I8@
1 MARR
2 DATE 1925
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 MARR
2 DATE 1928
1 CHIL @I3@
0 @F4@ FAM
1 WIFE @I6@
1 CHIL @I5@
1 CHIL @I11@
1 CHIL @I12@
0 @F5@ FAM
1 HUSB @I1@
1 WIFE @I9@
1 CHIL @I10@
0 @F6@ FAM
1 HUSB @I13@
1 WIFE @I14@
1 MARR
2 DATE 1885
1 CHIL @I7@
0 TRLR
"""

@Suite("Superlatives — oldest / youngest / longest-lived / deepest ancestor")
struct HallieSuperlativeTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    private func pre(_ q: String) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }
    private func answer(_ kind: Q.SuperlativeKind, _ scope: Q.SuperlativeScope = .wholeTree) throws -> Exec.Result {
        try #require(HallieLineageAnswer.answer(.superlative(kind: kind, scope: scope), context: context))
    }

    // MARK: Detection

    @Test func theTwoLiveUtterancesAreSuperlatives() {
        #expect(Q.detect("can you find the person in our family tree with the oldest birth year and tell me about them")
                == .superlative(kind: .earliestBorn, scope: .wholeTree))
        #expect(Q.detect("find the oldest photo of the oldest person in the tree")
                == .superlative(kind: .earliestBorn, scope: .wholeTree, media: "photo"))
    }

    @Test func everyKindAndScopeDetects() {
        #expect(Q.detect("who is the oldest person in the family tree") == .superlative(kind: .earliestBorn, scope: .wholeTree))
        #expect(Q.detect("who was born first in the tree") == .superlative(kind: .earliestBorn, scope: .wholeTree))
        #expect(Q.detect("who is the youngest person in the tree") == .superlative(kind: .latestBorn, scope: .wholeTree))
        #expect(Q.detect("who lived the longest") == .superlative(kind: .longestLived, scope: .wholeTree))
        #expect(Q.detect("who in the tree died most recently") == .superlative(kind: .latestDied, scope: .wholeTree))
        #expect(Q.detect("who was the first to marry in the family") == .superlative(kind: .earliestMarried, scope: .wholeTree))
        #expect(Q.detect("who had the most children") == .superlative(kind: .mostChildren, scope: .wholeTree))
        #expect(Q.detect("who had the largest family in the tree") == .superlative(kind: .mostChildren, scope: .wholeTree))
        #expect(Q.detect("who is my deepest ancestor") == .superlative(kind: .deepestAncestor, scope: .ancestorsOf(nil)))
        #expect(Q.detect("who is the farthest back ancestor of rick") == .superlative(kind: .deepestAncestor, scope: .ancestorsOf("Rick")))
        #expect(Q.detect("how far back does my family tree go") == .superlative(kind: .deepestAncestor, scope: .ancestorsOf(nil)))
        #expect(Q.detect("who was the first person born in ireland") == .superlative(kind: .firstBornIn(place: "Ireland"), scope: .wholeTree))
        #expect(Q.detect("who was the first born in scotland") == .superlative(kind: .firstBornIn(place: "Scotland"), scope: .wholeTree))
        // Scopes: surname three ways, ancestors of someone.
        #expect(Q.detect("who is the oldest breen") == .superlative(kind: .earliestBorn, scope: .surname("breen")))
        #expect(Q.detect("the oldest person in the breen family") == .superlative(kind: .earliestBorn, scope: .surname("breen")))
        #expect(Q.detect("the oldest person named mcgill") == .superlative(kind: .earliestBorn, scope: .surname("mcgill")))
        #expect(Q.detect("who is the oldest of rick's ancestors") == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Rick")))
        #expect(Q.detect("who is the oldest of my ancestors") == .superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)))
        #expect(Q.detect("who lived the longest among donna's ancestors") == .superlative(kind: .longestLived, scope: .ancestorsOf("Donna")))
        // Media wrappers.
        #expect(Q.detect("show me a video of the youngest person in the tree") == .superlative(kind: .latestBorn, scope: .wholeTree, media: "video"))
    }

    @Test func notOurs() {
        #expect(Q.detect("who was rick's oldest son") == nil)
        #expect(Q.detect("who is donna's first cousin") == nil)
        #expect(Q.detect("what is the oldest video in the catalog") == nil)
        #expect(Q.detect("show me donna in the 90s") == nil)
        #expect(Q.detect("tell me about David McGill") == nil)
        #expect(Q.detect("show me a photo of Fred Lamb") == .personPhoto(person: "Fred Lamb"))
        #expect(Q.detect("rick's maternal line back 5 generations") == .ancestorLine(person: "Rick", line: .maternal, generations: 5))
    }

    // MARK: Answers

    @Test func earliestBornIsATieOfTwoWithBiographies() throws {
        let r = try answer(.earliestBorn)
        #expect(r.route == .graph)
        #expect(r.outcome == .answered)
        #expect(r.prose.hasPrefix("2 people share the earliest birth year in the family tree (born 1860): "), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Hannah Ryan — born 1860; resting in peace since 1940; married to Patrick Breen; parent of George Breen."))
        #expect(r.prose.contains("Patrick Breen — born 1860; resting in peace since 1930"))
        #expect(r.catalogPersonName == "Hannah Ryan")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I14@", personName: "Hannah Ryan"),
                                     .openFamilyTreePerson(personID: "@I13@", personName: "Patrick Breen")])
        #expect(r.basisLine.contains("Ranked 14 of 14 people in the family tree"))
    }

    @Test func eachKindPicksTheRightPerson() throws {
        #expect(try answer(.latestBorn).prose.hasPrefix("The latest birth year in the family tree is born 1985: Tim Breen"))
        #expect(try answer(.longestLived).prose.hasPrefix("The longest recorded life in the family tree is about 95 years: Agnes McGill — born 1880; resting in peace since 1975"))
        #expect(try answer(.latestDied).prose.hasPrefix("The most recent death in the family tree is died 2010: Eileen Latta"))
        let married = try answer(.earliestMarried)
        #expect(married.prose.hasPrefix("2 people share the earliest recorded marriage in the family tree (married 1885): Hannah Ryan"))
        #expect(try answer(.mostChildren).prose.hasPrefix("The most recorded children in the family tree is 3 children: Agnes McGill"))
        let deepest = try answer(.deepestAncestor, .ancestorsOf(nil))
        // Patrick, Hannah and Agnes all sit three generations above Rick.
        #expect(deepest.prose.hasPrefix("3 people share the deepest recorded ancestor in Rick Breen’s ancestors (3 generations back): Agnes McGill"), Comment(rawValue: deepest.prose))
        #expect(deepest.offeredActions.count == 3)
        // "oldest ancestor" is the earliest-born ancestor, not the deepest.
        #expect(Q.detect("who is my oldest ancestor") == .superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)))
        let scotland = try answer(.firstBornIn(place: "Scotland"))
        #expect(scotland.prose.hasPrefix("The earliest birth in Scotland in the family tree is born 1904: Mary McGill"))
        #expect(scotland.prose.hasSuffix("The record says Glasgow, Scotland."))
    }

    @Test func scopesNarrowThePool() throws {
        let breen = try answer(.earliestBorn, .surname("breen"))
        #expect(breen.prose.hasPrefix("The earliest birth year in the Breen family is born 1860: Patrick Breen"))
        #expect(breen.basisLine.contains("Ranked 5 of 5 people in the Breen family"))
        let youngestAncestor = try answer(.latestBorn, .ancestorsOf("Rick"))
        #expect(youngestAncestor.prose.hasPrefix("The latest birth year in Rick Breen’s ancestors is born 1930: Eileen Latta"))
        // Honest declines: unknown surname; a person with no ancestors; a
        // fact nobody records.
        #expect(try answer(.earliestBorn, .surname("nobody")).outcome == .declined)
        let donna = try answer(.earliestBorn, .ancestorsOf("Donna"))
        #expect(donna.outcome == .declined)
        #expect(donna.prose.contains("no parents for Donna Hudson"))
        let france = try answer(.firstBornIn(place: "France"))
        #expect(france.outcome == .declined)
        #expect(france.prose.contains("has a birthplace in France recorded"))
    }

    // MARK: Sensor — the live utterances never reach keyword presence

    @Test func liveUtterancesNeverRouteToKeywordPresence() throws {
        guard case .answer(let r) = pre("can you find the person in our family tree with the oldest birth year and tell me about them") else {
            Issue.record("the superlative went to the translator"); return
        }
        #expect(r.route == .graph)
        #expect(r.prose.contains("Hannah Ryan"))
        #expect(!r.prose.contains("16383"))

        guard case .answer(let photo) = pre("find the oldest photo of the oldest person in the tree") else {
            Issue.record("the photo ask went to the translator (keyword presence)"); return
        }
        // Person resolved first, then the person-photo route (no portrait
        // in this fixture → its honest decline), never a transcript search.
        #expect(photo.route == .graph)
        #expect(photo.prose.hasPrefix("2 people share the earliest birth year in the family tree"))
        #expect(photo.prose.contains("I don’t have a photo of Hannah Ryan yet."))
        #expect(photo.queryDescription == "photo: Hannah Ryan")

        // Video: the presence route by NAME, with no superlative words left.
        guard case .translate(let q, _) = pre("show me a video of the youngest person in the tree") else {
            Issue.record("expected a person-media translate"); return
        }
        #expect(q == "videos of Tim Breen")
        #expect(!q.contains("youngest"))
    }
}
