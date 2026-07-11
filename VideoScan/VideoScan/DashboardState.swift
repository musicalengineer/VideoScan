import Foundation
import SwiftUI
import Combine

/// Separate ObservableObject for high-frequency dashboard and console updates.
/// Isolating these from VideoScanModel prevents the main Table view from
/// re-rendering on every console line or dashboard counter change.
@MainActor
final class DashboardState: ObservableObject {

    init() {
        chipName = Self.detectChipName()
        // Skip timer-based polling when running as a test host
        if NSClassFromString("XCTestCase") == nil {
            startSystemMetrics()
        }
        catalogLog.start(append: true)
    }

    // MARK: - Chip identity / match flash

    @Published var chipName: String = ""
    @Published var lastMatchFlashAt: Date?

    private static func detectChipName() -> String {
        // Shared with the About window — see ChipInfo.swift.
        ChipInfo.line
    }

    // MARK: - Console

    @Published var consoleLines: [String] = []
    private let maxConsoleLines = 2000
    private var pendingLines: [String] = []
    private var flushScheduled = false
    let catalogLog = PersistentLog(name: "catalog")

    func log(_ msg: String) {
        catalogLog.write(msg)
        let newLines = msg.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        pendingLines.append(contentsOf: newLines)

        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15 s
            self?.flushConsole()
        }
    }

    private func flushConsole() {
        flushScheduled = false
        guard !pendingLines.isEmpty else { return }
        consoleLines.append(contentsOf: pendingLines)
        pendingLines.removeAll(keepingCapacity: true)
        if consoleLines.count > maxConsoleLines {
            consoleLines.removeFirst(consoleLines.count - maxConsoleLines)
        }
    }

    func clearConsole() {
        consoleLines.removeAll()
        pendingLines.removeAll()
    }

    // MARK: - Scan Progress (used by CompactDashboard / ExpandedDashboard)

    @Published var scanTotal: Int = 0
    @Published var scanCompleted: Int = 0
    var scanStartTime: Date?

    // Counter integrity (2026-07-03 fix — Rick observed "PROBING
    // 18,456/18,450 (99%)" live: completed EXCEEDED discovered). Two rules:
    //
    //  1. GENERATION STAMPS. stopTarget marks a target .stopped immediately,
    //     but its aborted probe pool's in-flight children keep running
    //     (bounded only by the probe timeout). Starting the next scan then
    //     sees no active targets → resetForScan() zeroes both counters →
    //     the OLD scan's straggler completions landed in the NEW scan's
    //     scanCompleted with no matching discovery increment, breaking
    //     completed ≤ discovered for the whole scan (+6 ≈ the in-flight
    //     pool at the moment of the stop). Every probe now carries the
    //     scanGeneration captured at ENQUEUE time — the same turn as its
    //     discovery increment — and stale-generation events are dropped
    //     here at the seam.
    //
    //  2. AUTHORITATIVE INTERNALS. scanDiscoveredInternal /
    //     scanCompletedInternal are updated per event (never batched), so
    //     the invariant completed ≤ discovered holds at EVERY instant; the
    //     @Published pair is flushed from both internals in the SAME flush,
    //     so published values are always mutually consistent even though
    //     they may lag by one throttle window (≤4 Hz / 50-event batching,
    //     item-4 leg-2 of the 2026-07-02 feedback-storm fix).
    //
    // Violations are never clamped away by the UI: the seam counts them,
    // logs them, and (outside test hosts) trips assertionFailure in Debug.
    private(set) var scanGeneration: UInt64 = 0
    private(set) var scanDiscoveredInternal: Int = 0
    private(set) var scanCompletedInternal: Int = 0
    private(set) var scanCounterInvariantViolations: Int = 0
    /// Per-root discovered counts for the CURRENT generation — feeds
    /// volumeProgress[].totalFiles at flush time.
    private var volumeDiscoveredInternal: [String: Int] = [:]

    /// True once every registered volume row has finished its walk — the
    /// denominator (scanTotal) is final and a percentage is meaningful.
    /// While ANY walk is still streaming URLs, discovered grows alongside
    /// completed and a percent would hover at ~99–100% for the entire scan
    /// (the "no way to gauge progress" flaw) — display a running processed
    /// count instead.
    var scanDiscoveryFinal: Bool {
        !volumeProgress.isEmpty && volumeProgress.allSatisfy { !$0.isWalking }
    }

    /// Progress fraction for display: nil while the denominator is still
    /// growing (walk in progress) — the UI must show a count + "finding
    /// files…" indicator instead of a percentage. Deliberately UNCLAMPED:
    /// if the counter invariant ever breaks again, the UI shows >100%
    /// instead of silently masking it.
    var scanDisplayFraction: Double? {
        guard scanDiscoveryFinal, scanTotal > 0 else { return nil }
        return Double(scanCompleted) / Double(scanTotal)
    }

    /// Register (or re-register) a volume row at walk start. Replaces any
    /// stale row for the same root and zeroes its internal discovery count.
    /// Pass `knownTotal` when the denominator is already final (resumed
    /// scans re-verify a fixed checkpoint list — there is no walk).
    func beginVolumeWalk(volumeRoot: String, volumeName: String,
                         generation: UInt64, knownTotal: Int? = nil) {
        guard generation == scanGeneration else { return }
        volumeProgress.removeAll { $0.rootPath == volumeRoot }
        var vp = VolumeProgress(rootPath: volumeRoot, volumeName: volumeName)
        if let knownTotal {
            vp.isWalking = false
            vp.totalFiles = knownTotal
        }
        volumeProgress.append(vp)
        volumeDiscoveredInternal[volumeRoot] = 0
    }

    /// One file discovered. MUST be called strictly BEFORE the file's probe
    /// is enqueued (synchronously, same actor turn) so no completion can
    /// ever precede its discovery increment.
    func recordFileDiscovered(volumeRoot: String, generation: UInt64) {
        guard generation == scanGeneration else { return }
        scanDiscoveredInternal += 1
        volumeDiscoveredInternal[volumeRoot, default: 0] += 1
        pendingVolumeTotalDirty.insert(volumeRoot)
        noteScanProgressEvent()
    }

    /// One probe finished. Stale generations (probes enqueued before the
    /// last resetForScan) are dropped — their discovery increments were
    /// wiped by the reset, so counting them would break the invariant.
    func recordProbeCompletion(volumeRoot: String, wasCacheHit: Bool,
                               isProbeError: Bool, streamTypeRaw: String,
                               generation: UInt64) {
        guard generation == scanGeneration else { return }
        scanCompletedInternal += 1
        if scanCompletedInternal > scanDiscoveredInternal {
            scanCounterInvariantViolations += 1
            catalogLog.write("⚠️ SCAN COUNTER INVARIANT VIOLATION: completed \(scanCompletedInternal) > discovered \(scanDiscoveredInternal) (generation \(scanGeneration)) — a completion was counted before its discovery increment")
            if !TestEnvironment.isTestHost {
                assertionFailure("scan counter invariant violated: completed \(scanCompletedInternal) > discovered \(scanDiscoveredInternal)")
            }
        }
        pendingCompletedByVolume[volumeRoot, default: 0] += 1
        if wasCacheHit {
            pendingCacheHits += 1
            pendingCacheHitsByVolume[volumeRoot, default: 0] += 1
        } else {
            pendingCacheMisses += 1
        }
        if isProbeError {
            pendingErrors += 1
            pendingErrorsByVolume[volumeRoot, default: 0] += 1
        }
        pendingStreamCounts[streamTypeRaw, default: 0] += 1
        noteScanProgressEvent()
    }

    /// The walk for `volumeRoot` finished streaming — the denominator is
    /// final. Publishes immediately (once per volume, not high-frequency).
    func markVolumeWalkComplete(volumeRoot: String, totalFiles: Int, generation: UInt64) {
        guard generation == scanGeneration else { return }
        flushScanProgress()
        if let idx = volumeProgress.firstIndex(where: { $0.rootPath == volumeRoot }) {
            volumeProgress[idx].isWalking = false
            volumeProgress[idx].totalFiles = totalFiles
        }
        if scanTotal != scanDiscoveredInternal { scanTotal = scanDiscoveredInternal }
    }

    @Published var scanPhase: ScanPhase = .idle
    @Published var volumeProgress: [VolumeProgress] = []
    @Published var scanCacheHits: Int = 0
    @Published var scanCacheMisses: Int = 0
    @Published var scanErrors: Int = 0
    @Published var liveStreamCounts: [String: Int] = [:]
    @Published var throughputSamples: [ThroughputSample] = []

    /// Live "what is the scanner touching right now" — fed from VideoScanModel
    /// at the probe site so the Realtime Catalog Scan window can paint a
    /// running ticker of activity. Kept short on purpose.
    @Published var scanCurrentFile: String = ""
    @Published var scanCurrentVolume: String = ""
    @Published var scanRecentFiles: [String] = []
    private let maxRecentFiles = 14

    // Scan-progress batching (2026-07-02 feedback-storm fix): recordScanFile
    // used to hit three @Published setters PER SCANNED FILE. During the
    // 14.5h RicksBackups crawl every probe poked objectWillChange, every
    // poke invalidated the toolbar chrome, and (pre DossierToolbarChip
    // cache) every invalidation recounted the 90k-record catalog — the scan
    // starved itself through its own UI. Per-file updates now land in the
    // non-published pending state below and flush at ≤4 Hz OR every 50
    // files, whichever comes first, plus a guaranteed trailing flush so the
    // last file always lands after the burst ends. Pinned by
    // ScanProgressBatchingTests.
    private var pendingScanVolume: String?
    private var pendingScanFile: String?
    private var pendingRecentFiles: [String] = []
    private var pendingScanFileEvents = 0
    private var scanProgressFlushScheduled = false
    private var lastScanProgressFlush: TimeInterval = -.greatestFiniteMagnitude
    private static let scanProgressFlushInterval: TimeInterval = 0.25  // ≤4 Hz
    private static let scanProgressFlushFileCount = 50

    // Pending counter aggregates (item-4 leg-2, 2026-07-03): probeAndRecord's
    // per-file counter block used to hit @Published setters directly — the
    // same storm shape recordScanFile had. Completion/discovery events now
    // accumulate here and ride the SAME flush machinery above.
    private var pendingCacheHits = 0
    private var pendingCacheMisses = 0
    private var pendingErrors = 0
    private var pendingStreamCounts: [String: Int] = [:]
    private var pendingCompletedByVolume: [String: Int] = [:]
    private var pendingCacheHitsByVolume: [String: Int] = [:]
    private var pendingErrorsByVolume: [String: Int] = [:]
    private var pendingVolumeTotalDirty: Set<String> = []

    /// - Parameter generation: when non-nil, the call is dropped unless it
    ///   matches the current scan generation (stale stragglers must not
    ///   repaint the ticker after a reset). Nil (the pre-existing surface)
    ///   applies unconditionally.
    func recordScanFile(volume: String, filename: String, generation: UInt64? = nil) {
        if let generation, generation != scanGeneration { return }
        pendingScanVolume = volume
        pendingScanFile = filename
        pendingRecentFiles.append(filename)
        if pendingRecentFiles.count > maxRecentFiles {
            pendingRecentFiles.removeFirst(pendingRecentFiles.count - maxRecentFiles)
        }
        noteScanProgressEvent()
    }

    /// Shared throttle: flush immediately at the event/interval thresholds,
    /// otherwise guarantee a trailing flush within one window so the final
    /// event always publishes (scan end, stop, or a stalling probe).
    private func noteScanProgressEvent() {
        pendingScanFileEvents += 1
        let now = ProcessInfo.processInfo.systemUptime
        if pendingScanFileEvents >= Self.scanProgressFlushFileCount
            || now - lastScanProgressFlush >= Self.scanProgressFlushInterval {
            flushScanProgress()
        } else if !scanProgressFlushScheduled {
            scanProgressFlushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.scanProgressFlushScheduled = false
                self?.flushScanProgress()
            }
        }
    }

    /// Publish any pending scan-progress state now. Safe to call at any
    /// time — no-ops when nothing is pending, so a trailing flush that
    /// fires after `resetForScan()` cannot resurrect stale state.
    ///
    /// COUNTER CONSISTENCY: scanTotal and scanCompleted are published from
    /// the authoritative internals in the SAME flush, so the published pair
    /// can lag but never disagree (published completed ≤ published total as
    /// long as the internals hold the invariant — which the seam enforces).
    func flushScanProgress() {
        guard pendingScanFileEvents > 0 else { return }
        lastScanProgressFlush = ProcessInfo.processInfo.systemUptime
        pendingScanFileEvents = 0
        if let vol = pendingScanVolume, vol != scanCurrentVolume {
            scanCurrentVolume = vol
        }
        if let file = pendingScanFile {
            scanCurrentFile = file
        }
        pendingScanVolume = nil
        pendingScanFile = nil
        if !pendingRecentFiles.isEmpty {
            scanRecentFiles.append(contentsOf: pendingRecentFiles)
            pendingRecentFiles.removeAll(keepingCapacity: true)
            if scanRecentFiles.count > maxRecentFiles {
                scanRecentFiles.removeFirst(scanRecentFiles.count - maxRecentFiles)
            }
        }

        flushPendingCounters()
        flushPendingVolumeRows()
    }

    /// Publish the batched top-line counters — only setters that actually
    /// moved fire objectWillChange.
    private func flushPendingCounters() {
        if scanTotal != scanDiscoveredInternal { scanTotal = scanDiscoveredInternal }
        if scanCompleted != scanCompletedInternal { scanCompleted = scanCompletedInternal }
        if pendingCacheHits > 0 { scanCacheHits += pendingCacheHits; pendingCacheHits = 0 }
        if pendingCacheMisses > 0 { scanCacheMisses += pendingCacheMisses; pendingCacheMisses = 0 }
        if pendingErrors > 0 { scanErrors += pendingErrors; pendingErrors = 0 }
        if !pendingStreamCounts.isEmpty {
            for (key, delta) in pendingStreamCounts {
                liveStreamCounts[key, default: 0] += delta
            }
            pendingStreamCounts.removeAll(keepingCapacity: true)
        }
    }

    /// Apply the batched per-volume deltas — one volumeProgress publish for
    /// the whole batch.
    private func flushPendingVolumeRows() {
        guard !pendingCompletedByVolume.isEmpty || !pendingCacheHitsByVolume.isEmpty
            || !pendingErrorsByVolume.isEmpty || !pendingVolumeTotalDirty.isEmpty else { return }
        var rows = volumeProgress
        for idx in rows.indices {
            let root = rows[idx].rootPath
            if let delta = pendingCompletedByVolume[root] { rows[idx].completedFiles += delta }
            if let delta = pendingCacheHitsByVolume[root] { rows[idx].cacheHits += delta }
            if let delta = pendingErrorsByVolume[root] { rows[idx].errors += delta }
            if pendingVolumeTotalDirty.contains(root), rows[idx].isWalking,
               let total = volumeDiscoveredInternal[root] {
                rows[idx].totalFiles = total
            }
        }
        volumeProgress = rows
        pendingCompletedByVolume.removeAll(keepingCapacity: true)
        pendingCacheHitsByVolume.removeAll(keepingCapacity: true)
        pendingErrorsByVolume.removeAll(keepingCapacity: true)
        pendingVolumeTotalDirty.removeAll(keepingCapacity: true)
    }

    // MARK: - Network Prefetch Stats

    @Published var netPrefetchCount: Int = 0
    @Published var netPrefetchTotalMB: Double = 0
    @Published var netPrefetchTotalSeconds: Double = 0
    @Published var netPrefetchLastMBps: Double = 0

    /// Record a single network→RAM disk prefetch completion.
    func recordNetworkPrefetch(megabytesCopied mb: Double, seconds: Double) {
        netPrefetchCount += 1
        netPrefetchTotalMB += mb
        netPrefetchTotalSeconds += seconds
        netPrefetchLastMBps = seconds > 0 ? mb / seconds : 0
    }

    // MARK: - Combine Progress

    @Published var combineTotal: Int = 0
    @Published var combineCompleted: Int = 0
    var combineStartTime: Date?
    @Published var combineCurrentFile: String = ""
    @Published var combineSucceeded: Int = 0
    @Published var combineFailed: Int = 0
    @Published var combineSkipped: Int = 0

    // MARK: - Relocate Progress

    @Published var relocateTotal: Int = 0
    @Published var relocateCompleted: Int = 0
    @Published var relocateSucceeded: Int = 0
    @Published var relocateSalvageFailed: Int = 0
    @Published var relocateManuallyDeleted: Int = 0
    @Published var relocateAdopted: Int = 0
    @Published var relocateSourceMoves: Int = 0
    @Published var relocateSkipped: Int = 0
    /// Records classified as "same content exists on a third volume" by the
    /// new safelyRedundant rule. These are marked .manuallyDeleted with an
    /// audit-trail note carrying the witness list; the source file is never
    /// touched. See VideoScanModel+Relocate.swift §1A.
    @Published var relocateSafelyRedundant: Int = 0
    /// Sum of sizeBytes across safelyRedundant records. Surfaced in the UI
    /// disclosure under the toggle and in the end-of-batch summary as the
    /// "MB not copied" savings figure.
    @Published var relocateSafelyRedundantBytes: Int64 = 0
    @Published var relocateBytesCopied: Int64 = 0
    @Published var relocateCurrentFile: String = ""
    var relocateStartTime: Date?

    func resetForRelocate(total: Int) {
        relocateTotal = total
        relocateCompleted = 0
        relocateSucceeded = 0
        relocateSalvageFailed = 0
        relocateManuallyDeleted = 0
        relocateAdopted = 0
        relocateSourceMoves = 0
        relocateSkipped = 0
        relocateSafelyRedundant = 0
        relocateSafelyRedundantBytes = 0
        relocateBytesCopied = 0
        relocateCurrentFile = ""
        relocateStartTime = Date()
    }

    // MARK: - Throughput Timer

    private var throughputTimer: Timer?
    private var lastSampleCompleted: Int = 0
    private var lastSampleTime: Date = Date()
    private let maxThroughputSamples = 120

    func startThroughputTimer() {
        lastSampleCompleted = scanCompleted
        lastSampleTime = Date()
        throughputSamples = []
        throughputTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                let delta = self.scanCompleted - self.lastSampleCompleted
                let elapsed = now.timeIntervalSince(self.lastSampleTime)
                let fps = elapsed > 0 ? Double(delta) / elapsed : 0
                self.throughputSamples.append(ThroughputSample(timestamp: now, filesPerSecond: fps))
                if self.throughputSamples.count > self.maxThroughputSamples {
                    self.throughputSamples.removeFirst(self.throughputSamples.count - self.maxThroughputSamples)
                }
                self.lastSampleCompleted = self.scanCompleted
                self.lastSampleTime = now
            }
        }
    }

    func stopThroughputTimer() {
        throughputTimer?.invalidate()
        throughputTimer = nil
        // Scan-end funnel: make the final batched file/volume visible
        // immediately rather than waiting out the trailing flush window.
        flushScanProgress()
    }

    // MARK: - System Metrics (always-on)

    @Published var memUsedGB: Double = 0
    @Published var memTotalGB: Double = 0
    @Published var appMemoryMB: Double = 0
    @Published var cpuLoad1: Double = 0
    @Published var cpuLoad5: Double = 0
    @Published var cpuLoad15: Double = 0
    @Published var thermalLabel: String = "Normal"
    @Published var thermalWarning: Bool = false

    // Vision/ANE metrics — updated by PersonFinderModel during scans
    @Published var visionFPS: Double = 0
    @Published var visionMsPerFrame: Double = 0
    @Published var visionWorkers: Int = 0
    @Published var visionActive: Bool = false
    @Published var activeEngineLabel: String = "Vision / ANE"

    private var systemMetricsTimer: Timer?

    func startSystemMetrics() {
        memTotalGB = totalPhysicalMemoryGB()
        pollSystemMetrics()
        systemMetricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollSystemMetrics()
            }
        }
    }

    func stopSystemMetrics() {
        systemMetricsTimer?.invalidate()
        systemMetricsTimer = nil
    }

    private func pollSystemMetrics() {
        memUsedGB = usedMemoryGB()
        appMemoryMB = processResidentMemoryMB()
        let load = systemCPULoadAverage()
        cpuLoad1 = load.one
        cpuLoad5 = load.five
        cpuLoad15 = load.fifteen
        let thermal = systemThermalState()
        thermalLabel = thermal.label
        thermalWarning = thermal.isWarning
    }

    // MARK: - Reset

    func resetForScan() {
        catalogLog.start()
        consoleLines = []
        pendingLines.removeAll()
        flushScheduled = false
        // New scan generation FIRST: any straggler probe still in flight
        // from the previous scan carries the old stamp and is dropped at
        // the counter seam instead of corrupting the fresh counters.
        scanGeneration &+= 1
        scanDiscoveredInternal = 0
        scanCompletedInternal = 0
        volumeDiscoveredInternal.removeAll()
        scanTotal = 0
        scanCompleted = 0
        scanStartTime = Date()
        scanPhase = .idle
        volumeProgress = []
        scanCacheHits = 0
        scanCacheMisses = 0
        scanErrors = 0
        liveStreamCounts = [:]
        throughputSamples = []
        scanCurrentFile = ""
        scanCurrentVolume = ""
        scanRecentFiles = []
        // Drop pending batched progress too, or a trailing flush scheduled
        // before this reset would resurrect pre-reset state.
        pendingScanVolume = nil
        pendingScanFile = nil
        pendingRecentFiles.removeAll()
        pendingScanFileEvents = 0
        lastScanProgressFlush = -.greatestFiniteMagnitude
        pendingCacheHits = 0
        pendingCacheMisses = 0
        pendingErrors = 0
        pendingStreamCounts.removeAll()
        pendingCompletedByVolume.removeAll()
        pendingCacheHitsByVolume.removeAll()
        pendingErrorsByVolume.removeAll()
        pendingVolumeTotalDirty.removeAll()
        netPrefetchCount = 0
        netPrefetchTotalMB = 0
        netPrefetchTotalSeconds = 0
        netPrefetchLastMBps = 0
    }

    func resetForCombine(total: Int) {
        combineTotal = total
        combineCompleted = 0
        combineStartTime = Date()
        combineCurrentFile = ""
        combineSucceeded = 0
        combineFailed = 0
        combineSkipped = 0
        combineJobs = []
    }

    // MARK: - Per-Job Combine Tracking

    @Published var combineJobs: [CombineJobStatus] = []
}

// MARK: - CombineJobStatus

struct CombineJobStatus: Identifiable {
    let id = UUID()
    let pairIndex: Int
    let videoFilename: String
    let audioFilename: String
    let outputFilename: String
    let outputPath: String
    let videoSizeBytes: Int64
    let audioSizeBytes: Int64
    let totalDurationSeconds: Double
    let videoOnline: Bool
    let audioOnline: Bool
    var technique: CombineTechnique = .streamCopy
    var phase: CombinePhase = .queued
    var startTime: Date?
    var endTime: Date?
    var progressFraction: Double = 0
    var isPaused: Bool = false
    var warningMessage: String?

    var estimatedBytes: Int64 { videoSizeBytes + audioSizeBytes }
    var bothOnline: Bool { videoOnline && audioOnline }

    var elapsed: TimeInterval? {
        guard let start = startTime else { return nil }
        return (endTime ?? Date()).timeIntervalSince(start)
    }

    enum CombineTechnique: String {
        case streamCopy = "Stream Copy"
        case reencodeProRes = "Re-encode → ProRes"
        case reencodeH264 = "Re-encode → H.264"
    }

    enum CombinePhase: String {
        case queued = "Queued"
        case buffering = "Buffering"
        case muxing = "Muxing"
        case verifying = "Verifying"
        case done = "Verified"
        case failed = "Failed"
        case skipped = "Already Combined"
    }
}
