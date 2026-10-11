// VideoScanModel+PromoteDoor.swift
// The ONE door every "Promote" button goes through (tab charters,
// 2026-10-11: an action may have a button in several tabs, but exactly one
// engine). Today's buttons:
//   * Catalog row menu "Promote to Archive"   (CatalogContent+Promote.swift)
//   * Triage toolbar "Archive"                (TriageView.promoteSelectedToArchive)
//   * Under Construction "Promote" / row item (promoteWorkbenchToArchive)
// The engine behind it: `requestPromote(recordIDs:)` → the confirmation
// sheet (PromoteToArchiveSheet, or the "designate a master archive" alert)
// → PromoteToArchiveJob, which copies, verifies and registers the archive
// copy (`registerPromotedCopy`).
//
// Tab-charter audit T2: Triage's Archive and Under Construction's Promote
// used to set `lifecycleStage = .archived` and copy nothing — the file left
// Triage, its dates froze, and the Archive tab never saw it.
// PromoteLabelOnlySensorTests pins that no such label-only writer returns.

import Foundation

extension VideoScanModel {

    /// "Looks moved" first — a source that vanished while its drive is
    /// mounted gets the relink offer; the job reports the missing file on
    /// its own — then the Promote engine. Nothing here stamps a stage: a
    /// file is archived only when a verified copy is in the Master Archive.
    func requestPromote(records recs: [VideoRecord]) {
        for r in recs { noteMissingFileForUserAction(r) }
        requestPromote(recordIDs: recs.map(\.id))
    }
}
