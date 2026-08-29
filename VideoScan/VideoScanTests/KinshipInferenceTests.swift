// KinshipInferenceTests.swift
// Design docs/kinship_inference_design.md §1 (validation) + §2 (derivation),
// 2026-08-29. Five dimensions:
//   1. Logic     — derivation matrix on Rick's family; validation rule matrix
//   2. Scale     — 100 contemporaries × 5k-person synthetic tree, 1,000
//                  random pair queries, < 50 ms each on average (Debug)
//   3. Media     — n/a
//   4. Isolation — in-memory profiles + GEDCOM text only; no App Support,
//                  no UserDefaults
//   5. Sensors   — "Tim ↔ Martha Lamson = 8th-great-grandmother through
//                  Rick's parents" pinned; "validation never blocks a legal
//                  save" pinned over every fixture row
// The GEDCOM is synthetic (2026-08-03 privacy policy): Sr's line above him
// is invented, only the two Richards' FamilySearch IDs are the real fixture
// IDs already in FamilyKinshipTests.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Shared fixture

enum KinshipFixture {

    static func date(_ y: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = 6; dc.day = 15; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    static func profile(
        _ name: String, aliases: [String] = [], sex: PersonSex? = nil,
        born: Int? = nil, kinships: [Kinship] = []
    ) -> POIProfile {
        POIProfile(name: name, referencePath: "/fixture/\(name)", aliases: aliases,
                   birthdate: born.map(date), sex: sex, kinships: kinships)
    }

    static func row(_ relation: KinshipRelation, of name: String) -> Kinship {
        Kinship(relation: relation, relativeTo: .profile(name: name))
    }

    static let sons = ["Michael", "Kevin", "Brian", "Timothy"]

    /// Rick's family, primitives only (design §"Model"):
    ///   Dad (Sr, tree @I2@) + Eileen → Rick (tree @I1@) ═ Donna → four sons
    ///   Tim: ONE sibling row on Rick, no parent rows (the assumed-full case)
    ///   Ann: Donna's sister (sibling row on Donna) ═ Bob
    ///   Nana: no rows (validation prop for the spouse-age-gap warning)
    static let family: [POIProfile] = [
        profile("Rick", aliases: ["Richard Harding Breen Jr"], sex: .male, born: 1962,
                kinships: [row(.child, of: "Dad")]),
        profile("Dad", aliases: ["Richard Harding Breen Sr"], sex: .male, born: 1931),
        profile("Eileen", aliases: ["Eileen Latta"], sex: .female, born: 1935,
                kinships: [row(.parent, of: "Rick")]),
        profile("Tim", sex: .male, born: 1965, kinships: [row(.sibling, of: "Rick")]),
        profile("Donna", sex: .female, born: 1959, kinships: [row(.spouse, of: "Rick")]),
        profile("Michael", sex: .male, born: 1984, kinships: [row(.child, of: "Rick")]),
        profile("Kevin", sex: .male, born: 1986, kinships: [row(.child, of: "Rick")]),
        profile("Brian", sex: .male, born: 1988, kinships: [row(.child, of: "Rick")]),
        profile("Timothy", sex: .male, born: 1990, kinships: [row(.child, of: "Rick")]),
        profile("Ann", sex: .female, born: 1961, kinships: [row(.sibling, of: "Donna")]),
        profile("Bob", sex: .male, born: 1958, kinships: [row(.spouse, of: "Ann")]),
        profile("Nana", sex: .female, born: 1905),
    ]

    /// Jr (@I1@) ← Sr (@I2@) ← A1 … ← A9 = Martha Lamson: nine generations
    /// above Sr, so she is ten above Rick/Tim = 8th-great-grandmother.
    /// Side branch for cousin reckoning: A2 also has a son X1 (Sr's uncle),
    /// whose son is X2.
    static let tree: String = {
        var lines = ["0 HEAD",
                     "0 @I1@ INDI", "1 NAME Richard Harding /Breen/ Jr", "1 SEX M", "1 _FSFTID GVQV-NW3", "1 FAMC @F0@",
                     "0 @I2@ INDI", "1 NAME Richard Harding /Breen/ Sr", "1 SEX M", "1 _FSFTID G2S4-JF4",
                     "1 BIRT", "2 DATE 1931", "1 FAMS @F0@", "1 FAMC @F1@",
                     "0 @F0@ FAM", "1 HUSB @I2@", "1 CHIL @I1@"]
        for g in 1...9 {
            let name = g == 9 ? "Martha /Lamson/" : "Ancestor\(g) /Breen/"
            let sex = g == 9 ? "F" : (g % 2 == 1 ? "M" : "F")
            lines += ["0 @A\(g)@ INDI", "1 NAME \(name)", "1 SEX \(sex)",
                      "1 BIRT", "2 DATE \(1931 - 28 * g)", "1 FAMS @F\(g)@"]
            if g < 9 { lines.append("1 FAMC @F\(g + 1)@") }
            let child = g == 1 ? "@I2@" : "@A\(g - 1)@"
            lines += ["0 @F\(g)@ FAM", "1 \(sex == "M" ? "HUSB" : "WIFE") @A\(g)@", "1 CHIL \(child)"]
        }
        // Side branch under A2: X1 (child of A2) and X2 (child of X1).
        lines += ["0 @X1@ INDI", "1 NAME Xavier /Breen/", "1 SEX M", "1 FAMC @F2@", "1 FAMS @FX@",
                  "0 @X2@ INDI", "1 NAME Xena /Breen/", "1 SEX F", "1 FAMC @FX@",
                  "0 @FX@ FAM", "1 HUSB @X1@", "1 CHIL @X2@"]
        // A2's family also lists X1 as a child.
        if let i = lines.firstIndex(of: "0 @F2@ FAM") {
            lines.insert("1 CHIL @X1@", at: i + 3)
        }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }()

    static var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: tree) }

    static func inference(_ profiles: [POIProfile] = family, graph: GedcomFamilyGraph? = KinshipFixture.graph)
        -> FamilyKinshipInference {
        FamilyKinshipInference(profiles: profiles, graph: graph)
    }

    static func node(_ name: String, in inference: FamilyKinshipInference) -> FamilyKinshipInference.Node {
        inference.overlay.node(profileStableID: name.lowercased()) ?? .profile(stableID: name.lowercased())
    }
}

// MARK: - §2 Derivation

struct KinshipInferenceTests {

    private let inf = KinshipFixture.inference()
    private func n(_ name: String) -> FamilyKinshipInference.Node { KinshipFixture.node(name, in: inf) }

    @Test func profilesAnchoredToTreePeopleShareTheVertex() {
        #expect(n("Rick") == .tree(gedcomID: "@I1@"))
        #expect(n("Dad") == .tree(gedcomID: "@I2@"))
        #expect(inf.name(of: .tree(gedcomID: "@A9@")) == "Martha Lamson")
    }

    @Test func timIsUncleOfEachSonAndTheyAreHisNephews() {
        for son in KinshipFixture.sons {
            let d = inf.relation(from: n(son), to: n("Tim"))
            #expect(d?.term == "uncle", Comment(rawValue: son))
            #expect(d?.routeText == "father Rick → brother Tim", Comment(rawValue: son))
            #expect(inf.relation(from: n("Tim"), to: n(son))?.term == "nephew", Comment(rawValue: son))
        }
    }

    @Test func timIsDonnasBrotherInLaw() {
        let d = inf.relation(from: n("Donna"), to: n("Tim"))
        #expect(d?.term == "brother-in-law")
        #expect(d?.routeText == "husband Rick → brother Tim")
        #expect(inf.relation(from: n("Tim"), to: n("Donna"))?.term == "sister-in-law")
        #expect(d?.isAssumed == false)
    }

    @Test func timsParentsAreDerivedThroughTheSiblingRowAndFlaggedAssumedFull() {
        let parents = inf.parents(of: n("Tim"))
        #expect(parents.map(\.node) == [n("Dad"), n("Eileen")])
        #expect(parents.allSatisfy { $0.provenance == .assumedFullSibling(via: "Rick") })
        #expect(inf.explicitParents(of: n("Tim")).isEmpty)

        let father = inf.relation(from: n("Tim"), to: n("Dad"))
        #expect(father?.term == "father")
        #expect(father?.isAssumed == true)
        #expect(father?.caveats == ["Tim's parents are assumed from Rick's (sibling entered without shared parents — assumed full)"])
        #expect(inf.relation(from: n("Tim"), to: n("Eileen"))?.term == "mother")
        #expect(inf.relation(from: n("Dad"), to: n("Tim"))?.term == "son")
    }

    @Test func rickIsTimsOlderBrotherByBirthYear() {
        #expect(inf.relation(from: n("Tim"), to: n("Rick"))?.term == "older brother")
        #expect(inf.relation(from: n("Rick"), to: n("Tim"))?.term == "younger brother")
        #expect(inf.relation(from: n("Rick"), to: n("Tim"))?.provenance == [.profileRow(storedOn: "Tim")])
    }

    @Test func bobIsRicksBrotherInLawViaRoute() {
        let d = inf.relation(from: n("Rick"), to: n("Bob"))
        #expect(d?.term == "brother-in-law")
        #expect(d?.routeText == "sister-in-law Ann → husband Bob")
        #expect(d?.route.map(\.relation) == [.spouse, .sibling, .spouse])
        #expect(inf.relation(from: n("Bob"), to: n("Rick"))?.term == "brother-in-law")
    }

    /// SENSOR: through Rick's parents (assumed full) and the tree.
    @Test func timToMarthaLamsonIsEighthGreatGrandmother() {
        let martha = FamilyKinshipInference.Node.tree(gedcomID: "@A9@")
        let d = inf.relation(from: n("Tim"), to: martha)
        #expect(d?.term == "8th-great-grandmother")
        #expect(d?.route.count == 10)
        #expect(d?.route.first?.provenance == .assumedFullSibling(via: "Rick"))
        #expect(d?.usesTree == true)
        #expect(d?.isAssumed == true)
        #expect(d?.routeText.hasPrefix("father Dad → father Ancestor1 Breen → mother Ancestor2 Breen") == true)
        #expect(d?.routeText.hasSuffix("→ mother Martha Lamson") == true)
        // Rick reaches her the same way without the assumption.
        let fromRick = inf.relation(from: n("Rick"), to: martha)
        #expect(fromRick?.term == "8th-great-grandmother")
        #expect(fromRick?.isAssumed == false)
        // And back down.
        #expect(inf.relation(from: martha, to: n("Tim"))?.term == "8th-great-grandson")
        #expect(inf.relation(from: martha, to: n("Rick"))?.term == "8th-great-grandson")
    }

    @Test func lineAndCollateralTermsThroughTheTree() {
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@A1@"))?.term == "grandfather")
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@A2@"))?.term == "great-grandmother")
        #expect(inf.relation(from: n("Michael"), to: .tree(gedcomID: "@A1@"))?.term == "great-grandfather")
        #expect(inf.relation(from: n("Michael"), to: .tree(gedcomID: "@A9@"))?.term == "9th-great-grandmother")
        // X1 is Sr's uncle → Rick's great-uncle; X2 is Sr's 1st cousin →
        // Rick's 1st cousin once removed; Michael's 1st cousin twice removed.
        #expect(inf.relation(from: n("Dad"), to: .tree(gedcomID: "@X1@"))?.term == "uncle")
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@X1@"))?.term == "great-uncle")
        #expect(inf.relation(from: n("Dad"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin")
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin once removed")
        #expect(inf.relation(from: n("Michael"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin twice removed")
        #expect(inf.relation(from: n("Tim"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin once removed")
        #expect(inf.relation(from: .tree(gedcomID: "@X1@"), to: n("Rick"))?.term == "great-nephew")
    }

    @Test func grandparentsInLawsAndSonsInLawCompose() {
        #expect(inf.relation(from: n("Michael"), to: n("Dad"))?.term == "grandfather")
        #expect(inf.relation(from: n("Dad"), to: n("Kevin"))?.term == "grandson")
        #expect(inf.relation(from: n("Donna"), to: n("Dad"))?.term == "father-in-law")
        #expect(inf.relation(from: n("Dad"), to: n("Donna"))?.term == "daughter-in-law")
        // The sons carry child rows on Rick ONLY, so Donna's side is not
        // lineal for them: Ann is "father Rick → sister-in-law Ann", no word.
        let annViaRick = inf.relation(from: n("Michael"), to: n("Ann"))
        #expect(annViaRick?.term == nil)
        #expect(annViaRick?.routeText == "father Rick → sister-in-law Ann")
        // With Donna recorded as a parent too, the aunt and her husband fold.
        var both = KinshipFixture.family
        both[both.firstIndex { $0.name == "Michael" }!].kinships.append(KinshipFixture.row(.child, of: "Donna"))
        let inf2 = KinshipFixture.inference(both)
        #expect(inf2.relation(from: KinshipFixture.node("Michael", in: inf2), to: KinshipFixture.node("Ann", in: inf2))?.term == "aunt")
        #expect(inf2.relation(from: KinshipFixture.node("Michael", in: inf2), to: KinshipFixture.node("Bob", in: inf2))?.term == "uncle")   // by marriage (existing fold)
        #expect(inf.relation(from: n("Michael"), to: n("Kevin"))?.term == "younger brother")
        #expect(inf.relation(from: n("Kevin"), to: n("Michael"))?.term == "older brother")
    }

    @Test func neverFoldsThroughTwoSpouseHopsOrInventsStepRelations() {
        let profiles = KinshipFixture.family + [
            KinshipFixture.profile("Cyn", sex: .female, kinships: [KinshipFixture.row(.spouse, of: "Bob")]),
        ]
        let inf = KinshipFixture.inference(profiles)
        let cyn = inf.relation(from: KinshipFixture.node("Rick", in: inf), to: KinshipFixture.node("Cyn", in: inf))
        #expect(cyn?.term == nil)
        #expect(cyn?.routeText == "brother-in-law Bob → wife Cyn")
        // Eileen's spouse's other child is NOT invented as her child: Sr's
        // tree side has no such person, so use Donna: Donna → Tim's parents
        // are not Donna's parents (spouse ∘ parent = in-law, never parent).
        #expect(inf.relation(from: KinshipFixture.node("Donna", in: inf),
                             to: KinshipFixture.node("Eileen", in: inf))?.term == "mother-in-law")
        #expect(KinshipChainNamer.name([.spouse, .spouse]) == nil)
        #expect(KinshipChainNamer.name([.sibling, .sibling]) == nil)
        #expect(KinshipChainNamer.name([.parent, .spouse]) == nil)
        #expect(KinshipChainNamer.name([.spouse, .child]) == nil)
        #expect(KinshipChainNamer.name([.sibling, .spouse, .spouse]) == nil)
        #expect(KinshipChainNamer.name([.spouse, .sibling, .spouse]) == .relation(.siblingInLaw))
    }

    @Test func halfSiblingsNeedExactlyOneSharedParentWithBothPairsKnown() {
        let profiles = [
            KinshipFixture.profile("P1", sex: .male), KinshipFixture.profile("P2", sex: .female),
            KinshipFixture.profile("P3", sex: .female),
            KinshipFixture.profile("Al", sex: .male, born: 1970,
                                   kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
            KinshipFixture.profile("Ben", sex: .male, born: 1975,
                                   kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P3")]),
            KinshipFixture.profile("Cal", sex: .male, born: 1980,
                                   kinships: [KinshipFixture.row(.child, of: "P1")]),
            KinshipFixture.profile("Dee", sex: .female, born: 1972,
                                   kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
        ]
        let inf = KinshipFixture.inference(profiles, graph: nil)
        func n(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: inf) }
        #expect(inf.relation(from: n("Al"), to: n("Ben"))?.term == "younger half-brother")
        #expect(inf.relation(from: n("Ben"), to: n("Al"))?.term == "older half-brother")
        #expect(inf.relation(from: n("Al"), to: n("Cal"))?.term == "younger brother")     // default full
        #expect(inf.relation(from: n("Al"), to: n("Dee"))?.term == "younger sister")
        #expect(inf.relation(from: n("Dee"), to: n("Al"))?.term == "older brother")
    }

    @Test func derivedRelativesOfTimListsTheContemporaries() {
        let all = inf.derivedRelatives(of: n("Tim"))
        var byName: [String: String?] = [:]
        for d in all { byName[inf.name(of: d.to)] = d.term }
        #expect(byName["Rick"] == "older brother")
        #expect(byName["Dad"] == "father")
        #expect(byName["Eileen"] == "mother")
        #expect(byName["Donna"] == "sister-in-law")
        for son in KinshipFixture.sons { #expect(byName[son] == "nephew", Comment(rawValue: son)) }
        #expect(byName["Ann"] == .some(nil))          // brother's wife's sister: route only
        #expect(byName["Nana"] == nil)                // unreachable
    }

    @Test func overlayTermUsesTheSameComposerForGreatGrand() {
        // Three profile-only parent hops: the old fold table said nil
        // ("out of vocabulary"); the one composer now says great-grandfather.
        let profiles = [
            KinshipFixture.profile("G3", sex: .male),
            KinshipFixture.profile("G2", sex: .female, kinships: [KinshipFixture.row(.child, of: "G3")]),
            KinshipFixture.profile("G1", sex: .male, kinships: [KinshipFixture.row(.child, of: "G2")]),
            KinshipFixture.profile("Me", sex: .male, kinships: [KinshipFixture.row(.child, of: "G1")]),
        ]
        let overlay = FamilyKinshipOverlay(profiles: profiles, graph: nil)
        let hops = overlay.path(from: .profile(stableID: "me"), to: .profile(stableID: "g3"))
        #expect(hops?.count == 3)
        #expect(overlay.term(for: hops ?? []) == "great-grandfather")
        #expect(overlay.term(for: Array((hops ?? []).prefix(2))) == "grandmother")
        // The closed table is untouched (pinned elsewhere): still nil.
        #expect(KinshipRelation.compose([.parent, .parent, .parent]) == nil)
    }

    @Test func nothingLinksTwoStrangers() {
        #expect(inf.relation(from: n("Nana"), to: n("Rick")) == nil)
        #expect(inf.relation(from: n("Rick"), to: n("Rick")) == nil)
    }

    // MARK: 2. Scale

    /// 100 contemporaries over a 5,001-person pedigree; 1,000 random pair
    /// queries must average < 50 ms in Debug.
    @Test func hundredProfilesOverFiveThousandTreePeopleAnswerUnder50msEach() {
        // Pedigree of @P1@: person i has parents 2i (M) and 2i+1 (F).
        var lines = ["0 HEAD"]
        for i in 1...5001 {
            let depth = Int(log2(Double(i)))
            lines += ["0 @P\(i)@ INDI", "1 NAME Person\(i) /Line/", "1 SEX \(i % 2 == 0 ? "M" : "F")",
                      "1 BIRT", "2 DATE \(1962 - 28 * depth)"]
            if i <= 2500 { lines.append("1 FAMC @F\(i)@") }
            if i >= 2 { lines.append("1 FAMS @F\(i / 2)@") }
        }
        for i in 1...2500 {
            lines += ["0 @F\(i)@ FAM", "1 HUSB @P\(2 * i)@", "1 WIFE @P\(2 * i + 1)@", "1 CHIL @P\(i)@"]
        }
        lines.append("0 TRLR")
        let graph = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        #expect(graph.people.count == 5001)

        // 20 profiles anchored to tree people at assorted depths, 80 more
        // contemporaries hanging off earlier profiles by primitive rows.
        var rng = SplitMix(seed: 0x5EED_2026)
        var profiles: [POIProfile] = []
        let anchors = [1, 2, 3, 6, 7, 12, 13, 25, 51, 101, 203, 407, 815, 1631, 2000, 2500, 3001, 4001, 4500, 5001]
        for (k, p) in anchors.enumerated() {
            profiles.append(KinshipFixture.profile("C\(k)", aliases: ["Person\(p) Line"],
                                                   sex: p % 2 == 0 ? .male : .female, born: 1900 + k))
        }
        for k in 20..<100 {
            let target = "C\(Int(rng.next() % UInt64(k)))"
            let relation: KinshipRelation = [.child, .spouse, .sibling, .child][Int(rng.next() % 4)]
            profiles.append(KinshipFixture.profile("C\(k)", sex: k % 2 == 0 ? .male : .female,
                                                   born: 1920 + k % 60,
                                                   kinships: [KinshipFixture.row(relation, of: target)]))
        }
        let inf = FamilyKinshipInference(profiles: profiles, graph: graph)
        let nodes = (0..<100).map { KinshipFixture.node("C\($0)", in: inf) }
        var pairs: [(FamilyKinshipInference.Node, FamilyKinshipInference.Node)] = []
        for _ in 0..<1000 {
            pairs.append((nodes[Int(rng.next() % 100)], nodes[Int(rng.next() % 100)]))
        }
        var answered = 0, named = 0
        let elapsed = ContinuousClock().measure {
            for (a, b) in pairs {
                if let d = inf.relation(from: a, to: b) {
                    answered += 1
                    if d.term != nil { named += 1 }
                }
            }
        }
        let perQuery = elapsed / 1000
        #expect(perQuery < .milliseconds(50), "avg \(perQuery) per query (\(answered) answered, \(named) named)")
        #expect(answered > 0)
    }

    /// Deterministic PRNG (SplitMix64) so the scale fixture is reproducible.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

// MARK: - §1 Validation

struct KinshipValidationTests {

    private let inf = KinshipFixture.inference()

    private func validate(_ subject: String, _ relation: KinshipRelation, of anchor: String,
                          term: String? = nil, inference: FamilyKinshipInference? = nil)
        -> [KinshipValidation.Finding] {
        let inf = inference ?? self.inf
        let existing = KinshipFixture.family.first { $0.name == subject }?.kinships ?? []
        return KinshipValidation.validate(
            candidate: Kinship(relation: relation, relativeTo: .profile(name: anchor)),
            enteredTerm: term, subjectProfileStableID: subject.lowercased(),
            existingRows: existing, inference: inf)
    }

    private func rules(_ findings: [KinshipValidation.Finding]) -> [KinshipValidation.Rule] { findings.map(\.rule) }

    @Test func derivedKindsAreNotEntered() {
        let f = validate("Tim", .auntUncle, of: "Michael")
        #expect(rules(f) == [.derivedNotEntered])
        #expect(f.blocksSave)
        #expect(f[0].message.hasPrefix("“aunt or uncle” is derived, not entered"))
        for derived in KinshipRelation.allCases where !FamilyKinshipInference.primitives.contains(derived) {
            #expect(validate("Tim", derived, of: "Rick").blocksSave, Comment(rawValue: derived.rawValue))
        }
    }

    @Test func selfRelationAndSpouseOfSelf() {
        let child = validate("Rick", .child, of: "Rick")
        #expect(rules(child) == [.selfRelation])
        #expect(child[0].message == "Rick can't be their own son.")
        let spouse = validate("Donna", .spouse, of: "Donna")
        #expect(rules(spouse) == [.spouseOfSelf])
        #expect(spouse[0].message == "Donna can't be their own wife.")
    }

    @Test func duplicateRowFromEitherSide() {
        // Same row again on Tim.
        #expect(rules(validate("Tim", .sibling, of: "Rick")).contains(.duplicateRow))
        // The inverse already implied by Tim's row, entered on Rick.
        #expect(rules(validate("Rick", .sibling, of: "Tim")).contains(.duplicateRow))
        // Donna's spouse row seen from Rick's side.
        #expect(rules(validate("Rick", .spouse, of: "Donna")).contains(.duplicateRow))
    }

    @Test func parentChildCyclesOfAnyLengthIncludingTreeAncestors() {
        // Length 2 via rows: Dad as Michael's child (Dad → Rick → Michael).
        let short = validate("Dad", .child, of: "Michael")
        #expect(rules(short).contains(.parentChildCycle))
        // Michael as Dad's parent.
        #expect(rules(validate("Michael", .parent, of: "Dad")).contains(.parentChildCycle))
        // Length 11 through the tree: Rick as Martha Lamson's parent.
        let long = KinshipValidation.validate(
            candidate: Kinship(relation: .parent, relativeTo: .treePerson(familySearchID: "NOPE")),
            subjectProfileStableID: "rick", existingRows: [], inference: inf)
        #expect(rules(long) == [.unresolvedAnchor])   // unknown FSID: honest, not a guess
        let profiles = KinshipFixture.family + [
            KinshipFixture.profile("Martha", aliases: ["Martha Lamson"], sex: .female),
        ]
        let inf2 = KinshipFixture.inference(profiles)
        #expect(KinshipFixture.node("Martha", in: inf2) == .tree(gedcomID: "@A9@"))
        let viaTree = validate("Rick", .parent, of: "Martha", inference: inf2)
        #expect(rules(viaTree).contains(.parentChildCycle))
        #expect(viaTree.blocksSave)
        let asChildOfDescendant = validate("Martha", .child, of: "Kevin", inference: inf2)
        #expect(rules(asChildOfDescendant).contains(.parentChildCycle))
    }

    @Test func moreThanTwoParentsIsAnError() {
        // Rick has Dad (row + tree) and Eileen (row).
        let f = validate("Rick", .child, of: "Ann")
        #expect(rules(f) == [.tooManyParents])
        #expect(f[0].message == "Rick already has two parents recorded (Dad and Eileen) — remove one before adding a third.")
        #expect(rules(validate("Nana", .parent, of: "Rick")) == [.tooManyParents])
        // Re-stating an existing parent is a duplicate, not a third parent.
        #expect(rules(validate("Rick", .child, of: "Dad")) == [.duplicateRow])
    }

    @Test func parentNotOlderIsAWarningNotABlock() {
        let f = validate("Tim", .parent, of: "Ann")     // Tim 1965, Ann 1961
        #expect(rules(f) == [.parentNotOlder])
        #expect(!f.blocksSave)
        #expect(f[0].message == "Tim (born 1965) is not older than Ann (born 1961) — check the birthdates.")
        #expect(rules(validate("Ann", .child, of: "Tim")) == [.parentNotOlder])
        #expect(validate("Nana", .parent, of: "Ann").isEmpty)    // 1905 → fine
    }

    @Test func spouseBirthYearsMoreThanFortyApartWarn() {
        let f = validate("Bob", .spouse, of: "Nana")   // 1958 vs 1905
        #expect(rules(f) == [.spouseAgeGap])
        #expect(!f.blocksSave)
        #expect(f[0].message == "Bob and Nana were born 53 years apart — check the birthdates.")
        #expect(validate("Tim", .spouse, of: "Nana").isEmpty == false)
        #expect(validate("Kevin", .spouse, of: "Nana").blocksSave == false)
    }

    @Test func genderedTermAgainstKnownSexWarnsAndSavesNeutral() {
        let f = validate("Tim", .sibling, of: "Ann", term: "sister")
        #expect(rules(f) == [.sexMismatch])
        #expect(f[0].message == "You entered “sister” but Tim's profile says male — saving as “sibling”.")
        #expect(validate("Tim", .sibling, of: "Ann", term: "brother").isEmpty)
        #expect(validate("Tim", .sibling, of: "Ann", term: "sibling").isEmpty)
        // Unknown sex: no warning either way.
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Pat")]
        let inf2 = KinshipFixture.inference(profiles)
        #expect(validate("Pat", .sibling, of: "Ann", term: "sister", inference: inf2).isEmpty)
    }

    @Test func siblingRowWhileBothParentsRecordedSuggestsConversion() {
        let f = validate("Ann", .sibling, of: "Rick")
        #expect(rules(f) == [.siblingWithParentsRecorded])
        #expect(!f.blocksSave)
        #expect(f[0].message == "Rick's parents are both recorded (Dad and Eileen) — record Ann as their child instead and the sibling link is derived (convert to shared parents).")
        // Neither side has two parents: no nudge.
        #expect(validate("Bob", .sibling, of: "Nana").isEmpty)
    }

    @Test func legalRowsPassClean() {
        #expect(validate("Kevin", .child, of: "Donna").isEmpty)
        #expect(validate("Nana", .parent, of: "Donna").isEmpty)
        #expect(validate("Bob", .sibling, of: "Nana").isEmpty)
        #expect(validate("Tim", .spouse, of: "Nana", term: "husband").isEmpty == false)   // gap warning only
        #expect(validate("Tim", .spouse, of: "Nana").blocksSave == false)
    }

    /// SENSOR: validation never blocks a legal save — every row in the
    /// fixture, re-validated against the family WITHOUT that row, produces
    /// no error.
    @Test func everyFixtureRowRevalidatesWithoutErrors() {
        for profile in KinshipFixture.family {
            for (i, row) in profile.kinships.enumerated() {
                var without = KinshipFixture.family
                if let idx = without.firstIndex(where: { $0.name == profile.name }) {
                    without[idx].kinships.remove(at: i)
                }
                var remaining = profile.kinships
                remaining.remove(at: i)
                let findings = KinshipValidation.validate(
                    candidate: row, subjectProfileStableID: profile.id,
                    existingRows: remaining, inference: KinshipFixture.inference(without))
                #expect(!findings.blocksSave,
                        "\(profile.name) \(row.relation.rawValue) of \(row.relativeTo.key): \(findings.map(\.message))")
            }
        }
    }
}
