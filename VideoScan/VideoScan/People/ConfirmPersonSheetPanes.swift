// ConfirmPersonSheetPanes.swift
// Two sub-views extracted from ConfirmPersonSheet.swift (Rick
// 2026-06-17): the setup pane (stats card + round-size picker) and
// the end-of-round summary pane. Both take their inputs as plain
// let/Binding parameters so they're independently previewable and
// can be unit-tested without spinning up the full sheet state.
//
// ConfirmPersonSheet.swift dropped ~165 lines after this extraction.

import AppKit
import SwiftUI

// MARK: - Setup Pane

/// Round-setup view shown before any labeling begins. Surfaces what
/// the catalog scoring pass found, lets the user pick a round size
/// with a time estimate, and renders a "scoring…" placeholder while
/// the background score job is still running.
struct ConfirmSetupPane: View {
    let personName: String
    let stats: ConfirmRoundStats?
    /// Used to count "online and ready" candidates and to clamp the
    /// round-size picker upper bound. Not stored — passed in so the
    /// pane stays a pure render of inputs.
    let availOnline: Int
    @Binding var roundSize: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stats {
                statsCard(stats)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scoring catalog\u{2026}")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            roundSizePicker
            Spacer()
        }
        .padding(20)
    }

    private func statsCard(_ s: ConfirmRoundStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available for \(personName)")
                .font(.subheadline.weight(.medium))
            statRow(symbol: "magnifyingglass", color: .blue,
                    text: "\(s.candidatesSurfaced) candidates surfaced by catalog signal")
            if s.dupesCollapsed > 0 {
                let breakdown = "\(s.exactDupesCollapsed) exact + \(s.fuzzyDupesCollapsed) transcoded"
                statRow(symbol: "arrow.triangle.merge", color: .secondary,
                        text: "\(s.dupesCollapsed) duplicates collapsed (\(breakdown))")
            }
            if s.audioOnlySkipped > 0 {
                statRow(symbol: "waveform.slash", color: .secondary,
                        text: "\(s.audioOnlySkipped) audio-only \u{2014} skipped (no video to review)")
            }
            if s.tooLongSkipped > 0 {
                statRow(symbol: "hourglass", color: .secondary,
                        text: "\(s.tooLongSkipped) over \(s.durationCapMinutes) min \u{2014} skipped")
            }
            if s.alreadyLabeled > 0 {
                statRow(symbol: "checkmark.seal", color: .green,
                        text: "\(s.alreadyLabeled) already labeled in prior rounds \u{2014} skipped")
            }
            if s.heldOutExcluded > 0 {
                // Blocker fix 2026-07-27: eval-set rows never appear in
                // rated rounds; honest count, friendly wording.
                statRow(symbol: "eye.slash", color: .purple,
                        text: "\(s.heldOutExcluded) reserved for the blind review set \u{2014} excluded until that set retires")
            }
            if s.offlineSkipped > 0 {
                statRow(
                    symbol: "externaldrive.badge.exclamationmark", color: .orange,
                    text: "\(s.offlineSkipped) offline \u{2014} mount " +
                          s.offlineVolumes.joined(separator: ", ") +
                          " to include them"
                )
            }
            Divider().padding(.vertical, 4)
            statRow(symbol: "checkmark.circle", color: .accentColor,
                    text: "\(availOnline) candidates ready to review now")
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func statRow(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(color).frame(width: 18)
            Text(text).font(.callout)
            Spacer()
        }
    }

    private var roundSizePicker: some View {
        let options: [Int] = {
            var opts: [Int] = []
            for size in [10, 25, 50, 100] where size <= availOnline {
                opts.append(size)
            }
            if !opts.contains(availOnline) && availOnline > 0 { opts.append(availOnline) }
            return opts
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text("How many would you like to review now?")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { n in
                    Button {
                        roundSize = n
                    } label: {
                        Text(n == availOnline ? "All (\(n))" : "\(n)")
                            .frame(minWidth: 48)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(roundSize == n ? .accentColor : .secondary)
                }
                Spacer()
            }
            // Time estimate — 25 sec / candidate is a rough heuristic
            // (Rick's observed rate is ~12-15 sec/candidate, so this
            // over-estimates and the user is pleasantly surprised).
            Text("Estimated time: ~\(estimateMinutes(roundSize)) minutes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func estimateMinutes(_ size: Int) -> Int {
        max(1, (size * 25) / 60)
    }
}

// MARK: - Summary Pane

/// End-of-round report. Counts per rating tier + per-signal sources
/// of the confirmed positives + an explanation of what wrote back to
/// the catalog. Wrapped in a ScrollView so long signal-source lists
/// don't push the footer off-screen.
struct ConfirmSummaryPane: View {
    let personName: String
    let summary: ValidationLabelStore.RoundSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Round summary \u{2014} \(summary.total) labels")
                    .font(.title3.weight(.semibold))
                outcomesSection
                if !summary.signalsByPositive.isEmpty {
                    Divider()
                    signalsSection
                }
                Text("Catalog updated. Definitely \u{2192} confirmedByUserPeople, Likely \u{2192} suspectedPeople, No \u{2192} rejectedPeople. Cameo labels stay in the training sidecar only \u{2014} they don't elevate the record in search but are remembered.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(20)
        }
    }

    private var outcomesSection: some View {
        VStack(spacing: 6) {
            ForEach(ConfirmRating.userFacing) { rating in
                HStack {
                    Image(systemName: rating.symbol)
                        .foregroundColor(rating.color)
                        .frame(width: 18)
                    Text(rating.rawValue)
                        .frame(width: 110, alignment: .leading)
                    Text("\(summary.counts[rating, default: 0])")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                }
            }
        }
    }

    private var signalsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where \(personName) was confirmed \u{2014} signal sources")
                .font(.subheadline.weight(.medium))
            ForEach(summary.signalsByPositive.sorted { $0.value > $1.value }, id: \.key) { sig, count in
                HStack {
                    Image(systemName: confirmSignalIcon(sig))
                        .foregroundColor(.accentColor)
                        .frame(width: 18)
                    Text(sig)
                        .frame(width: 160, alignment: .leading)
                    Text("\(count)")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                }
                .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Shared signal-icon helper
//
// Used by ConfirmPersonSheet, ConfirmSummaryPane, and ConfirmationsView.
// Pure function — `nonisolated` so callers from any actor can use it.

nonisolated func confirmSignalIcon(_ signal: String) -> String {
    if signal.hasPrefix("PF-") || signal == "user-confirmed" { return "person.crop.square" }
    if signal == "filename"                                  { return "doc" }
    if signal == "directory"                                 { return "folder" }
    if signal.hasPrefix("transcript")                        { return "waveform" }
    if signal.hasPrefix("captions")                          { return "text.bubble" }
    if signal.hasPrefix("ocr")                               { return "textformat.size" }
    if signal == "control"                                   { return "minus.circle" }
    return "circle"
}
