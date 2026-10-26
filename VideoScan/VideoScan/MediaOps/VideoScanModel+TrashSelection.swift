// VideoScanModel+TrashSelection.swift
// The Catalog's Move to Trash: ⌘⌫ in the table — the Finder gesture — and
// the row menu's Move to Trash both call `trashSelectedRecords` (Rick,
// 2026-09-13; one function for both since 2026-10-09, so they behave
// identically, ignore list included).
//
// This is a DELETE path, so it adds NO file-deletion code of its own. It
// is a pure PLAN in front of the ONE existing "move to Trash" routine,
// `deleteConfirmedJunk(_:mode: .toTrash)` (VideoScanModel+JunkDelete.swift).
// That routine already: leaves Master Archive files alone
// (excludingMasterArchiveFiles), skips files whose drive is offline,
// stamps `purgedAt` + `lifecycleStage = .trashed`, publishes the change
// (#160), and writes one `copyTrashed` Media Ledger line per file that
// actually left the disk, by: rick. Rows it trashes are recoverable from
// Finder's Trash and, in the catalog, via Show Removed → Restore.
//
// The plan adds a gate the routine does not have: a member of a recovered
// audio/video pair (Combine's raw material) is refused, the way Tidy
// refuses it. Every refusal is a console line AND a held row in the
// result (with its reason), never a silent skip. The
// existing routine re-checks the archive and offline gates itself, so
// they are enforced twice (plan time + apply time — the Tidy shape).
//
// The move never exceeds the confirmation (adversarial 2026-10-26 F2):
// the caller hands in the plan the person said yes to, and at each file's
// turn a row outside it is held, and so is a row that became the only copy
// the catalog knows of after the alert said another copy survives.
//
// Memory: O(selection). Nothing here walks `records`.

import Foundation

extension VideoScanModel {

    /// What ⌘⌫ would do with a selection: the rows to hand to the Trash
    /// routine, in selection order, and every row it refuses, with why.
    struct CatalogTrashPlan: Equatable {
        enum Refusal: String, Equatable, CaseIterable {
            /// Lives in the Master Archive — only archive actions may change it.
            case masterArchive
            /// Half of a recovered audio/video pair (or a Combine output).
            case pairMember
            /// Its drive isn't connected right now.
            case offlineVolume
            /// Already removed, set aside, or replaced by a repair — the
            /// row menu never offers Delete for these either.
            case notActive
        }
        struct Refused: Equatable {
            let id: UUID
            let filename: String
            let reason: Refusal
        }
        var toTrash: [UUID] = []
        var refused: [Refused] = []
        /// Of `toTrash`, the files the catalog knows no other copy of
        /// (`CatalogKnownCopies`) — the confirmation warns, and Move to
        /// Trash becomes a deliberate click (tab-charter audit T3). Still
        /// allowed: Rick decides. Filled by the model's `catalogTrashPlan`.
        var onlyCopy: [UUID] = []

        func refusedCount(_ reason: Refusal) -> Int {
            refused.reduce(0) { $0 + ($1.reason == reason ? 1 : 0) }
        }
    }

    /// Pure planner. `isMasterArchive` / `isOffline` are injected so the
    /// plan is testable without an archive root or a mounted volume; the
    /// pair gate is the same predicate Tidy uses.
    nonisolated static func catalogTrashPlan(
        for records: [VideoRecord],
        isMasterArchive: (VideoRecord) -> Bool,
        isOffline: (VideoRecord) -> Bool
    ) -> CatalogTrashPlan {
        var plan = CatalogTrashPlan()
        for rec in records {
            let refusal: CatalogTrashPlan.Refusal?
            if rec.isPurged || rec.isSetAside || rec.isSuperseded {
                refusal = .notActive
            } else if isMasterArchive(rec) {
                refusal = .masterArchive
            } else if CatalogScopePolicy.isPairProtected(rec) {
                refusal = .pairMember
            } else if isOffline(rec) {
                refusal = .offlineVolume
            } else {
                refusal = nil
            }
            if let refusal {
                plan.refused.append(.init(id: rec.id, filename: rec.filename, reason: refusal))
            } else {
                plan.toTrash.append(rec.id)
            }
        }
        return plan
    }

    /// The plan with this model's real predicates (the ONE bulk-delete
    /// rule — archive tree AND the whole archive volume, 2026-09-22 —
    /// and volume reachability, the 5 s cache, one stat per volume at
    /// most). The archive-volume snapshot is taken once for the plan.
    /// `isOffline` is injectable so tests never depend on which drives
    /// the host has mounted (CLAUDE.md isolation dimension); production
    /// callers take the default.
    /// Also marks the rows that are the only copy the catalog knows of
    /// (`onlyCopy`): one pass over `self.records` — asked when the gesture
    /// arrives, never from a view body.
    func catalogTrashPlan(for records: [VideoRecord],
                          isOffline: (VideoRecord) -> Bool = VideoScanModel.isRecordOnOfflineVolume) -> CatalogTrashPlan {
        let archiveVolume = archiveVolumeProtection()
        var plan = Self.catalogTrashPlan(
            for: records,
            isMasterArchive: { self.bulkDeleteRefusal($0, volume: archiveVolume) != nil },
            isOffline: isOffline)
        plan.onlyCopy = catalogOnlyCopyIDs(plan.toTrash, among: records, isOffline: isOffline)
        return plan
    }

    /// Of `ids` (rows about to move, in order), those with no surviving
    /// copy the catalog knows of: no row outside the move with the same
    /// whole-file SHA-256 (`CatalogKnownCopies`; a Master Archive copy
    /// counts by its read-back digest) that passes `isKnownCopySurvivor`
    /// — retired drives included, for the archive too (Codex #150 F3) —
    /// and whose drive is connected (`isOffline`, injectable like the
    /// plan's). The promotion index's scored match never counts.
    func catalogOnlyCopyIDs(_ ids: [UUID], among selection: [VideoRecord],
                            isOffline: (VideoRecord) -> Bool = VideoScanModel.isRecordOnOfflineVolume) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(selection.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moving = ids.compactMap { byID[$0] }
        let retiredRoots = knownCopyRetiredRoots()
        let unmatched = CatalogKnownCopies.onlyCopies(moving, in: self.records) {
            Self.isKnownCopySurvivor($0, retiredRoots: retiredRoots) && !isOffline($0)
        }
        return moving.filter { unmatched.contains($0.id) }.map(\.id)
    }

    /// The roots of RETIRED drives — a copy there never survives a move.
    func knownCopyRetiredRoots() -> [String] {
        scanTargets.filter { $0.isRetired && !$0.searchPath.isEmpty }.map(\.searchPath)
    }

    /// Can `r` still hold the bytes after a Move to Trash? The Migrate
    /// witness rule (not removed, trashed, labelled deleted or a skipped
    /// row), and not superseded by a repair, set aside, or on a RETIRED
    /// drive (physically gone for good). QA round 1 M2.
    nonisolated static func isKnownCopySurvivor(_ r: VideoRecord, retiredRoots: [String]) -> Bool {
        r.isLiveRelocateWitness && !r.isSuperseded && !r.isSetAside
            && !retiredRoots.contains { PathScope.contains(r.fullPath, within: $0) }
    }

    /// The production offline predicate: an external /Volumes path whose
    /// drive is not mounted (VolumeReachability's 5 s cache).
    nonisolated static func isRecordOnOfflineVolume(_ rec: VideoRecord) -> Bool {
        isExternalVolumePath(rec.fullPath) && !VolumeReachability.isReachable(path: rec.fullPath)
    }

    /// ⌘⌫: plan, say what was refused, then hand the rest to the existing
    /// Trash routine. Returns ONE outcome per selected row (design R6): the
    /// plan's refusals as held / offline WITH their reasons, merged with
    /// the routine's outcomes, in selection order — so the alert can list
    /// every row that stayed, and why. An empty or fully-refused selection
    /// never reaches the disk.
    /// `confirmed` is the plan the person saw and said yes to (the alert's
    /// plan in `confirmThenTrash`) — required, so no caller can move files
    /// without saying what was confirmed. The move never exceeds it
    /// (adversarial 2026-10-26 F2, MOPS-1): at each file's turn a row that
    /// was not in `confirmed.toTrash` is held, and a row that is NOW the
    /// only copy the catalog knows of, but was not warned about as one
    /// (`confirmed.onlyCopy`), is held — refuse rather than guess.
    /// `fileOperation` is the tests' seam for the file operation (nil =
    /// the routine's own move to the Trash — every production caller).
    @discardableResult
    func trashSelectedRecords(_ requested: [VideoRecord],
                              confirmed: CatalogTrashPlan,
                              fileOperation: (@Sendable (URL) throws -> Void)? = nil) async -> JunkDeletionResult {
        guard !requested.isEmpty else { return .empty }
        guard !isReadOnly else {
            log("Move to Trash refused — read-only viewer mode.")
            let why = "this Mac is a read-only viewer of the catalog"
            return JunkDeletionResult(items: requested.map { .init(record: $0, outcome: .held(why)) })
        }
        let plan = catalogTrashPlan(for: requested)
        // G2: the auditor's record — START, a line + receipt row per file, OUTCOME.
        let audit = DeletionAudit(kind: .junk, verb: "Move to Trash", linePrefix: "[junk] ", sink: deletionAuditSink())
        audit.start(scope: "\(requested.count) selected in the Catalog", requested: requested.count,
                    bytes: requested.reduce(Int64(0)) { $0 + $1.sizeBytes })
        logMasterArchiveRefusals(plan, requested: requested)
        let paired = plan.refusedCount(.pairMember)
        if paired > 0 {
            log("Move to Trash: left \(paired) file(s) alone — each is half of a recovered audio/video pair, which Combine still needs.")
        }
        let offline = plan.refusedCount(.offlineVolume)
        if offline > 0 {
            log("Move to Trash: skipped \(offline) file(s) — their drive isn't connected right now. Plug it in and try again.")
        }
        let inert = plan.refusedCount(.notActive)
        if inert > 0 {
            log("Move to Trash: \(inert) file(s) were already removed or set aside — nothing more to do for them.")
        }
        let warned = Set(confirmed.onlyCopy)
        let warnedNow = plan.onlyCopy.filter(warned.contains).count
        if warnedNow > 0 {
            log("Move to Trash: \(warnedNow) file(s) are the only copy the catalog knows of — moving them as you confirmed after the warning (recoverable from the Trash until it is emptied).")
        }
        let byID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = plan.toTrash.compactMap { byID[$0] }
        // The one existing Trash routine — archive + offline gates,
        // purgedAt/.trashed, publish, and the copyTrashed ledger lines. The
        // plan's own catalog gates are asked AGAIN at each file's turn
        // (codex delete-engines F3): a row Combine pairs, or that is
        // removed or set aside, while the batch runs is held — and so is a
        // row the person did not confirm, or that became the only copy
        // after the alert (adversarial 2026-10-26 F2).
        let confirmedIDs = Set(confirmed.toTrash)
        let copies = CatalogTrashTurnCopies(batch: targets)
        // Each turn's catalog half (main actor) names the copies its disk
        // half must prove, off-main, immediately before the move (Codex
        // #150 F3: whole-file SHA-256 on a live file stat'd at the moment
        // of removal).
        let proofs = CatalogTrashMoveProofs()
        var fileGuard = JunkDeletionGuard(
            authorize: { [weak self] rec in
                guard let self else { return "the catalog went away — nothing moved" }
                let problem = self.catalogTrashTurnProblem(rec, confirmed: confirmedIDs,
                                                           warnedOnlyCopy: warned, copies: copies, proofs: proofs)
                // Passed: from now on it counts as gone for the turns after
                // it (the catalog marks the batch only at its end).
                if problem == nil { copies.handedOn(rec.id) }
                return problem
            },
            beforeRemoval: { path in proofs.problemAtTheMove(path) },
            remove: fileOperation)
        fileGuard.settled = { rec, outcome in audit.record(JunkDeletionResult.auditRow(rec, outcome), id: rec.id) }
        let routine = targets.isEmpty ? .empty : await deleteConfirmedJunk(targets, mode: .toTrash, reason: .catalogTrash, guard: fileGuard)
        var result = mergedCatalogTrashResult(requested, plan: plan, routine: routine).trashFailuresHeld()
        // "I don't wanna see it again" (Rick 2026-09-20): the content of
        // every row that actually left the disk goes on the ignore list
        // Tidy and Remove from Catalog use, so a rescan — or another copy
        // of the same clip on another drive — never catalogs it again.
        // Put Back in Tidy → Ignored content reverses it.
        let gone = targets.filter { $0.isPurged }
        var remembered = 0
        for rec in gone where noteIgnoredContent(rec, reason: "trashed-by-user") { remembered += 1 }
        if remembered > 0 {
            scheduleIgnoredContentSave()
            log("Move to Trash: remembered \(remembered) file(s) as ignored content — a rescan will not catalog them again (Tidy → Ignored content to put back).")
        }
        logJunkLaneOutcome(result, verb: "Move to Trash")
        audit.finish(result)   // the plan's refusals, then OUTCOME + the receipt
        result.receipt = audit.receipt.url
        return result
    }

    /// The ⌘⌫ plan's catalog gates at ONE file's turn: still active, still
    /// not half of a recovered A/V pair, among the rows the person
    /// confirmed, and — unless the alert warned about it — still not the
    /// only copy the catalog knows of. nil = go on. (The archive and
    /// read-only gates are the routine's own, also asked per file.)
    /// The only-copy question is asked only for rows the alert did not warn
    /// about, against `copies` (see `CatalogTrashTurnCopies` for its cost).
    /// `proofs` receives what the disk half must prove for this file: nothing
    /// for a warned row, else the source's and the copies' SHA-256 claims.
    func catalogTrashTurnProblem(_ rec: VideoRecord, confirmed: Set<UUID>,
                                 warnedOnlyCopy: Set<UUID>, copies: CatalogTrashTurnCopies,
                                 proofs: CatalogTrashMoveProofs? = nil) -> String? {
        if rec.isPurged || rec.isSetAside || rec.isSuperseded {
            return "was removed, set aside or replaced by a repair since you chose it — nothing moved"
        }
        if CatalogScopePolicy.isPairProtected(rec) { return Self.pairMemberHeldNote }
        if !confirmed.contains(rec.id) { return Self.notConfirmedHeldNote }
        if warnedOnlyCopy.contains(rec.id) {
            proofs?.record(.warned, for: rec.fullPath)
            return nil
        }
        guard let source = ContentCopyProof.digest(rec) else { return Self.becameOnlyCopyHeldNote }
        let claims = copies.survivingCopyClaims(of: rec, model: self)
        if claims.isEmpty { return Self.becameOnlyCopyHeldNote }
        proofs?.record(.claims(source: ContentCopyProof.Claim(path: rec.fullPath, fixity: source), copies: claims),
                       for: rec.fullPath)
        return nil
    }

    /// A row the confirmation held back (or never showed) that is movable
    /// now — the move never exceeds what the person said yes to.
    nonisolated static let notConfirmedHeldNote =
        "was not among the files you confirmed — nothing moved"

    /// A row the alert counted as having another copy, which is now the
    /// only copy the catalog knows of (another copy went away meanwhile).
    nonisolated static let becameOnlyCopyHeldNote =
        "is now the only copy the catalog knows of — another copy went away after you confirmed, so it was not moved"

    /// At the move itself: no other copy could be proven on disk by its
    /// whole-file SHA-256 (moved, rewritten, unplugged, or the file itself
    /// changed since it was hashed).
    nonisolated static let copyNotProvenAtTheMoveNote =
        "no other copy of it could be proven on disk just now (whole-file SHA-256) — nothing moved"

    /// One outcome per selected row, in selection order: the routine's
    /// outcome for a row it was handed, else the plan's refusal as a named
    /// hold (or "offline" for a drive that isn't connected).
    private func mergedCatalogTrashResult(_ requested: [VideoRecord], plan: CatalogTrashPlan,
                                          routine: JunkDeletionResult) -> JunkDeletionResult {
        let refusals = Dictionary(plan.refused.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        let handled = Dictionary(routine.items.map { (ObjectIdentifier($0.record), $0.outcome) },
                                 uniquingKeysWith: { first, _ in first })
        let archiveVolume = refusals.values.contains(.masterArchive) ? archiveVolumeProtection() : nil
        let items: [JunkDeletionResult.Item] = requested.map { rec in
            if let outcome = handled[ObjectIdentifier(rec)] { return .init(record: rec, outcome: outcome) }
            let reason = refusals[rec.id] ?? .notActive
            return .init(record: rec, outcome: catalogTrashRefusalOutcome(reason, rec, archiveVolume: archiveVolume))
        }
        return JunkDeletionResult(items: items)
    }

    /// A plan refusal as the row's outcome, in the person's words.
    private func catalogTrashRefusalOutcome(_ reason: CatalogTrashPlan.Refusal, _ rec: VideoRecord,
                                            archiveVolume: ArchiveVolumeProtection?) -> JunkFileOutcome {
        switch reason {
        case .offlineVolume:
            return .offline
        case .pairMember:
            return .held("is half of a recovered audio/video pair, which Combine still needs")
        case .notActive:
            return .held("was already removed, set aside or replaced by a repair — nothing more to do")
        case .masterArchive:
            let note = bulkDeleteRefusal(rec, volume: archiveVolume)
                .map { Self.bulkDeleteRefusalNote($0, volume: archiveVolume?.label ?? "the archive volume") }
            return .held(note ?? "lives in the Master Archive, which only archive actions may change")
        }
    }

    /// The SAME sentences excludingMasterArchiveFiles writes, one per kind
    /// (tree / rest of the archive volume / unprovable), for the rows the
    /// ⌘⌫ plan refused as Master Archive files.
    private func logMasterArchiveRefusals(_ plan: CatalogTrashPlan, requested: [VideoRecord]) {
        guard plan.refusedCount(.masterArchive) > 0 else { return }
        let archiveVolume = archiveVolumeProtection()
        let label = archiveVolume?.label ?? "the archive volume"
        let byID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tree = 0, onVolume = 0, unprovable = 0
        var readOnly: [String: Int] = [:]
        for r in plan.refused where r.reason == .masterArchive {
            switch byID[r.id].flatMap({ bulkDeleteRefusal($0, volume: archiveVolume) }) {
            case .archiveVolume?: onVolume += 1
            case .archiveVolumeUnprovable?: unprovable += 1
            case .readOnlyVolume(let name)?, .readOnlyVolumeDifferentDrive(let name)?: readOnly[name, default: 0] += 1
            default: tree += 1
            }
        }
        for (name, count) in readOnly.sorted(by: { $0.key < $1.key }) {
            log(Self.readOnlyVolumeRefusalLine(verb: "Move to Trash", count: count, volume: name))
        }
        if tree > 0 { log(Self.masterArchiveRefusalLine(verb: "Move to Trash", count: tree)) }
        if onVolume > 0 { log(Self.masterArchiveVolumeRefusalLine(verb: "Move to Trash", count: onVolume, volume: label)) }
        if unprovable > 0 { log(Self.masterArchiveUnprovableRefusalLine(verb: "Move to Trash", count: unprovable, volume: label)) }
    }
}

/// "Is this file NOW the only copy the catalog knows of?" at each turn of
/// ONE ⌘⌫ batch (adversarial 2026-10-26 F2). Owns, for that batch only:
///   - `leaving`: the rows already handed to the disk. They count as gone
///     for the turns after them — the routine marks the catalog only at
///     the batch's end, so without this two selected copies would vouch
///     for each other and both move. A row handed on whose move then fails
///     still counts as gone: the error is an extra hold, never a missing one.
///   - `pool`: the catalog rows sharing an identity value with the batch
///     (`CatalogKnownCopies.candidates`) — the only rows that can be a
///     copy. Rebuilt whenever the model's `catalogMutationRevision` moves
///     (rows appended or replaced while the batch runs), so a replaced
///     row's stale object is never trusted as a live copy.
/// Cost: one O(records) pass per rebuild (normally once per batch), then
/// O(pool) per turn. Worst-case memory: one reference per catalog row
/// (every row shares a key) ≈ 8 B × 100k = 0.8 MB, freed with the batch.
/// (A `final class` here ≈ a C++ object passed by pointer into the
/// per-file callback, so the callback can update it.)
@MainActor
final class CatalogTrashTurnCopies {
    private let batch: [VideoRecord]
    private var leaving: Set<UUID> = []
    private var pool: [VideoRecord] = []
    private var poolRevision: UInt64?

    init(batch: [VideoRecord]) { self.batch = batch }

    /// `id` passed its turn's gates and went to the disk half.
    func handedOn(_ id: UUID) { leaving.insert(id) }

    /// The catalog's surviving copies of `rec` (same whole-file SHA-256,
    /// the survivor rule incl. retired drives, not handed on earlier in
    /// this batch, not the same file), as claims for the disk half to
    /// prove. Empty = no copy the catalog knows of now. Offline copies are
    /// left in: the live proof at the move refuses them.
    func survivingCopyClaims(of rec: VideoRecord, model: VideoScanModel) -> [ContentCopyProof.Claim] {
        if poolRevision != model.catalogMutationRevision {
            pool = CatalogKnownCopies.candidates(for: batch + [rec], in: model.records)
            poolRevision = model.catalogMutationRevision
        }
        let retiredRoots = model.knownCopyRetiredRoots()
        let rows = CatalogKnownCopies.survivingCopies(of: rec, in: pool) {
            !leaving.contains($0.id) && VideoScanModel.isKnownCopySurvivor($0, retiredRoots: retiredRoots)
        }
        return rows.compactMap { row in
            if let f = ContentCopyProof.digest(row) { return ContentCopyProof.Claim(path: row.fullPath, fixity: f) }
            if let a = ContentCopyProof.archiveDigest(row) { return ContentCopyProof.Claim(path: row.fullPath, archive: a) }
            return nil
        }
    }
}

/// What each ⌘⌫ file's disk half must prove, handed over from its catalog
/// half (Codex #150 F3). The catalog half runs on the main actor, the disk
/// half on a detached task immediately before the Trash move, so the hand-
/// over is lock-owned (≈ a C++ std::map guarded by a std::mutex). One entry
/// per file path, taken (removed) by the disk half. Memory: one entry per
/// file in flight — at most the batch.
final class CatalogTrashMoveProofs: @unchecked Sendable {
    enum Entry: Sendable {
        /// The alert warned this is the only copy and the person moved it anyway.
        case warned
        /// Move only if `source` and one of `copies` hold the same bytes now.
        case claims(source: ContentCopyProof.Claim, copies: [ContentCopyProof.Claim])
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func record(_ entry: Entry, for path: String) { lock.withLock { entries[path] = entry } }

    /// The disk half's verdict for `path`, read ONCE: nil = move it.
    /// No entry → refuse (nothing proved it).
    func problemAtTheMove(_ path: String) -> String? {
        let entry = lock.withLock { entries.removeValue(forKey: path) }
        switch entry {
        case .warned?:
            return nil
        case let .claims(source, copies)?:
            // Codex #150 F4: a copy another job is removing right now is no
            // survivor. This file is already reserved by the engine's turn,
            // so whichever of two racing doors checks second is held.
            // Pin the copies this move relies on (released with the turn);
            // a copy that is leaving, or is this very file under another
            // spelling, cannot be pinned (closing pass F4/F5).
            let pinned = Set(RemovalReservations.shared.pin(copies.map(\.path), for: path))
            let staying = copies.filter { pinned.contains($0.path) }
            if staying.isEmpty, !copies.isEmpty { return RemovalReservations.survivorLeavingNote }
            return ContentCopyProof.proven(source: source, copies: staying)
                ? nil : VideoScanModel.copyNotProvenAtTheMoveNote
        case nil:
            return VideoScanModel.copyNotProvenAtTheMoveNote
        }
    }
}
