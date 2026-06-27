// VolumeStatusEnums.swift
// Volume lifecycle / role / trust / media-tech enums — moved verbatim
// from Models.swift (refactor 2026-06-26, model decomposition step 1), then
// into the VideoScanCore package (2026-06-26 step 3). The SwiftUI display
// accessors (SF Symbol / Color / short-label properties) live in
// ModelsUI/VolumeStatusEnums+Presentation.swift and the wholly-UI
// DestinationPolicy enum in ModelsUI/DestinationPolicy.swift, app-side, so
// this file is Foundation-only. `public` added during package extraction so
// the app target (which sees the package via @_exported) reads these
// unchanged.

import Foundation

// MARK: - Volume Phase (lifecycle)

public enum VolumePhase: String, CaseIterable, Codable {
    case noCatalog    = "NO CATALOG"
    case cataloged    = "Cataloged"
    case reviewed     = "Reviewed"
    case consolidated = "Consolidated"
    case archived     = "Archived"

    // Legacy decoding: "New" → .noCatalog
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "New" { self = .noCatalog; return }
        guard let v = VolumePhase(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "Unknown VolumePhase: \(raw)")
        }
        self = v
    }

    /// Next phase in the lifecycle, or nil if already archived.
    public var next: VolumePhase? {
        guard let idx = Self.allCases.firstIndex(of: self),
              idx + 1 < Self.allCases.count else { return nil }
        return Self.allCases[idx + 1]
    }
}

// MARK: - Volume Role

public enum VolumeRole: String, CaseIterable, Codable {
    case unassigned  = "Unassigned"
    case system      = "System"
    case original    = "Original"
    case backup      = "Backup"
    case archive     = "Archive"
    case lta         = "Long-Term Archive"
    case retired     = "Retired"
}

public enum VolumeTrust: String, CaseIterable, Codable {
    case unknown    = "Unknown"
    case reliable   = "Reliable"
    case aging      = "Aging"
    case unreliable = "Unreliable"
}

// MARK: - Volume Media Technology

public enum VolumeMediaTech: String, CaseIterable, Codable {
    case unknown = "Unknown"
    case ssd     = "SSD"
    case hdd     = "HDD"
    case raid0   = "RAID-0"
    case raid1   = "RAID-1"
    case raid5   = "RAID-5"
    case raid10  = "RAID-10"
    case cloud   = "Cloud"
    case network = "Network"

    /// Multi-disk redundancy: a single-disk failure doesn't lose the volume.
    public var isRedundant: Bool {
        switch self {
        case .raid1, .raid5, .raid10, .cloud: return true
        default: return false
        }
    }

    /// RAID-0 doubles failure probability with no redundancy — never an
    /// archive destination, even when new.
    public var isFragile: Bool { self == .raid0 }
}
