// HallieOwnerResolverTests.swift
// codex #790 (2026-08-28): on a MULTI-ROOT tree the owner precedence is
// pin > exactly one matching root > fail closed. A unique name match that
// is NOT a root must not be accepted — before this fix the unique-name
// shortcut ran first and bound a non-root namesake. Pure: synthetic GEDCOM
// text, no defaults touched.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Two roots (Donna, Walter) and ONE Richard who is a non-root cousin.
private let uniqueNonRootRick = """
0 HEAD
1 _VS_ROOT @I1@
1 _VS_ROOT @I2@
0 @I1@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 _FSFTID G2CL-86B
0 @I2@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 _FSFTID DON1-DAD
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
0 TRLR
"""

/// Two roots, Rick Jr is the second; a Sr namesake is not a root.
private let rickIsSecondRoot = """
0 HEAD
1 _VS_ROOT @I1@
1 _VS_ROOT @I2@
0 @I1@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 _FSFTID G2CL-86B
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 _FSFTID RICK-DAD
0 TRLR
"""

/// Two roots that BOTH match "Rick Breen".
private let bothRootsMatch = """
0 HEAD
1 _VS_ROOT @I1@
1 _VS_ROOT @I2@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 _FSFTID RICK-DAD
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
0 TRLR
"""

@Suite("Owner resolver — multi-root precedence (codex #790)")
struct HallieOwnerResolverTests {

    @Test func uniqueNonRootNamesakeIsNotAcceptedOnATwoRootTree() {
        let g = GedcomFamilyGraph(gedcomText: uniqueNonRootRick)
        #expect(g.roots.count == 2)
        #expect(g.people(namedLike: "Rick Breen").map(\.id) == ["@I3@"], "fixture: exactly one name hit, a non-root")
        guard case .none(let reason?) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .none(reason:) — a lone non-root namesake must fail closed"); return
        }
        #expect(reason.contains("2 home people"))
        #expect(reason.contains("Richard Harding Breen Jr"))
        #expect(reason.contains("set your FamilySearch ID"))
    }

    @Test func exactlyOneMatchingRootIsAccepted() {
        let g = GedcomFamilyGraph(gedcomText: rickIsSecondRoot)
        guard case .one(let p, let note) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .one"); return
        }
        #expect(p.id == "@I2@")
        #expect(note.contains("the one tree root matching Rick Breen"))
    }

    @Test func bothRootsMatchingFailsClosed() {
        let g = GedcomFamilyGraph(gedcomText: bothRootsMatch)
        guard case .none(let reason?) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .none(reason:)"); return
        }
        #expect(reason.contains("2 home people"))
        #expect(reason.contains("can’t tell which is you"))
    }

    @Test func pinStillWinsOverEverythingOnAMultiRootTree() {
        for text in [uniqueNonRootRick, rickIsSecondRoot, bothRootsMatch] {
            let g = GedcomFamilyGraph(gedcomText: text)
            guard case .one(let p, let note) = HallieOwnerResolver.resolve("Rick Breen", graph: g, familySearchID: "GVQV-NW3") else {
                Issue.record("expected the pinned person"); return
            }
            #expect(p.familySearchID == "GVQV-NW3")
            #expect(note.contains("FamilySearch ID GVQV-NW3"))
        }
    }

    @Test func noNamesakeAtAllOnAMultiRootTreeFailsClosed() {
        let g = GedcomFamilyGraph(gedcomText: uniqueNonRootRick)
        guard case .none(let reason?) = HallieOwnerResolver.resolve("Zebulon Quince", graph: g) else {
            Issue.record("expected .none(reason:) — never the first root by file order"); return
        }
        #expect(reason.contains("2 home people"))
    }

    @Test func singleRootTreeKeepsTheUniqueNameShortcut() {
        // Regression guard: the shortcut is only demoted on MULTI-root trees.
        let single = uniqueNonRootRick.replacingOccurrences(of: "1 _VS_ROOT @I1@\n1 _VS_ROOT @I2@\n", with: "")
        let g = GedcomFamilyGraph(gedcomText: single)
        #expect(g.roots.count == 1)
        guard case .one(let p, let note) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .one by unique name"); return
        }
        #expect(p.id == "@I3@")
        #expect(note.contains("matched Rick Breen by name"))
    }
}
