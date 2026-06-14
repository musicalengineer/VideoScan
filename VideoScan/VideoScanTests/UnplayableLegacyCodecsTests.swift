import Testing
import Foundation
@testable import VideoScan

// MARK: - Tests for legacy-codec detection + analyze-value heuristic

struct UnplayableLegacyCodecsTests {

    // MARK: hasUnplayableLegacyCodec

    @Test("svq3 video flags unplayable")
    func svq3VideoFlags() {
        #expect(hasUnplayableLegacyCodec(videoCodec: "svq3", audioCodec: "aac"))
    }

    @Test("qdm2 audio flags unplayable")
    func qdm2AudioFlags() {
        #expect(hasUnplayableLegacyCodec(videoCodec: "h264", audioCodec: "qdm2"))
    }

    @Test("cinepak / indeo / rpza all flag")
    func variousLegacyVideoCodecsFlag() {
        for codec in ["cinepak", "indeo3", "indeo4", "indeo5", "rpza"] {
            #expect(hasUnplayableLegacyCodec(videoCodec: codec, audioCodec: "aac"),
                    "\(codec) should flag as unplayable")
        }
    }

    @Test("modern codecs do NOT flag")
    func modernCodecsDoNotFlag() {
        #expect(!hasUnplayableLegacyCodec(videoCodec: "h264", audioCodec: "aac"))
        #expect(!hasUnplayableLegacyCodec(videoCodec: "hevc", audioCodec: "aac"))
        #expect(!hasUnplayableLegacyCodec(videoCodec: "prores", audioCodec: "pcm_s16le"))
        #expect(!hasUnplayableLegacyCodec(videoCodec: "mpeg4", audioCodec: "mp3"))
    }

    @Test("empty codec strings don't false-positive")
    func emptyCodecsAreSafe() {
        #expect(!hasUnplayableLegacyCodec(videoCodec: "", audioCodec: ""))
        #expect(!hasUnplayableLegacyCodec(videoCodec: "  ", audioCodec: "  "))
    }

    @Test("case-insensitive matching")
    func caseInsensitive() {
        #expect(hasUnplayableLegacyCodec(videoCodec: "SVQ3", audioCodec: "aac"))
        #expect(hasUnplayableLegacyCodec(videoCodec: "h264", audioCodec: "QDM2"))
    }

    // MARK: unplayableLegacyReason

    @Test("reason string names the offending codec")
    func reasonStringNamesCodec() {
        let r = unplayableLegacyReason(videoCodec: "svq3", audioCodec: "aac")
        #expect(r != nil)
        #expect(r?.contains("svq3") == true,
                "User-facing reason should call out the actual codec name")
    }

    @Test("reason is nil for fine codecs")
    func reasonNilForFine() {
        #expect(unplayableLegacyReason(videoCodec: "h264", audioCodec: "aac") == nil)
    }

    // MARK: analyzeValueScore

    @Test("long QuickTime mov with audio + legacy codec scores high")
    func longLegacyMovScoresHigh() {
        // Thanksgiving-Raw_Default.mov profile: 93 min, has audio,
        // svq3+qdm2, mov container, pre-2010 source.
        let mtime = Calendar.current.date(from: DateComponents(year: 2002, month: 1, day: 1))
        let score = analyzeValueScore(
            durationSeconds: 93 * 60,
            hasAudio: true,
            hasLegacyCodec: true,
            container: "QuickTime / MOV",
            fileMTime: mtime
        )
        #expect(score >= 90,
                "A 1980s-era family video should score near the top of the heuristic")
    }

    @Test("short modern clip scores low")
    func shortModernClipScoresLow() {
        let mtime = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1))
        let score = analyzeValueScore(
            durationSeconds: 30,
            hasAudio: false,
            hasLegacyCodec: false,
            container: "mp4",
            fileMTime: mtime
        )
        #expect(score == 0,
                "Short modern soundless clip should not be flagged as high-priority")
    }

    @Test("score is clamped to 100")
    func scoreClampedTo100() {
        let mtime = Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1))
        // Engineered to exceed 100 if all signals fired without clamp.
        let score = analyzeValueScore(
            durationSeconds: 99 * 60,
            hasAudio: true,
            hasLegacyCodec: true,
            container: "QuickTime / MOV",
            fileMTime: mtime
        )
        #expect(score == 100, "Score must not exceed 100")
    }
}
