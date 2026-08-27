// HallieDeepAncestorSensorTests.swift
// codex #707 blocker 1: the deep-ancestor walk kept every full path and
// only deduplicated after the whole frontier, so pedigree collapse (the
// same couple reached along several lines) grew paths as 2^depth — a
// freeze or an OOM through the 40-great bound. The walk is now a
// visited/predecessor BFS with hard budgets. These sensors pin it at
// production scale: a generated pedigree-collapse graph and a full
// 14-generation binary pedigree (16,383 people). Pure, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// GEDCOM generators. Names carry the generation and slot so a wrong
/// hop is visible in the prose.
private enum Pedigree {
    /// `generations` rows of four people (M0 F1 M2 F3). Every couple's
    /// parents are shared across four lines: child (g,i) hangs from
    /// family i of row g+1, and the four families of a row are
    /// (M0,F1) (M2,F3) (M0,F3) (M2,F1) — so each person has two parents
    /// but a row has only four people: 2^depth paths, 4 people per level.
    static func collapse(generations: Int) -> String {
        var out = ["0 HEAD"]
        for g in 0..<generations {
            for i in 0..<4 {
                out.append("0 @P\(g)_\(i)@ INDI")
                out.append("1 NAME Gen\(g) /Slot\(i)/")
                out.append("1 SEX \(i % 2 == 0 ? "M" : "F")")
                out.append("1 BIRT")
                out.append("2 DATE \(2000 - 25 * g)")
                if g + 1 < generations { out.append("1 FAMC @F\(g + 1)_\(i)@") }
                if g > 0 {
                    // Which of this row's four families does slot i sit in?
                    for f in 0..<4 where parentsOf(f).contains(i) { out.append("1 FAMS @F\(g)_\(f)@") }
                }
            }
        }
        for g in 1..<generations {
            for f in 0..<4 {
                let (h, w) = (parentsOf(f)[0], parentsOf(f)[1])
                out.append("0 @F\(g)_\(f)@ FAM")
                out.append("1 HUSB @P\(g)_\(h)@")
                out.append("1 WIFE @P\(g)_\(w)@")
                out.append("1 CHIL @P\(g - 1)_\(f)@")
            }
        }
        out.append("0 TRLR")
        return out.joined(separator: "\n")
    }
    private static func parentsOf(_ family: Int) -> [Int] {
        [[0, 1], [2, 3], [0, 3], [2, 1]][family]
    }

    /// A complete binary pedigree: heap-indexed, person n's parents are
    /// 2n (M) and 2n+1 (F). `generations` rows → 2^generations − 1 people.
    static func binary(generations: Int) -> String {
        let count = (1 << generations) - 1
        var out = ["0 HEAD"]
        for n in 1...count {
            out.append("0 @I\(n)@ INDI")
            out.append("1 NAME Person /N\(n)/")
            out.append("1 SEX \(n == 1 || n % 2 == 0 ? "M" : "F")")
            if 2 * n + 1 <= count { out.append("1 FAMC @F\(n)@") }
            if n > 1 { out.append("1 FAMS @F\(n / 2)@") }
        }
        for n in 1...count where 2 * n + 1 <= count {
            out.append("0 @F\(n)@ FAM")
            out.append("1 HUSB @I\(2 * n)@")
            out.append("1 WIFE @I\(2 * n + 1)@")
            out.append("1 CHIL @I\(n)@")
        }
        out.append("0 TRLR")
        return out.joined(separator: "\n")
    }
}

@Suite("Deep ancestors — scale sensors (pedigree collapse, 16,383-person pedigree)")
struct HallieDeepAncestorSensorTests {

    private func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = ContinuousClock.now
        let value = body()
        let elapsed = ContinuousClock.now - start
        return (value, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    @Test("pedigree collapse: 2^depth paths, 4 people per level — depth 12 / 30 / 42 each < 200 ms and bounded")
    func pedigreeCollapseIsLinearNotExponential() throws {
        let graph = GedcomFamilyGraph(gedcomText: Pedigree.collapse(generations: 44))
        let root = try #require(graph.people["@P0_0@"])
        #expect(graph.people.count == 44 * 4)
        for depth in [12, 30, 42] {
            let (r, secs) = timed {
                HallieLineageAnswer.deepAncestors(of: root, depth: depth, sex: nil, side: nil, graph: graph)
            }
            #expect(secs < 0.2, "depth \(depth) took \(secs)s")
            #expect(r.outcome == .answered, "depth \(depth): \(r.prose)")
            // Four people at that level, one route each, no "more".
            #expect(r.prose.contains("Gen\(depth) Slot0") && r.prose.contains("Gen\(depth) Slot3"), Comment(rawValue: r.prose))
            #expect(r.prose.components(separatedBy: "; ").count == 4, Comment(rawValue: r.prose))
            #expect(!r.prose.contains("more at that generation"))
            #expect(!r.prose.contains("budget"))
            #expect(r.offeredActions.count == 3)
        }
        // Sex filter and a side still work on the collapsed pedigree.
        let mothers = HallieLineageAnswer.deepAncestors(of: root, depth: 12, sex: "F", side: .maternal, graph: graph)
        #expect(mothers.outcome == .answered)
        #expect(mothers.prose.contains("maternal") && mothers.prose.contains("Slot1") && mothers.prose.contains("Slot3"))
        #expect(!mothers.prose.contains("Slot0 (") && !mothers.prose.contains("Slot2 ("), Comment(rawValue: mothers.prose))
        // A depth the pedigree does not reach is still said exactly.
        let past = HallieLineageAnswer.deepAncestors(of: root, depth: 43 + 1, sex: nil, side: nil, graph: graph)
        #expect(past.outcome == .declined)
        #expect(past.prose.contains("43 of 44 generations recorded"), Comment(rawValue: past.prose))
    }

    @Test("16,383-person binary pedigree: depth 13 lists 25 of 8,192 with an honest count, < 200 ms")
    func fullBinaryPedigreeIsBounded() throws {
        let graph = GedcomFamilyGraph(gedcomText: Pedigree.binary(generations: 14))
        #expect(graph.people.count == 16_383)
        let root = try #require(graph.people["@I1@"])
        let (r, secs) = timed {
            HallieLineageAnswer.deepAncestors(of: root, depth: 13, sex: nil, side: nil, graph: graph)
        }
        #expect(secs < 0.2, "took \(secs)s")
        #expect(r.outcome == .answered)
        #expect(r.prose.components(separatedBy: "; ").count == HallieLineageAnswer.deepAncestorMaxResults, Comment(rawValue: r.prose))
        #expect(r.prose.contains("There are \(8192 - 25) more at that generation I haven’t listed (8192 in all)."), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("budget"), "8k expansions is inside the budget")
        #expect(r.offeredActions.count == 3)
        // Every listed route is 13 hops long and ends at a 13th-generation id (8192...16383).
        for line in r.prose.components(separatedBy: "; ") {
            #expect(line.components(separatedBy: " → ").count == 14, Comment(rawValue: line))
        }
        // One generation past the pedigree: exact decline.
        let past = HallieLineageAnswer.deepAncestors(of: root, depth: 14, sex: nil, side: nil, graph: graph)
        #expect(past.outcome == .declined)
        #expect(past.prose.contains("13 of 14 generations recorded"), Comment(rawValue: past.prose))
        // Female-only at depth 13: 4,096 mothers, still 25 shown.
        let mothers = HallieLineageAnswer.deepAncestors(of: root, depth: 13, sex: "F", side: nil, graph: graph)
        #expect(mothers.prose.contains("(4096 in all)"), Comment(rawValue: mothers.prose))
    }

    @Test("a malformed cyclic GEDCOM cannot make someone their own ancestor")
    func cycleIsBounded() throws {
        // A is child of B, B is child of A.
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @A@ INDI
        1 NAME A /Loop/
        1 SEX M
        1 FAMC @F1@
        1 FAMS @F2@
        0 @B@ INDI
        1 NAME B /Loop/
        1 SEX M
        1 FAMC @F2@
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @B@
        1 CHIL @A@
        0 @F2@ FAM
        1 HUSB @A@
        1 CHIL @B@
        0 TRLR
        """)
        let a = try #require(graph.people["@A@"])
        let (r, secs) = timed { HallieLineageAnswer.deepAncestors(of: a, depth: 5, sex: nil, side: nil, graph: graph) }
        #expect(secs < 0.2)
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("no parents for B Loop"), Comment(rawValue: r.prose))
    }
}
