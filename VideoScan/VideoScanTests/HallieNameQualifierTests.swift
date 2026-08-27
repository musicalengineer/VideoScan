// HallieNameQualifierTests.swift
// Live miss 2026-08-27 03:26:37Z: "are there any photos of Nathaniel Parker
// born 1651" reached the translator, whose reading (a 1651 media-year
// filter) the strict decoder rejected. The deterministic photo shape now
// reads an explicit "<name> born <year>" / "(b. <year>)" / "who died in
// <year>" against EXACT, unqualified tree dates (HallieNameQualifier —
// TEMPORARY until the typed personQualifier lands). Pure fixture, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Two Nathaniel Parkers — Sr (16 MAY 1651–7 DEC 1737) and Nathaniel Caleb
/// (1760–1826); two Amos Birds — "ABT 1700" (tree-qualified) and 12 JAN 1802.
private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Nathaniel /Parker/ Sr
1 SEX M
1 BIRT
2 DATE 16 MAY 1651
1 DEAT
2 DATE 7 DEC 1737
0 @I2@ INDI
1 NAME Nathaniel Caleb /Parker/
1 SEX M
1 BIRT
2 DATE 14 JUL 1760
1 DEAT
2 DATE 4 MAR 1826
0 @I3@ INDI
1 NAME Amos /Bird/
1 SEX M
1 BIRT
2 DATE ABT 1700
0 @I4@ INDI
1 NAME Amos /Bird/
1 SEX M
1 BIRT
2 DATE 12 JAN 1802
1 DEAT
2 DATE 1870
0 TRLR
"""

@Suite("Name qualifiers — an explicit born/died year picks one namesake (exact dates only)")
struct HallieNameQualifierTests {
    typealias Q = HallieNameQualifier
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    private func pre(_ q: String) -> Exec.PreTranslation {
        let context = self.context
        return Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }
    private static let nathanielLine =
        "Nathaniel Parker Sr died in 1737, about a century before photography begins in 1838 — there can’t be a photograph of him. "
        + "If the family has a painting, engraving, or gravestone photo, put it in his People folder and I’ll show it."

    // MARK: Parser — explicit forms only

    @Test func parsesTheExplicitFormsAndNothingElse() {
        #expect(Q.parse("Nathaniel Parker born 1651") == .init(name: "Nathaniel Parker", kind: .born(1651)))
        #expect(Q.parse("nathaniel parker (b. 1651)") == .init(name: "nathaniel parker", kind: .born(1651)))
        #expect(Q.parse("Nathaniel Parker b. 1651") == .init(name: "Nathaniel Parker", kind: .born(1651)))
        #expect(Q.parse("Nathaniel Parker who died in 1737") == .init(name: "Nathaniel Parker", kind: .died(1737)))
        #expect(Q.parse("Nathaniel Parker d. 1737") == .init(name: "Nathaniel Parker", kind: .died(1737)))
        // The chip label typed back reads as its birth year.
        #expect(Q.parse("Nathaniel Parker Sr (b. 16 May 1651, d. 7 December 1737)") == .init(name: "Nathaniel Parker Sr", kind: .born(1651)))
        // Not qualifiers: a suffix (the graph honours it), a plain name, a
        // place, a bare year (a photo DATE, not a birth), relative age.
        #expect(Q.parse("Nathaniel Parker Sr") == nil)
        #expect(Q.parse("Donna Hudson") == nil)
        #expect(Q.parse("Nathaniel Parker (Framingham)") == nil)
        #expect(Q.parse("nathaniel parker (1651)") == nil)
        #expect(Q.parse("nathaniel parker in 1850") == nil)
        #expect(Q.parse("the older Nathaniel Parker") == nil)
        #expect(Q.parse("the oldest person in the tree") == nil)
        #expect(Q.parse("") == nil)
    }

    @Test func selectionIsExactAndNeverReadsATreeQualifiedDate() {
        let birds = graph.people(namedLike: "amos bird")
        #expect(birds.count == 2)
        #expect(Q(name: "amos bird", kind: .born(1802)).select(birds).map(\.id) == ["@I4@"])
        #expect(Q(name: "amos bird", kind: .born(1700)).select(birds).isEmpty, "ABT 1700 is not 'born 1700'")
        #expect(Q(name: "amos bird", kind: .born(1701)).select(birds).isEmpty, "no ±1")
        #expect(Q(name: "amos bird", kind: .born(1803)).select(birds).isEmpty)
        #expect(Q(name: "amos bird", kind: .died(1870)).select(birds).map(\.id) == ["@I4@"], "a plain year-only date is exact")
        #expect(Q.isQualifiedDate("ABT 1700") && Q.isQualifiedDate("BEF 1651") && Q.isQualifiedDate("BET 1650 AND 1652"))
        #expect(!Q.isQualifiedDate("1870") && !Q.isQualifiedDate("12 JAN 1802"))
    }

    // MARK: Deterministic photo shape

    @Test func theLiveUtteranceReachesThePhotographyFloor() throws {
        guard case .answer(let r) = pre("are there any photos of Nathaniel Parker born 1651") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.prose == Self.nathanielLine)
        #expect(r.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        #expect(r.basisLine.contains("No search was run"))

        guard case .answer(let paren) = pre("show me a photo of Nathaniel Parker (b. 1651)") else {
            Issue.record("the (b. 1651) form went to the translator"); return
        }
        #expect(paren.queryDescription == "photo: Nathaniel Parker Sr (before photography)")
        guard case .answer(let died) = pre("show me a photo of Nathaniel Parker who died in 1826") else {
            Issue.record("the died form went to the translator"); return
        }
        #expect(died.queryDescription == "photo: Nathaniel Caleb Parker (before photography)", "d. 1826 is before 1838 too")
    }

    @Test func aWrongYearGetsTheHonestYearsLine() throws {
        guard case .answer(let r) = pre("any photos of Nathaniel Parker born 1660") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.outcome == .declined)
        #expect(r.prose == "I have two Nathaniel Parkers, born 1651 and 1760 — neither born 1660.")
        #expect(r.queryDescription == "lineage: resolve Nathaniel Parker Born 1660 (no namesake born 1660)")
        // A tree-qualified date is quoted as the tree has it, never matched.
        guard case .answer(let bird) = pre("any photos of Amos Bird born 1700") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(bird.prose == "I have two Amos Birds, born ABT 1700 and 1802 — neither born 1700.")
        // A qualifier on a name the tree does not have at all: the ordinary
        // not-found answer, not a years line about nobody.
        guard case .answer(let nobody) = pre("any photos of Zebulon Nobody born 1660") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(nobody.outcome == .declined)
        #expect(!nobody.prose.contains("neither"))
    }

    // MARK: Regressions — everything else is untouched

    @Test func plainAndDatedMediaAsksAreUnchanged() {
        #expect(pre("photos of Donna") == .translate(question: "photos of Donna", playAfterAnswer: false))
        #expect(pre("show me photos of Nathaniel Parker in 1850") == .translate(question: "show me photos of Nathaniel Parker in 1850", playAfterAnswer: false),
                "a year alone is a photo DATE — the translator's, not a birth qualifier")
        #expect(pre("videos of donna from 1992 to 1995") == .translate(question: "videos of donna from 1992 to 1995", playAfterAnswer: false))
        #expect(pre("tell me about Nathaniel Parker born 1651") == .translate(question: "tell me about Nathaniel Parker born 1651", playAfterAnswer: false),
                "biography asks are not qualified tonight (typed personQualifier, phase 0)")
        guard case .answer(let r) = pre("show me a photo of Nathaniel Parker Sr") else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.prose == Self.nathanielLine)
    }
}
