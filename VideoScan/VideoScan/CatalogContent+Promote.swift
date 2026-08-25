// CatalogContent+Promote.swift
// Catalog-table pieces of Master Archive / Promote to Archive
// (docs/archive_promotion_workflow.md §4): the row context-menu item, the
// inspector's promotion links, and the two Show-menu filters' predicates.
// Split out so CatalogContent+Table.swift's already-huge menu builder
// stays inside Xcode's type-check budget.

import SwiftUI

extension CatalogContent {

    /// "Promote to Archive" for the active selection. Enabled for any
    /// pure-active selection with at least one online, not-yet-promoted,
    /// non-archive-copy record; the model's `requestPromote` does the
    /// real routing (no master → alert with fix-it; else the sheet whose
    /// plan lists skips/warnings). O(selection) — never O(records).
    @ViewBuilder
    func promoteToArchiveMenuItem(activeRecs: [VideoRecord], pureActive: Bool) -> some View {
        let promotable = activeRecs.contains { rec in
            !model.isArchiveCopy(rec)
                && model.masterArchiveCopy(of: rec) == nil
                && VolumeReachability.isReachable(path: rec.fullPath)
        }
        let label = activeRecs.count > 1
            ? "Promote \(activeRecs.count) to Archive"
            : "Promote to Archive"
        Button(label) {
            // "Looks moved" (Update Catalog): a source that vanished while
            // its volume is mounted gets the relink offer; the promote job
            // reports the missing file on its own.
            for r in activeRecs { model.noteMissingFileForUserAction(r) }
            model.requestPromote(recordIDs: activeRecs.map(\.id))
        }
        .disabled(!pureActive || !promotable || model.isReadOnly)
        .help(promotable
              ? "Copy the selected file(s) into the Master Archive tree — verified byte-for-byte, logged in the manifest, linked in the catalog. The originals are never moved or changed."
              : "Nothing here can be promoted right now (already in the archive, or the volume is offline).")
        .accessibilityIdentifier("catalog.row.promoteToArchive")
    }

    /// "Remove from Catalog (keep files)" — the app forgets these rows;
    /// nothing on disk changes. Distinct from every Delete verb on purpose.
    @ViewBuilder
    func removeFromCatalogMenuItem(activeRecs: [VideoRecord], pureActive: Bool) -> some View {
        let label = activeRecs.count > 1
            ? "Remove \(activeRecs.count) from Catalog (keep files)"
            : "Remove from Catalog (keep files)"
        Button(label) {
            model.removeFromCatalog(recordIDs: activeRecs.map(\.id))
        }
        .disabled(!pureActive || activeRecs.isEmpty || model.isReadOnly)
        .help("Take these entries out of the working catalog. Files are not touched; find them again under Show ▸ Set-aside files and put them back any time.")
        .accessibilityIdentifier("catalog.row.removeFromCatalog")
    }

    /// Inspector: the archive copy promoted from the selected record.
    /// O(1) memoized reverse-index read (ArchivePromotionIndex).
    var masterCopyOfSelected: VideoRecord? {
        guard let rec = selectedRecord else { return nil }
        return model.masterArchiveCopy(of: rec)
    }

    /// Inspector: the source the selected archive copy was promoted from.
    /// O(1) id-index read.
    var promotionSourceOfSelected: VideoRecord? {
        guard let rec = selectedRecord else { return nil }
        return model.promotionSource(of: rec)
    }
}

// MARK: - Show-menu predicates

extension VideoScanModel {
    /// "Not Yet Archived": a live source with no master copy — and not
    /// itself an archive copy. Used by computeFiltered (event-driven,
    /// not in a view body); the memoized index makes it O(1) per record.
    func pfNotYetArchived(_ rec: VideoRecord) -> Bool {
        !isArchiveCopy(rec) && archivedCopy(of: rec) == nil
    }

    /// "Has Master Copy": a source that has been promoted.
    func pfHasMasterCopy(_ rec: VideoRecord) -> Bool {
        archivedCopy(of: rec) != nil
    }
}
