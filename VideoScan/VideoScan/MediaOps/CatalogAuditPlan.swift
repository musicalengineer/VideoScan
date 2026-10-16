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
//     rows and rows with no path are SKIPPED and counted. Each item carries
//     a SNAPSHOT of the row's fields that matter (path, size, marker,
//     lifecycle, archive stage and fixity, hash time, mtime): the apply
//     step is compare-and-set on the whole snapshot, so a row rescanned,
//     edited, restored or marked by another door while the stats ran is
//     left alone.
//   • ANCHOR (CatalogAuditMountIdentity, below; the job does it per lane,
//     off the main actor, before the lane's first stat): for each item the
//     identity of the filesystem the file is EXPECTED on — `statfs` of the
//     nearest existing ancestor after resolving symlinks in the parent.
//     Not the lexical root: a path through a symlink onto an external
//     drive, or a mount outside /Volumes, lives on another filesystem than
//     "/". nil when it cannot be established → the row can never be marked.
//   • STAT (CatalogAuditStat, below): one `stat(2)` per row, off the main
//     actor; the file is never opened. ENOENT / ENOTDIR → gone; any other
//     errno → could not check (never marked); a path that is no longer a
//     regular file → could not check (a person decides). This is the cheap
//     FIRST PASS; it decides nothing.
//   • PROVE AT THE MARK (CatalogAuditProof, below; codex 2026-10-16 F1/F2):
//     for every gone answer — and only those, they are few — the apply
//     step re-stats the file SYNCHRONOUSLY on the main actor just before
//     marking, and accepts ENOENT only if the nearest existing ancestor
//     still resolves onto the SAME filesystem the plan anchored (same
//     fsid, same mount-on name). Present now → present; any other errno →
//     could not check; another filesystem (the drive left and the path
//     fell through to "/", the link's target moved) → could not check,
//     "drive not connected". A row is marked gone only on evidence read at
//     the moment of marking, on the filesystem the file was expected on.
//   • APPLY (VideoScanModel+CatalogAudit.swift): the one engine —
//     `stampRemoval(.missing(reason: .missingAtAudit))` for a proven-gone
//     file, `clearRemoval` (validates first) for one that came back.
//   • RUN (CatalogAuditJob.swift): lanes in parallel, chunks of stats,
//     batched acknowledged saves, undo of the unsaved marks on a save that
//     is not acknowledged.
//
// Memory: one `CatalogAuditItem` (~250 bytes with its snapshot) per live
// record — ~25 MB at 100k — plus the per-folder tally of gone rows (one
// entry per folder that lost a file; ≤ the number of gone rows).

import Foundation
import VideoScanCore

// MARK: - Plan (values)

/// The fields of a row the apply step compares, planned against live
/// (codex 2026-10-16 F3). Any difference means another door touched the
/// row while the stats ran, and the result is dropped as "record changed".
/// Id and path alone are not enough: Trash → Put Back → Restore returns
/// the marker to nil; archive fixity set meanwhile makes the row an
/// archive copy.
struct CatalogAuditRowSnapshot: Sendable, Equatable {
    let path: String
    let sizeBytes: Int64
    let removal: RemovalMarker?
    let lifecycleStage: LifecycleStage
    let archiveStage: ArchiveStage
    let hasArchiveFixity: Bool
    let derivationKind: String?
    let contentHashAt: Date?
    let dateModified: String

    /// (For Rick: a value copy of the fields, taken at plan time and again
    /// at apply time; `==` is the whole compare-and-set key.)
    static func of(_ r: VideoRecord) -> CatalogAuditRowSnapshot {
        CatalogAuditRowSnapshot(path: r.fullPath, sizeBytes: r.sizeBytes, removal: r.removal,
                                lifecycleStage: r.lifecycleStage, archiveStage: r.archiveStage,
                                hasArchiveFixity: r.archiveFixity != nil, derivationKind: r.derivationKind,
                                contentHashAt: r.contentHashAt, dateModified: r.dateModified)
    }
}

/// One row's question: "is the file still at this path?" together with
/// everything the apply step needs to answer it only for THIS row.
/// Carries nothing the apply step must not trust: whether the row is an
/// archive copy is read from the LIVE record at apply time.
struct CatalogAuditItem: Sendable, Equatable, Identifiable {
    let id: UUID
    /// The lane's volume root — the lexical rule ("/Volumes/X" or "/").
    let root: String
    /// The row as planned: the compare-and-set key.
    let planned: CatalogAuditRowSnapshot
    /// The filesystem the file is expected on, anchored before the lane's
    /// first stat. nil = could not be established (a dangling link in the
    /// parent chain, a parent folder that is not there under "/", an
    /// ancestor off the lane's root) — the row is then never marked.
    var expectedMount: CatalogAuditMountIdentity?

    var path: String { planned.path }
    /// The catalog's size — "changed" means the size on disk differs.
    var sizeBytes: Int64 { planned.sizeBytes }
    /// The marker the row carried when planned: nil = live; a `.missing`
    /// marker = re-checked for "came back".
    var plannedMarker: RemovalMarker? { planned.removal }
    var filename: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
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
                CatalogAuditItem(id: r.id, root: root, planned: .of(r)))
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
    /// fixity or the promoted derivation kind. Read from the LIVE record at
    /// apply time, never from the plan.
    static func isArchived(_ r: VideoRecord) -> Bool {
        r.archiveFixity != nil || r.derivationKind == ArchivePromotion.derivationKind
    }
}

// MARK: - Mount identity (which filesystem a path is really on)

/// What `statfs(2)` says a path is on: the filesystem id, where it is
/// mounted and what is mounted there. Two reads are the same filesystem
/// when all three agree. (For Rick: `f_fsid` ≈ a device id; `f_mntonname`
/// is the mount point; `f_mntfromname` is the device or share.)
struct CatalogAuditMountIdentity: Sendable, Equatable {
    let fsid0: Int32
    let fsid1: Int32
    let mountOn: String
    let mountFrom: String

    var words: String { "\(mountFrom) on \(mountOn)" }

    /// True when this filesystem is mounted at `root` or below it.
    func isMounted(atOrUnder root: String) -> Bool {
        root == "/" || mountOn == root || mountOn.hasPrefix(root + "/")
    }

    /// `statfs` of an existing path (nil when it is not there or cannot be
    /// read). No disk I/O beyond the kernel's mount table.
    static func of(_ path: String) -> CatalogAuditMountIdentity? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let on = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return CatalogAuditMountIdentity(fsid0: fs.f_fsid.val.0, fsid1: fs.f_fsid.val.1, mountOn: on, mountFrom: from)
    }

    /// The filesystem a file in `directory` is EXPECTED on (codex 2026-10-16
    /// F1): `statfs` of the nearest existing ancestor after resolving the
    /// symlinks in the parent chain. nil — "cannot be established; never
    /// mark" — when:
    ///   • a dangling symlink sits in the chain (the drive behind the link
    ///     is not connected; what is beyond it is unknown);
    ///   • the lane root is "/" and the parent folder itself is not there
    ///     (an unmounted mount point outside /Volumes looks exactly like a
    ///     deleted folder — refuse over guess);
    ///   • the lane root is a /Volumes root and the ancestor is not on a
    ///     filesystem mounted at or under it (the drive left and the path
    ///     fell through to the system disk).
    /// Under a mounted /Volumes root a missing parent folder IS provable:
    /// the ancestor is on that drive, so the folder is gone from it.
    static func expected(forDirectory directory: String, root: String) -> CatalogAuditMountIdentity? {
        guard let ancestor = nearestExistingAncestor(of: directory), let identity = of(ancestor.resolved) else { return nil }
        if root == "/" { return ancestor.isTheFolder ? identity : nil }
        return identity.isMounted(atOrUnder: root) ? identity : nil
    }

    /// Walks up from `directory` until `realpath` succeeds. nil when a
    /// component on the way is a symlink that leads nowhere.
    private static func nearestExistingAncestor(of directory: String) -> (resolved: String, isTheFolder: Bool)? {
        var dir = directory.isEmpty ? "/" : directory
        var isTheFolder = true
        while true {
            if let resolved = realpathString(dir) { return (resolved, isTheFolder) }
            if dir == "/" || isSymlink(dir) { return nil }
            let parent = (dir as NSString).deletingLastPathComponent
            dir = parent.isEmpty ? "/" : parent
            isTheFolder = false
        }
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `lstat`: the link itself, not what it names.
    private static func isSymlink(_ path: String) -> Bool {
        var sb = stat()
        return lstat(path, &sb) == 0 && (sb.st_mode & S_IFMT) == S_IFLNK
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

// MARK: - Proof at the mark (the second look)

/// The second look, taken SYNCHRONOUSLY at the moment of marking (codex
/// 2026-10-16 F1/F2). The chunk's stat was the cheap first pass; this
/// decides. Order matters: the file is stat'ed FIRST, and only an ENOENT
/// read now is followed by the mount read — a drive that leaves between
/// the two reads as a different filesystem, which is the safe side.
enum CatalogAuditProof: Sendable, Equatable {
    /// ENOENT / ENOTDIR again, on the filesystem the plan anchored.
    case gone
    /// The second stat did not say ENOENT: present (any size), not a
    /// regular file, or an errno — whatever it said stands.
    case notGone(CatalogAuditStat)
    /// ENOENT, but the path no longer leads to the expected filesystem (or
    /// none was anchored): the drive is not connected, the link moved.
    case driveNotConnected(expected: CatalogAuditMountIdentity?, now: CatalogAuditMountIdentity?)

    static func atTheMark(_ item: CatalogAuditItem) -> CatalogAuditProof {
        let second = CatalogAuditStat.of(item.path)
        guard second == .gone else { return .notGone(second) }
        let now = CatalogAuditMountIdentity.expected(forDirectory: item.directory, root: item.root)
        guard let expected = item.expectedMount, now == expected else {
            return .driveNotConnected(expected: item.expectedMount, now: now)
        }
        return .gone
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
