// CatalogAnalyzeMenu.swift
// The Catalog toolbar's ONE knowledge menu (Phase A trial, 2026-10-02;
// design §3.2). Replaces the "Correlate A/V Pairs" menu AND the
// "Duplicates" menu:
//
//   Analyze ▾
//     Click a row to update it now
//     Duplicates — current · 13,842 of 13,842
//     Similar Footage — 3,112 grouped · last run 2 days ago
//     … one row per cycler, registry order; a running one reads "running…"
//     ─────────────
//     Analyze Selected (N) — Duplicates / Similar Footage / Correlate A/V
//     ─────────────
//     Show Pairs Only ✓   One Per Footage
//     ─────────────
//     Combine All Correlated Pairs…        (the batch mux — kept reachable)
//     ─────────────
//     Analyze…   ⇧⌘O                       (opens the panel)
//
// Rules carried over from CatalogDuplicatesMenu.swift (Rick 2026-09-22):
// NO nested `Menu` — an open submenu on macOS closes whenever anything in
// the window updates, and the Catalog window updates many times a second
// while anything runs. "Analyze Selected ▸" is therefore FLATTENED into
// three top-level items (CatalogAnalyzeMenuStructureTests guards it). The
// menu is NEVER disabled as a whole: a cycler that is running shows
// "running…" on its own row and only that row is disabled.
//
// "Delete Duplicates on Volume…" and "Also clean up working copies" are
// NOT here any more — they moved to the Storage tab's Reclaimable card,
// where the operand (a drive) lives. The from-scratch "Clear &
// Re-correlate All…" moved into the Analyze panel's Correlate row.
//
// OBSERVATION: the one @ObservedObject is the model's
// AnalyzeCoverageSnapshot — equality-gated, published once per debounced
// catalog change, never per record. Everything else is a plain value.

import SwiftUI

struct CatalogAnalyzeMenu: View {

    @ObservedObject var coverage: AnalyzeCoverageSnapshot
    /// Cyclers whose engine flag is set right now (toolbar-computed).
    let running: Set<AnalyzeCycler>
    let isReadOnly: Bool
    let selectionCount: Int
    let hasCorrelatedPairs: Bool
    let canCombine: Bool
    let isCombining: Bool
    @Binding var showPairsOnly: Bool
    @Binding var viewFilters: Set<CatalogViewFilter>

    let onUpdateNow: (AnalyzeCycler) -> Void
    let onAnalyzeSelectedDuplicates: () -> Void
    let onAnalyzeSelectedFootage: () -> Void
    let onAnalyzeSelectedCorrelate: () -> Void
    let onOpenCombineSheet: () -> Void
    let onOpenPanel: () -> Void

    static let openPanelTitle = "Analyze…"
    static let analyzeSelectedPrefix = "Analyze Selected"

    /// "Duplicates — current · 13,842 of 13,842" / "… — running…"
    static func rowTitle(_ cycler: AnalyzeCycler, summary: String, isRunning: Bool) -> String {
        "\(cycler.menuTitle) — \(isRunning ? "running…" : summary)"
    }

    /// "Analyze Selected (3) — Duplicates"
    static func selectedTitle(_ cycler: AnalyzeCycler, count: Int) -> String {
        "\(analyzeSelectedPrefix) (\(count)) — \(cycler.menuTitle)"
    }

    var body: some View {
        Menu {
            Text("Click a row to update it now")
            ForEach(AnalyzeCycler.allCases) { cycler in
                let isRunning = running.contains(cycler)
                Button(Self.rowTitle(cycler, summary: coverage.report.menuSummary(cycler), isRunning: isRunning)) {
                    onUpdateNow(cycler)
                }
                .disabled(isRunning || isReadOnly)
                .help(cycler.help)
            }

            Divider()
            Button(Self.selectedTitle(.duplicates, count: selectionCount), action: onAnalyzeSelectedDuplicates)
                .disabled(selectionCount == 0 || isReadOnly || running.contains(.duplicates))
            Button(Self.selectedTitle(.footage, count: selectionCount), action: onAnalyzeSelectedFootage)
                .disabled(selectionCount == 0 || isReadOnly)
            Button(Self.selectedTitle(.correlate, count: selectionCount), action: onAnalyzeSelectedCorrelate)
                .disabled(selectionCount == 0 || isReadOnly || running.contains(.correlate))

            Divider()
            Toggle("Show Pairs Only", isOn: $showPairsOnly)
                .disabled(!hasCorrelatedPairs)
            Toggle("One Per Footage", isOn: Binding(
                get: { viewFilters.contains(.onePerFootage) },
                set: { on in
                    if on { viewFilters.insert(.onePerFootage) } else { viewFilters.remove(.onePerFootage) }
                }))

            Divider()
            // BATCH combine — the step AFTER correlating; the row's
            // right-click only offers one pair at a time, so this stays
            // reachable here (it is a file operation; its home is a Phase C
            // question).
            Button("Combine All Correlated Pairs…", action: onOpenCombineSheet)
                .disabled(!canCombine && !isCombining)
                .accessibilityIdentifier("catalog.combine.openSheet")

            Divider()
            // ⇧⌘O is declared ONCE, on the Window menu item (VideoScanApp);
            // a second key equivalent here would shadow it.
            Button(Self.openPanelTitle, action: onOpenPanel)
                .help("Open the Analyze panel (⇧⌘O): every cycler's state, coverage by drive, Pause/Resume and Run now.")
                .accessibilityIdentifier("catalog.analyze.openPanel")
        } label: {
            if running.isEmpty {
                Label("Analyze", systemImage: "wand.and.stars")
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Analyze")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("catalog.analyze.menu")
        .help("What the catalog knows about your files and how current it is. Click a row to bring it up to date; Analyze… opens the full panel.")
    }
}
