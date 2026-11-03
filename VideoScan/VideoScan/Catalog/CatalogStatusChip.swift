// CatalogStatusChip.swift
// The catalog's vital signs on the totals strip (Rick 2026-10-16 placement,
// far left of "TOTAL CATALOG"; split in two 2026-11-03, DECISIONS "two
// indicators, Catalog and Content"):
//
//   ● Catalog: Synced        ● Content: Up to date
//
//   Catalog  Synced (green) · Stale (yellow) · Unhealthy (red) · Unknown
//            (grey). Click → the Catalog Status window, which says why and
//            the one fix. Yellow and red earn a tinted pill.
//   Content  Up to date (green) · N left to analyze (grey) · Analyzing N of
//            M files (blue). Never yellow, never red, never a pill: content
//            is almost always behind — a work in progress, not an alarm; a
//            yellow that is always on teaches the eye to ignore yellow,
//            including Catalog's (Rick). Click → Content Analysis, where
//            per-file problems are listed.
//
// Both at the totals strip's own 15pt mono register so they read as figures,
// not chrome. The window's lead lines ride in each tooltip.
//
// OBSERVATION: observes the model's CatalogFreshnessSnapshot and nothing
// else (equality-gated, published once per debounced catalog change / job
// start / minute). Pure layout over that one value — `CatalogStatusIndicators`
// is a few strings built in the snapshot's one rejudge; nothing here touches
// the model or records (CatalogStatusSensorTests pins it).

import SwiftUI
import VideoScanCore

struct CatalogStatusChip: View {

    @ObservedObject var freshness: CatalogFreshnessSnapshot

    @Environment(\.openWindow) private var openWindow

    private var indicators: CatalogStatusIndicators { CatalogStatusIndicators(freshness.state) }

    var body: some View {
        HStack(spacing: 12) {
            IndicatorButton(indicator: indicators.catalog, prefix: CatalogStatusIndicator.catalogPrefix,
                            pill: indicators.catalog.state.needsAttention,
                            help: "Does the catalog match the disks? Click to open Catalog Status.",
                            identifier: "catalog.statusChip.catalog", action: openCatalogStatus)
            IndicatorButton(indicator: indicators.content, prefix: CatalogStatusIndicator.contentPrefix,
                            pill: false,
                            help: "Is every file analyzed? Click to open Content Analysis.",
                            identifier: "catalog.statusChip.content", action: openContentAnalysis)
        }
    }

    private func openCatalogStatus() {
        openWindow(id: CatalogStatusWindow.sceneID)
    }

    private func openContentAnalysis() {
        AnalyzeWindowOpener.open(using: openWindow, source: "status-chip")
    }
}

/// One dot, a prefix and the words; a value in, a button out.
private struct IndicatorButton: View {
    let indicator: CatalogStatusIndicator
    let prefix: String
    /// Only Catalog's yellow and red earn the tinted pill.
    let pill: Bool
    let help: String
    let identifier: String
    let action: () -> Void

    private var tint: Color { indicator.state.tint }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .padding(.trailing, 8)
                Text(prefix)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize()
                Text(indicator.words)
                    .font(.system(size: 15, weight: pill ? .semibold : .medium, design: .monospaced))
                    .foregroundColor(pill ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(pill ? tint.opacity(0.16) : Color.clear))
            .overlay(Capsule().strokeBorder(pill ? tint.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(([help] + indicator.why).joined(separator: "\n"))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(prefix)\(indicator.words)")
    }
}
