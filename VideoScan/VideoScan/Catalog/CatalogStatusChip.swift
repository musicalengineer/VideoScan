// CatalogStatusChip.swift
// The catalog's fourth vital sign on the totals strip (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §4): far left of
// "TOTAL CATALOG", in line with UNIQUE and ARCHIVED. A coloured dot and
// one short sentence; click opens Content Analysis, where the summary
// band at the top says the same thing with the items behind it.
//
//   ● Catalog Status: current            (green: quiet secondary text)
//   ● Catalog Status: needs attention    (yellow: a run fixes it)
//   ● Catalog Status: needs a decision   (red)
//
// Format (Rick 2026-10-16, shortened 2026-10-18 so it ends under the Files
// column): "Catalog Status: <colour in words>", at the totals strip's own
// 15pt mono register so it reads as one of the figures, not as chrome. The
// headline rides in the tooltip; the items are one click away.
//
// OBSERVATION: the chip observes the model's CatalogFreshnessSnapshot and
// nothing else (equality-gated, published once per debounced catalog
// change / job start / minute). Pure layout over that one value — nothing
// here touches the model or records (CatalogStatusSensorTests pins it).

import SwiftUI
import VideoScanCore

struct CatalogStatusChip: View {

    @ObservedObject var freshness: CatalogFreshnessSnapshot

    @Environment(\.openWindow) private var openWindow

    private var colour: FreshnessColour { freshness.state.isComputed ? freshness.state.summary.colour : .grey }
    private var words: String { CatalogStatusWords.chipWords(freshness.state) }
    private var tint: Color { colour.tint }

    /// Green stays calm: secondary text, no tinted pill. Yellow and red
    /// earn the pill so the eye lands on them before the figures.
    private var isQuiet: Bool { colour == .green || colour == .grey }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .padding(.trailing, 8)
                Text(CatalogStatusWords.chipPrefix)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize()
                Text(words)
                    .font(.system(size: 15, weight: isQuiet ? .medium : .semibold, design: .monospaced))
                    .foregroundColor(isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isQuiet ? Color.clear : tint.opacity(0.16))
            )
            .overlay(
                Capsule().strokeBorder(isQuiet ? Color.secondary.opacity(0.25) : tint.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Is what the catalog knows current? \(freshness.state.summary.headline). Click to open Content Analysis — the band at the top lists what needs what.")
        .accessibilityIdentifier("catalog.statusChip")
        .accessibilityLabel("Catalog status: \(words)")
    }

    private func open() {
        AnalyzeWindowOpener.open(using: openWindow, source: "status-chip")
    }
}
