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
        startSystemMetrics()
    }

    // MARK: - Chip identity / match flash

    @Published var chipName: String = ""
    @Published var lastMatchFlashAt: Date? = nil

    private static func detectChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Apple Silicon" : s
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
    var scanStartTime: Date? = nil

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

    func recordScanFile(volume: String, filename: String) {
        scanCurrentVolume = volume
        scanCurrentFile = filename
        scanRecentFiles.append(filename)
        if scanRecentFiles.count > maxRecentFiles {
            scanRecentFiles.removeFirst(scanRecentFiles.count - maxRecentFiles)
        }
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
    var combineStartTime: Date? = nil
    @Published var combineCurrentFile: String = ""
    @Published var combineSucceeded: Int = 0
    @Published var combineFailed: Int = 0

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
    }
}
