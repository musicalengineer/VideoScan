import Foundation
import SwiftUI
import Combine

/// Separate ObservableObject for high-frequency dashboard and console updates.
/// Isolating these from VideoScanModel prevents the main Table view from
/// re-rendering on every console line or dashboard counter change.
@MainActor
final class DashboardState: ObservableObject {

    // MARK: - Console

    @Published var consoleLines: [String] = []
    private let maxConsoleLines = 2000
    private var pendingLines: [String] = []
    private var flushScheduled = false

    func log(_ msg: String) {
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

    // MARK: - Reset

    func resetForScan() {
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
