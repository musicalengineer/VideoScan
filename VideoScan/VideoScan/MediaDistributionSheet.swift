// MediaDistributionSheet.swift
// "Where media lives" — a donut of the catalog, opened from the Volumes
// window toolbar (Rick, 2026-08-18). Non-retired drives only. Groups by
// drive (default), kind, streams, or decade; measures size or files.
//
// LAYOUT
//   ┌ Where media lives — by drive       [Drive|Kind|Streams|Decade] [Size|Files] ┐
//   │  ╭────╮      ■ FamilyArchive   3.1 TB   52%   4,102  Reachable
//   │ ╱ 5.9 ╲     ■ MediaExpansion  1.2 TB   20%     137  Reachable
//   │ ╲ TB  ╱     ■ Mac (home)      0.9 TB   15%   1,880  Reachable
//   │  ╰────╯      ■ X9              0.5 TB    8%   1,010  Offline
//   │ Non-retired drives only · 7,795 records · computed 3:42 PM   [Done]
//   └──────────────────────────────────────────────────────────────┘
// Legend sits to the right when the sheet is wide, below when narrow.
//
// COST DISCIPLINE (CLAUDE.md: no O(records) work in view bodies). The
// aggregate is computed ONCE when the sheet appears, again when the
// dimension changes, and on the `.videoScanCatalogMutated` notification;
// it is cached in @State. The projection to Sendable rows runs on the
// main actor (it must — the records are main-actor state) and is
// itself cached, so a dimension flip re-runs only the group-by, in a
// detached task. Flipping Size ↔ Files is a pure re-render of the same
// cached slices — no recompute.
//
// COLORS are fixed per category by alphabetical slot (see
// MediaDistribution.swift) and applied through
// `chartForegroundStyleScale(domain:range:)` so the sectors and the
// legend swatches cannot disagree. Text is always primary/secondary,
// never the series color.
//
// PERSISTENCE. Last dimension + measure via `@AppStorage` (the same
// pattern ArchiveView uses for its sidebar toggles). `@AppStorage` ≈
// a property whose getter/setter are wired to UserDefaults.

import SwiftUI
import Charts

struct MediaDistributionSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Persisted choices. Stored as raw strings; decoded through the
    /// enum's failable init so a stale/unknown value falls back to the
    /// default instead of crashing.
    @AppStorage("mediaDistribution.dimension") private var dimensionRaw: String = MediaDistributionDimension.volume.rawValue
    @AppStorage("mediaDistribution.measure") private var measureRaw: String = MediaDistributionMeasure.size.rawValue

    private var dimension: MediaDistributionDimension {
        get { MediaDistributionDimension(rawValue: dimensionRaw) ?? .volume }
        nonmutating set { dimensionRaw = newValue.rawValue }
    }
    private var measure: MediaDistributionMeasure {
        get { MediaDistributionMeasure(rawValue: measureRaw) ?? .size }
        nonmutating set { measureRaw = newValue.rawValue }
    }
    private var dimensionBinding: Binding<MediaDistributionDimension> {
        Binding(get: { dimension }, set: { dimension = $0 })
    }
    private var measureBinding: Binding<MediaDistributionMeasure> {
        Binding(get: { measure }, set: { measure = $0 })
    }

    @State private var distribution: MediaDistribution? = nil
    @State private var isComputing = false
    /// Cached main-actor projection + the target-derived sets, so a
    /// dimension flip does not re-walk `model.records`.
    @State private var cachedInputs: MediaDistributionCachedInputs? = nil
    /// Handle on the in-flight aggregation so a rapid-fire mutation
    /// storm cancels the stale run instead of stacking up.
    @State private var computeTask: Task<Void, Never>? = nil

    /// Below this width the legend drops under the chart.
    private static let wideLayoutMinWidth: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 860, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .task { recompute(reproject: true) }
        // Refresh when the catalog changes underneath us (deletes,
        // migrations, repairs all post this).
        .onReceive(NotificationCenter.default.publisher(for: .videoScanCatalogMutated)) { _ in
            recompute(reproject: true)
        }
        .onChange(of: dimensionRaw) { _, _ in recompute(reproject: false) }
        .onDisappear { computeTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "chart.pie")
                .font(.system(size: 26))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Where media lives — \(dimension.headerPhrase)")
                    .font(.title2.bold())
                    .accessibilityIdentifier("mediaDistribution.title")
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("Show", selection: dimensionBinding) {
                ForEach(MediaDistributionDimension.allCases) { dim in
                    Text(dim.title).tag(dim)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .help("Group the chart by drive, file kind, stream shape, or decade.")
            .accessibilityIdentifier("mediaDistribution.dimension")
            Picker("Measure", selection: measureBinding) {
                ForEach(MediaDistributionMeasure.allCases) { m in
                    Text(m == .size ? "Size (GB)" : "Files").tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .help("Slice by total bytes or by number of files.")
            .accessibilityIdentifier("mediaDistribution.measure")
        }
    }

    private var headerSubtitle: String {
        switch dimension {
        case .volume:  return "Each slice is a drive. Retired drives are left out."
        case .kind:    return "Each slice is a file kind (container). Retired drives are left out."
        case .streams: return "Each slice is a stream shape — the split audio and video halves show up here. Retired drives are left out."
        case .decade:  return "Each slice is a decade from the best date we have. Retired drives are left out."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let d = distribution, !d.slices.isEmpty {
            GeometryReader { geo in
                if geo.size.width >= Self.wideLayoutMinWidth {
                    HStack(alignment: .center, spacing: 20) {
                        MediaDistributionDonut(distribution: d, measure: measure)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        MediaDistributionLegend(distribution: d, measure: measure)
                            .frame(width: min(380, geo.size.width * 0.46))
                    }
                } else {
                    VStack(spacing: 14) {
                        MediaDistributionDonut(distribution: d, measure: measure)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        MediaDistributionLegend(distribution: d, measure: measure)
                    }
                }
            }
        } else if isComputing {
            VStack(spacing: 10) {
                ProgressView()
                Text("Adding things up…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                Text("Nothing to chart yet — scan a drive first.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let d = distribution {
                    Text("Non-retired drives only · \(d.recordCount.formatted()) records · computed \(MediaDistributionFormat.timeString(d.computedAt))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("mediaDistribution.footer")
                    if d.retiredFiles > 0 {
                        Text("Retired drives hold \(CatalogStorageTotals.displaySize(d.retiredBytes)) across \(d.retiredFiles.formatted()) records (not shown).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("mediaDistribution.retiredCaption")
                    }
                }
                if isComputing && distribution != nil {
                    Text("updating…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("mediaDistribution.done")
        }
    }

    // MARK: - Compute

    /// Project on the main actor (records are main-actor state), then
    /// aggregate off it. `reproject: false` reuses the cached projection
    /// (a dimension flip); `true` re-walks the catalog (open / mutation).
    private func recompute(reproject: Bool) {
        computeTask?.cancel()
        isComputing = true
        if reproject || cachedInputs == nil {
            cachedInputs = Self.projectInputs(from: model)
        }
        guard let cached = cachedInputs else { return }
        let dim = dimension
        // Outer Task runs on the main actor (SwiftUI views are
        // @MainActor); the inner detached task does the O(records) work
        // and hands back one Sendable value. Same shape as RelocateSheet's
        // preview computation. (`Task.detached` ≈ a worker thread that
        // does NOT inherit the caller's actor; only Sendable values cross.)
        computeTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> MediaDistribution in
                MediaDistributionCalculator.compute(
                    inputs: cached.inputs,
                    dimension: dim,
                    retiredPrefixes: cached.retiredPrefixes,
                    reachableVolumes: cached.reachableVolumes,
                    knownVolumes: cached.knownVolumes)
            }.value
            if Task.isCancelled { return }   // superseded by a newer recompute
            distribution = result
            isComputing = false
        }
    }

    /// The main-actor half: Sendable projection of records plus the
    /// target-derived sets. Reachability comes from the scan targets'
    /// already-cached `isReachable` flag — a @Published Bool, NOT a
    /// filesystem probe.
    @MainActor
    private static func projectInputs(from model: VideoScanModel) -> MediaDistributionCachedInputs {
        let inputs = MediaDistributionCalculator.project(model.records)
        let targets = model.scanTargets.filter { !$0.searchPath.isEmpty }
        let retiredPrefixes = targets.filter(\.isRetired).map(\.searchPath)
        let live = targets.filter { !$0.isRetired }
        let known = Set(live.map { MediaDistributionCalculator.volumeLabel(forPath: $0.searchPath) })
        let reachable = Set(live.filter(\.isReachable)
                                .map { MediaDistributionCalculator.volumeLabel(forPath: $0.searchPath) })
        return MediaDistributionCachedInputs(
            inputs: inputs,
            retiredPrefixes: retiredPrefixes,
            reachableVolumes: reachable,
            knownVolumes: known)
    }
}

/// The projection cache — everything the detached aggregation needs.
struct MediaDistributionCachedInputs: Sendable {
    var inputs: [MediaDistributionInput]
    var retiredPrefixes: [String]
    var reachableVolumes: Set<String>
    var knownVolumes: Set<String>
}

// MARK: - Donut

/// The chart proper. Split out of the sheet so each expression stays
/// small enough for the type-checker (the first draft's inline
/// annotation closure tripped "unable to type-check in reasonable time").
struct MediaDistributionDonut: View {
    @Environment(\.colorScheme) private var colorScheme
    let distribution: MediaDistribution
    let measure: MediaDistributionMeasure

    /// Slices at or above this share get a percent label ON the sector;
    /// smaller ones rely on the legend (a label on a sliver is noise).
    static let directLabelThresholdPercent = 6.0

    var body: some View {
        Chart(distribution.slices) { slice in
            sector(for: slice)
        }
        .chartForegroundStyleScale(
            domain: distribution.colorDomain,
            range: MediaDistributionCalculator.colorRange(for: distribution, scheme: colorScheme)
        )
        .chartLegend(.hidden)   // our own legend carries GB / % / files
        .chartBackground { proxy in
            centerLabel(proxy: proxy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("mediaDistribution.chart")
        .animation(.easeInOut(duration: 0.25), value: measure)
    }

    private func angle(for slice: MediaDistributionSlice) -> Double {
        measure == .size ? Double(slice.bytes) : Double(slice.files)
    }

    private func sector(for slice: MediaDistributionSlice) -> some ChartContent {
        let pct = distribution.percent(of: slice, by: measure)
        return SectorMark(
            angle: .value(measure == .size ? "Size" : "Files", angle(for: slice)),
            innerRadius: .ratio(0.55),
            angularInset: 1.5
        )
        .cornerRadius(3)
        .foregroundStyle(by: .value("Category", slice.name))
        // Direct percent label — only when the slice is big enough to
        // carry it. `.overlay` puts it at the sector's centroid.
        .annotation(position: .overlay) {
            MediaDistributionSectorLabel(percent: pct)
        }
    }

    @ViewBuilder
    private func centerLabel(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let frame = geo[anchor]
                VStack(spacing: 2) {
                    Text(CatalogStorageTotals.displaySize(distribution.totalBytes))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("\(distribution.totalFiles.formatted()) files")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .position(x: frame.midX, y: frame.midY)
            }
        }
    }

    private var accessibilitySummary: String {
        let parts = distribution.slices.map {
            "\($0.name) \(MediaDistributionFormat.percentString(distribution.percent(of: $0, by: measure)))"
        }
        return "Where media lives, \(distribution.dimension.headerPhrase). "
            + "\(CatalogStorageTotals.displaySize(distribution.totalBytes)), "
            + "\(distribution.totalFiles.formatted()) files. " + parts.joined(separator: ", ")
    }
}

/// Percent capsule drawn on a sector. Renders nothing under the
/// threshold — never a label on a sliver.
struct MediaDistributionSectorLabel: View {
    let percent: Double

    var body: some View {
        if percent >= MediaDistributionDonut.directLabelThresholdPercent {
            Text(MediaDistributionFormat.percentString(percent))
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

// MARK: - Legend

/// Table-like legend: swatch · name · size · % · files, plus a
/// reachability caption for drives. Sorted by size desc (the slice order).
struct MediaDistributionLegend: View {
    @Environment(\.colorScheme) private var colorScheme
    let distribution: MediaDistribution
    let measure: MediaDistributionMeasure

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().padding(.vertical, 4)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(distribution.slices) { slice in
                        MediaDistributionLegendRow(
                            slice: slice,
                            percent: distribution.percent(of: slice, by: measure),
                            color: MediaDistributionCalculator.color(for: slice, scheme: colorScheme),
                            dimension: distribution.dimension)
                        if slice.id != distribution.slices.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("mediaDistribution.legend")
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 12, height: 12)
            Text(distribution.dimension.legendHeading).frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: 68, alignment: .trailing)
            Text("%").frame(width: 44, alignment: .trailing)
            Text("Files").frame(width: 60, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundColor(.secondary)
    }
}

struct MediaDistributionLegendRow: View {
    let slice: MediaDistributionSlice
    let percent: Double
    let color: Color
    let dimension: MediaDistributionDimension

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.name)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(CatalogStorageTotals.displaySize(slice.bytes))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 68, alignment: .trailing)
            Text(MediaDistributionFormat.percentString(percent))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(slice.files.formatted())
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("mediaDistribution.legend.\(slice.name)")
    }

    /// "Reachable" / "Offline" for drives; "N smaller …" for Other;
    /// nothing for kind/streams/decade rows.
    private var caption: String? {
        if slice.isOther {
            let noun: String
            switch dimension {
            case .volume:  noun = "drive"
            case .kind:    noun = "kind"
            case .streams: noun = "shape"
            case .decade:  noun = "decade"
            }
            return "\(slice.foldedVolumeCount) smaller \(noun)\(slice.foldedVolumeCount == 1 ? "" : "s")"
        }
        guard dimension == .volume else { return nil }
        switch slice.isReachable {
        case .some(true):  return "Reachable"
        case .some(false): return "Offline"
        case .none:        return "Not in the drive list"
        }
    }

    private var accessibilityText: String {
        var s = "\(slice.name), \(CatalogStorageTotals.displaySize(slice.bytes)), "
            + "\(MediaDistributionFormat.percentString(percent)), \(slice.files.formatted()) files"
        if let caption { s += ", " + caption }
        return s
    }
}

// MARK: - Formatting

enum MediaDistributionFormat {
    static func percentString(_ pct: Double) -> String {
        if pct > 0 && pct < 1 { return "<1%" }
        return String(format: "%.0f%%", pct)
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
