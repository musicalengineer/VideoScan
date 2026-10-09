// MediaFileOperations+Repair.swift
// MediaFileOperationsCenter's "Repair Now" dispatch (Rick 2026-10-08). Same
// shape as startPromote: build the gate plan, add the job, refuse a
// duplicate loudly, write the START line, go. The job and the engine do
// the rest; nothing here touches a file.

import Foundation
import os

private let repairCenterLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "repair")

extension MediaFileOperationsCenter {

    /// A Repair Now job for this record is running.
    func activeRepairJob(forRecordID id: UUID) -> MediaRepairJob? {
        jobs.lazy.compactMap { $0 as? MediaRepairJob }.first { $0.state.isActive && $0.record.id == id }
    }

    /// Everything the job needs, asked HERE on the main actor: the recipe
    /// (with this session's sound measurement for Balance), the delete
    /// gate's sentence for the output path, and the gate packaged for the
    /// engine's off-main re-check. Pure apart from the model reads.
    func repairRequest(record: VideoRecord, fixes: [MediaRepairFix], output: URL,
                       model: VideoScanModel) -> MediaRepairRequest {
        let diagnosis = verifyDiagnosis(forRecordID: record.id)
        let recipe = MediaRepairRecipe(fixes: fixes, balance: MediaRepairBalanceInput(diagnosis: diagnosis))
        let label = model.archiveVolumeProtection()?.label ?? "the archive volume"
        let note = model.bulkDeleteRefusal(forPath: output.path)
            .map { VideoScanModel.bulkDeleteRefusalNote($0, volume: label) }
        return MediaRepairRequest(sourcePath: record.fullPath, sourceSizeBytes: record.sizeBytes,
                                  sourceDurationSeconds: max(0, record.durationSeconds),
                                  output: output, recipe: recipe,
                                  outputProtectionNote: note, archiveCheck: model.archiveRemovalCheck())
    }

    /// Kick off ONE Repair Now job: every selected fix, one ffmpeg pass, one
    /// new file at `output`. Refused (parked as a refused row) when a
    /// repair of the same file is already running — two runs would race
    /// for the same output name. `runner` / `quickVerifier` are TEST SEAMS
    /// only; production passes nil.
    @discardableResult
    func startRepair(record: VideoRecord, fixes: [MediaRepairFix], output: URL, besideOriginal: Bool,
                     model: VideoScanModel,
                     plannedPictureFrames: Int? = nil,
                     runner: MediaRepairJob.Runner? = nil,
                     quickVerifier: MediaRepairJob.QuickVerifier? = nil) -> MediaRepairJob {
        var request = repairRequest(record: record, fixes: fixes, output: output, model: model)
        request.plannedPictureFrames = plannedPictureFrames
        let busy = activeRepairJob(forRecordID: record.id)
        let job = MediaRepairJob(record: record, request: request, beforeCard: record.mediaReportCard,
                                 besideOriginal: besideOriginal, model: model,
                                 gates: gatePlan(forPaths: [record.fullPath, output.path]),
                                 runner: runner, quickVerifier: quickVerifier)
        guard add(job) else { return job }
        if busy != nil {
            repairCenterLog.notice("repair REFUSED duplicate dispatch: \(record.filename, privacy: .public)")
            job.refuseToStart(reason: "a repair of this file is already running — wait for it to finish (or stop it) first. Nothing was started.")
            return job
        }
        job.start()
        let plan = request.recipe.applied.map(\.rawValue).joined(separator: " + ")
        repairCenterLog.info("repair started: \(record.filename, privacy: .public) [\(plan, privacy: .public)] → \(output.path, privacy: .public)")
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "\(plan) → \(output.path) (original only read)"))
        return job
    }
}
