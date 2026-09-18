// FamilyIdentityDecisionsTests.swift
// Rick's rulings about who is who, as data (2026-09-17).
//
// The first case is his grandmother, because she is the reason this exists:
// two FamilySearch records, weeks of investigation, and a verdict that has
// to hold across every future re-pull. The rest are the shapes this data
// actually arrives in — half-known people, contradictory rulings made months
// apart, and relatives who are deliberately not on FamilySearch at all.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Family identity decisions")
struct FamilyIdentityDecisionsTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let mary = FamilyIdentityDecision.Key.familySearch("G89Q-34N")
    private let otherMary = FamilyIdentityDecision.Key.familySearch("GNZ5-428")

    // MARK: Rick's grandmother

    @Test func theVerifiedMaryStandsInForTheDuplicate() {
        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, verified: true,
                       note: "Confirmed by her son, Rick's uncle: Mary Christina, b. 23 Dec 1904 Cork."))
        d.record(.init(key: otherMary, duplicateOf: mary,
                       note: "Same parents (@F6@); carries her siblings but not her vitals."))

        #expect(d.isSuppressed(otherMary), "the wrong Mary must be kept out of the way")
        #expect(!d.isSuppressed(mary), "the verified record must never be suppressed")
        #expect(d.preferred(otherMary) == mary, "asking about the duplicate must answer with her")
        #expect(d.preferred(mary) == mary)
        #expect(d.decision(for: mary)?.verified == true)
    }

    @Test func aRulingSurvivesBeingWrittenAndReadBack() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, verified: true, note: "hard won"))
        d.record(.init(key: otherMary, duplicateOf: mary))
        try d.save(to: dir)

        let back = FamilyIdentityDecisions.load(from: dir)
        #expect(back.count == 2)
        #expect(back.preferred(otherMary) == mary)
        #expect(back.decision(for: mary)?.note == "hard won")
        #expect(back.decision(for: mary)?.verified == true)
    }

    // MARK: The shapes this data really arrives in

    /// Elizabeth Brashear: in the bible records and a printed tree from old
    /// relatives, and nowhere yet in FamilySearch. Unresolved must be a
    /// state the store can hold for months without pretending otherwise.
    @Test func someoneWithNoFamilySearchRecordIsANormalStateNotAnError() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let beth = FamilyIdentityDecision.Key.local("elizabeth-brashear")

        var d = FamilyIdentityDecisions()
        d.record(.init(key: beth, verified: false,
                       note: "In the bible records and the printed family tree. No FamilySearch record found yet."))
        try d.save(to: dir)

        let back = FamilyIdentityDecisions.load(from: dir)
        #expect(back.decision(for: beth)?.verified == false)
        #expect(back.decision(for: beth)?.key.familySearchID == nil)
        #expect(!back.isSuppressed(beth), "not knowing who someone is must never hide them")
        #expect(back.preferred(beth) == beth)
    }

    /// New evidence supersedes old evidence. That is the point of keeping
    /// this as data Rick can revise.
    @Test func aLaterRulingReplacesAnEarlierOne() {
        var d = FamilyIdentityDecisions()
        d.record(.init(key: otherMary, duplicateOf: mary, note: "first guess"))
        #expect(d.isSuppressed(otherMary))

        d.record(.init(key: otherMary, verified: true, duplicateOf: nil,
                       note: "turns out she is her own person after all"))
        #expect(!d.isSuppressed(otherMary), "the revision did not take")
        #expect(d.count == 1, "a revision must replace, not accumulate")
    }

    /// Two rulings made months apart can contradict each other. A loop must
    /// answer, not hang — this walks a bounded number of steps by design.
    @Test func aCircularPairOfRulingsTerminates() {
        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, duplicateOf: otherMary))
        d.record(.init(key: otherMary, duplicateOf: mary))
        // Whatever it answers, it must ANSWER.
        let a = d.preferred(mary)
        let b = d.preferred(otherMary)
        #expect(a == mary || a == otherMary)
        #expect(b == mary || b == otherMary)
    }

    /// A chain — C says it is B, B says it is A — resolves to the end.
    @Test func aChainOfDuplicatesResolvesToTheLastRecord() {
        let a = FamilyIdentityDecision.Key.familySearch("AAAA-111")
        let b = FamilyIdentityDecision.Key.familySearch("BBBB-222")
        let c = FamilyIdentityDecision.Key.familySearch("CCCC-333")
        var d = FamilyIdentityDecisions()
        d.record(.init(key: c, duplicateOf: b))
        d.record(.init(key: b, duplicateOf: a))
        d.record(.init(key: a, verified: true))
        #expect(d.preferred(c) == a)
        #expect(d.preferred(b) == a)
    }

    /// Names are never the key: John Latta exists many times over because
    /// sons carried their fathers' names. A ruling keyed on a name would
    /// drift onto a grandson.
    @Test func twoPeopleSharingANameHoldSeparateRulings() {
        let father = FamilyIdentityDecision.Key.familySearch("K8LJ-KDV")
        let son = FamilyIdentityDecision.Key.familySearch("LZXY-D6Y")
        var d = FamilyIdentityDecisions()
        d.record(.init(key: father, verified: true, note: "John Robert Latta b.1835"))
        d.record(.init(key: son, verified: true, note: "his son, same name"))
        #expect(d.preferred(father) == father)
        #expect(d.preferred(son) == son)
        #expect(!d.isSuppressed(son), "a namesake is not a duplicate")
    }

    /// Hidden WITHOUT naming a replacement — Rick's real workflow, since he
    /// recognises the wrong record long before he can prove which is right.
    @Test func aRecordCanBeHiddenWithoutNamingTheRightOne() {
        var d = FamilyIdentityDecisions()
        d.record(.init(key: otherMary, hidden: true, note: "the wrong Mary"))
        #expect(d.isSuppressed(otherMary))
        #expect(d.preferred(otherMary) == otherMary, "hiding names no replacement")
        #expect(d.suppressedFamilySearchIDs == ["GNZ5-428"])
    }

    /// The set handed to the graph must contain the hidden AND the
    /// duplicate-of records, and nothing else — a verified record in the
    /// same file must never leak into it.
    @Test func theSuppressedSetIsExactlyWhatShouldBeHidden() {
        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, verified: true))
        d.record(.init(key: otherMary, duplicateOf: mary))
        d.record(.init(key: .familySearch("AAAA-111"), hidden: true))
        d.record(.init(key: .local("beth"), hidden: true))
        #expect(d.suppressedFamilySearchIDs == ["GNZ5-428", "AAAA-111"],
                "a verified record or a local key leaked into the hidden set")
    }

    @Test func anUnreadableOrMissingFileMeansNothingHasBeenRuledYet() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FamilyIdentityDecisions.load(from: dir).isEmpty)
        try Data("not json".utf8).write(to: FamilyIdentityDecisions.fileURL(in: dir))
        #expect(FamilyIdentityDecisions.load(from: dir).isEmpty,
                "a damaged file must not stop the tree from opening")
    }

    /// Rick edits this file by hand, so it has to diff cleanly.
    @Test func theFileIsWrittenInAStableOrder() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = FamilyIdentityDecisions()
        for id in ["ZZZZ-999", "AAAA-111", "MMMM-555"] {
            d.record(.init(key: .familySearch(id)))
        }
        try d.save(to: dir)
        let first = try String(contentsOf: FamilyIdentityDecisions.fileURL(in: dir), encoding: .utf8)
        try d.save(to: dir)
        let second = try String(contentsOf: FamilyIdentityDecisions.fileURL(in: dir), encoding: .utf8)
        #expect(first == second)
        #expect(first.range(of: "AAAA-111")!.lowerBound < first.range(of: "MMMM-555")!.lowerBound)
    }
}
