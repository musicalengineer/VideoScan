// VideoScanModel+Cleanup.swift
// Triage ▸ Cleanup v1 — the catalog half of the PLAN
// (docs/design/cleanup_kiss_2026_10_12.md).
//
// Two steps, the Triage-snapshot shape (swift_playbook §2):
//   1. `cleanupInputs()` — ONE O(records) pass on the main actor that copies
//      what the rules read into Sendable values (CleanupRow), plus the bulk
//      gate and the keeper policy as values. Never called from a view body:
//      the page's store calls it from a button / onAppear handler.
//   2. `CleanupInputs.plan()` — off the main actor: the gate's verdicts, the
//      disk facts (one lstat / realpath / open per row that could matter)
//      and the pure planner.
//
// Memory: the inputs are ~200 bytes per active record (~20 MB at 100k).

import Foundation
import VideoScanCore

/// Everything the plan reads, captured on the main actor as values.
struct CleanupInputs: Sendable {
    var rows: [CleanupRow]
    /// What the bulk gate reads of each row, index-aligned with `rows`.
    let subjects: [VideoScanModel.BulkDeleteSubject]
    let gate: VideoScanModel.BulkDeleteGate
    let archiveLabel: String
    let policy: DuplicateKeeperPolicy
    /// Rows hidden by the old "deleted" label (see `CleanupPlan.hiddenByOldLabel`).
    var hiddenByOldLabel = CleanupPlan.Tally()

    /// The plan. Blocking disk reads — off the main actor only.
    /// `driveOnline` is the reachability seam.
    func plan(driveOnline: @escaping (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) })
        -> CleanupPlan {
        var rows = rows
        for i in rows.indices {
            rows[i].protection = protection(for: subjects[i])
        }
        let policy = policy
        var plan = CleanupPlanner.plan(rows: rows,
                                       facts: { CleanupDiskProbe.facts(for: $0, driveOnline: driveOnline) },
                                       rank: { policy.volumeRank(forPath: $0) })
        plan.hiddenByOldLabel = hiddenByOldLabel
        return plan
    }

    /// One row's protection. The gate answers the Master Archive half first,
    /// so a FamilyArchive file on a drive ALSO marked Read only reads
    /// "archive volume" there; the Read-only mark is asked here too, so the
    /// tick box never lists a file the engine would hold for that mark.
    func protection(for subject: VideoScanModel.BulkDeleteSubject) -> CleanupProtection? {
        guard let refusal = gate.refusal(for: subject) else { return nil }
        if refusal == .archiveVolume, let verdict = gate.readOnly?.verdict(forPath: subject.path) {
            return .other(VideoScanModel.readOnlyRefusalNote(verdict))
        }
        return Self.protection(refusal, archiveLabel: archiveLabel)
    }

    /// The gate's refusal, reduced to what Cleanup decides on.
    static func protection(_ refusal: VideoScanModel.BulkDeleteRefusal, archiveLabel: String) -> CleanupProtection {
        switch refusal {
        case .archiveTree: return .archiveTree
        case .archiveVolume: return .archiveVolume
        case .archiveVolumeUnprovable, .readOnlyVolume, .readOnlyVolumeDifferentDrive:
            return .other(VideoScanModel.bulkDeleteRefusalNote(refusal, volume: archiveLabel))
        }
    }
}

extension VideoScanModel {

    /// The one O(records) pass (main actor). Active rows only: not removed,
    /// not superseded, pointing at a file.
    func cleanupInputs() -> CleanupInputs {
        let gate = bulkDeleteGate(effect: .removesFiles)
        var rows: [CleanupRow] = []
        var subjects: [BulkDeleteSubject] = []
        rows.reserveCapacity(records.count)
        subjects.reserveCapacity(records.count)
        for r in records where FullHashBackfillPlanner.isActive(r) {
            rows.append(CleanupRow(
                id: r.id, path: r.fullPath, filename: r.filename, volumeName: r.volumeName,
                sizeBytes: r.sizeBytes, fullDigest: Self.storedFullDigest(r),
                isJunk: r.mediaDisposition == .confirmedJunk,
                isArchived: isArchived(r),
                isPairHalf: CatalogScopePolicy.isPairProtected(r),
                isSetAside: r.setAsideReason != nil,
                protection: nil,
                marks: Self.handMarks(r)))
            subjects.append(bulkDeleteSubject(r))
        }
        return CleanupInputs(rows: rows, subjects: subjects, gate: gate,
                             archiveLabel: gate.volume?.label ?? "the archive volume",
                             policy: duplicateKeeperPolicy())
    }

    /// Rick's hand marks on `r` (see `CleanupHandMarks`): never Migrate's
    /// `originalFullPath`, tags, attestations or a machine-written note
    /// line. Pure.
    nonisolated static func handMarks(_ r: VideoRecord) -> CleanupHandMarks {
        CleanupHandMarks(stars: max(0, r.starRating),
                         confirmedPeople: r.confirmedByUserPeople.count,
                         hasDate: r.userDate != nil,
                         hasPlace: r.userPlace != nil,
                         noteLines: CleanupHandMarks.humanNoteLines(r.userNotes))
    }

    /// Build the plan: the projection here, everything else off-main.
    func buildCleanupPlan() async -> CleanupPlan {
        let inputs = cleanupInputs()
        return await Task.detached(priority: .userInitiated) { inputs.plan() }.value
    }

    /// The stored whole-file SHA-256 for `r`, only when it covers exactly
    /// the catalog's size: `contentFixity` (any record), else the archive
    /// copy's `archiveFixity`. nil = "not checked yet". Pure.
    nonisolated static func storedFullDigest(_ r: VideoRecord) -> String? {
        if let f = r.contentFixity, f.algorithm == ContentFixity.sha256, f.byteCount == r.sizeBytes, !f.digest.isEmpty {
            return f.digest
        }
        if let a = r.archiveFixity, a.algorithm == ContentFixity.sha256, a.sizeBytes == r.sizeBytes, !a.digest.isEmpty {
            return a.digest.lowercased()
        }
        return nil
    }
}
