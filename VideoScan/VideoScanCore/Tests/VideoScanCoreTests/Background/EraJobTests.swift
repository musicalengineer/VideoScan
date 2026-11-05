// EraJobTests.swift — background service step 1's era/OCR job (EraJob.swift)
// against a real catalog.sqlite (GRDB, schema 14, read by the helper's
// read-only door) and the REAL bench.py worker loop hosting a fake
// ClipService (tests/fixtures/background/fake_clip_service.py; no model).
//   LOGIC      `order`: Rick's date > embedded > inferred > path year >
//              unknown (last), ties by digest; `pathYear` boundaries; the
//              plan keeps live readable video only, excludes contents cached
//              by the signer (catalog row OR journal line), honours `limit`,
//              and is FROZEN per job id (a resume plans nothing new); the
//              record mapper writes era.yearRange per valid window,
//              ocr.date per still that read a stamp, one era.fused — or one
//              era.none (no usable era; never a year) — or NOTHING when there
//              is no fused range and a window/still was a generation error or
//              a frame would not rip (Codex 2026-11-02 F1/F2); the planner skips a file whose only line by
//              the signer is era.none (journal or applied row), per signer.
//   REGRESSION a file with no usable era was re-analyzed every run (2026-11-02).
//   TRUTH      every line is signed by the worker's own load reply; START
//              names the approach, the file count and the order rule;
//              OUTCOME names assertions written, s/clip and the worker's RSS.
//   ISOLATION  a worker death and a clip past its cap fail THAT unit and the
//              job goes on; kill mid-unit (after the journal append, before
//              the checkpoint) → the relaunch skips the unit: no second set
//              of lines; a duplicate line, were one written, applies once; a
//              corrupt checkpoint restarts from zero, says so, and writes no
//              duplicate; a newer catalog schema is refused at plan.
//   LOGIC      no keyboard backoff (2026-11-04): the unit runs at once.
//   SCALE      order + pathYear over 100k candidates inside a budget.
// Synthetic digests and paths only.

import Foundation
import Testing
@testable import VideoScanCore

/// A factory over a fixed Setup (the job id comes from the request). It
/// keeps every job it made so a test can close the worker of a job whose
/// process "died" (abandonForTest never calls end()).
final class EraTestFactory: JobFactory, @unchecked Sendable {
    let make: @Sendable (JobID) -> EraJob.Setup
    private let lock = NSLock()
    private var made: [EraJob] = []
    init(make: @escaping @Sendable (JobID) -> EraJob.Setup) { self.make = make }
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        let job = try EraJob(make(request.id))
        lock.lock(); made.append(job); lock.unlock()
        return job
    }
    /// Close every worker this factory's jobs spawned (the OS reaping a dead process's child).
    func closeWorkers() async {
        for job in jobs { await job.worker.close() }
    }
    private var jobs: [EraJob] { lock.lock(); defer { lock.unlock() }; return made }
}

final class LogLines: BackgroundLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func write(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Suite("EraJob — logic")
struct EraJobLogicTests {

    @Test func orderIsOldestFirstByTheBestBoundUnknownLast() {
        let c = [
            EraCandidate(digest: "e", path: "/x", durationS: 1),                                   // unknown
            EraCandidate(digest: "d", path: "/x", durationS: 1, pathYear: 1975),
            EraCandidate(digest: "c", path: "/x", durationS: 1, inferredYear: 1980, pathYear: 1960), // inferred beats path
            EraCandidate(digest: "b", path: "/x", durationS: 1, embeddedYear: 2003, inferredYear: 1970),
            EraCandidate(digest: "a", path: "/x", durationS: 1, userYear: 1991, embeddedYear: 1950), // Rick's beats embedded
            EraCandidate(digest: "f", path: "/x", durationS: 1, pathYear: 1975),                   // tie with d → digest
        ]
        // d, f: path 1975 (tie → digest) · c: inferred 1980 (beats its path 1960) · a: Rick's 1991 (beats embedded 1950)
        // · b: embedded 2003 (beats inferred 1970) · e: unknown, last.
        #expect(EraJob.order(c).map(\.digest) == ["d", "f", "c", "a", "b", "e"])
        #expect(c[4].bound?.source == "user")
        #expect(c[0].bound == nil)
    }

    @Test func pathYearIsAFourDigitRunClosestToTheFile() {
        #expect(EraJob.pathYear("/Volumes/T/1991 Cape/clip.mov") == 1991)
        #expect(EraJob.pathYear("/Volumes/T/2003 transfers/1985 tape.mov") == 1985)
        #expect(EraJob.pathYear("/Volumes/T/IMG_19910.mov") == nil)
        #expect(EraJob.pathYear("/Volumes/T/1899/a.mov") == nil)
        #expect(EraJob.pathYear("/Volumes/T/2029/a.mov") == 2029)
        #expect(EraJob.pathYear("/Volumes/T/2030/a.mov") == nil)
        #expect(EraJob.pathYear("/a/b.mov") == nil)
    }

    @Test func theMapperWritesWindowsStampsAndOneFusedLine() throws {
        let info = PythonClipWorker.LoadInfo(approachID: SeatedApproach.eraA2ID, revision: 3, model: "m",
                                             json: Data(#"{"prompts_sha256":{"era":"ee","date":"dd"}}"#.utf8))
        let window = ["family": "era", "window": [10.0, 70.0], "yearRange": [1990, 1994], "rationale": "r",
                      "cues": [["kind": "onScreenText", "text": "JUN 21 1991", "atS": 12.0]], "selfConfidence": 0.8] as [String: Any]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: window), as: UTF8.self)
        let record: [String: Any] = [
            "window_results": [["family": "era", "window": [10.0, 70.0], "frame_times_s": [12.0, 20.0], "raw_text": raw, "error": NSNull(), "window_index": 0],
                               ["family": "era", "window": [80.0, 140.0], "frame_times_s": [90.0], "raw_text": "nope", "error": NSNull(), "window_index": 1]],
            "results": [["prompt_kind": "date", "at_s": 5.0, "raw_text": "JUN 21 1991", "error": NSNull(),
                         "parsed": ["dates": ["1991-06-21"], "degenerate": false]],
                        ["prompt_kind": "date", "at_s": 50.0, "raw_text": "NONE", "error": NSNull(), "parsed": ["dates": [], "degenerate": false]]],
            "summary": ["fused_years": [1991, 1991], "year_range": [1990.0, 1994.0], "burned_in_years": [1991]],
        ]
        let mapped = try EraRecordMapper.lines(record: try JSONSerialization.data(withJSONObject: record), digest: "sha256:" + EraFixture.hex(7),
                                               info: info, job: "J", unit: 4, at: 1_762_000_000)
        #expect(mapped.lines.map(\.field) == ["era.yearRange", "ocr.date", "era.fused"])
        #expect(mapped.windowsInvalid == 1, "the Swift contract refused the second window")
        #expect(mapped.lines.allSatisfy { $0.by == "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3" && $0.subjectID == EraFixture.hex(7) })
        #expect(mapped.lines[0].value == "1990-1994")
        #expect(mapped.lines[0].confidence == 0.8)
        #expect(mapped.lines[0].evidenceJSON.contains(#""window":[10,70]"#))
        #expect(mapped.lines[1].value == "1991-06-21")
        #expect(mapped.lines[1].confidence == 0.5, "1 of 2 stills read it")
        #expect(mapped.lines[2].value == "1991-1991")
        #expect(mapped.lines.allSatisfy { $0.unit == 4 && $0.at == 1_762_000_000 })
        #expect(!mapped.eraNone && !mapped.retryNextRun, "a fused file gets no era.none")
    }

    static let info = PythonClipWorker.LoadInfo(approachID: SeatedApproach.eraA2ID, revision: 3, model: "m",
                                                json: Data(#"{"prompts_sha256":{"era":"ee","date":"dd"}}"#.utf8))

    static func map(_ record: [String: Any]) throws -> EraRecordMapper.Mapped {
        try EraRecordMapper.lines(record: try JSONSerialization.data(withJSONObject: record), digest: EraFixture.hex(7), info: info,
                                  job: "J", unit: 0, at: 1_762_000_000)
    }

    static func window(_ i: Int, raw: String, error: Any = NSNull()) -> [String: Any] {
        ["family": "era", "window": [Double(i * 60), Double(i * 60 + 60)], "frame_times_s": [Double(i * 60 + 5)], "raw_text": raw,
         "error": error, "window_index": i]
    }

    @Test func noUsableWindowGivesExactlyOneEraNoneWithItsEvidenceAndNoYear() throws {
        let mapped = try Self.map(["window_results": [Self.window(0, raw: "not json"), Self.window(1, raw: "{}")],
                                   "results": [["prompt_kind": "date", "at_s": 5.0, "raw_text": "NONE", "error": NSNull(),
                                                "parsed": ["dates": [], "degenerate": false]]],
                                   "frames_failed": [],
                                   "summary": ["fused_years": NSNull(), "year_range": NSNull(), "burned_in_years": []]])
        #expect(mapped.lines.map(\.field) == [EraRecordMapper.noneField])
        #expect(EraRecordMapper.noneField == "era.none" && EraRecordMapper.noneValue == "none", "the wire name is pinned")
        let line = try #require(mapped.lines.first)
        #expect(line.value == "none" && line.confidence == 0 && line.subjectID == EraFixture.hex(7))
        #expect(line.by == "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3")
        #expect(MachineEraResolver.range(line.value) == nil, "the value is not a year range")
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(line.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["reason"] as? String == "no era window passed the contract")
        #expect(evidence["eraWindows"] as? Int == 2 && evidence["validEraWindows"] as? Int == 0)
        #expect(evidence["windowsRefusedByContract"] as? Int == 2)
        #expect(evidence["promptHash"] as? String == "sha256:ee")
        #expect(mapped.eraNone && !mapped.retryNextRun && mapped.generationErrors == 0)
    }

    @Test func aRecordWithNoEraWindowAtAllIsDoneToo() throws {
        let mapped = try Self.map(["window_results": [], "results": [], "summary": ["fused_years": NSNull()]])
        #expect(mapped.lines.map(\.field) == ["era.none"])
        #expect(mapped.lines.first?.evidenceJSON.contains("no era window (the sampler planned none)") == true)
    }

    @Test func aGenerationErrorIsNotEvidenceNoEraNoneRetryNextRun() throws {
        let mapped = try Self.map(["window_results": [Self.window(0, raw: "", error: "GenerationTimeout: 120 s"), Self.window(1, raw: "not json")],
                                   "results": [], "summary": ["fused_years": NSNull()]])
        #expect(mapped.lines.isEmpty)
        #expect(mapped.generationErrors == 1 && mapped.windowsInvalid == 2)
        #expect(!mapped.eraNone && mapped.retryNextRun)
    }

    @Test func aStampWithoutAFusedRangeStillGetsItsEraNone() throws {
        // ocr.date lines alone used to cache the file with no era verdict at all.
        let mapped = try Self.map(["window_results": [Self.window(0, raw: "not json")],
                                   "results": [["prompt_kind": "date", "at_s": 5.0, "raw_text": "JUN 21 1991", "error": NSNull(),
                                                "parsed": ["dates": ["1991-06-21"], "degenerate": false]]],
                                   "summary": ["fused_years": NSNull()]])
        #expect(mapped.lines.map(\.field) == ["ocr.date", "era.none"])
    }

    // Codex era.none pass (2026-11-02), closed against the invariant "a
    // transient failure never leaves a file cached for its signer without a
    // real verdict": the planner caches on ANY line, so a record with no
    // fused range and any sign the model did not see the whole file writes
    // NOTHING — not just no era.none — and the retry is real.

    static let validEraRaw: String = {
        let w = ["family": "era", "window": [60.0, 120.0], "yearRange": [1990, 1994], "rationale": "r", "cues": [],
                 "selfConfidence": 0.6] as [String: Any]
        return (try? JSONSerialization.data(withJSONObject: w)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }()
    // Computed (a fresh dictionary per read): `[String: Any]` is not Sendable, so it cannot be a stored static.
    static var stampStill: [String: Any] { ["prompt_kind": "date", "at_s": 5.0, "raw_text": "JUN 21 1991", "error": NSNull(),
                                            "parsed": ["dates": ["1991-06-21"], "degenerate": false]] }

    /// F1: every frame failed to rip → no window, no model call; not a verdict.
    @Test func framesThatWouldNotRipAreNotAVerdictNothingIsWritten() throws {
        let none = try Self.map(["window_results": [], "results": [],
                                 "frames_failed": [["frame_index": 0], ["frame_index": 1], ["frame_index": 2]],
                                 "summary": ["fused_years": NSNull()]])
        #expect(none.lines.isEmpty && none.retryNextRun && !none.eraNone)
        // Partial: one window's frames would not rip, the other was refused by the contract.
        let partial = try Self.map(["window_results": [Self.window(1, raw: "not json")], "results": [],
                                    "frames_failed": [["frame_index": 0, "window_index": 0]], "summary": ["fused_years": NSNull()]])
        #expect(partial.lines.isEmpty && partial.retryNextRun)
    }

    /// F2: a generation error beside ocr.date or a valid window used to write those lines, which cached the file.
    @Test func aGenerationErrorBesideOtherObservationsWritesNothingSoTheRetryIsReal() throws {
        let withStamp = try Self.map(["window_results": [Self.window(0, raw: "", error: "GenerationTimeout: 120 s")],
                                      "results": [Self.stampStill], "summary": ["fused_years": NSNull()]])
        #expect(withStamp.lines.isEmpty && withStamp.retryNextRun)
        let withWindow = try Self.map(["window_results": [Self.window(0, raw: "", error: "GenerationTimeout: 120 s"),
                                                          Self.window(1, raw: Self.validEraRaw)],
                                       "results": [], "summary": ["fused_years": NSNull()]])
        #expect(withWindow.lines.isEmpty && withWindow.retryNextRun)
    }

    /// The same invariant on the OCR side: a still the model never answered is not "no date read".
    @Test func anOCRStillGenerationErrorWithoutAFusedRangeWritesNothing() throws {
        let mapped = try Self.map(["window_results": [Self.window(0, raw: "not json")],
                                   "results": [["prompt_kind": "date", "at_s": 5.0, "raw_text": "", "error": "GenerationTimeout: 60 s",
                                                "parsed": ["dates": [], "degenerate": false]], Self.stampStill],
                                   "summary": ["fused_years": NSNull()]])
        #expect(mapped.lines.isEmpty && mapped.retryNextRun)
    }

    /// Which wins: a fused range is a verdict — it is written even beside a transient failure.
    @Test func aFusedRangeWinsOverATransientFailure() throws {
        let mapped = try Self.map(["window_results": [Self.window(0, raw: "", error: "GenerationTimeout: 120 s"),
                                                      Self.window(1, raw: Self.validEraRaw)],
                                   "results": [], "frames_failed": [["frame_index": 9]],
                                   "summary": ["fused_years": [1990, 1994]]])
        #expect(mapped.lines.map(\.field) == ["era.yearRange", "era.fused"])
        #expect(!mapped.retryNextRun && !mapped.eraNone)
    }
}

@Suite("EraJob — the planner honours era.none")
struct EraPlannerEraNoneTests {

    static func noneLine(_ n: Int, by: String = SeatedApproach.eraA2.signer) throws -> ObservationLine {
        try ObservationLine(subjectID: EraFixture.hex(n), field: "era.none", value: "none", by: by, at: 1, confidence: 0,
                            evidence: ["meaning": "no usable era evidence"], job: "old", unit: 0)
    }

    /// Isolation: the journal holds NOTHING but one era.none line (no era, no date) — it alone caches the file.
    @Test func aJournalWithOnlyAnEraNoneLineCachesTheFile() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/b.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        try ObservationJournal(directory: root.appendingPathComponent("journal")).append([try Self.noneLine(1)])
        let job = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(job.plan.units.map(\.digest) == [EraFixture.hex(2)])
        #expect(job.plan.cached == 1)
        await job.end()
    }

    /// After the app applied it (journal gone or rotated): the catalog row alone caches the file.
    @Test func anAppliedEraNoneRowCachesTheFile() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/b.mov")])
        defer { fixture.remove() }
        try EraFixture.execute(fixture, """
            INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
            VALUES ('content', ?, 'era.none', 'none', 'inferred', ?, 1, 0, '{}')
            """, [EraFixture.hex(2), SeatedApproach.eraA2.signer])
        let job = try EraJob(EraFixture.setup(fixture, root: try EraFixture.stateRoot()))
        #expect(job.plan.units.map(\.digest) == [EraFixture.hex(1)])
        #expect(job.plan.cached == 1)
        await job.end()
    }

    /// Caching is per signer: another prompt revision's era.none does not stop this signer from looking.
    @Test func anotherSignersEraNoneDoesNotCache() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        try ObservationJournal(directory: root.appendingPathComponent("journal")).append([
            try Self.noneLine(1, by: "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r2")])
        let job = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(job.plan.units.map(\.digest) == [EraFixture.hex(1)])
        await job.end()
    }
}

@Suite("EraJob — plan, run, isolation", .serialized)
struct EraJobRunTests {

    static let files: [EraFixture.File] = [
        EraFixture.File(n: 1, path: "/synthetic/2005/a.mov", embedded: 1_120_000_000),            // 2005 embedded
        EraFixture.File(n: 2, path: "/synthetic/stamp/b.mov", userYear: "1991"),                  // Rick's 1991
        EraFixture.File(n: 3, path: "/synthetic/1984 tape/c.mov"),                                // path 1984
        EraFixture.File(n: 4, path: "/synthetic/audio.m4a", stream: "Audio only"),                // not video
        EraFixture.File(n: 5, path: "/synthetic/gone.mov", removed: true),                       // removed
        EraFixture.File(n: 6, path: "/synthetic/nodate.mov"),                                     // unknown
    ]

    @Test func thePlanKeepsLiveReadableVideoOrdersItExcludesTheCachedAndIsFrozen() async throws {
        let fixture = try await EraFixture.catalog(Self.files + [EraFixture.File(n: 7, path: "/synthetic/unreadable.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        // Content 6 already has a catalog row by the signer; content 1 a journal line.
        try EraFixture.execute(fixture, """
            INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
            VALUES ('content', ?, 'era.fused', '1990-1995', 'inferred', ?, 1, 0.5, '{}')
            """, [EraFixture.hex(6), SeatedApproach.eraA2.signer])
        try ObservationJournal(directory: root.appendingPathComponent("journal")).append([
            try ObservationLine(subjectID: EraFixture.hex(1), field: "era.fused", value: "2000-2005", by: SeatedApproach.eraA2.signer,
                                at: 1, confidence: 0.5, evidence: [:], job: "old", unit: 0)])
        let id = JobID()
        let job = try EraJob(EraFixture.setup(fixture, root: root, jobID: id, readable: { !$0.contains("unreadable") }))
        #expect(job.plan.units.map(\.digest) == [EraFixture.hex(3), EraFixture.hex(2)], "1984 path, Rick's 1991; 1 and 6 cached")
        #expect(job.plan.cached == 2)
        #expect(job.plan.unreadable == 1)
        #expect(job.plan.videoContents == 5)
        #expect(job.startDetail.contains(EraJob.orderRule))
        // Frozen: the catalog changes, the same job id plans nothing new.
        try EraFixture.execute(fixture, "INSERT INTO user_dates (digest, value, confidence) VALUES (?, '1950', 'known')", [EraFixture.hex(6)])
        #expect(try EraJob(EraFixture.setup(fixture, root: root, jobID: id)).plan == job.plan)
        #expect(try EraJob(EraFixture.setup(fixture, root: root, jobID: id, limit: 1)).plan.units.count == 2, "a resume never re-plans")
        #expect(try EraJob(EraFixture.setup(fixture, root: root, limit: 1)).plan.units.count == 1, "a new job honours limit")
        await job.end()
        #expect(FileManager.default.fileExists(atPath: EraJob.planURL(root, id).path),
                "end keeps the plan: a crash before the checkpoint goes must resume the SAME list (Codex #239 F1)")
        await job.forget()
        #expect(!FileManager.default.fileExists(atPath: EraJob.planURL(root, id).path), "forget, after the checkpoint is gone, removes it")
        await #expect(throws: Refusal.self) { _ = try await job.runUnit(job.plan.units.count) }
    }

    @Test func aNewerCatalogSchemaIsRefusedAtPlan() async throws {
        let fixture = try await EraFixture.catalog([])
        defer { fixture.remove() }
        try EraFixture.execute(fixture, "UPDATE catalog_state SET schema_version = 99 WHERE singleton = 1", [])
        #expect(throws: Refusal.self) { _ = try EraJob(EraFixture.setup(fixture, root: try EraFixture.stateRoot())) }
    }

    @Test func theJobRunsSignsEveryLineFromTheWorkerAndSaysItAtStartAndOutcome() async throws {
        let fixture = try await EraFixture.catalog(Self.files)
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let log = LogLines()
        let checkpoints = InMemoryCheckpointStore()
        let factory = EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0) }
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: checkpoints, factory: factory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        let request = JobRequest(kind: .era, lane: "model", requestedBy: "test")
        guard case .accepted = await supervisor.enqueue(request) else { Issue.record("refused"); return }
        await supervisor.drain()
        let lines = try EraFixture.lines(root)
        let byDigest = Dictionary(grouping: lines, by: \.subjectID)
        #expect(byDigest.keys.sorted() == [EraFixture.hex(1), EraFixture.hex(2), EraFixture.hex(3), EraFixture.hex(6)])
        let stamp = byDigest[EraFixture.hex(2)] ?? []
        #expect(stamp.filter { $0.field == "era.yearRange" }.count == 3)
        #expect(stamp.filter { $0.field == "ocr.date" }.count == 5)
        #expect(stamp.filter { $0.field == "era.fused" }.map(\.value) == ["1991-1991"])
        #expect((byDigest[EraFixture.hex(1)] ?? []).filter { $0.field == "era.fused" }.map(\.value) == ["1991-1995"])
        #expect(lines.allSatisfy { $0.by == "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3" && $0.job == request.id.rawValue })
        let start = log.lines.first { $0.hasPrefix("START era") } ?? ""
        #expect(start.contains("4 units") && start.contains("approach machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3") && start.contains(EraJob.orderRule), "\(start)")
        let outcome = log.lines.first { $0.hasPrefix("OUTCOME era") } ?? ""
        #expect(outcome.contains("finished: 4 run · 0 skipped · 0 failed"), "\(outcome)")
        #expect(outcome.contains("\(lines.count) assertions written") && outcome.contains("s/clip") && outcome.contains("worker peak RSS"), "\(outcome)")
        #expect(!outcome.contains("worker peak RSS not measured"))
        #expect(!FileManager.default.fileExists(atPath: EraJob.planURL(root, request.id).path))
    }

    /// Regression (STATUS "To file", 2026-11-02): a file the 8B looked at and
    /// found no usable era in wrote NOTHING, so the next job planned it again —
    /// forever. It now gets one `era.none` line, and the next plan skips it.
    @Test func aFileWithNoUsableEraIsAnalyzedOnceNotEveryRun() async throws {
        let fixture = try await EraFixture.catalog([
            EraFixture.File(n: 1, path: "/synthetic/1970/blank.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/a.mov"),
        ])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let first = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(first.plan.units.count == 2)
        for i in 0..<first.unitCount { #expect(try await first.runUnit(i) == .done) }
        await first.end()
        let blank = try EraFixture.lines(root).filter { $0.subjectID == EraFixture.hex(1) }
        #expect(blank.map(\.field) == ["era.none"], "exactly one era.none line, no era, no date")
        #expect(blank.first?.value == "none")
        let second = try EraJob(EraFixture.setup(fixture, root: root))
        defer { Task { await second.end() } }
        #expect(second.plan.units.isEmpty, "the next job re-analyzes nothing: \(second.plan.units.map(\.path))")
        #expect(second.plan.cached == 2)
    }

    /// A generation error is not "no evidence": nothing is cached, the file is retried.
    @Test func aWindowGenerationErrorWritesNoEraNoneAndTheFileIsRetried() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/generr.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let first = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(try await first.runUnit(0) == .done)
        let words = await first.outcomeDetail()
        await first.end()
        #expect(try EraFixture.lines(root).isEmpty)
        #expect(words.contains("tried again next run: 0 frames would not decode, 1 model never answered"), "\(words)")
        let second = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(second.plan.units.map(\.digest) == [EraFixture.hex(1)])
        await second.end()
    }

    /// Codex F2 at run level: generation errors beside five ocr.date stills —
    /// nothing written, the next plan still holds the file.
    @Test func aGenerationErrorBesideAStampIsRetriedNotCached() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/generr-stamp.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let first = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(try await first.runUnit(0) == .done)
        await first.end()
        #expect(try EraFixture.lines(root).isEmpty, "no ocr.date either: any line would cache the file")
        let second = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(second.plan.units.map(\.digest) == [EraFixture.hex(1)])
        await second.end()
    }

    /// Codex F1 at run level: every frame failed to rip (the file still
    /// readable) — no era.none, the next plan still holds the file.
    @Test func framesThatWouldNotRipAreRetriedNotCached() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/ripfail.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let first = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(try await first.runUnit(0) == .done)
        let words = await first.outcomeDetail()
        await first.end()
        #expect(try EraFixture.lines(root).isEmpty)
        #expect(words.contains("tried again next run: 1 frames would not decode"), "\(words)")
        let second = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(second.plan.units.map(\.digest) == [EraFixture.hex(1)])
        await second.end()
    }

    /// The file vanished while the model looked at it (a drive unplugged): no
    /// verdict is cached on a file that was not there — the unit fails as unreadable.
    @Test func aFileThatVanishedDuringAnalysisGetsNoEraNone() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/blank.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let calls = ReadableCalls()
        let job = try EraJob(EraFixture.setup(fixture, root: root, readable: { _ in calls.next() <= 2 }))   // plan + pre-check
        await #expect(throws: Refusal.self) { _ = try await job.runUnit(0) }
        await job.end()
        #expect(try EraFixture.lines(root).isEmpty)
    }

    @Test func aWorkerDeathAndAClipPastItsCapFailThatUnitAndTheJobGoesOn() async throws {
        let fixture = try await EraFixture.catalog([
            EraFixture.File(n: 1, path: "/synthetic/1970/die.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/hang.mov"),
            EraFixture.File(n: 3, path: "/synthetic/1972/ok.mov"),
        ])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let log = LogLines()
        let factory = EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0, clipTimeout: .seconds(3)) }
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: factory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        _ = await supervisor.enqueue(JobRequest(kind: .era, requestedBy: "test"))
        await supervisor.drain()
        let outcome = log.lines.first { $0.hasPrefix("OUTCOME era") } ?? ""
        #expect(outcome.contains("finished: 3 run · 0 skipped · 0 failed"), "a counted try is progress (Fable review 11/04): \(outcome)")
        #expect(outcome.contains("1 timeout, 1 worker death"), "\(outcome)")
        #expect(Set(try EraFixture.lines(root).map(\.subjectID)) == [EraFixture.hex(3)])
    }

    @Test func killMidUnitThenRelaunchSkipsTheUnitAndWritesNoSecondSet() async throws {
        let fixture = try await EraFixture.catalog([
            EraFixture.File(n: 1, path: "/synthetic/1970/a.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/b.mov"),
            EraFixture.File(n: 3, path: "/synthetic/1972/c.mov"),
        ])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let queue = InMemoryJobQueueStore()
        let checkpoints = InMemoryCheckpointStore()
        let killer = SupervisorBox()
        let firstFactory = EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0, afterAppend: { index in
            if index == 1 { await killer.supervisor?.abandonForTest() }
        }) }
        let first = JobSupervisor(queue: queue, checkpoints: checkpoints, factory: firstFactory,
                                  backoff: BackgroundFixtures.fullBackoff(), log: LogLines(), configuration: BackgroundFixtures.fastConfiguration())
        killer.supervisor = first
        let request = JobRequest(kind: .era, requestedBy: "test")
        _ = await first.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil(.seconds(30)) { checkpoints.checkpoint(request.id)?.completedUnits == 1 && Set((try? EraFixture.lines(root))?.map(\.subjectID) ?? []).count == 2 })
        // Unit 1's lines are in the journal, its checkpoint is not: the process "died".
        try await Task.sleep(for: .milliseconds(300))
        #expect(checkpoints.checkpoint(request.id)?.completedUnits == 1)
        let before = try EraFixture.lines(root)
        // Its worker is an orphan of the "dead" process; reap it the way the OS would.
        await firstFactory.closeWorkers()
        let log = LogLines()
        let second = JobSupervisor(queue: queue, checkpoints: checkpoints, factory: EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0) },
                                   backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        await second.start()
        await second.drain()
        let after = try EraFixture.lines(root)
        let perDigest = Dictionary(grouping: after, by: \.subjectID).mapValues(\.count)
        let oneSet = Dictionary(grouping: before, by: \.subjectID).mapValues(\.count)[EraFixture.hex(2)]
        #expect(perDigest[EraFixture.hex(2)] == oneSet, "unit 1 was not written twice")
        #expect(Set(after.map(\.subjectID)) == [EraFixture.hex(1), EraFixture.hex(2), EraFixture.hex(3)])
        let outcome = log.lines.first { $0.hasPrefix("OUTCOME era") && $0.contains("finished") } ?? ""
        #expect(outcome.contains("2 run · 1 skipped · 0 failed"), "unit 0 from the first life, unit 1 skipped, unit 2 run: \(outcome)")
        #expect(log.lines.contains { $0.contains("interrupted at 1 of 3") })
    }

    @Test func aDuplicateLineWereOneWrittenAppliesOnce() async throws {
        let catalogFixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/stamp.mov")])
        defer { catalogFixture.remove() }
        let root = try EraFixture.stateRoot()
        let job = try EraJob(EraFixture.setup(catalogFixture, root: root))
        _ = try await job.runUnit(0)
        await job.end()
        let lines = try EraFixture.lines(root)
        try ObservationJournal(directory: root.appendingPathComponent("journal")).append(lines)   // the same lines again
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: catalogFixture.url) == .readWrite)
        let all = try EraFixture.lines(root).map { JournalApplicationTests.readLine($0) }
        #expect(all.count == 2 * lines.count)
        let outcome = try JournalApplicationTests.apply(repository, all)
        #expect(outcome.applied == lines.count)
        #expect(outcome.duplicates == lines.count)
        await repository.close()
    }

    @Test func aCorruptCheckpointRestartsFromZeroSaysSoAndWritesNoDuplicate() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/b.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let request = JobRequest(kind: .era, requestedBy: "test")
        // A first run wrote unit 0's lines and a checkpoint that is now garbage.
        let job = try EraJob(EraFixture.setup(fixture, root: root, jobID: request.id))
        _ = try await job.runUnit(0)
        await job.worker.close()
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(JobCheckpoint(jobID: request.id, totalUnits: 2))
        checkpoints.markCorrupt(request.id)
        let log = LogLines()
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                                       factory: EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0) },
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        await supervisor.start()
        await supervisor.drain()
        #expect(log.lines.contains { $0.contains("is unreadable") && $0.contains("restarts from zero") })
        let counts = Dictionary(grouping: try EraFixture.lines(root), by: \.subjectID).mapValues(\.count)
        #expect(counts[EraFixture.hex(1)] == 4, "3 windows + fused, once")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME era") && $0.contains("1 run · 1 skipped") })
    }

    @Test("no keyboard backoff (2026-11-04): the model loads and the unit runs at once, with no wait line")
    func runsWithoutAWait() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let loads = ClipWorkerFixture.temporaryFile("era-loads")
        defer { try? FileManager.default.removeItem(at: loads) }
        let log = LogLines()
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                                       factory: EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0, log: loads) },
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        _ = await supervisor.enqueue(JobRequest(kind: .era, requestedBy: "test"))
        await supervisor.drain()
        #expect(ClipWorkerFixture.lines(loads).first == "load")
        #expect(!log.lines.contains { $0.contains(" waits at ") }, "no unit defers")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME era") && $0.contains("1 run") })
    }

    @Test(.timeLimit(.minutes(2)))
    func orderAndPathYearOverOneHundredThousandInsideABudget() {
        let candidates = (0..<100_000).map { i in
            EraCandidate(digest: EraFixture.hex(i), path: "/Volumes/T/\(1960 + i % 60) box/clip \(i).mov", durationS: 60,
                         userYear: i % 7 == 0 ? 1990 : nil, embeddedYear: i % 11 == 0 ? 2004 : nil)
        }
        let clock = ContinuousClock()
        let loadBefore = TimingBudget.sampleLoad()
        var ordered: [EraCandidate] = []
        let took = clock.measure {
            let withPath = candidates.map { c -> EraCandidate in var c = c; c.pathYear = EraJob.pathYear(c.path); return c }
            ordered = EraJob.order(withPath)
        }
        #expect(ordered.count == 100_000)
        let years = ordered.map { $0.bound?.year ?? Int.max }
        #expect(zip(years, years.dropFirst()).allSatisfy { $0 <= $1 }, "oldest first, unknown last")
        print("EraJob scale: pathYear + order over 100k in \(took)")
        expectWithinTimingBudget("pathYear + order over 100k candidates", measured: took, budget: .seconds(20), loadBefore: loadBefore)
    }
}

final class SupervisorBox: @unchecked Sendable {
    var supervisor: JobSupervisor?
}

/// Counts `isReadable` calls (1-based), so a test can make the file vanish mid-unit.
final class ReadableCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

@Suite("EraJob — the CLI's words and the factory's refusals")
struct EraJobCLITests {

    @Test func theCLIWordsParseAndRefuseInWords() throws {
        let a = try EraCLIArguments.parse(["limit", "2", "repo", "/r", "python", "/p/python3", "catalog", "/c/catalog.sqlite", "state-root", "/s"])
        #expect(a == EraCLIArguments(limit: 2, repoPath: "/r", python: "/p/python3", catalogPath: "/c/catalog.sqlite", stateRoot: "/s"))
        #expect(try EraCLIArguments.parse([]).repoPath.hasSuffix("/dev/VideoScan"))
        #expect(throws: Refusal.self) { _ = try EraCLIArguments.parse(["limit"]) }
        #expect(throws: Refusal.self) { _ = try EraCLIArguments.parse(["limit", "-1"]) }
        #expect(throws: Refusal.self) { _ = try EraCLIArguments.parse(["frames", "8"]) }
        let request = a.request(requestedBy: "cli")
        #expect(request.kind == .era)
        #expect(request.parameters == ["limit": "2", "repoPath": "/r", "python": "/p/python3", "catalogPath": "/c/catalog.sqlite"])
    }

    @Test func theFactoryRefusesAMissingRepoMissingWeightsAndAnUnknownKindInWords() throws {
        let factory = DefaultJobFactory(stateRoot: try EraFixture.stateRoot())
        func words(_ r: JobRequest) -> String {
            do { _ = try factory.makeJob(for: r); return "accepted" } catch { return (error as? Refusal)?.words ?? "\(error)" }
        }
        #expect(words(JobRequest(kind: .era, requestedBy: "t")).contains("`repoPath` is required"))
        #expect(words(JobRequest(kind: .era, parameters: ["repoPath": "/r", "modelDir": "/nonexistent"], requestedBy: "t")).contains("weights are not on this Mac"))
        #expect(words(JobRequest(kind: .era, parameters: ["repoPath": "/r", "limit": "x"], requestedBy: "t")).contains("whole number"))
        #expect(words(JobRequest(kind: JobKind(rawValue: "captions"), requestedBy: "t")).contains("this build knows: noop, era"))
        #expect(DefaultJobFactory().stateRoot == nil)
    }
}
