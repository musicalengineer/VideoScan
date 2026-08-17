//
//  VideoScanModel+RecordIdentityRepair.swift
//  VideoScan
//
//  Load-time repair for duplicate record IDs. Rick 2026-08-17: 203 pairs
//  appeared during a Migrate (live dossier reload re-appended relinked
//  records under their OLD paths — see VideoScanModel+LiveReload). One
//  UUID must mean one record: every index (RecordIDIndex, promotion
//  index, dup groups, pair links) assumes it, and Dictionary(uniqueKeys…)
//  in the search tests trapped on the real file.
//
//  Policy — deterministic, logged, never guesses about media:
//    keep the record that is the CURRENT home (has originalFullPath —
//    i.e. it was relinked/migrated), else the one whose file exists,
//    else the first; drop the others. Nothing on disk is touched.
//

import Foundation
import os

private let identityRepairLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "recordIdentityRepair")

extension VideoScanModel {

    struct RecordIdentityRepairReport: Equatable {
        var duplicateIDs = 0
        var dropped = 0
    }

    /// Dedupe `records` by id. Returns what it did; logs when it did anything.
    @discardableResult
    func repairDuplicateRecordIDs() -> RecordIdentityRepairReport {
        var seen: [UUID: Int] = [:]          // id → index of the kept record
        var report = RecordIdentityRepairReport()
        var keep: [VideoRecord] = []
        keep.reserveCapacity(records.count)
        var dropIndices: [Int] = []
        for rec in records {
            if let idx = seen[rec.id] {
                let current = keep[idx]
                if Self.prefer(rec, over: current) {
                    keep[idx] = rec
                }
                report.dropped += 1
                dropIndices.append(idx)
            } else {
                seen[rec.id] = keep.count
                keep.append(rec)
            }
        }
        guard report.dropped > 0 else { return report }
        report.duplicateIDs = Set(dropIndices).count
        records = keep
        log("Repaired \(report.duplicateIDs) duplicate record id(s): dropped \(report.dropped) stale twin(s) — kept the current home for each (files untouched).")
        identityRepairLog.notice("record identity repair: duplicateIDs=\(report.duplicateIDs) dropped=\(report.dropped)")
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        return report
    }

    /// Which twin is the current home?
    nonisolated static func prefer(_ candidate: VideoRecord, over current: VideoRecord) -> Bool {
        let cRelinked = candidate.originalFullPath != nil
        let kRelinked = current.originalFullPath != nil
        if cRelinked != kRelinked { return cRelinked }
        let cExists = FileManager.default.fileExists(atPath: candidate.fullPath)
        let kExists = FileManager.default.fileExists(atPath: current.fullPath)
        if cExists != kExists { return cExists }
        return false
    }
}
