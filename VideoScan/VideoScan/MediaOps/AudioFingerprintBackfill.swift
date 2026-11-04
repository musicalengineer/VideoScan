// AudioFingerprintBackfill.swift
// "Fingerprint Sound…" — the values and the planner (Rick 2026-10-14: "run
// fingerprint like we did SHA-256: let it run overnight and see how far we
// get"). Every active catalog record without a CURRENT audio-fingerprint
// stamp gets one, so a later "is this clip cut from that tape?" question is
// a sidecar lookup, not a decode.
//
// Shape (the Fill In Full Hashes shape, FullHashBackfill.swift):
//   • PLAN (this file, main actor, one O(records) pass, NO I/O): group the
//     records that need a look into LANES, one per volume root; inside a
//     lane the archived files come first, then the rest, each in path
//     order. The need rule is the stamp's: `AudioFingerprintStamp.describes`
//     (same size, keyed on the record's PREFERRED digest, a stamp version
//     this build trusts — judged against the row's audio codec: a version-2
//     "no sound" stamp on a row whose header has sound was a decode
//     failure and is redone, Verify Catalog bug 2 2026-10-17) → skip,
//     whatever its outcome — fingerprinted, no sound, or partial. Only a
//     full "sha256:" digest is an identity; a sampled "v1:" key is good
//     enough for the record's OWN stamp but never for sharing.
//     Because a stamped record is skipped, running again after a stop, quit
//     or crash IS the resume: no resume file exists for this job.
//   • RUN (AudioFingerprintBackfillJob.swift): lanes in parallel, one decode
//     per volume at a time, under a memory budget (`AudioDecodeBudget`).
//   • "Shared" is decided at run time, not here: the job asks the sidecar
//     whether the record's digest already has a fingerprint (a copy was
//     done earlier) and stamps without decoding. The plan cannot know that
//     without I/O, so the sheet counts it under "need a look".
//
// Active = not removed (purged), not superseded, pointing at a file with a
// size. Set-aside ("hidden") rows ARE included: they are the copies a later
// Cleanup wants matched against a master. A record with NO digest at all
// (never hashed by a scan) cannot key the sidecar — counted, not planned.
//
// Memory: one item (~150 bytes) per record needing a look — ~15 MB at 100k —
// plus a dictionary of lanes keyed by volume root.

import Foundation
import VideoScanCore

// MARK: - Plan (values)

/// One file the job will look at — plain values captured on the main actor,
/// safe to hand to the off-main decode. (≈ a C++ POD; `VideoRecord` itself,
/// a main-actor class, never crosses.)
struct AudioFingerprintBackfillItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String
    let filename: String
    let sizeBytes: Int64
    /// Catalog duration (0 = unknown); sizes the memory budget and decides
    /// `complete`.
    let durationSeconds: Double
    /// The catalog already knows there is no sound track — stamped without
    /// a decode (only when `audioCodec` is empty too).
    let isVideoOnly: Bool
    /// The row's audio codec from its probe ("" = the header reports no
    /// audio stream). THE evidence a "no sound" stamp needs: zero samples
    /// from a file whose header names a codec is a failed decode, never a
    /// verdict (design: integrity_first §2).
    let audioCodec: String
    /// A Master Archive file (planned first within its drive).
    let isArchived: Bool
    /// Digests the record carries, preferred first ("sha256:…", then "v1:…").
    /// Never empty for a planned item.
    let digests: [String]

    /// The sidecar key this run writes under.
    var key: AudioFingerprintStore.Key { .init(contentDigest: digests[0], sizeBytes: sizeBytes) }
    /// The header says there is sound to hear.
    var headerHasAudio: Bool { !audioCodec.isEmpty }
}

/// One drive's queue: one decode at a time, archived files first.
struct AudioFingerprintBackfillLane: Sendable, Equatable {
    /// Volume root ("/Volumes/Archive1", or "/" for this Mac's disk).
    let root: String
    var items: [AudioFingerprintBackfillItem] = []

    var bytes: Int64 { items.reduce(Int64(0)) { $0 + $1.sizeBytes } }
    var archivedCount: Int { items.reduce(0) { $0 + ($1.isArchived ? 1 : 0) } }
    var label: String { FullHashBackfillPlanner.label(forRoot: root) }
}

struct AudioFingerprintBackfillPlan: Sendable, Equatable {
    /// Sorted by root (the lock-ordering rule the gate plan also uses).
    var lanes: [AudioFingerprintBackfillLane] = []
    /// Already carry a current stamp — skipped (the resume rule), by outcome.
    var alreadyFingerprinted = 0
    var noSoundStamped = 0
    var partialStamped = 0
    /// Never hashed by a scan: no key for the sidecar — counted, not planned.
    var noDigest = 0
    /// Tried `AudioFingerprintAttempt.cap` times by this engine without a
    /// print (GH #416 part 2) — skipped, by the last try's outcome. A new
    /// engine version retries them.
    var gaveUpHeardTooLittle = 0
    var gaveUpFailed = 0
    var gaveUp: Int { gaveUpHeardTooLittle + gaveUpFailed }

    var fileCount: Int { lanes.reduce(0) { $0 + $1.items.count } }
    var archivedCount: Int { lanes.reduce(0) { $0 + $1.archivedCount } }
    var bytes: Int64 { lanes.reduce(Int64(0)) { $0 + $1.bytes } }
    var alreadyStamped: Int { alreadyFingerprinted + noSoundStamped + partialStamped }
}

/// Builds the plan in one pass. Main actor because it reads live records.
@MainActor
enum AudioFingerprintBackfillPlanner {

    static func plan(records: [VideoRecord], isArchived: (VideoRecord) -> Bool) -> AudioFingerprintBackfillPlan {
        var plan = AudioFingerprintBackfillPlan()
        var byRoot: [String: AudioFingerprintBackfillLane] = [:]
        for r in records where isActive(r) {
            let digests = digests(of: r)
            guard !digests.isEmpty else { plan.noDigest += 1; continue }
            if let stamp = r.audioFingerprint,
               stamp.describes(sizeBytes: r.sizeBytes, digests: digests, headerHasAudio: !r.audioCodec.isEmpty) {
                switch (stamp.outcome, stamp.complete) {
                case (.noAudio, _): plan.noSoundStamped += 1
                case (.fingerprinted, false): plan.partialStamped += 1
                case (.fingerprinted, true): plan.alreadyFingerprinted += 1
                }
                continue
            }
            // GH #416 part 2: tried `cap` times by THIS engine, no print —
            // skipped (an older engine's tries count 0, so a new one retries).
            if let attempt = gaveUp(r, digests: digests) {
                switch attempt.outcome {
                case .heardTooLittle: plan.gaveUpHeardTooLittle += 1
                case .failed: plan.gaveUpFailed += 1
                }
                continue
            }
            let root = MediaVolumeGatePolicy.volumeRoot(forPath: r.fullPath)
            byRoot[root, default: AudioFingerprintBackfillLane(root: root)].items.append(
                AudioFingerprintBackfillItem(id: r.id, path: r.fullPath, filename: r.filename, sizeBytes: r.sizeBytes,
                                             durationSeconds: r.durationSeconds, isVideoOnly: r.streamType == .videoOnly,
                                             audioCodec: r.audioCodec, isArchived: isArchived(r), digests: digests))
        }
        plan.lanes = byRoot.values
            .map { lane in
                var sorted = lane
                sorted.items.sort { ($0.isArchived ? 0 : 1, $0.path) < ($1.isArchived ? 0 : 1, $1.path) }
                return sorted
            }
            .sorted { $0.root < $1.root }
        return plan
    }

    /// The record's note when the plan gives up on it: no current stamp
    /// (`describes`) and `cap` tries by this engine on its preferred full
    /// digest. ONE rule for the plan and the coverage count (Codex #217 F3).
    static func gaveUp(_ r: VideoRecord, digests: [String]? = nil) -> AudioFingerprintAttempt? {
        guard let attempt = r.audioFingerprintAttempt else { return nil }
        let digests = digests ?? self.digests(of: r)
        if let stamp = r.audioFingerprint,
           stamp.describes(sizeBytes: r.sizeBytes, digests: digests, headerHasAudio: !r.audioCodec.isEmpty) { return nil }
        return attempt.gaveUp(digests: digests) ? attempt : nil
    }

    /// Not removed, not superseded, pointing at a file with a size.
    static func isActive(_ r: VideoRecord) -> Bool {
        !r.isPurged && !r.isSuperseded && !r.fullPath.isEmpty && r.sizeBytes > 0
    }

    /// The record's content digests, preferred first: the stored full
    /// SHA-256 when the row has one, then the scan's sampled hash.
    ///
    /// "Stored full SHA-256" is the digest catalog.sqlite keys `sound_prints`
    /// on: the content fixity, else the archive copy's archive fixity, each
    /// only when it covers the row's size. GH #416: this read the
    /// content fixity only, so an archive copy whose row's digest is its
    /// archive fixity (it loads with no content fixity) was stamped under its
    /// sampled "v1:" hash, which `sound_prints` never binds: the commit saw
    /// no change, the stamp died at quit and 50 archived files were read
    /// again every run — and when the content's print WAS stored (by its
    /// original), the v1 restamp's commit deleted it.
    ///
    /// Asked of the commit's OWN rule (`CatalogRecordDTO.resolveDigest`),
    /// not a copy of it (Codex cycle #216 P1): two sha256 fixities that
    /// disagree name no identity — the commit refuses the row — so the
    /// stamp gets no full key, nothing is shared to it and no sidecar row
    /// is written under either hash.
    static func digests(of r: VideoRecord) -> [String] {
        var out: [String] = []
        let state = CatalogRecordDTO.resolveDigest(
            content: r.contentFixity.map { .init(algorithm: $0.algorithm, digest: $0.digest, bytes: $0.byteCount) },
            archive: r.archiveFixity.map { .init(algorithm: $0.algorithm, digest: $0.digest, bytes: $0.sizeBytes) },
            sizeBytes: r.sizeBytes)
        if let full = state.digest {
            out.append(AudioFingerprintStamp.fullDigest(full))
        }
        if let sampled = AudioFingerprintStamp.sampledDigest(r.contentHash) { out.append(sampled) }
        return out
    }
}

// MARK: - Memory budget (pure)

/// How many decodes may run at once. The decoder holds the raw pipe bytes
/// AND the Int16 samples at the same moment (codex P2 on the engine): about
/// 115 MB per hour of audio, 461 MB for the 4-hour cap. Rick's M4 Max has
/// crashed from unbounded memory before, so the sum of in-flight estimates
/// is capped at 1.5 GB and the count at 4; a file whose own estimate
/// exceeds the cap runs ALONE. A record with no known duration is budgeted
/// at the cap (the decoder stops there anyway).
enum AudioDecodeBudget {
    static let bytesPerHour: Int64 = 120_000_000
    static let totalBytes: Int64 = 1_500_000_000
    static let maxConcurrent = 4

    static func estimateBytes(durationSeconds: Double) -> Int64 {
        let seconds = durationSeconds > 0 ? min(durationSeconds, AudioPCMDecoder.defaultMaxSeconds)
            : AudioPCMDecoder.defaultMaxSeconds
        return Int64(seconds / 3_600 * Double(bytesPerHour))
    }

    /// May a decode of `durationSeconds` start beside `inFlight` (durations
    /// of the decodes running now)?
    static func canStart(durationSeconds: Double, inFlight: [Double]) -> Bool {
        if inFlight.isEmpty { return true }
        guard inFlight.count < maxConcurrent else { return false }
        let used = inFlight.reduce(Int64(0)) { $0 + estimateBytes(durationSeconds: $1) }
        return used + estimateBytes(durationSeconds: durationSeconds) <= totalBytes
    }
}

// MARK: - Results (values)

/// What happened to one file — the detail list's row and the tally's key.
enum AudioFingerprintBackfillResult: String, Sendable, Equatable, CaseIterable {
    case fingerprinted
    /// Stamped from a copy's fingerprint already in the sidecar — no decode.
    case shared
    case noAudio
    /// Longer than the decoder's cap: a prefix was fingerprinted and the
    /// stamp says so; listed, not retried.
    case partial
    /// Decoded and heard sound, but too little to make one landmark (stamp
    /// rule 4): not stamped, never "silent"; one TRY recorded (GH #416
    /// part 2) — retried until `AudioFingerprintAttempt.cap` tries.
    case heardTooLittle
    case driveNotConnected
    case missing
    case failed
    case recordChanged
    /// Cut off by a quit while decoding; the next run reads it again.
    case cancelled

    /// Plain words for the detail row and the summary line.
    var words: String {
        switch self {
        case .fingerprinted: return "fingerprinted"
        case .shared: return "shared with a copy"
        case .noAudio: return "no sound"
        case .partial: return "partial (longer than 4 h)"
        case .heardTooLittle: return "heard sound, too little to fingerprint"
        case .driveNotConnected: return "drive not connected"
        case .missing: return "missing at its path"
        case .failed: return "failed"
        case .recordChanged: return "changed in the catalog meanwhile"
        case .cancelled: return "cut off"
        }
    }

    /// A stamp was written (the record is done until its bytes change).
    var isStamped: Bool {
        switch self {
        case .fingerprinted, .shared, .noAudio, .partial: return true
        case .heardTooLittle, .driveNotConnected, .missing, .failed, .recordChanged, .cancelled: return false
        }
    }
}

struct AudioFingerprintBackfillItemRow: Identifiable, Sendable, Equatable {
    let id: Int
    let filename: String
    let path: String
    let drive: String
    let archived: Bool
    let result: AudioFingerprintBackfillResult
    let detail: String
}

/// One drive's row in the detail.
struct AudioFingerprintBackfillLaneStatus: Identifiable, Sendable, Equatable {
    enum Phase: String, Sendable { case waiting, reading, finished, disconnected, stopped }
    var id: String { root }
    let root: String
    let label: String
    let planned: Int
    var done = 0
    var phase: Phase = .waiting
}

struct AudioFingerprintBackfillTotals: Sendable, Equatable {
    var planned = 0
    var plannedBytes: Int64 = 0
    var archivedPlanned = 0
    var alreadyStamped = 0
    var noDigest = 0
    /// Skipped by the plan after `AudioFingerprintAttempt.cap` tries.
    var gaveUp = 0
    /// Files resolved, whatever the outcome (the "N" of "N of M").
    var done = 0
    var doneBytes: Int64 = 0
    /// Bytes of the files actually decoded (ffmpeg reads the whole file to
    /// reach its audio) — the rate's numerator.
    var readBytes: Int64 = 0
    var landmarks = 0
    var sidecarBytes: Int64 = 0
    var counts: [AudioFingerprintBackfillResult: Int] = [:]

    subscript(_ r: AudioFingerprintBackfillResult) -> Int { counts[r] ?? 0 }

    /// One file counted under `from` belongs under `to` (a queued stamp
    /// whose record changed before it could be written). `done` unchanged.
    mutating func move(_ from: AudioFingerprintBackfillResult, to: AudioFingerprintBackfillResult) {
        guard self[from] > 0 else { return }
        counts[from, default: 0] -= 1
        counts[to, default: 0] += 1
    }

    mutating func add(_ r: AudioFingerprintBackfillResult, files n: Int = 1, bytes: Int64) {
        counts[r, default: 0] += n
        done += n
        doneBytes += bytes
    }

    /// "1,204 of 3,310 fingerprinted (412 GB read, 2.1M landmarks, 17 MB kept) · 96 shared with a copy · 12 no sound · 2 failed · 3,000 already done"
    var line: String {
        var parts = ["\(self[.fingerprinted].formatted()) of \(planned.formatted()) fingerprinted "
                     + "(\(MediaBytes.display(readBytes)) read, \(Self.landmarksWord(landmarks)), \(MediaBytes.display(sidecarBytes)) kept)"]
        for r in AudioFingerprintBackfillResult.allCases where r != .fingerprinted && self[r] > 0 {
            parts.append("\(self[r].formatted()) \(r.words)")
        }
        if alreadyStamped > 0 { parts.append("\(alreadyStamped.formatted()) already done") }
        if gaveUp > 0 { parts.append(Self.gaveUpWords(gaveUp)) }
        if noDigest > 0 { parts.append("\(noDigest.formatted()) never hashed (scan them first)") }
        return parts.joined(separator: " · ")
    }

    /// "1,204 of 3,310 · 2 drives reading · clip.mov +1 · 410 MB/s · ~3 h 10 min left".
    func progressLine(reading: [String], lanesActive: Int, elapsed: TimeInterval) -> String {
        var parts = ["\(done.formatted()) of \(planned.formatted())"]
        if lanesActive > 0 { parts.append("\(lanesActive) drive\(lanesActive == 1 ? "" : "s") reading") }
        if let first = reading.first { parts.append(reading.count > 1 ? "\(first) +\(reading.count - 1)" : first) }
        guard elapsed > 5, readBytes > 0 else { return parts.joined(separator: " · ") }
        let rate = Double(readBytes) / elapsed
        parts.append("\(MediaBytes.display(Int64(rate)))/s")
        parts.append(FullHashBackfillTotals.timeLeft(Double(max(0, plannedBytes - doneBytes)) / rate))
        return parts.joined(separator: " · ")
    }

    /// "12 skipped after 3 tries (heard too little / failed) — a new engine retries them"
    nonisolated static func gaveUpWords(_ n: Int) -> String {
        "\(n.formatted()) skipped after \(AudioFingerprintAttempt.cap) tries (heard too little / failed) — a new engine retries them"
    }

    nonisolated static func landmarksWord(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM landmarks", Double(n) / 1_000_000)
            : n >= 10_000 ? "\(n / 1_000)k landmarks" : "\(n.formatted()) landmarks"
    }
}
