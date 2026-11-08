// TreeIdentityDeriverCharacterizationTests.swift
// Characterization of TreeIdentityDeriver.deriveWithResolvedPointerPins
// (2026-11-07), written against the CCN 32 version BEFORE it was split into
// one step per evidence rule, so the split is held to the same verdicts.
// TreeIdentityDeriverTests owns the headline matrix on the Breen fixture;
// this suite pins the edges of each rule on small synthetic trees: plain vs
// recorded roots, two matching roots, the owner beside a namesake, kinship
// rows that agree with none / several matches, the birth-year tie-break,
// the ambiguity cap, the suggestion fallback, and pointer pins with and
// without a fingerprint. Synthetic people only (2026-08-03 privacy policy).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

enum TreeIdentityCharacterizationFixture {
    struct Indi {
        let id: String, name: String, sex: String, born: Int?, fsid: String?
        init(_ id: String, _ name: String, _ sex: String = "", born: Int? = nil, fsid: String? = nil) {
            self.id = id; self.name = name; self.sex = sex; self.born = born; self.fsid = fsid
        }
    }

    /// A GEDCOM from rows. `roots` non-nil = a merged tree with RECORDED
    /// roots; nil = a plain export (its first INDI is the hint root).
    /// `families`: (husband, wife, children).
    static func graph(_ people: [Indi], roots: [String]? = nil,
                      families: [(String?, String?, [String])] = []) -> GedcomFamilyGraph {
        var lines = ["0 HEAD"]
        if let roots {
            lines.append("1 _VS_MERGED Y")
            lines += roots.map { "1 _VS_ROOT \($0)" }
        }
        for p in people {
            lines += ["0 \(p.id) INDI", "1 NAME \(p.name)"]
            if !p.sex.isEmpty { lines.append("1 SEX \(p.sex)") }
            if let fsid = p.fsid { lines.append("1 _FSFTID \(fsid)") }
            if let born = p.born { lines += ["1 BIRT", "2 DATE \(born)"] }
            for (n, f) in families.enumerated() {
                if f.0 == p.id || f.1 == p.id { lines.append("1 FAMS @F\(n)@") }
                if f.2.contains(p.id) { lines.append("1 FAMC @F\(n)@") }
            }
        }
        for (n, f) in families.enumerated() {
            lines.append("0 @F\(n)@ FAM")
            if let h = f.0 { lines.append("1 HUSB \(h)") }
            if let w = f.1 { lines.append("1 WIFE \(w)") }
            lines += f.2.map { "1 CHIL \($0)" }
        }
        lines.append("0 TRLR")
        return GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
    }

    static func subject(_ name: String, aliases: [String] = [], sex: PersonSex? = nil, born: Int? = nil,
                        kinships: [Kinship] = [], uuid: UUID? = nil, pin: TreeIdentity? = nil) -> TreeIdentitySubject {
        TreeIdentitySubject(stableID: "/fixture/\(name)", name: name, aliases: aliases, sex: sex,
                            birthdate: born.map { KinshipFixture.date($0) }, kinships: kinships,
                            uuid: uuid, treeIdentity: pin)
    }

    static func derive(_ subject: TreeIdentitySubject, among others: [TreeIdentitySubject] = [],
                       in graph: GedcomFamilyGraph, ownerName: String? = nil,
                       ownerFSID: String? = nil) -> TreeIdentityDerivation {
        TreeIdentityDeriver(graph: graph, subjects: [subject] + others,
                            ownerName: ownerName, ownerFamilySearchID: ownerFSID).derive(subject)
    }

    static func ids(_ d: TreeIdentityDerivation) -> [String] {
        switch d {
        case .certain(let c, _): return [c.personID]
        case .ambiguous(let cs): return cs.map(\.personID)
        case .none: return []
        }
    }

    static func reason(_ d: TreeIdentityDerivation) -> TreeIdentityDerivation.Reason? {
        if case .certain(_, let r) = d { return r }
        return nil
    }

    static func isAmbiguous(_ d: TreeIdentityDerivation) -> Bool {
        if case .ambiguous = d { return true }
        return false
    }
}

private typealias T = TreeIdentityCharacterizationFixture

@Suite("TreeIdentityDeriver — characterization of each evidence rule")
struct TreeIdentityDeriverCharacterizationTests {

    // MARK: 1. Owner setting

    @Test func anOwnerPinClaimedByAnotherProfileFallsThroughToTheName() {
        let g = T.graph([T.Indi("@I1@", "Ann /Root/", "F", born: 1950, fsid: "ANNA-001")], roots: ["@I1@"])
        let owner = T.subject("Ann Root", sex: .female, born: 1950)
        let other = T.subject("Someone", pin: .familySearchID("ANNA-001"))
        let v = T.derive(owner, among: [other], in: g, ownerName: "Ann Root", ownerFSID: "ANNA-001")
        #expect(v == .none, "\(v)")
    }

    @Test func anIncompatibleOwnerPinFallsThroughToTheRoot() {
        let g = T.graph([T.Indi("@I1@", "Ann /Root/", "F", born: 1950, fsid: "ANNA-001"),
                         T.Indi("@I2@", "Ann /Root/", "F", born: 1990, fsid: "ANNA-002")], roots: ["@I2@"])
        let owner = T.subject("Ann Root", sex: .female, born: 1990)
        let v = T.derive(owner, in: g, ownerName: "Ann Root", ownerFSID: "ANNA-001")
        #expect(T.ids(v) == ["@I2@"])
        #expect(T.reason(v) == .treeRoot)
    }

    // MARK: 2. Tree roots

    @Test func aPlainExportsFirstRecordIsEvidenceOnlyForTheOwner() {
        let g = T.graph([T.Indi("@I1@", "Ann /Root/", "F"), T.Indi("@I2@", "Bob /Other/", "M")])
        let ann = T.subject("Ann Root")
        let asOther = T.derive(ann, in: g)
        #expect(T.ids(asOther) == ["@I1@"])
        #expect(T.reason(asOther) == .uniqueFullName)
        let asOwner = T.derive(ann, in: g, ownerName: "Ann Root")
        #expect(T.ids(asOwner) == ["@I1@"])
        #expect(T.reason(asOwner) == .treeRoot)
    }

    @Test func twoRecordedRootsSpelledLikeTheProfileAreAsked() {
        let g = T.graph([T.Indi("@I1@", "Pat /Doe/", "M"), T.Indi("@I2@", "Pat /Doe/", "F"),
                         T.Indi("@I3@", "Pat /Doe/")], roots: ["@I1@", "@I2@"])
        let v = T.derive(T.subject("Pat Doe"), in: g)
        #expect(T.isAmbiguous(v))
        #expect(T.ids(v).sorted() == ["@I1@", "@I2@"])
    }

    @Test func theOwnerTakesTheRootBesideANamesakeButOthersAreAsked() {
        let g = T.graph([T.Indi("@I1@", "Pat /Doe/", "M"), T.Indi("@I2@", "Pat /Doe/", "M")], roots: ["@I1@"])
        let pat = T.subject("Pat Doe")
        let owner = T.derive(pat, in: g, ownerName: "Pat Doe")
        #expect(T.ids(owner) == ["@I1@"])
        #expect(T.reason(owner) == .treeRoot)
        let other = T.derive(pat, in: g)
        #expect(T.isAmbiguous(other))
        #expect(T.ids(other).sorted() == ["@I1@", "@I2@"])
    }

    @Test func aRootThatIsTheOnlyCompatibleNamesakeIsCertainForAnyone() {
        let g = T.graph([T.Indi("@I1@", "Pat /Doe/", "M"), T.Indi("@I2@", "Pat /Doe/", "F")], roots: ["@I1@"])
        let v = T.derive(T.subject("Pat Doe", sex: .male), in: g)
        #expect(T.ids(v) == ["@I1@"])
        #expect(T.reason(v) == .treeRoot)
    }

    // MARK: 3. Name, kinship, birth year

    @Test func kinshipRowsThatNoMatchSatisfiesLeaveAllMatchesToAsk() {
        let g = T.graph([T.Indi("@P@", "Ma /Doe/", "F", fsid: "MAMA-001"),
                         T.Indi("@C1@", "Kim /Doe/", "F"), T.Indi("@C2@", "Kim /Doe/", "F"),
                         T.Indi("@C3@", "Lee /Doe/", "F")],
                        families: [(nil, "@P@", ["@C3@"])])
        let ma = T.subject("Ma", pin: .familySearchID("MAMA-001"))
        let kim = T.subject("Kim Doe", kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Ma"))])
        let v = T.derive(kim, among: [ma], in: g)
        #expect(T.isAmbiguous(v))
        #expect(T.ids(v).sorted() == ["@C1@", "@C2@"])
    }

    @Test func kinshipRowsThatSeveralMatchesSatisfyNarrowThenBirthYearDecides() {
        let g = T.graph([T.Indi("@P@", "Ma /Doe/", "F", fsid: "MAMA-001"),
                         T.Indi("@C1@", "Kim /Doe/", "F", born: 1970), T.Indi("@C2@", "Kim /Doe/", "F"),
                         T.Indi("@C3@", "Kim /Doe/", "F", born: 1971)],
                        families: [(nil, "@P@", ["@C1@", "@C2@"])])
        let ma = T.subject("Ma", pin: .familySearchID("MAMA-001"))
        let kim = T.subject("Kim Doe", born: 1970,
                            kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Ma"))])
        let v = T.derive(kim, among: [ma], in: g)
        #expect(T.ids(v) == ["@C1@"])
        #expect(T.reason(v) == .nameAndBirth)
    }

    @Test func aRowStoredOnThePinnedProfileConstrainsToo() {
        let kimID = UUID()
        let g = T.graph([T.Indi("@P@", "Ma /Doe/", "F", fsid: "MAMA-001"),
                         T.Indi("@C1@", "Kim /Doe/", "F"), T.Indi("@C2@", "Kim /Doe/", "F")],
                        families: [(nil, "@P@", ["@C2@"])])
        // "I am the parent of Kim", written on Ma.
        let ma = T.subject("Ma", kinships: [Kinship(relation: .parent, relativeTo: .profile(id: kimID))],
                           pin: .familySearchID("MAMA-001"))
        let kim = T.subject("Kim Doe", uuid: kimID)
        let v = T.derive(kim, among: [ma], in: g)
        #expect(T.ids(v) == ["@C2@"], "\(v)")
        #expect(T.reason(v) == .nameAndKinship)
    }

    @Test func severalUndatedMatchesWithOneDatedAreSettledByBirthYear() {
        let g = T.graph([T.Indi("@A@", "Kim /Doe/"), T.Indi("@B@", "Kim /Doe/", born: 1970), T.Indi("@C@", "Kim /Doe/")])
        let dated = T.derive(T.subject("Kim Doe", born: 1970), in: g)
        #expect(T.ids(dated) == ["@B@"])
        #expect(T.reason(dated) == .nameAndBirth)
        let undated = T.derive(T.subject("Kim Doe"), in: g)
        #expect(T.isAmbiguous(undated))
        #expect(T.ids(undated).count == 3)
    }

    @Test func aLoneMatchIsCertainByBirthOrFullNameElseOffered() {
        let g = T.graph([T.Indi("@A@", "Kim /Doe/", born: 1970), T.Indi("@B@", "Nana /Roe/")])
        #expect(T.reason(T.derive(T.subject("Kim", born: 1970), in: g)) == .nameAndBirth)
        #expect(T.reason(T.derive(T.subject("Nana Roe"), in: g)) == .uniqueFullName)
        let nana = T.derive(T.subject("Nana"), in: g)
        #expect(T.isAmbiguous(nana))
        #expect(T.ids(nana) == ["@B@"])
    }

    @Test func manyNamesakesAreCappedForTheSheet() {
        let people = (0..<20).map { T.Indi("@K\($0)@", "Kim /Doe/") }
        let v = T.derive(T.subject("Kim Doe"), in: T.graph(people))
        #expect(T.isAmbiguous(v))
        #expect(T.ids(v).count == TreeIdentityDeriver.ambiguityCap)
    }

    // MARK: 3b / 4. No name match

    @Test func kinshipAloneSettlesOnlyOneCompatibleRecord() {
        let g = T.graph([T.Indi("@P@", "Ma /Doe/", "F", fsid: "MAMA-001"),
                         T.Indi("@C1@", "Robin /Doe/", "M"), T.Indi("@C2@", "Sam /Doe/", "F")],
                        families: [(nil, "@P@", ["@C1@", "@C2@"])])
        let ma = T.subject("Ma", pin: .familySearchID("MAMA-001"))
        let row = [Kinship(relation: .child, relativeTo: .profile(name: "Ma"))]
        let son = T.derive(T.subject("Junior", sex: .male, kinships: row), among: [ma], in: g)
        #expect(T.ids(son) == ["@C1@"], "\(son)")
        #expect(T.reason(son) == .kinshipToPinned)
        let either = T.derive(T.subject("Junior", kinships: row), among: [ma], in: g)
        #expect(!either.isAutoAcceptable)
        #expect(T.reason(either) == nil)
    }

    @Test func noEvidenceAtAllIsNone() {
        let g = T.graph([T.Indi("@A@", "Kim /Doe/")])
        #expect(T.derive(T.subject("Zebedee Quux"), in: g) == .none)
    }

    // MARK: Pointer pins

    @Test func pointerPinsWithoutAFingerprintFailClosed() {
        let g = T.graph([T.Indi("@A@", "Kim /Doe/"), T.Indi("@B@", "Lee /Roe/")])
        let pinned = T.subject("Lee", pin: .pointer(pointer: "@B@", sourceFingerprint: "fp"))
        let kim = T.subject("Kim Doe")
        let deriver = TreeIdentityDeriver(graph: g, subjects: [kim, pinned], ownerName: nil,
                                          ownerFamilySearchID: nil, currentGraphFingerprint: nil)
        #expect(deriver.derive(kim) == .none)
        #expect(deriver.deriveAll().isEmpty == false)
        #expect(deriver.deriveAll()[kim.stableID] == TreeIdentityDerivation.none)
    }

    @Test func aPointerPinOnThisTreeClaimsItsRecord() {
        let g = T.graph([T.Indi("@A@", "Kim /Doe/"), T.Indi("@B@", "Kim /Doe/", born: 1970)])
        let pinned = T.subject("Other", pin: .pointer(pointer: "@B@", sourceFingerprint: "fp-1"))
        let kim = T.subject("Kim Doe")
        let same = TreeIdentityDeriver(graph: g, subjects: [kim, pinned], ownerName: nil,
                                       ownerFamilySearchID: nil, currentGraphFingerprint: "fp-1")
        #expect(T.ids(same.derive(kim)) == ["@A@"])
        #expect(T.reason(same.derive(kim)) == .uniqueFullName)
        let stale = TreeIdentityDeriver(graph: g, subjects: [kim, pinned], ownerName: nil,
                                        ownerFamilySearchID: nil, currentGraphFingerprint: "fp-2")
        #expect(T.isAmbiguous(stale.derive(kim)))
        #expect(T.ids(stale.derive(kim)).sorted() == ["@A@", "@B@"])
    }
}

@Suite("TreeIdentityDeriver — the evidence steps one at a time")
struct TreeIdentityDeriverStepTests {

    private static let patTree = T.graph([T.Indi("@I1@", "Pat /Doe/", "M", born: 1950, fsid: "PATD-001"),
                                          T.Indi("@I2@", "Pat /Doe/", "M"),
                                          T.Indi("@I3@", "Pat /Doe/", "F", born: 1960)],
                                         roots: ["@I1@", "@I3@"])

    private func deriver(_ subjects: [TreeIdentitySubject], ownerFSID: String? = nil) -> TreeIdentityDeriver {
        TreeIdentityDeriver(graph: Self.patTree, subjects: subjects, ownerName: nil, ownerFamilySearchID: ownerFSID)
    }

    private func person(_ id: String) -> GedcomFamilyGraph.Person { Self.patTree.people[id]! }

    @Test func ownerSettingVerdictNeedsTheRecordCompatibleAndUnclaimed() {
        let pat = T.subject("Pat Doe", sex: .male)
        #expect(T.reason(deriver([pat], ownerFSID: "PATD-001").ownerSettingVerdict(for: pat)!) == .ownerSetting)
        #expect(deriver([pat], ownerFSID: "NONE-000").ownerSettingVerdict(for: pat) == nil)
        #expect(deriver([pat], ownerFSID: nil).ownerSettingVerdict(for: pat) == nil)
        let female = T.subject("Pat Doe", sex: .female)
        #expect(deriver([female], ownerFSID: "PATD-001").ownerSettingVerdict(for: female) == nil)
        let other = T.subject("Other", pin: .familySearchID("PATD-001"))
        #expect(deriver([pat, other], ownerFSID: "PATD-001").ownerSettingVerdict(for: pat) == nil)
    }

    @Test func compatibleNamesakesAreUniqueCompatibleAndUnclaimed() {
        let male = T.subject("Pat Doe", aliases: ["Pat"], sex: .male)
        #expect(deriver([male]).compatibleNamesakes(of: male, spellings: ["Pat Doe", "Pat"]).map(\.id).sorted()
                == ["@I1@", "@I2@"])
        let other = T.subject("Other", pin: .familySearchID("PATD-001"))
        #expect(deriver([male, other]).compatibleNamesakes(of: male, spellings: ["Pat Doe"]).map(\.id) == ["@I2@"])
    }

    @Test func rootVerdictSpeaksForOneRootAloneTheOwnerOrSeveralRoots() {
        let d = deriver([])
        #expect(T.ids(d.rootVerdict(namesakes: [person("@I1@")], isOwner: false)!) == ["@I1@"])
        #expect(d.rootVerdict(namesakes: [person("@I1@"), person("@I2@")], isOwner: false) == nil)
        #expect(T.reason(d.rootVerdict(namesakes: [person("@I1@"), person("@I2@")], isOwner: true)!) == .treeRoot)
        let two = d.rootVerdict(namesakes: [person("@I1@"), person("@I3@")], isOwner: true)!
        #expect(T.isAmbiguous(two))
        #expect(d.rootVerdict(namesakes: [person("@I2@")], isOwner: false) == nil)
        #expect(d.rootVerdict(namesakes: [], isOwner: true) == nil)
    }

    @Test func nameMatchesJoinNamesakesAndDropTheIncompatible() {
        let male = T.subject("Pat Doe", sex: .male)
        let ids = deriver([male]).nameMatches(for: male, spellings: ["Pat Doe"], namesakes: [person("@I3@")]).map(\.id)
        #expect(ids.sorted() == ["@I1@", "@I2@"])
    }

    @Test func narrowedByKinshipWithoutRowsLeavesTheMatches() {
        let pat = T.subject("Pat Doe")
        let all = [person("@I1@"), person("@I2@")]
        guard case .narrowed(let left) = deriver([pat]).narrowedByKinship(all, for: pat) else {
            Issue.record("rows that reach no pin must not decide")
            return
        }
        #expect(left.map(\.id) == ["@I1@", "@I2@"])
    }

    @Test func loneMatchVerdictByBirthFullNameOrOffered() {
        let d = deriver([])
        #expect(T.reason(d.loneMatchVerdict(person("@I1@"), for: T.subject("Pat", born: 1950), spellings: ["Pat"]))
                == .nameAndBirth)
        #expect(T.reason(d.loneMatchVerdict(person("@I2@"), for: T.subject("Pat Doe"), spellings: ["Pat Doe"]))
                == .uniqueFullName)
        #expect(d.loneMatchVerdict(person("@I2@"), for: T.subject("Pat"), spellings: ["Pat"])
                == .ambiguous([TreeIdentityCandidate(person("@I2@"))]))
    }

    @Test func severalNamesakesVerdictAsksAroundARootElseUsesTheOneDatedRecord() {
        let d = deriver([])
        let born = T.subject("Pat Doe", born: 1950)
        let withRoot = d.severalNamesakesVerdict([person("@I1@"), person("@I2@")], for: born, rootsConsidered: true)
        #expect(T.isAmbiguous(withRoot))
        let rootsIgnored = d.severalNamesakesVerdict([person("@I1@"), person("@I2@")], for: born, rootsConsidered: false)
        #expect(T.ids(rootsIgnored) == ["@I1@"])
        #expect(T.reason(rootsIgnored) == .nameAndBirth)
        let undated = d.severalNamesakesVerdict([person("@I1@"), person("@I2@")], for: T.subject("Pat Doe"),
                                                rootsConsidered: false)
        #expect(T.isAmbiguous(undated))
    }
}
