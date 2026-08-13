// VideoScanModel+ContentHashBackfill.swift
// Populate `contentHash` on records that predate it (2026-08-11).
//
// WHY A DEDICATED PASS RATHER THAN A RESCAN. Rick's instinct was to
// "re-catalog everything with the new hash". That would not have worked,
// and it is worth writing down why: `probeFile` consults the SQLite probe
// cache FIRST and returns early on a hit, before it reaches any hashing
// code. Every file whose (path, size, modDate) is unchanged short-
// circuits there — so a full rescan of an already-catalogued volume would
// burn hours of ffprobe and produce ZERO content hashes. Clearing the
// cache to force the issue would make it a genuine overnight job.
//
// This pass skips ffprobe entirely and reads only what the hash needs.
//
// COST. Segmented hashing is three seeks plus 3 MiB per file REGARDLESS
// OF FILE SIZE — a 12 GB master costs the same as a 200 MB clip. On
// Rick's ~8,760 reachable records that is minutes, not a night. The
// dominant term is seek latency on spinning drives, not bytes moved,
// which is why concurrency is capped per-volume rather than globally:
// two workers on one platter make it slower, not faster.
//
// CONCURRENCY. Hashing happens on the global executor via
// `Task.detached`; only plain `(UUID, String)` pairs cross the actor
// boundary. `VideoRecord` is a reference type and deliberately never
// leaves the main actor — this repo has had three separate incidents
// from `nonisolated async` silently running on the caller's actor
// (see [[project_approachable_concurrency_trap]]), so the boundary here
// is explicit and carries only Sendable values.
//
// SAFETY. This pass only ever WRITES a hash onto a record that had none.
// It never deletes, never moves a file, never touches an existing hash,
// and skips unreachable volumes rather than recording a failure. Re-
// running it is therefore always safe and always resumable: records
// hashed on a previous run are simply no longer candidates.

import Foundation

extension VideoScanModel {

    // MARK: - Plan (dry run)

    /// What a backfill would do, without doing any of it. Surfaced before
    /// the first run so the cost is a decision rather than a surprise.
    struct ContentHashBackfillPlan: Sendable, Equatable {
        /// Records missing a hash whose volume is mounted right now.
        var candidates: Int = 0
        /// Records missing a hash on volumes that are not mounted. These
        /// need the drive attached; the pass silently leaves them alone.
        var unreachable: Int = 0
        /// Records that already carry a hash — skipped, and the reason
        /// re-running is cheap.
        var alreadyHashed: Int = 0

        /// Bytes this pass will read: 3 MiB per candidate, flat.
        var bytesToRead: Int64 { Int64(candidates) * Int64(3 << 20) }

        /// Rough wall-clock estimate. Seek-dominated, so it is per-FILE
        /// not per-byte: ~70 ms is a spinning USB drive, and local SSDs
        /// come in far under. Deliberately pessimistic — a job that
        /// finishes early is a better surprise than one that doesn't.
        var estimatedSeconds: Double { Double(candidates) * 0.07 }

        var isEmpty: Bool { candidates == 0 }
    }

    /// Outcome of a run.
    struct ContentHashBackfillResult: Sendable, Equatable {
        var hashed: Int = 0
        /// Files that could not be read (vanished, permissions, I/O
        /// error). Left un-hashed; a later run retries them for free.
        var failed: Int = 0
        var cancelled: Bool = false
        var elapsed: TimeInterval = 0
    }

    // MARK: - Candidate selection

    /// True when this record wants a hash. Pure, so the plan and the run
    /// can never disagree about what the work is.
    ///
    /// Skips: records that already have a hash, purged/set-aside/
    /// superseded rows (not live storage), and zero-byte records (no
    /// content to identify — `segmentedHash` would return "" anyway).
    nonisolated static func needsContentHash(_ rec: VideoRecord) -> Bool {
        guard rec.contentHash.isEmpty else { return false }
        guard rec.purgedAt == nil, !rec.isSetAside, !rec.isSuperseded else { return false }
        guard rec.sizeBytes > 0, !rec.fullPath.isEmpty else { return false }
        return true
    }

    /// Build the plan. `isReachable` is injected so tests never touch a
    /// real filesystem and the caller can reuse its cached volume state
    /// rather than re-probing mounts.
    /// - Parameter pathPrefix: restrict to records under this path — a
    ///   volume root, a folder, or one file. `nil` means the whole
    ///   catalog.
    ///
    ///   NOTE the scope is over CATALOG RECORDS, not the filesystem.
    ///   Pointing this at a folder that was never scanned yields zero
    ///   candidates, because a content ID has nowhere to live without a
    ///   record to hold it. Callers surface that as "nothing catalogued
    ///   here" rather than a silent no-op.
    nonisolated static func planContentHashBackfill(
        records: [VideoRecord],
        isReachable: (String) -> Bool,
        pathPrefix: String? = nil
    ) -> ContentHashBackfillPlan {
        var plan = ContentHashBackfillPlan()
        for rec in records {
            guard rec.purgedAt == nil, !rec.isSetAside, !rec.isSuperseded else { continue }
            guard rec.sizeBytes > 0, !rec.fullPath.isEmpty else { continue }
            if let prefix = pathPrefix, !Self.isUnder(rec, prefix: prefix) { continue }
            if !rec.contentHash.isEmpty {
                plan.alreadyHashed += 1
            } else if isReachable(rec.fullPath) {
                plan.candidates += 1
            } else {
                plan.unreachable += 1
            }
        }
        return plan
    }

    /// Scope test. Compares against the record's CURRENT path and its
    /// origin path: a file migrated off a volume is still that volume's
    /// history, and scoping by the drive you are holding should find it.
    nonisolated static func isUnder(_ rec: VideoRecord, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        // Normalize so "/Volumes/X" does not also match "/Volumes/X2".
        let dir = prefix.hasSuffix("/") ? prefix : prefix + "/"
        if rec.fullPath == prefix || rec.fullPath.hasPrefix(dir) { return true }
        if let origin = rec.originalFullPath {
            if origin == prefix || origin.hasPrefix(dir) { return true }
        }
        return false
    }

    // MARK: - Run

    /// Hash every reachable record that lacks a `contentHash`.
    ///
    /// Results are applied to the catalog in batches so a long run shows
    /// progress and a cancellation keeps everything hashed so far —
    /// there is no all-or-nothing transaction to lose.
    ///
    /// - Parameters:
    ///   - batchSize: how many hashes to compute before handing them back
    ///     to the main actor. 200 keeps the UI responsive without
    ///     thrashing the actor hop.
    ///   - progress: called on the main actor with (done, total).
    @discardableResult
    func runContentHashBackfill(
        pathPrefix: String? = nil,
        batchSize: Int = 200,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> ContentHashBackfillResult {
        let started = Date()

        // One pass at a time. Every menu entry is repeatable and the
        // Tasks were unretained, so two clicks meant two fleets — each
        // honouring the lane cap alone and together doubling it, both
        // racing on the same records (codex #320.4). Reentrancy is
        // pointless here anyway: the second pass would find the first
        // one's candidates already signed.
        guard !isComputingSignatures else {
            log("File signatures: already running — ignoring duplicate request.")
            return ContentHashBackfillResult()
        }
        isComputingSignatures = true
        defer { isComputingSignatures = false }

        // Snapshot the work as Sendable pairs. VideoRecord itself never
        // crosses the boundary. Same scope predicate the PLAN uses, so a
        // dry run can never promise different work than the pass does.
        let work: [(id: UUID, path: String)] = records
            .filter { Self.needsContentHash($0) }
            .filter { rec in
                guard let prefix = pathPrefix else { return true }
                return Self.isUnder(rec, prefix: prefix)
            }
            .filter { VolumeReachability.isReachable(path: $0.fullPath) }
            .map { ($0.id, $0.fullPath) }

        guard !work.isEmpty else {
            return ContentHashBackfillResult(elapsed: Date().timeIntervalSince(started))
        }

        let total = work.count

        // Lane plan: concurrency per volume, from the hardware each
        // volume actually is. SSDs get many readers, a spinning platter
        // gets one (parallel seeks make a single head SLOWER), and every
        // volume gets at least one — so four volumes means at least four
        // lanes running at once. See SignatureConcurrencyPlan.
        let techByVolume: [String: VolumeMediaTech] = Dictionary(
            scanTargets.map {
                (VolumeReachability.volumeName(forPath: $0.searchPath), $0.mediaTech)
            },
            uniquingKeysWith: { a, _ in a }
        )
        let lanes = SignatureConcurrency.partition(
            items: work.map { SignatureWorkItem(id: $0.id, path: $0.path) },
            volumeOf: { VolumeReachability.volumeName(forPath: $0) },
            lanesFor: { SignatureConcurrency.lanes(for: techByVolume[$0] ?? .unknown) }
        )

        log("File signatures: computing for \(total) file\(total == 1 ? "" : "s") "
            + "across \(lanes.count) lane\(lanes.count == 1 ? "" : "s") "
            + "(≈\(Int(Double(total) * 0.07 / 60) + 1) min at 3 MB each)")

        var result = ContentHashBackfillResult()

        // Producers hash; this actor consumes. An AsyncStream is the
        // seam: lanes never touch `records`, and only Sendable value
        // pairs cross the boundary. VideoRecord stays main-actor-bound
        // throughout — the repo has three separate incidents from
        // getting that wrong.
        // BACKPRESSURE, not a dropping buffer. codex flagged the stream
        // as unbounded (#320.5). The obvious fix — AsyncStream's
        // `.bufferingOldest/.bufferingNewest` — would be WORSE than the
        // problem: a full buffer would silently discard computed
        // signatures, so files would come back unsigned with no error
        // anywhere. Losing work quietly is exactly the failure class
        // this whole feature is trying to avoid.
        //
        // So producers take a permit before yielding and the consumer
        // returns it after applying. Lanes throttle themselves to the
        // consumer's pace; nothing is ever dropped. In practice the
        // consumer (a dictionary lookup) far outruns the producers
        // (three seeks), so the permits are rarely exhausted — this
        // bounds the worst case rather than changing the normal one.
        let permits = AsyncSemaphore(limit: max(batchSize * 4, 64))

        let stream = AsyncStream<(UUID, String)> { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    for lane in lanes {
                        group.addTask {
                            // Lanes are DISJOINT by construction, so this
                            // loop needs no lock, no cursor, and no actor.
                            for item in lane {
                                if Task.isCancelled { return }
                                let signature = autoreleasepool {
                                    FileHasher.segmentedHash(path: item.path)
                                }
                                guard !signature.isEmpty else { continue }
                                // Blocks only when the consumer is behind.
                                do { try await permits.wait() } catch { return }
                                continuation.yield((item.id, signature))
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        // Apply in batches. One actor hop per file would cost more than
        // the hashing does; one hop per 200 is free.
        //
        // The index is built ONCE. Scanning all `records` per batch —
        // which is what this did — cost ~50M visits on a 100k catalog,
        // measured by codex at 264x slower than an indexed pass (#322).
        // The lookup, not the hashing, was the bottleneck.
        var index: [UUID: VideoRecord] = [:]
        index.reserveCapacity(records.count)
        for rec in records { index[rec.id] = rec }

        var pending: [(UUID, String)] = []
        pending.reserveCapacity(batchSize)
        var processed = 0   // signatures computed and handed back
        var applied = 0     // records this pass actually changed

        func flush() async {
            guard !pending.isEmpty else { return }
            let now = Date()
            for (id, signature) in pending {
                guard let rec = index[id] else { continue }
                // Never overwrite: a signature may have arrived from a
                // scan while this pass was running.
                guard rec.contentHash.isEmpty else { continue }
                rec.contentHash = signature
                rec.contentHashAt = now
                applied += 1
                // WRITE THROUGH to the probe cache. Records alone are
                // not enough: probeFile consults the cache first and
                // returns before hashing, so a rescan of an unchanged
                // file would hand back an empty signature and erase this
                // work. Adding the column was necessary; writing to it
                // is what makes it count (codex #320.1).
                metadataCache.updateContentHash(
                    path: rec.fullPath, hash: signature, at: now)
            }
            processed += pending.count
            let returned = pending.count
            pending.removeAll(keepingCapacity: true)
            // Release permits for everything drained, whether or not it
            // changed a record — a skipped item still consumed one.
            for _ in 0..<returned { await permits.signal() }
            progress?(processed, total)
        }

        for await pair in stream {
            pending.append(pair)
            if pending.count >= batchSize { await flush() }
            if Task.isCancelled { result.cancelled = true; break }
        }
        await flush()

        // `applied` counts records THIS pass changed; `processed` counts
        // signatures computed. They differ when a concurrent scan filled
        // one in first — reporting `processed` as work done would
        // over-claim mutations we did not make (codex #323).
        result.hashed = applied
        result.failed = result.cancelled ? 0 : max(0, total - processed)

        result.elapsed = Date().timeIntervalSince(started)
        // Persist once at the end — the catalog writer is single-writer,
        // and 18k records is one save, not one save per batch.
        _ = saveCatalogNow()

        log("File signatures: computed \(result.hashed), failed \(result.failed)"
            + (result.cancelled ? ", CANCELLED" : "")
            + String(format: ", %.1fs", result.elapsed))
        return result
    }
}
