// VolumeDetailPane.swift
// The right-hand side of the Storage tab / Volumes window for ONE drive
// (Rick 2026-08-19): the top quarter is a horizontal volume-info card —
// name, role, reliability, media tech, filesystem, capacity, age, last
// scan, what's cataloged — and the remaining three quarters are the
// dashboard charts (VolumeDashboardView). An Overview ⇄ Edit switch in
// the card swaps the charts for the metadata editor (VolumeEditor), so
// nothing the old pane could do is lost.
//
// The pane owns the per-volume statistics (`VolumeDashboardStats`) so the
// card's "Media here" tile and the charts read ONE computation: projected
// on the main actor, aggregated in a detached task, refreshed on catalog
// mutation — never O(records) inside a view body.

import SwiftUI

struct VolumeDetailPane: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var target: CatalogScanTarget

    enum Mode: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case edit = "Edit"
        var id: String { rawValue }
    }
    @AppStorage("storage.detailMode") private var modeRaw: String = Mode.overview.rawValue
    private var mode: Binding<Mode> {
        Binding(get: { Mode(rawValue: modeRaw) ?? .overview },
                set: { modeRaw = $0.rawValue })
    }
    @AppStorage("storage.measure") private var measureRaw: String = MediaDistributionMeasure.size.rawValue
    private var measure: Binding<MediaDistributionMeasure> {
        Binding(get: { MediaDistributionMeasure(rawValue: measureRaw) ?? .size },
                set: { measureRaw = $0.rawValue })
    }

    @State private var stats: VolumeDashboardStats? = nil
    @State private var freeBytes: Int64? = nil
    /// Live total capacity from statfs when the drive is mounted; the
    /// card/dashboard prefer it over the hand-entered `capacityTB`.
    @State private var liveCapacityBytes: Int64? = nil
    @State private var isComputing = false
    @State private var computeTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            VolumeInfoCard(target: target,
                           stats: stats,
                           capacityBytes: capacityBytes,
                           freeBytes: freeBytes,
                           isMasterArchive: model.isMasterArchive(target),
                           mode: mode)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            switch mode.wrappedValue {
            case .overview:
                VolumeDashboardView(target: target,
                                    stats: stats,
                                    capacityBytes: capacityBytes,
                                    freeBytes: freeBytes,
                                    isComputing: isComputing,
                                    isMasterArchive: model.isMasterArchive(target),
                                    measure: measure)
            case .edit:
                VolumeEditor(target: target, showHeader: false)
            }
        }
        .task(id: target.id) { recompute() }
        .onReceive(NotificationCenter.default.publisher(for: .videoScanCatalogMutated)) { _ in
            recompute()
        }
        .onChange(of: model.volumeAggregatesRevision) { _, _ in recompute() }
        .onChange(of: target.isReachable) { _, _ in recompute() }
        .onDisappear { computeTask?.cancel() }
    }

    /// Live statfs capacity when mounted, else the editor's TB figure.
    private var capacityBytes: Int64? {
        if let live = liveCapacityBytes, live > 0 { return live }
        return target.capacityTB.map { Int64($0 * 1_000_000_000_000) }
    }

    // MARK: - Compute

    /// Main-actor projection of the records under this target, then one
    /// detached aggregation (and a statfs for free space when the drive
    /// is mounted). A newer call cancels the in-flight one.
    private func recompute() {
        computeTask?.cancel()
        isComputing = true
        let root = target.searchPath
        let inputs = VolumeDashboardCalculator.project(model.records, under: root)
        let probeFree = target.isReachable && !target.isRetired
        computeTask = Task {
            let (result, free, cap) = await Task.detached(priority: .userInitiated) {
                () -> (VolumeDashboardStats, Int64?, Int64?) in
                let s = VolumeDashboardCalculator.compute(inputs: inputs, root: root)
                var f: Int64? = nil
                var c: Int64? = nil
                if probeFree {
                    f = VideoScanModel.freeBytes(atPath: root)
                    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: root),
                       let size = attrs[.systemSize] as? NSNumber {
                        c = size.int64Value
                    }
                }
                return (s, f, c)
            }.value
            if Task.isCancelled { return }
            stats = result
            freeBytes = free
            liveCapacityBytes = cap
            isComputing = false
        }
    }
}

// MARK: - Info card

/// The top quarter: identity row, then a horizontal strip of fact tiles,
/// then notes. Read-only — editing happens in the Edit mode below.
struct VolumeInfoCard: View {
    @ObservedObject var target: CatalogScanTarget
    let stats: VolumeDashboardStats?
    let capacityBytes: Int64?
    let freeBytes: Int64?
    let isMasterArchive: Bool
    @Binding var mode: VolumeDetailPane.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityRow
            factsStrip
            if !target.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notesLine
            }
        }
        .accessibilityIdentifier("storage.infoCard")
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: target.role.icon)
                .font(.system(size: 34))
                .foregroundColor(target.role.color)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.title.bold())
                        .lineLimit(1)
                    if isMasterArchive {
                        chip("MASTER ARCHIVE", color: .indigo, icon: "crown.fill")
                    }
                    if target.isRetired {
                        chip("RETIRED", color: .brown, icon: "archivebox.fill")
                    } else {
                        chip(target.isReachable ? "ONLINE" : "OFFLINE",
                             color: target.isReachable ? .green : .orange,
                             icon: target.isReachable ? "checkmark.circle.fill" : "wifi.slash")
                    }
                }
                Text(target.searchPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if !target.isRetired {
                PolicyBadge(policy: target.destinationPolicy)
                    .scaleEffect(1.1)
            }
            Picker("", selection: $mode) {
                ForEach(VolumeDetailPane.Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .accessibilityIdentifier("storage.modePicker")
        }
    }

    private func chip(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .bold))
            .labelStyle(.titleAndIcon)
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    // MARK: Facts strip

    /// Horizontal tiles; wraps onto a second line when the pane is
    /// narrow (ViewThatFits → scroll fallback keeps it honest at 460pt).
    private var factsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                factTile("Role", value: target.role.rawValue,
                         icon: target.role.icon, tint: target.role.color)
                factTile("Reliability", value: target.trust.rawValue,
                         icon: target.trust.icon, tint: target.trust.color)
                factTile("Media", value: target.mediaTech.rawValue,
                         icon: target.mediaTech.icon,
                         tint: target.mediaTech.isRedundant ? .green : .secondary)
                factTile("Filesystem", value: target.filesystem.isEmpty ? "—" : target.filesystem,
                         icon: "internaldrive", tint: .secondary)
                capacityTile
                factTile("Purchased", value: purchasedText,
                         icon: "calendar", tint: .secondary)
                factTile("Last scan", value: lastScanText,
                         icon: "clock.arrow.circlepath", tint: .secondary)
                mediaHereTile
            }
        }
    }

    private var purchasedText: String {
        guard let y = target.purchaseYear else { return "—" }
        let age = Calendar.current.component(.year, from: Date()) - y
        return age > 0 ? "\(y)  ·  \(age) yr\(age == 1 ? "" : "s")" : "\(y)"
    }

    private var lastScanText: String {
        guard let d = target.lastScannedDate else { return "Never" }
        return Self.relativeFmt.localizedString(for: d, relativeTo: Date())
    }

    private var capacityTile: some View {
        let cataloged = stats?.totalBytes ?? 0
        let used: Int64? = {
            guard let cap = capacityBytes, let free = freeBytes else { return nil }
            return max(0, cap - free)
        }()
        return VStack(alignment: .leading, spacing: 4) {
            tileLabel("Capacity", icon: "externaldrive.fill", tint: .secondary)
            if let cap = capacityBytes, cap > 0 {
                Text(CatalogStorageTotals.displaySize(cap))
                    .font(.system(size: 14, weight: .semibold))
                CapacityBar(capacity: cap, cataloged: cataloged, used: used)
                    .frame(width: 140, height: 7)
                Text(capacityCaption(cap: cap, used: used, cataloged: cataloged))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(size: 14, weight: .semibold))
                Text(target.isReachable ? "Reading…" : "Offline — set in Edit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.trailing, 22)
    }

    private func capacityCaption(cap: Int64, used: Int64?, cataloged: Int64) -> String {
        if let used, let free = freeBytes {
            let pct = cap > 0 ? Int((Double(used) / Double(cap) * 100).rounded()) : 0
            return "\(pct)% used · \(CatalogStorageTotals.displaySize(free)) free"
        }
        let pct = cap > 0 ? Int((Double(cataloged) / Double(cap) * 100).rounded()) : 0
        return "\(pct)% is cataloged media"
    }

    private var mediaHereTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            tileLabel("Media here", icon: "film.stack", tint: .accentColor)
            if let s = stats {
                Text("\(s.totalFiles.formatted()) files  ·  \(CatalogStorageTotals.displaySize(s.totalBytes))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                if s.deletedFiles > 0 {
                    Text("\(s.deletedFiles) deleted from every drive (not counted)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Counting…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.trailing, 22)
    }

    private func factTile(_ label: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            tileLabel(label, icon: icon, tint: tint)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.trailing, 22)
    }

    private func tileLabel(_ label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
        }
    }

    // MARK: Notes

    private var notesLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(target.notes.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(target.notes)
        }
    }

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Three-segment capacity bar: cataloged media (accent) · other used
/// (gray) · free (track). When `used` is unknown (drive offline) only the
/// cataloged segment draws over the track.
struct CapacityBar: View {
    let capacity: Int64
    let cataloged: Int64
    let used: Int64?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let capD = max(1, Double(capacity))
            let catW = w * min(1, Double(max(0, cataloged)) / capD)
            let usedW = used.map { w * min(1, Double($0) / capD) } ?? catW
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: max(usedW, catW))
                Capsule().fill(Color.accentColor).frame(width: catW)
            }
        }
        .accessibilityLabel("Capacity bar")
    }
}
