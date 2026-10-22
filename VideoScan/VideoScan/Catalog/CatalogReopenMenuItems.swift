// CatalogReopenMenuItems.swift
// Catalog ▸ "Reopen SQLite Catalog" and "Adopt This SQLite Catalog…", and the
// window-level host for the Adopt sheet. Moved here unchanged from
// CatalogSwitchToSQLite.swift when "Switch Catalog to SQLite…" was retired
// (2026-10-20, "JSON gone": the cutover is done — catalog.sqlite is the only
// catalog). Reopen stays as the recovery path while saving to catalog.sqlite
// has stopped, until a red "Can't Save" status offers it instead.

import SwiftUI
import VideoScanCore

// MARK: - Menu items

struct CatalogReopenMenuItems: View {
    @ObservedObject var cutover: CatalogCutoverState

    var body: some View {
        Button("Reopen SQLite Catalog") {
            Task { await cutover.reopen() }
        }
        .disabled(!cutover.canReopen)
        .help(cutover.blockedReason.map { cutover.canReopen ? "Saving to catalog.sqlite stopped: \($0). Reopen to try again."
                                                            : "Saving to catalog.sqlite stopped: \($0)." } ?? "Saving to catalog.sqlite is working.")
        .accessibilityIdentifier("catalog.menu.reopenSQLite")

        CatalogAdoptMenuItem(cutover: cutover)
    }
}

// MARK: - The sheet host

/// The Adopt sheet, and the job starter for held rows' full hashes. A view
/// modifier on the main window because it needs the Media File Operations
/// center from the environment. (For Rick: a `ViewModifier` ≈ a decorator
/// that wraps a view and adds behaviour — here, a sheet and an on-appear hook.)
struct CatalogCutoverSheetHost: ViewModifier {
    let model: VideoScanModel
    @ObservedObject var cutover: CatalogCutoverState
    @Environment(\.mediaFileOperationsCenterReference) private var center

    func body(content: Content) -> some View {
        content
            .sheet(item: $cutover.adoptRequest) { request in
                CatalogAdoptSheet(cutover: cutover, request: request)
            }
            .onAppear {
                // B2.1 gap 1: held rows get Fill In Full Hashes, scoped to them.
                guard let center else { return }
                cutover.attachDigestJobs { [weak model, weak center] ids in
                    guard let model, let center else { return }
                    center.startFullHashBackfill(model: model, scopedTo: ids)
                }
            }
    }
}
