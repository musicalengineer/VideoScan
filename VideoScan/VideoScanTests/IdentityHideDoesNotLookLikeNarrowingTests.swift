// IdentityHideDoesNotLookLikeNarrowingTests.swift
// A cross-feature invariant, written under the 2026-09-17 hardening theme.
//
// Two mechanisms landed the same day and both make people disappear from
// view. They must never be confused for each other:
//
//   • NARROWING is data loss. The tree was compiled from fewer sources than
//     it should have been, Donna's 23,000 people are gone, and the integrity
//     check must shout. That happened twice today.
//   • HIDING is a human decision. Rick ruled one record a duplicate. The
//     tree is intact; one card is out of the way.
//
// If hiding tripped the narrowing alarm, Rick would be told his tree was
// damaged every time he tidied a duplicate — and, far worse, he would learn
// to ignore the alarm that exists to tell him his wife's family vanished.

import Testing
import Foundation
@testable import VideoScan
@testable import VideoScanCore

@Suite("A hide is not a narrowing", .serialized)
struct IdentityHideDoesNotLookLikeNarrowingTests {

    private func archive(rulings: FamilyIdentityDecisions?) throws
        -> (base: URL, gedcoms: URL, config: FamilyAssetConfiguration) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hide-vs-narrow-\(UUID().uuidString)", isDirectory: true)
        let assets = base.appendingPathComponent("40_Family_Tree", isDirectory: true)
        let gedcoms = assets.appendingPathComponent("GEDCOM", isDirectory: true)
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        var lines = ["0 HEAD"]
        for n in 1...20 {
            lines += ["0 @I\(n)@ INDI", "1 NAME Person\(n) /Breen/", "1 _FSFTID AAA\(n)-111"]
        }
        lines.append("0 TRLR")
        try lines.joined(separator: "\n")
            .write(to: gedcoms.appendingPathComponent("tree.ged"), atomically: true, encoding: .utf8)
        if let rulings { try rulings.save(to: gedcoms) }
        return (base, gedcoms, FamilyAssetConfiguration(
            roots: .init(assets: assets, thumbnailCache: base.appendingPathComponent("thumbs")),
            access: .readWrite, legacyGEDCOMDirectory: nil))
    }

    /// THE INVARIANT. Hiding people changes what is on screen and changes
    /// NOTHING about the compiled artifact — so the manifest, which is what
    /// the integrity check reads, is byte-identical either way.
    @Test @MainActor func hidingPeopleDoesNotChangeTheCompiledTreeAtAll() throws {
        let plain = try archive(rulings: nil)
        defer { try? FileManager.default.removeItem(at: plain.base) }

        var rulings = FamilyIdentityDecisions()
        for n in 1...5 { rulings.record(.init(key: .familySearch("AAA\(n)-111"), hidden: true)) }
        let hidden = try archive(rulings: rulings)
        defer { try? FileManager.default.removeItem(at: hidden.base) }

        let cacheA = FamilyGraphSharedCache(log: { _ in })
        let cacheB = FamilyGraphSharedCache(log: { _ in })
        let a = try #require(cacheA.graph(for: plain.config, store: nil))
        let b = try #require(cacheB.graph(for: hidden.config, store: nil))

        #expect(b.suppressedPersonIDs.count == 5, "precondition: five are hidden")
        #expect(a.people.count == b.people.count,
                "hiding must not remove anybody from the TREE, only from view")
        #expect(a.people.count == 20)
        // What the integrity check reads is the manifest's people count, and
        // that comes from the artifact, which hiding never touches.
        #expect(b.people.count == 20,
                "a hide that shrank the compiled tree would be indistinguishable from data loss")
    }

    /// And the alarm still fires for the thing it is FOR. If this ever goes
    /// quiet, the test above has stopped meaning anything.
    @Test func aRealNarrowingStillRaisesTheAlarm() throws {
        let full = FamilyGraphCompiledStore.Manifest(
            schema: 3, codec: 6, index: 2, generation: "gen-full",
            createdAt: Date(timeIntervalSince1970: 1000),
            sources: [], logicalSources: [
                .init(fileName: "rick.ged", sha256: "a", droppedLineCount: 0),
                .init(fileName: "donna.ged", sha256: "b", droppedLineCount: 0)],
            peopleCount: 39250, familyCount: 24936, verification: [],
            mergeReport: nil, localDroppedLineCount: 0, totalDroppedLineCount: 0)
        let narrowed = FamilyGraphCompiledStore.Manifest(
            schema: 3, codec: 6, index: 2, generation: "gen-narrow",
            createdAt: Date(timeIntervalSince1970: 2000),
            sources: [], logicalSources: [
                .init(fileName: "rick.ged", sha256: "a", droppedLineCount: 0)],
            peopleCount: 16383, familyCount: 10682, verification: [],
            mergeReport: nil, localDroppedLineCount: 0, totalDroppedLineCount: 0)

        let findings = TreeIntegrityCheck.compare(incoming: narrowed, against: full)
        #expect(TreeIntegrityCheck.hasAlarm(findings),
                "the alarm for Rick's actual data loss has gone quiet: \(findings.map(\.message))")
    }
}
