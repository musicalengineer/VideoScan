// ReadOnlyVolumeProtection.swift
//
// Rick, 2026-10-03: "I'd like to be able to select a volume and mark it
// 'Read only' as a way to keep it off the delete list. Just a safety
// feature. FamilyArchive is RO for now, everything else is RW."
//
// A READ-ONLY volume is one where VideoScan's bulk verbs never remove,
// trash, move out or replace a file. Its files STILL COUNT as surviving
// copies when other drives are cleaned up — read-only is not "ignore".
//
// This file is the second half of the ONE bulk-verb gate
// (`VideoScanModel.bulkDeleteRefusal`, VideoScanModel+MasterArchive.swift):
// the Master Archive's volume is read-only BY RULE (ArchiveVolumeProtection);
// any other volume is read-only when the person MARKS it (the mark lives on
// its scan target — `CatalogScanTarget.readOnlyMark`).
//
// IDENTITY, the archive-volume precedent (refuse over guess):
//   1. The marked PATH is always protected, by string, with no disk access —
//      so an unmounted read-only drive stays protected (its catalog rows
//      still carry that path), and so does that path while the snapshot
//      below is still being built.
//   2. The volume UUID captured when the mark was made follows the DRIVE:
//      the same disk mounted under another name ("/Volumes/X 1") is found
//      by UUID and protected there too.
//   3. A DIFFERENT drive mounted under the marked name does not inherit the
//      flag silently: paths under the name are still refused (the catalog's
//      rows for that path describe the marked drive, not this one), but
//      with their own words — "a different drive is mounted there now".
//
// The build (`make`) reads volume UUIDs and so never runs on the main
// thread; `provisional` (rule 1 alone) needs no disk and is what callers get
// until a build lands. Nothing ever reads "not read-only" because a build is
// late.
//
// A mark on a FOLDER of the boot disk (a ~/Movies-style scan target)
// protects that folder; no UUID is kept for it (every boot file shares one).
//
// DRIVE OR FOLDER — decided from the MOUNT, never from the spelling (codex
// #258 F2, the archive volume's own lesson of #1642). When the mark is made
// the path is resolved physically (realpath: symlinks first, then "..") and
// its mount point read; the mark keeps both, plus the UUID of the volume it
// really lives on. So a scan target that is a symlink into /Volumes/X, or a
// drive mounted at a custom mount point, is a DRIVE: protected under its
// real path and wherever that volume mounts next — not only under the
// spelling that was marked. A marked FOLDER of an external drive is found
// on the renamed / remounted drive by UUID + its place on the volume, at
// removal time too, before any rebuild lands (F4).
//
// (For Rick: a Sendable value type, like ArchiveVolumeProtection — an
// immutable snapshot you can hand to a disk thread by copy.)

import Foundation

/// The person's "Read only" mark on one scan target. Stored with the other
/// per-volume settings (UserDefaults, keyed by the target's path).
struct VolumeReadOnlyMark: Sendable, Equatable {
    var markedAt: Date
    /// The persistent UUID of the volume the marked path REALLY lived on
    /// when the mark was made; nil for a folder on the boot disk, or when
    /// the drive was not connected.
    var volumeUUID: String?
    /// Where the marked path really lived then (realpath — symlinks
    /// resolved before any ".."). nil = it could not be resolved (the drive
    /// was away), or the mark predates this field. Additive.
    var resolvedPath: String? = nil
    /// The mount point of the volume it lived on then. Additive.
    var mountPoint: String? = nil
    /// The person said this drive is a BACKUP OF THE MASTER ARCHIVE
    /// (delete-excess lane, C05 amendment 3, 2026-10-07). An Archive backup
    /// is a Read-only drive with a name for why: the one bulk-verb gate
    /// refuses it exactly as it refuses any Read-only drive, its files still
    /// count as surviving copies, and the excess-copies lane says "on a
    /// drive marked Archive backup". Additive (absent = false).
    var isArchiveBackup: Bool = false
}

struct ReadOnlyVolumeProtection: Sendable, Equatable {

    /// One marked scan target, as the build sees it.
    struct Mark: Sendable, Equatable {
        let searchPath: String
        let volumeUUID: String?
        var resolvedPath: String? = nil
        var mountPoint: String? = nil
    }

    struct Entry: Sendable, Equatable {
        /// "SanDisk" — the name the refusal uses.
        let label: String
        /// Lower-cased canonical prefixes that are protected: the marked
        /// path and where it really lived (the first `markedRootCount`),
        /// then the same folder on any mount proven (by UUID) to be the
        /// marked drive.
        let roots: [String]
        /// How many of `roots` are the mark's own spellings.
        let markedRootCount: Int
        /// A different drive (another UUID) is mounted at the marked path.
        let differentDriveMounted: Bool
        /// The marked drive's UUID, for the removal-time re-check.
        let volumeUUID: String?
        /// The marked folder below its volume root ("" = the whole volume).
        let subpath: String
    }

    enum Verdict: Sendable, Equatable {
        /// On a volume the person marked Read only.
        case readOnly(String)
        /// Under the marked name, where a different drive is mounted now.
        case readOnlyDifferentDrive(String)

        var label: String {
            switch self {
            case .readOnly(let l), .readOnlyDifferentDrive(let l): return l
            }
        }
    }

    let entries: [Entry]
    /// The marks this snapshot was made for (the cache's key).
    let marks: [Mark]
    /// False for `provisional`: rule 1 only.
    let isBuilt: Bool

    static let none = ReadOnlyVolumeProtection(entries: [], marks: [], isBuilt: true)

    var isEmpty: Bool { entries.isEmpty }

    // MARK: Building

    /// One mark, taken apart with NO disk access.
    private struct Parts {
        let spelled: String
        /// Protected by string: the spelled path and, when the mark knows
        /// it, where that path really lived. Lower-cased.
        var markedRoots: [String]
        /// The root of the volume the mark lives on — its mount point when
        /// the mark recorded one, else the "/Volumes/<name>" of its
        /// spelling. nil = a folder of the boot disk.
        let volumeRoot: String?
        /// The marked folder below that root ("" = the whole volume).
        let subpath: String
        let label: String
        /// nil for a folder of the boot disk (every boot file shares one).
        let volumeUUID: String?
    }

    private static func parts(of mark: Mark) -> Parts? {
        let spelled = ArchiveVolumeProtection.canonical(mark.searchPath)
        guard spelled.count > 1 else { return nil }   // never "/"
        let spelledRoot = ArchiveVolumeProtection.externalVolumeRoot(of: spelled)
        let label = spelledRoot.map { String($0.dropFirst("/Volumes/".count)) } ?? (spelled as NSString).lastPathComponent
        var roots = [spelled.lowercased()]
        var volumeRoot = spelledRoot
        var located = spelled
        // What the MOUNT said when the mark was made outranks the spelling
        // (codex #258 F2): a symlink into a drive, a custom mount point.
        if let resolved = mark.resolvedPath, let mount = mark.mountPoint {
            let real = ArchiveVolumeProtection.canonical(resolved)
            // Both spellings of the real place ("/private/var…" and the
            // standardized one), as the archive's boot-folder rule keeps.
            for spelling in [real, resolved] where spelling.count > 1 && !roots.contains(spelling.lowercased()) {
                roots.append(spelling.lowercased())
            }
            if ArchiveVolumeProtection.isBootMountPoint(mount) {
                volumeRoot = nil
            } else {
                volumeRoot = ArchiveVolumeProtection.canonical(mount)
                located = real
            }
        }
        let subpath = volumeRoot.map { root in
            located.lowercased().hasPrefix(root.lowercased()) ? String(located.dropFirst(root.count)) : ""
        } ?? ""
        return Parts(spelled: spelled, markedRoots: roots, volumeRoot: volumeRoot, subpath: subpath, label: label,
                     volumeUUID: volumeRoot == nil ? nil : mark.volumeUUID)
    }

    /// NO disk access: the marked paths themselves (as spelled, and where
    /// they really lived when the mark was made). Safe on the main thread.
    static func provisional(marks: [Mark]) -> ReadOnlyVolumeProtection {
        let entries = marks.compactMap { mark -> Entry? in
            guard let p = parts(of: mark) else { return nil }
            return Entry(label: p.label, roots: p.markedRoots, markedRootCount: p.markedRoots.count,
                         differentDriveMounted: false, volumeUUID: p.volumeUUID, subpath: p.subpath)
        }
        return ReadOnlyVolumeProtection(entries: entries, marks: marks, isBuilt: false)
    }

    /// The full build. DISK I/O (volume-UUID reads of the marked mount and,
    /// when the marked drive is not found there, of every mounted local
    /// root; one realpath for a mark that never learned where it really
    /// lives) — never on the main thread. Network mounts are not read.
    static func make(marks: [Mark],
                     mountedRoots: () -> [String] = { ArchiveVolumeProtection.mountedVolumeRootsProbe() },
                     probe: (String) -> String? = { MasterArchiveDesignation.volumeUUID(forPath: $0) },
                     identity: (String) -> MountIdentity? = { ArchiveVolumeProtection.mountIdentityProbe($0) },
                     networkRoots: () -> [String] = { ArchiveVolumeProtection.networkMountRootsProbe() })
        -> ReadOnlyVolumeProtection {
        var mounted: [String]?
        var network: [String]?
        var entries: [Entry] = []
        for mark in marks {
            guard let s = parts(of: mark) else { continue }
            var roots = s.markedRoots
            // A mark that never learned where it really lives (made while
            // the drive was away): when its spelling resolves now, the real
            // place is protected too — by path; no identity is adopted.
            if mark.resolvedPath == nil {
                if network == nil { network = networkRoots().map { ArchiveVolumeProtection.canonical($0).lowercased() } }
                let onNetwork = (network ?? []).contains { ArchiveVolumeProtection.isInsideLexically(path: s.spelled.lowercased(), root: $0) }
                if !onNetwork, let id = identity(s.spelled) {
                    for spelling in [ArchiveVolumeProtection.canonical(id.resolvedPath), id.resolvedPath]
                    where spelling.count > 1 && !roots.contains(spelling.lowercased()) {
                        roots.append(spelling.lowercased())
                    }
                }
            }
            let markedRootCount = roots.count
            var different = false
            let uuid = s.volumeUUID
            if let uuid, let volumeRoot = s.volumeRoot {
                let here = probe(volumeRoot)
                if let here, here != uuid { different = true }
                if here != uuid {
                    // Not at its marked name (away, renamed, or displaced):
                    // look for the drive itself among what is mounted.
                    if mounted == nil { mounted = mountedRoots() }
                    for m in mounted ?? [] {
                        let c = ArchiveVolumeProtection.canonical(m)
                        guard !ArchiveVolumeProtection.isBootMountPoint(c), c.lowercased() != volumeRoot.lowercased(),
                              probe(c) == uuid else { continue }
                        let root = (c + s.subpath).lowercased()
                        if !roots.contains(root) { roots.append(root) }
                    }
                }
            }
            entries.append(Entry(label: s.label, roots: roots, markedRootCount: markedRootCount,
                                 differentDriveMounted: different, volumeUUID: uuid, subpath: s.subpath))
        }
        return ReadOnlyVolumeProtection(entries: entries, marks: marks, isBuilt: true)
    }

    // MARK: Asking (per record — string work only)

    func verdict(forPath raw: String) -> Verdict? {
        guard !entries.isEmpty, !raw.isEmpty else { return nil }
        let lower = Self.canonicalIfNeeded(raw).lowercased()
        for entry in entries {
            for (i, root) in entry.roots.enumerated() where lower.hasPrefix(root) {
                guard ArchiveVolumeProtection.isInsideLexically(path: lower, root: root) else { continue }
                // Only the MARKED spellings can be the displaced ones; a
                // root found by UUID is the drive itself.
                return i < entry.markedRootCount && entry.differentDriveMounted
                    ? .readOnlyDifferentDrive(entry.label) : .readOnly(entry.label)
            }
        }
        return nil
    }

    /// The last word, immediately before a file's own trash / remove, off
    /// the main actor: the string verdict; then the verdict for the file's
    /// REAL path (a symlinked parent); then a fresh read of the file's OWN
    /// volume UUID — the marked drive mounted since the snapshot, or under a
    /// name the snapshot never saw. A marked FOLDER is found the same way:
    /// the volume's UUID, then the file's place on that volume (its real
    /// path below its own mount point) inside the marked folder — so a
    /// rename or remount protects it before any rebuild lands (codex #258
    /// F4).
    func verdictAtRemoval(path: String, probe: (String) -> String?,
                          identity: (String) -> MountIdentity? = { ArchiveVolumeProtection.mountIdentityProbe($0) }) -> Verdict? {
        guard !entries.isEmpty else { return nil }
        if let v = verdict(forPath: path) { return v }
        let parent = (path as NSString).deletingLastPathComponent
        let resolved = identity(path)?.resolvedPath
            ?? identity(parent).map { ($0.resolvedPath as NSString).appendingPathComponent((path as NSString).lastPathComponent) }
        if let resolved {
            let real = ArchiveVolumeProtection.canonical(resolved)
            if real != path, let v = verdict(forPath: real) { return v }
        }
        let byIdentity = entries.filter { $0.volumeUUID != nil }
        guard !byIdentity.isEmpty else { return nil }
        guard let own = probe(path) else {
            // The file's own volume identity cannot be read (codex #258
            // r5-4): it may be a marked drive under a name nobody marked.
            // Clear only the provably-other: the boot disk, a network share.
            if let mount = (identity(path) ?? identity(parent))?.mountPoint, ArchiveVolumeProtection.isBootMountPoint(mount) { return nil }
            if ArchiveVolumeProtection.isNetworkMount(path) { return nil }
            let names = byIdentity.map(\.label).joined(separator: " or ")
            return .readOnly("\(names) (VideoScan could not read this drive's identity, so it cannot rule that out)")
        }
        // Where the file sits on its own volume — asked once, and only for
        // a marked folder.
        var placed = false
        var place: String?
        for entry in byIdentity where entry.volumeUUID == own {
            if entry.subpath.isEmpty { return .readOnly(entry.label) }
            if !placed {
                placed = true
                let id = identity(path) ?? identity(parent).map {
                    MountIdentity(resolvedPath: ($0.resolvedPath as NSString).appendingPathComponent((path as NSString).lastPathComponent),
                                  mountPoint: $0.mountPoint)
                }
                place = id.map { id in
                    let real = ArchiveVolumeProtection.canonical(id.resolvedPath).lowercased()
                    let mount = ArchiveVolumeProtection.canonical(id.mountPoint).lowercased()
                    return mount.count > 1 && real.hasPrefix(mount) ? String(real.dropFirst(mount.count)) : real
                }
            }
            // On the marked drive, but where on it cannot be told: refuse
            // over guess.
            guard let place else { return .readOnly(entry.label) }
            if ArchiveVolumeProtection.isInsideLexically(path: place, root: entry.subpath.lowercased()) { return .readOnly(entry.label) }
        }
        return nil
    }

    private static func canonicalIfNeeded(_ path: String) -> String {
        if path.contains("/./") || path.contains("/../") || path.contains("//")
            || path.hasSuffix("/.") || path.hasSuffix("/..")
            || ArchiveVolumeProtection.hasPrefixFolded(path, "/system/volumes/data/") {
            return ArchiveVolumeProtection.canonical(path)
        }
        return path
    }
}

/// Every sentence the "Read only" switch shows, in one place (the views
/// only place them; the tests pin them).
enum VolumeReadOnlyText {
    static let toggleLabel = "Read only"
    static let caption = "VideoScan will never delete, move or rewrite files on this drive. Its files still count as copies when other drives are cleaned up."
    /// The Master Archive's volume: on, and not the person's to change.
    static let byRuleLabel = "Read only — the Master Archive"
    static let markMenuTitle = "Mark Read Only"
    static let allowMenuTitle = "Allow Changes"
    static let chip = "READ ONLY"
    /// Shown where the Reclaimable card would be.
    static let reclaimableNotice = "This drive is Read only — nothing here is ever removed."
    static let badgeHelp = "Read only — VideoScan never deletes, moves or rewrites files on this drive."
    /// The Delete-duplicates picker's disabled row.
    static func pickerRow(_ name: String) -> String { "\(name) — Read only: nothing here is ever removed" }
    static func menuTitle(isMarked: Bool) -> String { isMarked ? allowMenuTitle : markMenuTitle }
}

/// The model's cache for the built snapshot (stored property in
/// VideoScanModel.swift; main-actor state).
struct ReadOnlyVolumeSnapshotCache {
    var snapshot: ReadOnlyVolumeProtection?
    /// False from a mount / unmount / rename until a rebuild lands.
    var isFresh = false
    var generation = 0
    var isBuilding = false
    /// Test hook: rebuilds installed so far.
    var installCount = 0
}

extension VideoScanModel {

    /// The marks on the scan targets, in target order. O(targets).
    var readOnlyVolumeMarks: [ReadOnlyVolumeProtection.Mark] {
        scanTargets.compactMap { t in
            t.readOnlyMark.map {
                .init(searchPath: t.searchPath, volumeUUID: $0.volumeUUID, resolvedPath: $0.resolvedPath, mountPoint: $0.mountPoint)
            }
        }
    }

    /// True when no scan target is marked — the gate's fast path (no
    /// allocation; asked once per record).
    var hasNoReadOnlyVolumeMarks: Bool {
        !scanTargets.contains { $0.readOnlyMark != nil }
    }

    /// The snapshot the bulk-verb gate reads. O(targets) and disk-free on
    /// every call: the built snapshot when it is fresh and was built for
    /// today's marks, else the provisional one (the marked paths, by
    /// string) while a rebuild runs off the main thread.
    func readOnlyVolumeProtection() -> ReadOnlyVolumeProtection {
        if hasNoReadOnlyVolumeMarks { return .none }
        let cache = readOnlyVolumeSnapshotCache
        if cache.isFresh, let built = cache.snapshot, marksMatch(built.marks) { return built }
        let marks = readOnlyVolumeMarks
        scheduleReadOnlyVolumeSnapshotRebuild(marks: marks)
        return .provisional(marks: marks)
    }

    /// Compare without building an array (asked once per record).
    private func marksMatch(_ built: [ReadOnlyVolumeProtection.Mark]) -> Bool {
        var i = 0
        for t in scanTargets {
            guard let mark = t.readOnlyMark else { continue }
            guard i < built.count, built[i].searchPath == t.searchPath, built[i].volumeUUID == mark.volumeUUID,
                  built[i].resolvedPath == mark.resolvedPath, built[i].mountPoint == mark.mountPoint else { return false }
            i += 1
        }
        return i == built.count
    }

    /// A mount, an unmount or a rename: what is mounted where may have
    /// changed (called beside the archive-volume snapshot's invalidation).
    func noteReadOnlyVolumeSnapshotStale() {
        readOnlyVolumeSnapshotCache.generation &+= 1
        readOnlyVolumeSnapshotCache.isFresh = false
    }

    private func scheduleReadOnlyVolumeSnapshotRebuild(marks: [ReadOnlyVolumeProtection.Mark]) {
        guard !readOnlyVolumeSnapshotCache.isBuilding else { return }
        readOnlyVolumeSnapshotCache.isBuilding = true
        let generation = readOnlyVolumeSnapshotCache.generation
        Task { @MainActor [weak self] in
            let built = await Self.buildReadOnlyVolumeSnapshot(marks: marks)
            self?.installReadOnlyVolumeSnapshot(built, generation: generation)
        }
    }

    /// Build (off-main) and install now; returns what the gate then reads.
    /// For tests, and for a verb that must not act on the provisional one.
    @discardableResult
    func refreshReadOnlyVolumeSnapshot() async -> ReadOnlyVolumeProtection {
        let marks = readOnlyVolumeMarks
        guard !marks.isEmpty else { return .none }
        readOnlyVolumeSnapshotCache.generation &+= 1
        let generation = readOnlyVolumeSnapshotCache.generation
        let built = await Self.buildReadOnlyVolumeSnapshot(marks: marks)
        installReadOnlyVolumeSnapshot(built, generation: generation)
        return readOnlyVolumeProtection()
    }

    @concurrent
    nonisolated static func buildReadOnlyVolumeSnapshot(marks: [ReadOnlyVolumeProtection.Mark]) async -> ReadOnlyVolumeProtection {
        ReadOnlyVolumeProtection.make(marks: marks)
    }

    private func installReadOnlyVolumeSnapshot(_ built: ReadOnlyVolumeProtection, generation: Int) {
        readOnlyVolumeSnapshotCache.isBuilding = false
        // A mount change (or a newer build) arrived meanwhile: the next
        // question schedules its own rebuild.
        guard readOnlyVolumeSnapshotCache.generation == generation else { return }
        let changed = readOnlyVolumeSnapshotCache.snapshot != built
        readOnlyVolumeSnapshotCache.snapshot = built
        readOnlyVolumeSnapshotCache.isFresh = true
        readOnlyVolumeSnapshotCache.installCount += 1
        // The Delete Duplicates menu payload may have been computed against
        // the provisional snapshot: recompute it against the real one.
        if changed { refreshDossierCountsNow() }
    }

    /// The connected, not-retired drives that are Read only — what the
    /// Delete-duplicates picker lists as not choosable. O(targets).
    var readOnlyVolumeNamesForPicker: [String] {
        scanTargets.filter { !$0.isRetired && !$0.isScratchVolume && isVolumeReadOnly($0) }
            .map { VolumeReachability.displayLabel(forPath: $0.searchPath) }
    }

    // MARK: The person's switch

    /// Is this scan target read-only — by the person's mark, or by rule
    /// (the Master Archive's volume)? For the Storage tab's badge and toggle.
    func isVolumeReadOnly(_ target: CatalogScanTarget) -> Bool {
        target.readOnlyMark != nil || isReadOnlyByRule(target)
    }

    /// The Master Archive's volume is read-only by rule: the toggle shows
    /// on and cannot be changed.
    func isReadOnlyByRule(_ target: CatalogScanTarget) -> Bool {
        guard masterArchive != nil else { return false }
        if isMasterArchive(target) { return true }
        return archiveVolumeProtection()?.verdict(forPath: target.searchPath) == .onArchiveVolume
    }

    /// Mark a volume Read only, or allow changes again. At the moment of
    /// the click (like Initialize's): one realpath + mount-point read of the
    /// target and one UUID read of the volume it REALLY lives on — a drive
    /// is a drive by its mount, never by its spelling (codex #258 F2). The
    /// mark is saved with the other volume settings and logged — START and
    /// OUTCOME, the volume's name only.
    func setVolumeReadOnly(_ on: Bool, for target: CatalogScanTarget, now: Date = Date()) {
        let name = VolumeReachability.displayLabel(forPath: target.searchPath)
        guard !isReadOnly else {
            log("Read only: \(name) — not changed: this Mac is a read-only viewer of the catalog.")
            return
        }
        guard on != (target.readOnlyMark != nil) else { return }
        log("Read only: \(on ? "marking" : "allowing changes on") \(name) — START")
        if on {
            target.readOnlyMark = Self.readOnlyMark(forPath: target.searchPath, isReachable: target.isReachable, now: now)
        } else {
            target.readOnlyMark = nil
        }
        noteReadOnlyVolumeSnapshotStale()
        persistScanDates()
        notifyTargetsChanged()
        refreshDossierCountsNow()
        let outcome = on
            ? "Read only: \(name) is marked Read only — VideoScan will never delete, move or rewrite files on it; its files still count as copies when other drives are cleaned up."
            : "Read only: \(name) allows changes again."
        log(outcome)
        appLog.write(outcome)
    }

    // MARK: Archive backup (2026-10-07, C05 amendment 3)

    /// The scan targets marked Archive backup, as Read-only marks.
    var archiveBackupVolumeMarks: [ReadOnlyVolumeProtection.Mark] {
        scanTargets.compactMap { t in
            guard let m = t.readOnlyMark, m.isArchiveBackup else { return nil }
            return .init(searchPath: t.searchPath, volumeUUID: m.volumeUUID, resolvedPath: m.resolvedPath, mountPoint: m.mountPoint)
        }
    }

    /// Paths on a drive marked Archive backup — string work only (the
    /// marked spellings; the removal-time check is the Read-only gate's,
    /// which already refuses these drives). For the lane's wording.
    func archiveBackupProtection() -> ReadOnlyVolumeProtection {
        let marks = archiveBackupVolumeMarks
        return marks.isEmpty ? .none : .provisional(marks: marks)
    }

    /// Mark a drive as a backup of the Master Archive, or take that name
    /// off. Marking makes it Read only too (one mark, one gate); taking the
    /// name off leaves it Read only — "Allow Changes" is the one way back to
    /// a writable drive. START and OUTCOME lines, the volume's name only.
    func setVolumeArchiveBackup(_ on: Bool, for target: CatalogScanTarget, now: Date = Date()) {
        let name = VolumeReachability.displayLabel(forPath: target.searchPath)
        guard !isReadOnly else {
            log("Archive backup: \(name) — not changed: this Mac is a read-only viewer of the catalog.")
            return
        }
        guard on != (target.readOnlyMark?.isArchiveBackup ?? false) else { return }
        log("Archive backup: \(on ? "marking" : "taking the name off") \(name) — START")
        var mark = target.readOnlyMark
            ?? Self.readOnlyMark(forPath: target.searchPath, isReachable: target.isReachable, now: now)
        mark.isArchiveBackup = on
        target.readOnlyMark = mark
        noteReadOnlyVolumeSnapshotStale()
        persistScanDates()
        notifyTargetsChanged()
        refreshDossierCountsNow()
        let outcome = on
            ? "Archive backup: \(name) is marked as a backup of the Master Archive — it is Read only, and nothing on it is ever offered as an excess copy."
            : "Archive backup: \(name) is no longer marked as an archive backup — it stays Read only until you choose Allow Changes."
        log(outcome)
        appLog.write(outcome)
    }

    /// The mark for a target at `searchPath`, made now: where the path
    /// really lives (realpath resolves symlinks before ".."), the mount it
    /// is on, and — when that mount is not the boot disk's — the volume's
    /// UUID read at the RESOLVED place. A drive that is away (or a path
    /// that does not resolve) is marked by its spelling alone, as before.
    /// A "/Volumes/X" that resolves onto the boot disk is the empty
    /// leftover folder of an unmounted volume: nothing is recorded from it.
    static func readOnlyMark(forPath searchPath: String, isReachable: Bool, now: Date) -> VolumeReadOnlyMark {
        var mark = VolumeReadOnlyMark(markedAt: now, volumeUUID: nil)
        guard isReachable else { return mark }
        let spelledExternal = ArchiveVolumeProtection.externalVolumeRoot(of: ArchiveVolumeProtection.canonical(searchPath)) != nil
        guard let id = ArchiveVolumeProtection.mountIdentityProbe(searchPath) else {
            if spelledExternal { mark.volumeUUID = MasterArchiveDesignation.volumeUUID(forPath: searchPath) }
            return mark
        }
        let onBootDisk = ArchiveVolumeProtection.isBootMountPoint(id.mountPoint)
        if onBootDisk && spelledExternal { return mark }
        mark.resolvedPath = id.resolvedPath
        mark.mountPoint = id.mountPoint
        if !onBootDisk { mark.volumeUUID = MasterArchiveDesignation.volumeUUID(forPath: id.resolvedPath) }
        return mark
    }
}
