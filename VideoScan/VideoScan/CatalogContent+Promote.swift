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

    /// "Prepare with Archive Angel" (Rick 2026-09-11): hand exactly this
    /// selection to the Angel — companions prepared in the buffer, then
    /// the same review sheet as an assessed batch. Enabled for a
    /// pure-active selection with at least one reachable, not-yet-archived
    /// record and a designated Master Archive. Lossless follows the
    /// Assess sheet's remembered choice. O(selection).
    @ViewBuilder
    func prepareWithArchiveAngelMenuItem(activeRecs: [VideoRecord], pureActive: Bool) -> some View {
        let preparable = activeRecs.filter { rec in
            model.pfNotYetArchived(rec) && VolumeReachability.isReachable(path: rec.fullPath)
        }
        let label = activeRecs.count > 1
            ? "Prepare \(preparable.count) with Archive Angel"
            : "Prepare with Archive Angel"
        Button(label) {
            let lossless = UserDefaults.standard.bool(forKey: "archiveAngel.makeLossless")
            fileOpsCenter.startArchiveAngel(recordIDs: preparable.map(\.id), makeLossless: lossless, model: model)
        }
        .disabled(!pureActive || preparable.isEmpty || model.masterArchive == nil || model.isReadOnly)
        .help(model.masterArchive == nil
              ? "Designate a Master Archive first (Archive tab)."
              : (preparable.isEmpty
                 ? "Nothing here needs preparing (already archived, or the volume is offline)."
                 : "Archive Angel prepares the selected file(s) — verifies, makes companions in the buffer — and opens them for review under the Archive tab. Nothing is promoted until you approve."))
        .accessibilityIdentifier("catalog.row.prepareWithArchiveAngel")
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
        // Content-level (Rick 2026-08-25): an identical original on another
        // volume shows the same "Archived on … to …" line as the promote source.
        return model.archivedCopy(of: rec)
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
    ///
    /// Rick 2026-09-11: 18 `.vs.archive/.vs.edit/.vs.preserve` versions
    /// written straight into the archive folders by older tooling carried
    /// no promotion record, so they sat in the to-do view — and Promote
    /// then refused them ("already lives inside the archive tree"). One
    /// definition of archived now: a promoted copy, a source with a master
    /// copy, OR anything living inside the Master Archive root, the same
    /// test Promote, Duplicates and Verify already apply.
    ///
    /// And a VERSION of something archived is not to-do either (Rick
    /// 2026-09-11: "or copied to Projects"): a balanced-audio, trimmed or
    /// transcoded copy whose original — up the derivedFrom chain — is in
    /// the archive. Repairs of damaged media (external repair, rebuilt
    /// audio) stay visible: a fix is a candidate in its own right.
    func pfNotYetArchived(_ rec: VideoRecord) -> Bool {
        !isArchiveCopy(rec)
            && !isInsideMasterArchive(path: rec.fullPath)
            && archivedCopy(of: rec) == nil
            && !isVersionOfArchived(rec)
    }

    /// Derivation kinds that FIX damaged media rather than re-express
    /// good media; these never inherit "archived" from their source.
    static let repairDerivationKinds: Set<String> = [
        ExternalRepairAdoption.derivationKind, RebuildAudioFix.derivationKind,
    ]

    /// True when `rec` derives (balanceAudio, trim, an older transcode with
    /// no kind stamp…) from a record that is archived, following at most
    /// four `derivedFrom` hops. Repairs are exempt. O(hops) id lookups.
    func isVersionOfArchived(_ rec: VideoRecord, maxHops: Int = 4) -> Bool {
        if let kind = rec.derivationKind, Self.repairDerivationKinds.contains(kind) { return false }
        var cursor = rec
        var seen: Set<UUID> = [rec.id]
        for _ in 0..<maxHops {
            guard let parentID = cursor.derivedFrom, let parent = record(forID: parentID),
                  seen.insert(parent.id).inserted else { return false }
            if isArchiveCopy(parent) || isInsideMasterArchive(path: parent.fullPath)
                || archivedCopy(of: parent) != nil {
                return true
            }
            if let kind = parent.derivationKind, Self.repairDerivationKinds.contains(kind) { return false }
            cursor = parent
        }
        return false
    }

    /// "Has Master Copy": a source that has been promoted.
    func pfHasMasterCopy(_ rec: VideoRecord) -> Bool {
        archivedCopy(of: rec) != nil
    }
}
