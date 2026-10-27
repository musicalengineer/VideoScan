// ArchiveModels+Presentation.swift
// SwiftUI display-only accessors for the archive-model enums — the SF
// Symbol / Color computed properties lifted OFF the pure-domain enums in
// Models/ArchiveModels.swift (refactor 2026-06-26, model decomposition
// step 2). The domain enums stay Foundation-only so the Models/ group
// can later be lifted into a Swift package; these UI accessors live in
// the app-side ModelsUI/ group.

import SwiftUI

extension MediaDisposition {
    var icon: String {
        switch self {
        case .unreviewed:    return "circle"
        case .important:     return "star.fill"
        case .recoverable:   return "wrench.and.screwdriver.fill"
        case .suspectedJunk: return "exclamationmark.triangle"
        case .confirmedJunk: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unreviewed:    return .secondary
        case .important:     return .blue
        case .recoverable:   return .teal
        case .suspectedJunk: return .orange
        case .confirmedJunk: return .red
        }
    }
}

extension ArchiveStage {
    /// The words the UI shows for a stage. The stage STORED as "Master"
    /// (`.masterAssigned`, stamped on a promoted file and its archive copy)
    /// is SHOWN as "Archived" (DECISIONS 2026-10-26: the Archive stops
    /// labelling files "Masters"; "Master" is the provenance role Rick
    /// confirms). Stored values are unchanged — never write this back.
    var displayName: String {
        switch self {
        case .masterAssigned: return "Archived"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .none:            return "circle"
        case .healthy:         return "heart.fill"
        case .masterAssigned:  return "crown.fill"
        case .backedUp:        return "doc.on.doc.fill"
        case .readyForArchive: return "checkmark.seal.fill"
        case .archived:        return "archivebox.fill"
        case .manuallyDeleted: return "trash.slash.fill"
        case .salvageFailed:   return "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .none:            return .secondary
        case .healthy:         return .green
        case .masterAssigned:  return .blue
        case .backedUp:        return .purple
        case .readyForArchive: return .mint
        case .archived:        return .indigo
        case .manuallyDeleted: return .secondary
        case .salvageFailed:   return .red
        }
    }
}

extension BackupEntry.BackupKind {
    var icon: String {
        switch self {
        case .local:   return "externaldrive.fill"
        case .cloud:   return "icloud.fill"
        case .offsite: return "building.2.fill"
        }
    }
}
