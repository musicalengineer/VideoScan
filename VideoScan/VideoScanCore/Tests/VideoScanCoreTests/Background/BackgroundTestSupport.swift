// BackgroundTestSupport.swift — shared doubles for the Background suites.
//
// `RecordingJob` records which units ran and how many ran at once; the
// factory hands it out for kind "recording" and NoOpJob for "noop".

import Foundation
import Testing
@testable import VideoScanCore

final class UnitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [Int] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func begin() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func end(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        completed.append(index)
    }

    /// A unit that threw: it ran, but is not a COMPLETED unit.
    func abort() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }

    var completedUnits: [Int] {
        lock.lock(); defer { lock.unlock() }
        return completed
    }
}

struct RecordingJob: BackgroundJob {
    let title = "Recording job"
    let unitCount: Int
    let sleepPerUnit: Duration
    let recorder: UnitRecorder
    /// A unit index that never returns (simulates the unit a kill lands on).
    let hangAt: Int?
    /// Unit indices that throw.
    let failAt: Set<Int>
    /// Unit indices reported as skipped.
    let skipAt: Set<Int>

    func runUnit(_ index: Int) async throws -> UnitOutcome {
        recorder.begin()
        if index == hangAt {
            // Park until cancelled: the process "died" here.
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        if sleepPerUnit > .zero { try await Task.sleep(for: sleepPerUnit) }
        if failAt.contains(index) {
            recorder.abort()
            throw Refusal("unit \(index) refused on purpose")
        }
        recorder.end(index)
        return skipAt.contains(index) ? .skipped : .done
    }
}

struct RecordingFactory: JobFactory {
    static let kind = JobKind(rawValue: "recording")
    let recorder: UnitRecorder
    var units = 10
    var sleepPerUnit: Duration = .zero
    var hangAt: Int? = nil
    var failAt: Set<Int> = []
    var skipAt: Set<Int> = []

    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        switch request.kind {
        case Self.kind:
            return RecordingJob(unitCount: units, sleepPerUnit: sleepPerUnit, recorder: recorder,
                                hangAt: hangAt, failAt: failAt, skipAt: skipAt)
        case .noop:
            return try NoOpJob(request: request)
        default:
            throw Refusal("unknown kind \(request.kind)")
        }
    }

    static func request(lane: String = "default", id: JobID = JobID()) -> JobRequest {
        JobRequest(id: id, kind: kind, lane: lane, requestedBy: "test")
    }
}

enum BackgroundFixtures {
    static func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fullBackoff() -> Backoff {
        Backoff(source: FakeActivitySource(ActivitySample()))
    }

    static func fastConfiguration() -> JobSupervisor.Configuration {
        var c = JobSupervisor.Configuration()
        c.pausePollInterval = .milliseconds(10)
        return c
    }

    /// Polls until `condition` holds or the poller has been RUNNING for `timeout`.
    ///
    /// Only time this poller was actually scheduled is charged: a gap between two polls longer
    /// than `stallGrace` (asked to sleep 10 ms, woken seconds later) means the whole cooperative
    /// pool was busy elsewhere, and is charged at `stallGrace`. Measured 2026-11-18 on the M4:
    /// under `swift test --enable-code-coverage` (Debug, instrumented, 16 cores) the scale suites
    /// held every pool thread for ~50 s at the start of the run, and 16 Background tests failed
    /// "after 50–68 s" on a 5 s wait whose job needed three 5 ms units — the machine's wait,
    /// not the code's. A job that never finishes still fails: a poller that is scheduled
    /// promptly is charged in full (5 s), and `ceiling` (20 × timeout of wall clock) ends any wait.
    /// (C++: a watchdog that counts ticks it actually got, with a wall-clock backstop.)
    static func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        return await waitUntil(timeout, now: { clock.now - start },
                               sleep: { try? await Task.sleep(for: $0) }, condition)
    }

    static let stallGrace: Duration = .milliseconds(100)
    static let pollInterval: Duration = .milliseconds(10)

    /// The rule above with its clock and sleep injected (`now`: time since the wait began).
    static func waitUntil(_ timeout: Duration, now: @Sendable () -> Duration, sleep: @Sendable (Duration) async -> Void,
                          _ condition: @Sendable () async -> Bool) async -> Bool {
        let ceiling = timeout * 20
        var charged: Duration = .zero
        var last = now()
        while charged < timeout && last < ceiling {
            if await condition() { return true }
            await sleep(pollInterval)
            let at = now()
            charged += min(at - last, stallGrace)
            last = at
        }
        return await condition()
    }
}

/// A unit that throws CancellationError on its own (an inner task group
/// cancelled, say) while the lane task itself is NOT cancelled (review
/// 2026-10-30): that is a failed unit, not a dead process.
struct SelfCancellingJob: BackgroundJob {
    let title = "Self-cancelling job"
    let unitCount = 3
    let recorder: UnitRecorder
    func runUnit(_ index: Int) async throws -> UnitOutcome {
        if index == 1 { throw CancellationError() }
        recorder.begin(); recorder.end(index)
        return .done
    }
}

struct SelfCancellingFactory: JobFactory {
    static let kind = JobKind(rawValue: "selfcancel")
    let recorder: UnitRecorder
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        SelfCancellingJob(recorder: recorder)
    }
}

/// A unit that holds until the test says go. The lane is INSIDE a unit for
/// as long as the gate is shut, so a verb issued meanwhile cannot be
/// overtaken by the between-units check (nightly 2026-10-31: the 100 ms
/// sleep-per-unit version of this lost that race under Release load).
/// C++: a condition variable the test owns; the job waits on it.
final class UnitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting = false

    func open() {
        lock.lock(); defer { lock.unlock() }
        opened = true
    }

    /// True once a unit has reached the gate and is held there.
    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting && !opened
    }

    /// Synchronous: Swift 6 refuses a raw NSLock inside an async function
    /// (a suspension while holding it would deadlock), so the async loop
    /// calls these and never touches the lock itself.
    private func arrive() {
        lock.lock(); defer { lock.unlock() }
        waiting = true
    }

    private var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    fileprivate func hold() async throws {
        arrive()
        while !isOpen {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        // The loop can leave on "open" with the task already cancelled (the
        // sleep had ended before the cancel landed, GH #475): a dead process
        // finishes nothing, so look once more on the way out.
        try Task.checkCancellation()
    }
}

struct GatedJob: BackgroundJob {
    let title = "Gated job"
    let unitCount: Int
    let recorder: UnitRecorder
    let gate: UnitGate
    /// The unit that waits at the gate; the others take `sleepPerUnit`
    /// (so the job is still RUNNING when the test reads its state after the gate).
    let heldUnit: Int
    let sleepPerUnit: Duration

    func runUnit(_ index: Int) async throws -> UnitOutcome {
        recorder.begin()
        if index == heldUnit { try await gate.hold() } else if sleepPerUnit > .zero { try await Task.sleep(for: sleepPerUnit) }
        recorder.end(index)
        return .done
    }
}

struct GatedFactory: JobFactory {
    static let kind = JobKind(rawValue: "gated")
    let recorder: UnitRecorder
    let gate: UnitGate
    var units = 1_000
    var heldUnit = 0
    var sleepPerUnit: Duration = .milliseconds(10)

    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        GatedJob(unitCount: units, recorder: recorder, gate: gate, heldUnit: heldUnit, sleepPerUnit: sleepPerUnit)
    }

    static func request() -> JobRequest { JobRequest(kind: kind, requestedBy: "test") }
}

extension InMemoryBackgroundLog {
    var startCount: Int { lines.filter { $0.hasPrefix("START ") }.count }
    var outcomeCount: Int { lines.filter { $0.hasPrefix("OUTCOME ") }.count }
}
