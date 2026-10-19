// EventsFolderDropTests.swift
// Catalog ▸ drag files onto a folder (2026-10-19).
// LOGIC: dropped ids become members (copies folded, keyless skipped); ADD
// keeps every other folder (a file may be in many — 2026-10-19); MOVE
// leaves only the source folder; Remove from Folder leaves only that one;
// a drop on the folder the files are already in does nothing; Finder's
// drag rule (out of a folder = move, ⌥ = add, loose = add); the drag
// payload round-trips with its folder and ignores foreign text.
// ISOLATION: the store writes only into its test directory. Scale / media
// matrix: not applicable — no media opened, O(dropped ids + members).

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

    @Test("MOVE from a folder: the file leaves that folder and joins the new one")
    func moveTakesTheFileOutOfTheOldEvent() async throws {
        let store = try await Self.loadedStore("drop-move")
        let old = try #require(store.confirm(name: "Old", categories: [],
                                             members: [ContentRange(contentKey: Self.shaA), ContentRange(contentKey: Self.shaB)]))
        let new = try #require(store.confirm(name: "New", categories: [], members: [ContentRange(contentKey: Self.shaC)]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)

        let drop = EventsFolderDrop(target: new.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot(),
                                    mode: .move(from: old.id))
        #expect(drop.movingFrom == [old.id: [ContentRange(contentKey: Self.shaA)]])
        #expect(drop.apply(in: store))
        let after = store.snapshot()
        #expect(after.members(of: old.id) == [ContentRange(contentKey: Self.shaB)], "A left the old folder; B stayed")
        #expect(after.members(of: new.id) == [ContentRange(contentKey: Self.shaA), ContentRange(contentKey: Self.shaC)])
    }

    @Test("ADD keeps every folder the file is already in: one content, several folders")
    func addKeepsOtherFolders() async throws {
        let store = try await Self.loadedStore("drop-add")
        let dad = try #require(store.confirm(name: "Dad", categories: [], members: [ContentRange(contentKey: Self.shaA)], kind: .person))
        let xmas = try #require(store.confirm(name: "Christmas 1990", categories: [], members: [ContentRange(contentKey: Self.shaC)]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)

        let drop = EventsFolderDrop(target: xmas.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot())
        #expect(drop.mode == .add)
        #expect(drop.movingFrom.isEmpty, "an add never takes a file out of another folder")
        #expect(drop.apply(in: store))
        let after = store.snapshot()
        #expect(after.members(of: dad.id) == [ContentRange(contentKey: Self.shaA)], "still in Dad")
        #expect(after.members(of: xmas.id).map(\.contentKey).sorted() == [Self.shaA, Self.shaC])
        #expect(Set(after.folders(containing: Self.shaA)) == [dad.id, xmas.id], "overlap: the content is in both")
        #expect(store.folderNames(containing: Self.shaA) == ["Christmas 1990", "Dad"], "In folders: by name")
    }

    @Test("a MOVE onto a folder that already holds the file still takes it out of the source")
    func moveIntoAFolderThatHasItLeavesTheSource() async throws {
        let store = try await Self.loadedStore("drop-move-dup")
        let a1 = ContentRange(contentKey: Self.shaA)
        let src = try #require(store.confirm(name: "Src", categories: [], members: [a1]))
        let dst = try #require(store.confirm(name: "Dst", categories: [], members: [a1]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)
        let drop = EventsFolderDrop(target: dst.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot(),
                                    mode: .move(from: src.id))
        #expect(drop.adding.isEmpty)
        #expect(!drop.isNoOp, "something leaves the source")
        #expect(drop.apply(in: store))
        #expect(store.snapshot().members(of: src.id).isEmpty)
        #expect(store.snapshot().members(of: dst.id) == [a1])
    }

    @Test("Remove from Folder: the content leaves that folder only")
    func removeLeavesOneFolder() async throws {
        let store = try await Self.loadedStore("drop-remove")
        let a1 = ContentRange(contentKey: Self.shaA)
        let one = try #require(store.confirm(name: "One", categories: [], members: [a1, ContentRange(contentKey: Self.shaB)]))
        let two = try #require(store.confirm(name: "Two", categories: [], members: [a1]))
        let a = F.record("/Volumes/LaCie/x/a.mov", digest: Self.shaA)
        let removal = EventsFolderRemoval(folder: one.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot())
        #expect(removal.leaving == [a1])
        #expect(removal.apply(in: store))
        #expect(store.snapshot().members(of: one.id) == [ContentRange(contentKey: Self.shaB)])
        #expect(store.snapshot().members(of: two.id) == [a1], "the other folder keeps it")
        let none = EventsFolderRemoval(folder: one.id, recordIDs: [a.id], record: Self.lookup([a]), decisions: store.snapshot())
        #expect(none.isNoOp, "removing what is not there does nothing")
    }

    @Test("Finder's drag rule: out of a folder = move, option = add, loose files = add")
    func dragModeFollowsFinder() {
        let f = UUID(), g = UUID(), target = UUID()
        let fromF = [CatalogRecordDrag.Item(record: UUID(), folder: f), CatalogRecordDrag.Item(record: UUID(), folder: f)]
        #expect(CatalogRecordDrag.mode(for: fromF, target: target, optionHeld: false) == .move(from: f))
        #expect(CatalogRecordDrag.mode(for: fromF, target: target, optionHeld: true) == .add, "option-drag adds")
        let loose = [CatalogRecordDrag.Item(record: UUID(), folder: nil)]
        #expect(CatalogRecordDrag.mode(for: loose, target: target, optionHeld: false) == .add)
        let mixed = [CatalogRecordDrag.Item(record: UUID(), folder: f), CatalogRecordDrag.Item(record: UUID(), folder: g)]
        #expect(CatalogRecordDrag.mode(for: mixed, target: target, optionHeld: false) == .add, "rows from two folders: add")
        #expect(CatalogRecordDrag.mode(for: fromF, target: f, optionHeld: false) == .add, "onto its own folder: nothing moves")
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

    @Test("the drag payload is a record id as a string (with its folder); foreign text is ignored")
    func payloadRoundTrips() {
        let id = UUID(), other = UUID(), folder = UUID()
        let items = [CatalogRecordDrag.payload(id), CatalogRecordDrag.payload(other, from: folder), "hello",
                     "file:///Volumes/LaCie/a.mov", CatalogRecordDrag.prefix + "not-a-uuid"]
        #expect(CatalogRecordDrag.recordIDs(in: items) == [id, other])
        #expect(CatalogRecordDrag.items(in: items) == [CatalogRecordDrag.Item(record: id, folder: nil),
                                                       CatalogRecordDrag.Item(record: other, folder: folder)])
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
