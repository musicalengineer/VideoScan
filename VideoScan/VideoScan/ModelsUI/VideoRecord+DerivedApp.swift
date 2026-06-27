// VideoRecord+DerivedApp.swift
// App-side derived properties of VideoRecord that depend on app
// infrastructure which can't follow VideoRecord into the pure-domain
// VideoScanCore package.
//
// Package-extraction note (2026-06-26): VideoRecord and its Foundation-only
// derivations moved into VideoScanCore (see the package's
// VideoRecord+Derived.swift). These two volume-LABEL helpers stayed behind
// because they call VolumeReachability — a synchronous, disk-aware,
// NSWorkspace-observing app service that has no place in the domain layer.
// Because VideoScanCore is re-exported via @_exported (VideoScanCoreExports.swift),
// the rest of the app sees `volumeName` / `displayVolumeLabel` exactly as
// before — they just resolve to this extension instead of the package's.
//
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state, methods share the same `self`.)

import Foundation

extension VideoRecord {

    /// Human-readable volume name. Prefers the name captured at scan time
    /// (e.g. "Macintosh HD", "LaCieWorkspace") which works even when the
    /// volume is offline. Falls back to path-component parsing for legacy
    /// records scanned before this field existed.
    var volumeName: String {
        // A relocated record physically lives wherever fullPath now points —
        // not where it was originally scanned. originalFullPath is set only by
        // Relocate, so for those records derive the volume from the CURRENT
        // path. Without this the catalog Volume column keeps showing the origin
        // volume (files moved RicksBackups → LaCie still read "RicksBackups").
        // volumeName(forPath:) is pure string parsing, so it stays correct even
        // when the destination volume is offline. (Bug found 2026-06-19 while
        // spot-testing the RicksBackups → LaCie salvage move: 1,474 relocated
        // files showed their old volume in the Volume column.)
        if originalFullPath != nil {
            let derived = VolumeReachability.volumeName(forPath: fullPath)
            if !derived.isEmpty { return derived }
        }
        if !scanContext.volumeName.isEmpty { return scanContext.volumeName }
        return VolumeReachability.volumeName(forPath: fullPath)
    }

    /// Disambiguated label for the catalog "Volume" column. Returns just
    /// the volume name for whole-volume scans, or "Volume > Folder" for
    /// folder scans. The " > " ASCII breadcrumb reads naturally and is
    /// trivially typeable/searchable — used everywhere subfolder scans need
    /// volume context (catalog column, inspector, scan-target menus).
    ///
    /// Legacy records (no `scanRootLabel`) read the same as before — just
    /// the volume name. Only newly scanned or re-scanned subfolder records
    /// pick up the combined form.
    var displayVolumeLabel: String {
        let vol = volumeName
        let root = scanContext.scanRootLabel
        // Defensive guards:
        //   - empty root  → whole-volume scan or legacy record → vol alone
        //   - root == vol → degenerate case (scan root happened to equal the
        //                   volume name, e.g. capture stamped the volume root)
        //                   → vol alone, no " > " duplication
        //   - empty vol   → fall back to root so the column is never blank
        guard !root.isEmpty, root != vol else { return vol }
        guard !vol.isEmpty else { return root }
        return "\(vol) > \(root)"
    }
}
