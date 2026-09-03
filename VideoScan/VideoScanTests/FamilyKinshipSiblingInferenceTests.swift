// FamilyKinshipSiblingInferenceTests.swift
// RULING (Rick, Director, 2026-09-02 19:20): "we can do the 'children of'
// inference as part of Biography. No need to edit gedcom." The living
// family is never in the FamilySearch GEDCOM; Rick's People-tab card says
// child of Ma and Dad and sibling of Tim, Ellen and Beth, and the siblings'
// cards carry no rows — so "who are Eileen's children" listed only Rick.
//
// FamilyKinshipOverlay now derives, at read time and never stored: FULL
// SIBLINGS SHARE PARENTS. Dimensions (docs/testing_retrospective):
//   LOGIC     — Rick's exact row set; explicit rows win; a contradicting
//               sibling gets nothing; transitivity; no rows → nothing; the
//               derived marker is on derived edges only; half rows share
//               only the named parent; the graph route and the biography
//               carry the marker in their basis lines.
//   SCALE     — 100k profiles with a 1,000-long sibling chain: the
//               derivation pass is budgeted separately from the build.
//   ISOLATION — poisoned UserDefaults + 60 unrelated families: no leakage
//               either way, no warnings.
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
                    maPin: String? = nil, dadPin: String? = nil, rickPin: String? = nil,
                    extra: [Snapshot] = []) -> [Snapshot] {
    [
        snapshot("Rick", aliases: ["Richard Harding Breen Jr"], sex: .male, kinships: rick, pin: rickPin),
        snapshot("Tim", sex: .male, kinships: tim),
        snapshot("Ellen", sex: .female, kinships: ellen),
        snapshot("Beth", sex: .female, kinships: beth),
        snapshot("Ma", aliases: ["Eileen", "Eileen Latta"], sex: .female, pin: maPin),
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

    @Test func aSiblingWithADifferentExplicitParentIsNeverGivenRicksParents() {
        // Tim says "child of Other" — under the full-sibling reading that is
        // a THIRD parent for the set. Tim keeps exactly his row, nothing is
        // derived for anyone in that set, and a warning names the problem.
        let other = snapshot("Other", sex: .male)
        let overlay = Overlay(snapshots: family(tim: [row(.child, "Other")], extra: [other]), graph: nil)
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Other"])
        #expect(!names(overlay.relatives(of: node("Ma"), relation: .child)).contains("Tim"))
        #expect(overlay.derivedEdgeCount == 0)
        #expect(overlay.warnings == [
            "Sibling rows on Beth, Ellen, Rick and Tim imply more than two parents (Dad, Ma, Other) — nothing derived until one is corrected",
        ], Comment(rawValue: overlay.warnings.joined(separator: " | ")))
    }

    @Test func aSiblingWithOneOfTheSameParentsKeepsOnlyThatRow() {
        // Tim records only Dad: he is not given Ma (his rows stand as they
        // are — conservative), while Ellen and Beth still get both.
        let overlay = Overlay(snapshots: family(tim: [row(.child, "Dad")]), graph: nil)
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Dad"])
        #expect(names(overlay.relatives(of: node("Beth"), relation: .parent)) == ["Dad", "Ma"])
        #expect(overlay.warnings.isEmpty)
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
        // Parents without a sibling row: nothing to share them with.
        let parentsOnly = Overlay(snapshots: family(rick: [row(.child, "Ma")]), graph: nil)
        #expect(parentsOnly.derivedEdgeCount == 0)
        #expect(names(parentsOnly.relatives(of: node("Ma"), relation: .child)) == ["Rick"])
    }

    @Test func derivedFactsCarryTheMarkerAndStoredOnesDoNot() {
        let overlay = Overlay(snapshots: family(), graph: nil)
        // Stored rows: never marked; `edges(from:)` (the engine's view) is
        // stored-only and unchanged by the derivation.
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

    // MARK: Graph route + biography basis wording

    /// The executor's own snapshot type (same fields, carried separately).
    private func turnSnapshot(_ s: Snapshot) -> HallieTurnExecutor.ProfileSnapshot {
        .init(stableID: s.stableID, canonicalName: s.canonicalName, aliases: s.aliases,
              kinships: s.kinships, sex: s.sex, uuid: s.uuid, treeIdentity: s.treeIdentity)
    }

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
            // Each People-tab claim cites the subject's record and the
            // three profiles' durable identities.
            let plan = try #require(r.answerPlan)
            let claim = try #require(plan.claims.first { $0.text.hasPrefix("In the People tab: Beth") })
            #expect(claim.evidenceIDs.first == "@I3@")
            #expect(claim.evidenceIDs.count == 4)
        }
    }

    @Test func aBiographyWithoutDerivedKinKeepsTheOldBasisShape() async throws {
        let r = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Rick"], operation: .biography)), context: context())
        #expect(r.prose.contains("In the People tab: Beth — sister, Ellen — sister and Tim — brother."), Comment(rawValue: r.prose))
        #expect(r.basisLine.hasSuffix("People tab relationships (stored on Rick's profile); local only, not from the family tree."),
                Comment(rawValue: r.basisLine))
    }
}

// MARK: - Scale

@Suite("Full siblings share parents — scale")
struct FamilyKinshipSiblingInferenceScaleTests {

    /// 100k profiles; 1,000 of them form one sibling chain (S_i sibling of
    /// S_{i-1}) whose head alone records two parents. The derivation pass
    /// is budgeted as the DIFFERENCE between that build and the same 100k
    /// with no rows at all, so the resolver/pass-1 cost of 100k names does
    /// not hide (or inflate) the number.
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
        let clock = ContinuousClock()
        var baseline: Overlay?
        let base = clock.measure { baseline = Overlay(snapshots: profiles(withChain: false), graph: nil) }
        var chained: Overlay?
        let full = clock.measure { chained = Overlay(snapshots: profiles(withChain: true), graph: nil) }
        #expect(baseline?.derivedEdgeCount == 0)
        // 999 orphans × 2 parents × 2 directions.
        #expect(chained?.derivedEdgeCount == 3_996)
        #expect(names(chained?.relatives(of: node("S999"), relation: .parent) ?? []) == ["PA", "PB"])
        #expect(chained?.relatives(of: node("PA"), relation: .child).count == 1_000)
        let delta = full - base
        #expect(delta < .milliseconds(200),
                "rows + derivation over 100k profiles took \(delta) (build with chain \(full), without \(base))")
    }
}

// MARK: - Isolation

@Suite("Full siblings share parents — isolation")
struct FamilyKinshipSiblingInferenceIsolationTests {

    /// The overlay reads the snapshots it is given and nothing else: a
    /// poisoned preference and sixty unrelated families with their own
    /// sibling chains change nothing about Eileen's children, and Rick's
    /// parents never reach a stranger.
    @Test func poisonedDefaultsAndUnrelatedFamiliesDoNotLeak() {
        let poisonKey = OllamaEndpoints.hostsKey
        let prior = UserDefaults.standard.object(forKey: poisonKey)
        UserDefaults.standard.set("poison.invalid", forKey: poisonKey)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: poisonKey) }
            else { UserDefaults.standard.removeObject(forKey: poisonKey) }
        }
        var strangers: [Snapshot] = []
        for f in 0..<60 {
            strangers.append(snapshot("Parent\(f)A", sex: .male))
            strangers.append(snapshot("Parent\(f)B", sex: .female))
            strangers.append(snapshot("Kid\(f)-0", sex: .male,
                                      kinships: [row(.child, "Parent\(f)A"), row(.child, "Parent\(f)B")]))
            for k in 1..<4 {
                strangers.append(snapshot("Kid\(f)-\(k)", sex: .female, kinships: [row(.sibling, "Kid\(f)-\(k - 1)")]))
            }
        }
        let overlay = Overlay(snapshots: family(extra: strangers), graph: nil)
        #expect(names(overlay.relatives(of: node("Ma"), relation: .child)) == ["Beth", "Ellen", "Rick", "Tim"])
        #expect(names(overlay.relatives(of: node("Tim"), relation: .parent)) == ["Dad", "Ma"])
        #expect(names(overlay.relatives(of: node("Kid7-3"), relation: .parent)) == ["Parent7A", "Parent7B"])
        #expect(overlay.derivationNote(for: overlay.relatives(of: node("Kid7-3"), relation: .parent)[0].hops)
                == "derived from Kid7-0's rows: full siblings share parents (sibling rows on Kid7-1, Kid7-2 and Kid7-3)")
        // 12 for Rick's family + 60 × (3 orphans × 2 parents × 2 directions).
        #expect(overlay.derivedEdgeCount == 12 + 60 * 12)
        #expect(overlay.warnings.isEmpty, Comment(rawValue: overlay.warnings.joined(separator: " | ")))
        #expect(UserDefaults.standard.string(forKey: poisonKey) == "poison.invalid")
    }
}
