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
}
