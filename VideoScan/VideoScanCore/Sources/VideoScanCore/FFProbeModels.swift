// FFProbeModels.swift
// Codable mirrors of ffprobe's JSON output — moved verbatim from
// Models.swift (refactor 2026-06-26, model decomposition step 1), then into
// the VideoScanCore package (2026-06-26 step 3). `public` added during
// package extraction: app code decodes FFProbeOutput and reads these fields
// across the module boundary (ScanEngine, CombineVerifier, VideoScanModel).
// A public Codable struct gets a public synthesized `init(from:)`, so
// decode-only types need no hand-written init — only the field reads need
// `public`.

import Foundation

// MARK: - ffprobe JSON Models

public struct FFProbeOutput: Codable {
    public let streams: [FFStream]?
    public let format: FFFormat?
}

public struct FFStream: Codable {
    public let codec_type: String?
    public let codec_name: String?
    public let width: Int?
    public let height: Int?
    public let r_frame_rate: String?
    public let avg_frame_rate: String?
    public let bit_rate: String?
    public let color_space: String?
    public let bits_per_raw_sample: String?
    public let field_order: String?
    public let channels: Int?
    public let sample_rate: String?
    public let tags: [String: String]?
}

public struct FFFormat: Codable {
    public let format_name: String?
    public let format_long_name: String?
    public let duration: String?
    public let size: String?
    public let bit_rate: String?
    public let tags: [String: String]?
}
