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

    /// The plan with this model's real predicates (the ONE bulk-delete
    /// rule — archive tree AND the whole archive volume, 2026-09-22 —
    /// and volume reachability, the 5 s cache, one stat per volume at
    /// most). The archive-volume snapshot is taken once for the plan.
    /// `isOffline` is injectable so tests never depend on which drives
    /// the host has mounted (CLAUDE.md isolation dimension); production
    /// callers take the default.
    func catalogTrashPlan(for records: [VideoRecord],
                          isOffline: (VideoRecord) -> Bool = VideoScanModel.isRecordOnOfflineVolume) -> CatalogTrashPlan {
        let archiveVolume = archiveVolumeProtection()
        return Self.catalogTrashPlan(
            for: records,
            isMasterArchive: { self.bulkDeleteRefusal($0, volume: archiveVolume) != nil },
            isOffline: isOffline)
    }

    /// The production offline predicate: an external /Volumes path whose
    /// drive is not mounted (VolumeReachability's 5 s cache).
    static func isRecordOnOfflineVolume(_ rec: VideoRecord) -> Bool {
        isExternalVolumePath(rec.fullPath) && !VolumeReachability.isReachable(path: rec.fullPath)
    }

    /// ⌘⌫: plan, say what was refused, then hand the rest to the existing
    /// Trash routine. Returns ONE outcome per selected row (design R6): the
    /// plan's refusals as held / offline WITH their reasons, merged with
    /// the routine's outcomes, in selection order — so the alert can list
    /// every row that stayed, and why. An empty or fully-refused selection
    /// never reaches the disk.
    @discardableResult
    func trashSelectedRecords(_ requested: [VideoRecord]) async -> JunkDeletionResult {
        guard !requested.isEmpty else { return .empty }
        guard !isReadOnly else {
            log("Move to Trash refused — read-only viewer mode.")
            let why = "this Mac is a read-only viewer of the catalog"
            return JunkDeletionResult(items: requested.map { .init(record: $0, outcome: .held(why)) })
        }
        let plan = catalogTrashPlan(for: requested)
        logMasterArchiveRefusals(plan, requested: requested)
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
        let byID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = plan.toTrash.compactMap { byID[$0] }
        // The one existing Trash routine — archive + offline gates,
        // purgedAt/.trashed, publish, and the copyTrashed ledger lines.
        let routine = targets.isEmpty ? .empty : await deleteConfirmedJunk(targets, mode: .toTrash)
        let result = mergedCatalogTrashResult(requested, plan: plan, routine: routine)
        // "I don't wanna see it again" (Rick 2026-09-20): the content of
        // every row that actually left the disk goes on the ignore list
        // Tidy and Remove from Catalog use, so a rescan — or another copy
        // of the same clip on another drive — never catalogs it again.
        // Put Back in Tidy → Ignored content reverses it.
        let gone = targets.filter { $0.isPurged }
        var remembered = 0
        for rec in gone where noteIgnoredContent(rec, reason: "trashed-by-user") { remembered += 1 }
        if remembered > 0 {
            scheduleIgnoredContentSave()
            log("Move to Trash: remembered \(remembered) file(s) as ignored content — a rescan will not catalog them again (Tidy → Ignored content to put back).")
        }
        return result
    }

    /// One outcome per selected row, in selection order: the routine's
    /// outcome for a row it was handed, else the plan's refusal as a named
    /// hold (or "offline" for a drive that isn't connected).
    private func mergedCatalogTrashResult(_ requested: [VideoRecord], plan: CatalogTrashPlan,
                                          routine: JunkDeletionResult) -> JunkDeletionResult {
        let refusals = Dictionary(plan.refused.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        let handled = Dictionary(routine.items.map { (ObjectIdentifier($0.record), $0.outcome) },
                                 uniquingKeysWith: { first, _ in first })
        let archiveVolume = refusals.values.contains(.masterArchive) ? archiveVolumeProtection() : nil
        let items: [JunkDeletionResult.Item] = requested.map { rec in
            if let outcome = handled[ObjectIdentifier(rec)] { return .init(record: rec, outcome: outcome) }
            let reason = refusals[rec.id] ?? .notActive
            return .init(record: rec, outcome: catalogTrashRefusalOutcome(reason, rec, archiveVolume: archiveVolume))
        }
        return JunkDeletionResult(items: items)
    }

    /// A plan refusal as the row's outcome, in the person's words.
    private func catalogTrashRefusalOutcome(_ reason: CatalogTrashPlan.Refusal, _ rec: VideoRecord,
                                            archiveVolume: ArchiveVolumeProtection?) -> JunkFileOutcome {
        switch reason {
        case .offlineVolume:
            return .offline
        case .pairMember:
            return .held("is half of a recovered audio/video pair, which Combine still needs")
        case .notActive:
            return .held("was already removed, set aside or replaced by a repair — nothing more to do")
        case .masterArchive:
            let note = bulkDeleteRefusal(rec, volume: archiveVolume)
                .map { Self.bulkDeleteRefusalNote($0, volume: archiveVolume?.label ?? "the archive volume") }
            return .held(note ?? "lives in the Master Archive, which only archive actions may change")
        }
    }

    /// The SAME sentences excludingMasterArchiveFiles writes, one per kind
    /// (tree / rest of the archive volume / unprovable), for the rows the
    /// ⌘⌫ plan refused as Master Archive files.
    private func logMasterArchiveRefusals(_ plan: CatalogTrashPlan, requested: [VideoRecord]) {
        guard plan.refusedCount(.masterArchive) > 0 else { return }
        let archiveVolume = archiveVolumeProtection()
        let label = archiveVolume?.label ?? "the archive volume"
        let byID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tree = 0, onVolume = 0, unprovable = 0
        var readOnly: [String: Int] = [:]
        for r in plan.refused where r.reason == .masterArchive {
            switch byID[r.id].flatMap({ bulkDeleteRefusal($0, volume: archiveVolume) }) {
            case .archiveVolume?: onVolume += 1
            case .archiveVolumeUnprovable?: unprovable += 1
            case .readOnlyVolume(let name)?, .readOnlyVolumeDifferentDrive(let name)?: readOnly[name, default: 0] += 1
            default: tree += 1
            }
        }
        for (name, count) in readOnly.sorted(by: { $0.key < $1.key }) {
            log(Self.readOnlyVolumeRefusalLine(verb: "Move to Trash", count: count, volume: name))
        }
        if tree > 0 { log(Self.masterArchiveRefusalLine(verb: "Move to Trash", count: tree)) }
        if onVolume > 0 { log(Self.masterArchiveVolumeRefusalLine(verb: "Move to Trash", count: onVolume, volume: label)) }
        if unprovable > 0 { log(Self.masterArchiveUnprovableRefusalLine(verb: "Move to Trash", count: unprovable, volume: label)) }
    }
}
