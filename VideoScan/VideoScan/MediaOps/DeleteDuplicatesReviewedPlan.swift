// DeleteDuplicatesReviewedPlan.swift
// R2 (design triage_delete_streamline_2026_10_09 §9 R2, codex F2): Delete
// Duplicates runs EXACTLY the plan Rick reviewed.
//
//   "For content with several verified copies, keep one proven copy and
//    move the extras I selected to the Trash, exactly as I reviewed them."
//
// Before this, a fresh job re-planned from the catalog
// (`prepareDuplicateDeletion(onVolume:)`), so what ran could differ from
// what the Duplicates view showed. Now:
//
//   1. FREEZE (`reviewedDuplicateBatch`): every copy Rick ticked — record
//      id, the path he saw, the keeper he saw — becomes exactly ONE plan
//      entry. Nothing is added. A pick that no longer stands is entered
//      already HELD with the reason (one outcome per requested copy, R6).
//   2. ONE KEEPER PER GROUP, NEVER A TARGET (`DeleteDuplicatesReview
//      .holds`): two different keepers chosen for one group → that group is
//      held; a copy that is a keeper (by id, by canonical spelling — case,
//      firmlink, "..", trailing "/" — or by device + inode: a hard link, a
//      symlink) → held. Asked at the freeze AND again when each volume's
//      job starts (stat only).
//   3. PARTITION (`DeleteDuplicatesReview.partition`): one plan per volume,
//      in the order first met; the batch runs them one after the other
//      (`DeleteDuplicatesBatchRun`). Each plan's job asks, at each row's
//      turn, whether the row still stands (`authorizeDuplicateDeletion`):
//      any changed fact holds the row — never widens it.
//
// (For Rick: `struct` values are copied like C++ PODs; `enum` with only
// static functions ≈ a namespace of free functions.)

import Foundation
import VideoScanCore

/// One copy Rick ticked in the review, as he saw it.
struct ReviewedDuplicatePick: Sendable, Equatable, Hashable {
    /// The catalog record of the copy to move to the Trash.
    let recordID: UUID
    /// Its path as the review showed it — a record now pointing elsewhere
    /// is not the copy that was reviewed.
    let path: String
    /// The keeper the review showed for its group.
    let keeperID: UUID
}

/// A reviewed plan over one or more volumes: one `DeleteDuplicatesPlan`
/// per volume, run in order.
struct DeleteDuplicatesBatch: Sendable, Equatable {
    var plans: [DeleteDuplicatesPlan]
    /// Every copy that was requested (each is an entry of exactly one plan).
    var requested: Int { plans.reduce(0) { $0 + $1.entries.count } }
}

/// The pure half: holds and the per-volume partition. Table-testable.
enum DeleteDuplicatesReview {

    static let keeperOfAGroupNote = "it is a keeper — a keeper is never moved to the Trash"
    static let twoKeepersNote = "two different keepers were chosen for this group — review it again"
    static let notOnVolumeNote = "not on the drive this part of the plan cleans"
    static func keeperAliasNote(_ how: String) -> String {
        "it is a keeper under another name (\(how)) — a keeper is never moved to the Trash"
    }

    /// One key per spelling of a path: the canonical form (firmlink, "."
    /// and "..", a trailing "/"), ASCII case folded — APFS/HFS+ volumes are
    /// case-insensitive, and folding can only hold MORE. The shared helper
    /// behind the Excess lane's alias check (`excessSurvivorAlias`).
    nonisolated static func pathKey(_ path: String) -> String {
        ArchiveVolumeProtection.canonical(path).lowercased()
    }

    /// Why each entry must be HELD before anything runs (entry id → note):
    /// a keeper chosen as a target, under any name; or a group with two
    /// different keepers. `stamps` = paths stat'ed now (absent = not
    /// reachable; such a pair is left to the run's own gate). O(entries).
    nonisolated static func holds(_ entries: [DeleteDuplicatesPlan.Entry],
                                  stamps: [String: FileIdentityStamp]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        // One keeper per group, across every volume of the batch.
        var keeperOfGroup: [UUID: UUID] = [:]
        var conflicted = Set<UUID>()
        for e in entries {
            guard let g = e.groupID else { continue }
            if let k = keeperOfGroup[g], k != e.keeperID { conflicted.insert(g) } else { keeperOfGroup[g] = e.keeperID }
        }
        // Every keeper, by id, by spelling and by inode.
        let keeperIDs = Set(entries.map(\.keeperID))
        let keeperKeys = Set(entries.filter { !$0.keeperPath.isEmpty }.map { pathKey($0.keeperPath) })
        func inode(_ s: FileIdentityStamp) -> String { "\(s.device):\(s.inode)" }
        let keeperInodes = Set(entries.compactMap { stamps[$0.keeperPath].map(inode) })
        for e in entries {
            if let g = e.groupID, conflicted.contains(g) {
                out[e.id] = twoKeepersNote
            } else if keeperIDs.contains(e.id) {
                out[e.id] = keeperOfAGroupNote
            } else if keeperKeys.contains(pathKey(e.path)) {
                out[e.id] = keeperAliasNote("the same file name")
            } else if let s = stamps[e.path], keeperInodes.contains(inode(s)) {
                out[e.id] = keeperAliasNote("the same file on disk — a link")
            }
        }
        return out
    }

    /// One plan per volume, in the order the volumes are first met; each
    /// entry in exactly one plan. `volumeRoot` = the app's own rule
    /// (`VideoScanModel.volumeRoot(for:)`). A volume's plan is cross-volume
    /// when one of its keepers lives on another drive; such an entry is a
    /// working copy (its keeper is the higher-ranked master the run's
    /// eligibility check asks about at the row's turn).
    nonisolated static func partition(_ entries: [DeleteDuplicatesPlan.Entry], catalogLocation: String,
                                      volumeRoot: (String) -> String) -> [DeleteDuplicatesPlan] {
        var order: [String] = []
        var byVolume: [String: [DeleteDuplicatesPlan.Entry]] = [:]
        for var e in entries {
            let volume = volumeRoot(e.path)
            if byVolume[volume] == nil { order.append(volume) }
            e.isWorkingCopy = !e.keeperPath.isEmpty && !PathScope.contains(e.keeperPath, within: volume)
            byVolume[volume, default: []].append(e)
        }
        return order.map { volume in
            let rows = byVolume[volume] ?? []
            var plan = DeleteDuplicatesPlan(volumePath: volume, catalogLocation: catalogLocation,
                                            crossVolumeMode: rows.contains(where: \.isWorkingCopy),
                                            skippedBeforePlan: 0,
                                            summaryLine: "\(rows.count) reviewed cop\(rows.count == 1 ? "y" : "ies")",
                                            entries: rows)
            plan.reviewed = true
            return plan
        }
    }

    /// Settle `holds` on `entries` (status skipped, the note) — before
    /// anything is read; the row stays an entry so it has its outcome.
    nonisolated static func apply(_ holds: [UUID: String], to entries: inout [DeleteDuplicatesPlan.Entry],
                                  at now: Date = Date()) {
        guard !holds.isEmpty else { return }
        for i in entries.indices {
            guard let note = holds[entries[i].id], !entries[i].status.isSettled else { continue }
            entries[i].status = .skipped
            entries[i].note = note
            entries[i].settledAt = now
        }
    }
}

extension VideoScanModel {

    /// FREEZE what Rick reviewed: one entry per distinct pick, the keeper
    /// and the path as he saw them, the keeper's stamp now (a resume
    /// refuses a rewritten keeper). A pick that no longer stands is entered
    /// HELD, with the reason. Then one plan per volume. One O(records) pass
    /// (copy counts) plus O(picks) lookups on the main actor; the stats run
    /// off it. Never in a view body.
    func reviewedDuplicateBatch(_ picks: [ReviewedDuplicatePick]) async -> DeleteDuplicatesBatch {
        var seen = Set<UUID>()
        let unique = picks.filter { seen.insert($0.recordID).inserted }
        var entries: [DeleteDuplicatesPlan.Entry] = []
        var holds: [UUID: String] = [:]
        let groups = Set(unique.compactMap { record(forID: $0.recordID)?.duplicateGroupID })
        let copyCounts = duplicateGroupCopyCounts(groups)
        for pick in unique {
            let rec = record(forID: pick.recordID)
            let keeper = record(forID: pick.keeperID)
            let group = rec?.duplicateGroupID
            entries.append(DeleteDuplicatesPlan.Entry(
                id: pick.recordID, path: pick.path,
                filename: rec?.filename ?? (pick.path as NSString).lastPathComponent,
                sizeBytes: rec?.sizeBytes ?? 0,
                keeperID: pick.keeperID, keeperPath: keeper?.fullPath ?? "", keeperFilename: keeper?.filename ?? "",
                groupID: group, groupCopyCount: group.flatMap { copyCounts[$0] }))
            if let why = reviewedPickChanged(pick, record: rec, keeper: keeper) { holds[pick.recordID] = why }
        }
        let paths = Set(entries.flatMap { [$0.path, $0.keeperPath] }.filter { !$0.isEmpty })
        let stamps = await Self.captureStamps(paths: Array(paths))
        for i in entries.indices { entries[i].keeperStamp = stamps[entries[i].keeperPath] }
        holds.merge(DeleteDuplicatesReview.holds(entries, stamps: stamps)) { first, _ in first }
        DeleteDuplicatesReview.apply(holds, to: &entries)
        for (id, why) in holds { log("  Delete Duplicates (reviewed): held \(entries.first { $0.id == id }?.filename ?? "?") — \(why)") }
        return DeleteDuplicatesBatch(plans: DeleteDuplicatesReview.partition(
            entries, catalogLocation: catalogStore.fileLocation, volumeRoot: { self.volumeRoot(for: $0) }))
    }

    /// Why a pick no longer stands (nil = it does): the copy is gone or is
    /// somewhere else now, or the keeper the review showed is no longer its
    /// group's keeper. The row's turn asks all of this again, live.
    func reviewedPickChanged(_ pick: ReviewedDuplicatePick, record rec: VideoRecord?, keeper: VideoRecord?) -> String? {
        guard let rec, !rec.isPurged, rec.fullPath == pick.path else {
            return "no longer in the catalog at the place you reviewed"
        }
        guard rec.duplicateDisposition == .extraCopy, let group = rec.duplicateGroupID else {
            return "no longer marked as an extra copy since you reviewed it"
        }
        guard let keeper, !keeper.isPurged, keeper.duplicateDisposition == .keep, keeper.duplicateGroupID == group else {
            return "its keeper changed since you reviewed it"
        }
        return nil
    }
}
