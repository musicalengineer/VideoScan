// HallieHonoursIdentityHideTests.swift
// Rick, 2026-09-17: "hallie needs to honor FT hide."
//
// The filtering was in the Family Tree model first, which meant Hallie,
// kinship and the People tab still saw both Marys. It now lives on the graph
// and is applied once in FamilyGraphSharedCache — the one place all of them
// get their tree from — and `people(matching:)` is the single door all 25
// app call sites use.
//
// This suite exists because that is an argument, not a proof. It loads a
// tree through the REAL shared cache with a REAL rulings file beside it and
// asks the graph the way Hallie asks it.

import Testing
import Foundation
@testable import VideoScan
@testable import VideoScanCore

@Suite("Hallie honours a Family Tree hide", .serialized)
struct HallieHonoursIdentityHideTests {

    private func archive(rulings: FamilyIdentityDecisions?) throws -> (base: URL, config: FamilyAssetConfiguration) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hide-\(UUID().uuidString)", isDirectory: true)
        let assets = base.appendingPathComponent("40_Family_Tree", isDirectory: true)
        let gedcoms = assets.appendingPathComponent("GEDCOM", isDirectory: true)
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        try """
        0 HEAD
        0 @F6@ FAM
        1 CHIL @I5@
        1 CHIL @I7@
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 23 December 1904
        1 FAMC @F6@
        1 _FSFTID G89Q-34N
        0 @I5@ INDI
        1 NAME Mary /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 1905
        1 FAMC @F6@
        1 _FSFTID GNZ5-428
        0 TRLR
        """.write(to: gedcoms.appendingPathComponent("tree.ged"), atomically: true, encoding: .utf8)
        if let rulings { try rulings.save(to: gedcoms) }
        return (base, FamilyAssetConfiguration(
            roots: .init(assets: assets, thumbnailCache: base.appendingPathComponent("thumbs")),
            access: .readWrite, legacyGEDCOMDirectory: nil))
    }

    /// The way Hallie asks. If this returns two Marys, Rick's uncle gets the
    /// wrong grandmother.
    @Test @MainActor func askingTheGraphForMaryAnswersWithOneWhenTheOtherIsHidden() throws {
        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("G89Q-34N"), verified: true))
        rulings.record(.init(key: .familySearch("GNZ5-428"),
                             duplicateOf: .familySearch("G89Q-34N")))
        let a = try archive(rulings: rulings)
        defer { try? FileManager.default.removeItem(at: a.base) }

        let cache = FamilyGraphSharedCache(log: { _ in })
        let graph = try #require(cache.graph(for: a.config, store: nil),
                                 "the tree did not load at all")
        #expect(graph.people.count == 2, "precondition: both records are in the tree")
        #expect(graph.suppressedPersonIDs == ["@I5@"],
                "the ruling did not reach the graph Hallie uses")

        // The phrase that NAMES the hidden record must still answer, with
        // the right person — not with nothing. That is the whole point of
        // "so we always get the right one".
        let found = graph.people(matching: "Mary O'Connor")
        #expect(found.count == 1, "Hallie was offered \(found.count) Marys: \(found.map(\.name))")
        #expect(found.first?.familySearchID == "G89Q-34N", "the wrong Mary was the survivor")
    }

    /// With no rulings the behaviour is exactly what it was — both records,
    /// nothing hidden. This is what makes the case above meaningful.
    @Test @MainActor func withNoRulingsBothRecordsAreStillOffered() throws {
        let a = try archive(rulings: nil)
        defer { try? FileManager.default.removeItem(at: a.base) }

        let cache = FamilyGraphSharedCache(log: { _ in })
        let graph = try #require(cache.graph(for: a.config, store: nil))
        #expect(graph.suppressedPersonIDs.isEmpty)
        #expect(graph.people(matching: "Mary O'Connor").count == 1,
                "baseline: with no ruling the phrase finds exactly the record it names")
        #expect(graph.people(matching: "Mary").count == 2,
                "if this is 1 without any ruling, the hiding cases prove nothing")
    }

    /// A hide with no named replacement — Rick's real workflow — reaches the
    /// graph the same way.
    @Test @MainActor func aPlainHideReachesTheGraphToo() throws {
        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("GNZ5-428"), hidden: true,
                             note: "the wrong Mary"))
        let a = try archive(rulings: rulings)
        defer { try? FileManager.default.removeItem(at: a.base) }

        let cache = FamilyGraphSharedCache(log: { _ in })
        let graph = try #require(cache.graph(for: a.config, store: nil))
        // A plain hide names no replacement, so the phrase that named her
        // finds nobody — correct, and different from the duplicateOf case.
        #expect(graph.people(matching: "Mary").count == 1)
        #expect(graph.people(matching: "Mary").first?.familySearchID == "G89Q-34N")
    }

    /// A ruling naming an id this tree does not contain must hide nobody.
    @Test @MainActor func aRulingForSomeoneNotInThisTreeHidesNobody() throws {
        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("ZZZZ-999"), hidden: true))
        let a = try archive(rulings: rulings)
        defer { try? FileManager.default.removeItem(at: a.base) }

        let cache = FamilyGraphSharedCache(log: { _ in })
        let graph = try #require(cache.graph(for: a.config, store: nil))
        #expect(graph.suppressedPersonIDs.isEmpty)
        #expect(graph.people(matching: "Mary").count == 2)
    }
}
