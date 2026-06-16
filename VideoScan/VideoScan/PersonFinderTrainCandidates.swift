// PersonFinderTrainCandidates.swift
// Catalog-only scoring for "which records likely contain person X."
// Used by the Confirm-Person workflow to surface a small ranked
// candidate list to the user — instead of forcing them to either
// (a) watch every video in the library, or (b) trust PF face inference
// alone (which we now know has ~5% recall on the home video corpus).
//
// Inputs are pure catalog metadata: filename, directory, transcript,
// scene captions, OCR text, existing PF tags. No face inference, no
// disk reads — runs in ~1-2 seconds over 16K records on M4.
//
// Rick 2026-06-16. Mirrors the Python prototype that surfaced 340
// Donna candidates from a catalog where PF had tagged only 19 — that
// experiment was the gating reason for shipping this verb at all.

import Foundation

// MARK: - Scored candidate

struct PersonCandidateScore: Equatable, Identifiable {
    /// The record id (UUID) used by the sheet UI for selection /
    /// indexed lookup. Mirrors VideoRecord.id.
    let recordID: UUID
    /// Path at scoring time. The sheet uses this for thumbnail + the
    /// ValidationLabel store keys by it.
    let recordPath: String
    /// Display name (basename) so the sheet doesn't need to chase the
    /// record through the model.
    let filename: String
    /// Higher = more likely contains the person. Comparable across
    /// candidates only; absolute value is heuristic.
    let score: Int
    /// Human-readable list of catalog signals that contributed score:
    /// `["filename", "transcript×10", "PF-tagged"]`. Both displayed
    /// in the UI ("here's why we surfaced this") and persisted on the
    /// ValidationLabel for later precision-by-signal analysis.
    let signals: [String]
    /// Whether the file is currently reachable (volume mounted). Used
    /// by the sheet to skip-or-warn on offline candidates.
    let reachable: Bool

    var id: UUID { recordID }
}

// MARK: - Scoring

/// Score every record in `records` for "likely contains `name`," sorted
/// by descending score. Records that score zero are excluded. The
/// returned array is suitable for direct surfacing in the Confirm UI
/// (cap to top-N at the call site).
///
/// nonisolated so callers can dispatch this onto a background queue
/// for big catalogs without an actor hop.
nonisolated func pfCandidatesForPerson(
    name: String,
    records: [VideoRecord]
) -> [PersonCandidateScore] {
    let n = name.lowercased()
    guard !n.isEmpty else { return [] }

    var out: [PersonCandidateScore] = []
    out.reserveCapacity(min(records.count, 256))

    for rec in records {
        var score = 0
        var signals: [String] = []

        // Existing PF tags — strongest signal. Treat detected /
        // suspected / confirmedByUserPeople differently; user
        // confirmations get the highest weight because they're already
        // ground truth.
        if rec.confirmedByUserPeople.contains(where: { $0.name.lowercased() == n }) {
            score += 25; signals.append("user-confirmed")
        }
        if rec.suspectedPeople.contains(where: { $0.lowercased() == n }) {
            score += 15; signals.append("PF-suspected")
        }
        if rec.detectedPeople.contains(where: { $0.lowercased() == n }) {
            score += 10; signals.append("PF-tagged")
        }

        // Path-level signals.
        if rec.filename.lowercased().contains(n) {
            score += 10; signals.append("filename")
        }
        if rec.directory.lowercased().contains(n) {
            score += 5; signals.append("directory")
        }

        // Transcript — count occurrences for a signal strength cue.
        if let transcript = rec.audioTranscript, !transcript.isEmpty {
            let count = countOccurrences(of: n, in: transcript.lowercased())
            if count > 0 {
                let bumped = min(10, 2 * count)
                score += bumped
                signals.append("transcript×\(count)")
            }
        }

        // Scene captions (VLM output).
        var captionHits = 0
        for cap in rec.sceneCaptions {
            captionHits += countOccurrences(of: n, in: cap.text.lowercased())
        }
        if captionHits > 0 {
            score += min(10, 2 * captionHits)
            signals.append("captions×\(captionHits)")
        }

        // OCR text — birthday cards, name tags, signs.
        var ocrHits = 0
        for hit in rec.ocrText {
            ocrHits += countOccurrences(of: n, in: hit.text.lowercased())
        }
        for hit in rec.ocrDateCandidates {
            ocrHits += countOccurrences(of: n, in: hit.text.lowercased())
        }
        if ocrHits > 0 {
            score += min(5, ocrHits)
            signals.append("ocr×\(ocrHits)")
        }

        guard score > 0 else { continue }

        out.append(PersonCandidateScore(
            recordID: rec.id,
            recordPath: rec.fullPath,
            filename: rec.filename,
            score: score,
            signals: signals,
            reachable: VolumeReachability.isReachable(path: rec.fullPath)
        ))
    }

    out.sort { $0.score > $1.score }
    return out
}

/// Cheap occurrence counter — both inputs already lowercased.
nonisolated private func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var search = haystack[...]
    while let r = search.range(of: needle) {
        count += 1
        search = search[r.upperBound...]
    }
    return count
}

// MARK: - Round assembly

/// Convenience that wraps `pfCandidatesForPerson` with the policy
/// Rick chose for v1: take the top N by score, plus K random low-
/// score "control" records (score == 0) so each round has a built-in
/// false-positive control. Excludes records the user has already
/// rated in a prior round.
///
/// `topN` and `controlK` chosen at the call site so the sheet can
/// expose them as preferences later if needed.
nonisolated func pfConfirmRound(
    name: String,
    records: [VideoRecord],
    topN: Int,
    controlK: Int,
    alreadyLabeled: Set<String>,
    rng: inout SystemRandomNumberGenerator
) -> [PersonCandidateScore] {
    let scored = pfCandidatesForPerson(name: name, records: records)
        .filter { !alreadyLabeled.contains($0.recordPath) }

    let positives = Array(scored.prefix(topN))

    // Build the control pool: records with NO signal for this person,
    // not already labeled, video-only stream types (skip audio-only).
    let n = name.lowercased()
    let scoredPaths = Set(scored.map { $0.recordPath })
    var controlPool: [VideoRecord] = []
    controlPool.reserveCapacity(min(records.count, 1024))
    for rec in records where !scoredPaths.contains(rec.fullPath)
        && !alreadyLabeled.contains(rec.fullPath) {
        // Quick reject: don't even consider records whose haystack
        // looks like it might contain the person. Cheap to check.
        if rec.filename.lowercased().contains(n) { continue }
        if rec.directory.lowercased().contains(n) { continue }
        let st = rec.streamType
        guard st == .videoAndAudio || st == .videoOnly else { continue }
        guard VolumeReachability.isReachable(path: rec.fullPath) else { continue }
        controlPool.append(rec)
    }

    // Random sample K controls without replacement. nonisolated so we
    // accept the RNG as inout from the caller.
    var controls: [VideoRecord] = []
    var pool = controlPool
    let target = min(controlK, pool.count)
    while controls.count < target && !pool.isEmpty {
        let idx = Int.random(in: 0..<pool.count, using: &rng)
        controls.append(pool.remove(at: idx))
    }

    let controlScores = controls.map {
        PersonCandidateScore(
            recordID: $0.id,
            recordPath: $0.fullPath,
            filename: $0.filename,
            score: 0,
            signals: ["control"],
            reachable: true
        )
    }

    // Positives first (highest score → lowest), then controls
    // interleaved so the user gets variety. For v1 just append; we
    // can shuffle controls in if user feedback says the run feels
    // monotone.
    return positives + controlScores
}
