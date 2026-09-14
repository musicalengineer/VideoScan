// HoldoutClearStoreTests.swift
// The app-side, reversible way out of a holdout review row
// (feature/holdout-review-explain-clear, Rick 2026-09-13).
//
// Covers:
//   1. Logic     — clear / undo round trip, idempotence, per-queue keying
//   2. Disk      — save → load round trip through the real Codable path
//   3. ISOLATION — the poisoned-state dimension the house checklist asks
//      for: a store from ANOTHER queue, a corrupt/truncated file, a
//      future store version, duplicate entries, and entries naming
//      reviewIds the CSV no longer has must all leave the badge CORRECT
//      rather than crashing or hiding a live row.
//   4. Sensor    — the badge count after a clear, end to end through
//      HoldoutReviewCenter and a real CSV on disk.
//
// Every store here is built with an explicit temp directory, so the real
// ~/Library/Application Support/VideoScan/holdout-review-clears.json is
// never opened (and the store's own defaultDirectory already redirects
// under a test host — belt and braces).

import Foundation
import Testing
@testable import VideoScan

@Suite("Holdout Clear Store")
@MainActor
struct HoldoutClearStoreTests {

    // MARK: Fixtures

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holdout-clears-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store(in dir: URL) -> HoldoutClearStore {
        HoldoutClearStore(directory: dir)
    }

    private let queueA = "2026-08-05/rick-review-neutral.csv"
    private let queueB = "2026-07-23/rick-review-neutral.csv"

    // MARK: - 1. Logic

    @Test func clearThenUndo_roundTripsInMemory() throws {
        let s = store(in: try tempDir())
        #expect(s.isEmpty)
        #expect(s.clear(queueKey: queueA, reviewId: "R1", filename: "a.mkv", reason: .userChoice))
        #expect(s.isCleared(queueKey: queueA, reviewId: "R1"))
        #expect(s.clearedReviewIds(queueKey: queueA) == ["R1"])

        let entry = try #require(s.mostRecent(queueKey: queueA))
        #expect(entry.reviewId == "R1")
        #expect(entry.filename == "a.mkv")
        #expect(entry.reason == HoldoutClearReason.userChoice.rawValue)

        #expect(s.undo(id: entry.id))
        #expect(!s.isCleared(queueKey: queueA, reviewId: "R1"))
        #expect(s.clearedReviewIds(queueKey: queueA).isEmpty)
        #expect(s.isEmpty)
        // A second undo of the same id is a no-op, not a crash.
        #expect(!s.undo(id: entry.id))
    }

    @Test func clearIsIdempotent_originalReasonAndTimestampStand() {
        let dir = try! tempDir()
        let s = store(in: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(s.clear(queueKey: queueA, reviewId: "R1", filename: "a.mkv",
                        reason: .offline, now: t0))
        // Second clear returns false and changes nothing.
        #expect(!s.clear(queueKey: queueA, reviewId: "R1", filename: "a.mkv",
                         reason: .userChoice, now: t0.addingTimeInterval(60)))
        #expect(s.count == 1)
        #expect(s.mostRecent(queueKey: queueA)?.reason == HoldoutClearReason.offline.rawValue)
        #expect(s.mostRecent(queueKey: queueA)?.clearedAt == t0)
    }

    @Test func clearsAreKeyedPerQueue() {
        let s = store(in: try! tempDir())
        s.clear(queueKey: queueA, reviewId: "R1", filename: "a.mkv", reason: .userChoice)
        s.clear(queueKey: queueB, reviewId: "R1", filename: "same-id-other-queue.mkv",
                reason: .userChoice)
        #expect(s.count == 2)
        #expect(s.clearedReviewIds(queueKey: queueA) == ["R1"])
        #expect(s.clearedReviewIds(queueKey: queueB) == ["R1"])
        // Undoing one queue's clear leaves the other alone.
        #expect(s.undoAll(queueKey: queueA) == 1)
        #expect(s.clearedReviewIds(queueKey: queueA).isEmpty)
        #expect(s.clearedReviewIds(queueKey: queueB) == ["R1"])
    }

    @Test func undoMostRecent_takesTheNewestBack() {
        let s = store(in: try! tempDir())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.clear(queueKey: queueA, reviewId: "OLD", filename: "old.mkv",
                reason: .offline, now: t0)
        s.clear(queueKey: queueA, reviewId: "NEW", filename: "new.mkv",
                reason: .offline, now: t0.addingTimeInterval(60))
        let back = s.undoMostRecent(queueKey: queueA)
        #expect(back?.reviewId == "NEW")
        #expect(s.clearedReviewIds(queueKey: queueA) == ["OLD"])
        #expect(s.undoMostRecent(queueKey: queueB) == nil)   // nothing to undo
    }

    @Test func blankKeysAreRefused() {
        let s = store(in: try! tempDir())
        #expect(!s.clear(queueKey: "", reviewId: "R1", filename: "a", reason: .offline))
        #expect(!s.clear(queueKey: queueA, reviewId: "  ", filename: "a", reason: .offline))
        #expect(s.isEmpty)
    }

    // MARK: - 2. Disk round trip

    @Test func saveThenLoad_roundTripsThroughJSON() async throws {
        let dir = try tempDir()
        let writer = store(in: dir)
        writer.clear(queueKey: queueA, reviewId: "R1", filename: "a.mkv", reason: .unrenderable)
        writer.clear(queueKey: queueB, reviewId: "R2", filename: "b.mov", reason: .offline)
        #expect(await writer.save())

        let reader = store(in: dir)
        #expect(await reader.load())
        #expect(reader.count == 2)
        #expect(reader.clearedReviewIds(queueKey: queueA) == ["R1"])
        #expect(reader.mostRecent(queueKey: queueB)?.reason == HoldoutClearReason.offline.rawValue)

        // The LAST undo must reach disk — an empty list is written too.
        reader.undoAll(queueKey: queueA)
        reader.undoAll(queueKey: queueB)
        #expect(await reader.save())
        let reader2 = store(in: dir)
        await reader2.load()
        #expect(reader2.isEmpty)
    }

    @Test func theFileIsPlainReadableJSON_notTheReviewCSV() async throws {
        let dir = try tempDir()
        let s = store(in: dir)
        s.clear(queueKey: queueA, reviewId: "R1", filename: "a.mkv", reason: .userChoice)
        #expect(await s.save())
        let url = dir.appendingPathComponent(HoldoutClearStore.filename)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"storeVersion\""))
        #expect(text.contains("\"queueKey\""))
        #expect(text.contains("2026-08-05/rick-review-neutral.csv"))
        // The sidecar carries NO answer column — a clear is not an answer.
        #expect(!text.contains("rickConfirm"))
        #expect(!text.lowercased().contains("\"yes\""))
    }

    // MARK: - 3. ISOLATION — poisoned state

    @Test func poison_storeFromAnotherQueueHidesNothingHere() {
        let s = store(in: try! tempDir())
        // Everything in the store belongs to LAST month's queue.
        s.clear(queueKey: queueB, reviewId: "R1", filename: "x", reason: .offline)
        s.clear(queueKey: queueB, reviewId: "R2", filename: "y", reason: .offline)

        let rows = [
            HoldoutReviewRow(reviewId: "R1", fullPath: "/Volumes/T/1.mov",
                             rickConfirm: "", notes: "", extraColumns: []),
            HoldoutReviewRow(reviewId: "R2", fullPath: "/Volumes/T/2.mov",
                             rickConfirm: "", notes: "", extraColumns: []),
        ]
        let clearedForA = s.clearedReviewIds(queueKey: queueA)
        #expect(clearedForA.isEmpty)
        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: clearedForA) == 2)
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [],
            unplayableExcluded: [], cleared: clearedForA) == 0)
    }

    @Test func poison_corruptAndTruncatedFilesStartEmpty() async throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(HoldoutClearStore.filename)

        // Truncated mid-object.
        try Data("{\"storeVersion\":1,\"entries\":[{\"reviewId\":\"R".utf8).write(to: url)
        let s1 = store(in: dir)
        #expect(await s1.load() == false)
        #expect(s1.isEmpty)
        #expect(s1.clearedReviewIds(queueKey: queueA).isEmpty)

        // Not JSON at all.
        try Data("this is not json\n".utf8).write(to: url)
        let s2 = store(in: dir)
        #expect(await s2.load() == false)
        #expect(s2.isEmpty)

        // Valid JSON, future store version.
        try Data("{\"storeVersion\":99,\"savedAt\":\"2026-09-13T00:00:00Z\",\"entries\":[]}".utf8)
            .write(to: url)
        let s3 = store(in: dir)
        #expect(await s3.load() == false)
        #expect(s3.isEmpty)

        // Missing file.
        try FileManager.default.removeItem(at: url)
        let s4 = store(in: dir)
        #expect(await s4.load() == false)
        #expect(s4.isEmpty)
    }

    @Test func poison_duplicateEntriesCollapseFirstWins() {
        let s = store(in: try! tempDir())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let file = HoldoutClearFile(entries: [
            HoldoutClearEntry(queueKey: queueA, reviewId: "R1", filename: "first.mkv",
                              reason: HoldoutClearReason.offline.rawValue, clearedAt: t0),
            HoldoutClearEntry(queueKey: queueA, reviewId: "R1", filename: "second.mkv",
                              reason: HoldoutClearReason.userChoice.rawValue,
                              clearedAt: t0.addingTimeInterval(60)),
            HoldoutClearEntry(queueKey: "", reviewId: "R9", filename: "blank-queue",
                              reason: "offline", clearedAt: t0),
        ])
        s.replace(with: file)
        #expect(s.count == 1)
        #expect(s.mostRecent(queueKey: queueA)?.filename == "first.mkv")
        // The blank-key entry was dropped, and undoing the survivor leaves
        // a clean store.
        #expect(s.undoAll(queueKey: queueA) == 1)
        #expect(s.isEmpty)
    }

    @Test func poison_entriesNamingUnknownReviewIdsSubtractNothing() {
        let s = store(in: try! tempDir())
        s.clear(queueKey: queueA, reviewId: "GHOST-1", filename: "gone.mkv", reason: .offline)
        s.clear(queueKey: queueA, reviewId: "GHOST-2", filename: "gone2.mkv", reason: .offline)
        // The CSV was regenerated and has entirely different ids.
        let rows = [
            HoldoutReviewRow(reviewId: "NEW-1", fullPath: "/Volumes/T/1.mov",
                             rickConfirm: "", notes: "", extraColumns: []),
            HoldoutReviewRow(reviewId: "NEW-2", fullPath: "/Volumes/T/2.mov",
                             rickConfirm: "", notes: "", extraColumns: []),
        ]
        let stored = s.clearedReviewIds(queueKey: queueA)
        #expect(stored.count == 2)
        // Row-walking counts are immune...
        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: stored) == 2)
        // ...and the SIZE-derived figures are protected by the narrowing.
        #expect(HoldoutNavigation.clearedReviewIds(rows: rows, storeCleared: stored).isEmpty)
        // The breakdown still shows both rows as live.
        let b = HoldoutNavigation.breakdown(rows: rows, meta: [:],
                                            cleared: stored, offlinePaths: [])
        #expect(b.pending == 2)
        #expect(b.cleared == 0)
    }

    // MARK: - 4. SENSOR — the badge, end to end

    /// A real CSV on disk, a real center, a real clear: the badge count
    /// must drop to zero and the badge must disappear.
    @Test func sensor_badgeCountDropsToZeroAfterClearingTheLastRow() async throws {
        let repoRoot = try tempDir()
        let queueDir = repoRoot.appendingPathComponent("output/person-eval-private/2026-08-05",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        let csv = queueDir.appendingPathComponent(HoldoutReviewQueue.csvFilename)
        let text = ([HoldoutReviewQueue.expectedHeaderPrefix.joined(separator: ",")] + [
            "AAAA0001,/Volumes/MediaExpansion/answered.mov,yes,",
            "469E9ABDE1B3,/Volumes/MediaExpansion/Converted_VHS_Tapes_2026/Montana/2026-07-05_13-09-52.mkv,,",
        ]).map { $0 + "\r\n" }.joined()
        try Data(text.utf8).write(to: csv)

        let clears = HoldoutClearStore(directory: try tempDir())
        let center = HoldoutReviewCenter(repoRoot: repoRoot, clears: clears)
        await center.refresh()

        let q = try #require(center.pendingQueue(for: "Donna"))
        #expect(q.queueKey == "2026-08-05/rick-review-neutral.csv")
        #expect(center.effectivePendingCount(for: q) == 1)
        #expect(center.badgeCount(for: "Donna") == 1)

        // Rick clears the row he can't judge.
        #expect(clears.clear(queueKey: q.queueKey, reviewId: "469E9ABDE1B3",
                             filename: "2026-07-05_13-09-52.mkv", reason: .userChoice))
        #expect(center.effectivePendingCount(for: q) == 0)
        #expect(center.pendingQueue(for: "Donna") == nil)   // badge is gone
        #expect(center.badgeCount(for: "Donna") == 0)

        // The CSV itself is UNTOUCHED — the sealed artifact still says
        // pending, which is what codex's grading tooling reads.
        let onDisk = try String(contentsOf: csv, encoding: .utf8)
        #expect(onDisk == text)

        // Undo brings the badge back.
        #expect(clears.undoMostRecent(queueKey: q.queueKey) != nil)
        #expect(center.badgeCount(for: "Donna") == 1)
        #expect(center.pendingQueue(for: "Donna") != nil)
    }
}
