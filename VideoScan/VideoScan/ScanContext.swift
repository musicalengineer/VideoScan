// ScanContext.swift
// Provenance captured at scan time for each cataloged file.
//
// These fields answer "what machine scanned this file, from what kind of
// volume, and — if the volume was remotely mounted — what was the remote
// server's name?" They are nested on every VideoRecord so downstream
// features (Compare presets, Coverage view, disaster-recovery audits) can
// reason about machine boundaries without guessing.
//
// Capture is intentionally cheap: two syscalls (statfs + URL resource
// values) per file. It runs on every probe — cache hits and cache misses
// alike — so every scan freshens provenance and old records backfill
// naturally as volumes get rescanned.
//
// All fields default to empty strings / nil so records written before this
// struct existed decode cleanly.

import Foundation

struct ScanContext: Codable, Equatable {
    /// Hostname of the machine running the scan (e.g. "MacStudio").
    var scanHost: String = ""

    /// Stable volume identifier pulled from URL resource values. Survives
    /// volume rename and remount. Empty when the filesystem doesn't vend
    /// one (some network mounts, pre-APFS media).
    var volumeUUID: String = ""

    /// Filesystem type string from statfs — "hfs", "apfs", "smbfs", "nfs",
    /// "afpfs", "webdav", "msdos", "exfat", etc. Empty if statfs fails.
    var volumeMountType: String = ""

    /// Human-readable volume name captured at scan time via
    /// `URLResourceValues.volumeName` (e.g. "Macintosh HD", "LaCieWorkspace").
    /// Empty for legacy records written before this field existed.
    var volumeName: String = ""

    /// For remote mounts: the server name (e.g. "macpro.local" from an SMB
    /// `//macpro.local/share` mount). Empty for local filesystems.
    var remoteServerName: String = ""

    /// When the scan that produced this context ran.
    var scannedAt: Date?

    /// When the scan target was a SUBFOLDER (not a whole volume), this is
    /// the basename of that folder — e.g. "Movies" for /Volumes/X/Movies.
    /// Empty when the scan target was the whole volume root.
    ///
    /// Lets the catalog UI disambiguate multiple scan targets with the same
    /// folder name across different volumes ("RicksBackups > Movies" vs
    /// "InternalRaid > Movies").
    var scanRootLabel: String = ""

    /// `true` if this context has any provenance data at all. Useful for
    /// UI that wants to say "provenance not yet captured" for legacy
    /// records.
    var isPopulated: Bool {
        !scanHost.isEmpty || !volumeUUID.isEmpty || !volumeMountType.isEmpty
    }

    /// `true` if the scan ran against a remote (network) filesystem.
    var isRemoteMount: Bool {
        ["smbfs", "nfs", "afpfs", "webdav"].contains(volumeMountType)
    }

    init() {}

    // Custom Codable: decodeIfPresent for every field so partial JSON (including
    // legacy `{}` blobs written before a field existed) decodes cleanly to
    // defaults. Mirrors the forward-compatible pattern used by VideoRecord.
    private enum CodingKeys: String, CodingKey {
        case scanHost, volumeUUID, volumeMountType, volumeName, remoteServerName, scannedAt, scanRootLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanHost         = try c.decodeIfPresent(String.self, forKey: .scanHost) ?? ""
        volumeUUID       = try c.decodeIfPresent(String.self, forKey: .volumeUUID) ?? ""
        volumeMountType  = try c.decodeIfPresent(String.self, forKey: .volumeMountType) ?? ""
        volumeName       = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? ""
        remoteServerName = try c.decodeIfPresent(String.self, forKey: .remoteServerName) ?? ""
        scannedAt        = try c.decodeIfPresent(Date.self, forKey: .scannedAt)
        scanRootLabel    = try c.decodeIfPresent(String.self, forKey: .scanRootLabel) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !scanHost.isEmpty { try c.encode(scanHost, forKey: .scanHost) }
        if !volumeUUID.isEmpty { try c.encode(volumeUUID, forKey: .volumeUUID) }
        if !volumeMountType.isEmpty { try c.encode(volumeMountType, forKey: .volumeMountType) }
        if !volumeName.isEmpty { try c.encode(volumeName, forKey: .volumeName) }
        if !remoteServerName.isEmpty { try c.encode(remoteServerName, forKey: .remoteServerName) }
        try c.encodeIfPresent(scannedAt, forKey: .scannedAt)
        // Only emit scanRootLabel when populated — keeps snapshot deltas minimal
        // for whole-volume scans (the common case).
        if !scanRootLabel.isEmpty { try c.encode(scanRootLabel, forKey: .scanRootLabel) }
    }
}

extension ScanContext {
    /// Capture provenance for a file URL at scan time. Callers should pass
    /// the real on-disk URL, not a RAM-disk prefetch path — the whole
    /// point is to tag where the file actually lives.
    ///
    /// - Parameter scanRootPath: The scan target's `searchPath` (the folder
    ///   the user pointed VideoScan at). When this is a subfolder of a
    ///   volume — e.g. `/Volumes/MyBook/Movies` — its basename is stamped
    ///   into `scanRootLabel` so the UI can disambiguate "Movies" between
    ///   volumes. Pass `nil` to skip (callers that don't know the root, or
    ///   backfill paths where the scan root is meaningless).
    static func capture(for url: URL, scanRootPath: String? = nil, now: Date = Date()) -> ScanContext {
        var ctx = ScanContext()
        ctx.scanHost = CatalogHost.currentName
        ctx.scannedAt = now

        let info = VolumeReachability.mountInfo(forPath: url.path)
        ctx.volumeMountType = info.mountType
        ctx.remoteServerName = info.remoteServer

        if let vals = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey]) {
            if let uuid = vals.volumeUUIDString {
                ctx.volumeUUID = uuid
            }
            if let name = vals.volumeName {
                ctx.volumeName = name
            }
        }

        // Stamp the scan-root label only when the scan target is a SUBFOLDER
        // of a volume, not the volume root itself or "/" — those are
        // already represented adequately by `volumeName`.
        if let rootPath = scanRootPath,
           let label = subfolderLabel(forScanRootPath: rootPath) {
            ctx.scanRootLabel = label
        }
        return ctx
    }

    /// Returns the basename of `scanRootPath` when it is a SUBFOLDER of a
    /// volume (or a non-root path on the system disk). Returns `nil` when
    /// the path is the whole-volume root (`/Volumes/<X>` or `/`) — those
    /// cases need no disambiguation because `volumeName` already covers them.
    ///
    /// Examples:
    ///   `/Volumes/MyBook`                  → nil      (whole volume)
    ///   `/Volumes/MyBook/`                 → nil      (trailing slash)
    ///   `/Volumes/MyBook/Movies`           → "Movies"
    ///   `/Volumes/MyBook/Movies/2024`      → "2024"
    ///   `/`                                → nil      (root)
    ///   `/Users/rickb/Movies`              → "Movies"
    ///   `""`                               → nil
    static func subfolderLabel(forScanRootPath scanRootPath: String) -> String? {
        // Strip trailing slashes so `/Volumes/X/` and `/Volumes/X` behave the
        // same. Swift's `URL.standardizedFileURL` would do this too, but a
        // small string trim is cheaper and doesn't touch the filesystem.
        var path = scanRootPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty, path != "/" else { return nil }

        let comps = (path as NSString).pathComponents
        // /Volumes/<X>     → 3 comps ["/", "Volumes", "X"] — whole volume, no label
        // /Volumes/<X>/<Y> → 4+ comps — subfolder, label = last component
        if comps.count >= 2 && comps[1] == "Volumes" {
            return comps.count >= 4 ? comps.last : nil
        }
        // For paths NOT under /Volumes (e.g. /Users/rickb/Movies), any non-root
        // path is treated as a subfolder. The volume IS the system disk and
        // its name ("Macintosh HD") doesn't naturally embed a useful tail, so
        // exposing the folder name helps the UI either way.
        return (path as NSString).lastPathComponent
    }
}
