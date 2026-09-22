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
// volume?" — answered from a snapshot taken once per verb (a handful of
// mount-table / volume-UUID reads, never one per record), so the question
// itself is a couple of string operations and is safe to ask of 100k
// records. The model's `bulkDeleteRefusal` / `excludingMasterArchiveFiles`
// (VideoScanModel+MasterArchive.swift) are the only callers that turn it
// into a refusal; every verb that removes files goes through them.
//
// Identity, strongest first (the designation's own rules):
//   1. the volume UUID captured at Initialize — a renamed or remounted
//      FamilyArchive ("/Volumes/FamilyArchive 1") is still protected;
//   2. the designated path's own volume root — protected even when a
//      different disk is mounted there (refuse over guess).
// When a UUID is recorded but the archive volume cannot be found mounted,
// a /Volumes path whose drive cannot be PROVEN to be another volume is
// refused ("unprovable") rather than guessed about.
//
// An archive designated on the boot disk (a folder, not a /Volumes
// volume — what the test sandboxes do) protects that FOLDER, not the
// whole boot disk: protecting "/" would forbid deleting anything in
// ~/Movies, which is not what "almost read only" means.
//
// (For Rick: `Sendable` value type ≈ an immutable C++ struct you can hand
// to another thread by copy; the `@TaskLocal` seams below are like a
// thread_local override that tests install for one scope only.)

import Foundation

struct ArchiveVolumeProtection: Sendable, Equatable {

    enum Verdict: Equatable, Sendable {
        /// Proven NOT to be on the Master Archive volume.
        case clear
        /// On the Master Archive volume (by UUID or by its path).
        case onArchiveVolume
        /// The archive volume is not connected, and this path's drive
        /// cannot be proven to be a different one.
        case unprovable
    }

    /// Display name for the log line ("FamilyArchive").
    let label: String
    /// Lower-cased "/Volumes/<name>" roots that ARE the archive volume.
    let archiveRoots: Set<String>
    /// Archive designated on the boot disk: the designated folder, the
    /// only region protected there. nil for a /Volumes archive.
    let protectedFolder: String?
    /// The designation's volume UUID, when one was recorded.
    let expectedUUID: String?
    /// The archive volume was found mounted (or no UUID exists to look
    /// for — then the path is the whole identity).
    let isResolved: Bool
    /// Lower-cased mounted /Volumes roots whose UUID was read and differs.
    let provenOtherRoots: Set<String>

    // MARK: Building (once per verb)

    /// Mounted /Volumes roots. Task-local test seam (never process-global).
    @TaskLocal static var mountedVolumeRootsProbe: @Sendable () -> [String] = {
        VolumeReachability.currentMountedRoots().filter { $0.hasPrefix("/Volumes/") }.sorted()
    }

    /// nil when no Master Archive is designated (nothing beyond the old
    /// tree rule applies). `probe` = the volume-UUID read
    /// (`MasterArchiveDesignation.volumeUUID(forPath:)` in production).
    static func make(designation d: MasterArchiveDesignation?,
                     mountedRoots: () -> [String] = { mountedVolumeRootsProbe() },
                     probe: (String) -> String? = { MasterArchiveDesignation.volumeUUID(forPath: $0) })
        -> ArchiveVolumeProtection? {
        guard let d else { return nil }
        let target = canonical(d.targetPath)
        guard let targetRoot = externalVolumeRoot(of: target) else {
            // Boot-disk archive: the designated folder only.
            return ArchiveVolumeProtection(label: (target as NSString).lastPathComponent,
                                           archiveRoots: [], protectedFolder: target,
                                           expectedUUID: d.volumeUUID, isResolved: true,
                                           provenOtherRoots: [])
        }
        let label = String(targetRoot.dropFirst("/Volumes/".count))
        var roots: Set<String> = [targetRoot.lowercased()]
        guard let uuid = d.volumeUUID else {
            return ArchiveVolumeProtection(label: label, archiveRoots: roots, protectedFolder: nil,
                                           expectedUUID: nil, isResolved: true, provenOtherRoots: [])
        }
        // The usual case costs ONE read: the designated root is mounted
        // and carries the UUID, so no other volume can.
        if probe(targetRoot) == uuid {
            return ArchiveVolumeProtection(label: label, archiveRoots: roots, protectedFolder: nil,
                                           expectedUUID: uuid, isResolved: true, provenOtherRoots: [])
        }
        // Renamed / remounted / offline: read every mounted volume once.
        var resolved = false
        var others = Set<String>()
        for m in mountedRoots() {
            guard let root = externalVolumeRoot(of: canonical(m)) else { continue }
            let key = root.lowercased()
            if key == targetRoot.lowercased() { continue }   // already protected by path
            switch probe(root) {
            case uuid?: roots.insert(key); resolved = true
            case .some: others.insert(key)
            case nil: break                                   // no UUID → cannot prove
            }
        }
        return ArchiveVolumeProtection(label: label, archiveRoots: roots, protectedFolder: nil,
                                       expectedUUID: uuid, isResolved: resolved, provenOtherRoots: others)
    }

    // MARK: Asking (per record — string work only)

    func verdict(forPath raw: String) -> Verdict {
        guard !raw.isEmpty else { return .clear }
        let path = Self.canonicalIfNeeded(raw)
        if let folder = protectedFolder {
            if path.lowercased().hasPrefix(folder.lowercased()),
               ArchivePathResolver.isInside(path: path.lowercased(), root: folder.lowercased()) {
                return .onArchiveVolume
            }
            return .clear
        }
        // The boot disk is never the archive volume here: the archive was
        // designated under /Volumes, so it is an external mount.
        guard let root = Self.externalVolumeRoot(of: path)?.lowercased() else { return .clear }
        if archiveRoots.contains(root) { return .onArchiveVolume }
        if isResolved || provenOtherRoots.contains(root) { return .clear }
        return .unprovable
    }

    /// The last word, immediately before a file's own trash/remove, off
    /// the main actor: the snapshot's verdict, then a fresh read of the
    /// file's OWN volume UUID (a volume mounted since the snapshot).
    func verdictAtRemoval(path: String, probe: (String) -> String?) -> Verdict {
        let v = verdict(forPath: path)
        guard v == .clear else { return v }
        // Whole-volume protection only: a boot-disk archive shares its
        // volume UUID with every file on the boot disk, and only its
        // FOLDER is protected (the verdict above already answered that).
        guard protectedFolder == nil else { return .clear }
        if let uuid = expectedUUID, probe(path) == uuid { return .onArchiveVolume }
        return .clear
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

    private static func canonical(_ path: String) -> String {
        PathScope.normalize(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// Standardize only when the path could be hiding a different volume
    /// behind "." / ".." / "//" — scanned paths never are.
    private static func canonicalIfNeeded(_ path: String) -> String {
        if path.contains("/./") || path.contains("/../") || path.contains("//")
            || path.hasSuffix("/.") || path.hasSuffix("/..") {
            return canonical(path)
        }
        return path
    }
}
