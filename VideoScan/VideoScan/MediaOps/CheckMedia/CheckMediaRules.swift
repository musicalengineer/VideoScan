import Foundation

// MARK: - Check Media — pure rules, quick tier (Rick 2026-10-07)
//
// One function per check, each `(inputs) -> MediaCheck`: a verdict, a
// plain-English sentence, the evidence numbers and a suggested fix. No
// I/O — the probe feeds measurements, tests feed canned values.
//
// Thresholds and wording are SHARED with Verify Video: wherever a check
// is the same question Verify Video asks (bitrate bands, duplicate-frame
// bloat, timestamp order/gaps, picture size), it calls VerifyVideoRules
// rather than re-deriving the numbers — one source of truth.
//
// Motivating case (read-only calibration, never modified):
//   CapeCod_June_1997.mp4 — 43,370,703,217 B for 36.65 s at 640×480
//   (≈ 9.5 Gbit/s), r_frame_rate 90000/1, 2,159,585 frames (≈ 60,000 fps
//   stored), packets 1–2 ticks apart at 1/90000, a 240 KB keyframe every
//   12 frames with tiny packets between, mpdecimate keeps 1 of 300.
//   HandBrake 1.9.2. The quick tier must call it a problem in seconds.
//
// Design: docs/design/check_media_and_menu_cleanup_2026_10_07.md

enum CheckMediaRules {

    // MARK: Thresholds (named so the tests pin them)

    /// Frame rates a camera records. Outside this is a Warning; beyond
    /// VerifyVideoRules.brokenFPS it is a Problem.
    static let cameraFPS: ClosedRange<Double> = 1...120
    /// A frame step this short is not a real frame (1 ms = 1,000 fps).
    static let shortestRealStepSeconds = 0.001
    /// Packet-duration spread (p90 ÷ p10) beyond this = variable frame rate.
    static let vfrSpread: Double = 4
    /// Distinct-frame share: Problem below this (when corroborated by an
    /// absurd stored rate), Warning below `distinctWarningRatio`.
    static let distinctProblemRatio = 0.05
    static let distinctWarningRatio = 0.25
    /// Picture vs sound length: Warning beyond 1 s, or beyond 2 % when that
    /// is also more than a quarter second; Problem beyond 10 % AND 5 s.
    static let avToleranceSeconds = 1.0
    static let avToleranceFraction = 0.02
    static let avFloorSeconds = 0.25
    /// Sound-speed tolerance; mislabel ratios match within `rateMatch`.
    static let sampleCountTolerance = 0.02
    static let rateMatch = 0.015
    /// Common sample-rate mix-ups: actual ÷ declared.
    static let mislabelledRates: [(ratio: Double, words: String)] = [
        (48_000.0 / 44_100.0, "48 kHz sound labelled as 44.1 kHz"),
        (44_100.0 / 48_000.0, "44.1 kHz sound labelled as 48 kHz"),
        (48_000.0 / 32_000.0, "48 kHz sound labelled as 32 kHz"),
        (32_000.0 / 48_000.0, "32 kHz sound labelled as 48 kHz"),
    ]

    /// The full tier's filters, riding the one Verify Video decode.
    /// `signalstats` + two `metadata=print`s add each frame's luma range
    /// and pts_time (PictureSignals.swift): 4 short info lines per frame.
    static let signalFilterChain = "idet,blackdetect=d=2:pix_th=0.10,freezedetect=n=-60dB:d=5,"
        + "signalstats,metadata=mode=print:key=lavfi.signalstats.YMIN,"
        + "metadata=mode=print:key=lavfi.signalstats.YMAX"

    // MARK: Small helpers (formatting is VerifyVideoRules', deterministic)

    typealias V = VerifyVideoRules

    static func verdict(_ s: VideoVerifySeverity) -> MediaCheckVerdict {
        switch s {
        case .broken: return .problem
        case .warning: return .warning
        case .info: return .ok
        }
    }

    static func pictureWords(_ f: VideoVerifyFacts) -> String {
        "\(f.width)×\(f.height) \(f.videoCodec)"
    }

    /// Frames per second actually stored (nb_frames ÷ duration, else the
    /// packet sample) — VerifyVideoRules' own definition.
    static func storedFPS(_ i: CheckMediaQuickInputs) -> Double? {
        V.effectiveFPS(i.videoFacts, sample: i.packets?.sample)
    }

    static let noPicture = "this file has no picture"

    // MARK: The quick tier

    static func quickChecks(_ i: CheckMediaQuickInputs) -> [MediaCheck] {
        [checkBitrate(i), checkFrameRate(i), checkTimestamps(i), checkAVDuration(i),
         checkAudioSamples(i), checkAspect(i), checkTruncation(i), checkDistinctFrames(i),
         checkLayout(i)]
    }

    // 1. Size for the picture.
    static func checkBitrate(_ i: CheckMediaQuickInputs) -> MediaCheck {
        let f = i.videoFacts
        guard f.hasVideo else { return .notRun(.bitrate, because: noPicture) }
        let bps = V.bitsPerSecond(f)
        var evidence = [MediaEvidence("Picture", pictureWords(f))]
        if bps > 0 { evidence.append(MediaEvidence("Spends", V.bitrateText(bps))) }
        if f.fileSizeBytes > 0 { evidence.append(MediaEvidence("File size", V.sizeText(f.fileSizeBytes))) }
        let bloat = V.checkDuplicateBloat(f, sample: i.packets?.sample)
        let rate = V.checkBitrate(f)
        if case .bitrateImplausible(let ratio, _, let severe)? = rate.first {
            let because = bloat.isEmpty ? "" : ", because each frame is stored many times over"
            return MediaCheck(
                kind: .bitrate, verdict: (severe || !bloat.isEmpty) ? .problem : .warning,
                sentence: "It spends \(V.bitrateText(bps)) on a \(pictureWords(f)) picture — about \(V.factorText(ratio))× what it should need\(because).",
                evidence: evidence,
                fix: V.recommendation(for: bloat.isEmpty ? rate : bloat))
        }
        if let first = bloat.first {
            return MediaCheck(kind: .bitrate, verdict: .problem,
                              sentence: "The file is far bigger than its picture: \(V.noteFragment(for: first)).",
                              evidence: evidence, fix: V.recommendation(for: bloat))
        }
        if bps == 0 {
            return .notRun(.bitrate, because: "the file's size or length is unknown")
        }
        return MediaCheck(kind: .bitrate, verdict: .ok,
                          sentence: "Its size is sensible for a \(pictureWords(f)) picture.",
                          evidence: evidence)
    }

    // 2. Frame rate: r vs avg, nb_frames ÷ duration, 1–120.
    static func checkFrameRate(_ i: CheckMediaQuickInputs) -> MediaCheck {
        let f = i.videoFacts
        guard f.hasVideo else { return .notRun(.frameRate, because: noPicture) }
        let stored = storedFPS(i) ?? f.avgFrameRate
        var evidence = [MediaEvidence("Declared (r_frame_rate)", "\(V.fpsText(f.rFrameRate)) fps"),
                        MediaEvidence("Average (avg_frame_rate)", "\(V.fpsText(f.avgFrameRate)) fps")]
        if let n = f.frameCount { evidence.append(MediaEvidence("Frames", V.groupedInt(n))) }
        if stored > 0 { evidence.append(MediaEvidence("Stored per second", "\(V.fpsText(stored)) fps")) }
        if stored > V.brokenFPS {
            return MediaCheck(
                kind: .frameRate, verdict: .problem,
                sentence: "About \(V.fpsText(stored)) frames are stored per second — no camera does that; real video runs at 24 to 60.",
                evidence: evidence,
                fix: V.recommendation(for: [.frameRateBroken(fps: stored)]))
        }
        if stored > 0, !cameraFPS.contains(stored) {
            return MediaCheck(kind: .frameRate, verdict: .warning,
                              sentence: "\(V.fpsText(stored)) frames per second is outside what cameras record (1 to 120).",
                              evidence: evidence,
                              fix: "Play it once to see whether it runs at the right speed.")
        }
        return frameRateHeaderCheck(f, stored: stored, evidence: evidence)
    }

    /// The header-vs-average half of the frame-rate check.
    private static func frameRateHeaderCheck(_ f: VideoVerifyFacts, stored: Double,
                                             evidence: [MediaEvidence]) -> MediaCheck {
        let r = f.rFrameRate, avg = f.avgFrameRate
        if stored <= 0 && r <= 0 {
            return MediaCheck(kind: .frameRate, verdict: .warning,
                              sentence: "The file doesn't say how many frames it shows per second.",
                              evidence: evidence)
        }
        if r > 0, avg > 0, r / avg > 1.5 || avg / r > 1.5 {
            return MediaCheck(kind: .frameRate, verdict: .warning,
                              sentence: "The header says \(V.fpsText(r)) fps but the frames average \(V.fpsText(avg)) — variable or mislabelled timing; most players cope.",
                              evidence: evidence,
                              fix: "Usually harmless. If an editor drifts out of sync, re-wrap it at \(V.fpsText(avg)) fps.")
        }
        return MediaCheck(kind: .frameRate, verdict: .ok,
                          sentence: "\(V.fpsText(stored > 0 ? stored : r)) frames per second, as a camera records.",
                          evidence: evidence)
    }

    // 3. Timing, from the packet sample.
    static func checkTimestamps(_ i: CheckMediaQuickInputs) -> MediaCheck {
        guard i.videoFacts.hasVideo else { return .notRun(.timestamps, because: noPicture) }
        guard let scan = i.packets, scan.packets >= 2 else {
            return .notRun(.timestamps, because: "the frame timings could not be sampled")
        }
        let step = scan.medianStepSeconds
        var evidence = [MediaEvidence("Frames sampled", V.groupedInt(scan.packets))]
        if let step { evidence.append(MediaEvidence("Typical step", stepText(step))) }
        if let s = scan.sample, s.dtsBackwardSteps > 0 {
            evidence.append(MediaEvidence("Out of order", V.groupedInt(s.dtsBackwardSteps)))
        }
        if let step, step < shortestRealStepSeconds {
            return MediaCheck(
                kind: .timestamps, verdict: .problem,
                sentence: "Frames are stamped \(stepText(step)) apart — far shorter than any real frame, so players stall or rush.",
                evidence: evidence,
                fix: V.recommendation(for: [.frameRateBroken(fps: 1 / step)]))
        }
        let findings = V.checkTimestamps(scan.sample)
        if let first = findings.first {
            return MediaCheck(kind: .timestamps, verdict: verdict(V.severity(first)),
                              sentence: "In the sampled stretches: \(findings.map(V.noteFragment(for:)).joined(separator: "; ")).",
                              evidence: evidence,
                              fix: "Usually still plays. If it stutters or drifts, re-wrap it (copy, no re-encode) to rebuild the timestamps.")
        }
        if let spread = scan.durationSpread, spread > vfrSpread {
            return MediaCheck(kind: .timestamps, verdict: .warning,
                              sentence: "Frame lengths vary a lot (variable frame rate) — normal for phones, can drift in editors.",
                              evidence: evidence + [MediaEvidence("Longest ÷ shortest", String(format: "%.1f×", spread))],
                              fix: "Fine for watching. For editing, transcode to a constant frame rate first.")
        }
        return MediaCheck(kind: .timestamps, verdict: .ok,
                          sentence: "Frames are stamped in order, evenly, with no gaps.",
                          evidence: evidence)
    }

    static func stepText(_ s: Double) -> String {
        if s >= 0.001 { return String(format: "%.1f ms", s * 1_000) }
        return String(format: "%.0f µs", s * 1_000_000)
    }

    // 4. Picture vs sound lengths.
    static func checkAVDuration(_ i: CheckMediaQuickInputs) -> MediaCheck {
        guard let video = i.facts.video, let audio = i.facts.audio else {
            return .notRun(.avDuration, because: "it needs both a picture and a sound track")
        }
        guard let v = video.durationSeconds, let a = audio.durationSeconds, v > 0, a > 0 else {
            return .notRun(.avDuration, because: "the file doesn't record separate picture and sound lengths")
        }
        let diff = abs(v - a), longer = max(v, a)
        let evidence = [MediaEvidence("Picture", V.durationText(v)),
                        MediaEvidence("Sound", V.durationText(a)),
                        MediaEvidence("Difference", String(format: "%.2f s", diff))]
        let which = v > a ? "picture runs" : "sound runs"
        if diff > 5, diff > longer * 0.10 {
            return MediaCheck(kind: .avDuration, verdict: .problem,
                              sentence: "The \(which) \(V.durationText(diff)) longer than the other — they can't line up all the way through.",
                              evidence: evidence,
                              fix: "Look for another copy, or for the matching full-length sound (Find Matching Audio).")
        }
        if diff > avToleranceSeconds || (diff > avToleranceFraction * longer && diff > avFloorSeconds) {
            return MediaCheck(kind: .avDuration, verdict: .warning,
                              sentence: "The \(which) \(String(format: "%.1f", diff)) s longer than the other — check the sound stays in step at the end.",
                              evidence: evidence,
                              fix: "Play the last minute. If the sound drifts, prefer another copy.")
        }
        return MediaCheck(kind: .avDuration, verdict: .ok,
                          sentence: "Picture and sound are the same length.",
                          evidence: evidence)
    }

    // 5. Sound speed: sample count vs length × sample rate.
    static func checkAudioSamples(_ i: CheckMediaQuickInputs) -> MediaCheck {
        guard let audio = i.facts.audio, let rate = audio.sampleRate, rate > 0 else {
            return .notRun(.audioSamples, because: "this file has no sound track")
        }
        guard let count = audio.sampleCount else {
            return .notRun(.audioSamples, because: "the file doesn't record a sample count")
        }
        let reference = i.facts.video?.durationSeconds ?? i.facts.durationSeconds ?? 0
        guard reference > 0 else {
            return .notRun(.audioSamples, because: "the file's length is unknown")
        }
        let expected = reference * Double(rate)
        let ratio = Double(count) / expected
        let evidence = [MediaEvidence("Sample rate", "\(rate) Hz"),
                        MediaEvidence("Samples", V.groupedInt(Int(count))),
                        MediaEvidence("Expected for \(V.durationText(reference))", V.groupedInt(Int(expected.rounded())))]
        if let mix = mislabelledRates.first(where: { abs(ratio / $0.ratio - 1) < rateMatch }) {
            return MediaCheck(kind: .audioSamples, verdict: .problem,
                              sentence: "The sound looks like \(mix.words): it would play at the wrong speed and pitch.",
                              evidence: evidence,
                              fix: "Re-wrap the sound with the right sample rate (no re-encode of the picture); keep this copy until the fixed one sounds right.")
        }
        let driftSeconds = abs(Double(count) / Double(rate) - reference)
        if abs(ratio - 1) > sampleCountTolerance, driftSeconds > avToleranceSeconds {
            return MediaCheck(kind: .audioSamples, verdict: .warning,
                              sentence: "There is \(String(format: "%.1f", driftSeconds)) s more or less sound than picture at \(rate) Hz.",
                              evidence: evidence,
                              fix: "Play the end to check the sound stays in step.")
        }
        return MediaCheck(kind: .audioSamples, verdict: .ok,
                          sentence: "\(rate) Hz sound with the right number of samples — it plays at the right speed.",
                          evidence: evidence)
    }

    // 6. Shape of the picture (SAR/DAR).
    static func checkAspect(_ i: CheckMediaQuickInputs) -> MediaCheck {
        let f = i.videoFacts
        guard f.hasVideo else { return .notRun(.aspect, because: noPicture) }
        let evidence = [MediaEvidence("Stored size", "\(f.width)×\(f.height)"),
                        MediaEvidence("Pixel shape (SAR)", f.sampleAspectRatio.isEmpty ? "—" : f.sampleAspectRatio),
                        MediaEvidence("Shown as (DAR)", f.displayAspectRatio.isEmpty ? "—" : f.displayAspectRatio)]
        let dims = V.checkDimensions(f)
        if let first = dims.first {
            return MediaCheck(kind: .aspect, verdict: verdict(V.severity(first)),
                              sentence: "The picture's shape is odd: \(V.noteFragment(for: first)).",
                              evidence: evidence,
                              fix: "Play it to see whether people look stretched; a re-wrap can fix the shape without re-encoding.")
        }
        if isSquarePixelSD(f) {
            return MediaCheck(kind: .aspect, verdict: .warning,
                              sentence: "Stored as square pixels; tape-era \(f.width)-wide video is normally 4:3 with narrow pixels, so it will look about 12 % too wide.",
                              evidence: evidence,
                              fix: "Re-wrap with a 4:3 display shape (16:9 if it was widescreen) — no re-encode needed.")
        }
        return MediaCheck(kind: .aspect, verdict: .ok,
                          sentence: "\(f.width)×\(f.height), shown as \(f.displayAspectRatio.isEmpty ? "stored" : f.displayAspectRatio).",
                          evidence: evidence)
    }

    /// 720/704-wide NTSC/PAL frame flagged square-pixel (or unflagged).
    static func isSquarePixelSD(_ f: VideoVerifyFacts) -> Bool {
        let sdWidths: Set<Int> = [720, 704], sdHeights: Set<Int> = [480, 486, 576]
        guard sdWidths.contains(f.width), sdHeights.contains(f.height) else { return false }
        return ["1:1", "0:1", ""].contains(f.sampleAspectRatio)
    }

    // 7. Complete file: last packet vs file size; picture vs container.
    static func checkTruncation(_ i: CheckMediaQuickInputs) -> MediaCheck {
        let size = i.facts.sizeBytes ?? i.videoFacts.fileSizeBytes
        var evidence = [MediaEvidence("File size", V.groupedInt(Int(size)) + " bytes")]
        if let end = i.packets?.lastPacketEndByte {
            evidence.append(MediaEvidence("Last sampled frame ends at", V.groupedInt(Int(end)) + " bytes"))
            if size > 0, end > size {
                return MediaCheck(kind: .truncation, verdict: .problem,
                                  sentence: "The file stops before its last frame — it was cut short.",
                                  evidence: evidence,
                                  fix: "Look for a complete copy. If none exists, keep this one — the part that is there may be all there is.")
            }
        }
        let shortfall = V.checkDurations(i.videoFacts).first {
            if case .streamVsContainerDuration = $0 { return true }
            return false
        }
        if let shortfall, case .streamVsContainerDuration(let stream, let container) = shortfall,
           container - stream > max(2, container * 0.05) {
            return MediaCheck(kind: .truncation, verdict: .warning,
                              sentence: "The picture ends \(V.durationText(container - stream)) before the file says it does.",
                              evidence: evidence + [MediaEvidence("Picture", V.durationText(stream)),
                                                    MediaEvidence("File says", V.durationText(container))],
                              fix: "Play the end. If it stops early, look for a complete copy.")
        }
        if i.packets?.lastPacketEndByte == nil {
            return MediaCheck(kind: .truncation, verdict: .ok,
                              sentence: "The file's lengths agree (the end of the file could not be sampled).",
                              evidence: evidence)
        }
        return MediaCheck(kind: .truncation, verdict: .ok,
                          sentence: "The file is whole — its last frame ends inside it.",
                          evidence: evidence)
    }

    // 8. Real frames vs repeats (mpdecimate windows).
    static func checkDistinctFrames(_ i: CheckMediaQuickInputs) -> MediaCheck {
        guard i.videoFacts.hasVideo else { return .notRun(.distinctFrames, because: noPicture) }
        guard let sample = i.distinct, let best = sample.bestRatio else {
            return .notRun(.distinctFrames, because: "the frame windows could not be decoded")
        }
        let evidence = sample.usable.map {
            MediaEvidence("From \(V.timecode($0.offsetSeconds))",
                          "\(V.groupedInt($0.framesKept)) of \(V.groupedInt($0.framesIn)) frames are new pictures")
        }
        let corroborated = (storedFPS(i) ?? 0) > cameraFPS.upperBound
        if best < distinctProblemRatio, corroborated {
            return MediaCheck(kind: .distinctFrames, verdict: .problem,
                              sentence: "Only \(percentText(best)) of the sampled frames are new pictures — the rest repeat the one before.",
                              evidence: evidence,
                              fix: V.recommendation(for: [.duplicateFrameBloat(factor: 1 / max(best, 1e-6), frames: 0,
                                                                               seconds: 0, sizeBytes: 0,
                                                                               mostlyEmptyPackets: true)]))
        }
        if best < distinctWarningRatio {
            return MediaCheck(kind: .distinctFrames, verdict: .warning,
                              sentence: "Most sampled frames repeat the one before — normal for a slideshow or a still title, suspicious otherwise.",
                              evidence: evidence,
                              fix: "Watch a minute of it. If it should be moving, prefer another copy.")
        }
        return MediaCheck(kind: .distinctFrames, verdict: .ok,
                          sentence: "\(percentText(best)) of the sampled frames are real changes of picture.",
                          evidence: evidence)
    }

    static func percentText(_ r: Double) -> String {
        r >= 0.1 ? "\(Int((r * 100).rounded())) %" : String(format: "%.1f %%", r * 100)
    }
}
