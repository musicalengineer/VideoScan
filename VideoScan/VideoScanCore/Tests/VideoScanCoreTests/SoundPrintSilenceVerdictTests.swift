// SoundPrintSilenceVerdictTests.swift — "silent" means decoded and MEASURED
// silent (2026-10-20, Verify Catalog tier 3 fired on 32 rows; 14 were wrong).
//
//   B. 8 AVCHD .MTS clips (AC-3, 0.9–10.5 s, up to −0.1 dB peak) were stamped
//      `.fingerprinted` with 0 landmarks and read as "silent". The engine is
//      right that they make no landmark (a landmark needs two peaks, each the
//      loudest of a ±3-frame × ±15-bin patch; the first/last 3 frames are
//      never centres) — the READING was wrong: zero landmarks is not silence.
//      The engine's own audible-seconds bitmap is the measurement.
//   C. 6 files whose decode gives 0 samples carried version-2 "no sound"
//      stamps (written on decode failures before rule 3) — read as evidence.
//
// Dimensions (CLAUDE.md checklist):
//   Logic — `reading(of:)`, `hearing(headerHasAudio:)`, `describes` for
//           every (version × outcome × landmarks × header) that matters.
//   Media — synthetic ffmpeg fixtures (test_ prefix) through the REAL
//           decoder + engine: a short AC-3 .mts with a tone, an AAC .mov
//           with tones, a DV digital-silence track, a TS whose header names
//           AC-3 but whose sound cannot be decoded.
//   Sensor — "silent" only for decoded, measured silence: a sweep over every
//           stamp shape and every print shape.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Sound print — silence is measured, never inferred")
struct SoundPrintSilenceVerdictTests {

    // MARK: Helpers

    static func print(landmarks: Int, active: [Bool], seconds: Double) -> AudioFingerprint {
        AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: seconds,
                         activeSeconds: active, hashes: Array(repeating: 1, count: landmarks),
                         times: Array(repeating: 0, count: landmarks))
    }

    static func stamp(version: Int, _ outcome: AudioFingerprintStamp.Outcome, landmarks: Int,
                      seconds: Double = 2) -> AudioFingerprintStamp {
        AudioFingerprintStamp(engineVersion: version, contentDigest: "sha256:ab", sizeBytes: 1_000, outcome: outcome,
                              analyzedSeconds: outcome == .noAudio ? 0 : seconds, complete: true,
                              landmarks: outcome == .noAudio ? 0 : landmarks,
                              bytes: outcome == .noAudio ? 0 : 39 + 8 * landmarks + 1)
    }

    // MARK: Logic — reading a fresh print

    @Test("reading: landmarks → printable; no landmark + every second quiet → silence; no landmark + any audible second → heard too little (never silence)")
    func readingOfAFreshPrint() {
        #expect(AudioFingerprintStamp.reading(of: Self.print(landmarks: 3, active: [true, false], seconds: 2)) == .printable)
        #expect(AudioFingerprintStamp.reading(of: Self.print(landmarks: 0, active: [false, false, false], seconds: 3)) == .silence)
        // 00085.MTS on 10/20: 1.504 s, both seconds audible, one peak, 0 landmarks.
        #expect(AudioFingerprintStamp.reading(of: Self.print(landmarks: 0, active: [true, true], seconds: 1.504))
                == .heardTooLittle(audibleSeconds: 2))
        #expect(AudioFingerprintStamp.reading(of: Self.print(landmarks: 0, active: [false, true, false], seconds: 3))
                == .heardTooLittle(audibleSeconds: 1), "one audible second is enough to rule out 'silent'")
    }

    @Test("reading: an empty bitmap is UNKNOWN — the conservative side is 'heard', never 'silent'; so is 0 analysed seconds")
    func emptyBitmapIsNotSilence() {
        #expect(AudioFingerprintStamp.reading(of: Self.print(landmarks: 0, active: [], seconds: 3)) == .heardTooLittle(audibleSeconds: 0))
        #expect(AudioFingerprintStamp.reading(of: Self.print(landmarks: 0, active: [], seconds: 0)) == .heardTooLittle(audibleSeconds: 0))
    }

    @Test("the engine on PCM: a 0.3 s loud tone makes no landmark and is heard too little; 3 s of digital zeros is silence")
    func engineShortToneVersusZeros() {
        let tone = (0..<2_400).map { Int16(12_000 * sin(2 * Double.pi * 1_000 * Double($0) / 8_000)) }
        let toneFP = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: tone))
        #expect(toneFP.landmarkCount == 0, "fewer than 7 frames: no centre frame, no peak")
        #expect(toneFP.activeSecondCount == 1)
        #expect(AudioFingerprintStamp.reading(of: toneFP) == .heardTooLittle(audibleSeconds: 1))

        let zeros = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: [Int16](repeating: 0, count: 24_000)))
        #expect(zeros.landmarkCount == 0 && zeros.activeSeconds == [false, false, false])
        #expect(AudioFingerprintStamp.reading(of: zeros) == .silence)
    }

    // MARK: Logic — reading a stamp

    @Test("hearing: a zero-landmark print is measured silence ONLY from stamp rule 4; before 4 it is not evidence")
    func hearingZeroLandmarks() {
        #expect(Self.stamp(version: 4, .fingerprinted, landmarks: 0).hearing(headerHasAudio: true) == .measuredSilence)
        #expect(Self.stamp(version: 3, .fingerprinted, landmarks: 0).hearing(headerHasAudio: true) == .notEvidence)
        #expect(Self.stamp(version: 2, .fingerprinted, landmarks: 0).hearing(headerHasAudio: true) == .notEvidence,
                "the 8 AVCHD clips' stamps (v2, 0 landmarks, real sound)")
        let zeroSeconds = AudioFingerprintStamp(engineVersion: 4, contentDigest: "sha256:ab", sizeBytes: 1, outcome: .fingerprinted,
                                                analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 39)
        #expect(zeroSeconds.hearing(headerHasAudio: true) == .notEvidence, "nothing analysed is no measurement")
        for v in 2...4 {
            #expect(Self.stamp(version: v, .fingerprinted, landmarks: 12).hearing(headerHasAudio: true) == .heardSound)
        }
    }

    @Test("hearing: a version-2 'no sound' stamp on an audio header is not evidence (decode failures, 0 samples); with no audio codec it is a real no-sound track")
    func hearingNoAudio() {
        #expect(Self.stamp(version: 2, .noAudio, landmarks: 0).hearing(headerHasAudio: true) == .notEvidence,
                "the 6 'could not decode the sound (0 samples)' rows")
        #expect(Self.stamp(version: 2, .noAudio, landmarks: 0).hearing(headerHasAudio: false) == .noAudioTrack)
        #expect(Self.stamp(version: 3, .noAudio, landmarks: 0).hearing(headerHasAudio: false) == .noAudioTrack)
        #expect(Self.stamp(version: 4, .noAudio, landmarks: 0).hearing(headerHasAudio: false) == .noAudioTrack)
    }

    @Test("describes (the re-print rule): every pre-4 zero-landmark print and every v2 decode-failure 'no sound' is redone; prints with landmarks and agreed 'no sound' stand")
    func describesRedoesWhatIsNotEvidence() {
        func d(_ s: AudioFingerprintStamp, header: Bool = true) -> Bool {
            s.describes(sizeBytes: 1_000, digests: ["sha256:ab"], headerHasAudio: header)
        }
        #expect(!d(Self.stamp(version: 2, .fingerprinted, landmarks: 0)), "B: re-printed")
        #expect(!d(Self.stamp(version: 3, .fingerprinted, landmarks: 0)), "B (v3): re-printed")
        #expect(!d(Self.stamp(version: 2, .noAudio, landmarks: 0)), "C: retried")
        #expect(d(Self.stamp(version: 2, .noAudio, landmarks: 0), header: false))
        #expect(d(Self.stamp(version: 3, .noAudio, landmarks: 0), header: false))
        #expect(d(Self.stamp(version: 2, .fingerprinted, landmarks: 9)))
        #expect(d(Self.stamp(version: 3, .fingerprinted, landmarks: 9)))
        #expect(d(Self.stamp(version: 4, .fingerprinted, landmarks: 0)), "a rule-4 silence stands")
        #expect(!d(Self.stamp(version: 1, .fingerprinted, landmarks: 9)), "version 1 never stands")
        #expect(AudioFingerprintStamp.currentEngineVersion == 4 && AudioFingerprintStamp.silenceMeasuredVersion == 4)
    }

    // MARK: Sensor — "silent" only for decoded, measured silence

    @Test("SENSOR: across every stamp shape, measuredSilence ⇔ (fingerprinted, rule ≥ 4, 0 landmarks, analysed > 0); across every print shape, .silence ⇔ (0 landmarks, a bitmap, no audible second)")
    func silentOnlyForMeasuredSilence() {
        var silentStamps = 0
        for version in 1...5 {
            for outcome in [AudioFingerprintStamp.Outcome.fingerprinted, .noAudio] {
                for landmarks in [0, 1, 50] {
                    for seconds in [0.0, 0.3, 1.5, 600] {
                        for header in [true, false] {
                            let s = AudioFingerprintStamp(engineVersion: version, contentDigest: "sha256:ab", sizeBytes: 1,
                                                          outcome: outcome, analyzedSeconds: outcome == .noAudio ? 0 : seconds,
                                                          complete: true, landmarks: outcome == .noAudio ? 0 : landmarks, bytes: 0)
                            let silent = s.hearing(headerHasAudio: header) == .measuredSilence
                            let expected = outcome == .fingerprinted && version >= 4 && landmarks == 0 && seconds > 0
                            #expect(silent == expected, "v\(version) \(outcome) lm=\(landmarks) s=\(seconds) header=\(header)")
                            if silent { silentStamps += 1 }
                        }
                    }
                }
            }
        }
        #expect(silentStamps > 0, "the sweep reached the silent shape")
        for landmarks in [0, 1] {
            for active in [[], [false], [false, false], [true], [false, true], [true, true]] as [[Bool]] {
                let r = AudioFingerprintStamp.reading(of: Self.print(landmarks: landmarks, active: active, seconds: Double(max(1, active.count))))
                #expect((r == .silence) == (landmarks == 0 && !active.isEmpty && !active.contains(true)),
                        "lm=\(landmarks) active=\(active) → \(r)")
            }
        }
    }

    // MARK: Media matrix — real ffmpeg fixtures through the real decoder

    @Test("MEDIA: short AC-3 .mts with a tone → heard too little (not silent); AAC .mov with tones → printable; DV digital silence → silence; a TS whose header names AC-3 but holds no sound → a decode failure, never PCM")
    func mediaMatrix() async throws {
        let fx = try await SilenceFixtures.build()
        defer { try? FileManager.default.removeItem(at: fx.directory) }
        let decoder = AudioPCMDecoder()

        let shortPCM = try await decoder.decode(path: try fx.url("short_tone_ac3").path)
        #expect(!shortPCM.samples.isEmpty && shortPCM.durationSeconds < 0.5, "decoded \(shortPCM.samples.count) samples")
        let short = AudioFingerprint.compute(shortPCM)
        #expect(short.landmarkCount == 0)
        #expect(AudioFingerprintStamp.reading(of: short) == .heardTooLittle(audibleSeconds: 1),
                "a 0.3 s tone in AC-3/MPEG-TS was heard — it must never read as silent")

        let aac = AudioFingerprint.compute(try await decoder.decode(path: try fx.url("tone_aac_mov").path))
        #expect(aac.landmarkCount > 0, "AAC .mov with stepped tones prints")
        #expect(AudioFingerprintStamp.reading(of: aac) == .printable)

        let silencePCM = try await decoder.decode(path: try fx.url("digital_silence_dv").path)
        #expect(silencePCM.samples.count > 8_000, "the DV silence track decoded (\(silencePCM.samples.count) samples)")
        let silence = AudioFingerprint.compute(silencePCM)
        #expect(AudioFingerprintStamp.reading(of: silence) == .silence, "decoded digital zeros are measured silence")

        let undecodable = try fx.url("undecodable_sound_mts")
        await #expect(throws: AudioPCMDecoder.Failure.self) {
            _ = try await decoder.decode(path: undecodable.path)
        }
    }
}

/// The four synthetic files, built in a scratch folder (test_ prefix).
struct SilenceFixtures {
    let directory: URL
    let files: [String: URL]

    func url(_ name: String) throws -> URL {
        guard let url = files[name] else { throw AudioFixtures.FixtureUnavailable(name: name, reason: "not built") }
        return url
    }

    static func build() async throws -> SilenceFixtures {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_silence_matrix_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let picture = ["-f", "lavfi", "-i", "testsrc=size=64x64:rate=25"]
        let h264 = ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        let specs: [(name: String, file: String, args: [String])] = [
            ("short_tone_ac3", "test_short_tone_ac3.mts",
             picture + ["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000", "-t", "0.3",
                        "-map", "0:v", "-map", "1:a"] + h264 + ["-c:a", "ac3", "-ac", "2", "-f", "mpegts"]),
            ("tone_aac_mov", "test_tone_aac.mov",
             picture + ["-f", "lavfi", "-i",
                        "aevalsrc=0.4*sin(2*PI*(400+300*floor(4*t))*t)+0.2*sin(2*PI*(1500-200*floor(3*t))*t):s=48000",
                        "-t", "4", "-map", "0:v", "-map", "1:a"] + h264 + ["-c:a", "aac", "-ac", "1"]),
            ("digital_silence_dv", "test_digital_silence.dv",
             ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
              "-t", "3", "-map", "0:v", "-map", "1:a", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le", "-f", "dv"]),
            ("tone_ac3_ts_source", "test_tone_ac3_source.mts",
             picture + ["-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*(400+300*floor(4*t))*t):s=48000", "-t", "2",
                        "-map", "0:v", "-map", "1:a"] + h264 + ["-c:a", "ac3", "-ac", "2", "-f", "mpegts"]),
        ]
        var files: [String: URL] = [:]
        for spec in specs {
            let out = dir.appendingPathComponent(spec.file)
            let result = await ProcessRunner.runProcess(executable: FFmpegLocator.ffmpegPath,
                                                        arguments: ["-nostdin", "-v", "error", "-y"] + spec.args + [out.path],
                                                        deadlineSeconds: 120)
            guard result.exitCode == 0 else {
                throw AudioFixtures.FixtureUnavailable(name: spec.name, reason: "ffmpeg exit \(result.exitCode): \(result.stderr.suffix(300))")
            }
            files[spec.name] = out
        }
        // Group C's shape: the PMT still names an AC-3 stream (ffprobe reports
        // it), but every audio packet (ffmpeg's default audio PID 0x101) is
        // gone, so a decode finds no sound.
        let source = try Data(contentsOf: try #require(files["tone_ac3_ts_source"]))
        var stripped = Data(capacity: source.count)
        var offset = 0
        while offset + 188 <= source.count {
            let pid = (Int(source[offset + 1] & 0x1F) << 8) | Int(source[offset + 2])
            if pid != 0x101 { stripped.append(source[offset..<(offset + 188)]) }
            offset += 188
        }
        #expect(stripped.count < source.count, "the audio packets were found and removed")
        let undecodable = dir.appendingPathComponent("test_undecodable_sound.mts")
        try stripped.write(to: undecodable)
        files["undecodable_sound_mts"] = undecodable
        return SilenceFixtures(directory: dir, files: files)
    }
}
