// VideoScanModel+EmbeddedDateBackfill.swift
// "Refresh Embedded Dates" — populate `embeddedCreationDate` + the origin
// line on records that predate the field (2026-08-16).
//
// WHY A DEDICATED PASS RATHER THAN A RESCAN. Same reason as the content-
// hash backfill: `probeFile` consults the SQLite probe cache FIRST and
// returns on a hit, before ffprobe runs. Every unchanged file short-
// circuits there, so a rescan would burn nothing AND capture nothing.
// This pass runs ffprobe with ONLY the tag entries it needs — no stream
// analysis, no packet reads — so it is one small read per file.
//
// COST. ffprobe reading just format/stream tags touches the container
// header (the moov atom on MOV/MP4 — for some camera files that is at
// the END of the file, so a seek). Tens of ms per file on local disks;
// seek-bound on spinning drives, hence per-volume lanes (one lane on an
// HDD, more on SSD/RAID — SignatureConcurrency's plan, reused verbatim).
//
// CONCURRENCY. ffprobe runs on the global executor via `Task.detached`;
// only Sendable value pairs cross the actor boundary. `VideoRecord` is a
// reference type and deliberately never leaves the main actor (see
// [[project_approachable_concurrency_trap]] — three separate incidents).
//
// SAFETY. Writes an embedded date / origin ONLY onto a record that has
// none. Never deletes, never moves, never touches user dates. Skips
// unreachable volumes. Re-running is always safe and resumable. Also
// WRITES THROUGH to the probe cache — without that, the next rescan of an
// unchanged file would return the cached (nil) value and erase the work
// (the content-hash lesson, codex #320.1).
//
// MEMORY. Worst case is the work list (one (UUID, String) per candidate —
// ~100 bytes × 100k = 10 MB) plus a bounded in-flight window: producers
// take a permit before yielding, so at most `batchSize * 4` results are
// buffered (~64 KB). ffprobe output is a few KB of JSON per file, parsed
// and dropped inside the lane. Nothing scales with file size.

import Foundation

extension VideoScanModel {

    // MARK: - Result

    struct EmbeddedDateBackfillResult: Sendable, Equatable {
        /// Records that gained an embedded date.
        var dated: Int = 0
        /// Records probed that carry no usable creation tag (old tapes,
        /// VOBs, AVIs) — origin may still have been captured.
        var noTag: Int = 0
        /// ffprobe could not read the file at all.
        var failed: Int = 0
        var cancelled: Bool = false
        var elapsed: TimeInterval = 0
    }

    // MARK: - Candidate selection

    /// True when this record wants an embedded-date probe. Pure, so a
    /// plan and the run agree.
    ///
    /// Skips: records that already have an embedded date, purged / set-
    /// aside / superseded rows, ffprobe-failed records (a tag-only probe
    /// would fail the same way), and pathless rows.
    nonisolated static func needsEmbeddedDate(_ rec: VideoRecord) -> Bool {
        guard rec.embeddedCreationDate == nil else { return false }
        guard rec.purgedAt == nil, !rec.isSetAside, !rec.isSuperseded else { return false }
        guard !rec.fullPath.isEmpty else { return false }
        guard rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue else { return false }
        return true
    }

    /// One tag-only ffprobe: `-show_entries format_tags:stream_tags` as
    /// JSON. Returns (capture, origin) or nil when ffprobe failed. Pure
    /// apart from the subprocess; safe to call from any executor.
    nonisolated static func probeEmbeddedTags(path: String) async -> (EmbeddedCreationDate.Capture?, EmbeddedOriginTags.Origin)? {
        let args = ["-v", "error",
                    "-print_format", "json",
                    "-show_entries", "format_tags:stream_tags",
                    path]
        let result = await ProcessRunner.runCapturingStderr(executable: ToolLocator.ffprobePath,
                                                            arguments: args,
                                                            deadlineSeconds: 60)
        guard let json = result.stdout, let data = json.data(using: .utf8),
              let out = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else { return nil }
        let fmtTags = out.format?.tags ?? [:]
        let streamTags = (out.streams ?? []).map { $0.tags ?? [:] }
        let cap = EmbeddedCreationDate.extract(formatTags: fmtTags, streamTags: streamTags)
        let origin = EmbeddedOriginTags.extract(formatTags: fmtTags, streamTags: streamTags)
        return (cap, origin)
    }

    // MARK: - Run

    /// One probe result, as it crosses the actor boundary.
    private struct EmbeddedProbeOutcome: Sendable {
        let id: UUID
        let path: String
        let capture: EmbeddedCreationDate.Capture?
        let origin: EmbeddedOriginTags.Origin
        let failed: Bool
    }

    /// Probe every reachable record lacking an embedded date. Applies in
    /// batches on the main actor; saves once at the end.
    @discardableResult
    func runEmbeddedDateBackfill(
        pathPrefix: String? = nil,
        batchSize: Int = 100,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> EmbeddedDateBackfillResult {
        let started = Date()
        guard !isReadOnly else {
            log("Refresh Embedded Dates: catalog is read-only — nothing done.")
            return EmbeddedDateBackfillResult()
        }
        guard !isRefreshingEmbeddedDates else {
            log("Refresh Embedded Dates: already running — ignoring duplicate request.")
            return EmbeddedDateBackfillResult()
        }
        isRefreshingEmbeddedDates = true
        defer { isRefreshingEmbeddedDates = false }

        let work: [(id: UUID, path: String)] = records
            .filter { Self.needsEmbeddedDate($0) }
            .filter { rec in
                guard let prefix = pathPrefix else { return true }
                return Self.isUnder(rec, prefix: prefix)
            }
            .filter { VolumeReachability.isReachable(path: $0.fullPath) }
            .map { ($0.id, $0.fullPath) }

        guard !work.isEmpty else {
            log("Refresh Embedded Dates: nothing to do — every reachable record already has one or has no tag to read.")
            return EmbeddedDateBackfillResult(elapsed: Date().timeIntervalSince(started))
        }
        let total = work.count

        let techByVolume: [String: VolumeMediaTech] = Dictionary(
            scanTargets.map { (VolumeReachability.volumeName(forPath: $0.searchPath), $0.mediaTech) },
            uniquingKeysWith: { a, _ in a }
        )
        let lanes = SignatureConcurrency.partition(
            items: work.map { SignatureWorkItem(id: $0.id, path: $0.path) },
            volumeOf: { VolumeReachability.volumeName(forPath: $0) },
            lanesFor: { SignatureConcurrency.lanes(for: techByVolume[$0] ?? .unknown) }
        )
        log("Refresh Embedded Dates: probing \(total) file\(total == 1 ? "" : "s") "
            + "across \(lanes.count) lane\(lanes.count == 1 ? "" : "s") (tags only, no decode)")

        var result = EmbeddedDateBackfillResult()
        // Backpressure, never a dropping buffer (see the content-hash pass).
        let permits = AsyncSemaphore(limit: max(batchSize * 4, 64))

        let stream = AsyncStream<EmbeddedProbeOutcome> { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    for lane in lanes {
                        group.addTask {
                            for item in lane {
                                if Task.isCancelled { return }
                                let probed = await Self.probeEmbeddedTags(path: item.path)
                                let outcome = EmbeddedProbeOutcome(
                                    id: item.id, path: item.path,
                                    capture: probed?.0, origin: probed?.1 ?? .init(),
                                    failed: probed == nil)
                                do { try await permits.wait() } catch { return }
                                continuation.yield(outcome)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        var index: [UUID: VideoRecord] = [:]
        index.reserveCapacity(records.count)
        for rec in records { index[rec.id] = rec }

        var pending: [EmbeddedProbeOutcome] = []
        pending.reserveCapacity(batchSize)
        var processed = 0

        func flush() async {
            guard !pending.isEmpty else { return }
            for o in pending {
                defer { processed += 1 }
                if o.failed { result.failed += 1; continue }
                guard let rec = index[o.id] else { continue }
                var changed = false
                if rec.embeddedCreationDate == nil, let cap = o.capture {
                    rec.embeddedCreationDate = cap.date
                    rec.embeddedCreationSource = cap.source
                    result.dated += 1
                    changed = true
                } else if o.capture == nil {
                    result.noTag += 1
                }
                if rec.originMake == nil, rec.originModel == nil, rec.originEncoder == nil, !o.origin.isEmpty {
                    rec.originMake = o.origin.make
                    rec.originModel = o.origin.model
                    rec.originEncoder = o.origin.encoder
                    changed = true
                }
                if changed {
                    // Write through to the probe cache — see the file header.
                    metadataCache.updateEmbeddedDate(path: rec.fullPath,
                                                     date: rec.embeddedCreationDate,
                                                     source: rec.embeddedCreationSource,
                                                     make: rec.originMake,
                                                     model: rec.originModel,
                                                     encoder: rec.originEncoder)
                }
            }
            let returned = pending.count
            pending.removeAll(keepingCapacity: true)
            for _ in 0..<returned { await permits.signal() }
            progress?(processed, total)
        }

        for await outcome in stream {
            pending.append(outcome)
            if pending.count >= batchSize { await flush() }
            if Task.isCancelled { result.cancelled = true; break }
        }
        await flush()

        result.elapsed = Date().timeIntervalSince(started)
        if result.dated > 0 || processed > 0 {
            noteCatalogRecordsMutated()
            saveCatalogDebounced()
        }
        log("Refresh Embedded Dates: dated \(result.dated), no tag \(result.noTag), failed \(result.failed)"
            + (result.cancelled ? ", CANCELLED" : "")
            + String(format: ", %.1fs", result.elapsed))
        return result
    }
}
