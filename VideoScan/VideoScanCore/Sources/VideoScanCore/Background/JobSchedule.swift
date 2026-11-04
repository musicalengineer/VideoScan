// JobSchedule.swift — VideoScanCore/Background
//
// The helper owns its schedule (Rick 2026-11-04, DECISIONS). The app no
// longer enqueues: the supervisor plans by itself at launch, every
// `planInterval`, and when the catalog generation changes, and enqueues a
// job of each scheduled kind whose plan is not empty and that has no active
// job. These are the values it plans with; the loop is in JobSupervisor
// (`scheduleTick`), so it runs only while that supervisor owns the state root.
//
// Failures hold (answers Codex #232 F4, a fail-fast job re-queued on the
// next recount, forever): a scheduled kind whose job ends `.failed` (fail
// fast, every unit failed, or refused at START or admission) is HELD — never
// planned again — until (1) Rick presses Resume, (2) the build changes, or
// (3) THE WORK CHANGES: the plan size differs from the size of the first plan
// after the hold (Fable review 11/04, replacing "a catalog commit releases
// once, then sticky": failure words carry a stderr tail that differs per
// spawn, so no words-based rule is stable; and a commit that adds no work
// says nothing about the failure). Holds live in `background/holds.json`;
// Pause per kind in `background/paused.json` (atomic publish both), so they
// survive a crash or a relaunch.
//
// Memory: a handful of holds (≤ one per kind) and one Int per kind for the
// last plan size.
//
// C++ reading: `Kind` is a small strategy record (two std::function members);
// `ScheduleHoldStore` is a file-backed vector<Hold>.

import Foundation

public struct JobSchedule: Sendable {
    /// One kind the helper keeps running.
    public struct Kind: Sendable {
        public var kind: JobKind
        /// The number of units the next job would run (the job's own planner,
        /// read-only). Called off the supervisor's actor.
        public var planSize: @Sendable () throws -> Int
        public var makeRequest: @Sendable () -> JobRequest

        public init(kind: JobKind, planSize: @escaping @Sendable () throws -> Int, makeRequest: @escaping @Sendable () -> JobRequest) {
            self.kind = kind
            self.planSize = planSize
            self.makeRequest = makeRequest
        }
    }

    public var kinds: [Kind]
    /// `generations.generation` of the catalog (nil: unreadable or absent).
    public var generation: @Sendable () -> Int?
    /// Identity of the running build; a hold made by another build is released.
    public var buildID: String
    public var holds: ScheduleHoldStore
    /// Plan at least this often (Rick 2026-11-04: every 10 minutes).
    public var planInterval: Duration = .seconds(600)
    /// How often the generation is read (one primary-key SELECT).
    public var pollInterval: Duration = .seconds(30)

    public init(kinds: [Kind], generation: @escaping @Sendable () -> Int?, buildID: String, holds: ScheduleHoldStore) {
        self.kinds = kinds
        self.generation = generation
        self.buildID = buildID
        self.holds = holds
    }

    /// The running executable's identity: path, size and modification time,
    /// so every rebuild is a new build (CFBundleVersion does not move per build).
    public static func buildID(executable: URL? = Bundle.main.executableURL) -> String {
        guard let executable, let a = try? FileManager.default.attributesOfItem(atPath: executable.path) else { return "unknown" }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(executable.lastPathComponent) \(size) \(Int64(mtime))"
    }
}

/// A scheduled kind that failed and is not planned again until released.
public struct ScheduleHold: Codable, Equatable, Sendable {
    public var kind: JobKind
    /// The failed job (the menu's Resume names it).
    public var jobID: JobID
    public var reason: String
    public var build: String
    /// The plan size the hold is measured against: nil until the first plan
    /// after the hold sets it; a later plan of a different size releases it.
    public var planSize: Int?
    public var heldAt: Date
    /// Legacy wire field, always false and unused: a reader built at
    /// 0dedf4768 requires it to decode a status with a hold (Codex #241 F5).
    /// Encoded always; decoded when present (07c314e5d wrote none, #242).
    public var sticky = false

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(JobKind.self, forKey: .kind)
        jobID = try c.decode(JobID.self, forKey: .jobID)
        reason = try c.decode(String.self, forKey: .reason)
        build = try c.decode(String.self, forKey: .build)
        planSize = try c.decodeIfPresent(Int.self, forKey: .planSize)
        heldAt = try c.decode(Date.self, forKey: .heldAt)
        sticky = try c.decodeIfPresent(Bool.self, forKey: .sticky) ?? false
    }

    public init(kind: JobKind, jobID: JobID, reason: String, build: String, planSize: Int? = nil, heldAt: Date = Date()) {
        self.kind = kind
        self.jobID = jobID
        self.reason = reason
        self.build = build
        self.planSize = planSize
        self.heldAt = heldAt
    }

    /// What every surface says (menu bar, Settings, the log).
    public var words: String {
        "held after a failure: \(reason) — Resume, a new build or new work clears it"
    }
}

/// `background/holds.json` and `background/paused.json`. An unreadable file
/// fails CLOSED: the supervisor holds (or pauses) every scheduled kind until
/// Resume (which rewrites the file) or a new build, and logs it.
public final class ScheduleHoldStore: @unchecked Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static func beside(stateRoot: URL) -> ScheduleHoldStore {
        ScheduleHoldStore(url: stateRoot.appendingPathComponent("holds.json"))
    }

    public func load() -> Result<[ScheduleHold], Refusal> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success([]) }
        do {
            return .success(try BackgroundPayloadCodec.decode([ScheduleHold].self, from: Data(contentsOf: url)))
        } catch {
            return .failure(Refusal("\(url.path) is unreadable (\(error))"))
        }
    }

    public func save(_ holds: [ScheduleHold]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFilePublish.write(try BackgroundPayloadCodec.encode(holds), to: url)
    }

    /// The paused kinds (Pause in the menu bar survives a restart; Rick 11/04).
    public var pausedURL: URL { url.deletingLastPathComponent().appendingPathComponent("paused.json") }

    public func loadPaused() -> Result<[JobKind], Refusal> {
        guard FileManager.default.fileExists(atPath: pausedURL.path) else { return .success([]) }
        do {
            return .success(try BackgroundPayloadCodec.decode([JobKind].self, from: Data(contentsOf: pausedURL)))
        } catch {
            return .failure(Refusal("\(pausedURL.path) is unreadable (\(error))"))
        }
    }

    public func savePaused(_ kinds: [JobKind]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFilePublish.write(try BackgroundPayloadCodec.encode(kinds), to: pausedURL)
    }
}
