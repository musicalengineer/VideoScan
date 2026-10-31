// BackgroundJob.swift — VideoScanCore/Background
//
// A job is a loop over UNITS (one file, one window; design §3.5): the
// supervisor runs `runUnit(i)` for i in checkpoint..<unitCount, checks
// Backoff and pause/stop between units, and rewrites the checkpoint after
// each. A job never sees the queue, the checkpoint or the log — it only
// does one unit when asked.
//
// `NoOpJob` is step 0's one job (design §4 row 0): it counts units with a
// sleep, so the lifecycle — START, checkpoint, pause, stop, OUTCOME,
// resume after a kill — is proven with no media and no model.
//
// C++ reading: `BackgroundJob` is the strategy interface; `JobFactory` is
// the registry that turns a `JobKind` into a concrete strategy or refuses.

import Foundation

public enum UnitOutcome: Sendable, Equatable {
    case done
    case skipped
}

public protocol BackgroundJob: Sendable {
    /// The MFO row's verb line ("No-op job").
    var title: String { get }
    var unitCount: Int { get }
    func runUnit(_ index: Int) async throws -> UnitOutcome
}

public struct NoOpJob: BackgroundJob {
    public static let unitsKey = "units"
    public static let sleepMillisecondsKey = "sleepMilliseconds"
    public static let defaultUnits = 100
    public static let defaultSleepMilliseconds = 1000

    public let title = "No-op job"
    public let unitCount: Int
    public let sleepPerUnit: Duration

    public init(units: Int, sleepPerUnit: Duration) {
        self.unitCount = max(0, units)
        self.sleepPerUnit = sleepPerUnit
    }

    /// From a request's parameters: `units` (default 100) and
    /// `sleepMilliseconds` (default 1000 — one unit a second, so Rick can
    /// watch it count in Activity Monitor and the log).
    public init(request: JobRequest) throws {
        let p = request.parameters
        guard let units = Int(p[Self.unitsKey] ?? String(Self.defaultUnits)), units >= 0 else {
            throw Refusal("noop: `\(Self.unitsKey)` must be a whole number, got \(p[Self.unitsKey] ?? "nothing")")
        }
        guard let ms = Int(p[Self.sleepMillisecondsKey] ?? String(Self.defaultSleepMilliseconds)), ms >= 0 else {
            throw Refusal("noop: `\(Self.sleepMillisecondsKey)` must be a whole number, got \(p[Self.sleepMillisecondsKey] ?? "nothing")")
        }
        self.init(units: units, sleepPerUnit: .milliseconds(ms))
    }

    public func runUnit(_ index: Int) async throws -> UnitOutcome {
        if sleepPerUnit > .zero { try await Task.sleep(for: sleepPerUnit) }
        return .done
    }

    /// A request for this job, for the CLI's `--enqueue noop`.
    public static func request(units: Int = defaultUnits, sleepMilliseconds: Int = defaultSleepMilliseconds,
                               lane: String = "default", requestedBy: String) -> JobRequest {
        JobRequest(kind: .noop, lane: lane,
                   parameters: [unitsKey: String(units), sleepMillisecondsKey: String(sleepMilliseconds)],
                   requestedBy: requestedBy)
    }
}

public protocol JobFactory: Sendable {
    /// A job for the request, or a `Refusal` in words (unknown kind, bad
    /// parameters, a resource profile the Mac cannot hold).
    func makeJob(for request: JobRequest) throws -> any BackgroundJob
}

/// Step 0's registry: `noop` only.
public struct DefaultJobFactory: JobFactory {
    public init() {}
    public func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        switch request.kind {
        case .noop: return try NoOpJob(request: request)
        default: throw Refusal("VideoScan Background does not know the job kind `\(request.kind)` (this build knows: noop)")
        }
    }
}
