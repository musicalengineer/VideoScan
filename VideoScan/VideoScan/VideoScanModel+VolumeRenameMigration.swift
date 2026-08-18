// VideoScanModel+VolumeRenameMigration.swift
// "Volume renamed" autodiscovery + lossless catalog migration.
//
// Motivating case (Rick, 2026-07): the SSD `Crucial2TB` was renamed to
// `CrucialX9` in Finder. VideoScan is path-keyed, so the saved scan target
// `/Volumes/Crucial2TB` went permanently Offline and every catalog record
// under it was orphaned — while the bytes sat happily on the same disk,
// now mounted at `/Volumes/CrucialX9`. Rescanning the new path would mint
// duplicate records (scan merge scopes by PathScope root). BUT most
// records carry the volume UUID captured at scan time
// (ScanContext.volumeUUID — survives renames), so a lossless migration is
// possible: prove identity, then rewrite the path prefixes.
//
// TWO-SIGNAL CONFIDENCE TIERS (Rick's spec, 2026-07-13). UUID alone isn't
// bulletproof — legacy records may predate provenance capture, and
// ASR/CCC clones can carry the same UUID under another name — so identity
// is judged on two signals:
//   Signal A — a mounted volume's volumeUUIDString equals the CONSENSUS
//              volumeUUID of the offline target's records (strict
//              majority of the UUID-carrying records).
//   Signal B — fingerprint spot-check: sample up to 25 of the target's
//              records and verify each exists at the same relative path
//              under the mounted volume with a matching file size.
//              Near-instant, off-main.
// Decision (pure function `decideVolumeRenameAction`, unit-tested):
//   A + B(≥80% clean)  → AUTO-MIGRATE, then informational dialog with
//                        [OK] [Undo] (+ the existing rescan action when
//                        drift was seen). Failing samples below 20% are
//                        ordinary catalog drift, NOT evidence against the
//                        rename — UUID is decisive on identity.
//   A + B(~0% clean)   → do NOT auto-migrate (reformat/restore smell) —
//                        fall back to the ASK dialog.
//   B(≥80%) without A  → ASK ("It looks like 'X' was renamed to 'Y'.
//                        Update the catalog?") — covers legacy catalogs
//                        with no stored UUIDs. Ambiguous (two mounted
//                        volumes pass) → nothing automatic.
//   Neither            → nothing.
// Manual fallback: right-click an offline target → "This Volume Was
// Renamed…" → pick a mounted volume → Signal-B spot-check → migrate on
// pass (≥80%), friendly refusal on fail.
//
// DETECTION COST (VolumeStatusCache pattern — NO O(records) work in view
// bodies): a debounced, generation-guarded rebuild snapshots the catalog
// on the main actor (cheap field reads), computes consensus + spot-checks
// OFF-main (@concurrent — in this repo a plain `nonisolated async` runs
// on the CALLER's actor, see project_approachable_concurrency_trap), and
// publishes a dictionary. Rows read it via `volumeRenameCandidate(for:)`
// — O(1). The mounted-volume UUID probe (disk hit) runs only when some
// offline target actually produced evidence to match. Triggers: app
// launch (init), NSWorkspace mount/unmount, records didSet.
//
// MIGRATION:
//   - Pre-flight catalog snapshot (`catalog.pre-volume-rename.<stamp>.json`,
//     same facility as the scan-merge tripwire). NO snapshot → NO rewrite
//     (fail safe). The snapshot is also what UNDO restores.
//   - Off-main re-verify (mounted volume must still be there, with the
//     expected UUID when one was part of the evidence) + plan: old→new
//     path per record, UUID-GATED — only records whose stored UUID is in
//     the candidate's accepted set follow the rename; the rest are
//     counted and reported, never rewritten.
//   - Apply on the main actor with NO awaits between derivation and
//     mutation (ScanMerge atomicity discipline): fullPath + directory
//     prefixes rewritten at component boundaries, scanContext.volumeName
//     refreshed. `originVolume` / `originalFullPath` are HISTORICAL
//     provenance — deliberately untouched.
//   - Search index: remove(oldPath) + update(record) per migrated record
//     (the LiveReload maintenance pattern), then best-effort saveToDisk
//     (production only) so the persisted index doesn't go stale against
//     the freshly-saved catalog.
//   - The scan target follows: searchPath rewritten, reachability
//     refreshed, persisted (path list + the path-keyed metadata
//     dictionaries re-emitted from live objects, so phase/role/trust/
//     notes follow the new key automatically).
//   - Explicit save (saveCatalogNow) + one audit line per migration on
//     Logger category "volumeRename".
//   - Migration is NEVER gated on scanning and never auto-starts a
//     rescan; when drift was seen the dialog offers the EXISTING
//     "Rescan" action (startTarget — no new machinery; label was
//     "Scan / Update Catalog" until GH #162 renamed it).
//
// Worst-case memory: two value snapshots of the catalog (fullPath + UUID
// + size, ~160 B/record → ~16–32 MB transient at 100k records) plus the
// rewrite dictionary for one volume's records. No media files opened.
// Duration is pinned by the scale test well under the 15 s honest-
// progress threshold at 100k records; the affected row shows a
// SpinningRing (rotation-based — scale/opacity animations silently fail
// on macOS here) while `volumeRenameMigrationInFlightTargetID` is set.
//
// What this feature does NOT do: it never touches files on disk, never
// deletes records, and never rewrites records whose identity evidence
// doesn't match — Rick's irreplaceable family media gets the same
// fail-safe treatment as the scan-merge path.

import Foundation
import os

private let volumeRenameLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                     category: "volumeRename")

// MARK: - Value types

/// What the tier decision says to do about a detected match.
enum VolumeRenameAction: Equatable, Sendable {
    /// A + B agree (≥80% clean samples): migrate immediately, inform after.
    case autoMigrate(drift: Bool)
    /// Enough evidence to ask, not enough to act: B-only match (no stored
    /// UUIDs), or UUID match with heavy/total sample drift.
    case ask(drift: Bool)
    /// Not enough evidence — no badge, no dialog.
    case none
}

/// One detected rename: "the offline target at `targetPath` is the same
/// physical volume as the one now mounted at `newVolumeRoot`". Published
/// in the model's `volumeRenameCache`, rendered by the scan-targets table
/// badge, consumed by the auto pass and `migrateRenamedVolume(for:)`.
struct VolumeRenameCandidate: Equatable, Sendable {
    /// Normalized old searchPath (the cache key), e.g. "/Volumes/Crucial2TB".
    let targetPath: String
    /// The searchPath with its volume component swapped, e.g.
    /// "/Volumes/CrucialX9" (or "/Volumes/CrucialX9/Movies" for a
    /// subfolder target — only the volume component changes).
    let newTargetPath: String
    /// Mounted root of the renamed volume, e.g. "/Volumes/CrucialX9".
    let newVolumeRoot: String
    /// Friendly old name for dialog/badge text ("Crucial2TB").
    let oldVolumeName: String
    /// Friendly new name for dialog/badge text ("CrucialX9").
    let newVolumeName: String
    /// Consensus volume UUID when Signal A fired; "" for B-only matches.
    let volumeUUID: String
    /// The rewrite gate: a record follows the rename only when its stored
    /// volumeUUID is in this set. Consensus tier → {consensusUUID};
    /// B-only tier → {"", mountedUUID} (legacy records have no UUID —
    /// that's exactly why the tier exists).
    let acceptedUUIDs: Set<String>
    /// Records under `targetPath` whose stored UUID passes the gate.
    let matchingRecords: Int
    /// Records under `targetPath` that fail the gate. Never rewritten;
    /// counted + reported.
    let mismatchedRecords: Int
    /// Signal A fired (consensus UUID == mounted UUID).
    let uuidMatched: Bool
    /// Signal B: samples attempted / samples clean (exists at the new
    /// path with matching size).
    let sampledCount: Int
    let cleanCount: Int
    /// The decided tier.
    let action: VolumeRenameAction

    /// Any sampled file that didn't check out = the volume's contents
    /// drifted since the last scan (or worse) — drives the dialog's
    /// "some files look different" sentence + rescan offer.
    var driftDetected: Bool { cleanCount < sampledCount }
}

/// Identity of a currently mounted /Volumes root. Produced by the real
/// prober (`probeMountedVolumeInfos`) or the test seam
/// (`mountedVolumeInfoProviderForTesting`).
struct MountedVolumeInfo: Equatable, Sendable {
    let root: String    // "/Volumes/CrucialX9"
    let name: String    // "CrucialX9" (OS volume name)
    let uuid: String    // volumeUUIDString; "" when the FS doesn't vend one
}

/// The three record fields detection/planning needs, captured as values
/// on the main actor so the off-main pass never touches live VideoRecord
/// instances (same discipline as VolumeStatusRecordSnap).
struct VolumeRenameRecordSnap: Sendable {
    let fullPath: String
    let volumeUUID: String
    let sizeBytes: Int64
}

/// What a migration did (or why it refused). Pinned by
/// VolumeRenameMigrationTests; logged verbatim to the audit category.
enum VolumeRenameMigrationResult: Equatable, Sendable {
    case completed(migrated: Int, mismatchedSkipped: Int, snapshotPath: String)
    /// No pre-migration catalog snapshot could be written → nothing was
    /// rewritten (fail safe — same contract as the mass-removal tripwire).
    case abortedSnapshotFailed
    /// The mounted volume no longer carries the expected identity at plan
    /// time (unmounted/replaced during the click) → nothing was rewritten.
    case abortedVolumeChanged
    /// No cached candidate for this target (stale click).
    case abortedNoCandidate
    /// Another rename migration is already in flight.
    case abortedBusy
    /// Viewer-mode Macs never rewrite the catalog.
    case abortedReadOnly
}

/// Dialog payload for the auto/ask/refused flows. Bound to an alert in
/// ContentView; cleared by the model's accept/dismiss/undo handlers.
struct VolumeRenameNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Auto (or badge/manual) migration finished — informational,
        /// with Undo. Carries the pre-migration snapshot Undo restores.
        case migrated(undoSnapshotPath: String)
        /// Ask tier — "It looks like 'X' was renamed to 'Y'." [Update] [Not Now]
        case ask
        /// Manual spot-check failed — friendly refusal, [OK] only.
        case refused(reason: String)
    }
    let id = UUID()
    let kind: Kind
    let targetID: UUID
    let oldVolumeName: String
    let newVolumeName: String
    let oldTargetPath: String   // normalized — Undo restores this
    let newTargetPath: String
    let migratedCount: Int
    let mismatchedCount: Int
    let driftDetected: Bool
}

extension VideoScanModel {

    // MARK: - Tier decision (pure — the unit-tested heart of the feature)

    /// Decide what to do with a matched (target, mounted-volume) pair.
    ///
    /// `// nonisolated static ≈ a free C++ function: pure inputs → pure`
    /// `// output, no actor, no I/O — table-driven unit tests.`
    ///
    /// Rules (Rick's spec, updates 1+2):
    ///   - UUID matched, ≥80% of samples clean → auto-migrate
    ///     (drift = any sample failed). Sub-20% failures are ordinary
    ///     catalog drift; UUID is decisive on identity.
    ///   - UUID matched, ZERO samples clean → ask (reformat/restore smell).
    ///   - UUID matched, 1–79% clean → ask (heavy drift — let Rick decide).
    ///   - No UUID evidence, ≥80% clean → ask (Signal B alone never acts).
    ///   - Otherwise → none.
    nonisolated static func decideVolumeRenameAction(
        uuidMatched: Bool, sampledCount: Int, cleanCount: Int
    ) -> VolumeRenameAction {
        guard sampledCount > 0 else {
            // Nothing verifiable on disk. With a UUID match we still have
            // ONE real signal — ask, never act. Without it there's nothing.
            return uuidMatched ? .ask(drift: false) : .none
        }
        let fraction = Double(cleanCount) / Double(sampledCount)
        let drift = cleanCount < sampledCount
        if uuidMatched {
            if cleanCount == 0 { return .ask(drift: true) }
            if fraction >= 0.8 { return .autoMigrate(drift: drift) }
            return .ask(drift: true)
        }
        if fraction >= 0.8 { return .ask(drift: drift) }
        return .none
    }

    // MARK: - Detection: invalidation (debounced, coalescing)

    /// Mark the rename-candidate cache stale. Cheap enough to call from
    /// records didSet and the mount/unmount handlers — coalesces bursts
    /// into ONE background rebuild 500 ms later. Mirrors
    /// `noteVolumeStatusesStale`.
    func noteVolumeRenameCandidatesStale() {
        volumeRenameGeneration &+= 1
        guard !volumeRenameRefreshScheduled else { return }
        volumeRenameRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.volumeRenameRefreshScheduled = false
            await self.rebuildVolumeRenameCandidatesNow()
        }
    }

    /// Snapshot on the main actor, detect off it, publish back on it,
    /// then run the auto pass. Public so tests can await a deterministic
    /// rebuild without the debounce. A rebuild that loses a generation
    /// race publishes nothing.
    func rebuildVolumeRenameCandidatesNow() async {
        countVolumeRenameRecompute()
        let generation = volumeRenameGeneration
        // Only offline, non-retired /Volumes targets can be rename
        // candidates. None → publish empty WITHOUT the O(records)
        // snapshot or any disk probing.
        let offlinePaths = scanTargets
            .filter {
                !$0.searchPath.isEmpty
                    && $0.searchPath.hasPrefix("/Volumes/")
                    && !$0.isReachable
                    && !$0.isRetired
            }
            .map { PathScope.normalize($0.searchPath) }
        guard !offlinePaths.isEmpty else {
            guard generation == volumeRenameGeneration else { return }
            publishVolumeRenameCandidates([:])
            return
        }
        let recordSnaps = snapshotRecordsForVolumeRename()
        let allTargetPaths = Set(scanTargets.map { PathScope.normalize($0.searchPath) })
        let mountedProvider = mountedVolumeInfoProviderForTesting
        let statProvider = volumeRenameStatProviderForTesting
        let fresh = await Self.computeVolumeRenameCandidates(
            records: recordSnaps,
            offlineTargetPaths: offlinePaths,
            allTargetPaths: allTargetPaths,
            mountedProvider: mountedProvider,
            statProvider: statProvider)
        guard generation == volumeRenameGeneration else { return }
        publishVolumeRenameCandidates(fresh)
        await runVolumeRenameAutoPass()
    }

    /// Lean value snapshot of the catalog for the off-main passes.
    private func snapshotRecordsForVolumeRename() -> [VolumeRenameRecordSnap] {
        records.map {
            VolumeRenameRecordSnap(fullPath: $0.fullPath,
                                   volumeUUID: $0.scanContext.volumeUUID,
                                   sizeBytes: $0.sizeBytes)
        }
    }

    // MARK: - Detection: off-main aggregator

    /// Compute every offline target's rename candidate: one census pass
    /// over the record snapshots (consensus UUID + per-root sample pool),
    /// then — only if some root produced evidence — the mounted-volume
    /// UUID probe and the Signal-B spot-checks (≤25 stats per root).
    // #if guard: pre-6.2 compilers know `@concurrent` only as a deprecated
    // alias; a nonisolated async already runs off-actor there. Same guard
    // as computeVolumeStatuses.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func computeVolumeRenameCandidates(
        records: [VolumeRenameRecordSnap],
        offlineTargetPaths: [String],
        allTargetPaths: Set<String>,
        mountedProvider: (@Sendable () -> [MountedVolumeInfo])?,
        statProvider: (@Sendable (String) -> Int64?)?
    ) async -> [String: VolumeRenameCandidate] {
        guard !offlineTargetPaths.isEmpty else { return [:] }
        let stat: (String) -> Int64? = statProvider ?? Self.statFileSize

        // Census pass — per-root record indices + UUID counts, one walk.
        struct Root {
            let key: String       // normalized searchPath
            let slashed: String   // key + "/" for prefix tests
        }
        let roots: [Root] = offlineTargetPaths.compactMap { path in
            let key = PathScope.normalize(path)
            guard !key.isEmpty, key != "/" else { return nil }
            return Root(key: key, slashed: key + "/")
        }
        var uuidCounts = [[String: Int]](repeating: [:], count: roots.count)
        var indicesUnderRoot = [[Int]](repeating: [], count: roots.count)
        for (idx, rec) in records.enumerated() {
            let p = PathScope.normalize(rec.fullPath)
            for (i, root) in roots.enumerated() {
                guard p == root.key || p.hasPrefix(root.slashed) else { continue }
                indicesUnderRoot[i].append(idx)
                if !rec.volumeUUID.isEmpty {
                    uuidCounts[i][rec.volumeUUID, default: 0] += 1
                }
            }
        }
        // No offline root has any records → nothing to identify; skip the
        // mounted probe entirely.
        guard indicesUnderRoot.contains(where: { !$0.isEmpty }) else { return [:] }

        // NOW pay for the disk: mounted /Volumes roots + their UUIDs.
        let mounted = (mountedProvider?() ?? probeMountedVolumeInfos())
            .filter { !CatalogScanTarget.isScratchVolumePath($0.root) }
        guard !mounted.isEmpty else { return [:] }
        var mountedByUUID: [String: MountedVolumeInfo] = [:]
        for m in mounted where !m.uuid.isEmpty { mountedByUUID[m.uuid] = m }

        var out: [String: VolumeRenameCandidate] = [:]
        for (i, root) in roots.enumerated() {
            let indices = indicesUnderRoot[i]
            guard !indices.isEmpty else { continue }
            let oldVolumeRoot = volumeRootForPathPublic(root.key)
            guard oldVolumeRoot.hasPrefix("/Volumes/") else { continue }

            // Consensus: most frequent UUID, strict majority of the
            // UUID-carrying records. Mixed evidence (no majority) means
            // the records disagree about where they came from — never
            // nominate on that.
            let counts = uuidCounts[i]
            let uuidCarrying = counts.values.reduce(0, +)
            var consensus: String?
            if let (uuid, count) = counts.max(by: {
                ($0.value, $1.key) < ($1.value, $0.key)   // deterministic tie-break
            }), count * 2 > uuidCarrying, count > 0 {
                consensus = uuid
            }

            func candidate(for m: MountedVolumeInfo, uuidMatched: Bool,
                           acceptedUUIDs: Set<String>) -> VolumeRenameCandidate? {
                guard m.root != oldVolumeRoot else { return nil }
                let newTargetPath = m.root + String(root.key.dropFirst(oldVolumeRoot.count))
                // The new path already registered as its own target →
                // migrating would collide two targets on one path; leave
                // it to the manual flow / Rick (open design question).
                guard !allTargetPaths.contains(PathScope.normalize(newTargetPath)) else { return nil }
                // Signal B: spot-check the gate-passing records.
                let gated = indices.map { records[$0] }
                    .filter { acceptedUUIDs.contains($0.volumeUUID) }
                guard !gated.isEmpty else { return nil }
                let samples = sampleForSpotCheck(gated)
                let (sampled, clean) = spotCheckRelocated(
                    samples: samples, oldRoot: root.key,
                    newRoot: newTargetPath, stat: stat)
                let action = decideVolumeRenameAction(
                    uuidMatched: uuidMatched, sampledCount: sampled, cleanCount: clean)
                guard action != VolumeRenameAction.none else { return nil }
                return VolumeRenameCandidate(
                    targetPath: root.key,
                    newTargetPath: newTargetPath,
                    newVolumeRoot: m.root,
                    oldVolumeName: (oldVolumeRoot as NSString).lastPathComponent,
                    newVolumeName: m.name.isEmpty
                        ? (m.root as NSString).lastPathComponent : m.name,
                    volumeUUID: uuidMatched ? (consensus ?? "") : "",
                    acceptedUUIDs: acceptedUUIDs,
                    matchingRecords: gated.count,
                    mismatchedRecords: indices.count - gated.count,
                    uuidMatched: uuidMatched,
                    sampledCount: sampled,
                    cleanCount: clean,
                    action: action)
            }

            if let consensus {
                // Signal A path: exactly one mounted volume can carry the
                // consensus UUID.
                guard let m = mountedByUUID[consensus],
                      let cand = candidate(for: m, uuidMatched: true,
                                           acceptedUUIDs: [consensus]) else { continue }
                out[root.key] = cand
            } else if uuidCarrying == 0 {
                // Signal A unavailable (legacy catalog, no stored UUIDs):
                // B-only. Spot-check every plausible mounted volume; act
                // only when EXACTLY ONE passes — two look-alikes (e.g. a
                // clone next to its source) are ambiguous, so nothing
                // automatic.
                let passing = mounted.compactMap { m in
                    candidate(for: m, uuidMatched: false,
                              acceptedUUIDs: ["", m.uuid])
                }
                if passing.count == 1, let only = passing.first {
                    out[root.key] = only
                }
            }
            // Mixed non-majority UUIDs: conflicting evidence — no candidate.
        }
        return out
    }

    /// Real mounted-volume prober. Kernel mount table for the roots
    /// (getmntinfo — no disk I/O), then one URLResourceValues read per
    /// /Volumes root for UUID + OS name (a disk hit — callers run this
    /// off-main only, and only when there's evidence to match).
    nonisolated static func probeMountedVolumeInfos() -> [MountedVolumeInfo] {
        VolumeReachability.currentMountedRoots()
            .filter { $0.hasPrefix("/Volumes/") }
            .compactMap { root in
                guard !CatalogScanTarget.isScratchVolumePath(root) else { return nil }
                let vals = try? URL(fileURLWithPath: root).resourceValues(
                    forKeys: [.volumeUUIDStringKey, .volumeNameKey])
                return MountedVolumeInfo(
                    root: root,
                    name: vals?.volumeName ?? (root as NSString).lastPathComponent,
                    uuid: vals?.volumeUUIDString ?? "")
            }
    }

    /// Real file-size stat for the spot-check. nil = missing/unreadable.
    nonisolated static func statFileSize(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    // MARK: - Signal B: fingerprint spot-check (pure given a stat closure)

    /// Deterministic, evenly-spaced sample of up to `limit` records —
    /// deterministic so tests (and repeated rebuilds) see stable verdicts.
    nonisolated static func sampleForSpotCheck(
        _ items: [VolumeRenameRecordSnap], limit: Int = 25
    ) -> [VolumeRenameRecordSnap] {
        guard items.count > limit, limit > 0 else { return items }
        let step = Double(items.count) / Double(limit)
        return (0..<limit).map { items[Int(Double($0) * step)] }
    }

    /// Verify each sampled record exists at its rewritten path with a
    /// matching size (size 0/unknown → existence alone counts). Returns
    /// (attempted, clean). Partial-MD5 hashing was considered and skipped:
    /// size+existence over 25 samples is decisive in practice and never
    /// spins up a sleeping disk for megabytes of reads.
    nonisolated static func spotCheckRelocated(
        samples: [VolumeRenameRecordSnap],
        oldRoot: String,
        newRoot: String,
        stat: (String) -> Int64?
    ) -> (sampled: Int, clean: Int) {
        var sampled = 0
        var clean = 0
        for s in samples {
            guard let newPath = rewritePathPrefix(s.fullPath, from: oldRoot, to: newRoot)
            else { continue }
            sampled += 1
            guard let onDisk = stat(newPath) else { continue }
            if s.sizeBytes <= 0 || onDisk == s.sizeBytes { clean += 1 }
        }
        return (sampled, clean)
    }

    // MARK: - Pure path rewrite (component-boundary — PathScope semantics)

    /// Rewrite `path`'s `oldRoot` prefix to `newRoot`, matching ONLY at a
    /// component boundary: "/Volumes/Crucial2TB" rewrites
    /// "/Volumes/Crucial2TB/a.mov" but never
    /// "/Volumes/Crucial2TBBackup/a.mov". Returns nil when `path` is not
    /// under `oldRoot` (caller skips), and refuses ""/"/" roots outright —
    /// a rename migration must never sweep the whole filesystem.
    nonisolated static func rewritePathPrefix(
        _ path: String, from oldRoot: String, to newRoot: String
    ) -> String? {
        let r = PathScope.normalize(oldRoot)
        guard !r.isEmpty, r != "/" else { return nil }
        let n = PathScope.normalize(newRoot)
        guard !n.isEmpty, n != "/" else { return nil }
        let p = PathScope.normalize(path)
        if p == r { return n }
        guard p.hasPrefix(r + "/") else { return nil }
        return n + String(p.dropFirst(r.count))
    }

    // MARK: - Auto pass (runs after every detection rebuild)

    /// Act on the freshest candidates: auto-migrate the auto tier, raise
    /// the ask dialog for the ask tier. One candidate per pass (multiple
    /// simultaneous renames are vanishingly rare; the post-migration
    /// rebuild picks up any others). Suppressed keys (Undo / Not Now this
    /// session) keep their badge but never re-trigger dialogs.
    func runVolumeRenameAutoPass() async {
        guard volumeRenameAutoPassEnabled, !isReadOnly else { return }
        guard pendingVolumeRenameNotice == nil,
              volumeRenameMigrationInFlight == nil else { return }
        // Deterministic order so tests (and logs) are stable.
        for key in volumeRenameCache.keys.sorted() {
            guard let cand = volumeRenameCache[key],
                  !volumeRenameAutoSuppressed.contains(key),
                  let target = scanTargets.first(where: {
                      PathScope.normalize($0.searchPath) == key
                  }) else { continue }
            switch cand.action {
            case .autoMigrate:
                await performVolumeRenameMigrationAndNotify(for: target, candidate: cand)
                return
            case .ask:
                pendingVolumeRenameNotice = VolumeRenameNotice(
                    kind: .ask,
                    targetID: target.id,
                    oldVolumeName: cand.oldVolumeName,
                    newVolumeName: cand.newVolumeName,
                    oldTargetPath: cand.targetPath,
                    newTargetPath: cand.newTargetPath,
                    migratedCount: 0,
                    mismatchedCount: cand.mismatchedRecords,
                    driftDetected: cand.driftDetected)
                return
            case .none:
                continue
            }
        }
    }

    /// Shared migrate-and-raise-dialog step for the auto pass, the row
    /// badge, the ask dialog's Update button, and the manual fallback.
    func performVolumeRenameMigrationAndNotify(
        for target: CatalogScanTarget, candidate: VolumeRenameCandidate
    ) async {
        let result = await migrateRenamedVolume(for: target)
        guard case .completed(let migrated, let mismatched, let snapshotPath) = result else { return }
        pendingVolumeRenameNotice = VolumeRenameNotice(
            kind: .migrated(undoSnapshotPath: snapshotPath),
            targetID: target.id,
            oldVolumeName: candidate.oldVolumeName,
            newVolumeName: candidate.newVolumeName,
            oldTargetPath: candidate.targetPath,
            newTargetPath: candidate.newTargetPath,
            migratedCount: migrated,
            mismatchedCount: mismatched,
            driftDetected: candidate.driftDetected)
    }

    /// Row-badge entry point (the badge IS the fix button). Captures the
    /// candidate BEFORE migrating (migration consumes it) so the dialog
    /// can report drift honestly.
    func userInitiatedVolumeRenameMigration(for target: CatalogScanTarget) async {
        guard let cand = volumeRenameCandidate(for: target.searchPath) else { return }
        await performVolumeRenameMigrationAndNotify(for: target, candidate: cand)
    }

    // MARK: - Migration: off-main plan

    /// The rewrite plan: old fullPath → new fullPath for every gate-passing
    /// record, keyed by PATH so it stays valid across the migrate's one
    /// suspension even if `records` mutates meanwhile (ScanMerge
    /// re-derivation discipline — a record that appeared during the await
    /// has no plan entry and is simply skipped).
    struct VolumeRenamePlan: Sendable {
        var rewrites: [String: String] = [:]
        var mismatchedSkipped: Int = 0
    }

    /// Re-verify the mounted volume is still there (with the expected
    /// UUID, when a UUID was part of the evidence), then compute the
    /// per-record rewrites. Returns nil when verification fails (volume
    /// unmounted/replaced between detection and click) — the caller
    /// aborts without touching anything.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func planVolumeRenameMigration(
        records: [VolumeRenameRecordSnap],
        candidate: VolumeRenameCandidate,
        mountedProvider: (@Sendable () -> [MountedVolumeInfo])?
    ) async -> VolumeRenamePlan? {
        let mounted = mountedProvider?() ?? probeMountedVolumeInfos()
        guard mounted.contains(where: {
            $0.root == candidate.newVolumeRoot
                && (candidate.volumeUUID.isEmpty || $0.uuid == candidate.volumeUUID)
        }) else { return nil }

        var plan = VolumeRenamePlan()
        plan.rewrites.reserveCapacity(candidate.matchingRecords)
        for rec in records {
            guard let newPath = rewritePathPrefix(
                rec.fullPath, from: candidate.targetPath, to: candidate.newTargetPath
            ) else { continue }
            // UUID GATE: only records whose stored provenance passes the
            // candidate's accepted set follow the rename. Foreign UUIDs
            // (and, on the consensus tier, empty legacy ones) are counted
            // and reported — never silently rewritten.
            if candidate.acceptedUUIDs.contains(rec.volumeUUID) {
                plan.rewrites[rec.fullPath] = newPath
            } else {
                plan.mismatchedSkipped += 1
            }
        }
        return plan
    }

    // MARK: - Migration: the engine

    /// Migrate the catalog after a volume rename: rewrite record paths
    /// (gate-checked), refresh scanContext.volumeName, maintain the search
    /// index, move the scan target to the new path, persist everything,
    /// and write one audit line. Never touches files on disk.
    ///
    /// Fail-safe order: snapshot FIRST (no snapshot → no rewrite), verify
    /// the mounted identity off-main, apply atomically on the main actor.
    @discardableResult
    func migrateRenamedVolume(for target: CatalogScanTarget) async -> VolumeRenameMigrationResult {
        guard !isReadOnly else { return .abortedReadOnly }
        let key = PathScope.normalize(target.searchPath)
        guard let candidate = volumeRenameCache[key] else { return .abortedNoCandidate }
        guard volumeRenameMigrationInFlight == nil else { return .abortedBusy }
        volumeRenameMigrationInFlight = key
        volumeRenameMigrationInFlightTargetID = target.id
        defer {
            volumeRenameMigrationInFlight = nil
            volumeRenameMigrationInFlightTargetID = nil
        }

        // 1. Safety snapshot — the recovery copy IS the permission to
        //    proceed (same contract as the mass-removal tripwire), and
        //    it's what the dialog's Undo restores.
        guard let snapshotPath = snapshotCatalog(prefix: "pre-volume-rename") else {
            log("  ⚠ Couldn't write the pre-update catalog snapshot — nothing was changed. Fix the catalog folder and try again.")
            volumeRenameLog.error("Volume rename \(candidate.oldVolumeName, privacy: .public) → \(candidate.newVolumeName, privacy: .public): pre-migration snapshot FAILED; migration aborted (nothing rewritten)")
            return .abortedSnapshotFailed
        }

        log("Updating catalog: \(candidate.oldVolumeName) is now \(candidate.newVolumeName) — \(candidate.matchingRecords) file record(s) will follow the new name…")

        // 2. Off-main verify + plan (the migrate's ONE suspension point).
        let recordSnaps = snapshotRecordsForVolumeRename()
        let provider = mountedVolumeInfoProviderForTesting
        guard let plan = await Self.planVolumeRenameMigration(
            records: recordSnaps, candidate: candidate, mountedProvider: provider
        ) else {
            log("  ⚠ \(candidate.newVolumeName) is no longer connected the way it was a moment ago — nothing was changed.")
            volumeRenameLog.warning("Volume rename \(candidate.oldVolumeName, privacy: .public) → \(candidate.newVolumeName, privacy: .public): mounted-identity re-verification failed at plan time; migration aborted")
            noteVolumeRenameCandidatesStale()
            return .abortedVolumeChanged
        }

        // 3. Apply — atomic on the main actor (no awaits from here to the
        //    save). The plan is keyed by path, and each live record's
        //    UUID gate is re-checked, so a catalog mutated during the
        //    await above can only shrink the applied set, never widen it.
        var migrated = 0
        var migratedRecords: [VideoRecord] = []
        var migratedOldPaths: [String] = []
        migratedRecords.reserveCapacity(plan.rewrites.count)
        migratedOldPaths.reserveCapacity(plan.rewrites.count)
        for rec in records {
            guard let newPath = plan.rewrites[rec.fullPath],
                  candidate.acceptedUUIDs.contains(rec.scanContext.volumeUUID)
            else { continue }
            let oldPath = rec.fullPath
            rec.fullPath = newPath
            rec.directory = Self.rewritePathPrefix(
                rec.directory, from: candidate.targetPath, to: candidate.newTargetPath
            ) ?? (newPath as NSString).deletingLastPathComponent
            // The volume's CURRENT name — provenance fields (originVolume,
            // originalFullPath) are history and stay untouched.
            rec.scanContext.volumeName = candidate.newVolumeName
            // Thumbnail cache is keyed by fullPath; drop the stale key.
            // (MetadataCache SQLite rows under the old path become inert
            // stale entries — same tolerated leak as renameRecord; the
            // next scan of the new path probes fresh.)
            invalidateThumbnailCacheEntry(forPath: oldPath)
            migratedRecords.append(rec)
            migratedOldPaths.append(oldPath)
            migrated += 1
        }
        // Search index: haystacks are keyed by fullPath, so every migrated
        // record needs its old key dropped + new key indexed. Small
        // migrations use the LiveReload per-record maintenance; bulk
        // migrations use the canonical full rebuild — at 100k records the
        // per-record word-set diffs cost several SECONDS more than one
        // fresh O(n) rebuild (measured 2026-07-13; this is what keeps the
        // whole operation under the 15 s honest-progress budget on M1).
        if migrated > 2_000 {
            searchIndex.rebuild(records: records)
        } else {
            for (rec, oldPath) in zip(migratedRecords, migratedOldPaths) {
                searchIndex.remove(fullPath: oldPath)
                searchIndex.update(rec)
            }
        }

        // 4. The scan target follows its volume. persistScanDates re-emits
        //    the path-keyed metadata dictionaries from the live objects,
        //    so phase/role/trust/notes/retire fields all move to the new
        //    key in the same write.
        target.searchPath = candidate.newTargetPath
        target.isReachable = VolumeReachability.isReachable(path: candidate.newTargetPath)
        persistScanTargets()
        persistScanDates()

        // 5. Publish + persist. In-place fullPath rewrites shift records
        //    between volume buckets without an array-level mutation — the
        //    same cache set Bucket-D adoption invalidates.
        notifyVolumeAggregatesStale()
        noteCatalogChangedForDossierCounts()
        notifyTargetsChanged()
        saveCatalogNow()
        if !Self.isRunningTests {
            // Keep the persisted search index fresh against the catalog we
            // just saved (known staleness issue — don't make it worse).
            // Best-effort, exactly like init's rebuild path.
            try? searchIndex.saveToDisk()
        }

        // 6. The candidate is consumed; drop it immediately so the badge
        //    disappears on this render, then let the debounced rebuild
        //    re-derive from scratch (there could be OTHER renamed volumes).
        var remaining = volumeRenameCache
        remaining.removeValue(forKey: key)
        publishVolumeRenameCandidates(remaining)
        noteVolumeRenameCandidatesStale()

        // 7. Audit — one line per migration.
        volumeRenameLog.notice("Volume rename migrated: \(candidate.targetPath, privacy: .public) → \(candidate.newTargetPath, privacy: .public) (UUID \(candidate.volumeUUID.isEmpty ? "n/a (spot-check tier)" : candidate.volumeUUID, privacy: .public), samples \(candidate.cleanCount)/\(candidate.sampledCount) clean): \(migrated) record(s) rewritten, \(plan.mismatchedSkipped) skipped (identity mismatch), snapshot=\(snapshotPath, privacy: .public)")
        appLog.write("Volume rename: \(candidate.oldVolumeName) → \(candidate.newVolumeName); \(migrated) records followed, \(plan.mismatchedSkipped) skipped (not proven to be this volume); pre-migration snapshot: \(snapshotPath)")
        if plan.mismatchedSkipped > 0 {
            log("  Done — \(migrated) file record(s) now point at \(candidate.newVolumeName). \(plan.mismatchedSkipped) record(s) were left alone because they couldn't be proven to belong to this drive; they still show under \(candidate.oldVolumeName).")
        } else {
            log("  Done — \(migrated) file record(s) now point at \(candidate.newVolumeName). Nothing on the drive was touched.")
        }
        return .completed(migrated: migrated,
                          mismatchedSkipped: plan.mismatchedSkipped,
                          snapshotPath: snapshotPath)
    }

    // MARK: - Dialog handlers (ask / dismiss / undo / follow-up rescan)

    /// Ask-tier "Update" button: migrate, then show the informational
    /// dialog (with Undo — and the rescan offer when drift was seen, per
    /// spec: the no-UUID accept path gets the same follow-up).
    func acceptVolumeRenameAsk(_ notice: VolumeRenameNotice) async {
        guard notice.kind == .ask else { return }
        pendingVolumeRenameNotice = nil
        guard let target = scanTargets.first(where: { $0.id == notice.targetID }),
              let cand = volumeRenameCandidate(for: notice.oldTargetPath) else { return }
        await performVolumeRenameMigrationAndNotify(for: target, candidate: cand)
    }

    /// Ask-tier "Not Now" (and stray dismissals): never nag again this
    /// session. The row badge stays as the manual affordance.
    func dismissVolumeRenameNotice(_ notice: VolumeRenameNotice) {
        if notice.kind == .ask {
            volumeRenameAutoSuppressed.insert(PathScope.normalize(notice.oldTargetPath))
        }
        pendingVolumeRenameNotice = nil
    }

    /// Undo an auto/accepted migration: restore the pre-migration catalog
    /// snapshot verbatim (records array AND the scan target's old path),
    /// rebuild the search index, persist, and suppress the auto pass for
    /// this volume so the very next rebuild doesn't redo what Rick just
    /// undid. Returns false (and changes nothing) when the snapshot can't
    /// be read back.
    @discardableResult
    func undoVolumeRenameMigration(_ notice: VolumeRenameNotice) -> Bool {
        guard case .migrated(let snapshotPath) = notice.kind else { return false }
        guard let restored = catalogStore.loadRecords(fromSnapshotAtPath: snapshotPath) else {
            log("  ⚠ Couldn't read the pre-update snapshot at \(snapshotPath) — the catalog was left as-is.")
            volumeRenameLog.error("Volume rename UNDO failed: snapshot unreadable at \(snapshotPath, privacy: .public)")
            pendingVolumeRenameNotice = nil
            return false
        }
        // Suppress BEFORE mutating records — the didSet schedules a
        // detection rebuild whose auto pass must not re-migrate.
        volumeRenameAutoSuppressed.insert(PathScope.normalize(notice.oldTargetPath))
        records = restored
        if let target = scanTargets.first(where: { $0.id == notice.targetID }) {
            target.searchPath = notice.oldTargetPath
            target.isReachable = VolumeReachability.isReachable(path: notice.oldTargetPath)
            persistScanTargets()
            persistScanDates()
        }
        searchIndex.rebuild(records: records)
        if !Self.isRunningTests { try? searchIndex.saveToDisk() }
        notifyVolumeAggregatesStale()
        notifyTargetsChanged()
        saveCatalogNow()
        pendingVolumeRenameNotice = nil
        noteVolumeRenameCandidatesStale()
        volumeRenameLog.notice("Volume rename UNDONE: restored \(restored.count) record(s) from \(snapshotPath, privacy: .public); target back to \(notice.oldTargetPath, privacy: .public)")
        appLog.write("Volume rename undone: \(notice.newVolumeName) → \(notice.oldVolumeName); catalog restored from \(snapshotPath)")
        log("Undone — the catalog is back to how it was before the \(notice.oldVolumeName) → \(notice.newVolumeName) update.")
        return true
    }

    /// Dialog follow-up when drift was seen: run the EXISTING incremental
    /// rescan on the migrated target ("Rescan" — the same
    /// verb, the same startTarget entry point, the same scan merge +
    /// move-identity + progress UI; no new scan machinery). Never called
    /// automatically — migration is not gated on scanning.
    func rescanAfterVolumeRename(_ notice: VolumeRenameNotice) {
        pendingVolumeRenameNotice = nil
        guard let target = scanTargets.first(where: { $0.id == notice.targetID }) else { return }
        startTarget(target)
    }

    // MARK: - Manual fallback ("This Volume Was Renamed…")

    /// Rick right-clicked an offline target and picked a mounted volume:
    /// run the Signal-B spot-check against exactly that volume, migrate
    /// on pass (≥80% clean), refuse in friendly language on fail.
    func manualVolumeRenameCheck(for target: CatalogScanTarget, mountedRoot: String) async {
        guard !isReadOnly, volumeRenameMigrationInFlight == nil else { return }
        let key = PathScope.normalize(target.searchPath)
        let recordSnaps = snapshotRecordsForVolumeRename()
        let mountedProvider = mountedVolumeInfoProviderForTesting
        let statProvider = volumeRenameStatProviderForTesting
        let cand = await Self.buildManualVolumeRenameCandidate(
            records: recordSnaps,
            targetPath: key,
            mountedRoot: PathScope.normalize(mountedRoot),
            mountedProvider: mountedProvider,
            statProvider: statProvider)
        guard let cand else {
            pendingVolumeRenameNotice = VolumeRenameNotice(
                kind: .refused(reason: "That volume couldn't be checked — it may have just disconnected, or \(VolumeReachability.volumeName(forPath: target.searchPath)) has no cataloged files to compare."),
                targetID: target.id,
                oldVolumeName: VolumeReachability.volumeName(forPath: target.searchPath),
                newVolumeName: (mountedRoot as NSString).lastPathComponent,
                oldTargetPath: key,
                newTargetPath: mountedRoot,
                migratedCount: 0, mismatchedCount: 0, driftDetected: false)
            return
        }
        let fraction = cand.sampledCount == 0
            ? 0 : Double(cand.cleanCount) / Double(cand.sampledCount)
        guard fraction >= 0.8 else {
            volumeRenameLog.notice("Manual rename check refused: \(cand.targetPath, privacy: .public) vs \(cand.newVolumeRoot, privacy: .public) — \(cand.cleanCount)/\(cand.sampledCount) samples clean")
            pendingVolumeRenameNotice = VolumeRenameNotice(
                kind: .refused(reason: "Only \(cand.cleanCount) of \(cand.sampledCount) checked files from \(cand.oldVolumeName) were found on \(cand.newVolumeName) — that doesn't look like the same drive, so the catalog was left alone."),
                targetID: target.id,
                oldVolumeName: cand.oldVolumeName,
                newVolumeName: cand.newVolumeName,
                oldTargetPath: cand.targetPath,
                newTargetPath: cand.newTargetPath,
                migratedCount: 0, mismatchedCount: cand.mismatchedRecords,
                driftDetected: cand.driftDetected)
            return
        }
        // Stash the candidate so the shared engine can consume it, then
        // migrate — Rick explicitly initiated this, no second ask.
        var cache = volumeRenameCache
        cache[key] = cand
        publishVolumeRenameCandidates(cache)
        await performVolumeRenameMigrationAndNotify(for: target, candidate: cand)
    }

    /// Build a candidate for the manual flow: identity is whatever the
    /// picked volume offers (UUID consensus when both sides have one,
    /// otherwise the legacy empty-UUID gate), verdict comes from the
    /// spot-check the caller thresholds.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func buildManualVolumeRenameCandidate(
        records: [VolumeRenameRecordSnap],
        targetPath: String,
        mountedRoot: String,
        mountedProvider: (@Sendable () -> [MountedVolumeInfo])?,
        statProvider: (@Sendable (String) -> Int64?)?
    ) async -> VolumeRenameCandidate? {
        let key = PathScope.normalize(targetPath)
        guard !key.isEmpty, key != "/" else { return nil }
        let oldVolumeRoot = volumeRootForPathPublic(key)
        guard oldVolumeRoot.hasPrefix("/Volumes/"), mountedRoot != oldVolumeRoot else { return nil }
        let mounted = mountedProvider?() ?? probeMountedVolumeInfos()
        guard let m = mounted.first(where: { $0.root == mountedRoot }) else { return nil }
        let stat: (String) -> Int64? = statProvider ?? Self.statFileSize

        let slashed = key + "/"
        let underRoot = records.filter {
            let p = PathScope.normalize($0.fullPath)
            return p == key || p.hasPrefix(slashed)
        }
        guard !underRoot.isEmpty else { return nil }
        // Consensus (same strict-majority rule as autodiscovery).
        var counts: [String: Int] = [:]
        for r in underRoot where !r.volumeUUID.isEmpty {
            counts[r.volumeUUID, default: 0] += 1
        }
        let uuidCarrying = counts.values.reduce(0, +)
        let consensus: String? = counts
            .max(by: { ($0.value, $1.key) < ($1.value, $0.key) })
            .flatMap { $0.value * 2 > uuidCarrying ? $0.key : nil }
        let uuidMatched = consensus != nil && consensus == m.uuid && !m.uuid.isEmpty
        let acceptedUUIDs: Set<String> = uuidMatched
            ? [m.uuid]
            : ["", m.uuid]   // legacy/no-UUID records may follow a manual pick
        let newTargetPath = m.root + String(key.dropFirst(oldVolumeRoot.count))
        let gated = underRoot.filter { acceptedUUIDs.contains($0.volumeUUID) }
        guard !gated.isEmpty else { return nil }
        let samples = sampleForSpotCheck(gated)
        let (sampled, clean) = spotCheckRelocated(
            samples: samples, oldRoot: key, newRoot: newTargetPath, stat: stat)
        return VolumeRenameCandidate(
            targetPath: key,
            newTargetPath: newTargetPath,
            newVolumeRoot: m.root,
            oldVolumeName: (oldVolumeRoot as NSString).lastPathComponent,
            newVolumeName: m.name.isEmpty ? (m.root as NSString).lastPathComponent : m.name,
            volumeUUID: uuidMatched ? m.uuid : "",
            acceptedUUIDs: acceptedUUIDs,
            matchingRecords: gated.count,
            mismatchedRecords: underRoot.count - gated.count,
            uuidMatched: uuidMatched,
            sampledCount: sampled,
            cleanCount: clean,
            action: decideVolumeRenameAction(uuidMatched: uuidMatched,
                                             sampledCount: sampled,
                                             cleanCount: clean))
    }
}
