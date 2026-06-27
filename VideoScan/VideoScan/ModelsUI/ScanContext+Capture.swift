// ScanContext+Capture.swift
// App-side factory that POPULATES a ScanContext at scan time.
//
// Package-extraction note (2026-06-26): the ScanContext value type, its
// Codable, and the pure `subfolderLabel(forScanRootPath:)` helper live in
// the VideoScanCore package (see the package's ScanContext.swift). This
// `capture(for:scanRootPath:)` factory stayed app-side because it reaches
// into two pieces of app infrastructure that can't follow into the pure
// domain layer:
//   - CatalogHost.currentName   (app's hostname/provenance service)
//   - VolumeReachability.mountInfo (app's statfs-based mount probe)
// Because VideoScanCore is re-exported via @_exported, callers still write
// `ScanContext.capture(for: url, scanRootPath: …)` exactly as before.
//
// Capture is intentionally cheap: two syscalls (statfs + URL resource
// values) per file. It runs on every probe — cache hits and cache misses
// alike — so every scan freshens provenance and old records backfill
// naturally as volumes get rescanned.

import Foundation

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
        // already represented adequately by `volumeName`. subfolderLabel is
        // the pure helper that moved into the VideoScanCore package.
        if let rootPath = scanRootPath,
           let label = subfolderLabel(forScanRootPath: rootPath) {
            ctx.scanRootLabel = label
        }
        return ctx
    }
}
