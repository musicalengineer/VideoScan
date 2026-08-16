// MediaFileOperations+Promote.swift
// MediaFileOperationsCenter's "Promote to Archive" dispatch (split out of
// MediaFileOperations.swift, which is at the file-length limit). Same
// shape as startRebuildAudio: build the gate plan, add the job, refuse a
// duplicate dispatch loudly, write the START line, go.

import Foundation
import os

private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

extension MediaFileOperationsCenter {

    /// Kick off ONE Promote job for a confirmed plan (spec §4/§5). Gates
    /// on every source volume plus the archive volume so a batch off one
    /// HDD onto the RAID runs one file at a time instead of thrashing.
    /// Refuses (parked, `.failed` + wasRefused) when another Promote job
    /// is already active for ANY of the same records — two jobs would
    /// race on the same destination name and the idempotency re-check.
    @discardableResult
    func startPromote(plan: ArchivePromotePlan, model: VideoScanModel) -> PromoteToArchiveJob {
        let sourcePaths = plan.entries.compactMap { model.record(forID: $0.recordID)?.fullPath }
        let gates = gatePlan(forPaths: sourcePaths + [plan.rootPath])
        let job = PromoteToArchiveJob(plan: plan, model: model, gates: gates)
        add(job)

        let planIDs = Set(plan.entries.map(\.recordID))
        let duplicate = jobs.contains { other in
            guard other.id != job.id, other.state.isActive,
                  let p = other as? PromoteToArchiveJob else { return false }
            return !planIDs.isDisjoint(with: p.plan.entries.map(\.recordID))
        }
        if duplicate {
            fileOpsLog.warning("promote REFUSED (overlapping promote already running): \(plan.entries.count) file(s)")
            job.refuseToStart(reason: "A promotion including some of these files is already running — wait for it to finish (or cancel it) before starting another. Nothing was started.")
            return job
        }
        job.start()
        fileOpsLog.info("promote started: \(plan.entries.count) file(s), \(plan.totalBytes) bytes → \(plan.rootPath, privacy: .public) (gates: \(gates.count))")
        appLog.write(Self.startSummaryLine(
            verb: job.kind.logVerb,
            title: job.title,
            plan: "\(plan.entries.count) file(s), \(PromoteToArchiveJob.humanBytes(plan.totalBytes)) → \(URL(fileURLWithPath: plan.rootPath).lastPathComponent)/"))
        return job
    }
}
