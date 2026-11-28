// MediaFileOperations+AVSync.swift
// MediaFileOperationsCenter's "Check A/V Sync" dispatch (design
// docs/design/av_sync_analysis.md §6). Same shape as the other verbs: build
// the gate plan, refuse a duplicate loudly, add the job, write the START line.
// The job (AVSyncJob) does the rest; nothing here touches a file.

import Foundation

extension MediaFileOperationsCenter {

    /// The Check A/V Sync job already measuring this processed file.
    func activeAVSyncJob(forProcessedID id: UUID) -> AVSyncJob? {
        jobs.lazy.compactMap { $0 as? AVSyncJob }
            .first { $0.state.isActive && $0.items.contains { $0.pair.processed.recordID == id } }
    }

    /// Start ONE job for `pairs` (processed file → its original). Pairs whose
    /// processed file is already being checked are left out; nil (and a
    /// "refused" log line) when nothing is left. `reader` / `stat` are test
    /// seams; production passes nil.
    @discardableResult
    func startAVSync(pairs: [AVSyncJob.Pair], reader: AVSyncJob.Reader? = nil,
                     stat: AVSyncJob.Stat? = nil, vouch: AVSyncJob.Vouch? = nil) -> AVSyncJob? {
        let fresh = pairs.filter { activeAVSyncJob(forProcessedID: $0.processed.recordID) == nil }
        guard !fresh.isEmpty else {
            appLog.write("check a/v sync refused: the selected file(s) are already being checked; nothing was started")
            return nil
        }
        let job = AVSyncJob(pairs: fresh, store: avSyncResults,
                            gatesFor: { [weak self] paths in self?.gatePlan(forPaths: paths) ?? [] },
                            reader: reader ?? AVSyncJob.realReader, stat: stat ?? AVSyncJob.realStat,
                            vouch: vouch ?? AVSyncJob.realVouch, cache: avSyncEvidence)
        guard add(job) else { return nil }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: Self.avSyncPlan(pairs: fresh, policy: job.policy)))
        return job
    }

    /// The START line's plan clause.
    nonisolated static func avSyncPlan(pairs: [AVSyncJob.Pair], policy: AVSyncPolicy) -> String {
        let list = pairs.prefix(3).map { "\($0.processed.filename) against \($0.original.filename)" }
            .joined(separator: "; ")
        let more = pairs.count > 3 ? "; and \(pairs.count - 3) more" : ""
        return "sound-vs-picture timing of \(pairs.count) file(s) — \(list)\(more) "
            + "(policy \(policy.identity): in sync from \(Int(policy.lateLimitMs)) ms late to "
            + "\(Int(policy.earlyLimitMs)) ms early; reads only)"
    }
}
