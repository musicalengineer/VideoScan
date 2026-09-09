// MediaFileOperations+ArchiveAngel.swift
// Center hook for Archive Angel Stage 1 (docs/archive_angel_design.md).

import Foundation

extension MediaFileOperationsCenter {

    /// Start one Archive Angel batch: consider `count` candidates, prepare
    /// their companions in the buffer, stop for review. One active Angel
    /// at a time; a second request is parked as refused.
    @discardableResult
    func startArchiveAngel(count: Int, makeLossless: Bool, model: VideoScanModel) -> ArchiveAngelJob {
        let job = ArchiveAngelJob(model: model, center: self, count: count, makeLossless: makeLossless,
                                  bufferRoot: ArchiveAngelPlanStore.defaultBufferRoot)
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
            plan: "consider \(count) candidates, lossless \(makeLossless ? "on" : "off"), buffer \(job.bufferRoot.path)"))
        return job
    }
}
