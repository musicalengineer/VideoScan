// VideoScanModel+ArchiveVolumeSnapshot.swift
//
// ONE cached Master Archive VOLUME snapshot for every bulk verb and every
// view that asks "may this file be deleted?" (2026-09-22 follow-up to the
// archive-volume protection, QA MAJOR 2).
//
// Why: `ArchiveVolumeProtection.make` reads volume UUIDs. It used to run
// on the MAIN thread inside `refreshDossierCountsNow` (every debounced
// catalog change), inside `authorizeDuplicateDeletion` (every pair) and
// inside two `.sheet` bodies (every body pass). With FamilyArchive
// offline or renamed it reads EVERY mounted root — and one hung SMB
// server there is a beachball (GH #104 class).
//
// Now:
//   • the snapshot is built OFF the main thread (`@concurrent` — in this
//     project a plain `nonisolated async` func runs on the CALLER's actor,
//     the Approachable Concurrency trap), once per designation change and
//     once per NSWorkspace mount / unmount / rename;
//   • `archiveVolumeProtection()` is O(1): the cached snapshot when it is
//     fresh, otherwise `ArchiveVolumeProtection.provisional` — built with
//     NO disk access — which refuses what it cannot prove, and a rebuild
//     is kicked. Nothing ever reads "clear" because a snapshot is late.
//   • network mounts are never read (they stay unprovable → refused).
//   • the scan targets' search paths ride along as ALIAS CANDIDATES
//     (codex #1642): a scan root that is a symlink / firmlink spelling
//     into FamilyArchive is resolved off-main once per build, so every
//     row spelled through it is refused by string at the final step —
//     Remove / Remove from Catalog / Tidy included, with no per-row disk
//     read on the main thread. A scan-target change makes the snapshot
//     stale like a mount does.
//
// (For Rick: the generation counter is the usual "sequence number on the
// request, drop stale replies" pattern — a rebuild that started before a
// newer invalidation throws its answer away instead of installing it.)

import AppKit
import Foundation
import os

private let archiveVolumeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archive-volume")

/// Storage for the cached snapshot. Lives on the model (stored property in
/// VideoScanModel.swift); every field is main-actor state.
struct ArchiveVolumeSnapshotCache {
    /// Bumped on every invalidation. A rebuild installs its result only
    /// when the generation it started under is still current.
    var generation = 0
    /// The designation the snapshot below was built for.
    var builtFor: MasterArchiveDesignation?
    /// The alias candidates (scan-target search paths) it was built with.
    var builtForCandidates: [String] = []
    /// The designation Initialize resolved to a boot-disk FOLDER — its
    /// provisional snapshot is then exact (codex #1642), not `.unknown`.
    var provenBootFolder: MasterArchiveDesignation?
    var snapshot: ArchiveVolumeProtection?
    /// False from an invalidation until a rebuild for the current
    /// generation lands.
    var isFresh = false
    /// Test hook: rebuilds installed so far.
    var installCount = 0
}

extension VideoScanModel {

    /// The whole-volume snapshot bulk verbs read (nil = no designation).
    /// O(1) and disk-free on every call: the cached snapshot when fresh,
    /// else the provisional one (refuse over guess) while a rebuild runs
    /// off the main thread.
    func archiveVolumeProtection() -> ArchiveVolumeProtection? {
        guard let d = masterArchive else { return nil }
        let cache = archiveVolumeSnapshotCache
        if isArchiveVolumeSnapshotFresh { return cache.snapshot }
        scheduleArchiveVolumeSnapshotRebuild()
        // The last build for THIS designation keeps its proven spellings
        // protected while the new one is built.
        return ArchiveVolumeProtection.provisional(designation: d,
                                                   previous: cache.builtFor == d ? cache.snapshot : nil,
                                                   provenBootFolder: cache.provenBootFolder == d)
    }

    /// True when `archiveVolumeProtection()` is returning a real (built)
    /// snapshot rather than the provisional one.
    var isArchiveVolumeSnapshotFresh: Bool {
        guard let d = masterArchive else { return true }
        let cache = archiveVolumeSnapshotCache
        return cache.isFresh && cache.builtFor == d && cache.builtForCandidates == archiveAliasCandidates
    }

    /// The scan targets' search paths — the spellings catalog rows can
    /// carry. O(targets), a handful.
    var archiveAliasCandidates: [String] {
        scanTargets.map(\.searchPath)
    }

    /// The snapshot plus the volume-UUID probe, captured HERE (task-local
    /// seams do not follow a detached task) for a removal-time re-check
    /// on a disk thread. nil = no designation.
    func archiveRemovalCheck() -> ArchiveRemovalCheck? {
        guard let protection = archiveVolumeProtection() else { return nil }
        return ArchiveRemovalCheck(protection: protection, probe: MasterArchiveDesignation.volumeUUIDProbe,
                                   isProvisional: !isArchiveVolumeSnapshotFresh,
                                   identity: ArchiveVolumeProtection.mountIdentityProbe)
    }

    /// Something the snapshot depends on changed (designation, a mount, an
    /// unmount, a rename): drop it and rebuild off-main.
    func noteArchiveVolumeSnapshotStale(reason: String) {
        archiveVolumeSnapshotCache.generation &+= 1
        archiveVolumeSnapshotCache.isFresh = false
        archiveVolumeSnapshotTask = nil
        guard masterArchive != nil else { return }
        archiveVolumeLog.debug("archive volume snapshot stale (\(reason, privacy: .public)) — rebuilding off-main")
        scheduleArchiveVolumeSnapshotRebuild()
    }

    /// Start ONE off-main rebuild unless one is already running for the
    /// current generation.
    func scheduleArchiveVolumeSnapshotRebuild() {
        guard archiveVolumeSnapshotTask == nil, let d = masterArchive else { return }
        let generation = archiveVolumeSnapshotCache.generation
        let candidates = archiveAliasCandidates
        archiveVolumeSnapshotTask = Task { @MainActor [weak self] in
            let built = await Self.buildArchiveVolumeSnapshot(designation: d, aliasCandidates: candidates)
            self?.installArchiveVolumeSnapshot(built, for: d, candidates: candidates, generation: generation)
        }
    }

    /// Build (off-main) and install a snapshot now, and return what
    /// `archiveVolumeProtection()` answers afterwards. `force` rebuilds
    /// even when the cache is fresh (tests; a verb that must not act on a
    /// snapshot older than the moment it was asked).
    @discardableResult
    func refreshArchiveVolumeSnapshot(force: Bool = false) async -> ArchiveVolumeProtection? {
        guard let d = masterArchive else { return nil }
        if force { archiveVolumeSnapshotCache.generation &+= 1; archiveVolumeSnapshotCache.isFresh = false }
        if isArchiveVolumeSnapshotFresh { return archiveVolumeSnapshotCache.snapshot }
        let generation = archiveVolumeSnapshotCache.generation
        let candidates = archiveAliasCandidates
        let built = await Self.buildArchiveVolumeSnapshot(designation: d, aliasCandidates: candidates)
        installArchiveVolumeSnapshot(built, for: d, candidates: candidates, generation: generation)
        return archiveVolumeProtection()
    }

    /// The disk reads, never on the main thread. `@concurrent` is what
    /// guarantees that here; `nonisolated async` alone would run on the
    /// caller's (main) actor under Approachable Concurrency.
    @concurrent
    nonisolated static func buildArchiveVolumeSnapshot(
        designation: MasterArchiveDesignation, aliasCandidates: [String] = []) async -> ArchiveVolumeProtection? {
        ArchiveVolumeProtection.make(designation: designation, aliasCandidates: aliasCandidates)
    }

    private func installArchiveVolumeSnapshot(_ built: ArchiveVolumeProtection?,
                                              for d: MasterArchiveDesignation, candidates: [String],
                                              generation: Int) {
        if archiveVolumeSnapshotCache.generation == generation { archiveVolumeSnapshotTask = nil }
        guard archiveVolumeSnapshotCache.generation == generation, masterArchive == d else {
            // A newer invalidation (or a new designation) arrived while
            // this one was building: its own rebuild will land.
            if archiveVolumeSnapshotTask == nil { scheduleArchiveVolumeSnapshotRebuild() }
            return
        }
        let changed = archiveVolumeSnapshotCache.snapshot != built || archiveVolumeSnapshotCache.builtFor != d
        archiveVolumeSnapshotCache.builtFor = d
        archiveVolumeSnapshotCache.builtForCandidates = candidates
        archiveVolumeSnapshotCache.snapshot = built
        archiveVolumeSnapshotCache.isFresh = true
        archiveVolumeSnapshotCache.installCount += 1
        if let built {
            archiveVolumeLog.info("archive volume snapshot: \(built.label, privacy: .public) resolved=\(built.isResolved) roots=\(built.archiveRoots.count) provenOther=\(built.provenOtherRoots.count)")
            archiveVolumeLog.info("archive volume snapshot placement=\(String(describing: built.placement), privacy: .public) aliases=\(built.aliasRoots.count) folders=\(built.protectedFolders.count)")
        }
        // The Delete Duplicates menu payload was computed against the
        // provisional snapshot: recompute it against the real one.
        if changed { refreshDossierCountsNow() }
    }

    /// Mount / unmount / rename → the snapshot is stale. Installed once
    /// from the model's init, beside the scan-target mount observers.
    func installArchiveVolumeSnapshotObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didMountNotification,
                                          NSWorkspace.didUnmountNotification,
                                          NSWorkspace.didRenameVolumeNotification]
        archiveVolumeSnapshotObservers = names.map { name in
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let what = note.name.rawValue
                Task { @MainActor in self?.noteArchiveVolumeSnapshotStale(reason: what) }
            }
        }
    }
}
