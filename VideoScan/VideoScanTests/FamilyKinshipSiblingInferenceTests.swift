// FamilyKinshipSiblingInferenceTests.swift
// RULING (Rick, Director, 2026-09-02 19:20): "we can do the 'children of'
// inference as part of Biography. No need to edit gedcom." The living
// family is never in the FamilySearch GEDCOM; Rick's People-tab card says
// child of Ma and Dad and sibling of Tim, Ellen and Beth, and the siblings'
// cards carry no rows — so "who are Eileen's children" listed only Rick.
//
// FamilyKinshipOverlay derives, at read time and never stored: FULL
// SIBLINGS SHARE PARENTS. After codex #984 (2026-09-02) it is the ONE
// policy for every reader — the inference engine, validation, the
// Relationships overview, the biography and the kinship route all consume
// the overlay's derived edges:
//   • `.unspecified` = full; `.attestedFull` = full; `.attestedHalf` shares
//     only its named parent and DOMINATES for its unordered pair;
//   • full-vs-half for one pair, > 2 parents, two mothers, or a cycle
//     FAILS CLOSED with one warning on every involved profile;
//   • a sibling with one stored parent receives the missing one;
//   • a derived edge cites the profile whose row was copied.
// Dimensions (docs/testing_retrospective):
//   LOGIC     — Rick's exact row set; cross-surface agreement; mixed bases;
//               partial explicit parent; half dominates unspecified;
//               full-vs-half conflict; populated 3- and 4-parent conflicts;
//               two mothers; provenance; self-cycle guard; bridge blast
//               radius; markers in the basis lines.
//   SCALE     — 100k profiles / 1,000-sibling chain: the derivation pass
//               alone (`derivationDuration`) < 200 ms; fixtures built
//               outside the timed region.
//   ISOLATION — poisoned owner / host defaults + a real on-disk profile
//               store with contradicting rows: neither reaches an overlay
//               built from the given profiles.
// The end-to-end shell sensor lives in HallieShellCLITests.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private typealias Snapshot = ArchivistGraphProfileSnapshot
private typealias Overlay = FamilyKinshipOverlay

private func row(_ relation: KinshipRelation, _ name: String,
                 basis: SiblingBasis = .unspecified) -> Kinship {
    Kinship(relation: relation, relativeTo: .profile(name: name), basis: basis)
}

private func half(_ name: String, via parent: String) -> Kinship {
    row(.sibling, name, basis: .attestedHalf(sharedParent: .profile(name: parent)))
}

private func snapshot(_ name: String, aliases: [String] = [], sex: PersonSex? = nil,
                      kinships: [Kinship] = [], pin: String? = nil) -> Snapshot {
    Snapshot(stableID: name.lowercased(), canonicalName: name, aliases: aliases,
             kinships: kinships, sex: sex, uuid: UUID(),
             treeIdentity: pin.map { .familySearchID($0) })
}

/// Rick's card exactly as it stands today (2026-09-02): sibling of Tim,
/// Ellen, Beth; child of Ma and Dad; parent of Dan, Mark, Matt, Timmy;
/// child-in-law of Anna; grandparent of Libby. Nobody else has rows.
private func ricksRows(siblingBasis: SiblingBasis = .unspecified) -> [Kinship] {
    [row(.sibling, "Tim", basis: siblingBasis), row(.sibling, "Ellen", basis: siblingBasis),
     row(.sibling, "Beth", basis: siblingBasis),
     row(.child, "Ma"), row(.child, "Dad"),
     row(.parent, "Dan"), row(.parent, "Mark"), row(.parent, "Matt"), row(.parent, "Timmy"),
     row(.childInLaw, "Anna"), row(.grandparent, "Libby")]
}

private func family(rick: [Kinship] = ricksRows(),
                    tim: [Kinship] = [], ellen: [Kinship] = [], beth: [Kinship] = [],
                    ma: [Kinship] = [],
                    maPin: String? = nil, dadPin: String? = nil, rickPin: String? = nil,
                    extra: [Snapshot] = []) -> [Snapshot] {
    [
        snapshot("Rick", aliases: ["Richard Harding Breen Jr"], sex: .male, kinships: rick, pin: rickPin),
        snapshot("Tim", sex: .male, kinships: tim),
        snapshot("Ellen", sex: .female, kinships: ellen),
        snapshot("Beth", sex: .female, kinships: beth),
        snapshot("Ma", aliases: ["Eileen", "Eileen Latta"], sex: .female, kinships: ma, pin: maPin),
        snapshot("Dad", aliases: ["Richard Harding Breen Sr"], sex: .male, pin: dadPin),
        snapshot("Dan", sex: .male), snapshot("Mark", sex: .male),
        snapshot("Matt", sex: .male), snapshot("Timmy", sex: .male),
        snapshot("Anna", sex: .female), snapshot("Libby", sex: .female),
    ] + extra
}

/// The three tree people the profiles pin to (synthetic GEDCOM; only the
/// FamilySearch IDs are real, 2026-08-03 privacy policy).
private let treeText = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 FAMS @F1@
1 _FSFTID G2S4-JF4
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 31 AUG 1930
1 FAMS @F1@
1 _FSFTID G2CR-R4H
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 TRLR
"""

private func names(_ hits: [Overlay.Hit]) -> [String] { hits.map(\.member.name).sorted() }

private func node(_ name: String) -> Overlay.Node { .profile(stableID: name.lowercased()) }

private let fullRule = "derived from Rick's rows: full siblings share parents"

/// Every one of `people` sees exactly `line` through the card-badge
/// route, and nobody else does.
private func expectWarning(_ line: String, on people: [String], notOn others: [String],
                           overlay: Overlay, _ location: SourceLocation = #_sourceLocation) {
    for name in people {
        #expect(overlay.warnings(forProfileNamed: name) == [line], Comment(rawValue: name),
                sourceLocation: location)
        #expect(overlay.derivationWarnings(touching: [node(name)]) == [line], Comment(rawValue: name),
                sourceLocation: location)
    }
    for name in others {
        #expect(overlay.warnings(forProfileNamed: name).isEmpty, Comment(rawValue: name),
                sourceLocation: location)
    }
}

// MARK: - Logic

@Suite("Full siblings share parents — overlay logic")
struct FamilyKinshipSiblingInferenceTests {

    @Test func ricksRowsGiveEileenFourChildrenAndTimTwoParents() {
        let overlay = Overlay(snapshots: family(), graph: nil)
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: node("Dad"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Dad", "Ma"])
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent, sex: .female)) == ["Ma"])
        // Ellen's siblings reach Tim and Beth THROUGH the derived parents
        // ([parent, child] folds to sibling; sibling∘sibling never did).
        #expect(names(overlay.relatives(of: node("Ellen"), relation: .sibling)) == ["Beth", "Rick", "Tim"])
        // Composition keeps working on top: Eileen's grandchildren are the
        // four sons via Rick (no derived hop involved) — unchanged.
        #expect(names(overlay.relatives(of: node("Ma"), relation: .grandchild)) == ["Dan", "Mark", "Matt", "Timmy"])
        // 3 orphans × 2 parents × 2 directions.
        #expect(overlay.derivedEdgeCount == 12)
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        #expect(overlay.derivationProblems.isEmpty)
    }

    /// ONE policy (codex #984 item 1): the overlay, the inference engine
    /// and the Relationships overview give the same parents for the same
    /// rows, with the same wording, and no surface says "not attested".
    @Test func overlayEngineAndOverviewAgreeOnTimsParents() {
        let people = family()
        let overlay = Overlay(snapshots: people, graph: nil)
        let engine = FamilyKinshipInference(snapshots: people, graph: nil)
        let fromOverlay = names(overlay.relatives(of: node("Tim"), relation: .parent))
        let fromEngine = engine.parents(of: node("Tim")).map { engine.name(of: $0.node) }.sorted()
        #expect(fromOverlay == ["Dad", "Ma"])
        #expect(fromEngine == fromOverlay)
        #expect(engine.parents(of: node("Tim")).allSatisfy { !$0.provenance.isExplicit })
        #expect(engine.explicitParents(of: node("Tim")).isEmpty)   // still not a stored row
        let dad = engine.relation(from: node("Tim"), to: node("Dad"))
        #expect(dad?.term == "father")
        #expect(dad?.caveats.isEmpty == true)
        #expect(dad?.usesDerivation == true)
        #expect(dad?.derivationRules == ["full siblings share parents"])
        #expect(engine.relation(from: node("Dad"), to: node("Tim"))?.term == "son")
        // The engine's proposal only offers to WRITE the derivation down.
        #expect(engine.proposals(for: node("Tim")).map(\.text)
                == ["Tim shares Rick's parents (Dad and Ma) — derived: full siblings share parents; confirm to record them on Tim's card"])

        let context = HallieTurnExecutor.Context(
            profiles: people.map(turnSnapshot), graph: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
        let overview = HallieRelationshipsOverview.answer(.init(subject: .named("Tim")), context: context)
        #expect(overview.outcome == .answered, Comment(rawValue: overview.prose))
        #expect(overview.prose.contains("Dad, Ma — Tim's parents (derived: full siblings share parents)"),
                Comment(rawValue: overview.prose))
        #expect(overview.prose.contains("Beth, Ellen — Tim's sisters (derived: full siblings share parents)"),
                Comment(rawValue: overview.prose))
        #expect(!overview.prose.contains("not attested"), Comment(rawValue: overview.prose))
        #expect(!overview.prose.contains("assumed"), Comment(rawValue: overview.prose))
        #expect(overview.basisLine.contains("derived: full siblings share parents"), Comment(rawValue: overview.basisLine))
        #expect(!overview.basisLine.contains("unattested"), Comment(rawValue: overview.basisLine))
        #expect(!overview.basisLine.contains("Relationship warning"), Comment(rawValue: overview.basisLine))
    }

    @Test func explicitParentRowsOnASiblingWinOverTheDerivation() {
        // Tim records his own parents: the same two, as rows. Nothing is
        // derived FOR Tim (his hops are stored rows), Ellen and Beth still
        // inherit, and Tim's own rows count as a source for them.
        let overlay = Overlay(snapshots: family(tim: [row(.child, "Ma"), row(.child, "Dad")]), graph: nil)
        let tim = overlay.relatives(of: node("Tim"), relation: .parent)
        #expect(names(tim) == ["Dad", "Ma"])
        #expect(tim.allSatisfy { hit in hit.hops.allSatisfy { !$0.isDerived } })
        #expect(overlay.derivedEdges(from: node("Tim")).isEmpty)
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        let ellen = overlay.relatives(of: node("Ellen"), relation: .parent)
        #expect(ellen.compactMap { overlay.derivationNote(for: $0.hops) }.first
                == "derived from Rick's and Tim's rows: full siblings share parents")
    }

    /// Codex #984 item 3: a full sibling with ONE stored parent receives
    /// the missing one (per-parent merge); the stored one stays a stored
    /// fact.
    @Test func aSiblingWithOneStoredParentReceivesTheOther() throws {
        let overlay = Overlay(snapshots: family(tim: [row(.child, "Dad")]), graph: nil)
        let tim = overlay.relatives(of: node("Tim"), relation: .parent)
        #expect(names(tim) == ["Dad", "Ma"])
        let dad = try #require(tim.first { $0.member.name == "Dad" })
        let ma = try #require(tim.first { $0.member.name == "Ma" })
        #expect(dad.hops.allSatisfy { !$0.isDerived })
        #expect(ma.hops.allSatisfy { $0.isDerived })
        #expect(overlay.derivationNote(for: ma.hops) == fullRule)
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: node("Beth"), relation: .parent)) == ["Dad", "Ma"])
        // Tim: 1 derived parent; Ellen, Beth: 2 each — × 2 directions.
        #expect(overlay.derivedEdgeCount == 10)
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        // The engine sees the same: Dad explicit, Ma derived.
        let engine = FamilyKinshipInference(snapshots: family(tim: [row(.child, "Dad")]), graph: nil)
        #expect(engine.parents(of: node("Tim")).map { $0.provenance.isExplicit } == [true, false])
        #expect(engine.relation(from: node("Tim"), to: node("Ma"))?.term == "mother")
    }

    /// Codex #984 item 2: rows are coalesced per unordered pair, and a half
    /// row DOMINATES a reciprocal legacy unspecified row — Tim never
    /// receives Ma through Rick's "sibling Tim".
    @Test func halfDominatesAReciprocalUnspecifiedRow() {
        let overlay = Overlay(snapshots: family(tim: [half("Rick", via: "Dad")]), graph: nil)
        let tim = overlay.relatives(of: node("Tim"), relation: .parent)
        #expect(names(tim) == ["Dad"])
        #expect(overlay.derivationNote(for: tim[0].hops)
                == "derived from Rick's rows: half siblings share the named parent (sibling rows on Tim)")
        #expect(!names(overlay.relatives(of: node("Ma"), relation: .child)).contains("Tim"))
        #expect(names(overlay.relatives(of: node("Dad"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        // Ellen and Beth (unspecified rows on Rick) are still full.
        #expect(names(overlay.relatives(of: node("Ellen"), relation: .parent)) == ["Dad", "Ma"])
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        // Same verdict in the engine: Tim ↔ Rick is half, Tim → Ma is no fact.
        let engine = FamilyKinshipInference(snapshots: family(tim: [half("Rick", via: "Dad")]), graph: nil)
        #expect(engine.parents(of: node("Tim")).map { engine.name(of: $0.node) } == ["Dad"])
        #expect(engine.relation(from: node("Rick"), to: node("Tim"))?.term == "half-brother")
        #expect(engine.relation(from: node("Tim"), to: node("Ma"))?.term == nil)
    }

    /// Codex #984 item 2: an explicit full row against an explicit half row
    /// for the same pair is a CONFLICT — nothing derived for the whole
    /// set, one warning on every involved profile.
    @Test func explicitFullVersusExplicitHalfFailsClosedForTheSet() {
        let overlay = Overlay(
            snapshots: family(rick: ricksRows(siblingBasis: .attestedFull), tim: [half("Rick", via: "Dad")]),
            graph: nil)
        let line = "Sibling rows between Rick and Tim disagree — one says full sibling, one says half sibling through Dad — nothing derived for their sibling set until one is corrected"
        #expect(overlay.derivedEdgeCount == 0)
        #expect(overlay.relatives(of: node("Tim"), relation: .parent).isEmpty)
        #expect(overlay.relatives(of: node("Ellen"), relation: .parent).isEmpty)   // same set: fails too
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Rick"])
        #expect(overlay.warnings == [line], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        expectWarning(line, on: ["Rick", "Tim", "Ellen", "Beth", "Ma", "Dad"],
                      notOn: ["Dan", "Anna", "Libby"], overlay: overlay)
        // The engine reports the same problem for every one of them.
        let engine = FamilyKinshipInference(
            snapshots: family(rick: ricksRows(siblingBasis: .attestedFull), tim: [half("Rick", via: "Dad")]),
            graph: nil)
        for name in ["Rick", "Tim", "Ellen", "Beth", "Ma", "Dad"] {
            #expect(engine.derivationProblems[node(name)] == line, Comment(rawValue: name))
        }
        #expect(engine.parents(of: node("Tim")).isEmpty)
        #expect(engine.relation(from: node("Tim"), to: node("Dad"))?.term == nil)
    }

    /// Mixed bases in ONE set: an attested-full row, a legacy unspecified
    /// row and a half row. Full ones share both parents; the half one
    /// shares only Dad; nothing conflicts.
    @Test func mixedBasesInOneSet() {
        let rick = [row(.sibling, "Tim", basis: .attestedFull), row(.sibling, "Ellen"),
                    row(.child, "Ma"), row(.child, "Dad")]
        let overlay = Overlay(snapshots: family(rick: rick, beth: [half("Rick", via: "Dad")]), graph: nil)
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Dad", "Ma"])
        #expect(names(overlay.relatives(of: node("Ellen"), relation: .parent)) == ["Dad", "Ma"])
        #expect(names(overlay.relatives(of: node("Beth"), relation: .parent)) == ["Dad"])
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: node("Dad"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(overlay.derivedEdgeCount == 10)
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        let engine = FamilyKinshipInference(snapshots: family(rick: rick, beth: [half("Rick", via: "Dad")]), graph: nil)
        #expect(engine.relation(from: node("Rick"), to: node("Beth"))?.term == "half-sister")
        #expect(engine.relation(from: node("Rick"), to: node("Ellen"))?.term == "sister")
        #expect(engine.relation(from: node("Beth"), to: node("Ma"))?.term == nil)
    }

    @Test func aSiblingWithADifferentExplicitParentFailsClosedAndWarnsEveryone() {
        // Tim says "child of Other" — under the full-sibling reading that is
        // a THIRD parent for the set. Tim keeps exactly his row, nothing is
        // derived for anyone in that set, and every involved profile —
        // the four siblings and all three parents — sees the one warning.
        let other = snapshot("Other", sex: .male)
        let people = family(tim: [row(.child, "Other")], extra: [other])
        let overlay = Overlay(snapshots: people, graph: nil)
        let line = "Sibling rows on Beth, Ellen, Rick and Tim imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected"
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Other"])
        #expect(!names(overlay.relatives(of: node("Ma"), relation: .child)).contains("Tim"))
        #expect(overlay.derivedEdgeCount == 0)
        #expect(overlay.warnings == [line], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        expectWarning(line, on: ["Beth", "Ellen", "Rick", "Tim", "Ma", "Dad", "Other"],
                      notOn: ["Dan", "Mark", "Anna"], overlay: overlay)
        #expect(FamilyKinshipInference(snapshots: people, graph: nil).derivationProblems[node("Other")] == line)
    }

    /// Codex #984 item 5: the conflict check no longer hides behind the
    /// orphan check — a set where EVERY sibling has stored parents, adding
    /// up to three or four people, is reported and derives nothing.
    @Test func populatedThreeAndFourParentConflictsAreReportedNotSilent() {
        let other = snapshot("Other", sex: .male)
        let p3 = snapshot("P3", sex: .male), p4 = snapshot("P4", sex: .female)
        // Three parents, nobody an orphan: Rick (Ma, Dad), Tim (Ma, Other),
        // Ellen (Ma, Dad), Beth (Ma, Dad).
        let three = Overlay(snapshots: family(
            tim: [row(.child, "Ma"), row(.child, "Other")],
            ellen: [row(.child, "Ma"), row(.child, "Dad")],
            beth: [row(.child, "Ma"), row(.child, "Dad")],
            extra: [other]), graph: nil)
        let threeLine = "Sibling rows on Beth, Ellen, Rick and Tim imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected"
        #expect(three.derivedEdgeCount == 0)
        #expect(three.warnings == [threeLine], Comment(rawValue: three.warnings.joined(separator: " | ")))
        expectWarning(threeLine, on: ["Beth", "Ellen", "Rick", "Tim", "Ma", "Dad", "Other"],
                      notOn: ["Dan", "Anna"], overlay: three)
        // Stored facts stand exactly as recorded.
        #expect(names(three.relatives(of: node("Tim"), relation: .parent)) == ["Ma", "Other"])
        #expect(names(three.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])

        // Four parents: Tim (P3, P4) against Rick / Ellen / Beth (Ma, Dad).
        let four = Overlay(snapshots: family(
            tim: [row(.child, "P3"), row(.child, "P4")],
            ellen: [row(.child, "Ma"), row(.child, "Dad")],
            beth: [row(.child, "Ma"), row(.child, "Dad")],
            extra: [p3, p4]), graph: nil)
        let fourLine = "Sibling rows on Beth, Ellen, Rick and Tim imply more than two parents (Dad, Ma, P3, P4) — nothing derived until one is corrected"
        #expect(four.derivedEdgeCount == 0)
        #expect(four.warnings == [fourLine], Comment(rawValue: four.warnings.joined(separator: " | ")))
        expectWarning(fourLine, on: ["Beth", "Ellen", "Rick", "Tim", "Ma", "Dad", "P3", "P4"],
                      notOn: ["Dan", "Anna"], overlay: four)
        // Hallie's basis carries it when the question touches the set.
        let engine = FamilyKinshipInference(snapshots: family(
            tim: [row(.child, "P3"), row(.child, "P4")],
            ellen: [row(.child, "Ma"), row(.child, "Dad")],
            beth: [row(.child, "Ma"), row(.child, "Dad")],
            extra: [p3, p4]), graph: nil)
        #expect(engine.derivationProblems[node("P4")] == fourLine)
        #expect(engine.relation(from: node("Tim"), to: node("Ma"))?.term == nil)
    }

    /// Codex #984 item 3: a stored parent that contradicts the set's parent
    /// of the same role (two mothers) is a conflict, not a merge — the
    /// stored one is kept, nothing is added.
    @Test func twoMothersForOneSetIsAConflict() {
        let other = snapshot("Other", sex: .female)
        let overlay = Overlay(snapshots: family(
            rick: [row(.sibling, "Tim"), row(.child, "Ma")],
            tim: [row(.child, "Other")], extra: [other]), graph: nil)
        let line = "Sibling rows on Rick and Tim imply two mothers (Ma, Other) — nothing derived until one is corrected"
        #expect(overlay.derivedEdgeCount == 0)
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Other"])
        #expect(names(overlay.relatives(of: node("Rick"), relation: .parent)) == ["Ma"])
        #expect(overlay.warnings == [line], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        expectWarning(line, on: ["Rick", "Tim", "Ma", "Other"], notOn: ["Ellen", "Dad"], overlay: overlay)
    }

    @Test func transitivityOverTheSiblingSet() {
        // Beth is only Ellen's sibling; Ellen is only Rick's sibling; Rick
        // alone records the parents. Beth gets them, and the basis cites
        // the sibling rows that carried them.
        let rick = [row(.child, "Ma"), row(.child, "Dad")]
        let overlay = Overlay(
            snapshots: family(rick: rick, ellen: [row(.sibling, "Rick")], beth: [row(.sibling, "Ellen")]),
            graph: nil)
        let beth = overlay.relatives(of: node("Beth"), relation: .parent)
        #expect(names(beth) == ["Dad", "Ma"])
        #expect(overlay.derivationNote(for: beth[0].hops)
                == "derived from Rick's rows: full siblings share parents (sibling rows on Beth and Ellen)")
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick"])
        // Tim has no row at all here: untouched.
        #expect(overlay.relatives(of: node("Tim"), relation: .parent).isEmpty)
    }

    @Test func noRowsMeansNoInference() {
        #expect(Overlay(snapshots: family(rick: []), graph: nil).derivedEdgeCount == 0)
        // Siblings without any parent row anywhere: nothing to share.
        let siblingsOnly = Overlay(
            snapshots: family(rick: [row(.sibling, "Tim"), row(.sibling, "Ellen")]), graph: nil)
        #expect(siblingsOnly.derivedEdgeCount == 0)
        #expect(siblingsOnly.relatives(of: node("Tim"), relation: .parent).isEmpty)
        #expect(siblingsOnly.warnings.isEmpty)
        // Parents without a sibling row: nothing to share them with.
        let parentsOnly = Overlay(snapshots: family(rick: [row(.child, "Ma")]), graph: nil)
        #expect(parentsOnly.derivedEdgeCount == 0)
        #expect(names(parentsOnly.relatives(of: node("Ma"), relation: .child)) == ["Rick"])
    }

    @Test func derivedFactsCarryTheMarkerAndStoredOnesDoNot() {
        let overlay = Overlay(snapshots: family(), graph: nil)
        // Stored rows: never marked; `edges(from:)` is stored-only and
        // unchanged by the derivation.
        #expect(overlay.edges(from: node("Rick")).allSatisfy { !$0.isDerived })
        #expect(overlay.edges(from: node("Tim")).map(\.relation) == [.sibling])
        #expect(overlay.edgeCount == 22)
        let rickToMa = overlay.relatives(of: node("Rick"), relation: .parent)
        #expect(overlay.derivationNote(for: rickToMa[0].hops) == nil)
        // Derived: marked, cited to Rick, one note per relative.
        let derived = overlay.derivedEdges(from: node("Tim"))
        #expect(derived.count == 2)
        #expect(derived.allSatisfy { $0.isDerived })
        #expect(derived.allSatisfy { $0.storedOn == "Rick" })
        #expect(derived.map(\.relation) == [.parent, .parent])
        for hit in overlay.relatives(of: node("Ma"), relation: .child) where hit.member.name != "Rick" {
            #expect(overlay.derivationNote(for: hit.hops) == fullRule, Comment(rawValue: hit.member.name))
        }
        // The rule text is the one the basis lines quote.
        #expect(Overlay.Derivation.fullSiblingRule == "full siblings share parents")
        #expect(Overlay.Derivation.siblingsShareParents(parentRowsOn: ["Rick"], siblingRowsOn: ["Rick"], half: false).note
                == fullRule)
    }

    /// Codex #984 item 4: a derived edge cites the profile whose row was
    /// COPIED. When Ma's card says "parent of Rick" (Rick's card only says
    /// "sibling of Tim"), Tim's derived mother comes from Ma's rows — never
    /// from Tim (the child) or Rick (the sibling the row points at).
    @Test func provenanceCitesTheSourceProfileNeverTheTarget() throws {
        let people = family(rick: [row(.sibling, "Tim"), row(.child, "Dad")], ma: [row(.parent, "Rick")])
        let overlay = Overlay(snapshots: people, graph: nil)
        let tim = overlay.relatives(of: node("Tim"), relation: .parent)
        #expect(names(tim) == ["Dad", "Ma"])
        let ma = try #require(tim.first { $0.member.name == "Ma" })
        let dad = try #require(tim.first { $0.member.name == "Dad" })
        #expect(ma.hops[0].storedOn == "Ma")
        #expect(dad.hops[0].storedOn == "Rick")
        let identity = { (name: String) in overlay.member(node(name))?.identity ?? "" }
        #expect(ma.hops[0].storedOnIdentity == identity("Ma"))
        #expect(dad.hops[0].storedOnIdentity == identity("Rick"))
        #expect(ma.hops[0].storedOnIdentity != identity("Tim"))
        #expect(overlay.derivationNote(for: ma.hops)
                == "derived from Ma's rows: full siblings share parents (sibling rows on Rick)")
        #expect(overlay.derivationNote(for: dad.hops) == fullRule)
        // The engine's hop cites the same source identity.
        let engine = FamilyKinshipInference(snapshots: people, graph: nil)
        let parents = engine.parents(of: node("Tim"))
        #expect(parents.map { $0.provenance } == [
            .derivedSibling(sourceIdentity: identity("Rick"), half: false),
            .derivedSibling(sourceIdentity: identity("Ma"), half: false),
        ])
        // Ma's card: her own children include Tim, and the basis names HER rows.
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Rick", "Tim"])
    }

    /// Codex #984 minor: a malformed sibling / parent cycle never yields
    /// "P child of P" or "P sibling of P"; it warns and derives nothing.
    @Test func aSiblingWhoIsAlsoAParentNeverBecomesTheirOwnParent() {
        // Rick: sibling Tim, child of Ma. Tim: child of Rick. Rick is both a
        // set member and an implied parent of the set.
        let overlay = Overlay(snapshots: family(
            rick: [row(.sibling, "Tim"), row(.child, "Ma")],
            tim: [row(.child, "Rick")]), graph: nil)
        let line = "Rick is recorded both as a sibling and as a parent among Rick and Tim — a person can't be their own sibling's parent; nothing derived until one row is corrected"
        #expect(overlay.derivedEdgeCount == 0)
        for name in ["Rick", "Tim", "Ma"] {
            #expect(overlay.derivedEdges(from: node(name)).allSatisfy { $0.from != $0.to }, Comment(rawValue: name))
        }
        #expect(!names(overlay.relatives(of: node("Rick"), relation: .parent)).contains("Rick"))
        #expect(!names(overlay.relatives(of: node("Rick"), relation: .sibling)).contains("Rick"))
        #expect(overlay.warnings == [line], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        expectWarning(line, on: ["Rick", "Tim", "Ma"], notOn: ["Ellen", "Dad"], overlay: overlay)
        // A half row naming one of the pair as the shared parent: same guard.
        let selfHalf = Overlay(snapshots: family(
            rick: [row(.child, "Ma")], tim: [half("Rick", via: "Rick")]), graph: nil)
        #expect(selfHalf.derivedEdgeCount == 0)
        #expect(selfHalf.warnings == [
            "The half-sibling row between Rick and Tim names Rick as the shared parent — a person can't be their own sibling's parent; nothing derived until it is corrected",
        ], Comment(rawValue: selfHalf.warnings.joined(separator: " | ")))
    }

    @Test func attestedFullReadsTheSameAndAttestedHalfSharesOnlyTheNamedParent() {
        let full = Overlay(snapshots: family(rick: ricksRows(siblingBasis: .attestedFull)), graph: nil)
        #expect(names(full.relatives(of: node("Tim"), relation: .parent)) == ["Dad", "Ma"])

        // Tim's own row: half sibling of Rick through Dad. Tim gets Dad
        // only, Ellen and Beth (unspecified rows on Rick) still get both,
        // and the half row is never a bridge into the full set.
        let half = Overlay(snapshots: family(
            rick: [row(.sibling, "Ellen"), row(.sibling, "Beth"), row(.child, "Ma"), row(.child, "Dad")],
            tim: [row(.sibling, "Rick", basis: .attestedHalf(sharedParent: .profile(name: "Dad")))]),
            graph: nil)
        let tim = half.relatives(of: node("Tim"), relation: .parent)
        #expect(names(tim) == ["Dad"])
        #expect(half.derivationNote(for: tim[0].hops)
                == "derived from Rick's rows: half siblings share the named parent (sibling rows on Tim)")
        #expect(names(half.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick"])
        #expect(names(half.relatives(of: node("Dad"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
    }

    @Test func pinnedMaIsEileenLattaOnTheTreeVertex() {
        // Identity is the existing pin bridge: Ma → Eileen Latta (G2CR-R4H),
        // so the derived children hang on the TREE vertex the graph route
        // and the biography look up.
        let graph = GedcomFamilyGraph(gedcomText: treeText)
        let overlay = Overlay(
            snapshots: family(maPin: "G2CR-R4H", dadPin: "G2S4-JF4", rickPin: "GVQV-NW3"), graph: graph)
        #expect(names(overlay.relatives(of: .tree(gedcomID: "@I3@"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: .tree(gedcomID: "@I2@"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        let tim = overlay.relatives(of: node("Tim"), relation: .parent)
        #expect(tim.map(\.member.displayName).sorted() == ["Dad (Richard Harding Breen Sr)", "Ma (Eileen Latta)"])
        #expect(overlay.pinProblems.isEmpty)
    }

    /// Bridge blast radius: a derived parent that maps to a GEDCOM person
    /// through the identity bridge adds the derived CHILDREN to that vertex
    /// and nothing else — the tree's own links, and every tree-side
    /// answer, are exactly what they were.
    @Test func derivedChildrenOnABridgedVertexDoNotAlterTheTreeSide() {
        let graph = GedcomFamilyGraph(gedcomText: treeText)
        let people = family(maPin: "G2CR-R4H", dadPin: "G2S4-JF4", rickPin: "GVQV-NW3")
        let engine = FamilyKinshipInference(snapshots: people, graph: graph)
        let eileen = Overlay.Node.tree(gedcomID: "@I3@")
        let richardSr = Overlay.Node.tree(gedcomID: "@I2@")
        let rick = Overlay.Node.tree(gedcomID: "@I1@")
        // The graph itself: one child, one spouse, as exported.
        #expect(graph.relatives(.children, of: graph.people["@I3@"]!).map(\.id) == ["@I1@"])
        // Hops on the bridged vertex: the spouse from the FAM link, Rick as
        // a recorded child (his row and the tree agree on one vertex); the
        // three others are derived — nothing else is added.
        let hops = engine.hops(from: eileen)
        #expect(hops.filter { $0.relation == .spouse }.map(\.to) == [richardSr])
        #expect(hops.filter { $0.relation == .spouse }.allSatisfy { $0.provenance == .tree })
        #expect(hops.filter { $0.relation == .child && $0.provenance.isExplicit }.map(\.to) == [rick])
        #expect(hops.filter { $0.relation == .child && !$0.provenance.isExplicit }.count == 3)
        #expect(hops.count == 5)
        #expect(hops.filter { $0.relation == .parent }.isEmpty)
        // Rick's own vertex: tree parents only, nothing derived onto him.
        #expect(engine.parents(of: rick).allSatisfy { $0.provenance.isExplicit })
        #expect(engine.parents(of: rick).map(\.node).sorted { $0.identityKey < $1.identityKey } == [richardSr, eileen])
        // Tree-side answers are unchanged.
        #expect(engine.relation(from: eileen, to: richardSr)?.term == "husband")
        #expect(engine.relation(from: rick, to: eileen)?.term == "mother")
        #expect(engine.relation(from: rick, to: eileen)?.usesDerivation == false)
        // The derived side reads through the same vertex.
        #expect(engine.relation(from: node("Tim"), to: eileen)?.term == "mother")
        #expect(engine.relation(from: node("Tim"), to: eileen)?.usesDerivation == true)
        #expect(engine.relation(from: node("Tim"), to: rick)?.term == "brother")
    }

    // MARK: Graph route + biography basis wording

    private func context(ownerFSID: String? = "GVQV-NW3") -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(
            profiles: family(maPin: "G2CR-R4H", dadPin: "G2S4-JF4", rickPin: "GVQV-NW3").map(turnSnapshot),
            graph: GedcomFamilyGraph(gedcomText: treeText),
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                            ownerFamilySearchID: ownerFSID))
    }

    @Test func whoAreEileensChildrenNamesAllFourAndMarksTheDerivedOnes() async throws {
        let r = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Eileen"], operation: .kinship, relation: .children)),
            context: context())
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        for name in ["Rick", "Tim", "Ellen", "Beth"] {
            #expect(r.prose.contains(name), Comment(rawValue: r.prose))
        }
        #expect(r.basisLine.contains("(stored on Rick's profile; Beth, Ellen and Tim \(fullRule));"),
                Comment(rawValue: r.basisLine))
        #expect(r.basisLine.hasPrefix("Basis: People tab relationship (stored on Rick's profile;"),
                Comment(rawValue: r.basisLine))
        #expect(!r.basisLine.contains("Relationship warning"), Comment(rawValue: r.basisLine))
    }

    @Test func whoAreTimsParentsAnswersEileenAndRichardSrFromTheTree() async throws {
        let r = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Tim"], operation: .kinship, relation: .parents)),
            context: context())
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Eileen Latta (Ma in the People tab)"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Richard Harding Breen Sr (Dad in the People tab)"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("; Dad and Ma \(fullRule));"), Comment(rawValue: r.basisLine))
        #expect(r.basisLine.contains("name and dates from the imported family tree (GEDCOM: Richard Harding Breen Sr @I2@, Eileen Latta @I3@)"),
                Comment(rawValue: r.basisLine))
    }

    @Test func ricksOwnParentsStayAStoredFactWithNoMarker() async throws {
        let r = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Rick"], operation: .kinship, relation: .parents)),
            context: context())
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("derived"), Comment(rawValue: r.basisLine))
        #expect(r.basisLine.contains("(stored on Rick's profile);"), Comment(rawValue: r.basisLine))
    }

    @Test func eileensBiographyListsTheFourChildrenWithTheDerivedNote() async throws {
        for typed in ["Eileen Latta", "Ma"] {
            let r = try await HallieTurnExecutor.execute(
                .graph(.init(people: [typed], operation: .biography)), context: context())
            #expect(r.outcome == .answered, Comment(rawValue: r.prose))
            // The tree's child first, then the People tab's three — the
            // living are never on FamilySearch.
            #expect(r.prose.contains("1 recorded child, Richard Harding Breen Jr."), Comment(rawValue: r.prose))
            #expect(r.prose.contains("In the People tab: Beth — daughter, Ellen — daughter and Tim — son."),
                    Comment(rawValue: r.prose))
            #expect(r.basisLine.contains("People tab relationships (stored on Rick's profile; Beth, Ellen and Tim \(fullRule)); local only, not from the family tree."),
                    Comment(rawValue: r.basisLine))
            // The derived claim cites the subject's record and the SOURCE
            // of the derivation — Rick's pinned identity, once — never the
            // three children's own profiles (codex #984 item 4).
            let plan = try #require(r.answerPlan)
            let claim = try #require(plan.claims.first { $0.text.hasPrefix("In the People tab: Beth") })
            #expect(claim.evidenceIDs == ["@I3@", "fsid:GVQV-NW3"], Comment(rawValue: claim.evidenceIDs.joined(separator: ",")))
        }
    }

    @Test func aBiographyWithoutDerivedKinKeepsTheOldBasisShape() async throws {
        let r = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Rick"], operation: .biography)), context: context())
        #expect(r.prose.contains("In the People tab: Beth — sister, Ellen — sister and Tim — brother."), Comment(rawValue: r.prose))
        #expect(r.basisLine.hasSuffix("People tab relationships (stored on Rick's profile); local only, not from the family tree."),
                Comment(rawValue: r.basisLine))
    }

    /// Codex #984 item 5: a set that failed closed reaches Hallie's basis
    /// from every side — the kinship route, the two-person route, the
    /// biography and the Relationships overview.
    @Test func aConflictReachesEveryHallieSurface() async throws {
        let other = snapshot("Other", sex: .male)
        let people = family(tim: [row(.child, "Other")], maPin: "G2CR-R4H", dadPin: "G2S4-JF4",
                            rickPin: "GVQV-NW3", extra: [other])
        let graph = GedcomFamilyGraph(gedcomText: treeText)
        let context = HallieTurnExecutor.Context(
            profiles: people.map(turnSnapshot), graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae", ownerFamilySearchID: "GVQV-NW3"))
        let line = "Sibling rows on Beth, Ellen, Rick and Tim imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected"
        // Kinship: Eileen's children are the tree's Rick only, and the basis says why.
        let children = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Eileen"], operation: .kinship, relation: .children)), context: context)
        #expect(!children.prose.contains("Tim"), Comment(rawValue: children.prose))
        #expect(children.basisLine.contains("Relationship warning: \(line)."), Comment(rawValue: children.basisLine))
        // Tim's parents: Other, with the warning.
        let parents = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Tim"], operation: .kinship, relation: .parents)), context: context)
        #expect(parents.prose.contains("Other"), Comment(rawValue: parents.prose))
        #expect(parents.basisLine.contains("Relationship warning: \(line)."), Comment(rawValue: parents.basisLine))
        // Biography of Ma: no derived children, the warning in the basis.
        let bio = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Ma"], operation: .biography)), context: context)
        #expect(!bio.prose.contains("Tim — son"), Comment(rawValue: bio.prose))
        #expect(bio.basisLine.contains("Relationship warning: \(line)."), Comment(rawValue: bio.basisLine))
        // Overview for Tim: Rick is his brother, Dad / Ma are not his parents.
        let overview = HallieRelationshipsOverview.answer(.init(subject: .named("Tim")), context: context)
        #expect(!overview.prose.contains("Tim's parents"), Comment(rawValue: overview.prose))
        #expect(overview.basisLine.contains("Relationship warning: \(line)."), Comment(rawValue: overview.basisLine))
        // Every involved card badge shows it.
        let overlay = Overlay(snapshots: people, graph: graph)
        for name in ["Beth", "Ellen", "Rick", "Tim", "Ma", "Dad", "Other"] {
            #expect(overlay.warnings(forProfileNamed: name) == [line], Comment(rawValue: name))
        }
    }

    // MARK: Codex #1019 — indirect cycles, one pair verdict, half provenance, vertex-keyed warnings

    /// Codex #1019 item 1: A and B are full siblings, A is a child of P,
    /// and P is a child of B. "Full siblings share parents" would derive B
    /// as a child of P — B → P → B. The set fails closed BEFORE anything
    /// is derived (the stored rows stand exactly as recorded), and A, B
    /// and P all carry the one warning.
    @Test func anIndirectParentCycleFailsClosed() {
        let people = [
            snapshot("A", sex: .male, kinships: [row(.sibling, "B"), row(.child, "P")]),
            snapshot("B", sex: .male),
            snapshot("P", sex: .female, kinships: [row(.child, "B")]),
        ]
        let overlay = Overlay(snapshots: people, graph: nil)
        let line = "Sibling rows on A and B would derive B as a child of P, but P already descends from B (parent line: P → B) — that would make B an ancestor of their own parent; nothing derived for that sibling set until one row is corrected"
        #expect(overlay.derivedEdgeCount == 0)
        #expect(overlay.relatives(of: node("B"), relation: .parent).isEmpty)
        #expect(names(overlay.relatives(of: node("B"), relation: .child)) == ["P"])     // the stored row stands
        #expect(names(overlay.relatives(of: node("A"), relation: .parent)) == ["P"])
        #expect(overlay.warnings == [line], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        expectWarning(line, on: ["A", "B", "P"], notOn: [], overlay: overlay)
        #expect(overlay.siblingVerdict(node("A"), node("B")) == .full)   // the pair itself is not in dispute
        let engine = FamilyKinshipInference(snapshots: people, graph: nil)
        #expect(engine.parents(of: node("B")).isEmpty)
        #expect(engine.relation(from: node("B"), to: node("P"))?.term == "daughter")
        for name in ["A", "B", "P"] {
            #expect(engine.derivationProblems[node(name)] == line, Comment(rawValue: name))
        }

        // A longer loop: A child of P, P child of Q, Q child of B. The
        // walk climbs the whole accepted parent line, and Q is involved.
        let longer = [
            snapshot("A", sex: .male, kinships: [row(.sibling, "B"), row(.child, "P")]),
            snapshot("B", sex: .male),
            snapshot("P", sex: .female, kinships: [row(.child, "Q")]),
            snapshot("Q", sex: .male, kinships: [row(.child, "B")]),
        ]
        let two = Overlay(snapshots: longer, graph: nil)
        let longLine = "Sibling rows on A and B would derive B as a child of P, but P already descends from B (parent line: P → Q → B) — that would make B an ancestor of their own parent; nothing derived for that sibling set until one row is corrected"
        #expect(two.derivedEdgeCount == 0)
        #expect(two.warnings == [longLine], Comment(rawValue: two.warnings.joined(separator: " | ")))
        expectWarning(longLine, on: ["A", "B", "P", "Q"], notOn: [], overlay: two)
        #expect(FamilyKinshipInference(snapshots: longer, graph: nil).parents(of: node("B")).isEmpty)

        // The loop can also close through a parent edge ACCEPTED earlier in
        // the same pass: A / B's set (planned first) puts B under P; P is a
        // stored child of D; C / D's set would then put D under B — B → P
        // → D → B. The walk climbs planned derivations as well as rows, so
        // the second set fails, and because the loop needs BOTH sets' edges
        // the first set is involved (and fails) too. Nothing is derived.
        let viaDerived = [
            snapshot("A", sex: .male, kinships: [row(.sibling, "B"), row(.child, "P")]),
            snapshot("B", sex: .male),
            snapshot("C", sex: .male, kinships: [row(.sibling, "D"), row(.child, "B")]),
            snapshot("D", sex: .male),
            snapshot("P", sex: .female, kinships: [row(.child, "D")]),
        ]
        let three = Overlay(snapshots: viaDerived, graph: nil)
        let plannedLine = "Sibling rows on C and D would derive D as a child of B, but B already descends from D (parent line: B → P → D) — that would make D an ancestor of their own parent; nothing derived for that sibling set until one row is corrected"
        #expect(three.derivedEdgeCount == 0)
        #expect(three.relatives(of: node("D"), relation: .parent).isEmpty)
        #expect(three.relatives(of: node("B"), relation: .parent).isEmpty)
        #expect(three.warnings == [plannedLine], Comment(rawValue: three.warnings.joined(separator: " | ")))
        expectWarning(plannedLine, on: ["A", "B", "C", "D", "P"], notOn: [], overlay: three)
    }

    /// Codex #1019 item 2: the verdict for a pair is computed from EVERY
    /// row on the unordered pair, so the order the profiles (and their
    /// rows) are read in cannot change it or its wording. Explicit full
    /// against explicit half is a conflict: the neutral "sibling" plus the
    /// warning on every surface — the profile-card line, the engine in
    /// both directions, the Relationships overview and the two-person
    /// route — never "brother" one way and "half-brother" the other.
    @Test func rowOrderCannotChangeTheSiblingVerdictOrItsWording() {
        let rick = snapshot("Rick", sex: .male,
                            kinships: [row(.sibling, "Tim", basis: .attestedFull), row(.child, "Ma"), row(.child, "Dad")])
        let tim = snapshot("Tim", sex: .male, kinships: [half("Rick", via: "Dad")])
        let rest = [snapshot("Ma", sex: .female), snapshot("Dad", sex: .male)]
        let line = "Sibling rows between Rick and Tim disagree — one says full sibling, one says half sibling through Dad — nothing derived for their sibling set until one is corrected"
        var seen: Set<String> = []
        for people in [[rick, tim] + rest, [tim, rick] + rest, rest + [tim, rick]] {
            let overlay = Overlay(snapshots: people, graph: nil)
            #expect(overlay.siblingVerdict(node("Rick"), node("Tim")) == .conflict)
            #expect(overlay.siblingVerdict(node("Tim"), node("Rick")) == .conflict)
            #expect(overlay.derivedEdgeCount == 0)
            #expect(overlay.warnings == [line], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
            // The profile-card reader: neutral, from either card.
            #expect(overlay.relationshipsLine(forProfileStableID: "tim", kinships: tim.kinships) == "Rick's sibling")
            #expect(overlay.relationshipsLine(forProfileStableID: "rick", kinships: rick.kinships)
                    == "Tim's sibling; Ma's son; Dad's son")
            // The engine, both directions.
            let engine = FamilyKinshipInference(snapshots: people, graph: nil)
            for (a, b) in [("Rick", "Tim"), ("Tim", "Rick")] {
                let d = engine.relation(from: node(a), to: node(b))
                #expect(d?.term == "sibling", Comment(rawValue: "\(a) → \(b): \(d?.term ?? "nil")"))
                #expect(d?.siblingVerdict == .conflict)
                #expect(d?.caveats == ["full or half not established — the sibling rows between \(a) and \(b) disagree (see the relationship warning)"])
                seen.insert("\(a)>\(b) \(d?.term ?? "") \(d?.caveats.joined() ?? "")")
            }
            // The overview and the two-person route: the same word, the warning in the basis.
            let context = HallieTurnExecutor.Context(
                profiles: people.map(turnSnapshot), graph: nil,
                speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
            let overview = HallieRelationshipsOverview.answer(.init(subject: .named("Tim")), context: context)
            #expect(overview.prose.contains("Rick — Tim's sibling"), Comment(rawValue: overview.prose))
            #expect(!overview.prose.contains("brother"), Comment(rawValue: overview.prose))
            #expect(overview.basisLine.contains("Relationship warning: \(line)."), Comment(rawValue: overview.basisLine))
            let inputs = ArchivistGraphInputs(graph: GedcomFamilyGraph(gedcomText: treeText), profiles: people, ownerName: "Rick Breen")
            let related = ArchivistGraphExecutor.execute(
                ArchivistGraphQuery(people: ["Rick", "Tim"], operation: .relationship), inputs: inputs)
            #expect(related.prose == "Tim is Rick's sibling.", Comment(rawValue: related.prose))
            #expect(related.basisLine.contains("Relationship warning: \(line)."), Comment(rawValue: related.basisLine))
            let brothers = ArchivistGraphExecutor.execute(
                ArchivistGraphQuery(people: ["Rick"], operation: .kinship, relation: .brother), inputs: inputs)
            #expect(brothers.prose == "Rick's brother: Tim (sibling rows disagree — full or half unknown).", Comment(rawValue: brothers.prose))
        }
        // Two ordered pairs, one wording each — identical across the three orders.
        #expect(seen.count == 2, Comment(rawValue: seen.sorted().joined(separator: " | ")))

        // An unresolved half (the named parent can't be found) beside a
        // reciprocal unspecified row is still HALF in every order — never
        // promoted to full — with the caveat saying what to fix.
        let stale = snapshot("Tim", sex: .male,
                             kinships: [row(.sibling, "Rick", basis: .attestedHalf(sharedParent: .profile(id: UUID())))])
        let plain = snapshot("Rick", sex: .male, kinships: [row(.sibling, "Tim"), row(.child, "Ma"), row(.child, "Dad")])
        let staleLine = "The shared parent named on the half-sibling row between Rick and Tim could not be found — nothing derived across that row until they are picked again"
        for people in [[plain, stale] + rest, [stale, plain] + rest] {
            let overlay = Overlay(snapshots: people, graph: nil)
            #expect(overlay.siblingVerdict(node("Rick"), node("Tim")) == .unresolved)
            #expect(overlay.derivedEdgeCount == 0)
            #expect(overlay.warnings == [staleLine], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
            // A nudge on the two cards, not a set failure (nothing else is wrong).
            for name in ["Rick", "Tim"] { #expect(overlay.warnings(forProfileNamed: name) == [staleLine], Comment(rawValue: name)) }
            for name in ["Ma", "Dad"] { #expect(overlay.warnings(forProfileNamed: name).isEmpty, Comment(rawValue: name)) }
            #expect(overlay.derivationProblems.isEmpty)
            #expect(overlay.relationshipsLine(forProfileStableID: "tim", kinships: stale.kinships) == "Rick's half-brother")
            #expect(overlay.relationshipsLine(forProfileStableID: "rick", kinships: plain.kinships)
                    == "Tim's half-brother; Ma's son; Dad's son")
            let engine = FamilyKinshipInference(snapshots: people, graph: nil)
            for (a, b) in [("Rick", "Tim"), ("Tim", "Rick")] {
                let d = engine.relation(from: node(a), to: node(b))
                #expect(d?.term == "half-brother", Comment(rawValue: "\(a) → \(b): \(d?.term ?? "nil")"))
                #expect(d?.siblingVerdict == .unresolved)
                #expect(d?.caveats == ["the shared parent named on the half-sibling row could not be found — pick them again"])
            }
            #expect(engine.parents(of: node("Tim")).isEmpty)
        }
    }

    /// Codex #1019 item 3: a half verdict cites the half attestation — the
    /// row that decided it — never the reciprocal unspecified row on the
    /// same pair, even when that row's card sorts first. Neither card
    /// records Dad, so the half row itself is the only source.
    @Test func aHalfDerivationCitesTheHalfAttestationNotTheReciprocalRow() throws {
        let rick = snapshot("Rick", sex: .male, kinships: [row(.sibling, "Tim")])   // legacy unspecified, no parents
        let tim = snapshot("Tim", sex: .male, kinships: [half("Rick", via: "Dad")])
        let people = [rick, tim, snapshot("Dad", sex: .male)]
        let timIdentity = "uuid:" + (try #require(tim.uuid)).uuidString.lowercased()
        let overlay = Overlay(snapshots: people, graph: nil)
        #expect(overlay.siblingVerdict(node("Rick"), node("Tim")) == .half(sharedParent: node("Dad")))
        let rickParents = overlay.relatives(of: node("Rick"), relation: .parent)
        let timParents = overlay.relatives(of: node("Tim"), relation: .parent)
        #expect(names(rickParents) == ["Dad"])
        #expect(names(timParents) == ["Dad"])
        for hit in rickParents + timParents {
            let hop = try #require(hit.hops.first)
            #expect(hop.isDerived)
            #expect(hop.storedOn == "Tim", Comment(rawValue: hop.storedOn))
            #expect(hop.storedOnIdentity == timIdentity, Comment(rawValue: hop.storedOnIdentity))
            #expect(overlay.derivationNote(for: hit.hops) == "derived from Tim's rows: half siblings share the named parent")
        }
        #expect(names(overlay.relatives(of: node("Dad"), relation: .child)) == ["Rick", "Tim"])
        #expect(overlay.derivedEdgeCount == 4)
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        // The engine cites the same source, and reads the pair as half.
        let engine = FamilyKinshipInference(snapshots: people, graph: nil)
        #expect(engine.parents(of: node("Rick")).map(\.provenance) == [.derivedSibling(sourceIdentity: timIdentity, half: true)])
        #expect(engine.parents(of: node("Tim")).map(\.provenance) == [.derivedSibling(sourceIdentity: timIdentity, half: true)])
        #expect(engine.relation(from: node("Rick"), to: node("Tim"))?.term == "half-brother")
        #expect(engine.relation(from: node("Tim"), to: node("Rick"))?.term == "half-brother")
        #expect(engine.proposals(for: node("Rick")).isEmpty)   // Tim records no parent row to copy
        // With Dad recorded on Rick's card, the half derivation for Tim
        // cites Rick's PARENT row (the card that names Dad), and the
        // sibling-row clause names the half row's card only.
        let withDad = [snapshot("Rick", sex: .male, kinships: [row(.sibling, "Tim"), row(.child, "Dad")]), tim, snapshot("Dad", sex: .male)]
        let second = Overlay(snapshots: withDad, graph: nil)
        let timDad = second.relatives(of: node("Tim"), relation: .parent)
        #expect(names(timDad) == ["Dad"])
        #expect(timDad.first?.hops.first?.storedOn == "Rick")
        #expect(second.derivationNote(for: timDad.first?.hops ?? [])
                == "derived from Rick's rows: half siblings share the named parent (sibling rows on Tim)")
    }

    /// Codex #1019 item 4: warnings are keyed by VERTEX. Two profiles that
    /// both read "Mary" — one in a sibling set that failed closed and one
    /// with an unrelated hygiene nudge — and each carries only its own.
    @Test func warningsAreKeyedByProfileNotByDisplayName() {
        let rick = snapshot("Rick", sex: .male, kinships: [row(.sibling, "Mary"), row(.child, "Ma"), row(.child, "Dad")])
        let mary = Snapshot(stableID: "mary", canonicalName: "Mary",
                            kinships: [row(.child, "Other")], sex: .female, uuid: UUID())
        let namesake = Snapshot(stableID: "mary-2", canonicalName: "Mary", aliases: ["Mom"], sex: .female, uuid: UUID())
        let people = [rick, mary, namesake, snapshot("Ma", sex: .female), snapshot("Dad", sex: .male),
                      snapshot("Other", sex: .male)]
        let overlay = Overlay(snapshots: people, graph: nil)
        let conflict = "Sibling rows on Mary and Rick imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected"
        let hygiene = "Alias 'Mom' on Mary looks relational — use a Relationship row instead"
        #expect(overlay.warnings == [hygiene, conflict], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        #expect(overlay.derivedEdgeCount == 0)
        // By stable id (the card badge's lookup): only the involved Mary.
        #expect(overlay.warnings(forProfileStableID: "mary") == [conflict])
        #expect(overlay.warnings(forProfileStableID: "mary-2") == [hygiene])
        for id in ["rick", "ma", "dad", "other"] {
            #expect(overlay.warnings(forProfileStableID: id) == [conflict], Comment(rawValue: id))
        }
        #expect(overlay.derivationWarnings(touching: [.profile(stableID: "mary-2")]).isEmpty)
        #expect(overlay.derivationWarnings(touching: [.profile(stableID: "mary")]) == [conflict])
        #expect(overlay.derivationProblems[.profile(stableID: "mary-2")] == nil)
        // By name: a name is not an identity — both Marys carry the
        // spelling, so the name form answers for both; nobody else.
        #expect(overlay.warnings(forProfileNamed: "Mary") == [hygiene, conflict])
        #expect(overlay.warnings(forProfileNamed: "Rick") == [conflict])
        #expect(overlay.warnings(forProfileNamed: "Mom").isEmpty)
        // The engine keys the problem by vertex too.
        let engine = FamilyKinshipInference(snapshots: people, graph: nil)
        #expect(engine.derivationProblems[.profile(stableID: "mary")] == conflict)
        #expect(engine.derivationProblems[.profile(stableID: "mary-2")] == nil)
    }
}

/// The executor's own snapshot type (same fields, carried separately).
private func turnSnapshot(_ s: Snapshot) -> HallieTurnExecutor.ProfileSnapshot {
    .init(stableID: s.stableID, canonicalName: s.canonicalName, aliases: s.aliases,
          kinships: s.kinships, sex: s.sex, uuid: s.uuid, treeIdentity: s.treeIdentity)
}

// MARK: - Scale

@Suite("Full siblings share parents — scale")
struct FamilyKinshipSiblingInferenceScaleTests {

    /// 100k profiles; 1,000 of them form one sibling chain (S_i sibling of
    /// S_{i-1}) whose head alone records two parents. The fixture is built
    /// OUTSIDE the timed region and the budget is on the derivation pass
    /// alone (`derivationDuration`, measured around pass 3 of the build),
    /// so neither fixture construction nor the resolver / vertex cost of
    /// 100k names hides or inflates the number.
    @Test func hundredThousandProfilesWithAThousandSiblingChainDerivesUnder200ms() {
        func profiles(withChain: Bool) -> [Snapshot] {
            var out: [Snapshot] = []
            out.reserveCapacity(100_000)
            out.append(Snapshot(stableID: "pa", canonicalName: "PA", sex: .male))
            out.append(Snapshot(stableID: "pb", canonicalName: "PB", sex: .female))
            for i in 0..<1_000 {
                var rows: [Kinship] = []
                if withChain {
                    rows = i == 0 ? [row(.child, "PA"), row(.child, "PB")] : [row(.sibling, "S\(i - 1)")]
                }
                out.append(Snapshot(stableID: "s\(i)", canonicalName: "S\(i)", kinships: rows,
                                    sex: i % 2 == 0 ? .male : .female))
            }
            for i in 0..<(100_000 - out.count) {
                out.append(Snapshot(stableID: "q\(i)", canonicalName: "Q\(i)"))
            }
            return out
        }
        let plain = profiles(withChain: false)
        let withChain = profiles(withChain: true)
        let baseline = Overlay(snapshots: plain, graph: nil)
        let chained = Overlay(snapshots: withChain, graph: nil)
        #expect(baseline.derivedEdgeCount == 0)
        // 999 orphans × 2 parents × 2 directions.
        #expect(chained.derivedEdgeCount == 3_996)
        #expect(names(chained.relatives(of: node("S999"), relation: .parent)) == ["PA", "PB"])
        #expect(chained.relatives(of: node("PA"), relation: .child).count == 1_000)
        #expect(chained.warnings.isEmpty)
        #expect(chained.derivationDuration < .milliseconds(200),
                "derivation over a 1,000-sibling chain in 100k profiles took \(chained.derivationDuration)")
        #expect(baseline.derivationDuration < .milliseconds(50),
                "derivation with no sibling rows took \(baseline.derivationDuration)")
    }
}

// MARK: - Isolation

@Suite("Full siblings share parents — isolation")
struct FamilyKinshipSiblingInferenceIsolationTests {

    /// The overlay reads the profiles it is given and nothing else. Two
    /// poisons that the kinship display path DOES read elsewhere — the
    /// owner / owner-pin defaults (KinshipDisplayCenter's default anchor)
    /// and a real on-disk People-tab store (the shell's read-only loader)
    /// holding a CONTRADICTING Tim — change nothing about Eileen's
    /// children, and the store's conflict never shows up as a warning.
    @MainActor
    @Test func poisonedDefaultsAndAContradictingProfileStoreDoNotLeak() throws {
        let defaults = UserDefaults.standard
        let keys = [HallieTurnExecutor.Speakers.ownerDefaultsKey,
                    HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey,
                    OllamaEndpoints.hostsKey]
        let priors = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, prior) in zip(keys, priors) {
                if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("Tim", forKey: keys[0])                 // the owner is a SIBLING, not Rick
        defaults.set("G2CR-R4H", forKey: keys[1])            // the owner pin is Ma's
        defaults.set("poison.invalid", forKey: keys[2])

        // A real store on disk (temp dir only): Rick's rows plus a Tim who
        // says "child of Other" — the three-parent conflict.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinship-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let poi = root.appendingPathComponent("VideoScan/POI", isDirectory: true)
        func stored(_ name: String, sex: PersonSex, kinships: [Kinship] = []) throws {
            let folder = poi.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let profile = POIProfile(name: name, referencePath: folder.path, sex: sex, kinships: kinships)
            try JSONEncoder().encode(profile).write(to: folder.appendingPathComponent("profile.json"))
        }
        try stored("Rick", sex: .male, kinships: [row(.sibling, "Tim"), row(.child, "Ma"), row(.child, "Dad")])
        try stored("Tim", sex: .male, kinships: [row(.child, "Other")])
        for name in ["Ma", "Other"] { try stored(name, sex: name == "Ma" ? .female : .male) }
        try stored("Dad", sex: .male)
        guard case .loaded(let onDisk) = HallieShellCLI.loadProfilesReadOnly(applicationSupportURL: root) else {
            Issue.record("the poison store did not load")
            return
        }
        #expect(onDisk.count == 5)
        // Read on its own, the store DOES conflict — so a leak would be visible.
        let poisonOverlay = Overlay(profiles: onDisk, graph: nil)
        #expect(poisonOverlay.warnings.count == 1)
        #expect(poisonOverlay.derivedEdgeCount == 0)

        // The center and the overlay, built from the in-memory family only.
        func inMemory(_ s: Snapshot) -> POIProfile {
            POIProfile(name: s.canonicalName, referencePath: "/isolated/people/\(s.stableID)",
                       aliases: s.aliases, sex: s.sex, kinships: s.kinships)
        }
        let profiles = family().map(inMemory)
        let center = KinshipDisplayCenter()
        let overlay = center.overlay(for: profiles)
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Dad", "Ma"])
        #expect(overlay.derivedEdgeCount == 12)
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        for name in ["Tim", "Ma", "Rick", "Other"] {
            #expect(overlay.warnings(forProfileNamed: name).isEmpty, Comment(rawValue: name))
        }
        #expect(center.aliasWarning(for: profiles[1], among: profiles) == nil)   // Tim
        // The poisoned owner only changes the display anchor, never a fact:
        // Rick's line still names his stored rows; Beth (no rows) has none.
        let rickLine = center.relationshipsLine(for: profiles[0], among: profiles) ?? ""
        #expect(rickLine.hasPrefix("Tim's brother"), Comment(rawValue: rickLine))
        #expect(!rickLine.contains("Other"), Comment(rawValue: rickLine))
        #expect(center.relationshipsLine(for: profiles[3], among: profiles) == nil)
        // The engine agrees, from the same profiles.
        let engine = center.inference(for: profiles)
        #expect(engine.parents(of: node("Tim")).map { engine.name(of: $0.node) }.sorted() == ["Dad", "Ma"])
        #expect(engine.derivationProblems.isEmpty)
        #expect(defaults.string(forKey: keys[2]) == "poison.invalid")
    }
}
