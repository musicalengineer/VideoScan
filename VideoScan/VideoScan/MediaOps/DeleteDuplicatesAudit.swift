// DeleteDuplicatesAudit.swift
// G2 for Delete Duplicates: every run (bulk, resumed, reviewed — and the
// Copies & Advice hand-off, which is a reviewed run) writes the auditor's
// record through `DeletionAudit`:
//   [dupjob] audit: START Delete Duplicates — by rickb · volume … · plan … · N files requested (X)
//   [dupjob] audit: moved /Volumes/X/a.mov (4 GB) → /Volumes/X/.Trashes/501/a.mov · keeper /…/k.mov (sha256:… — keeper read in full) — reason
//   [dupjob] audit: OUTCOME Delete Duplicates — moved … · held … · … · receipt: ~/Library/Logs/VideoScan/deletions/…_duplicates.csv
// One row per requested copy: each row is written the moment it settles
// (`mutatePlan` → `auditNewlySettledRows`); rows never reached are written
// at the end as cancelled. The existing "[dupjob] trashed …" lines stay.

import Foundation

extension DeleteDuplicatesPlan.Entry {

    /// This row as the audit and the receipt say it.
    var auditRow: DeletionAuditRow {
        let kind = outcome
        let mapped: DeletionAuditOutcome
        var reason = note
        switch kind {
        case .moved: mapped = .moved
        case .held: mapped = .held
        case .failed: mapped = .failed
        case .recoveryNeeded:
            mapped = .failed
            reason += (reason.isEmpty ? "" : " — ") + "still in its quarantine folder \(quarantineDirectory ?? "?") — Put Back is owed"
        case .missing: mapped = .missing
        case .offline: mapped = .offline
        case .cancelled:
            mapped = .cancelled
            if reason.isEmpty { reason = DeleteDuplicatesOutcomeReport.notReachedReason }
        case .deletedOutright:
            mapped = .failed
            reason = "deleted outright by an older build (never requested since Trash only)"
        }
        return DeletionAuditRow(outcome: mapped, originalPath: path,
                                trashPath: mapped == .moved ? trashPath : nil,
                                sizeBytes: mapped == .moved ? bytesMoved : sizeBytes,
                                keeperPath: keeperPath.isEmpty ? nil : keeperPath,
                                keeperProof: keeperProof, reason: reason)
    }
}

extension DeleteDuplicatesJob {

    /// "sha256:0123456789ab — keeper read in full" / "— keeper's stored fixity, stat stamp unchanged".
    nonisolated static func keeperProofWords(_ proof: VerifiedDuplicate) -> String {
        "sha256:\(proof.fullHash.prefix(12)) — "
            + (proof.keeperReadInFull ? "keeper read in full" : "keeper's stored fixity, stat stamp unchanged")
    }

    /// START, and the rows this run settled before the first read (a
    /// reviewed row that no longer stands). A resumed plan's earlier rows
    /// belong to the run that settled them: not repeated here.
    func startAudit(_ plan: DeleteDuplicatesPlan, model: VideoScanModel) {
        let audit = DeletionAudit(kind: .duplicates, verb: "Delete Duplicates", linePrefix: "[dupjob] audit: ",
                                  sink: model.deletionAuditSink(appLog: appLogSink))
        self.audit = audit
        let resumed = resumingPlanIsSet
        let earlier = resumed ? Set(plan.entries.filter(\.status.isSettled).map(\.id)) : []
        auditedRows = earlier
        let requested = plan.entries.filter { !earlier.contains($0.id) }
        let how = plan.isReviewed ? "reviewed" : (resumed ? "resumed" : "bulk")
        audit.start(scope: "volume \(volumeName) · plan \(plan.id.uuidString.prefix(8)) (\(how))",
                    requested: requested.count, bytes: requested.reduce(Int64(0)) { $0 + $1.sizeBytes })
        auditNewlySettledRows()
    }

    /// Each row that has settled since the last call: one line, one receipt row.
    func auditNewlySettledRows() {
        guard let audit, let plan else { return }
        for e in plan.entries where e.status.isSettled && !auditedRows.contains(e.id) {
            auditedRows.insert(e.id)
            audit.record(e.auditRow)
        }
    }

    /// The end of the run: rows never reached are written as cancelled, then
    /// the OUTCOME line with the receipt's path. Idempotent.
    func auditRemainingAndFinish(_ plan: DeleteDuplicatesPlan) {
        guard let audit else { return }
        for e in plan.entries where !auditedRows.contains(e.id) {
            auditedRows.insert(e.id)
            audit.record(e.auditRow)
        }
        audit.finish()
        receiptURL = audit.receipt.url
        self.audit = nil
    }

    /// A reviewed plan refused before anything was read: every row, held.
    func auditRefusedReviewedPlan(model: VideoScanModel) {
        guard let plan, !plan.entries.isEmpty else { return }
        startAudit(plan, model: model)
        auditRemainingAndFinish(plan)
    }
}
