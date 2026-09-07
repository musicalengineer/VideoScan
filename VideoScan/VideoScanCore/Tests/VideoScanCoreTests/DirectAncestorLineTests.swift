// DirectAncestorLineTests.swift
// Rick, live 2026-09-07: "how am I related to King Edward III of England?"
// → "no chain of parents, children, or marriages joins them within 12 steps."
//
// Edward III is his 18th-great-grandfather, twenty generations straight up,
// on a twenty-generation GEDCOM pull. The twelve-hop bound is correct for
// LATERAL kin (6 up + 6 down ≈ a fifth cousin, and the prose grows with every
// hop) and wrong for a straight climb, whose answer is four words long
// however deep it runs.

import Foundation
import Testing
@testable import VideoScanCore

/// A deliberately deep straight line: 22 generations of fathers, so the walk
/// has to pass the old twelve-hop bound to find the top.
private let deepLine: String = {
    var text = "0 HEAD\n"
    for generation in 0...22 {
        text += "0 @I\(generation)@ INDI\n"
        text += "1 NAME Person\(generation) /Line/\n"
        text += "1 SEX M\n"
        if generation > 0 { text += "1 FAMS @F\(generation)@\n" }
        if generation < 22 { text += "1 FAMC @F\(generation + 1)@\n" }
    }
    for generation in 1...22 {
        text += "0 @F\(generation)@ FAM\n1 HUSB @I\(generation)@\n1 CHIL @I\(generation - 1)@\n"
    }
    return text + "0 TRLR\n"
}()

@Suite("A direct ancestral line is not bounded like a cousin")
struct DirectAncestorLineTests {
    let graph = GedcomFamilyGraph(gedcomText: deepLine)

    private func person(_ n: Int) throws -> GedcomFamilyGraph.Person {
        try #require(graph.people["@I\(n)@"])
    }

    /// THE INCIDENT: twenty generations up must be found and counted.
    @Test func twentyGenerationsUpIsFound() throws {
        let line = try #require(graph.directAncestorLine(from: try person(0), to: try person(20)))
        #expect(line.generations == 20)
        #expect(line.chain.count == 21, "the chain includes both ends")
        #expect(line.chain.first?.id == "@I0@")
        #expect(line.chain.last?.id == "@I20@")
    }

    /// The general relationship search still stops where it always did, so
    /// this is an ADDITION and not a widening of the lateral bound.
    @Test func theLateralBoundIsUnchanged() throws {
        #expect(GedcomFamilyGraph.relationshipSearchDepthLimit == 12)
        #expect(graph.relationshipPath(from: try person(0), to: try person(20)) == nil,
                "twenty hops is still beyond the twelve-hop lateral search")
    }

    /// The direct search has its own bound and honours it.
    @Test func itStopsAtItsOwnLimit() throws {
        #expect(graph.directAncestorLine(from: try person(0), to: try person(20),
                                         maxGenerations: 5) == nil)
        #expect(graph.directAncestorLine(from: try person(0), to: try person(5),
                                         maxGenerations: 5)?.generations == 5)
    }

    /// Direction matters: a descendant is not an ancestor.
    @Test func itIsDirectionalAndRejectsSelf() throws {
        #expect(graph.directAncestorLine(from: try person(20), to: try person(0)) == nil)
        #expect(graph.directAncestorLine(from: try person(3), to: try person(3)) == nil)
    }

    /// The words Rick reads. Genealogy's convention: generation 4 is the
    /// SECOND great-grandparent, so the ordinal is generations − 2.
    @Test func theTermMatchesGenealogicalConvention() {
        let term = GedcomFamilyGraph.directAncestorTerm
        #expect(term(1, "M") == "father")
        #expect(term(2, "F") == "grandmother")
        #expect(term(3, "M") == "great-grandfather")
        #expect(term(4, "F") == "2nd-great-grandmother")
        #expect(term(20, "M") == "18th-great-grandfather", "Edward III")
        #expect(term(23, "M") == "21st-great-grandfather")
        #expect(term(12, "M") == "10th-great-grandfather")
        #expect(term(15, "F") == "13th-great-grandmother")
        #expect(term(2, "") == "grandparent", "unrecorded sex stays neutral")
    }
}
