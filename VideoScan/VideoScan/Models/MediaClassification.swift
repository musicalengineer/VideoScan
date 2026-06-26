// MediaClassification.swift
// Media stream-type and pairing/duplicate classification enums — moved
// verbatim from Models.swift (refactor 2026-06-26, model decomposition
// step 1). See Models.swift for the group overview. The SwiftUI display
// accessors (Color properties) were lifted into
// ModelsUI/MediaClassification+Presentation.swift in step 2 so this file
// is Foundation-only.

import Foundation

// MARK: - Stream Type

enum StreamType: String, Codable {
    case videoAndAudio = "Video+Audio"
    case videoOnly     = "Video only"
    case audioOnly     = "Audio only"
    case noStreams      = "No A/V streams"
    case ffprobeFailed = "ffprobe failed"

    var needsCorrelation: Bool {
        self == .videoOnly || self == .audioOnly
    }
}

// MARK: - Pair Confidence

enum PairConfidence: String, Codable, Comparable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    static func < (lhs: PairConfidence, rhs: PairConfidence) -> Bool {
        let order: [PairConfidence] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Duplicate Confidence

enum DuplicateConfidence: String, Codable, Comparable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    static func < (lhs: DuplicateConfidence, rhs: DuplicateConfidence) -> Bool {
        let order: [DuplicateConfidence] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

enum DuplicateDisposition: String, Codable {
    case none      = ""
    case keep      = "Keep"
    case review    = "Review"
    case extraCopy = "Extra copy"
}
