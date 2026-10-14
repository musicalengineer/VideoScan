// AudioFingerprintMatcher.swift (VideoScanCore)
// ONE SENTENCE: given a master's fingerprint and a query's, find the time
// offset at which their landmarks line up and say what that means — same
// recording, clip of the master, master inside the query, partial overlap,
// or different.
//
// STUB (red phase, 2026-10-14): the public surface the acceptance suite is
// written against. The real matcher lands in a later commit.

import Foundation

public struct AudioMatchPolicy: Sendable, Equatable {
    public var minMatchedLandmarks: Int = 20
    public var minCoverage: Double = 0.5
    public var edgeToleranceSeconds: Double = 1.5
    public var minOverlapSeconds: Double = 5
    public var bucketGapSeconds: Double = 2
    public var offsetToleranceFrames: Int = 1

    public init() {}
    public static let `default` = AudioMatchPolicy()
}

public enum AudioMatchVerdict: Sendable, Equatable {
    case sameRecording
    case containedInMaster(offsetSeconds: Double)
    case masterContainedInQuery(offsetSeconds: Double)
    case overlap(offsetSeconds: Double, seconds: Double)
    case different
}

public struct AudioMatchEvidence: Sendable, Equatable {
    public var matchedLandmarks: Int
    public var coverage: Double
    public var overlapSeconds: Double
    public var spanSeconds: Double
    public var offsetSeconds: Double
    public var queryDurationSeconds: Double
    public var masterDurationSeconds: Double

    public init(matchedLandmarks: Int, coverage: Double, overlapSeconds: Double, spanSeconds: Double,
                offsetSeconds: Double, queryDurationSeconds: Double, masterDurationSeconds: Double) {
        self.matchedLandmarks = matchedLandmarks
        self.coverage = coverage
        self.overlapSeconds = overlapSeconds
        self.spanSeconds = spanSeconds
        self.offsetSeconds = offsetSeconds
        self.queryDurationSeconds = queryDurationSeconds
        self.masterDurationSeconds = masterDurationSeconds
    }

    public func verdict(policy: AudioMatchPolicy = .default) -> AudioMatchVerdict { .different }
}

public struct AudioMatch: Sendable, Equatable {
    public let evidence: AudioMatchEvidence
    public let verdict: AudioMatchVerdict
    public let queryLandmarks: Int
    public let masterLandmarks: Int
    public let spanStartInMasterSeconds: Double
    public let spanEndInMasterSeconds: Double

    public var offsetSeconds: Double { evidence.offsetSeconds }
    public var matchedLandmarks: Int { evidence.matchedLandmarks }
    public var coverage: Double { evidence.coverage }
    public var density: Double { queryLandmarks > 0 ? Double(matchedLandmarks) / Double(queryLandmarks) : 0 }
    public var spanSeconds: Double { evidence.spanSeconds }
}

public struct AudioFingerprintIndex: Sendable {
    public let master: AudioFingerprint

    public init(master: AudioFingerprint) {
        self.master = master
    }

    public func match(_ query: AudioFingerprint, policy: AudioMatchPolicy = .default) -> AudioMatch {
        let evidence = AudioMatchEvidence(matchedLandmarks: 0, coverage: 0, overlapSeconds: 0, spanSeconds: 0,
                                          offsetSeconds: 0, queryDurationSeconds: query.durationSeconds,
                                          masterDurationSeconds: master.durationSeconds)
        return AudioMatch(evidence: evidence, verdict: .different, queryLandmarks: query.landmarkCount,
                          masterLandmarks: master.landmarkCount, spanStartInMasterSeconds: 0,
                          spanEndInMasterSeconds: 0)
    }
}

public enum AudioFingerprintMatcher {
    public static func match(query: AudioFingerprint, master: AudioFingerprint,
                             policy: AudioMatchPolicy = .default) -> AudioMatch {
        AudioFingerprintIndex(master: master).match(query, policy: policy)
    }
}
