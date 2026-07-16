// TrimLogicTests.swift
// LOGIC dimension for Trim Master (feature-test checklist item 1):
// timecode parse/format round-trips (positive AND negative), the codec
// accuracy classification table, output naming + uniquify, free-space
// estimation, plan validation, the pinned ffmpeg argument vector (the
// -ss-before--i decision is a REGRESSION SENSOR here — see
// TrimEngine.swift for the measured study), keyframe-probe parsing,
// frame-rate parsing, and the pure verification verdict.

import Testing
import Foundation
@testable import VideoScan

struct TrimLogicTests {

    // MARK: - Timecode parsing (positive)

    @Test func parsesFullTimecodes() {
        #expect(TrimTimecode.parse("01:02:03") == 3723)
        #expect(TrimTimecode.parse("00:00:00") == 0)
        #expect(TrimTimecode.parse("10:59:59") == 39599)
        #expect(TrimTimecode.parse("01:02:03.500") == 3723.5)
        #expect(TrimTimecode.parse("00:00:05.125") == 5.125)
    }

    @Test func parsesShortForms() {
        #expect(TrimTimecode.parse("02:03") == 123)
        #expect(TrimTimecode.parse("2:03.5") == 123.5)
        #expect(TrimTimecode.parse("45") == 45)
        #expect(TrimTimecode.parse("45.25") == 45.25)
        #expect(TrimTimecode.parse("  01:02:03  ") == 3723, "surrounding whitespace tolerated")
    }

    // MARK: - Timecode parsing (negative)

    @Test func rejectsMalformedTimecodes() {
        #expect(TrimTimecode.parse("") == nil)
        #expect(TrimTimecode.parse("-1") == nil)
        #expect(TrimTimecode.parse("-00:00:01") == nil)
        #expect(TrimTimecode.parse("01:60:00") == nil, "minutes must be < 60")
        #expect(TrimTimecode.parse("00:00:60") == nil, "seconds must be < 60")
        #expect(TrimTimecode.parse("1:2:3:4") == nil, "too many components")
        #expect(TrimTimecode.parse("abc") == nil)
        #expect(TrimTimecode.parse("1.2.3") == nil)
        #expect(TrimTimecode.parse("01:0x:03") == nil)
        #expect(TrimTimecode.parse("1e3") == nil, "scientific notation rejected")
        #expect(TrimTimecode.parse("::") == nil)
        #expect(TrimTimecode.parse("01::03") == nil, "empty component rejected")
    }

    // MARK: - Timecode formatting + round trip

    @Test func formatsTimecodes() {
        #expect(TrimTimecode.format(0) == "00:00:00")
        #expect(TrimTimecode.format(3723) == "01:02:03")
        #expect(TrimTimecode.format(3723.5) == "01:02:03.500")
        #expect(TrimTimecode.format(-5) == "00:00:00", "negative clamps to zero")
        #expect(TrimTimecode.format(59.9996) == "00:01:00",
                "millisecond rounding carries into the seconds field")
    }

    @Test func parseFormatRoundTripsWithinHalfMillisecond() throws {
        for value in [0.0, 0.001, 1.0, 59.999, 60.0, 3599.5, 3723.457, 7200.25, 86399.999] {
            let text = TrimTimecode.format(value)
            let back = try #require(TrimTimecode.parse(text), "\(value) → \(text)")
            #expect(abs(back - value) < 0.0005, "\(value) → \(text) → \(back)")
        }
    }

    // MARK: - Codec classification table

    @Test func classifiesIntraOnlyCodecs() {
        for codec in ["ffv1", "prores", "dvvideo", "mjpeg", "huffyuv",
                      "ffvhuff", "v210", "rawvideo", "png", "utvideo", "dnxhd"] {
            #expect(TrimCodecClassifier.classify(videoCodec: codec) == .intraOnly, "\(codec)")
        }
        // Case/whitespace tolerant — catalog strings aren't normalized.
        #expect(TrimCodecClassifier.classify(videoCodec: "FFV1") == .intraOnly)
        #expect(TrimCodecClassifier.classify(videoCodec: " ProRes ") == .intraOnly)
    }

    @Test func classifiesLongGOPCodecs() {
        for codec in ["h264", "hevc", "mpeg2video", "mpeg4", "vp9", "av1",
                      "wmv3", "svq3", "cinepak"] {
            #expect(TrimCodecClassifier.classify(videoCodec: codec) == .longGOP, "\(codec)")
        }
    }

    @Test func unknownCodecsNeverClaimFrameAccuracy() {
        #expect(TrimCodecClassifier.classify(videoCodec: "") == .unknown)
        #expect(TrimCodecClassifier.classify(videoCodec: "somefuturecodec") == .unknown)
        #expect(!TrimCodecClass.unknown.claimsFrameAccuracy)
        #expect(!TrimCodecClass.longGOP.claimsFrameAccuracy)
        #expect(TrimCodecClass.intraOnly.claimsFrameAccuracy)
    }

    // MARK: - Plan validation (positive AND negative)

    @Test func validatesGoodRanges() throws {
        try TrimPlan.validate(range: TrimRange(inSeconds: 1, outSeconds: 5),
                              sourceDuration: 10)
        // Container rounding tolerance: out == displayed duration passes.
        try TrimPlan.validate(range: TrimRange(inSeconds: 0, outSeconds: 10.3),
                              sourceDuration: 10)
        // Unknown duration: out-bound check skipped, in<out still enforced.
        try TrimPlan.validate(range: TrimRange(inSeconds: 1, outSeconds: 9999),
                              sourceDuration: 0)
    }

    @Test func rejectsInvalidRanges() {
        #expect(throws: TrimPlanError.inNotBeforeOut) {
            try TrimPlan.validate(range: TrimRange(inSeconds: 5, outSeconds: 5),
                                  sourceDuration: 10)
        }
        #expect(throws: TrimPlanError.inNotBeforeOut) {
            try TrimPlan.validate(range: TrimRange(inSeconds: 7, outSeconds: 5),
                                  sourceDuration: 10)
        }
        #expect(throws: TrimPlanError.negativeIn) {
            try TrimPlan.validate(range: TrimRange(inSeconds: -1, outSeconds: 5),
                                  sourceDuration: 10)
        }
        #expect(throws: TrimPlanError.outBeyondDuration(sourceDuration: 10)) {
            try TrimPlan.validate(range: TrimRange(inSeconds: 1, outSeconds: 11),
                                  sourceDuration: 10)
        }
    }

    @Test func planErrorsAreFriendly() {
        // These strings surface directly in the sheet / job row — pin that
        // they exist and don't leak jargon-y raw values.
        #expect(TrimPlanError.inNotBeforeOut.friendlyMessage.contains("start point"))
        #expect(TrimPlanError.outBeyondDuration(sourceDuration: 60).friendlyMessage
            .contains("00:01:00"))
    }

    // MARK: - Free-space estimate

    @Test func estimateScalesWithKeptFraction() {
        let src: Int64 = 100 << 30   // 100 GB
        let half = TrimPlan.estimatedOutputBytes(
            sourceBytes: src, sourceDuration: 7200,
            range: TrimRange(inSeconds: 0, outSeconds: 3600))
        // Half the source × 1.05 + 64 MB margin.
        let expected = Int64(Double(src) * 0.5 * 1.05) + (64 << 20)
        #expect(abs(half - expected) < (1 << 20))
        // Estimate never exceeds full source × 1.05 + margin.
        let full = TrimPlan.estimatedOutputBytes(
            sourceBytes: src, sourceDuration: 7200,
            range: TrimRange(inSeconds: 0, outSeconds: 7200))
        #expect(full <= Int64(Double(src) * 1.05) + (65 << 20))
    }

    @Test func estimateIsConservativeOnMissingMetadata() {
        // Unknown duration → assume the whole source is kept.
        let unknownDur = TrimPlan.estimatedOutputBytes(
            sourceBytes: 1 << 30, sourceDuration: 0,
            range: TrimRange(inSeconds: 0, outSeconds: 10))
        #expect(unknownDur >= (1 << 30))
        // Unknown size → margin only, never zero or negative.
        let unknownSize = TrimPlan.estimatedOutputBytes(
            sourceBytes: 0, sourceDuration: 100,
            range: TrimRange(inSeconds: 0, outSeconds: 10))
        #expect(unknownSize > 0)
    }

    // MARK: - ffmpeg argument vector (REGRESSION SENSOR)

    /// Pins the measured -ss placement decision: input seeking (-ss
    /// BEFORE -i), duration via -t on the post-seek timeline, -map 0,
    /// stream copy, no re-encode flags anywhere. If someone "fixes" this
    /// to output seeking, frame accuracy on intra masters breaks AND the
    /// cut starts dropping wanted content — this test is the tripwire.
    @Test func ffmpegArgsPinTheMeasuredSeekArrangement() throws {
        let args = TrimPlan.ffmpegArgs(input: "/in/tape.mkv",
                                       partialOutput: "/in/tape_trimmed.vs-partial.mkv",
                                       range: TrimRange(inSeconds: 2, outSeconds: 5))
        #expect(args == [
            "-hide_banner", "-nostdin", "-y",
            "-ss", "2.000",
            "-i", "/in/tape.mkv",
            "-t", "3.000",
            "-map", "0",
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "-progress", "pipe:2",
            "/in/tape_trimmed.vs-partial.mkv"
        ])
        // The load-bearing ordering, stated explicitly: -ss precedes -i.
        let ssIndex = try #require(args.firstIndex(of: "-ss"))
        let inputIndex = try #require(args.firstIndex(of: "-i"))
        #expect(ssIndex < inputIndex,
                "-ss must come BEFORE -i (input seeking) — see TrimEngine.swift header")
    }

    // MARK: - Keyframe probe parsing

    @Test func keyframeProbeParsesFlags() {
        #expect(TrimKeyframeProbe.allSampledPacketsAreKeyframes(
            csv: "0.000000,K__\n0.040000,K__\n0.080000,K__") == true)
        #expect(TrimKeyframeProbe.allSampledPacketsAreKeyframes(
            csv: "0.000000,K__\n0.040000,___") == false,
                "one non-keyframe packet downgrades the accuracy claim")
        #expect(TrimKeyframeProbe.allSampledPacketsAreKeyframes(csv: "") == nil,
                "no packets = undecidable, never a claim")
        #expect(TrimKeyframeProbe.allSampledPacketsAreKeyframes(
            csv: "\n  \ngarbage-without-comma\n0.0,K__") == true,
                "malformed lines are skipped, parseable ones counted")
    }

    // MARK: - Frame-rate parsing (±1-frame nudge)

    @Test func parsesFrameRateDisplayStrings() {
        #expect(TrimFrameRate.fps(fromDisplayString: "29.97") == 29.97)
        #expect(TrimFrameRate.fps(fromDisplayString: "25 fps") == 25)
        let ntsc = TrimFrameRate.fps(fromDisplayString: "30000/1001")
        #expect(abs((ntsc ?? 0) - 29.97) < 0.01)
        #expect(TrimFrameRate.fps(fromDisplayString: "") == nil)
        #expect(TrimFrameRate.fps(fromDisplayString: "0") == nil)
        #expect(TrimFrameRate.fps(fromDisplayString: "abc") == nil)
        #expect(TrimFrameRate.fps(fromDisplayString: "30/0") == nil, "zero denominator")
    }

    // MARK: - Output naming

    @Test func trimmedNamePreservesContainerExtension() {
        let url = TrimJob.trimmedOutputURL(forSourcePath: "/Volumes/T/1998/tape7.mkv",
                                           fileExists: { _ in false })
        #expect(url.path == "/Volumes/T/1998/tape7_trimmed.mkv",
                "stream copy keeps the container — the extension must match the source")
        let mxf = TrimJob.trimmedOutputURL(forSourcePath: "/x/A01.mxf",
                                           fileExists: { _ in false })
        #expect(mxf.lastPathComponent == "A01_trimmed.mxf")
    }

    @Test func trimmedNameUniquifiesFinderStyle() {
        var existing: Set<String> = ["/x/tape_trimmed.mkv", "/x/tape_trimmed 2.mkv"]
        let url = TrimJob.trimmedOutputURL(forSourcePath: "/x/tape.mkv",
                                           fileExists: { existing.contains($0) })
        #expect(url.lastPathComponent == "tape_trimmed 3.mkv")
        existing = []
        let first = TrimJob.trimmedOutputURL(forSourcePath: "/x/tape.mkv",
                                             fileExists: { existing.contains($0) })
        #expect(first.lastPathComponent == "tape_trimmed.mkv")
    }

    @Test func trimmedNameHandlesExtensionlessSource() {
        let url = TrimJob.trimmedOutputURL(forSourcePath: "/x/recovered_essence",
                                           fileExists: { _ in false })
        #expect(url.lastPathComponent == "recovered_essence_trimmed")
    }

    // MARK: - Verification verdict (pure)

    @Test func verificationRejectsCodecChange() {
        let src = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 2, durationSeconds: 10)
        let out = TrimJob.StreamProbe(videoCodecName: "h264", streamCount: 2, durationSeconds: 3)
        let verdict = TrimJob.evaluateVerification(source: src, output: out,
                                                   expectedDuration: 3, codecClass: .intraOnly)
        guard case .failed(let reason) = verdict else {
            Issue.record("codec change must fail verification")
            return
        }
        #expect(reason.contains("codec changed"))
    }

    @Test func verificationRejectsDroppedStreams() {
        let src = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 2, durationSeconds: 10)
        let out = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 1, durationSeconds: 3)
        let verdict = TrimJob.evaluateVerification(source: src, output: out,
                                                   expectedDuration: 3, codecClass: .intraOnly)
        guard case .failed(let reason) = verdict else {
            Issue.record("dropped stream must fail verification")
            return
        }
        #expect(reason.contains("stream count"))
    }

    @Test func verificationDurationToleranceIsCodecClassAware() {
        let src = TrimJob.StreamProbe(videoCodecName: "h264", streamCount: 2, durationSeconds: 10)
        // +1.2 s on a long-GOP cut = the honest keyframe snap → passes.
        let gopOut = TrimJob.StreamProbe(videoCodecName: "h264", streamCount: 2, durationSeconds: 4.2)
        if case .failed = TrimJob.evaluateVerification(source: src, output: gopOut,
                                                       expectedDuration: 3, codecClass: .longGOP) {
            Issue.record("keyframe-snap overshoot must pass for long-GOP")
        }
        // The same +1.2 s on an intra cut = a real fault → fails.
        let srcIntra = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 2, durationSeconds: 10)
        let intraOut = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 2, durationSeconds: 4.2)
        guard case .failed(let reason) = TrimJob.evaluateVerification(
            source: srcIntra, output: intraOut,
            expectedDuration: 3, codecClass: .intraOnly) else {
            Issue.record("1.2 s duration error must fail for intra (tolerance 0.75 s)")
            return
        }
        #expect(reason.contains("duration"))
    }

    @Test func verificationSuccessCarriesHonestDetail() {
        let src = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 2, durationSeconds: 10)
        let out = TrimJob.StreamProbe(videoCodecName: "ffv1", streamCount: 2, durationSeconds: 3.01)
        guard case .verified(let detail) = TrimJob.evaluateVerification(
            source: src, output: out, expectedDuration: 3, codecClass: .intraOnly) else {
            Issue.record("faithful trim must verify")
            return
        }
        #expect(detail.contains("ffv1 unchanged"))
        #expect(detail.contains("2 streams"))
    }

    // MARK: - MFO kind wiring

    @Test func trimKindHasBadge() {
        #expect(MediaFileOperationKind.trim.badgeText == "Trim")
    }
}
