import Foundation

// MARK: - Trim Master — pure engine logic
//
// "Trim Master…" — Rick 2026-07-16. Cuts static/garbage off the head and
// tail of an archival master (the canonical case: a 2-hour VHS capture →
// 100 GB FFV1/MKV) with a pure ffmpeg STREAM COPY — no re-encode, ever.
// The trimmed file becomes the clean archival version; the original is
// never modified and stays in the catalog.
//
// This file is the PURE half: codec classification, timecode parse/format,
// range validation, output-size estimation, the exact ffmpeg argument
// vector, and the keyframe-probe parser. No I/O — everything here is
// unit-testable without media. The subprocess/publish/catalog half lives
// in TrimJob.swift.
//
// ── The -ss placement decision (measured 2026-07-16, ffmpeg 7.x) ──────
//
// Three arrangements were tested against synthetic fixtures (FFV1/MKV
// g=1 and g=12(default), ProRes/MOV, DV/AVI, long-GOP H.264/MP4,
// MPEG-2/MXF), counting output video packets with ffprobe:
//
//   (a) `-ss <in> -i src -t <out−in> … -c copy`   INPUT seeking
//       → seeks via the container index to the last SEEK POINT ≤ in,
//         then copies for the requested duration. On all-intra sources
//         (ProRes, DV, FFV1 with -g 1 — which is exactly what our own
//         Preservation preset writes, see TranscodeJob+Args) the seek
//         point IS the requested frame: measured EXACTLY 75/75 frames
//         for a 3 s cut at 25 fps. Fast on a 100 GB file (index seek,
//         no demux of the skipped 2 hours).
//   (b) `-ss/-to both before -i` — identical packet counts to (a);
//         (a) is kept because `-t <duration>` is unambiguous about the
//         post-seek timeline, while input `-to` semantics have shifted
//         across ffmpeg versions.
//   (c) `-i src -ss <in> -to <out>` OUTPUT seeking — REJECTED. With
//         -c copy it demuxes from t=0 (minutes of wasted I/O on 100 GB)
//         and, worse, DROPS leading packets up to the next keyframe
//         AFTER the in-point: measured cut starting 0.4 s LATE on a
//         default-GOP FFV1 fixture — it deletes content the user asked
//         to keep. Input seeking errs the other way (starts at/earlier
//         than asked — extra static, never missing family footage).
//
// So: `-ss` BEFORE `-i`, duration via `-t`, always `-map 0 -c copy`.
//
// ── The FFV1 "GOP" surprise (also measured) ───────────────────────────
//
// FFV1 is an intra-only codec in the DCT sense, but ffmpeg's encoder
// defaults to `-g 12`: frames between "keyframes" reuse the range-coder
// context of the previous frame and are NOT independent seek points.
// A default-GOP FFV1/MKV therefore snaps to ~0.5 s boundaries. Our own
// Preservation masters are written with `-g 1` (every frame a seek
// point → truly frame-accurate). Classification below is by codec NAME
// (the honest baseline the UI shows immediately); TrimJob/TrimSheet can
// additionally run the cheap packet-flag probe (parser at the bottom of
// this file) to confirm or downgrade the frame-accuracy claim for the
// actual file.

// MARK: - Codec accuracy classification

/// How accurately a stream-copy trim can honor the requested cut points
/// for a given video codec.
/// (≈ a C++ enum class driving a policy table.)
enum TrimCodecClass: String, Sendable {
    /// Every frame is (nominally) independently decodable — a stream-copy
    /// cut lands on the requested frame. FFV1 caveat: see the file
    /// header; the packet-flag probe is the final word.
    case intraOnly
    /// Inter-frame compression — a stream-copy cut snaps BACK to the
    /// nearest earlier keyframe (up to one GOP of extra footage kept).
    case longGOP
    /// Codec not in either table — treated exactly like longGOP (honest
    /// warning), never silently promised frame accuracy.
    case unknown

    /// Whether the UI may claim a frame-accurate cut (subject to the
    /// packet-flag probe's confirmation).
    var claimsFrameAccuracy: Bool { self == .intraOnly }
}

enum TrimCodecClassifier {

    /// ffprobe `codec_name` values that are intra-only (every coded
    /// picture independently decodable).
    static let intraOnlyCodecs: Set<String> = [
        "ffv1", "prores", "dvvideo", "mjpeg", "mjpegb", "huffyuv",
        "ffvhuff", "v210", "v410", "rawvideo", "png", "qtrle",
        "utvideo", "magicyuv", "dnxhd", "jpeg2000", "tiff", "cfhd"
    ]

    /// ffprobe `codec_name` values known to use long-GOP inter coding.
    static let longGOPCodecs: Set<String> = [
        "h264", "hevc", "mpeg2video", "mpeg1video", "mpeg4", "vp8",
        "vp9", "av1", "wmv1", "wmv2", "wmv3", "vc1", "msmpeg4v1",
        "msmpeg4v2", "msmpeg4v3", "h263", "theora", "flv1", "svq1",
        "svq3", "cinepak", "indeo3", "indeo4", "indeo5", "rpza"
    ]

    /// Classify an ffprobe codec name. Case/whitespace tolerant; empty
    /// or unrecognized → `.unknown` (treated as long-GOP — never
    /// silently promise frame accuracy for a codec we haven't vetted).
    static func classify(videoCodec: String) -> TrimCodecClass {
        let name = videoCodec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if intraOnlyCodecs.contains(name) { return .intraOnly }
        if longGOPCodecs.contains(name) { return .longGOP }
        return .unknown
    }
}

// MARK: - Timecode parse / format

/// HH:MM:SS(.mmm) ⇄ seconds for the trim sheet's in/out fields.
/// Pure, locale-independent (POSIX-style manual parse — no DateFormatter,
/// which would drag in locale/timezone behavior we don't want here).
enum TrimTimecode {

    /// Parse "HH:MM:SS", "HH:MM:SS.mmm", "MM:SS(.mmm)" or plain
    /// "SS(.mmm)" into seconds. Returns nil for anything malformed:
    /// empty, negative, non-numeric, minutes/seconds ≥ 60 (in the
    /// multi-component forms), or extra components.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        let parts = trimmed.components(separatedBy: ":")
        guard (1...3).contains(parts.count) else { return nil }

        // Every component must be plain digits, except the last which may
        // carry a ".fraction".
        var values: [Double] = []
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty else { return nil }
            if isLast {
                // digits(.digits)? — reject "1.2.3", "1e5", "+3" etc.
                guard part.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil,
                      let v = Double(part) else { return nil }
                values.append(v)
            } else {
                guard part.range(of: #"^\d+$"#, options: .regularExpression) != nil,
                      let v = Double(part) else { return nil }
                values.append(v)
            }
        }

        switch values.count {
        case 1:
            return values[0]
        case 2:
            guard values[1] < 60 else { return nil }
            return values[0] * 60 + values[1]
        default:
            guard values[1] < 60, values[2] < 60 else { return nil }
            return values[0] * 3600 + values[1] * 60 + values[2]
        }
    }

    /// Commit an edited timecode field: the parsed value, or `lastGood`
    /// when the text is unparseable. Used by the trim sheet on field
    /// submit AND at Trim-click time — typing an out-point and clicking
    /// Trim without pressing Return must use the TYPED value, not the
    /// last committed one (QA MINOR 4, 2026-07-17).
    static func commitValue(text: String, lastGood: Double) -> Double {
        parse(text) ?? lastGood
    }

    /// Format seconds as "HH:MM:SS" (whole seconds) or "HH:MM:SS.mmm"
    /// (fractional), millisecond precision. Negative input clamps to 0.
    /// Round-trip contract: `parse(format(x)) == x` within 0.5 ms.
    static func format(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        // Round to milliseconds FIRST so 59.9996 doesn't render ":59.1000".
        let totalMS = Int64((clamped * 1000).rounded())
        let ms = totalMS % 1000
        let totalSeconds = totalMS / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if ms == 0 {
            return String(format: "%02lld:%02lld:%02lld", h, m, s)
        }
        return String(format: "%02lld:%02lld:%02lld.%03lld", h, m, s, ms)
    }
}

// MARK: - Trim range + validation

/// The user's requested cut, in source-file seconds.
struct TrimRange: Equatable, Sendable {
    let inSeconds: Double
    let outSeconds: Double
    var duration: Double { outSeconds - inSeconds }
}

/// Why a requested trim can't run. Every case carries friendly text —
/// these surface directly in the job row / sheet.
enum TrimPlanError: Error, Equatable {
    case inNotBeforeOut
    case outBeyondDuration(sourceDuration: Double)
    case negativeIn

    var friendlyMessage: String {
        switch self {
        case .inNotBeforeOut:
            return "The start point must come before the end point."
        case .outBeyondDuration(let dur):
            return "The end point is past the end of the video (\(TrimTimecode.format(dur)))."
        case .negativeIn:
            return "The start point can't be negative."
        }
    }
}

enum TrimPlan {

    /// The provenance tag written to `VideoRecord.derivationKind` on
    /// trim derivatives (the universal which-MFO-verb marker; Balance
    /// Audio writes "balanceAudio" via `BalanceAudioFix.derivationKind`).
    static let derivationKind = "trim"

    /// Validate a requested range against the source duration.
    /// `sourceDuration <= 0` means "duration unknown" (a probe failure) —
    /// the out-bound check is skipped, in<out is still enforced.
    /// A small tolerance lets out == duration-as-displayed pass despite
    /// container rounding (mkv reports 10.013 for a 10.0 s encode).
    static func validate(range: TrimRange,
                         sourceDuration: Double,
                         tolerance: Double = 0.5) throws {
        guard range.inSeconds >= 0 else { throw TrimPlanError.negativeIn }
        guard range.inSeconds < range.outSeconds else { throw TrimPlanError.inNotBeforeOut }
        if sourceDuration > 0, range.outSeconds > sourceDuration + tolerance {
            throw TrimPlanError.outBeyondDuration(sourceDuration: sourceDuration)
        }
    }

    /// Estimated output size for the free-space precheck and the sheet's
    /// readout: source size × kept fraction, +5% container overhead,
    /// +64 MB fixed margin. Duration unknown (≤0) → assume the whole
    /// source is kept (conservative — never under-checks disk space).
    static func estimatedOutputBytes(sourceBytes: Int64,
                                     sourceDuration: Double,
                                     range: TrimRange) -> Int64 {
        guard sourceBytes > 0 else { return 64 << 20 }
        let fraction: Double
        if sourceDuration > 0 {
            fraction = min(1.0, max(0.0, range.duration / sourceDuration))
        } else {
            fraction = 1.0
        }
        let estimate = Double(sourceBytes) * fraction * 1.05 + Double(64 << 20)
        return Int64(estimate)
    }

    /// Duration tolerance for the post-trim ffprobe verification.
    /// Intra: container rounding + one frame — 0.75 s covers every
    /// measured case with margin. Long-GOP/unknown: the cut legitimately
    /// snaps back up to one GOP (measured +1.2 s on a 2 s-GOP H.264;
    /// old MPEG-2 captures can run ~15 s GOPs), so the check only
    /// catches gross failures, not the honest snap.
    static func verificationTolerance(for codecClass: TrimCodecClass) -> Double {
        switch codecClass {
        case .intraOnly: return 0.75
        case .longGOP, .unknown: return 20.0
        }
    }

    /// The exact ffmpeg argument vector for a stream-copy trim.
    /// See the file header for the measured -ss placement rationale.
    ///   -ss before -i        index seek to ≤ in (fast, keeps content)
    ///   -t (out − in)        duration on the post-seek timeline
    ///   -map 0               carry ALL streams: video, audio, subs, data
    ///   -c copy              stream copy — the whole point; NEVER re-encode
    ///   -avoid_negative_ts   normalize shifted timestamps for the muxer
    ///   -progress pipe:2     structured progress for the job row
    /// Output goes to the `.vs-partial` sibling; TrimJob promotes it.
    static func ffmpegArgs(input: String,
                           partialOutput: String,
                           range: TrimRange) -> [String] {
        [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-ss", String(format: "%.3f", range.inSeconds),
            "-i", input,
            "-t", String(format: "%.3f", range.duration),
            "-map", "0",
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "-progress", "pipe:2",
            partialOutput
        ]
    }
}

// MARK: - Keyframe probe parsing

/// Parses the output of the cheap "are the first N packets all seek
/// points?" probe:
///
///   ffprobe -select_streams v:0 -read_intervals %+#N \
///           -show_entries packet=pts_time,flags -of csv=p=0 file
///
/// which emits lines like "0.000000,K__" / "0.040000,___". All-K over a
/// GOP-sized sample ⇒ genuinely all-intra ⇒ the frame-accuracy claim
/// holds. Any non-K ⇒ downgrade to the keyframe-snap warning (the
/// default-GOP FFV1 case). Pure parser — the subprocess lives with its
/// callers.
enum TrimKeyframeProbe {

    /// nil = probe produced no parseable packets (undecidable — callers
    /// must fall back to the by-name classification, not claim accuracy).
    static func allSampledPacketsAreKeyframes(csv: String) -> Bool? {
        var sawPacket = false
        for rawLine in csv.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            sawPacket = true
            // flags field: "K__" / "K_" / "___" — keyframe iff it
            // contains "K".
            if !fields[1].contains("K") { return false }
        }
        return sawPacket ? true : nil
    }
}

// MARK: - Frame-rate parsing (for the ±1-frame nudge)

enum TrimFrameRate {

    /// Parse the catalog's display frame-rate string into fps.
    /// Accepts "29.97", "29.97 fps", "30000/1001". Returns nil when
    /// unparseable — callers fall back to a 1/30 s nudge.
    static func fps(fromDisplayString text: String) -> Double? {
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "fps", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains("/") {
            let parts = cleaned.split(separator: "/")
            guard parts.count == 2,
                  let num = Double(parts[0]), let den = Double(parts[1]),
                  den > 0, num > 0 else { return nil }
            return num / den
        }
        guard let v = Double(cleaned), v > 0, v.isFinite else { return nil }
        return v
    }
}
