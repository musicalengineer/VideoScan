// ArchiveAngelMenuItems.swift
// The Archive Angel's items in the CATALOG's row context menu — public
// surface (the catalog places this view; it never names Angel internals).
// Moved from CatalogContent+Promote.swift in consolidation S2, unchanged:
// same label, enablement, help text and accessibility id.
//
// S4 (Rick 2026-09-22): the items sit under one "Archive Angel" submenu —
// Prepare with Archive Angel (unchanged) and Show Copies… (read-only: which
// of this recording's copies is the original), which replaces the retired
// Promote Helper's catalog item.
//
// The model and the center are passed in, not read from the environment:
// context-menu content is built from the table's captured state, exactly as
// the other menu builders in CatalogContent do.

import SwiftUI

struct ArchiveAngelMenuItems: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    let activeRecs: [VideoRecord]
    let pureActive: Bool
    /// Opens the catalog's Transcode sheet (the one Transcode path) — for
    /// the already-archived follow-ups below. nil = those items hidden.
    var onTranscode: ((VideoRecord, TranscodePreset) -> Void)? = nil

    /// "Prepare with Archive Angel" (Rick 2026-09-11): hand exactly this
    /// selection to the Angel — companions prepared in the buffer, then
    /// the same review sheet as an assessed batch. Enabled for a
    /// pure-active selection with at least one reachable, not-yet-archived
    /// record and a designated Master Archive. Lossless follows the
    /// Assess sheet's remembered choice. O(selection).
    var body: some View {
        Menu("Archive Angel") {
            prepareItem
            showCopiesItem
            alreadyArchivedItems
        }
        .accessibilityIdentifier("catalog.row.archiveAngelMenu")
    }

    @ViewBuilder
    private var prepareItem: some View {
        let preparable = activeRecs.filter { rec in
            model.pfNotYetArchived(rec) && VolumeReachability.isReachable(path: rec.fullPath)
        }
        let label = activeRecs.count > 1
            ? "Prepare \(preparable.count) with Archive Angel"
            : "Prepare with Archive Angel"
        Button(label) {
            model.archiveAngel.prepare(recordIDs: preparable.map(\.id), using: center)
        }
        .disabled(!pureActive || preparable.isEmpty || model.masterArchive == nil || model.isReadOnly)
        .help(model.masterArchive == nil
              ? "Designate a Master Archive first (Archive tab)."
              : (preparable.isEmpty
                 ? "Nothing here needs preparing (already archived, or the volume is offline)."
                 : "Archive Angel prepares the selected file(s) — verifies, makes companions in the buffer — and opens them for review under the Archive tab. Nothing is promoted until you approve."))
        .accessibilityIdentifier("catalog.row.prepareWithArchiveAngel")
    }

    /// One file that is ALREADY in the Master Archive (Rick 2026-10-05:
    /// "AA should look at it and say 'Already in archive, do you want to
    /// create an access copy … other copies for editing, and mark it to be
    /// present in the People tab under XXX'"). Says so plainly instead of a
    /// greyed-out Prepare with a tooltip, and offers the follow-ups through
    /// the existing paths: the catalog's Transcode sheet (which files the
    /// output beside the original in the archive's year folder — Rick
    /// 8/25) and Show in People tab. Nothing new writes data.
    @ViewBuilder
    private var alreadyArchivedItems: some View {
        if activeRecs.count == 1, let rec = activeRecs.first, !model.pfNotYetArchived(rec) {
            let reachable = VolumeReachability.isReachable(path: rec.fullPath)
            Divider()
            Text("Already in the Master Archive")
            if let onTranscode {
                Button("Make an Access Copy (HEVC, for everyday viewing)…") { onTranscode(rec, .archival) }
                    .disabled(!reachable)
                    .help(reachable ? "A compact copy that plays anywhere, filed beside the original in the archive's year folder. The original is untouched."
                                    : "The drive holding it is not connected.")
                    .accessibilityIdentifier("catalog.row.angel.accessCopy")
                Button("Make an Editing Copy (ProRes)…") { onTranscode(rec, .editingLT) }
                    .disabled(!reachable)
                    .accessibilityIdentifier("catalog.row.angel.editingCopy")
            }
            ShowInPeopleTabMenu(records: [rec])
        }
    }

    /// "Show Copies…" — one recording at a time: its whole copy family
    /// (duplicate group ∪ lineage ∪ archive links ∪ same content
    /// signature), read-only. Offline copies are listed too.
    private var showCopiesItem: some View {
        Button("Show Copies…") {
            guard let seed = activeRecs.first else { return }
            model.archiveAngel.showCopies(of: seed.id)
        }
        .disabled(!pureActive || activeRecs.count != 1)
        .help(activeRecs.count == 1
              ? "Which of this recording's copies is the original? Lists every copy the catalog knows, where it lives and which one to keep. Read-only."
              : "Show Copies works on one recording at a time — select a single row.")
        .accessibilityIdentifier("catalog.row.showCopies")
    }
}
