// HallieSurnameRosterTests.swift
// LIVE MISS #11 (Rick, 2026-08-29 13:20): "tell me about pa oc'connor" →
// "I don't find “pa oc'connor” in the family tree — try a fuller name."
// The tree has O'Connors; the surname was one keystroke off and "Pa" is a
// nickname no record carries. Contract pinned here:
//   • Rick's exact sentence on a tree with three O'Connors → the surname
//     roster as a which-one, three chips, the spelling recovery in the
//     basis, the "let me tell you about…" offer, never a catalog search;
//   • a People-tab profile "Pa" bridged to Christopher → his biography;
//   • a given name that DOES match → the normal biography;
//   • an unknown surname → the unchanged honest decline + offer.
// Pure: synthetic GEDCOM text, no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let oconnorTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
0 @I2@ INDI
1 NAME Christopher Dennis /O'Connor/
1 SEX M
1 BIRT
2 DATE 12 JUN 1870
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1941
1 FAMS @F1@
0 @I3@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 BIRT
2 DATE 1905
2 PLAC Ireland
1 FAMC @F1@
0 @I4@ INDI
1 NAME Mary Catherine /O'Connor/
1 SEX F
1 BIRT
2 DATE 3 SEP 1932
0 @I5@ INDI
1 NAME Bridget /Lynch/
1 SEX F
1 FAMS @F1@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I5@
1 CHIL @I3@
0 TRLR
"""

private func ricksSentence(_ text: String) -> HallieTurnExecutor.Request {
    guard case .biography(let person)? = ArchivistQuestionParser.general(text) else {
        Issue.record("parser did not read “\(text)” as a biography ask")
        return HallieTurnExecutor.Request(intent: .init(
            originalQuestion: text, ast: .graph(.init(people: [text], operation: .biography))))
    }
    return HallieTurnExecutor.Request(intent: .init(
        originalQuestion: text,
        ast: .graph(.init(people: [person], operation: .biography))))
}

@Suite("Surname roster — surname resolves, given token is a nickname (live miss #11)")
struct HallieSurnameRosterTests {
    let graph = GedcomFamilyGraph(gedcomText: oconnorTree)
    typealias Profile = HallieTurnExecutor.ProfileSnapshot

    func context(profiles: [Profile] = []) -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(
            profiles: profiles, graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    // MARK: Rick's sentence

    @Test func ricksSentenceGetsTheRosterWithChipsAndTheRecoveryInTheBasis() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa oc'connor"), context: context())
        #expect(r.route == .graph)
        #expect(r.outcome == .needsClarification, "got: \(r.prose)")
        #expect(r.prose == "I don't know a “Pa” O'Connor. The O'Connors in the tree are "
                + "Christopher Dennis O'Connor (b. 12 JUN 1870, d. 1941), Mary Catherine O'Connor (b. 3 SEP 1932), "
                + "and Mary O'Connor (b. 1905) — which one? "
                + "(Or “let me tell you about Pa O'Connor” and I'll remember the name.)", "got: \(r.prose)")
        #expect(r.basisLine.contains("took “oc'connor” as O'Connor"), "got: \(r.basisLine)")
        #expect(r.basisLine.contains("no O'Connor in the family tree goes by “Pa”"), "got: \(r.basisLine)")
        #expect(r.basisLine.contains("nothing was looked up"))
        let chips = try #require(r.clarification)
        #expect(chips.stage == .gedcomPerson)
        #expect(chips.candidates.map(\.id) == [.gedcomPersonID("@I2@"), .gedcomPersonID("@I4@"), .gedcomPersonID("@I3@")])
        // Never a catalog search.
        #expect(r.catalogPersonName == nil)
        #expect(r.mediaAction == nil)
        #expect(r.citations.isEmpty)
        // Never the old bare decline.
        #expect(!r.prose.contains("try a fuller name"))
    }

    @Test func aChipChosenFromTheRosterAnswersThatPerson() async throws {
        let ctx = context()
        let asked = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa oc'connor"), context: ctx)
        let pending = try #require(asked.clarification)
        let r = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .gedcomPersonID("@I3@"), context: ctx)
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Mary O'Connor"), "got: \(r.prose)")
    }

    @Test func anExactSurnameWithAnUnknownGivenAlsoGetsTheRosterWithoutARecoveryNote() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about nana o'connor"), context: context())
        #expect(r.outcome == .needsClarification, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("I don't know a “Nana” O'Connor. The O'Connors in the tree are "), "got: \(r.prose)")
        #expect(!r.basisLine.contains("took “"), "got: \(r.basisLine)")
        #expect(r.clarification?.candidates.count == 3)
    }

    /// Live addition to #11 (2026-08-29): "tell me about pa o'connor" echoed
    /// the typed lowercase "Pa o'connor". Once the surname has resolved, the
    /// roster and the offer render it in the tree's own casing, and the
    /// given token is title-cased.
    @Test func theRosterAndTheOfferUseTheTreesCasingOfTheSurname() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa o'connor"), context: context())
        #expect(r.outcome == .needsClarification, "got: \(r.prose)")
        #expect(r.prose == "I don't know a “Pa” O'Connor. The O'Connors in the tree are "
                + "Christopher Dennis O'Connor (b. 12 JUN 1870, d. 1941), Mary Catherine O'Connor (b. 3 SEP 1932), "
                + "and Mary O'Connor (b. 1905) — which one? "
                + "(Or “let me tell you about Pa O'Connor” and I'll remember the name.)", "got: \(r.prose)")
        #expect(!r.prose.contains("o'connor"), "got: \(r.prose)")
        #expect(!r.prose.contains("Pa o"), "got: \(r.prose)")
        #expect(r.basisLine.contains("no O'Connor in the family tree goes by “Pa”"), "got: \(r.basisLine)")
        // The recovered spelling, typed all in caps or mixed, comes out the same way.
        let shouted = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about PA OC'CONNOR"), context: context())
        #expect(shouted.prose.hasPrefix("I don't know a “Pa” O'Connor. The O'Connors in the tree are "), "got: \(shouted.prose)")
        #expect(shouted.basisLine.contains("took “OC'CONNOR” as O'Connor"), "got: \(shouted.basisLine)")
    }

    // MARK: Alias path

    @Test func aPeopleTabAliasForTheGivenTokenBridgesToTheBiography() async throws {
        let pa = Profile(stableID: "pa", canonicalName: "Pa",
                         aliases: ["Christopher Dennis O'Connor", "Grampa O'Connor"])
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa oc'connor"), context: context(profiles: [pa]))
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Christopher Dennis O'Connor"), "got: \(r.prose)")
        #expect(r.clarification == nil)
        #expect(r.basisLine.contains("“Pa” = Christopher Dennis O'Connor (People tab: Pa)"), "got: \(r.basisLine)")
        #expect(r.basisLine.contains("took “oc'connor” as O'Connor"), "got: \(r.basisLine)")
    }

    @Test func aGivenNameAliasOnTheProfileBridgesToo() async throws {
        let pa = Profile(stableID: "pa", canonicalName: "Pa", aliases: ["Christopher"])
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa oc'connor"), context: context(profiles: [pa]))
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Christopher Dennis O'Connor"), "got: \(r.prose)")
    }

    @Test func anAliasThatBridgesOutsideTheFamilyIsIgnoredAndTheRosterIsOffered() async throws {
        // "Pa" is Rick's father in the People tab — a Breen, not an O'Connor.
        let pa = Profile(stableID: "pa", canonicalName: "Pa", aliases: ["Richard Harding Breen Jr"])
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa oc'connor"), context: context(profiles: [pa]))
        #expect(r.outcome == .needsClarification, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("I don't know a “Pa” O'Connor."), "got: \(r.prose)")
    }

    @Test func aCyberBrainAliasForTheGivenTokenBridgesToTheBiography() async throws {
        let archive = CyberBrainArchive(
            archiveID: "test", displayName: "Test brain", people: [
                CyberBrainPerson(id: "p1", gedcomPersonID: "@I2@",
                                 canonicalName: "Christopher Dennis O'Connor", aliases: ["Pa"])
            ], sources: [])
        let brain = try CyberBrainIndex(archive: archive)
        let ctx = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: brain,
            speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
        let r = try await HallieTurnExecutor.execute(ricksSentence("tell me about pa oc'connor"), context: ctx)
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Christopher Dennis O'Connor"), "got: \(r.prose)")
        #expect(r.basisLine.contains("“Pa” = Christopher Dennis O'Connor (family knowledge:"), "got: \(r.basisLine)")
    }

    // MARK: A given name that does match

    @Test func aGivenNameThatMatchesGetsTheNormalBiography() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about christopher o'connor"), context: context())
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Christopher Dennis O'Connor"), "got: \(r.prose)")
        #expect(r.clarification == nil)
        #expect(!r.basisLine.contains("took “"))
    }

    @Test func aMatchingGivenNameWithARecoveredSurnameAnswersAndSaysSo() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about christopher oc'connor"), context: context())
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Christopher Dennis O'Connor"), "got: \(r.prose)")
        #expect(r.basisLine.contains("took “oc'connor” as O'Connor"), "got: \(r.basisLine)")
    }

    @Test func aMatchingGivenNameSharedByTwoMembersAsksWhichOne() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about mary oc'connor"), context: context())
        #expect(r.outcome == .needsClarification, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("Which Mary O'Connor do you mean — "), "got: \(r.prose)")
        #expect(r.clarification?.candidates.map(\.id) == [.gedcomPersonID("@I4@"), .gedcomPersonID("@I3@")])
        #expect(r.basisLine.contains("took “oc'connor” as O'Connor"), "got: \(r.basisLine)")
    }

    // MARK: Unknown surname — unchanged

    @Test func anUnknownSurnameKeepsTheHonestDeclineAndOffer() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa quixlebottom"), context: context())
        #expect(r.outcome == .declined, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("I don't find “pa quixlebottom” in the family tree — try a fuller name."), "got: \(r.prose)")
        #expect(r.prose.contains("“let me tell you about Pa quixlebottom” — I'll remember it."), "got: \(r.prose)")
        #expect(r.clarification == nil)
    }

    @Test func aTwoLetterSurnameNeverRecovers() async throws {
        let r = try await HallieTurnExecutor.execute(
            ricksSentence("tell me about pa oc"), context: context())
        #expect(r.outcome == .declined, "got: \(r.prose)")
    }

    // MARK: Pure surname recovery

    @Test func surnameRecoveryIsApostropheAndSpaceInsensitiveWithinOneEdit() {
        for typed in ["oc'connor", "o connor", "oconnor", "O'Connor", "oconor", "o'conner"] {
            let family = HallieSurnameRoster.family(forSurname: typed, in: graph)
            #expect(family?.surname == "O'Connor", "typed: \(typed)")
            #expect(family?.people.count == 3, "typed: \(typed)")
        }
        #expect(HallieSurnameRoster.family(forSurname: "O'Connor", in: graph)?.recovered == false)
        #expect(HallieSurnameRoster.family(forSurname: "oc'connor", in: graph)?.recovered == true)
        #expect(HallieSurnameRoster.family(forSurname: "oc'connor", in: graph)?.recoveryNote == "took “oc'connor” as O'Connor")
        // Two edits away, or too short to recover: nothing.
        #expect(HallieSurnameRoster.family(forSurname: "ocanner", in: graph) == nil)
        #expect(HallieSurnameRoster.family(forSurname: "oc", in: graph) == nil)
        #expect(HallieSurnameRoster.family(forSurname: "lynn", in: graph) == nil)
    }

    @Test func aTypoEquidistantFromTwoFamiliesIsNotGuessed() {
        let text = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Ann /Lamb/
        0 @I2@ INDI
        1 NAME Bea /Lame/
        0 TRLR
        """
        let two = GedcomFamilyGraph(gedcomText: text)
        #expect(HallieSurnameRoster.family(forSurname: "lamm", in: two) == nil)
        #expect(HallieSurnameRoster.family(forSurname: "lambs", in: two)?.surname == "Lamb")
    }

    @Test func splitNeedsTwoWordsAndALetterGiven() {
        #expect(HallieSurnameRoster.split("pa oc'connor") == .init(given: "pa", surname: "oc'connor"))
        #expect(HallieSurnameRoster.split("Pa Mc Gill") == .init(given: "Pa", surname: "Mc Gill"))
        #expect(HallieSurnameRoster.split("pa") == nil)
        #expect(HallieSurnameRoster.split("jr o'connor") == nil)
        #expect(HallieSurnameRoster.split("GVQV-NW3 o'connor") == nil)
        #expect(HallieSurnameRoster.split("p o'connor") == nil)
    }

    @Test func membersMatchGivenOrMiddleNamesThroughDiminutives() throws {
        let family = try #require(HallieSurnameRoster.family(forSurname: "o'connor", in: graph))
        #expect(HallieSurnameRoster.members(named: "chris", in: family).map(\.id) == ["@I2@"])
        #expect(HallieSurnameRoster.members(named: "dennis", in: family).map(\.id) == ["@I2@"])
        #expect(HallieSurnameRoster.members(named: "mary", in: family).map(\.id) == ["@I4@", "@I3@"])
        #expect(HallieSurnameRoster.members(named: "pa", in: family).isEmpty)
        // The surname token itself is not a given name.
        #expect(HallieSurnameRoster.members(named: "connor", in: family).isEmpty)
    }

    @Test func whichOneEchoKeepsApostropheSurnamesAndTypedCasing() {
        #expect(HallieWhichOne.display("mary o'connor") == "Mary O'Connor")
        #expect(HallieWhichOne.display("rick") == "Rick")
        #expect(HallieWhichOne.display("ann McGill") == "Ann McGill")
        #expect(HallieWhichOne.display("jean-luc") == "Jean-Luc")
    }

    @Test func givenTokenIsTitleCased() {
        #expect(HallieSurnameRoster.titleCased("pa") == "Pa")
        #expect(HallieSurnameRoster.titleCased("PA") == "Pa")
        #expect(HallieSurnameRoster.titleCased("Nana") == "Nana")
    }

    @Test func plurals() {
        #expect(HallieSurnameRoster.plural("O'Connor") == "O'Connors")
        #expect(HallieSurnameRoster.plural("Jones") == "Joneses")
        #expect(HallieSurnameRoster.plural("Lynch") == "Lynches")
    }

    // MARK: Scale — the roster is capped, home people first

    @Test func aBigFamilyIsCappedWithTheOverflowCounted() async throws {
        var text = "0 HEAD\n0 @I1@ INDI\n1 NAME Richard Harding /Breen/ Jr\n1 SEX M\n"
        for i in 2...41 {
            text += "0 @I\(i)@ INDI\n1 NAME Person\(i) /O'Connor/\n1 BIRT\n2 DATE \(1800 + i)\n"
        }
        text += "0 @I42@ INDI\n1 NAME Zed /O'Connor/\n0 TRLR\n"
        let big = GedcomFamilyGraph(gedcomText: text)
        let ctx = HallieTurnExecutor.Context(
            profiles: [], graph: big,
            speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
        let r = try await HallieTurnExecutor.execute(ricksSentence("tell me about pa oc'connor"), context: ctx)
        #expect(r.outcome == .needsClarification, "got: \(r.prose)")
        #expect(r.prose.hasPrefix("I don't know a “Pa” O'Connor. The O'Connors in the tree include "), "got: \(r.prose)")
        #expect(r.prose.contains("; there are 35 more — which one? Add a birth year to narrow it."), "got: \(r.prose)")
        #expect(r.clarification?.candidates.count == HallieWhichOne.cap)
        #expect(r.basisLine.contains("6 of 41 O'Connors offered"), "got: \(r.basisLine)")
    }
}
