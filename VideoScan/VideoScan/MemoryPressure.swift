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
    /// Parked acquireWorkerSlot callers, keyed by a per-wait id so a
    /// cancelled waiter can remove and resume exactly its own continuation.
    private var slotWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextSlotWaiterID: UInt64 = 0

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
            // The ArcFace model is shared and CoreML/ANE scheduling owns most
            // transient memory. The previous 2 GB estimate collapsed scans to
            // one worker on high-reserve systems despite tens of GB free.
            return 768
        case .adaface:
            // Same CoreML profile as ArcFace: ~85 MB fp16 weights per worker
            // plus transient ANE scheduling (#144).
            return 768
        case .hybrid:
            // Hybrid does a Vision pass and may then do an AdaFace fallback;
            // size to the larger of the two so a fallback never OOMs.
            return 3072
        }
    }

    private func hardCap(requested: Int, engine: RecognitionEngine) -> Int {
        switch engine {
        case .vision:
            return min(requested, max(1, ProcessInfo.processInfo.processorCount))
        case .arcface, .adaface:
            // CoreML handles its own ANE scheduling; allow moderate parallelism
            return min(requested, max(1, ProcessInfo.processInfo.processorCount))
        case .hybrid:
            // Both passes (Vision, AdaFace fallback) tolerate full-width
            // parallelism; the old min(4) cap existed only for the dlib
            // Python subprocesses that no longer run here (#144).
            return min(requested, max(1, ProcessInfo.processInfo.processorCount))
        }
    }

    private func bytesPerWorker(for engine: RecognitionEngine) -> UInt64 {
        UInt64(workerBudgetMB(for: engine)) * 1024 * 1024
    }

    private func canStartWorker(requested: Int, engine: RecognitionEngine) -> Bool {
        let requested = max(1, requested)
        let available = availableMemory()
        let reserve = lowMemoryThreshold + 1 * 1024 * 1024 * 1024
        let cap = hardCap(requested: requested, engine: engine)
        guard activeWorkers < cap else { return false }
        guard available > reserve else { return activeWorkers == 0 }

        let usable = available - reserve
        let memoryBound = max(1, Int(usable / bytesPerWorker(for: engine)))
        return activeWorkers < memoryBound
    }

    /// Reserve a worker slot atomically so parallel jobs do not all claim the
    /// same free-memory budget at once.
    ///
    /// Returns `true` when a slot was taken — the caller then owes exactly
    /// one `decrementWorkers()`. Returns `false` when the calling task was
    /// cancelled before a slot came free (or on entry); nothing was taken
    /// and nothing must be decremented.
    ///
    /// Cancellation (night QA 2026-09-25): a waiter used to park on a plain
    /// continuation that only `decrementWorkers()` released, so a Person
    /// Finder job the user Stopped sat until ANOTHER job's worker finished a
    /// video — then took a slot anyway. C++ analogy: a condition-variable
    /// wait whose predicate now includes a stop_token.
    @discardableResult
    func acquireWorkerSlot(requested: Int, engine: RecognitionEngine) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            if canStartWorker(requested: requested, engine: engine) {
                activeWorkers += 1
                return true
            }
            let id = nextSlotWaiterID
            nextSlotWaiterID &+= 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Runs synchronously on this actor. A task cancelled
                    // before this point never parks: its onCancel hop (if
                    // it already fired) found no entry to resume.
                    if Task.isCancelled {
                        cont.resume()
                    } else {
                        slotWaiters[id] = cont
                    }
                }
            } onCancel: {
                Task { await self.cancelSlotWaiter(id) }
            }
        }
    }

    /// Release one cancelled waiter (no-op if it was already woken).
    private func cancelSlotWaiter(_ id: UInt64) {
        slotWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeWaitersIfPossible() {
        guard !slotWaiters.isEmpty else { return }
        let pending = slotWaiters.values
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
        let reserve = lowMemoryThreshold + 1 * 1024 * 1024 * 1024
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

/// Who is holding a PauseGate paused. The gate is paused while ANY reason is
/// held; each owner adds and removes only its own.
///
/// Why a set and not a Bool (night QA 2026-09-25, M2): the gate used to have
/// one `_isPaused` flag with three owners, so any owner's resume undid the
/// others' pauses — memory relief resumed a Combine the user had paused
/// under "Resume All"; a network share coming back resumed a scan the user
/// had paused; a user Resume cleared an active memory pause.
/// C++ analogy: a std::bitset of hold reasons instead of a single bool.
enum PauseReason: String, Sendable, Hashable, CaseIterable {
    /// The Pause/Resume buttons — the public `pause()` / `resume()`.
    case user
    /// The gate's own memory auto-pause (`waitIfPaused` sets and clears it).
    case memory
    /// VolumeKeepalive: the scanned network volume is unreachable.
    case volume
}

/// Cooperative pause gate for structured concurrency.
/// Tasks call `waitIfPaused()` at safe checkpoints. When paused,
/// they suspend until resumed — no teardown, no resource leaks.
actor PauseGate {
    private var reasons: Set<PauseReason> = []
    /// Parked waiters, keyed by a per-wait id so a cancelled waiter can
    /// remove and resume exactly its own continuation.
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID: UInt64 = 0
    private var autoPauseEnabled: Bool

    /// How the gate asks "is memory low right now?". Production always uses
    /// the process-wide MemoryPressureMonitor; tests inject a fixed answer so
    /// they neither depend on the host's free RAM (a 7 GB CI runner sits
    /// under the 4 GB floor) nor poison the shared monitor for other suites.
    /// C++ analogy: a std::function<bool()> strategy member with a default.
    private let pressureCheck: @Sendable () async -> Bool

    /// How long the auto-pause loop sleeps between memory re-checks.
    private let recheckInterval: Duration

    /// The production reading: the shared monitor against the configured floor.
    static let hostPressureCheck: @Sendable () async -> Bool = {
        await MemoryPressureMonitor.shared.checkPressure()
    }

    /// Whether a gate auto-pauses on memory pressure when its creator did
    /// not say. The app: ON (unchanged). A test host: OFF.
    ///
    /// Why a test-host default rather than one opt-out per suite
    /// (2026-09-25, CI run 36192353105): every gate the app creates — the
    /// Combine gate, each CatalogScanTarget's scan gate, the Person Finder
    /// gates — reads the HOST's free RAM against a 4 GB floor. The GitHub
    /// runner has ~7 GB with ~2 GB free, so ANY test that drives one of
    /// those pipelines auto-paused on its first checkpoint and waited for
    /// memory that never came: CombineNeverOverwritesTests one day,
    /// tripAcrossCountryShapeCatalogsExactlyTheValidMedia the next (a scan's
    /// probe child waits on its target's gate). Opting out suite by suite
    /// only fixes the suites someone has already watched hang. Host RAM is
    /// environment, not the unit under test; the gate's auto-pause logic is
    /// tested with an injected reading and an explicit `autoPause: true`
    /// (PauseGateCancellationTests, PauseGateTestHostDefaultTests).
    /// Pure so both branches are testable. C++ analogy: a constexpr policy
    /// function the constructor consults when the caller passes std::nullopt.
    nonisolated static func defaultAutoPause(isTestHost: Bool) -> Bool {
        !isTestHost
    }

    /// - Parameter autoPause: `nil` = `defaultAutoPause(isTestHost:)` for this
    ///   process (on in the app, off in a test host); `true`/`false` = explicit.
    ///   `setAutoPause(_:)` still overrides later.
    init(pressureCheck: @escaping @Sendable () async -> Bool = PauseGate.hostPressureCheck,
         recheckInterval: Duration = .milliseconds(500),
         autoPause: Bool? = nil) {
        self.pressureCheck = pressureCheck
        self.recheckInterval = recheckInterval
        self.autoPauseEnabled = autoPause
            ?? Self.defaultAutoPause(isTestHost: TestHostDetection.isTestHost)
    }

    /// Whether this gate currently consults memory pressure (for tests and
    /// diagnostics).
    var isAutoPauseEnabled: Bool { autoPauseEnabled }

    /// Paused for ANY reason (user, memory, volume).
    var isPaused: Bool { !reasons.isEmpty }

    /// Paused by the user's Pause button specifically.
    var isUserPaused: Bool { reasons.contains(.user) }

    /// Every reason currently holding the gate (diagnostics and tests).
    var pauseReasons: Set<PauseReason> { reasons }

    /// The user's Pause. Adds only the user reason.
    func pause() { pause(.user) }

    /// The user's Resume. Removes only the user reason: a gate still held
    /// by memory pressure or a down volume stays paused until THAT owner
    /// releases it. Also wakes every parked waiter so a cancelled one (a
    /// Stop path: cancel, then resume()) re-checks and returns.
    func resume() { resume(.user) }

    /// Add one owner's reason. Idempotent.
    func pause(_ reason: PauseReason) {
        reasons.insert(reason)
    }

    /// Remove one owner's reason and wake parked waiters to re-evaluate —
    /// they return if the gate is now open (or they were cancelled and no
    /// user pause holds them), else they park again.
    func resume(_ reason: PauseReason) {
        reasons.remove(reason)
        wakeAllWaiters()
    }

    /// Toggle the USER pause. Returns the new user-pause state.
    @discardableResult
    func toggle() -> Bool {
        if reasons.contains(.user) { resume() } else { pause() }
        return reasons.contains(.user)
    }

    /// Enable/disable auto-pause from memory pressure.
    func setAutoPause(_ enabled: Bool) {
        autoPauseEnabled = enabled
    }

    /// Called by tasks at safe checkpoints (between videos, between probes).
    /// Suspends if paused; returns immediately if not.
    /// Also checks memory pressure and auto-pauses if needed.
    ///
    /// While the MEMORY reason is held, waiters poll the pressure reading
    /// every `recheckInterval` and the first to see relief removes it; other
    /// reasons park the waiter until their owner's resume.
    ///
    /// Cancellation: a cancelled caller returns at once unless the USER
    /// pause is held (the caller re-checks Task.isCancelled after this
    /// call). Before 2026-09-25 the memory re-check loop used
    /// `try? await Task.sleep`, which swallows CancellationError and
    /// returns immediately — so a cancelled waiter hot-spun on the actor for
    /// as long as memory stayed low, and a Swift Testing time limit (which
    /// cancels, then awaits) could never end a test stuck here. A MANUAL
    /// pause still waits for resume() even when cancelled: Stop paths
    /// (stopCombine, stopTarget, …) cancel and then call resume(), which
    /// wakes the parked waiter to see its cancellation. A volume pause does
    /// NOT hold a cancelled waiter — Stop during an outage must end the scan.
    func waitIfPaused() async {
        // Check memory pressure if auto-pause is enabled
        if autoPauseEnabled && reasons.isEmpty {
            let pressureHigh = await pressureCheck()
            if pressureHigh {
                reasons.insert(.memory)
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

        while !reasons.isEmpty {
            let cancelled = Task.isCancelled
            if cancelled && !reasons.contains(.user) { return }

            if reasons.contains(.memory) && !cancelled {
                let stillHigh = await pressureCheck()
                if !stillHigh {
                    resume(.memory)
                    continue
                }
                do {
                    try await Task.sleep(for: recheckInterval)
                } catch {
                    // Task.sleep throws only CancellationError: the caller
                    // was stopped. Loop to the cancellation check above —
                    // it returns unless the user pause holds this waiter,
                    // in which case the waiter parks (never spins).
                    continue
                }
            } else {
                await park()
            }
        }
    }

    /// Suspend until the next resume(_:) wakes all waiters, or until this
    /// task is cancelled while no user pause is held.
    private func park() async {
        let id = nextWaiterID
        nextWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Runs synchronously on this actor, so it is ordered before
                // the onCancel hop below can reach cancelWaiter(_:).
                if Task.isCancelled && !reasons.contains(.user) {
                    cont.resume()
                } else {
                    waiters[id] = cont
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Release one cancelled waiter — unless the user pause holds it, in
    /// which case the Stop path's resume() will wake it.
    private func cancelWaiter(_ id: UInt64) {
        guard !reasons.contains(.user) else { return }
        waiters.removeValue(forKey: id)?.resume()
    }

    private func wakeAllWaiters() {
        guard !waiters.isEmpty else { return }
        let pending = waiters.values
        waiters.removeAll()
        for cont in pending {
            cont.resume()
        }
    }
}

// MARK: - Throttled MainActor Update
//
// ThrottledMainActorUpdate moved to VideoScanCore (2026-07-28) so the
// extracted preview-sweep engine can use it — logic verbatim, visibility
// widened to public. Referenced here (and by PersonFinder) via the app's
// @_exported import VideoScanCore.

// MARK: - Notification

extension Notification.Name {
    static let memoryPressureAutoPause = Notification.Name("memoryPressureAutoPause")
}
