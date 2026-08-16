// PromoteToArchiveJob+Steps.swift
// The per-file steps of Promote to Archive: preflight, journal
// reconciliation (convergence), destination choice with adopt-if-identical,
// the off-main copy hop, the manifest tail, and the batch-end durable
// catalog save that alone advances journal entries to DONE. Split from
// PromoteToArchiveJob.swift to keep each file readable; see that file's
// header for the overall contract.

import Foundation
import os

extension PromoteToArchiveJob {

    struct RunContext {
        let root: String
        let manifestURL: URL
        let journalURL: URL
        /// What the manifest already says per source (idempotency leg 2).
        let manifestRows: [UUID: (relPath: String, sha256: String)]
        /// Full manifest fields per source (orphan registration).
        let manifestFields: [UUID: [String]]
    }

    enum FileResult {
        case promoted(relPath: String)
        /// An identical file already sat in the archive (or the manifest
        /// already listed it) — linked instead of copied again.
        case adopted(relPath: String)
        case skipped(String)
        case failed(String)
        case cancelled
    }

    // MARK: Preflight

    /// Refuse before ANY I/O when: the catalog is read-only on this Mac
    /// (codex R3 blocker 2); the plan's root is no longer the designated
    /// master; the volume mounted at the root is not the archive volume
    /// (UUID mismatch — R3 blocker 1); the master's scan target cannot be
    /// resolved by identity or is retired (`isRetired`, never `role`; nil
    /// target = unknown state = refuse — R3 major 8); the root is offline;
    /// the manifest is missing / a symlink / header-less (R3 blocker 3);
    /// or the batch would not fit (§5.2, re-read now).
    func preflight(model: VideoScanModel) -> RunContext? {
        let root = plan.rootPath
        let fm = FileManager.default
        if model.isReadOnly {
            finish(failed: "This Mac is a read-only viewer of the catalog — promotion runs on the master Mac only. Nothing was copied.")
            return nil
        }
        guard let designated = model.masterArchiveRootPath,
              VideoScanModel.samePath(designated, root) else {
            finish(failed: "The Master Archive designation changed since this promotion was planned. Nothing was copied — try again.")
            return nil
        }
        if let refusal = model.masterArchiveIdentityRefusal() {
            model.masterArchiveIdentityMismatch = refusal
            finish(failed: refusal)
            return nil
        }
        guard let target = model.resolvedMasterArchiveTarget() else {
            finish(failed: "The Master Archive's volume could not be matched to a scan target (by path or volume UUID) — its retired/role state is unknown, so nothing was copied. Re-run Initialize Master Archive on the archive volume.")
            return nil
        }
        if target.isRetired {
            finish(failed: "The Master Archive volume is marked retired — reinstate it in the Volumes window before promoting. Nothing was copied.")
            return nil
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            finish(failed: "The Master Archive folder is not reachable (\(root)). Connect the archive volume and try again.")
            return nil
        }
        do {
            try ArchiveManifestCSV.validate(rootPath: root)
        } catch {
            finish(failed: Self.describe(error))
            return nil
        }
        if let free = VideoScanModel.freeBytes(atPath: root), free < plan.requiredBytes {
            finish(failed: "Not enough free space on the archive volume — need about \(Self.humanBytes(plan.requiredBytes)), only \(Self.humanBytes(free)) available. Nothing was copied.")
            return nil
        }
        let manifestURL = MasterArchiveLayout.manifestURL(rootPath: root)
        return RunContext(root: root,
                          manifestURL: manifestURL,
                          journalURL: ArchivePromoteJournal.url(rootPath: root),
                          manifestRows: ArchiveManifestCSV.rowsBySource(rootPath: root),
                          manifestFields: ArchiveManifestCSV.fieldRowsBySource(rootPath: root))
    }

    // MARK: Reconcile (convergence)

    /// Finish whatever an earlier run left half-done, per the journal:
    ///   intent    + no file        → drop the stale partial, mark abandoned
    ///   any       + file, no row   → verify the file's digest against the
    ///                                journaled sha (or the source's bytes),
    ///                                then append the row + link the record
    ///   published + no catalog link → link the record from manifest/journal
    ///                                provenance (self-contained when the
    ///                                source is gone) — DONE was never
    ///                                written, so the catalog save that
    ///                                should have carried the link may not
    ///                                have landed (codex R3 blocker 5)
    ///   done                       → trusted (a durable catalog save wrote it)
    /// Returns how many promotions were completed here.
    func reconcileJournal(model: VideoScanModel, ctx: RunContext) async -> Int {
        let latest = ArchivePromoteJournal.latestBySource(rootPath: ctx.root)
        var completed = 0
        for (sourceID, entry) in latest where entry.state != .done && entry.state != .abandoned {
            if Task.isCancelled { break }
            let fm = FileManager.default
            // Containment FIRST (codex R4-A): a journal relpath is data from
            // disk, not a trusted value. Non-contained ⇒ logged and skipped —
            // never unlinked, read, or adopted.
            guard ArchivePromoteEngine.isContainedRelPath(entry.destRelPath, root: ctx.root) else {
                promoteLog.error("promote reconcile: journal relpath escapes the archive root — ignored: \(entry.destRelPath, privacy: .public)")
                appLog.write("promote reconcile: journal entry \(entry.destRelPath) is not inside the archive root — ignored")
                continue
            }
            let dest = URL(fileURLWithPath: ctx.root, isDirectory: true)
                .appendingPathComponent(entry.destRelPath).standardizedFileURL
            // Already linked (a crash between catalog save and 'done')? The
            // link is in memory now; the batch-end durable save re-marks it.
            if let src = model.record(forID: sourceID), model.masterArchiveCopy(of: src) != nil {
                publishedThisBatch.append(entry.with(state: .published))
                continue
            }
            // Presence + digest THROUGH the dirfd O_NOFOLLOW chain.
            let actualOrNil: String?
            do {
                actualOrNil = try await Self.hashContainedOffMain(root: ctx.root, relPath: entry.destRelPath)
            } catch {
                promoteLog.error("promote reconcile: \(entry.destRelPath, privacy: .public) refused — \(Self.describe(error), privacy: .public)")
                appLog.write("promote reconcile: \(entry.destRelPath) refused (\(Self.describe(error))) — ignored")
                continue
            }
            guard let actual = actualOrNil else {
                // Never published: clean the partial (dirfd chain), close the intent.
                _ = try? ArchivePromoteEngine.removeContainedPartial(root: ctx.root, relativePath: entry.destRelPath)
                try? ArchivePromoteJournal.append(entry.with(state: .abandoned), rootPath: ctx.root)
                continue
            }
            // Published. Establish the digest we can trust.
            let expected: String?
            if let journaled = entry.sha256 {
                expected = journaled
            } else if let manifestRow = ctx.manifestRows[sourceID] {
                expected = manifestRow.sha256
            } else if fm.fileExists(atPath: entry.sourcePath) {
                expected = try? await Self.hashOffMain(path: entry.sourcePath)
            } else {
                expected = nil
            }
            guard let expected, actual == expected else {
                promoteLog.error("promote reconcile: \(entry.destRelPath, privacy: .public) is in the archive but its digest could not be confirmed — left in place, NOT indexed; check it by hand")
                appLog.write("promote reconcile: \(entry.destRelPath) could not be verified against its source — left in place, not indexed")
                continue
            }
            do {
                try await finishPublished(sourceID: sourceID,
                                          source: model.record(forID: sourceID),
                                          sourcePath: entry.sourcePath,
                                          relPath: entry.destRelPath,
                                          destURL: dest,
                                          sha: actual,
                                          model: model, ctx: ctx,
                                          journalBase: entry)
                completed += 1
                model.log("Promote: completed an interrupted promotion — \(entry.destRelPath) is now indexed.")
            } catch {
                promoteLog.error("promote reconcile failed for \(entry.destRelPath, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return completed
    }

    // MARK: One file

    /// Steps 1–5 for one plan entry.
    func promoteOne(entry: ArchivePromotePlan.Entry,
                    model: VideoScanModel,
                    ctx: RunContext,
                    bytesDone: Int64) async -> FileResult {
        guard let source = model.record(forID: entry.recordID) else {
            return .skipped("record no longer in the catalog")
        }
        // ---- Idempotency by SOURCE IDENTITY (catalog leg).
        if model.masterArchiveCopy(of: source) != nil {
            return .skipped("already in the Master Archive")
        }
        if model.isArchiveCopy(source) || ArchivePathResolver.isInside(path: source.fullPath, root: ctx.root) {
            return .skipped("already inside the Master Archive")
        }
        // ---- Idempotency by SOURCE IDENTITY (manifest leg): a row without
        // a catalog record = crash after manifest append. Adopt, never recopy.
        if let row = ctx.manifestRows[source.id] {
            return await adoptFromManifest(row: row, source: source, entry: entry, model: model, ctx: ctx)
        }
        guard FileManager.default.fileExists(atPath: source.fullPath) else {
            return .failed("source file missing on disk")
        }
        do {
            return try await copyOrAdopt(source: source, entry: entry, model: model, ctx: ctx, bytesDone: bytesDone)
        } catch is CancellationError {
            return .cancelled
        } catch ArchivePromoteEngine.Failure.cancelled {
            return .cancelled
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Manifest-leg adoption: the manifest names this source; verify the
    /// file it points at against the recorded digest, then link it.
    private func adoptFromManifest(row: (relPath: String, sha256: String),
                                   source: VideoRecord,
                                   entry: ArchivePromotePlan.Entry,
                                   model: VideoScanModel,
                                   ctx: RunContext) async -> FileResult {
        // Containment FIRST (codex R4-A): the manifest relpath is data from
        // disk. Non-contained / symlinked ⇒ refused, never read or adopted.
        guard ArchivePromoteEngine.isContainedRelPath(row.relPath, root: ctx.root) else {
            appLog.write("promote: manifest row for \(entry.filename) points outside the archive root (\(row.relPath)) — ignored")
            return .failed("the manifest row for this file points outside the archive root (\(row.relPath)) — refused; check the manifest by hand")
        }
        let dest = URL(fileURLWithPath: ctx.root, isDirectory: true)
            .appendingPathComponent(row.relPath).standardizedFileURL
        do {
            guard let actual = try await Self.hashContainedOffMain(root: ctx.root, relPath: row.relPath) else {
                appLog.write("promote reconcile: manifest lists \(entry.filename) at \(row.relPath) but the file is missing — skipped; check the archive by hand")
                return .skipped("the manifest already lists this file at \(row.relPath) but it is missing from the archive — check by hand")
            }
            guard actual == row.sha256 else {
                return .failed("manifest lists \(row.relPath) but the file there does not match the recorded digest — refused")
            }
            try await finishPublished(sourceID: source.id, source: source, sourcePath: source.fullPath,
                                      relPath: row.relPath, destURL: dest, sha: actual,
                                      model: model, ctx: ctx, journalBase: nil)
            return .adopted(relPath: row.relPath)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Fresh promotion: choose the destination (adopting an identical
    /// existing file when there is one), journal intent, copy+verify+
    /// publish off-main, journal renamed, then the manifest + catalog tail.
    private func copyOrAdopt(source: VideoRecord,
                             entry: ArchivePromotePlan.Entry,
                             model: VideoScanModel,
                             ctx: RunContext,
                             bytesDone: Int64) async throws -> FileResult {
        let facts = ArchivePathResolver.facts(for: source)
        let choice = try await Self.chooseDestinationOffMain(
            facts: facts, root: ctx.root, sourcePath: source.fullPath,
            sourceSize: source.sizeBytes, claimed: claimedNames)
        let destURL = URL(fileURLWithPath: ctx.root, isDirectory: true)
            .appendingPathComponent(choice.relPath).standardizedFileURL
        guard ArchivePathResolver.isInside(path: destURL.path, root: ctx.root) else {
            return .failed("resolved destination escapes the archive root (\(choice.relPath)) — refused")
        }
        claimedNames.insert(destURL.path)

        let sha: String
        var journalEntry = ArchivePromoteJournal.Entry(
            sourceRecordID: source.id, sourcePath: source.fullPath,
            destRelPath: choice.relPath,
            state: choice.identicalExistingSHA == nil ? .intent : .renamed,
            sha256: choice.identicalExistingSHA, copyRecordID: nil, at: Date())
        // Intent (or, for an adoption, "already published") BEFORE any
        // byte moves — the convergence contract. A journal that cannot be
        // written durably stops the file here.
        try ArchivePromoteJournal.append(journalEntry, rootPath: ctx.root)

        if let existingSHA = choice.identicalExistingSHA {
            sha = existingSHA
        } else {
            let totalBytes = max(1, plan.totalBytes)
            let progress: @Sendable (Int64) -> Void = { [weak self] copied in
                Task { @MainActor [weak self] in
                    self?.applyProgress(Double(bytesDone + copied) / Double(totalBytes))
                }
            }
            let published = try await Self.copyOffMain(sourcePath: source.fullPath,
                                                       root: ctx.root,
                                                       relPath: choice.relPath,
                                                       progress: progress)
            sha = published.sha256
            journalEntry = journalEntry.with(state: .renamed, sha256: sha)
            try ArchivePromoteJournal.append(journalEntry, rootPath: ctx.root)
        }
        if Task.isCancelled { return .cancelled }

        try await finishPublished(sourceID: source.id, source: source, sourcePath: source.fullPath,
                                  relPath: choice.relPath, destURL: destURL, sha: sha,
                                  model: model, ctx: ctx, journalBase: journalEntry)
        model.log("Promote: \(entry.filename) → \(choice.relPath) (sha256 \(sha.prefix(12))…) ✓")
        promoteLog.info("promoted \(entry.filename, privacy: .public) → \(choice.relPath, privacy: .public)")
        return choice.identicalExistingSHA == nil ? .promoted(relPath: choice.relPath)
                                                  : .adopted(relPath: choice.relPath)
    }

    // MARK: Manifest + catalog tail (shared by promote / adopt / reconcile)

    /// After the file is verified and in place: probe it, append the
    /// manifest row (unless the manifest already has one for this source)
    /// + F_FULLFSYNC, journal `published`, then create the catalog link —
    /// linked to the source when it still exists, SELF-CONTAINED from
    /// journal/manifest provenance when it does not (codex R3 major 7).
    /// The link is only in memory + a debounced save at this point: the
    /// journal advances to `done` at batch end, after `saveCatalogNow()`
    /// returns true (codex R3 blocker 5).
    func finishPublished(sourceID: UUID,
                         source: VideoRecord?,
                         sourcePath: String,
                         relPath: String,
                         destURL: URL,
                         sha: String,
                         model: VideoScanModel,
                         ctx: RunContext,
                         journalBase: ArchivePromoteJournal.Entry?) async throws {
        // The catalog record's id: when the manifest already names this
        // copy, REUSE its record_id so manifest ↔ catalog join on one id
        // (codex R5 major 5); a fresh id only for a brand-new row. A
        // manifest id already present in the catalog (or malformed) falls
        // back to fresh — never a duplicate id.
        let copyID = Self.recordID(fromManifestFields: ctx.manifestFields[sourceID], model: model)
        let outcome = await model.probeFileOutcome(url: destURL)
        let copyProbe = VideoRecord(id: copyID)
        copyProbe.apply(outcome)
        let now = Date()
        var journal = journalBase ?? ArchivePromoteJournal.Entry(
            sourceRecordID: sourceID, sourcePath: sourcePath, destRelPath: relPath,
            state: .renamed, sha256: sha, copyRecordID: nil, at: now)

        if ctx.manifestRows[sourceID] == nil {
            var recordDate = "", dateConfidence = "", people: [String] = []
            if let source {
                let facts = ArchivePathResolver.facts(for: source)
                recordDate = facts.dateHint.manifestDate
                dateConfidence = Self.dateConfidenceLabel(source: source, facts: facts)
                people = Self.peopleForManifest(source)
            }
            let row = ArchiveManifestCSV.Row(
                promotedAt: now,
                archiveRelPath: relPath,
                sha256: sha,
                sizeBytes: copyProbe.sizeBytes,
                originalPath: sourcePath,
                originalVolume: source?.volumeName ?? VolumeReachability.volumeName(forPath: sourcePath),
                recordID: copyProbe.id,
                sourceRecordID: sourceID,
                recordDate: recordDate,
                dateConfidence: dateConfidence,
                people: people,
                starRating: max(source?.starRating ?? 0, 3))
            // Manifest row + F_FULLFSYNC — a barrier failure throws and the
            // file is reported failed (it stays in place; the journal's
            // `renamed` entry converges it next run).
            try ArchiveManifestCSV.append(row, rootPath: ctx.root)
        }
        journal = journal.with(state: .published, sha256: sha, copyRecordID: copyProbe.id)
        try ArchivePromoteJournal.append(journal, rootPath: ctx.root)

        if let source {
            model.registerPromotedCopy(source: source, destinationURL: destURL,
                                       relativePath: relPath, sha256: sha,
                                       probed: copyProbe, promotedAt: now)
        } else {
            model.registerOrphanPromotedCopy(sourceID: sourceID, sourcePath: sourcePath,
                                             destinationURL: destURL, relativePath: relPath,
                                             sha256: sha, probed: copyProbe,
                                             manifestRow: ctx.manifestFields[sourceID],
                                             promotedAt: now)
            appLog.write("promote: \(relPath) cataloged as a self-contained archive copy — its source record (\(sourceID.uuidString.prefix(8))…) is no longer in the catalog")
        }
        publishedThisBatch.append(journal)
    }

    /// Batch end (codex R3 blocker 5): ONE synchronous, durable catalog
    /// save; only if it lands do the batch's `published` entries advance
    /// to `done`. A refused/failed save leaves them `published` — the next
    /// run's reconcile re-links from manifest/journal provenance, never
    /// trusting an in-memory link that may not have been persisted.
    func finalizeBatch(model: VideoScanModel, ctx: RunContext) -> Bool {
        guard !publishedThisBatch.isEmpty else { return true }
        let saved = model.saveCatalogNow()
        if saved {
            for entry in publishedThisBatch {
                try? ArchivePromoteJournal.append(entry.with(state: .done), rootPath: ctx.root)
            }
            promoteLog.info("promote: catalog saved durably — \(self.publishedThisBatch.count) journal entr(ies) marked done")
        } else {
            promoteLog.error("promote: catalog save did not land — \(self.publishedThisBatch.count) entr(ies) stay 'published' for reconcile")
            appLog.write("promote: the catalog could not be saved right now — \(publishedThisBatch.count) promotion(s) are on disk and in the manifest; the catalog links will be re-established on the next promotion run")
        }
        publishedThisBatch.removeAll()
        return saved
    }

    // MARK: Off-main hops
    //
    // `@concurrent` (Approachable Concurrency): a `nonisolated async` on
    // this repo runs on the CALLER's actor — without the attribute the
    // whole multi-GB copy would run ON MAIN.

    struct DestinationChoice: Sendable, Equatable {
        let relPath: String
        /// Non-nil when an existing file at `relPath` holds exactly the
        /// source's bytes — adopt it instead of copying.
        let identicalExistingSHA: String?
    }

    /// Base name first; on a collision compare the existing file's bytes
    /// with the source (adopt if identical); otherwise the first free
    /// `_NN`. Names claimed by this batch and in-flight `.partial`s count
    /// as taken. The source is hashed at most ONCE (lazily, only if a
    /// same-size collision needs it).
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func chooseDestinationOffMain(facts: ArchivePathResolver.RecordFacts,
                                         root: String,
                                         sourcePath: String,
                                         sourceSize: Int64,
                                         claimed: Set<String>) async throws -> DestinationChoice {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let base = ArchivePathResolver.baseRelativePath(facts: facts)
        let ext = (base as NSString).pathExtension
        let stemPath = (base as NSString).deletingPathExtension
        var cachedSourceSHA: String?
        func sourceSHA() throws -> String? {
            if let cachedSourceSHA { return cachedSourceSHA }
            let s = try ArchivePromoteEngine.sha256(path: sourcePath, shouldCancel: { Task.isCancelled })
            cachedSourceSHA = s
            return s
        }
        var n = 1
        while n <= 9_999 {
            let candidate: String
            if n == 1 {
                candidate = base
            } else {
                candidate = ext.isEmpty
                    ? String(format: "%@_%02d", stemPath, n)
                    : String(format: "%@_%02d.%@", stemPath, n, ext)
            }
            n += 1
            let path = rootURL.appendingPathComponent(candidate).standardizedFileURL.path
            if Task.isCancelled { throw CancellationError() }
            if claimed.contains(path) { continue }
            // Existence + identity THROUGH the dirfd O_NOFOLLOW chain (codex
            // R5 blocker 2): a symlinked intermediate throws here (refused,
            // never adopted); an in-flight partial counts as taken.
            if let pfd = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: candidate + ".partial") {
                Darwin.close(pfd)
                continue
            }
            if let fd = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: candidate) {
                defer { Darwin.close(fd) }
                if let sha = try ArchivePromoteEngine.identicalDigest(
                    fd: fd, sourceSize: sourceSize,
                    sourceSHA: sourceSHA, shouldCancel: { Task.isCancelled }) {
                    return DestinationChoice(relPath: candidate, identicalExistingSHA: sha)
                }
                continue
            }
            return DestinationChoice(relPath: candidate, identicalExistingSHA: nil)
        }
        throw PromoteError(message: "could not find a free archive name for \(base) after 9,999 tries")
    }

    /// The manifest's `record_id` for this source when it is a well-formed
    /// UUID not already used by any catalog record; otherwise a fresh id.
    static func recordID(fromManifestFields fields: [String]?, model: VideoScanModel) -> UUID {
        guard let fields, fields.count >= 12, let id = UUID(uuidString: fields[6]),
              model.record(forID: id) == nil else { return UUID() }
        return id
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    static func copyOffMain(sourcePath: String,
                            root: String,
                            relPath: String,
                            progress: @escaping @Sendable (Int64) -> Void) async throws -> ArchivePromoteEngine.PublishResult {
        let source = try ArchivePromoteEngine.openSource(path: sourcePath)
        defer { source.close() }
        return try ArchivePromoteEngine.copyVerifyPublish(
            source: source, root: root, relativePath: relPath,
            progress: progress, shouldCancel: { Task.isCancelled })
    }

    /// Digest of an archive-relative file resolved through the dirfd
    /// O_NOFOLLOW chain; nil ⇒ absent; throws for non-contained / symlink.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func hashContainedOffMain(root: String, relPath: String) async throws -> String? {
        try ArchivePromoteEngine.sha256(root: root, relativePath: relPath, shouldCancel: { Task.isCancelled })
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    static func hashOffMain(path: String) async throws -> String? {
        try ArchivePromoteEngine.sha256(path: path, shouldCancel: { Task.isCancelled })
    }

    // MARK: Pure helpers

    static func describe(_ error: Error) -> String {
        if let e = error as? PromoteError { return e.message }
        if let e = error as? ArchivePromoteEngine.Failure { return e.description }
        if let e = error as? ArchiveManifestCSV.ManifestError { return e.description }
        return String(describing: error)
    }

    /// The manifest's `date_confidence` column: "user-known" /
    /// "user-estimated" / "inferred 0.87" / "low 0.41" / "".
    static func dateConfidenceLabel(source: VideoRecord,
                                    facts: ArchivePathResolver.RecordFacts) -> String {
        if source.userDate != nil {
            return source.userDateStatus == .known ? "user-known" : "user-estimated"
        }
        if let conf = source.inferredDateConfidence, source.inferredRecordDate != nil {
            let tag = facts.dateIsLowConfidence ? "low" : "inferred"
            return String(format: "%@ %.2f", tag, conf)
        }
        return ""
    }

    /// Confirmed people first, then detected — the manifest's `people`
    /// column (deduped, order-preserving).
    static func peopleForManifest(_ source: VideoRecord) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in source.confirmedByUserPeople.map(\.name) + source.detectedPeople {
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }
}

extension ArchivePromoteJournal.Entry {
    /// Same source/dest, new state (and optionally digest / copy id).
    func with(state: State, sha256: String? = nil, copyRecordID: UUID? = nil) -> ArchivePromoteJournal.Entry {
        ArchivePromoteJournal.Entry(sourceRecordID: sourceRecordID,
                                    sourcePath: sourcePath,
                                    destRelPath: destRelPath,
                                    state: state,
                                    sha256: sha256 ?? self.sha256,
                                    copyRecordID: copyRecordID ?? self.copyRecordID,
                                    at: Date())
    }
}
