// TreeIdentityDeriverTests.swift
// Auto-derived profile → family-tree identity (Rick, 2026-08-29: "the app
// knows my identity — can't it auto-derive that from the family tree?").
// Five dimensions:
//   1. Logic     — deriver matrix on a synthetic two-root tree (owner,
//                  Donna root, Tim through a kinship row to pinned Rick,
//                  namesake + birth year, two namesakes without one, sex /
//                  claimed-record exclusions); Show-in-tree reducer per state
//   2. Scale     — n/a (indexed name lookups; the kinship suite gates the tree)
//   3. Media     — n/a
//   4. Isolation — in-memory GEDCOM text + profiles, a capturing store, a
//                  throwaway UserDefaults suite; UserDefaults.standard is never
//                  read or written; a poisoned owner setting fails closed
//   5. Sensors   — "Tim is never pinned by name" and "auto-accept is owner
//                  and root ONLY" pinned as explicit tests
// The GEDCOM is synthetic (2026-08-03 privacy policy); only the two
// Richards' FamilySearch IDs are the fixture IDs the kinship tests use.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixture

enum TreeIdentityFixture {

    /// Merged two-root tree: Rick (@I1@) and Donna (@I3@) are the recorded
    /// home people. Sr (@I2@) + Eileen (@I4@) → Rick ═ Donna. Two John
    /// Breens (1900 / 1940) and two undated Walter Lambs for the namesake
    /// rows; a stray non-root "Rick Smith" for the literal-name trap.
    static let gedcom = """
    0 HEAD
    1 _VS_MERGED Y
    1 _VS_ROOT @I1@
    1 _VS_ROOT @I3@
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 _FSFTID G2S4-JF4
    1 BIRT
    2 DATE 4 MAR 1931
    2 PLAC Albany, New York
    1 FAMS @F0@
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 _FSFTID GVQV-NW3
    1 FAMC @F0@
    1 FAMS @F2@
    0 @I3@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 _FSFTID DONN-A03
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 _FSFTID EILN-001
    1 BIRT
    2 DATE 1935
    1 FAMS @F0@
    0 @I5@ INDI
    1 NAME John /Breen/
    1 SEX M
    1 _FSFTID JOHN-001
    1 BIRT
    2 DATE 1900
    0 @I6@ INDI
    1 NAME John /Breen/
    1 SEX M
    1 _FSFTID JOHN-002
    1 BIRT
    2 DATE 1940
    2 PLAC Boston, Massachusetts
    0 @I7@ INDI
    1 NAME Walter /Lamb/
    1 SEX M
    1 _FSFTID WALT-001
    0 @I8@ INDI
    1 NAME Walter /Lamb/
    1 SEX M
    1 _FSFTID WALT-002
    0 @I9@ INDI
    1 NAME Rick /Smith/
    1 SEX M
    1 _FSFTID RICK-SMI
    0 @F0@ FAM
    1 HUSB @I2@
    1 WIFE @I4@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    0 TRLR
    """

    static let graph = GedcomFamilyGraph(gedcomText: gedcom)

    static func profile(_ name: String, aliases: [String] = [], sex: PersonSex? = nil,
                        born: Int? = nil, kinships: [Kinship] = [], pin: String? = nil,
                        notInTree: Bool = false) -> POIProfile {
        var p = POIProfile(name: name, referencePath: "/fixture/\(name)", aliases: aliases,
                           birthdate: born.map { KinshipFixture.date($0) }, sex: sex, kinships: kinships,
                           treeIdentity: pin.map { .familySearchID($0) })
        p.notInFamilyTree = notInTree
        return p
    }

    static let rick = profile("Rick", aliases: ["Dicky", "Dad"], sex: .male, born: 1962)
    static let donna = profile("Donna", sex: .female, born: 1959)
    static let tim = profile("Tim", sex: .male, born: 1965,
                             kinships: [Kinship(relation: .sibling, relativeTo: .profile(name: "Rick"))])

    static func deriver(_ profiles: [POIProfile], ownerName: String? = "Rick Breen",
                        ownerFSID: String? = "GVQV-NW3") -> TreeIdentityDeriver {
        TreeIdentityDeriver(graph: graph, profiles: profiles, ownerName: ownerName, ownerFamilySearchID: ownerFSID)
    }

    static func certainID(_ d: TreeIdentityDerivation) -> String? { d.certainCandidate?.personID }
    static func reason(_ d: TreeIdentityDerivation) -> TreeIdentityDerivation.Reason? {
        if case .certain(_, let r) = d { return r }
        return nil
    }
}

// MARK: - Deriver

@Suite("TreeIdentityDeriver — evidence ranking")
struct TreeIdentityDeriverTests {
    typealias F = TreeIdentityFixture

    @Test func ownerProfileDerivesTheOwnerPin() {
        let d = F.deriver([F.rick, F.donna, F.tim])
        let v = d.derive(TreeIdentitySubject(F.rick))
        #expect(F.certainID(v) == "@I1@")
        #expect(F.reason(v) == .ownerSetting)
        #expect(v.isAutoAcceptable)
    }

    @Test func ownerWithoutASettingFallsToTheMatchingRoot() {
        let d = F.deriver([F.rick, F.donna], ownerFSID: nil)
        let v = d.derive(TreeIdentitySubject(F.rick))
        #expect(F.certainID(v) == "@I1@")
        #expect(F.reason(v) == .treeRoot)
    }

    @Test func poisonedOwnerSettingFailsClosedToTheRootRule() {
        // A stale / garbage owner ID never pins anyone and never reaches
        // UserDefaults: the deriver only sees the string it was handed.
        for poisoned in ["ZZZZ-999", "not an id", ""] {
            let d = F.deriver([F.rick, F.donna], ownerFSID: poisoned)
            let v = d.derive(TreeIdentitySubject(F.rick))
            #expect(F.reason(v) == .treeRoot, "poisoned '\(poisoned)'")
            #expect(F.certainID(v) == "@I1@")
        }
    }

    @Test func secondRootDerivesByName() {
        let v = F.deriver([F.rick, F.donna]).derive(TreeIdentitySubject(F.donna))
        #expect(F.certainID(v) == "@I3@")
        #expect(F.reason(v) == .treeRoot)
        #expect(v.isAutoAcceptable)
    }

    @Test func literalNonRootNamesakeDoesNotStealTheRoot() {
        // "Rick Smith" is on the tree; the owner profile still goes to the
        // owner pin / root, never to the literal spelling.
        let v = F.deriver([F.rick], ownerFSID: nil).derive(TreeIdentitySubject(F.rick))
        #expect(F.certainID(v) == "@I1@")
    }

    /// SENSOR: a contemporary with no tree record is never pinned by a name
    /// or kinship coincidence — Tim's sibling row reaches Rick's record, and
    /// Rick has no siblings on FamilySearch.
    @Test func timHasNoTreeRecordAndIsNeverPinned() {
        let rickPinned = F.profile("Rick", aliases: ["Dicky"], sex: .male, born: 1962, pin: "GVQV-NW3")
        let v = F.deriver([rickPinned, F.donna, F.tim]).derive(TreeIdentitySubject(F.tim))
        #expect(v == TreeIdentityDerivation.none)
        let all = F.deriver([rickPinned, F.donna, F.tim]).deriveAll()
        #expect(all["tim"] == TreeIdentityDerivation.none)
        #expect(all["rick"] == nil, "a pinned profile is not re-derived")
    }

    @Test func namesakeWithBirthYearIsCertain() {
        let john = F.profile("John Breen", sex: .male, born: 1940)
        let v = F.deriver([F.rick, john]).derive(TreeIdentitySubject(john))
        #expect(F.certainID(v) == "@I6@")
        #expect(F.reason(v) == .nameAndBirth)
        #expect(!v.isAutoAcceptable, "name evidence waits for Show in Family Tree")
    }

    @Test func namesakeBornOutsideEveryRecordIsNotCertain() {
        let john = F.profile("John Breen", sex: .male, born: 1970)
        let v = F.deriver([F.rick, john]).derive(TreeIdentitySubject(john))
        #expect(v.certainCandidate == nil)
    }

    @Test func twoNamesakesWithoutBirthYearAreAmbiguous() {
        let walter = F.profile("Walter Lamb", sex: .male)
        let v = F.deriver([F.rick, walter]).derive(TreeIdentitySubject(walter))
        guard case .ambiguous(let candidates) = v else {
            Issue.record("expected ambiguous, got \(v)"); return
        }
        #expect(Set(candidates.map(\.personID)) == ["@I7@", "@I8@"])
        #expect(candidates.allSatisfy { $0.detail.isEmpty })
    }

    @Test func candidateCarriesYearAndPlaceForTheSheet() {
        let john = F.profile("John Breen", sex: .male, born: 1940)
        let v = F.deriver([john]).derive(TreeIdentitySubject(john))
        let c = try! #require(v.certainCandidate)
        #expect(c.label == "John Breen (b. 1940)")
        #expect(c.detail == "b. 1940, Boston, Massachusetts")
        #expect(c.code == "JOHN-002")
        #expect(c.identity(fingerprint: nil) == .familySearchID("JOHN-002"))
    }

    @Test func sexMismatchExcludesTheRecord() {
        let john = F.profile("John Breen", sex: .female, born: 1940)
        let v = F.deriver([john]).derive(TreeIdentitySubject(john))
        #expect(v == TreeIdentityDerivation.none)
    }

    @Test func dadDerivesSrByAliasAndBirth() {
        let dad = F.profile("Dad", aliases: ["Richard Harding Breen Sr"], sex: .male, born: 1931)
        let v = F.deriver([F.rick, dad]).derive(TreeIdentitySubject(dad))
        #expect(F.certainID(v) == "@I2@")
        #expect(F.reason(v) == .nameAndBirth)
    }

    @Test func kinshipRowToAPinnedProfileSettlesAOneWordName() {
        // "Eileen" alone is one record but a one-word spelling; her
        // "parent of Rick" row against pinned Rick makes it certain.
        let rickPinned = F.profile("Rick", sex: .male, born: 1962, pin: "GVQV-NW3")
        let eileen = F.profile("Eileen", sex: .female,
                               kinships: [Kinship(relation: .parent, relativeTo: .profile(name: "Rick"))])
        let v = F.deriver([rickPinned, eileen]).derive(TreeIdentitySubject(eileen))
        #expect(F.certainID(v) == "@I4@")
        #expect(F.reason(v) == .nameAndKinship)

        // Without the row the same one-word match is offered, not assumed.
        let plain = F.profile("Eileen", sex: .female)
        let w = F.deriver([rickPinned, plain]).derive(TreeIdentitySubject(plain))
        #expect(w == .ambiguous([TreeIdentityCandidate(F.graph.people["@I4@"]!)]))
    }

    @Test func uniqueFullNameWithoutBirthIsCertain() {
        let eileen = F.profile("Eileen Latta", sex: .female)
        let v = F.deriver([eileen]).derive(TreeIdentitySubject(eileen))
        #expect(F.certainID(v) == "@I4@")
        #expect(F.reason(v) == .uniqueFullName)
    }

    @Test func recordClaimedByAnotherProfileIsNeverOffered() {
        let rickPinned = F.profile("Rick", sex: .male, born: 1962, pin: "GVQV-NW3")
        let imposter = F.profile("Richard", aliases: ["Richard Harding Breen Jr"], sex: .male)
        let v = F.deriver([rickPinned, imposter], ownerFSID: nil).derive(TreeIdentitySubject(imposter))
        #expect(v == TreeIdentityDerivation.none)
    }

    @Test func twoOwnerSpelledProfilesGetNoOwnerPinByName() {
        let dadAsRichardBreen = F.profile("Dad", aliases: ["Richard Breen"], sex: .male, born: 1931)
        let d = F.deriver([F.rick, dadAsRichardBreen])
        #expect(F.reason(d.derive(TreeIdentitySubject(F.rick))) != .ownerSetting)
        // Dad still lands on Sr through name + birth, never on the owner pin.
        #expect(F.certainID(d.derive(TreeIdentitySubject(dadAsRichardBreen))) == "@I2@")
    }

    @Test func deriveAllSkipsPinnedQuarantinedAndNotInTree() {
        var quarantined = F.profile("Nana", sex: .female)
        quarantined.treeIdentityQuarantined = .string("garbage")
        let notInTree = F.profile("Bob", sex: .male, notInTree: true)
        let pinned = F.profile("Rick", sex: .male, pin: "GVQV-NW3")
        let all = F.deriver([quarantined, notInTree, pinned, F.donna]).deriveAll()
        #expect(all.keys.sorted() == ["donna"])
    }

    @Test func suggestionsAreCapped() {
        var lines = ["0 HEAD"]
        for i in 1...40 {
            lines += ["0 @P\(i)@ INDI", "1 NAME Mary /Kelly/", "1 SEX F", "1 _FSFTID MARY-\(String(format: "%03d", i))"]
        }
        lines.append("0 TRLR")
        let graph = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        let mary = F.profile("Mary", sex: .female)
        let v = TreeIdentityDeriver(graph: graph, profiles: [mary], ownerName: nil, ownerFamilySearchID: nil)
            .derive(TreeIdentitySubject(mary))
        guard case .ambiguous(let candidates) = v else { Issue.record("expected ambiguous"); return }
        #expect(candidates.count == TreeIdentityDeriver.ambiguityCap)
    }

    /// SENSOR: only the two trusted sources auto-accept.
    @Test func autoAcceptIsOwnerAndRootOnly() {
        for reason in TreeIdentityDerivation.Reason.allCases {
            #expect(reason.isAutoAcceptable == (reason == .ownerSetting || reason == .treeRoot), "\(reason)")
        }
        #expect(TreeIdentityDerivation.Reason.ownerSetting.attestation == "derived: owner setting")
        #expect(TreeIdentityDerivation.Reason.treeRoot.attestation == "derived: tree root")
    }
}

// MARK: - Hallie assumption

@Suite("TreeIdentityDeriver — Hallie assumed bridges")
struct TreeIdentityHallieAssumptionTests {
    typealias F = TreeIdentityFixture

    @Test func certainDerivationsBridgeForOneTurnAndAreNamed() {
        let snapshots = [F.rick, F.donna, F.tim].map {
            HallieTurnExecutor.ProfileSnapshot(stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                                               birthdate: $0.birthdate, kinships: $0.kinships, sex: $0.sex,
                                               uuid: $0.uuid, treeIdentity: $0.treeIdentity)
        }
        let out = TreeIdentityDeriver.assumingCertainPins(
            snapshots: snapshots, graph: F.graph, ownerName: "Rick Breen", ownerFamilySearchID: "GVQV-NW3")
        #expect(out.snapshots[0].treeIdentity == .familySearchID("GVQV-NW3"))
        #expect(out.snapshots[1].treeIdentity == .familySearchID("DONN-A03"))
        #expect(out.snapshots[2].treeIdentity == nil)
        #expect(out.assumed["@I1@"] == "Rick as Richard Harding Breen Jr")
        #expect(out.assumed["@I3@"] == "Donna as Donna Hudson")
        #expect(out.assumed.count == 2)
    }

    @Test func stalePinsStayStale() {
        let stale = HallieTurnExecutor.ProfileSnapshot(stableID: "rick", canonicalName: "Rick",
                                                       treeIdentity: .familySearchID("ZZZZ-999"))
        let out = TreeIdentityDeriver.assumingCertainPins(
            snapshots: [stale], graph: F.graph, ownerName: "Rick Breen", ownerFamilySearchID: "GVQV-NW3")
        #expect(out.snapshots[0].treeIdentity == .familySearchID("ZZZZ-999"))
        #expect(out.assumed.isEmpty)
    }
}

// MARK: - Show in Family Tree reducer

@Suite("ShowInTreeReducer — state machine")
struct ShowInTreeReducerTests {
    typealias F = TreeIdentityFixture
    let jr = TreeIdentityCandidate(F.graph.people["@I1@"]!)

    @Test func noTree() {
        #expect(ShowInTreeReducer.state(profile: F.rick, profiles: [F.rick], graph: nil,
                                        fingerprint: nil, derivation: .certain(jr, reason: .ownerSetting)) == .noTree)
    }

    @Test func pinnedFocuses() {
        let pinned = F.profile("Rick", pin: "GVQV-NW3")
        let s = ShowInTreeReducer.state(profile: pinned, profiles: [pinned], graph: F.graph,
                                        fingerprint: nil, derivation: nil)
        #expect(s == .pinned(jr))
        #expect(ShowInTreeReducer.pinnedLine(profileName: "Rick", candidate: jr)
                == "Rick is Richard Harding Breen Jr · GVQV-NW3")
        #expect(ShowInTreeReducer.usingLine(profileName: "Rick", candidate: jr)
                == "Using Richard Harding Breen Jr (GVQV-NW3) for Rick")
    }

    @Test func stalePinIsAProblemNotAGuess() {
        let stale = F.profile("Rick", pin: "ZZZZ-999")
        guard case .pinProblem(let why) = ShowInTreeReducer.state(
            profile: stale, profiles: [stale], graph: F.graph, fingerprint: nil,
            derivation: .certain(jr, reason: .ownerSetting)) else {
            Issue.record("expected pinProblem"); return
        }
        #expect(why.contains("doesn't carry"))
    }

    @Test func collidingPinsAreAProblem() {
        let a = F.profile("Rick", pin: "GVQV-NW3")
        let b = F.profile("Richard", pin: "GVQV-NW3")
        guard case .pinProblem(let why) = ShowInTreeReducer.state(
            profile: a, profiles: [a, b], graph: F.graph, fingerprint: nil, derivation: nil) else {
            Issue.record("expected pinProblem"); return
        }
        #expect(why.contains("both pinned"))
    }

    @Test func quarantinedPinIsAProblem() {
        var q = F.profile("Rick")
        q.treeIdentityQuarantined = .string("x")
        guard case .pinProblem = ShowInTreeReducer.state(
            profile: q, profiles: [q], graph: F.graph, fingerprint: nil, derivation: nil) else {
            Issue.record("expected pinProblem"); return
        }
    }

    @Test func derivedAmbiguousNoneAndNotInTree() {
        let s1 = ShowInTreeReducer.state(profile: F.rick, profiles: [F.rick], graph: F.graph,
                                         fingerprint: nil, derivation: .certain(jr, reason: .treeRoot))
        #expect(s1 == .derived(jr, reason: .treeRoot))
        let s2 = ShowInTreeReducer.state(profile: F.rick, profiles: [F.rick], graph: F.graph,
                                         fingerprint: nil, derivation: .ambiguous([jr]))
        #expect(s2 == .ambiguous([jr]))
        let s3 = ShowInTreeReducer.state(profile: F.tim, profiles: [F.tim], graph: F.graph,
                                         fingerprint: nil, derivation: TreeIdentityDerivation.none)
        #expect(s3 == ShowInTreeState.none)
        let s4 = ShowInTreeReducer.state(profile: F.tim, profiles: [F.tim], graph: F.graph,
                                         fingerprint: nil, derivation: nil)
        #expect(s4 == ShowInTreeState.none)
        let marked = F.profile("Tim", notInTree: true)
        let s5 = ShowInTreeReducer.state(profile: marked, profiles: [marked], graph: F.graph,
                                         fingerprint: nil, derivation: .certain(jr, reason: .treeRoot))
        #expect(s5 == .notInTree, "a not-in-tree mark beats any derivation")
    }

    @Test func pointerPinHonoursTheFingerprint() {
        let fp = FamilyKinshipOverlay.fingerprint(of: F.graph)
        var p = F.profile("Rick")
        p.treeIdentity = .pointer(pointer: "@I1@", sourceFingerprint: fp)
        #expect(ShowInTreeReducer.state(profile: p, profiles: [p], graph: F.graph,
                                        fingerprint: fp, derivation: nil) == .pinned(jr))
        guard case .pinProblem = ShowInTreeReducer.state(profile: p, profiles: [p], graph: F.graph,
                                                         fingerprint: "other", derivation: nil) else {
            Issue.record("a pointer from another export must not bridge"); return
        }
    }
}

// MARK: - Persistence (injected store + defaults)

@Suite("TreeIdentityPinning — injected store and owner mirror")
struct TreeIdentityPinningTests {
    typealias F = TreeIdentityFixture
    let jr = TreeIdentityCandidate(F.graph.people["@I1@"]!)
    let donna = TreeIdentityCandidate(F.graph.people["@I3@"]!)

    /// A throwaway suite; removed after each test so nothing leaks between
    /// tests or into the real prefs domain.
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "TreeIdentityPinningTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func pinWritesAttestationAndMirrorsTheOwner() {
        withSuite { defaults in
            var saved: [POIProfile] = []
            let outcome = TreeIdentityPinning.pin(
                jr, on: F.rick, among: [F.rick, F.donna], fingerprint: nil,
                attestation: "derived: tree root", ownerName: "Rick Breen",
                store: { saved.append($0) }, defaults: defaults)
            let p = try! #require(outcome.profile)
            #expect(saved.count == 1)
            #expect(p.treeIdentity == .familySearchID("GVQV-NW3"))
            #expect(p.treeIdentityAttestation == "derived: tree root")
            #expect(p.notInFamilyTree == false)
            #expect(defaults.string(forKey: HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey) == "GVQV-NW3")
        }
    }

    @Test func nonOwnerPinDoesNotTouchTheOwnerSetting() {
        withSuite { defaults in
            defaults.set("GVQV-NW3", forKey: HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey)
            _ = TreeIdentityPinning.pin(
                donna, on: F.donna, among: [F.rick, F.donna], fingerprint: nil,
                attestation: "derived: tree root", ownerName: "Rick Breen",
                store: { _ in }, defaults: defaults)
            #expect(defaults.string(forKey: HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey) == "GVQV-NW3")
        }
    }

    @Test func nilDefaultsMirrorsNothing() {
        var saved: [POIProfile] = []
        let outcome = TreeIdentityPinning.pin(
            jr, on: F.rick, among: [F.rick], fingerprint: nil, attestation: "derived: owner setting",
            ownerName: "Rick Breen", store: { saved.append($0) }, defaults: nil)
        #expect(outcome.profile != nil)
        #expect(saved.count == 1)
    }

    @Test func collisionIsRefusedAndNothingIsWritten() {
        let rickPinned = F.profile("Rick", pin: "GVQV-NW3")
        let richard = F.profile("Richard")
        var writes = 0
        let outcome = TreeIdentityPinning.pin(
            jr, on: richard, among: [rickPinned, richard], fingerprint: nil,
            attestation: "picked", ownerName: nil, store: { _ in writes += 1 }, defaults: nil)
        #expect(outcome.refusal?.contains("Rick is already pinned") == true)
        #expect(writes == 0)
    }

    @Test func storeFailureIsReportedNotSwallowed() {
        struct Boom: Error {}
        let outcome = TreeIdentityPinning.pin(
            jr, on: F.rick, among: [F.rick], fingerprint: nil, attestation: "picked",
            ownerName: nil, store: { _ in throw Boom() }, defaults: nil)
        #expect(outcome.refusal?.hasPrefix("Could not save") == true)
    }

    @Test func unpinAndNotInTree() {
        let pinned = F.profile("Rick", pin: "GVQV-NW3")
        let un = try! #require(TreeIdentityPinning.unpin(pinned, store: { _ in }).profile)
        #expect(un.treeIdentity == nil)
        #expect(un.treeIdentityAttestation == nil)
        let marked = try! #require(TreeIdentityPinning.markNotInTree(pinned, store: { _ in }).profile)
        #expect(marked.treeIdentity == nil)
        #expect(marked.notInFamilyTree)
        // Re-pinning clears the mark.
        let again = try! #require(TreeIdentityPinning.pin(
            jr, on: marked, among: [marked], fingerprint: nil, attestation: "picked",
            ownerName: nil, store: { _ in }, defaults: nil).profile)
        #expect(!again.notInFamilyTree)
    }

    @Test func newProfileFieldsRoundTripAndOlderJSONLoads() throws {
        var p = F.profile("Rick", pin: "GVQV-NW3")
        p.treeIdentityAttestation = "derived: owner setting"
        p.notInFamilyTree = false
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(POIProfile.self, from: data)
        #expect(back.treeIdentityAttestation == "derived: owner setting")
        #expect(back.notInFamilyTree == false)
        // A profile.json from before the fields existed.
        let legacy = Data(#"{"name":"Tim","referencePath":"/x"}"#.utf8)
        let old = try JSONDecoder().decode(POIProfile.self, from: legacy)
        #expect(old.treeIdentityAttestation == nil)
        #expect(old.notInFamilyTree == false)
    }
}

// MARK: - Center (memo + auto-accept), isolated

@Suite("TreeIdentityCenter — memo and auto-accept")
@MainActor
struct TreeIdentityCenterTests {
    typealias F = TreeIdentityFixture

    private func makeCenter() -> (TreeIdentityCenter, KinshipDisplayCenter) {
        let kinship = KinshipDisplayCenter()
        let center = TreeIdentityCenter(kinshipCenter: kinship)
        center.defaults = nil
        center.speakers = { HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                                        ownerFamilySearchID: "GVQV-NW3") }
        return (center, kinship)
    }

    @Test func autoAcceptsOwnerAndRootOnlyAndMemoises() async {
        let (center, kinship) = makeCenter()
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }
        let john = F.profile("John Breen", sex: .male, born: 1940)
        let profiles = [F.rick, F.donna, F.tim, john]

        await center.refresh(profiles: profiles)
        #expect(saved.isEmpty, "no tree → nothing derived")

        kinship.install(graph: F.graph)
        await center.refresh(profiles: profiles)
        #expect(saved.map(\.name).sorted() == ["Donna", "Rick"])
        #expect(saved.first { $0.name == "Rick" }?.treeIdentityAttestation == "derived: owner setting")
        #expect(saved.first { $0.name == "Donna" }?.treeIdentityAttestation == "derived: tree root")
        #expect(center.derivations["tim"] == TreeIdentityDerivation.none)
        #expect(center.derivations["john breen"]?.certainCandidate?.personID == "@I6@", "proposal kept, not persisted")
        #expect(center.derivations["rick"] == nil)
        #expect(center.pinsRevision == 1)
        #expect(center.derivationRunCount == 1)

        // Same inputs → memo hit, no second pass, no second write.
        await center.refresh(profiles: profiles)
        #expect(center.derivationRunCount == 1)
        #expect(saved.count == 2)

        // A notes edit is not identity-relevant.
        var noted = profiles
        noted[3].notes = "Uncle John"
        await center.refresh(profiles: noted)
        #expect(center.derivationRunCount == 1)

        // A tree replacement is.
        kinship.install(graph: F.graph)
        await center.refresh(profiles: profiles)
        #expect(center.derivationRunCount == 2)
    }

    @Test func showInTreeStateDerivesOneProfileWhenTheMemoIsCold() {
        let (center, kinship) = makeCenter()
        kinship.install(graph: F.graph)
        let john = F.profile("John Breen", sex: .male, born: 1940)
        let s = center.showInTreeState(for: john, among: [F.rick, john])
        guard case .derived(let c, let reason) = s else { Issue.record("expected derived, got \(s)"); return }
        #expect(c.personID == "@I6@")
        #expect(reason == .nameAndBirth)
        #expect(center.showInTreeState(for: F.tim, among: [F.tim]) == ShowInTreeState.none)
        #expect(center.showInTreeState(for: F.profile("Tim", notInTree: true), among: []) == .notInTree)
    }

    @Test func pinUnpinAndBannerLifecycle() {
        let (center, kinship) = makeCenter()
        kinship.install(graph: F.graph)
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }
        let jr = TreeIdentityCandidate(F.graph.people["@I1@"]!)
        let outcome = center.pin(jr, on: F.rick, among: [F.rick], attestation: "picked: test")
        #expect(outcome.profile?.treeIdentity == .familySearchID("GVQV-NW3"))
        #expect(center.pinsRevision == 1)
        center.showBanner(.using, profileName: "Rick", candidate: jr)
        #expect(center.banner?.line == "Using Richard Harding Breen Jr (GVQV-NW3) for Rick")
        center.showBanner(.pinned, profileName: "Rick", candidate: jr)
        #expect(center.banner?.line == "Rick is Richard Harding Breen Jr · GVQV-NW3")
        center.dismissBanner()
        #expect(center.banner == nil)
        _ = center.unpin(saved[0])
        #expect(saved.last?.treeIdentity == nil)
        #expect(center.pinsRevision == 2)
        _ = center.markNotInTree(saved.last!)
        #expect(saved.last?.notInFamilyTree == true)
        #expect(center.pinsRevision == 3)
    }

    @Test func autoAcceptCanBeSwitchedOff() async {
        let (center, kinship) = makeCenter()
        center.autoAcceptsTrustedSources = false
        var writes = 0
        center.store = { _ in writes += 1 }
        kinship.install(graph: F.graph)
        await center.refresh(profiles: [F.rick, F.donna])
        #expect(writes == 0)
        #expect(center.derivations["rick"]?.isAutoAcceptable == true)
    }
}
