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
//              ocr.date per still that read a stamp, one era.fused.
//   TRUTH      every line is signed by the worker's own load reply; START
//              names the approach, the file count and the order rule;
//              OUTCOME names assertions written, s/clip and the worker's RSS.
//   ISOLATION  a worker death and a clip past its cap fail THAT unit and the
//              job goes on; kill mid-unit (after the journal append, before
//              the checkpoint) → the relaunch skips the unit: no second set
//              of lines; a duplicate line, were one written, applies once; a
//              corrupt checkpoint restarts from zero, says so, and writes no
//              duplicate; a newer catalog schema is refused at plan.
//   SENSOR     Backoff trickle: no model load while Rick is at the keyboard
//              (the fake worker's load log stays empty), then it runs.
//   SCALE      order + pathYear over 100k candidates inside a budget.
// Synthetic digests and paths only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

enum EraFixture {
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    struct File {
        var n: Int
        var path: String
        var duration: Double = 120
        var stream = "Video+Audio"
        var removed = false
        var userYear: String?
        var embedded: Int64?
        var inferred: Int64?
    }

    /// A catalog.sqlite at schema 14 holding `files` (one content each).
    static func catalog(_ files: [File]) async throws -> StoreFixture {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
                for f in files {
                    try db.execute(sql: "INSERT OR IGNORE INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [hex(f.n)])
                    let dir = (f.path as NSString).deletingLastPathComponent
                    try db.execute(sql: """
                        INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                                           digest_computed_at, digest_source, stream_type, duration_s, lifecycle, archive_stage,
                                           volume_case_sensitive, embedded_created_at, embedded_created_source,
                                           removal_state, removal_since, removal_reason)
                        VALUES (?, ?, '', ?, ?, ?, 'mov', ?, 100, 1, 'archiveFixity', ?, ?, 'Cataloged', 'None', 0, ?, ?, ?, ?, ?)
                        """, arguments: [String(format: "00000000-0000-0000-0000-%012X", f.n), hex(f.n), f.path, f.path.lowercased(),
                                         (f.path as NSString).lastPathComponent, dir, f.stream, f.duration,
                                         f.embedded, f.embedded.map { _ in "creation_time" },
                                         f.removed ? "removedFromCatalog" : nil, f.removed ? 1 : nil, f.removed ? "test" : nil])
                    if let y = f.userYear {
                        try db.execute(sql: "INSERT INTO user_dates (digest, value, confidence) VALUES (?, ?, 'known')", arguments: [hex(f.n), y])
                    }
                    if let i = f.inferred {
                        try db.execute(sql: "INSERT INTO inferred_dates (digest, date_at, confidence, source) VALUES (?, ?, 0.5, 'folder-year')",
                                       arguments: [hex(f.n), i])
                    }
                }
                return .commit
            }
        }
        return fixture
    }

    static func stateRoot() throws -> URL { try BackgroundFixtures.scratch("era") }

    static func setup(_ fixture: StoreFixture, root: URL, jobID: JobID = JobID(), limit: Int? = nil, clipTimeout: Duration = .seconds(20),
                      log: URL? = nil, backoff: Backoff? = nil, readable: @escaping @Sendable (String) -> Bool = { _ in true },
                      afterAppend: (@Sendable (Int) async -> Void)? = nil) -> EraJob.Setup {
        EraJob.Setup(jobID: jobID, catalogURL: fixture.url, stateRoot: root,
                     worker: ClipWorkerFixture.configuration(clipTimeout: clipTimeout, log: log),
                     limit: limit, backoff: backoff, isReadable: readable, afterJournalAppend: afterAppend)
    }

    static func lines(_ root: URL) throws -> [ObservationLine] {
        let journal = ObservationJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
        var out: [ObservationLine] = []
        for file in journal.dayFiles() {
            var offset = 0
            while true {
                let r = try journal.read(file: file, from: offset, maxLines: 4096)
                out += r.lines.compactMap { try? $0.result.get() }
                if r.lines.isEmpty { break }
                offset = r.nextOffset
            }
        }
        return out
    }
}

/// A factory over a fixed Setup (the job id comes from the request).
struct EraTestFactory: JobFactory {
    let make: @Sendable (JobID) -> EraJob.Setup
    func makeJob(for request: JobRequest) throws -> any BackgroundJob { try EraJob(make(request.id)) }
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
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: """
                INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
                VALUES ('content', ?, 'era.fused', '1990-1995', 'inferred', ?, 1, 0.5, '{}')
                """, arguments: [EraFixture.hex(6), SeatedApproach.eraA2.signer])
        }
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
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "INSERT INTO user_dates (digest, value, confidence) VALUES (?, '1950', 'known')", arguments: [EraFixture.hex(6)])
        }
        #expect(try EraJob(EraFixture.setup(fixture, root: root, jobID: id)).plan == job.plan)
        #expect(try EraJob(EraFixture.setup(fixture, root: root, jobID: id, limit: 1)).plan.units.count == 2, "a resume never re-plans")
        #expect(try EraJob(EraFixture.setup(fixture, root: root, limit: 1)).plan.units.count == 1, "a new job honours limit")
        await job.end()
        #expect(!FileManager.default.fileExists(atPath: EraJob.planURL(root, id).path), "end removes the plan")
    }

    @Test func aNewerCatalogSchemaIsRefusedAtPlan() async throws {
        let fixture = try await EraFixture.catalog([])
        defer { fixture.remove() }
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "UPDATE catalog_state SET schema_version = 99 WHERE singleton = 1")
        }
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
        #expect(outcome.contains("finished: 1 run · 0 skipped · 2 failed"), "\(outcome)")
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
        let first = JobSupervisor(queue: queue, checkpoints: checkpoints,
                                  factory: EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0, afterAppend: { index in
                                      if index == 1 { await killer.supervisor?.abandonForTest() }
                                  }) },
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
        if let stale = try? EraJob(EraFixture.setup(fixture, root: root, jobID: request.id)) { await stale.worker.close() }
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

    @Test func noModelLoadWhileRickIsAtTheKeyboardThenItRuns() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let loads = ClipWorkerFixture.temporaryFile("era-loads")
        defer { try? FileManager.default.removeItem(at: loads) }
        let source = FakeActivitySource(ActivitySample(secondsSinceLastInput: 5))     // Rick is typing
        let backoff = Backoff(source: source, trickleInterval: .milliseconds(10))
        var configuration = BackgroundFixtures.fastConfiguration()
        configuration.deferRetryInterval = .milliseconds(50)
        let log = LogLines()
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                                       factory: EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0, log: loads, backoff: backoff) },
                                       backoff: backoff, log: log, configuration: configuration)
        _ = await supervisor.enqueue(JobRequest(kind: .era, requestedBy: "test"))
        try await Task.sleep(for: .milliseconds(800))
        #expect(ClipWorkerFixture.lines(loads).isEmpty, "no model load while trickling")
        #expect(log.lines.contains { $0.contains(EraJob.deferWords) })
        #expect(log.lines.filter { $0.contains(EraJob.deferWords) }.count == 1, "said once, not every retry")
        source.update { $0.secondsSinceLastInput = 3_600 }                          // Rick walked away
        await supervisor.drain()
        #expect(ClipWorkerFixture.lines(loads).first == "load")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME era") && $0.contains("1 run") })
    }

    @Test(.timeLimit(.minutes(2)))
    func orderAndPathYearOverOneHundredThousandInsideABudget() {
        let candidates = (0..<100_000).map { i in
            EraCandidate(digest: EraFixture.hex(i), path: "/Volumes/T/\(1960 + i % 60) box/clip \(i).mov", durationS: 60,
                         userYear: i % 7 == 0 ? 1990 : nil, embeddedYear: i % 11 == 0 ? 2004 : nil)
        }
        let clock = ContinuousClock()
        var ordered: [EraCandidate] = []
        let took = clock.measure {
            let withPath = candidates.map { c -> EraCandidate in var c = c; c.pathYear = EraJob.pathYear(c.path); return c }
            ordered = EraJob.order(withPath)
        }
        #expect(ordered.count == 100_000)
        let years = ordered.map { $0.bound?.year ?? Int.max }
        #expect(zip(years, years.dropFirst()).allSatisfy { $0 <= $1 }, "oldest first, unknown last")
        print("EraJob scale: pathYear + order over 100k in \(took)")
        #expect(took < .seconds(20), "\(took) (budget 20 s, Debug)")
    }
}

final class SupervisorBox: @unchecked Sendable {
    var supervisor: JobSupervisor?
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
