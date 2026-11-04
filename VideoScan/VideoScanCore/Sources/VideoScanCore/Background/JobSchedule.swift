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
// fast, or refused at START or enqueue) is HELD — never planned again —
// until (1) Rick presses Resume, (2) the build changes, or (3) the catalog
// generation changes. (3) is honoured once per reason: if the job fails again
// with the same words after a catalog change released it, the new hold is
// `sticky` and only Resume or a new build clears it. Without that, every
// catalog edit (each commit is a generation) would buy another fail-fast run.
// Holds live in `background/holds.json` (atomic publish), so they survive a
// crash or a relaunch.
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
    /// The failure's stable words (the error, without unit counts); a repeat
    /// is recognised by these. Optional: absent in a file from an earlier cut.
    public var signature: String?
    public var build: String
    public var generation: Int?
    public var heldAt: Date
    /// Set when a catalog change released it; the record is kept so a repeat
    /// failure with the same words becomes `sticky`.
    public var releasedByCatalogAt: Date?
    /// A catalog change no longer releases it (it already did once, in vain).
    public var sticky: Bool

    public init(kind: JobKind, jobID: JobID, reason: String, signature: String? = nil, build: String, generation: Int?,
                heldAt: Date = Date(), releasedByCatalogAt: Date? = nil, sticky: Bool = false) {
        self.kind = kind
        self.jobID = jobID
        self.reason = reason
        self.signature = signature
        self.build = build
        self.generation = generation
        self.heldAt = heldAt
        self.releasedByCatalogAt = releasedByCatalogAt
        self.sticky = sticky
    }

    public var isActive: Bool { releasedByCatalogAt == nil }

    /// What every surface says (menu bar, Settings, the log).
    public var words: String {
        "held after a failure: \(reason) — "
            + (sticky ? "Resume or a new build clears it" : "Resume, a new build or a catalog change clears it")
    }
}

/// `background/holds.json`. An unreadable file fails CLOSED: the supervisor
/// holds every scheduled kind until Resume (which rewrites the file) or a new
/// build, and logs it (Codex #235 F2).
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
            return .failure(Refusal("\(url.path) is unreadable (\(error)) — read as no holds"))
        }
    }

    public func save(_ holds: [ScheduleHold]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFilePublish.write(try BackgroundPayloadCodec.encode(holds), to: url)
    }
}
