// CatalogScanTarget.swift
// The per-scan-target observable model plus its status enum and the
// dashboard progress value types — moved verbatim from Models.swift
// (refactor 2026-06-26, model decomposition step 1). See Models.swift
// for the group overview.

import SwiftUI
import Combine

// MARK: - Catalog Scan Target Status

enum CatalogTargetStatus: String {
    case idle        = "Idle"
    case discovering = "Discovering…"
    case scanning    = "Scanning"
    case paused      = "Paused"
    case complete    = "Complete"
    case stopped     = "Stopped"
    case error       = "Error"
    case resumable   = "Resumable"
    case waitingForVolume = "Waiting for Volume"

    var isIdle: Bool { self == .idle || self == .resumable }
    var isActive: Bool { self == .scanning || self == .paused || self == .discovering || self == .waitingForVolume }
    var isPaused: Bool { self == .paused }

    var color: Color {
        switch self {
        case .idle:              return .secondary.opacity(0.4)
        case .discovering:       return .yellow
        case .scanning:          return .green
        case .paused:            return .cyan
        case .complete:          return .blue
        case .stopped:           return .orange
        case .error:             return .red
        case .resumable:         return .purple
        case .waitingForVolume:  return .yellow.opacity(0.7)
        }
    }
}

// MARK: - Catalog Scan Target

@MainActor
final class CatalogScanTarget: ObservableObject, Identifiable {
    let id = UUID()
    @Published var searchPath: String
    @Published var status: CatalogTargetStatus = .idle
    @Published var filesFound: Int = 0
    @Published var filesScanned: Int = 0
    @Published var elapsedSecs: Double = 0.0
    /// Whether the search path is currently mounted/reachable. Updated by
    /// VideoScanModel on launch and on NSWorkspace mount/unmount notifications.
    @Published var isReachable: Bool = true
    /// When this volume's catalog was last updated (scan completed).
    @Published var lastScannedDate: Date?
    /// Lifecycle phase — user-assigned workflow state.
    @Published var phase: VolumePhase = .noCatalog
    /// What role this volume plays in the archival workflow.
    @Published var role: VolumeRole = .unassigned
    /// How trustworthy this volume is (age/reliability).
    @Published var trust: VolumeTrust = .unknown
    /// Filesystem name (APFS, HFS+, exFAT, NTFS, SMB, …). User-entered.
    @Published var filesystem: String = ""
    /// Storage medium / topology (SSD, HDD, RAID-0/-1/-5, cloud, network).
    @Published var mediaTech: VolumeMediaTech = .unknown
    /// Year the volume was placed in service. Drives the age penalty in
    /// `destinationPolicy`.
    @Published var purchaseYear: Int?
    /// Total capacity in terabytes. Free-form display, not an enforced limit.
    @Published var capacityTB: Double?
    /// User notes — model number, serial, location, history, etc.
    @Published var notes: String = ""

    /// §1B — Retirement metadata. When `retiredAt != nil` this volume has
    /// been *retired*: physically disconnected and not coming back. The
    /// catalog still has the records (preserved for audit), but the volume
    /// is excluded from scan suggestions, "missing volume" complaints, and
    /// dashboard nags. Reinstate by setting all three back to nil.
    ///
    /// Set after a Relocate run that lands every catalogued record on the
    /// source volume in `.manuallyDeleted` (Bucket B + Bucket E disposed
    /// 100% of records). Two-button modal (`Retire` / `Skip for now`) —
    /// no typed confirmation; fully reversible via the Reinstate context
    /// action. See docs/relocate_volume_plan.md §1B.
    ///
    /// Swift's `Date?` ≈ C++ `std::optional<Date>` — nil means "not retired."
    @Published var retiredAt: Date?

    /// Free-text reason captured at retire time. Default-populated from
    /// the Relocate end-of-run modal (e.g. "All records dup-elsewhere or
    /// source-deleted via Relocate 2026-05-30"), editable before the user
    /// hits Retire.
    @Published var retiredReason: String?

    /// Union of Bucket E witness paths aggregated across every
    /// `.manuallyDeleted` record on this volume. Lets the post-retire
    /// audit trail answer "where does the content from this drive live now?"
    /// without re-querying every record. Deduped at retire time.
    @Published var retiredWitnesses: [String]?

    /// Convenience predicate. `// guard let` ≈ C++ early-return after a
    /// null check.
    var isRetired: Bool { retiredAt != nil }

    /// Computed archival-destination suitability. Rules (first match wins):
    ///   1. RAID-0 or trust=Unreliable → Forbidden
    ///   2. Offline → Discouraged (can't write to it now)
    ///   3. Role not Archive/LTA → Acceptable (it's not meant as a target)
    ///   4. Trust=Aging → Discouraged
    ///   5. ≥12 yr old, or ≥8 yr old without redundancy → Discouraged
    ///   6. Trust=Unknown on plain HDD/Network → Acceptable
    ///   7. Else → Preferred
    var destinationPolicy: DestinationPolicy {
        if mediaTech.isFragile { return .forbidden }
        if trust == .unreliable { return .forbidden }
        if !isReachable { return .discouraged }

        let isDestRole = (role == .archive || role == .lta)
        if !isDestRole { return .acceptable }

        if trust == .aging { return .discouraged }

        if let year = purchaseYear {
            let now = Calendar.current.component(.year, from: Date())
            let age = now - year
            if age >= 12 { return .discouraged }
            if age >= 8 && !mediaTech.isRedundant { return .discouraged }
        }

        if trust == .unknown
            && !mediaTech.isRedundant
            && mediaTech != .ssd
            && mediaTech != .cloud {
            return .acceptable
        }

        return .preferred
    }

    var scanTask: Task<Void, Never>?
    let pauseGate = PauseGate()
    private var taskStarted: Date?
    private var timerTask: Task<Void, Never>?

    init(searchPath: String) {
        self.searchPath = searchPath
        self.isReachable = VolumeReachability.isReachable(path: searchPath)
    }

    func startElapsedTimer() {
        taskStarted = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { [weak self] in
                    guard let self, let s = self.taskStarted else { return }
                    self.elapsedSecs = Date().timeIntervalSince(s)
                }
            }
        }
    }

    func stopElapsedTimer() {
        timerTask?.cancel()
        if let s = taskStarted { elapsedSecs = Date().timeIntervalSince(s) }
    }

    func reset() {
        scanTask?.cancel(); timerTask?.cancel()
        Task { await pauseGate.resume() }
        status = .idle; filesFound = 0; filesScanned = 0; elapsedSecs = 0
        scanTask = nil; timerTask = nil; taskStarted = nil
    }
}

// MARK: - Dashboard Types

enum ScanPhase: String {
    case idle        = "Idle"
    case discovering = "Discovering"
    case probing     = "Probing"
    case paused      = "Paused"
    case writingCSV  = "Writing CSV"
    case complete    = "Complete"
}

struct VolumeProgress: Identifiable {
    let id = UUID()
    let rootPath: String
    var volumeName: String
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var cacheHits: Int = 0
    var errors: Int = 0
    var isWalking: Bool = true
}

struct ThroughputSample {
    let timestamp: Date
    let filesPerSecond: Double
}
