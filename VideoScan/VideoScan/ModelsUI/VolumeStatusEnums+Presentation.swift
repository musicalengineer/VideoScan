// VolumeStatusEnums+Presentation.swift
// SwiftUI display-only accessors for the volume lifecycle / role / trust /
// media-tech enums — the SF Symbol / Color / short-label computed
// properties lifted OFF the pure-domain enums in
// Models/VolumeStatusEnums.swift (refactor 2026-06-26, model
// decomposition step 2). The domain enums stay Foundation-only so the
// Models/ group can later be lifted into a Swift package; these UI
// accessors live in the app-side ModelsUI/ group.

import SwiftUI

extension VolumePhase {
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
}

extension VolumeRole {
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

extension VolumeTrust {
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

extension VolumeMediaTech {
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
}
