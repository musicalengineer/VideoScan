import Foundation
import os

// MARK: - Verify Audio diagnosis engine (GH #128)
//
// "Verify Audio…" — Rick 2026-07-24. One catalog verb that DIAGNOSES a
// file's audio instead of dead-ending on "bad audio" (proof case:
// JustPatsHouse.mov, an Avid reference movie with no essence). This
// file follows the repo's engine split:
//
//   - `VerifyAudioRules`  — PURE classification: findings taxonomy,
//     reference-movie stderr parsing, duration-mismatch rule, and the
//     persisted status/note mapping. No I/O — fully unit-testable.
//   - `VerifyAudioProbe`  — the I/O half: one ffprobe pass (capturing
//     stderr for the dref "Skipped opening external track" lines), then
//     AudioBalanceProbe.analyze for the per-channel levels. Reuses the
//     existing Balance Audio machinery rather than growing a parallel
//     probe stack.
//
// FINDINGS TAXONOMY (empty findings = "All is well"):
//   - channelImbalance    → offer Balance Audio (existing engine
//                           becomes a treatment, not an entry point)
//   - unsupportedCodec    → offer Rebuild Audio Track (RebuildAudioJob:
//                           -c:v copy + audio-only pcm_s16le re-encode)
//   - noAudioStream       → point at Find Matching Audio (message only)
//   - referenceMovie      → dref aliases, essence missing — no repair
//                           possible; show referenced paths; DAMAGED
//   - durationMismatch    → audio >10% shorter than video (the #125
//                           class); suggest correlate/deep-verify; DAMAGED
//   - silentAudio         → reported honestly, not damaged
//   - surround            → reported; Balance Audio can't help yet
//   - multipleProgramTracks → >1 audio track carries program (12-bit DV
//                           both-pairs-live shape) — Balance would
//                           refuse it, so we report instead of offering
//
// FRAME-RATE GOTCHA: the readout never surfaces a frame rate — shallow
// probes of elementary streams misreport avg_frame_rate. The probed
// r_frame_rate is kept ONLY as the raw-DV `-r` input override for the
// rebuild remux (where `-c:v copy` makes the rate cosmetic anyway).
//
// Memory: ffprobe/ffmpeg stream; this process retains only ffprobe's
// JSON (KBs) + its stderr (capped 256 KB by ProcessRunner) + astats
// stderr per stream. Worst-case in-process footprint ≈ 1 MB per
// diagnosis.
//
// Concurrency: `diagnose` is `@concurrent` — this repo's Approachable
// Concurrency runs `nonisolated async` on the CALLER's actor, so a
// plain async func called from the @MainActor sheet would decode audio
// on the UI thread (the documented trap). `@concurrent` forces the
// global executor. (For Rick: ≈ explicitly punting work to a background
// thread pool instead of inheriting the caller's thread.)

private let verifyLog = Logger(subsystem: "Rick-Breen.VideoScan",
                               category: "verifyAudio")

// MARK: - Shape (extended ffprobe view)

/// What Verify Audio's ffprobe pass learned — a superset of the balance
/// probe's shape (adds per-stream durations, sample rate, bit depth,
/// and the file size for the reference-movie corroboration).
struct AudioVerifyShape: Sendable, Equatable {
    var videoCodec: String?
    /// First VIDEO stream's own duration (0 = unknown/absent).
    var videoDurationSeconds: Double = 0
    /// `r_frame_rate` of the first video stream — kept only for the
    /// raw-DV `-r` rebuild override, never displayed (see file header).
    var videoRFrameRate: String?
    var audioStreams: Int = 0
    /// First AUDIO stream's codec/channels/etc. (the stream the rebuild
    /// maps with `0:a:0`).
    var audioCodec: String = ""
    var audioChannels: Int = 0
    var audioSampleRateHz: Int?
    /// Stored bit depth when ffprobe reports one; derived from the PCM
    /// codec name otherwise; nil = unknown (typical for lossy codecs).
    var audioBitDepth: Int?
    /// First AUDIO stream's own duration (0 = unknown).
    var audioDurationSeconds: Double = 0
    var containerFormat: String = ""
    var containerDurationSeconds: Double = 0
    var fileSizeBytes: Int64 = 0
}

// MARK: - Findings

/// One diagnosis finding. Empty list = healthy ("All is well").
/// (≈ a C++ tagged union / std::variant — cases carry their payload.)
enum AudioVerifyFinding: Sendable, Equatable {
    /// One-sided stereo or plain mono — Balance Audio applies. Only
    /// ever produced when `BalanceAudioFix.refusalReason` is nil for
    /// the analysis, so the sheet never offers what the job refuses.
    case channelImbalance(AudioChannelClass)
    /// Audio codec AVFoundation can't play (qdm2/mace/…) or a track
    /// ffmpeg itself failed to decode — Rebuild Audio Track applies.
    /// `decodable` = false when even ffmpeg couldn't read it (rebuild
    /// is still offered; it fails loudly if ffmpeg truly can't decode).
    case unsupportedCodec(codec: String, decodable: Bool)
    /// No audio stream at all — point at Find Matching Audio.
    case noAudioStream
    /// QuickTime/Avid reference movie: the file only points at media on
    /// another disk (dref external aliases). No repair possible. DAMAGED.
    case referenceMovie(referencedPaths: [String])
    /// Audio stream runs >10% shorter than the picture (the #125
    /// wrong-audio class) — suggest correlate/deep-verify. DAMAGED.
    case durationMismatch(audioSeconds: Double, videoSeconds: Double)
    /// Audio track present but carries no program at all.
    case silentAudio
    /// More than 2 channels — reported; Balance Audio can't help yet.
    case surround(channels: Int)
    /// More than one audio track carries program (12-bit DV with both
    /// pairs live) — Balance Audio would refuse, so no button.
    case multipleProgramTracks(count: Int)
}

/// The complete diagnosis the sheet displays and persists.
struct AudioVerifyDiagnosis: Sendable {
    var findings: [AudioVerifyFinding]
    var shape: AudioVerifyShape
    /// Per-channel levels + classification when the astats pass ran
    /// (nil for reference movies, no-audio, and undecodable tracks).
    /// Handed verbatim to `startBalanceAudio` when the imbalance
    /// finding's button is clicked — same analyze-then-confirm contract
    /// BalanceAudioSheet uses.
    var balanceAnalysis: AudioBalanceAnalysis?

    var isHealthy: Bool { findings.isEmpty }

    /// Persisted `audioVerifyStatus` for this diagnosis.
    var persistedStatus: String { VerifyAudioRules.status(for: findings) }
    /// Persisted `audioVerifyNote` for this diagnosis.
    var persistedNote: String { VerifyAudioRules.note(for: findings) }
}

enum AudioVerifyProbeError: Error, Equatable {
    case toolUnavailable(String)
    case probeFailed(String)
}

// MARK: - Pure rules

enum VerifyAudioRules {

    /// Audio must be at least this fraction shorter than the video
    /// before we call it a mismatch (the ">10%" rule from the spec).
    static let durationMismatchFraction: Double = 0.10

    /// The stderr marker ffprobe's mov demuxer emits once per dref
    /// external track it could not open. The remainder of the line
    /// carries the alias/path detail we surface to the user.
    static let referenceTrackMarker = "Skipped opening external track"

    /// Parse the referenced-path details out of ffprobe's stderr. One
    /// entry per marker line, de-duplicated in order. Pure — tested
    /// with canned stderr text.
    static func referencedPaths(fromProbeStderr stderr: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in stderr.split(separator: "\n") {
            guard let range = line.range(of: referenceTrackMarker) else { continue }
            var detail = line[range.upperBound...]
            // Strip a leading ": " / ":" separator, then trim.
            while detail.first == ":" || detail.first == " " {
                detail = detail.dropFirst()
            }
            let path = detail.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    /// True when the audio stream runs meaningfully SHORTER than the
    /// video (>10%). Only fires when both durations are known — an
    /// unknown duration must never manufacture a damage verdict.
    static func hasDurationMismatch(audioSeconds: Double,
                                    videoSeconds: Double) -> Bool {
        guard audioSeconds > 0, videoSeconds > 0 else { return false }
        return (videoSeconds - audioSeconds) / videoSeconds > durationMismatchFraction
    }

    /// Corroboration for the reference-movie verdict: a file claiming
    /// a long duration but occupying almost no bytes cannot contain
    /// real essence. Purely informational — the marker lines are the
    /// authoritative signal.
    static func isSuspiciouslyTiny(fileSizeBytes: Int64,
                                   durationSeconds: Double) -> Bool {
        durationSeconds >= 60 && fileSizeBytes > 0 && fileSizeBytes < (2 << 20)
    }

    /// Derive a bit depth from a PCM codec name when ffprobe didn't
    /// report `bits_per_raw_sample` ("pcm_s16le" → 16). nil for lossy /
    /// unknown codecs — the readout shows "—" rather than a guess.
    static func bitDepth(fromCodecName codec: String) -> Int? {
        let c = codec.lowercased()
        guard c.hasPrefix("pcm_") else { return nil }
        let digits = c.dropFirst(4).drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// The common prefix EVERY damaged-status note leads with (Manager
    /// decision 2026-07-24): one `notes:damaged` query batch-finds all
    /// red rows — no per-cause query zoo. The em dash separates prefix
    /// from detail, so detail fragments must not carry their own em
    /// dash (see the referenceMovie fragment's comma).
    static let damagedNotePrefix = "Damaged audio — "

    /// Which findings mark the record DAMAGED (red row, batch-delete
    /// candidate). Everything else is reported in the sheet but leaves
    /// the record's status at "ok" — imbalance is repairable, silence /
    /// no-audio / surround are honest states, not broken files.
    static func isDamage(_ finding: AudioVerifyFinding) -> Bool {
        switch finding {
        case .referenceMovie, .durationMismatch, .unsupportedCodec:
            return true
        case .channelImbalance, .noAudioStream, .silentAudio, .surround,
             .multipleProgramTracks:
            return false
        }
    }

    /// Persisted `audioVerifyStatus`: "damaged" when any damage finding
    /// is present, otherwise "ok" (verified — even when non-damage
    /// findings exist; the note carries their story). "" is reserved
    /// for never-verified and is never produced here.
    static func status(for findings: [AudioVerifyFinding]) -> String {
        findings.contains(where: isDamage) ? "damaged" : "ok"
    }

    /// Short machine note per finding — the catalog tooltip / notes:
    /// token text. Ordered damage-first so a damaged record's note
    /// leads with why it's red. Fragments stay UNPREFIXED — `note(for:)`
    /// adds `damagedNotePrefix` once for damaged verdicts, and the
    /// rebuild's File Journey `reason` uses the bare fragment.
    static func noteFragment(for finding: AudioVerifyFinding) -> String {
        switch finding {
        case .referenceMovie:
            // Comma, not em dash: the damaged-note prefix already uses
            // the em dash — "Damaged audio — reference movie, media
            // missing" reads as one clause, not two dashes.
            return "reference movie, media missing"
        case .unsupportedCodec(let codec, let decodable):
            return decodable
                ? "invalid codec (\(codec))"
                : "undecodable audio (\(codec.isEmpty ? "unknown codec" : codec))"
        case .durationMismatch(let audio, let video):
            return "audio shorter than video (\(Int(audio.rounded()))s vs \(Int(video.rounded()))s)"
        case .channelImbalance(let c):
            switch c {
            case .leftOnly:  return "one-sided audio (left only)"
            case .rightOnly: return "one-sided audio (right only)"
            case .mono:      return "mono audio"
            default:         return "channel imbalance"
            }
        case .noAudioStream:
            return "no audio stream"
        case .silentAudio:
            return "silent audio"
        case .surround(let channels):
            return "surround audio (\(channels) channels)"
        case .multipleProgramTracks(let count):
            return "\(count) live audio tracks"
        }
    }

    /// Persisted `audioVerifyNote` — damage fragments first, joined
    /// with "; ". "" for a clean bill of health. Damaged verdicts lead
    /// with `damagedNotePrefix` so ONE query (`notes:damaged`) batch-
    /// finds every red row — the #128 batch-delete flow; ok-status
    /// notes stay bare.
    static func note(for findings: [AudioVerifyFinding]) -> String {
        let ordered = findings.filter(isDamage) + findings.filter { !isDamage($0) }
        let joined = ordered.map(noteFragment(for:)).joined(separator: "; ")
        guard !joined.isEmpty else { return "" }
        return findings.contains(where: isDamage)
            ? damagedNotePrefix + joined
            : joined
    }

    /// Build the findings list from the probed shape + (optional)
    /// balance analysis. `analyzeFailed` = the astats levels pass threw
    /// (ffmpeg couldn't decode the audio). Pure — the I/O half feeds
    /// it, tests feed it canned values.
    static func findings(shape: AudioVerifyShape,
                         referencedPaths: [String],
                         analysis: AudioBalanceAnalysis?,
                         analyzeFailed: Bool) -> [AudioVerifyFinding] {
        // Reference movie outranks everything: there is no real essence
        // in the file, so every other measurement is meaningless.
        if !referencedPaths.isEmpty {
            return [.referenceMovie(referencedPaths: referencedPaths)]
        }
        var out: [AudioVerifyFinding] = []
        guard shape.audioStreams > 0 else {
            return [.noAudioStream]
        }
        // Codec trouble: AVFoundation-dead codec (ffmpeg still decodes
        // these — the rebuild fixes playback), or a track even ffmpeg
        // couldn't decode.
        let codec = shape.audioCodec.lowercased()
            .trimmingCharacters(in: .whitespaces)
        if analyzeFailed {
            out.append(.unsupportedCodec(codec: shape.audioCodec, decodable: false))
        } else if !codec.isEmpty, unplayableLegacyAudioCodecs.contains(codec) {
            out.append(.unsupportedCodec(codec: shape.audioCodec, decodable: true))
        }
        // Duration mismatch is independent of level findings — wrong
        // audio can be perfectly stereo (#125: a 2-minute track on a
        // 63-minute Christmas video).
        if hasDurationMismatch(audioSeconds: shape.audioDurationSeconds,
                               videoSeconds: shape.videoDurationSeconds) {
            out.append(.durationMismatch(audioSeconds: shape.audioDurationSeconds,
                                         videoSeconds: shape.videoDurationSeconds))
        }
        // Level-based findings need the analysis.
        if let analysis {
            if analysis.programStreamCount > 1 {
                out.append(.multipleProgramTracks(count: analysis.programStreamCount))
            } else {
                switch analysis.classification {
                case .silent:
                    out.append(.silentAudio)
                case .multichannel:
                    out.append(.surround(channels: analysis.measurements.channels.count))
                case .leftOnly, .rightOnly, .mono:
                    // Offer Balance ONLY when the shared gate agrees —
                    // the sheet must never promise what the job refuses.
                    if BalanceAudioFix.refusalReason(for: analysis) == nil {
                        out.append(.channelImbalance(analysis.classification))
                    }
                case .dualMono, .trueStereo:
                    break   // healthy from a channel-balance standpoint
                }
            }
        }
        return out
    }
}

// MARK: - Probe (I/O)

enum VerifyAudioProbe {

    /// ffprobe request — the balance probe's fields PLUS per-stream
    /// duration/sample_rate/bits_per_raw_sample and the container size
    /// (reference-movie corroboration). Pure args builder.
    static func shapeArgs(input: String) -> [String] {
        [
            // NOT "-v error": the dref "Skipped opening external track"
            // lines are emitted at default (info) verbosity and are the
            // reference-movie detection signal. JSON rides on stdout
            // either way; -hide_banner keeps stderr scannable.
            "-hide_banner",
            "-show_entries",
            "stream=index,codec_type,codec_name,channels,sample_rate,bits_per_raw_sample,bit_rate,r_frame_rate,duration",
            "-show_entries", "format=format_name,duration,size",
            "-of", "json",
            input
        ]
    }

    // MARK: ffprobe JSON decoding (pure)

    private struct ProbedStream: Decodable {
        let index: Int?
        let codec_type: String?
        let codec_name: String?
        let channels: Int?
        let sample_rate: String?
        let bits_per_raw_sample: String?
        let bit_rate: String?
        let r_frame_rate: String?
        let duration: String?
    }
    private struct ProbedFormat: Decodable {
        let format_name: String?
        let duration: String?
        let size: String?
    }
    private struct ProbeReport: Decodable {
        let streams: [ProbedStream]?
        let format: ProbedFormat?
    }

    /// Decode ffprobe's JSON into the extended shape. Pure — tested
    /// with canned JSON. Unlike the balance probe's `shape`, a file
    /// with NO audio decodes fine here (no-audio IS a finding).
    static func shape(fromProbeJSON data: Data) throws -> AudioVerifyShape {
        let report: ProbeReport
        do {
            report = try JSONDecoder().decode(ProbeReport.self, from: data)
        } catch {
            throw AudioVerifyProbeError.probeFailed(
                "ffprobe output was not readable JSON")
        }
        let streams = report.streams ?? []
        var shape = AudioVerifyShape()
        shape.containerFormat = report.format?.format_name ?? ""
        shape.containerDurationSeconds = Double(report.format?.duration ?? "") ?? 0
        shape.fileSizeBytes = Int64(report.format?.size ?? "") ?? 0

        if let video = streams.first(where: { $0.codec_type == "video" }) {
            shape.videoCodec = video.codec_name
            shape.videoRFrameRate = video.r_frame_rate
            shape.videoDurationSeconds = Double(video.duration ?? "") ?? 0
        }
        let audio = streams.filter { $0.codec_type == "audio" }
        shape.audioStreams = audio.count
        if let first = audio.first {
            shape.audioCodec = first.codec_name ?? ""
            shape.audioChannels = first.channels ?? 0
            shape.audioSampleRateHz = first.sample_rate.flatMap { Int($0) }
            shape.audioBitDepth = first.bits_per_raw_sample.flatMap { Int($0) }
                ?? VerifyAudioRules.bitDepth(fromCodecName: shape.audioCodec)
            shape.audioDurationSeconds = Double(first.duration ?? "") ?? 0
        }
        // Missing per-stream durations (some MXF/elementary shapes):
        // fall back to the container duration for the VIDEO side only —
        // the audio side must stay 0/unknown so the mismatch rule can't
        // fire against a guessed value.
        if shape.videoDurationSeconds == 0, shape.videoCodec != nil {
            shape.videoDurationSeconds = shape.containerDurationSeconds
        }
        return shape
    }

    // MARK: Full diagnosis (I/O)

    /// Diagnose one media file's audio: extended ffprobe (stderr kept
    /// for the dref reference-movie signal), then — when audio exists
    /// and the file is not a reference movie — the balance analyzer's
    /// per-stream astats pass for levels + classification.
    ///
    /// `@concurrent`: runs on the global executor — safe to call from
    /// the @MainActor sheet without pinning the UI thread (file-header
    /// concurrency note).
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func diagnose(path: String) async throws -> AudioVerifyDiagnosis {
        let ffprobe = ToolLocator.ffprobePath
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            throw AudioVerifyProbeError.toolUnavailable(
                "ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)")
        }

        // ---- Shape + stderr (ffprobe, sub-second).
        let probeResult = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: shapeArgs(input: path),
            stdoutLimitBytes: 1 << 20,
            deadlineSeconds: 60)
        guard probeResult.exitCode == 0, let stdout = probeResult.stdout,
              let data = stdout.data(using: .utf8) else {
            throw AudioVerifyProbeError.probeFailed(
                "ffprobe exited with status \(probeResult.exitCode)")
        }
        let shape = try Self.shape(fromProbeJSON: data)
        let referencedPaths = VerifyAudioRules.referencedPaths(
            fromProbeStderr: probeResult.stderr)
        try Task.checkCancellation()

        // ---- Levels pass (audio-only decode; seconds even for a
        // two-hour tape). Skipped for reference movies (no essence to
        // decode) and no-audio files. A decode failure is itself a
        // finding, not a diagnosis failure.
        var analysis: AudioBalanceAnalysis?
        var analyzeFailed = false
        if referencedPaths.isEmpty, shape.audioStreams > 0 {
            do {
                analysis = try await AudioBalanceProbe.analyze(path: path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                analyzeFailed = true
                verifyLog.notice("verify: levels pass failed for \((path as NSString).lastPathComponent, privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        try Task.checkCancellation()

        let findings = VerifyAudioRules.findings(
            shape: shape,
            referencedPaths: referencedPaths,
            analysis: analysis,
            analyzeFailed: analyzeFailed)
        let diagnosis = AudioVerifyDiagnosis(
            findings: findings, shape: shape, balanceAnalysis: analysis)
        verifyLog.info("verify: \((path as NSString).lastPathComponent, privacy: .public) → \(diagnosis.isHealthy ? "healthy" : diagnosis.persistedNote, privacy: .public) (status=\(diagnosis.persistedStatus, privacy: .public), audioStreams=\(shape.audioStreams), refs=\(referencedPaths.count))")
        return diagnosis
    }
}
