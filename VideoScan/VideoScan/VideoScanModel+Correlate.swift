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

    /// Correlate all records, or only those whose IDs are in `selectedIDs` (if non-nil/non-empty).
    func correlate(selectedIDs: Set<UUID>? = nil) {
        isCorrelating = true
        correlateStatus = ""
        defer { isCorrelating = false }

        let scope = CorrelationScorer.resolveCorrelateScope(records: records, selectedIDs: selectedIDs)
        let needsPairing = scope.filter { $0.streamType.needsCorrelation }
        let allVideos = needsPairing.filter { $0.streamType == .videoOnly }
        let allAudios = needsPairing.filter { $0.streamType == .audioOnly }

        correlateStatus = "\(allVideos.count) video + \(allAudios.count) audio candidates"
        log("  Correlating \(allVideos.count) video-only + \(allAudios.count) audio-only files...")

        let pools = CorrelationScorer.buildAudioPools(from: allAudios)
        var candidates: [CorrelationScorer.Candidate] = []
        for v in allVideos {
            let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
            let audioPool = CorrelationScorer.gatherCandidateAudios(
                for: v, vKey: vKey, allAudios: allAudios,
                byKey: pools.byKey, byDir: pools.byDir,
                durationTolerance: Self.durationTolerance,
                timestampTolerance: Self.timestampTolerance
            )
            for a in audioPool {
                if let candidate = CorrelationScorer.scoreCorrelatePair(
                    video: v, audio: a, vKey: vKey,
                    durationTolerance: Self.durationTolerance,
                    timestampTolerance: Self.timestampTolerance
                ) {
                    candidates.append(candidate)
                }
            }
        }

        var matched = Set<UUID>()
        let logLines = CorrelationScorer.assignCandidates(candidates, matched: &matched)
        for line in logLines { log(line) }

        let totalPairs     = matched.count / 2
        let highCount      = records.filter { $0.pairConfidence == .high }.count / 2
        let medCount       = records.filter { $0.pairConfidence == .medium }.count / 2
        let lowCount       = records.filter { $0.pairConfidence == .low }.count / 2
        let stillUnmatched = needsPairing.filter { !matched.contains($0.id) }.count
        correlateStatus = "\(totalPairs) pairs · \(stillUnmatched) unmatched"
        log("""

        Correlation complete:
          \(totalPairs) pairs — \(highCount) high, \(medCount) medium, \(lowCount) low confidence
          \(stillUnmatched) unmatched
        """)

        // Force table refresh
        let tmp = records
        records = []
        records = tmp
    }
}
