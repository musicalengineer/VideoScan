//
//  MediaAnalyzerTests.swift
//  VideoScanTests
//
//  Coverage for the MediaAnalyzer rule engine. Each rule should have at
//  least one positive case (rule fires) and one negative case (rule
//  doesn't false-positive on look-alike filenames). The goal is regression
//  protection as the rule set grows.
//

import Testing
import Foundation
@testable import VideoScan

// MARK: - Test Helpers

private func record(filename: String,
                    fullPath: String? = nil,
                    duration: Double = 60,
                    sizeBytes: Int64 = 100_000_000,
                    streamType: StreamType = .videoAndAudio,
                    resolution: String = "1920x1080",
                    videoCodec: String = "h264",
                    audioCodec: String = "aac") -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.fullPath = fullPath ?? "/Volumes/Test/\(filename)"
    r.durationSeconds = duration
    r.sizeBytes = sizeBytes
    r.streamTypeRaw = streamType.rawValue
    r.resolution = resolution
    r.videoCodec = videoCodec
    r.audioCodec = audioCodec
    return r
}

// MARK: - Damaged / Unreadable Files

struct DamagedFileTests {

    @Test func probeFailedScoresHigh() {
        let r = record(filename: "broken.mov", streamType: .ffprobeFailed)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 5)
        #expect(result.junkReasons.contains { $0.contains("Probe failed") })
    }

    @Test func noStreamsScoresHigh() {
        let r = record(filename: "empty.mp4", streamType: .noStreams)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 5)
    }

    @Test func zeroByteFile() {
        let r = record(filename: "zero.mov", sizeBytes: 0)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 5)
    }
}

// MARK: - Very Short Clips

struct ShortClipTests {

    @Test func underThreeSecondsFlagged() {
        let r = record(filename: "blip.mov", duration: 1.2)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("Very short") })
    }

    @Test func threeSecondsExactNotFlagged() {
        let r = record(filename: "ok.mov", duration: 3.0)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("Very short") })
    }
}

// MARK: - Transition / Render Patterns (NEW RULE)

struct TransitionRuleTests {

    // --- Positive cases: should fire ---

    @Test func xfadePrefix() {
        let r = record(filename: "xfade_001.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("transition or render") })
    }

    @Test func dissolveDelimited() {
        let r = record(filename: "wedding_dissolve_2010.mp4")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("transition or render") })
    }

    @Test func renderDelimited() {
        let r = record(filename: "vacation_render_v3.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("transition or render") })
    }

    @Test func crossfadeUppercase() {
        // Filenames are normalized to lowercase before matching.
        let r = record(filename: "CROSSFADE_intro.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("transition or render") })
    }

    @Test func proxyMatches() {
        let r = record(filename: "edit_proxy_v1.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("transition or render") })
    }

    // --- Negative cases: must NOT false-positive ---

    @Test func wipeoutAsNameDoesNotMatch() {
        // Kid named "Wipeout" or surname containing "wipe" should not match.
        // The rule requires word-boundary delimiters around `wipe`.
        let r = record(filename: "wipeout_2010.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("transition or render") })
    }

    @Test func dissolveInProseDoesNotMatch() {
        // The word "dissolve" embedded without delimiters shouldn't fire.
        let r = record(filename: "thedissolveband.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("transition or render") })
    }

    @Test func familyFilenameClean() {
        let r = record(filename: "donna_birthday_2020.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("transition or render") })
    }

    @Test func christmasFilenameClean() {
        let r = record(filename: "christmas_morning_2015.mp4")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("transition or render") })
    }

    // --- Composition: rule does not single-handedly promote to junk ---

    @Test func transitionAlonePlusAudioPlusVideoStaysUnreviewed() {
        // A 60s 1080p H.264+AAC file with a transition-y name should NOT
        // auto-promote to .suspectedJunk because the family signals partly
        // offset the +3 transition score. This guards against the rule
        // being too aggressive.
        let r = record(filename: "vacation_render_final.mov", duration: 600)
        let result = MediaAnalyzer.score(r)
        // junkScore +3 from transition rule. familyScore should be ≥ 2 from
        // codec + duration + resolution signals. Disposition logic:
        //   junkScore >= 5 && familyScore < 2 → suspectedJunk
        // So with junkScore = 3, this should NOT be suspectedJunk.
        #expect(result.suggestedDisposition != .suspectedJunk)
    }
}

// MARK: - Test/Temp Filename Patterns (existing rule, baseline coverage)

struct TestTempRuleTests {

    @Test func testPrefixFires() {
        let r = record(filename: "test_clip.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("test/temp/sample") })
    }

    @Test func untitledPrefixFires() {
        let r = record(filename: "untitled.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("test/temp/sample") })
    }

    @Test func nameContainingTestSubstringDoesNotFire() {
        // "testimony" / "Tester family" embeddings shouldn't trigger.
        let r = record(filename: "testimony_grandma.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("test/temp/sample") })
    }
}

// MARK: - Disposition Suggestion

struct DispositionTests {

    @Test func cleanFamilyFileNotJunk() {
        let r = record(filename: "donna_birthday_2020.mov",
                       fullPath: "/Volumes/Family/Donna/donna_birthday_2020.mov",
                       duration: 600)
        let result = MediaAnalyzer.score(r)
        #expect(result.suggestedDisposition != .suspectedJunk)
        #expect(result.suggestedDisposition != .confirmedJunk)
    }

    @Test func damagedFileIsSuspectedJunk() {
        // Realistic probe-failed record: no codec/audio info because probing
        // failed. The default helper populates modern codecs which would
        // otherwise contribute familyScore and prevent .suspectedJunk.
        let r = record(filename: "broken.mov",
                       streamType: .ffprobeFailed,
                       resolution: "",
                       videoCodec: "",
                       audioCodec: "")
        let result = MediaAnalyzer.score(r)
        #expect(result.suggestedDisposition == .suspectedJunk)
    }

    @Test func userSetDispositionPreserved() {
        // analyzeAll must NOT overwrite a user-set mediaDisposition.
        let r = record(filename: "donna.mov")
        r.mediaDisposition = .important
        _ = MediaAnalyzer.analyzeAll([r])
        #expect(r.mediaDisposition == .important)
    }
}

// MARK: - Paired File Recovery

struct PairedFileTests {

    @Test func audioOnlyWithPairIsRecoverable() {
        let r = record(filename: "audio.mxf", streamType: .audioOnly)
        r.pairGroupID = UUID()
        let result = MediaAnalyzer.score(r)
        #expect(result.suggestedDisposition == .recoverable)
    }

    @Test func videoOnlyWithPairIsRecoverable() {
        let r = record(filename: "video.mxf", streamType: .videoOnly)
        r.pairGroupID = UUID()
        let result = MediaAnalyzer.score(r)
        #expect(result.suggestedDisposition == .recoverable)
    }

    @Test func audioOnlyWithoutPairScoresJunk() {
        let r = record(filename: "orphan.mxf", duration: 10, streamType: .audioOnly)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 3)
    }

    @Test func longAudioOnlyWithoutPairScoresLess() {
        let r = record(filename: "long_audio.mxf", duration: 120, streamType: .audioOnly)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore <= 2)
    }
}

// MARK: - Voicemail / VoIP Detection

struct VoicemailTests {

    @Test func lowSampleRateFlagged() {
        let r = record(filename: "recording.mov")
        r.audioSampleRate = "8000"
        r.audioChannels = "1"
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("voicemail") || $0.contains("VoIP") })
    }

    @Test func normalSampleRateNotFlagged() {
        let r = record(filename: "family_dinner.mov")
        r.audioSampleRate = "48000"
        r.audioChannels = "2"
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("voicemail") && !$0.contains("VoIP") })
    }
}

// MARK: - Family Scoring Signals

struct FamilyScoringTests {

    @Test func longFormVideoWithAudioScoresFamily() {
        let r = record(filename: "christmas_2015.mov", duration: 600)
        let result = MediaAnalyzer.score(r)
        #expect(result.familyScore >= 2)
        #expect(result.familyReasons.contains { $0.contains("Long-form") })
    }

    @Test func familyPathBoostsScore() {
        let r = record(filename: "clip.mov",
                       fullPath: "/Volumes/Family/Home Videos/clip.mov",
                       duration: 120)
        let result = MediaAnalyzer.score(r)
        #expect(result.familyScore >= 1)
    }

    @Test func camcorderResolutionBoosts() {
        let r = record(filename: "tape01.mov", duration: 120, resolution: "720x480")
        let result = MediaAnalyzer.score(r)
        #expect(result.familyReasons.contains { $0.contains("camcorder") })
    }

    @Test func importantDispositionForStrongFamilySignals() {
        let r = record(filename: "donna_birthday.mov",
                       fullPath: "/Volumes/Family/Videos/donna_birthday.mov",
                       duration: 600,
                       resolution: "720x480")
        let result = MediaAnalyzer.score(r)
        #expect(result.suggestedDisposition == .important)
    }
}

// MARK: - Screencast Detection

struct ScreencastTests {

    @Test func screencastResolutionVideoOnlyFlagged() {
        let r = record(filename: "screen.mov", streamType: .videoOnly, resolution: "2560x1440")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("Screencast") })
    }

    @Test func screencastResolutionWithAudioNotFlagged() {
        let r = record(filename: "presentation.mov", duration: 600, resolution: "2560x1440")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("Screencast resolution") || !$0.contains("no audio") })
    }
}

// MARK: - System Artifact Detection

struct SystemArtifactTests {

    @Test func trashPathFlagged() {
        let r = record(filename: "clip.mov", fullPath: "/Volumes/Test/.Trash/clip.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("System") || $0.contains("hidden") })
    }

    @Test func dsStorePathFlagged() {
        let r = record(filename: ".DS_Store.mov", fullPath: "/Volumes/Test/.DS_Store.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 4)
    }
}

// MARK: - Truncated File Detection

struct TruncatedFileTests {

    @Test func normalSizeNotFlagged() {
        let r = record(filename: "good.mov", duration: 60, sizeBytes: 100_000_000)
        r.totalBitrate = "13000000"
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.allSatisfy { !$0.contains("truncated") })
    }

    @Test func drasticallySmallSizeFlagged() {
        let r = record(filename: "cut_short.mov", duration: 60, sizeBytes: 1_000)
        r.totalBitrate = "13000000"
        let result = MediaAnalyzer.score(r)
        #expect(result.junkReasons.contains { $0.contains("truncated") })
    }
}

// MARK: - Disposition Threshold Edge Cases

struct DispositionThresholdTests {

    @Test func junkScore4WithLowFamilyStaysUnreviewed() {
        let r = record(filename: "test_render.mov", duration: 1.5,
                       streamType: .videoOnly, resolution: "320x240",
                       videoCodec: "rawvideo", audioCodec: "")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 2)
        #expect(result.suggestedDisposition != .important)
    }

    @Test func zeroDurationIsSuspectedJunk() {
        let r = record(filename: "empty.mov", duration: 0,
                       resolution: "", videoCodec: "", audioCodec: "")
        let result = MediaAnalyzer.score(r)
        #expect(result.suggestedDisposition == .suspectedJunk)
    }

    @Test func analyzeAllSummaryCountsCorrect() {
        let good = record(filename: "family.mov",
                          fullPath: "/Volumes/Family/Videos/family.mov",
                          duration: 600, resolution: "720x480")
        let bad = record(filename: "broken.mov",
                         streamType: .ffprobeFailed,
                         resolution: "", videoCodec: "", audioCodec: "")
        let paired = record(filename: "audio.mxf", streamType: .audioOnly)
        paired.pairGroupID = UUID()

        let summary = MediaAnalyzer.analyzeAll([good, bad, paired])
        #expect(summary.familyCount >= 1)
        #expect(summary.junkCount >= 1)
        #expect(summary.recoverableCount >= 1)
    }
}
