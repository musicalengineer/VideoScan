import Foundation

// MARK: - Correlate (A/V pair matching)
//
// Two correlate entry points share this file:
//   - correlateAcrossVolumes() — uses Avid clip IDs encoded in MXF
//     filenames; high-confidence-only, picks one "best copy" per pair
//     across every mounted volume.
//   - correlate(selectedIDs:) — the general-purpose fuzzy correlator:
//     duration tolerance, timestamp tolerance, scored candidate matching
//     via CorrelationScorer.
//
// The tolerances live as static let on the extension because they're
// engine-tuning knobs, not per-instance state, and extensions can't add
// stored instance properties on a class.

extension VideoScanModel {

    /// Tolerance for duration matching (seconds)
    fileprivate static let durationTolerance: Double = 1.0
    /// Tolerance for timestamp matching (seconds)
    fileprivate static let timestampTolerance: TimeInterval = 5.0

    // MARK: - Cross-Volume Avid Correlator

    /// Correlate Avid MXF A/V pairs across all volumes using clip ID matching.
    func correlateAcrossVolumes() {
        isCorrelating = true
        correlateStatus = ""
        defer { isCorrelating = false }

        // Clear existing pairs
        for r in records {
            r.pairedWith = nil
            r.pairGroupID = nil
            r.pairConfidence = nil
        }

        // Group by Avid clip ID
        var videosByClip: [String: [VideoRecord]] = [:]
        var audiosByClip: [String: [VideoRecord]] = [:]

        for r in records {
            guard let (clipID, isVideo) = CorrelationScorer.avidClipID(from: r.filename) else { continue }
            if isVideo {
                videosByClip[clipID, default: []].append(r)
            } else {
                audiosByClip[clipID, default: []].append(r)
            }
        }

        let allClipIDs = Set(videosByClip.keys).union(audiosByClip.keys)
        var paired = 0
        var videoOnlyOrphans = 0
        var audioOnlyOrphans = 0

        for clipID in allClipIDs {
            let videos = videosByClip[clipID] ?? []
            let audios = audiosByClip[clipID] ?? []

            guard !videos.isEmpty, !audios.isEmpty else {
                if videos.isEmpty { audioOnlyOrphans += audios.count }
                if audios.isEmpty { videoOnlyOrphans += videos.count }
                continue
            }

            guard let bestVideo = CorrelationScorer.bestCopy(from: videos),
                  let bestAudio = CorrelationScorer.bestCopy(from: audios) else { continue }

            let gid = UUID()
            bestVideo.pairedWith = bestAudio
            bestVideo.pairGroupID = gid
            bestVideo.pairConfidence = .high
            bestAudio.pairedWith = bestVideo
            bestAudio.pairGroupID = gid
            bestAudio.pairConfidence = .high
            paired += 1
            log("  Paired [high] (clipID): \(bestVideo.filename) ↔ \(bestAudio.filename)")
        }

        // Enrich with Avid bin metadata if bins have been scanned
        if !avidBinResults.isEmpty {
            crossReferenceAvidBins()
        }

        correlateStatus = "\(paired) pairs · \(videoOnlyOrphans)V + \(audioOnlyOrphans)A orphans"
        log("""

        Cross-volume Avid correlation complete:
          \(allClipIDs.count) unique clip IDs
          \(paired) pairs matched
          \(videoOnlyOrphans) video-only orphans (no audio found)
          \(audioOnlyOrphans) audio-only orphans (no video found)
        """)

        // Force table refresh
        let tmp = records
        records = []
        records = tmp
    }

    /// Correlate under the analysis-ledger contract
    /// (docs/analysis_ledger_design.md, 2026-07-05):
    ///
    ///   - `selectedIDs == nil` (Correlate All): INCREMENTAL. Existing
    ///     pairs are settled history — only unpaired A/V-only orphans are
    ///     scored. Re-running after a scan processes just the delta; an
    ///     unchanged catalog is a fast no-op. The record IS the ledger
    ///     row: `pairedWith == nil` means "correlation pending".
    ///   - `selectedIDs` non-empty: the user's explicit "redo THESE" —
    ///     the selection is cleared and re-derived (legacy semantics).
    ///   - Full from-scratch redo: `clearAndRecorrelateAll()` only.
    ///
    /// Scoring runs OFF the main actor (CorrelationScorer.assignPairs,
    /// @concurrent) over value snapshots; assignments apply back here in
    /// one batch. Pre-fix this loop blocked the main thread 15.3 s at a
    /// mere 12k records (CorrelateLedgerPerfTests RED run) — a minute+
    /// at catalog scale, all beachball.
    func correlate(selectedIDs: Set<UUID>? = nil) async {
        isCorrelating = true
        correlateStatus = ""
        defer { isCorrelating = false }

        let needsPairing: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            // Explicit selection: clear + re-derive that subset.
            let subset = CorrelationScorer.resolveCorrelateScope(records: records,
                                                                 selectedIDs: ids)
            needsPairing = subset.filter { $0.streamType.needsCorrelation }
        } else {
            // Incremental: unpaired orphans only. No clearing, ever.
            needsPairing = records.filter {
                $0.streamType.needsCorrelation && $0.pairedWith == nil
            }
        }
        let videoSnaps = needsPairing.filter { $0.streamType == .videoOnly }
            .map(CorrelationScorer.snap)
        let audioSnaps = needsPairing.filter { $0.streamType == .audioOnly }
            .map(CorrelationScorer.snap)

        correlateStatus = "\(videoSnaps.count) video + \(audioSnaps.count) audio candidates"
        log("  Correlating \(videoSnaps.count) video-only + \(audioSnaps.count) audio-only files (existing pairs preserved)...")

        // Heavy pass off the main actor.
        let assignments = await CorrelationScorer.assignPairs(
            videos: videoSnaps, audios: audioSnaps,
            durationTolerance: Self.durationTolerance,
            timestampTolerance: Self.timestampTolerance
        )

        // Apply in ONE main-actor batch. The catalog may have moved during
        // the await — a record that got paired or removed in the meantime
        // is skipped (its pairing is settled; ours is stale evidence).
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(needsPairing.count)
        for r in needsPairing { byID[r.id] = r }
        var applied = 0
        var runHigh = 0, runMed = 0, runLow = 0
        var pairLogLines: [String] = []
        for asg in assignments {
            guard let v = byID[asg.videoID], let a = byID[asg.audioID],
                  v.pairedWith == nil, a.pairedWith == nil else { continue }
            let gid = UUID()
            v.pairedWith = a
            v.pairGroupID = gid
            v.pairConfidence = asg.confidence
            a.pairedWith = v
            a.pairGroupID = gid
            a.pairConfidence = asg.confidence
            applied += 1
            switch asg.confidence {
            case .high: runHigh += 1
            case .medium: runMed += 1
            case .low: runLow += 1
            }
            pairLogLines.append("  Paired [\(asg.confidence.rawValue)] (\(asg.reasons.joined(separator: "+"))): \(asg.videoFilename)  \u{2194}  \(asg.audioFilename)")
        }
        // Narrate as ONE log call — per-line log() published the console
        // per pair (the 10ae1be feedback-storm class).
        if !pairLogLines.isEmpty {
            log(pairLogLines.joined(separator: "\n"))
        }

        let stillUnmatched = needsPairing.filter { $0.pairedWith == nil }.count
        correlateStatus = "\(applied) new pairs · \(stillUnmatched) unmatched"
        log("""

        Correlation complete (incremental):
          \(applied) new pairs — \(runHigh) high, \(runMed) medium, \(runLow) low confidence
          \(stillUnmatched) orphans remain pending (re-run after more media is ingested)
        """)

        // One mutation notification replaces the records=[]/records=tmp
        // double-republish: debounced catalog save + dependent-cache
        // invalidation + view refresh all hang off it.
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
    }

    /// The explicit from-scratch action (analysis-ledger design,
    /// 2026-07-05): wipe EVERY pair — including manual ones — and
    /// re-derive the world. This is the only sanctioned full recompute;
    /// `correlate()` itself is incremental.
    func clearAndRecorrelateAll() async {
        for r in records {
            r.pairedWith = nil
            r.pairGroupID = nil
            r.pairConfidence = nil
        }
        await correlate()
    }
}
