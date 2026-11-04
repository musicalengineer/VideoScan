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
    /// Not now, and not counted: the unit is asked again after the
    /// supervisor's `deferRetryInterval`, through the same between-units
    /// hold (pause / stop / Backoff honoured). EraJob defers while Backoff
    /// says `.trickle` and its model is not loaded — no model load while
    /// Rick is at the keyboard (design §3.5).
    case deferred(reason: String)
}

public protocol BackgroundJob: Sendable {
    /// The MFO row's verb line ("No-op job").
    var title: String { get }
    var unitCount: Int { get }
    func runUnit(_ index: Int) async throws -> UnitOutcome
    /// Words appended to the START line (approach, model, order rule…).
    var startDetail: String { get }
    /// Words appended to the OUTCOME line (assertions written, s/unit, RSS…).
    func outcomeDetail() async -> String
    /// The job ends (finished or stopped): release what it holds (a worker
    /// process, a plan file). Not called when the process dies.
    func end() async
    /// Can this unit's failure speak for the whole job — the environment, the
    /// worker — rather than for one unit's file? The supervisor stops a job
    /// after `Configuration.failFastUnits` such failures in a row with the
    /// same words (2026-11-03: 523 of 523 units failed on a missing ffmpeg).
    /// Default true; answer false for failures one bad file can cause whose
    /// words do not name the file (EraJob: a clip past its cap, a worker death).
    func failureIsSystemic(_ error: any Error) -> Bool
}

extension BackgroundJob {
    public var startDetail: String { "" }
    public func outcomeDetail() async -> String { "" }
    public func end() async {}
    public func failureIsSystemic(_ error: any Error) -> Bool { true }
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

/// The registry: `noop` (step 0) and `era` (step 1). `stateRoot` is the
/// service's background/ folder (the journal and the frozen plans live
/// under it); `catalogURL` the catalog it plans from (read-only).
public struct DefaultJobFactory: JobFactory {
    public let stateRoot: URL?
    public let catalogURL: URL
    public let backoff: Backoff?

    public static var productionCatalogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VideoScan/catalog.sqlite")
    }

    public init(stateRoot: URL? = nil, catalogURL: URL = DefaultJobFactory.productionCatalogURL, backoff: Backoff? = nil) {
        self.stateRoot = stateRoot
        self.catalogURL = catalogURL
        self.backoff = backoff
    }

    public func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        switch request.kind {
        case .noop: return try NoOpJob(request: request)
        case .era:
            guard let stateRoot else { throw Refusal("era: this service has no state folder for its journal") }
            return try EraJob(try EraJob.setup(for: request, stateRoot: stateRoot, catalogURL: catalogURL, backoff: backoff))
        default: throw Refusal("VideoScan Background does not know the job kind `\(request.kind)` (this build knows: noop, era)")
        }
    }
}

extension EraJob {
    /// A request's parameters → a Setup, refused in words before anything
    /// runs: `repoPath` (required, must hold tools/video-llm-bench/bench.py),
    /// `python` (default <repo>/venv-mlx/bin/python3), `modelDir` (default:
    /// the Hugging Face snapshot of the 8B, which must be present),
    /// `catalogPath` (default the factory's), `limit` (files; default all).
    /// `environment` is the helper's own (launchd's minimal PATH under the
    /// service): the worker gets it through `SubprocessEnvironment.mediaTools`,
    /// so bench.py's bare `ffmpeg`/`ffprobe` are the ones FFmpegLocator finds —
    /// or the job is refused here, naming what is missing (2026-11-03 bug).
    public static func setup(for request: JobRequest, stateRoot: URL, catalogURL: URL, backoff: Backoff?,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             fileManager: FileManager = .default) throws -> Setup {
        let p = request.parameters
        guard let repo = p[repoPathKey], !repo.isEmpty else {
            throw Refusal("era: `\(repoPathKey)` is required — the VideoScan checkout that holds tools/video-llm-bench/bench.py and venv-mlx")
        }
        var limit: Int?
        if let text = p[limitKey] {
            guard let n = Int(text), n >= 0 else { throw Refusal("era: `\(limitKey)` must be a whole number, got \(text)") }
            limit = n
        }
        let modelDir = p[modelDirKey] ?? defaultModelSnapshot()
        guard let modelDir, FileManager.default.fileExists(atPath: modelDir + "/config.json") else {
            throw Refusal("era: the 8B weights are not on this Mac (\(p[modelDirKey] ?? "no snapshot of mlx-community/Qwen3-VL-8B-Instruct-4bit in ~/.cache/huggingface")) — refused at START, not after 400 files")
        }
        var worker = try PythonClipWorker.Configuration.repo(URL(fileURLWithPath: repo), factory: "clip-service:a2-py:\(modelDir)",
                                                              python: p[pythonKey].map { URL(fileURLWithPath: $0) })
        do {
            worker.environment = try SubprocessEnvironment.mediaTools(inheriting: environment, fileManager: fileManager)
        } catch let refusal as Refusal {
            throw Refusal("era: \(refusal.words) — refused at START, not once per file")
        }
        let catalog = p[catalogPathKey].map { URL(fileURLWithPath: $0) } ?? catalogURL
        return Setup(jobID: request.id, catalogURL: catalog, stateRoot: stateRoot, worker: worker, limit: limit, backoff: backoff)
    }

    /// The newest snapshot folder of the 8B in the Hugging Face cache, or nil.
    static func defaultModelSnapshot() -> String? {
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen3-VL-8B-Instruct-4bit/snapshots")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return names.sorted().last.map { snapshots.appendingPathComponent($0).path }
    }

    /// A request for the CLI's `--enqueue era`.
    public static func request(limit: Int?, repoPath: String, python: String? = nil, catalogPath: String? = nil,
                               lane: String = "model", requestedBy: String) -> JobRequest {
        var parameters = [repoPathKey: repoPath]
        if let limit { parameters[limitKey] = String(limit) }
        if let python { parameters[pythonKey] = python }
        if let catalogPath { parameters[catalogPathKey] = catalogPath }
        return JobRequest(kind: .era, lane: lane, parameters: parameters,
                          resources: JobResourceProfile(peakMemoryBytes: 8_000_000_000, needsResidentModel: true, secondsPerUnitEstimate: 7),
                          requestedBy: requestedBy)
    }
}
