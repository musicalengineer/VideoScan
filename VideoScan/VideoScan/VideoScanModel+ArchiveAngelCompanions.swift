// VideoScanModel+ArchiveAngelCompanions.swift
// The Angel's companions (balanced audio, access copy, lossless copy) are
// CATALOGUED the moment their job finishes — BalanceAudioJob and
// TranscodeJob append a workspaceActive record with derivedFrom = the
// original. When the Angel later throws the companion FILE away (a row
// skipped, a batch cancelled or discarded, an interrupted batch settled)
// the record must go with it, or the catalog carries a live record for a
// file that no longer exists (codex #1572, 2026-09-19: "unfinished-row
// reclaim deletes already-catalogued Balance/Access companions, leaving
// workspaceActive records with missing files").
//
// ONE entry point, called at every site that removes buffer files (Rick's
// wrapper-over-N-call-sites rule): a record is a companion of a batch when
// its path lies inside that batch folder. It is retired the way Delete
// Confirmed Junk retires a removed file — `purgedAt` stamped, no undo
// banner (nothing to undo: the Angel made it and the Angel deleted it), a
// `copyDeleted` ledger line by the angel, one log line — never deleted
// from the array (caches and indexes hold the record).
//
// (For Rick: this is the same "separate, don't delete" discipline as the
// rest of the catalog — a tombstone, not a removal.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// Retire every catalogued companion whose file lives under
    /// `batchDir` (optionally only under the given entry folders). Safe to
    /// call before or after the files are removed; idempotent. Returns the
    /// number of records retired.
    @discardableResult
    func forgetArchiveAngelCompanions(batchDir: String, entryIDs: Set<UUID>? = nil,
                                      reason: String, at now: Date = Date()) -> Int {
        let root = Self.folderPrefix(batchDir)
        guard !root.isEmpty else { return 0 }
        let entryPrefixes = entryIDs.map { ids in ids.map { root + $0.uuidString + "/" } }
        var retired: [VideoRecord] = []
        for rec in records where !rec.isPurged && rec.fullPath.hasPrefix(root) {
            if let prefixes = entryPrefixes, !prefixes.contains(where: { rec.fullPath.hasPrefix($0) }) { continue }
            rec.purgedAt = now
            retired.append(rec)
        }
        guard !retired.isEmpty else { return 0 }
        saveCatalogDebounced()
        noteCatalogRecordsMutated()
        ledgerAppend(retired.map {
            ledgerEvent(.copyDeleted, for: $0, by: .angel, at: now,
                        batchID: (batchDir as NSString).lastPathComponent,
                        detail: [MediaLedgerEvent.Detail.volume: $0.volumeName,
                                 MediaLedgerEvent.Detail.mode: "permanent",
                                 MediaLedgerEvent.Detail.reason: reason])
        })
        let line = "Archive Angel: retired \(retired.count) catalogued companion record(s) of "
            + "\((batchDir as NSString).lastPathComponent) — \(reason): "
            + retired.prefix(5).map(\.filename).joined(separator: ", ")
            + (retired.count > 5 ? " and \(retired.count - 5) more" : "")
        log(line)
        appLog.write(line)
        return retired.count
    }

    /// The companions of the rows listed, by entry id.
    @discardableResult
    func forgetArchiveAngelCompanions(of entries: [ArchiveAngelPlan.Entry], in plan: ArchiveAngelPlan,
                                      reason: String, at now: Date = Date()) -> Int {
        guard !entries.isEmpty else { return 0 }
        return forgetArchiveAngelCompanions(batchDir: plan.batchDir, entryIDs: Set(entries.map(\.id)),
                                            reason: reason, at: now)
    }

    /// After `ArchiveAngelPlanStore.settleInterruptedBatches`: a discarded
    /// batch lost its whole folder; a kept batch lost the folders of the
    /// rows the settle failed. A row that failed EARLIER (a real step
    /// failure) keeps its folder and its records, so only rows whose
    /// entry folder is gone are retired.
    @discardableResult
    func forgetArchiveAngelCompanions(settled plans: [ArchiveAngelPlan],
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        var total = 0
        for plan in plans {
            if plan.status == .discarded {
                total += forgetArchiveAngelCompanions(batchDir: plan.batchDir, reason: "interrupted batch discarded")
                continue
            }
            let gone = plan.entries.filter { e in
                e.status == .failed
                    && !fileExists(URL(fileURLWithPath: plan.batchDir).appendingPathComponent(e.id.uuidString).path)
            }
            total += forgetArchiveAngelCompanions(of: gone, in: plan, reason: "interrupted before the row was prepared")
        }
        return total
    }

    /// "/Volumes/X/Buffer/batch-…" → "/Volumes/X/Buffer/batch-…/" (standardized, trailing slash).
    nonisolated static func folderPrefix(_ dir: String) -> String {
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard !path.isEmpty, path != "/" else { return "" }
        return path.hasSuffix("/") ? path : path + "/"
    }
}
