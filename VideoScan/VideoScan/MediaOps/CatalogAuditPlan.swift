// CatalogAuditPlan.swift
// "Audit Catalog…" tier 0 — the values and the planner (Rick 2026-10-15/16;
// docs/design/catalog_status_freshness_2026_10_16.md §6, audit_archive §2a).
//
// One sentence: check that every catalog row on a connected drive still
// points at its file, and mark the ones that are gone as Missing.
//
// Shape:
//   • PLAN (this file, main actor, one O(records) pass, no I/O): every live
//     row — no removal marker, or a `.missing` marker that is re-checked
//     for "came back" — grouped into LANES, one per volume root, each lane
//     in path order. Rows In the Trash or Removed from Catalog, superseded
//     rows and rows with no path are SKIPPED and counted. The plan carries
//     the marker each row had when planned: the apply step is compare-and-
//     set on (id, path, marker), so a row rescanned, edited, restored or
//     marked by another door while the stats ran is left alone.
//   • STAT (CatalogAuditStat, below): one `stat(2)` per row, off the main
//     actor; the file is never opened. ENOENT / ENOTDIR → gone; any other
//     errno → could not check (never marked); a path that is no longer a
//     regular file → could not check (a person decides).
//   • APPLY (VideoScanModel+CatalogAudit.swift): the one engine —
//     `stampRemoval(.missing(reason: .missingAtAudit))` for a gone file,
//     `clearRemoval` (validates first) for one that came back.
//   • RUN (CatalogAuditJob.swift): lanes in parallel, chunks of stats,
//     batched acknowledged saves, undo of the unsaved marks on a save that
//     is not acknowledged.
//
// Memory: one `CatalogAuditItem` (~150 bytes) per live record — ~15 MB at
// 100k — plus the per-folder tally of gone rows (one entry per folder that
// lost a file; ≤ the number of gone rows).

import Foundation
import VideoScanCore

// MARK: - Plan (values)

/// One row's question: "is the file still at this path?" together with
/// everything the apply step needs to answer it only for THIS row.
struct CatalogAuditItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let path: String
    /// The catalog's size — "changed" means the size on disk differs.
    let sizeBytes: Int64
    /// The marker the row carried when planned: nil = live; a `.missing`
    /// marker = re-checked for "came back". The compare-and-set key.
    let plannedMarker: RemovalMarker?
    /// An archived row (Master Archive copy) is stat'ed and REPORTED, never
    /// marked: Verify Archive owns the archive's own integrity.
    let isArchived: Bool

    var filename: String { (path as NSString).lastPathComponent }
    var wasMissing: Bool { plannedMarker?.state == .missing }
}

/// One drive's queue, in path order.
struct CatalogAuditLane: Sendable, Equatable {
    /// Volume root ("/Volumes/Archive1", or "/" for this Mac's disk).
    let root: String
    var items: [CatalogAuditItem] = []

    var label: String { FullHashBackfillPlanner.label(forRoot: root) }
}

/// Why a row was not asked at all (counted, never an error).
enum CatalogAuditSkip: String, Sendable, Equatable, CaseIterable {
    case inTrash
    case removedFromCatalog
    case superseded
    case noPath

    var words: String {
        switch self {
        case .inTrash: return "in the Trash"
        case .removedFromCatalog: return "removed from the catalog"
        case .superseded: return "superseded"
        case .noPath: return "without a path"
        }
    }
}

struct CatalogAuditPlan: Sendable, Equatable {
    /// Sorted by root.
    var lanes: [CatalogAuditLane] = []
    var skipped: [CatalogAuditSkip: Int] = [:]
    /// Rows planned that carry a `.missing` marker (re-checked for "came back").
    var missingRecheck = 0

    var rowCount: Int { lanes.reduce(0) { $0 + $1.items.count } }
    var skippedCount: Int { skipped.values.reduce(0, +) }
}

/// Builds the plan in one pass. Main actor because it reads live records.
@MainActor
enum CatalogAuditPlanner {

    static func plan(records: [VideoRecord]) -> CatalogAuditPlan {
        var plan = CatalogAuditPlan()
        var byRoot: [String: CatalogAuditLane] = [:]
        for r in records {
            if let skip = skipReason(r) {
                plan.skipped[skip, default: 0] += 1
                continue
            }
            if r.removal?.state == .missing { plan.missingRecheck += 1 }
            let root = MediaVolumeGatePolicy.volumeRoot(forPath: r.fullPath)
            byRoot[root, default: CatalogAuditLane(root: root)].items.append(
                CatalogAuditItem(id: r.id, path: r.fullPath, sizeBytes: r.sizeBytes,
                                 plannedMarker: r.removal, isArchived: isArchived(r)))
        }
        plan.lanes = byRoot.values
            .map { lane in
                var sorted = lane
                sorted.items.sort { $0.path < $1.path }
                return sorted
            }
            .sorted { $0.root < $1.root }
        return plan
    }

    /// nil = the row is asked. The order is the rule: a marker other than
    /// Missing means the file left through a door that already knows.
    static func skipReason(_ r: VideoRecord) -> CatalogAuditSkip? {
        switch r.removal?.state {
        case .inTrash: return .inTrash
        case .removedFromCatalog: return .removedFromCatalog
        case .missing, .none: break
        }
        if r.isSuperseded { return .superseded }
        if r.fullPath.isEmpty { return .noPath }
        return nil
    }

    /// CheckCopies' "left alone" rule: an archive copy carries its archive
    /// fixity or the promoted derivation kind.
    static func isArchived(_ r: VideoRecord) -> Bool {
        r.archiveFixity != nil || r.derivationKind == ArchivePromotion.derivationKind
    }
}

// MARK: - Stat (one syscall, no open)

/// What `stat(2)` said about one path. Pure value; the stat itself is the
/// only I/O the audit does.
enum CatalogAuditStat: Sendable, Equatable {
    case file(size: Int64)
    /// ENOENT or ENOTDIR: nothing is at the path (the drive is still asked
    /// about separately — an unmounted root makes every path look gone).
    case gone
    /// A directory, device, socket… where a file was. Never marked.
    case notAFile
    /// Any other errno (EACCES, EIO, ETIMEDOUT…). Never marked.
    case unreadable(errno: Int32)

    /// One `stat()` — metadata only; the file is never opened. Follows a
    /// symlink to what it names, as the scan did.
    /// (For Rick: `stat()` here is the libc call; the enum is the result
    /// decoded once so no caller re-reads errno.)
    static func of(_ path: String) -> CatalogAuditStat {
        var sb = stat()
        guard stat(path, &sb) == 0 else {
            let e = errno
            return (e == ENOENT || e == ENOTDIR) ? .gone : .unreadable(errno: e)
        }
        guard (sb.st_mode & S_IFMT) == S_IFREG else { return .notAFile }
        return .file(size: Int64(sb.st_size))
    }
}

// MARK: - Results (values)

/// What happened to one row — the detail list's row and the tally's key.
/// The §6 outcomes, plus three the run needs to be honest about:
/// `stillMissing` (a Missing row whose file is still gone — no new mark),
/// `goneArchived` (an archive copy's file is gone — reported, never marked)
/// and `recordChanged` (the row moved or changed while the stat ran — the
/// result is dropped).
enum CatalogAuditResult: String, Sendable, Equatable, CaseIterable {
    case present
    case changed
    case gone
    case cameBack
    case stillMissing
    case goneArchived
    case notAsked
    case couldNotCheck
    case recordChanged

    /// Plain words for the detail row and the summary line.
    var words: String {
        switch self {
        case .present: return "present"
        case .changed: return "changed size (reported, not marked)"
        case .gone: return "gone — marked Missing"
        case .cameBack: return "came back — live again"
        case .stillMissing: return "still missing"
        case .goneArchived: return "archived copy gone (reported, not marked)"
        case .notAsked: return "not asked (drive not connected)"
        case .couldNotCheck: return "could not check"
        case .recordChanged: return "changed in the catalog meanwhile"
        }
    }

    /// Results that change a catalog row (through the one engine).
    var isMark: Bool { self == .gone || self == .cameBack }
    /// Results that need a person to look — the Catalog Status band's red.
    var needsAPerson: Bool {
        switch self {
        case .gone, .goneArchived, .changed, .couldNotCheck: return true
        case .present, .cameBack, .stillMissing, .notAsked, .recordChanged: return false
        }
    }
}

struct CatalogAuditRow: Identifiable, Sendable, Equatable {
    let id: Int
    let filename: String
    let path: String
    let drive: String
    let result: CatalogAuditResult
    let detail: String
}

/// One drive's row in the detail.
struct CatalogAuditLaneStatus: Identifiable, Sendable, Equatable {
    enum Phase: String, Sendable { case waiting, checking, finished, disconnected, stopped }
    var id: String { root }
    let root: String
    let label: String
    let planned: Int
    var done = 0
    var phase: Phase = .waiting
}

struct CatalogAuditTotals: Sendable, Equatable {
    var planned = 0
    var skipped: [CatalogAuditSkip: Int] = [:]
    var missingRecheck = 0
    /// Rows resolved, whatever the outcome (the "N" of "N of M").
    var done = 0
    var counts: [CatalogAuditResult: Int] = [:]
    /// Folder → how many of its files were found gone (for the OUTCOME's
    /// "3 gone under …"). Archived copies count here too.
    var goneFolders: [String: Int] = [:]

    subscript(_ r: CatalogAuditResult) -> Int { counts[r] ?? 0 }
    var skippedCount: Int { skipped.values.reduce(0, +) }
    /// Rows the run changed (marked Missing or restored).
    var marked: Int { self[.gone] + self[.cameBack] }

    mutating func add(_ r: CatalogAuditResult, rows n: Int = 1) {
        counts[r, default: 0] += n
        done += n
    }

    mutating func noteGone(path: String) {
        goneFolders[(path as NSString).deletingLastPathComponent, default: 0] += 1
    }

    /// The folders that lost the most files, most first; ties by name.
    func topFolders(_ limit: Int = 3) -> [(folder: String, count: Int)] {
        goneFolders.map { (folder: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.folder < $1.folder }
            .prefix(limit)
            .map { $0 }
    }

    /// "9,812 of 9,815 present · 3 gone — marked Missing · 1 changed size … · 12 skipped (in the Trash)"
    var line: String {
        var parts = ["\(self[.present].formatted()) of \(planned.formatted()) present"]
        for r in CatalogAuditResult.allCases where r != .present && self[r] > 0 {
            parts.append("\(self[r].formatted()) \(r.words)")
        }
        if skippedCount > 0 { parts.append("\(skippedCount.formatted()) skipped (\(skippedWords))") }
        return parts.joined(separator: " · ")
    }

    /// "in the Trash 10, superseded 2"
    var skippedWords: String {
        CatalogAuditSkip.allCases.compactMap { s -> String? in
            guard let n = skipped[s], n > 0 else { return nil }
            return "\(s.words) \(n.formatted())"
        }.joined(separator: ", ")
    }

    /// The OUTCOME's tail: "3 gone under /Volumes/Projects/_staging" per
    /// folder, most first. Empty when nothing is gone.
    var goneFoldersClause: String {
        let top = topFolders()
        guard !top.isEmpty else { return "" }
        var clause = top.map { "\($0.count.formatted()) gone under \($0.folder)" }.joined(separator: "; ")
        let shown = top.reduce(0) { $0 + $1.count }
        let total = goneFolders.values.reduce(0, +)
        if total > shown { clause += "; \((total - shown).formatted()) more in \((goneFolders.count - top.count).formatted()) other folder(s)" }
        return clause
    }

    /// "1,204 of 9,815 · 2 drives · Archive1 · ~12 s left"
    func progressLine(checking: [String], elapsed: TimeInterval) -> String {
        var parts = ["\(done.formatted()) of \(planned.formatted())"]
        if !checking.isEmpty { parts.append("\(checking.count) drive\(checking.count == 1 ? "" : "s") checking") }
        if let first = checking.first { parts.append(checking.count > 1 ? "\(first) +\(checking.count - 1)" : first) }
        guard elapsed > 2, done > 0 else { return parts.joined(separator: " · ") }
        let rate = Double(done) / elapsed
        parts.append(FullHashBackfillTotals.timeLeft(Double(max(0, planned - done)) / rate))
        return parts.joined(separator: " · ")
    }
}
