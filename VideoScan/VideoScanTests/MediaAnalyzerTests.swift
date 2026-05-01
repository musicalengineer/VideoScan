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
