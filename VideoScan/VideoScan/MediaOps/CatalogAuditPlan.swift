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
//     time, mtime): the apply step is compare-and-set on the whole
//     snapshot, so a row rescanned, edited, restored, marked or superseded
//     by another door while the stats ran is left alone.
//   • ANCHOR (CatalogAuditMountIdentity, below; the job does it per lane,
//     off the main actor, before the lane's first stat): the identity of
//     the LANE ROOT's filesystem — `statfs` of "/Volumes/X", or for "/"
//     this Mac's data volume (codex r2 2026-10-16 F1). Never "where the
//     parent is now": a gone proof must be read on THAT filesystem. nil
//     when it cannot be established → the lane's rows are never marked.
//   • STAT (CatalogAuditStat, below): one `stat(2)` per row, off the main
//     actor; the file is never opened. ENOENT / ENOTDIR → gone; any other
//     errno → could not check (never marked); a path that is no longer a
//     regular file → could not check (a person decides). This is the cheap
//     FIRST PASS; it decides nothing.
//   • PROVE AT THE MARK (CatalogAuditProof + CatalogAuditDirectoryWalk,
//     below; codex 2026-10-16 F1/F2, r2 F1/F2): for every gone answer —
//     and only those, they are few — the apply step walks the path again
//     SYNCHRONOUSLY on the main actor just before marking, BOUND TO A
//     DIRECTORY HANDLE: the nearest existing ancestor folder is opened
//     read-only (O_DIRECTORY | O_NOFOLLOW), its identity read with
//     `fstatfs(fd)`, the remaining folders walked one `openat` at a time
//     and the name itself read with `fstatat(…, AT_SYMLINK_NOFOLLOW)`.
//     ENOENT / ENOTDIR through that handle, on the lane root's filesystem,
//     is gone. Present now → present; a symlink anywhere on the way
//     (O_NOFOLLOW refuses it; a folder that would not open is looked at
//     with `fstatat` link-not-followed before it counts as gone) → could
//     not check, "a link in the path"; any other errno → could not check;
//     another filesystem (the
//     drive left, the path fell through to the system disk) → could not
//     check, "drive not connected". Under lane "/" the STUB RULE (r2 F1):
//     gone is provable only when the file's own folder is there and holds
//     something else — an unmounted custom mount point is an empty folder
//     on this Mac's disk and looks exactly like a deleted folder; a deleted
//     subfolder under "/" is a declared limit (refuse over guess). Under a
//     mounted /Volumes root a missing parent folder IS proof, bound to the
//     root's identity. This directory handle is the ONE declared exception
//     to "nothing opened" (MOPS-14): a folder, read-only, never a media
//     file; CatalogAuditJobSensorTests pins the calls to this file.
//   • APPLY (VideoScanModel+CatalogAudit.swift): the one engine —
//     `stampRemoval(.missing(reason: .missingAtAudit))` for a proven-gone
//     file, `clearRemoval` (validates first) for one that came back.
//   • RUN (CatalogAuditJob.swift): lanes in parallel, chunks of stats,
//     batched acknowledged saves, undo of the unsaved marks on a save that
//     is not acknowledged.
//
// Memory: one `CatalogAuditItem` (~270 bytes with its snapshot) per live
// record — ~27 MB at 100k — plus the per-folder tally of gone rows (one
// entry per folder that lost a file; ≤ the number of gone rows).

import Foundation
import VideoScanCore

// MARK: - Plan (values)

/// The fields of a row the apply step compares, planned against live
/// (codex 2026-10-16 F3; r2 F3 adds supersession). Any difference means
/// another door touched the row while the stats ran, and the result is
/// dropped as "record changed". Id and path alone are not enough: Trash →
/// Put Back → Restore returns the marker to nil; archive fixity set
/// meanwhile makes the row an archive copy; Repair supersedes a row the
/// plan skipped only if it was superseded when planned.
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

    /// (For Rick: a value copy of the fields, taken at plan time and again
    /// at apply time; `==` is the whole compare-and-set key.)
    static func of(_ r: VideoRecord) -> CatalogAuditRowSnapshot {
        CatalogAuditRowSnapshot(path: r.fullPath, sizeBytes: r.sizeBytes, removal: r.removal,
                                lifecycleStage: r.lifecycleStage, archiveStage: r.archiveStage,
                                hasArchiveFixity: r.archiveFixity != nil, derivationKind: r.derivationKind,
                                supersededByID: r.supersededByID,
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
    /// The filesystem the LANE ROOT is on, anchored before the lane's first
    /// stat — the identity every gone proof in the lane must be read on.
    /// nil = could not be established (the root is not a mount point; its
    /// statfs failed) — the row is then never marked.
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

    /// This Mac's data volume: every file a person writes lives here
    /// (/Users, /private, /opt… are firmlinks onto it); the sealed system
    /// snapshot mounted at "/" holds none.
    static let bootDataVolume = "/System/Volumes/Data"

    var words: String { "\(mountFrom) on \(mountOn)" }

    /// `statfs` of an existing path (nil when it is not there or cannot be
    /// read). No disk I/O beyond the kernel's mount table.
    static func of(_ path: String) -> CatalogAuditMountIdentity? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return decode(&fs)
    }

    /// `fstatfs` of an open directory handle: the filesystem the handle is
    /// bound to, whatever the path says now (codex r2 F2).
    static func of(fd: Int32) -> CatalogAuditMountIdentity? {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        return decode(&fs)
    }

    /// The identity a LANE's gone proofs must be read on (codex r2 F1):
    /// the lane root's own filesystem, never where a parent folder leads
    /// now. "/Volumes/X" must BE a mount point (an unmounted root's stub
    /// folder is on the system disk — nil, never provable). "/" means this
    /// Mac's data volume when it is a mount of its own (every Mac since
    /// Catalina), else "/" itself. Any other root (a test sandbox) is
    /// whatever it is on.
    static func ofLaneRoot(_ root: String) -> CatalogAuditMountIdentity? {
        if root == "/" {
            if let data = of(bootDataVolume), data.mountOn == bootDataVolume { return data }
            return of("/")
        }
        guard let identity = of(root) else { return nil }
        if root.hasPrefix("/Volumes/") && identity.mountOn != root { return nil }
        return identity
    }

    private static func decode(_ fs: inout statfs) -> CatalogAuditMountIdentity {
        let on = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return CatalogAuditMountIdentity(fsid0: fs.f_fsid.val.0, fsid1: fs.f_fsid.val.1, mountOn: on, mountFrom: from)
    }
}

// MARK: - Stat (one syscall, no open)

/// What `stat(2)` said about one path. Pure value; the stat itself is the
/// only I/O the first pass does.
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

// MARK: - The directory-handle walk (the second look, bound to an fd)

/// What the fd-bound walk found. Pure value.
enum CatalogAuditWalk: Sendable, Equatable {
    /// The name is there: a regular file (with its size), or something else.
    case found(CatalogAuditStat)
    /// ENOENT / ENOTDIR read THROUGH the handle, bound to the identity of
    /// the folder the handle is open on. `missingFolders` = how many
    /// folders of the file's directory were not there (0 = only the file
    /// itself); `parentHasEntries` is read only when asked (the "/" stub
    /// rule) and only when the file's own folder is the handle.
    case gone(on: CatalogAuditMountIdentity, missingFolders: Int, parentHasEntries: Bool?)
    /// A symlink on the way — O_NOFOLLOW refused it (ELOOP). Not provable.
    case link
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

    private enum Opened { case opened(fd: Int32, depth: Int), failed(CatalogAuditWalk) }
    private enum Descent { case reached, gone(missingFolders: Int), failed(CatalogAuditWalk) }
    private enum Named { case found(CatalogAuditStat), gone, failed(CatalogAuditWalk) }

    /// Walk `root`/…/`directory`/`filename` through directory handles. Every
    /// handle is closed before returning, on every path.
    static func prove(directory: String, filename: String, root: String, readParentEntries: Bool) -> CatalogAuditWalk {
        guard let folders = folders(of: directory, below: root) else { return .unreadable(errno: EINVAL) }
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } }
        let depth: Int
        switch openNearestExistingAncestor(root: root, folders: folders) {
        case .opened(let opened, let d): fd = opened; depth = d
        case .failed(let walk): return walk
        }
        switch descend(&fd, through: folders[depth...]) {
        case .reached: break
        case .gone(let missing): return goneThrough(fd, missingFolders: missing, readParentEntries: false)
        case .failed(let walk): return walk
        }
        switch statName(filename, in: fd) {
        case .found(let stat): return .found(stat)
        case .gone: return goneThrough(fd, missingFolders: 0, readParentEntries: readParentEntries)
        case .failed(let walk): return walk
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

    /// Opens the deepest `root/folders[0..<k]` that is there, trying the
    /// whole directory first and walking up. Each open is O_NOFOLLOW on
    /// its last component: landing on a symlink is refused (ELOOP).
    private static func openNearestExistingAncestor(root: String, folders: [String]) -> Opened {
        var k = folders.count
        while k >= 0 {
            let fd = open(pathOf(root, folders[..<k]), directoryFlags)
            let e = errno
            if fd >= 0 { return .opened(fd: fd, depth: k) }
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
    /// previous handle is closed as the walk moves down. A folder that
    /// will not open as a directory (ENOENT / ENOTDIR — on Darwin a
    /// symlink refused by O_NOFOLLOW | O_DIRECTORY reads ENOTDIR, not
    /// ELOOP) is looked at through the handle, link not followed, before
    /// it counts as gone.
    private static func descend(_ fd: inout Int32, through folders: ArraySlice<String>) -> Descent {
        for (i, name) in folders.enumerated() {
            let next = openat(fd, name, directoryFlags)
            let e = errno
            if next >= 0 { close(fd); fd = next; continue }
            switch e {
            case ENOENT, ENOTDIR:
                if let failure = whatIsThere(name, in: fd) { return .failed(failure) }
                return .gone(missingFolders: folders.count - i)
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

    /// ENOENT through `fd`: bound to the handle's identity, read now.
    private static func goneThrough(_ fd: Int32, missingFolders: Int, readParentEntries: Bool) -> CatalogAuditWalk {
        guard let on = CatalogAuditMountIdentity.of(fd: fd) else { return .unreadable(errno: errno) }
        return .gone(on: on, missingFolders: missingFolders, parentHasEntries: readParentEntries ? hasEntries(fd) : nil)
    }

    /// Does the folder behind `fd` hold anything but "." and ".."? nil when
    /// it cannot be read. A duplicate of the handle is listed so `fd`
    /// itself stays untouched.
    private static func hasEntries(_ fd: Int32) -> Bool? {
        let dupFd = dup(fd)
        guard dupFd >= 0 else { return nil }
        guard let dir = fdopendir(dupFd) else { close(dupFd); return nil }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            var d = entry.pointee
            let name = withUnsafePointer(to: &d.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { return true }
        }
        return false
    }
}

// MARK: - Proof at the mark (the second look)

/// The second look, taken SYNCHRONOUSLY at the moment of marking (codex
/// 2026-10-16 F1/F2; r2 F1/F2). The chunk's stat was the cheap first pass;
/// this decides — through a directory handle (CatalogAuditDirectoryWalk),
/// bound to the lane root's filesystem, under the lane's rule.
enum CatalogAuditProof: Sendable, Equatable {
    /// ENOENT / ENOTDIR through the handle, on the lane root's filesystem,
    /// and the lane's rule accepts it.
    case gone
    /// The name is there (any size), not a regular file, or an errno —
    /// whatever the handle said stands.
    case notGone(CatalogAuditStat)
    /// ENOENT, but not on the expected filesystem (or none was anchored):
    /// the drive is not connected, the path fell through to another disk.
    case driveNotConnected(expected: CatalogAuditMountIdentity?, now: CatalogAuditMountIdentity?)
    /// ENOENT on the expected filesystem, but the lane's rule says that is
    /// not proof here; the words say why.
    case notProvable(String)

    /// The walk first — a file that is there is present whatever was
    /// anchored; only an ENOENT read through the handle is held against the
    /// lane root's identity.
    static func atTheMark(_ item: CatalogAuditItem) -> CatalogAuditProof {
        let walk = CatalogAuditDirectoryWalk.prove(directory: item.directory, filename: item.filename,
                                                   root: item.root, readParentEntries: item.root == "/")
        switch walk {
        case .found(let stat):
            return .notGone(stat)
        case .link:
            return .notProvable("a link in the path — not provable")
        case .rootNotThere:
            return .driveNotConnected(expected: item.expectedMount, now: nil)
        case .unreadable(let e):
            return .notGone(.unreadable(errno: e))
        case .gone(let on, let missingFolders, let parentHasEntries):
            guard let expected = item.expectedMount, on == expected else { return .driveNotConnected(expected: item.expectedMount, now: on) }
            return item.root == "/" ? stubRule(missingFolders: missingFolders, parentHasEntries: parentHasEntries) : .gone
        }
    }

    /// Lane "/" (rows outside /Volumes): an unmounted custom mount point is
    /// an empty folder on this Mac's disk and looks exactly like a deleted
    /// folder — refuse over guess. Gone is provable only when the file's
    /// own folder is there and holds something else.
    private static func stubRule(missingFolders: Int, parentHasEntries: Bool?) -> CatalogAuditProof {
        if missingFolders > 0 {
            return .notProvable("its folder is not there — on this Mac's disk a deleted folder and an unmounted mount point look the same")
        }
        guard let has = parentHasEntries else { return .notProvable("its folder could not be listed") }
        return has ? .gone : .notProvable("the folder is empty (an unmounted mount point looks the same)")
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
