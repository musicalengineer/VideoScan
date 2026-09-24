// IdentityRulingsCoherenceTests.swift
// codex #1710 / #1711 (2026-09-23): the identity rulings were applied in
// the shared tree cache, but
//   (1) the cache key did not include the rulings file, so a Hide / Unhide
//       in the Family Tree tab — or a hand edit of the file — never reached
//       a Hallie that had already loaded the tree;
//   (2) the cache returned TWO views: `outcome.graph` (what the Family Tree
//       tab installs) captured BEFORE the rulings were applied, and
//       `loaded.graph` (what Hallie reads) after — so a fresh load already
//       disagreed;
//   (3) the Family Tree model saved a ruling AFTER putting it in force, so a
//       failed save left the tab and Hallie disagreeing until relaunch; and
//       its installed graph honoured nothing but the sidebar filter.
//
// Every case below goes through the real cache / real model with a real
// rulings file in a scratch folder — never Rick's archive.
//
// Dimensions: LOGIC · ISOLATION (scratch dirs only; the SHARED cache is
// never touched — each test builds its own) · SENSOR (a same-mtime hand edit
// still reaches Hallie: the key is the file's content, not its timestamp).

import Testing
import Foundation
@testable import VideoScan
@testable import VideoScanCore

@Suite("Identity rulings reach every view, coherently (codex #1710/#1711)", .serialized)
struct IdentityRulingsCoherenceTests {

    /// Michael + Bridget → Mary Christina [G89Q-34N] and a duplicate Mary
    /// [GNZ5-428]. `gedcoms` is the archive's GEDCOM folder.
    private func archive(rulings: FamilyIdentityDecisions? = nil) throws
        -> (base: URL, gedcoms: URL, config: FamilyAssetConfiguration) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coherence-\(UUID().uuidString)", isDirectory: true)
        let assets = base.appendingPathComponent("40_Family_Tree", isDirectory: true)
        let gedcoms = assets.appendingPathComponent("GEDCOM", isDirectory: true)
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        try """
        0 HEAD
        0 @F6@ FAM
        1 HUSB @M@
        1 WIFE @B@
        1 CHIL @I7@
        1 CHIL @I5@
        0 @M@ INDI
        1 NAME Michael /O'Connor/
        1 SEX M
        1 FAMS @F6@
        1 _FSFTID GMOC-001
        0 @B@ INDI
        1 NAME Bridget /Ronan/
        1 SEX F
        1 FAMS @F6@
        1 _FSFTID GBRI-002
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
        2 DATE 1850
        1 FAMC @F6@
        1 _FSFTID GNZ5-428
        0 TRLR
        """.write(to: gedcoms.appendingPathComponent("tree.ged"), atomically: true, encoding: .utf8)
        if let rulings { try rulings.save(to: gedcoms) }
        return (base, gedcoms, FamilyAssetConfiguration(
            roots: .init(assets: assets, thumbnailCache: base.appendingPathComponent("thumbs")),
            access: .readWrite, legacyGEDCOMDirectory: nil))
    }

    private static var duplicateRuling: FamilyIdentityDecisions {
        var r = FamilyIdentityDecisions()
        r.record(.init(key: .familySearch("G89Q-34N"), verified: true))
        r.record(.init(key: .familySearch("GNZ5-428"), duplicateOf: .familySearch("G89Q-34N")))
        return r
    }

    private func oConnors(_ graph: GedcomFamilyGraph?) -> [String] {
        (graph?.people(withSurname: "O'Connor") ?? []).map(\.id).sorted()
    }

    // MARK: (1) a ruling made AFTER Hallie loaded the tree reaches her next turn

    @Test @MainActor func aHideInTheFamilyTreeReachesAnAlreadyLoadedHallie() async throws {
        let a = try archive()
        defer { try? FileManager.default.removeItem(at: a.base) }
        let cache = FamilyGraphSharedCache(log: { _ in })
        let before = try #require(cache.graph(for: a.config, store: nil))
        #expect(before.people(matching: "Mary").count == 2, "precondition: nothing hidden yet")

        // Rick hides the wrong Mary from the card menu (the real verb, the
        // real save to the same GEDCOM folder).
        let tree = FamilyTreeLiveModel(originalsDirectory: a.gedcoms, bookmarksDirectory: a.gedcoms)
        await tree.prepareForAppearance(revision: "t-\(UUID().uuidString)")
        try #require(tree.peopleCount > 0, "the tree never loaded")
        #expect(tree.setRecordHidden(true, personID: "@I5@", note: "the wrong Mary"))

        let runsBefore = cache.loaderRuns
        let after = try #require(cache.graph(for: a.config, store: nil))
        #expect(after.suppressedPersonIDs.contains("@I5@"), "Hallie still sees the Mary Rick just hid")
        #expect(after.people(matching: "Mary").map(\.id) == ["@I7@"])
        #expect(cache.loaderRuns == runsBefore, "a ruling-only change must re-rule, not re-parse")

        // …and Unhide reaches her the same way.
        #expect(tree.setRecordHidden(false, personID: "@I5@"))
        let restored = try #require(cache.graph(for: a.config, store: nil))
        #expect(!restored.suppressedPersonIDs.contains("@I5@"), "Unhide did not reach Hallie")
        #expect(restored.people(matching: "Mary").count == 2)
    }

    /// SENSOR: a hand edit that keeps the file's timestamp (an editor, a
    /// restore) still invalidates — the key is the content.
    @Test func aHandEditWithTheSameTimestampStillReachesHallie() throws {
        let a = try archive(rulings: FamilyIdentityDecisions())
        defer { try? FileManager.default.removeItem(at: a.base) }
        let file = FamilyIdentityDecisions.fileURL(in: a.gedcoms)
        let stamp = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let cache = FamilyGraphSharedCache(log: { _ in })
        #expect(cache.graph(for: a.config, store: nil)?.suppressedPersonIDs.isEmpty == true)

        try Self.duplicateRuling.save(to: a.gedcoms)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let graph = try #require(cache.graph(for: a.config, store: nil))
        #expect(graph.suppressedPersonIDs.contains("@I5@"), "a same-mtime edit of the rulings was ignored")
        #expect(graph.preferredPersonID["@I5@"] == "@I7@")
    }

    // MARK: (2) one load, one view

    @Test func theTabsOutcomeAndHalliesGraphAreTheSameRuledView() throws {
        let a = try archive(rulings: Self.duplicateRuling)
        defer { try? FileManager.default.removeItem(at: a.base) }
        let cache = FamilyGraphSharedCache(log: { _ in })
        let result = cache.outcome(for: a.config, store: nil)
        let tab = try #require(result.outcome?.graph, "no outcome graph")
        let hallie = try #require(result.loaded?.graph, "no loaded graph")
        #expect(tab.suppressedPersonIDs == hallie.suppressedPersonIDs,
                "the Family Tree tab's graph and Hallie's disagree about who is hidden")
        #expect(tab.preferredPersonID == hallie.preferredPersonID)
        #expect(tab.suppressedPersonIDs.contains("@I5@"))
        #expect(oConnors(tab) == oConnors(hallie))
        #expect(oConnors(tab) == ["@I7@", "@M@"])
        // A reused (cache-hit) call returns the same view too.
        let again = cache.outcome(for: a.config, store: nil)
        #expect(again.loaded?.reused == true)
        #expect(again.outcome?.graph?.suppressedPersonIDs == ["@I5@"])
    }

    // MARK: (3) the Family Tree model

    @Test @MainActor func theInstalledTreeHonoursARulingAlreadyOnDisk() async throws {
        let a = try archive(rulings: Self.duplicateRuling)
        defer { try? FileManager.default.removeItem(at: a.base) }
        let tree = FamilyTreeLiveModel(originalsDirectory: a.gedcoms, bookmarksDirectory: a.gedcoms)
        await tree.prepareForAppearance(revision: "t-\(UUID().uuidString)")
        try #require(tree.peopleCount > 0, "the tree never loaded")
        // "Show All Children" reads the installed graph's relationships.
        #expect(tree.children(of: "@M@").map(\.id) == ["@I7@"],
                "the installed tree lists the hidden Mary as Michael's child")
    }

    @Test @MainActor func hideAndUnhideMoveTheInstalledRelationshipsToo() async throws {
        let a = try archive()
        defer { try? FileManager.default.removeItem(at: a.base) }
        let tree = FamilyTreeLiveModel(originalsDirectory: a.gedcoms, bookmarksDirectory: a.gedcoms)
        await tree.prepareForAppearance(revision: "t-\(UUID().uuidString)")
        try #require(tree.peopleCount > 0)
        #expect(Set(tree.children(of: "@M@").map(\.id)) == ["@I5@", "@I7@"], "precondition")
        #expect(tree.setRecordHidden(true, personID: "@I5@"))
        #expect(tree.children(of: "@M@").map(\.id) == ["@I7@"], "a hidden record is still Michael's child")
        #expect(tree.setRecordHidden(false, personID: "@I5@"))
        #expect(Set(tree.children(of: "@M@").map(\.id)) == ["@I5@", "@I7@"], "Unhide did not restore her")
    }

    /// Save FIRST: a ruling the disk refused is not in force anywhere —
    /// otherwise the tab hides a record Hallie (reading the file) still
    /// offers, until relaunch.
    @Test @MainActor func aRulingThatCannotBeSavedIsNotPutInForce() async throws {
        let a = try archive()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.gedcoms.path)
            try? FileManager.default.removeItem(at: a.base)
        }
        let tree = FamilyTreeLiveModel(originalsDirectory: a.gedcoms, bookmarksDirectory: a.gedcoms)
        await tree.prepareForAppearance(revision: "t-\(UUID().uuidString)")
        try #require(tree.peopleCount > 0)
        // The GEDCOM folder becomes read-only: the atomic save cannot
        // create its temporary file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: a.gedcoms.path)
        #expect(tree.setRecordHidden(true, personID: "@I5@") == false, "the failed save reported success")
        #expect(!tree.isSuppressedRecord("@I5@"), "a ruling that never reached disk is in force in the tab")
        #expect(tree.identityDecisions.isEmpty)
        #expect(Set(tree.children(of: "@M@").map(\.id)) == ["@I5@", "@I7@"])
        #expect(!FileManager.default.fileExists(atPath: FamilyIdentityDecisions.fileURL(in: a.gedcoms).path))
    }

    // MARK: A Hallie surface, end to end

    @Test func theSurnameRosterHallieReadsLeavesTheHiddenRecordOut() throws {
        let a = try archive(rulings: Self.duplicateRuling)
        defer { try? FileManager.default.removeItem(at: a.base) }
        let graph = try #require(FamilyGraphSharedCache(log: { _ in }).graph(for: a.config, store: nil))
        let family = try #require(HallieSurnameRoster.family(forSurname: "O'Connor", in: graph))
        #expect(!family.people.map(\.id).contains("@I5@"), "the hidden Mary is in the O'Connor roster")
        #expect(family.people.map(\.id).sorted() == ["@I7@", "@M@"])
    }
}
