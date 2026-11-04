// EraJob.swift — VideoScanCore/Background
//
// Background service step 1 (DECISIONS 2026-10-31): the helper's first real
// job. Units = files. Per unit, the seated 8B (SeatedApproach.eraA2, through
// PythonClipWorker → bench.py ClipService) looks at the pixels only and the
// job appends journal lines — one `era.yearRange` per valid window, one
// `ocr.date` per still that read a date stamp, and ONE file-level era
// verdict — `era.fused` (bench.py's fuse_range of the windows' range and the
// burned-in years) or, when the model answered but no usable range came of
// it, `era.none` (2026-11-02: "analyzed by this signer, no usable era
// evidence", so the caching rule below sees the file as done instead of
// re-running it every job; never an era, never a date) — for the app's
// JournalApplier to commit. A record with no fused range that shows the model
// did not see the whole file — an era window or OCR still it never answered
// (a generation error), a frame that would not rip — is not evidence of
// anything: the unit writes NO line at all (the caching rule below counts any
// line by the signer, so even an ocr.date would cache it) and the file is
// retried next run (Codex era.none pass, 2026-11-02). A fused range is a
// verdict and wins over such a failure. Nothing here writes the catalog; the catalog is opened
// read-only (BackgroundCatalogAccess) to plan.
//
// The plan (frozen per job id in background/plans/<id>.json, so a resume's
// unit N is the same file as the first run's unit N):
//   * every content with a live, readable, video file (stream_type Video+…),
//   * EXCLUDING contents that already have a provenance_assertions row by
//     the same signer, or a journal line by it (not applied yet) — the
//     caching rule, design §0.7,
//   * ordered by `EraJob.order`: oldest first by the best date bound the
//     catalog has — Rick's date, else the embedded date, else the inferred
//     date, else a year in the path, else unknown (last),
//   * cut to `limit`.
// At run time a unit whose digest has gained a line by the worker's signer
// (a kill after the journal append, before the checkpoint) is SKIPPED, so a
// relaunch never writes a second set of lines for it.
//
// Isolation (design §6): a clip past its cap, a worker death, an unreadable
// file → the unit throws (the supervisor counts it failed) and the job goes
// on; the next unit respawns the worker. Two load failures in a row → every
// remaining unit fails fast with the load's words (weights missing must not
// cost 300 s × 6,000 files), and the supervisor's fail-fast then stops the
// job (`failureIsSystemic`; timeouts and worker deaths never stop it).
// The worker's environment comes from `SubprocessEnvironment.mediaTools` in
// `EraJob.setup`, so ffmpeg/ffprobe are found under launchd or the job is
// refused at START (2026-11-03: 523 units failed on a bare `ffmpeg`).
// No keyboard backoff (2026-11-04): units run back to back and the model
// stays loaded in the worker for the whole job; the worker child runs at
// utility QoS (PythonClipWorker.makeProcess).
//
// Memory: the plan holds one EraUnit (≈ 200 B) per planned file — 100k files
// ≈ 20 MB; the caching sets one 64-char digest per cached content; one clip
// record (a few KB) in flight. The model lives in the worker process.
//
// C++ reading: a strategy object (BackgroundJob) owning a child-process
// proxy (PythonClipWorker actor) and a tiny actor for its counters.

import Foundation

// MARK: - Plan values

/// What the ordering reads about one content.
public struct EraCandidate: Codable, Equatable, Sendable {
    public var digest: String
    public var path: String
    public var durationS: Double
    public var userYear: Int?
    public var embeddedYear: Int?
    public var inferredYear: Int?
    public var pathYear: Int?

    public init(digest: String, path: String, durationS: Double, userYear: Int? = nil, embeddedYear: Int? = nil,
                inferredYear: Int? = nil, pathYear: Int? = nil) {
        self.digest = digest
        self.path = path
        self.durationS = durationS
        self.userYear = userYear
        self.embeddedYear = embeddedYear
        self.inferredYear = inferredYear
        self.pathYear = pathYear
    }

    /// The best date bound and where it came from, or nil (unknown).
    public var bound: (year: Int, source: String)? {
        if let y = userYear { return (y, "user") }
        if let y = embeddedYear { return (y, "embedded") }
        if let y = inferredYear { return (y, "inferred") }
        if let y = pathYear { return (y, "path") }
        return nil
    }
}

public struct EraPlan: Codable, Equatable, Sendable {
    public var jobID: String
    public var signer: String
    public var units: [EraCandidate]
    public var videoContents: Int
    public var cached: Int
    public var unreadable: Int
}

// MARK: - The job

public final class EraJob: BackgroundJob, @unchecked Sendable {

    public static let kind = JobKind.era
    public static let limitKey = "limit"
    public static let repoPathKey = "repoPath"
    public static let pythonKey = "python"
    public static let modelDirKey = "modelDir"
    public static let catalogPathKey = "catalogPath"
    public static let orderRule = "oldest first by the best date bound (Rick's date, else embedded, else inferred, else a year in the path; unknown last)"

    /// Everything a job needs, injected (the factory builds it from a request; tests directly).
    public struct Setup: Sendable {
        public var jobID: JobID
        public var catalogURL: URL
        public var stateRoot: URL
        public var worker: PythonClipWorker.Configuration
        public var limit: Int?
        public var isReadable: @Sendable (String) -> Bool
        public var now: @Sendable () -> Date
        /// Test seam: runs after a unit's journal append, before it returns.
        public var afterJournalAppend: (@Sendable (Int) async -> Void)?

        public init(jobID: JobID, catalogURL: URL, stateRoot: URL, worker: PythonClipWorker.Configuration, limit: Int? = nil,
                    isReadable: @escaping @Sendable (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) },
                    now: @escaping @Sendable () -> Date = { Date() }, afterJournalAppend: (@Sendable (Int) async -> Void)? = nil) {
            self.jobID = jobID
            self.catalogURL = catalogURL
            self.stateRoot = stateRoot
            self.worker = worker
            self.limit = limit
            self.isReadable = isReadable
            self.now = now
            self.afterJournalAppend = afterJournalAppend
        }
    }

    public let title = "Machine era (8B)"
    public let plan: EraPlan
    public var unitCount: Int { plan.units.count }
    public let journal: ObservationJournal
    public let worker: PythonClipWorker
    private let setup: Setup
    private let counters = EraCounters()

    /// Load the frozen plan for this job id, or build and freeze it.
    public init(_ setup: Setup) throws {
        self.setup = setup
        journal = ObservationJournal(directory: setup.stateRoot.appendingPathComponent("journal", isDirectory: true), now: setup.now)
        worker = PythonClipWorker(configuration: setup.worker, descriptor: SeatedApproach.eraA2)
        let planURL = Self.planURL(setup.stateRoot, setup.jobID)
        if let data = try? Data(contentsOf: planURL), let frozen = try? JSONDecoder().decode(EraPlan.self, from: data),
           frozen.jobID == setup.jobID.rawValue {
            plan = frozen
        } else {
            plan = try EraPlanner.plan(catalogURL: setup.catalogURL, journal: journal, signer: SeatedApproach.eraA2.signer,
                                       limit: setup.limit, jobID: setup.jobID, isReadable: setup.isReadable)
            try FileManager.default.createDirectory(at: planURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFilePublish.write(try JSONEncoder().encode(plan), to: planURL)
        }
    }

    static func planURL(_ root: URL, _ id: JobID) -> URL {
        root.appendingPathComponent("plans/\(id.rawValue).json")
    }

    public var startDetail: String {
        "approach \(plan.signer) (expected; every line is signed by the worker's own load reply) · model "
            + "\(SeatedApproach.eraA2.resources.weightsLocation ?? "?") · \(plan.units.count) files of \(plan.videoContents) video contents "
            + "(\(plan.cached) cached by that signer, \(plan.unreadable) unreadable) · order: \(Self.orderRule)"
    }

    public func runUnit(_ index: Int) async throws -> UnitOutcome {
        let unit = plan.units[index]
        if let words = await counters.failFast { throw Refusal(words) }
        let info: PythonClipWorker.LoadInfo
        do {
            info = try await worker.load()
            await counters.loaded(info)
        } catch {
            throw Refusal(await counters.loadFailed("\(error)"))
        }
        if await counters.isCached(unit.digest, signer: info.signer, journal: journal) {
            await counters.count(.cached)
            return .skipped
        }
        guard setup.isReadable(unit.path) else {
            await counters.count(.unreadable)
            throw Refusal("unreadable: \(unit.path) — the file is not there or cannot be read now")
        }
        let started = ContinuousClock.now
        let data: Data
        do {
            data = try await worker.analyzeClip(path: unit.path, durationS: unit.durationS)
        } catch let error as PythonClipWorkerError {
            switch error {
            case .timeout: await counters.count(.timeout)
            case .died: await counters.count(.workerDeath)
            default: await counters.count(.other)
            }
            throw error
        }
        let at = Int64(setup.now().timeIntervalSince1970)
        let mapped = try EraRecordMapper.lines(record: data, digest: unit.digest, info: info, job: setup.jobID.rawValue, unit: index, at: at)
        // A verdict of "no usable era" is cached for good; never reach it on a
        // file that went away while the model looked (frames that would not rip).
        if mapped.eraNone, !setup.isReadable(unit.path) {
            await counters.count(.unreadable)
            throw Refusal("unreadable: \(unit.path) — the file went away during analysis; nothing written, retried next run")
        }
        try journal.append(mapped.lines)
        await counters.wrote(mapped, digest: unit.digest, signer: info.signer, seconds: started.duration(to: .now))
        await setup.afterJournalAppend?(index)
        return .done
    }

    public func outcomeDetail() async -> String {
        let rss = await worker.peakRSSBytes()
        return await counters.words(peakRSS: rss, planCached: plan.cached)
    }

    /// A clip past its cap and a worker death can come from one file (a huge
    /// tape, a decoder crash) and their words do not name it, so a run of
    /// them never stops the job; everything else (a worker exception, a load
    /// failure, a protocol error) can (JobSupervisor fail-fast).
    public func failureIsSystemic(_ error: any Error) -> Bool {
        switch error as? PythonClipWorkerError {
        case .timeout?, .died?: return false
        default: return true
        }
    }

    /// A line by the plan's signer for this unit's digest is in the journal.
    public func unitIsAlreadyRecorded(_ index: Int) async -> Bool {
        guard plan.units.indices.contains(index) else { return false }
        return journal.subjects(by: plan.signer).contains(plan.units[index].digest)
    }

    public func end() async {
        await worker.close()
        try? FileManager.default.removeItem(at: Self.planURL(setup.stateRoot, setup.jobID))
    }

    // MARK: Ordering (pure)

    /// Oldest first by `EraCandidate.bound`; unknown last; ties by digest
    /// (a stable, reproducible order). O(n log n).
    public static func order(_ candidates: [EraCandidate]) -> [EraCandidate] {
        candidates.sorted { a, b in
            switch (a.bound?.year, b.bound?.year) {
            case let (x?, y?): return x != y ? x < y : a.digest < b.digest
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.digest < b.digest
            }
        }
    }

    /// A year 1900…2029 named in the path — a run of exactly four ASCII
    /// digits — the one closest to the file (the filename first, then its
    /// folder, outward); nil when none. "1991 Cape/clip.mov" → 1991;
    /// "IMG_19910.mov" → nil (five digits are not a year).
    public static func pathYear(_ path: String) -> Int? {
        for component in path.split(separator: "/").reversed() {
            var run = ""
            for ch in component + "/" {
                if ch.isASCII, ch.isNumber { run.append(ch); continue }
                if run.count == 4, let y = Int(run), (1900...2029).contains(y) { return y }
                run = ""
            }
        }
        return nil
    }
}

extension JobKind {
    /// The 8B era/OCR job (background service step 1).
    public static let era = JobKind(rawValue: "era")
}

// MARK: - Counters (one small actor)

actor EraCounters {
    enum Failure { case cached, unreadable, timeout, workerDeath, other }

    private var assertions = 0
    private var analyzed = 0
    private var seconds = 0.0
    private var cachedAtRun = 0
    private var unreadable = 0
    private var timeouts = 0
    private var deaths = 0
    private var other = 0
    private var loadFailures = 0
    private(set) var failFast: String?
    private var info: PythonClipWorker.LoadInfo?
    private var observed: [String: Set<String>] = [:]   // signer → digests with lines (journal + this run)
    private var windowsInvalid = 0
    private var eraNone = 0
    private var retriedNextRun = 0

    func loaded(_ info: PythonClipWorker.LoadInfo) {
        self.info = info
        loadFailures = 0
    }

    func loadFailed(_ words: String) -> String {
        loadFailures += 1
        let message = "the worker could not load the model (\(words))"
        // The remaining files fail with the SAME words, so the supervisor's streak
        // sees one systemic error on every unit — fail fast, or the short-plan
        // verdict — and the kind is held (Codex #236 F1).
        if loadFailures >= 2 { failFast = message }
        return message
    }

    func isCached(_ digest: String, signer: String, journal: ObservationJournal) -> Bool {
        if observed[signer] == nil { observed[signer] = journal.subjects(by: signer) }
        return observed[signer]?.contains(digest) == true
    }

    func count(_ f: Failure) {
        switch f {
        case .cached: cachedAtRun += 1
        case .unreadable: unreadable += 1
        case .timeout: timeouts += 1
        case .workerDeath: deaths += 1
        case .other: other += 1
        }
    }

    func wrote(_ mapped: EraRecordMapper.Mapped, digest: String, signer: String, seconds s: Duration) {
        assertions += mapped.lines.count
        windowsInvalid += mapped.windowsInvalid
        if mapped.eraNone { eraNone += 1 }
        if mapped.retryNextRun { retriedNextRun += 1 }
        analyzed += 1
        seconds += Double(s.components.seconds) + Double(s.components.attoseconds) / 1e18
        // Only a unit that wrote a line is cached (the journal is the cache).
        if !mapped.lines.isEmpty { observed[signer, default: []].insert(digest) }
    }

    func words(peakRSS: Int64?, planCached: Int) -> String {
        let perClip = analyzed > 0 ? String(format: "%.1f", seconds / Double(analyzed)) : "–"
        let rss = peakRSS.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "not measured"
        return "approach \(info?.signer ?? "not loaded") · model \(info?.model ?? "–") · \(analyzed) analyzed · "
            + "\(assertions) assertions written · skipped (cached) \(planCached) at plan + \(cachedAtRun) at run · "
            + "failed: \(timeouts) timeout, \(deaths) worker death, \(unreadable) unreadable, \(other) other · "
            + "\(windowsInvalid) windows refused by the Swift contract · no usable era: \(eraNone) era.none, "
            + "\(retriedNextRun) retried next run (generation errors or frames that would not rip) · \(perClip) s/clip · worker peak RSS \(rss)"
    }
}

// MARK: - Planner (reads the catalog, read-only)

public enum EraPlanner {

    /// The frozen unit list (see the file header). Refuses a catalog whose
    /// schema is newer than this build reads.
    public static func plan(catalogURL: URL, journal: ObservationJournal, signer: String, limit: Int?, jobID: JobID,
                            isReadable: @Sendable (String) -> Bool) throws -> EraPlan {
        let catalog = try BackgroundCatalogAccess.open(at: catalogURL)
        defer { catalog.close() }
        if let version = try catalog.schemaVersion(), version > GRDBCatalogRepository.currentSchemaVersion {
            throw Refusal("the catalog's schema version \(version) is newer than this helper reads (\(GRDBCatalogRepository.currentSchemaVersion)) — update VideoScan")
        }
        var byDigest: [String: [EraCandidate]] = [:]
        try catalog.forEachRow("""
            SELECT f.content_digest, f.full_path, f.duration_s,
                   (SELECT substr(u.value, 1, 4) FROM user_dates u WHERE u.digest = f.content_digest AND u.value IS NOT NULL),
                   CAST(strftime('%Y', f.embedded_created_at, 'unixepoch') AS TEXT),
                   (SELECT CAST(strftime('%Y', coalesce(i.date_at, i.range_start), 'unixepoch') AS TEXT)
                      FROM inferred_dates i WHERE i.digest = f.content_digest)
              FROM files f
             WHERE f.content_digest IS NOT NULL AND f.removal_state IS NULL
               AND f.stream_type IN ('Video+Audio', 'Video only')
             ORDER BY f.content_digest, f.full_path
            """) { row in
            guard let digest = row[0], let path = row[1] else { return }
            let candidate = EraCandidate(digest: digest, path: path, durationS: Double(row[2] ?? "") ?? 0,
                                         userYear: row[3].flatMap { Int($0) }, embeddedYear: row[4].flatMap { Int($0) },
                                         inferredYear: row[5].flatMap { Int($0) }, pathYear: EraJob.pathYear(path))
            byDigest[digest, default: []].append(candidate)
        }
        var cached = journal.subjects(by: signer)
        let hasTable = try !catalog.strings("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'provenance_assertions'").isEmpty
        if hasTable {
            let quoted = signer.replacingOccurrences(of: "'", with: "''")
            try catalog.forEachRow("SELECT DISTINCT subject_id FROM provenance_assertions WHERE subject_kind = 'content' AND by = '\(quoted)'") { row in
                if let d = row[0] { cached.insert(d) }
            }
        }
        var units: [EraCandidate] = []
        var unreadable = 0
        var cachedCount = 0
        for (digest, copies) in byDigest {
            if cached.contains(digest) { cachedCount += 1; continue }
            guard var first = copies.first(where: { isReadable($0.path) }) else { unreadable += 1; continue }
            // The best bound any copy's path names (copies share the content).
            first.pathYear = first.pathYear ?? copies.compactMap(\.pathYear).min()
            units.append(first)
        }
        var ordered = EraJob.order(units)
        if let limit, limit >= 0, ordered.count > limit { ordered = Array(ordered.prefix(limit)) }
        return EraPlan(jobID: jobID.rawValue, signer: signer, units: ordered, videoContents: byDigest.count,
                       cached: cachedCount, unreadable: unreadable)
    }
}

// MARK: - Record → journal lines (pure)

public enum EraRecordMapper {

    public struct Mapped: Sendable {
        public var lines: [ObservationLine] = []
        /// era windows the Swift ContractDecoder refused (fail-closed; never written),
        /// generation errors included.
        public var windowsInvalid = 0
        /// era windows the model never answered (`error` set: a timeout, a crash in the generation).
        public var generationErrors = 0
        /// The record carries the file's `era.none` line.
        public var eraNone: Bool { lines.contains { $0.field == EraRecordMapper.noneField } }
        /// No fused range and the model did not see the whole file (a generation
        /// error, a frame that would not rip): `lines` is empty — retry.
        public internal(set) var retryNextRun = false
        var selfConfidences: [Double] = []
        var validWindows: [[Double]] = []
    }

    /// One bench clip record (ClipService.analyze_clip) → its journal lines:
    /// `era.yearRange` per window the Swift contract accepts (through
    /// EvidenceAssertionMapper), `ocr.date` per still that read a date,
    /// one `era.fused` when the record's summary has a fused range; else, when
    /// the model saw the whole file (every frame ripped, every era window and
    /// OCR still answered), one `era.none` — the file is done for this signer,
    /// with no usable era evidence; else NOTHING (`retryNextRun`).
    public static func lines(record: Data, digest: String, info: PythonClipWorker.LoadInfo, job: String, unit: Int,
                             at: Int64) throws -> Mapped {
        guard let o = (try? JSONSerialization.jsonObject(with: record)) as? [String: Any] else {
            throw Refusal("the clip record is not a JSON object")
        }
        guard let subject = ProvenanceAssertionSubject.contentID(digest) else { throw Refusal("\(digest) is not a whole-file SHA-256") }
        let context = Context(subject: subject, info: info, job: job, unit: unit, at: at)
        var out = try windowLines(o["window_results"] as? [[String: Any]] ?? [], context)
        out.lines += try stampLines(o["results"] as? [[String: Any]] ?? [], context)
        if let fused = try fusedLine(o["summary"] as? [String: Any], windows: out, context) {
            out.lines.append(fused)
        } else if out.generationErrors > 0 || stillErrors(o) > 0 || !((o["frames_failed"] as? [Any]) ?? []).isEmpty {
            // Not a verdict: write nothing, so the planner (any line = cached) retries the file.
            out.lines = []
            out.retryNextRun = true
        } else {
            out.lines.append(try noneLine(o, windows: out, context))
        }
        return out
    }

    /// The file-level "looked, found no usable era" verdict (2026-11-02).
    /// Its field is not `era.fused` / `era.yearRange`, so MachineEraResolver
    /// never reads it as an era, and its value is not a year: nothing can
    /// make it a date (DECISIONS 2026-11-01). It exists for the caching rule.
    public static let noneField = "era.none"
    public static let noneValue = "none"

    /// OCR stills the model never answered (`error` set).
    static func stillErrors(_ o: [String: Any]) -> Int {
        (o["results"] as? [[String: Any]] ?? []).filter { r in
            r["prompt_kind"] as? String == "date" && r["error"] != nil && !(r["error"] is NSNull)
        }.count
    }

    static func noneLine(_ o: [String: Any], windows: Mapped, _ c: Context) throws -> ObservationLine {
        let eraWindows = (o["window_results"] as? [[String: Any]] ?? []).filter { $0["family"] as? String == "era" }.count
        let evidence: [String: Any] = [
            "meaning": "analyzed by this signer; no usable era evidence — not an era and not a date",
            "reason": eraWindows == 0 ? "no era window (the sampler planned none)"
                : windows.validWindows.isEmpty ? "no era window passed the contract" : "the valid windows gave no fused range",
            "eraWindows": eraWindows, "validEraWindows": windows.validWindows.count,
            "windowsRefusedByContract": windows.windowsInvalid - windows.generationErrors,
            "promptHash": c.approach.promptHash, "host": c.approach.host.label,
        ]
        return try c.line(noneField, noneValue, confidence: 0, evidence: evidence)
    }

    /// What every line of one record shares.
    struct Context {
        let subject: String
        let job: String
        let unit: Int
        let at: Int64
        let approach: ApproachDescriptor
        let hashes: [String: String]

        init(subject: String, info: PythonClipWorker.LoadInfo, job: String, unit: Int, at: Int64) {
            self.subject = subject
            self.job = job
            self.unit = unit
            self.at = at
            let reply = (try? JSONSerialization.jsonObject(with: info.json)) as? [String: Any]
            hashes = reply?["prompts_sha256"] as? [String: String] ?? [:]
            approach = ApproachDescriptor(id: info.approachID, revision: info.revision, host: SeatedApproach.eraA2.host,
                                          accepts: SeatedApproach.eraA2.accepts, emits: SeatedApproach.eraA2.emits,
                                          resources: SeatedApproach.eraA2.resources, promptHash: "sha256:" + (hashes["era"] ?? "unknown"))
        }

        func line(_ field: String, _ value: String, confidence: Double, evidence: [String: Any]) throws -> ObservationLine {
            try ObservationLine(subjectID: subject, field: field, value: value, by: approach.signer, at: at, confidence: confidence,
                                evidence: evidence, job: job, unit: unit)
        }
    }

    /// The era windows: decoded fail-closed by the Swift contract, mapped by EvidenceAssertionMapper.
    static func windowLines(_ windows: [[String: Any]], _ c: Context) throws -> Mapped {
        var out = Mapped()
        for (i, w) in windows.enumerated() where w["family"] as? String == "era" {
            if let error = w["error"], !(error is NSNull) { out.generationErrors += 1; out.windowsInvalid += 1; continue }
            guard let raw = w["raw_text"] as? String,
                  let window = w["window"] as? [Double], window.count == 2 else { out.windowsInvalid += 1; continue }
            let sample = SampleWindow(startS: window[0], endS: window[1], frameTimesS: w["frame_times_s"] as? [Double] ?? [], audioRange: nil)
            guard case .output(let output) = ContractDecoder.decode(family: .era, json: Data(raw.utf8), window: sample),
                  case .era(let era) = output.value else { out.windowsInvalid += 1; continue }
            out.selfConfidences.append(era.selfConfidence)
            out.validWindows.append(window)
            for a in EvidenceAssertionMapper.assertions(from: output, subjectDigest: "sha256:" + c.subject, approach: c.approach,
                                                         elapsedS: w["elapsed_s"] as? Double ?? 0) {
                var evidence = (try? JSONSerialization.jsonObject(with: Data(a.evidenceJSON.utf8))) as? [String: Any] ?? [:]
                evidence["window"] = window
                evidence["windowIndex"] = w["window_index"] as? Int ?? i
                out.lines.append(try c.line(a.field, a.value, confidence: era.selfConfidence, evidence: evidence))
            }
        }
        return out
    }

    /// The OCR stills: one ocr.date per still per date it read; the
    /// confidence is the share of stills that read that date.
    static func stampLines(_ results: [[String: Any]], _ c: Context) throws -> [ObservationLine] {
        let stills = results.filter { $0["prompt_kind"] as? String == "date" }
        let readings = stills.map { r -> [String] in
            guard r["error"] is NSNull || r["error"] == nil, let parsed = r["parsed"] as? [String: Any],
                  parsed["degenerate"] as? Bool != true else { return [] }
            return parsed["dates"] as? [String] ?? []
        }
        var out: [ObservationLine] = []
        for (r, dates) in zip(stills, readings) {
            for date in dates {
                let parts = date.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3 else { continue }
                let agree = readings.filter { $0.contains(date) }.count
                let evidence: [String: Any] = [
                    "atS": r["at_s"] as? Double ?? 0, "year": parts[0], "month": parts[1], "day": parts[2],
                    "rawText": String((r["raw_text"] as? String ?? "").prefix(200)), "sampler": "stills", "stills": stills.count,
                    "agreement": "\(agree)/\(stills.count)", "confidenceIs": "the share of stills that read this date (not a model's self-assessment)",
                    "promptHash": "sha256:" + (c.hashes["date"] ?? "unknown"), "host": c.approach.host.label,
                ]
                out.append(try c.line("ocr.date", date, confidence: Double(agree) / Double(stills.count), evidence: evidence))
            }
        }
        return out
    }

    /// The one file-level range bench.py fused (nil when no window answered).
    static func fusedLine(_ summary: [String: Any]?, windows: Mapped, _ c: Context) throws -> ObservationLine? {
        guard let summary, let fused = summary["fused_years"] as? [Int], fused.count == 2, fused[0] <= fused[1] else { return nil }
        let evidence: [String: Any] = [
            "yearRange": summary["year_range"] ?? NSNull(), "burnedInYears": summary["burned_in_years"] ?? [],
            "validEraWindows": windows.validWindows.count, "windows": windows.validWindows,
            "rule": "bench.py fuse_range: the windows' median range; a date stamp cited in two windows (or the only one) inside it collapses it to that year",
            "promptHash": c.approach.promptHash, "host": c.approach.host.label,
        ]
        let confidences = windows.selfConfidences
        let confidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return try c.line("era.fused", "\(fused[0])-\(fused[1])", confidence: confidence, evidence: evidence)
    }
}

// MARK: - The CLI's words (pure; the helper's --enqueue / --run read them)

/// `era [limit N] [repo PATH] [python PATH] [catalog PATH] [state-root PATH]`
/// → a request (and, for `--run`, the state folder). `repo` defaults to
/// ~/dev/VideoScan (the checkout that holds bench.py and venv-mlx on Rick's
/// Macs). Pure: a C++ reader would call it a tiny argv parser.
public struct EraCLIArguments: Equatable, Sendable {
    public var limit: Int?
    public var repoPath: String
    public var python: String?
    public var catalogPath: String?
    public var stateRoot: String?

    public static var defaultRepo: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/VideoScan").path
    }

    public static let usage = "era [limit N] [repo PATH] [python PATH] [catalog PATH] [state-root PATH]"

    /// `words` = everything after `era`.
    public static func parse(_ words: [String]) throws -> EraCLIArguments {
        var out = EraCLIArguments(limit: nil, repoPath: defaultRepo, python: nil, catalogPath: nil, stateRoot: nil)
        var i = 0
        while i < words.count {
            let key = words[i]
            guard i + 1 < words.count else { throw Refusal("era: `\(key)` needs a value — \(usage)") }
            let value = words[i + 1]
            switch key {
            case "limit":
                guard let n = Int(value), n >= 0 else { throw Refusal("era: limit must be a whole number, got \(value)") }
                out.limit = n
            case "repo": out.repoPath = value
            case "python": out.python = value
            case "catalog": out.catalogPath = value
            case "state-root": out.stateRoot = value
            default: throw Refusal("era: unknown word `\(key)` — \(usage)")
            }
            i += 2
        }
        return out
    }

    public func request(requestedBy: String) -> JobRequest {
        EraJob.request(limit: limit, repoPath: repoPath, python: python, catalogPath: catalogPath, requestedBy: requestedBy)
    }
}
