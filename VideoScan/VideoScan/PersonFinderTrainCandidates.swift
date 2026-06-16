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

/// Stats reported back to the UI alongside the round itself, so the
/// setup pane can show the user what was filtered out and why.
struct ConfirmRoundStats {
    /// Distinct records that scored positively (before dedup or
    /// offline filtering). The "universe" of catalog-surfaced
    /// candidates.
    let candidatesSurfaced: Int
    /// Records collapsed because they were duplicates of another
    /// candidate that was kept (e.g., same MP4 on three different
    /// volumes). Surfaced so the user knows how aggressive dedup was.
    let dupesCollapsed: Int
    /// Records skipped because their volume isn't currently mounted.
    /// We surface the count AND the list of volume names so the user
    /// can decide whether to plug something in and re-run.
    let offlineSkipped: Int
    let offlineVolumes: [String]
    /// Records skipped because the user already labeled them in a
    /// prior round (idempotency).
    let alreadyLabeled: Int
}

/// Wraps `pfCandidatesForPerson` with the round-assembly policy:
///   - Dedup by (md5 OR duplicateGroupID OR basename+size) — keep one
///     canonical per group; prefer reachable + highest-score.
///   - Drop offline candidates so the user only rates what they can
///     watch.
///   - Drop already-labeled candidates (idempotency).
///   - Cap to `topN` highest-score positives + `controlK` random
///     controls with no signal.
///
/// Returns both the candidates AND the stats so the setup pane can
/// surface counts like "180 candidates · 47 dupes collapsed · 12
/// offline."
nonisolated func pfConfirmRound(
    name: String,
    records: [VideoRecord],
    topN: Int,
    controlK: Int,
    alreadyLabeled: Set<String>,
    rng: inout SystemRandomNumberGenerator
) -> (candidates: [PersonCandidateScore], stats: ConfirmRoundStats) {
    let scoredAll = pfCandidatesForPerson(name: name, records: records)
    let candidatesSurfaced = scoredAll.count
    let alreadyLabeledMatches = scoredAll.filter { alreadyLabeled.contains($0.recordPath) }.count

    let fresh = scoredAll.filter { !alreadyLabeled.contains($0.recordPath) }

    // --- Dedup pass ---
    // Group by an identity key that survives cross-volume duplicates.
    // Prefer MD5 (when probed) → duplicateGroupID (when correlated) →
    // basename+size (last-resort heuristic). Keep one representative
    // per group: reachable wins over offline, higher score wins ties.
    var byKey: [String: PersonCandidateScore] = [:]
    var dupesCollapsed = 0
    // We need the underlying VideoRecord to look up md5 /
    // duplicateGroupID / sizeBytes, so build a path → record map.
    var byPath: [String: VideoRecord] = [:]
    byPath.reserveCapacity(records.count)
    for rec in records { byPath[rec.fullPath] = rec }

    for cand in fresh {
        let rec = byPath[cand.recordPath]
        let key = dedupKey(for: rec, fallback: cand.filename)
        if let existing = byKey[key] {
            dupesCollapsed += 1
            // Replace if this one is preferable (reachable wins over
            // offline; higher score wins ties).
            let replace: Bool = {
                if cand.reachable && !existing.reachable { return true }
                if existing.reachable && !cand.reachable { return false }
                return cand.score > existing.score
            }()
            if replace { byKey[key] = cand }
        } else {
            byKey[key] = cand
        }
    }

    let deduped = Array(byKey.values).sorted { $0.score > $1.score }

    // --- Offline filter ---
    let offlineCandidates = deduped.filter { !$0.reachable }
    let offlineVolumes = Array(Set(offlineCandidates.compactMap { volumeName(from: $0.recordPath) })).sorted()
    let online = deduped.filter { $0.reachable }

    // --- Cap to topN ---
    let positives = Array(online.prefix(topN))

    // --- Controls: records with NO signal for this person ---
    let n = name.lowercased()
    let scoredPaths = Set(scoredAll.map { $0.recordPath })
    var controlPool: [VideoRecord] = []
    controlPool.reserveCapacity(min(records.count, 1024))
    for rec in records where !scoredPaths.contains(rec.fullPath)
        && !alreadyLabeled.contains(rec.fullPath) {
        if rec.filename.lowercased().contains(n) { continue }
        if rec.directory.lowercased().contains(n) { continue }
        let st = rec.streamType
        guard st == .videoAndAudio || st == .videoOnly else { continue }
        guard VolumeReachability.isReachable(path: rec.fullPath) else { continue }
        controlPool.append(rec)
    }
    var controls: [VideoRecord] = []
    var pool = controlPool
    let target = min(controlK, pool.count)
    while controls.count < target && !pool.isEmpty {
        let idx = Int.random(in: 0..<pool.count, using: &rng)
        controls.append(pool.remove(at: idx))
    }
    let controlScores = controls.map {
        PersonCandidateScore(
            recordID: $0.id, recordPath: $0.fullPath, filename: $0.filename,
            score: 0, signals: ["control"], reachable: true
        )
    }

    let stats = ConfirmRoundStats(
        candidatesSurfaced: candidatesSurfaced,
        dupesCollapsed: dupesCollapsed,
        offlineSkipped: offlineCandidates.count,
        offlineVolumes: offlineVolumes,
        alreadyLabeled: alreadyLabeledMatches
    )
    return (positives + controlScores, stats)
}

/// Build a dedup key from the strongest available identity signal.
/// Order of preference:
///   1. Non-empty md5  — content-identical files share this even
///      across format changes? No: MD5 is over bytes, format changes
///      will produce different MD5s. Still strongest cross-volume
///      signal for verbatim copies.
///   2. duplicateGroupID — set by the existing DuplicateDetector pass.
///      Groups files the catalog considers "same content."
///   3. basename + size — last-resort heuristic for files that
///      haven't been hashed or duplicate-detected yet.
nonisolated private func dedupKey(for rec: VideoRecord?, fallback filename: String) -> String {
    if let rec {
        if !rec.partialMD5.isEmpty { return "md5:\(rec.partialMD5)" }
        if let dgid = rec.duplicateGroupID { return "dgid:\(dgid)" }
        return "bn-size:\(rec.filename.lowercased())|\(rec.sizeBytes)"
    }
    return "bn:\(filename.lowercased())"
}

nonisolated private func volumeName(from path: String) -> String? {
    guard path.hasPrefix("/Volumes/") else { return nil }
    let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    return String(parts[1])
}
