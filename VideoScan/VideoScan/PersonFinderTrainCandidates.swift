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
    /// Distinct records that scored positively (before any filter).
    /// The "universe" of catalog-surfaced candidates.
    let candidatesSurfaced: Int
    /// Records collapsed because they were duplicates of another
    /// candidate that was kept (exact dedup + fuzzy dedup combined).
    let dupesCollapsed: Int
    /// Exact-dedup hits — same content by MD5 / duplicateGroupID /
    /// basename+size. Cross-volume copies of the same file.
    let exactDupesCollapsed: Int
    /// Fuzzy-dedup hits — same content across formats (different MD5
    /// and size, but matching duration + creation timestamp). Catches
    /// transcoded copies the exact pass misses. Rick 2026-06-17.
    let fuzzyDupesCollapsed: Int
    /// Records skipped because they have no video track (audio-only
    /// or no-stream). Can't have a visible person, so excluded from
    /// the round. Rick 2026-06-17.
    let audioOnlySkipped: Int
    /// Records skipped because their duration exceeds `durationCapSec`.
    /// Too long → too many people / too many things going on for a
    /// rating to be meaningful. Rick 2026-06-17.
    let tooLongSkipped: Int
    /// The duration cap applied this round, in minutes (for display).
    let durationCapMinutes: Int
    /// Records skipped because their volume isn't currently mounted.
    let offlineSkipped: Int
    let offlineVolumes: [String]
    /// Records skipped because the user already labeled them in a
    /// prior round (idempotency).
    let alreadyLabeled: Int
}

/// Wraps `pfCandidatesForPerson` with the round-assembly policy:
///   - Drop audio-only / no-stream records (can't have a visible
///     person — there's no video track).
///   - Drop records longer than `durationCapSec` (long videos have
///     too many people / too much going on for a rating to be
///     useful — Rick 2026-06-17).
///   - Exact dedup by (md5 OR duplicateGroupID OR basename+size).
///   - Fuzzy dedup by (duration + dateCreated) to catch transcoded
///     copies the exact pass misses (different MD5 + different size
///     but same source content).
///   - Drop offline candidates so the user only rates what they can
///     watch.
///   - Drop already-labeled candidates (idempotency).
///   - Cap to `topN` highest-score positives + `controlK` random
///     controls with no signal.
///
/// Returns both the candidates AND the stats so the setup pane can
/// surface counts like "180 candidates · 47 dupes collapsed · 12
/// offline · 5 too long · 3 audio-only".
nonisolated func pfConfirmRound(
    name: String,
    records: [VideoRecord],
    topN: Int,
    controlK: Int,
    alreadyLabeled: Set<String>,
    durationCapSec: Double = 3600,   // 60 min default
    skipAudioOnly: Bool = true,
    rng: inout SystemRandomNumberGenerator
) -> (candidates: [PersonCandidateScore], stats: ConfirmRoundStats) {
    let scoredAll = pfCandidatesForPerson(name: name, records: records)
    let candidatesSurfaced = scoredAll.count
    let alreadyLabeledMatches = scoredAll.filter { alreadyLabeled.contains($0.recordPath) }.count

    let fresh = scoredAll.filter { !alreadyLabeled.contains($0.recordPath) }

    // Build path → rec lookup; reused by every filter / dedup pass.
    var byPath: [String: VideoRecord] = [:]
    byPath.reserveCapacity(records.count)
    for rec in records { byPath[rec.fullPath] = rec }

    // --- Audio-only / no-stream filter ---
    // Records without a video track can't have a visible person, so
    // they don't belong in a visual-confirmation round. Strictly
    // pre-dedup so we don't lose a video-track copy to an audio-only
    // duplicate winning the canonical slot.
    var audioOnlySkipped = 0
    let withVideoTrack: [PersonCandidateScore]
    if skipAudioOnly {
        withVideoTrack = fresh.filter { cand in
            guard let rec = byPath[cand.recordPath] else { return true }
            let st = rec.streamType
            let hasVideo = (st == .videoAndAudio || st == .videoOnly)
            if !hasVideo { audioOnlySkipped += 1 }
            return hasVideo
        }
    } else {
        withVideoTrack = fresh
    }

    // --- Duration cap filter ---
    // Records longer than the cap are excluded with a counted skip.
    // durationSeconds == 0 means "unknown" — we KEEP those rather
    // than penalize records where the probe couldn't measure
    // duration (e.g., legacy codecs).
    var tooLongSkipped = 0
    let withinDuration = withVideoTrack.filter { cand in
        guard let rec = byPath[cand.recordPath] else { return true }
        let dur = rec.durationSeconds
        if dur > 0 && dur > durationCapSec {
            tooLongSkipped += 1
            return false
        }
        return true
    }

    // --- Exact dedup pass ---
    // Group by MD5 → duplicateGroupID → basename+size. Catches
    // cross-volume copies of the same byte-stream.
    var byExactKey: [String: PersonCandidateScore] = [:]
    var exactDupesCollapsed = 0
    for cand in withinDuration {
        let rec = byPath[cand.recordPath]
        let key = dedupKey(for: rec, fallback: cand.filename)
        if let existing = byExactKey[key] {
            exactDupesCollapsed += 1
            if preferReplace(cand: cand, existing: existing) {
                byExactKey[key] = cand
            }
        } else {
            byExactKey[key] = cand
        }
    }
    let exactDeduped = Array(byExactKey.values)

    // --- Fuzzy dedup pass ---
    // Same source content in different formats: same duration, very
    // close creation timestamp, but different MD5 + size. Bucket by
    // (duration in 0.5s, date in 60s). Records missing either
    // duration or dateCreated get a path-unique key so they can't
    // accidentally collapse together. Rick 2026-06-17.
    var byFuzzyKey: [String: PersonCandidateScore] = [:]
    var fuzzyDupesCollapsed = 0
    for cand in exactDeduped {
        let rec = byPath[cand.recordPath]
        let key = fuzzyDedupKey(for: rec, fallbackPath: cand.recordPath)
        if let existing = byFuzzyKey[key] {
            fuzzyDupesCollapsed += 1
            if preferReplace(cand: cand, existing: existing) {
                byFuzzyKey[key] = cand
            }
        } else {
            byFuzzyKey[key] = cand
        }
    }
    let deduped = Array(byFuzzyKey.values).sorted { $0.score > $1.score }

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
        dupesCollapsed: exactDupesCollapsed + fuzzyDupesCollapsed,
        exactDupesCollapsed: exactDupesCollapsed,
        fuzzyDupesCollapsed: fuzzyDupesCollapsed,
        audioOnlySkipped: audioOnlySkipped,
        tooLongSkipped: tooLongSkipped,
        durationCapMinutes: Int(durationCapSec / 60),
        offlineSkipped: offlineCandidates.count,
        offlineVolumes: offlineVolumes,
        alreadyLabeled: alreadyLabeledMatches
    )
    return (positives + controlScores, stats)
}

/// Replace-existing predicate for the dedup passes: reachable wins
/// over offline; score breaks ties.
nonisolated private func preferReplace(
    cand: PersonCandidateScore,
    existing: PersonCandidateScore
) -> Bool {
    if cand.reachable && !existing.reachable { return true }
    if existing.reachable && !cand.reachable { return false }
    return cand.score > existing.score
}

/// Bucket records by (duration ≈ 0.5s, dateCreated ≈ 60s) to catch
/// transcoded copies the exact dedup pass misses — same source media
/// re-encoded as ProRes / HEVC / DV will have identical playback
/// duration and very close creation timestamps even when MD5 and
/// basename differ. Records that lack EITHER duration or
/// dateCreatedRaw get a path-unique key so they don't accidentally
/// collapse together.
nonisolated private func fuzzyDedupKey(for rec: VideoRecord?, fallbackPath: String) -> String {
    guard let rec, rec.durationSeconds > 0, let d = rec.dateCreatedRaw else {
        return "fpath:\(fallbackPath)"
    }
    let durKey = Int(rec.durationSeconds * 2)
    let dateKey = Int(d.timeIntervalSince1970 / 60)
    return "fuzzy:\(durKey)|\(dateKey)"
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
