import Foundation

/// Multi-signal audio/video pair correlation engine.
/// Scores candidate pairs using filename, duration, timestamp, timecode,
/// directory, and tape name — then greedily assigns best matches.
enum Correlator {

    // MARK: - Configuration

    /// Duration tolerance for matching (seconds).
    static let durationTolerance: Double = 1.0

    /// Timestamp tolerance for matching (seconds).
    static let timestampTolerance: TimeInterval = 5.0

    /// Minimum score required to consider a pair (at least one strong signal).
    static let minimumScore = 3

    // MARK: - Correlation

    /// Correlate records, optionally limited to a selection.
    /// Mutates pairing properties on each `VideoRecord` in place.
    /// Returns a summary string for console logging.
    @discardableResult
    static func correlate(
        records: [VideoRecord],
        selectedIDs: Set<UUID>? = nil
    ) -> String {
        let scope: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
            for r in scope {
                r.pairedWith = nil
                r.pairGroupID = nil
                r.pairConfidence = nil
            }
        } else {
            scope = records
            for r in records {
                r.pairedWith = nil
                r.pairGroupID = nil
                r.pairConfidence = nil
            }
        }

        let needsPairing = scope.filter { $0.streamType.needsCorrelation }
        let allVideos = needsPairing.filter { $0.streamType == .videoOnly }
        let allAudios = needsPairing.filter { $0.streamType == .audioOnly }
        var matched = Set<UUID>()
        var logLines: [String] = []

        logLines.append("  Correlating \(allVideos.count) video-only + \(allAudios.count) audio-only files...")

        // Score every possible video↔audio pair
        var candidates: [Candidate] = []

        for v in allVideos {
            for a in allAudios {
                var score = 0
                var reasons: [String] = []

                // Signal 1: Filename similarity (strongest — Avid V/A prefix convention)
                if filenameCorrelationKey(v.filename) == filenameCorrelationKey(a.filename) {
                    score += 4
                    reasons.append("filename")
                }

                // Signal 2: Duration match
                if v.durationSeconds > 0 && a.durationSeconds > 0 &&
                   abs(v.durationSeconds - a.durationSeconds) <= durationTolerance {
                    score += 3
                    reasons.append("duration")
                }

                // Signal 3: Timestamp match
                if let vDate = v.dateCreatedRaw, let aDate = a.dateCreatedRaw,
                   abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance {
                    score += 3
                    reasons.append("timestamp")
                }

                // Signal 4: Timecode match
                if !v.timecode.isEmpty && v.timecode == a.timecode {
                    score += 2
                    reasons.append("timecode")
                }

                // Signal 5: Same directory
                if v.directory == a.directory {
                    score += 1
                    reasons.append("directory")
                }

                // Signal 6: Tape name match
                if !v.tapeName.isEmpty && v.tapeName == a.tapeName {
                    score += 1
                    reasons.append("tape")
                }

                guard score >= minimumScore else { continue }

                let confidence: PairConfidence
                if score >= 7 { confidence = .high } else if score >= 4 { confidence = .medium } else { confidence = .low }

                candidates.append(Candidate(
                    video: v, audio: a, score: score,
                    confidence: confidence, reasons: reasons
                ))
            }
        }

        // Greedy assignment from highest score down
        candidates.sort { $0.score > $1.score }

        for c in candidates {
            guard !matched.contains(c.video.id) && !matched.contains(c.audio.id) else { continue }

            let gid = UUID()
            c.video.pairedWith = c.audio
            c.video.pairGroupID = gid
            c.video.pairConfidence = c.confidence
            c.audio.pairedWith = c.video
            c.audio.pairGroupID = gid
            c.audio.pairConfidence = c.confidence
            matched.insert(c.video.id)
            matched.insert(c.audio.id)

            logLines.append(
                "  Paired [\(c.confidence.rawValue)] " +
                "(\(c.reasons.joined(separator: "+"))): " +
                "\(c.video.filename)  ↔  \(c.audio.filename)"
            )
        }

        let totalPairs     = matched.count / 2
        let highCount      = records.filter { $0.pairConfidence == .high }.count / 2
        let medCount       = records.filter { $0.pairConfidence == .medium }.count / 2
        let lowCount       = records.filter { $0.pairConfidence == .low }.count / 2
        let stillUnmatched = needsPairing.filter { !matched.contains($0.id) }.count

        logLines.append("""

        Correlation complete:
          \(totalPairs) pairs — \(highCount) high, \(medCount) medium, \(lowCount) low confidence
          \(stillUnmatched) unmatched
        """)

        return logLines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Normalize filename by stripping V/A prefix (Avid MXF convention).
    /// Only strips when followed by hex digits (e.g., V01A23BC.mxf → _01A23BC.mxf).
    static func filenameCorrelationKey(_ filename: String) -> String {
        var parts = filename.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        for i in parts.indices {
            let p = parts[i]
            if p.count > 1,
               let first = p.first,
               first == "V" || first == "A" || first == "v" || first == "a",
               p.dropFirst().allSatisfy({ $0.isHexDigit }) {
                parts[i] = "_" + p.dropFirst()
                break
            }
        }
        return parts.joined(separator: ".")
    }

    /// Extract all correlated pairs from a record array (video first in tuple).
    static func correlatedPairs(from records: [VideoRecord]) -> [(video: VideoRecord, audio: VideoRecord)] {
        var seen = Set<UUID>()
        var pairs: [(VideoRecord, VideoRecord)] = []
        for rec in records {
            guard let partner = rec.pairedWith, !seen.contains(rec.id) else { continue }
            seen.insert(rec.id)
            seen.insert(partner.id)
            let v = rec.streamType == .videoOnly ? rec : partner
            let a = rec.streamType == .audioOnly ? rec : partner
            pairs.append((v, a))
        }
        return pairs
    }

    // MARK: - Private Types

    private struct Candidate {
        let video: VideoRecord
        let audio: VideoRecord
        let score: Int
        let confidence: PairConfidence
        let reasons: [String]
    }
}
