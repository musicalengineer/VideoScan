// EventsFolderDropTests.swift
// Catalog ▸ drag files onto a folder (2026-10-19).
// LOGIC: dropped ids become members (copies folded, keyless skipped); a
// recording in another folder moves out of it; a drop on the folder the
// files are already in does nothing; the drag payload round-trips and
// ignores foreign text. ISOLATION: the store writes only into its test
// directory. Scale / media matrix: not applicable — no media opened,
// O(dropped ids + live members).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Events — drag files onto a folder")
struct EventsFolderDropTests {

    private typealias F = EventsFixture

    private static let shaA = String(repeating: "a", count: 64)
    private static let shaB = String(repeating: "b", count: 64)
    private static let shaC = String(repeating: "c", count: 64)

    private static func loadedStore(_ name: String) async throws -> EventsDecisionStore {
        let store = EventsDecisionStore(directory: try F.scratchDirectory(name))
        _ = await store.load()
        return store
    }

    private static func lookup(_ recs: [VideoRecord]) -> (UUID) -> VideoRecord? {
        let byID = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        return { byID[$0] }
    }

    @Test("dropped ids become members of the folder: copies folded, keyless skipped")
    func droppedIDsBecomeMembers() async throws {
        let store = try await Self.loadedStore("drop-members")
        let folder = try #require(store.confirm(name: "Cape 1990", categories: [], members: [ContentRange(contentKey: Self.shaC)]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)
        let aCopy = F.record("/Volumes/SanDisk/x/a.mov", digest: Self.shaA)
        let b = F.record("/Volumes/LaCie/x/b.mov", digest: Self.shaB)
        let keyless = F.record("/Volumes/LaCie/x/nohash.mov")
        let recs = [a, aCopy, b, keyless]

        let drop = EventsFolderDrop(target: folder.id, recordIDs: Set(recs.map(\.id)), record: Self.lookup(recs),
                                    decisions: store.snapshot())
        #expect(drop.adding.map(\.contentKey) == [Self.shaA, Self.shaB])
        #expect(drop.members.copies == 1)
        #expect(drop.members.skipped == 1)
        #expect(drop.movedCount == 0)
        #expect(drop.apply(in: store))
        #expect(store.snapshot().members(of: folder.id).map(\.contentKey).sorted() == [Self.shaA, Self.shaB, Self.shaC])
    }

    @Test("a recording in another folder moves: it leaves the old folder and joins the new one")
    func moveTakesTheFileOutOfTheOldEvent() async throws {
        let store = try await Self.loadedStore("drop-move")
        let old = try #require(store.confirm(name: "Old", categories: [],
                                             members: [ContentRange(contentKey: Self.shaA), ContentRange(contentKey: Self.shaB)]))
        let new = try #require(store.confirm(name: "New", categories: [], members: [ContentRange(contentKey: Self.shaC)]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)

        let drop = EventsFolderDrop(target: new.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot())
        #expect(drop.movingFrom == [old.id: [ContentRange(contentKey: Self.shaA)]])
        #expect(drop.apply(in: store))
        let after = store.snapshot()
        #expect(after.members(of: old.id) == [ContentRange(contentKey: Self.shaB)], "A left the old folder; B stayed")
        #expect(after.members(of: new.id) == [ContentRange(contentKey: Self.shaA), ContentRange(contentKey: Self.shaC)])
        #expect(FolderDropWords.moved(drop, title: { $0 == old.id ? "Old" : "New" }) != nil, "one console line says which folder")
    }

    @Test("a drop on the folder the files are already in does nothing")
    func dropOnTheSameEventDoesNothing() async throws {
        let store = try await Self.loadedStore("drop-same")
        let folder = try #require(store.confirm(name: "Here", categories: [], members: [ContentRange(contentKey: Self.shaA)]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)
        let aCopy = F.record("/Volumes/SanDisk/x/a.mov", digest: Self.shaA)
        let revision = store.revision
        let decisions = store.decisionCount

        let drop = EventsFolderDrop(target: folder.id, recordIDs: [a.id, aCopy.id], record: Self.lookup([a, aCopy]),
                                    decisions: store.snapshot())
        #expect(drop.isNoOp)
        #expect(drop.alreadyIn == 1)
        #expect(!drop.apply(in: store))
        #expect(store.revision == revision, "no change, no save")
        #expect(store.decisionCount == decisions)
    }

    @Test("the drag payload is a record id as a string; foreign text is ignored")
    func payloadRoundTrips() {
        let id = UUID()
        let items = [CatalogRecordDrag.payload(id), "hello", "file:///Volumes/LaCie/a.mov", CatalogRecordDrag.prefix + "not-a-uuid"]
        #expect(CatalogRecordDrag.recordIDs(in: items) == [id])
        #expect(!CatalogRecordDrag.payload(id).hasPrefix("file:"), "never a file URL: a drop into Finder must not copy media")
    }

    @Test("a drop writes only into the store's own directory")
    func writesOnlyIntoTheTestDirectory() async throws {
        let dir = try F.scratchDirectory("drop-isolation")
        let store = EventsDecisionStore(directory: dir)
        _ = await store.load()
        #expect(!store.fileURL.path.contains("/Application Support/"))
        let folder = try #require(store.confirm(name: "F", categories: [], members: [ContentRange(contentKey: Self.shaC)]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)
        #expect(EventsFolderDrop(target: folder.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot()).apply(in: store))
        #expect(await store.save())
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(written.contains(EventsDecisionStore.filename))
        #expect(EventsDecisionStore.defaultDirectory.path.contains("VideoScan-tests"), "the shared store is redirected under a test host")
    }
}
