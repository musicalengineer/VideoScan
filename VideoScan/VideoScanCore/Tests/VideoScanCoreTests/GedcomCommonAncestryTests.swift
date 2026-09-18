// GedcomCommonAncestryTests.swift
// `commonAncestry(of:and:)` — the blood connection grouped for telling
// (Rick, 2026-09-18). Synthetic names only; the real-tree sensor skips when
// no compiled tree is installed.

import XCTest
@testable import VideoScanCore

final class GedcomCommonAncestryTests: XCTestCase {

    /// One INDI record. `birth: nil` leaves BIRT out.
    private static func indi(_ id: String, _ name: String, _ sex: String, birth: String? = "1700",
                             famc: [String] = [], fams: [String] = []) -> String {
        var lines = ["0 @\(id)@ INDI", "1 NAME \(name)", "1 SEX \(sex)"]
        if let birth { lines += ["1 BIRT", "2 DATE \(birth)"] }
        lines += famc.map { "1 FAMC @\($0)@" } + fams.map { "1 FAMS @\($0)@" }
        return lines.joined(separator: "\n")
    }

    private static func fam(_ id: String, husb: String? = nil, wife: String? = nil, children: [String]) -> String {
        (["0 @\(id)@ FAM"] + (husb.map { ["1 HUSB @\($0)@"] } ?? []) + (wife.map { ["1 WIFE @\($0)@"] } ?? [])
            + children.map { "1 CHIL @\($0)@" }).joined(separator: "\n")
    }

    /// Hugh + Wanda are the nearest couple: Ann is 3 generations below
    /// (Ann → Al → Carl → Hugh/Wanda), Ben 4 (Ben → Bo → Bea → Clara →
    /// Hugh/Wanda) — 2nd cousins once removed. Clara has no birth date and
    /// Carl has a second parent family. A second, farther line meets at Otto
    /// alone (4 above Ann, 5 above Ben). Gus, Hugh's father, is shared too
    /// but is not a separate line.
    static let tree: GedcomFamilyGraph = {
        let records = [
            indi("G", "Gus /Hill/", "M", fams: ["F0"]),
            fam("F0", husb: "G", children: ["H"]),
            indi("H", "Hugh /Hill/", "M", famc: ["F0"], fams: ["F1"]),
            indi("W", "Wanda /Wood/", "F", fams: ["F1"]),
            fam("F1", husb: "H", wife: "W", children: ["C1", "C2"]),
            indi("Z", "Zed /Alt/", "M", fams: ["F99"]),
            fam("F99", husb: "Z", children: ["C1"]),
            indi("C1", "Carl /Hill/", "M", famc: ["F1", "F99"], fams: ["F2"]),
            fam("F2", husb: "C1", children: ["A1"]),
            indi("A1", "Al /Hill/", "M", famc: ["F2"], fams: ["F3"]),
            fam("F3", husb: "A1", wife: "MA", children: ["A"]),
            indi("A", "Ann /Hill/", "F", famc: ["F3"]),
            indi("MA", "Mae /Quill/", "F", famc: ["F4"], fams: ["F3"]),
            fam("F4", husb: "Q", children: ["MA"]),
            indi("Q", "Quin /Quill/", "M", famc: ["F13"], fams: ["F4"]),
            fam("F13", husb: "Q2", children: ["Q"]),
            indi("Q2", "Quade /Quill/", "M", famc: ["F5"], fams: ["F13"]),
            fam("F5", husb: "O", children: ["Q2", "S2"]),
            indi("O", "Otto /Oak/", "M", fams: ["F5"]),
            indi("C2", "Clara /Hill/", "F", birth: nil, famc: ["F1"], fams: ["F6"]),
            fam("F6", wife: "C2", children: ["B1"]),
            indi("B1", "Bea /Bell/", "F", famc: ["F6"], fams: ["F7"]),
            fam("F7", wife: "B1", children: ["B2"]),
            indi("B2", "Bo /Bell/", "M", famc: ["F7"], fams: ["F8"]),
            fam("F8", husb: "B2", wife: "PB", children: ["B"]),
            indi("B", "Ben /Bell/", "M", famc: ["F8"]),
            indi("PB", "Pia /Reed/", "F", famc: ["F10"], fams: ["F8"]),
            fam("F10", husb: "R", children: ["PB"]),
            indi("R", "Rex /Reed/", "M", famc: ["F11"], fams: ["F10"]),
            fam("F11", husb: "S", children: ["R"]),
            indi("S", "Sid /Reed/", "M", famc: ["F12"], fams: ["F11"]),
            fam("F12", husb: "S2", children: ["S"]),
            indi("S2", "Sam /Oak/", "M", famc: ["F5"], fams: ["F12"]),
        ]
        return GedcomFamilyGraph(gedcomText: "0 HEAD\n" + records.joined(separator: "\n") + "\n0 TRLR\n")
    }()

    func testNearestIsTheCoupleNotOneOfThem() throws {
        let ancestry = try XCTUnwrap(Self.tree.commonAncestry(of: "@A@", and: "@B@"))
        let nearest = try XCTUnwrap(ancestry.nearest)
        XCTAssertEqual(nearest.ancestors.map(\.name), ["Hugh Hill", "Wanda Wood"], "husband first, then wife — one meeting")
        XCTAssertEqual([nearest.depthA, nearest.depthB], [3, 4])
        XCTAssertEqual(nearest.kinshipTerm, "2nd cousins once removed")
        XCTAssertEqual(nearest.pathA.map(\.name), ["Hugh Hill", "Carl Hill", "Al Hill", "Ann Hill"])
        XCTAssertEqual(nearest.pathB.map(\.name), ["Hugh Hill", "Clara Hill", "Bea Bell", "Bo Bell", "Ben Bell"])
    }

    func testSeparateLinesCountOnlyTheLowestMeetingPoints() throws {
        let ancestry = try XCTUnwrap(Self.tree.commonAncestry(of: "@A@", and: "@B@"))
        XCTAssertEqual(ancestry.sharedAncestorCount, 4, "Hugh, Wanda, Gus and Otto")
        XCTAssertEqual(ancestry.meetings.count, 2, "Gus is Hugh's father — the same line, not a new one")
        XCTAssertEqual(ancestry.meetings[1].ancestors.map(\.name), ["Otto Oak"])
        XCTAssertEqual([ancestry.meetings[1].depthA, ancestry.meetings[1].depthB], [4, 5])
        // The same shared set the one-at-a-time list reports.
        XCTAssertEqual(Self.tree.commonAncestors(of: "@A@", and: "@B@").count, ancestry.sharedAncestorCount)
    }

    func testGrainOfSaltNamesUndatedAndDisputedLinksOnTheNearestLines() throws {
        let ancestry = try XCTUnwrap(Self.tree.commonAncestry(of: "@A@", and: "@B@"))
        XCTAssertEqual(ancestry.undatedLinks.map(\.name), ["Clara Hill"])
        XCTAssertEqual(ancestry.disputedParentLinks.map(\.name), ["Carl Hill"])
    }

    func testSymmetricAndEmptyCases() throws {
        let ab = try XCTUnwrap(Self.tree.commonAncestry(of: "@A@", and: "@B@"))
        let ba = try XCTUnwrap(Self.tree.commonAncestry(of: "@B@", and: "@A@"))
        XCTAssertEqual(ba.nearest?.ancestors.map(\.id), ab.nearest?.ancestors.map(\.id))
        XCTAssertEqual([ba.nearest?.depthA, ba.nearest?.depthB], [4, 3])
        XCTAssertEqual(ba.meetings.count, ab.meetings.count)
        XCTAssertNil(Self.tree.commonAncestry(of: "@A@", and: "@A@"))
        XCTAssertNil(Self.tree.commonAncestry(of: "@A@", and: "@NOPE@"))
        XCTAssertNil(Self.tree.commonAncestry(of: "@A@", and: "@W@"), "Ann descends from Wanda; they share no ancestor")
    }

    /// Scale: interactive on a 100k-person synthetic pedigree.
    func testSynthetic100kIsInteractive() throws {
        let g = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        _ = g.index
        let pairs = GedcomCommonAncestorsBruteForceTests.randomPairs(g, count: 50, seed: 0xC0_FFEE)
        var found = 0
        let ms = GedcomCommonAncestorsBruteForceTests.ms {
            for (a, b) in pairs {
                guard let ancestry = g.commonAncestry(of: a, and: b) else { continue }
                found += 1
                // Every meeting is a genuinely shared ancestor at its true depths.
                for m in ancestry.meetings {
                    XCTAssertEqual(m.pathA.first?.id, m.ancestors.first?.id)
                    XCTAssertEqual(m.pathA.count - 1, m.depthA)
                    XCTAssertEqual(m.pathB.count - 1, m.depthB)
                }
            }
        }
        XCTAssertGreaterThan(found, 5)
        XCTAssertLessThan(ms / Double(pairs.count), 40 * GedcomCommonAncestorsBruteForceTests.slack,
                          "per-pair commonAncestry ms at 100k")
    }

    /// Sensor on the real tree: Rick and Donna's nearest shared couple.
    func testRealArtifactRickAndDonnaNearestCouple() throws {
        guard let url = GedcomCommonAncestorsBruteForceTests.newestArtifact,
              FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no compiled family tree installed")
        }
        let g: GedcomFamilyGraph
        do {
            g = try GedcomCompiledTree.decode(Data(contentsOf: url))
        } catch let error as GedcomCompiledTree.CodecError {
            guard case .versionMismatch = error else { throw error }
            throw XCTSkip("installed family tree was compiled with an older codec (\(error))")
        }
        let rick = g.people(matching: "GVQV-NW3").map(\.id), donna = g.people(matching: "G2CL-86B").map(\.id)
        try XCTSkipUnless(!rick.isEmpty && !donna.isEmpty, "artifact is not the two-root Rick/Donna tree")
        let ancestry = try XCTUnwrap(g.commonAncestry(of: rick[0], and: donna[0]))
        let nearest = try XCTUnwrap(ancestry.nearest)
        XCTAssertEqual(nearest.ancestors.count, 2, "a couple, not one of them")
        XCTAssertEqual([nearest.depthA, nearest.depthB], [10, 11])
        XCTAssertEqual(nearest.kinshipTerm, "9th cousins once removed")
        XCTAssertEqual(ancestry.sharedAncestorCount, g.commonAncestors(of: rick[0], and: donna[0]).count)
        XCTAssertLessThan(ancestry.meetings.count, ancestry.sharedAncestorCount)
        print("[sensor] Rick/Donna: shared \(ancestry.sharedAncestorCount), lines \(ancestry.meetings.count), nearest "
              + nearest.ancestors.map(\.name).joined(separator: " + ")
              + ", undated \(ancestry.undatedLinks.map(\.name)), disputed \(ancestry.disputedParentLinks.map(\.name))")
    }
}
