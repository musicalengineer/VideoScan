// ArchiveVolumeProtection.swift
//
// Rick, 2026-09-22: "the app should never offer to delete from
// FamilyArchive since it is almost read only except for dropping in
// videos, photos, promotions etc."
//
// Until now only the Breen_Family_Archive TREE was protected from bulk
// verbs. The rest of the volume that hosts it (MoviesExpansion,
// RecordingProjectArchives, Hallie, ancestry, loose scans at the root)
// was fair game for Delete Duplicates, Delete Confirmed Junk, ⌘⌫,
// Discard and "Archived — what next?" → Move to Trash.
//
// This file is the ONE rule: "is this path on the Master Archive's
// volume?" — answered from a snapshot (a handful of mount-table /
// volume-UUID reads, never one per record), so the question itself is a
// couple of string operations and is safe to ask of 100k records. The
// model's `bulkDeleteRefusal` / `excludingMasterArchiveFiles`
// (VideoScanModel+MasterArchive.swift) are the only callers that turn it
// into a refusal; every verb that removes files goes through them.
//
// Where the snapshot comes from (2026-09-22 follow-up, QA MAJOR 2): the
// model holds ONE cached snapshot, rebuilt OFF the main thread when the
// designation changes, when the scan targets change, and on every mount /
// unmount / rename (VideoScanModel+ArchiveVolumeSnapshot.swift). Until a
// fresh one lands, callers get `provisional(designation:previous:)` —
// built with NO disk access — which refuses whatever it cannot prove
// (refuse over guess) and says so (`isProvisional`). The build itself
// (`make`) reads mount identities and volume UUIDs and must never run on
// the main thread: with FamilyArchive offline it reads every mounted
// root, and a hung SMB server there used to beachball the app (GH #104).
//
// BOOT FOLDER OR EXTERNAL VOLUME — decided from the MOUNT, never from the
// spelling (codex #1642, 2026-09-23). Before this, any designation not
// literally under "/Volumes/" was taken for a boot-disk folder, which
// switched off whole-volume UUID protection. Designating FamilyArchive as
// "/System/Volumes/Data/Volumes/FamilyArchive" (the firmlink spelling), a
// symlink, or a custom mount point left the canonical
// "/Volumes/FamilyArchive/MoviesExpansion/a.mov" unprotected. Now:
//   • the designated path is resolved (realpath) and its mount point read
//     (statfs f_mntonname) — `mountIdentityProbe`, off-main;
//   • mount point "/" or "/System/Volumes/…" = the boot disk → a FOLDER
//     archive (see below); anything else → an EXTERNAL VOLUME, protected
//     whole, by UUID, wherever it is mounted;
//   • a designation that cannot be resolved right now (dangling symlink,
//     unmounted custom mount) is external when its recorded UUID is not
//     the boot disk's.
//
// Identity for an external volume, strongest first:
//   1. the volume UUID captured at Initialize — a renamed or remounted
//      FamilyArchive ("/Volumes/FamilyArchive 1") is still protected;
//   2. the designated path's own volume root, and every spelling the
//      snapshot proved lands on the archive's mount (the designation's
//      alias, a scan target that is a symlink into it) — protected even
//      when a different disk is mounted there (refuse over guess).
// When a UUID is recorded but the archive volume cannot be found mounted,
// a /Volumes path whose drive cannot be PROVEN to be another volume is
// "unprovable". Network mounts are never read (a hung server) and so are
// never proven.
//
// An archive designated on the boot disk (a folder, not a volume — what
// the test sandboxes do) protects that FOLDER, not the whole boot disk:
// protecting "/" would forbid deleting anything in ~/Movies, which is not
// what "almost read only" means.
//
// (For Rick: `Sendable` value type ≈ an immutable C++ struct you can hand
// to another thread by copy; the `@TaskLocal` seams below are like a
// thread_local override that tests install for one scope only.)

import Darwin
import Foundation

/// Where a path really lives: its symlink-free path and the mount point
/// of its filesystem (≈ `realpath(3)` + `statfs(2).f_mntonname`).
struct MountIdentity: Sendable, Equatable {
    let resolvedPath: String
    let mountPoint: String
}

struct ArchiveVolumeProtection: Sendable, Equatable {

    enum Verdict: Equatable, Sendable {
        /// Proven NOT to be on the Master Archive volume.
        case clear
        /// On the Master Archive volume (by UUID or by its path).
        case onArchiveVolume
        /// The archive volume is not connected (or the snapshot is still
        /// being built), and this path's drive cannot be proven to be a
        /// different one.
        case unprovable
    }

    /// What the designation turned out to be.
    enum Placement: Sendable, Equatable {
        /// A folder on the boot disk — only the folder is protected.
        case bootFolder
        /// A whole external volume — protected by UUID wherever mounted.
        case externalVolume
        /// Not known yet (provisional snapshot of a designation whose
        /// spelling does not say): folder protected, /Volumes refused.
        case unknown
    }

    /// Display name for the log line ("FamilyArchive").
    let label: String
    let placement: Placement
    /// Lower-cased "/Volumes/<name>" roots that ARE the archive volume.
    let archiveRoots: Set<String>
    /// Lower-cased NON-"/Volumes/<name>" prefixes that are on the archive
    /// volume: a custom mount point, the designation's alias spelling, a
    /// scan target that is a symlink into the volume. Usually empty.
    let aliasRoots: [String]
    /// Lower-cased folders protected for a boot-disk archive (the
    /// designated spelling, its realpath, scan-target aliases of it).
    /// Empty for an external volume.
    let protectedFolders: [String]
    /// The designation's volume UUID, when one was recorded (or read).
    let expectedUUID: String?
    /// The archive volume was found mounted (or no UUID exists to look
    /// for — then the path is the whole identity).
    let isResolved: Bool
    /// Lower-cased mounted roots whose UUID was read and differs.
    let provenOtherRoots: Set<String>
    /// Built without disk access while the real snapshot is (re)built.
    /// Its "unprovable" is TRANSIENT.
    let isProvisional: Bool

    // MARK: Seams

    /// Mounted LOCAL roots other than the boot disk — network mounts are
    /// left out so a hung server is never read. Includes custom mount
    /// points outside /Volumes (codex #1642). Task-local test seam (never
    /// process-global).
    @TaskLocal static var mountedVolumeRootsProbe: @Sendable () -> [String] = {
        VolumeReachability.currentLocalMountedRoots().filter { !isBootMountPoint($0) }.sorted()
    }

    /// realpath + statfs of `path`; nil when it does not resolve (missing,
    /// dangling symlink). DISK I/O. Task-local test seam.
    @TaskLocal static var mountIdentityProbe: @Sendable (String) -> MountIdentity? = { liveMountIdentity($0) }

    /// Network mount points (in-memory mount table — no server round
    /// trip). Scan-target aliases on them are never resolved.
    @TaskLocal static var networkMountRootsProbe: @Sendable () -> [String] = {
        Array(VolumeReachability.currentMountedRoots().subtracting(VolumeReachability.currentLocalMountedRoots()))
    }

    nonisolated static func liveMountIdentity(_ path: String) -> MountIdentity? {
        guard let raw = realpath(path, nil) else { return nil }
        defer { free(raw) }
        let resolved = String(cString: raw)
        var fs = statfs()
        guard statfs(resolved, &fs) == 0 else { return nil }
        let mountPoint = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return MountIdentity(resolvedPath: resolved, mountPoint: mountPoint)
    }

    // MARK: Building

    /// The full build: resolves where the designation really lives, reads
    /// the archive's volume UUID and, when the archive is not found there,
    /// every mounted local root's; resolves `aliasCandidates` (the scan
    /// targets' search paths) that land on the archive. DISK I/O — call it
    /// off the main thread (the model's cache does). nil when no Master
    /// Archive is designated. `probe` = the volume-UUID read.
    static func make(designation d: MasterArchiveDesignation?,
                     aliasCandidates: [String] = [],
                     mountedRoots: () -> [String] = { mountedVolumeRootsProbe() },
                     probe: (String) -> String? = { MasterArchiveDesignation.volumeUUID(forPath: $0) },
                     identity: (String) -> MountIdentity? = { mountIdentityProbe($0) },
                     networkRoots: () -> [String] = { networkMountRootsProbe() })
        -> ArchiveVolumeProtection? {
        guard let d else { return nil }
        let spelled = canonical(d.targetPath)
        let spelledRoot = externalVolumeRoot(of: spelled)
        // A "/Volumes/X" whose mount point reads as the boot disk is an
        // empty leftover directory of an unmounted volume — not the archive.
        let mounted = identity(spelled).flatMap { isBootMountPoint($0.mountPoint) && spelledRoot != nil ? nil : $0 }

        // ── Boot folder or external volume: from the mount, not the text.
        let external: Bool
        if spelledRoot != nil {
            external = true
        } else if let mounted, !isBootMountPoint(mounted.mountPoint) {
            external = true
        } else if let uuid = d.volumeUUID {
            // On the boot disk now, or not resolvable: only the boot
            // disk's own UUID makes it a folder archive (a custom mount's
            // leftover directory reads as the boot disk while unmounted).
            if let boot = probe("/") {
                external = boot != uuid
            } else {
                // Boot UUID unreadable (never seen in production): trust
                // the mount when there is one; unresolvable → external.
                external = mounted == nil
            }
        } else {
            external = false   // no UUID: the path is the whole identity
        }

        guard external else {
            return makeBootFolder(spelled: spelled, mounted: mounted, uuid: d.volumeUUID,
                                  aliasCandidates: aliasCandidates, identity: identity, networkRoots: networkRoots)
        }

        // ── External volume.
        var roots = Set<String>()
        var aliases: [String] = []
        func addRoot(_ p: String) {
            let c = canonical(p)
            if let r = externalVolumeRoot(of: c) { roots.insert(r.lowercased()) }
            else if !aliases.contains(c.lowercased()) { aliases.append(c.lowercased()) }
        }
        addRoot(spelledRoot ?? spelled)   // the designated spelling (refuse over guess)
        // Never the boot disk's mount point: an external archive that reads
        // as "on the boot disk" is an unmounted custom mount's directory.
        let mountedPoint = mounted.flatMap { isBootMountPoint($0.mountPoint) ? nil : canonical($0.mountPoint) }
        let expected = d.volumeUUID ?? mountedPoint.flatMap { probe($0) }
        var resolved = false
        var archiveMounts = Set<String>()   // lower-cased mount points proven to be the archive
        // The usual case costs ONE read: the designated mount carries the
        // UUID, so no other volume can.
        if let mountedPoint {
            if let expected, probe(mountedPoint) == expected {
                addRoot(mountedPoint); archiveMounts.insert(mountedPoint.lowercased()); resolved = true
            } else if expected == nil {
                addRoot(mountedPoint); archiveMounts.insert(mountedPoint.lowercased())
            }
        } else if let root = spelledRoot, let expected, probe(root) == expected {
            archiveMounts.insert(root.lowercased()); resolved = true
        }
        var others = Set<String>()
        if !resolved, let expected {
            // Renamed / remounted / offline: read every mounted volume once.
            for m in mountedRoots() {
                let c = canonical(m)
                guard !isBootMountPoint(c) else { continue }
                let key = externalVolumeRoot(of: c) ?? c
                let lower = key.lowercased()
                if lower == spelledRoot?.lowercased() || lower == mountedPoint?.lowercased() { continue }
                switch probe(key) {
                case expected?: addRoot(key); archiveMounts.insert(lower); resolved = true
                case .some: others.insert(lower)
                case nil: break                                   // no UUID → cannot prove
                }
            }
        }
        if expected == nil { resolved = true }   // no UUID: the path is the whole identity
        // Scan targets whose real mount IS the archive's (a symlinked scan
        // root, a firmlink spelling): rows spelled through them are on it.
        if !archiveMounts.isEmpty {
            let network = networkRoots().map { canonical($0).lowercased() }
            for c in aliasCandidates {
                let spelledC = canonical(c)
                let lower = spelledC.lowercased()
                guard !lower.isEmpty, lower != "/",
                      !network.contains(where: { isInsideLexically(path: lower, root: $0) }) else { continue }
                if let r = externalVolumeRoot(of: spelledC)?.lowercased(), roots.contains(r) { continue }
                if aliases.contains(where: { isInsideLexically(path: lower, root: $0) }) { continue }
                guard let cid = identity(spelledC),
                      archiveMounts.contains(canonical(cid.mountPoint).lowercased()) else { continue }
                aliases.append(lower)
            }
        }
        let labelSource = spelledRoot ?? mountedPoint ?? spelled
        return ArchiveVolumeProtection(label: (labelSource as NSString).lastPathComponent,
                                       placement: .externalVolume, archiveRoots: roots, aliasRoots: aliases,
                                       protectedFolders: [], expectedUUID: expected, isResolved: resolved,
                                       provenOtherRoots: others, isProvisional: false)
    }

    private static func makeBootFolder(spelled: String, mounted: MountIdentity?, uuid: String?,
                                       aliasCandidates: [String],
                                       identity: (String) -> MountIdentity?,
                                       networkRoots: () -> [String]) -> ArchiveVolumeProtection {
        var folders = [spelled.lowercased()]
        let real = mounted.map { canonical($0.resolvedPath) }
        // Both spellings of the real folder: realpath keeps "/private/var…",
        // URL standardizing drops the "/private" (the /tmp ≡ /private/tmp pair).
        for spelling in [real, mounted?.resolvedPath].compactMap({ $0?.lowercased() }) where !folders.contains(spelling) {
            folders.append(spelling)
        }
        if let real, !aliasCandidates.isEmpty {
            let network = networkRoots().map { canonical($0).lowercased() }
            for c in aliasCandidates {
                let spelledC = canonical(c)
                let lower = spelledC.lowercased()
                guard lower != "/", !network.contains(where: { isInsideLexically(path: lower, root: $0) }),
                      !folders.contains(where: { isInsideLexically(path: lower, root: $0) }),
                      let cid = identity(spelledC) else { continue }
                let creal = canonical(cid.resolvedPath)
                if isInsideLexically(path: creal, root: real) {
                    folders.append(lower)                       // the scan target is inside the folder
                } else if isInsideLexically(path: real, root: creal) {
                    // The folder spelled through the scan target's alias.
                    let tail = String(real.dropFirst(creal.count))
                    let alias = (spelledC == "/" ? "" : spelledC) + tail
                    if !folders.contains(alias.lowercased()) { folders.append(alias.lowercased()) }
                }
            }
        }
        return ArchiveVolumeProtection(label: (spelled as NSString).lastPathComponent,
                                       placement: .bootFolder, archiveRoots: [], aliasRoots: [],
                                       protectedFolders: folders, expectedUUID: uuid, isResolved: true,
                                       provenOtherRoots: [], isProvisional: false)
    }

    /// The snapshot to use while the real one is being (re)built: NO disk
    /// access at all, so it is safe on the main thread. `previous` = the
    /// last built snapshot FOR THE SAME designation, whose proven archive
    /// spellings stay protected; what mounts where may have changed, so an
    /// external archive with a UUID is treated as unresolved (every other
    /// /Volumes path is refused as unprovable — refuse over guess, never
    /// "clear" by default).
    /// `provenBootFolder` = Initialize already resolved this designation
    /// to a folder on the boot disk (`isProvenBootFolder`), so its first
    /// provisional snapshot is exact instead of `.unknown`.
    static func provisional(designation d: MasterArchiveDesignation?,
                            previous: ArchiveVolumeProtection? = nil,
                            provenBootFolder: Bool = false) -> ArchiveVolumeProtection? {
        guard let d else { return nil }
        if let previous {
            let unresolve = previous.placement != .bootFolder && previous.expectedUUID != nil
            return ArchiveVolumeProtection(label: previous.label, placement: previous.placement,
                                           archiveRoots: previous.archiveRoots, aliasRoots: previous.aliasRoots,
                                           protectedFolders: previous.protectedFolders,
                                           expectedUUID: previous.expectedUUID,
                                           isResolved: unresolve ? false : previous.isResolved,
                                           provenOtherRoots: unresolve ? [] : previous.provenOtherRoots,
                                           isProvisional: true)
        }
        let spelled = canonical(d.targetPath)
        if let root = externalVolumeRoot(of: spelled) {
            // No UUID: the path is the whole identity — exact without disk.
            let exact = d.volumeUUID == nil
            return ArchiveVolumeProtection(label: String(root.dropFirst("/Volumes/".count)),
                                           placement: .externalVolume, archiveRoots: [root.lowercased()],
                                           aliasRoots: [], protectedFolders: [], expectedUUID: d.volumeUUID,
                                           isResolved: exact, provenOtherRoots: [], isProvisional: !exact)
        }
        if provenBootFolder {
            return ArchiveVolumeProtection(label: (spelled as NSString).lastPathComponent,
                                           placement: .bootFolder, archiveRoots: [], aliasRoots: [],
                                           protectedFolders: [spelled.lowercased()], expectedUUID: d.volumeUUID,
                                           isResolved: true, provenOtherRoots: [], isProvisional: true)
        }
        // Not under /Volumes: a boot folder, a symlink, or a custom mount —
        // only the disk can tell. Protect the spelling; refuse /Volumes.
        return ArchiveVolumeProtection(label: (spelled as NSString).lastPathComponent,
                                       placement: .unknown, archiveRoots: [], aliasRoots: [],
                                       protectedFolders: [spelled.lowercased()], expectedUUID: d.volumeUUID,
                                       isResolved: false, provenOtherRoots: [], isProvisional: true)
    }

    /// True when `targetPath` (already canonical) is a folder on the boot
    /// disk: not a /Volumes spelling, its mount point is the boot disk's,
    /// and its recorded UUID (if any) is the boot disk's. ONE realpath +
    /// statfs + one UUID read — for Initialize, which has just read and
    /// written that very path on the main thread anyway.
    static func isProvenBootFolder(targetPath: String, volumeUUID: String?,
                                   probe: (String) -> String? = { MasterArchiveDesignation.volumeUUID(forPath: $0) },
                                   identity: (String) -> MountIdentity? = { mountIdentityProbe($0) }) -> Bool {
        let spelled = canonical(targetPath)
        guard externalVolumeRoot(of: spelled) == nil,
              let id = identity(spelled), isBootMountPoint(id.mountPoint) else { return false }
        guard let volumeUUID else { return true }
        return probe("/") == volumeUUID
    }

    // MARK: Asking (per record — string work only)

    func verdict(forPath raw: String) -> Verdict {
        guard !raw.isEmpty else { return .clear }
        let path = Self.canonicalIfNeeded(raw)
        let lower = path.lowercased()
        for folder in protectedFolders where lower.hasPrefix(folder) {
            if Self.isInsideLexically(path: lower, root: folder) { return .onArchiveVolume }
        }
        for alias in aliasRoots where lower.hasPrefix(alias) {
            if Self.isInsideLexically(path: lower, root: alias) { return .onArchiveVolume }
        }
        if placement == .bootFolder { return .clear }
        // The boot disk is never an external archive; a custom mount that
        // is not one of the alias roots is decided at removal (UUID).
        guard let root = Self.externalVolumeRoot(of: path)?.lowercased() else { return .clear }
        if archiveRoots.contains(root) { return .onArchiveVolume }
        if isResolved || provenOtherRoots.contains(root) { return .clear }
        return .unprovable
    }

    /// The last word, immediately before a file's own trash/remove, off
    /// the main actor: the snapshot's verdict; then the verdict for the
    /// file's REAL path (a symlinked or firmlink-spelled parent); then a
    /// fresh read of the file's OWN volume UUID (a volume mounted since
    /// the snapshot, a custom mount path whose text hides the volume).
    func verdictAtRemoval(path: String, probe: (String) -> String?,
                          identity: (String) -> MountIdentity? = { ArchiveVolumeProtection.mountIdentityProbe($0) })
        -> Verdict {
        let v = verdict(forPath: path)
        guard v == .clear else { return v }
        if let real = Self.resolvedPath(of: path, identity: identity), real != path {
            let v2 = verdict(forPath: real)
            if v2 != .clear { return v2 }
        }
        switch placement {
        case .bootFolder:
            // A boot-disk archive shares its volume UUID with every file on
            // the boot disk, and only its FOLDER is protected (answered above).
            return .clear
        case .externalVolume:
            if let uuid = expectedUUID, probe(path) == uuid { return .onArchiveVolume }
            return .clear
        case .unknown:
            // Could be a boot folder (every boot file shares its UUID):
            // cannot tell yet — transient, never a recorded refusal.
            if let uuid = expectedUUID, probe(path) == uuid { return .unprovable }
            return .clear
        }
    }

    /// The symlink-free, firmlink-canonical path of `path` (or, for a file
    /// that does not exist, of its parent + name). nil when neither resolves.
    private static func resolvedPath(of path: String, identity: (String) -> MountIdentity?) -> String? {
        if let id = identity(path) { return canonical(id.resolvedPath) }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path, let id = identity(parent) else { return nil }
        return canonical((id.resolvedPath as NSString).appendingPathComponent((path as NSString).lastPathComponent))
    }

    // MARK: Path helpers (pure)

    /// "/Volumes/<name>" for a path on an external mount, else nil.
    /// Two string scans, no URL parsing — asked once per record.
    static func externalVolumeRoot(of path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let rest = path.dropFirst("/Volumes/".count)
        let name = rest.prefix { $0 != "/" }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return "/Volumes/" + name
    }

    /// Component-wise "is `path` at or under `root`" on text ALREADY
    /// canonical (both sides via `canonical` / `canonicalIfNeeded`). Pure:
    /// `ArchivePathResolver.isInside` standardizes through NSURL, which
    /// drops "/private" only when the path EXISTS — a missing file under
    /// an existing folder then compares unequal, and the check touches the
    /// disk per record. Never contains everything: a root of "/" is refused.
    static func isInsideLexically(path: String, root: String) -> Bool {
        guard root.count > 1 else { return false }
        return path == root || (path.hasPrefix(root) && path.dropFirst(root.count).first == "/")
    }

    /// Mount points that belong to the boot disk: "/" and the APFS
    /// system/data group under "/System/Volumes/" (Data, Preboot, VM, …).
    static func isBootMountPoint(_ mountPoint: String) -> Bool {
        mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes/")
    }

    /// The boot disk's data-volume FIRMLINKS for the two trees a media
    /// path can be spelled through: "/System/Volumes/Data/Volumes/X" IS
    /// "/Volumes/X", "/System/Volumes/Data/Users/…" IS "/Users/…".
    static func strippingDataFirmlink(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        guard path.hasPrefix(data + "/") else { return path }
        let rest = String(path.dropFirst(data.count))
        return rest.hasPrefix("/Volumes/") || rest.hasPrefix("/Users/") ? rest : path
    }

    static func canonical(_ path: String) -> String {
        strippingDataFirmlink(PathScope.normalize(URL(fileURLWithPath: path).standardizedFileURL.path))
    }

    /// Standardize only when the path could be hiding a different volume
    /// behind "." / ".." / "//" or the data-volume firmlink — scanned
    /// paths never are.
    private static func canonicalIfNeeded(_ path: String) -> String {
        if path.contains("/./") || path.contains("/../") || path.contains("//")
            || path.hasSuffix("/.") || path.hasSuffix("/..") || path.hasPrefix("/System/Volumes/Data/") {
            return canonical(path)
        }
        return path
    }
}

// MARK: - The removal-time check, packaged to cross to a disk thread

/// A snapshot plus the volume-UUID and mount-identity probes, captured on
/// the main actor and handed to the thread that performs a removal.
/// Task-local seams do not follow a `Task.detached`, so the probes are
/// captured HERE, where they are visible, not looked up on the disk thread.
///
/// `refusalNote(forPath:)` is the exact wording the bulk verbs use
/// (`VideoScanModel.bulkDeleteRefusalNote`), so a Delete Duplicates row,
/// a Junk row and a Transcode "kept beside" line read the same.
struct ArchiveRemovalCheck: Sendable {
    let protection: ArchiveVolumeProtection
    let probe: @Sendable (String) -> String?
    /// Captured while the model's snapshot was being rebuilt (the
    /// provisional one). Its "unprovable" is then TRANSIENT — the caller
    /// leaves the file alone and must not record a refusal (QA 2026-09-22).
    var isProvisional: Bool = false
    /// realpath + statfs, captured with the UUID probe (codex #1642).
    var identity: @Sendable (String) -> MountIdentity? = ArchiveVolumeProtection.mountIdentityProbe

    /// nil = may be removed; else the note, and whether the refusal is
    /// only transient (provisional snapshot + unprovable).
    func refusal(forPath path: String) -> (note: String, transient: Bool)? {
        let verdict = protection.verdictAtRemoval(path: path, probe: probe, identity: identity)
        guard let note = Self.note(verdict, label: protection.label) else { return nil }
        return (note, (isProvisional || protection.isProvisional) && verdict == .unprovable)
    }

    private static func note(_ verdict: ArchiveVolumeProtection.Verdict, label: String) -> String? {
        switch verdict {
        case .clear: return nil
        case .onArchiveVolume: return VideoScanModel.bulkDeleteRefusalNote(.archiveVolume, volume: label)
        case .unprovable: return VideoScanModel.bulkDeleteRefusalNote(.archiveVolumeUnprovable, volume: label)
        }
    }

    /// nil = this file may be removed; else why not. DISK I/O (one UUID
    /// read of `path`'s own volume, one realpath) — call it off the main thread.
    func refusalNote(forPath path: String) -> String? {
        refusal(forPath: path)?.note
    }
}
