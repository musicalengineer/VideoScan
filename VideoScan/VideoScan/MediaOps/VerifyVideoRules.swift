import Foundation

// MARK: - Verify Video — pure rules (Rick 2026-09-23)
//
// "Verify Video" is Verify Audio's picture-side sibling: one catalog verb
// that DIAGNOSES a file's video and says, in plain words, whether it is
// OK, has a Warning, or is Broken — plus what to do about it.
//
// Motivating case (READ-ONLY calibration, never modified):
//   DickyTheBoysDadBreen-1985.mp4 — HandBrake 1.9.2, 640×480 h264, 71.2 s,
//   45,976,101,977 bytes, 4,268,265 frames, r_frame_rate 90000/1,
//   5.2 Gbit/s. Every frame stored ~2,000× — a broken encode, 46 GB for
//   71 s. Its healthy sibling (-3.mp4) is 39 MB, 2,133 frames, 29.97 fps.
//
// Engine split (the VerifyAudioProbe convention):
//   - THIS FILE — PURE. Fact structs, findings taxonomy, one small check
//     function per rule, verdict/note/recommendation mapping, and the
//     ffprobe/packet/progress parsers. No I/O — every rule is table-tested
//     (VerifyVideoRulesTests) including the Dicky numbers.
//   - VerifyVideoProbe.swift — the I/O half (ffprobe, packet samples, the
//     full decode) through ProcessRunner (the one shell-out module).
//
// Each check is `static func check…(…) -> [VideoVerifyFinding]` over facts
// only. (≈ C++: free functions over POD structs — no hidden state, so a
// test can feed any number it likes.)

// MARK: - Facts

/// What ffprobe's header pass learned about the file. 0 / "" / nil mean
/// "unknown" everywhere — an unknown value must never manufacture a
/// finding (the VerifyAudioRules.hasDurationMismatch rule).
struct VideoVerifyFacts: Sendable, Equatable {
    /// At least one real video stream (cover art / attached pictures
    /// excluded — an mp3's album art is not a picture track).
    var hasVideo: Bool = false
    var videoCodec: String = ""
    var width: Int = 0
    var height: Int = 0
    /// "8:9", "1:1", "0:1" (= unknown), "" (absent).
    var sampleAspectRatio: String = ""
    var displayAspectRatio: String = ""
    /// Parsed r_frame_rate (0 = "0/0" / unknown).
    var rFrameRate: Double = 0
    /// Parsed avg_frame_rate (0 = unknown).
    var avgFrameRate: Double = 0
    /// nb_frames — nil when the container doesn't record it (Matroska).
    var frameCount: Int?
    /// The video stream's own duration (falls back to the container's).
    var videoDurationSeconds: Double = 0
    /// First audio stream's duration (0 = no audio / unknown).
    var audioDurationSeconds: Double = 0
    var containerDurationSeconds: Double = 0
    var fileSizeBytes: Int64 = 0
    /// Video stream bit_rate in bits/s (0 = unknown).
    var videoBitRate: Int64 = 0
    var containerFormat: String = ""
    /// Container "encoder" tag ("HandBrake 1.9.2 …") — informational.
    var encoder: String = ""
}

/// Short packet-timestamp samples (start of file + middle), never a
/// whole-file walk. Built by `VerifyVideoRules.packetSample(from:)`.
struct VideoPacketSample: Sendable, Equatable {
    var packets: Int = 0
    /// max(pts) − min(pts) over the sample.
    var ptsSpanSeconds: Double = 0
    /// Consecutive packets whose DTS went strictly BACKWARD.
    var dtsBackwardSteps: Int = 0
    /// Largest step between consecutive (sorted) presentation times.
    var largestGapSeconds: Double = 0
    var medianDeltaSeconds: Double = 0
    /// Fraction of packets ≤ `tinyPacketBytes` — the "empty P-frame"
    /// signature of a duplicate-frame encode.
    var tinyPacketFraction: Double = 0
    var medianPacketBytes: Int = 0

    /// Frames per second actually stored in the sampled stretch.
    var sampledFPS: Double? {
        guard packets >= 2, ptsSpanSeconds > 0 else { return nil }
        return Double(packets - 1) / ptsSpanSeconds
    }
}

/// What the full decode (`ffmpeg -v error … -f null -`) found.
struct VideoDecodeFacts: Sendable, Equatable {
    enum Coverage: Sendable, Equatable {
        /// Decoded start to finish.
        case complete
        /// Stopped by the time budget after `checkedSeconds` of picture.
        case partial(checkedSeconds: Double)
        /// Never run — `reason` says why in plain words.
        case skipped(reason: String)
    }
    var coverage: Coverage
    /// ffmpeg error lines on stderr (each is one decode complaint).
    var errorCount: Int = 0
    /// First few error lines, "[h264 @ 0x…]" addresses stripped.
    var sampleErrors: [String] = []
    /// ffmpeg itself gave up (non-zero exit that was NOT our budget and
    /// NOT the user's Stop) at `stoppedAtSeconds`.
    var failedToFinish: Bool = false
    var stoppedAtSeconds: Double = 0
}

// MARK: - Findings

enum VideoVerifySeverity: Int, Sendable, Comparable {
    case info = 0, warning = 1, broken = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Persisted verdict. Raw values ARE the persisted `videoVerifyStatus`
/// strings ("" = never verified is never produced here).
enum VideoVerifyVerdict: String, Sendable, Equatable {
    case ok, warning, broken

    var displayName: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .broken: return "Broken"
        }
    }
}

/// One diagnosis finding. (≈ a C++ std::variant — each case carries its
/// own payload.)
enum VideoVerifyFinding: Sendable, Equatable {
    /// ffprobe can't open it while the file itself is on disk and readable.
    case unopenable(detail: String)
    /// Width or height is zero.
    case zeroDimensions(width: Int, height: Int)
    /// Implausibly large picture.
    case implausibleDimensions(width: Int, height: Int)
    /// SAR/DAR outside anything a real camera or format produces.
    case oddAspect(sar: String, dar: String)
    /// Average frame rate is absurd (> 240 fps).
    case frameRateBroken(fps: Double)
    /// The header rate (r_frame_rate) is absurd but the average is sane.
    case frameRateHeaderOdd(declared: Double, actual: Double)
    /// No usable frame rate at all.
    case frameRateUnknown
    /// Each real frame stored `factor` times over.
    case duplicateFrameBloat(factor: Double, frames: Int, seconds: Double,
                             sizeBytes: Int64, mostlyEmptyPackets: Bool)
    /// Bits per pixel far beyond what the codec family needs.
    case bitrateImplausible(ratio: Double, bitsPerSecond: Int64, severe: Bool)
    case timestampsOutOfOrder(count: Int, sampled: Int)
    case timestampGap(seconds: Double)
    case streamVsContainerDuration(stream: Double, container: Double)
    case videoVsAudioDuration(video: Double, audio: Double)
    case decodeErrors(count: Int, severe: Bool)
    case decodeStopped(atSeconds: Double)
    case partiallyChecked(checkedSeconds: Double, totalSeconds: Double)
    case decodeSkipped(reason: String)
}

// MARK: - Diagnosis

struct VideoVerifyDiagnosis: Sendable, Equatable {
    var findings: [VideoVerifyFinding]
    var facts: VideoVerifyFacts
    var sample: VideoPacketSample?
    var decode: VideoDecodeFacts?

    var verdict: VideoVerifyVerdict { VerifyVideoRules.verdict(for: findings) }
    var persistedStatus: String { verdict.rawValue }
    var persistedNote: String { VerifyVideoRules.note(for: findings) }
    var recommendation: String { VerifyVideoRules.recommendation(for: findings) }
    /// The MFO row's one-line summary.
    var summary: String { VerifyVideoRules.summary(for: findings) }
}

enum VideoVerifyProbeError: Error, Equatable {
    case toolUnavailable(String)
    case probeFailed(String)
    /// The file has no video stream — nothing to verify, no verdict.
    case noVideoStream
}

// MARK: - Rules

enum VerifyVideoRules {

    // MARK: Thresholds (named so the tests pin them)

    /// Above this, a frame rate is not a camera — it's broken timing.
    static let maxPlausibleFPS: Double = 240
    /// Average rate beyond this is Broken on its own (not just Warning).
    static let brokenFPS: Double = 1_000
    /// Stored frames per real frame before we call it duplicate bloat.
    static let bloatMinFactor: Double = 4
    /// The fallback "what a real video runs at" when the header rates are
    /// both absurd (NTSC — the bulk of the family archive).
    static let fallbackReferenceFPS: Double = 30_000.0 / 1_001.0
    /// Duration mismatches beyond this (seconds) are reported.
    static let durationToleranceSeconds: Double = 1.0
    /// A packet this small carries no picture change (skip/empty P-frame).
    static let tinyPacketBytes = 64
    /// Timestamp gap: at least this many seconds AND this many median steps.
    static let gapMinSeconds: Double = 1.0
    static let gapMinMedianMultiple: Double = 20
    /// Decode errors: Broken at this many, or at this rate with ≥ 10.
    static let severeDecodeErrorCount = 100
    static let severeDecodeErrorsPerMinute: Double = 60

    // MARK: Codec families (bitrate plausibility)

    enum CodecFamily: String, Sendable, Equatable {
        case lossy, intraMezzanine, lossless, unknown

        /// Bits per pixel per frame: (typical, warn above, broken above).
        /// Typical is deliberately generous so "N× what it should need"
        /// never overstates.
        var bppBands: (typical: Double, warn: Double, broken: Double)? {
            switch self {
            case .lossy:          return (0.25, 3, 20)
            case .intraMezzanine: return (3, 15, 80)
            case .lossless:       return (8, 64, 256)
            case .unknown:        return nil
            }
        }
    }

    static func codecFamily(_ codec: String) -> CodecFamily {
        let c = codec.lowercased()
        let lossy: Set<String> = [
            "h264", "hevc", "h265", "mpeg4", "mpeg2video", "mpeg1video", "vp8",
            "vp9", "av1", "wmv1", "wmv2", "wmv3", "vc1", "msmpeg4v1",
            "msmpeg4v2", "msmpeg4v3", "h263", "h263p", "svq1", "svq3",
            "theora", "cinepak", "flv1", "rv10", "rv20", "rv30", "rv40",
            "indeo3", "indeo4", "indeo5", "mpeg2", "h261"]
        let mezz: Set<String> = [
            "prores", "prores_ks", "dnxhd", "dnxhr", "cfhd", "mjpeg",
            "jpeg2000", "dvvideo", "avrp", "avui", "hap", "mjpegb"]
        let lossless: Set<String> = [
            "ffv1", "rawvideo", "v210", "v410", "r210", "r10k", "huffyuv",
            "ffvhuff", "utvideo", "magicyuv", "png", "qtrle", "lagarith",
            "zlib", "v308", "v408", "yuv4", "ayuv", "012v", "tiff", "dpx"]
        if lossy.contains(c) { return .lossy }
        if mezz.contains(c) { return .intraMezzanine }
        if lossless.contains(c) { return .lossless }
        return .unknown
    }

    // MARK: Small math helpers

    /// "30000/1001" → 29.97; "0/0" → 0; "25" → 25; garbage → 0.
    static func parseRate(_ s: String?) -> Double {
        guard let s, !s.isEmpty else { return 0 }
        let parts = s.split(separator: "/")
        if parts.count == 2 {
            guard let n = Double(parts[0]), let d = Double(parts[1]), d != 0 else { return 0 }
            return n / d
        }
        return Double(s) ?? 0
    }

    /// "8:9" → 0.888…; "0:1" / "" / garbage → nil (unknown).
    static func parseRatio(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]),
              n > 0, d > 0 else { return nil }
        return n / d
    }

    /// The frame rate a real video of this file would run at: the header
    /// rate when plausible, else the average, else NTSC.
    static func referenceFPS(_ f: VideoVerifyFacts) -> Double {
        if f.rFrameRate > 1, f.rFrameRate <= maxPlausibleFPS { return f.rFrameRate }
        if f.avgFrameRate > 1, f.avgFrameRate <= maxPlausibleFPS { return f.avgFrameRate }
        return fallbackReferenceFPS
    }

    /// Frames per second actually STORED — nb_frames over duration when
    /// the container records it, else the packet sample's rate.
    static func effectiveFPS(_ f: VideoVerifyFacts, sample: VideoPacketSample?) -> Double? {
        if let n = f.frameCount, n > 0, f.videoDurationSeconds > 0 {
            return Double(n) / f.videoDurationSeconds
        }
        if let s = sample, s.packets >= 50, let fps = s.sampledFPS { return fps }
        return nil
    }

    /// Video bits per second: the stream's own figure, else size ÷ time.
    static func bitsPerSecond(_ f: VideoVerifyFacts) -> Int64 {
        if f.videoBitRate > 0 { return f.videoBitRate }
        let d = f.containerDurationSeconds > 0 ? f.containerDurationSeconds : f.videoDurationSeconds
        guard f.fileSizeBytes > 0, d > 0 else { return 0 }
        return Int64(Double(f.fileSizeBytes) * 8 / d)
    }

    /// Wall-clock budget for the full decode: generous (10 min + one
    /// real-time pass), capped at 4 h. Decode normally runs many times
    /// faster than real time; hitting this means "partially checked".
    static func decodeBudgetSeconds(durationSeconds: Double) -> Double {
        let d = max(0, durationSeconds)
        return min(4 * 3_600, max(600, 600 + d))
    }

    // MARK: Checks (each pure, each table-tested)

    /// Picture size present and plausible; aspect ratios sane.
    static func checkDimensions(_ f: VideoVerifyFacts) -> [VideoVerifyFinding] {
        if f.width <= 0 || f.height <= 0 {
            return [.zeroDimensions(width: f.width, height: f.height)]
        }
        var out: [VideoVerifyFinding] = []
        if f.width > 16_384 || f.height > 16_384 {
            out.append(.implausibleDimensions(width: f.width, height: f.height))
        }
        let sar = parseRatio(f.sampleAspectRatio)
        let dar = parseRatio(f.displayAspectRatio)
        let sarOdd = sar.map { $0 < 0.25 || $0 > 4 } ?? false
        let darOdd = dar.map { $0 < 0.4 || $0 > 4 } ?? false
        if sarOdd || darOdd {
            out.append(.oddAspect(sar: f.sampleAspectRatio, dar: f.displayAspectRatio))
        }
        return out
    }

    /// r_frame_rate / avg_frame_rate sanity.
    static func checkFrameRate(_ f: VideoVerifyFacts) -> [VideoVerifyFinding] {
        let r = f.rFrameRate, avg = f.avgFrameRate
        if avg > maxPlausibleFPS {
            return [.frameRateBroken(fps: avg)]
        }
        if r > maxPlausibleFPS {
            // Header absurd. With a sane average it is odd timing (often
            // harmless VFR); with no average at all we can't tell more.
            if avg > 0 { return [.frameRateHeaderOdd(declared: r, actual: avg)] }
            return [.frameRateBroken(fps: r)]
        }
        if r <= 0 && avg <= 0 { return [.frameRateUnknown] }
        return []
    }

    /// Duplicate-frame bloat: far more frames stored than the running
    /// time can hold at any real frame rate.
    static func checkDuplicateBloat(_ f: VideoVerifyFacts,
                                    sample: VideoPacketSample?) -> [VideoVerifyFinding] {
        guard let eff = effectiveFPS(f, sample: sample), eff > maxPlausibleFPS else { return [] }
        let factor = eff / referenceFPS(f)
        guard factor >= bloatMinFactor else { return [] }
        let seconds = f.videoDurationSeconds > 0 ? f.videoDurationSeconds : f.containerDurationSeconds
        let frames = f.frameCount ?? Int((eff * seconds).rounded())
        let mostlyEmpty = (sample?.tinyPacketFraction ?? 0) >= 0.8
        return [.duplicateFrameBloat(factor: factor, frames: frames, seconds: seconds,
                                     sizeBytes: f.fileSizeBytes,
                                     mostlyEmptyPackets: mostlyEmpty)]
    }

    /// Bits per pixel for the codec family. Measured at the REFERENCE
    /// frame rate, so a bloated file's excess is charged to the file.
    static func checkBitrate(_ f: VideoVerifyFacts) -> [VideoVerifyFinding] {
        guard let bands = codecFamily(f.videoCodec).bppBands,
              f.width > 0, f.height > 0 else { return [] }
        let bps = bitsPerSecond(f)
        guard bps > 0 else { return [] }
        let pixelsPerSecond = Double(f.width) * Double(f.height) * referenceFPS(f)
        let bpp = Double(bps) / pixelsPerSecond
        guard bpp > bands.warn else { return [] }
        let ratio = bpp / bands.typical
        return [.bitrateImplausible(ratio: ratio, bitsPerSecond: bps, severe: bpp > bands.broken)]
    }

    /// DTS order and PTS gaps from the packet sample.
    static func checkTimestamps(_ s: VideoPacketSample?) -> [VideoVerifyFinding] {
        guard let s, s.packets >= 2 else { return [] }
        var out: [VideoVerifyFinding] = []
        if s.dtsBackwardSteps > 0 {
            out.append(.timestampsOutOfOrder(count: s.dtsBackwardSteps, sampled: s.packets))
        }
        if s.largestGapSeconds > gapMinSeconds,
           s.largestGapSeconds > s.medianDeltaSeconds * gapMinMedianMultiple {
            out.append(.timestampGap(seconds: s.largestGapSeconds))
        }
        return out
    }

    /// Stream vs container, video vs audio — > 1 s either way.
    static func checkDurations(_ f: VideoVerifyFacts) -> [VideoVerifyFinding] {
        var out: [VideoVerifyFinding] = []
        let v = f.videoDurationSeconds, c = f.containerDurationSeconds, a = f.audioDurationSeconds
        if v > 0, c > 0, abs(v - c) > durationToleranceSeconds {
            out.append(.streamVsContainerDuration(stream: v, container: c))
        }
        if v > 0, a > 0, abs(v - a) > durationToleranceSeconds {
            out.append(.videoVsAudioDuration(video: v, audio: a))
        }
        return out
    }

    /// The full decode's outcome.
    static func checkDecode(_ d: VideoDecodeFacts?, totalSeconds: Double) -> [VideoVerifyFinding] {
        guard let d else { return [] }
        var out: [VideoVerifyFinding] = []
        var checkedSeconds = totalSeconds
        switch d.coverage {
        case .complete:
            break
        case .partial(let checked):
            checkedSeconds = checked
            out.append(.partiallyChecked(checkedSeconds: checked, totalSeconds: totalSeconds))
        case .skipped(let reason):
            return [.decodeSkipped(reason: reason)]
        }
        if d.failedToFinish {
            out.insert(.decodeStopped(atSeconds: d.stoppedAtSeconds), at: 0)
        }
        if d.errorCount > 0 {
            let minutes = max(checkedSeconds, 1) / 60
            let perMinute = Double(d.errorCount) / minutes
            let severe = d.errorCount >= severeDecodeErrorCount
                || (d.errorCount >= 10 && perMinute >= severeDecodeErrorsPerMinute)
            out.insert(.decodeErrors(count: d.errorCount, severe: severe), at: 0)
        }
        return out
    }

    /// Everything the header facts + sample say, BEFORE the decode. The
    /// probe uses this to decide whether a full decode is worth running.
    static func preDecodeFindings(facts f: VideoVerifyFacts,
                                  sample: VideoPacketSample?) -> [VideoVerifyFinding] {
        let dims = checkDimensions(f)
        if dims.contains(where: { if case .zeroDimensions = $0 { return true }; return false }) {
            return dims
        }
        let bloat = checkDuplicateBloat(f, sample: sample)
        var out = bloat
        out += checkFrameRate(f)
        // A bloated file's bitrate is explained by the bloat finding (its
        // size clause) — a second "N× too big" line would say it twice.
        if bloat.isEmpty { out += checkBitrate(f) }
        out += checkTimestamps(sample)
        out += checkDurations(f)
        out += dims
        return out
    }

    /// The whole findings list (ordered most-severe first, stable).
    static func findings(facts: VideoVerifyFacts,
                         sample: VideoPacketSample?,
                         decode: VideoDecodeFacts?) -> [VideoVerifyFinding] {
        let all = preDecodeFindings(facts: facts, sample: sample)
            + checkDecode(decode, totalSeconds: facts.videoDurationSeconds)
        return ordered(all)
    }

    static func ordered(_ findings: [VideoVerifyFinding]) -> [VideoVerifyFinding] {
        findings.enumerated().sorted { a, b in
            let (sa, sb) = (severity(a.element), severity(b.element))
            return sa == sb ? a.offset < b.offset : sa > sb
        }.map(\.element)
    }

    /// True when the pre-decode facts already prove the file broken in a
    /// way a full decode can't change (bloat / no picture). Skipping the
    /// decode then saves reading, e.g., 46 GB off a spinning disk.
    static func decodeIsPointless(_ pre: [VideoVerifyFinding]) -> Bool {
        pre.contains {
            switch $0 {
            case .duplicateFrameBloat, .zeroDimensions, .unopenable: return true
            default: return false
            }
        }
    }

    // MARK: Severity / verdict

    static func severity(_ finding: VideoVerifyFinding) -> VideoVerifySeverity {
        switch finding {
        case .unopenable, .zeroDimensions, .duplicateFrameBloat, .decodeStopped:
            return .broken
        case .frameRateBroken(let fps):
            return fps > brokenFPS ? .broken : .warning
        case .bitrateImplausible(_, _, let severe), .decodeErrors(_, let severe):
            return severe ? .broken : .warning
        case .implausibleDimensions, .oddAspect, .frameRateHeaderOdd, .frameRateUnknown,
             .timestampsOutOfOrder, .timestampGap, .streamVsContainerDuration,
             .videoVsAudioDuration:
            return .warning
        case .partiallyChecked, .decodeSkipped:
            return .info
        }
    }

    static func verdict(for findings: [VideoVerifyFinding]) -> VideoVerifyVerdict {
        switch findings.map(severity).max() ?? .info {
        case .broken: return .broken
        case .warning: return .warning
        case .info: return .ok
        }
    }

    // MARK: Words

    /// Every Broken note leads with this, so ONE query (`notes:broken`)
    /// batch-finds every broken picture (the Verify Audio
    /// "Damaged audio — " convention).
    static let brokenNotePrefix = "Broken video — "
    /// Warnings get their own findable prefix (`notes:"video warning"`).
    static let warningNotePrefix = "Video warning — "

    static func noteFragment(for finding: VideoVerifyFinding) -> String {
        switch finding {
        case .unopenable(let detail):
            return "can't be opened (\(detail))"
        case .zeroDimensions(let w, let h):
            return "picture has no size (\(w)×\(h))"
        case .implausibleDimensions(let w, let h):
            return "implausible picture size (\(w)×\(h))"
        case .oddAspect(let sar, let dar):
            return "odd aspect ratio (pixel \(sar.isEmpty ? "?" : sar), display \(dar.isEmpty ? "?" : dar))"
        case .frameRateBroken(let fps):
            return "timestamps/frame rate broken (\(fpsText(fps)) fps)"
        case .frameRateHeaderOdd(let declared, let actual):
            return "frame-rate header odd (\(fpsText(declared)) fps declared, \(fpsText(actual)) actual)"
        case .frameRateUnknown:
            return "frame rate unknown"
        case .duplicateFrameBloat(let factor, _, let seconds, let size, _):
            let sizeClause = size > 0 && seconds > 0
                ? "; \(sizeText(size)) for \(durationText(seconds))" : ""
            return "each frame stored ~\(factorText(factor))× — broken encode\(sizeClause)"
        case .bitrateImplausible(let ratio, let bps, _):
            return "size is ~\(factorText(ratio))× what this video should need (\(bitrateText(bps)))"
        case .timestampsOutOfOrder(let count, let sampled):
            return "timestamps out of order (\(count) in \(sampled) sampled frames)"
        case .timestampGap(let seconds):
            return "gap of \(durationText(seconds)) in the timestamps"
        case .streamVsContainerDuration(let stream, let container):
            return "picture runs \(durationText(stream)) but the file says \(durationText(container))"
        case .videoVsAudioDuration(let video, let audio):
            return "picture \(durationText(video)) vs sound \(durationText(audio))"
        case .decodeErrors(let count, let severe):
            return "\(groupedInt(count)) decode error\(count == 1 ? "" : "s") (\(severe ? "picture damage" : "minor glitches"))"
        case .decodeStopped(let at):
            return "decoding stopped with an error at \(timecode(at))"
        case .partiallyChecked(let checked, let total):
            return total > 0
                ? "partially checked (decoded \(durationText(checked)) of \(durationText(total)))"
                : "partially checked (decoded \(durationText(checked)))"
        case .decodeSkipped(let reason):
            return "full decode skipped (\(reason))"
        }
    }

    /// Persisted `videoVerifyNote`: prefix by verdict, then the fragments
    /// (already severity-ordered) joined "; ". "" for a clean OK.
    static func note(for findings: [VideoVerifyFinding]) -> String {
        let joined = ordered(findings).map(noteFragment(for:)).joined(separator: "; ")
        guard !joined.isEmpty else { return "" }
        switch verdict(for: findings) {
        case .broken: return brokenNotePrefix + joined
        case .warning: return warningNotePrefix + joined
        case .ok: return joined
        }
    }

    /// The MFO row summary line.
    static func summary(for findings: [VideoVerifyFinding]) -> String {
        switch verdict(for: findings) {
        case .ok:
            let info = ordered(findings).map(noteFragment(for:)).joined(separator: "; ")
            return info.isEmpty
                ? "OK — the picture checked out."
                : "OK — nothing wrong found; \(info)."
        case .warning, .broken:
            return note(for: findings)
        }
    }

    /// One plain-words recommendation, keyed off the most serious finding.
    static func recommendation(for findings: [VideoVerifyFinding]) -> String {
        let top = ordered(findings)
        guard let first = top.first, severity(first) > .info else {
            if top.contains(where: { if case .partiallyChecked = $0 { return true }; return false }) {
                return "What was checked is fine. Run Verify Video again when the drive is less busy to check the rest."
            }
            return "Nothing to do — the picture checked out."
        }
        switch first {
        case .duplicateFrameBloat:
            return "Don't archive this copy. Look for a healthy copy of the same video (one of normal size) and keep that; otherwise re-make it from the original source. Once a good copy is confirmed, this one can be set aside."
        case .unopenable, .zeroDimensions:
            return "This file can't be played. If another copy exists, keep that one instead; a truncated copy can sometimes be rescued with a repair tool, but usually the original is needed."
        case .decodeStopped:
            return "The picture breaks off partway. Prefer another copy if one exists; otherwise keep this one — the part before the break may be all there is."
        case .decodeErrors(_, true):
            return "There is picture damage throughout. Prefer another copy if one exists; otherwise keep it — a damaged original may still be the only one."
        case .frameRateBroken(let fps) where fps > brokenFPS:
            return "The timing is broken, so players will stutter or stall. Look for a healthy copy; otherwise re-encode it at its real frame rate from the best source available."
        case .bitrateImplausible(_, _, true):
            return "This file is far bigger than its picture needs — likely a broken encode. Look for a normal-size copy of the same video and prefer that one."
        default:
            return "It plays, but check it by eye once before archiving; if a cleaner copy exists, prefer that one."
        }
    }

    // MARK: Formatting (deterministic — no locale)

    static func groupedInt(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out: [Character] = []
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// ≥ 100 → two significant figures ("2,000"); 10–100 → integer;
    /// below → one decimal.
    static func factorText(_ f: Double) -> String {
        guard f.isFinite else { return "?" }
        if f >= 100 {
            let magnitude = pow(10, floor(log10(f)) - 1)
            return groupedInt(Int((f / magnitude).rounded() * magnitude))
        }
        if f >= 10 { return groupedInt(Int(f.rounded())) }
        return String(format: "%.1f", f)
    }

    static func fpsText(_ fps: Double) -> String {
        guard fps.isFinite else { return "?" }
        if fps >= 1_000 || abs(fps - fps.rounded()) < 0.005 {
            return groupedInt(Int(fps.rounded()))
        }
        return String(format: "%.2f", fps)
    }

    /// Decimal units, like Finder: 45,976,101,977 → "46 GB".
    static func sizeText(_ bytes: Int64) -> String {
        let b = Double(bytes)
        func fmt(_ v: Double, _ unit: String) -> String {
            v >= 10 ? "\(Int(v.rounded())) \(unit)" : String(format: "%.1f %@", v, unit)
        }
        if b >= 1e12 { return fmt(b / 1e12, "TB") }
        if b >= 1e9 { return fmt(b / 1e9, "GB") }
        if b >= 1e6 { return fmt(b / 1e6, "MB") }
        if b >= 1e3 { return fmt(b / 1e3, "KB") }
        return "\(bytes) bytes"
    }

    static func bitrateText(_ bps: Int64) -> String {
        let b = Double(bps)
        if b >= 1e9 { return String(format: "%.1f Gbit/s", b / 1e9) }
        if b >= 1e6 { return String(format: "%.1f Mbit/s", b / 1e6) }
        return String(format: "%.0f kbit/s", b / 1e3)
    }

    /// "71 s" / "12 min" / "1 h 5 min".
    static func durationText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "?" }
        if s < 10 { return String(format: "%.1f s", s) }
        if s < 120 { return "\(Int(s.rounded())) s" }
        if s < 3_600 { return "\(Int((s / 60).rounded())) min" }
        let totalMinutes = Int((s / 60).rounded())
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }

    static func timecode(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%02d:%02d:%02d", t / 3_600, (t % 3_600) / 60, t % 60)
    }

    // MARK: Parsers (pure — canned text in tests)

    private struct ProbedStream: Decodable {
        struct Disposition: Decodable { let attached_pic: Int? }
        let codec_type: String?
        let codec_name: String?
        let width: Int?
        let height: Int?
        let sample_aspect_ratio: String?
        let display_aspect_ratio: String?
        let r_frame_rate: String?
        let avg_frame_rate: String?
        let nb_frames: String?
        let duration: String?
        let bit_rate: String?
        let disposition: Disposition?
    }
    private struct ProbedFormat: Decodable {
        let format_name: String?
        let duration: String?
        let size: String?
        let tags: [String: String]?
    }
    private struct ProbeReport: Decodable {
        let streams: [ProbedStream]?
        let format: ProbedFormat?
    }

    /// ffprobe JSON → facts. Throws only on unreadable JSON.
    static func facts(fromProbeJSON data: Data) throws -> VideoVerifyFacts {
        let report: ProbeReport
        do {
            report = try JSONDecoder().decode(ProbeReport.self, from: data)
        } catch {
            throw VideoVerifyProbeError.probeFailed("ffprobe output was not readable JSON")
        }
        var f = VideoVerifyFacts()
        f.containerFormat = report.format?.format_name ?? ""
        f.containerDurationSeconds = Double(report.format?.duration ?? "") ?? 0
        f.fileSizeBytes = Int64(report.format?.size ?? "") ?? 0
        f.encoder = report.format?.tags?["encoder"] ?? ""
        let streams = report.streams ?? []
        if let v = streams.first(where: {
            $0.codec_type == "video" && ($0.disposition?.attached_pic ?? 0) == 0
        }) {
            f.hasVideo = true
            f.videoCodec = v.codec_name ?? ""
            f.width = v.width ?? 0
            f.height = v.height ?? 0
            f.sampleAspectRatio = v.sample_aspect_ratio ?? ""
            f.displayAspectRatio = v.display_aspect_ratio ?? ""
            f.rFrameRate = parseRate(v.r_frame_rate)
            f.avgFrameRate = parseRate(v.avg_frame_rate)
            f.frameCount = v.nb_frames.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            f.videoDurationSeconds = Double(v.duration ?? "") ?? 0
            f.videoBitRate = Int64(v.bit_rate ?? "") ?? 0
        }
        if let a = streams.first(where: { $0.codec_type == "audio" }) {
            f.audioDurationSeconds = Double(a.duration ?? "") ?? 0
        }
        // Per-stream durations missing (Matroska, some MXF): the picture
        // takes the container's duration — the audio side stays unknown
        // so the mismatch rule can't fire against a guess.
        if f.hasVideo, f.videoDurationSeconds == 0 {
            f.videoDurationSeconds = f.containerDurationSeconds
        }
        return f
    }

    /// One packet line from `ffprobe -of compact=p=0` with
    /// `packet=pts_time,dts_time,size`: "pts_time=0.03|dts_time=0.0|size=13658".
    /// Any field may be "N/A".
    struct PacketRow: Sendable, Equatable {
        var pts: Double?
        var dts: Double?
        var size: Int
    }

    static func packetRows(fromCompact text: String) -> [PacketRow] {
        var rows: [PacketRow] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var pts: Double?, dts: Double?, size: Int?
            for field in line.split(separator: "|") {
                guard let eq = field.firstIndex(of: "=") else { continue }
                let key = field[..<eq], value = String(field[field.index(after: eq)...])
                switch key {
                case "pts_time": pts = Double(value)
                case "dts_time": dts = Double(value)
                case "size": size = Int(value)
                default: break
                }
            }
            if let size { rows.append(PacketRow(pts: pts, dts: dts, size: size)) }
        }
        return rows
    }

    /// Summarize ONE contiguous window of packets.
    static func packetSample(from rows: [PacketRow]) -> VideoPacketSample {
        var s = VideoPacketSample()
        s.packets = rows.count
        guard !rows.isEmpty else { return s }
        var lastDTS: Double?
        for r in rows {
            if let d = r.dts {
                if let last = lastDTS, d < last { s.dtsBackwardSteps += 1 }
                lastDTS = d
            }
        }
        let pts = rows.compactMap(\.pts).sorted()
        if let lo = pts.first, let hi = pts.last { s.ptsSpanSeconds = hi - lo }
        if pts.count >= 2 {
            let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }.sorted()
            s.medianDeltaSeconds = deltas[deltas.count / 2]
            s.largestGapSeconds = deltas.last ?? 0
        }
        let sizes = rows.map(\.size).sorted()
        s.medianPacketBytes = sizes[sizes.count / 2]
        s.tinyPacketFraction = Double(sizes.filter { $0 <= tinyPacketBytes }.count) / Double(sizes.count)
        return s
    }

    /// Combine per-window samples. Counts add; the gap is the worst; the
    /// sampled rate is the LOWEST window's (a Broken claim must hold
    /// everywhere we looked, not just in one stretch).
    static func merge(_ windows: [VideoPacketSample]) -> VideoPacketSample? {
        let usable = windows.filter { $0.packets > 0 }
        guard let first = usable.first else { return nil }
        guard usable.count > 1 else { return first }
        var m = VideoPacketSample()
        m.packets = usable.reduce(0) { $0 + $1.packets }
        m.dtsBackwardSteps = usable.reduce(0) { $0 + $1.dtsBackwardSteps }
        m.largestGapSeconds = usable.map(\.largestGapSeconds).max() ?? 0
        m.medianDeltaSeconds = usable.map(\.medianDeltaSeconds).sorted()[usable.count / 2]
        let weighted = usable.reduce(0.0) { $0 + $1.tinyPacketFraction * Double($1.packets) }
        m.tinyPacketFraction = weighted / Double(m.packets)
        m.medianPacketBytes = usable.map(\.medianPacketBytes).sorted()[usable.count / 2]
        // Keep the slowest window's rate by reusing its span/packets ratio.
        let slowest = usable.min { ($0.sampledFPS ?? .infinity) < ($1.sampledFPS ?? .infinity) } ?? first
        if let fps = slowest.sampledFPS, fps > 0 {
            m.ptsSpanSeconds = Double(m.packets - 1) / fps
        }
        return m
    }

    /// ffmpeg `-progress pipe:1` line → seconds of picture decoded so far
    /// ("out_time_us=71171100" → 71.1711). nil for every other line and
    /// for "N/A".
    static func progressSeconds(fromLine line: String) -> Double? {
        let prefix = "out_time_us="
        guard line.hasPrefix(prefix), let us = Int64(line.dropFirst(prefix.count)), us >= 0 else { return nil }
        return Double(us) / 1_000_000
    }

    /// "[h264 @ 0x75d044700] error while decoding MB 18 11" →
    /// "h264: error while decoding MB 18 11" (addresses change run to run).
    static func cleanErrorLine(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        let tag = line[line.index(after: line.startIndex)..<close]
        let name = tag.components(separatedBy: " @ ").first ?? String(tag)
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return "\(name): \(rest)"
    }

    /// Plain-words reason from ffprobe's stderr when it cannot open a file.
    static func unopenableDetail(fromProbeStderr stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("moov atom not found") {
            return "its index is missing — typically a truncated copy or an interrupted recording"
        }
        if s.contains("invalid data found") {
            return "the contents are not a readable video — damaged or not really a video"
        }
        if s.contains("could not find codec parameters") {
            return "the picture format could not be worked out"
        }
        let first = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? "ffprobe could not read it" : cleanErrorLine(first)
    }

    /// Does ffprobe's failure point at the FILE (a verdict) rather than the
    /// I/O path (no verdict)? Only content complaints count.
    static func stderrBlamesContent(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        if s.contains("input/output error") || s.contains("no such file")
            || s.contains("operation timed out") || s.contains("permission denied") {
            return false
        }
        return s.contains("moov atom not found")
            || s.contains("invalid data found")
            || s.contains("could not find codec parameters")
            || s.contains("end of file")
    }
}
