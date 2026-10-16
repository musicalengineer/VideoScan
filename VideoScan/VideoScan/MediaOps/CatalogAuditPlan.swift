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
//     lifecycle, archive stage and fixity, derivation, supersession, hash
//     time, mtime, the where-seen stamp): the apply step is compare-and-set
//     on the whole snapshot, so a row rescanned, edited, restored, marked
//     or superseded by another door while the stats ran is left alone.
//   • STAT (CatalogAuditStat, below): one `stat(2)` per row, off the main
//     actor; the file is never opened. ENOENT / ENOTDIR → gone; any other
//     errno → could not check (never marked); a path that is no longer a
//     regular file → could not check (a person decides). This is the cheap
//     FIRST PASS; it decides nothing. For every row it finds PRESENT the
//     same pass reads WHERE the file is (CatalogAuditDirectoryWalk.seenOn):
//     the file's folder is opened as a DIRECTORY handle, the identity of
//     the volume it is on is read through that handle (`fstatfs` + the
//     volume's persistent UUID, `fgetattrlist`), and the name is read
//     through the same handle; a file found that way is STAMPED
//     (`VideoRecord.auditSeenOn`) at apply time.
//   • THE ONE PROOF RULE (codex r3 2026-10-16 F1, D5): a file is provably
//     gone ONLY when the folder it is not in is on the volume the file was
//     LAST SEEN on — the handle's volume UUID equals the row's stamp. No
//     stamp → "never seen by an audit" (never marked; Fix Links decides).
//     A different volume → could not check ("drive not connected?"): an
//     unmounted drive's stub folder, a nested volume that left, a relocated
//     home all read ENOENT on SOME volume, never on the one the file was
//     seen on. Nothing is inferred from the lane root or from what a
//     folder holds: the lane root's mount check is only the cheap "not
//     asked" skip for a drive that is not connected.
//   • PROVE AT THE MARK (CatalogAuditProof + CatalogAuditDirectoryWalk,
//     below; codex 2026-10-16 F1/F2, r2 F2, r3 F2): for every gone answer —
//     and only those, they are few — the apply step walks the path again
//     SYNCHRONOUSLY on the main actor just before marking, BOUND TO A
//     DIRECTORY HANDLE. First every EXISTING component of the path is
//     looked at lexically with `lstat`: a symlink ANYWHERE (an
//     intermediate one too — `/var` → `/private/var`) → could not check,
//     "a link in the path" (D6). Then the nearest existing ancestor folder
//     is opened read-only (O_DIRECTORY | O_NOFOLLOW), the remaining folders
//     walked one `openat` at a time, the name read with `fstatat(…,
//     AT_SYMLINK_NOFOLLOW)`; after an ENOENT the handle must STILL be the
//     directory its pathname names (`fstat(fd)` dev+ino == `lstat(path)`
//     dev+ino) — a folder renamed away and replaced between the open and
//     the lookup → could not check, "the folder changed under the audit".
//     The declared residual: a file arriving after the observation, or a
//     folder replaced and replaced BACK between two syscalls (two renames
//     by an outside actor inside that window) — the next run restores it.
//     This directory handle is the ONE declared exception to "nothing
//     opened" (MOPS-14): a folder, read-only, never a media file;
//     CatalogAuditJobSensorTests pins the calls to this file.
//   • APPLY (VideoScanModel+CatalogAudit.swift): the one engine —
//     `stampRemoval(.missing(reason: .missingAtAudit))` for a proven-gone
//     file, `clearRemoval` (validates first) for one that came back — and
//     the stamp for a present one.
//   • RUN (CatalogAuditJob.swift): lanes in parallel, chunks of stats,
//     batched acknowledged saves (marks every 25 rows or 60 s; stamps on
//     the clock, at lane end and run end — never per row), undo of the
//     unsaved marks on a save that is not acknowledged.
//
// Memory: one `CatalogAuditItem` (~300 bytes with its snapshot) per live
// record — ~30 MB at 100k — plus the per-folder tally of gone rows (one
// entry per folder that lost a file; ≤ the number of gone rows).

import Foundation
import VideoScanCore

// MARK: - Plan (values)

/// The fields of a row the apply step compares, planned against live
/// (codex 2026-10-16 F3; r2 F3 adds supersession; r3 D5 the stamp). Any
/// difference means another door touched the row while the stats ran, and
/// the result is dropped as "record changed". Id and path alone are not
/// enough: Trash → Put Back → Restore returns the marker to nil; archive
/// fixity set meanwhile makes the row an archive copy; Repair supersedes a
/// row the plan skipped only if it was superseded when planned.
struct CatalogAuditRowSnapshot: Sendable, Equatable {
    let path: String
    let sizeBytes: Int64
    let removal: RemovalMarker?
    let lifecycleStage: LifecycleStage
    let archiveStage: ArchiveStage
    let hasArchiveFixity: Bool
    let derivationKind: String?
    let supersededByID: UUID?
    let contentHashAt: Date?
    let dateModified: String
    let auditSeenOn: AuditSeenOn?

    /// (For Rick: a value copy of the fields, taken at plan time and again
    /// at apply time; `==` is the whole compare-and-set key.)
    static func of(_ r: VideoRecord) -> CatalogAuditRowSnapshot {
        CatalogAuditRowSnapshot(path: r.fullPath, sizeBytes: r.sizeBytes, removal: r.removal,
                                lifecycleStage: r.lifecycleStage, archiveStage: r.archiveStage,
                                hasArchiveFixity: r.archiveFixity != nil, derivationKind: r.derivationKind,
                                supersededByID: r.supersededByID,
                                contentHashAt: r.contentHashAt, dateModified: r.dateModified,
                                auditSeenOn: r.auditSeenOn)
    }
}

/// One row's question: "is the file still at this path?" together with
/// everything the apply step needs to answer it only for THIS row.
/// Carries nothing the apply step must not trust: whether the row is an
/// archive copy, and where the file was last seen, are read from the LIVE
/// record at apply time.
struct CatalogAuditItem: Sendable, Equatable, Identifiable {
    let id: UUID
    /// The lane's volume root — the lexical rule ("/Volumes/X" or "/").
    let root: String
    /// The row as planned: the compare-and-set key.
    let planned: CatalogAuditRowSnapshot

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

    /// The production lane rule: "/Volumes/X" or "/". Tests pass a rule
    /// that makes a sandbox folder a lane root of its own.
    static let productionLaneRoot: @Sendable (String) -> String = { MediaVolumeGatePolicy.volumeRoot(forPath: $0) }

    static func plan(records: [VideoRecord],
                     laneRoot: @Sendable (String) -> String = CatalogAuditPlanner.productionLaneRoot) -> CatalogAuditPlan {
        var plan = CatalogAuditPlan()
        var byRoot: [String: CatalogAuditLane] = [:]
        for r in records {
            if let skip = skipReason(r) {
                plan.skipped[skip, default: 0] += 1
                continue
            }
            if r.removal?.state == .missing { plan.missingRecheck += 1 }
            let root = laneRoot(r.fullPath)
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

// MARK: - Mount identity (which volume an open folder is really on)

/// What the kernel says an OPEN directory handle is on: the filesystem id,
/// where it is mounted, what is mounted there (`fstatfs`) and the volume's
/// PERSISTENT UUID (`fgetattrlist ATTR_VOL_UUID`, through `VolumeIdentity`
/// — the same value Finder, `diskutil` and the fixity stamps use; survives
/// a remount, unlike `f_fsid` / `st_dev`). The UUID is the key the proof
/// compares; the rest is for the words. (For Rick: `f_mntonname` is the
/// mount point; `f_mntfromname` is the device or share.)
struct CatalogAuditMountIdentity: Sendable, Equatable {
    let fsid0: Int32
    let fsid1: Int32
    let mountOn: String
    let mountFrom: String
    /// nil = the filesystem reports no UUID (some network shares): nothing
    /// on it can be stamped, so nothing on it is ever provably gone.
    let volumeUUID: String?

    var words: String { "\(mountFrom) on \(mountOn)" + (volumeUUID.map { " [\($0)]" } ?? " [no volume UUID]") }

    /// `fstatfs` + the volume UUID of an open directory handle: the volume
    /// the handle is bound to, whatever the path says now (codex r2 F2).
    static func of(fd: Int32) -> CatalogAuditMountIdentity? {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        let on = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return CatalogAuditMountIdentity(fsid0: fs.f_fsid.val.0, fsid1: fs.f_fsid.val.1, mountOn: on, mountFrom: from,
                                         volumeUUID: VolumeIdentity.uuid(forDescriptor: fd, path: nil))
    }

    /// The stamp a file found through this handle gets; nil when the
    /// volume has no UUID (no stamp — D5).
    func seenOn(at now: Date) -> AuditSeenOn? {
        volumeUUID.map { AuditSeenOn(volumeUUID: $0, mountFrom: mountFrom, seenAt: now) }
    }
}

// MARK: - Stat (one syscall, no open)

/// What `stat(2)` said about one path. Pure value; the stat itself is the
/// only I/O the first pass does on the file's own path.
enum CatalogAuditStat: Sendable, Equatable {
    case file(size: Int64)
    /// ENOENT or ENOTDIR: nothing is at the path (the drive is still asked
    /// about separately — an unmounted root makes every path look gone).
    case gone
    /// A directory, device, socket, link… where a file was. Never marked.
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

/// The first pass's answer for one row: the stat, and — for a file the
/// directory handle found — where it is (the stamp to write). Pure value.
struct CatalogAuditObservation: Sendable, Equatable {
    let stat: CatalogAuditStat
    let seenOn: AuditSeenOn?
}

// MARK: - The directory-handle walk (bound to an fd)

/// What the fd-bound walk found. Pure value.
enum CatalogAuditWalk: Sendable, Equatable {
    /// The name is there: a regular file (with its size), or something
    /// else — with the identity of the volume the handle is on (nil when
    /// it could not be read).
    case found(CatalogAuditStat, on: CatalogAuditMountIdentity?)
    /// ENOENT / ENOTDIR read THROUGH the handle, bound to the identity of
    /// the volume the handle is open on, the handle still naming its path.
    case gone(on: CatalogAuditMountIdentity)
    /// A symlink anywhere in the path (D6). Not provable.
    case link
    /// After the ENOENT the handle no longer IS the directory its pathname
    /// names (renamed away and replaced between the open and the lookup).
    /// Not provable (D6).
    case changedUnderTheAudit
    /// The lane root itself could not be opened (ENOENT: the drive left).
    case rootNotThere
    /// Any other errno, or the handle's identity could not be read.
    case unreadable(errno: Int32)
}

/// The ONE declared exception to "nothing opened" (MOPS-14): a FOLDER
/// handle, read-only, never a media file. Every open here carries
/// `directoryFlags`; the name itself is read with the link not followed.
/// (For Rick: openat/fstatat are the *at() family — paths relative to an
/// open directory fd, so the kernel resolves each step against the folder
/// we already hold, not against a pathname something could retarget.)
enum CatalogAuditDirectoryWalk {

    static let directoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// TEST SEAM (D6) — task-local, never process-global: runs between the
    /// handle reaching the file's folder and the name being read, so a
    /// test can rename the folder away and put another at its path. nil in
    /// production.
    @TaskLocal static var beforeTheNameIsReadForTesting: (@Sendable () -> Void)?

    private enum Opened { case opened(fd: Int32, path: String, depth: Int), failed(CatalogAuditWalk) }
    private enum Descent { case reached, gone, failed(CatalogAuditWalk) }
    private enum Named { case found(CatalogAuditStat), gone, failed(CatalogAuditWalk) }

    /// THE SECOND LOOK: walk `root`/…/`directory`/`filename` through
    /// directory handles. Every handle is closed before returning, on every
    /// path.
    static func prove(directory: String, filename: String, root: String) -> CatalogAuditWalk {
        guard let folders = folders(of: directory, below: root) else { return .unreadable(errno: EINVAL) }
        if let refusal = linkInTheExistingPath(root: root, folders: folders) { return refusal }
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } }
        var handlePath: String
        switch openNearestExistingAncestor(root: root, folders: folders) {
        case .opened(let opened, let path, let depth):
            fd = opened
            handlePath = path
            switch descend(&fd, &handlePath, through: folders[depth...]) {
            case .reached: break
            case .gone: return goneThrough(fd, named: handlePath)
            case .failed(let walk): return walk
            }
        case .failed(let walk): return walk
        }
        beforeTheNameIsReadForTesting?()
        switch statName(filename, in: fd) {
        case .found(let stat): return .found(stat, on: CatalogAuditMountIdentity.of(fd: fd))
        case .gone: return goneThrough(fd, named: handlePath)
        case .failed(let walk): return walk
        }
    }

    /// THE FIRST PASS'S "where is it": one handle on `directory`, the
    /// volume identity read through it, each name read through it. The
    /// stamp for every name found as a regular file that way; nil for the
    /// others (no stamp: a link in the path, a folder that is not there, a
    /// name that is not a regular file through the handle, a volume with
    /// no UUID). Off the main actor; no pathname is trusted twice.
    static func seenOn(directory: String, filenames: [String], root: String, now: Date) -> [AuditSeenOn?] {
        let none = [AuditSeenOn?](repeating: nil, count: filenames.count)
        guard let folders = folders(of: directory, below: root),
              linkInTheExistingPath(root: root, folders: folders) == nil,
              case .opened(let fd, _, let depth) = openNearestExistingAncestor(root: root, folders: folders) else { return none }
        defer { close(fd) }
        guard depth == folders.count, let stamp = CatalogAuditMountIdentity.of(fd: fd)?.seenOn(at: now) else { return none }
        return filenames.map { name in
            if case .found(.file) = statName(name, in: fd) { return stamp }
            return nil
        }
    }

    /// The folders of `directory` below `root`, lexically. nil when the
    /// directory is not under the root, or a component would step out of
    /// it ("." / "..").
    static func folders(of directory: String, below root: String) -> [String]? {
        let dir = directory.isEmpty ? "/" : directory
        if dir == root { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard dir.hasPrefix(prefix) else { return nil }
        let parts = dir.dropFirst(prefix.count).split(separator: "/").map(String.init)
        return parts.contains { $0 == "." || $0 == ".." } ? nil : parts
    }

    /// D6 (codex r3 F2): every EXISTING component of `root/folders`, in
    /// order, looked at with the link NOT followed — a symlink anywhere
    /// (`/var` → `/private/var` included) is "a link in the path", not
    /// provable. Stops at the first component that is not there (the
    /// remainder is the handle walk's). Any other errno → unreadable.
    private static func linkInTheExistingPath(root: String, folders: [String]) -> CatalogAuditWalk? {
        for k in 0...folders.count {
            var sb = stat()
            guard lstat(pathOf(root, folders[..<k]), &sb) == 0 else {
                let e = errno
                return (e == ENOENT || e == ENOTDIR) ? nil : .unreadable(errno: e)
            }
            if (sb.st_mode & S_IFMT) == S_IFLNK { return .link }
        }
        return nil
    }

    /// Opens the deepest `root/folders[0..<k]` that is there, trying the
    /// whole directory first and walking up. Each open is O_NOFOLLOW on
    /// its last component: landing on a symlink is refused (ELOOP).
    private static func openNearestExistingAncestor(root: String, folders: [String]) -> Opened {
        var k = folders.count
        while k >= 0 {
            let path = pathOf(root, folders[..<k])
            let fd = open(path, directoryFlags)
            let e = errno
            if fd >= 0 { return .opened(fd: fd, path: path, depth: k) }
            switch e {
            case ENOENT, ENOTDIR: k -= 1
            case ELOOP: return .failed(.link)
            default: return .failed(.unreadable(errno: e))
            }
        }
        return .failed(.rootNotThere)
    }

    private static func pathOf(_ root: String, _ folders: ArraySlice<String>) -> String {
        guard !folders.isEmpty else { return root }
        return (root.hasSuffix("/") ? root : root + "/") + folders.joined(separator: "/")
    }

    /// From an open ancestor, one `openat` per remaining folder; the
    /// previous handle is closed as the walk moves down and `handlePath`
    /// follows it. A folder that will not open as a directory (ENOENT /
    /// ENOTDIR — on Darwin a symlink refused by O_NOFOLLOW | O_DIRECTORY
    /// reads ENOTDIR, not ELOOP) is looked at through the handle, link
    /// not followed, before it counts as gone.
    private static func descend(_ fd: inout Int32, _ handlePath: inout String, through folders: ArraySlice<String>) -> Descent {
        for name in folders {
            let next = openat(fd, name, directoryFlags)
            let e = errno
            if next >= 0 {
                close(fd)
                fd = next
                handlePath = (handlePath.hasSuffix("/") ? handlePath : handlePath + "/") + name
                continue
            }
            switch e {
            case ENOENT, ENOTDIR:
                if let failure = whatIsThere(name, in: fd) { return .failed(failure) }
                return .gone
            case ELOOP: return .failed(.link)
            default: return .failed(.unreadable(errno: e))
            }
        }
        return .reached
    }

    /// A folder that would not open: nil = nothing is there (gone); `.link`
    /// = a symlink sits where the folder was (not provable); anything else
    /// there (a file where a folder was) → not a folder, never gone.
    private static func whatIsThere(_ name: String, in fd: Int32) -> CatalogAuditWalk? {
        var sb = stat()
        guard fstatat(fd, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else {
            let e = errno
            return (e == ENOENT || e == ENOTDIR) ? nil : .unreadable(errno: e)
        }
        return (sb.st_mode & S_IFMT) == S_IFLNK ? .link : .unreadable(errno: ENOTDIR)
    }

    /// The name itself, through the handle, the link not followed: a link
    /// where a file was is "not a regular file", never gone.
    private static func statName(_ name: String, in fd: Int32) -> Named {
        var sb = stat()
        guard fstatat(fd, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else {
            let e = errno
            return (e == ENOENT || e == ENOTDIR) ? .gone : .failed(.unreadable(errno: e))
        }
        guard (sb.st_mode & S_IFMT) == S_IFREG else { return .found(.notAFile) }
        return .found(.file(size: Int64(sb.st_size)))
    }

    /// ENOENT through `fd`: bound to the handle's identity, read now — and
    /// only while the handle still IS the directory `path` names (D6).
    private static func goneThrough(_ fd: Int32, named path: String) -> CatalogAuditWalk {
        guard let on = CatalogAuditMountIdentity.of(fd: fd) else { return .unreadable(errno: errno) }
        guard stillNames(path, fd) else { return .changedUnderTheAudit }
        return .gone(on: on)
    }

    /// `fstat(fd)` and `lstat(path)` agree on device and inode, and the
    /// path is a directory (not a link put there since).
    private static func stillNames(_ path: String, _ fd: Int32) -> Bool {
        var held = stat()
        var named = stat()
        guard fstat(fd, &held) == 0, lstat(path, &named) == 0 else { return false }
        return (named.st_mode & S_IFMT) == S_IFDIR && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }
}

// MARK: - Proof at the mark (the second look)

/// The second look, taken SYNCHRONOUSLY at the moment of marking (codex
/// 2026-10-16 F1/F2; r2 F2; r3 F1/F2). The chunk's stat was the cheap first
/// pass; this decides — through a directory handle
/// (CatalogAuditDirectoryWalk), under THE ONE RULE: ENOENT is proof only in
/// a folder on the volume the file was last seen on.
enum CatalogAuditProof: Sendable, Equatable {
    /// ENOENT / ENOTDIR through the handle, on the volume the row's stamp
    /// names, the handle still naming its path.
    case gone
    /// The name is there (any size), not a regular file, or an errno —
    /// whatever the handle said stands; with the stamp a found file gets.
    case notGone(CatalogAuditStat, seenOn: AuditSeenOn?)
    /// ENOENT, but the row carries no stamp: no audit has ever seen this
    /// file, so nothing says which volume to believe. Never marked.
    case neverSeenByAnAudit
    /// ENOENT, but not proof here; the words say why (a link in the path,
    /// the folder changed under the audit, the drive is not connected,
    /// another volume than the one the file was last seen on).
    case notProvable(String)

    /// The walk first — a file that is there is present whatever the stamp
    /// says; only an ENOENT read through the handle is held against the
    /// volume the file was last seen on (`lastSeenOn`, read from the LIVE
    /// record).
    static func atTheMark(_ item: CatalogAuditItem, lastSeenOn: AuditSeenOn?, now: Date = Date()) -> CatalogAuditProof {
        switch CatalogAuditDirectoryWalk.prove(directory: item.directory, filename: item.filename, root: item.root) {
        case .found(let stat, let on):
            return .notGone(stat, seenOn: on?.seenOn(at: now))
        case .link:
            return .notProvable("a link in the path — not provable")
        case .changedUnderTheAudit:
            return .notProvable("the folder changed under the audit — not provable")
        case .rootNotThere:
            return .notProvable("the drive is not connected (its root is not there)")
        case .unreadable(let e):
            return .notGone(.unreadable(errno: e), seenOn: nil)
        case .gone(let on):
            return onTheVolumeLastSeen(on, lastSeenOn: lastSeenOn)
        }
    }

    /// THE ONE RULE (D5): the folder the file is not in must be on the
    /// volume the file was last seen on.
    private static func onTheVolumeLastSeen(_ on: CatalogAuditMountIdentity, lastSeenOn: AuditSeenOn?) -> CatalogAuditProof {
        guard let lastSeenOn else { return .neverSeenByAnAudit }
        guard let uuid = on.volumeUUID else {
            return .notProvable("the volume the folder is on reports no UUID (\(on.words)), so it cannot be the one the file was last seen on")
        }
        guard uuid == lastSeenOn.volumeUUID else {
            let seen = lastSeenOn.seenAt.formatted(date: .abbreviated, time: .shortened)
            return .notProvable("the folder is on a different volume (\(on.words)) than the file was last seen on "
                + "(\(lastSeenOn.mountFrom ?? "?") [\(lastSeenOn.volumeUUID)], \(seen)) — drive not connected?")
        }
        return .gone
    }
}

// MARK: - Results (values)

/// What happened to one row — the detail list's row and the tally's key.
/// The §6 outcomes, plus four the run needs to be honest about:
/// `stillMissing` (a Missing row whose file is still gone — no new mark),
/// `goneArchived` (an archive copy's file is gone — reported, never
/// marked), `neverSeenByAnAudit` (not at its path, and no audit has ever
/// seen it, so nothing says which volume to believe — never marked; the
/// Fix Links bucket) and `recordChanged` (the row moved or changed while
/// the stat ran — the result is dropped).
enum CatalogAuditResult: String, Sendable, Equatable, CaseIterable {
    case present
    case changed
    case gone
    case cameBack
    case stillMissing
    case goneArchived
    case neverSeenByAnAudit
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
        case .neverSeenByAnAudit: return "not at its path, never seen by an audit (not marked — Fix Links decides)"
        case .notAsked: return "not asked (drive not connected)"
        case .couldNotCheck: return "could not check"
        case .recordChanged: return "changed in the catalog meanwhile"
        }
    }

    /// Results that change a catalog row's marker (through the one engine).
    var isMark: Bool { self == .gone || self == .cameBack }
    /// Results that need a person to look — the Catalog Status band's red.
    var needsAPerson: Bool {
        switch self {
        case .gone, .goneArchived, .neverSeenByAnAudit, .changed, .couldNotCheck: return true
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
    /// Folder → how many of its files were found not at their path (for
    /// the OUTCOME's "3 gone under …"). Archived copies and never-seen
    /// rows count here too.
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
