// MediaClassification.swift
// Media stream-type and pairing/duplicate classification enums — moved
// verbatim from Models.swift (refactor 2026-06-26, model decomposition
// step 1), then into the VideoScanCore package (2026-06-26 step 3). The
// SwiftUI display accessors (Color properties) live in
// ModelsUI/MediaClassification+Presentation.swift app-side so this file is
// Foundation-only. `public` added during package extraction so the app
// target (which sees the package via @_exported) reads these unchanged.

import Foundation

// MARK: - Stream Type

public enum StreamType: String, Codable {
    case videoAndAudio = "Video+Audio"
    case videoOnly     = "Video only"
    case audioOnly     = "Audio only"
    case noStreams      = "No A/V streams"
    case ffprobeFailed = "ffprobe failed"

    public var needsCorrelation: Bool {
        self == .videoOnly || self == .audioOnly
    }
}

// MARK: - Pair Confidence

public enum PairConfidence: String, Codable, Comparable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    public static func < (lhs: PairConfidence, rhs: PairConfidence) -> Bool {
        let order: [PairConfidence] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Duplicate Confidence

public enum DuplicateConfidence: String, Codable, Comparable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    public static func < (lhs: DuplicateConfidence, rhs: DuplicateConfidence) -> Bool {
        let order: [DuplicateConfidence] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

public enum DuplicateDisposition: String, Codable {
    case none      = ""
    case keep      = "Keep"
    case review    = "Review"
    case extraCopy = "Extra copy"
}
