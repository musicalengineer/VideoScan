// PromoteToArchiveSheet+Readiness.swift
// The archival-readiness section of the Promote confirmation sheet (Rick
// 2026-08-16): summary counters (audio first), one line per file, and the
// "Archive anyway (I know this file)" override for un-probeable files.
// Everything here reads the plan's precomputed entries — O(selection),
// never O(records).

import SwiftUI

extension PromoteToArchiveSheet {

    @ViewBuilder
    var readinessSection: some View {
        let plan = request.plan
        if !plan.entries.isEmpty {
            GroupBox("Archival readiness (preserve as-is — assess, record, never alter)") {
                VStack(alignment: .leading, spacing: 6) {
                    // Counters — audio first, then format, then date, then un-probeable.
                    HStack(spacing: 12) {
                        counter(plan.audioProblemCount, "audio problem", color: .red, icon: "waveform.badge.exclamationmark")
                        counter(plan.audioNotVerifiedCount, "audio not verified", color: .orange, icon: "waveform")
                        counter(plan.atRiskFormatCount, "at-risk format", color: .orange, icon: "film")
                        counter(plan.dateWarningCount, "undated / low-confidence", color: .secondary, icon: "calendar.badge.exclamationmark")
                        counter(plan.unprobeableCount, "un-probeable", color: .red, icon: "xmark.octagon")
                    }
                    .font(.system(size: 11))

                    Divider()

                    // Per-file lines (bounded list; the selection is what the user chose).
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(plan.entries) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.filename)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(entry.readiness.sheetLine(dateLabel: entry.dateHint.filenamePrefix))
                                        .font(.system(size: 11))
                                        .foregroundColor(entry.readiness.blocking ? .red
                                                         : (entry.readiness.warnings.isEmpty ? .green : .secondary))
                                    // First (most important — audio-first) warning, if any.
                                    if let first = entry.readiness.warnings.first {
                                        Text(first)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: min(220, CGFloat(plan.entries.count) * 44 + 8))

                    if plan.unprobeableCount > 0 {
                        Divider()
                        Toggle(isOn: $overrideUnprobeable) {
                            Text("Archive anyway (I know this file)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.checkbox)
                        .help("\(plan.unprobeableCount) file(s) could not be probed (no decodable streams). The archive would hold bytes nobody has decoded — promote only if you know what they are.")
                        .accessibilityIdentifier("promote.overrideUnprobeable")
                        Text("Un-probeable files are the only thing that stops a promotion. Everything else is a note for later — the original is always preserved byte-for-byte.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private func counter(_ n: Int, _ label: String, color: Color, icon: String) -> some View {
        Label("\(n) \(label)", systemImage: icon)
            .foregroundColor(n == 0 ? .secondary : color)
            .opacity(n == 0 ? 0.6 : 1)
    }
}
