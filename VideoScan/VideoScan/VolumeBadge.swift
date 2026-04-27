//
//  VolumeBadge.swift
//  VideoScan
//
//  Reusable visual identifiers for a volume's role/trust/policy. Used by
//  the Archive sidebar and Volumes window today; intended for catalog
//  rows, scan picker, and Compare presets in subsequent passes.
//

import SwiftUI

/// Compact role + trust cluster: a colored dot, the role short label,
/// and a trust glyph (suppressed when trust is Unknown). Sized to fit
/// inline in table rows.
struct VolumeBadge: View {
    let role: VolumeRole
    let trust: VolumeTrust
    let isReachable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isReachable ? role.color : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(role.shortLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(role.color)
            if trust != .unknown {
                Image(systemName: trust.icon)
                    .font(.system(size: 8))
                    .foregroundColor(trust.color)
            }
        }
    }
}

/// Live-updating wrapper for callers that have the `CatalogScanTarget`
/// itself. Subscribes to the target's `@Published` role/trust/reachable
/// so the badge re-renders in place when the user edits the volume.
struct ObservedVolumeBadge: View {
    @ObservedObject var target: CatalogScanTarget

    var body: some View {
        VolumeBadge(role: target.role,
                    trust: target.trust,
                    isReachable: target.isReachable)
    }
}

/// Larger badge for the computed destination policy. Color carries the
/// signal; the icon disambiguates when colors are similar (preferred vs.
/// acceptable both lean green/yellow).
struct PolicyBadge: View {
    let policy: DestinationPolicy

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: policy.icon)
                .font(.system(size: 10))
            Text(policy.label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundColor(policy.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(policy.color.opacity(0.12))
        .clipShape(Capsule())
    }
}
