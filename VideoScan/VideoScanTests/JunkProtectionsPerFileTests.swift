// JunkProtectionsPerFileTests.swift
// Codex delete-engines review 2026-10-09, F3 (P1): "Junk does not refresh
// all protections during the batch." The Master Archive protection was
// captured ONCE, at the batch's start (nil when no archive was designated
// then), and A/V pairing was never re-asked at a file's turn.
//
// Now each file's turn re-reads, on the main actor: the Master Archive
// protection (tree, volume, and the disk half's UUID last word) and the
// catalog's pair membership. Two pins:
//   * the archive is designated while the batch runs → a later target on
//     it is HELD, named, untouched;
//   * a frozen target becomes half of a recovered A/V pair before its
//     turn → HELD, named, untouched.
//
// Synthetic files in temp folders; the "Trash" is a sandbox folder.

import Foundation
import Testing
@testable import VideoScan

@Suite("Junk — protections re-read at each file's turn (codex F3)", .serialized)
@MainActor
struct JunkProtectionsPerFileTests {

    /// Run `body` on the main actor from the disk worker's thread (the
    /// main actor is suspended awaiting that worker, never blocked).
    nonisolated private static func onMain(_ body: @MainActor () -> Void) {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    @Test func anArchiveDesignatedMidBatchHoldsTheLaterFilesOnIt() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("f3_arch")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let first = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_first.mov"),
                                                           bytes: 1_024, seed: 1)
        let later = try MasterArchiveTestSupport.writeBlob(at: sb.archiveVolume.appendingPathComponent("test_later.mov"),
                                                           bytes: 1_024, seed: 2)
        let recs = [first, later].map { MasterArchiveTestSupport.makeRecord(path: $0.path) }
        model.records = recs
        #expect(model.masterArchive == nil, "fixture: no archive when the batch starts")

        let trash = sb.root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        nonisolated(unsafe) let live = model
        let sandbox = sb
        let operation: @Sendable (URL) throws -> Void = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            // Rick designates the archive while the first file is moving.
            Self.onMain { _ = try? MasterArchiveTestSupport.initialize(live, in: sandbox) }
        }
        let result = await model.trashSelectedRecords(recs, fileOperation: operation)

        #expect(model.masterArchive != nil, "fixture: the archive was designated mid-batch")
        #expect(result.items.map(\.outcome.kind) == [.moved, .held], "\(result.items.map(\.outcome))")
        #expect(FileManager.default.fileExists(atPath: later.path), "the file on the archive volume stays")
        #expect(recs[1].purgedAt == nil)
        let why = try #require(result.refused.first?.reason)
        #expect(why.contains("archive"), Comment(rawValue: why))
    }

    @Test func aFrozenTargetPairedBeforeItsTurnIsHeld() async throws {
        let sb = try JunkTrashSandbox("f3_pair"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        let b = sb.junk(try sb.write("test_b.mov", fill: 0x33))
        model.records = [a, b]
        let snapshot = await model.freezeJunkSnapshot([a, b], isOffline: { _ in false })
        #expect(snapshot.moveCount == 2, "fixture: both counted")

        nonisolated(unsafe) let second = b
        let trash = sb.trash
        let operation: @Sendable (URL) throws -> Void = { url in
            try trash.operation(url)
            // Combine pairs the second file while the first is moving.
            Self.onMain { second.pairGroupID = UUID() }
        }
        let result = await model.trashFrozenJunk(snapshot, fileOperation: operation)

        #expect(result.items.map(\.outcome.kind) == [.moved, .held], "\(result.items.map(\.outcome))")
        #expect(FileManager.default.fileExists(atPath: b.fullPath), "the paired file stays")
        #expect(b.purgedAt == nil)
        let why = try #require(result.refused.first?.reason)
        #expect(why.contains("audio/video pair"), Comment(rawValue: why))
    }

    @Test func aCatalogSelectionTargetPairedBeforeItsTurnIsHeld() async throws {
        let sb = try JunkTrashSandbox("f3_pair_sel"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        let b = sb.junk(try sb.write("test_b.mov", fill: 0x44))
        model.records = [a, b]

        nonisolated(unsafe) let second = b
        let trash = sb.trash
        let operation: @Sendable (URL) throws -> Void = { url in
            try trash.operation(url)
            Self.onMain { second.pairGroupID = UUID() }
        }
        let result = await model.trashSelectedRecords([a, b], fileOperation: operation)

        #expect(result.items.map(\.outcome.kind) == [.moved, .held], "\(result.items.map(\.outcome))")
        #expect(FileManager.default.fileExists(atPath: b.fullPath))
        #expect(result.refused.first?.reason.contains("audio/video pair") == true, "\(result.refused)")
    }
}
