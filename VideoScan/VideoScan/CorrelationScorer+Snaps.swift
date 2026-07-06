// CorrelationScorer+Snaps.swift
// Off-main correlation pipeline over Sendable value snapshots — the
// analysis-ledger arc (docs/analysis_ledger_design.md, 2026-07-05).
//
// The legacy correlate path ran the full videos × candidate-audios
// scoring loop on the main actor: a 15.3 s worst main-thread hop at a
// mere 12k records (CorrelateLedgerPerfTests, RED run), a full minute+
// on Rick's 103k catalog. The scoring math is pure — only the record
// mutation needs the main actor. So: snapshot the six scoring signals
// on main, run pooling/scoring/greedy-assignment `@concurrent`, return
// value assignments, and let the model apply them on main in one batch.
//
// The record-based helpers in CorrelationScorer.swift stay for the
// single-file findBestPair path and existing tests; the scoring rubric
// lives in ONE place (`scoreParts`) shared by both.

import Foundation

extension CorrelationScorer {

    // MARK: - Sendable snapshots

    /// The signals `scoreCorrelatePair` reads, captured as values on the
    /// main actor so the scoring pass can run off it.
    struct Snap: Sendable {
        let id: UUID
        let filename: String
        let directory: String
        let durationSeconds: Double
        let dateCreatedRaw: Date?
        let timecode: String
        let tapeName: String
    }

    /// Main-actor boundary: capture one record's scoring signals.
    @MainActor
    static func snap(_ r: VideoRecord) -> Snap {
        Snap(id: r.id,
             filename: r.filename,
             directory: r.directory,
             durationSeconds: r.durationSeconds,
             dateCreatedRaw: r.dateCreatedRaw,
             timecode: r.timecode,
             tapeName: r.tapeName)
    }

    /// One pairing decision, ready to apply on the main actor. Filenames
    /// ride along so the apply step can narrate without re-lookup.
    struct PairAssignment: Sendable {
        let videoID: UUID
        let audioID: UUID
        let confidence: PairConfidence
        let reasons: [String]
        let videoFilename: String
        let audioFilename: String
    }

    // MARK: - Shared scoring rubric

    /// The ONE place the correlation rubric lives (filename 4 /
    /// duration 3 / timestamp 3 / timecode 2 / directory 1 / tape 1,
    /// floor 3). Both the record path (`scoreCorrelatePair`) and the
    /// snap path below delegate here.
    static func scoreParts(
        vKey: String, audioFilename: String,
        vDuration: Double, aDuration: Double,
        vDate: Date?, aDate: Date?,
        vTimecode: String, aTimecode: String,
        vDirectory: String, aDirectory: String,
        vTape: String, aTape: String,
        durationTolerance: Double,
        timestampTolerance: TimeInterval
    ) -> (score: Int, confidence: PairConfidence, reasons: [String])? {
        var score = 0
        var reasons: [String] = []
        if vKey == filenameCorrelationKey(audioFilename) { score += 4; reasons.append("filename") }
        if vDuration > 0 && aDuration > 0 &&
           abs(vDuration - aDuration) <= durationTolerance {
            score += 3; reasons.append("duration")
        }
        if let vDate, let aDate,
           abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance {
            score += 3; reasons.append("timestamp")
        }
        if !vTimecode.isEmpty && vTimecode == aTimecode {
            score += 2; reasons.append("timecode")
        }
        if vDirectory == aDirectory { score += 1; reasons.append("directory") }
        if !vTape.isEmpty && vTape == aTape {
            score += 1; reasons.append("tape")
        }
        guard score >= 3 else { return nil }
        let confidence: PairConfidence
        if score >= 7 { confidence = .high } else if score >= 4 { confidence = .medium } else { confidence = .low }
        return (score, confidence, reasons)
    }

    // MARK: - Off-main pipeline

    /// The full pooling → scoring → greedy-assignment pass, off the main
    /// actor. Pure over the input snapshots; returns value assignments.
    /// Mirrors the legacy pipeline exactly: same pools (by key, by dir,
    /// thin-pool duration/timestamp fallback), same rubric, same
    /// greedy-by-score claim order.
    @concurrent
    static func assignPairs(
        videos: [Snap],
        audios: [Snap],
        durationTolerance: Double,
        timestampTolerance: TimeInterval
    ) async -> [PairAssignment] {
        // Pools (legacy buildAudioPools shape).
        var byKey: [String: [Int]] = [:]
        var byDir: [String: [Int]] = [:]
        for (i, a) in audios.enumerated() {
            byKey[filenameCorrelationKey(a.filename), default: []].append(i)
            byDir[a.directory, default: []].append(i)
        }

        struct SnapCandidate {
            let vIndex: Int
            let aIndex: Int
            let score: Int
            let confidence: PairConfidence
            let reasons: [String]
        }
        var candidates: [SnapCandidate] = []

        for (vi, v) in videos.enumerated() {
            let vKey = filenameCorrelationKey(v.filename)
            // Gather (legacy gatherCandidateAudios shape).
            var seen = Set<Int>()
            var pool: [Int] = []
            for ai in byKey[vKey] ?? [] where seen.insert(ai).inserted { pool.append(ai) }
            for ai in byDir[v.directory] ?? [] where seen.insert(ai).inserted { pool.append(ai) }
            if pool.count < 5 {
                for (ai, a) in audios.enumerated() where !seen.contains(ai) {
                    let durationHit = v.durationSeconds > 0 && a.durationSeconds > 0 &&
                        abs(v.durationSeconds - a.durationSeconds) <= durationTolerance
                    let timestampHit: Bool
                    if let vDate = v.dateCreatedRaw, let aDate = a.dateCreatedRaw {
                        timestampHit = abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance
                    } else {
                        timestampHit = false
                    }
                    if (durationHit || timestampHit) && seen.insert(ai).inserted {
                        pool.append(ai)
                    }
                }
            }
            // Score.
            for ai in pool {
                let a = audios[ai]
                if let (score, confidence, reasons) = scoreParts(
                    vKey: vKey, audioFilename: a.filename,
                    vDuration: v.durationSeconds, aDuration: a.durationSeconds,
                    vDate: v.dateCreatedRaw, aDate: a.dateCreatedRaw,
                    vTimecode: v.timecode, aTimecode: a.timecode,
                    vDirectory: v.directory, aDirectory: a.directory,
                    vTape: v.tapeName, aTape: a.tapeName,
                    durationTolerance: durationTolerance,
                    timestampTolerance: timestampTolerance
                ) {
                    candidates.append(SnapCandidate(vIndex: vi, aIndex: ai,
                                                    score: score,
                                                    confidence: confidence,
                                                    reasons: reasons))
                }
            }
        }

        // Greedy max-score assignment (legacy assignCandidates shape).
        var vMatched = Set<Int>()
        var aMatched = Set<Int>()
        var out: [PairAssignment] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            guard !vMatched.contains(c.vIndex), !aMatched.contains(c.aIndex) else { continue }
            vMatched.insert(c.vIndex)
            aMatched.insert(c.aIndex)
            out.append(PairAssignment(videoID: videos[c.vIndex].id,
                                      audioID: audios[c.aIndex].id,
                                      confidence: c.confidence,
                                      reasons: c.reasons,
                                      videoFilename: videos[c.vIndex].filename,
                                      audioFilename: audios[c.aIndex].filename))
        }
        return out
    }
}
