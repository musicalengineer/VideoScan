// CatalogDistributionPane.swift
// The Storage tab's "Catalog" view — the pinned row above the volumes
// (Rick 2026-08-19): how well the whole catalog is spread across drives,
// and how SAFELY. One big donut by drive with two lenses:
//
//   • Drive  — each drive its own palette color (the "Where media lives"
//              picture, promoted from a sheet to a first-class view)
//   • Safety — slices colored by storage tier:
//                 green  = safe archive  (Master Archive, redundant RAID, cloud)
//                 yellow = HDD           (spinning, single disk, not aging)
//                 orange = SSD           (fast, single device, not aging)
//                 red    = at risk       (aging/unreliable, RAID-0, unknown,
//                                         retired, or a drive we can't place)
//
// Under the donut: tier totals as a stacked strip, then the catalog-wide
// Copies and Archive pies (the "distribution efficiency" question — how
// much of the library exists in only one place).
//
// Arithmetic reuses MediaDistributionCalculator (by drive) and
// VolumeDashboardCalculator at root "/" (copies / archive across every
// drive). Tier assignment is the pure `StorageTier.tier(for:)` below.

import SwiftUI
import Charts

// MARK: - Storage tier

enum StorageTier: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case safe = 0, hdd, ssd, atRisk
    var id: Int { rawValue }
    static func < (a: StorageTier, b: StorageTier) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe:   return "Safe archive"
        case .hdd:    return "HDD"
        case .ssd:    return "SSD"
        case .atRisk: return "At risk"
        }
    }
    var detail: String {
        switch self {
        case .safe:   return "Master Archive, redundant RAID, or cloud"
        case .hdd:    return "single spinning disk in good standing"
        case .ssd:    return "single SSD in good standing — working tier"
        case .atRisk: return "aging or unreliable, RAID-0, unknown, or retired"
        }
    }
    var color: Color {
        switch self {
        case .safe:   return .green
        case .hdd:    return .yellow
        case .ssd:    return .orange
        case .atRisk: return .red
        }
    }
    var icon: String {
        switch self {
        case .safe:   return "checkmark.shield.fill"
        case .hdd:    return "externaldrive.fill"
        case .ssd:    return "internaldrive.fill"
        case .atRisk: return "exclamationmark.triangle.fill"
        }
    }

    /// Pure tier assignment from a drive's metadata. Order of the tests
    /// is the policy: retirement and bad trust trump everything; a
    /// redundant/cloud/master drive is safe; then the single-device tiers.
    static func tier(role: VolumeRole, trust: VolumeTrust, mediaTech: VolumeMediaTech,
                     isRetired: Bool, isMasterArchive: Bool, isBootVolume: Bool) -> StorageTier {
        if isRetired { return .atRisk }
        if trust == .aging || trust == .unreliable { return .atRisk }
        if mediaTech.isFragile { return .atRisk }
        if isMasterArchive || mediaTech.isRedundant || role == .cloud { return .safe }
        switch mediaTech {
        case .hdd:     return .hdd
        case .ssd:     return .ssd
        case .network: return .hdd          // a NAS share is spinning rust until told otherwise
        default:
            // Unknown media: the boot volume is an SSD on every Mac this
            // app runs on; anything else we genuinely can't place.
            return isBootVolume ? .ssd : .atRisk
        }
    }
}

// MARK: - Result

struct CatalogDistributionStats: Sendable, Equatable {
    /// By drive (the "Where media lives" donut).
    var byDrive = MediaDistribution()
    /// Tier per drive label (nil → at risk: not in the drive list).
    var tierByDrive: [String: StorageTier] = [:]
    /// Tier totals across the catalog.
    var tierBytes: [StorageTier: Int64] = [:]
    var tierFiles: [StorageTier: Int] = [:]
    /// Catalog-wide copies / archive ladders.
    var copies = VolumeDashboardSeries()
    var archive = VolumeDashboardSeries()
    var totalBytes: Int64 = 0
    var totalFiles: Int = 0
    var driveCount: Int = 0
    var computedAt: Date = Date(timeIntervalSince1970: 0)

    func tier(of slice: MediaDistributionSlice) -> StorageTier? {
        slice.isOther ? nil : (tierByDrive[slice.name] ?? .atRisk)
    }
    func tierPercent(_ t: StorageTier, by measure: MediaDistributionMeasure) -> Double {
        switch measure {
        case .size:  return totalBytes > 0 ? Double(tierBytes[t] ?? 0) / Double(totalBytes) * 100 : 0
        case .files: return totalFiles > 0 ? Double(tierFiles[t] ?? 0) / Double(totalFiles) * 100 : 0
        }
    }
}

enum CatalogDistributionCalculator {
    /// Everything the detached aggregation needs, projected on the main actor.
    struct Inputs: Sendable {
        var distribution: MediaDistributionCachedInputs
        var dashboard: [VolumeDashboardInput]
        var tierByDrive: [String: StorageTier]
    }

    static func compute(_ inputs: Inputs, now: Date = Date()) -> CatalogDistributionStats {
        var s = CatalogDistributionStats()
        s.computedAt = now
        s.byDrive = MediaDistributionCalculator.compute(
            inputs: inputs.distribution.inputs,
            dimension: .volume,
            retiredPrefixes: inputs.distribution.retiredPrefixes,
            reachableVolumes: inputs.distribution.reachableVolumes,
            knownVolumes: inputs.distribution.knownVolumes,
            maxSlices: 12,
            now: now)
        s.tierByDrive = inputs.tierByDrive
        s.totalBytes = s.byDrive.totalBytes
        s.totalFiles = s.byDrive.totalFiles
        s.driveCount = s.byDrive.slices.reduce(0) { $0 + $1.foldedVolumeCount }
        // Tier totals must cover EVERY record, including the folded
        // "Other" drives — walk the raw rows once, not the slices.
        let retired = inputs.distribution.retiredPrefixes.filter { !$0.isEmpty }
        for row in inputs.distribution.inputs {
            if row.isManuallyDeleted { continue }
            if !retired.isEmpty, retired.contains(where: { row.fullPath.hasPrefix($0) }) { continue }
            let label = MediaDistributionCalculator.volumeLabel(forPath: row.fullPath)
            let t = inputs.tierByDrive[label] ?? .atRisk
            s.tierBytes[t, default: 0] += max(0, row.sizeBytes)
            s.tierFiles[t, default: 0] += 1
        }
        let dash = VolumeDashboardCalculator.compute(inputs: inputs.dashboard, root: "/", now: now)
        s.copies = dash.copies
        s.archive = dash.archive
        return s
    }
}

// MARK: - View

struct CatalogDistributionPane: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.colorScheme) private var colorScheme

    enum Lens: String, CaseIterable, Identifiable {
        case drive = "Drive", safety = "Safety"
        var id: String { rawValue }
    }
    @AppStorage("storage.catalogLens") private var lensRaw: String = Lens.drive.rawValue
    private var lens: Binding<Lens> {
        Binding(get: { Lens(rawValue: lensRaw) ?? .drive }, set: { lensRaw = $0.rawValue })
    }
    @AppStorage("storage.measure") private var measureRaw: String = MediaDistributionMeasure.size.rawValue
    private var measure: MediaDistributionMeasure { MediaDistributionMeasure(rawValue: measureRaw) ?? .size }
    private var measureBinding: Binding<MediaDistributionMeasure> {
        Binding(get: { measure }, set: { measureRaw = $0.rawValue })
    }

    @State private var stats: CatalogDistributionStats? = nil
    @State private var computeTask: Task<Void, Never>? = nil

    static let bigDonut: CGFloat = 340

    var body: some View {
        Group {
            if let s = stats, s.totalFiles > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: VolumeDashboardView.gap) {
                        header(s)
                        distributionCard(s)
                        HStack(alignment: .top, spacing: VolumeDashboardView.gap) {
                            ladderCard("Copies", subtitle: "how much of the library exists in only one place",
                                       series: s.copies)
                            ladderCard("Archive", subtitle: "reviewed and archived, across every drive",
                                       series: s.archive)
                        }
                        Text("Present records on non-retired drives · as of \(MediaDistributionFormat.timeString(s.computedAt))"
                             + (s.byDrive.retiredFiles > 0
                                ? " · retired drives hold \(CatalogStorageTotals.displaySize(s.byDrive.retiredBytes)) more (not shown)"
                                : ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(VolumeDashboardView.gap)
                }
            } else if stats == nil {
                ProgressView("Reading the catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.pie").font(.system(size: 44)).foregroundColor(.secondary)
                    Text("The catalog is empty").font(.headline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { recompute() }
        .onReceive(NotificationCenter.default.publisher(for: .videoScanCatalogMutated)) { _ in recompute() }
        .onChange(of: model.volumeAggregatesRevision) { _, _ in recompute() }
        .onDisappear { computeTask?.cancel() }
        .accessibilityIdentifier("storage.catalogPane")
    }

    // MARK: Header

    private func header(_ s: CatalogDistributionStats) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 34))
                .foregroundColor(.accentColor)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Where the catalog lives")
                    .font(.title.bold())
                Text("\(s.totalFiles.formatted()) files · \(CatalogStorageTotals.displaySize(s.totalBytes)) across \(s.driveCount) drive\(s.driveCount == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Picker("Color by", selection: lens) {
                ForEach(Lens.allCases) { l in Text(l.rawValue).tag(l) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .help("Drive: one color per drive. Safety: color by storage tier — green safe archive, yellow HDD, orange SSD, red at risk.")
            .accessibilityIdentifier("storage.catalogLens")
            Picker("Measure", selection: measureBinding) {
                ForEach(MediaDistributionMeasure.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .accessibilityIdentifier("storage.measurePicker")
        }
    }

    // MARK: Big donut + legend

    private func distributionCard(_ s: CatalogDistributionStats) -> some View {
        card(lens.wrappedValue == .drive ? "By drive" : "By safety tier",
             subtitle: lens.wrappedValue == .drive
                ? "each drive's share of the library"
                : "how much of the library sits on safe, spinning, solid-state, or at-risk storage") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 28) {
                    bigDonut(s)
                        .frame(width: Self.bigDonut, height: Self.bigDonut)
                    driveLegend(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                tierStrip(s)
            }
        }
    }

    private func sliceColor(_ slice: MediaDistributionSlice, in s: CatalogDistributionStats) -> Color {
        switch lens.wrappedValue {
        case .drive:
            return MediaDistributionCalculator.color(for: slice, scheme: colorScheme)
        case .safety:
            guard let t = s.tier(of: slice) else { return .gray }
            return t.color
        }
    }

    private func angle(_ slice: MediaDistributionSlice) -> Double {
        measure == .size ? Double(slice.bytes) : Double(slice.files)
    }

    private func bigDonut(_ s: CatalogDistributionStats) -> some View {
        let slices = s.byDrive.slices
        return Chart(slices) { slice in
            SectorMark(angle: .value(measure == .size ? "Size" : "Files", angle(slice)),
                       innerRadius: .ratio(0.56), angularInset: 1.4)
                .cornerRadius(4)
                .foregroundStyle(by: .value("Drive", slice.name))
                .annotation(position: .overlay) {
                    let pct = s.byDrive.percent(of: slice, by: measure)
                    if pct >= MediaDistributionDonut.directLabelThresholdPercent {
                        Text(MediaDistributionFormat.percentString(pct))
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
        }
        .chartForegroundStyleScale(domain: slices.map(\.name),
                                   range: slices.map { sliceColor($0, in: s) })
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let frame = geo[anchor]
                    VStack(spacing: 2) {
                        Text(measure == .size ? CatalogStorageTotals.displaySize(s.totalBytes) : s.totalFiles.formatted())
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(measure == .size ? "\(s.totalFiles.formatted()) files" : CatalogStorageTotals.displaySize(s.totalBytes))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: measure)
        .animation(.easeInOut(duration: 0.25), value: lensRaw)
        .accessibilityIdentifier("storage.catalogDonut")
    }

    /// Drive · tier chip · size · % · files — one row per slice, largest first.
    private func driveLegend(_ s: CatalogDistributionStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 14, height: 14)
                Text("Drive").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tier").frame(width: 110, alignment: .leading)
                Text("Size").frame(width: 76, alignment: .trailing)
                Text("%").frame(width: 48, alignment: .trailing)
                Text("Files").frame(width: 64, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundColor(.secondary)
            Divider().padding(.vertical, 5)
            ForEach(s.byDrive.slices) { slice in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sliceColor(slice, in: s))
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.name)
                            .font(VolumeDashboardView.legendFont)
                            .lineLimit(1).truncationMode(.middle)
                        if slice.isOther {
                            Text("\(slice.foldedVolumeCount) smaller drives")
                                .font(.caption2).foregroundColor(.secondary)
                        } else if slice.isReachable == false {
                            Text("Offline").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if let t = s.tier(of: slice) {
                            Label(t.label, systemImage: t.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(t.color)
                                .lineLimit(1)
                        } else {
                            Text("mixed").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 110, alignment: .leading)
                    Text(CatalogStorageTotals.displaySize(slice.bytes))
                        .font(VolumeDashboardView.legendFont.monospacedDigit())
                        .frame(width: 76, alignment: .trailing)
                    Text(MediaDistributionFormat.percentString(s.byDrive.percent(of: slice, by: measure)))
                        .font(VolumeDashboardView.legendFont.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    Text(slice.files.formatted())
                        .font(VolumeDashboardView.legendFont.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.vertical, 5)
                if slice.id != s.byDrive.slices.last?.id { Divider().opacity(0.4) }
            }
        }
    }

    /// Tier totals as one stacked strip with a four-swatch legend — the
    /// one-glance answer to "how safe is the library".
    private func tierStrip(_ s: CatalogDistributionStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(StorageTier.allCases) { t in
                    let v = measure == .size ? Double(s.tierBytes[t] ?? 0) : Double(s.tierFiles[t] ?? 0)
                    if v > 0 {
                        BarMark(x: .value(measure == .size ? "Size" : "Files", v), y: .value("Strip", "tiers"))
                            .foregroundStyle(t.color)
                            .cornerRadius(3)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 22)
            HStack(spacing: 18) {
                ForEach(StorageTier.allCases) { t in
                    HStack(spacing: 6) {
                        Circle().fill(t.color).frame(width: 10, height: 10)
                        Text(t.label).font(.callout)
                        Text(MediaDistributionFormat.percentString(s.tierPercent(t, by: measure)))
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .help(t.detail)
                }
                Spacer()
            }
        }
    }

    // MARK: Ladder pies (catalog-wide copies / archive)

    private func ladderCard(_ title: String, subtitle: String, series: VolumeDashboardSeries) -> some View {
        card(title, subtitle: subtitle) {
            HStack(alignment: .center, spacing: 22) {
                Chart(series.slices) { slice in
                    SectorMark(angle: .value(measure == .size ? "Size" : "Files",
                                             measure == .size ? Double(slice.bytes) : Double(slice.files)),
                               innerRadius: .ratio(0.58), angularInset: 1.2)
                        .cornerRadius(3)
                        .foregroundStyle(by: .value("Category", slice.name))
                        .annotation(position: .overlay) {
                            let pct = series.percent(of: slice, by: measure)
                            if pct >= MediaDistributionDonut.directLabelThresholdPercent {
                                Text(MediaDistributionFormat.percentString(pct))
                                    .font(VolumeDashboardView.sectorLabelFont)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                }
                .chartForegroundStyleScale(domain: series.slices.map(\.name),
                                           range: series.slices.map { VolumeDashboardView.resolve($0.fixedColor ?? .gray) })
                .chartLegend(.hidden)
                .frame(width: 200, height: 200)
                .animation(.easeInOut(duration: 0.25), value: measure)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(series.slices) { slice in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(VolumeDashboardView.resolve(slice.fixedColor ?? .gray))
                                .frame(width: 14, height: 14)
                            Text(slice.name).font(VolumeDashboardView.legendFont).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(measure == .size ? CatalogStorageTotals.displaySize(slice.bytes) : slice.files.formatted())
                                .font(VolumeDashboardView.legendFont.monospacedDigit())
                            Text(MediaDistributionFormat.percentString(series.percent(of: slice, by: measure)))
                                .font(VolumeDashboardView.legendFont.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func card<Content: View>(_ title: String, subtitle: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundColor(.secondary)
            }
            content()
        }
        .padding(VolumeDashboardView.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .accessibilityIdentifier("storage.catalogCard.\(title)")
    }

    // MARK: Compute

    private func recompute() {
        computeTask?.cancel()
        let records = model.records
        let targets = model.scanTargets.filter { !$0.searchPath.isEmpty }
        let live = targets.filter { !$0.isRetired }
        var tiers: [String: StorageTier] = [:]
        for t in targets {
            let label = MediaDistributionCalculator.volumeLabel(forPath: t.searchPath)
            let tier = StorageTier.tier(role: t.role, trust: t.trust, mediaTech: t.mediaTech,
                                        isRetired: t.isRetired,
                                        isMasterArchive: model.isMasterArchive(t),
                                        isBootVolume: t.isBootVolumeRoot || t.isHomeFolderTarget)
            // Several targets can share a label (e.g. two ~/… folders →
            // "Mac (home)"); keep the WORST tier so the lens never flatters.
            tiers[label] = max(tiers[label] ?? .safe, tier)
        }
        let inputs = CatalogDistributionCalculator.Inputs(
            distribution: MediaDistributionCachedInputs(
                inputs: MediaDistributionCalculator.project(records),
                retiredPrefixes: targets.filter(\.isRetired).map(\.searchPath),
                reachableVolumes: Set(live.filter(\.isReachable).map { MediaDistributionCalculator.volumeLabel(forPath: $0.searchPath) }),
                knownVolumes: Set(live.map { MediaDistributionCalculator.volumeLabel(forPath: $0.searchPath) })),
            // Same scope as the donut: present records on non-retired drives.
            dashboard: VolumeDashboardCalculator.project(records, under: "/")
                .filter { row in !targets.contains { $0.isRetired && row.fullPath.hasPrefix($0.searchPath) } },
            tierByDrive: tiers)
        computeTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                CatalogDistributionCalculator.compute(inputs)
            }.value
            if Task.isCancelled { return }
            stats = result
        }
    }
}
