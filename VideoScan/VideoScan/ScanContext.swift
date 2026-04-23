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

    /// For remote mounts: the server name (e.g. "macpro.local" from an SMB
    /// `//macpro.local/share` mount). Empty for local filesystems.
    var remoteServerName: String = ""

    /// When the scan that produced this context ran.
    var scannedAt: Date?

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
        case scanHost, volumeUUID, volumeMountType, remoteServerName, scannedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanHost         = try c.decodeIfPresent(String.self, forKey: .scanHost) ?? ""
        volumeUUID       = try c.decodeIfPresent(String.self, forKey: .volumeUUID) ?? ""
        volumeMountType  = try c.decodeIfPresent(String.self, forKey: .volumeMountType) ?? ""
        remoteServerName = try c.decodeIfPresent(String.self, forKey: .remoteServerName) ?? ""
        scannedAt        = try c.decodeIfPresent(Date.self, forKey: .scannedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !scanHost.isEmpty { try c.encode(scanHost, forKey: .scanHost) }
        if !volumeUUID.isEmpty { try c.encode(volumeUUID, forKey: .volumeUUID) }
        if !volumeMountType.isEmpty { try c.encode(volumeMountType, forKey: .volumeMountType) }
        if !remoteServerName.isEmpty { try c.encode(remoteServerName, forKey: .remoteServerName) }
        try c.encodeIfPresent(scannedAt, forKey: .scannedAt)
    }
}

extension ScanContext {
    /// Capture provenance for a file URL at scan time. Callers should pass
    /// the real on-disk URL, not a RAM-disk prefetch path — the whole
    /// point is to tag where the file actually lives.
    static func capture(for url: URL, now: Date = Date()) -> ScanContext {
        var ctx = ScanContext()
        ctx.scanHost = CatalogHost.currentName
        ctx.scannedAt = now

        let info = VolumeReachability.mountInfo(forPath: url.path)
        ctx.volumeMountType = info.mountType
        ctx.remoteServerName = info.remoteServer

        // URL resource values vend a UUID string for most local and some
        // network volumes. It's best-effort; empty is a valid outcome.
        if let vals = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
           let uuid = vals.volumeUUIDString {
            ctx.volumeUUID = uuid
        }
        return ctx
    }
}
