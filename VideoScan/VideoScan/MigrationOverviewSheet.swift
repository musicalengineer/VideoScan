import SwiftUI
import Charts

// MARK: - MigrationOverviewSheet (View 3)
//
// "From aging drives to safe homes." Four sections, top-to-bottom:
//   1. Fleet snapshot pie (records by current host role)
//   2. Migration flow stacked bars (where records by origin role now live)
//   3. Triage funnel (Scanned → Triaged → Repaired/Combined → Archived)
//   4. "Best stuff" highlight — clips that made it all the way
//
// Friendly-tone copy per feedback_friendly_language.md.
//
// macOS 26+ Charts framework usage — `SectorMark` is native, `BarMark`
// stacked via `.position(by:)`. No third-party deps.

struct MigrationOverviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let overview: MigrationOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    fleetSection
                    Divider()
                    flowSection
                    Divider()
                    funnelSection
                    Divider()
                    bestStuffSection
                }
                .padding(.vertical, 4)
            }
            buttonBar
        }
        .padding(22)
        .frame(minWidth: 720, idealWidth: 800, minHeight: 600, idealHeight: 720)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 32))
                .foregroundColor(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("From aging drives to safe homes")
                    .font(.title.bold())
                    .accessibilityIdentifier("migrationOverview.title")
                Text("Snapshot taken \(Self.timeString(overview.generatedAt)) — \(overview.totalRecords) record\(overview.totalRecords == 1 ? "" : "s") on the books.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 1. Fleet snapshot

    @ViewBuilder
    private var fleetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where your files live right now")
                .font(.title3.bold())
                .accessibilityIdentifier("migrationOverview.fleetTitle")
            if overview.fleetSlices.isEmpty {
                emptyHint("No files in the catalog yet.")
            } else {
                HStack(alignment: .top, spacing: 22) {
                    fleetChart
                        .frame(width: 220, height: 220)
                    fleetLegend
                    Spacer()
                }
            }
        }
    }

    private var fleetChart: some View {
        Chart(overview.fleetSlices) { slice in
            SectorMark(
                angle: .value("Records", slice.recordCount),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(slice.role.color)
        }
        .chartLegend(.hidden)
        .accessibilityIdentifier("migrationOverview.fleetChart")
    }

    private var fleetLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(overview.fleetSlices) { slice in
                HStack(spacing: 6) {
                    Circle()
                        .fill(slice.role.color)
                        .frame(width: 10, height: 10)
                    Text(slice.label)
                        .font(.callout)
                    Spacer()
                    Text("\(slice.recordCount)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: 260)
    }

    // MARK: - 2. Migration flow

    @ViewBuilder
    private var flowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How files moved between drives")
                .font(.title3.bold())
                .accessibilityIdentifier("migrationOverview.flowTitle")
            if overview.flowBars.isEmpty {
                emptyHint("No movement to show yet — nothing has been migrated.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(overview.flowBars) { bar in
                        flowBarView(bar)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func flowBarView(_ bar: MigrationFlowBar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: bar.sourceRole.icon)
                    .foregroundColor(bar.sourceRole.color)
                Text(bar.headline)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(bar.totalRecords) record\(bar.totalRecords == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Chart(bar.entries) { entry in
                BarMark(
                    x: .value("Records", entry.recordCount),
                    y: .value("Source", bar.sourceRole.rawValue)
                )
                .foregroundStyle(entry.destinationRole.color)
            }
            .frame(height: 28)
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Compact destination labels under the bar.
            HStack(spacing: 8) {
                ForEach(bar.entries) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(entry.destinationRole.color)
                            .frame(width: 8, height: 8)
                        Text("\(entry.destinationRole.rawValue) \(entry.recordCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .accessibilityIdentifier("migrationOverview.flowBar.\(bar.sourceRole.rawValue)")
    }

    // MARK: - 3. Triage funnel

    @ViewBuilder
    private var funnelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Triage progress")
                .font(.title3.bold())
                .accessibilityIdentifier("migrationOverview.funnelTitle")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(overview.funnelStages) { stage in
                    funnelRow(stage)
                }
            }
        }
    }

    private func funnelRow(_ stage: TriageFunnelStage) -> some View {
        let top = overview.funnelStages.first?.recordCount ?? max(stage.recordCount, 1)
        let fraction = top > 0 ? min(1.0, Double(stage.recordCount) / Double(top)) : 0
        return HStack(spacing: 10) {
            Image(systemName: stage.icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(stage.label)
                .font(.callout)
                .frame(width: 200, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 16)
            Text("\(stage.recordCount)")
                .font(.system(.callout, design: .monospaced).bold())
                .frame(width: 60, alignment: .trailing)
        }
        .accessibilityIdentifier("migrationOverview.funnelRow.\(stage.label)")
    }

    // MARK: - 4. Best stuff

    @ViewBuilder
    private var bestStuffSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The best stuff")
                .font(.title3.bold())
                .accessibilityIdentifier("migrationOverview.bestTitle")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("\(overview.bestStuffCount)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(overview.bestStuffCount > 0 ? .green : .secondary)
                    .accessibilityIdentifier("migrationOverview.bestStuffCount")
                Text(overview.bestStuffSentence)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("migrationOverview.bestStuffSentence")
                Spacer()
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.06))
        .cornerRadius(8)
    }

    // MARK: - Buttons & helpers

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("migrationOverview.done")
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
