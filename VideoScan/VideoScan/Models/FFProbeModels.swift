// FFProbeModels.swift
// Codable mirrors of ffprobe's JSON output — moved verbatim from
// Models.swift (refactor 2026-06-26, model decomposition step 1). See
// Models.swift for the group overview.

import Foundation

// MARK: - ffprobe JSON Models

struct FFProbeOutput: Codable {
    let streams: [FFStream]?
    let format: FFFormat?
}

struct FFStream: Codable {
    let codec_type: String?
    let codec_name: String?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let bit_rate: String?
    let color_space: String?
    let bits_per_raw_sample: String?
    let field_order: String?
    let channels: Int?
    let sample_rate: String?
    let tags: [String: String]?
}

struct FFFormat: Codable {
    let format_name: String?
    let format_long_name: String?
    let duration: String?
    let size: String?
    let bit_rate: String?
    let tags: [String: String]?
}
