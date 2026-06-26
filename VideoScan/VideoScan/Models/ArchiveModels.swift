// ArchiveModels.swift
// File-lifecycle, disposition, archive-stage, archive-health, and backup
// models — moved verbatim from Models.swift (refactor 2026-06-26, model
// decomposition step 1). See Models.swift for the group overview.

import SwiftUI

// MARK: - Lifecycle Stage (which tab shows this file)

enum LifecycleStage: String, Codable, CaseIterable {
    case cataloged = "Cataloged"
    case reviewing = "In Triage"
    /// Output of Combine / Repair / Transcode workflows that have produced
    /// a new file but haven't yet been reviewed and promoted to the long-
    /// term Archive. The Workbench tab surfaces these so the user can spot-
    /// check recent work before committing it, and prune test artifacts
    /// without them lingering in the Catalog forever. See
    /// [[project_archive_combine_pipeline_order]] step 2C.
    case workbench = "Workbench"
    case archived  = "Archived"
    /// File moved to macOS Trash via Delete Confirmed Junk workflow.
    /// Record is preserved (soft-deleted via `purgedAt`); the file itself
    /// is recoverable from Finder's Trash until the user empties it.
    case trashed   = "Trashed"
    /// File hard-removed from disk via Delete Confirmed Junk workflow.
    /// Record preserved (soft-deleted via `purgedAt`); the file is gone
    /// and cannot be recovered from the app. Distinct from `.trashed`
    /// so the UI can show the right post-delete provenance to the user.
    case deletedPermanently = "Deleted"
}

// MARK: - Media Disposition (per-file lifecycle)

enum MediaDisposition: String, Codable, CaseIterable {
    case unreviewed    = "Unreviewed"
    case important     = "Important"
    case recoverable   = "Recoverable"
    case suspectedJunk = "Suspected Junk"
    case confirmedJunk = "Confirmed Junk"

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

enum ArchiveStage: String, Codable, CaseIterable, Comparable {
    case none            = "None"
    case healthy         = "Healthy"
    case masterAssigned  = "Master"
    case backedUp        = "Backed Up"
    case readyForArchive = "Ready"
    case archived        = "Archived"
    // Out-of-band terminal states introduced by Relocate. Kept at the end
    // of the case list so Comparable ordering for the happy-path cases is
    // unchanged. See docs/relocate_volume_plan.md §1, §1A.
    case manuallyDeleted = "Manually Deleted"
    case salvageFailed   = "Salvage Failed"

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

    static func < (lhs: ArchiveStage, rhs: ArchiveStage) -> Bool {
        let order: [ArchiveStage] = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Archive Health (traffic-light summary)

enum ArchiveHealth {
    case safe            // green: reviewed, has A/V, backed up
    case inProgress      // yellow: partially classified or archived
    case needsAttention  // red: unreviewed, no backups
    case notApplicable   // junk — no badge

    var icon: String {
        switch self {
        case .safe:           return "checkmark.shield.fill"
        case .inProgress:     return "clock.badge.checkmark"
        case .needsAttention: return "exclamationmark.shield.fill"
        case .notApplicable:  return ""
        }
    }

    var color: Color {
        switch self {
        case .safe:           return .green
        case .inProgress:     return .yellow
        case .needsAttention: return .red
        case .notApplicable:  return .clear
        }
    }

    var label: String {
        switch self {
        case .safe:           return "Safe"
        case .inProgress:     return "In Progress"
        case .needsAttention: return "Needs Attention"
        case .notApplicable:  return ""
        }
    }

    var detail: String {
        switch self {
        case .safe:           return "Reviewed, has audio/video, backed up"
        case .inProgress:     return "Partially reviewed or archived"
        case .needsAttention: return "Not yet reviewed or backed up"
        case .notApplicable:  return ""
        }
    }
}

// MARK: - Backup Entry

struct BackupEntry: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String           // "LTA_Crucial", "iCloud", "Breen's NAS"
    let kind: BackupKind
    let date: Date

    enum BackupKind: String, Codable, CaseIterable {
        case local   = "Local"       // external drive, same network
        case cloud   = "Cloud"       // iCloud, Backblaze, S3
        case offsite = "Offsite"     // physically elsewhere (son's NAS, etc.)

        var icon: String {
            switch self {
            case .local:   return "externaldrive.fill"
            case .cloud:   return "icloud.fill"
            case .offsite: return "building.2.fill"
            }
        }
    }
}
