import Foundation

extension VideoScanModel {

    // MARK: - Delete Confirmed Junk
    //
    // The ONE "move files to the Trash" routine behind Delete Junk (Triage),
    // the Catalog row's Move to Trash, ⌘⌫ and the prune / Excess lanes. The
    // caller hands us records; we go to disk and trash each file, then
    // soft-delete the catalog record so the row stops cluttering the default
    // view. The record itself is preserved with a deletion timestamp
    // (`purgedAt`) so the user can still see WHAT left even though the file
    // is gone.
    //
    // Policy (decided 2026-05-25, amended 2026-10-09):
    //  - No backup check, no dup check. The user already promoted these to
    //    .confirmedJunk; second-guessing them is paternalistic, and the
    //    dup-check belongs to a different feature. (Keeper proof is the
    //    DUPLICATE path's job — design R4.)
    //  - Trash only (ruling 2026-10-09, R3), as an EXECUTION rule (codex
    //    delete-engines F1): this routine contains no permanent removal of
    //    its own. `.toTrash` is the only mode the app can spell; the one
    //    other mode, `.removeThroughTestSeam(op)`, removes through the
    //    operation the CALLER injects — the test target's `.permanent` is
    //    that seam (its fixtures stay out of the real Trash). No production
    //    source builds it — JunkPermanentUnreachableTests pins that.
    //  - "Already missing" is not an error. If the file vanished between
    //    tagging and the delete pass we still update the catalog record so
    //    the row reads consistently afterward.
    //  - "Skipped offline" is a DIFFERENT bucket. If the volume containing
    //    the file isn't currently mounted we do NOT touch the record at
    //    all; the user remounts and runs the workflow again.
    //  - Per-record errors are collected and reported, not thrown. One
    //    permission-denied file does NOT abort the batch.
    //
    // `fullPath` is intentionally NOT cleared on the record — the user may
    // want to remember where a file lived months later.
    //
    // Threading (2026-05-26, per-file since 2026-10-09):
    //  - Each file gets one TURN. The catalog half of the turn runs on the
    //    main actor (VideoRecord lives there): offline check, the caller's
    //    `authorize`, a fresh read-only snapshot — asked for THIS file, at
    //    its turn, never once for the batch (codex design F1). The disk half
    //    runs on `Task.detached` (≈ a C++ worker thread you then join with
    //    `await …value`): the caller's `beforeRemoval`, the archive and
    //    read-only last words, existence, the Trash — one synchronous
    //    stretch with no await inside it.
    //  - The main thread is only suspended (never blocked) while a file's
    //    disk half runs, so the UI stays responsive.
    //  - Catalog writes for the whole batch happen at the end, once, on main.

    /// How a file leaves. `.toTrash` is the only mode the app can reach
    /// (ruling 2026-10-09). `.removeThroughTestSeam(op)` hands the file to
    /// `op` and records it as removed outright — TESTS ONLY: the engine has
    /// no removal of its own to fall back to, so without an injected
    /// operation nothing but the Trash can happen. (For Rick: an enum case
    /// carrying a closure ≈ a C++ std::variant holding a std::function.)
    enum JunkDeletionMode: Sendable {
        case toTrash
        case removeThroughTestSeam(@Sendable (URL) throws -> Void)

        /// True for the test seam: the catalog and ledger record the file
        /// as removed outright (`.deletedPermanently`, `copyDeleted`).
        var isOutrightRemoval: Bool {
            if case .removeThroughTestSeam = self { return true }
            return false
        }
    }

    /// Outcome of a batch: ONE item per requested record, in request
    /// order, each with exactly one outcome (design R6/R7: requested ==
    /// moved + held + failed + missing + offline + cancelled). The counts
    /// the sheets and the prune lane read are derived from the items, so
    /// they cannot disagree with them.
    struct JunkDeletionResult {
        struct Item {
            let record: VideoRecord
            let outcome: JunkFileOutcome
        }
        let items: [Item]

        init(items: [Item]) { self.items = items }
        /// Computed, not a stored static: the result holds `VideoRecord`
        /// references, which are not Sendable, so a shared global would not
        /// be concurrency-safe.
        static var empty: JunkDeletionResult { JunkDeletionResult(items: []) }

        /// Every record that was requested (each has one outcome).
        var attempted: Int { items.count }
        /// Files actually moved this pass.
        var succeeded: Int { items.count { $0.outcome.isMoved } }
        /// The SUM of the moved files' sizes — bytes moved to the Trash
        /// (design R7). Never "freed": space comes back when the Trash is
        /// emptied.
        var bytesMoved: Int64 {
            items.reduce(into: Int64(0)) { sum, item in
                if case .moved(let bytes) = item.outcome { sum += bytes }
            }
        }
        /// The file was already gone (its drive WAS reachable) — the catalog
        /// was updated (purgedAt + lifecycleStage), no disk op.
        var alreadyMissing: Int { items.count { $0.outcome.kind == .missing } }
        /// Its drive isn't mounted. Untouched — retry after remounting.
        var skippedOffline: Int { items.count { $0.outcome.kind == .offline } }
        /// Not reached: the run was stopped before this file's turn.
        var cancelled: Int { items.count { $0.outcome.kind == .cancelled } }
        /// The file operation itself failed (the file is where it was).
        var failed: [(record: VideoRecord, error: Error)] {
            items.compactMap { item in
                guard case .failed(let error) = item.outcome else { return nil }
                return (record: item.record, error: error)
            }
        }
        /// Held back — before any disk work (viewer, Master Archive, a drive
        /// marked Read only) or at the file's turn (a caller's guard, the
        /// archive / read-only last word). Nothing moved; record untouched.
        var refused: [(record: VideoRecord, reason: String)] {
            items.compactMap { item in
                guard case .held(let why) = item.outcome else { return nil }
                return (record: item.record, reason: why)
            }
        }
    }

    /// A per-file guard for a caller that PROVED something about a file
    /// before asking for its removal (the frozen Delete Junk snapshot; the
    /// "Archived — what next?" byte proof). A verdict from moments ago is
    /// not authority to remove whatever sits at that pathname NOW, so the
    /// proof is re-checked twice per file, as late as possible:
    ///   - `authorize` — on the main actor, at THAT file's turn: the LIVE
    ///     catalog still says what the caller verified.
    ///   - `beforeRemoval` — off-main, immediately before THAT file's own
    ///     trashItem, with its path: the file still reproduces the proof's
    ///     identity.
    /// Either returning a reason refuses the file: it is reported in
    /// `JunkDeletionResult.refused`, named, and nothing is moved. The guard
    /// runs before the existence check, so a guard decides what a vanished
    /// file means (return nil → "already missing").
    /// (For Rick: two callbacks, one per thread the routine runs on.)
    struct JunkDeletionGuard {
        let authorize: @MainActor (VideoRecord) -> String?
        let beforeRemoval: @Sendable (String) -> String?
        /// The file operation itself, for tests (a seam that throws on the
        /// Nth file, or moves into a sandbox "Trash"). nil = FileManager's
        /// trashItem, which is what every production caller gets.
        var remove: (@Sendable (URL) throws -> Void)? = nil
    }

    /// One file's outcome — mutually exclusive by construction (one enum
    /// value per file; ≈ a C++ std::variant).
    enum JunkFileOutcome: Sendable {
        /// Moved; `bytes` = the file's size measured at its turn, just
        /// before the move (the catalog's size if it could not be stat'ed).
        case moved(bytes: Int64)
        case held(String)
        case failed(any Error)
        case missing
        case offline
        /// The run was stopped (task cancelled) before this file's turn.
        case cancelled

        /// The case without its payload, for counting and grouping.
        enum Kind: Equatable { case moved, held, failed, missing, offline, cancelled }
        var kind: Kind {
            switch self {
            case .moved: return .moved
            case .held: return .held
            case .failed: return .failed
            case .missing: return .missing
            case .offline: return .offline
            case .cancelled: return .cancelled
            }
        }
        var isMoved: Bool { kind == .moved }
    }

    /// C04-F5 (P1, 2026-10-06): a viewer Mac never moves or deletes a file.
    /// Either signal refuses on its own: the model flag VideoScanApp sets
    /// from CatalogSync (`isReadOnly`), or the process-wide
    /// ViewerModeCenter (which also records the refusal for the sensor).
    /// Returns nil on the master. On a viewer nothing is touched, every
    /// record comes back in `refused`, and one line is logged. It is the
    /// first step of `junkDeletionPreflight`, which is the first statement
    /// of `deleteConfirmedJunk`, so every caller sits behind it.
    func junkDeletionRefusedOnViewer(_ records: [VideoRecord]) -> JunkDeletionResult? {
        let viewer = ViewerWriteGuard.refuse("VideoScanModel.deleteConfirmedJunk")
        guard viewer || isReadOnly else { return nil }
        let reason = "this Mac is a read-only viewer of the catalog"
        log("Delete Confirmed Junk refused — \(reason); \(records.count) file(s) left untouched.")
        return JunkDeletionResult(items: records.map { .init(record: $0, outcome: .held(reason)) })
    }

    /// Everything `deleteConfirmedJunk` decides before any disk work, in
    /// order: (1) the viewer refusal — FIRST, before anything else;
    /// (2) the empty-selection short-circuit; (3) Master Archive files and
    /// drives marked Read only are never bulk-deleted
    /// (excludingMasterArchiveFiles, which also writes the console lines) —
    /// each such file gets a HOLD with the gate's own sentence, never a
    /// silent drop (design R6). A non-nil `finished` is the whole answer;
    /// otherwise `pending[i]` is file i's outcome when it is already
    /// decided, nil when it goes on to its turn.
    func junkDeletionPreflight(_ requested: [VideoRecord])
        -> (pending: [JunkFileOutcome?], finished: JunkDeletionResult?) {
        if let refused = junkDeletionRefusedOnViewer(requested) { return ([], refused) }
        guard !requested.isEmpty else { return ([], .empty) }
        let mayGo = Set(excludingMasterArchiveFiles(requested, verb: "Delete Confirmed Junk").map(ObjectIdentifier.init))
        var pending = [JunkFileOutcome?](repeating: nil, count: requested.count)
        guard mayGo.count < requested.count else { return (pending, nil) }
        let archiveVolume = archiveVolumeProtection()
        let label = archiveVolume?.label ?? "the archive volume"
        for (i, rec) in requested.enumerated() where !mayGo.contains(ObjectIdentifier(rec)) {
            let note = bulkDeleteRefusal(rec, volume: archiveVolume)
                .map { Self.bulkDeleteRefusalNote($0, volume: label) } ?? "is protected by the delete rules"
            pending[i] = .held(note + " — nothing moved")
        }
        return (pending, nil)
    }

    /// Trash every record in `records`, one file at a time, regardless of
    /// their current `mediaDisposition` — the CALLER decides what may go
    /// (the frozen Delete Junk lane re-checks Confirmed status per file
    /// through its guard). All catalog mutations happen in-memory on the
    /// existing `VideoRecord` instances; one `saveCatalogDebounced()` at the
    /// end persists the batch.
    @discardableResult
    func deleteConfirmedJunk(
        _ requested: [VideoRecord],
        mode: JunkDeletionMode,
        guard fileGuard: JunkDeletionGuard? = nil
    ) async -> JunkDeletionResult {
        let (pending, finished) = junkDeletionPreflight(requested)
        if let finished { return finished }

        // The disk half's fixed inputs — all Sendable, so they may cross to
        // the worker. The Master Archive VOLUME is re-asked per file at the
        // moment of removal (Rick 2026-09-22) with a fresh read of the
        // file's own volume UUID; the probe is the task-local seam captured
        // HERE — a detached task does not inherit task-locals.
        let disk = JunkDiskTurn(
            mode: mode,
            archiveVolume: archiveVolumeProtection(),
            uuidProbe: MasterArchiveDesignation.volumeUUIDProbe,
            beforeRemoval: fileGuard?.beforeRemoval,
            remove: fileGuard?.remove)

        var outcomes: [JunkFileOutcome] = []
        outcomes.reserveCapacity(requested.count)
        for (rec, decided) in zip(requested, pending) {
            if let decided {
                outcomes.append(decided)
            } else if Task.isCancelled {
                outcomes.append(.cancelled)
            } else {
                outcomes.append(await junkTurn(rec, guard: fileGuard, disk: disk))
            }
        }
        return applyJunkOutcomes(requested, outcomes, mode: mode)
    }

    /// One file's turn. The catalog half, here on the main actor, as late
    /// as possible (codex design F1: authorization is per FILE, never once
    /// per batch); then the disk half, off-main.
    private func junkTurn(_ rec: VideoRecord, guard fileGuard: JunkDeletionGuard?,
                          disk: JunkDiskTurn) async -> JunkFileOutcome {
        let path = rec.fullPath
        // Offline-volume check: only /Volumes/<X>/... paths can be offline
        // (drive unmounted); internal paths live on the boot volume. The
        // 5 s VolumeReachability cache makes this near-free. The record is
        // NOT stamped: the user remounts and re-runs.
        if Self.isExternalVolumePath(path), !VolumeReachability.isReachable(path: path) {
            return .offline
        }
        // The caller's live-catalog authorization, for THIS file, now.
        if let fileGuard, let why = fileGuard.authorize(rec) {
            return .held(why)
        }
        // The volumes the person marked Read only (2026-10-03), as the model
        // is at THIS file's turn (codex #258 F5): a drive marked Read only
        // while the batch runs protects every file not yet moved.
        let readOnlyVolumes = readOnlyVolumeProtection()
        let catalogBytes = rec.sizeBytes
        return await Task.detached(priority: .userInitiated) {
            disk.run(path: path, readOnlyVolumes: readOnlyVolumes, catalogBytes: catalogBytes)
        }.value
    }

    /// Back on main: stamp the catalog for the files that left (or were
    /// already gone), persist once, write the ledger, log, and count.
    private func applyJunkOutcomes(_ records: [VideoRecord], _ outcomes: [JunkFileOutcome],
                                   mode: JunkDeletionMode) -> JunkDeletionResult {
        let now = Date()
        let stage: LifecycleStage = mode.isOutrightRemoval ? .deletedPermanently : .trashed
        var removedFromDisk: [VideoRecord] = []

        for (rec, outcome) in zip(records, outcomes) {
            switch outcome {
            case .offline, .held, .failed, .cancelled:
                // Untouched: the file is still there (or is not what was
                // verified, or its drive is away); the row stays active so
                // the user can retry or inspect.
                break
            case .missing:
                // Stamped so the row stops showing as active junk; the stage
                // follows the requested mode even though no disk op ran.
                rec.purgedAt = now
                rec.lifecycleStage = stage
            case .moved:
                rec.lifecycleStage = stage
                rec.purgedAt = now
                removedFromDisk.append(rec)
            }
        }
        let result = JunkDeletionResult(items: zip(records, outcomes).map { .init(record: $0, outcome: $1) })

        // Single batched persist (a per-record save would saturate the
        // debouncer and could leave a half-written catalog on a crash).
        saveCatalogDebounced()
        // #160: purgedAt/lifecycleStage flipped in place — no count change —
        // so the table's cache must be told to recompute.
        noteCatalogRecordsMutated()
        // Media Ledger (stage 2): one copyTrashed / copyDeleted line per file
        // that actually left the disk.
        ledgerCopyRemoved(removedFromDisk, permanent: mode.isOutrightRemoval, by: .rick, at: now,
                          batchID: "junk-\(UUID().uuidString.prefix(8))")

        let refused = result.refused.count, cancelled = result.cancelled
        log("Delete Confirmed Junk: attempted=\(result.attempted) succeeded=\(result.succeeded) missing=\(result.alreadyMissing) offline=\(result.skippedOffline) failed=\(result.failed.count)\(refused == 0 ? "" : " refused=\(refused)")\(cancelled == 0 ? "" : " cancelled=\(cancelled)") mode=\(mode.isOutrightRemoval ? "permanent" : "trash")")
        return result
    }

    /// Convenience filter: every active (non-purged) record currently
    /// tagged `.confirmedJunk`.
    ///
    /// We deliberately exclude purged records — once `purgedAt` is set the
    /// row is hidden by default and the file is already gone or trashed.
    var confirmedJunkRecords: [VideoRecord] {
        records.filter {
            $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
        }
    }

    /// Reachability-split view over a record list (currently-actionable rows
    /// vs. rows whose volume isn't mounted).
    struct ConfirmedJunkSplit {
        let reachable: [VideoRecord]
        let offline: [VideoRecord]
        var reachableBytes: Int64 {
            reachable.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        }
        var offlineBytes: Int64 {
            offline.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        }
    }

    /// Split an arbitrary record list by current volume reachability.
    /// Mirrors the predicate in `deleteConfirmedJunk`: only paths under
    /// `/Volumes/<X>/...` are eligible to be "offline".
    static func splitByReachability(
        _ records: [VideoRecord]
    ) -> ConfirmedJunkSplit {
        var reachable: [VideoRecord] = []
        var offline: [VideoRecord] = []
        reachable.reserveCapacity(records.count)
        for r in records {
            if isExternalVolumePath(r.fullPath),
               !VolumeReachability.isReachable(path: r.fullPath) {
                offline.append(r)
            } else {
                reachable.append(r)
            }
        }
        return ConfirmedJunkSplit(reachable: reachable, offline: offline)
    }

    /// True iff `path` is under "/Volumes/<volumeName>/..." — i.e. lives
    /// on a removable/external mount that could be ejected.
    /// Static + nonisolated so callers in any context can use it.
    nonisolated static func isExternalVolumePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let comps = (path as NSString).pathComponents
        // ["/", "Volumes", "<name>", ...] → length ≥ 3, comps[1] == "Volumes".
        return comps.count >= 3 && comps[1] == "Volumes"
    }
}

// MARK: - The disk half of one file's turn

/// Everything the off-main half of a turn needs, as one Sendable value
/// (≈ a C++ struct of value members handed to a worker thread by copy). No
/// `VideoRecord` crosses: only the path does.
struct JunkDiskTurn: Sendable {
    let mode: VideoScanModel.JunkDeletionMode
    let archiveVolume: ArchiveVolumeProtection?
    let uuidProbe: @Sendable (String) -> String?
    let beforeRemoval: (@Sendable (String) -> String?)?
    let remove: (@Sendable (URL) throws -> Void)?

    /// The caller's proof, the archive and read-only last words, existence,
    /// then the file operation — one synchronous stretch, nothing awaited.
    func run(path: String, readOnlyVolumes: ReadOnlyVolumeProtection,
             catalogBytes: Int64) -> VideoScanModel.JunkFileOutcome {
        // Before the existence check on purpose: the guard decides what a
        // vanished file means.
        if let beforeRemoval, let why = beforeRemoval(path) { return .held(why) }
        if let why = protectionRefusal(path: path, readOnlyVolumes: readOnlyVolumes) { return .held(why) }
        // Distinguishes "the user tagged a file that's already gone" from a
        // genuine failure for the result sheet.
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return .missing }
        // The size that is about to move (one stat), for "N GB moved to
        // the Trash" (design R7).
        let bytes = FileIdentityStamp.capture(path: path)?.size ?? catalogBytes
        do {
            try perform(URL(fileURLWithPath: path))
            return .moved(bytes: bytes)
        } catch {
            // Never a fallback to another kind of removal: the file stays.
            return .failed(error)
        }
    }

    /// The archive volume's and the read-only drives' last word, asked in
    /// the same synchronous stretch as the removal.
    private func protectionRefusal(path: String, readOnlyVolumes: ReadOnlyVolumeProtection) -> String? {
        if let archiveVolume {
            switch archiveVolume.verdictAtRemoval(path: path, probe: uuidProbe) {
            case .clear: break
            case .onArchiveVolume:
                return VideoScanModel.bulkDeleteRefusalNote(.archiveVolume, volume: archiveVolume.label) + " — nothing moved"
            case .unprovable:
                return VideoScanModel.bulkDeleteRefusalNote(.archiveVolumeUnprovable, volume: archiveVolume.label) + " — nothing moved"
            }
        }
        if let verdict = readOnlyVolumes.verdictAtRemoval(path: path, probe: uuidProbe) {
            return VideoScanModel.readOnlyRefusalNote(verdict) + " — nothing moved"
        }
        return nil
    }

    private func perform(_ url: URL) throws {
        if let remove {
            try remove(url)
            return
        }
        switch mode {
        case .toTrash:
            // trashItem moves to the volume's .Trashes; a volume with no
            // Trash (some network mounts) throws — caught by the caller.
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
        case .removeThroughTestSeam(let operation):
            // The caller's operation — never one of this routine's own.
            try operation(url)
        }
    }
}
