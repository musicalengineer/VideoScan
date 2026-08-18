import Foundation
import SwiftUI

// MARK: - Provenance & Audit Trail value types
//
// These are the data envelopes for the three views in the
// Provenance & Audit Trail feature (docs/relocate_volume_plan.md §2):
//
//   - VolumeProvenance    — "Where files from <volume> live now"
//   - FileJourney         — "Following <filename>"
//   - MigrationOverview   — "From aging drives to safe homes"
//
// All three types are pure values built by `VideoScanModel+Provenance`.
// Keeping the value types separate from the view code lets the tests
// exercise the logic without instantiating SwiftUI at all (same pattern
// the §1A Reconcile work uses).
//
// Memory footprint: each provenance value is O(records-on-volume) for
// path strings plus a handful of summary scalars. For Rick's largest
// volumes (~50K records, ~256B average path) the worst case is ~12 MB
// per VolumeProvenance — well within budget for an on-demand sheet that
// is built once per click and discarded on dismiss.

// MARK: - Volume Provenance (View 1)

/// One destination volume that holds copies of files originally cataloged
/// on a given source volume. Backs each card in `VolumeProvenanceSheet`.
///
/// `Identifiable` so SwiftUI can drive a `ForEach` directly.
struct DestinationVolumeGroup: Identifiable, Equatable {
    let id = UUID()
    /// Friendly display name — "MyBook3Terabytes". Falls back to the raw
    /// volume root path leaf component when there's no matching scan target.
    let volumeName: String
    /// Absolute path of the volume root (or empty for unknown volumes).
    let volumeRootPath: String
    /// Host volume's archival role, when resolvable.
    let role: VolumeRole
    /// Host volume's trust band, when resolvable.
    let trust: VolumeTrust
    /// File count on this destination volume — paths-deduped.
    let fileCount: Int
    /// Total bytes across all files on this destination volume.
    let totalBytes: Int64
    /// Up to 5 sample paths for the disclosure list. Sorted alphabetically
    /// so the same set of files always renders in the same order.
    let samplePaths: [String]
    /// Total files on this destination (so the UI can say "and N more"
    /// when `samplePaths.count < totalSampleAvailable`).
    let totalSampleAvailable: Int
    /// Host volume retired (`CatalogScanTarget.isRetired`). Lifecycle, not
    /// a role — rides alongside role/trust (taxonomy cleanup 2026-08-16).
    /// Defaulted so the memberwise init keeps its historical shape.
    var isRetired: Bool = false

    /// `safe == true` iff host volume is not retired AND trust is not
    /// `.unreliable`. ONE definition — `VolumeSafety.isSafe` — so a
    /// destination derived from the same machinery agrees on what "safe"
    /// means with the reconcile pass.
    var isSafe: Bool { VolumeSafety(role: role, trust: trust, isRetired: isRetired).isSafe }

    /// Single composite score used for card ordering. Same weighting as
    /// `SafeWitnessInfo.safetyScore` (role dominates trust at 10x) so the
    /// destination ordering matches the §1A.2 witness ranking.
    var safetyScore: Int {
        SafeWitnessInfo(path: "", role: role, trust: trust, isRetired: isRetired).safetyScore
    }
}

/// Full payload for `VolumeProvenanceSheet`. Built once per click and
/// kept in `@State` for the lifetime of the sheet.
struct VolumeProvenance: Identifiable, Equatable {
    let id = UUID()
    /// "Mini2TB" — display name of the source volume.
    let sourceVolumeName: String
    /// Absolute source volume root path. Drives queries.
    let sourceVolumeRootPath: String
    /// True when the source volume is currently retired.
    let sourceIsRetired: Bool
    /// Retire date if `sourceIsRetired`, else nil.
    let sourceRetiredAt: Date?
    /// Free-text retire reason if any.
    let sourceRetiredReason: String?
    /// Total records originally scoped to (or already migrated off) the
    /// source. Drives the "all NN files" headline.
    let sourceRecordCount: Int
    /// Records that still have at least one known safe copy somewhere in
    /// the catalog. Drives the green-vs-yellow headline.
    let recordsWithSafeBackup: Int
    /// Records lacking any safe backup — these are at-risk filenames.
    let atRiskFilenames: [String]
    /// Destination cards sorted by safety score descending. Each card is
    /// the union of every copy (current `fullPath` AND every parsed Bucket
    /// E witness) seen on that destination volume.
    let allDestinations: [DestinationVolumeGroup]

    /// Subset of `allDestinations` whose host volume is safe. Default tab
    /// of the sheet.
    var safeDestinations: [DestinationVolumeGroup] {
        allDestinations.filter { $0.isSafe }
    }

    /// Friendly headline above the destination cards.
    var headlineText: String {
        if sourceRecordCount == 0 {
            return "No files cataloged from \(sourceVolumeName) yet."
        }
        if recordsWithSafeBackup == sourceRecordCount {
            return "All \(sourceRecordCount) files have at least one safe backup."
        }
        let missing = sourceRecordCount - recordsWithSafeBackup
        return "\(missing) of \(sourceRecordCount) files lack a safe backup."
    }

    /// True when every record has at least one safe witness or current
    /// location. Drives the green-vs-yellow headline color.
    var allRecordsSafe: Bool {
        sourceRecordCount > 0 && recordsWithSafeBackup == sourceRecordCount
    }
}

// MARK: - File Journey (View 2)

/// One timeline event drawn in the File Journey sheet. Renders as an
/// icon + timestamp + sentence. The icon is a SF Symbol name; the color
/// belongs to the event family.
struct JourneyEvent: Identifiable, Equatable {
    let id = UUID()
    /// Sort key. Lower events render higher (older first).
    let timestamp: Date?
    /// Pretty stamp for the timeline — may be empty when the source line
    /// didn't carry a parseable date (free-form user notes, legacy import).
    let displayStamp: String
    /// SF Symbol name.
    let icon: String
    /// SwiftUI Color name. We use the enum to keep the type Equatable for
    /// tests; the view picks a `Color` from the case.
    let kind: JourneyEventKind
    /// Human-readable sentence — already friendly-toned by the producer.
    let sentence: String

    /// The icon color the timeline renders. C++ analogue: a switch on
    /// `kind` returning a Color enum.
    var color: Color { kind.color }
}

/// Family of events on a File Journey timeline. Lets the view pick an
/// icon + color without scattering `if`s through the SwiftUI code.
enum JourneyEventKind: String, Equatable {
    case origin
    case reconcile
    case combine
    case relocate
    case retire
    case currentState
    case freeForm
    /// Rick 2026-06-14: ReformatJob (and future "Improve via recipe"
    /// jobs that produce a new file) write a Reformat event onto the
    /// SOURCE record's journey ("Reformatted to HEVC as …") and an
    /// origin-flavored event onto the DERIVED record's journey
    /// ("Derived from <source> via Reformat"). Lets the timeline tell
    /// the full rescue story.
    case reformat
    /// Master Archive promotion (2026-08-15): the SOURCE record's journey
    /// gets "Promoted to Master Archive as …"; the archive COPY's journey
    /// gets "Promoted from …". Verified copy, never a move.
    case promote

    var color: Color {
        switch self {
        case .origin:       return .blue
        case .reconcile:    return .mint
        case .combine:      return .purple
        case .relocate:     return .orange
        case .retire:       return .brown
        case .currentState: return .green
        case .freeForm:     return .secondary
        case .reformat:     return .red
        case .promote:      return .yellow
        }
    }

    var defaultIcon: String {
        switch self {
        case .origin:       return "scope"
        case .reconcile:    return "checkmark.shield"
        case .combine:      return "link.circle"
        case .relocate:     return "arrow.right.circle"
        case .retire:       return "archivebox"
        case .currentState: return "mappin.and.ellipse"
        case .freeForm:     return "text.bubble"
        case .reformat:     return "wand.and.stars"
        case .promote:      return "star.circle"
        }
    }
}

/// One known copy of this file at some other location. Renders in the
/// "N other copies known" disclosure of the journey sheet.
struct KnownCopy: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let volumeName: String
    let role: VolumeRole
    let trust: VolumeTrust
    /// Host volume retired (`CatalogScanTarget.isRetired`).
    var isRetired: Bool = false

    var isSafe: Bool { VolumeSafety(role: role, trust: trust, isRetired: isRetired).isSafe }
}

/// Full payload for the File Journey sheet.
struct FileJourney: Identifiable, Equatable {
    let id = UUID()
    let recordID: UUID
    let filename: String
    /// "partialMD5: abc12345…" — hash line at the top.
    let hashStatusLine: String
    /// True when the record is currently marked deleted from the catalog
    /// (`.manuallyDeleted`). Shifts the "current state" event to use the
    /// retire icon + friendlier "marked deleted" copy.
    let isMarkedDeleted: Bool
    /// Timeline events, oldest-first.
    let events: [JourneyEvent]
    /// "N other copies known" — list of currently known copies on volumes
    /// other than the current `fullPath`. Includes witness paths parsed
    /// out of Bucket E notes.
    let otherKnownCopies: [KnownCopy]
    /// Scored preservation steps (2026-08-12). Computed when the journey
    /// is built so the sheet stays a pure function of one value, and so
    /// the checklist can never disagree with the history beneath it.
    var preservation: [PreservationStep] = []
}

// MARK: - Migration Overview (View 3)

/// One slice of the fleet snapshot pie. Volume-role keyed.
struct FleetRoleSlice: Identifiable, Equatable {
    let id = UUID()
    let role: VolumeRole
    let recordCount: Int

    var label: String { role.rawValue }
}

/// One row of the migration flow stacked bar — "records originally on
/// role X currently live on role Y, in count Z." UI renders one bar per
/// source role; each bar is the array of these entries summed.
struct MigrationFlowEntry: Identifiable, Equatable {
    let id = UUID()
    let sourceRole: VolumeRole
    let destinationRole: VolumeRole
    let recordCount: Int
}

/// One bar of the migration flow chart — all destination breakdowns for
/// a single source role. UI iterates over these to render the stacked
/// horizontal bars.
struct MigrationFlowBar: Identifiable, Equatable {
    let id = UUID()
    let sourceRole: VolumeRole
    let totalRecords: Int
    let entries: [MigrationFlowEntry]

    /// Friendly headline for the bar.
    var headline: String {
        "Records that began on \(sourceRole.rawValue) drives"
    }
}

/// One row of the triage funnel — stage count + label.
struct TriageFunnelStage: Identifiable, Equatable {
    let id = UUID()
    let label: String
    /// Records currently sitting in this stage.
    let recordCount: Int
    /// SF Symbol for the icon.
    let icon: String
}

/// Full payload for the Migration Overview sheet.
struct MigrationOverview: Identifiable, Equatable {
    let id = UUID()
    /// Generated-on stamp for the report. The UI uses this for a "Snapshot
    /// taken at <time>" caption.
    let generatedAt: Date
    /// Total records considered.
    let totalRecords: Int

    // 1. Fleet snapshot
    let fleetSlices: [FleetRoleSlice]

    // 2. Migration flow bars
    let flowBars: [MigrationFlowBar]

    // 3. Triage funnel
    let funnelStages: [TriageFunnelStage]

    // 4. Best stuff highlight
    /// Records that went through Combine AND reached `.archived` OR live
    /// on a `.cloud`/`.archive` role volume. The friendly count.
    let bestStuffCount: Int
    /// Total bytes the best-stuff cohort represents — for the friendly
    /// subhead, since users think in GB more than file counts.
    let bestStuffBytes: Int64
    /// How many of those also have a recorded cloud copy (the 3-2-1 leg).
    var bestStuffWithCloudCopy: Int = 0

    /// Friendly best-stuff sentence.
    var bestStuffSentence: String {
        if bestStuffCount == 0 {
            return "Nothing has been promoted to the Master Archive yet."
        }
        // Rick 2026-08-18: decimal via the shared formatter (was base-1024 "GB").
        let gbStr = MediaBytes.display(bestStuffBytes)
        let cloud = bestStuffWithCloudCopy == 0
            ? "No cloud copy recorded yet — that's the next leg."
            : "\(bestStuffWithCloudCopy) also have a cloud copy."
        return "\(bestStuffCount) file\(bestStuffCount == 1 ? "" : "s") (\(gbStr)) "
            + "are verified in the Master Archive. \(cloud)"
    }
}
