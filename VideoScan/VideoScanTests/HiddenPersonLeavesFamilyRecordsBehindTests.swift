// HiddenPersonLeavesFamilyRecordsBehindTests.swift
// KNOWN ISSUE, found by the overnight Hallie run on 2026-09-17 and written
// down rather than guessed at.
//
// Hiding a duplicate PERSON does not hide the FAMILY records that hang off
// them, and in Rick's real tree that leaves his aunt with three sets of
// parents that are all the same marriage:
//
//   @F3@   David McGill Latta Sr  +  Mary Christina O'Connor [G89Q-34N]
//   @F4@   (no husband)           +  Mary O'Connor           [GNZ5-428]  ← duplicate
//   @FB3@  (no husband)           +  Mary Christina O'Connor [G89Q-34N]
//
// Four questions about Eileen Latta that passed against the old tree now
// fail: "who is eileen latta's mother", "tell me about eileen latta", "who
// are eileen's parents", "show eileen latta's maternal line back 3
// generations".
//
// WHY IT IS MARKED KNOWN RATHER THAN FIXED. The repair is in parent-family
// resolution, which decides who Rick's relatives' parents are. Rick's
// 2026-09-02 ruling already governs the two-FAMC case ("a family
// FamilySearch itself knows outranks a stray local one"); three FAMC links
// where two name the same woman under different ids is a case that ruling
// did not consider, and it is his to make, not mine to infer at midnight.
//
// `withKnownIssue` means this does not redden the suite AND fails loudly the
// day somebody fixes it, so the marker cannot rot.

import Testing
import Foundation
@testable import VideoScan
@testable import VideoScanCore

@Suite("Hiding a person leaves their family records behind", .serialized)
struct HiddenPersonLeavesFamilyRecordsBehindTests {

    /// Rick's shape exactly: one aunt, one grandmother recorded twice, and
    /// three family records that are all the same marriage.
    private func archive() throws -> (base: URL, config: FamilyAssetConfiguration) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("famdup-\(UUID().uuidString)", isDirectory: true)
        let assets = base.appendingPathComponent("40_Family_Tree", isDirectory: true)
        let gedcoms = assets.appendingPathComponent("GEDCOM", isDirectory: true)
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        try """
        0 HEAD
        0 @F3@ FAM
        1 HUSB @D@
        1 WIFE @I7@
        1 CHIL @E@
        0 @F4@ FAM
        1 WIFE @I5@
        1 CHIL @E@
        0 @D@ INDI
        1 NAME David McGill /Latta/ Sr
        1 _FSFTID LX9M-WJG
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 _FSFTID G89Q-34N
        0 @I5@ INDI
        1 NAME Mary /O'Connor/
        1 _FSFTID GNZ5-428
        0 @E@ INDI
        1 NAME Eileen /Latta/
        1 FAMC @F3@
        1 FAMC @F4@
        1 _FSFTID G2CR-R4H
        0 TRLR
        """.write(to: gedcoms.appendingPathComponent("tree.ged"), atomically: true, encoding: .utf8)

        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("G89Q-34N"), verified: true))
        rulings.record(.init(key: .familySearch("GNZ5-428"),
                             duplicateOf: .familySearch("G89Q-34N")))
        try rulings.save(to: gedcoms)

        return (base, FamilyAssetConfiguration(
            roots: .init(assets: assets, thumbnailCache: base.appendingPathComponent("thumbs")),
            access: .readWrite, legacyGEDCOMDirectory: nil))
    }

    /// What DOES work today, so the known issue below is precisely scoped:
    /// the hidden person is gone from every lookup.
    @Test @MainActor func theHiddenPersonHerselfIsGoneFromLookups() throws {
        let a = try archive()
        defer { try? FileManager.default.removeItem(at: a.base) }
        let graph = try #require(FamilyGraphSharedCache(log: { _ in })
            .graph(for: a.config, store: nil))

        let marys = graph.people(matching: "Mary")
        #expect(marys.count == 1)
        #expect(marys.first?.familySearchID == "G89Q-34N")
    }

    /// THE KNOWN ISSUE. Eileen still carries a parent family whose only
    /// parent is the hidden record.
    @Test @MainActor func eileenShouldNotKeepAParentFamilyBuiltOnAHiddenPerson() throws {
        let a = try archive()
        defer { try? FileManager.default.removeItem(at: a.base) }
        let graph = try #require(FamilyGraphSharedCache(log: { _ in })
            .graph(for: a.config, store: nil))
        let eileen = try #require(graph.people["@E@"])
        let parentFamilies = Set(eileen.childOfFamilies
            + [eileen.childOfFamily].compactMap { $0 })

        withKnownIssue("""
            Hiding GNZ5-428 does not disregard @F4@, whose only parent IS \
            GNZ5-428, so Eileen keeps two parent families that are one \
            marriage. Rick's 2026-09-02 ruling covers two FAMC links; this \
            is the case it did not consider and the ruling is his to make.
            """) {
            #expect(parentFamilies == ["@F3@"],
                    "Eileen still has \(parentFamilies.sorted()) — @F4@ hangs off a hidden person")
        }
    }
}
