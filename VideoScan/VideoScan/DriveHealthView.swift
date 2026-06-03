//
//  DriveHealthView.swift
//  VideoScan
//
//  Two UI surfaces for the Drive Health probe:
//    1. `DriveHealthCard` — inline in the Volume editor's Hardware
//       section. Compact summary + expandable details + Re-probe.
//    2. `DriveHealthSheet` — standalone modal launched from the volume
//       row context menu. Same data, more room to breathe.
//
//  Friendly tone throughout per feedback_friendly_language.md. Trust-
//  changing affordances NEVER auto-apply — they always ask first.
//

import SwiftUI

// MARK: - Inline card

/// Inline Drive Health panel for the Volume editor. Loads asynchronously
/// on appear; uses `task(id:)` so switching to a different target re-
/// fires the probe.
struct DriveHealthCard: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var target: CatalogScanTarget

    @State private var snapshot: DriveHealthSnapshot?
    @State private var isProbing: Bool = false
    @State private var isExpanded: Bool = false
    /// True while we wait for the user to confirm a trust update.
    /// SwiftUI's alert(isPresented:) ≈ a modal yes/no — never auto-
    /// applies the change.
    @State private var pendingTrustChange: VolumeTrust?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let snap = snapshot {
                summaryLine(for: snap)
                if isExpanded {
                    detailsGrid(for: snap)
                    warningsList(for: snap)
                    trustSuggestion(for: snap)
                }
                lastProbedFooter(for: snap)
            } else if isProbing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking drive health…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Tap Re-probe to check this drive's health.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .task(id: target.searchPath) {
            await loadSnapshot(forceRefresh: false)
        }
        .alert(item: trustChangeBinding) { change in
            Alert(
                title: Text("Update reliability to \(change.target.rawValue)?"),
                message: Text(change.message),
                primaryButton: .default(Text("Update")) {
                    model.setTrust(change.target, for: target)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack {
            Text("Drive Health")
                .font(.title3.bold())
            Spacer()
            Button {
                Task { await loadSnapshot(forceRefresh: true) }
            } label: {
                Label("Re-probe", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isProbing)
            .accessibilityIdentifier("driveHealth.reprobe")
        }
    }

    private func summaryLine(for snap: DriveHealthSnapshot) -> some View {
        let rec = snap.recommendation
        return HStack(spacing: 8) {
            Image(systemName: rec.sfSymbol)
                .foregroundColor(color(for: rec))
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.headline)
                    .font(.headline)
                    .foregroundColor(color(for: rec))
                Text(rec.reasonText)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("driveHealth.disclosure")
        }
    }

    @ViewBuilder
    private func detailsGrid(for snap: DriveHealthSnapshot) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            row("Model", snap.modelName ?? "—")
            row("Serial", snap.serialNumber ?? "—")
            row("Firmware", snap.firmware ?? "—")
            if let cap = snap.capacityBytes {
                row("Capacity", formatBytes(cap))
            }
            row("Connection", snap.protocolKind.friendly)
            row("Media", snap.mediaTech.friendly)
            row("SMART status", snap.smartStatus.friendly)
            if let hours = snap.powerOnHours {
                let yrsText = snap.estimatedYearsPowered.map {
                    String(format: " (~%.1f years)", $0)
                } ?? ""
                row("Power-on time", "\(hours.formatted()) hours\(yrsText)")
            }
            if let temp = snap.temperatureCelsius {
                row("Temperature", "\(temp)°C")
            }
            if let r = snap.reallocatedSectors {
                row("Reallocated sectors", r.formatted())
            }
            if let p = snap.pendingSectors {
                row("Pending sectors", p.formatted())
            }
            if let o = snap.offlineUncorrectable {
                row("Offline uncorrectable", o.formatted())
            }
            if let s = snap.ssdAvailableSpare {
                row("Spare capacity", "\(s)%")
            }
            if let u = snap.ssdPercentageUsed {
                row("Write life used", "\(u)%")
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func warningsList(for snap: DriveHealthSnapshot) -> some View {
        if !snap.probeWarnings.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(snap.probeWarnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trustSuggestion(for snap: DriveHealthSnapshot) -> some View {
        let rec = snap.recommendation
        if let suggested = rec.suggestedTrust(currentTrust: target.trust),
           shouldOfferTrustChange(rec: rec, current: target.trust) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Would you like to set Reliability to \(suggested.rawValue)?")
                        .font(.callout)
                    Text("You'll always be the one to flip the switch — this is just a suggestion.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Update Trust") {
                    pendingTrustChange = suggested
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("driveHealth.updateTrust")
            }
        }
    }

    /// Only show the offer when the current Trust is meaningfully softer
    /// than the recommendation — don't pester Rick to "downgrade" an
    /// already-unreliable drive.
    private func shouldOfferTrustChange(rec: DriveHealthRecommendation,
                                         current: VolumeTrust) -> Bool {
        switch rec {
        case .retireNow:    return current != .unreliable
        case .planToRetire: return current != .unreliable && current != .aging
        case .watch:        return current == .unknown || current == .reliable
        case .healthy:      return false
        }
    }

    private func lastProbedFooter(for snap: DriveHealthSnapshot) -> some View {
        HStack {
            Spacer()
            Text("Last probed \(relativeTime(snap.probedAt))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func loadSnapshot(forceRefresh: Bool) async {
        isProbing = true
        defer { isProbing = false }
        // Swift's `await` ≈ "park this fiber, resume on the actor's
        // turn." DriveHealthProbe is an actor so the call is implicitly
        // serialized.
        let result = await DriveHealthProbe.shared.snapshot(
            forMountPath: target.searchPath,
            forceRefresh: forceRefresh
        )
        snapshot = result
    }

    private func color(for rec: DriveHealthRecommendation) -> Color {
        switch rec {
        case .healthy:      return .green
        case .watch:        return .yellow
        case .planToRetire: return .orange
        case .retireNow:    return .red
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: bytes)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Build an Identifiable wrapper for the trust-change alert.
    private var trustChangeBinding: Binding<TrustChangeAlertPayload?> {
        Binding(
            get: {
                guard let pending = pendingTrustChange else { return nil }
                let message = "VideoScan thinks this drive's reliability should change. You can always edit it manually."
                return TrustChangeAlertPayload(target: pending, message: message)
            },
            set: { newValue in
                if newValue == nil { pendingTrustChange = nil }
            }
        )
    }
}

private struct TrustChangeAlertPayload: Identifiable {
    let id = UUID()
    let target: VolumeTrust
    let message: String
}

// MARK: - Standalone sheet

/// Modal Drive Health sheet — launched from the volume row context
/// menu. Reuses `DriveHealthCard` with no chrome of its own beyond a
/// title bar + Done button.
struct DriveHealthSheet: View {
    // TODO(env-object-cleanup): forwarded only via .environmentObject(model)
    // to DriveHealthCard below. Subscribing here is overhead — see
    // project_bug_prevention_strategy memory.
    // swiftlint:disable-next-line vs-env-object-unused
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var target: CatalogScanTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drive Health")
                        .font(.title.bold())
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            DriveHealthCard(target: target)
                .environmentObject(model)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
        .accessibilityIdentifier("driveHealth.sheet")
    }
}

// MARK: - Friendly enum labels

extension ProtocolKind {
    var friendly: String {
        switch self {
        case .usb:          return "USB"
        case .sata:         return "SATA"
        case .thunderbolt:  return "Thunderbolt"
        case .nvmeInternal: return "Internal NVMe"
        case .nvmeExternal: return "External NVMe"
        case .unknown:      return "Unknown"
        }
    }
}

extension DetectedMediaTech {
    var friendly: String {
        switch self {
        case .hdd:     return "Spinning HDD"
        case .ssd:     return "SSD"
        case .nvme:    return "NVMe"
        case .unknown: return "Unknown"
        }
    }
}

extension SmartOverall {
    var friendly: String {
        switch self {
        case .passed:        return "Passing"
        case .failingNow:    return "Failing"
        case .notSupported:  return "Not supported"
        case .unknown:       return "Unknown"
        }
    }
}
