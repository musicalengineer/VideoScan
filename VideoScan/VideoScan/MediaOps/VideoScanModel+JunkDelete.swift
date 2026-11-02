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
        /// The lane's per-run receipt (G2), once written; nil from the bare
        /// engine.
        var receipt: URL?
        /// Lines a door adds about groups of files (⌘⌫'s recovered A/V
        /// pairs: how many moved whole, and any SPLIT pair with where each
        /// half is). Shown in the result alert; empty from the bare engine.
        var groupNotes: [String] = []
        /// A group note the person must see even when every file moved (a
        /// SPLIT, a change during the move) — the alert is never skipped.
        var groupNeedsAttention = false
        /// Rows whose marker another action changed while their file moved:
        /// kept as that action set it, not overwritten (Codex #202 F2).
        var markerKept: Set<UUID> = []
        /// One sentence per such row, for every door's result alert (Codex
        /// #204): "<file> kept another action's marker (…) — it is in the
        /// Trash at <path>".
        var keptMarkerNotes: [String] = []

        /// This result's settlement warnings carried onto `other` (the
        /// result transforms keep them — Codex #204).
        func carryingWarnings(to other: JunkDeletionResult) -> JunkDeletionResult {
            var r = other
            r.markerKept = markerKept
            r.keptMarkerNotes = keptMarkerNotes
            r.groupNotes = groupNotes
            r.groupNeedsAttention = groupNeedsAttention
            return r
        }

        init(items: [Item], receipt: URL? = nil) {
            self.items = items
            self.receipt = receipt
        }
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
                if case .moved(let bytes, _) = item.outcome { sum += bytes }
            }
        }
        /// The file was already gone (its drive WAS reachable) — the row is
        /// marked missing (removal marker), no disk op.
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
        /// Told each file's outcome the moment it is decided (G2: the audit
        /// writes its line and receipt row as the run goes).
        var settled: (@MainActor (VideoRecord, JunkFileOutcome) -> Void)? = nil
        /// Rick's per-run tick box (2026-10-12, Cleanup design option b:
        /// "Include these N marked-junk files from FamilyArchive"). The
        /// records listed here may leave although they live ELSEWHERE ON the
        /// Master Archive volume — that one refusal (`.archiveVolume`) is
        /// waived, asked at every gate the same way. Nothing else is: the
        /// archive TREE, an unprovable drive, a drive marked Read only and
        /// every other check still hold. Empty (the default) for every door
        /// but Cleanup's junk lane.
        var archiveVolumeJunkWaiver: Set<UUID> = []
        /// Extra ledger detail for one file that left the disk (⌘⌫ names
        /// the recovered A/V pair a half moved with). nil = none.
        var ledgerDetail: (@MainActor (VideoRecord) -> [String: String])? = nil
        /// Files that leave TOGETHER or not at all (⌘⌫'s recovered A/V
        /// pairs): each unit is its members' ids, in order, contiguous in
        /// the request. A unit is ONE turn (`junkUnitTurn`): every member's
        /// real gate and real reservation first, then the moves. Empty for
        /// every other door.
        var units: [[UUID]] = []
        /// The words for a member held because ANOTHER member of its unit
        /// was refused (given that member's name and reason).
        var unitHeldNote: @Sendable (String) -> String = JunkDeletionGuard.defaultUnitHeldNote
        nonisolated static let defaultUnitHeldNote: @Sendable (String) -> String = {
            "stays with the files it moves with — \($0) — nothing moved"
        }
        /// Asked off-main immediately before EACH unit member's move (after
        /// the earlier members moved), under its own reservation: nil = move.
        var atTheMove: (@Sendable (String) -> String?)? = nil

        /// True when `refusal` is the one the waiver may lift for `rec`.
        /// Belt and braces: never for a path that runs through an archive
        /// root folder by NAME, even if its spelling hid it from the tree
        /// check ("/var/…" vs "/private/var/…").
        func waives(_ refusal: BulkDeleteRefusal?, for rec: VideoRecord) -> Bool {
            refusal == .archiveVolume && archiveVolumeJunkWaiver.contains(rec.id)
                && !CleanupPathRules.isInArchiveRootFolder(rec.fullPath)
        }
    }

    /// One file's outcome — mutually exclusive by construction (one enum
    /// value per file; ≈ a C++ std::variant).
    enum JunkFileOutcome: Sendable {
        /// Moved; `bytes` = the file's size measured at its turn, just
        /// before the move (the catalog's size if it could not be stat'ed);
        /// `trashPath` = where the Trash put it (G2 — "where did my file
        /// go"); nil through a test seam, which does not say.
        case moved(bytes: Int64, trashPath: String? = nil)
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
    func junkDeletionPreflight(_ requested: [VideoRecord], verb: String = "Delete Confirmed Junk",
                               guard fileGuard: JunkDeletionGuard? = nil)
        -> (pending: [JunkFileOutcome?], finished: JunkDeletionResult?) {
        if let refused = junkDeletionRefusedOnViewer(requested) { return ([], refused) }
        guard !requested.isEmpty else { return ([], .empty) }
        // The tick box's files skip the archive-volume half of the batch
        // gate (and its console line); they still meet every other gate.
        let waived = archiveVolumeJunkWaived(requested, guard: fileGuard)
        var mayGo = Set(excludingMasterArchiveFiles(requested.filter { !waived.contains(ObjectIdentifier($0)) },
                                                    verb: verb).map(ObjectIdentifier.init))
        mayGo.formUnion(waived)
        var pending = [JunkFileOutcome?](repeating: nil, count: requested.count)
        guard mayGo.count < requested.count else { return (pending, nil) }
        let archiveVolume = archiveVolumeProtection()
        let label = archiveVolume?.label ?? "the archive volume"
        for (i, rec) in requested.enumerated() where !mayGo.contains(ObjectIdentifier(rec)) {
            let note = bulkDeleteRefusal(rec, volume: archiveVolume)
                .map { heldNote(rec, refusal: $0, label: label, guard: fileGuard) } ?? "is protected by the delete rules"
            pending[i] = .held(note + " — nothing moved")
        }
        return (pending, nil)
    }

    /// The words a held file gets. A file on the tick box's list that stays
    /// only because its drive is ALSO marked Read only is told THAT (the
    /// gate answers the archive half first, which would otherwise hide the
    /// mark); every other refusal keeps the gate's own words.
    private func heldNote(_ rec: VideoRecord, refusal: BulkDeleteRefusal, label: String,
                          guard fileGuard: JunkDeletionGuard?) -> String {
        if fileGuard?.waives(refusal, for: rec) == true,
           let readOnly = readOnlyVolumeRefusal(forPath: rec.fullPath, effect: .removesFiles) {
            return Self.bulkDeleteRefusalNote(readOnly, volume: label)
        }
        return Self.bulkDeleteRefusalNote(refusal, volume: label)
    }

    /// The requested records whose ONLY batch-gate refusal is the one the
    /// guard's FamilyArchive-junk tick box lifts. Empty for every door but
    /// Cleanup's junk lane (no waiver, no snapshot built).
    private func archiveVolumeJunkWaived(_ requested: [VideoRecord],
                                         guard fileGuard: JunkDeletionGuard?) -> Set<ObjectIdentifier> {
        guard let fileGuard, !fileGuard.archiveVolumeJunkWaiver.isEmpty else { return [] }
        let snapshot = archiveVolumeProtection()
        return Set(requested.filter { archiveJunkWaiverApplies($0, refusal: bulkDeleteRefusal($0, volume: snapshot),
                                                               guard: fileGuard) }
            .map(ObjectIdentifier.init))
    }

    /// The waiver lifts `.archiveVolume` for a listed record — and only when
    /// the gate's OTHER half (a drive marked Read only, which the archive
    /// half's refusal would otherwise hide) has nothing to say.
    private func archiveJunkWaiverApplies(_ rec: VideoRecord, refusal: BulkDeleteRefusal?,
                                          guard fileGuard: JunkDeletionGuard?) -> Bool {
        guard let fileGuard, fileGuard.waives(refusal, for: rec) else { return false }
        return readOnlyVolumeRefusal(forPath: rec.fullPath, effect: .removesFiles) == nil
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
        reason: RemovalReason = .junk,
        guard fileGuard: JunkDeletionGuard? = nil
    ) async -> JunkDeletionResult {
        let (pending, finished) = junkDeletionPreflight(requested, verb: reason.doorVerb, guard: fileGuard)
        if let finished { return finished }

        // The disk half's fixed inputs — all Sendable, so they may cross to
        // the worker. The protections are NOT among them: each file's turn
        // reads them afresh (codex delete-engines F3). The probe is the
        // task-local seam captured HERE — a detached task does not inherit
        // task-locals.
        let disk = JunkDiskTurn(
            mode: mode,
            uuidProbe: MasterArchiveDesignation.volumeUUIDProbe,
            beforeRemoval: fileGuard?.beforeRemoval,
            remove: fileGuard?.remove)

        var outcomes: [JunkFileOutcome] = []
        var turns: [JunkTurnIdentity?] = []
        outcomes.reserveCapacity(requested.count)
        turns.reserveCapacity(requested.count)
        let units = JunkTurnUnits(fileGuard?.units ?? [])
        var i = 0
        while i < requested.count {
            let span = units.span(at: i, in: requested)
            let recs = Array(requested[i..<(i + span.count)])
            let decided = Array(pending[i..<(i + span.count)])
            var unitOutcomes: [JunkFileOutcome]
            var unitTurns: [JunkTurnIdentity?] = Array(repeating: nil, count: recs.count)
            if let note = span.broken {
                // A unit member out of place: never moved alone.
                unitOutcomes = decided.map { $0 ?? .held(note) }
            } else if decided.contains(where: { $0 != nil }) {
                unitOutcomes = Self.unitHeld(recs, decided, note: fileGuard?.unitHeldNote)
            } else if Task.isCancelled {
                // Stop acts between turns, and a unit is one turn.
                unitOutcomes = Array(repeating: .cancelled, count: recs.count)
            } else {
                // Who each turn is about, frozen before the disk work (codex
                // round 1 F3): the row may be relinked while it runs.
                unitTurns = recs.map { JunkTurnIdentity($0) }
                unitOutcomes = recs.count == 1 && !span.isUnit
                    ? [await junkTurn(recs[0], guard: fileGuard, disk: disk)]
                    : await junkUnitTurn(recs, guard: fileGuard, disk: disk)
            }
            for (k, rec) in recs.enumerated() {
                outcomes.append(unitOutcomes[k]); turns.append(unitTurns[k])
                // Reported on the record that still describes the file this
                // turn was about (codex round 2 P2), never a row relinked meanwhile.
                fileGuard?.settled?(reportedRecord(rec, turn: unitTurns[k]), unitOutcomes[k])
            }
            i += recs.count
        }
        return applyJunkOutcomes(requested, outcomes, turns: turns, mode: mode, reason: reason,
                                 ledgerDetail: fileGuard?.ledgerDetail)
    }

    /// One file's turn. The catalog half, here on the main actor, as late
    /// as possible (codex design F1: authorization is per FILE, never once
    /// per batch); then the disk half, off-main.
    private func junkTurn(_ rec: VideoRecord, guard fileGuard: JunkDeletionGuard?,
                          disk: JunkDiskTurn) async -> JunkFileOutcome {
        let path = rec.fullPath
        if let offline = junkTurnOfflineRefusal(path) { return offline }
        // The caller's live-catalog authorization, for THIS file, now.
        if let fileGuard, let why = fileGuard.authorize(rec) {
            return .held(why)
        }
        let protections: JunkTurnProtections
        switch junkTurnVerdict(rec, guard: fileGuard) {
        case .refused(let outcome): return outcome
        case .clear(let p): protections = p
        }
        let catalogBytes = rec.sizeBytes
        return await Task.detached(priority: .userInitiated) {
            disk.run(path: path, protections: protections, catalogBytes: catalogBytes)
        }.value
    }

    /// A UNIT's turn (files that leave together or not at all). Phase 1 —
    /// every member's REAL gate, in order: offline, the caller's
    /// authorization, the turn's refusal list (main actor); then, off-main
    /// in one synchronous stretch, every member's REAL reservation at once
    /// (`reserveAll`), its `beforeRemoval` proof (the copy pins), the
    /// archive / Read-only last words and existence. Any refusal anywhere:
    /// nothing moves, every reservation is released, the whole unit is held
    /// with that reason. Phase 2 — only when every member is reserved and
    /// passed: the moves, in order, each re-checked (`atTheMove`) under its
    /// own reservation. A refusal or failure after the first move is the one
    /// honest SPLIT (the caller reports it).
    private func junkUnitTurn(_ recs: [VideoRecord], guard fileGuard: JunkDeletionGuard?,
                              disk: JunkDiskTurn) async -> [JunkFileOutcome] {
        var protections: [JunkTurnProtections] = []
        for (i, rec) in recs.enumerated() {
            var refused: JunkFileOutcome?
            if let offline = junkTurnOfflineRefusal(rec.fullPath) {
                refused = offline
            } else if let fileGuard, let why = fileGuard.authorize(rec) {
                refused = .held(why)
            } else {
                switch junkTurnVerdict(rec, guard: fileGuard) {
                case .refused(let outcome): refused = outcome
                case .clear(let p): protections.append(p)
                }
            }
            if let refused {
                var decided = [JunkFileOutcome?](repeating: nil, count: recs.count)
                decided[i] = refused
                return Self.unitHeld(recs, decided, note: fileGuard?.unitHeldNote)
            }
        }
        let members = recs.map { JunkDiskTurn.Member(path: $0.fullPath, filename: $0.filename, catalogBytes: $0.sizeBytes) }
        let note = fileGuard?.unitHeldNote ?? JunkDeletionGuard.defaultUnitHeldNote
        let atTheMove = fileGuard?.atTheMove
        return await Task.detached(priority: .userInitiated) {
            disk.runUnit(members, protections: protections, heldNote: note, atTheMove: atTheMove)
        }.value
    }

    /// One unit member refused (`decided`): it keeps its outcome, every
    /// other member is held, naming it and why.
    nonisolated static func unitHeld(_ recs: [VideoRecord], _ decided: [JunkFileOutcome?],
                                     note: (@Sendable (String) -> String)?) -> [JunkFileOutcome] {
        let note = note ?? JunkDeletionGuard.defaultUnitHeldNote
        guard let i = decided.firstIndex(where: { $0 != nil }), let first = decided[i] else {
            return recs.map { _ in .held(note("one of them was refused")) }
        }
        let why = "\(recs[i].filename) \(JunkDeletionReport.reason(first) ?? "was refused")"
        return decided.map { $0 ?? .held(note(why)) }
    }

    /// Offline-volume check: only /Volumes/<X>/... paths can be offline
    /// (drive unmounted); internal paths live on the boot volume. The 5 s
    /// VolumeReachability cache makes this near-free. The record is NOT
    /// stamped: the user remounts and re-runs.
    func junkTurnOfflineRefusal(_ path: String) -> JunkFileOutcome? {
        Self.isExternalVolumePath(path) && !VolumeReachability.isReachable(path: path) ? .offline : nil
    }

    /// The turn's catalog-side verdict after the caller's authorization.
    enum JunkTurnVerdict { case refused(JunkFileOutcome), clear(JunkTurnProtections) }

    /// The turn's refusals after authorization, in order — the Master
    /// Archive, the removal-marker save, the drives marked Read only — and,
    /// when none refuses, the protections the disk half asks again.
    func junkTurnVerdict(_ rec: VideoRecord, guard fileGuard: JunkDeletionGuard?) -> JunkTurnVerdict {
        // The Master Archive, as the model is at THIS file's turn (codex
        // delete-engines F3): an archive designated while the batch runs
        // protects every file not yet moved — its tree and its volume here,
        // the file's own volume UUID again in the disk half.
        let archiveVolume = archiveVolumeProtection()
        let refusal = bulkDeleteRefusal(rec, volume: archiveVolume)
        let waived = archiveJunkWaiverApplies(rec, refusal: refusal, guard: fileGuard)
        if let refusal, !waived {
            return .refused(.held(heldNote(rec, refusal: refusal, label: archiveVolume?.label ?? "the archive volume", guard: fileGuard)
                                  + " — nothing moved"))
        }
        // Cutover B2.3: the catalog must be able to record the move — asked
        // HERE, before any disk work, so a held or read-only catalog.sqlite
        // refuses the file instead of leaving it in the Trash with a live row.
        if let why = CatalogMarkerRelay.saveRefusal(for: rec) {
            return .refused(.held(Self.markerRefusal(rec, verb: "move <name> to the Trash", why) + " — nothing moved"))
        }
        // The volumes the person marked Read only (2026-10-03), as the model
        // is at THIS file's turn (codex #258 F5): a drive marked Read only
        // while the batch runs protects every file not yet moved.
        return .clear(JunkTurnProtections(archiveVolume: archiveVolume, readOnlyVolumes: readOnlyVolumeProtection(),
                                          archiveVolumeWaived: waived))
    }

    /// Back on main: stamp the catalog for the files that left (or were
    /// already gone), persist once, write the ledger, log, and count.
    /// The stamp is the one removal marker (GH #143, `stampRemoval`):
    /// moved → inTrash with the Trash path macOS returned; already gone →
    /// missing. Held / failed / offline / cancelled rows are untouched. The
    /// legacy lifecycle mirror is unchanged from before the marker: Trashed
    /// (Deleted through the test seam) for both moved and missing rows.
    private func applyJunkOutcomes(_ records: [VideoRecord], _ outcomes: [JunkFileOutcome],
                                   turns: [JunkTurnIdentity?],
                                   mode: JunkDeletionMode, reason: RemovalReason,
                                   ledgerDetail: (@MainActor (VideoRecord) -> [String: String])? = nil) -> JunkDeletionResult {
        let now = Date()
        let stage: LifecycleStage = mode.isOutrightRemoval ? .deletedPermanently : .trashed
        var removedFromDisk: [VideoRecord] = []
        // Where each moved file went, by row id — the ledger carries it
        // whatever the row's marker says (Codex #203 F1).
        var trashPaths: [UUID: String] = [:]
        var markerKept: Set<UUID> = []
        var keptNotes: [String] = []

        for (i, (rec, outcome)) in zip(records, outcomes).enumerated() {
            guard let marker = Self.removalMarker(for: outcome, outright: mode.isOutrightRemoval,
                                                  reason: reason, at: now) else {
                // Untouched: the file is still there (or is not what was
                // verified, or its drive is away); the row stays active so
                // the user can retry or inspect.
                continue
            }
            let target = settlementTarget(rec, turn: turns[i])
            if outcome.isMoved { removedFromDisk.append(target) }
            if case .moved(_, let landed?) = outcome { trashPaths[target.id] = landed }
            // Detect, then write — never overwrite (Codex #202 F2): a marker
            // another door wrote to this row while its file was moving is
            // kept, and said; the file's move is still a fact (ledger, with
            // its Trash path — Codex #203 F1).
            if let turn = turns[i], target !== turn.snapshot, target.removalRevision != turn.snapshot.removalRevision {
                markerKept.insert(target.id)
                let kept = target.removal.map { "\($0.state.rawValue)" } ?? "live"
                keptNotes.append("\(target.filename) kept another action's marker (\(kept)) — it is in the Trash at "
                                 + "\(trashPaths[target.id] ?? "an unrecorded place"); its catalog row was not overwritten")
                log("  \(target.filename): its catalog row was changed by another action while the file moved to the Trash "
                    + "(the row keeps that action's marker: \(kept)); the file is in the Trash at "
                    + "\(trashPaths[target.id] ?? "an unrecorded place") — the row was not overwritten")
                continue
            }
            // The file already left: a disk fact (B2.3).
            recordFileLeft(target, marker, stage: stage, whereNow: outcome.isMoved ? "is in the Trash" : "was already gone")
        }
        // The items name the file each outcome was about (codex round 2 P2):
        // a row relinked mid-turn is reported through its frozen snapshot.
        var result = JunkDeletionResult(items: zip(records, outcomes).enumerated().map { i, pair in
            .init(record: reportedRecord(pair.0, turn: turns[i]), outcome: pair.1)
        })
        result.markerKept = markerKept
        result.keptMarkerNotes = keptNotes

        // Single batched persist (a per-record save would saturate the
        // debouncer and could leave a half-written catalog on a crash).
        saveCatalogDebounced()
        // #160: purgedAt/lifecycleStage flipped in place — no count change —
        // so the table's cache must be told to recompute.
        noteCatalogRecordsMutated()
        // Media Ledger (stage 2): one copyTrashed / copyDeleted line per file
        // that actually left the disk.
        ledgerCopyRemoved(removedFromDisk, permanent: mode.isOutrightRemoval, by: .rick, at: now,
                          batchID: "junk-\(UUID().uuidString.prefix(8))",
                          detailFor: { rec in
                              var detail = ledgerDetail?(rec) ?? [:]
                              if let landed = trashPaths[rec.id] { detail[MediaLedgerEvent.Detail.trashPath] = landed }
                              return detail
                          })

        let refused = result.refused.count, cancelled = result.cancelled
        log("\(reason.doorVerb): attempted=\(result.attempted) succeeded=\(result.succeeded) missing=\(result.alreadyMissing) offline=\(result.skippedOffline) failed=\(result.failed.count)\(refused == 0 ? "" : " refused=\(refused)")\(cancelled == 0 ? "" : " cancelled=\(cancelled)") mode=\(mode.isOutrightRemoval ? "permanent" : "trash")")
        return result
    }

    /// The row a settled outcome is written to (codex round 1 F3). The
    /// outcome is about the file at the path frozen at its turn: the live row
    /// with that id gets the stamp only if it STILL describes that path.
    /// Relinked or replaced while the disk work ran → the live row is left
    /// exactly as it is and the detached snapshot carries the stamp, so the
    /// ledger and receipt still say what left (the Delete Duplicates rule,
    /// codex 1593 #4).
    private func settlementTarget(_ rec: VideoRecord, turn: JunkTurnIdentity?) -> VideoRecord {
        let target = reportedRecord(rec, turn: turn)
        if let turn, target === turn.snapshot {
            log("  Catalog changed while trashing \(turn.snapshot.filename); the current row is left as it is")
        }
        return target
    }

    /// The record an outcome is REPORTED on — the result item, the guard's
    /// `settled` callback (every lane's audit and receipt read it), and the
    /// stamp: the live row with the turn's id while it still describes the
    /// path frozen at the turn, else the detached snapshot (codex round 2
    /// P2: trash A, repoint the row to B before settlement → the report must
    /// say A). No turn (decided before any disk work) → the row as given.
    private func reportedRecord(_ rec: VideoRecord, turn: JunkTurnIdentity?) -> VideoRecord {
        guard let turn else { return rec }
        let live = record(forID: turn.id) ?? rec
        return live.fullPath == turn.path ? live : turn.snapshot
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

// MARK: - Units: files that leave together or not at all

/// The caller's units, looked up by position in the request. Main actor.
struct JunkTurnUnits {
    struct Span { let count: Int; let isUnit: Bool; let broken: String? }
    private let byID: [UUID: [UUID]]

    init(_ units: [[UUID]]) {
        var map: [UUID: [UUID]] = [:]
        for u in units where !u.isEmpty { for id in u { map[id] = u } }
        byID = map
    }

    /// The turn starting at `i`: a single file, a whole unit (its members
    /// contiguous, in order, from `i`), or a unit member out of place —
    /// held with a reason, never moved alone.
    @MainActor
    func span(at i: Int, in requested: [VideoRecord]) -> Span {
        guard let unit = byID[requested[i].id] else { return Span(count: 1, isUnit: false, broken: nil) }
        let end = i + unit.count
        if unit.first == requested[i].id, end <= requested.count, requested[i..<end].map(\.id) == unit {
            return Span(count: unit.count, isUnit: true, broken: nil)
        }
        return Span(count: 1, isUnit: true,
                    broken: "its files were not handed over together, so it was not moved alone — nothing moved")
    }
}

// MARK: - Who a turn is about

/// The row's id, its path and a detached copy, frozen at the start of a
/// file's turn — before any await (codex round 1 F3). Main actor only.
struct JunkTurnIdentity {
    let id: UUID
    let path: String
    let snapshot: VideoRecord

    @MainActor
    init(_ rec: VideoRecord) {
        id = rec.id
        path = rec.fullPath
        snapshot = rec.snapshotClone()
    }
}

// MARK: - The disk half of one file's turn

/// The protections as the model is at ONE file's turn (codex delete-engines
/// F3: never captured once for the batch): the Master Archive volume and
/// the drives marked Read only.
struct JunkTurnProtections: Sendable {
    let archiveVolume: ArchiveVolumeProtection?
    let readOnlyVolumes: ReadOnlyVolumeProtection
    /// This file is on Rick's per-run FamilyArchive-junk list
    /// (`JunkDeletionGuard.archiveVolumeJunkWaiver`): the disk half's
    /// "on the archive volume" verdict does not hold it. "Unprovable" and
    /// the Read-only marks still do.
    var archiveVolumeWaived = false
}

/// Everything the off-main half of a turn needs, as one Sendable value
/// (≈ a C++ struct of value members handed to a worker thread by copy). No
/// `VideoRecord` crosses: only the path does.
struct JunkDiskTurn: Sendable {
    let mode: VideoScanModel.JunkDeletionMode
    let uuidProbe: @Sendable (String) -> String?
    let beforeRemoval: (@Sendable (String) -> String?)?
    let remove: (@Sendable (URL) throws -> Void)?

    /// One member of a unit, as the worker needs it (Sendable).
    struct Member: Sendable {
        let path: String
        let filename: String
        let catalogBytes: Int64
    }

    /// A unit's disk half — one synchronous stretch, nothing awaited.
    /// Phase 1b: every member reserved at once, then each one's proof, last
    /// words and existence; any refusal → nothing moved, all held. Phase 2:
    /// the moves in order, each re-checked first (`atTheMove`); a refusal or
    /// failure after a move leaves the rest held (the caller's SPLIT).
    /// Every reservation (and the copy pins taken under it) is released when
    /// the stretch ends.
    func runUnit(_ members: [Member], protections: [JunkTurnProtections],
                 heldNote: @Sendable (String) -> String,
                 atTheMove: (@Sendable (String) -> String?)?) -> [VideoScanModel.JunkFileOutcome] {
        func held(_ i: Int, _ outcome: VideoScanModel.JunkFileOutcome) -> [VideoScanModel.JunkFileOutcome] {
            let why = "\(members[i].filename) \(JunkDeletionReport.reason(outcome) ?? "was refused")"
            return members.indices.map { $0 == i ? outcome : .held(heldNote(why)) }
        }
        let keys: [String]
        switch RemovalReservations.shared.reserveAll(members.map(\.path)) {
        case .held(let i, let note): return held(i, .held(note))
        case .reserved(let k): keys = k
        }
        defer { for k in keys { RemovalReservations.shared.release(k) } }
        // Phase 1b: the REAL disk-side gates of every member, nothing moved.
        for (i, m) in members.enumerated() {
            if let beforeRemoval, let why = beforeRemoval(m.path) { return held(i, .held(why)) }
            if let why = protectionRefusal(path: m.path, protections: protections[i]) { return held(i, .held(why)) }
            guard !m.path.isEmpty, FileManager.default.fileExists(atPath: m.path) else {
                return held(i, .held("is not on disk at its path any more — nothing moved"))
            }
        }
        // Phase 2: every member reserved and passed — the moves, in order.
        var out: [VideoScanModel.JunkFileOutcome] = []
        for (i, m) in members.enumerated() {
            var stop: VideoScanModel.JunkFileOutcome?
            if let atTheMove, let why = atTheMove(m.path) {
                stop = .held(why)
            } else {
                let bytes = FileIdentityStamp.capture(path: m.path)?.size ?? m.catalogBytes
                do {
                    out.append(.moved(bytes: bytes, trashPath: try perform(URL(fileURLWithPath: m.path))))
                } catch {
                    // Never a fallback to another kind of removal: the file stays.
                    stop = .failed(error)
                }
            }
            if let stop {
                out.append(stop)
                let why = "\(m.filename) \(JunkDeletionReport.reason(stop) ?? "did not move")"
                out += members[(i + 1)...].map { _ in .held(heldNote(why)) }
                break
            }
        }
        return out
    }

    /// The caller's proof, the archive and read-only last words, existence,
    /// then the file operation — one synchronous stretch, nothing awaited.
    func run(path: String, protections: JunkTurnProtections,
             catalogBytes: Int64) -> VideoScanModel.JunkFileOutcome {
        // Codex #150 F4: the file is reserved for removal from the door's
        // proof through the move, so no other door counts it as the copy
        // that stays meanwhile (RemovalReservations).
        // A file another removal relies on as its surviving copy is held too.
        let reservation: String
        switch RemovalReservations.shared.reserve(path) {
        case .held(let note): return .held(note)
        case .reserved(let key): reservation = key
        }
        defer { RemovalReservations.shared.release(reservation) }
        // Before the existence check on purpose: the guard decides what a
        // vanished file means.
        if let beforeRemoval, let why = beforeRemoval(path) { return .held(why) }
        if let why = protectionRefusal(path: path, protections: protections) { return .held(why) }
        // Distinguishes "the user tagged a file that's already gone" from a
        // genuine failure for the result sheet.
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return .missing }
        // The size that is about to move (one stat), for "N GB moved to
        // the Trash" (design R7).
        let bytes = FileIdentityStamp.capture(path: path)?.size ?? catalogBytes
        do {
            let landed = try perform(URL(fileURLWithPath: path))
            return .moved(bytes: bytes, trashPath: landed)
        } catch {
            // Never a fallback to another kind of removal: the file stays.
            return .failed(error)
        }
    }

    /// The archive volume's and the read-only drives' last word, asked in
    /// the same synchronous stretch as the removal.
    private func protectionRefusal(path: String, protections: JunkTurnProtections) -> String? {
        if let archiveVolume = protections.archiveVolume {
            switch archiveVolume.verdictAtRemoval(path: path, probe: uuidProbe) {
            case .clear: break
            case .onArchiveVolume:
                if protections.archiveVolumeWaived { break }
                return VideoScanModel.bulkDeleteRefusalNote(.archiveVolume, volume: archiveVolume.label) + " — nothing moved"
            case .unprovable:
                return VideoScanModel.archiveVolumeUnprovableNote(archiveVolume) + " — nothing moved"
            }
        }
        if let verdict = protections.readOnlyVolumes.verdictAtRemoval(path: path, probe: uuidProbe) {
            return VideoScanModel.readOnlyRefusalNote(verdict) + " — nothing moved"
        }
        return nil
    }

    /// The file operation; returns where the Trash put the file (nil
    /// through a seam).
    private func perform(_ url: URL) throws -> String? {
        if let remove {
            try remove(url)
            return nil
        }
        switch mode {
        case .toTrash:
            // THE one Trash call (GH #143): the volume's .Trashes; a volume
            // with no Trash (some network mounts) throws — caught by the
            // caller. Its resulting location is KEPT (G2: the receipt and
            // the removal marker say where).
            return try MediaTrash.move(url).path
        case .removeThroughTestSeam(let operation):
            // The caller's operation — never one of this routine's own.
            try operation(url)
            return nil
        }
    }

}
