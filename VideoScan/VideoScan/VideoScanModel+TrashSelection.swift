// VideoScanModel+TrashSelection.swift
// ⌘⌫ in the Catalog table — the Finder gesture — moves the highlighted
// rows to the macOS Trash (Rick, 2026-09-13).
//
// This is a DELETE path, so it adds NO file-deletion code of its own. It
// is a pure PLAN in front of the ONE existing "move to Trash" routine,
// `deleteConfirmedJunk(_:mode: .toTrash)` (VideoScanModel+JunkDelete.swift)
// — the same call the catalog row's "Delete File → Move to Trash" menu
// item makes. That routine already: leaves Master Archive files alone
// (excludingMasterArchiveFiles), skips files whose drive is offline,
// stamps `purgedAt` + `lifecycleStage = .trashed`, publishes the change
// (#160), and writes one `copyTrashed` Media Ledger line per file that
// actually left the disk, by: rick. Rows it trashes are recoverable from
// Finder's Trash and, in the catalog, via Show Removed → Restore.
//
// The plan adds the gate the row menu never had: a member of a recovered
// audio/video pair (Combine's raw material) is refused, the way Tidy
// refuses it. Every refusal is a console line, never a silent skip. The
// existing routine re-checks the archive and offline gates itself, so
// they are enforced twice (plan time + apply time — the Tidy shape).
//
// Memory: O(selection). Nothing here walks `records`.

import Foundation

extension VideoScanModel {

    /// What ⌘⌫ would do with a selection: the rows to hand to the Trash
    /// routine, in selection order, and every row it refuses, with why.
    struct CatalogTrashPlan: Equatable {
        enum Refusal: String, Equatable, CaseIterable {
            /// Lives in the Master Archive — only archive actions may change it.
            case masterArchive
            /// Half of a recovered audio/video pair (or a Combine output).
            case pairMember
            /// Its drive isn't connected right now.
            case offlineVolume
            /// Already removed, set aside, or replaced by a repair — the
            /// row menu never offers Delete for these either.
            case notActive
        }
        struct Refused: Equatable {
            let id: UUID
            let filename: String
            let reason: Refusal
        }
        var toTrash: [UUID] = []
        var refused: [Refused] = []

        func refusedCount(_ reason: Refusal) -> Int {
            refused.reduce(0) { $0 + ($1.reason == reason ? 1 : 0) }
        }
    }

    /// Pure planner. `isMasterArchive` / `isOffline` are injected so the
    /// plan is testable without an archive root or a mounted volume; the
    /// pair gate is the same predicate Tidy uses.
    nonisolated static func catalogTrashPlan(
        for records: [VideoRecord],
        isMasterArchive: (VideoRecord) -> Bool,
        isOffline: (VideoRecord) -> Bool
    ) -> CatalogTrashPlan {
        var plan = CatalogTrashPlan()
        for rec in records {
            let refusal: CatalogTrashPlan.Refusal?
            if rec.isPurged || rec.isSetAside || rec.isSuperseded {
                refusal = .notActive
            } else if isMasterArchive(rec) {
                refusal = .masterArchive
            } else if CatalogScopePolicy.isPairProtected(rec) {
                refusal = .pairMember
            } else if isOffline(rec) {
                refusal = .offlineVolume
            } else {
                refusal = nil
            }
            if let refusal {
                plan.refused.append(.init(id: rec.id, filename: rec.filename, reason: refusal))
            } else {
                plan.toTrash.append(rec.id)
            }
        }
        return plan
    }

    /// The plan with this model's real predicates (archive root, volume
    /// reachability — the 5 s cache, one stat per volume at most).
    func catalogTrashPlan(for records: [VideoRecord]) -> CatalogTrashPlan {
        Self.catalogTrashPlan(
            for: records,
            isMasterArchive: { self.isArchiveCopy($0) || self.isInsideMasterArchive(path: $0.fullPath) },
            isOffline: { Self.isExternalVolumePath($0.fullPath) && !VolumeReachability.isReachable(path: $0.fullPath) })
    }

    /// ⌘⌫: plan, say what was refused, then hand the rest to the existing
    /// Trash routine. Returns its result (the table reports it the same
    /// way the row menu does). An empty or fully-refused selection never
    /// reaches the disk.
    @discardableResult
    func trashSelectedRecords(_ requested: [VideoRecord]) async -> JunkDeletionResult {
        let nothing = JunkDeletionResult(attempted: 0, succeeded: 0, alreadyMissing: 0, skippedOffline: 0, failed: [])
        guard !requested.isEmpty else { return nothing }
        guard !isReadOnly else {
            log("Move to Trash refused — read-only viewer mode.")
            return nothing
        }
        let plan = catalogTrashPlan(for: requested)
        let archived = plan.refusedCount(.masterArchive)
        if archived > 0 {
            // The SAME sentence excludingMasterArchiveFiles writes.
            log(Self.masterArchiveRefusalLine(verb: "Move to Trash", count: archived))
        }
        let paired = plan.refusedCount(.pairMember)
        if paired > 0 {
            log("Move to Trash: left \(paired) file(s) alone — each is half of a recovered audio/video pair, which Combine still needs.")
        }
        let offline = plan.refusedCount(.offlineVolume)
        if offline > 0 {
            log("Move to Trash: skipped \(offline) file(s) — their drive isn't connected right now. Plug it in and try again.")
        }
        let inert = plan.refusedCount(.notActive)
        if inert > 0 {
            log("Move to Trash: \(inert) file(s) were already removed or set aside — nothing more to do for them.")
        }
        guard !plan.toTrash.isEmpty else { return nothing }
        let byID = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, $0) })
        let targets = plan.toTrash.compactMap { byID[$0] }
        // The one existing Trash routine — archive + offline gates,
        // purgedAt/.trashed, publish, and the copyTrashed ledger lines.
        return await deleteConfirmedJunk(targets, mode: .toTrash)
    }
}
