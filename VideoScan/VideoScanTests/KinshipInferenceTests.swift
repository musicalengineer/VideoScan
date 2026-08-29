// KinshipInferenceTests.swift
// Design docs/kinship_inference_design.md §1 (validation) + §2 (derivation)
// with the amendments after codex review #830/#831/#833, 2026-08-29.
// Five dimensions:
//   1. Logic     — derivation matrix on Rick's family; validation rule matrix;
//                  identity pins (stale / colliding fail closed); sibling
//                  basis both outcomes; date precision; determinism
//   2. Scale     — 100 contemporaries × 5k-person synthetic tree, 1,000
//                  random pair queries, < 50 ms each on average (Debug)
//   3. Media     — n/a
//   4. Isolation — in-memory profiles + GEDCOM text only; no App Support,
//                  no UserDefaults
//   5. Sensors   — "Tim ↔ Martha Lamson = 8th-great-grandmother" pinned in
//                  BOTH sibling-basis outcomes; "validation never blocks a
//                  legal save" pinned over every fixture row
// The GEDCOM is synthetic (2026-08-03 privacy policy): Sr's line above him
// is invented; only the two Richards' FamilySearch IDs are the real fixture
// IDs already used in FamilyKinshipTests.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Shared fixture

enum KinshipFixture {

    static func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    static func profile(
        _ name: String, aliases: [String] = [], sex: PersonSex? = nil,
        born: Int? = nil, kinships: [Kinship] = [], pin: String? = nil
    ) -> POIProfile {
        POIProfile(name: name, referencePath: "/fixture/\(name)", aliases: aliases,
                   birthdate: born.map { date($0) }, sex: sex, kinships: kinships,
                   treeIdentity: pin.map { .familySearchID($0) })
    }

    static func row(_ relation: KinshipRelation, of name: String, basis: SiblingBasis = .unspecified) -> Kinship {
        Kinship(relation: relation, relativeTo: .profile(name: name), basis: basis)
    }

    static let sons = ["Michael", "Kevin", "Brian", "Timothy"]

    /// Rick's family, primitives only. Rick, Dad and Donna are PINNED to
    /// their tree records (identity ≠ relationship); nobody else is.
    ///   Dad (Sr) + Eileen → Rick ═ Donna → four sons (child rows on Rick)
    ///   Tim: ONE sibling row on Rick, basis `unspecified`, no parent rows
    ///   Ann: Donna's sister (sibling row on Donna) ═ Bob
    ///   Nana: no rows (validation prop for the spouse-age-gap warning)
    static func family(timBasis: SiblingBasis = .unspecified) -> [POIProfile] {
        [
            profile("Rick", aliases: ["Richard Harding Breen Jr"], sex: .male, born: 1962,
                    kinships: [row(.child, of: "Dad")], pin: "GVQV-NW3"),
            profile("Dad", aliases: ["Richard Harding Breen Sr"], sex: .male, born: 1931, pin: "G2S4-JF4"),
            profile("Eileen", aliases: ["Eileen Latta"], sex: .female, born: 1935,
                    kinships: [row(.parent, of: "Rick")]),
            profile("Tim", sex: .male, born: 1965, kinships: [row(.sibling, of: "Rick", basis: timBasis)]),
            profile("Donna", sex: .female, born: 1959, kinships: [row(.spouse, of: "Rick")], pin: "DONN-A03"),
            profile("Michael", sex: .male, born: 1984, kinships: [row(.child, of: "Rick")]),
            profile("Kevin", sex: .male, born: 1986, kinships: [row(.child, of: "Rick")]),
            profile("Brian", sex: .male, born: 1988, kinships: [row(.child, of: "Rick")]),
            profile("Timothy", sex: .male, born: 1990, kinships: [row(.child, of: "Rick")]),
            profile("Ann", sex: .female, born: 1961, kinships: [row(.sibling, of: "Donna")]),
            profile("Bob", sex: .male, born: 1958, kinships: [row(.spouse, of: "Ann")]),
            profile("Nana", sex: .female, born: 1905),
        ]
    }
    static let family = family()

    /// Jr (@I1@) ← Sr (@I2@) ← A1 … ← A9 = Martha Lamson: nine generations
    /// above Sr, so she is ten above Rick = 8th-great-grandmother. Donna is
    /// @I3@ (no parents). Side branch for cousin reckoning: A2 also has a
    /// son X1 (Sr's uncle), whose daughter is X2.
    static let tree: String = {
        var lines = ["0 HEAD",
                     "0 @I1@ INDI", "1 NAME Richard Harding /Breen/ Jr", "1 SEX M", "1 _FSFTID GVQV-NW3", "1 FAMC @F0@",
                     "0 @I2@ INDI", "1 NAME Richard Harding /Breen/ Sr", "1 SEX M", "1 _FSFTID G2S4-JF4",
                     "1 BIRT", "2 DATE 1931", "1 FAMS @F0@", "1 FAMC @F1@",
                     "0 @I3@ INDI", "1 NAME Donna /Breen/", "1 SEX F", "1 _FSFTID DONN-A03",
                     "0 @F0@ FAM", "1 HUSB @I2@", "1 CHIL @I1@"]
        for g in 1...9 {
            let name = g == 9 ? "Martha /Lamson/" : "Ancestor\(g) /Breen/"
            let sex = g == 9 ? "F" : (g % 2 == 1 ? "M" : "F")
            lines += ["0 @A\(g)@ INDI", "1 NAME \(name)", "1 SEX \(sex)", "1 _FSFTID ANC\(g)-00\(g)",
                      "1 BIRT", "2 DATE \(g == 1 ? "ABT " : "")\(1931 - 28 * g)", "1 FAMS @F\(g)@"]
            if g < 9 { lines.append("1 FAMC @F\(g + 1)@") }
            let child = g == 1 ? "@I2@" : "@A\(g - 1)@"
            lines += ["0 @F\(g)@ FAM", "1 \(sex == "M" ? "HUSB" : "WIFE") @A\(g)@", "1 CHIL \(child)"]
        }
        lines += ["0 @X1@ INDI", "1 NAME Xavier /Breen/", "1 SEX M", "1 _FSFTID XAV1-001", "1 FAMC @F2@", "1 FAMS @FX@",
                  "0 @X2@ INDI", "1 NAME Xena /Breen/", "1 SEX F", "1 _FSFTID XEN2-002", "1 FAMC @FX@",
                  "0 @FX@ FAM", "1 HUSB @X1@", "1 CHIL @X2@"]
        if let i = lines.firstIndex(of: "0 @F2@ FAM") { lines.insert("1 CHIL @X1@", at: i + 3) }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }()

    static var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: tree) }

    /// Pedigree of @P1@: person i has parents 2i (M) and 2i+1 (F); FSID
    /// "S<i>". 5,001 people, 2,500 families — the Tier B tie fixture.
    static let pedigree5001: GedcomFamilyGraph = {
        var lines = ["0 HEAD"]
        for i in 1...5001 {
            let depth = Int(log2(Double(i)))
            lines += ["0 @P\(i)@ INDI", "1 NAME Person\(i) /Line/", "1 SEX \(i % 2 == 0 ? "M" : "F")",
                      "1 _FSFTID " + String(format: "S%03d-%03d", i / 1000, i % 1000), "1 BIRT", "2 DATE \(1962 - 28 * depth)"]
            if i <= 2500 { lines.append("1 FAMC @F\(i)@") }
            if i >= 2 { lines.append("1 FAMS @F\(i / 2)@") }
        }
        for i in 1...2500 {
            lines += ["0 @F\(i)@ FAM", "1 HUSB @P\(2 * i)@", "1 WIFE @P\(2 * i + 1)@", "1 CHIL @P\(i)@"]
        }
        lines.append("0 TRLR")
        return GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
    }()

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
    private static let attestedFamily = KinshipFixture.family(timBasis: .attestedFull)
    private let attested = KinshipFixture.inference(Self.attestedFamily)
    private func n(_ name: String) -> FamilyKinshipInference.Node { KinshipFixture.node(name, in: inf) }
    private static let martha = FamilyKinshipInference.Node.tree(gedcomID: "@A9@")

    // MARK: Identity pins (amendment 1)

    @Test func onlyPinnedProfilesShareATreeVertex() {
        #expect(n("Rick") == .tree(gedcomID: "@I1@"))
        #expect(n("Dad") == .tree(gedcomID: "@I2@"))
        #expect(n("Donna") == .tree(gedcomID: "@I3@"))
        #expect(n("Eileen") == .profile(stableID: "eileen"))
        #expect(inf.name(of: Self.martha) == "Martha Lamson")
        // An alias that matches a tree name exactly is NOT identity for the
        // engine — suggestion only.
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Xavier", aliases: ["Xavier Breen"], sex: .male)]
        let inf2 = KinshipFixture.inference(profiles)
        #expect(KinshipFixture.node("Xavier", in: inf2) == .profile(stableID: "xavier"))
        let suggested = FamilyKinshipOverlay.suggestedTreeMatches(
            canonicalName: "Xavier", aliases: ["Xavier Breen"], graph: KinshipFixture.graph)
        #expect(suggested.map(\.id) == ["@X1@"])
        // The display overlay is the same identity space: no name bridge there either.
        let display = FamilyKinshipOverlay(profiles: profiles, graph: KinshipFixture.graph)
        #expect(display.node(profileStableID: "xavier") == .profile(stableID: "xavier"))
    }

    @Test func stalePinFailsClosed() {
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Ghost", sex: .male, pin: "NOPE-000")]
        let inf2 = KinshipFixture.inference(profiles)
        #expect(KinshipFixture.node("Ghost", in: inf2) == .profile(stableID: "ghost"))
        #expect(inf2.overlay.pinProblem(forProfileStableID: "ghost")
                == "Ghost's family-tree pin points at a person this tree doesn't carry — pin them again")
        // No tree at all: the pin can't be checked; still a profile vertex.
        let offline = KinshipFixture.inference(profiles, graph: nil)
        #expect(KinshipFixture.node("Rick", in: offline) == .profile(stableID: "rick"))
        #expect(offline.overlay.pinProblem(forProfileStableID: "rick")?.hasSuffix("no tree is installed") == true)
        #expect(offline.relation(from: KinshipFixture.node("Michael", in: offline),
                                 to: KinshipFixture.node("Tim", in: offline))?.term == "uncle")
    }

    @Test func collidingPinsUnbridgeBothProfiles() {
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Rick2", sex: .male, pin: "GVQV-NW3")]
        let inf2 = KinshipFixture.inference(profiles)
        #expect(KinshipFixture.node("Rick", in: inf2) == .profile(stableID: "rick"))
        #expect(KinshipFixture.node("Rick2", in: inf2) == .profile(stableID: "rick2"))
        let why = "Rick and Rick2 are both pinned to Richard Harding Breen Jr in the family tree — only one profile can be that person"
        #expect(inf2.overlay.pinProblem(forProfileStableID: "rick") == why)
        #expect(inf2.overlay.pinProblem(forProfileStableID: "rick2") == why)
        #expect(inf2.overlay.warnings(forProfileNamed: "Rick2") == [why])
        // Rick's rows still work: the DIRECT pin failed, but his explicit
        // "child of Dad" row reaches the (separately pinned) Dad vertex and
        // from there the tree — with that row cited as the first hop.
        let rick = KinshipFixture.node("Rick", in: inf2)
        #expect(inf2.relation(from: rick, to: KinshipFixture.node("Tim", in: inf2))?.term == "younger brother")
        let viaDad = inf2.relation(from: rick, to: Self.martha)
        #expect(viaDad?.term == "8th-great-grandmother")
        #expect(viaDad?.route.first?.to == .tree(gedcomID: "@I2@"))
        #expect(viaDad?.route.first?.provenance == .profileRow(profileIdentity: inf2.identity(of: rick)))
        #expect(inf2.identity(of: rick).hasPrefix("uuid:"))          // not the contested FSID
        // The tree's own Rick is now a stranger who shares Dad: the data says "brother", with the evidence caveat.
        let treeRick = inf2.relation(from: rick, to: .tree(gedcomID: "@I1@"))
        #expect(treeRick?.term == "brother")
        #expect(treeRick?.caveats.first?.hasPrefix("full or half not established") == true)
    }

    @Test func treeIdentityAndSiblingBasisRoundTripAndDefault() throws {
        let p = KinshipFixture.profile("Tim", sex: .male, kinships: [
            KinshipFixture.row(.sibling, of: "Rick", basis: .attestedHalf(sharedParent: .profile(name: "Dad"))),
            KinshipFixture.row(.sibling, of: "Ann", basis: .attestedFull),
            KinshipFixture.row(.sibling, of: "Sue"),
        ], pin: "GVQV-NW3")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(POIProfile.self, from: data)
        #expect(back == p)
        #expect(back.treeIdentity == .familySearchID("GVQV-NW3"))
        #expect(back.kinships.map(\.basis) == [.attestedHalf(sharedParent: .profile(name: "Dad")), .attestedFull, .unspecified])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(obj["kinships"] as? [[String: Any]])
        #expect(rows[2]["basis"] == nil)                       // unspecified is not written
        #expect(rows[1]["basis"] as? String == "attestedFull")
        #expect((obj["treeIdentity"] as? [String: Any])?["familySearchID"] as? String == "GVQV-NW3")
        // Older JSON: no basis, no pin.
        let legacy = #"{"name":"Tim","referencePath":"/p","kinships":[{"relation":"sibling","relativeTo":{"profile":{"name":"Rick"}}}]}"#
        let old = try JSONDecoder().decode(POIProfile.self, from: Data(legacy.utf8))
        #expect(old.kinships[0].basis == .unspecified)
        #expect(old.treeIdentity == nil)
        let pointer = POIProfile(name: "P", referencePath: "/p", treeIdentity: .pointer(pointer: "@I7@", sourceFingerprint: "abc"))
        #expect(try JSONDecoder().decode(POIProfile.self, from: JSONEncoder().encode(pointer)).treeIdentity
                == .pointer(pointer: "@I7@", sourceFingerprint: "abc"))
    }

    // MARK: Composition through an unspecified sibling row

    @Test func timIsUncleOfEachSonAndTheyAreHisNephews() {
        for son in KinshipFixture.sons {
            let d = inf.relation(from: n(son), to: n("Tim"))
            #expect(d?.term == "uncle", Comment(rawValue: son))
            #expect(d?.routeText == "father Rick → brother Tim", Comment(rawValue: son))
            #expect(d?.caveats.isEmpty == true, Comment(rawValue: son))
            #expect(inf.relation(from: n("Tim"), to: n(son))?.term == "nephew", Comment(rawValue: son))
        }
    }

    @Test func timIsDonnasBrotherInLaw() {
        let d = inf.relation(from: n("Donna"), to: n("Tim"))
        #expect(d?.term == "brother-in-law")
        #expect(d?.routeText == "husband Rick → brother Tim")
        #expect(inf.relation(from: n("Tim"), to: n("Donna"))?.term == "sister-in-law")
        #expect(d?.usesAttestation == false)
    }

    @Test func rickIsTimsOlderBrotherByBirthYear() {
        #expect(inf.relation(from: n("Tim"), to: n("Rick"))?.term == "older brother")
        #expect(inf.relation(from: n("Rick"), to: n("Tim"))?.term == "younger brother")
        #expect(inf.relation(from: n("Rick"), to: n("Tim"))?.provenance == [.profileRow(profileIdentity: inf.identity(of: n("Tim")))])
    }

    @Test func bobIsRicksBrotherInLawViaRoute() {
        let d = inf.relation(from: n("Rick"), to: n("Bob"))
        #expect(d?.term == "brother-in-law")
        #expect(d?.routeText == "sister-in-law Ann → husband Bob")
        #expect(d?.route.map(\.relation) == [.spouse, .sibling, .spouse])
        #expect(inf.relation(from: n("Bob"), to: n("Rick"))?.term == "brother-in-law")
    }

    // MARK: Sibling basis (amendment 2) — both outcomes pinned

    @Test func unspecifiedSiblingNeverInheritsParentsButProposesThem() {
        #expect(inf.parents(of: n("Tim")).isEmpty)
        #expect(inf.explicitParents(of: n("Tim")).isEmpty)
        let proposals = inf.proposals(for: n("Tim"))
        #expect(proposals.count == 1)
        #expect(proposals.first?.kind == .sharedParents(via: n("Rick"), parents: [n("Dad"), n("Eileen")]))
        #expect(proposals.first?.text == "Tim shares Rick's parents (Dad and Eileen) — assumed full; confirm to inherit Rick's ancestry")
        // "Tim → Dad" is a route with a note, not "father".
        let dad = inf.relation(from: n("Tim"), to: n("Dad"))
        #expect(dad?.term == nil)
        #expect(dad?.routeText == "brother Rick → father Dad")
        #expect(dad?.caveats == ["Tim's sibling link to Rick is not attested as full, so Rick's parents are not treated as Tim's"])
        #expect(inf.relation(from: n("Dad"), to: n("Tim"))?.term == nil)
        #expect(inf.relation(from: n("Dad"), to: n("Tim"))?.routeText == "son Rick → brother Tim")
        // Rick has parents: nothing to propose for him.
        #expect(inf.proposals(for: n("Rick")).isEmpty)
    }

    @Test func attestedFullSiblingInheritsParentsAsAttestedFacts() {
        func a(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: attested) }
        let parents = attested.parents(of: a("Tim"))
        #expect(parents.map(\.node) == [a("Dad"), a("Eileen")])
        #expect(parents.allSatisfy { $0.provenance == .attestedSibling(viaIdentity: "fsid:GVQV-NW3") })
        #expect(attested.explicitParents(of: a("Tim")).isEmpty)      // still not a stored row
        #expect(attested.proposals(for: a("Tim")).isEmpty)
        let father = attested.relation(from: a("Tim"), to: a("Dad"))
        #expect(father?.term == "father")
        #expect(father?.usesAttestation == true)
        #expect(father?.caveats.isEmpty == true)
        #expect(attested.relation(from: a("Tim"), to: a("Eileen"))?.term == "mother")
        #expect(attested.relation(from: a("Dad"), to: a("Tim"))?.term == "son")
    }

    /// SENSOR: Tim ↔ Martha Lamson in both outcomes.
    @Test func timToMarthaLamsonDependsOnTheSiblingBasis() {
        // Unspecified: the route stops at Rick and says why.
        let honest = inf.relation(from: n("Tim"), to: Self.martha)
        #expect(honest?.term == nil)
        #expect(honest?.route.count == 11)
        #expect(honest?.route.first?.relation == .sibling)
        #expect(honest?.routeText.hasPrefix("brother Rick → father Dad → father Ancestor1 Breen") == true)
        #expect(honest?.caveats == ["Tim's sibling link to Rick is not attested as full, so Rick's parents are not treated as Tim's — Martha Lamson is Rick's 8th-great-grandmother (confirm the shared parents to inherit this)"])
        let honestBack = inf.relation(from: Self.martha, to: n("Tim"))
        #expect(honestBack?.term == nil)
        #expect(honestBack?.route.last?.relation == .sibling)
        #expect(honestBack?.caveats.first?.contains("Rick is Martha Lamson's 8th-great-grandson") == true)

        // Attested full: a word, through Rick's parents.
        func a(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: attested) }
        let d = attested.relation(from: a("Tim"), to: Self.martha)
        #expect(d?.term == "8th-great-grandmother")
        #expect(d?.route.count == 10)
        #expect(d?.route.first?.provenance == .attestedSibling(viaIdentity: "fsid:GVQV-NW3"))
        #expect(d?.usesTree == true)
        #expect(d?.routeText.hasPrefix("father Dad → father Ancestor1 Breen → mother Ancestor2 Breen") == true)
        #expect(d?.routeText.hasSuffix("→ mother Martha Lamson") == true)
        #expect(attested.relation(from: Self.martha, to: a("Tim"))?.term == "8th-great-grandson")
        // Rick reaches her without any attestation, in both engines.
        for engine in [inf, attested] {
            let r = engine.relation(from: KinshipFixture.node("Rick", in: engine), to: Self.martha)
            #expect(r?.term == "8th-great-grandmother")
            #expect(r?.usesAttestation == false)
            #expect(engine.relation(from: Self.martha, to: KinshipFixture.node("Rick", in: engine))?.term == "8th-great-grandson")
        }
    }

    @Test func attestedHalfInheritsOnlyTheSharedParent() {
        let profiles = [
            KinshipFixture.profile("P1", sex: .male), KinshipFixture.profile("P2", sex: .female),
            KinshipFixture.profile("Al", sex: .male, born: 1970,
                                   kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
            KinshipFixture.profile("Hal", sex: .male, born: 1975, kinships: [
                KinshipFixture.row(.sibling, of: "Al", basis: .attestedHalf(sharedParent: .profile(name: "P1"))),
            ]),
        ]
        let inf = KinshipFixture.inference(profiles, graph: nil)
        func n(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: inf) }
        #expect(inf.parents(of: n("Hal")).map(\.node) == [n("P1")])
        #expect(inf.relation(from: n("Hal"), to: n("P1"))?.term == "father")
        #expect(inf.relation(from: n("Hal"), to: n("P2"))?.term == nil)
        #expect(inf.relation(from: n("Al"), to: n("Hal"))?.term == "younger half-brother")
        #expect(inf.relation(from: n("Hal"), to: n("Al"))?.term == "older half-brother")
    }

    @Test func halfSiblingsNeedCompleteDisjointSecondParentEvidence() {
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
        #expect(inf.relation(from: n("Ben"), to: n("Al"))?.caveats.isEmpty == true)
        // One shared parent + one unknown ≠ half: full assumed, with a note.
        let cal = inf.relation(from: n("Al"), to: n("Cal"))
        #expect(cal?.term == "younger brother")
        #expect(cal?.caveats == ["full or half not established — Cal's second parent is not recorded (full assumed)"])
        let dee = inf.relation(from: n("Al"), to: n("Dee"))
        #expect(dee?.term == "younger sister")
        #expect(dee?.caveats.isEmpty == true)
        #expect(inf.relation(from: n("Dee"), to: n("Al"))?.term == "older brother")
    }

    // MARK: Tree reckoning through pins

    @Test func lineAndCollateralTermsThroughTheTree() {
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@A1@"))?.term == "grandfather")
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@A2@"))?.term == "great-grandmother")
        #expect(inf.relation(from: n("Michael"), to: .tree(gedcomID: "@A1@"))?.term == "great-grandfather")
        #expect(inf.relation(from: n("Michael"), to: Self.martha)?.term == "9th-great-grandmother")
        #expect(inf.relation(from: n("Dad"), to: .tree(gedcomID: "@X1@"))?.term == "uncle")
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@X1@"))?.term == "great-uncle")
        #expect(inf.relation(from: n("Dad"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin")
        #expect(inf.relation(from: n("Rick"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin once removed")
        #expect(inf.relation(from: n("Michael"), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin twice removed")
        #expect(inf.relation(from: .tree(gedcomID: "@X1@"), to: n("Rick"))?.term == "great-nephew")
        // Through the attested sibling row, Tim gets the same reckoning.
        #expect(attested.relation(from: KinshipFixture.node("Tim", in: attested), to: .tree(gedcomID: "@X2@"))?.term == "1st cousin once removed")
        // Unattested: no word, honest route.
        #expect(inf.relation(from: n("Tim"), to: .tree(gedcomID: "@X2@"))?.term == nil)
    }

    @Test func grandparentsInLawsAndSonsInLawCompose() {
        #expect(inf.relation(from: n("Michael"), to: n("Dad"))?.term == "grandfather")
        #expect(inf.relation(from: n("Dad"), to: n("Kevin"))?.term == "grandson")
        #expect(inf.relation(from: n("Donna"), to: n("Dad"))?.term == "father-in-law")
        #expect(inf.relation(from: n("Dad"), to: n("Donna"))?.term == "daughter-in-law")
        #expect(inf.relation(from: n("Donna"), to: n("Eileen"))?.term == "mother-in-law")
        // The sons carry child rows on Rick ONLY, so Donna's side is not
        // lineal for them: Ann is "father Rick → sister-in-law Ann", no word.
        let annViaRick = inf.relation(from: n("Michael"), to: n("Ann"))
        #expect(annViaRick?.term == nil)
        #expect(annViaRick?.routeText == "father Rick → sister-in-law Ann")
        var both = KinshipFixture.family
        if let i = both.firstIndex(where: { $0.name == "Michael" }) {
            both[i].kinships.append(KinshipFixture.row(.child, of: "Donna"))
        }
        let inf2 = KinshipFixture.inference(both)
        #expect(inf2.relation(from: KinshipFixture.node("Michael", in: inf2), to: KinshipFixture.node("Ann", in: inf2))?.term == "aunt")
        #expect(inf2.relation(from: KinshipFixture.node("Michael", in: inf2), to: KinshipFixture.node("Bob", in: inf2))?.term == "uncle")
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
        #expect(KinshipChainNamer.name([.spouse, .spouse]) == nil)
        #expect(KinshipChainNamer.name([.sibling, .sibling]) == nil)
        #expect(KinshipChainNamer.name([.parent, .spouse]) == nil)
        #expect(KinshipChainNamer.name([.spouse, .child]) == nil)
        #expect(KinshipChainNamer.name([.child, .sibling]) == nil)
        #expect(KinshipChainNamer.name([.sibling, .parent]) == nil)
        #expect(KinshipChainNamer.name([.sibling, .spouse, .spouse]) == nil)
        #expect(KinshipChainNamer.name([.spouse, .sibling, .spouse]) == .relation(.siblingInLaw))
        #expect(KinshipChainNamer.name([.sibling, .child, .child]) == .collateral(up: 1, down: 3))
    }

    @Test func derivedRelativesOfTimListsTheContemporaries() {
        let all = inf.derivedRelatives(of: n("Tim"))
        var byName: [String: String?] = [:]
        for d in all { byName[inf.name(of: d.to)] = d.term }
        #expect(byName["Rick"] == "older brother")
        #expect(byName["Dad"] == .some(nil))          // route + note, not a fact
        #expect(byName["Eileen"] == .some(nil))
        #expect(byName["Donna"] == "sister-in-law")
        for son in KinshipFixture.sons { #expect(byName[son] == "nephew", Comment(rawValue: son)) }
        #expect(byName["Nana"] == nil)                // unreachable
    }

    @Test func overlayTermUsesTheSameComposerForGreatGrand() {
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
        #expect(KinshipRelation.compose([.parent, .parent, .parent]) == nil)
    }

    @Test func nothingLinksTwoStrangers() {
        #expect(inf.relation(from: n("Nana"), to: n("Rick")) == nil)
        #expect(inf.relation(from: n("Rick"), to: n("Rick")) == nil)
    }

    // MARK: Dates keep their precision (amendment 6)

    @Test func ageOrderOnlyWhenProvableAtTheKnownPrecision() {
        let exact = BirthKnowledge.years(.exact(1962))
        #expect(BirthKnowledge.ageWord(subject: exact, anchor: .years(.exact(1962))) == nil)
        #expect(BirthKnowledge.ageWord(subject: exact, anchor: .years(.exact(1965))) == "older")
        #expect(BirthKnowledge.ageWord(subject: .date(KinshipFixture.date(1962, 3, 1)),
                                       anchor: .date(KinshipFixture.date(1962, 9, 1))) == "older")
        // A full date against a year: same year ⇒ unknowable, no Jan 1 guess.
        #expect(BirthKnowledge.ageWord(subject: .date(KinshipFixture.date(1962, 3, 1)), anchor: exact) == nil)
        let about = BirthKnowledge.years(GedcomYearInterval.parse("ABT 1931")!)
        #expect(BirthKnowledge.ageWord(subject: about, anchor: .years(.exact(1932))) == nil)
        #expect(BirthKnowledge.ageWord(subject: about, anchor: .years(.exact(1965))) == "older")
        #expect(BirthKnowledge.provableGapYears(about, .years(.exact(1965))) == 32)
        #expect(BirthKnowledge.provableGapYears(.years(.exact(1958)), .years(.exact(1905))) == 53)
        // Through the engine: Ancestor1 is "ABT 1903" in the tree; a sibling
        // born 1904 gets no age word, one born 1965 does.
        let profiles = [
            KinshipFixture.profile("A1", sex: .male, pin: "ANC1-001"),
            KinshipFixture.profile("Near", sex: .male, born: 1904, kinships: [KinshipFixture.row(.sibling, of: "A1")]),
            KinshipFixture.profile("Far", sex: .male, born: 1965, kinships: [KinshipFixture.row(.sibling, of: "A1")]),
        ]
        let inf = KinshipFixture.inference(profiles)
        #expect(inf.birth(of: KinshipFixture.node("A1", in: inf)) == .years(GedcomYearInterval.parse("ABT 1903")!))
        #expect(inf.relation(from: KinshipFixture.node("A1", in: inf), to: KinshipFixture.node("Near", in: inf))?.term == "brother")
        #expect(inf.relation(from: KinshipFixture.node("A1", in: inf), to: KinshipFixture.node("Far", in: inf))?.term == "younger brother")
        // The display overlay agrees (no manufactured date on tree members).
        #expect(inf.overlay.member(.tree(gedcomID: "@A1@"))?.birthdate == nil)
    }

    // MARK: Determinism (amendment 7)

    @Test func reversedProfileOrderGivesIdenticalAnswers() {
        let forward = KinshipFixture.inference(KinshipFixture.family)
        let reversed = KinshipFixture.inference(Array(KinshipFixture.family.reversed()))
        let names = KinshipFixture.family.map(\.name)
        var compared = 0
        for a in names {
            for b in names where a != b {
                let x = forward.relation(from: KinshipFixture.node(a, in: forward), to: KinshipFixture.node(b, in: forward))
                let y = reversed.relation(from: KinshipFixture.node(a, in: reversed), to: KinshipFixture.node(b, in: reversed))
                #expect(x == y, "\(a) → \(b)")
                compared += 1
            }
        }
        #expect(compared == names.count * (names.count - 1))
    }

    @Test func equalLengthAlternativesPickTheStableOne() {
        // Two 2-hop routes to Zed: wife Yve → brother Zed, and brother Wes →
        // wife's-brother … no: brother Wes → husband Zed? Keep both routes
        // sibling-in-law: X ═ Yve, Yve's brother Zed; X's sister Wen ═ Zed.
        // (Zed married X's sister AND is X's wife's brother.) Hop-kind
        // order prefers spouse (2) over sibling (3) at the first hop, so the
        // route is via Yve regardless of profile order.
        func build(_ order: [String]) -> FamilyKinshipInference {
            let all: [String: POIProfile] = [
                "X":   KinshipFixture.profile("X", sex: .male),
                "Yve": KinshipFixture.profile("Yve", sex: .female, kinships: [KinshipFixture.row(.spouse, of: "X")]),
                "Zed": KinshipFixture.profile("Zed", sex: .male, kinships: [KinshipFixture.row(.sibling, of: "Yve")]),
                "Wen": KinshipFixture.profile("Wen", sex: .female, kinships: [
                    KinshipFixture.row(.sibling, of: "X"), KinshipFixture.row(.spouse, of: "Zed")]),
            ]
            return KinshipFixture.inference(order.compactMap { all[$0] }, graph: nil)
        }
        for order in [["X", "Yve", "Zed", "Wen"], ["Wen", "Zed", "Yve", "X"], ["Zed", "Wen", "X", "Yve"]] {
            let inf = build(order)
            let d = inf.relation(from: KinshipFixture.node("X", in: inf), to: KinshipFixture.node("Zed", in: inf))
            #expect(d?.term == "brother-in-law", Comment(rawValue: order.joined()))
            #expect(d?.route.map(\.relation) == [.spouse, .sibling], Comment(rawValue: order.joined()))
            #expect(d?.provenance == [.profileRow(profileIdentity: inf.identity(of: KinshipFixture.node("Yve", in: inf))),
                                      .profileRow(profileIdentity: inf.identity(of: KinshipFixture.node("Zed", in: inf)))],
                    Comment(rawValue: order.joined()))
            #expect(d?.routeText == "wife Yve → brother Zed", Comment(rawValue: order.joined()))
        }
    }

    // MARK: Attestation merge, rename stability, pin seam (codex #845 2–4)

    @Test func attestedFullMergesPerParentWithWhatIsRecorded() {
        // Tim has ONE explicit parent (Eileen); attesting full to Rick adds
        // Dad, not a duplicate Eileen and not a third parent.
        var profiles = KinshipFixture.family(timBasis: .attestedFull)
        if let i = profiles.firstIndex(where: { $0.name == "Tim" }) {
            profiles[i].kinships.append(KinshipFixture.row(.child, of: "Eileen"))
        }
        let inf = KinshipFixture.inference(profiles)
        let tim = KinshipFixture.node("Tim", in: inf)
        let parents = inf.parents(of: tim)
        // Canonical order: explicit (Eileen, a row) before attested (Dad).
        #expect(parents.map(\.node) == [KinshipFixture.node("Eileen", in: inf), KinshipFixture.node("Dad", in: inf)])
        #expect(parents.map { $0.provenance.isExplicit } == [true, false])
        #expect(inf.attestationProblems.isEmpty)
        #expect(inf.relation(from: tim, to: Self.martha)?.term == "8th-great-grandmother")
        // attestedHalf with an explicit NON-shared parent inherits the shared one.
        let half = KinshipFixture.inference([
            KinshipFixture.profile("P1", sex: .male), KinshipFixture.profile("P2", sex: .female), KinshipFixture.profile("P3", sex: .female),
            KinshipFixture.profile("Al", sex: .male, kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
            KinshipFixture.profile("Hal", sex: .male, kinships: [
                KinshipFixture.row(.child, of: "P3"),
                KinshipFixture.row(.sibling, of: "Al", basis: .attestedHalf(sharedParent: .profile(name: "P1"))),
            ]),
        ], graph: nil)
        let hal = KinshipFixture.node("Hal", in: half)
        #expect(half.parents(of: hal).map(\.node) == [KinshipFixture.node("P3", in: half), KinshipFixture.node("P1", in: half)])   // explicit first
        #expect(half.relation(from: KinshipFixture.node("Al", in: half), to: hal)?.term == "half-brother")
        // A half row whose shared parent does not resolve is NOT half.
        let stale = KinshipFixture.inference([
            KinshipFixture.profile("Al", sex: .male),
            KinshipFixture.profile("Hal", sex: .male, kinships: [
                KinshipFixture.row(.sibling, of: "Al", basis: .attestedHalf(sharedParent: .profile(id: UUID()))),
            ]),
        ], graph: nil)
        let d = stale.relation(from: KinshipFixture.node("Al", in: stale), to: KinshipFixture.node("Hal", in: stale))
        #expect(d?.term == "brother")
        #expect(d?.caveats == ["the shared parent named on the half-sibling row could not be found — treated as unspecified"])
        #expect(stale.parents(of: KinshipFixture.node("Hal", in: stale)).isEmpty)
    }

    @Test func duplicateLegacyRowsMergeToTheStrongestBasisRegardlessOfOrder() {
        func build(_ first: SiblingBasis, _ second: SiblingBasis) -> FamilyKinshipInference {
            KinshipFixture.inference([
                KinshipFixture.profile("P1", sex: .male), KinshipFixture.profile("P2", sex: .female),
                KinshipFixture.profile("Al", sex: .male, kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
                KinshipFixture.profile("Tom", sex: .male, kinships: [
                    KinshipFixture.row(.sibling, of: "Al", basis: first),
                    KinshipFixture.row(.sibling, of: "Al", basis: second),
                ]),
            ], graph: nil)
        }
        for engine in [build(.unspecified, .attestedFull), build(.attestedFull, .unspecified)] {
            let tom = KinshipFixture.node("Tom", in: engine)
            #expect(engine.parents(of: tom).count == 2)
            #expect(engine.hops(from: tom).filter { $0.relation == .sibling }.count == 1)
            #expect(engine.relation(from: tom, to: KinshipFixture.node("P1", in: engine))?.term == "father")
        }
    }

    @Test func renamingAProfileKeepsProvenanceAndPathHash() {
        // Rows anchored by uuid survive a rename; the citation is the uuid.
        var profiles = KinshipFixture.family
        let rickUUID = profiles[0].uuid
        if let i = profiles.firstIndex(where: { $0.name == "Tim" }) {
            profiles[i].kinships = [Kinship(relation: .sibling, relativeTo: .profile(id: rickUUID))]
        }
        let before = KinshipFixture.inference(profiles)
        let timID = profiles.first { $0.name == "Tim" }!.uuid
        let first = before.relation(from: KinshipFixture.node("Rick", in: before), to: KinshipFixture.node("Tim", in: before))
        var renamed = profiles
        if let i = renamed.firstIndex(where: { $0.name == "Tim" }) { renamed[i].name = "Timothy Breen" }
        let after = KinshipFixture.inference(renamed)
        let second = after.relation(from: KinshipFixture.node("Rick", in: after), to: KinshipFixture.node("Timothy Breen", in: after))
        #expect(first?.provenance == [.profileRow(profileIdentity: "uuid:" + timID.uuidString.lowercased())])
        #expect(second?.provenance == first?.provenance)
        #expect(second?.pathHash == first?.pathHash)
        #expect(second?.term == "younger brother")
    }

    @Test func malformedPinIsQuarantinedAndFailsClosed() throws {
        let json = #"{"name":"Rick","referencePath":"/p","treeIdentity":{"galaxy":"far away"}}"#
        let p = try JSONDecoder().decode(POIProfile.self, from: Data(json.utf8))
        #expect(p.treeIdentity == nil)
        #expect(p.treeIdentityQuarantined == .object(["galaxy": .string("far away")]))
        // Written back verbatim, and still quarantined on the next read.
        let data = try JSONEncoder().encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((obj["treeIdentityQuarantined"] as? [String: Any])?["galaxy"] as? String == "far away")
        #expect(obj["treeIdentity"] == nil)
        let again = try JSONDecoder().decode(POIProfile.self, from: data)
        #expect(again.treeIdentityQuarantined == p.treeIdentityQuarantined)
        // The overlay fails closed: unbridged, with a pin problem — never a name match.
        var rick = p
        rick.aliases = ["Richard Harding Breen Jr"]
        let inf = KinshipFixture.inference([rick], graph: KinshipFixture.graph)
        #expect(KinshipFixture.node("Rick", in: inf) == .profile(stableID: "rick"))
        #expect(inf.overlay.pinProblem(forProfileStableID: "rick")
                == "Rick's family-tree pin could not be read (written by a newer app version?) — kept as is, not used")
    }

    @Test func hallieProfileSnapshotsCarryThePin() {
        // Phase B seam: the executor's own snapshot type carries the pin and
        // the overlay it builds honours it.
        let profiles = KinshipFixture.family.map {
            HallieTurnExecutor.ProfileSnapshot(stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                                               birthdate: $0.birthdate, kinships: $0.kinships, sex: $0.sex,
                                               uuid: $0.uuid, treeIdentity: $0.treeIdentity)
        }
        let context = HallieTurnExecutor.Context(
            profiles: profiles, graph: KinshipFixture.graph, cyberBrain: nil,
            speakers: HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
        let overlay = HallieTurnExecutor.kinshipOverlay(context: context)
        #expect(overlay?.node(profileStableID: "rick") == .tree(gedcomID: "@I1@"))
        #expect(overlay?.node(profileStableID: "eileen") == .profile(stableID: "eileen"))
    }

    @Test func identicalDuplicateProfilePinsCollapseRegardlessOfOrder() {
        let first = HallieTurnExecutor.ProfileSnapshot(
            stableID: "duplicate-rick",
            canonicalName: "Archive Subject Seven",
            treeIdentity: .familySearchID("GVQV-NW3"))
        let second = first

        for definitions in [[first, second], [second, first]] {
            let overlay = FamilyKinshipOverlay(
                snapshots: definitions, graph: KinshipFixture.graph)
            #expect(overlay.node(profileStableID: first.stableID)
                    == .tree(gedcomID: "@I1@"))
            #expect(overlay.pinProblem(forProfileStableID: first.stableID) == nil)
        }
    }

    @Test func conflictingDuplicateProfilePinsFailClosedRegardlessOfOrder() {
        let rick = HallieTurnExecutor.ProfileSnapshot(
            stableID: "conflicting-profile",
            canonicalName: "Archive Subject Seven",
            treeIdentity: .familySearchID("GVQV-NW3"))
        let donna = HallieTurnExecutor.ProfileSnapshot(
            stableID: rick.stableID,
            canonicalName: rick.canonicalName,
            treeIdentity: .familySearchID("DONN-A03"))

        for definitions in [[rick, donna], [donna, rick]] {
            let overlay = FamilyKinshipOverlay(
                snapshots: definitions, graph: KinshipFixture.graph)
            #expect(overlay.node(profileStableID: rick.stableID)
                    == .profile(stableID: rick.stableID))
            #expect(overlay.pinProblem(forProfileStableID: rick.stableID)?
                .contains("duplicate profile definitions disagree") == true)
        }
    }

    @Test func readableAndUnreadableDuplicatePinsFailClosedRegardlessOfOrder() {
        let readable = HallieTurnExecutor.ProfileSnapshot(
            stableID: "mixed-readable-profile",
            canonicalName: "Archive Subject Seven",
            treeIdentity: .familySearchID("GVQV-NW3"))
        let unreadable = HallieTurnExecutor.ProfileSnapshot(
            stableID: readable.stableID,
            canonicalName: readable.canonicalName,
            treeIdentityUnreadable: true)

        for definitions in [[readable, unreadable], [unreadable, readable]] {
            let overlay = FamilyKinshipOverlay(
                snapshots: definitions, graph: KinshipFixture.graph)
            #expect(overlay.node(profileStableID: readable.stableID)
                    == .profile(stableID: readable.stableID))
            #expect(overlay.pinProblem(forProfileStableID: readable.stableID)?
                .contains("duplicate profile definitions disagree") == true)
        }
    }

    @Test func hallieExecutorWalksFromADurableProfilePinIntoTheTree() async throws {
        // End-to-end sensor for the People-tab -> GEDCOM seam. The profile's
        // display name and aliases deliberately match NO tree record, so a
        // green answer can only have crossed the explicit FamilySearch pin.
        let local = HallieTurnExecutor.ProfileSnapshot(
            stableID: "durable-rick",
            canonicalName: "Archive Subject Seven",
            aliases: [],
            kinships: [],
            sex: .male,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000077"),
            treeIdentity: .familySearchID("GVQV-NW3"))
        let graph = KinshipFixture.graph
        #expect(graph.people(matching: local.canonicalName).isEmpty,
                "fixture accidentally permits a name bridge")

        let context = HallieTurnExecutor.Context(
            profiles: [local], graph: graph,
            speakers: HallieTurnExecutor.Speakers(
                ownerName: "Someone Else", archivistName: "Hallie Mae"))
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how is Archive Subject Seven related to Martha Lamson?",
            ast: .graph(.init(
                people: ["Archive Subject Seven", "Martha Lamson"],
                operation: .relationship)))

        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent), context: context)
        #expect(result.outcome == .answered, "got: \(result.prose)")
        #expect(result.prose.contains("Martha Lamson"), "got: \(result.prose)")
        #expect(result.prose.contains("8th-great-grandmother"), "got: \(result.prose)")
        #expect(result.basisLine.contains("People profile identity bridge"),
                "the durable identity crossing must remain auditable: \(result.basisLine)")
        #expect(result.basisLine.contains("Archive Subject Seven")
                && result.basisLine.contains("Richard Harding Breen Jr"),
                "the profile and pinned tree identity must both be named: \(result.basisLine)")
        #expect(result.basisLine.contains("path (GEDCOM)"),
                "the relationship must come from the tree path: \(result.basisLine)")
        #expect(!result.basisLine.contains("local only"),
                "a GEDCOM ancestor answer must not be presented as a local-only row")
    }

    @Test func hallieExecutorDoesNotNameBridgeAfterAStaleProfilePin() async throws {
        // The canonical name DOES match @I1@. A stale pin must still win by
        // failing closed; otherwise this test would produce a persuasive but
        // unaudited 8th-great-grandmother answer through the matching name.
        let stale = HallieTurnExecutor.ProfileSnapshot(
            stableID: "stale-rick",
            canonicalName: "Richard Harding Breen Jr",
            treeIdentity: .familySearchID("NOPE-000"))
        let result = try await relationshipResult(
            profiles: [stale], first: stale.canonicalName)

        #expect(result.outcome == .declined, "got: \(result.prose)")
        #expect(result.basisLine.contains("People profile identity route"))
        #expect(result.basisLine.contains("points at a person this tree doesn't carry"))
        #expect(result.basisLine.contains("No name-based GEDCOM bridge was attempted"))
        #expect(!result.basisLine.contains("path (GEDCOM)"))
    }

    @Test func hallieExecutorDoesNotNameBridgeAfterCollidingProfilePins() async throws {
        // Both profiles claim @I1@. Even though the first profile's display
        // name exactly matches that record, neither claimant may bridge.
        let matching = HallieTurnExecutor.ProfileSnapshot(
            stableID: "collision-a",
            canonicalName: "Richard Harding Breen Jr",
            treeIdentity: .familySearchID("GVQV-NW3"))
        let other = HallieTurnExecutor.ProfileSnapshot(
            stableID: "collision-b",
            canonicalName: "Archive Subject Eight",
            treeIdentity: .familySearchID("GVQV-NW3"))
        let result = try await relationshipResult(
            profiles: [matching, other], first: matching.canonicalName)

        #expect(result.outcome == .declined, "got: \(result.prose)")
        #expect(result.basisLine.contains("People profile identity route"))
        #expect(result.basisLine.contains("are both pinned to Richard Harding Breen Jr"))
        #expect(result.basisLine.contains("No name-based GEDCOM bridge was attempted"))
        #expect(!result.basisLine.contains("path (GEDCOM)"))
    }

    private func relationshipResult(
        profiles: [HallieTurnExecutor.ProfileSnapshot], first: String
    ) async throws -> HallieTurnExecutor.Result {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how is \(first) related to Martha Lamson?",
            ast: .graph(.init(
                people: [first, "Martha Lamson"],
                operation: .relationship)))
        return try await HallieTurnExecutor.execute(
            .init(intent: intent),
            context: .init(
                profiles: profiles,
                graph: KinshipFixture.graph,
                speakers: .init(
                    ownerName: "Someone Else", archivistName: "Hallie Mae")))
    }


    // MARK: 2. Scale — see KinshipPerformanceGateTests (Release gate, codex #845)

    /// Invalidation: the display center rebuilds the engine (and so its memo)
    /// on a tree replacement and on a profile edit, and NOT otherwise.
    @Test @MainActor func inferenceMemoInvalidatesOnGraphReplacementAndProfileEdit() {
        let center = KinshipDisplayCenter()
        center.install(graph: KinshipFixture.graph)
        let profiles = KinshipFixture.family
        _ = center.inference(for: profiles)
        #expect(center.inferenceBuildCount == 1)
        _ = center.inference(for: profiles)
        #expect(center.inferenceBuildCount == 1)                     // same inputs: memo hit
        center.install(graph: KinshipFixture.graph)                  // same content, new install
        _ = center.inference(for: profiles)
        #expect(center.inferenceBuildCount == 2)
        var edited = profiles
        edited[3].kinships[0].basis = .attestedFull                  // Tim attested
        let engine = center.inference(for: edited)
        #expect(center.inferenceBuildCount == 3)
        #expect(engine.relation(from: KinshipFixture.node("Tim", in: engine), to: Self.martha)?.term == "8th-great-grandmother")
        center.install(graph: nil)
        #expect(center.inference(for: edited).relation(from: KinshipFixture.node("Tim", in: center.inference(for: edited)), to: Self.martha) == nil)
        #expect(center.inferenceBuildCount == 4)
    }

    // MARK: Acceptance (codex #835 a, c, d, e)

    @Test func proposalsNeverBecomeFactsUntilAttested() {
        // (i) one-parent evidence: proposed, not inherited.
        let one = KinshipFixture.inference([
            KinshipFixture.profile("P1", sex: .male),
            KinshipFixture.profile("Cal", sex: .male, kinships: [KinshipFixture.row(.child, of: "P1")]),
            KinshipFixture.profile("Kid", sex: .female, kinships: [KinshipFixture.row(.sibling, of: "Cal")]),
        ], graph: nil)
        func o(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: one) }
        #expect(one.proposals(for: o("Kid")) == [.init(subject: o("Kid"), kind: .sharedParents(via: o("Cal"), parents: [o("P1")]),
                                                        text: "Kid shares Cal's parents (P1) — assumed full; confirm to inherit Cal's ancestry")])
        #expect(one.parents(of: o("Kid")).isEmpty)
        #expect(one.relation(from: o("Kid"), to: o("P1"))?.term == nil)
        #expect(one.relation(from: o("Kid"), to: o("Cal"))?.term == "brother")

        // (ii) disjoint recorded parent sets under a sibling row: no proposal,
        // no bridge, the word stands with a caveat.
        let disjoint = KinshipFixture.inference([
            KinshipFixture.profile("P1", sex: .male), KinshipFixture.profile("P2", sex: .female),
            KinshipFixture.profile("P3", sex: .male), KinshipFixture.profile("P4", sex: .female),
            KinshipFixture.profile("A", sex: .male, kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
            KinshipFixture.profile("B", sex: .male, kinships: [KinshipFixture.row(.child, of: "P3"), KinshipFixture.row(.child, of: "P4"),
                                                               KinshipFixture.row(.sibling, of: "A")]),
        ], graph: nil)
        func d(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: disjoint) }
        #expect(disjoint.proposals(for: d("B")).isEmpty)
        #expect(disjoint.parents(of: d("B")).map(\.node) == [d("P3"), d("P4")])
        let ab = disjoint.relation(from: d("A"), to: d("B"))
        #expect(ab?.term == "brother")
        #expect(ab?.caveats == ["recorded parents don't overlap (P1 and P2 vs P3 and P4) — check the rows"])
        #expect(disjoint.relation(from: d("A"), to: d("P3"))?.term == nil)

        // (iii) two sibling rows proposing four parents: two proposals, no
        // facts; attesting BOTH is contradictory and inherits nothing.
        func fourParents(_ basis: SiblingBasis) -> FamilyKinshipInference {
            KinshipFixture.inference([
                KinshipFixture.profile("P1", sex: .male), KinshipFixture.profile("P2", sex: .female),
                KinshipFixture.profile("P3", sex: .male), KinshipFixture.profile("P4", sex: .female),
                KinshipFixture.profile("A", sex: .male, kinships: [KinshipFixture.row(.child, of: "P1"), KinshipFixture.row(.child, of: "P2")]),
                KinshipFixture.profile("Z", sex: .male, kinships: [KinshipFixture.row(.child, of: "P3"), KinshipFixture.row(.child, of: "P4")]),
                KinshipFixture.profile("Kid", sex: .female, kinships: [KinshipFixture.row(.sibling, of: "A", basis: basis),
                                                                       KinshipFixture.row(.sibling, of: "Z", basis: basis)]),
            ], graph: nil)
        }
        let four = fourParents(.unspecified)
        #expect(four.proposals(for: KinshipFixture.node("Kid", in: four)).count == 2)
        #expect(four.parents(of: KinshipFixture.node("Kid", in: four)).isEmpty)
        let both = fourParents(.attestedFull)
        let kid = KinshipFixture.node("Kid", in: both)
        #expect(both.parents(of: kid).isEmpty)
        #expect(both.attestationProblems[kid] == "Kid's attested sibling rows imply more than two parents (P1, P2, P3, P4) — nothing inherited until one is corrected")
        #expect(both.relation(from: kid, to: KinshipFixture.node("P1", in: both))?.term == nil)
        #expect(both.relation(from: kid, to: KinshipFixture.node("A", in: both))?.term == "brother")
    }

    @Test func provenanceCarriesDurableIdentitiesOnly() {
        let tim = inf.relation(from: n("Rick"), to: n("Tim"))
        let timID = KinshipFixture.family.first { $0.name == "Tim" }!.uuid.uuidString.lowercased()
        #expect(tim?.provenance == [.profileRow(profileIdentity: "uuid:" + timID)])
        #expect(inf.identity(of: n("Rick")) == "fsid:GVQV-NW3")
        #expect(inf.identity(of: Self.martha) == "fsid:ANC9-009")
        func a(_ s: String) -> FamilyKinshipInference.Node { KinshipFixture.node(s, in: attested) }
        let d = attested.relation(from: a("Tim"), to: Self.martha)
        for p in d?.provenance ?? [] {
            switch p {
            case .profileRow(let id):       #expect(id.hasPrefix("uuid:"), Comment(rawValue: id))
            case .attestedSibling(let id):  #expect(id.hasPrefix("fsid:") || id.hasPrefix("uuid:"), Comment(rawValue: id))
            case .tree:                     break
            }
        }
        #expect(d?.pathHash.count == 16)
        #expect(d?.pathHash == attested.pathHash(d?.route ?? []))
        // Two engines over the same data agree on the key; a different path
        // (Rick → Martha) does not.
        let again = KinshipFixture.inference(Self.attestedFamily)
        #expect(again.relation(from: KinshipFixture.node("Tim", in: again), to: Self.martha)?.pathHash == d?.pathHash)
        #expect(attested.relation(from: a("Rick"), to: Self.martha)?.pathHash != d?.pathHash)
    }

    @Test func reversedProfileAndRowOrderPinRouteProvenanceSpokenRouteAndHash() {
        let base = KinshipFixture.family(timBasis: .attestedFull)
        var rowsReversed = base
        for i in rowsReversed.indices { rowsReversed[i].kinships.reverse() }
        let variants = [base, Array(base.reversed()), rowsReversed, Array(rowsReversed.reversed())]
        let engines = variants.map { KinshipFixture.inference($0) }
        let names = base.map(\.name)
        var compared = 0
        for a in names {
            for b in names + ["@A9@", "@X2@"] where a != b {
                let answers = engines.map { e -> FamilyKinshipInference.Derived? in
                    let to: FamilyKinshipInference.Node = b.hasPrefix("@") ? .tree(gedcomID: b) : KinshipFixture.node(b, in: e)
                    return e.relation(from: KinshipFixture.node(a, in: e), to: to)
                }
                for other in answers.dropFirst() {
                    #expect(other?.route.map(\.relation) == answers[0]?.route.map(\.relation), "\(a) → \(b) route")
                    #expect(other?.route.map(\.to) == answers[0]?.route.map(\.to), "\(a) → \(b) nodes")
                    #expect(other?.provenance == answers[0]?.provenance, "\(a) → \(b) provenance")
                    #expect(other?.routeText == answers[0]?.routeText, "\(a) → \(b) spoken")
                    #expect(other?.pathHash == answers[0]?.pathHash, "\(a) → \(b) hash")
                    #expect(other?.term == answers[0]?.term, "\(a) → \(b) term")
                }
                compared += 1
            }
        }
        #expect(compared == names.count * (names.count + 1))
    }

    /// Tier B tie: Kid's two pinned parents (P16, P17 — spouses) both reach
    /// Root (P1) at the same cost; the entry with the smaller identity key
    /// wins every time.
    @Test func equalCostTierBRoutesPickTheStableEntry() {
        let graph = KinshipFixture.pedigree5001
        let base = [
            KinshipFixture.profile("Root", sex: .female, pin: "S000-001"),
            KinshipFixture.profile("Pa", sex: .male, pin: "S000-016"),
            KinshipFixture.profile("Ma", sex: .female, pin: "S000-017"),
            KinshipFixture.profile("Kid", sex: .male, kinships: [KinshipFixture.row(.child, of: "Pa"), KinshipFixture.row(.child, of: "Ma")]),
        ]
        func build(_ reversed: Bool) -> FamilyKinshipInference {
            var profiles = base                       // same uuids in both orders
            if reversed { profiles.reverse(); profiles[0].kinships.reverse() }
            return KinshipFixture.inference(profiles, graph: graph)
        }
        var hashes = Set<String>()
        for reversed in [false, true] {
            let inf = build(reversed)
            let d = inf.relation(from: KinshipFixture.node("Kid", in: inf), to: KinshipFixture.node("Root", in: inf))
            #expect(d?.term == "great-great-niece")
            #expect(d?.route.map(\.relation) == [.parent, .child, .child, .child, .child])
            #expect(d?.route.first?.to == .tree(gedcomID: "@P16@"))
            #expect(d?.routeText == "father Pa → son Person8 Line → son Person4 Line → son Person2 Line → daughter Root")
            #expect(d?.provenance == [.profileRow(profileIdentity: inf.identity(of: KinshipFixture.node("Kid", in: inf))), .tree])
            if let h = d?.pathHash { hashes.insert(h) }
        }
        #expect(hashes.count == 1)
    }

    /// Full executor, graph == nil: "how is Tim related to Rick?" is a
    /// People-tab answer and must not need a GEDCOM (codex #835 e).
    @Test func hallieAnswersLocalRelationshipsWithoutATree() async throws {
        let profiles = KinshipFixture.family.map {
            HallieTurnExecutor.ProfileSnapshot(stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                                               birthdate: $0.birthdate, kinships: $0.kinships, sex: $0.sex, uuid: $0.uuid)
        }
        let context = HallieTurnExecutor.Context(
            profiles: profiles, graph: nil, cyberBrain: nil,
            speakers: HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how is Tim related to Rick?",
            ast: .graph(.init(people: ["Tim", "Rick"], operation: .relationship)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose == "Rick is Tim's older brother.")   // executor convention: second person described from the first
        // No link and no tree: an honest decline that names the reason.
        let stranger = HallieTurnExecutor.Intent(
            originalQuestion: "how is Nana related to Rick?",
            ast: .graph(.init(people: ["Nana", "Rick"], operation: .relationship)))
        let declined = try await HallieTurnExecutor.execute(.init(intent: stranger), context: context)
        #expect(declined.outcome == .declined)
        #expect(declined.basisLine == "Basis: no readable GEDCOM was available; the People-tab relationships don't link them.")
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
                          inference: FamilyKinshipInference? = nil, profiles: [POIProfile] = KinshipFixture.family)
        -> [KinshipValidation.Finding] {
        let inf = inference ?? self.inf
        let existing = profiles.first { $0.name == subject }?.kinships ?? []
        return KinshipValidation.validate(
            candidate: Kinship(relation: relation, relativeTo: .profile(name: anchor)),
            subjectProfileStableID: subject.lowercased(),
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

    @Test func semanticDuplicatesAcrossInverseRowsAndProfiles() {
        #expect(rules(validate("Tim", .sibling, of: "Rick")) == [.duplicateRow, .siblingWithParentsRecorded])
        #expect(rules(validate("Rick", .sibling, of: "Tim")) == [.duplicateRow, .siblingWithParentsRecorded])   // inverse, other profile
        #expect(rules(validate("Rick", .spouse, of: "Donna")) == [.duplicateRow])
        #expect(rules(validate("Rick", .parent, of: "Michael")) == [.duplicateRow])   // Michael's "child of Rick"
        #expect(rules(validate("Rick", .child, of: "Eileen")) == [.duplicateRow])     // Eileen's "parent of Rick"
        #expect(rules(validate("Rick", .child, of: "Dad")) == [.duplicateRow])        // not a third parent
    }

    @Test func conflictingRelationsOnOnePair() {
        #expect(rules(validate("Tim", .parent, of: "Rick")).contains(.conflictingRelation))   // sibling + parent
        #expect(rules(validate("Donna", .child, of: "Rick")).contains(.conflictingRelation))  // spouse + child
        #expect(rules(validate("Eileen", .spouse, of: "Rick")).contains(.conflictingRelation)) // parent + spouse
        let f = validate("Michael", .sibling, of: "Rick")
        #expect(f.map(\.rule).contains(.conflictingRelation))
        #expect(f.first { $0.rule == .conflictingRelation }?.message
                == "Michael is already recorded as Rick's son — they can't also be their brother.")
        #expect(f.blocksSave)
    }

    @Test func parentChildCyclesOfAnyLengthIncludingTreeAncestors() {
        #expect(rules(validate("Dad", .child, of: "Michael")).contains(.parentChildCycle))
        #expect(rules(validate("Michael", .parent, of: "Dad")).contains(.parentChildCycle))
        // Through the tree via pins: Martha Lamson pinned as a profile.
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Martha", sex: .female, pin: "ANC9-009")]
        let inf2 = KinshipFixture.inference(profiles)
        #expect(KinshipFixture.node("Martha", in: inf2) == .tree(gedcomID: "@A9@"))
        let viaTree = validate("Rick", .parent, of: "Martha", inference: inf2, profiles: profiles)
        #expect(rules(viaTree).contains(.parentChildCycle))
        #expect(viaTree.blocksSave)
        #expect(rules(validate("Martha", .child, of: "Kevin", inference: inf2, profiles: profiles)).contains(.parentChildCycle))
        // Unattested sibling: Tim is NOT below Dad, so "Dad child of Tim" is a
        // conflict-free (if odd) row — no cycle claimed from an assumption.
        #expect(!rules(validate("Dad", .child, of: "Tim")).contains(.parentChildCycle))
        // Attested: now it is a cycle.
        let att = KinshipFixture.inference(KinshipFixture.family(timBasis: .attestedFull))
        #expect(rules(validate("Dad", .child, of: "Tim", inference: att)).contains(.parentChildCycle))
    }

    @Test func moreThanTwoParentsAfterNodeDedup() {
        // Rick: row to Dad + tree father @I2@ are ONE vertex, + Eileen = 2.
        #expect(inf.explicitParents(of: KinshipFixture.node("Rick", in: inf)).count == 2)
        let f = validate("Rick", .child, of: "Ann")
        #expect(rules(f) == [.tooManyParents])
        #expect(f[0].message == "Rick already has two parents recorded (Dad and Eileen) — remove one before adding a third.")
        #expect(rules(validate("Nana", .parent, of: "Rick")) == [.tooManyParents])
    }

    @Test func siblingOfAnAncestorOrDescendantIsAnError() {
        let f = validate("Michael", .sibling, of: "Dad")
        #expect(rules(f) == [.siblingOfLineal])
        #expect(f[0].message == "Dad is an ancestor of Michael — they can't be siblings.")
        #expect(rules(validate("Dad", .sibling, of: "Michael")) == [.siblingOfLineal])
    }

    @Test func danglingAndStaleAnchorsAreErrors() {
        let unknownTree = KinshipValidation.validate(
            candidate: Kinship(relation: .parent, relativeTo: .treePerson(familySearchID: "NOPE")),
            subjectProfileStableID: "rick", existingRows: [], inference: inf)
        #expect(rules(unknownTree) == [.unresolvedAnchor])
        let removed = KinshipValidation.validate(
            candidate: Kinship(relation: .spouse, relativeTo: .profile(id: UUID())),
            subjectProfileStableID: "rick", existingRows: [], inference: inf)
        #expect(rules(removed) == [.unresolvedAnchor])
        // A stale pointer anchor already on a profile resolves to a placeholder.
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Old", kinships: [
            Kinship(relation: .child, relativeTo: .treePointer(pointer: "@I9@", sourceFingerprint: "stale")),
        ])]
        let inf2 = KinshipFixture.inference(profiles)
        let stale = KinshipValidation.validate(
            candidate: Kinship(relation: .spouse, relativeTo: .treePointer(pointer: "@I9@", sourceFingerprint: "stale")),
            subjectProfileStableID: "rick", existingRows: [], inference: inf2)
        #expect(rules(stale) == [.unresolvedAnchor])
    }

    @Test func collidingPinsBlockRowsOnEitherProfile() {
        let profiles = KinshipFixture.family + [KinshipFixture.profile("Rick2", sex: .male, pin: "GVQV-NW3")]
        let inf2 = KinshipFixture.inference(profiles)
        let onSubject = validate("Rick2", .sibling, of: "Tim", inference: inf2, profiles: profiles)
        #expect(rules(onSubject) == [.treePinProblem])
        #expect(onSubject.blocksSave)
        let onAnchor = validate("Nana", .parent, of: "Rick2", inference: inf2, profiles: profiles)
        #expect(rules(onAnchor) == [.treePinProblem])
        // A stale pin on the anchor blocks too.
        let stale = KinshipFixture.family + [KinshipFixture.profile("Ghost", pin: "NOPE-000")]
        let inf3 = KinshipFixture.inference(stale)
        #expect(rules(validate("Nana", .parent, of: "Ghost", inference: inf3, profiles: stale)) == [.treePinProblem])
    }

    @Test func parentNotOlderRespectsPrecisionAndIsAWarning() {
        let f = validate("Tim", .parent, of: "Ann")     // Tim 1965, Ann 1961
        #expect(rules(f) == [.parentNotOlder])
        #expect(!f.blocksSave)
        #expect(f[0].message == "Tim (born 1965) is not older than Ann (born 1961) — check the birthdates.")
        #expect(rules(validate("Ann", .child, of: "Tim")) == [.parentNotOlder])
        #expect(validate("Nana", .parent, of: "Ann").isEmpty)
        // Same exact year: not provably older ⇒ warning.
        let same = KinshipFixture.family + [KinshipFixture.profile("Twin", born: 1931)]
        let inf2 = KinshipFixture.inference(same)
        #expect(rules(validate("Twin", .parent, of: "Dad", inference: inf2, profiles: same)) == [.parentNotOlder])
        // "ABT 1903" (Ancestor1) vs a profile born 1904: overlap ⇒ nothing provable ⇒ no warning.
        let about = KinshipFixture.family + [KinshipFixture.profile("A1", pin: "ANC1-001"), KinshipFixture.profile("Kid", born: 1904)]
        let inf3 = KinshipFixture.inference(about)
        #expect(validate("Kid", .child, of: "A1", inference: inf3, profiles: about).isEmpty)
        // …but born 1890 is provably before ⇒ warning with the tree's own wording.
        let before = KinshipFixture.family + [KinshipFixture.profile("A1", pin: "ANC1-001"), KinshipFixture.profile("Elder", born: 1890)]
        let inf4 = KinshipFixture.inference(before)
        let w = validate("Elder", .child, of: "A1", inference: inf4, profiles: before)
        #expect(rules(w) == [.parentNotOlder])
        #expect(w[0].message == "A1 (born about 1903) is not older than Elder (born 1890) — check the birthdates.")
    }

    @Test func spouseBirthYearsProvablyMoreThanFortyApartWarn() {
        let f = validate("Bob", .spouse, of: "Nana")   // 1958 vs 1905
        #expect(rules(f) == [.spouseAgeGap])
        #expect(!f.blocksSave)
        #expect(f[0].message == "Bob and Nana were born at least 53 years apart — check the birthdates.")
        #expect(validate("Kevin", .spouse, of: "Nana").blocksSave == false)
        #expect(validate("Bob", .spouse, of: "Tim").isEmpty)
    }

    @Test func siblingRowWhileBothParentsRecordedSuggestsConversion() {
        let f = validate("Ann", .sibling, of: "Rick")
        #expect(rules(f) == [.siblingWithParentsRecorded])
        #expect(!f.blocksSave)
        #expect(f[0].message == "Rick's parents are both recorded (Dad and Eileen) — record Ann as their child instead and the sibling link is derived (convert to shared parents).")
        #expect(validate("Bob", .sibling, of: "Nana").isEmpty)
    }

    @Test func legalRowsPassClean() {
        #expect(validate("Kevin", .child, of: "Donna").isEmpty)
        #expect(validate("Nana", .parent, of: "Donna").isEmpty)
        #expect(validate("Bob", .sibling, of: "Nana").isEmpty)
        #expect(validate("Tim", .spouse, of: "Nana").blocksSave == false)
        // Local-only (graph == nil): pins can't be checked, so a row that
        // does not touch a pinned profile is still fine; one that does is
        // blocked honestly (the pin problem), not silently accepted.
        let offline = KinshipFixture.inference(graph: nil)
        #expect(validate("Bob", .sibling, of: "Nana", inference: offline).isEmpty)
        #expect(rules(validate("Kevin", .child, of: "Donna", inference: offline)) == [.treePinProblem])
    }

    @Test func attestingASiblingThatWouldGiveThreeParentsIsAnError() {
        // Tim already has Dad + Eileen through his attested row to Rick; a
        // second attested-full row to Zoe (parents Q1, Q2) is a conflict.
        let profiles = KinshipFixture.family(timBasis: .attestedFull) + [
            KinshipFixture.profile("Q1", sex: .male), KinshipFixture.profile("Q2", sex: .female),
            KinshipFixture.profile("Zoe", sex: .female, kinships: [KinshipFixture.row(.child, of: "Q1"), KinshipFixture.row(.child, of: "Q2")]),
        ]
        let inf = KinshipFixture.inference(profiles)
        let timRows = profiles.first { $0.name == "Tim" }?.kinships ?? []
        let f = KinshipValidation.validate(
            candidate: KinshipFixture.row(.sibling, of: "Zoe", basis: .attestedFull),
            subjectProfileStableID: "tim", existingRows: timRows, inference: inf)
        #expect(rules(f).contains(.attestationConflict))
        #expect(f.first { $0.rule == .attestationConflict }?.message
                == "Attesting this sibling link would give Tim more than two parents (Dad, Eileen, Q1, Q2) — correct the other rows first.")
        // Unspecified: fine (a proposal, not a fact).
        #expect(!KinshipValidation.validate(
            candidate: KinshipFixture.row(.sibling, of: "Zoe"),
            subjectProfileStableID: "tim", existingRows: timRows, inference: inf).blocksSave)
        // A half row naming a parent that does not exist: unresolved.
        let stale = KinshipValidation.validate(
            candidate: KinshipFixture.row(.sibling, of: "Zoe", basis: .attestedHalf(sharedParent: .profile(id: UUID()))),
            subjectProfileStableID: "tim", existingRows: [], inference: inf)
        #expect(rules(stale).contains(.unresolvedAnchor))
    }

    // MARK: Whole-batch validation (codex #835 b)

    @Test func batchCatchesThreeParentsEnteredTogether() {
        let batch = [KinshipFixture.row(.child, of: "Rick"), KinshipFixture.row(.child, of: "Donna"), KinshipFixture.row(.child, of: "Tim")]
        let result = KinshipValidation.validate(batch: batch, subjectProfileStableID: "nana",
                                                profiles: KinshipFixture.family, graph: KinshipFixture.graph)
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.findings.map(\.rule).contains(.tooManyParents) })
        #expect(result.blocksSave)
        // Two parents together: legal (Nana 1905 is older than both — only
        // the birthdate warning about a child born before the parent).
        let two = KinshipValidation.validate(batch: Array(batch.prefix(2)), subjectProfileStableID: "nana",
                                             profiles: KinshipFixture.family, graph: KinshipFixture.graph)
        #expect(!two.blocksSave)
        #expect(two.flatMap(\.findings).map(\.rule) == [.parentNotOlder, .parentNotOlder])
    }

    @Test func batchCatchesDuplicatesTypedTwiceAndMultiRowCycles() {
        let twice = [KinshipFixture.row(.spouse, of: "Bob"), KinshipFixture.row(.spouse, of: "Bob")]
        let dup = KinshipValidation.validate(batch: twice, subjectProfileStableID: "nana",
                                             profiles: KinshipFixture.family, graph: KinshipFixture.graph)
        #expect(dup.map { $0.findings.map(\.rule) } == [[.duplicateRow, .spouseAgeGap], [.duplicateRow, .spouseAgeGap]])
        // A cycle that only closes through two new rows: C child of B and C
        // parent of A, where B is A's child.
        let profiles = [
            KinshipFixture.profile("A"), KinshipFixture.profile("B", kinships: [KinshipFixture.row(.child, of: "A")]),
            KinshipFixture.profile("C"),
        ]
        let rows = [KinshipFixture.row(.child, of: "B"), KinshipFixture.row(.parent, of: "A")]
        let cycle = KinshipValidation.validate(batch: rows, subjectProfileStableID: "c", profiles: profiles, graph: nil)
        #expect(cycle.map { $0.findings.map(\.rule) } == [[.parentChildCycle], [.parentChildCycle]])
        // Each row alone would have passed the single-candidate check.
        let alone = KinshipFixture.inference(profiles, graph: nil)
        for row in rows {
            #expect(KinshipValidation.validate(candidate: row, subjectProfileStableID: "c", existingRows: [], inference: alone).isEmpty)
        }
    }

    @Test func batchSkipsUnchangedRowsAndReportsUnknownProfiles() {
        let tim = KinshipFixture.family.first { $0.name == "Tim" }!
        #expect(KinshipValidation.validate(batch: tim.kinships, subjectProfileStableID: "tim",
                                           profiles: KinshipFixture.family, graph: KinshipFixture.graph).isEmpty)
        let ghost = KinshipValidation.validate(batch: [KinshipFixture.row(.spouse, of: "Rick")], subjectProfileStableID: "ghost",
                                               profiles: KinshipFixture.family, graph: KinshipFixture.graph)
        #expect(ghost.map { $0.findings.map(\.rule) } == [[.unresolvedAnchor]])
    }

    /// SENSOR: validation never blocks a legal save — every row in the
    /// fixture, re-validated against the family WITHOUT that row, produces
    /// no error (both sibling-basis fixtures).
    @Test func everyFixtureRowRevalidatesWithoutErrors() {
        for family in [KinshipFixture.family, KinshipFixture.family(timBasis: .attestedFull)] {
            for profile in family {
                for (i, row) in profile.kinships.enumerated() {
                    var without = family
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
}
