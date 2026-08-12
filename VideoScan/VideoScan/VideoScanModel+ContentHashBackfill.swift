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
        log("File signatures: computing for \(total) file\(total == 1 ? "" : "s") to hash "
            + "(≈\(Int(Double(total) * 0.07 / 60) + 1) min, reading 3 MiB each)")

        var result = ContentHashBackfillResult()
        var index = 0

        while index < total {
            if Task.isCancelled { result.cancelled = true; break }

            let slice = Array(work[index ..< min(index + batchSize, total)])
            index += slice.count

            // Hash OFF the main actor. `Task.detached` (not a plain
            // `nonisolated async` call) is the documented requirement in
            // this repo — see the file header.
            let hashed: [(UUID, String)] = await Task.detached(priority: .utility) {
                var out: [(UUID, String)] = []
                out.reserveCapacity(slice.count)
                for item in slice {
                    if Task.isCancelled { break }
                    autoreleasepool {
                        let h = FileHasher.segmentedHash(path: item.path)
                        if !h.isEmpty { out.append((item.id, h)) }
                    }
                }
                return out
            }.value

            // Apply on the main actor, where the records live.
            let byID = Dictionary(hashed, uniquingKeysWith: { a, _ in a })
            for rec in records {
                guard let h = byID[rec.id] else { continue }
                // Never overwrite: a hash could have arrived from a scan
                // while this pass was running.
                if rec.contentHash.isEmpty { rec.contentHash = h }
            }
            result.hashed += hashed.count
            result.failed += slice.count - hashed.count
            progress?(index, total)
        }

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
