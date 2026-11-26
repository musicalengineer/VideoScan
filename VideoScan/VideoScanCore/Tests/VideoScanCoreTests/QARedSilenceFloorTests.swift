import Foundation
import Testing
@testable import VideoScanCore

@Suite("QA red — silence floor is absolute, not gain-relative")
struct QARedSilenceFloorTests {
    /// 3 s of 1-LSB TPDF-style dither (~ -92 dBFS RMS): inaudible, what a
    /// DAW export or a camera's muted track holds instead of digital zeros.
    /// AudioFingerprintStamp.swift:131-138 (reading) + AudioFingerprint.swift:401
    /// (floorRMS divided by the normalising gain, up to x100 = +40 dB).
    @Test("RED: an inaudible dither track (-92 dBFS) reads as silence, never 'heard sound'")
    func ditherIsSilence() {
        var rng = SystemRandomNumberGenerator()
        let samples = (0..<24_000).map { _ in Int16(Int.random(in: -1...1, using: &rng)) }
        let fp = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: samples))
        let r = AudioFingerprintStamp.reading(of: fp)
        #expect(r == .silence, "landmarks=\(fp.landmarkCount) active=\(fp.activeSeconds) reading=\(r)")
    }

    @Test("RED: a -80 dBFS hiss floor (well below audible on any playback) reads as silence")
    func lowHissIsSilence() {
        var rng = SystemRandomNumberGenerator()
        let samples = (0..<24_000).map { _ in Int16(Int.random(in: -6...6, using: &rng)) }
        let fp = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: samples))
        let r = AudioFingerprintStamp.reading(of: fp)
        #expect(r == .silence, "landmarks=\(fp.landmarkCount) active=\(fp.activeSeconds) reading=\(r)")
    }

    // MARK: GH #345 — a −68 dBFS floor lifted ×100 into landmarks is not sound

    /// 10 s at 8 kHz of a tonal floor peaking at 12 of 32,768 ≈ −68 dBFS —
    /// the level of the three CapeCodAndMuseum1991 files (#345): a tone
    /// wandering ±30 Hz around 440 Hz (tape wow on a faint bleed or hum
    /// line). The ×100 normalising gain lifts it to −28 dBFS, where it
    /// makes ~50 landmarks; plain dither and white hiss (above) make none.
    static func tonalFloor(peak: Double) -> [Int16] {
        (0..<80_000).map { i in
            let t = Double(i) / 8_000
            return Int16((peak * sin(2 * Double.pi * (440 * t + 30 * sin(2 * Double.pi * 0.7 * t)))).rounded())
        }
    }

    @Test("#345: a −68 dBFS tonal floor makes no landmark, reads silence, and its stamp says measured silence — never 'heard sound'")
    func tonalFloorIsSilence() throws {
        let samples = Self.tonalFloor(peak: 12)
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak <= 13, "fixture must peak at or below −68 dBFS (13 of 32,768), got \(peak)")
        let fp = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: samples))
        #expect(fp.secondsAboveSilenceCeiling == 0)
        #expect(fp.landmarkCount == 0, "noise lifted by the normalising gain made \(fp.landmarkCount) landmarks")
        #expect(AudioFingerprintStamp.reading(of: fp) == .silence)
        let stamp = AudioFingerprintStamp.fingerprinted(fp, contentDigest: "sha256:ab", sizeBytes: 1_000)
        #expect(stamp.hearing(headerHasAudio: true) == .measuredSilence, "stamp: \(stamp)")
    }

    @Test("#345 control: the same tone at −20 dBFS is programme — landmarks, printable, heard sound")
    func loudToneIsSound() {
        let fp = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: Self.tonalFloor(peak: 3_000)))
        #expect(fp.landmarkCount > 0)
        #expect(AudioFingerprintStamp.reading(of: fp) == .printable)
        #expect(AudioFingerprintStamp.fingerprinted(fp, contentDigest: "sha256:ab", sizeBytes: 1_000)
                    .hearing(headerHasAudio: true) == .heardSound)
    }

    @Test("#345 rule: a print with landmarks but no second above −60 dBFS at gain 1 reads silence — the absolute level decides before the landmark count")
    func absoluteLevelOutranksLandmarks() {
        let fp = AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 10,
                                  activeSeconds: Array(repeating: true, count: 10), hashes: [1, 2, 3], times: [0, 1, 2],
                                  secondsAboveSilenceCeiling: 0)
        #expect(AudioFingerprintStamp.reading(of: fp) == .silence)
    }

    @Test("#345 MEDIA: a −68 dBFS tonal floor in AAC .mov and PCM .mkv (the CapeCodAndMuseum1991 shapes), through the real decoder — no landmark, measured silence",
          .timeLimit(.minutes(2)))
    func tonalFloorThroughTheDecoder() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: FFmpegLocator.ffmpegPath), "ffmpeg is needed")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_tonal_floor_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 0.00033 FS ≈ −69.6 dBFS peak: the same wandering tone as `tonalFloor`.
        let tone = "aevalsrc=0.00033*sin(2*PI*(440*t+30*sin(2*PI*0.7*t))):s=48000"
        let picture = ["-f", "lavfi", "-i", "testsrc=size=64x64:rate=25", "-f", "lavfi", "-i", tone, "-t", "6",
                       "-map", "0:v", "-map", "1:a", "-c:v", "mpeg4"]
        for (file, audio) in [("test_tonal_floor_aac.mov", ["-c:a", "aac"]), ("test_tonal_floor_pcm.mkv", ["-c:a", "pcm_s16le"])] {
            let out = dir.appendingPathComponent(file)
            let made = await ProcessRunner.runProcess(executable: FFmpegLocator.ffmpegPath,
                                                      arguments: ["-nostdin", "-v", "error", "-y"] + picture + audio + [out.path],
                                                      deadlineSeconds: 120)
            try #require(made.exitCode == 0, "\(file): ffmpeg exit \(made.exitCode) \(made.stderr.suffix(300))")
            let pcm = try await AudioPCMDecoder().decode(path: out.path)
            #expect(pcm.durationSeconds > 5, "\(file): decoded \(pcm.durationSeconds) s")
            let fp = AudioFingerprint.compute(pcm)
            #expect(fp.landmarkCount == 0, "\(file): \(fp.landmarkCount) landmarks from a −68 dBFS floor")
            #expect(AudioFingerprintStamp.reading(of: fp) == .silence, "\(file): \(AudioFingerprintStamp.reading(of: fp))")
        }
    }

    @Test("#345 Codex round 2: anti-phase stereo (left a −21 dBFS wandering tone, right its near-inverse) has a −68 dBFS mono mix — the source channels are loud, so the print keeps its landmarks and its stamp says heard sound",
          .timeLimit(.minutes(2)))
    func antiPhaseStereoIsSound() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: FFmpegLocator.ffmpegPath), "ffmpeg is needed")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_antiphase_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Codex's shape: L = 3000/32768 · tone, R = −2976/32768 · tone.
        let tone = "sin(2*PI*(440*t+30*sin(2*PI*0.7*t)))"
        let out = dir.appendingPathComponent("test_antiphase.mkv")
        let made = await ProcessRunner.runProcess(
            executable: FFmpegLocator.ffmpegPath,
            arguments: ["-nostdin", "-v", "error", "-y", "-f", "lavfi",
                        "-i", "aevalsrc=0.0915527*\(tone)|-0.0908203*\(tone):s=8000:d=10",
                        "-c:a", "pcm_s16le", out.path],
            deadlineSeconds: 120)
        try #require(made.exitCode == 0, "ffmpeg exit \(made.exitCode) \(made.stderr.suffix(300))")
        let pcm = try await AudioPCMDecoder().decode(path: out.path)
        let mixPeak = pcm.samples.map { abs(Int($0)) }.max() ?? 0
        #expect(mixPeak <= 40, "the mono mix must be near-silent for this case to bite (peak \(mixPeak))")
        let fp = AudioFingerprint.compute(pcm)
        #expect(fp.landmarkCount > 0, "matching evidence must survive: \(fp.landmarkCount) landmarks")
        #expect(AudioFingerprintStamp.reading(of: fp) == .printable, "\(AudioFingerprintStamp.reading(of: fp))")
        #expect(AudioFingerprintStamp.fingerprinted(fp, contentDigest: "sha256:ab", sizeBytes: 1_000)
                    .hearing(headerHasAudio: true) == .heardSound)
    }

    @Test("#345 Codex round 2 rule: silence needs the SOURCE channels quiet too — a quiet mix over a −21 dBFS source keeps its landmarks and is not measured per second; a −70 dBFS source is silence; an unmeasured source is never silence")
    func silenceNeedsQuietSourceChannels() {
        let quietMix = Self.tonalFloor(peak: 12)
        let loudSource = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: quietMix, sourceLevel: .peakDBFS(-21)))
        #expect(loudSource.landmarkCount > 0)
        #expect(loudSource.secondsAboveSilenceCeiling == nil, "0 would claim silence the source contradicts")
        #expect(AudioFingerprintStamp.reading(of: loudSource) == .printable)
        let quietSource = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: quietMix, sourceLevel: .peakDBFS(-70)))
        #expect(quietSource.landmarkCount == 0 && AudioFingerprintStamp.reading(of: quietSource) == .silence)
        let unmeasured = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: quietMix, sourceLevel: .unmeasured))
        #expect(AudioFingerprintStamp.reading(of: unmeasured) != .silence)
        let zeros = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: [Int16](repeating: 0, count: 16_000),
                                                      sourceLevel: .peakDBFS(-.infinity)))
        #expect(AudioFingerprintStamp.reading(of: zeros) == .silence, "digital zeros on every channel")
    }

    @Test("#345 Codex round 2: the decoder reads only its own astats instance's peak lines — the loudest wins, '-inf' is −∞, an indented metadata line or garbage is never a measurement")
    func sourceLevelParse() {
        let tag = "[astats@vsprint @ 0x7805040900] "
        #expect(AudioSourceLevel.parse(stderr: "\(tag)Channel: 1\n\(tag)Peak level dB: -20.9\n\(tag)Channel: 2\n\(tag)Peak level dB: -63.0\n")
                == .peakDBFS(-20.9))
        #expect(AudioSourceLevel.parse(stderr: "\(tag)Peak level dB: -inf\n") == .peakDBFS(-.infinity))
        #expect(AudioSourceLevel.parse(stderr: "    COMMENT         : [astats@vsprint @ 0x1] Peak level dB: -90\n") == .unmeasured)
        #expect(AudioSourceLevel.parse(stderr: "[astats@other @ 0x1] Peak level dB: -90\n") == .unmeasured)
        #expect(AudioSourceLevel.parse(stderr: "\(tag)Peak level dB: -90\n\(tag)Peak level dB: nan\n") == .unmeasured)
        #expect(AudioSourceLevel.parse(stderr: "") == .unmeasured)
    }
}
