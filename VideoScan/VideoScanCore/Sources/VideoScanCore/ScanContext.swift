// ScanContext.swift
// Provenance captured at scan time for each cataloged file.
//
// These fields answer "what machine scanned this file, from what kind of
// volume, and — if the volume was remotely mounted — what was the remote
// server's name?" They are nested on every VideoRecord so downstream
// features (Compare presets, Coverage view, disaster-recovery audits) can
// reason about machine boundaries without guessing.
//
// All fields default to empty strings / nil so records written before this
// struct existed decode cleanly.
//
// Package-extraction note (2026-06-26): this is the PURE, Foundation-only
// half of ScanContext — the struct, its Codable, the `isPopulated` /
// `isRemoteMount` predicates, and the `subfolderLabel(forScanRootPath:)`
// pure-string helper. The `capture(for:scanRootPath:)` FACTORY stayed
// app-side (ModelsUI/ScanContext+Capture.swift) because it depends on
// CatalogHost + VolumeReachability — app infrastructure that has no place in
// the domain package. `subfolderLabel` is `public` here because
// VolumeReachability.displayLabel (app-side, via @_exported) calls it.

import Foundation

public struct ScanContext: Codable, Equatable, Sendable {
    /// Hostname of the machine running the scan (e.g. "MacStudio").
    public var scanHost: String = ""

    /// Stable volume identifier pulled from URL resource values. Survives
    /// volume rename and remount. Empty when the filesystem doesn't vend
    /// one (some network mounts, pre-APFS media).
    public var volumeUUID: String = ""

    /// Filesystem type string from statfs — "hfs", "apfs", "smbfs", "nfs",
    /// "afpfs", "webdav", "msdos", "exfat", etc. Empty if statfs fails.
    public var volumeMountType: String = ""

    /// Human-readable volume name captured at scan time via
    /// `URLResourceValues.volumeName` (e.g. "Macintosh HD", "LaCieWorkspace").
    /// Empty for legacy records written before this field existed.
    public var volumeName: String = ""

    /// For remote mounts: the server name (e.g. "macpro.local" from an SMB
    /// `//macpro.local/share` mount). Empty for local filesystems.
    public var remoteServerName: String = ""

    /// When the scan that produced this context ran.
    public var scannedAt: Date?

    /// When the scan target was a SUBFOLDER (not a whole volume), this is
    /// the basename of that folder — e.g. "Movies" for /Volumes/X/Movies.
    /// Empty when the scan target was the whole volume root.
    ///
    /// Lets the catalog UI disambiguate multiple scan targets with the same
    /// folder name across different volumes ("RicksBackups > Movies" vs
    /// "InternalRaid > Movies").
    public var scanRootLabel: String = ""

    /// When the file lives INSIDE a pro-video project bundle (.fcpbundle,
    /// .imovielibrary, .rcproject, …), this is the path of the enclosing
    /// bundle directory. Empty for ordinary files. Additive (2026-07-02,
    /// "Look Inside Video Project Bundles"): decodeIfPresent below means
    /// old catalogs without the key decode cleanly to "". Path-derived
    /// (ProVideoBundles.container(forPath:)), so it refreshes on every
    /// probe alongside the rest of the context.
    public var bundleContainer: String = ""

    /// `true` if this context has any provenance data at all. Useful for
    /// UI that wants to say "provenance not yet captured" for legacy
    /// records.
    public var isPopulated: Bool {
        !scanHost.isEmpty || !volumeUUID.isEmpty || !volumeMountType.isEmpty
    }

    /// `true` if the scan ran against a remote (network) filesystem.
    public var isRemoteMount: Bool {
        ["smbfs", "nfs", "afpfs", "webdav"].contains(volumeMountType)
    }

    public init() {}

    // Custom Codable: decodeIfPresent for every field so partial JSON (including
    // legacy `{}` blobs written before a field existed) decodes cleanly to
    // defaults. Mirrors the forward-compatible pattern used by VideoRecord.
    private enum CodingKeys: String, CodingKey {
        case scanHost, volumeUUID, volumeMountType, volumeName, remoteServerName, scannedAt, scanRootLabel
        case bundleContainer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanHost         = try c.decodeIfPresent(String.self, forKey: .scanHost) ?? ""
        volumeUUID       = try c.decodeIfPresent(String.self, forKey: .volumeUUID) ?? ""
        volumeMountType  = try c.decodeIfPresent(String.self, forKey: .volumeMountType) ?? ""
        volumeName       = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? ""
        remoteServerName = try c.decodeIfPresent(String.self, forKey: .remoteServerName) ?? ""
        scannedAt        = try c.decodeIfPresent(Date.self, forKey: .scannedAt)
        scanRootLabel    = try c.decodeIfPresent(String.self, forKey: .scanRootLabel) ?? ""
        bundleContainer  = try c.decodeIfPresent(String.self, forKey: .bundleContainer) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
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
        // Same emit-only-when-populated treatment: the overwhelmingly common
        // case (file not inside a bundle) adds zero bytes to catalog.json.
        if !bundleContainer.isEmpty { try c.encode(bundleContainer, forKey: .bundleContainer) }
    }
}

extension ScanContext {
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
    public static func subfolderLabel(forScanRootPath scanRootPath: String) -> String? {
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
