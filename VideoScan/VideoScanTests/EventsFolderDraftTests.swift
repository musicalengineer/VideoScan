// EventsFolderDraftTests.swift
// Catalog ▸ Make Folder… / New Folder with Selection (2026-10-19).
// LOGIC: records → members (copies folded by content key, A/V halves one,
// files with no content identity or outside the Events scope skipped, the
// name passed through, categories from the name); the banner door and the
// menu door give the same members. NAMING: a suggestion's name carries no
// date source; the folder-title cleanup reads a legacy name without it.
// ISOLATION: the store writes only into its test directory.
// Scale / media matrix: not applicable — no media opened, O(focus set).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Events — Make Folder from files")
struct EventsFolderDraftTests {

    private typealias F = EventsFixture

    private static let shaA = String(repeating: "a", count: 64)
    private static let shaB = String(repeating: "b", count: 64)

    @Test("copies fold into one member, A/V halves are one, keyless and removed files are skipped")
    func recordsBecomeMembers() {
        let a1 = F.record("/Volumes/LaCie/Thanksgiving 1984/tape1.mov", digest: Self.shaA)
        let a2 = F.record("/Volumes/SanDisk/Backup/tape1.mov", digest: Self.shaA)   // a copy
        let b = F.record("/Volumes/LaCie/Thanksgiving 1984/tape2.mov", digest: Self.shaB)
        let pair = UUID()
        let v = F.record("/Volumes/Avid/MediaFiles/t.V1.mxf"); v.pairGroupID = pair
        let au = F.record("/Volumes/Avid/MediaFiles/t.A1.mxf"); au.pairGroupID = pair
        let keyless = F.record("/Volumes/LaCie/Thanksgiving 1984/nohash.mov")       // would be "id:…"
        let removed = F.record("/Volumes/LaCie/Thanksgiving 1984/gone.mov", digest: String(repeating: "c", count: 64))
        removed.purgedAt = Date()

        let m = EventsFolderMembers(records: [a1, a2, b, v, au, keyless, removed])
        #expect(m.ranges.map(\.contentKey) == [Self.shaA, Self.shaB, "pair:" + pair.uuidString])
        #expect(m.copies == 2, "the SanDisk copy and the second A/V half")
        #expect(m.skipped == 2)
        #expect(m.fileCount == 7)
    }

    @Test("the name is passed through (trimmed), its category inferred, and the event confirmed with those members")
    func namePassesThroughToTheConfirmedEvent() async throws {
        let store = EventsDecisionStore(directory: try F.scratchDirectory("make-folder"))
        _ = await store.load()
        let recs = [F.record("/Volumes/LaCie/x/tape1.mov", digest: Self.shaA),
                    F.record("/Volumes/LaCie/x/tape2.mov", digest: Self.shaB)]
        let draft = EventsFolderDraft(name: "  Thanksgiving 1984 ", records: recs)
        #expect(draft.categories == ["Thanksgiving"])
        let e = try #require(draft.make(in: store))
        #expect(e.name == "Thanksgiving 1984")
        #expect(e.categories == ["Thanksgiving"])
        #expect(store.snapshot().members(of: e.id) == [ContentRange(contentKey: Self.shaA), ContentRange(contentKey: Self.shaB)])
        #expect(EventsFolderDraft(name: "Grandma visits", records: recs).categories.isEmpty, "no occasion word → no category")
    }

    @Test("nothing is confirmed with no name, no members, or a store not loaded yet")
    func refusals() throws {
        let unloaded = EventsDecisionStore(directory: try F.scratchDirectory("make-folder-unloaded"))
        let rec = F.record("/Volumes/LaCie/x/tape1.mov", digest: Self.shaA)
        #expect(EventsFolderDraft(name: " ", records: [rec]).refusal != nil)
        #expect(EventsFolderDraft(name: "X", records: [F.record("/Volumes/LaCie/x/nohash.mov")]).refusal != nil)
        #expect(EventsFolderDraft(name: "X", records: [rec]).make(in: unloaded) == nil, "a write before the load is refused")
        #expect(unloaded.eventCount == 0)
    }

    @Test("the banner door and the menu door give the same members for the same files")
    func bannerAndMenuGiveTheSameMembers() {
        let recs = [F.record("/Volumes/LaCie/T/c.mov", digest: Self.shaB),
                    F.record("/Volumes/LaCie/T/a.mov", digest: Self.shaA),
                    F.record("/Volumes/SanDisk/T/a.mov", digest: Self.shaA),
                    F.record("/Volumes/LaCie/T/n.mov")]
        let byID = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        let ids = Set(recs.map(\.id))
        // Banner: the focus set as it is. Menu: the selection through the
        // displayed rule (folder view on) — a folder row id and a hidden
        // member in the raw selection must not change the result.
        let folderRow = UUID()
        let hidden = F.record("/Volumes/LaCie/T/hidden.mov", digest: String(repeating: "d", count: 64))
        let shown = CatalogSelectionPrune.displayed(ids.union([folderRow, hidden.id]), foldersOn: true,
                                                    folderRecordIDs: ids, rows: recs + [hidden])
        let banner = EventsFolderDraft(name: "T", recordIDs: ids, record: { byID[$0] })
        let menu = EventsFolderDraft(name: "T", recordIDs: shown, record: { byID[$0] ?? ($0 == hidden.id ? hidden : nil) })
        #expect(shown == ids)
        #expect(banner.members == menu.members)
        #expect(banner.members.ranges.map(\.contentKey) == [Self.shaA, Self.shaB], "path order, whatever the Set's order")
    }

    @Test("a suggestion's name carries the date alone; the question and the date words keep the source")
    func suggestionNameHasNoProvenance() {
        let plan = F.plan([F.row("/Volumes/Tapes/Thanksgiving 1984/t.mov", inferred: F.day(1984, 7, 1),
                                 inferredSource: VideoScanModel.InferredDateSource.folderYear)])
        let s = try! #require(plan.suggestions.first)
        #expect(s.name == "Thanksgiving · 1984")
        #expect(s.dateWords == "1984 (folder name (year only))")
    }

    @Test("a legacy name is shown as a folder title without its date source; the stored name is untouched")
    func legacyNameCleanedOnDisplayOnly() {
        #expect(EventsNaming.folderTitle("Thanksgiving · 1984 (folder name (year only))") == "Thanksgiving · 1984")
        #expect(EventsNaming.folderTitle("Birthday · Jun 5, 1998 (camera) – Jun 7, 1998 (camera)") == "Birthday · Jun 5, 1998 – Jun 7, 1998")
        #expect(EventsNaming.folderTitle("Cape (with Grandma)") == "Cape (with Grandma)", "Rick's own parentheses stay")
        let id = UUID()
        let file = EventsDecisionSnapshot(events: [EventRecord(id: id, name: "Thanksgiving · 1984 (folder name (year only))", categories: [])],
                                          decisions: [.member(eventID: id, range: ContentRange(contentKey: Self.shaA), verdict: .accepted)])
        #expect(FootageFolders.Event.events(in: file).first?.title == "Thanksgiving · 1984")
        #expect(file.events[id]?.name == "Thanksgiving · 1984 (folder name (year only))")
    }

    @Test("Make Folder writes only into the store's own directory")
    func writesOnlyIntoTheTestDirectory() async throws {
        let dir = try F.scratchDirectory("make-folder-isolation")
        let store = EventsDecisionStore(directory: dir)
        _ = await store.load()
        #expect(!store.fileURL.path.contains("/Application Support/"))
        _ = try #require(EventsFolderDraft(name: "Thanksgiving 1984",
                                           records: [F.record("/Volumes/LaCie/x/t.mov", digest: Self.shaA)]).make(in: store))
        #expect(await store.save())
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(written.contains(EventsDecisionStore.filename))
        #expect(EventsDecisionStore.defaultDirectory.path.contains("VideoScan-tests"), "the shared store is redirected under a test host")
    }
}
