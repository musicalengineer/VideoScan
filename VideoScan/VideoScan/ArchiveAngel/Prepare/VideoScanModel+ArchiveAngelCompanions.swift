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
// LAUNCH RECONCILIATION (2026-09-21): the entry point above reconciles
// only when it is called, so batches cleared BEFORE it existed left their
// companion records live (8 of the 13 "not connected" rows in Rick's
// "Archived — what next?" sheet were exactly those). Once per launch,
// `reconcileArchiveAngelBufferAtLaunch` walks the active records under
// the buffer root, stats their batch and entry folders OFF the main
// actor, and retires — through the same entry point, per batch folder —
// the companions whose folder is gone. A record whose folder is still
// there is never touched, whatever its file says: that is a job's call.
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

    // MARK: - Launch reconciliation (2026-09-21)

    /// The reason strings the launch pass writes (tests pin them).
    enum ArchiveAngelLaunchReconcile {
        static let batchFolderGone = "buffer folder gone — retired at launch"
        static let entryFolderGone = "buffer row folder gone — retired at launch"
    }

    /// The folders a record under the buffer root belongs to, from its
    /// path alone: `<root>/batch-…/<entryUUID>/file` → (batchDir, entryDir).
    /// nil when the path is not `<root>/batch-…/…`; `entryDir` nil when the
    /// second component is not a UUID (a file directly in the batch
    /// folder, or an older layout). Pure — unit-tested directly.
    nonisolated static func archiveAngelBufferFolders(of path: String, bufferRoot: URL)
        -> (batchDir: String, entryDir: String?)? {
        let prefix = folderPrefix(bufferRoot.path)
        guard !prefix.isEmpty, path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        let comps = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard comps.count >= 2, comps[0].hasPrefix("batch-") else { return nil }
        let batchDir = prefix + comps[0]
        guard comps.count >= 3, UUID(uuidString: comps[1]) != nil else { return (batchDir, nil) }
        return (batchDir, batchDir + "/" + comps[1])
    }

    /// Once per launch (called from `ArchiveAngel.launch()`'s launch task
    /// with the façade's buffer root; tests call it directly with a sandbox
    /// root): every active
    /// record whose path lies under the Angel buffer root and whose batch
    /// folder — or row folder — no longer exists is retired through
    /// `forgetArchiveAngelCompanions` per batch, with a launch reason and
    /// a `copyDeleted` line by the angel. Folder stats run OFF the main
    /// actor; the catalog is read and written on it. A record whose
    /// folders still exist is never touched — even if its file is gone —
    /// that is a job's reconciliation, not launch's. A batch a job is
    /// running right now is skipped. Idempotent: the second pass finds
    /// nothing. Returns the number of records retired; one log line names
    /// the count.
    @discardableResult
    func reconcileArchiveAngelBufferAtLaunch(bufferRoot: URL,
                                             fileExists: @escaping @Sendable (String) -> Bool = VideoScanModel.fileIsOnDisk) async -> Int {
        // Main actor: which records live under the buffer, and in which folders.
        var recordsInBatch: [String: Int] = [:]
        var entriesOfBatch: [String: Set<String>] = [:]
        for rec in records where !rec.isPurged {
            guard let (batchDir, entryDir) = Self.archiveAngelBufferFolders(of: rec.fullPath, bufferRoot: bufferRoot) else { continue }
            guard !ArchiveAngelLiveBatches.isLive(batchDir) else { continue }
            recordsInBatch[batchDir, default: 0] += 1
            if let entryDir { entriesOfBatch[batchDir, default: []].insert(entryDir) }
        }
        guard !recordsInBatch.isEmpty else { return 0 }
        let batchDirs = recordsInBatch.keys.sorted()
        let entryDirs = entriesOfBatch

        // Off-main: one stat per batch folder, one per row folder of the
        // batches that are still there.
        let (goneBatches, goneEntries): ([String], [String: [String]]) = await Task.detached(priority: .utility) {
            var gone: [String] = []
            var goneRows: [String: [String]] = [:]
            for dir in batchDirs {
                if !fileExists(dir) { gone.append(dir); continue }
                for entry in (entryDirs[dir] ?? []).sorted() where !fileExists(entry) {
                    goneRows[dir, default: []].append(entry)
                }
            }
            return (gone, goneRows)
        }.value

        // Main actor: retire through the one entry point, per batch. The
        // folders are gone, so every file under them is gone — the
        // entry point's own file check is answered from that fact (no
        // second stat, and never a "survivor" line for a folder that
        // does not exist).
        let now = Date()
        var retired = 0
        if !goneBatches.isEmpty {
            retired += forgetArchiveAngelCompanions(batchDirs: goneBatches,
                                                    reason: ArchiveAngelLaunchReconcile.batchFolderGone,
                                                    at: now, fileExists: { _ in false })
        }
        for (dir, entries) in goneEntries.sorted(by: { $0.key < $1.key }) {
            let ids = Set(entries.compactMap { UUID(uuidString: ($0 as NSString).lastPathComponent) })
            guard !ids.isEmpty else { continue }
            retired += forgetArchiveAngelCompanions(batchDir: dir, entryIDs: ids,
                                                    reason: ArchiveAngelLaunchReconcile.entryFolderGone,
                                                    at: now, fileExists: { _ in false })
        }
        let checked = recordsInBatch.values.reduce(0, +)
        let line = "Archive Angel: launch reconciliation — \(checked) companion record(s) under the buffer in "
            + "\(batchDirs.count) batch folder(s); \(goneBatches.count) folder(s) gone, "
            + "\(goneEntries.values.reduce(0) { $0 + $1.count }) row folder(s) gone; retired \(retired) record(s)"
        log(line)
        appLog.write(line)
        return retired
    }
}
