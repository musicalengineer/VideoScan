// AudioFingerprint.swift (VideoScanCore)
// ONE SENTENCE: a Shazam-style landmark fingerprint of an audio signal — a
// deterministic, compact list of (hash, time) pairs that survives re-encodes,
// rewraps, gain changes and noise, so two files can be asked "same recording,
// at what offset?".
//
// STUB (red phase, 2026-10-14): the public surface the acceptance suite is
// written against. The real engine lands in a later commit.

import Foundation

public struct AudioFingerprintParameters: Sendable, Equatable {
    public var sampleRate: Int = 8_000
    public var frameSize: Int = 1_024
    public var hopSamples: Int = 512
    public var timeRadius: Int = 3
    public var frequencyRadius: Int = 15
    public var maxPeaksPerFrame: Int = 5
    public var floorDB: Float = -30
    public var aboveFrameMeanDB: Float = 6
    public var fanOut: Int = 5
    public var minDeltaFrames: Int = 1
    public var maxDeltaFrames: Int = 63
    public var maxDeltaBins: Int = 127

    public init() {}
    public static let `default` = AudioFingerprintParameters()

    public var hopSeconds: Double { Double(hopSamples) / Double(sampleRate) }
}

public struct AudioFingerprint: Sendable, Equatable {
    public static let currentVersion: UInt16 = 1
    public static let magic: [UInt8] = Array("VSAF".utf8)

    public let version: UInt16
    public let sampleRate: Int
    public let hopSamples: Int
    public let frameSize: Int
    public let durationSeconds: Double
    public let hashes: [UInt32]
    public let times: [UInt32]

    public init(version: UInt16 = AudioFingerprint.currentVersion, sampleRate: Int, hopSamples: Int,
                frameSize: Int, durationSeconds: Double, hashes: [UInt32], times: [UInt32]) {
        self.version = version
        self.sampleRate = sampleRate
        self.hopSamples = hopSamples
        self.frameSize = frameSize
        self.durationSeconds = durationSeconds
        self.hashes = hashes
        self.times = times
    }

    public var landmarkCount: Int { hashes.count }
    public var hopSeconds: Double { Double(hopSamples) / Double(sampleRate) }
    public var estimatedBytes: Int { 0 }

    public static func packHash(f1: Int, f2: Int, dt: Int) -> UInt32 { 0 }
    public static func unpackHash(_ hash: UInt32) -> (f1: Int, f2: Int, dt: Int) { (0, 0, 0) }

    public func encoded() -> Data { Data() }
    public init?(decoding data: Data) { return nil }

    public static func compute(_ pcm: AudioPCM,
                               parameters: AudioFingerprintParameters = .default) -> AudioFingerprint {
        AudioFingerprint(sampleRate: pcm.sampleRate, hopSamples: parameters.hopSamples,
                         frameSize: parameters.frameSize, durationSeconds: pcm.durationSeconds,
                         hashes: [], times: [])
    }
}
