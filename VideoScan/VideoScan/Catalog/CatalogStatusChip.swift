// CatalogStatusChip.swift
// The catalog's fourth vital sign on the totals strip (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §4): far left of
// "TOTAL CATALOG", in line with UNIQUE and ARCHIVED. A coloured dot and
// one short sentence; click opens Content Analysis, where the summary
// band at the top says the same thing with the items behind it.
//
//   ● Catalog current · checked 02:14        (green: quiet secondary text)
//   ● 2 things need a run                    (yellow: a run fixes it)
//   ● Needs attention: 3 rows point at nothing (red: a person must look)
//
// MOCK (2026-10-16): the words and colour are fixed until the freshness
// model (VideoScanCore.CatalogFreshness) and the integrity rows land;
// the chip's shape, place and door are what Rick is judging by eye.
// Pure layout — nothing here observes the model.

import SwiftUI

struct CatalogStatusChip: View {

    enum Colour { case green, yellow, red, grey }

    var colour: Colour = .yellow
    var words: String = "2 things need a run"

    @Environment(\.openWindow) private var openWindow

    private var tint: Color {
        switch colour {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .grey: return .secondary
        }
    }

    /// Green stays calm: secondary text, no tinted pill. Yellow and red
    /// earn the pill so the eye lands on them before the figures.
    private var isQuiet: Bool { colour == .green || colour == .grey }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(words)
                    .font(.system(size: 12, weight: isQuiet ? .regular : .medium))
                    .foregroundColor(isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 9)
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
        .help("Catalog status (mock while the freshness model is built). Click to open Content Analysis.")
        .accessibilityIdentifier("catalog.statusChip")
        .accessibilityLabel("Catalog status: \(words)")
    }

    private func open() {
        AnalyzeWindowOpener.open(using: openWindow, source: "status-chip")
    }
}
