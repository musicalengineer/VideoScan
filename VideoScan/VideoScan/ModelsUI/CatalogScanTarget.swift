// CatalogScanTarget.swift
// The per-scan-target observable model plus its status enum and the
// dashboard progress value types — moved verbatim from Models.swift
// (refactor 2026-06-26, model decomposition step 1). In step 2 this file
// moved from Models/ into the app-side ModelsUI/ group: it is a
// @MainActor ObservableObject that depends on SwiftUI/Combine and is not
// part of the pure (Foundation-only) domain layer. Moved verbatim — no
// logic change.

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

    /// ONE definition of "retired" (codex #385 / docs/volume_taxonomy_proposal.md
    /// — retirement used to have two owners: this stamp AND a `.retired`
    /// VolumeRole case). The taxonomy cleanup (2026-08-16) removed the
    /// role case; `retiredAt` is the sole owner again. Legacy persisted
    /// "Retired" role strings are converted to a stamp at decode time
    /// (`ScanTargetPersistence` / bundle import), so this predicate no
    /// longer needs the role fallback. Every consumer (scan gates, nag,
    /// Volumes window, master-archive refusals, safety resolvers) goes
    /// through this predicate.
    var isRetired: Bool { retiredAt != nil }

    /// Computed archival-destination suitability. Rules (first match wins):
    ///   1. RAID-0 or trust=Unreliable → Forbidden
    ///   2. Offline → Discouraged (can't write to it now)
    ///   3. Role not Archive/Offsite → Acceptable (it's not meant as a target)
    ///   4. Trust=Aging → Discouraged
    ///   5. ≥12 yr old, or ≥8 yr old without redundancy → Discouraged
    ///   6. Trust=Unknown on plain HDD/Network → Acceptable
    ///   7. Else → Preferred
    var destinationPolicy: DestinationPolicy {
        if mediaTech.isFragile { return .forbidden }
        if trust == .unreliable { return .forbidden }
        if !isReachable { return .discouraged }

        let isDestRole = (role == .archive || role == .offsite)
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

// MARK: - Scratch-Volume Screening (RAM disk)

/// The app's own RAM-disk scratch volume (`/Volumes/VideoScan_Temp*`,
/// created by RAMDisk.swift as the network-prefetch cache) is internal
/// plumbing — it must NEVER appear as a catalog/analysis target. This
/// extension is the ONE canonical predicate; every target-list filter and
/// every scan-target ingestion point routes through it.
///
/// History: screening used to be six scattered ad-hoc
/// `contains("VideoScan_Temp")` filters, so each NEW enumeration surface
/// (the Analyze dashboard, 2026-07-08) shipped unscreened and the bug
/// kept regressing. See ScratchVolumeScreeningTests for the sensors.
extension CatalogScanTarget {

    /// RAM-disk naming convention — keep in sync with `RAMDisk.mount`
    /// (`let name = "VideoScan_Temp"`, RAMDisk.swift) and the
    /// `RAMDisk.cleanupStaleMounts` reap pattern (`VideoScan_Temp*`).
    nonisolated static let scratchVolumeNamePrefix = "VideoScan_Temp"

    /// True when any path component STARTS WITH the RAM-disk prefix.
    /// Covers the whole family macOS can produce on mount-name collision
    /// (`VideoScan_Temp`, `VideoScan_Temp 1`, `VideoScan_Temp2`, …) plus
    /// any path beneath one. Anchored on path components, not a bare
    /// substring — a user folder named "MyVideoScan_TempStuff" is legit
    /// and stays visible (the old `contains` filters would have hidden it).
    nonisolated static func isScratchVolumePath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(scratchVolumeNamePrefix) }
    }

    /// Canonical per-target form of the predicate.
    var isScratchVolume: Bool { Self.isScratchVolumePath(searchPath) }

    /// Analyze/dossier candidate gate — the ONE definition shared by the
    /// dossier dashboard rows, the catalog-wide caption sweep, and the
    /// dossier queue, so what the user sees as a row always matches what
    /// Analyze will queue.
    var isAnalyzeCandidate: Bool {
        isReachable && !searchPath.isEmpty && !isRetired && !isScratchVolume
    }

    /// Extracted, testable filters — house rule: inline closures in
    /// `ForEach`/view bodies can't be unit-tested (and no O(records)
    /// work belongs in view bodies anyway).
    static func analyzeCandidates(_ targets: [CatalogScanTarget]) -> [CatalogScanTarget] {
        targets.filter { $0.isAnalyzeCandidate }
    }

    static func excludingScratch(_ targets: [CatalogScanTarget]) -> [CatalogScanTarget] {
        targets.filter { !$0.isScratchVolume }
    }
}

// MARK: - Boot-volume / home-folder classification (role taxonomy 2026-08-16)

/// Path predicates the role migration uses to auto-assign `.system` (the
/// boot volume root — never user-picked) and default `.working` (folder
/// targets inside the user's home, e.g. ~/Movies). Pure string logic
/// except the one `realpath` step needed to recognise the boot volume's
/// `/Volumes/<BootName>` alias — a symlink macOS keeps pointing at "/".
extension CatalogScanTarget {

    /// True when `path` IS the boot volume root: "/", the APFS data
    /// volume mount "/System/Volumes/Data", or the `/Volumes/<BootName>`
    /// alias (resolved via `URL.resolvingSymlinksInPath()` ≈ C `realpath()`,
    /// so a folder INSIDE the boot volume — ~/Movies — is never "system").
    /// `resolveAlias` is injectable so tests can pin the alias rule
    /// without depending on the host's boot-volume name.
    nonisolated static func isBootVolumeRootPath(
        _ path: String,
        resolveAlias: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) -> Bool {
        let p = PathScope.normalize(path)
        if p == "/" || p == "/System/Volumes/Data" { return true }
        let comps = (p as NSString).pathComponents
        // Exactly "/Volumes/<name>" — deeper paths are folders, not roots.
        guard comps.count == 3, comps[1] == "Volumes" else { return false }
        let resolved = PathScope.normalize(resolveAlias(p))
        return resolved == "/" || resolved == "/System/Volumes/Data"
    }

    /// True when `path` lies inside a user home directory (`/Users/<name>`
    /// or deeper) — the ~/Movies-style folder target. Such targets are
    /// NOT system; the migration defaults them to `.working` when they are
    /// still unassigned. `homeDirectory` is injectable for tests; the
    /// default also recognises any `/Users/<name>/…` so a target created
    /// under another account's home still classifies sensibly.
    nonisolated static func isHomeFolderPath(
        _ path: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        let p = PathScope.normalize(path)
        let home = PathScope.normalize(homeDirectory)
        if !home.isEmpty, home != "/", (p == home || p.hasPrefix(home + "/")) { return true }
        let comps = (p as NSString).pathComponents
        // "/Users/<name>" (3 comps) or deeper; "/Users" itself is not a home.
        return comps.count >= 3 && comps[1] == "Users" && comps[2] != "Shared"
    }

    var isBootVolumeRoot: Bool { Self.isBootVolumeRootPath(searchPath) }
    var isHomeFolderTarget: Bool { Self.isHomeFolderPath(searchPath) }
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
