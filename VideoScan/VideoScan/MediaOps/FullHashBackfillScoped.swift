// FullHashBackfillScoped.swift
// "Fill In Full Hashes" for a named set of records (cutover B2.1 gap 1):
// catalog.sqlite keeps a row only for content it can name by its whole-file
// SHA-256, so a new record without one (a scan result, a Combine / Transcode
// output, a Promote copy) is HELD in `pending_rows` and this job is queued
// for exactly those ids. It is the same MFO job as the menu's — same lanes,
// gates, checkpoints, resume rules, read-only on media — planned over the
// scoped records only. When its checkpoint save lands the hash, the commit
// stores the row and drops the pending one.
//
// One Fill In Full Hashes at a time: while one runs, the request is not
// started (nothing is refused in words — the ids stay in
// `CatalogCutoverState.awaitingDigest` and are offered again on the next
// request or the next launch).
//
// (For Rick: the same worker with a filter on its to-do list.)

import Foundation

extension MediaFileOperationsCenter {

    /// Start Fill In Full Hashes over `ids` only. False = not started (one
    /// is already running, or nothing to do).
    @discardableResult
    func startFullHashBackfill(model: VideoScanModel, scopedTo ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty, !jobs.contains(where: { $0.state.isActive && $0 is FullHashBackfillJob }) else { return false }
        let job = FullHashBackfillJob(model: model, marker: nil)
        job.scope = ids
        job.gatesFor = { [weak self] path in self?.gatePlan(forPaths: [path]) ?? [] }
        guard add(job) else { return false }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "hash in full the \(ids.count) new catalog row(s) catalog.sqlite holds until they have a "
                                               + "whole-file hash — read only on media"))
        return true
    }
}
