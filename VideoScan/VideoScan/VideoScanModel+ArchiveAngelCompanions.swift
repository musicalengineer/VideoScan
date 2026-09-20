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
// RECONCILED, not assumed (codex review 2026-09-20 #4): a record is
// retired only when its file is CONFIRMED gone. Every caller invokes this
// AFTER the removal has finished (the detached removals hop back to the
// main actor for it); a record whose file survived — a read-only folder,
// a file ffmpeg still held — keeps its record and is logged as a
// survivor, never given a `copyDeleted` line it did not earn.
//
// (For Rick: this is the same "separate, don't delete" discipline as the
// rest of the catalog — a tombstone, not a removal.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// One batch (optionally only some of its entry folders) to reconcile.
    struct ArchiveAngelCompanionScope: Sendable {
        let batchDir: String
        let entryIDs: Set<UUID>?
        init(batchDir: String, entryIDs: Set<UUID>? = nil) {
            self.batchDir = batchDir; self.entryIDs = entryIDs
        }
    }

    /// Retire every catalogued companion whose file lives under
    /// `batchDir` (optionally only under the given entry folders) AND is
    /// gone from disk. Call AFTER the files are removed; idempotent.
    /// Returns the number of records retired.
    @discardableResult
    func forgetArchiveAngelCompanions(batchDir: String, entryIDs: Set<UUID>? = nil,
                                      reason: String, at now: Date = Date(),
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        forgetArchiveAngelCompanions(scopes: [.init(batchDir: batchDir, entryIDs: entryIDs)],
                                     reason: reason, at: now, fileExists: fileExists)
    }

    /// Several whole batches in ONE catalog pass (Clear all, #10).
    @discardableResult
    func forgetArchiveAngelCompanions(batchDirs: [String], reason: String, at now: Date = Date(),
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        forgetArchiveAngelCompanions(scopes: batchDirs.map { .init(batchDir: $0) },
                                     reason: reason, at: now, fileExists: fileExists)
    }

    /// The companions of the rows listed, by entry id.
    @discardableResult
    func forgetArchiveAngelCompanions(of entries: [ArchiveAngelPlan.Entry], in plan: ArchiveAngelPlan,
                                      reason: String, at now: Date = Date(),
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        guard !entries.isEmpty else { return 0 }
        return forgetArchiveAngelCompanions(batchDir: plan.batchDir, entryIDs: Set(entries.map(\.id)),
                                            reason: reason, at: now, fileExists: fileExists)
    }

    /// After `ArchiveAngelPlanStore.settleInterruptedBatches`: a discarded
    /// batch lost its whole folder; a kept batch lost the folders of the
    /// rows the settle failed. A row that failed EARLIER (a real step
    /// failure) keeps its folder and its records, so only rows whose
    /// entry folder is gone are retired — and within them, only records
    /// whose file is gone.
    @discardableResult
    func forgetArchiveAngelCompanions(settled plans: [ArchiveAngelPlan],
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        var total = 0
        for plan in plans {
            if plan.status == .discarded {
                total += forgetArchiveAngelCompanions(batchDir: plan.batchDir, reason: "interrupted batch discarded",
                                                      fileExists: fileExists)
                continue
            }
            let gone = plan.entries.filter { e in
                e.status == .failed
                    && !fileExists(URL(fileURLWithPath: plan.batchDir).appendingPathComponent(e.id.uuidString).path)
            }
            total += forgetArchiveAngelCompanions(of: gone, in: plan, reason: "interrupted before the row was prepared",
                                                  fileExists: fileExists)
        }
        return total
    }

    /// The one pass: every live record under any scope is checked on disk
    /// once; gone → retired with its `copyDeleted` line; still there →
    /// kept and named in the log.
    @discardableResult
    func forgetArchiveAngelCompanions(scopes: [ArchiveAngelCompanionScope], reason: String, at now: Date = Date(),
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        struct Root { let prefix: String; let batchID: String; let entryPrefixes: [String]? }
        let roots: [Root] = scopes.compactMap { scope in
            let prefix = Self.folderPrefix(scope.batchDir)
            guard !prefix.isEmpty else { return nil }
            return Root(prefix: prefix, batchID: (scope.batchDir as NSString).lastPathComponent,
                        entryPrefixes: scope.entryIDs.map { ids in ids.map { prefix + $0.uuidString + "/" } })
        }
        guard !roots.isEmpty else { return 0 }
        var retired: [(VideoRecord, String)] = []
        var survivors: [(VideoRecord, String)] = []
        for rec in records where !rec.isPurged {
            guard let root = roots.first(where: { rec.fullPath.hasPrefix($0.prefix) }) else { continue }
            if let prefixes = root.entryPrefixes, !prefixes.contains(where: { rec.fullPath.hasPrefix($0) }) { continue }
            if fileExists(rec.fullPath) {
                survivors.append((rec, root.batchID))
                continue
            }
            rec.purgedAt = now
            retired.append((rec, root.batchID))
        }
        if !survivors.isEmpty {
            let byBatch = Dictionary(grouping: survivors, by: \.1)
            for (batchID, kept) in byBatch.sorted(by: { $0.key < $1.key }) {
                let line = "Archive Angel: kept \(kept.count) companion record(s) of \(batchID) — "
                    + "their files are still in the buffer (the removal did not finish) — \(reason): "
                    + kept.prefix(5).map { $0.0.filename }.joined(separator: ", ")
                    + (kept.count > 5 ? " and \(kept.count - 5) more" : "")
                log(line)
                appLog.write(line)
            }
        }
        guard !retired.isEmpty else { return 0 }
        saveCatalogDebounced()
        noteCatalogRecordsMutated()
        ledgerAppend(retired.map { rec, batchID in
            ledgerEvent(.copyDeleted, for: rec, by: .angel, at: now,
                        batchID: batchID,
                        detail: [MediaLedgerEvent.Detail.volume: rec.volumeName,
                                 MediaLedgerEvent.Detail.mode: "permanent",
                                 MediaLedgerEvent.Detail.reason: reason])
        })
        let byBatch = Dictionary(grouping: retired, by: \.1)
        for (batchID, gone) in byBatch.sorted(by: { $0.key < $1.key }) {
            let line = "Archive Angel: retired \(gone.count) catalogued companion record(s) of "
                + "\(batchID) — \(reason): "
                + gone.prefix(5).map { $0.0.filename }.joined(separator: ", ")
                + (gone.count > 5 ? " and \(gone.count - 5) more" : "")
            log(line)
            appLog.write(line)
        }
        return retired.count
    }

    /// "/Volumes/X/Buffer/batch-…" → "/Volumes/X/Buffer/batch-…/" (standardized, trailing slash).
    nonisolated static func folderPrefix(_ dir: String) -> String {
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard !path.isEmpty, path != "/" else { return "" }
        return path.hasSuffix("/") ? path : path + "/"
    }
}
