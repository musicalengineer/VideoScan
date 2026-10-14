// ShowAgain.swift
// "Show these files again" — the one-time repair of a false "deleted" label
// (Rick 2026-10-11; docs/reviews/night/manually_deleted_959_classification_2026_10_11.md).
//
// ONE SENTENCE: files that sit on disk, untouched, but are hidden behind a
// `.manuallyDeleted` label nobody asked for, get their label set back to the
// ordinary live value — and nothing else changes.
//
// Where the false labels came from: Migrate's "skip duplicates on other
// volumes" (Bucket E) labelled skipped files deleted (fixed 2026-10-11 in
// VideoScanModel+Relocate — a skip is now just a skip), and the duplicate /
// prune keeper fold inherited the label from a removed extra (fixed the same
// day, `travelsWithFootage`). 959 live files, 976 GB, were hidden.
//
// CRITERIA, per record — all must hold, judged at the review AND again at
// the job's turn (`verdict`, pure, truth-table tested):
//   1. the record carries the old label in EITHER encoding — `archiveStage`
//      `.manuallyDeleted`, or the removal marker the GH #143 load migration
//      made of that label (`removedFromCatalog` / `.legacyDeletedLabel`;
//      persisted on every such row since 2026-10-12) — its removal marker
//      is nil or exactly that legacy one (any other marker — in the Trash,
//      missing, Remove from Catalog… — is a real removal, never ours), and
//      it is not set aside or superseded. The footer caption's population;
//   2. no Trash / delete receipt for it in the Media Ledger (a `copyTrashed`
//      or `copyDeleted` line naming its record id OR its path; a damaged
//      ledger line mentioning either counts as a receipt — refuse over guess;
//      an unreadable ledger refuses the whole run);
//   3. its drive is connected, a regular file is at its recorded path, and
//      that file's size equals the catalog's size (> 0).
// Anything else STAYS labelled, with its reason. The 9 records whose file
// is missing stay labelled.
//
// THE CHANGE: `archiveStage` `.manuallyDeleted` → `.none`, and the legacy
// removal marker cleared — through the one Trash engine's Restore
// (`clearRemoval`, VideoScanModel+RemovalMarker.swift), the only writer of
// the marker. Why `.none`: it is the value every scanned record starts with
// and the one Migrate's own recovery paths restore (`.salvageFailed` →
// `.none` on a verified copy or adoption). The label overwrote whatever the
// record had; no surviving field says what that was, so `.none` ("no
// archive progress claimed") is the only value that asserts nothing.
// Notes, dates, tags, people — untouched. `lifecycleStage` is left alone
// EXCEPT by the engine's own Restore rule: a row still carrying the
// pre-#143 `.trashed` / `.deletedPermanently` mirror (no purgedAt, so the
// migration made it the legacy marker) becomes `.cataloged` — the truer
// value for a file just proven on disk at its size. The reverse puts the
// marker and the label back, never that stage (QA P3-2, 2026-10-14). No
// File Journey stamp: label and marker only.
//
// NEVER TOUCHES MEDIA. This file and the job read `stat()` and the ledger,
// and write only: a catalog safety snapshot, a receipt JSON beside the
// catalog, the catalog itself (through the normal atomic save), and log
// lines. No move, rename, trash, unlink or open-for-write of a media path
// exists here (ShowAgainSensorTests reads this source to keep it so).
//
// REVERSIBLE: before the first label changes, (a) `catalog.pre-show-again.
// <stamp>.json` — the whole catalog, from memory, through the store's
// canonical encoder — and (b) `label-repairs/show-again-<stamp>.json`, the
// exact list of changed ids with the stage each row really had → new and,
// where the row carried the legacy marker, its `since`.
// `reverseShowAgain(receiptURL:)` puts `.manuallyDeleted` (only where the
// run cleared it — a marker-only row gets no label) and that marker, same
// `since`, back on exactly those ids whose label is still the value this
// run set (the detail view's "Put the labels back"). No snapshot or no receipt → the run refuses
// before changing anything.
//
// OUTCOMES (named, none reads as success unless labels changed and the
// catalog save was acknowledged): shown · stayed(reason) · refused(why) ·
// saveUnconfirmed (labels changed in memory; the debounced save retries; the
// receipt lists them).
//
// Memory: the candidate list is O(labelled records) — about a thousand on
// Rick's catalog; the ledger is read once (≤ 256 MB cap, ~1 MB today).
// (For Rick: `@concurrent` on a `nonisolated static async` func ≈ "run this
// on the worker pool" — without it Swift 6.2 would run it on the caller's
// actor, i.e. the UI thread.)

import Foundation
import os

let showAgainLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "showAgain")

// MARK: - Values

/// One labelled-deleted record as the check sees it (a value: `VideoRecord`
/// is a main-actor class and never crosses to the worker pool).
struct ShowAgainCandidate: Sendable, Equatable, Identifiable, Codable {
    let id: UUID
    let filename: String
    let fullPath: String
    let volumeName: String
    let sizeBytes: Int64
    /// The legacy marker's `since` when the row carries one (the receipt
    /// keeps it so the reverse puts the same marker back); nil = label only.
    var removalSince: Date? = nil
}

extension RemovalMarker {
    /// The marker the GH #143 load migration makes of the old "Manually
    /// Deleted" label: the file was never touched, the row is merely hidden.
    var isLegacyDeletedLabel: Bool { state == .removedFromCatalog && reason == .legacyDeletedLabel }
}

extension VideoRecord {
    /// True when the row's removal marker is the migrated old label (and
    /// nothing else — a real removal never reads true here).
    var hasLegacyDeletedLabelMarker: Bool { removal?.isLegacyDeletedLabel ?? false }
}

/// What one `stat()` said about a path.
enum ShowAgainOnDisk: Sendable, Equatable {
    case file(size: Int64)
    case notAFile
    case missing
    case unreadable(errno: Int32)
}

/// The facts the verdict reads for one candidate.
struct ShowAgainFacts: Sendable, Equatable {
    var hasRemovalReceipt: Bool
    var volumeOnline: Bool
    var onDisk: ShowAgainOnDisk
}

/// Why a candidate stays labelled.
enum ShowAgainStayReason: Sendable, Equatable, Hashable {
    case hasRemovalReceipt
    case noCatalogSize
    case driveNotConnected
    case fileMissing
    case notAFile
    case couldNotCheck
    case sizeChanged
    /// The live record changed between the review and the run (label,
    /// path, size, marker or active state) — or left the catalog.
    case changedSinceReview
    /// The engine's Restore said no (its own words). Never expected for a
    /// removed-from-catalog marker; kept so a refusal is a row, not a crash.
    case restoreRefused(String)

    var words: String {
        switch self {
        case .restoreRefused(let why): return "the catalog's Restore refused: \(why)"
        case .hasRemovalReceipt: return "the ledger says the app moved it to the Trash or deleted it"
        case .noCatalogSize: return "the catalog has no size for it to compare"
        case .driveNotConnected: return "its drive is not connected"
        case .fileMissing: return "file missing at its recorded path"
        case .notAFile: return "something other than a file is at its path"
        case .couldNotCheck: return "its path could not be checked"
        case .sizeChanged: return "the file there is a different size than the catalog's"
        case .changedSinceReview: return "changed in the catalog since the review"
        }
    }
}

enum ShowAgainVerdict: Sendable, Equatable {
    case showAgain
    case stays(ShowAgainStayReason)
}

// MARK: - The criteria (pure)

enum ShowAgainRules {

    /// The label this repair clears, and the value it sets.
    static let falseLabel: ArchiveStage = .manuallyDeleted
    static let liveLabel: ArchiveStage = .none

    /// Rule 1: the old label in either encoding, no REAL removal marker,
    /// not set aside or superseded — the footer caption's population.
    /// `isPurged` first: it is a cached `Date?` load; the marker itself is
    /// read only on the rows that have one (the 100k scale budget).
    @MainActor
    static func isCandidate(_ r: VideoRecord) -> Bool {
        guard !r.isSetAside, !r.isSuperseded else { return false }
        guard r.isPurged else { return r.archiveStage == falseLabel }   // no marker: the label alone hides it
        return r.hasLegacyDeletedLabelMarker                           // the migrated label; anything else is a real removal
    }

    /// The legacy marker's `since` for a candidate row; nil = label only.
    @MainActor
    static func legacyMarkerSince(_ r: VideoRecord) -> Date? {
        guard let m = r.removal, m.isLegacyDeletedLabel else { return nil }
        return m.since
    }

    /// Rules 2 and 3. Receipt first (the strongest stop), then the catalog's
    /// own size, then the disk.
    static func verdict(_ c: ShowAgainCandidate, _ f: ShowAgainFacts) -> ShowAgainVerdict {
        if f.hasRemovalReceipt { return .stays(.hasRemovalReceipt) }
        if c.sizeBytes <= 0 { return .stays(.noCatalogSize) }
        if !f.volumeOnline { return .stays(.driveNotConnected) }
        switch f.onDisk {
        case .missing: return .stays(.fileMissing)
        case .notAFile: return .stays(.notAFile)
        case .unreadable: return .stays(.couldNotCheck)
        case .file(let size): return size == c.sizeBytes ? .showAgain : .stays(.sizeChanged)
        }
    }
}

// MARK: - Removal receipts (the Media Ledger, read strictly)

/// Every Trash / delete receipt in the ledger, by record id and by path.
/// Undecodable lines that mention a removal are kept raw: a candidate whose
/// id or path appears in one is treated as having a receipt.
struct ShowAgainReceipts: Sendable, Equatable {
    var ids: Set<UUID> = []
    var paths: Set<String> = []
    var damagedRemovalLines: [String] = []

    static let removalKinds: Set<MediaLedgerEvent.Kind> = [.copyTrashed, .copyDeleted]

    func covers(_ c: ShowAgainCandidate) -> Bool {
        if ids.contains(c.id) || paths.contains(c.fullPath) { return true }
        guard !damagedRemovalLines.isEmpty else { return false }
        let id = c.id.uuidString.lowercased()
        return damagedRemovalLines.contains { $0.lowercased().contains(id) || $0.contains(c.fullPath) }
    }

    /// Index ledger text. Pure.
    static func index(ledgerText text: String) -> ShowAgainReceipts {
        var out = ShowAgainReceipts()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let e = MediaLedgerEvent.decodeLine(line) {
                guard removalKinds.contains(e.event) else { continue }
                out.ids.insert(e.recordID)
                if !e.fullPath.isEmpty { out.paths.insert(e.fullPath) }
            } else if line.contains("copyTrashed") || line.contains("copyDeleted") {
                out.damagedRemovalLines.append(String(line))
            }
        }
        return out
    }

    /// Read the ledger file. No file yet = no receipts. A file that exists
    /// but cannot be read in full is a refusal, never "no receipts"
    /// (`MediaLedger.events(at:)` would quietly return [] here).
    static func read(ledgerURL url: URL) -> Result<ShowAgainReceipts, ShowAgainRefusal> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(ShowAgainReceipts()) }
        let data: Data
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= MediaLedger.readLimit else {
                return .failure(ShowAgainRefusal("the Media Ledger is larger than \(MediaLedger.readLimit >> 20) MB, so its Trash receipts can't all be read"))
            }
            data = try Data(contentsOf: url)
        } catch {
            return .failure(ShowAgainRefusal("the Media Ledger could not be read (\(error.localizedDescription)), so its Trash receipts can't be checked"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(ShowAgainRefusal("the Media Ledger is not readable text, so its Trash receipts can't be checked"))
        }
        return .success(index(ledgerText: text))
    }
}

struct ShowAgainRefusal: Error, Equatable, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

// MARK: - The disk seam

/// Volume + stat, injectable so tests never touch a real drive.
struct ShowAgainDisk: Sendable {
    var volumeOnline: @Sendable (String) -> Bool
    var stat: @Sendable (String) -> ShowAgainOnDisk

    static let live = ShowAgainDisk(
        volumeOnline: { VolumeReachability.isVolumeReachable(path: $0) },
        stat: { ShowAgainDisk.statPath($0) })

    /// One `stat()` (follows a symlink to what it names). Metadata only:
    /// the file is never opened.
    static func statPath(_ path: String) -> ShowAgainOnDisk { showAgainStat(path) }
}

/// Free function so the syscall `stat` is not shadowed by the seam's
/// `stat` property inside `ShowAgainDisk`.
private func showAgainStat(_ path: String) -> ShowAgainOnDisk {
    var sb = stat()
    guard stat(path, &sb) == 0 else {
        let e = errno
        return (e == ENOENT || e == ENOTDIR) ? .missing : .unreadable(errno: e)
    }
    guard (sb.st_mode & S_IFMT) == S_IFREG else { return .notAFile }
    return .file(size: Int64(sb.st_size))
}

// MARK: - The plan (what the review shows, and what the job re-checks)

struct ShowAgainPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable, Identifiable {
        let candidate: ShowAgainCandidate
        let verdict: ShowAgainVerdict
        var id: UUID { candidate.id }
    }

    let items: [Item]
    /// Non-nil = nothing may change (an unreadable ledger).
    let refusal: String?

    static let empty = ShowAgainPlan(items: [], refusal: nil)

    var toShow: [Item] { items.filter { $0.verdict == .showAgain } }
    var staying: [Item] { items.filter { $0.verdict != .showAgain } }
    var showCount: Int { items.reduce(0) { $0 + ($1.verdict == .showAgain ? 1 : 0) } }
    var showBytes: Int64 {
        items.reduce(Int64(0)) { $0 + ($1.verdict == .showAgain ? $1.candidate.sizeBytes : 0) }
    }

    /// "959 files, 976 GB will be shown again".
    var headline: String {
        let n = showCount
        return "\(n.formatted()) file\(n == 1 ? "" : "s"), \(MediaBytes.display(showBytes)) will be shown again"
    }

    /// Stays, grouped: [(reason, count)], largest first.
    var stayCounts: [(reason: ShowAgainStayReason, count: Int)] {
        var counts: [ShowAgainStayReason: Int] = [:]
        for item in items {
            if case .stays(let why) = item.verdict { counts[why, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    /// "9 stay labelled: file missing at its recorded path (9)".
    var stayLine: String? {
        let groups = stayCounts
        guard !groups.isEmpty else { return nil }
        let n = groups.reduce(0) { $0 + $1.count }
        return "\(n) stay labelled: " + groups.map { "\($0.reason.words) (\($0.count))" }.joined(separator: "; ")
    }

    /// The check, off the main actor: the ledger read once, one `stat` per
    /// candidate, `progress(done, total)` between chunks. Cancellation stops
    /// between chunks (the caller then changes nothing).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func check(_ candidates: [ShowAgainCandidate], ledgerURL: URL, disk: ShowAgainDisk,
                                  progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ShowAgainPlan {
        let receipts: ShowAgainReceipts
        switch ShowAgainReceipts.read(ledgerURL: ledgerURL) {
        case .failure(let r): return ShowAgainPlan(items: [], refusal: r.reason)
        case .success(let index): receipts = index
        }
        var items: [Item] = []
        items.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            if i % 256 == 0 {
                if Task.isCancelled { break }
                progress?(i, candidates.count)
            }
            let receipt = receipts.covers(c)
            // Skip the disk for a record the ledger already rules out.
            let online = receipt ? true : disk.volumeOnline(c.fullPath)
            let onDisk: ShowAgainOnDisk = (receipt || !online) ? .missing : disk.stat(c.fullPath)
            let facts = ShowAgainFacts(hasRemovalReceipt: receipt, volumeOnline: online, onDisk: onDisk)
            items.append(Item(candidate: c, verdict: ShowAgainRules.verdict(c, facts)))
        }
        progress?(items.count, candidates.count)
        return ShowAgainPlan(items: items, refusal: nil)
    }
}

// MARK: - The receipt file (write-ahead, the reverse reads it)

struct ShowAgainReceiptFile: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let id: UUID
        let path: String
        let from: String
        let to: String
        /// The legacy removal marker's `since`, when the run cleared one.
        /// Optional: a receipt written before 2026-10-14 has no such key and
        /// still decodes (the reverse then puts back the label only).
        var removalSince: Date? = nil
    }
    let runID: String
    let writtenAt: Date
    let snapshotPath: String
    let changes: [Change]

    static func encode(_ r: ShowAgainReceiptFile) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(r)
    }

    static func decode(_ data: Data) throws -> ShowAgainReceiptFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(ShowAgainReceiptFile.self, from: data)
    }
}

// MARK: - Log lines (pure words)

enum ShowAgainLines {
    static let prefix = "Show again"

    static func shownLine(_ c: ShowAgainCandidate) -> String {
        let marker = c.removalSince == nil ? "" : "; removal marker (old deleted label) cleared"
        return "[show-again] shown again: \(c.fullPath) id=\(c.id.uuidString) — label \(ShowAgainRules.falseLabel.rawValue) → \(ShowAgainRules.liveLabel.rawValue)\(marker) (on disk at the catalog's size, \(c.sizeBytes) bytes; no Trash receipt)"
    }

    static func stayedLine(_ c: ShowAgainCandidate, _ why: ShowAgainStayReason) -> String {
        "[show-again] left labelled: \(c.fullPath) id=\(c.id.uuidString) — \(why.words)"
    }

    static func revertedLine(path: String, id: UUID, labelPutBack: Bool, markerPutBack: Bool) -> String {
        let marker = markerPutBack ? "; removal marker (old deleted label) put back" : ""
        guard labelPutBack else {
            return "[show-again] put back: \(path) id=\(id.uuidString) — removal marker (old deleted label) put back; no label to put back"
        }
        return "[show-again] label put back: \(path) id=\(id.uuidString) — \(ShowAgainRules.liveLabel.rawValue) → \(ShowAgainRules.falseLabel.rawValue)\(marker)"
    }

    static func outcome(shown: Int, bytes: Int64, stayed: Int) -> String {
        "\(shown.formatted()) shown again (\(MediaBytes.display(bytes))) · \(stayed.formatted()) left labelled"
    }
}

// MARK: - The model half

extension VideoScanModel {

    /// Console + catalog.log (`log`), videoscan.log, unified log — the one
    /// sink for START / progress / OUTCOME lines.
    func showAgainNote(_ line: String) {
        log(line)
        appLog.write("[show-again] " + line)
        showAgainLog.notice("\(line, privacy: .public)")
    }

    /// Rule 1 over the catalog, on the main actor (plain field reads; no I/O).
    func showAgainCandidates() -> [ShowAgainCandidate] {
        var out: [ShowAgainCandidate] = []
        for r in records where ShowAgainRules.isCandidate(r) {
            out.append(ShowAgainCandidate(id: r.id, filename: r.filename, fullPath: r.fullPath,
                                          volumeName: r.volumeName, sizeBytes: r.sizeBytes,
                                          removalSince: ShowAgainRules.legacyMarkerSince(r)))
        }
        return out
    }

    /// The review's dry run: candidates on main, the check off it. Writes
    /// nothing anywhere.
    func showAgainReview(disk: ShowAgainDisk = .live,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ShowAgainPlan {
        let candidates = showAgainCandidates()
        guard !candidates.isEmpty else { return .empty }
        return await ShowAgainPlan.check(candidates, ledgerURL: mediaLedger.fileURL, disk: disk, progress: progress)
    }

    /// Folder for the receipts, beside the catalog (App Support in
    /// production; the sandbox's catalog folder in tests).
    var showAgainReceiptsDirectory: URL {
        URL(fileURLWithPath: (catalogStore.fileLocation as NSString).deletingLastPathComponent, isDirectory: true)
            .appendingPathComponent("label-repairs", isDirectory: true)
    }
}
