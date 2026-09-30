// HoldoutClearStore.swift
// The app-side, reversible way out of a holdout review row
// (feature/holdout-review-explain-clear, Rick 2026-09-13).
//
// THE CASE: Donna's purple "Review 1" badge never went away. Her one
// remaining row is an FFV1+PCM Matroska master that the prefilter hid
// from the sheet while the badge still counted it pending — badge lit,
// nothing to review, no exit. The filmstrip work on this branch makes
// that particular row reviewable; this store is the general answer for
// the rows that stay unreviewable (a drive that is never coming back, a
// file nothing can decode): Rick can CLEAR the row, it leaves the badge
// and the review sheet, and an undo puts it right back.
//
// THE CONTRACT THIS MUST NOT BREAK (HoldoutReviewQueue.swift header):
// the review CSV is codex's sealed artifact — reviewId / fullPath /
// answer / notes only, and the only values the app may ever write into
// the answer column are the exact strings "yes" and "no". A clear is NOT
// an answer, so it is NOT written there. It lives here instead, in a
// sidecar under Application Support, and the CSV row keeps reading
// "pending" for codex's grading tooling. Nothing in this file opens,
// reads, or writes the CSV.
//
// Shape follows IgnoredContentStore / ArchiveAngelEvidenceStore: a
// main-actor façade over a Codable value, loaded and saved off-main,
// written atomically via AtomicFilePublish (temp file in the same
// directory + rename(2) — a reader never sees a torn file, and we stay
// off RENAME_SWAP, which deadlocks Sandbox.kext; see the P0 of
// 2026-09-14). Every read and mutation is O(1).
//
// KEYING: (queueKey, reviewId). `queueKey` is the CSV's identity —
// "<dated dir>/rick-review-neutral.csv" — so a clear made against the
// 2026-08-05 queue can never suppress a row in a queue codex regenerates
// tomorrow, and a store written on one machine's checkout still matches
// on another (no absolute paths in the key).
//
// POISONED STATE (house dimension 4): a corrupt/truncated file, a file
// from a future store version, duplicate entries, and entries naming
// reviewIds the CSV no longer has must all leave the badge CORRECT. The
// first two make the store start empty (nothing hidden — the badge
// over-reports rather than swallowing a live row); duplicates collapse
// first-wins on load; unknown reviewIds simply never match a row, so
// they subtract nothing.
//
// Worst-case memory: one entry ≈ 300 B plus three dictionary slots,
// capped at `maxEntries` (50 000) with drop-oldest — ≈ 20 MB at the cap,
// and Rick's real queues are tens of rows.

import Combine
import Foundation
import os
import VideoScanCore

private let holdoutClearLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "poi.holdout-review"
)

// MARK: - Reasons

/// Why a row was set aside. Stored as a raw string so the JSON stays
/// readable and an unknown future reason never fails a decode.
/// (Swift `enum` with a `String` raw value ≈ a C++ enum plus a
/// hand-written to_string / from_string pair, generated for you.)
enum HoldoutClearReason: String, Codable, Sendable, CaseIterable {
    /// Its volume is not mounted and Rick does not expect it back.
    case offline
    /// Nothing can draw a frame from it.
    case unrenderable
    /// Rick looked and chose not to judge this one.
    case userChoice = "user-choice"

    var friendlyLabel: String {
        switch self {
        case .offline:      return "on a drive that wasn't connected"
        case .unrenderable: return "nothing could show a frame from it"
        case .userChoice:   return "set aside by you"
        }
    }
}

// MARK: - On-disk shapes

/// One cleared row. `filename` rides along purely so the undo list can
/// name the video without reloading the CSV — it is never matched on.
struct HoldoutClearEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var queueKey: String
    var reviewId: String
    var filename: String
    var reason: String
    var clearedAt: Date

    init(id: UUID = UUID(), queueKey: String, reviewId: String,
         filename: String, reason: String, clearedAt: Date) {
        self.id = id
        self.queueKey = queueKey
        self.reviewId = reviewId
        self.filename = filename
        self.reason = reason
        self.clearedAt = clearedAt
    }

    var friendlyReason: String {
        HoldoutClearReason(rawValue: reason)?.friendlyLabel ?? reason
    }
}

/// The file. A file from another store version is ignored on load
/// (poisoned-state rule) — nothing is hidden, the list simply starts
/// empty and the badge counts every pending row again.
struct HoldoutClearFile: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var storeVersion: Int = HoldoutClearFile.currentVersion
    var savedAt: Date
    var entries: [HoldoutClearEntry]

    init(savedAt: Date = Date(), entries: [HoldoutClearEntry] = []) {
        self.savedAt = savedAt
        self.entries = entries
    }
}

// MARK: - Store

@MainActor
final class HoldoutClearStore: ObservableObject {

    /// `nonisolated` because `fileURL` and the off-main load/save helpers
    /// read it from outside the main actor; a `static let` on a
    /// `@MainActor` class is otherwise main-actor-isolated, which Swift 6
    /// makes an error. (For Rick: an immutable `String` is `Sendable` —
    /// think `constexpr`, nothing can race on it.)
    nonisolated static let filename = "holdout-review-clears.json"

    /// Drop-oldest bound, so a pathological session cannot grow this
    /// file without limit. Rick's queues are tens of rows; the cap exists
    /// only to make the memory claim in the header provable.
    static let maxEntries = 50_000

    /// Application Support/VideoScan/ in production. Under a unit-test
    /// host this is a per-process scratch folder instead — the same
    /// discipline as IgnoredContentStore, so a test can never hide a row
    /// from Rick's real badge.
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/holdout-clears-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
    }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    /// Bumped on every mutation (clear / undo / load). The ONE published
    /// signal — the badge and the popover re-read on it.
    @Published private(set) var revision: Int = 0

    private var byID: [UUID: HoldoutClearEntry] = [:]
    /// (queueKey, reviewId) → entry id. The O(1) "is this row cleared?"
    /// answer.
    private var idByRow: [RowKey: UUID] = [:]
    /// queueKey → its cleared reviewIds. Kept incrementally so the sheet
    /// and badge never rebuild it per render.
    private var reviewIdsByQueue: [String: Set<String>] = [:]
    /// Insertion order for drop-oldest eviction at the cap.
    private var insertionOrder: [UUID] = []

    /// Composite key. (Swift lets a `struct` be a dictionary key for free
    /// once it is `Hashable` — no std::hash specialization to write.)
    private struct RowKey: Hashable {
        let queueKey: String
        let reviewId: String
    }

    init(directory: URL = HoldoutClearStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Reads

    var count: Int { byID.count }
    var isEmpty: Bool { byID.isEmpty }

    /// Cleared reviewIds for ONE queue. O(1) — hand this straight to
    /// HoldoutNavigation's `cleared:` parameters.
    func clearedReviewIds(queueKey: String) -> Set<String> {
        reviewIdsByQueue[queueKey] ?? []
    }

    func isCleared(queueKey: String, reviewId: String) -> Bool {
        idByRow[RowKey(queueKey: queueKey, reviewId: reviewId)] != nil
    }

    /// Newest first — the popover's undo list. O(n log n) over ONE
    /// queue's entries, called on revision change, never per render.
    func entries(queueKey: String) -> [HoldoutClearEntry] {
        guard let ids = reviewIdsByQueue[queueKey], !ids.isEmpty else { return [] }
        return byID.values
            .filter { $0.queueKey == queueKey }
            .sorted {
                $0.clearedAt != $1.clearedAt
                    ? $0.clearedAt > $1.clearedAt
                    : $0.id.uuidString > $1.id.uuidString
            }
    }

    /// Most recently cleared row of a queue, or nil.
    func mostRecent(queueKey: String) -> HoldoutClearEntry? {
        entries(queueKey: queueKey).first
    }

    // MARK: Writes (in memory — call `save()` to persist)

    /// Set a row aside. Returns false when it was already cleared (the
    /// original reason and timestamp stand — clearing twice is a no-op,
    /// not a second entry). O(1).
    @discardableResult
    func clear(queueKey: String, reviewId: String, filename: String,
               reason: HoldoutClearReason, now: Date = Date()) -> Bool {
        let trimmedQueue = queueKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReview = reviewId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQueue.isEmpty, !trimmedReview.isEmpty else { return false }
        let key = RowKey(queueKey: trimmedQueue, reviewId: trimmedReview)
        guard idByRow[key] == nil else { return false }
        let entry = HoldoutClearEntry(queueKey: trimmedQueue, reviewId: trimmedReview,
                                      filename: filename, reason: reason.rawValue,
                                      clearedAt: now)
        insert(entry)
        evictIfNeeded()
        revision &+= 1
        holdoutClearLog.info("holdout row cleared — queue: \(trimmedQueue, privacy: .public), reviewId: \(trimmedReview, privacy: .public), reason: \(reason.rawValue, privacy: .public)")
        return true
    }

    /// THE UNDO: put one cleared row back. Returns true when found. O(1).
    @discardableResult
    func undo(id: UUID) -> Bool {
        guard let entry = byID[id] else { return false }
        removeEntry(id: id)
        revision &+= 1
        holdoutClearLog.info("holdout clear undone — queue: \(entry.queueKey, privacy: .public), reviewId: \(entry.reviewId, privacy: .public)")
        return true
    }

    /// Put back the most recently cleared row of a queue. Returns the
    /// entry that came back, or nil when there was nothing to undo.
    @discardableResult
    func undoMostRecent(queueKey: String) -> HoldoutClearEntry? {
        guard let entry = mostRecent(queueKey: queueKey) else { return nil }
        return undo(id: entry.id) ? entry : nil
    }

    /// Put EVERY cleared row of a queue back. Returns how many returned.
    @discardableResult
    func undoAll(queueKey: String) -> Int {
        let all = entries(queueKey: queueKey)
        guard !all.isEmpty else { return 0 }
        for e in all { removeEntry(id: e.id) }
        revision &+= 1
        holdoutClearLog.info("holdout clears undone — queue: \(queueKey, privacy: .public), count: \(all.count, privacy: .public)")
        return all.count
    }

    /// Replace the in-memory list (does not touch disk). Duplicate
    /// (queueKey, reviewId) rows in a hand-edited file collapse
    /// first-wins; blank keys are dropped.
    func replace(with file: HoldoutClearFile) {
        byID.removeAll(keepingCapacity: true)
        idByRow.removeAll(keepingCapacity: true)
        reviewIdsByQueue.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        byID.reserveCapacity(file.entries.count)
        idByRow.reserveCapacity(file.entries.count)
        for e in file.entries {
            guard !e.queueKey.isEmpty, !e.reviewId.isEmpty else { continue }
            guard idByRow[RowKey(queueKey: e.queueKey, reviewId: e.reviewId)] == nil else { continue }
            guard byID[e.id] == nil else { continue }
            insert(e)
        }
        evictIfNeeded()
        revision &+= 1
    }

    /// Forget everything (tests).
    func clearAll() {
        byID.removeAll()
        idByRow.removeAll()
        reviewIdsByQueue.removeAll()
        insertionOrder.removeAll()
        revision &+= 1
    }

    /// Every entry, oldest first — what `save()` writes.
    var allEntries: [HoldoutClearEntry] {
        insertionOrder.compactMap { byID[$0] }
    }

    // MARK: Index maintenance (all O(1))

    private func insert(_ entry: HoldoutClearEntry) {
        byID[entry.id] = entry
        idByRow[RowKey(queueKey: entry.queueKey, reviewId: entry.reviewId)] = entry.id
        reviewIdsByQueue[entry.queueKey, default: []].insert(entry.reviewId)
        insertionOrder.append(entry.id)
    }

    private func removeEntry(id: UUID) {
        guard let entry = byID.removeValue(forKey: id) else { return }
        let key = RowKey(queueKey: entry.queueKey, reviewId: entry.reviewId)
        if idByRow[key] == id { idByRow.removeValue(forKey: key) }
        reviewIdsByQueue[entry.queueKey]?.remove(entry.reviewId)
        if reviewIdsByQueue[entry.queueKey]?.isEmpty == true {
            reviewIdsByQueue.removeValue(forKey: entry.queueKey)
        }
        // The stale insertionOrder slot is harmless — eviction skips a
        // missing key — but drop it when it is cheap to find.
        if let last = insertionOrder.last, last == id { insertionOrder.removeLast() }
    }

    private func evictIfNeeded() {
        while insertionOrder.count > Self.maxEntries {
            let oldest = insertionOrder.removeFirst()
            guard let entry = byID.removeValue(forKey: oldest) else { continue }
            let key = RowKey(queueKey: entry.queueKey, reviewId: entry.reviewId)
            if idByRow[key] == oldest { idByRow.removeValue(forKey: key) }
            reviewIdsByQueue[entry.queueKey]?.remove(entry.reviewId)
        }
    }

    // MARK: Disk

    /// Load off-main and publish. Missing / malformed / wrong-version
    /// file → the store stays empty. Returns whether anything loaded.
    @discardableResult
    func load() async -> Bool {
        let url = fileURL
        guard let loaded = await Self.loadOffMain(url) else { return false }
        replace(with: loaded)
        return true
    }

    /// Save off-main (atomic replace). An EMPTY list is written too — the
    /// last undo must reach disk.
    @discardableResult
    func save() async -> Bool {
        let file = HoldoutClearFile(entries: allEntries)
        let ok = await Self.saveOffMain(file, to: fileURL)
        if !ok {
            holdoutClearLog.error("holdout clear store could not be saved to \(self.fileURL.path, privacy: .public)")
        }
        return ok
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOffMain(_ url: URL) async -> HoldoutClearFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(HoldoutClearFile.self, from: data) else {
            // Truncated / hand-mangled file: start empty rather than
            // throw. Over-reporting the badge is the safe failure —
            // hiding a live row is not.
            holdoutClearLog.error("holdout clear store is unreadable — starting with no cleared rows")
            return nil
        }
        guard f.storeVersion == HoldoutClearFile.currentVersion else {
            holdoutClearLog.error("holdout clear store version \(f.storeVersion, privacy: .public) is not \(HoldoutClearFile.currentVersion, privacy: .public) — starting with no cleared rows")
            return nil
        }
        return f
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func saveOffMain(_ file: HoldoutClearFile, to url: URL) async -> Bool {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            // withoutEscapingSlashes keeps queueKey readable —
            // "2026-08-05/rick-review-neutral.csv", not the "\/" JSON
            // default. This file is meant to be openable in an editor.
            enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            // A clear and an immediate undo can race here; AtomicFilePublish
            // gives each its own temp — last writer wins, neither fails.
            try AtomicFilePublish.write(try enc.encode(file), to: url, durability: .fullFsync)
            return true
        } catch {
            return false
        }
    }
}
