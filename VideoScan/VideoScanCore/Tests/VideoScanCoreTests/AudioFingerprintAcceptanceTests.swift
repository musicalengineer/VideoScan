// AudioFingerprintAcceptanceTests.swift — FROZEN 2026-10-14, before the
// engine existed (Rick: "create similar, same, different files and show
// right out of the gate how well it works").
//
// The matrix below is the contract. The pass bars are NOT loosened to make
// the run green; a bar that fails is reported with its numbers.
//
//   Positive pairs  → the expected verdict, |offset error| ≤ 0.1 s.
//   Negative pairs  → .different, raw score printed.
//   Margin          → min positive matchedLandmarks ÷ max negative ≥ 3.
//   Media matrix    → the exact copy rewrapped as mov/mkv/mxf/avi → .sameRecording.
//   Allowed to fail → the 0.5 % speed change (DV/VHS drift) is expected but
//                     tolerated; it is reported either way.
//
// "query vs master" everywhere: the first name is the query, the second
// the master that gets indexed.

import Foundation
import Testing
@testable import VideoScanCore

/// |offset error| allowed on every positive verdict.
let audioOffsetTolerance = 0.1

struct AudioPositiveCase: Sendable, CustomTestStringConvertible {
    enum Expectation: Sendable {
        /// `offsets`: the true alignments. One entry normally; the 300 ms
        /// inter-channel-delay file contains TWO copies of A (0 and 0.3 s
        /// after the mono downmix), so either alignment is correct.
        case sameRecording(offsets: [Double])
        case containedInMaster(offset: Double)
        case masterContainedInQuery(offset: Double)
        case overlap(offset: Double, seconds: ClosedRange<Double>)
    }
    let query: String
    let master: String
    let expected: Expectation
    var allowedToFail = false
    var testDescription: String { "\(query) vs \(master)" }

    /// nil when the match meets the expectation, else why not.
    func mismatch(_ m: AudioMatch) -> String? {
        func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= audioOffsetTolerance }
        switch (expected, m.verdict) {
        case (.sameRecording(let offsets), .sameRecording):
            return offsets.contains { near($0, m.offsetSeconds) } ? nil
                : "offset \(m.offsetSeconds) not within \(audioOffsetTolerance) of \(offsets)"
        case (.containedInMaster(let o), .containedInMaster(let got)):
            return near(o, got) ? nil : "offset \(got), expected \(o)"
        case (.masterContainedInQuery(let o), .masterContainedInQuery(let got)):
            return near(o, got) ? nil : "offset \(got), expected \(o)"
        case (.overlap(let o, let secs), .overlap(let got, let s)):
            if !near(o, got) { return "offset \(got), expected \(o)" }
            return secs.contains(s) ? nil : "overlap \(s) s, expected \(secs)"
        default:
            return "verdict \(m.verdict), expected \(expected)"
        }
    }

    static let all: [AudioPositiveCase] = [
        .init(query: "A_copy", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_aac96", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_mp3_64", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_44k", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_32k", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_minus6dB", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_plus6dB", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_noise10dB", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_stereo", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_stereo_delay300", master: "A", expected: .sameRecording(offsets: [0, 0.3])),
        .init(query: "A_speed0_5pct", master: "A", expected: .sameRecording(offsets: [0]),
              allowedToFail: true),
        .init(query: "A_sub20_at60_aac", master: "A", expected: .containedInMaster(offset: 60)),
        .init(query: "A_sub5_at100", master: "A", expected: .containedInMaster(offset: 100)),
        .init(query: "A", master: "D", expected: .containedInMaster(offset: 30)),
        .init(query: "D", master: "A", expected: .masterContainedInQuery(offset: 30)),
        .init(query: "A", master: "E", expected: .overlap(offset: 0, seconds: 54...66)),
    ]

    static let mediaMatrix: [AudioPositiveCase] = [
        .init(query: "A_copy_mov", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_copy_mkv", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_copy_mxf", master: "A", expected: .sameRecording(offsets: [0])),
        .init(query: "A_copy_avi", master: "A", expected: .sameRecording(offsets: [0])),
    ]
}

struct AudioNegativeCase: Sendable, CustomTestStringConvertible {
    let query: String
    let master: String
    var testDescription: String { "\(query) vs \(master)" }

    static let all: [AudioNegativeCase] =
        [.init(query: "A", master: "B"), .init(query: "A", master: "C"), .init(query: "B", master: "C"),
         .init(query: "A", master: "silence"), .init(query: "A", master: "tone1k"),
         .init(query: "A_reversed", master: "A")]
        + stride(from: 0, to: 180, by: 20).map { .init(query: "B_sub20_at\($0)", master: "A") }
}

/// Runs one pair through the shared store; nil (with a known issue) when a
/// fixture could not be built on this machine (e.g. an ffmpeg without lame).
func audioMatchPair(_ query: String, _ master: String) async throws -> AudioMatch? {
    let store = AudioFixtureStore.shared
    let fixtures = try await store.fixtures()
    if let why = fixtures.unavailable[query] ?? fixtures.unavailable[master] {
        withKnownIssue("fixture could not be built on this machine") {
            Issue.record("skipped \(query) vs \(master): \(why)")
        }
        return nil
    }
    let q = try await store.fingerprint(query)
    let m = try await store.fingerprint(master)
    return AudioFingerprintIndex(master: m).match(q)
}

func audioMatchLine(_ label: String, _ m: AudioMatch) -> String {
    String(format: "[audio-fp] %@: %@ offset %.3f s matched %d/%d (density %.3f) coverage %.2f span %.1f s",
           label, "\(m.verdict)", m.offsetSeconds, m.matchedLandmarks, m.queryLandmarks, m.density,
           m.coverage, m.spanSeconds)
}

@Suite("AudioFingerprint acceptance",
       .enabled(if: FFmpegLocator.ffmpegIsAvailable(), "ffmpeg not installed — fixtures need it"))
struct AudioFingerprintAcceptanceTests {

    @Test("positive pair", arguments: AudioPositiveCase.all)
    func positive(_ c: AudioPositiveCase) async throws {
        guard let m = try await audioMatchPair(c.query, c.master) else { return }
        print(audioMatchLine(c.testDescription, m))
        if let why = c.mismatch(m) {
            if c.allowedToFail {
                withKnownIssue("expected but allowed to fail (reported, not hidden)") {
                    Issue.record("\(c.testDescription): \(why)")
                }
            } else {
                Issue.record("\(c.testDescription): \(why)")
            }
        }
    }

    @Test("negative pair", arguments: AudioNegativeCase.all)
    func negative(_ c: AudioNegativeCase) async throws {
        guard let m = try await audioMatchPair(c.query, c.master) else { return }
        print(audioMatchLine(c.testDescription, m))
        #expect(m.verdict == .different, "\(c.testDescription): \(m.verdict)")
    }

    @Test("media matrix: exact copy rewrapped", arguments: AudioPositiveCase.mediaMatrix)
    func mediaMatrix(_ c: AudioPositiveCase) async throws {
        guard let m = try await audioMatchPair(c.query, c.master) else { return }
        print(audioMatchLine(c.testDescription, m))
        if let why = c.mismatch(m) { Issue.record("\(c.testDescription): \(why)") }
    }

    /// Margin bar: the weakest positive must beat the strongest negative 3×.
    @Test("margin: min positive ÷ max negative matched landmarks ≥ 3")
    func margin() async throws {
        var minPositive = Int.max, minPositiveName = ""
        var maxNegative = 0, maxNegativeName = ""
        for c in AudioPositiveCase.all + AudioPositiveCase.mediaMatrix where !c.allowedToFail {
            guard let m = try await audioMatchPair(c.query, c.master) else { continue }
            if m.matchedLandmarks < minPositive { minPositive = m.matchedLandmarks; minPositiveName = c.testDescription }
        }
        for c in AudioNegativeCase.all {
            guard let m = try await audioMatchPair(c.query, c.master) else { continue }
            if m.matchedLandmarks > maxNegative { maxNegative = m.matchedLandmarks; maxNegativeName = c.testDescription }
        }
        let margin = Double(minPositive) / Double(max(1, maxNegative))
        print(String(format: "[audio-fp] margin %.1f× — weakest positive %@ = %d, strongest negative %@ = %d",
                     margin, minPositiveName, minPositive, maxNegativeName, maxNegative))
        #expect(margin >= 3, "margin \(margin) (weakest positive \(minPositiveName) \(minPositive), strongest negative \(maxNegativeName) \(maxNegative))")
    }

    @Test("fingerprint is deterministic and round-trips its binary encoding")
    func deterministicAndEncodable() async throws {
        let fixtures = try await AudioFixtureStore.shared.fixtures()
        let pcm = AudioPCM(sampleRate: fixtures.sampleRate, samples: fixtures.a)
        let first = AudioFingerprint.compute(pcm)
        let second = AudioFingerprint.compute(pcm)
        #expect(first == second)
        #expect(first.landmarkCount > 0)
        let data = first.encoded()
        #expect(data.count == first.estimatedBytes)
        #expect(Array(data.prefix(4)) == AudioFingerprint.magic)
        #expect(AudioFingerprint(decoding: data) == first)
        #expect(AudioFingerprint(decoding: data.prefix(10)) == nil)
        print("[audio-fp] A: \(first.landmarkCount) landmarks, \(data.count) bytes for \(first.durationSeconds) s")
    }
}
