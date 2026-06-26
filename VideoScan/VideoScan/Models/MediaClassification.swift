// MediaClassification.swift
// Media stream-type and pairing/duplicate classification enums — moved
// verbatim from Models.swift (refactor 2026-06-26, model decomposition
// step 1). See Models.swift for the group overview.

import SwiftUI

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

    var color: Color {
        switch self {
        case .high:   return Color.green.opacity(0.22)
        case .medium: return Color.orange.opacity(0.22)
        case .low:    return Color.clear
        }
    }

    var textColor: Color {
        switch self {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .secondary
        }
    }

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

    var textColor: Color {
        switch self {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        }
    }

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

    var textColor: Color {
        switch self {
        case .none:      return .secondary
        case .keep:      return .green
        case .review:    return .orange
        case .extraCopy: return .red
        }
    }
}
