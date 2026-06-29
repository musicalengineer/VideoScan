// ArchiveModels.swift
// File-lifecycle, disposition, archive-stage, and backup models — moved
// verbatim from Models.swift (refactor 2026-06-26, model decomposition
// step 1), then into the VideoScanCore package (2026-06-26 step 3). The
// SwiftUI display accessors (SF Symbol / Color properties) live in
// ModelsUI/ArchiveModels+Presentation.swift and the wholly-UI ArchiveHealth
// type in ModelsUI/ArchiveHealth.swift, app-side, so this file is
// Foundation-only. `public` added during package extraction so the app
// target (which sees the package via @_exported) reads these unchanged.

import Foundation

// MARK: - Lifecycle Stage (which tab shows this file)

public enum LifecycleStage: String, Codable, CaseIterable, Sendable {
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

public enum MediaDisposition: String, Codable, CaseIterable, Sendable {
    case unreviewed    = "Unreviewed"
    case important     = "Important"
    case recoverable   = "Recoverable"
    case suspectedJunk = "Suspected Junk"
    case confirmedJunk = "Confirmed Junk"
}

public enum ArchiveStage: String, Codable, CaseIterable, Comparable, Sendable {
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

    public static func < (lhs: ArchiveStage, rhs: ArchiveStage) -> Bool {
        let order: [ArchiveStage] = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Backup Entry

public struct BackupEntry: Codable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String           // "LTA_Crucial", "iCloud", "Breen's NAS"
    public let kind: BackupKind
    public let date: Date

    // Public memberwise init: a public struct's compiler-synthesized
    // memberwise init is internal, but app code (ArchiveView) constructs
    // BackupEntry across the module boundary.
    public init(name: String, kind: BackupKind, date: Date) {
        self.name = name
        self.kind = kind
        self.date = date
    }

    public enum BackupKind: String, Codable, CaseIterable {
        case local   = "Local"       // external drive, same network
        case cloud   = "Cloud"       // iCloud, Backblaze, S3
        case offsite = "Offsite"     // physically elsewhere (son's NAS, etc.)
    }
}
