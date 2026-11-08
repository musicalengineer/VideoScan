// ValidateCatalogMenuItem.swift
// Catalog ▸ "Validate Catalog…" — the ONE catalog-checking verb (Rick
// 2026-10-20; it replaces the separate "Audit Catalog…" and "Verify
// Catalog…" items). Since the 11/01 "what and how long" rule the item opens
// ValidateCatalogSheet first: what it touches, what it never touches, how
// long; Start there runs ValidateCatalogJob as a Media File Operation (the
// MFO window comes forward via `startedByUser`): every file on disk first,
// then — only after a complete file check — the catalog against itself.
// The Catalog Status window's "Check Now…" opens the same sheet. The menu
// never starts it on its own; the app's daily check (DailyFileCheck, 03:30
// in the away window) starts the same job, and `--validate-catalog` (or the
// older `--audit-catalog`) runs it headless.

import SwiftUI

struct ValidateCatalogMenuItem: View {
    @ObservedObject var store: CatalogMenuStore
    let isReadOnly: Bool

    var body: some View {
        Button("Validate Catalog…") {
            store.present(.validateCatalog)
        }
        .disabled(isReadOnly)
        .help(CatalogActionBrief.validateCatalog.help)
        .accessibilityIdentifier("catalog.menu.validateCatalog")
    }
}

/// The sheet in front of Validate Catalog: the brief, then Start / Cancel.
/// Start is the one engine (`CatalogMenuActions.startValidate`).
struct ValidateCatalogSheet: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Validate Catalog")
                .font(.title2.weight(.semibold))
            CatalogActionBriefHeader(brief: .validateCatalog)
            Text("Step 1 asks every connected drive's files; step 2 runs only after a complete step 1. The report is what Catalog Status reads.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    CatalogMenuActions.startValidate(model: model, center: center)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.isReadOnly)
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityIdentifier("sheet.validateCatalog")
    }
}
