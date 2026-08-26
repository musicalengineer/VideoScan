// HallieOwnerFamilySearchIDTests.swift
// ITEM 6 (2026-08-26): the owner's FamilySearch ID (`_FSFTID`, written by
// getmyancestors for every INDI) pins "me" to one tree record before any
// name matching. Pure: synthetic GEDCOM text, no defaults touched.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Two Richard Breens, the Sr FIRST in file order (so the root fallback
/// would pick the wrong one), Jr carrying Rick's real FamilySearch ID.
private let twoRichards = """
0 HEAD
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 _FSFTID L1AB-2CD
1 FAMS @F1@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
1 FAMC @F1@
1 FAMS @F2@
0 @I9@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMS @F2@
0 @F1@ FAM
1 HUSB @I2@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I9@
0 TRLR
"""

@Suite("Owner by FamilySearch ID")
struct HallieOwnerFamilySearchIDTests {
    let graph = GedcomFamilyGraph(gedcomText: twoRichards)

    @Test func fsftidIsParsedAndIndexed() {
        #expect(graph.people["@I1@"]?.familySearchID == "GVQV-NW3")
        #expect(graph.person(familySearchID: "GVQV-NW3")?.id == "@I1@")
        #expect(graph.person(familySearchID: " gvqv-nw3 ")?.id == "@I1@")   // case/space tolerant
        #expect(graph.person(familySearchID: "ZZZZ-999") == nil)
        #expect(graph.person(familySearchID: "") == nil)
        #expect(graph.person(familySearchID: nil) == nil)
    }

    @Test func familySearchIDWinsOverSameNamedSrAndRoot() {
        // Name match is ambiguous (two Richards) and the root is the Sr.
        #expect(graph.rootPerson?.id == "@I2@")
        switch HallieOwnerResolver.resolve("Rick Breen", graph: graph, familySearchID: "GVQV-NW3") {
        case .one(let p, let note):
            #expect(p.id == "@I1@")
            #expect(note.contains("FamilySearch ID GVQV-NW3"))
        default:
            Issue.record("expected the FS-ID person")
        }
    }

    @Test func missingIDFallsBackToRootAsBefore() {
        // No ID configured → the 2026-08-26 chain unchanged: several
        // Richards, root among them → root (the Sr here, by file order).
        switch HallieOwnerResolver.resolve("Rick Breen", graph: graph, familySearchID: nil) {
        case .one(let p, let note):
            #expect(p.id == "@I2@")
            #expect(note.contains("tree root"))
        default:
            Issue.record("expected the root fallback")
        }
        // An ID the tree does not carry behaves like no ID.
        if case .one(let p, _) = HallieOwnerResolver.resolve("Rick Breen", graph: graph, familySearchID: "NOPE-000") {
            #expect(p.id == "@I2@")
        } else { Issue.record("expected the root fallback") }
    }

    @Test func lineageOwnerResolutionUsesTheID() throws {
        let speakers = HallieTurnExecutor.Speakers(
            ownerName: "Rick Breen", archivistName: nil, ownerFamilySearchID: "GVQV-NW3")
        #expect(speakers.ownerFamilySearchID == "GVQV-NW3")
        let context = HallieTurnExecutor.Context(profiles: [], graph: graph, speakers: speakers)
        let r = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: nil, line: .paternal, generations: 3), context: context))
        #expect(r.catalogPersonName == "Richard Harding Breen Jr")
        #expect(r.basisLine.contains("FamilySearch ID GVQV-NW3"))
        // Without the ID the same question lands on the root (Sr).
        let plain = HallieTurnExecutor.Context(
            profiles: [], graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: nil))
        let p = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: nil, line: .paternal, generations: 3), context: plain))
        #expect(p.catalogPersonName == "Richard Harding Breen Sr")
    }

    @Test func familyTreeAnchorsPreferTheIDPerson() {
        #expect(FamilyTreeLiveModel.anchors(in: graph).map(\.id) == ["@I2@"])
        #expect(FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: "GVQV-NW3").map(\.id) == ["@I1@", "@I9@"])
        #expect(FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: "GVQV-NW3").map(\.label) == ["Richard", "Donna"])
    }

    @Test func emptyDefaultIsNil() {
        let d = UserDefaults(suiteName: "HallieOwnerFamilySearchIDTests.\(UUID().uuidString)")!
        #expect(HallieTurnExecutor.Speakers.fromDefaults(d).ownerFamilySearchID == nil)
        d.set("gvqv-nw3", forKey: HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey)
        #expect(HallieTurnExecutor.Speakers.fromDefaults(d).ownerFamilySearchID == "GVQV-NW3")
        d.removePersistentDomain(forName: d.description)
    }
}
