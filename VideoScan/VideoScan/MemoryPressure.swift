import Foundation
import Darwin.Mach

// MARK: - Memory Pressure Monitor

/// Monitors system memory pressure and provides a cooperative pause gate.
/// When available RAM drops below a threshold, active scans auto-pause
/// until memory recovers. Also supports manual pause/resume.
actor MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    /// Minimum available RAM (bytes) before auto-pause triggers.
    /// Configurable via ScanPerformanceSettings.memoryFloorGB.
    private(set) var lowMemoryThreshold: UInt64 = 4 * 1024 * 1024 * 1024

    /// Hysteresis: resume when available RAM exceeds threshold + 1 GB.
    private var resumeThreshold: UInt64 { lowMemoryThreshold + 1 * 1024 * 1024 * 1024 }

    /// Update the memory floor (call when settings change).
    func setFloorGB(_ gb: Int) {
        lowMemoryThreshold = UInt64(gb) * 1024 * 1024 * 1024
    }

    func thresholdBytes() -> UInt64 {
        lowMemoryThreshold
    }

    private(set) var isMemoryLow = false

    /// Returns available physical memory in bytes using Mach VM statistics.
    nonisolated func availableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
    }

    /// Check memory and return true if pressure is high.
    func checkPressure() -> Bool {
        let avail = availableMemory()
        if avail < lowMemoryThreshold {
            if !isMemoryLow {
                isMemoryLow = true
                NSLog("Memory pressure HIGH — available: %llu MB, threshold: %llu MB",
                      avail / (1024*1024), lowMemoryThreshold / (1024*1024))
            }
            return true
        } else if avail > resumeThreshold {
            if isMemoryLow {
                isMemoryLow = false
                NSLog("Memory pressure resolved — available: %llu MB", avail / (1024*1024))
            }
        }
        return isMemoryLow
    }

    // Global count of active scan workers across all jobs.
    // Each worker increments on start and decrements on finish so that
    // recommendedConcurrency can account for already-running work.
    private var activeWorkers: Int = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    func incrementWorkers() { activeWorkers += 1 }
    func decrementWorkers() {
        activeWorkers = max(0, activeWorkers - 1)
        resumeWaitersIfPossible()
    }
    func currentWorkers() -> Int { activeWorkers }

    func workerBudgetMB(for engine: RecognitionEngine) -> Int {
        switch engine {
        case .vision:
            return 3072
        case .arcface:
            return 2048   // CoreML model ~200MB + Vision detection overhead
        case .dlib:
            return 1024
        case .hybrid:
            // Hybrid does a Vision pass and may then do a dlib fallback;
            // size to the larger of the two so a fallback never OOMs.
            return 3072
        }
    }

    private func hardCap(requested: Int, engine: RecognitionEngine) -> Int {
        switch engine {
        case .vision:
            return min(requested, max(1, ProcessInfo.processInfo.processorCount))
        case .arcface:
            // CoreML handles its own ANE scheduling; allow moderate parallelism
            return min(requested, max(1, ProcessInfo.processInfo.processorCount))
        case .dlib:
            return min(requested, 4)
        case .hybrid:
            // Cap at the dlib limit so the fallback pass cannot blow the budget
            // when several videos miss on Vision and converge on dlib at once.
            return min(requested, 4)
        }
    }

    private func bytesPerWorker(for engine: RecognitionEngine) -> UInt64 {
        UInt64(workerBudgetMB(for: engine)) * 1024 * 1024
    }

    private func canStartWorker(requested: Int, engine: RecognitionEngine) -> Bool {
        let requested = max(1, requested)
        let available = availableMemory()
        let reserve = lowMemoryThreshold + 2 * 1024 * 1024 * 1024
        let cap = hardCap(requested: requested, engine: engine)
        guard activeWorkers < cap else { return false }
        guard available > reserve else { return activeWorkers == 0 }

        let usable = available - reserve
        let memoryBound = max(1, Int(usable / bytesPerWorker(for: engine)))
        return activeWorkers < memoryBound
    }

    /// Reserve a worker slot atomically so parallel jobs do not all claim the
    /// same free-memory budget at once.
    func acquireWorkerSlot(requested: Int, engine: RecognitionEngine) async {
        while !canStartWorker(requested: requested, engine: engine) {
            await withCheckedContinuation { cont in
                slotWaiters.append(cont)
            }
        }
        activeWorkers += 1
    }

    private func resumeWaitersIfPossible() {
        guard !slotWaiters.isEmpty else { return }
        let pending = slotWaiters
        slotWaiters.removeAll()
        for cont in pending {
            cont.resume()
        }
    }

    /// Recommend a safe parallelism level based on current free RAM.
    /// Keeps a reserve above the configured floor instead of using all memory.
    /// Accounts for workers already running across all jobs.
    func recommendedConcurrency(requested: Int, engine: RecognitionEngine) -> Int {
        let requested = max(1, requested)
        let available = availableMemory()
        let reserve = lowMemoryThreshold + 2 * 1024 * 1024 * 1024
        guard available > reserve else { return 1 }

        let usable = available - reserve
        let hardCap = hardCap(requested: requested, engine: engine)
        let memoryBound = max(1, Int(usable / bytesPerWorker(for: engine)))
        // Subtract workers already running globally so concurrent jobs
        // don't each assume they have the full memory budget.
        let available_slots = max(1, memoryBound - activeWorkers)
        return max(1, min(requested, hardCap, available_slots))
    }

    /// Formatted string of current available memory.
    nonisolated func availableMemoryString() -> String {
        let mb = availableMemory() / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }
}

// MARK: - System Metrics Helpers

/// CPU load averages (1, 5, 15 minute) — no sudo required.
func systemCPULoadAverage() -> (one: Double, five: Double, fifteen: Double) {
    var loadavg = [Double](repeating: 0, count: 3)
    getloadavg(&loadavg, 3)
    return (loadavg[0], loadavg[1], loadavg[2])
}

/// Current process resident memory in MB — no sudo required.
func processResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / (1024 * 1024)
}

/// System thermal state as a user-facing label + color hint.
func systemThermalState() -> (label: String, isWarning: Bool) {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:  return ("Normal", false)
    case .fair:     return ("Fair", false)
    case .serious:  return ("Serious", true)
    case .critical: return ("Critical", true)
    @unknown default: return ("Unknown", false)
    }
}

/// Total physical memory in GB.
func totalPhysicalMemoryGB() -> Double {
    Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
}

/// Used physical memory in GB (total - available).
func usedMemoryGB() -> Double {
    let available = Double(MemoryPressureMonitor.shared.availableMemory()) / (1024 * 1024 * 1024)
    return totalPhysicalMemoryGB() - available
}

// MARK: - Pause Gate

/// Cooperative pause gate for structured concurrency.
/// Tasks call `waitIfPaused()` at safe checkpoints. When paused,
/// they suspend until resumed — no teardown, no resource leaks.
actor PauseGate {
    private var _isPaused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var autoPauseEnabled = true
    private var autoPaused = false

    var isPaused: Bool { _isPaused }

    /// Pause all tasks waiting on this gate.
    func pause() {
        _isPaused = true
        autoPaused = false
    }

    /// Resume all waiting tasks.
    func resume() {
        _isPaused = false
        autoPaused = false
        let pending = waiters
        waiters.removeAll()
        for cont in pending {
            cont.resume()
        }
    }

    /// Toggle pause state. Returns new state.
    @discardableResult
    func toggle() -> Bool {
        if _isPaused { resume() } else { pause() }
        return _isPaused
    }

    /// Enable/disable auto-pause from memory pressure.
    func setAutoPause(_ enabled: Bool) {
        autoPauseEnabled = enabled
    }

    /// Called by tasks at safe checkpoints (between videos, between probes).
    /// Suspends if paused; returns immediately if not.
    /// Also checks memory pressure and auto-pauses if needed.
    func waitIfPaused() async {
        // Check memory pressure if auto-pause is enabled
        if autoPauseEnabled && !_isPaused {
            let pressureHigh = await MemoryPressureMonitor.shared.checkPressure()
            if pressureHigh {
                _isPaused = true
                autoPaused = true
                // Notify on main actor that we auto-paused
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .memoryPressureAutoPause,
                        object: nil,
                        userInfo: ["available": MemoryPressureMonitor.shared.availableMemory()]
                    )
                }
            }
        }

        guard _isPaused else { return }

        if autoPaused {
            while _isPaused {
                let stillHigh = await MemoryPressureMonitor.shared.checkPressure()
                if !stillHigh {
                    resume()
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return
        }

        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }
}

// MARK: - Throttled MainActor Update

/// Coalesces frequent MainActor dispatches to a maximum rate.
/// Used to prevent UI beachball when many concurrent tasks all want
/// to update progress/frames on the main thread.
actor ThrottledMainActorUpdate {
    private let interval: TimeInterval
    private var lastUpdate: CFAbsoluteTime = 0

    init(intervalSecs: TimeInterval = 0.25) {
        self.interval = intervalSecs
    }

    /// Execute `block` on MainActor only if enough time has passed since the last update.
    /// Skipped updates are silently dropped — the next one that fires will have current data.
    func update(_ block: @MainActor @Sendable () -> Void) async {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastUpdate >= interval else { return }
        lastUpdate = now
        await MainActor.run { block() }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let memoryPressureAutoPause = Notification.Name("memoryPressureAutoPause")
}
