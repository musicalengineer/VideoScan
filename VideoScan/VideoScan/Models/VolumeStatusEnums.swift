// VolumeStatusEnums.swift
// Volume lifecycle / role / trust / media-tech enums plus the computed
// destination-policy enum — moved verbatim from Models.swift (refactor
// 2026-06-26, model decomposition step 1). See Models.swift for the
// group overview.

import SwiftUI

// MARK: - Volume Phase (lifecycle)

enum VolumePhase: String, CaseIterable, Codable {
    case noCatalog    = "NO CATALOG"
    case cataloged    = "Cataloged"
    case reviewed     = "Reviewed"
    case consolidated = "Consolidated"
    case archived     = "Archived"

    // Legacy decoding: "New" → .noCatalog
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "New" { self = .noCatalog; return }
        guard let v = VolumePhase(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "Unknown VolumePhase: \(raw)")
        }
        self = v
    }

    var icon: String {
        switch self {
        case .noCatalog:    return "circle"
        case .cataloged:    return "list.bullet"
        case .reviewed:     return "checkmark.circle"
        case .consolidated: return "arrow.triangle.merge"
        case .archived:     return "archivebox"
        }
    }

    var color: Color {
        switch self {
        case .noCatalog:    return .secondary
        case .cataloged:    return .blue
        case .reviewed:     return .green
        case .consolidated: return .purple
        case .archived:     return .mint
        }
    }

    /// Next phase in the lifecycle, or nil if already archived.
    var next: VolumePhase? {
        guard let idx = Self.allCases.firstIndex(of: self),
              idx + 1 < Self.allCases.count else { return nil }
        return Self.allCases[idx + 1]
    }
}

// MARK: - Volume Role

enum VolumeRole: String, CaseIterable, Codable {
    case unassigned  = "Unassigned"
    case system      = "System"
    case original    = "Original"
    case backup      = "Backup"
    case archive     = "Archive"
    case lta         = "Long-Term Archive"
    case retired     = "Retired"

    var icon: String {
        switch self {
        case .unassigned: return "questionmark.circle"
        case .system:     return "internaldrive.fill"
        case .original:   return "film.stack"
        case .backup:     return "doc.on.doc"
        case .archive:    return "archivebox.fill"
        case .lta:        return "icloud.fill"
        case .retired:    return "archivebox"
        }
    }

    var color: Color {
        switch self {
        case .unassigned: return .secondary
        case .system:     return .purple
        case .original:   return .orange
        case .backup:     return .blue
        case .archive:    return .green
        case .lta:        return .mint
        case .retired:    return .brown
        }
    }

    var shortLabel: String {
        switch self {
        case .unassigned: return "—"
        case .system:     return "SYS"
        case .original:   return "ORIG"
        case .backup:     return "BKUP"
        case .archive:    return "ARCH"
        case .lta:        return "LTA"
        case .retired:    return "RTD"
        }
    }
}

enum VolumeTrust: String, CaseIterable, Codable {
    case unknown    = "Unknown"
    case reliable   = "Reliable"
    case aging      = "Aging"
    case unreliable = "Unreliable"

    var icon: String {
        switch self {
        case .unknown:    return "questionmark.circle"
        case .reliable:   return "checkmark.shield.fill"
        case .aging:      return "exclamationmark.triangle"
        case .unreliable: return "xmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown:    return .secondary
        case .reliable:   return .green
        case .aging:      return .yellow
        case .unreliable: return .red
        }
    }
}

// MARK: - Volume Media Technology

enum VolumeMediaTech: String, CaseIterable, Codable {
    case unknown = "Unknown"
    case ssd     = "SSD"
    case hdd     = "HDD"
    case raid0   = "RAID-0"
    case raid1   = "RAID-1"
    case raid5   = "RAID-5"
    case raid10  = "RAID-10"
    case cloud   = "Cloud"
    case network = "Network"

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .ssd:     return "internaldrive"
        case .hdd:     return "externaldrive"
        case .raid0,
             .raid1,
             .raid5,
             .raid10:  return "externaldrive.connected.to.line.below"
        case .cloud:   return "icloud"
        case .network: return "network"
        }
    }

    /// Multi-disk redundancy: a single-disk failure doesn't lose the volume.
    var isRedundant: Bool {
        switch self {
        case .raid1, .raid5, .raid10, .cloud: return true
        default: return false
        }
    }

    /// RAID-0 doubles failure probability with no redundancy — never an
    /// archive destination, even when new.
    var isFragile: Bool { self == .raid0 }
}

// MARK: - Destination Policy (computed)

/// How appropriate a volume is as a *destination* for archived media.
/// Pure function of role + trust + mediaTech + age + reachability.
enum DestinationPolicy: String {
    case preferred
    case acceptable
    case discouraged
    case forbidden

    var label: String {
        switch self {
        case .preferred:   return "Preferred"
        case .acceptable:  return "Acceptable"
        case .discouraged: return "Discouraged"
        case .forbidden:   return "Forbidden"
        }
    }

    var color: Color {
        switch self {
        case .preferred:   return .green
        case .acceptable:  return .yellow
        case .discouraged: return .orange
        case .forbidden:   return .red
        }
    }

    var icon: String {
        switch self {
        case .preferred:   return "checkmark.seal.fill"
        case .acceptable:  return "checkmark.circle"
        case .discouraged: return "exclamationmark.triangle.fill"
        case .forbidden:   return "xmark.octagon.fill"
        }
    }
}
