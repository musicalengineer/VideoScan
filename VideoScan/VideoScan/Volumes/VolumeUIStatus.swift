// VolumeUIStatus.swift
// Single-source-of-truth UI status enum for a volume row in the catalog.
//
// Replaces a scatter of "is the volume mounted? + what's the scan target's
// CatalogTargetStatus? + is the model combining/correlating?" checks that
// were duplicated at every render site. Centralising the derivation here
// lets the volume status view (and its tests) reason about one value.
//
// Idle and connected look the same to the user (no badge / no spinner) but
// are kept distinct here so callers can branch on either without recomputing.

import Foundation
import SwiftUI

// Swift's `enum with associated values` ≈ C++ `std::variant`; switch-with-pattern
// is the type-safe `std::visit` equivalent.
enum VolumeUIStatus: Equatable {
    /// Volume is not mounted right now.
    case offline

    /// Volume is mounted; no remediation pass is touching it.
    case connected

    /// Catalog scan is in progress. `progress` 0.0–1.0 if known, nil if
    /// still in the discovery phase (file count not yet established).
    case scanning(progress: Double?)

    /// Verify pass is in progress (stat every cataloged file, check size).
    case verifying

    /// Provenance backfill is in progress.
    case backfilling

    /// A/V combine job is in progress (touches this volume's media).
    case combining

    // MARK: - Derived properties

    /// Whether this status represents any in-progress remediation pass.
    /// Used to drive the cycling spinner in the status view.
    var isActive: Bool {
        switch self {
        case .scanning, .verifying, .backfilling, .combining:
            return true
        case .offline, .connected:
            return false
        }
    }

    /// Human label for the status pill. Localizable today via literal swap;
    /// no NSLocalizedString plumbing yet because the rest of the catalog UI
    /// uses inline literals.
    var label: String {
        switch self {
        case .offline:        return "Offline"
        case .connected:      return "Connected"
        case .scanning:       return "Scanning"
        case .verifying:      return "Verifying"
        case .backfilling:    return "Backfilling"
        case .combining:      return "Combining"
        }
    }

    /// Tooltip shown over the cycling indicator. Ellipsis communicates
    /// in-progress.
    var activityTooltip: String? {
        switch self {
        case .scanning:       return "Scanning…"
        case .verifying:      return "Verifying…"
        case .backfilling:    return "Backfilling provenance…"
        case .combining:      return "Combining…"
        case .offline, .connected:
            return nil
        }
    }

    /// Accent colour for the pill background / text. Matches the legacy
    /// VolumeRow.connectionColor mapping so the post-refactor UI looks
    /// identical when the volume is just sitting connected.
    var color: Color {
        switch self {
        case .offline:        return .orange
        case .connected:      return .green
        case .scanning:       return .green
        case .verifying:      return .blue
        case .backfilling:    return .purple
        case .combining:      return .cyan
        }
    }
}

// MARK: - Derivation from model inputs

/// Inputs needed to compute a `VolumeUIStatus` for a single scan target.
///
/// Plain-old-data struct so callers (SwiftUI views, tests) can construct it
/// without dragging in `VideoScanModel` or `CatalogScanTarget`. The view
/// extracts these from its `@ObservedObject` model + target on every render
/// and asks `VolumeUIStatus.compute(...)` for the verdict.
struct VolumeUIStatusInputs: Equatable {
    /// True if the volume root is currently mounted (already-cached
    /// VolumeReachability bit, NOT a fresh stat per render).
    let mountReachable: Bool

    /// Current `CatalogScanTarget.status` for this volume.
    let targetStatus: CatalogTargetStatus

    /// Global "model is running a combine job right now" flag.
    let isCombining: Bool

    /// Global "model is running a provenance backfill right now" flag.
    let isBackfilling: Bool

    /// Global "model is running a Verify pass right now (against THIS
    /// volume)" flag. Verify currently sets target.status = .scanning,
    /// so we need an out-of-band hint to distinguish a scan from a
    /// verify; this flag is set by the model around verifyCatalog().
    let isVerifyingThisVolume: Bool

    /// 0.0–1.0 if known, nil if discovery phase or unknown.
    let scanProgress: Double?
}

extension VolumeUIStatus {
    /// Compute the user-facing status from the model state. Order matters:
    /// offline beats every active state (a yanked drive mid-scan reads as
    /// Offline immediately), then combine > backfill > verify > scan > idle.
    static func compute(_ inputs: VolumeUIStatusInputs) -> VolumeUIStatus {
        guard inputs.mountReachable else { return .offline }

        if inputs.isCombining             { return .combining }
        if inputs.isBackfilling           { return .backfilling }
        if inputs.isVerifyingThisVolume   { return .verifying }

        switch inputs.targetStatus {
        case .scanning, .discovering, .paused, .waitingForVolume:
            return .scanning(progress: inputs.scanProgress)
        case .idle, .complete, .stopped, .error, .resumable:
            return .connected
        }
    }
}
