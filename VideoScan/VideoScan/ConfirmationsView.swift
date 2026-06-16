// ConfirmationsView.swift
// Cumulative-progress view for a single person, presented as a sheet
// from the PersonCard right-click "View Confirmations…" item. Reads
// directly from the ValidationLabelStore (all rounds, all sessions)
// AND the live catalog (to count the total candidate pool today).
//
// Rick 2026-06-16. Answers "how far have I gotten with Donna?"
// without making the user re-open the Confirm sheet just to see
// progress numbers.

import SwiftUI

struct ConfirmationsTarget: Identifiable {
    let id = UUID()
    let profile: POIProfile
}

struct ConfirmationsView: View {

    let profile: POIProfile
    @EnvironmentObject var personFinderModel: PersonFinderModel
    @EnvironmentObject var catalogModel: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    /// Callback invoked when the user clicks "Confirm More…" from
    /// this view. The parent (PersonFinderView) uses it to open the
    /// Confirm sheet for the same profile.
    let onConfirmMore: () -> Void

    @State private var stats: ConfirmRoundStats?
    @State private var allLabels: [ValidationLabel] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    progressSection
                    outcomesSection
                    if !signalPrecision.isEmpty {
                        signalsSection
                    }
                    if !rounds.isEmpty {
                        roundsSection
                    }
                    remainingSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .onAppear(perform: loadData)
        .onDisappear { loadTask?.cancel() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(profile.name) \u{2014} Confirmations")
                    .font(.headline)
                Text("Cumulative progress across every Confirm round.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var progressSection: some View {
        let reviewed = allLabels.count
        let total = (stats?.candidatesSurfaced ?? 0)
        let pct = total > 0 ? Double(reviewed) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Progress")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(reviewed) of \(total) candidates \u{00B7} \(Int(pct * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: pct)
                .tint(.accentColor)
        }
    }

    private var outcomesSection: some View {
        let counts = countsByRating
        return VStack(alignment: .leading, spacing: 8) {
            Text("Outcomes")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 4) {
                ForEach(ConfirmRating.userFacing) { rating in
                    HStack {
                        Image(systemName: rating.symbol).foregroundColor(rating.color).frame(width: 18)
                        Text(rating.rawValue).frame(width: 90, alignment: .leading)
                        Text("\(counts[rating, default: 0])")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .leading)
                        Text(writebackHint(for: rating))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                // Surface any legacy Unsure/Unlikely labels from v1
                // rounds, but de-emphasize them.
                let legacy = (counts[.unsure, default: 0]) + (counts[.unlikely, default: 0])
                if legacy > 0 {
                    HStack {
                        Image(systemName: "questionmark.circle").foregroundColor(.secondary).frame(width: 18)
                        Text("Unsure / past")
                            .frame(width: 90, alignment: .leading)
                            .foregroundColor(.secondary)
                        Text("\(legacy)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Text("v1 rounds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var signalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where positives came from")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 4) {
                ForEach(signalPrecision, id: \.signal) { item in
                    HStack {
                        Image(systemName: symbol(for: item.signal))
                            .foregroundColor(.accentColor)
                            .frame(width: 18)
                        Text(item.signal).frame(width: 140, alignment: .leading)
                        Text("\(item.positives)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 36, alignment: .leading)
                        Text("\(Int(item.precision * 100))% precise")
                            .font(.caption)
                            .foregroundColor(precisionColor(item.precision))
                        Spacer()
                    }
                }
            }
        }
    }

    private var roundsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rounds")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 4) {
                ForEach(rounds.indices, id: \.self) { idx in
                    let r = rounds[idx]
                    HStack {
                        Text("Round \(idx + 1)")
                            .frame(width: 70, alignment: .leading)
                        Text(r.firstLabel, style: .date)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(r.count) labels")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var remainingSection: some View {
        guard let stats else { return AnyView(EmptyView()) }
        let remaining = max(0, stats.candidatesSurfaced - allLabels.count)
        // Treat remaining as: total surfaced - already-labeled.
        // Of that, some are still online, some offline. We don't have
        // the exact split without re-running the scoring + reachability
        // pass; surface the headline number and the offline volumes.
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("Remaining")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed")
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                    Text("\(remaining) candidates unreviewed")
                }
                if stats.offlineSkipped > 0 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundColor(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(stats.offlineSkipped) on offline volumes:")
                            Text(stats.offlineVolumes.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if stats.dupesCollapsed > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        Text("\(stats.dupesCollapsed) collapsed as duplicates")
                            .foregroundColor(.secondary)
                    }
                }
            }
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button("Confirm More\u{2026}") {
                dismiss()
                onConfirmMore()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Data loading

    private func loadData() {
        loadTask = Task { @MainActor in
            // Labels are cheap to fetch from the store.
            let store = personFinderModel.validationLabels
            let target = profile.name.lowercased()
            allLabels = store.labels.filter { $0.person.lowercased() == target }

            // Score the catalog to get the surfaced count + stats.
            // This is the same pass the Confirm setup pane runs and
            // takes ~1-2 sec on 16K records.
            let already = Set(allLabels.map { $0.recordPath })
            var rng = SystemRandomNumberGenerator()
            let result = pfConfirmRound(
                name: profile.name,
                records: catalogModel.records,
                topN: 100, controlK: 0,
                alreadyLabeled: already,
                rng: &rng
            )
            self.stats = result.stats
        }
    }

    // MARK: - Derived

    private var countsByRating: [ConfirmRating: Int] {
        var out: [ConfirmRating: Int] = [:]
        for l in allLabels {
            out[l.rating, default: 0] += 1
        }
        return out
    }

    private struct SignalPrecisionRow {
        let signal: String
        let positives: Int
        let total: Int
        let precision: Double
    }

    private var signalPrecision: [SignalPrecisionRow] {
        var bySignal: [String: (positives: Int, total: Int)] = [:]
        for l in allLabels {
            let isPositive = (l.rating == .definitely || l.rating == .likely)
            for sig in l.signals where sig != "control" {
                var cell = bySignal[sig, default: (0, 0)]
                cell.total += 1
                if isPositive { cell.positives += 1 }
                bySignal[sig] = cell
            }
        }
        return bySignal
            .map { SignalPrecisionRow(
                signal: $0.key, positives: $0.value.positives,
                total: $0.value.total,
                precision: $0.value.total == 0 ? 0
                    : Double($0.value.positives) / Double($0.value.total)
            )}
            .sorted { $0.total > $1.total }
    }

    private struct RoundEntry {
        let firstLabel: Date
        let count: Int
    }

    /// Group labels into "rounds" by time clustering — labels within
    /// 30 minutes of each other are the same round.
    private var rounds: [RoundEntry] {
        let sorted = allLabels.sorted { $0.labeledAt < $1.labeledAt }
        guard !sorted.isEmpty else { return [] }
        var groups: [(start: Date, count: Int)] = []
        var lastTime = sorted[0].labeledAt
        var groupStart = sorted[0].labeledAt
        var groupCount = 0
        for l in sorted {
            if l.labeledAt.timeIntervalSince(lastTime) > 30 * 60 {
                groups.append((groupStart, groupCount))
                groupStart = l.labeledAt
                groupCount = 0
            }
            groupCount += 1
            lastTime = l.labeledAt
        }
        if groupCount > 0 {
            groups.append((groupStart, groupCount))
        }
        return groups.map { RoundEntry(firstLabel: $0.start, count: $0.count) }
    }

    private func writebackHint(for rating: ConfirmRating) -> String {
        switch rating {
        case .definitely: return "\u{2192} confirmedByUserPeople"
        case .likely:     return "\u{2192} suspectedPeople"
        case .no:         return "\u{2192} rejectedPeople"
        case .unsure, .unlikely: return ""
        }
    }

    private func symbol(for signal: String) -> String {
        if signal.hasPrefix("PF-") || signal == "user-confirmed" { return "person.crop.square" }
        if signal == "filename" { return "doc" }
        if signal == "directory" { return "folder" }
        if signal.hasPrefix("transcript") { return "waveform" }
        if signal.hasPrefix("captions") { return "text.bubble" }
        if signal.hasPrefix("ocr") { return "textformat.size" }
        return "circle"
    }

    private func precisionColor(_ p: Double) -> Color {
        switch p {
        case 0.90...:    return .green
        case 0.75..<0.90: return .blue
        case 0.50..<0.75: return .orange
        default:         return .red
        }
    }
}
