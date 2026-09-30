// MissingAudioFinder.swift
// "Find Missing Audio" — the aggressive per-video audio hunt the Tidy
// Catalog sheet has promised since July (GH #111, Rick 2026-09-11).
//
// Rick's safety net for being ruthless with Tidy: "if we find a video
// missing audio we'll just do an aggressive search to find the missing
// audio, even if it's not in the catalog." Set-aside hides a record but
// never touches the file; the catalog-scope gate declines unlinked audio
// at scan time and only logs it. Both leave the audio on disk — this
// finder goes and gets it, for ONE video at a time, and hands the chosen
// file back to the normal Correlate so the pair is recorded exactly like
// any other. Nothing here muxes, moves, or deletes.
//
// Three tiers, cheapest first:
//   a. hidden catalog records — audio-only records that are set aside or
//      purged. Pure over snapshots, zero disk I/O.
//   b. nearby folders — the video's own folder, its parent, and the
//      parent's other children ("one level up, then down"). Bounded
//      directory listings; ffprobe for durations under the probe cap.
//   c. all scan roots — a bounded breadth-first walk of every reachable
//      scan target for audio files whose NORMALIZED name stem matches
//      the video's (case-insensitive; `_audio`, `.A1`, `-a`, Avid V/A
//      track naming stripped — see `normalizedStem`).
//
// Match rubric = the Correlate rubric, not a new one: every candidate is
// scored by `CorrelationScorer.scoreParts` (filename 4 / duration 3 /
// timestamp 3 / timecode 2 / directory 1 / tape 1, floor
// `Correlator.minimumScore`). One deliberate loosening for the hunt: a
// normalized-stem match that the strict filename key misses counts like
// the filename signal ("stem", +4) — for a single video reviewed by a
// human, the GH #101 coincidence-at-scale argument does not apply. The
// candidate additionally predicts whether Correlate's own pair-formation
// gate (`durationGatePermitsFuzzyPair` + the pooling rule in
// `assignPairs`) would accept it, so the sheet can say so honestly
// BEFORE Rick presses Pair.
//
// Design contract (same as CatalogScopePolicy / AnalysisScope): this file
// is PURE. Filesystem and ffprobe are injected behind two tiny protocols
// so tests drive synthetic trees with no real /Volumes walk, and the
// isolation test can prove the finder never lists a directory outside
// the roots it was given. The default implementations at the bottom use
// FileManager and ffprobe-via-ProcessRunner (the ExecuteShellCommand
// module — never a bare Process()).
//
// Memory (worst case, all caps at defaults): the BFS queue holds
// directory paths only, bounded by `maxEntriesWalked` (250k × ~100 B ≈
// 25 MB); candidate paths are bounded by `maxFilesProbed` per tier plus
// the hidden-record snapshot the model already holds. No file content is
// ever read here — ffprobe reads headers in its own process.

import Foundation
import os

let missingAudioLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "missingAudio")

// MARK: - Injection seams

/// One directory listing. `children(of:)` is NON-recursive — the finder
/// does its own bounded recursion so every cap and the isolation test
/// see one seam. (Protocol ≈ a C++ pure-abstract interface; `Sendable`
/// ≈ "safe to hand across threads".)
protocol MissingAudioFileSystem: Sendable {
    func children(of directory: String) -> [MissingAudioFinder.DirectoryEntry]
}

/// Duration + stream shape for one file. nil = unreadable / not media.
protocol MissingAudioDurationProbe: Sendable {
    func probe(path: String) async -> MissingAudioFinder.ProbeResult?
}

enum MissingAudioFinder {

    // MARK: - Types

    /// Search tiers, cheapest first. `rawValue` order IS the rank order.
    enum Tier: Int, Comparable, Sendable, CaseIterable {
        case hiddenCatalogRecords = 0
        case nearbyFolders = 1
        case allScanRoots = 2

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .hiddenCatalogRecords: return "Set aside / removed"
            case .nearbyFolders:        return "Nearby folder"
            case .allScanRoots:         return "Scan roots"
            }
        }

        var logName: String {
            switch self {
            case .hiddenCatalogRecords: return "a:hidden-records"
            case .nearbyFolders:        return "b:nearby-folders"
            case .allScanRoots:         return "c:scan-roots"
            }
        }
    }

    /// Where a candidate stands in the catalog right now.
    enum CatalogState: Equatable, Sendable {
        case notInCatalog
        case active
        case setAside(reason: String)
        case purged

        var label: String {
            switch self {
            case .notInCatalog: return "not in catalog"
            case .active: return "in catalog"
            case .setAside(let reason):
                let friendly = CatalogScopePolicy.SetAsideReason(rawValue: reason)?.friendlyLabel ?? reason
                return "set aside — \(friendly)"
            case .purged: return "removed from catalog"
            }
        }
    }

    /// The video we are hunting audio for — a Sendable snapshot of the
    /// record's scoring signals plus its path.
    struct VideoTarget: Sendable {
        let id: UUID
        let filename: String
        let fullPath: String
        let directory: String
        let durationSeconds: Double
        let dateCreatedRaw: Date?
        let timecode: String
        let tapeName: String

        init(id: UUID, filename: String, fullPath: String, directory: String,
             durationSeconds: Double, dateCreatedRaw: Date? = nil,
             timecode: String = "", tapeName: String = "") {
            self.id = id
            self.filename = filename
            self.fullPath = fullPath
            self.directory = directory
            self.durationSeconds = durationSeconds
            self.dateCreatedRaw = dateCreatedRaw
            self.timecode = timecode
            self.tapeName = tapeName
        }

        init(snap: CorrelationScorer.Snap, fullPath: String) {
            self.init(id: snap.id, filename: snap.filename, fullPath: fullPath,
                      directory: snap.directory, durationSeconds: snap.durationSeconds,
                      dateCreatedRaw: snap.dateCreatedRaw, timecode: snap.timecode,
                      tapeName: snap.tapeName)
        }

        /// Correlate's strict filename key (Avid V/A aware).
        var correlationKey: String { CorrelationScorer.filenameCorrelationKey(filename) }
        /// The loose stem used by tiers b/c.
        var stem: String { MissingAudioFinder.normalizedStem(filename) }
    }

    /// Tier-a input: an audio-only catalog record that is hidden (set
    /// aside or purged), as a snapshot.
    struct HiddenAudio: Sendable {
        let snap: CorrelationScorer.Snap
        let fullPath: String
        let state: CatalogState
    }

    /// One ranked candidate. `id` is synthesized per candidate (a
    /// `UUID` so the sheet's List has a stable identity).
    struct Candidate: Identifiable, Sendable, Equatable {
        let id: UUID
        let path: String
        let tier: Tier
        /// Correlate rubric score (+4 for a loose stem match).
        let score: Int
        /// Why it matched, in rubric vocabulary ("stem" is the one
        /// addition): e.g. ["filename", "duration", "directory"].
        let reasons: [String]
        /// Known duration of the candidate, or nil when it was not probed.
        let durationSeconds: Double?
        /// |video − audio| when both durations are known.
        let durationDelta: Double?
        /// Non-nil when the file is already a catalog record.
        let catalogRecordID: UUID?
        let catalogState: CatalogState
        /// Prediction of Correlate's own pair-formation decision for
        /// this pair (pooling rule + duration gate + rubric floor).
        let correlateWillAccept: Bool

        var filename: String { (path as NSString).lastPathComponent }
        var directory: String { (path as NSString).deletingLastPathComponent }
    }

    /// Engine knobs. `standard(...)` fills the extension and skip-dir
    /// sets from the model; tests inject their own.
    struct Config: Sendable {
        /// Lowercase audio extensions to consider on disk. `mxf` is
        /// always added: Avid audio-only essence wears the video
        /// extension, so an MXF is a candidate only after ffprobe says
        /// it has no video stream.
        var audioExtensions: Set<String>
        /// Directory NAMES never descended into (Finder metadata, system
        /// dirs, music libraries — the scan's own skip list).
        var skipDirNames: Set<String>
        var durationTolerance: Double = Correlator.durationTolerance
        var timestampTolerance: TimeInterval = Correlator.timestampTolerance
        /// The probe cap: at most this many ffprobe runs per SEARCH
        /// (tiers b + c share it). Local ffprobe ≈ 30–80 ms/file, so the
        /// default bounds a search at roughly 15 s of probing on local
        /// disks; slower on network volumes, which is why the sheet
        /// shows live progress and has a Cancel. Tier c also stops
        /// collecting name matches at 2 × this (the surplus is judged
        /// unprobed, by name only) so the candidate list stays bounded.
        var maxFilesProbed: Int = 200
        /// Tier c walk cap: total directory entries examined across all
        /// roots. Bounds both time and the BFS queue's memory.
        var maxEntriesWalked: Int = 250_000
        /// Progress callback cadence (entries walked between calls).
        var progressEvery: Int = 500

        init(audioExtensions: Set<String>, skipDirNames: Set<String>) {
            var exts = Set(audioExtensions.map { $0.lowercased() })
            exts.insert("mxf")
            self.audioExtensions = exts
            self.skipDirNames = skipDirNames
        }

        /// Everything the project already knows as audio: the scan's
        /// standalone-audio list plus the catalog-scope ambiguous set.
        static func standard(modelAudioExtensions: Set<String>,
                             skipDirNames: Set<String>) -> Config {
            var exts = modelAudioExtensions
            exts.formUnion(CatalogScopePolicy.ambiguousAudioExtensions)
            exts.formUnion(AnalysisScope.audioExtensions)
            return Config(audioExtensions: exts, skipDirNames: skipDirNames)
        }
    }

    struct DirectoryEntry: Sendable, Hashable {
        let path: String
        let isDirectory: Bool
        /// Filesystem creation date when the lister has it cheaply
        /// (feeds the rubric's weak "timestamp" signal).
        var creationDate: Date? = nil

        var name: String { (path as NSString).lastPathComponent }
    }

    struct ProbeResult: Sendable {
        let durationSeconds: Double
        let hasVideo: Bool
        let hasAudio: Bool
    }

    /// Honest progress for the sheet (project rule: >15–30 s ops narrate).
    struct Progress: Sendable {
        let tier: Tier
        let entriesWalked: Int
        let filesProbed: Int
        let candidatesSoFar: Int
        let detail: String
    }

    /// Per-tier tallies for the log line and the sheet footer.
    struct TierReport: Sendable, Equatable {
        let tier: Tier
        /// Records / files looked at (before any probe).
        var examined = 0
        /// ffprobe runs spent in this tier.
        var probed = 0
        /// Candidates that cleared the rubric floor.
        var matched = 0
        /// Related files refused because both durations were known and
        /// incompatible (Correlate would refuse them too — GH #125).
        var durationRefused = 0
        /// A cap (walk or probe) cut this tier short.
        var truncated = false
    }

    struct Result: Sendable {
        var candidates: [Candidate] = []
        var reports: [TierReport] = []
        var cancelled = false
        /// Total ffprobe runs across tiers.
        var filesProbed = 0
    }

    /// Mutable, shared across tiers b and c within one search.
    struct ProbeBudget {
        let cap: Int
        var used = 0
        var exhausted: Bool { used >= cap }
    }

    // MARK: - Stem normalization

    /// Loose, case-insensitive name stem for tiers b and c.
    ///
    /// Starts from Correlate's strict key (which already folds the Avid
    /// bare V/A-hex and OMFI tape-name shapes) and then strips trailing
    /// "role" suffixes: `_audio`, `-a`, `.A1`, `_v02`, `_ch1`, `_L`/`_R`,
    /// `_mono`/`_stereo`, and the `._N` form the strict key produces for
    /// a bare `.A1`/`.V1` segment. Two-digit Avid-style `V01`/`A01` are
    /// also stripped WITHOUT a separator (`tape9v01` → `tape9`).
    ///
    /// Only the loose tiers use this; the strict key still decides the
    /// rubric's "filename" signal, so a stem-only match is labelled
    /// "stem" and is never mistaken for Correlate's own identity match.
    static func normalizedStem(_ filename: String) -> String {
        var s = CorrelationScorer.filenameCorrelationKey(filename).lowercased()
        s = s.trimmingCharacters(in: .whitespaces)
        if let range = roleSuffixPattern.firstMatch(
            in: s, range: NSRange(s.startIndex..., in: s)
        ).flatMap({ Range($0.range, in: s) }) {
            // Never strip the whole name: "a.wav" stays "a".
            let stripped = String(s[..<range.lowerBound])
            if !stripped.isEmpty { s = stripped }
        }
        return s
    }

    /// Trailing role suffix chain. Each link is `<sep><role>` where role
    /// ∈ audio/aud/sound/snd/video/vid/a/v/[av]NN/chN/trackN/trkN/l/r/
    /// left/right/mono/stereo/mix, OR the strict key's `._N` rewrite, OR
    /// a bare two-digit `[av]\d\d` with no separator (Avid track style).
    private static let roleSuffixPattern = try! NSRegularExpression(
        pattern: #"(?:[ _\-.]+(?:audio|aud|sound|snd|video|vid|a|v|[av]\d{1,2}|ch\d{1,2}|track\d{1,2}|trk\d{1,2}|l|r|left|right|mono|stereo|mix)|\._\d{1,2}|(?<=[a-z0-9])[av]\d{2})+$"#,
        options: [.caseInsensitive])

    static func stemsMatch(_ a: String, _ b: String) -> Bool {
        let sa = normalizedStem(a), sb = normalizedStem(b)
        return !sa.isEmpty && sa == sb
    }

    // MARK: - Shared match evaluation

    /// The scoring signals of one audio candidate (record or file).
    struct AudioFacts: Sendable {
        let filename: String
        let directory: String
        /// 0 = unknown.
        let durationSeconds: Double
        let dateCreatedRaw: Date?
        var timecode: String = ""
        var tapeName: String = ""
    }

    struct Match: Sendable, Equatable {
        let score: Int
        let reasons: [String]
        let durationDelta: Double?
        let correlateWillAccept: Bool
    }

    /// Outcome of judging one audio against the video.
    enum Verdict: Equatable {
        case match(Match)
        case belowFloor
        /// Both durations known and incompatible — Correlate would refuse.
        case durationRefused
    }

    /// Score one audio against the video with the Correlate rubric, plus
    /// the loose stem signal. Pure.
    static func evaluate(video v: VideoTarget, audio a: AudioFacts, config: Config) -> Verdict {
        let vKey = v.correlationKey
        let strict = CorrelationScorer.scoreParts(
            vKey: vKey, audioFilename: a.filename,
            vDuration: v.durationSeconds, aDuration: a.durationSeconds,
            vDate: v.dateCreatedRaw, aDate: a.dateCreatedRaw,
            vTimecode: v.timecode, aTimecode: a.timecode,
            vDirectory: v.directory, aDirectory: a.directory,
            vTape: v.tapeName, aTape: a.tapeName,
            durationTolerance: config.durationTolerance,
            timestampTolerance: config.timestampTolerance)

        // Rebuild the raw signal set (scoreParts hides sub-floor detail).
        let keyMatch = vKey == CorrelationScorer.filenameCorrelationKey(a.filename)
        let vKnown = v.durationSeconds > 0 && v.durationSeconds.isFinite
        let aKnown = a.durationSeconds > 0 && a.durationSeconds.isFinite
        let durationHit = vKnown && aKnown &&
            abs(v.durationSeconds - a.durationSeconds) <= config.durationTolerance
        let timestampHit: Bool
        if let vd = v.dateCreatedRaw, let ad = a.dateCreatedRaw {
            timestampHit = abs(vd.timeIntervalSince(ad)) <= config.timestampTolerance
        } else {
            timestampHit = false
        }
        let dirMatch = v.directory == a.directory

        // GH #125: a known-incompatible duration is a refusal, not a
        // low score — Correlate would refuse the pair on Pair anyway.
        if vKnown && aKnown,
           !CorrelationScorer.durationCompatible(videoDuration: v.durationSeconds,
                                                 audioDuration: a.durationSeconds) {
            return .durationRefused
        }

        var score = strict?.score ?? 0
        var reasons = strict?.reasons ?? []
        if score == 0 {
            // Below floor — recover the partial signals for the stem path.
            if durationHit { score += 3; reasons.append("duration") }
            if timestampHit { score += 3; reasons.append("timestamp") }
            if !v.timecode.isEmpty && v.timecode == a.timecode { score += 2; reasons.append("timecode") }
            if dirMatch { score += 1; reasons.append("directory") }
            if !v.tapeName.isEmpty && v.tapeName == a.tapeName { score += 1; reasons.append("tape") }
        }
        if !keyMatch && stemsMatch(v.filename, a.filename) {
            score += 4
            reasons.insert("stem", at: 0)
        }
        guard score >= Correlator.minimumScore else { return .belowFloor }

        let delta: Double? = (vKnown && aKnown) ? abs(v.durationSeconds - a.durationSeconds) : nil

        // Predict Correlate (assignPairs): pooled by key or directory, or
        // by duration/timestamp in the thin-pool fallback (a two-record
        // selection is always thin); then the duration gate; then the
        // strict rubric floor.
        let pooled = keyMatch || dirMatch || durationHit || timestampHit
        let gate = CorrelationScorer.durationGatePermitsFuzzyPair(
            videoDuration: v.durationSeconds, audioDuration: a.durationSeconds,
            filenameKeyMatches: keyMatch)
        let willAccept = pooled && gate && strict != nil

        return .match(Match(score: score, reasons: reasons, durationDelta: delta,
                            correlateWillAccept: willAccept))
    }

    // MARK: - Tier a: hidden catalog records (zero disk I/O)

    static func hiddenCatalogCandidates(video: VideoTarget,
                                        hidden: [HiddenAudio],
                                        config: Config) -> (candidates: [Candidate], report: TierReport) {
        var report = TierReport(tier: .hiddenCatalogRecords)
        var out: [Candidate] = []
        for h in hidden {
            report.examined += 1
            let facts = AudioFacts(filename: h.snap.filename, directory: h.snap.directory,
                                   durationSeconds: h.snap.durationSeconds,
                                   dateCreatedRaw: h.snap.dateCreatedRaw,
                                   timecode: h.snap.timecode, tapeName: h.snap.tapeName)
            switch evaluate(video: video, audio: facts, config: config) {
            case .belowFloor:
                continue
            case .durationRefused:
                report.durationRefused += 1
            case .match(let m):
                report.matched += 1
                out.append(Candidate(
                    id: UUID(), path: h.fullPath, tier: .hiddenCatalogRecords,
                    score: m.score, reasons: m.reasons,
                    durationSeconds: h.snap.durationSeconds > 0 ? h.snap.durationSeconds : nil,
                    durationDelta: m.durationDelta,
                    catalogRecordID: h.snap.id, catalogState: h.state,
                    correlateWillAccept: m.correlateWillAccept))
            }
        }
        return (out, report)
    }

    // MARK: - Tier b: nearby folders

    /// The directories tier b lists: the video's folder, its parent, and
    /// the parent's other child folders. Pure; exposed for the isolation
    /// test.
    static func nearbyDirectories(for video: VideoTarget,
                                  fileSystem: MissingAudioFileSystem) -> [String] {
        let own = video.directory
        guard !own.isEmpty else { return [] }
        var dirs = [own]
        let parent = (own as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != own, parent != "/" else { return dirs }
        dirs.append(parent)
        for entry in fileSystem.children(of: parent) where entry.isDirectory && entry.path != own {
            if entry.name.hasPrefix(".") { continue }
            dirs.append(entry.path)
        }
        return dirs
    }

    static func nearbyFolderCandidates(video: VideoTarget,
                                       config: Config,
                                       fileSystem: MissingAudioFileSystem,
                                       probe: MissingAudioDurationProbe,
                                       budget: inout ProbeBudget,
                                       excludingPaths: Set<String>,
                                       progress: (@Sendable (Progress) -> Void)?) async -> (candidates: [Candidate], report: TierReport) {
        var report = TierReport(tier: .nearbyFolders)
        let dirs = nearbyDirectories(for: video, fileSystem: fileSystem)

        // Gather audio-extension files, remembering where each came from
        // so the probe order can favour the likeliest first.
        struct Found { let entry: DirectoryEntry; let priority: Int }
        var found: [Found] = []
        var seen = Set<String>()
        for (i, dir) in dirs.enumerated() {
            for entry in fileSystem.children(of: dir) where !entry.isDirectory {
                guard isAudioExtension(entry.path, config: config),
                      entry.path != video.fullPath,
                      !excludingPaths.contains(entry.path),
                      seen.insert(entry.path).inserted else { continue }
                report.examined += 1
                // 0 = stem match anywhere, 1 = own folder, 2 = parent, 3+ = sibling
                let priority = stemsMatch(video.filename, entry.name) ? 0 : (i == 0 ? 1 : (i == 1 ? 2 : 3))
                found.append(Found(entry: entry, priority: priority))
            }
        }
        found.sort { ($0.priority, $0.entry.path) < ($1.priority, $1.entry.path) }

        let probedBefore = budget.used
        var out: [Candidate] = []
        for f in found {
            if Task.isCancelled { break }
            let (cand, refused, truncated) = await judgeFile(
                video: video, entry: f.entry, tier: .nearbyFolders,
                config: config, probe: probe, budget: &budget)
            if truncated { report.truncated = true }
            if refused { report.durationRefused += 1 }
            if let cand {
                out.append(cand)
                report.matched += 1
            }
            progress?(Progress(tier: .nearbyFolders, entriesWalked: report.examined,
                               filesProbed: budget.used, candidatesSoFar: out.count,
                               detail: f.entry.name))
        }
        report.probed = budget.used - probedBefore
        return (out, report)
    }

    // MARK: - Tier c: all scan roots (bounded BFS)

    static func scanRootCandidates(video: VideoTarget,
                                   roots: [String],
                                   config: Config,
                                   fileSystem: MissingAudioFileSystem,
                                   probe: MissingAudioDurationProbe,
                                   budget: inout ProbeBudget,
                                   excludingPaths: Set<String>,
                                   progress: (@Sendable (Progress) -> Void)?) async -> (candidates: [Candidate], report: TierReport, cancelled: Bool) {
        var report = TierReport(tier: .allScanRoots)
        let targetStem = video.stem
        let targetKey = video.correlationKey
        var matches: [DirectoryEntry] = []
        var seen = Set<String>(excludingPaths)
        var walked = 0
        var cancelled = false

        // Explicit BFS queue (≈ std::deque<std::string> of directory
        // paths) — no recursion, so depth can't blow the stack and the
        // cap bounds memory.
        var queue: [String] = roots.filter { !$0.isEmpty }
        var head = 0
        outer: while head < queue.count {
            let dir = queue[head]
            head += 1
            if Task.isCancelled { cancelled = true; break }
            for entry in fileSystem.children(of: dir) {
                walked += 1
                if walked > config.maxEntriesWalked {
                    report.truncated = true
                    break outer
                }
                if walked % config.progressEvery == 0 {
                    progress?(Progress(tier: .allScanRoots, entriesWalked: walked,
                                       filesProbed: budget.used, candidatesSoFar: matches.count,
                                       detail: dir))
                    if Task.isCancelled { cancelled = true; break outer }
                }
                if entry.isDirectory {
                    let name = entry.name
                    if name.hasPrefix(".") || config.skipDirNames.contains(name) { continue }
                    queue.append(entry.path)
                    continue
                }
                guard isAudioExtension(entry.path, config: config),
                      entry.path != video.fullPath else { continue }
                report.examined += 1
                let name = entry.name
                let matched = CorrelationScorer.filenameCorrelationKey(name) == targetKey
                    || normalizedStem(name) == targetStem
                guard matched, seen.insert(entry.path).inserted else { continue }
                matches.append(entry)
                if matches.count >= config.maxFilesProbed * 2 {
                    // Twice as many stem matches as we could ever probe
                    // (the surplus is judged unprobed, by name only) —
                    // stop walking; the report says so.
                    report.truncated = true
                    break outer
                }
            }
        }
        // Drop the queue before probing — it's the big allocation.
        queue = []

        let probedBefore = budget.used
        var out: [Candidate] = []
        for entry in matches {
            if Task.isCancelled { cancelled = true; break }
            let (cand, refused, truncated) = await judgeFile(
                video: video, entry: entry, tier: .allScanRoots,
                config: config, probe: probe, budget: &budget)
            if truncated { report.truncated = true }
            if refused { report.durationRefused += 1 }
            if let cand {
                out.append(cand)
                report.matched += 1
            }
            progress?(Progress(tier: .allScanRoots, entriesWalked: walked,
                               filesProbed: budget.used, candidatesSoFar: out.count,
                               detail: entry.name))
        }
        report.probed = budget.used - probedBefore
        return (out, report, cancelled)
    }

    // MARK: - Per-file judgement (shared by b and c)

    /// Probe (under the budget) and evaluate one on-disk file. Returns
    /// (candidate, durationRefused, probeCapHit).
    private static func judgeFile(video: VideoTarget,
                                  entry: DirectoryEntry,
                                  tier: Tier,
                                  config: Config,
                                  probe: MissingAudioDurationProbe,
                                  budget: inout ProbeBudget) async -> (Candidate?, Bool, Bool) {
        let isMXF = (entry.path as NSString).pathExtension.lowercased() == "mxf"
        var duration: Double = 0
        var capHit = false
        if budget.exhausted {
            capHit = true
            // Unprobed MXF: could be the video half of another pair —
            // only a strict key / stem match may carry it unprobed.
            if isMXF, !(CorrelationScorer.filenameCorrelationKey(entry.name) == video.correlationKey
                        || stemsMatch(video.filename, entry.name)) {
                return (nil, false, capHit)
            }
        } else {
            budget.used += 1
            guard let p = await probe.probe(path: entry.path) else {
                return (nil, false, capHit)          // unreadable → not a candidate
            }
            // The audio HALF of a pair has no picture. A video+audio file
            // (or a picture-only MXF) is never "missing audio".
            guard p.hasAudio, !p.hasVideo else { return (nil, false, capHit) }
            duration = p.durationSeconds
        }
        let facts = AudioFacts(filename: entry.name, directory: entry.directoryPath,
                               durationSeconds: duration, dateCreatedRaw: entry.creationDate)
        switch evaluate(video: video, audio: facts, config: config) {
        case .belowFloor:
            return (nil, false, capHit)
        case .durationRefused:
            return (nil, true, capHit)
        case .match(let m):
            return (Candidate(id: UUID(), path: entry.path, tier: tier,
                              score: m.score, reasons: m.reasons,
                              durationSeconds: duration > 0 ? duration : nil,
                              durationDelta: m.durationDelta,
                              catalogRecordID: nil, catalogState: .notInCatalog,
                              correlateWillAccept: m.correlateWillAccept),
                    false, capHit)
        }
    }

    static func isAudioExtension(_ path: String, config: Config) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && config.audioExtensions.contains(ext)
    }

    // MARK: - Ranking

    /// Correlate-acceptable first, then score, then cheaper tier, then
    /// smaller duration delta (unknown last), then name — deterministic.
    static func rank(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { a, b in
            if a.correlateWillAccept != b.correlateWillAccept { return a.correlateWillAccept }
            if a.score != b.score { return a.score > b.score }
            if a.tier != b.tier { return a.tier < b.tier }
            switch (a.durationDelta, b.durationDelta) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    // MARK: - The whole search (off the main actor)

    /// Run all three tiers for one video. Pure over its inputs; the only
    /// side effects are through the injected file system / probe and the
    /// progress callback. Cooperative cancellation via the calling Task
    /// (≈ a cancel flag polled between units of work).
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable`; pre-6.2 a
    // nonisolated async static already runs off-actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func search(video: VideoTarget,
                       hidden: [HiddenAudio],
                       roots: [String],
                       config: Config,
                       fileSystem: MissingAudioFileSystem,
                       probe: MissingAudioDurationProbe,
                       progress: (@Sendable (Progress) -> Void)? = nil) async -> Result {
        var result = Result()
        var budget = ProbeBudget(cap: config.maxFilesProbed)

        // a — free.
        let a = hiddenCatalogCandidates(video: video, hidden: hidden, config: config)
        result.candidates += a.candidates
        result.reports.append(a.report)
        progress?(Progress(tier: .hiddenCatalogRecords, entriesWalked: a.report.examined,
                           filesProbed: 0, candidatesSoFar: result.candidates.count,
                           detail: "\(a.report.examined) hidden audio record(s) checked"))
        if Task.isCancelled { result.cancelled = true; return finish(result) }

        // b — nearby folders. Paths already found in tier a are skipped so
        // a hidden record shows once, with its catalog state.
        let known = Set(result.candidates.map(\.path))
        let b = await nearbyFolderCandidates(video: video, config: config,
                                             fileSystem: fileSystem, probe: probe,
                                             budget: &budget, excludingPaths: known,
                                             progress: progress)
        result.candidates += b.candidates
        result.reports.append(b.report)
        if Task.isCancelled { result.cancelled = true; result.filesProbed = budget.used; return finish(result) }

        // c — every reachable root.
        let knownB = Set(result.candidates.map(\.path))
        let c = await scanRootCandidates(video: video, roots: roots, config: config,
                                         fileSystem: fileSystem, probe: probe,
                                         budget: &budget, excludingPaths: knownB,
                                         progress: progress)
        result.candidates += c.candidates
        result.reports.append(c.report)
        result.cancelled = c.cancelled
        result.filesProbed = budget.used
        return finish(result)
    }

    private static func finish(_ r: Result) -> Result {
        var out = r
        out.candidates = rank(r.candidates)
        return out
    }
}

extension MissingAudioFinder.DirectoryEntry {
    var directoryPath: String { (path as NSString).deletingLastPathComponent }
}

// MARK: - Default implementations (real disk, real ffprobe)

/// FileManager-backed lister. Skips symlinks (no cycles) and hidden
/// entries; never follows into packages either — a `.fcpbundle` is a
/// directory to the walker, and the scan's skip list handles the rest.
struct FileManagerMissingAudioFileSystem: MissingAudioFileSystem {
    func children(of directory: String) -> [MissingAudioFinder.DirectoryEntry] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [MissingAudioFinder.DirectoryEntry] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            out.append(.init(path: item.path,
                             isDirectory: values.isDirectory ?? false,
                             creationDate: values.creationDate))
        }
        return out
    }
}

/// ffprobe through ProcessRunner (the ExecuteShellCommand module): stream
/// types + container duration only, JSON, hard 20 s deadline so a dead
/// network volume cannot wedge the search.
struct FFprobeMissingAudioDurationProbe: MissingAudioDurationProbe {
    var ffprobePath: String = ToolLocator.ffprobePath
    var deadlineSeconds: Double = 20

    private struct Output: Decodable {
        struct Stream: Decodable { let codec_type: String? }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]?
        let format: Format?
    }

    func probe(path: String) async -> MissingAudioFinder.ProbeResult? {
        let args = ["-v", "error",
                    "-show_entries", "stream=codec_type:format=duration",
                    "-of", "json", path]
        let (stdout, _) = await ProcessRunner.runCapturingStderr(
            executable: ffprobePath, arguments: args, deadlineSeconds: deadlineSeconds)
        guard let json = stdout, let data = json.data(using: .utf8),
              let out = try? JSONDecoder().decode(Output.self, from: data) else { return nil }
        let types = (out.streams ?? []).compactMap(\.codec_type)
        let duration = Double(out.format?.duration ?? "") ?? 0
        return .init(durationSeconds: duration,
                     hasVideo: types.contains("video"),
                     hasAudio: types.contains("audio"))
    }
}
