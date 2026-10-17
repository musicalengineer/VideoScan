// ImportToSQLiteMenuItems.swift
// Catalog ▸ "Import to SQLite (Dry Run)…" and "Import to SQLite…" (Rick
// 2026-10-17, catalog_sqlite_migration §10c "app wiring"; one action verb
// the same evening). Each runs as ONE Media File Operation in three phases
// inside one write hold — Audit Catalog, Verify Catalog, then the import —
// so there is nothing to sequence by hand. The dry run starts straight
// away (the MFO window comes forward via `startedByUser`); the real import
// is ENABLED once a dry run has passed on THIS BUILD (ImportDryRunMarker,
// beside the catalog) and confirms with a sheet that shows the last dry
// run's line and says the real run repeats audit + verify + gate +
// comparator, the JSON catalog stays as it is, nothing is deleted. Both
// are disabled in read-only (viewer) mode.

import SwiftUI
import VideoScanCore

struct ImportToSQLiteMenuItems: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    @ObservedObject var marker: ImportDryRunMarker
    let isReadOnly: Bool

    private var commitEnabled: Bool {
        ImportDryRunMarker.enablesCommit(marker.lastPassed, build: ImportBuildIdentity.current)
    }

    var body: some View {
        Button("Import to SQLite (Dry Run)…") {
            _ = center.startedByUser { $0.startImportToSQLite(model: model, mode: .dryRun) }
        }
        .disabled(isReadOnly)
        .help("Audit Catalog, then Verify Catalog, then the whole import — the gate, every row, the sidecars, the comparator — rolled back at the end. Catalog saves wait until it finishes. Nothing is written beside the catalog but the audit's stamps and the two reports; the row shows the reconciliation line the real import would commit.")
        .accessibilityIdentifier("catalog.menu.importToSQLiteDryRun")

        Button("Import to SQLite…") {
            guard let passed = marker.lastPassed else { return }
            model.importToSQLiteConfirm = ImportToSQLiteConfirmRequest(reconciliationLine: passed.reconciliationLine,
                                                                       catalogGeneration: passed.catalogGeneration,
                                                                       passedAt: passed.passedAt)
        }
        .disabled(isReadOnly || !commitEnabled)
        .help(commitEnabled
              ? "Audit, verify and import the catalog into catalog.sqlite beside it, in one run. The JSON catalog stays as it is; nothing is deleted. A confirm sheet shows the last dry run's line first."
              : "Run Import to SQLite (Dry Run)… first; the real import is offered once a dry run has passed with this build of VideoScan.")
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
            Text("The last dry run (\(request.passedAt.formatted(date: .abbreviated, time: .shortened)), catalog generation \(request.catalogGeneration)) passed with this reconciliation line:")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Text(request.reconciliationLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Label("The real import repeats everything in one run: Audit Catalog, Verify Catalog, the gate and the comparator — then commits. Its line may differ from the dry run's if the catalog changed since.", systemImage: "checkmark.shield")
                Label("Catalog saves wait until it finishes. The JSON catalog stays as it is; nothing is deleted.", systemImage: "lock.shield")
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
