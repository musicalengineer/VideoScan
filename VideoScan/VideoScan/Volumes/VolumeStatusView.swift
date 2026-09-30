// VolumeStatusView.swift
// Renders the "Connected / Offline / Scanning / Verifying / Backfilling /
// Combining" status pill for one row in the Scan Volumes table. Replaces
// the inline pill that used to live in CatalogHelpers.swift (which was
// brushing up against SwiftLint's 1000-line cap).
//
// The view takes a `VolumeUIStatus` directly — derivation lives in
// VolumeUIStatus.compute() so the same logic is unit-testable without a
// running SwiftUI environment.

import SwiftUI

/// One-line status pill. Identical visual to the legacy inline rendering
/// when the volume is offline or just connected; gains a cycling spinner
/// + accent colour shift when a remediation pass is touching the volume.
struct VolumeStatusView: View {
    let status: VolumeUIStatus

    var body: some View {
        HStack(spacing: 6) {
            Text(status.label)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(status.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(status.color.opacity(0.12))
                )

            if status.isActive {
                // Native macOS spinner is the cleanest in-progress affordance.
                // It auto-animates without requiring us to drive a rotation
                // ourselves and matches the Phase column already using
                // ProgressView. SF Symbol arrow.triangle.2.circlepath was
                // the alternative but would need explicit Animation glue and
                // wouldn't match the rest of the table's styling.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .help(status.activityTooltip ?? "")
            }
        }
    }
}

// MARK: - Preview

#Preview("All states") {
    VStack(alignment: .leading, spacing: 8) {
        VolumeStatusView(status: .offline)
        VolumeStatusView(status: .connected)
        VolumeStatusView(status: .scanning(progress: 0.42))
        VolumeStatusView(status: .scanning(progress: nil))
        VolumeStatusView(status: .verifying)
        VolumeStatusView(status: .backfilling)
        VolumeStatusView(status: .combining)
    }
    .padding()
}
