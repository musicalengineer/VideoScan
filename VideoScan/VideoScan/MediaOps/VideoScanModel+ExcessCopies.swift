// VideoScanModel+ExcessCopies.swift
// "Delete excess copies", Tier 1 — the app half (docs/design/
// delete_excess_copies_2026_10_06.md + C05 amendments + Rick's decisions
// of 2026-10-07).
//
// ONE SENTENCE: move to the Trash, in one bulk action, every copy outside
// the Master Archive that is byte-for-byte an archived file — each copy read
// in full now, and the archive file read in full now when the copy is the
// last one outside the archive.
//
// WHAT THIS FILE ADDS, and what it deliberately does not:
//   * NO file operation of its own. Every move goes through the existing
//     per-copy pipeline, `pruneOneCopy` (VideoScanModel+PruneApply), which
//     re-reads the live catalog, establishes the archive copy's evidence,
//     reads the copy in full against the archive digest
//     (`SignatureVerification.verifyAgainstStoredKeeper`), carries notes,
//     and hands the file to the ONE Trash routine, `deleteConfirmedJunk`,
//     behind a `JunkDeletionGuard` that re-checks the proof at the move.
//     That routine refuses viewer Macs, the Master Archive tree and volume,
//     and drives marked Read only (Archive backup drives are Read only).
//   * TRASH ONLY. The lane has no mode parameter: `.toTrash`, always.
//   * EVERY COPY IS A DUPLICATE TO THE PIPELINE (`kind: .duplicate`), so it
//     is always read in full — never trusted on a promotion stamp, never on
//     provenance.
//   * ONE PLAN (C05 amendment 4): `ExcessCopiesPlan` is what the forecast
//     and the confirmation showed; the run moves only copies that BOTH that
//     plan and a fresh plan offer, against the same archived file. A copy
//     the forecast did not show is never moved.
//   * NO OVERRIDE PATH (amendment 1): there is no "checked anyway"; the
//     keep rules are refusals. They run at selection (the plan), at the
//     copy's turn before its read, and again at the move (`PruneLaneGuard`).
//   * LAST COPY → READ THE ARCHIVE (amendment 2): when no connected copy of
//     an archived file stays outside the archive, the archive file is read
//     end to end in this job before any of its copies go. The copies the
//     forecast said would STAY are re-stat'd at the move (`survivors`): one
//     gone means the confirmation no longer holds, and the copy is held.
//   * NETWORK MOUNTS REFUSED (amendment 6), at the plan and again off-main
//     immediately before the move.
//
// Outcomes (PruneCopyResult): trashed · held(reason) — a keep rule, a hold,
// a proof failure, "archive copy changed" (the archive file failed its read:
// every copy of it is held) · failed (the Trash move threw — the file is
// where it was) · alreadyMissing · skippedOffline. None reads as success
// unless the file is in its drive's Trash.
//
// Memory: the plan is O(nominated copies) — hundreds; the snapshot pass is
// one O(records) value capture on the main actor with no allocation for a
// record that cannot match. Whole-file reads stream in 1 MiB blocks.

import Foundation
import os
import VideoScanCore

private let excessLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "excessCopies")

/// Rick's "Keep" choices in the lane — record ids, remembered across
/// launches. Tests hand in their own suite. A stored value that cannot be
/// read (another build's, a hand edit) is NOT "nothing kept": the lane
/// offers nothing and holds everything until it can be read (refuse over
/// guess — a damaged list must not un-hold what Rick said to keep).
/// (For Rick: a thin wrapper over a `UserDefaults*` — no state of its own.)
struct ExcessKeepStore {
    static let key = "excessCopies.kept"
    static let unreadableReason = "your Keep list for excess copies could not be read — nothing is offered until it can be"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// nil = a value is stored and it is not a list of strings.
    var keptIDsIfReadable: Set<UUID>? {
        guard let raw = defaults.object(forKey: Self.key) else { return [] }
        guard let list = raw as? [String] else { return nil }
        return Set(list.compactMap(UUID.init(uuidString:)))
    }

    var keptIDs: Set<UUID> { keptIDsIfReadable ?? [] }

    /// Add to the Keep list. Returns whether it was written. A list that
    /// cannot be read is NEVER written over (QA MINOR 4): that would erase
    /// whatever it held. The value stays for a person to look at; the lane
    /// keeps offering nothing until it can be read.
    @discardableResult
    func keep(_ ids: some Sequence<UUID>) -> Bool {
        guard let kept = keptIDsIfReadable else { return false }
        defaults.set(kept.union(ids).map(\.uuidString).sorted(), forKey: Self.key)
        return true
    }

    @discardableResult
    func bringBack(_ ids: some Sequence<UUID>) -> Bool {
        guard let kept = keptIDsIfReadable else { return false }
        defaults.set(kept.subtracting(ids).map(\.uuidString).sorted(), forKey: Self.key)
        return true
    }
}

extension VideoScanModel {

    /// What the lane reads from outside the catalog — injectable so tests
    /// never touch a real share or the real preferences.
    struct ExcessLaneEnvironment: @unchecked Sendable {
        var isNetworkMount: @Sendable (String) -> Bool
        var keepDefaults: UserDefaults

        static let live = ExcessLaneEnvironment(isNetworkMount: { ArchiveVolumeProtection.isNetworkMount($0) },
                                                keepDefaults: .standard)
    }

    nonisolated static let excessLogPrefix = "Excess copies"

    // MARK: Snapshot (main actor, O(records), no disk)

    /// The plan's input: every archived file with a verified sha256, and
    /// every other active record that could match one (by its own stored
    /// digest, or its `v1:` hash + size). A record that cannot match costs
    /// two set probes and allocates nothing.
    func excessCopySnapshots(env: ExcessLaneEnvironment = .live) -> [ExcessCopySnapshot] {
        var out: [ExcessCopySnapshot] = []
        var digests = Set<String>(), sampled = Set<String>()
        let root = masterArchiveRootPath
        for r in records where !r.isPurged && isArchiveElement(r) {
            // Every archived file goes in — an FFV1 master without a verified
            // digest still sets its item's length and holds it (QA MINOR 3) —
            // but only a verified one can be matched.
            let s = excessArchiveSnapshot(r, root: root)
            out.append(s)
            guard let d = s.archiveDigest else { continue }
            digests.insert(d)
            if let k = Self.excessSampledKey(r) { sampled.insert(k) }
        }
        guard !digests.isEmpty else { return [] }
        let context = ExcessHoldContext(model: self, env: env)
        for r in records where !r.isPurged && !isArchiveElement(r) {
            let digestHit = Self.excessWholeDigest(r).map(digests.contains) ?? false
            let sampledHit = Self.excessSampledKey(r).map(sampled.contains) ?? false
            guard digestHit || sampledHit else { continue }
            out.append(excessCopySnapshot(r, context: context))
        }
        return out
    }

    nonisolated static func excessWholeDigest(_ r: VideoRecord) -> String? {
        guard let f = r.contentFixity, f.algorithm == ContentFixity.sha256, f.isUsableForVerification,
              !f.digest.isEmpty else { return nil }
        return f.digest.lowercased()
    }

    nonisolated static func excessSampledKey(_ r: VideoRecord) -> String? {
        guard r.contentHash.hasPrefix("v1:"), r.sizeBytes > 0 else { return nil }
        return "\(r.contentHash)|\(r.sizeBytes)"
    }

    private func excessArchiveSnapshot(_ r: VideoRecord, root: String?) -> ExcessCopySnapshot {
        let fixity = r.archiveFixity.flatMap { $0.algorithm == ContentFixity.sha256 && !$0.digest.isEmpty ? $0 : nil }
        var rel: String?
        if let root, r.fullPath.hasPrefix(root) { rel = String(r.fullPath.dropFirst(root.count)) }
        let name = r.filename.lowercased()
        return ExcessCopySnapshot(id: r.id, filename: r.filename, fullPath: r.fullPath, volumeName: r.volumeName,
                                  sizeBytes: r.sizeBytes, durationSeconds: r.durationSeconds,
                                  contentHash: r.contentHash, isArchiveSide: true,
                                  archiveDigest: fixity?.digest.lowercased(), archiveVerifiedAt: fixity?.verifiedAt,
                                  isPreservationMaster: name.contains(".vs.preserve.") || r.videoCodec.lowercased() == "ffv1",
                                  archiveRelPath: rel, derivedFrom: r.derivedFrom)
    }

    /// Everything the per-record keep rules read, captured once per pass.
    struct ExcessHoldContext {
        let gate: BulkDeleteGate
        let gateVolumeLabel: String
        let backup: ReadOnlyVolumeProtection
        let angel: (UUID) -> Bool
        let kept: Set<UUID>

        @MainActor
        init(model: VideoScanModel, env: ExcessLaneEnvironment) {
            let volume = model.archiveVolumeProtection()
            gate = model.bulkDeleteGate(volume: volume)
            gateVolumeLabel = volume?.label ?? "the archive volume"
            backup = model.archiveBackupProtection()
            angel = model.duplicateAngelUseRule()
            kept = ExcessKeepStore(defaults: env.keepDefaults).keptIDs
        }
    }

    private func excessCopySnapshot(_ r: VideoRecord, context c: ExcessHoldContext) -> ExcessCopySnapshot {
        let refusal = c.gate.refusal(for: bulkDeleteSubject(r))
        return ExcessCopySnapshot(id: r.id, filename: r.filename, fullPath: r.fullPath, volumeName: r.volumeName,
                                  sizeBytes: r.sizeBytes, durationSeconds: r.durationSeconds,
                                  contentHash: r.contentHash, wholeDigest: Self.excessWholeDigest(r),
                                  derivedFrom: r.derivedFrom, isOnline: Self.volumeIsOnline(r),
                                  gateRefusal: refusal.map { Self.bulkDeleteRefusalNote($0, volume: c.gateVolumeLabel) },
                                  gateRefusesAsArchive: refusal.map { !$0.leavesAlone } ?? false,
                                  isOnArchiveBackupDrive: c.backup.verdict(forPath: r.fullPath) != nil,
                                  isPairMember: CatalogScopePolicy.isPairProtected(r),
                                  heldByAngel: c.angel(r.id), starRating: r.starRating, tags: r.tags,
                                  keptInLane: c.kept.contains(r.id))
    }

    // MARK: The plan (snapshot on main, compute off it)

    func excessCopiesPlan(env: ExcessLaneEnvironment = .live) async -> ExcessCopiesPlan {
        guard ExcessKeepStore(defaults: env.keepDefaults).keptIDsIfReadable != nil else {
            log("\(Self.excessLogPrefix): \(ExcessKeepStore.unreadableReason).")
            return .empty
        }
        let snaps = excessCopySnapshots(env: env)
        guard !snaps.isEmpty else { return .empty }
        return await Self.excessCopiesPlanOffMain(snaps, isNetworkMount: env.isNetworkMount)
    }

    /// The network probe (one statfs per nominated copy — hundreds, not the
    /// catalog) and the pure plan, off the main actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func excessCopiesPlanOffMain(_ snapshots: [ExcessCopySnapshot],
                                                    isNetworkMount: @Sendable (String) -> Bool) async -> ExcessCopiesPlan {
        var snaps = snapshots
        for i in snaps.indices where !snaps[i].isArchiveSide && snaps[i].isOnline {
            snaps[i].isNetworkMount = isNetworkMount(snaps[i].fullPath)
        }
        return ExcessCopiesPlan.compute(snaps)
    }

    // MARK: The keep rules, live (asked before the read and at the move)

    /// The holds that can appear while a job runs, asked of the LIVE record
    /// on the main actor. nil = nothing holds it.
    func excessHoldNow(_ rec: VideoRecord, keepDefaults: UserDefaults) -> String? {
        if archiveBackupProtection().verdict(forPath: rec.fullPath) != nil { return ExcessCopiesPlan.backupDriveReason }
        if CatalogScopePolicy.isPairProtected(rec) { return ExcessCopiesPlan.pairReason }
        if duplicateAngelUseRule()(rec.id) { return ExcessCopiesPlan.angelReason }
        guard let kept = ExcessKeepStore(defaults: keepDefaults).keptIDsIfReadable else {
            return ExcessKeepStore.unreadableReason
        }
        return ExcessCopiesPlan.personHold(starRating: rec.starRating, tags: rec.tags, keptInLane: kept.contains(rec.id))
    }

    /// The lane's guard for `pruneOneCopy`: the live holds on main (before
    /// the read and at the move), the network refusal off-main right before
    /// the file's own Trash.
    func excessLaneGuard(env: ExcessLaneEnvironment) -> PruneLaneGuard {
        let isNetwork = env.isNetworkMount
        let defaults = env.keepDefaults
        return PruneLaneGuard(
            catalog: { [weak self] rec in
                guard let self else { return "the catalog went away" }
                return self.excessHoldNow(rec, keepDefaults: defaults)
            },
            disk: { path in isNetwork(path) ? ExcessCopiesPlan.networkReason + " — nothing moved" : nil })
    }

    // MARK: Prepare — the one plan, re-asked at the job's turn

    struct ExcessPrepared {
        let fresh: ExcessCopiesPlan
        let items: [PruneItem]
        let held: [PruneHeldCopy]
        static let nothing = ExcessPrepared(fresh: .empty, items: [], held: [])
    }

    /// Which copies the confirmation showed may still go: offered by BOTH
    /// plans against the same archived file, in the order shown. Anything
    /// else that was shown is held with the fresh reason. Pure; O(copies).
    nonisolated static func excessTargets(shown: ExcessCopiesPlan, fresh: ExcessCopiesPlan)
        -> (go: [(item: ExcessCopiesPlan.Item, copy: ExcessCopiesPlan.Copy)], held: [PruneHeldCopy]) {
        var go: [(item: ExcessCopiesPlan.Item, copy: ExcessCopiesPlan.Copy)] = []
        var held: [PruneHeldCopy] = []
        for item in shown.items {
            for copy in item.offered {
                if let h = excessTarget(copy, in: fresh) { held.append(h) } else { go.append((item, copy)) }
            }
        }
        return (go, held)
    }

    /// nil = the fresh plan still offers `copy` against the same archived
    /// file at the same path; else why it is held. The ITEM that travels on
    /// is the SHOWN one (QA MAJOR 1): its survivors are what the sheet said
    /// would stay, and each must still be there at the move.
    nonisolated static func excessTarget(_ copy: ExcessCopiesPlan.Copy, in fresh: ExcessCopiesPlan) -> PruneHeldCopy? {
        guard let now = fresh.offeredCopy(copy.id) else {
            return PruneHeldCopy(copyID: copy.id, filename: copy.filename, sizeBytes: copy.sizeBytes,
                                 reason: "changed since the list was shown: " + excessFreshReason(copy.id, in: fresh))
        }
        guard now.copy.archiveID == copy.archiveID, now.copy.fullPath == copy.fullPath else {
            return PruneHeldCopy(copyID: copy.id, filename: copy.filename, sizeBytes: copy.sizeBytes,
                                 reason: "changed since the list was shown: it no longer matches the same archived file")
        }
        return nil
    }

    /// Why the fresh plan no longer offers `id`, in words.
    nonisolated static func excessFreshReason(_ id: UUID, in plan: ExcessCopiesPlan) -> String {
        for item in plan.items {
            if let l = item.leftAlone.first(where: { $0.id == id }) { return l.reason }
            if item.longer.contains(where: { $0.id == id }) { return ExcessCopiesPlan.longerFlag }
        }
        return "it no longer matches an archived file"
    }

    /// The fresh plan, the shown plan intersected with it, the live records,
    /// and the survivors' stat stamps → the copies to work through. Refused
    /// outright on a viewer Mac. Called at the job's turn, never earlier.
    func prepareExcess(shown: ExcessCopiesPlan, env: ExcessLaneEnvironment) async -> ExcessPrepared {
        guard !isReadOnly, !ViewerWriteGuard.refuse("VideoScanModel.prepareExcess") else {
            log("\(Self.excessLogPrefix): refused — this Mac is a read-only viewer of the catalog; nothing moved.")
            return .nothing
        }
        let fresh = await excessCopiesPlan(env: env)
        let (go, changed) = Self.excessTargets(shown: shown, fresh: fresh)
        var held = changed
        let survivorIDs = Set(go.flatMap { pair in pair.item.survivors(of: pair.copy.archiveID).map(\.id) })
        let survivorPaths = survivorIDs.compactMap { record(forID: $0) }.filter { !$0.isPurged }.map(\.fullPath)
        let stamps = await Self.captureStamps(paths: Array(Set(survivorPaths)))
        var items: [PruneItem] = []
        for (item, copy) in go {
            switch excessPruneItem(item: item, copy: copy, stamps: stamps) {
            case .success(let pruneItem): items.append(pruneItem)
            case .failure(let why): held.append(PruneHeldCopy(copyID: copy.id, filename: copy.filename,
                                                              sizeBytes: copy.sizeBytes, reason: why.text))
            }
        }
        for h in held { log("\(Self.excessLogPrefix): held back \(h.line)") }
        return ExcessPrepared(fresh: fresh, items: items, held: held)
    }

    struct ExcessHold: Error { let text: String }

    /// One offered copy → the pipeline's item: live record and archive
    /// record at the planned paths; every copy the forecast said would STAY
    /// is on disk now (its stamp is the move's baseline); no survivor at all
    /// → the archive file is read in full before this copy goes.
    func excessPruneItem(item: ExcessCopiesPlan.Item, copy: ExcessCopiesPlan.Copy,
                         stamps: [String: FileIdentityStamp]) -> Result<PruneItem, ExcessHold> {
        guard let rec = record(forID: copy.id), !rec.isPurged, rec.fullPath == copy.fullPath else {
            return .failure(ExcessHold(text: "no longer an active catalog record at the listed path"))
        }
        guard let archive = record(forID: copy.archiveID), !archive.isPurged else {
            return .failure(ExcessHold(text: "its archived file is no longer in the catalog"))
        }
        var survivors: [PruneSurvivor] = []
        for s in item.survivors(of: copy.archiveID) {
            guard let live = record(forID: s.id), !live.isPurged, let stamp = stamps[live.fullPath] else {
                return .failure(ExcessHold(text: "\(s.filename), a copy the list said would stay, is no longer in the catalog or on disk — the list you confirmed has changed, so nothing moved"))
            }
            survivors.append(PruneSurvivor(recordID: s.id, filename: s.filename, path: live.fullPath, stamp: stamp))
        }
        var pruneItem = PruneItem(copyID: copy.id, filename: copy.filename, path: rec.fullPath, sizeBytes: rec.sizeBytes,
                                  kind: .duplicate, archiveID: archive.id, archivePath: archive.fullPath,
                                  archiveFilename: archive.filename)
        pruneItem.survivors = survivors
        pruneItem.forceArchiveRead = survivors.isEmpty
        return .success(pruneItem)
    }

    // MARK: Run (one await — tests, and the job's loop body)

    /// One copy, through the shared pipeline, Trash only.
    func excessOneCopy(_ item: PruneItem, batch: PruneBatchState, env: ExcessLaneEnvironment,
                       hooks: PruneVerifyHooks) async -> PruneCopyOutcome {
        await pruneOneCopy(item, batch: batch, mode: .toTrash, hooks: hooks, laneGuard: excessLaneGuard(env: env))
    }

    /// The whole run in one await: prepare → one copy at a time → the
    /// approval line. `hooks.removeFile` is the tests' seam for the file
    /// operation; the mode is ALWAYS `.toTrash`.
    func applyExcess(shown: ExcessCopiesPlan, env: ExcessLaneEnvironment = .live,
                     hooks: PruneVerifyHooks = .live) async -> PruneApplyOutcome {
        var outcome = PruneApplyOutcome()
        log(Self.excessStartLine(shown))
        let prepared = await prepareExcess(shown: shown, env: env)
        outcome.held = prepared.held.map(\.line)
        let batch = PruneBatchState()
        var trashed: [VideoRecord] = []
        for item in prepared.items {
            let one = await excessOneCopy(item, batch: batch, env: env, hooks: hooks)
            outcome.absorb(one, item: item)
            if case .trashed = one.result, let rec = record(forID: item.copyID) { trashed.append(rec) }
            if case .held(let why) = one.result { log("\(Self.excessLogPrefix): held back \(item.filename) — \(why)") }
        }
        finishExcess(trashed: trashed, batchID: "excess-\(UUID().uuidString.prefix(8))")
        log("\(Self.excessLogPrefix): OUTCOME — " + outcome.summary)
        appLog.write("excess copies OUTCOME: " + outcome.summary)
        return outcome
    }

    /// "Excess copies: START — 12 copies, 640 GB …". Pure words.
    nonisolated static func excessStartLine(_ plan: ExcessCopiesPlan) -> String {
        "\(excessLogPrefix): START — \(plan.offeredCount) cop\(plan.offeredCount == 1 ? "y" : "ies"), "
            + "\(MediaBytes.display(plan.offeredBytes)) — each read in full against its archived file, then moved to the Trash"
    }

    /// The approval ledger line with the ACTUAL count — never an override
    /// (there is none in this lane). Nothing moved → no line.
    func finishExcess(trashed: [VideoRecord], batchID: String) {
        guard let first = trashed.first else { return }
        let bytes = trashed.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let detail: [String: String] = [
            MediaLedgerEvent.Detail.count: String(trashed.count),
            MediaLedgerEvent.Detail.bytes: String(bytes),
            MediaLedgerEvent.Detail.files: trashed.map(\.filename).joined(separator: "\n"),
            MediaLedgerEvent.Detail.action: "trash",
        ]
        ledgerAppend([ledgerEvent(.approval, for: first, by: .rick, batchID: batchID, detail: detail)])
        excessLog.notice("excess approval trashed=\(trashed.count, privacy: .public) bytes=\(bytes, privacy: .public)")
    }
}
