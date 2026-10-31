// BackgroundPayloads.swift — VideoScanCore/Background
//
// The Codable values that cross the XPC wire and sit in the queue and
// checkpoint files (design §3.3, §3.4). Plain structs and enums with stable
// string raw values: a file written tonight must decode next year.
//
// Memory: every payload here is a handful of scalars and short strings; a
// 100k-request queue in memory is ≈ 100k × ~200 B = 20 MB worst case, and
// the supervisor never holds more than the queue folder holds.

import Foundation

/// A job's identity: a UUID string, also the stem of its queue and
/// checkpoint files.
public struct JobID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

/// What kind of work a request asks for. Step 0 knows one: `noop`. Later
/// steps add `modelLab`, `caption`, … (design §4). Unknown kinds decode
/// (the raw string is kept) so an older service can refuse them in words.
public struct JobKind: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Counts units with a sleep; proves the lifecycle (design §4 row 0).
    public static let noop = JobKind(rawValue: "noop")
}

/// What a job declares about itself before START (design §3.2 "one resident
/// model"): the service refuses a job the Mac cannot hold.
public struct JobResourceProfile: Codable, Equatable, Sendable {
    public var peakMemoryBytes: Int64
    public var needsResidentModel: Bool
    public var secondsPerUnitEstimate: Double

    public init(peakMemoryBytes: Int64 = 0, needsResidentModel: Bool = false, secondsPerUnitEstimate: Double = 0) {
        self.peakMemoryBytes = peakMemoryBytes
        self.needsResidentModel = needsResidentModel
        self.secondsPerUnitEstimate = secondsPerUnitEstimate
    }
}

/// One queued job: `queue/<id>.json` (design §3.4).
public struct JobRequest: Codable, Equatable, Sendable {
    public var id: JobID
    public var kind: JobKind
    /// One job runs per lane at a time; jobs in different lanes run beside
    /// each other. Default lane: "default".
    public var lane: String
    /// Kind-specific arguments (a NoOp job reads `units` and `sleepMilliseconds`).
    public var parameters: [String: String]
    public var resources: JobResourceProfile
    public var requestedAt: Date
    /// Who asked: "app", "cli", "nightly".
    public var requestedBy: String

    public init(id: JobID = JobID(), kind: JobKind, lane: String = "default",
                parameters: [String: String] = [:], resources: JobResourceProfile = JobResourceProfile(),
                requestedAt: Date = Date(), requestedBy: String = "app") {
        self.id = id
        self.kind = kind
        self.lane = lane
        self.parameters = parameters
        self.resources = resources
        self.requestedAt = requestedAt
        self.requestedBy = requestedBy
    }
}

/// The reply to `enqueue`: accepted with the id, or refused in words.
public enum EnqueueReply: Codable, Equatable, Sendable {
    case accepted(JobID)
    case refused(Refusal)
}

/// Where a job is in its life. Raw strings are the wire and file form.
public enum JobRunState: Codable, Equatable, Sendable {
    case queued
    case running
    /// Pause requested; the current unit is finishing (design §3.5 "pausing…").
    case pausing
    /// Paused: by the user, by `Backoff` (thermal, memory), or by a failed
    /// checkpoint write (`disk`). The reason is words for the row.
    case paused(reason: String)
    case stopped
    case finished
    case failed(reason: String)

    public var isActive: Bool {
        switch self {
        case .queued, .running, .pausing, .paused: return true
        case .stopped, .finished, .failed: return false
        }
    }

    public var words: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .pausing: return "pausing…"
        case .paused(let reason): return "paused (\(reason))"
        case .stopped: return "stopped"
        case .finished: return "finished"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

/// Progress of one job, as the MFO row draws it (design §3.3: the app's row
/// shows a service job exactly as an in-app one). Mirrors the fields of
/// `MediaFileOperationJob` in MediaOps — title, subtitle, fraction,
/// indeterminate, state, startedAt, finishedAt — plus the counts the
/// OUTCOME line reports. Kept as a value so it crosses the wire unchanged.
public struct JobProgressSnapshot: Codable, Equatable, Sendable {
    public var id: JobID
    public var kind: JobKind
    public var lane: String
    /// The row's verb line, e.g. "No-op job".
    public var title: String
    /// Live status line, e.g. "unit 412 of 10,000".
    public var subtitle: String
    public var completedUnits: Int
    public var totalUnits: Int
    public var skippedUnits: Int
    public var failedUnits: Int
    public var state: JobRunState
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: JobID, kind: JobKind, lane: String, title: String, subtitle: String,
                completedUnits: Int, totalUnits: Int, skippedUnits: Int, failedUnits: Int,
                state: JobRunState, startedAt: Date?, finishedAt: Date?) {
        self.id = id
        self.kind = kind
        self.lane = lane
        self.title = title
        self.subtitle = subtitle
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.skippedUnits = skippedUnits
        self.failedUnits = failedUnits
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// 0…1; 0 while the total is unknown.
    public var fraction: Double {
        totalUnits > 0 ? min(1, Double(completedUnits) / Double(totalUnits)) : 0
    }
    public var isIndeterminate: Bool { totalUnits <= 0 }
}

/// The answer to `status` (design §3.3): every job the service knows about,
/// its backoff state, its version, and who it is.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var processIdentifier: Int32
    public var startedAt: Date
    public var backoff: BackoffState
    public var jobs: [JobProgressSnapshot]
    /// Seconds since the service last did anything (a unit, an XPC call).
    public var idleSeconds: Double

    public init(protocolVersion: Int = BackgroundProtocolVersion.current, processIdentifier: Int32,
                startedAt: Date, backoff: BackoffState, jobs: [JobProgressSnapshot], idleSeconds: Double) {
        self.protocolVersion = protocolVersion
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.backoff = backoff
        self.jobs = jobs
        self.idleSeconds = idleSeconds
    }

    /// One line for the CLI and the log.
    public var summaryLine: String {
        let active = jobs.filter { $0.state.isActive }.count
        return "VideoScan Background pid \(processIdentifier) · \(backoff.words) · \(active) active of \(jobs.count) job(s) · idle \(Int(idleSeconds))s · schema \(protocolVersion)"
    }
}
