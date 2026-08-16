import SwiftUI

// MARK: - VolumeProvenanceSheet (View 1)
//
// "Where files from <volume> live now." Two tabs: Safe backups (default)
// and All known copies. Triggered from the right-click context menu on a
// volume row in `VolumesWindow`.
//
// Family-friendly tone per feedback_friendly_language.md — no "audit"
// language, no surveillance imagery. The headline is reassuring on the
// safe path and clearly actionable on the unsafe path.

struct VolumeProvenanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let provenance: VolumeProvenance

    @State private var selectedTab: Tab = .safe

    enum Tab: String, CaseIterable, Identifiable {
        case safe = "Safe backups"
        case all  = "All known copies"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tabPicker
            destinationList
            footer
            buttonBar
        }
        .padding(22)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: provenance.allRecordsSafe
                                  ? "checkmark.shield.fill"
                                  : "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(provenance.allRecordsSafe ? .green : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where files from \(provenance.sourceVolumeName) live now")
                        .font(.title2.bold())
                        .accessibilityIdentifier("volumeProvenance.title")
                    Text(provenance.headlineText)
                        .font(.callout)
                        .foregroundColor(provenance.allRecordsSafe ? .secondary : .orange)
                        .accessibilityIdentifier("volumeProvenance.headline")
                }
                Spacer()
            }
            if provenance.sourceIsRetired, let retiredAt = provenance.sourceRetiredAt {
                retirementLine(retiredAt: retiredAt)
            }
            if !provenance.allRecordsSafe && !provenance.atRiskFilenames.isEmpty {
                atRiskDisclosure
            }
        }
    }

    @ViewBuilder
    private func retirementLine(retiredAt: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
                .foregroundColor(.brown)
            Text("Retired \(Self.shortDate(retiredAt))")
                .font(.callout)
                .foregroundColor(.brown)
            if let reason = provenance.sourceRetiredReason, !reason.isEmpty {
                Text("— \(reason)")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.brown.opacity(0.08))
        .cornerRadius(6)
        .accessibilityIdentifier("volumeProvenance.retiredLine")
    }

    @State private var showAtRisk: Bool = false

    @ViewBuilder
    private var atRiskDisclosure: some View {
        DisclosureGroup(isExpanded: $showAtRisk) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(provenance.atRiskFilenames.prefix(20), id: \.self) { f in
                    Text(f)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if provenance.atRiskFilenames.count > 20 {
                    Text("… \(provenance.atRiskFilenames.count - 20) more")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Files that lack a safe backup")
                .font(.caption)
                .foregroundColor(.orange)
        }
        .accessibilityIdentifier("volumeProvenance.atRiskDisclosure")
    }

    // MARK: - Tab picker

    @ViewBuilder
    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(Tab.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("volumeProvenance.tabPicker")
    }

    // MARK: - Destination list

    private var visibleDestinations: [DestinationVolumeGroup] {
        switch selectedTab {
        case .safe: return provenance.safeDestinations
        case .all:  return provenance.allDestinations
        }
    }

    @ViewBuilder
    private var destinationList: some View {
        if visibleDestinations.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleDestinations) { dest in
                        DestinationCard(destination: dest,
                                         demoted: !dest.isSafe)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 220)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            if selectedTab == .safe && !provenance.allDestinations.isEmpty {
                Text("No safe destinations yet")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Switch to All known copies to see every match.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if provenance.sourceRecordCount == 0 {
                Text("No catalog records for this volume yet")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Scan the volume and try again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Nothing on file yet")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityIdentifier("volumeProvenance.emptyState")
    }

    // MARK: - Footer + buttons

    @ViewBuilder
    private var footer: some View {
        if !provenance.allDestinations.isEmpty {
            Text("Showing \(visibleDestinations.count) of \(provenance.allDestinations.count) destination volume(s).")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("volumeProvenance.done")
        }
    }

    // MARK: - Helpers

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}

// MARK: - Destination card

private struct DestinationCard: View {
    let destination: DestinationVolumeGroup
    let demoted: Bool

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: destination.role.icon)
                    .foregroundColor(destination.role.color)
                    .frame(width: 22)
                Text(destination.volumeName)
                    .font(.system(.headline, design: .monospaced).weight(.semibold))
                    .foregroundColor(demoted ? .secondary : .primary)
                roleBadge
                trustBadge
                if demoted {
                    Text(destination.isRetired ? "(retired)" : "(unreliable)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Spacer()
                Text("\(destination.fileCount) file\(destination.fileCount == 1 ? "" : "s")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("·")
                    .foregroundColor(.secondary)
                Text(Self.byteString(destination.totalBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(destination.samplePaths, id: \.self) { p in
                        Text(p)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if destination.totalSampleAvailable > destination.samplePaths.count {
                        Text("… and \(destination.totalSampleAvailable - destination.samplePaths.count) more")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 30)
                .padding(.top, 4)
            } label: {
                Text("Show sample paths")
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .opacity(demoted ? 0.7 : 1.0)
        .accessibilityIdentifier(demoted
                                 ? "volumeProvenance.destinationCard.demoted"
                                 : "volumeProvenance.destinationCard.safe")
    }

    private var roleBadge: some View {
        Text(destination.role.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(destination.role.color.opacity(0.18))
            .foregroundColor(destination.role.color)
            .cornerRadius(3)
    }

    private var trustBadge: some View {
        Text(destination.trust.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(destination.trust.color.opacity(0.18))
            .foregroundColor(destination.trust.color)
            .cornerRadius(3)
    }

    private static func byteString(_ bytes: Int64) -> String {
        let mb: Int64 = 1_048_576
        let gb: Int64 = 1_073_741_824
        let tb: Int64 = 1_099_511_627_776
        if bytes < mb { return String(format: "%.0f KB", Double(bytes) / 1024.0) }
        if bytes < gb { return String(format: "%.1f MB", Double(bytes) / Double(mb)) }
        if bytes < tb { return String(format: "%.1f GB", Double(bytes) / Double(gb)) }
        return String(format: "%.2f TB", Double(bytes) / Double(tb))
    }
}
