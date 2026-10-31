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

    static func fullBackoff(trickle: Duration = .milliseconds(20)) -> Backoff {
        Backoff(source: FakeActivitySource(ActivitySample()), trickleInterval: trickle)
    }

    static func fastConfiguration() -> JobSupervisor.Configuration {
        var c = JobSupervisor.Configuration()
        c.pausePollInterval = .milliseconds(10)
        return c
    }

    /// Polls until `condition` holds or `timeout` passes.
    static func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
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

extension InMemoryBackgroundLog {
    var startCount: Int { lines.filter { $0.hasPrefix("START ") }.count }
    var outcomeCount: Int { lines.filter { $0.hasPrefix("OUTCOME ") }.count }
}
