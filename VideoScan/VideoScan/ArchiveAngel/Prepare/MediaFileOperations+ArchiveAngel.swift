// MediaFileOperations+ArchiveAngel.swift
// Center hook for Archive Angel Stage 1 (docs/archive_angel_design.md).

import Foundation

extension MediaFileOperationsCenter {

    /// Start one Archive Angel batch: consider `count` candidates, prepare
    /// their companions in the buffer, stop for review. One active Angel
    /// at a time; a second request is parked as refused.
    @discardableResult
    func startArchiveAngel(count: Int, makeLossless: Bool, model: VideoScanModel) -> ArchiveAngelJob {
        launchArchiveAngel(
            ArchiveAngelJob(model: model, center: self, count: count, makeLossless: makeLossless,
                            bufferRoot: ArchiveAngelPlanStore.defaultBufferRoot),
            model: model,
            plan: "consider \(count) candidates, lossless \(makeLossless ? "on" : "off")")
    }

    /// "Prepare with Archive Angel" on a catalog selection (Rick
    /// 2026-09-11): exactly these records, same batch/review flow.
    @discardableResult
    func startArchiveAngel(recordIDs: [UUID], makeLossless: Bool, model: VideoScanModel) -> ArchiveAngelJob {
        launchArchiveAngel(
            ArchiveAngelJob(model: model, center: self, count: recordIDs.count, makeLossless: makeLossless,
                            bufferRoot: ArchiveAngelPlanStore.defaultBufferRoot, explicitRecordIDs: recordIDs),
            model: model,
            plan: "prepare \(recordIDs.count) selected record(s), lossless \(makeLossless ? "on" : "off")")
    }

    private func launchArchiveAngel(_ job: ArchiveAngelJob, model: VideoScanModel, plan: String) -> ArchiveAngelJob {
        guard add(job) else { return job }
        let duplicate = jobs.contains { other in
            other.id != job.id && other.state.isActive && other is ArchiveAngelJob
        }
        if duplicate {
            job.refuseToStart(reason: "An Archive Angel batch is already running — let it finish or stop it first.")
            return job
        }
        if let reason = job.preflight(model: model) {
            job.refuseToStart(reason: reason)
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(
            verb: job.kind.logVerb, title: job.title,
            plan: plan + ", buffer \(job.bufferRoot.path)"))
        return job
    }
}
