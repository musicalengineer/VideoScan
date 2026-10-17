// ImportToSQLiteMenuItems.swift
// Catalog ▸ "Import to SQLite (Dry Run)…" and "Import to SQLite…" (Rick
// 2026-10-17, catalog_sqlite_migration §10c "app wiring"). The dry run
// starts straight away as a Media File Operation (the MFO window comes
// forward via `startedByUser`); the real import is ENABLED only when a dry
// run has passed on the current catalog generation (ImportDryRunMarker,
// beside the catalog) and confirms with a sheet that names the
// reconciliation line and says: the JSON catalog stays as it is; nothing is
// deleted. Both are disabled in read-only (viewer) mode.

import SwiftUI
import VideoScanCore

struct ImportToSQLiteMenuItems: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    @ObservedObject var marker: ImportDryRunMarker
    /// The catalog generation the app holds now (the store's); the marker
    /// must name the same one for the real import to be offered.
    let catalogGeneration: Int
    let isReadOnly: Bool

    var body: some View {
        Button("Import to SQLite (Dry Run)…") {
            _ = center.startedByUser { $0.startImportToSQLite(model: model, mode: .dryRun) }
        }
        .disabled(isReadOnly)
        .help("Run the whole import — the gate, every row, the sidecars, the comparator — and then roll it back. Nothing is written beside the catalog; the row shows the reconciliation line the real import would commit. The JSON catalog is read-only for the run.")
        .accessibilityIdentifier("catalog.menu.importToSQLiteDryRun")

        Button("Import to SQLite…") {
            guard let passed = marker.lastPassed else { return }
            model.importToSQLiteConfirm = ImportToSQLiteConfirmRequest(reconciliationLine: passed.reconciliationLine,
                                                                       catalogGeneration: passed.catalogGeneration)
        }
        .disabled(isReadOnly || !ImportDryRunMarker.enablesCommit(marker.lastPassed, catalogGeneration: catalogGeneration))
        .help(ImportDryRunMarker.enablesCommit(marker.lastPassed, catalogGeneration: catalogGeneration)
              ? "Import the verified catalog into catalog.sqlite beside it. The JSON catalog stays as it is; nothing is deleted. A confirm sheet names the reconciliation line first."
              : "Run Import to SQLite (Dry Run)… first; the real import is offered once a dry run has passed on this catalog.")
        .accessibilityIdentifier("catalog.menu.importToSQLite")
    }
}

/// The confirm sheet (`.sheet(item:)` on `model.importToSQLiteConfirm`).
struct ImportToSQLiteConfirmSheet: View {
    let request: ImportToSQLiteConfirmRequest
    /// Forwarded to the job only (the sheet shows the request it was handed).
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    /// The non-observing center reference (CatalogView's pattern): this
    /// sheet only starts a job.
    @Environment(\.mediaFileOperationsCenterReference) private var center

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import to SQLite")
                .font(.title2.weight(.semibold))
            Text("The dry run on catalog generation \(request.catalogGeneration) passed with this reconciliation line. The real import runs the same flow and commits it.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Text(request.reconciliationLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Label("The JSON catalog stays as it is; nothing is deleted. It is read-only while the import runs.", systemImage: "lock.shield")
                Label("One new file is written: catalog.sqlite beside the catalog. If it is already there, the import refuses.", systemImage: "cylinder")
                Label(ImportToSQLiteJob.noPauseWords, systemImage: "stop.circle")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    _ = center?.startedByUser { $0.startImportToSQLite(model: model, mode: .commit) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityIdentifier("sheet.importToSQLite")
    }
}
