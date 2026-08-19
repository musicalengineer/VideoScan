// VolumeDashboardView.swift
// The bottom three quarters of a drive's detail pane in the Storage tab:
// "what's on this drive", as charts (Rick 2026-08-19 — "we humans like
// pretty graphs and pie charts to process info visually").
//
// Layout (scrolls):
//
//   What's on this drive                        [ Size | Files ]  3:14 PM
//   ┌ Space ──────────────┐ ┌ Eras ──────────────────────────────────┐
//   │ ███████░░░░░░ 62%   │ │ ▂▅█▇▃  bars by decade                   │
//   └─────────────────────┘ └────────────────────────────────────────┘
//   ┌ Kind (donut) ┐ ┌ Copies (donut) ┐ ┌ Archive (donut) ┐   ← 3 across when
//   (+ Fixity on the Master Archive)                             the pane allows
//   ┌ Years (bars, Master Archive only) ───────────────────────────┐
//   ┌ Folders (horizontal bars, full width) ───────────────────────┐
//
// Every card is the same frame — title · chart · compact legend — and
// every angle/height flips with the ONE Size ⇄ Files control. Colors:
// open-ended categories (kind, streams, folders) use the 8-slot
// colorblind-safe palette from MediaDistribution.swift by alphabetical
// slot, so "mov" is the same color on every drive; review / copies /
// stars / fixity use semantic colors (the Triage tab's, and a
// red→green safety ladder). Decades/years ramp through the palette in
// chronological order.
//
// The view is passive: the parent (VolumeDetailPane) owns the stats and
// recomputes them off the main thread.

import SwiftUI
import Charts

struct VolumeDashboardView: View {
    @ObservedObject var target: CatalogScanTarget
    let stats: VolumeDashboardStats?
    let capacityBytes: Int64?
    let freeBytes: Int64?
    let isComputing: Bool
    let isMasterArchive: Bool
    @Binding var measure: MediaDistributionMeasure

    @Environment(\.colorScheme) private var colorScheme

    /// Donut card grid: as many ~380pt columns as fit (two on a normal
    /// pane). Rick 2026-08-19 iteration 2: fewer, bigger pies with
    /// readable text — Streams dropped, Folders moved below the grid.
    private let gridColumns = [GridItem(.adaptive(minimum: 330, maximum: 620), spacing: 14, alignment: .top)]
    /// Donut diameter and the legend/center type sizes — the RD knobs.
    static let donutSize: CGFloat = 210
    static let legendFont: Font = .system(size: 14)
    static let centerFont: Font = .system(size: 22, weight: .semibold, design: .rounded)
    static let sectorLabelFont: Font = .system(size: 13, weight: .semibold)

    var body: some View {
        Group {
            if let s = stats, !s.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(s)
                        topRow(s)
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                            // Three pies (Rick 2026-08-19 iteration 3):
                            // what it is, how safe it is, how far along
                            // the archive road it is.
                            donutCard("Kind", subtitle: "container / extension", series: s.kind)
                            donutCard("Copies", subtitle: "known copies on other drives", series: s.copies)
                            donutCard("Archive", subtitle: "reviewed and archived so far", series: s.archive)
                            if isMasterArchive {
                                donutCard("Fixity", subtitle: "promoted copies verified",
                                          series: s.fixity)
                            }
                        }
                        if isMasterArchive {
                            yearsCard(s)
                        }
                        foldersCard(s)
                        footer(s)
                    }
                    .padding(18)
                }
            } else if stats == nil || isComputing {
                ProgressView("Reading the catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .accessibilityIdentifier("storage.dashboard")
    }

    // MARK: - Header / footer

    private func header(_ s: VolumeDashboardStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("What's on this drive")
                .font(.title3.weight(.semibold))
            Text("\(s.totalFiles.formatted()) files · \(CatalogStorageTotals.displaySize(s.totalBytes))")
                .font(.callout)
                .foregroundColor(.secondary)
                .monospacedDigit()
            Spacer()
            Picker("Measure", selection: $measure) {
                ForEach(MediaDistributionMeasure.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("Angles and bar heights show bytes (Size) or record counts (Files).")
            .accessibilityIdentifier("storage.measurePicker")
        }
    }

    private func footer(_ s: VolumeDashboardStats) -> some View {
        HStack(spacing: 6) {
            if isComputing { ProgressView().controlSize(.mini) }
            Text("Present records under \(target.searchPath)"
                 + (s.deletedFiles > 0 ? " · \(s.deletedFiles) deleted-everywhere record\(s.deletedFiles == 1 ? "" : "s") not shown" : "")
                 + " · as of \(MediaDistributionFormat.timeString(s.computedAt))")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Nothing cataloged here yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(target.isRetired
                 ? "This drive is retired; its files were moved or retired with it."
                 : "Scan this volume from the Catalog tab and the charts fill in.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top row: space + eras

    private func topRow(_ s: VolumeDashboardStats) -> some View {
        HStack(alignment: .top, spacing: 14) {
            spaceCard(s)
                .frame(minWidth: 240, maxWidth: 320)
            erasCard(s)
                .frame(maxWidth: .infinity)
        }
    }

    /// Space: a stacked bar of cataloged media · other used · free, with
    /// the honest fallback when capacity/free are unknown.
    private func spaceCard(_ s: VolumeDashboardStats) -> some View {
        let capacity: Int64? = capacityBytes
        let cataloged = s.totalBytes
        let used: Int64? = {
            guard let cap = capacity, let free = freeBytes else { return nil }
            return max(cataloged, cap - free)
        }()
        let other: Int64 = used.map { max(0, $0 - cataloged) } ?? 0
        let free: Int64? = {
            guard let cap = capacity, let used else { return nil }
            return max(0, cap - used)
        }()
        return card("Space", subtitle: capacity == nil ? "capacity not set" : "how full is it") {
            VStack(alignment: .leading, spacing: 10) {
                if let cap = capacity, cap > 0 {
                    Chart {
                        BarMark(x: .value("Bytes", Double(cataloged)), y: .value("Bar", "space"))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(3)
                        if other > 0 {
                            BarMark(x: .value("Bytes", Double(other)), y: .value("Bar", "space"))
                                .foregroundStyle(Color.secondary.opacity(0.55))
                        }
                        if let free {
                            BarMark(x: .value("Bytes", Double(free)), y: .value("Bar", "space"))
                                .foregroundStyle(Color.secondary.opacity(0.15))
                        } else {
                            BarMark(x: .value("Bytes", Double(max(0, cap - cataloged))), y: .value("Bar", "space"))
                                .foregroundStyle(Color.secondary.opacity(0.15))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartXScale(domain: 0...Double(cap))
                    .frame(height: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        legendLine(Color.accentColor, "Cataloged media", cataloged, of: cap)
                        if other > 0 {
                            legendLine(Color.secondary.opacity(0.55), "Other files", other, of: cap)
                        }
                        if let free {
                            legendLine(Color.secondary.opacity(0.3), "Free", free, of: cap)
                        } else {
                            HStack(spacing: 6) {
                                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 9, height: 9)
                                Text(target.isReachable ? "Free space: reading…" : "Free space unknown — drive is offline")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    Text(CatalogStorageTotals.displaySize(cataloged))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("of cataloged media. Set the capacity in Edit (or Detect Hardware while the drive is mounted) to see how full it is.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func legendLine(_ color: Color, _ name: String, _ bytes: Int64, of total: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(name).font(.caption)
            Spacer(minLength: 4)
            Text(CatalogStorageTotals.displaySize(bytes))
                .font(.caption.monospacedDigit())
            Text(MediaDistributionFormat.percentString(total > 0 ? Double(bytes) / Double(total) * 100 : 0))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    /// Eras: one bar per decade, chronological, palette ramp.
    private func erasCard(_ s: VolumeDashboardStats) -> some View {
        card("Eras", subtitle: "by decade of the footage") {
            barChart(s.decade, horizontal: false)
                .frame(height: 150)
        }
    }

    // MARK: - Cards

    private func donutCard(_ title: String, subtitle: String, series: VolumeDashboardSeries) -> some View {
        card(title, subtitle: subtitle) {
            if series.slices.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    donut(series)
                        .frame(width: Self.donutSize, height: Self.donutSize)
                    compactLegend(series)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func foldersCard(_ s: VolumeDashboardStats) -> some View {
        card("Folders", subtitle: "top-level folders, largest first") {
            barChart(s.folders, horizontal: true)
                .frame(height: max(140, CGFloat(s.folders.slices.count) * 26 + 16))
        }
    }

    private func yearsCard(_ s: VolumeDashboardStats) -> some View {
        card("Years", subtitle: "the archive's decade/year scaffold") {
            barChart(s.year, horizontal: false, showEveryLabel: false)
                .frame(height: 150)
        }
    }

    private func card<Content: View>(_ title: String, subtitle: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.card.\(title)")
    }

    // MARK: - Charts

    private func value(_ slice: VolumeDashboardSlice) -> Double {
        measure == .size ? Double(slice.bytes) : Double(slice.files)
    }

    private func color(for slice: VolumeDashboardSlice) -> Color {
        if let fixed = slice.fixedColor { return Self.resolve(fixed) }
        if let slot = slice.colorSlot {
            let p = MediaDistributionCalculator.palette(for: colorScheme)
            return p[slot % p.count]
        }
        return .gray
    }

    static func resolve(_ c: VolumeDashboardColor) -> Color {
        switch c {
        case .gray:      return .gray
        case .blue:      return .blue
        case .teal:      return .teal
        case .orange:    return .orange
        case .red:       return .red
        case .green:     return .green
        case .yellow:    return .yellow
        case .purple:    return .purple
        case .secondary: return Color.secondary.opacity(0.6)
        }
    }

    private func donut(_ series: VolumeDashboardSeries) -> some View {
        Chart(series.slices) { slice in
            SectorMark(
                angle: .value(measure == .size ? "Size" : "Files", value(slice)),
                innerRadius: .ratio(0.58),
                angularInset: 1.2
            )
            .cornerRadius(3)
            .foregroundStyle(by: .value("Category", slice.name))
            .annotation(position: .overlay) {
                sectorLabel(series.percent(of: slice, by: measure))
            }
        }
        .chartForegroundStyleScale(
            domain: series.slices.map(\.name),
            range: series.slices.map { color(for: $0) }
        )
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let frame = geo[anchor]
                    VStack(spacing: 1) {
                        Text(measure == .size
                             ? CatalogStorageTotals.displaySize(series.totalBytes)
                             : series.totalFiles.formatted())
                            .font(Self.centerFont)
                            .monospacedDigit()
                        Text(measure == .size ? "total" : "files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: measure)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.slices.map {
            "\($0.name) \(MediaDistributionFormat.percentString(series.percent(of: $0, by: measure)))"
        }.joined(separator: ", "))
    }

    /// Percent capsule on a sector — only when the slice can carry it.
    @ViewBuilder
    private func sectorLabel(_ percent: Double) -> some View {
        if percent >= MediaDistributionDonut.directLabelThresholdPercent {
            Text(MediaDistributionFormat.percentString(percent))
                .font(Self.sectorLabelFont)
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
        }
    }

    /// Swatch · name · value · %, one line per slice.
    private func compactLegend(_ series: VolumeDashboardSeries) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(series.slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: slice))
                        .frame(width: 13, height: 13)
                    Text(slice.name)
                        .font(Self.legendFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(measure == .size
                         ? CatalogStorageTotals.displaySize(slice.bytes)
                         : slice.files.formatted())
                        .font(Self.legendFont.monospacedDigit())
                        .foregroundColor(.primary)
                    Text(MediaDistributionFormat.percentString(series.percent(of: slice, by: measure)))
                        .font(Self.legendFont.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .help("\(slice.name): \(CatalogStorageTotals.displaySize(slice.bytes)), \(slice.files.formatted()) files")
            }
        }
    }

    /// Bars: vertical (x = category) or horizontal (y = category, sorted
    /// by the series order, which is largest-first for folders).
    private func barChart(_ series: VolumeDashboardSeries, horizontal: Bool,
                          showEveryLabel: Bool = true) -> some View {
        let unit = measure == .size ? "Size" : "Files"
        return Chart(series.slices) { slice in
            if horizontal {
                BarMark(x: .value(unit, value(slice)),
                        y: .value("Category", slice.name))
                    .foregroundStyle(by: .value("Category", slice.name))
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        Text(measure == .size
                             ? CatalogStorageTotals.displaySize(slice.bytes)
                             : slice.files.formatted())
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
            } else {
                BarMark(x: .value("Category", slice.name),
                        y: .value(unit, value(slice)))
                    .foregroundStyle(by: .value("Category", slice.name))
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        if showEveryLabel || series.slices.count <= 12 {
                            Text(measure == .size
                                 ? CatalogStorageTotals.displaySize(slice.bytes)
                                 : slice.files.formatted())
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: series.slices.map(\.name),
            range: series.slices.map { color(for: $0) }
        )
        .chartLegend(.hidden)
        .chartXAxis {
            if horizontal {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(measure == .size ? CatalogStorageTotals.displaySize(Int64(d)) : Int(d).formatted())
                                .font(.caption2)
                        }
                    }
                }
            } else {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2)
                }
            }
        }
        .chartYAxis {
            if horizontal {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2)
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(measure == .size ? CatalogStorageTotals.displaySize(Int64(d)) : Int(d).formatted())
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: measure)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.slices.map { "\($0.name) \(CatalogStorageTotals.displaySize($0.bytes))" }
            .joined(separator: ", "))
    }
}
