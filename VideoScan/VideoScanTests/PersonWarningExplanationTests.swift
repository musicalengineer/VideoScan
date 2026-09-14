// PersonWarningExplanationTests.swift
// The People-tab warning triangle explains itself (Rick, 2026-09-13). The
// badge used to be `.help(aliasWarning)` — one tooltip for ten different
// causes with ten different remedies.
//
// Dimensions (docs/testing_retrospective_2026_07_05):
//   LOGIC   — one case per warning code, built from REAL overlay inputs
//             (a relational alias, a row anchored at a deleted profile, a
//             stale export pointer, each of the five pin failures, a
//             missing half-sibling parent, a sibling-set contradiction).
//             Every case asserts the code AND that `text` is still the
//             exact string the overlay has always produced: Hallie's basis
//             lines and the strict replays are pinned to those bytes.
//   SENSOR  — (a) every `Code` yields non-empty `why` and `fix`, so a new
//             code cannot ship with no guidance; (b) the fixtures above
//             cover EVERY case of the enum, so a new code cannot ship
//             without a producing site and a test.
//   IDENTITY— two profiles both named "Richard" (Rick and Dad, the live
//             pair): the warning is on one card only, and the fix button
//             routes by uuid, never by name.
//   VIEW    — the popover's section list (a pure model) has one section per
//             warning in `warnings` order, with the action and identifiers
//             each section needs, and the route the button fires resolves
//             to the right person.
//   SCALE   — the gallery's warning map is built ONCE per evaluation and
//             memoised on (tree generation, kinship signature): no O(people)
//             work in a card body.
// Every fixture is in memory; the GEDCOM is synthetic (2026-08-03 policy).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private typealias Snapshot = ArchivistGraphProfileSnapshot
private typealias Overlay = FamilyKinshipOverlay
private typealias Code = KinshipWarning.Code

/// One producing fixture per code: the overlay to build, whose card to look
/// at, and the exact line that card must carry.
private struct WarningCase {
    let code: Code
    let text: String
    let overlay: Overlay
    let stableID: String
}

private func row(_ relation: KinshipRelation, _ name: String,
                 basis: SiblingBasis = .unspecified) -> Kinship {
    Kinship(relation: relation, relativeTo: .profile(name: name), basis: basis)
}

private func snapshot(_ name: String, stableID: String? = nil, aliases: [String] = [],
                      sex: PersonSex? = nil, kinships: [Kinship] = [],
                      pin: TreeIdentity? = nil, unreadable: Bool = false) -> Snapshot {
    Snapshot(stableID: stableID ?? name.lowercased(), canonicalName: name, aliases: aliases,
             kinships: kinships, sex: sex, uuid: UUID(),
             treeIdentity: pin, treeIdentityUnreadable: unreadable)
}

/// Two Richards and one other record — the shape of Rick's own tree.
private let treeText = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 _FSFTID G2S4-JF4
0 TRLR
"""

@Suite("People-tab warning explanations")
struct PersonWarningExplanationTests {

    private static let tree = GedcomFamilyGraph(gedcomText: treeText)

    // MARK: Producing fixtures — one per code

    /// Built fresh per call: an overlay is a value, and each case wants its
    /// own profile set.
    private static func cases() -> [WarningCase] {
        var out: [WarningCase] = []

        // 1. Relational alias — the live one on Dad's card.
        out.append(WarningCase(
            code: .relationalAlias,
            text: "Alias 'Dad' on Richard looks relational — use a Relationship row instead",
            overlay: Overlay(snapshots: [snapshot("Richard", stableID: "dad", aliases: ["Dad"], sex: .male)],
                             graph: nil),
            stableID: "dad"))

        // 2. A relationship row anchored at a profile that was deleted.
        let ghostAnchor = Kinship(relation: .sibling, relativeTo: .profile(id: UUID()))
        out.append(WarningCase(
            code: .danglingRelationshipRow,
            text: "Relationship row on Ann points at a profile that no longer exists — remove or re-pick it",
            overlay: Overlay(snapshots: [snapshot("Ann", sex: .female, kinships: [ghostAnchor])], graph: nil),
            stableID: "ann"))

        // 3. A `.treePointer` anchor whose export fingerprint is stale.
        let otherExport = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 @I7@ INDI\n1 NAME Somebody /Else/\n0 TRLR")
        let cara = snapshot("Cara", sex: .female, kinships: [
            Kinship(relation: .grandchild,
                    relativeTo: .treePointer(pointer: "@I7@", sourceFingerprint: "deadbeefdeadbeef")),
        ])
        out.append(WarningCase(
            code: .staleTreePointer,
            text: "Relationship row on Cara points at @I7@ in an older tree export — pick them again",
            overlay: Overlay(snapshots: [cara], graph: otherExport),
            stableID: "cara"))

        // 4. Two definitions of ONE profile disagreeing about the pin.
        let twice = [
            snapshot("Ma", pin: .familySearchID("GVQV-NW3")),
            snapshot("Ma", pin: .familySearchID("G2S4-JF4")),
        ]
        out.append(WarningCase(
            code: .pinDefinitionsDisagree,
            text: "Ma's duplicate profile definitions disagree about the family-tree pin — pin the profile again",
            overlay: Overlay(snapshots: twice, graph: tree),
            stableID: "ma"))

        // 5. A pin a newer build wrote.
        out.append(WarningCase(
            code: .pinUnreadable,
            text: "Beth's family-tree pin could not be read (written by a newer app version?) — kept as is, not used",
            overlay: Overlay(snapshots: [snapshot("Beth", sex: .female, unreadable: true)], graph: tree),
            stableID: "beth"))

        // 6. A pin this tree does not carry.
        out.append(WarningCase(
            code: .pinNotInTree,
            text: "Ellen's family-tree pin points at a person this tree doesn't carry — pin them again",
            overlay: Overlay(snapshots: [snapshot("Ellen", sex: .female, pin: .familySearchID("ZZZZ-999"))],
                             graph: tree),
            stableID: "ellen"))

        // 7. The same pin with no tree installed at all.
        out.append(WarningCase(
            code: .pinNoTreeInstalled,
            text: "Ellen's family-tree pin can't be checked — no tree is installed",
            overlay: Overlay(snapshots: [snapshot("Ellen", sex: .female, pin: .familySearchID("GVQV-NW3"))],
                            graph: nil),
            stableID: "ellen"))

        // 8. Two profiles pinned to one tree person.
        let collide = [
            snapshot("Dad", pin: .familySearchID("G2S4-JF4"), unreadable: false),
            snapshot("Grampa", pin: .familySearchID("G2S4-JF4")),
        ]
        out.append(WarningCase(
            code: .pinCollision,
            text: "Dad and Grampa are both pinned to Richard Harding Breen Sr in the family tree — only one profile can be that person",
            overlay: Overlay(snapshots: collide, graph: tree),
            stableID: "dad"))

        // 9. A half-sibling row whose named shared parent is gone.
        let halfRow = row(.sibling, "Tim", basis: .attestedHalf(sharedParent: .profile(name: "Ghost")))
        out.append(WarningCase(
            code: .halfSiblingParentMissing,
            text: "The shared parent named on the half-sibling row between Rick and Tim could not be found — nothing derived across that row until they are picked again",
            overlay: Overlay(snapshots: [snapshot("Rick", sex: .male, kinships: [halfRow]),
                                         snapshot("Tim", sex: .male)], graph: nil),
            stableID: "rick"))

        // 10. A sibling set that adds up to three parents (the shape from
        //     FamilyKinshipSiblingInferenceTests' namesake case).
        let conflicted = [
            snapshot("Rick", sex: .male, kinships: [row(.sibling, "Mary"), row(.child, "Ma"), row(.child, "Dad")]),
            snapshot("Mary", sex: .female, kinships: [row(.child, "Other")]),
            snapshot("Ma", sex: .female), snapshot("Dad", sex: .male), snapshot("Other", sex: .male),
        ]
        out.append(WarningCase(
            code: .derivationConflict,
            text: "Sibling rows on Mary and Rick imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected",
            overlay: Overlay(snapshots: conflicted, graph: tree),
            stableID: "rick"))

        return out
    }

    // MARK: 1. Logic — classified at the producing site, prose unchanged

    @Test func everyWarningIsClassifiedWhereItIsProducedAndKeepsItsExactWording() {
        for fixture in Self.cases() {
            let label = Comment(rawValue: fixture.code.rawValue)
            // The string API is untouched: same line, same place.
            #expect(fixture.overlay.warnings.contains(fixture.text), label)
            #expect(fixture.overlay.warnings(forProfileStableID: fixture.stableID).contains(fixture.text), label)

            let structured = fixture.overlay.structuredWarnings(forProfileStableID: fixture.stableID)
            let match = structured.first { $0.text == fixture.text }
            #expect(match?.code == fixture.code, label)
            // Byte-identical: `text` is the existing line, never a rewrite.
            #expect(match?.text == fixture.text, label)
            // And the structured list is the string list, in order.
            #expect(structured.map(\.text)
                    == fixture.overlay.warnings(forProfileStableID: fixture.stableID), label)
        }
    }

    @Test func structuredAndStringWarningsStayInStepForEveryLookup() {
        for fixture in Self.cases() {
            let label = Comment(rawValue: fixture.code.rawValue)
            #expect(fixture.overlay.structuredWarnings.map(\.text) == fixture.overlay.warnings, label)
            let named = fixture.overlay.member(
                fixture.overlay.node(profileStableID: fixture.stableID) ?? .profile(stableID: ""))?.name
            if let named {
                #expect(fixture.overlay.structuredWarnings(forProfileNamed: named).map(\.text)
                        == fixture.overlay.warnings(forProfileNamed: named), label)
            }
            let nodes = fixture.overlay.allNodes
            #expect(fixture.overlay.structuredDerivationWarnings(touching: nodes).map(\.text)
                    == fixture.overlay.derivationWarnings(touching: nodes), label)
        }
    }

    // MARK: 2. Sensors — no code without guidance, no code without a site

    @Test func everyCodeExplainsItselfAndOffersSomewhereToGo() {
        for code in Code.allCases {
            let label = Comment(rawValue: code.rawValue)
            #expect(!code.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label)
            #expect(!code.fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label)
            // The guidance is prose, not a restatement of the enum name.
            #expect(code.why.count > 40, label)
            #expect(code.fix.count > 40, label)
            if let action = code.action {
                #expect(!action.buttonTitle(personName: "Dad").isEmpty, label)
                #expect(action.buttonTitle(personName: "Dad").contains("Dad"), label)
            }
        }
        for action in KinshipWarning.Action.allCases {
            #expect(action.buttonTitle(personName: "Ma").contains("Ma"),
                    Comment(rawValue: action.rawValue))
        }
    }

    /// A new code has to arrive with a producing site and a fixture, or this
    /// fails — the counterpart to the guidance sensor above.
    @Test func everyCodeHasAProducingFixture() {
        let produced = Set(Self.cases().map(\.code))
        #expect(produced == Set(Code.allCases),
                Comment(rawValue: "missing: \(Set(Code.allCases).subtracting(produced).map(\.rawValue).sorted())"))
    }

    // MARK: 3. Identity — two Richards, one badge

    /// Codex #1019 item 4, on the live pair: Rick and his father are both
    /// "Richard" since Rick adopted surnames. Give them DIFFERENT causes and
    /// each card must carry only its own — same line, same code, same fix.
    @Test func aWarningOnOneRichardNeverReachesTheOther() {
        let alias = "Alias 'Dad' on Richard looks relational — use a Relationship row instead"
        let dangling = "Relationship row on Richard points at a profile that no longer exists — remove or re-pick it"
        // "Dad" is a relational word; "Dad Breen" is a name and is fine.
        let dad = Snapshot(stableID: "FF6C5474", canonicalName: "Richard",
                           aliases: ["Dad", "Dad Breen"], sex: .male, uuid: UUID())
        let rick = Snapshot(stableID: "71393E0E", canonicalName: "Richard",
                            aliases: ["Rick"],
                            kinships: [Kinship(relation: .sibling, relativeTo: .profile(id: UUID()))],
                            sex: .male, uuid: UUID())
        let overlay = Overlay(snapshots: [dad, rick], graph: nil)

        #expect(overlay.structuredWarnings(forProfileStableID: "FF6C5474")
                == [KinshipWarning(code: .relationalAlias, text: alias)])
        #expect(overlay.structuredWarnings(forProfileStableID: "71393E0E")
                == [KinshipWarning(code: .danglingRelationshipRow, text: dangling)])
        // Neither card is shown the other's cause, guidance or fix.
        #expect(overlay.structuredWarnings(forProfileStableID: "FF6C5474").first?.fix
                != overlay.structuredWarnings(forProfileStableID: "71393E0E").first?.fix)
        // Take the alias off and only Dad's card clears.
        let fixed = Overlay(snapshots: [Snapshot(stableID: "FF6C5474", canonicalName: "Richard",
                                                 aliases: ["Dad Breen"], sex: .male, uuid: UUID()), rick],
                            graph: nil)
        #expect(fixed.structuredWarnings(forProfileStableID: "FF6C5474").isEmpty)
        #expect(fixed.structuredWarnings(forProfileStableID: "71393E0E").count == 1)
        // The NAME form still answers for both Richards — a name is not an
        // identity — which is exactly why the card badge uses the stable id.
        #expect(overlay.structuredWarnings(forProfileNamed: "Richard").map(\.text) == [alias, dangling])
    }

    @Test func theFixButtonRoutesByUUIDNotByName() {
        let dad = POIProfile(name: "Richard", referencePath: "/fixture/dad", aliases: ["Dad"])
        let rick = POIProfile(name: "Richard", referencePath: "/fixture/rick", aliases: ["Rick"])
        #expect(dad.uuid != rick.uuid)
        #expect(PersonWarningRoute.route(for: .editRelationships, on: dad)
                == .editPerson(PersonEditRequest(dad)))
        #expect(PersonWarningRoute.route(for: .editRelationships, on: dad)
                != .editPerson(PersonEditRequest(rick)))
        #expect(PersonWarningRoute.route(for: .editPerson, on: dad)
                == .editPerson(PersonEditRequest(dad)))
        #expect(PersonWarningRoute.route(for: .openFamilyTree, on: dad)
                == .familyTree(profileUUID: dad.uuid))
        // The editor request the button builds is the SAME one the
        // double-click builds — one sheet, one person, one identity.
        #expect(PeopleCardAction.resolve(.double, on: dad, isBeingScanned: false)
                == .edit(PersonEditRequest(dad)))
    }

    // MARK: 4. View — one section per warning, in order, with its button

    @Test func thePopoverRendersASectionPerWarningInOrder() {
        let warnings = [
            KinshipWarning(code: .relationalAlias, text: "Alias 'Dad' on Richard looks relational — use a Relationship row instead"),
            KinshipWarning(code: .pinNotInTree, text: "Richard's family-tree pin points at a person this tree doesn't carry — pin them again"),
        ]
        let sections = PersonWarningPopoverModel.sections(
            for: warnings, personName: "Dad", profileID: "FF6C5474")
        #expect(sections.count == 2)
        #expect(sections.map(\.code) == [.relationalAlias, .pinNotInTree])
        #expect(sections.map(\.text) == warnings.map(\.text))
        #expect(sections[0].why == Code.relationalAlias.why)
        #expect(sections[0].fix == Code.relationalAlias.fix)
        #expect(sections[0].action == .editRelationships)
        #expect(sections[0].actionTitle == "Open Dad's Relationships")
        #expect(sections[1].action == .openFamilyTree)
        #expect(sections[1].actionTitle == "Show Dad in the Family Tree")
        // Identifiers in the house style, unique per section.
        #expect(sections[0].identifier == "pf.person.warning.section.relationalAlias.0.FF6C5474")
        #expect(sections[1].actionIdentifier == "pf.person.warning.fix.pinNotInTree.1.FF6C5474")
        #expect(Set(sections.map(\.id)).count == sections.count)
        #expect(PersonWarningPopoverModel.badgeIdentifier(personName: "Richard", profileID: "FF6C5474")
                == "pf.person.warning.Richard.FF6C5474")
        #expect(PersonWarningPopoverModel.popoverIdentifier(personName: "Richard", profileID: "FF6C5474")
                == "pf.person.warning.popover.Richard.FF6C5474")
        // Two of the same cause stay distinguishable.
        let twice = PersonWarningPopoverModel.sections(
            for: [warnings[0], warnings[0]], personName: "Dad", profileID: "FF6C5474")
        #expect(Set(twice.map(\.id)).count == 2)
        // No warnings, no sections (the triangle isn't drawn at all).
        #expect(PersonWarningPopoverModel.sections(for: [], personName: "Dad", profileID: "x").isEmpty)
        #expect(KinshipWarning.tooltip(for: []) == nil)
        // The hover tooltip is still the newline-joined summary it was.
        #expect(KinshipWarning.tooltip(for: warnings) == warnings.map(\.text).joined(separator: "\n"))
    }

    /// The end-to-end shape the card gets: overlay → popover sections, with
    /// a real warning and a real person.
    @Test func aRealWarningReachesThePopoverWithItsGuidance() {
        let dad = Snapshot(stableID: "FF6C5474", canonicalName: "Richard",
                           aliases: ["Dad"], sex: .male, uuid: UUID())
        let overlay = Overlay(snapshots: [dad], graph: nil)
        let sections = PersonWarningPopoverModel.sections(
            for: overlay.structuredWarnings(forProfileStableID: "FF6C5474"),
            personName: "Dad", profileID: "FF6C5474")
        let section = try? #require(sections.first)
        #expect(section?.text == "Alias 'Dad' on Richard looks relational — use a Relationship row instead")
        #expect(section?.why.contains("depending on who says it") == true)
        #expect(section?.fix.contains("Relationship row") == true)
        #expect(section?.action == .editRelationships)
    }

    // MARK: 5. Scale — one map per gallery evaluation, memoised

    @MainActor
    @Test func theGalleryWarningMapIsBuiltOncePerEvaluationAndMemoised() {
        var dad = POIProfile(name: "Dad", referencePath: "/fixture/dad", aliases: ["Dad Breen", "Grampa"])
        let rick = POIProfile(name: "Rick", referencePath: "/fixture/rick")
        let center = KinshipDisplayCenter()
        let profiles = [dad, rick]

        let first = center.warnings(among: profiles)
        #expect(center.warningMapBuildCount == 1)
        #expect(first[dad.id]?.map(\.code) == [.relationalAlias])
        #expect(first[rick.id] == nil)           // clean cards carry no entry

        // Twenty card bodies reading the map cost nothing.
        for _ in 0..<20 { _ = center.warnings(among: profiles) }
        #expect(center.warningMapBuildCount == 1)

        // A tree install invalidates it (a pin may resolve now).
        center.install(graph: Self.tree)
        _ = center.warnings(among: profiles)
        #expect(center.warningMapBuildCount == 2)

        // A notes edit does not — the signature covers only what warnings
        // depend on.
        var quiet = dad
        quiet.notes = "typewriter repairman"
        _ = center.warnings(among: [quiet, rick])
        #expect(center.warningMapBuildCount == 2)

        // Taking the alias off does.
        dad.aliases = ["Dad Breen"]
        let healed = center.warnings(among: [dad, rick])
        #expect(center.warningMapBuildCount == 3)
        #expect(healed.isEmpty)
    }
}
