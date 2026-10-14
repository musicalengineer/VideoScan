// AudioPCMDecoder.swift (VideoScanCore)
// ONE SENTENCE: turn any media file ffmpeg can open into 8 kHz mono 16-bit
// PCM in memory, over a pipe, with every failure a named outcome.
//
// STUB (red phase, 2026-10-14): the public surface the acceptance suite is
// written against. The real decoder lands in the next commit.

import Foundation

public struct AudioPCM: Sendable, Equatable {
    public let sampleRate: Int
    public let samples: [Int16]

    public init(sampleRate: Int, samples: [Int16]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}

public struct AudioPCMDecoder: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        case ffmpegMissing(path: String)
        case noAudioStream
        case decodeFailed(exitCode: Int32, stderrTail: String)
        case timedOut
    }

    public struct Window: Sendable, Equatable {
        public var startSeconds: Double?
        public var durationSeconds: Double?
        public init(startSeconds: Double? = nil, durationSeconds: Double? = nil) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }
        public static let whole = Window()
    }

    public static let defaultSampleRate = 8_000
    public static let defaultMaxSeconds: Double = 4 * 3_600
    public static let defaultDeadlineSeconds: Double = 300

    public var ffmpegPath: String
    public var sampleRate: Int
    public var maxSeconds: Double
    public var deadlineSeconds: Double

    public init(ffmpegPath: String = FFmpegLocator.ffmpegPath,
                sampleRate: Int = AudioPCMDecoder.defaultSampleRate,
                maxSeconds: Double = AudioPCMDecoder.defaultMaxSeconds,
                deadlineSeconds: Double = AudioPCMDecoder.defaultDeadlineSeconds) {
        self.ffmpegPath = ffmpegPath
        self.sampleRate = sampleRate
        self.maxSeconds = maxSeconds
        self.deadlineSeconds = deadlineSeconds
    }

    public static func arguments(path: String, window: Window, sampleRate: Int, maxSeconds: Double) -> [String] {
        []
    }

    public func decode(path: String, window: Window = .whole) async throws -> AudioPCM {
        throw Failure.decodeFailed(exitCode: -1, stderrTail: "not implemented")
    }
}
