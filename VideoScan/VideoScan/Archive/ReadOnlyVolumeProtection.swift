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
// (For Rick: a Sendable value type, like ArchiveVolumeProtection — an
// immutable snapshot you can hand to a disk thread by copy.)

import Foundation

/// The person's "Read only" mark on one scan target. Stored with the other
/// per-volume settings (UserDefaults, keyed by the target's path).
struct VolumeReadOnlyMark: Sendable, Equatable {
    var markedAt: Date
    /// The volume's persistent UUID when the mark was made; nil for a
    /// folder on the boot disk, or when the drive was not connected.
    var volumeUUID: String?
}

struct ReadOnlyVolumeProtection: Sendable, Equatable {

    /// One marked scan target, as the build sees it.
    struct Mark: Sendable, Equatable {
        let searchPath: String
        let volumeUUID: String?
    }

    struct Entry: Sendable, Equatable {
        /// "SanDisk" — the name the refusal uses.
        let label: String
        /// Lower-cased canonical prefixes that are protected: the marked
        /// path, and the same folder on any mount proven (by UUID) to be
        /// the marked drive.
        let roots: [String]
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

    private static func split(_ searchPath: String) -> (spelled: String, volumeRoot: String?, subpath: String, label: String) {
        let spelled = ArchiveVolumeProtection.canonical(searchPath)
        let volumeRoot = ArchiveVolumeProtection.externalVolumeRoot(of: spelled)
        let subpath = volumeRoot.map { String(spelled.dropFirst($0.count)) } ?? ""
        let label = volumeRoot.map { String($0.dropFirst("/Volumes/".count)) } ?? (spelled as NSString).lastPathComponent
        return (spelled, volumeRoot, subpath, label)
    }

    /// NO disk access: the marked paths themselves. Safe on the main thread.
    static func provisional(marks: [Mark]) -> ReadOnlyVolumeProtection {
        let entries = marks.compactMap { mark -> Entry? in
            let s = split(mark.searchPath)
            guard s.spelled.count > 1 else { return nil }   // never "/"
            return Entry(label: s.label, roots: [s.spelled.lowercased()], differentDriveMounted: false,
                         volumeUUID: s.volumeRoot == nil ? nil : mark.volumeUUID, subpath: s.subpath)
        }
        return ReadOnlyVolumeProtection(entries: entries, marks: marks, isBuilt: false)
    }

    /// The full build. DISK I/O (volume-UUID reads of the marked mount and,
    /// when the marked drive is not found there, of every mounted local
    /// root) — never on the main thread. Network mounts are not read.
    static func make(marks: [Mark],
                     mountedRoots: () -> [String] = { ArchiveVolumeProtection.mountedVolumeRootsProbe() },
                     probe: (String) -> String? = { MasterArchiveDesignation.volumeUUID(forPath: $0) })
        -> ReadOnlyVolumeProtection {
        var mounted: [String]?
        var entries: [Entry] = []
        for mark in marks {
            let s = split(mark.searchPath)
            guard s.spelled.count > 1 else { continue }
            var roots = [s.spelled.lowercased()]
            var different = false
            let uuid = s.volumeRoot == nil ? nil : mark.volumeUUID
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
            entries.append(Entry(label: s.label, roots: roots, differentDriveMounted: different,
                                 volumeUUID: uuid, subpath: s.subpath))
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
                // Only the MARKED spelling can be the displaced one; a root
                // found by UUID is the drive itself.
                return i == 0 && entry.differentDriveMounted ? .readOnlyDifferentDrive(entry.label) : .readOnly(entry.label)
            }
        }
        return nil
    }

    /// The last word, immediately before a file's own trash / remove, off
    /// the main actor: the string verdict; then the verdict for the file's
    /// REAL path (a symlinked parent); then a fresh read of the file's OWN
    /// volume UUID — the marked drive mounted since the snapshot, or under a
    /// name the snapshot never saw.
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
        let wholeVolume = entries.filter { $0.volumeUUID != nil && $0.subpath.isEmpty }
        guard !wholeVolume.isEmpty, let own = probe(path) else { return nil }
        return wholeVolume.first { $0.volumeUUID == own }.map { .readOnly($0.label) }
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
            t.readOnlyMark.map { .init(searchPath: t.searchPath, volumeUUID: $0.volumeUUID) }
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
            guard i < built.count, built[i].searchPath == t.searchPath, built[i].volumeUUID == mark.volumeUUID else { return false }
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

    /// Mark a volume Read only, or allow changes again. One UUID read of the
    /// volume at the moment of the click (like Initialize's); the mark is
    /// saved with the other volume settings and logged — START and OUTCOME,
    /// the volume's name only.
    func setVolumeReadOnly(_ on: Bool, for target: CatalogScanTarget, now: Date = Date()) {
        let name = VolumeReachability.displayLabel(forPath: target.searchPath)
        guard !isReadOnly else {
            log("Read only: \(name) — not changed: this Mac is a read-only viewer of the catalog.")
            return
        }
        guard on != (target.readOnlyMark != nil) else { return }
        log("Read only: \(on ? "marking" : "allowing changes on") \(name) — START")
        if on {
            let canonical = ArchiveVolumeProtection.canonical(target.searchPath)
            let onExternal = ArchiveVolumeProtection.externalVolumeRoot(of: canonical) != nil
            let uuid = onExternal && target.isReachable ? MasterArchiveDesignation.volumeUUID(forPath: target.searchPath) : nil
            target.readOnlyMark = VolumeReadOnlyMark(markedAt: now, volumeUUID: uuid)
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
}
