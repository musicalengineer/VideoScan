// ArchiveAngelRowActions.swift
// "Show in Catalog" / "Show in Finder" for one Archive Angel row — Rick
// 2026-09-10: "I can't click show in catalog or show in finder which would
// help me decide if 35 seconds is worth it." Shared by the chevron row
// under the Archive tab and the review sheet so the two surfaces agree.
//
// Show in Catalog uses the same focus plumbing as the Archive tab's
// context menu (focus set + pending selection + tab index). A sheet must
// close itself first — the catalog is behind it — so the caller passes
// `beforeNavigate`.

import AppKit
import SwiftUI

struct ArchiveAngelRowActions: View {
    @EnvironmentObject var model: VideoScanModel

    /// Catalog record id of the original.
    let recordID: UUID
    let filename: String
    let sourcePath: String
    /// Runs before the tab switch (a sheet dismisses itself here).
    var beforeNavigate: () -> Void = {}

    init(recordID: UUID, filename: String, sourcePath: String, beforeNavigate: @escaping () -> Void = {}) {
        self.recordID = recordID; self.filename = filename; self.sourcePath = sourcePath
        self.beforeNavigate = beforeNavigate
    }

    init(entry: ArchiveAngelPlan.Entry, beforeNavigate: @escaping () -> Void = {}) {
        self.init(recordID: entry.id, filename: entry.filename, sourcePath: entry.sourcePath,
                  beforeNavigate: beforeNavigate)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                showInCatalog()
            } label: {
                Image(systemName: "film.stack")
            }
            .help("Show in Catalog — the row, its preview and inspector")
            .accessibilityIdentifier("archiveAngel.row.showInCatalog")

            Button {
                showInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Show in Finder")
            .accessibilityIdentifier("archiveAngel.row.showInFinder")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func showInCatalog() {
        guard model.canNavigateToRecord(id: recordID) else {
            model.log("Archive Angel: \(filename) is no longer in the catalog — it may have been removed or replaced by a re-scan.")
            return
        }
        beforeNavigate()
        Self.navigate(model: model, to: recordID)
    }

    private func showInFinder() {
        if !NSWorkspace.shared.selectFile(sourcePath, inFileViewerRootedAtPath: "") {
            model.log("Archive Angel: Finder could not show \(sourcePath) — is the volume mounted?")
        }
    }

    /// Same steps as ArchiveView+Table.showInCatalog, without the view.
    @MainActor
    static func navigate(model: VideoScanModel, to id: UUID) {
        model.focusedMediaIDs = model.focusSet(for: id)
        model.pendingCatalogSelection = id
        model.pendingCatalogPairMode = false
        UserDefaults.standard.set(1, forKey: "selectedTab")
        MainWindowHelper.shared.openMainWindow()
    }
}
