// AnalysisResultsReportTests.swift — the Content Analysis ▸ Results sheet's
// numbers and lists (AnalysisResultsReport.swift; Rick 2026-11-04).
//   LOGIC      each outcome counted once per content on a fixture catalog:
//              era found · no usable era · given up · other (ocr only) ·
//              tries in progress · still to do (the planner's predicate:
//              audio-only and removed files are not planned); a second
//              signer appears with its own counts; agreement within 5 years
//              at the 5-vs-6 boundary, the width rule and Rick's rejection;
//              pace over the last hour / 24 h from the FIRST verdict; the ETA
//              and era words.
//   TRUTH      every number equals an independent SQL count written another
//              way; every list is as long as its count; a give-up row's
//              reason is byte-for-byte what EraRecordMapper.giveUpLine wrote;
//              the agreement equals MachineEraResolver.convergence (Catalog
//              Status's line) on the same catalog; the content's standing
//              file is its live copy.
//   SCALE      100k contents (≈ 200k assertion rows, 20k dated) → the report
//              and one 10k list inside the budget.
//   ISOLATION  an unreadable try-count file → the report still builds, says
//              "unavailable", and the file's bytes are untouched (also a torn
//              tail and a file the job would compact); a missing file creates
//              nothing; an empty catalog; an unknown signer.
//   MEDIA      N/A — rows only. SENSOR: the app's AnalysisResultsSheetSensorTests.
// Synthetic digests and paths only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AnalysisResultsReport")
struct AnalysisResultsReportTests {

    static let seated = SeatedApproach.eraA2.signer
    static let info = PythonClipWorker.LoadInfo(approachID: SeatedApproach.eraA2ID, revision: 3, model: "m",
                                                json: Data(#"{"prompts_sha256":{"era":"ee","date":"dd"}}"#.utf8))
    static let info32 = PythonClipWorker.LoadInfo(approachID: ApproachID(model: "qwen3-vl-32b-4bit", promptFamily: "era-v1", sampler: "window-60s")
                                                      ?? SeatedApproach.eraA2ID,       // never taken; the 32B assertions would fail
                                                  revision: 1, model: "m32", json: Data(#"{"prompts_sha256":{"era":"ee"}}"#.utf8))
    static let now: Int64 = 1_762_300_000
    static let giveUpReason = "3 of 3 frames would not decode (ffmpeg: Invalid data found when processing input)"
    static func hex(_ n: Int) -> String { EraFixture.hex(n) }

    // MARK: Lines exactly as the era job writes them

    static func fused(_ n: Int, _ lo: Int, _ hi: Int, info: PythonClipWorker.LoadInfo = info, at: Int64 = now - 60) throws -> [ObservationLine] {
        let window: [String: Any] = ["family": "era", "window": [0.0, 60.0], "yearRange": [lo, hi], "rationale": "r", "cues": [], "selfConfidence": 0.7]
        let raw = String(bytes: try JSONSerialization.data(withJSONObject: window), encoding: .utf8) ?? ""
        let record: [String: Any] = [
            "window_results": [["family": "era", "window": [0.0, 60.0], "frame_times_s": [5.0], "raw_text": raw, "error": NSNull(), "window_index": 0]],
            "results": [],
            "summary": ["fused_years": [lo, hi], "year_range": [Double(lo), Double(hi)], "burned_in_years": []],
        ]
        let mapped = try EraRecordMapper.lines(record: try JSONSerialization.data(withJSONObject: record), digest: hex(n), info: info,
                                               job: "J", unit: n, at: at)
        try #require(mapped.lines.contains { $0.field == "era.fused" })
        return mapped.lines
    }

    static func none(_ n: Int, at: Int64 = now - 60) throws -> [ObservationLine] {
        let record: [String: Any] = [
            "window_results": [["family": "era", "window": [0.0, 60.0], "frame_times_s": [5.0], "raw_text": "nope", "error": NSNull(), "window_index": 0]],
            "results": [],
        ]
        let mapped = try EraRecordMapper.lines(record: try JSONSerialization.data(withJSONObject: record), digest: hex(n), info: info,
                                               job: "J", unit: n, at: at)
        try #require(mapped.eraNone)
        return mapped.lines
    }

    static func giveUp(_ n: Int, at: Int64 = now - 60) throws -> ObservationLine {
        try EraRecordMapper.giveUpLine(digest: hex(n), info: info, job: "J", unit: n, at: at, tries: EraAttemptStore.maxTries, reason: giveUpReason)
    }

    static func ocrOnly(_ n: Int, at: Int64 = now - 60) throws -> ObservationLine {
        try ObservationLine(subjectID: hex(n), field: "ocr.date", value: "1994-07-04", by: seated, at: at, confidence: 0.5,
                            evidence: ["atS": 1.0], job: "J", unit: n)
    }

    /// Through the store's one door, as the JournalApplier writes them.
    static func put(_ repository: GRDBCatalogRepository, _ lines: [ObservationLine]) throws {
        let outcome = repository.writeBlocking(as: .ui) { tx in
            for l in lines {
                let landing = try tx.appendProvenanceAssertion(CatalogRow.ProvenanceAssertionDraft(
                    subjectKind: l.subjectKind, subjectID: l.subjectID, field: l.field, value: l.value, state: l.state, by: l.by,
                    at: l.at, confidence: l.confidence, evidenceJSON: l.evidenceJSON))
                guard case .recorded = landing else { throw Refusal("not recorded: \(landing)") }
            }
        }
        guard case .committed = outcome else { throw Refusal("write: \(outcome)") }
    }

    static func reject(_ repository: GRDBCatalogRepository, _ n: Int, value: String) throws {
        let outcome = repository.writeBlocking(as: .ui) { tx in
            _ = try tx.appendProvenanceAssertion(CatalogRow.ProvenanceAssertionDraft(
                subjectKind: "content", subjectID: hex(n), field: "era.fused", value: value, state: "rejected", by: "rick",
                at: now, confidence: nil, evidenceJSON: "{}"))
        }
        guard case .committed = outcome else { throw Refusal("write: \(outcome)") }
    }

    static func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return repository
    }

    static func attempts(_ root: URL, _ entries: [(Int, String, Int, String)]) throws {
        let store = try EraAttemptStore(stateRoot: root)
        for (n, signer, tries, reason) in entries {
            for _ in 0..<tries { try store.record(digest: hex(n), signer: signer, reason: reason, at: now - 30) }
        }
    }

    // MARK: The fixture catalog of the logic and truth tests

    /// 1–2 found (1 agrees with Rick's 1993, 2 does not) · 3 none · 4–5 given up ·
    /// 6 ocr only · 7–9 nothing (7, 8 tried) · 10 audio only · 11 removed, found,
    /// dated · 12 none, a removed copy that sorts first and a live one.
    /// The 32B signer: found on 1 (disagrees), tried on 9.
    static func scene() async throws -> (StoreFixture, GRDBCatalogRepository, URL) {
        let files: [EraFixture.File] = [
            .init(n: 1, path: "/V/a/Alpha.mov", userYear: "1993"),
            .init(n: 2, path: "/V/a/Bravo.mov", userYear: "1990"),
            .init(n: 3, path: "/V/a/Charlie.mov"),
            .init(n: 4, path: "/V/a/Delta.mov"),
            .init(n: 5, path: "/V/a/Echo.mov"),
            .init(n: 6, path: "/V/a/Foxtrot.mov"),
            .init(n: 7, path: "/V/a/Golf.mov"),
            .init(n: 8, path: "/V/a/Hotel.mov"),
            .init(n: 9, path: "/V/a/India.mov"),
            .init(n: 10, path: "/V/a/Juliet.wav", stream: "Audio only"),
            .init(n: 11, path: "/V/a/Kilo.mov", removed: true, userYear: "1993"),
            .init(n: 12, path: "/V/b/Lima.mov"),
            .init(n: 12, path: "/V/0old/AAA.mov", removed: true, fileN: 112),
        ]
        let fixture = try await EraFixture.catalog(files)
        let repository = try await open(fixture)
        var lines = try fused(1, 1991, 1995) + fused(2, 1960, 1969) + none(3) + none(12) + fused(11, 1991, 1995)
        lines += [try giveUp(4), try giveUp(5), try ocrOnly(6)]
        lines += try fused(1, 1970, 1975, info: info32)
        try put(repository, lines)
        let root = try EraFixture.stateRoot()
        try attempts(root, [(7, seated, 2, "1 of 8 frames would not decode"), (8, seated, 1, "the model never answered"),
                            (9, info32.signer, 1, "timeout")])
        return (fixture, repository, root)
    }

    static func report(_ repository: GRDBCatalogRepository, _ root: URL) async throws -> AnalysisResultsReport {
        let attempts = AnalysisResultsReport.readAttempts(stateRoot: root)
        let journal = ObservationJournal(directory: EraPlanner.journalDirectory(stateRoot: root))
        return try await repository.read { try AnalysisResultsReport.build(reader: $0, attempts: attempts, journal: journal, now: now) }
    }

    // MARK: LOGIC

    @Test func eachOutcomeIsCountedOncePerContent() async throws {
        let (fixture, repository, root) = try await Self.scene()
        defer { fixture.remove() }
        let report = try await Self.report(repository, root)
        #expect(report.analyzers.map(\.signer) == [Self.seated, Self.info32.signer], "the seated analyzer first, then the rest")
        let a = try #require(report.analyzers.first)
        #expect(a.isSeated && a.modelShortName == "8B")
        #expect(a.analyzed == 8)                                   // 1 2 3 4 5 6 11 12
        #expect(a.eraFound == 3)                                   // 1 2 11 (11 is removed; what it produced still counts)
        #expect(a.eraNone == 2)                                    // 3 12
        #expect(a.gaveUp == 2)                                     // 4 5 — never in "no usable era"
        #expect(a.other == 1)                                      // 6: ocr.date only
        #expect(a.triesInProgress == 2)                            // 7 8 (9's try is the 32B's)
        #expect(a.stillToDo == 3)                                  // 7 8 9 — 10 is audio, 11 removed
        #expect(a.agreement == MachineEraConvergence(total: 2, agree: 1), "1 agrees, 2 does not, 11 is removed")
        let b = try #require(report.analyzers.last)
        #expect(!b.isSeated && b.modelShortName == "32B")
        #expect(b.analyzed == 1 && b.eraFound == 1 && b.triesInProgress == 1)
        #expect(b.stillToDo == nil, "nothing plans a signer that is not seated")
        #expect(b.agreement == MachineEraConvergence(total: 1, agree: 0))
        #expect(report.triesProblem == nil)
        await repository.close()
    }

    @Test func agreementIsWithinFiveYearsAtTheBoundaryAndHonoursWidthAndRejection() async throws {
        let fixture = try await EraFixture.catalog([
            .init(n: 1, path: "/V/1.mov", userYear: "1995"),          // 1990 vs 1995: 5 y → agrees
            .init(n: 2, path: "/V/2.mov", userYear: "1996"),          // 1990 vs 1996: 6 y → disagrees
            .init(n: 3, path: "/V/3.mov", userYear: "1988"),          // 1980–1995 is 15 y wide → disagrees
            .init(n: 4, path: "/V/4.mov", userYear: "1985-06-14"),    // midpoint 1990 vs 1985 at day precision → agrees
            .init(n: 5, path: "/V/5.mov", userYear: "1990"),          // no era → not counted
            .init(n: 6, path: "/V/6.mov"),                            // no date → not counted
            .init(n: 7, path: "/V/7.mov", userYear: "1990"),          // Rick rejected the era → not counted
        ])
        defer { fixture.remove() }
        let repository = try await Self.open(fixture)
        try Self.put(repository, try Self.fused(1, 1990, 1990) + Self.fused(2, 1990, 1990) + Self.fused(3, 1980, 1995)
                     + Self.fused(4, 1990, 1990) + Self.fused(6, 1990, 1990) + Self.fused(7, 1990, 1990))
        try Self.reject(repository, 7, value: "1990-1990")
        let report = try await Self.report(repository, try EraFixture.stateRoot())
        let a = try #require(report.analyzers.first)
        #expect(a.agreement == MachineEraConvergence(total: 4, agree: 2))
        #expect(AnalysisResultsReport.agreementWords(a.agreement) == "2 of 4 (50 %)")
        await repository.close()
    }

    @Test func paceCountsEachFileOnceAtItsFirstVerdict() async throws {
        let fixture = try await EraFixture.catalog((1...5).map { .init(n: $0, path: "/V/\($0).mov") })
        defer { fixture.remove() }
        let repository = try await Self.open(fixture)
        try Self.put(repository, try Self.none(1, at: Self.now - 100)            // last hour
                     + Self.none(2, at: Self.now - 5_000)                         // last 24 h
                     + Self.none(3, at: Self.now - 90_000)                        // older
                     + [try Self.ocrOnly(4, at: Self.now - 200_000), try Self.giveUp(4, at: Self.now - 50)])   // first verdict is old
        let report = try await Self.report(repository, try EraFixture.stateRoot())
        let a = try #require(report.analyzers.first)
        #expect(a.rate == .init(lastHour: 1, last24Hours: 2))
        #expect(a.stillToDo == 1)
        #expect(AnalysisResultsReport.rateWords(a.rate) == "1 in the last hour · 2 in the last 24 hours")
        #expect(AnalysisResultsReport.etaWords(stillToDo: 1, rate: a.rate) == "about 12 hours at the last 24 h rate")
        await repository.close()
    }

    @Test func theETAIsPlainAndNeverMadeUp() {
        typealias R = AnalysisResultsReport
        #expect(R.etaWords(stillToDo: 48, rate: .init(lastHour: 0, last24Hours: 24)) == "about 48 hours (about 2 days) at the last 24 h rate")
        #expect(R.etaWords(stillToDo: 1, rate: .init(lastHour: 0, last24Hours: 1)) == "about 24 hours at the last 24 h rate")
        #expect(R.etaWords(stillToDo: 1, rate: .init(lastHour: 0, last24Hours: 48)) == "under an hour at the last 24 h rate")
        #expect(R.etaWords(stillToDo: 10, rate: .init(lastHour: 3, last24Hours: 0)).hasPrefix("no rate yet"))
        #expect(R.etaWords(stillToDo: 0, rate: .init(lastHour: 0, last24Hours: 0)) == "nothing left to analyze")
        #expect(R.etaWords(stillToDo: nil, rate: .init(lastHour: 0, last24Hours: 9)).hasPrefix("not planned"))
    }

    @Test(arguments: [
        ("1991-1995", "early 1990s (1991–1995)"),
        ("1994-1996", "mid 1990s (1994–1996)"),
        ("1965-1965", "mid 1960s (1965)"),
        ("1960-1969", "1960s (1960–1969)"),
        ("1988-1992", "1980s–1990s (1988–1992)"),
        ("2001-2003", "early 2000s (2001–2003)"),
        ("not-a-range", "not-a-range"),
    ])
    func eraWordsArePeoplesWordsThenTheRange(_ value: String, _ words: String) {
        #expect(AnalysisResultsReport.eraWords(value) == words)
    }

    // MARK: TRUTH

    @Test func everyNumberEqualsAnIndependentCountAndEveryListItsCount() async throws {
        let (fixture, repository, root) = try await Self.scene()
        defer { fixture.remove() }
        let report = try await Self.report(repository, root)
        let s = Self.seated
        let by = "by = '\(s)' AND subject_kind = 'content'"
        let fusedSet = "SELECT subject_id FROM provenance_assertions WHERE \(by) AND field = 'era.fused'"
        let gaveSet = "SELECT subject_id FROM provenance_assertions WHERE \(by) AND field = 'era.none' AND evidence_json LIKE '%\"gaveUp\":true%'"
        let independent: [AnalysisResultsReport.Outcome: Int] = [
            .eraFound: try EraFixture.count(fixture, "SELECT count(DISTINCT subject_id) FROM provenance_assertions WHERE \(by) AND field = 'era.fused'"),
            .gaveUp: try EraFixture.count(fixture, "SELECT count(DISTINCT subject_id) FROM (\(gaveSet)) WHERE subject_id NOT IN (\(fusedSet))"),
            .eraNone: try EraFixture.count(fixture, """
                SELECT count(DISTINCT subject_id) FROM provenance_assertions WHERE \(by) AND field = 'era.none'
                   AND subject_id NOT IN (\(fusedSet)) AND subject_id NOT IN (\(gaveSet))
                """),
            .stillToDo: try EraFixture.count(fixture, """
                SELECT count(*) FROM content c
                 WHERE EXISTS (SELECT 1 FROM files f WHERE f.content_digest = c.digest AND f.removal_state IS NULL
                                 AND f.stream_type IN ('Video+Audio', 'Video only'))
                   AND NOT EXISTS (SELECT 1 FROM provenance_assertions a WHERE a.subject_id = c.digest AND a.by = '\(s)')
                """),
        ]
        let a = try #require(report.analyzers.first)
        for (outcome, n) in independent { #expect(a.count(outcome) == n, "\(outcome)") }
        #expect(a.analyzed == (try EraFixture.count(fixture, "SELECT count(DISTINCT subject_id) FROM provenance_assertions WHERE \(by)")))
        #expect(a.triesInProgress == (try EraAttemptStore.snapshot(stateRoot: root)).entries.keys.filter { $0.hasPrefix(s + " ") }.count)

        let snapshot = try EraAttemptStore.snapshot(stateRoot: root)
        for outcome in AnalysisResultsReport.Outcome.allCases {
            let list = try await repository.read { try AnalysisResultsReport.files(reader: $0, signer: s, outcome: outcome, attempts: snapshot) }
            #expect(list.rows.count == a.count(outcome), "the \(outcome) list is as long as its count")
            #expect(!list.truncated)
            #expect(Set(list.rows.map(\.digest)).count == list.rows.count, "one row per content")
        }
        await repository.close()
    }

    @Test func aGiveUpRowShowsTheReasonGiveUpLineWroteAndAnEraRowShowsWordsNeverANone() async throws {
        let (fixture, repository, root) = try await Self.scene()
        defer { fixture.remove() }
        let written = try #require(try JSONSerialization.jsonObject(with: Data(try Self.giveUp(4).evidenceJSON.utf8)) as? [String: Any])
        let reason = try #require(written["reason"] as? String)
        #expect(reason == "gave up after 3 tries: \(Self.giveUpReason)")
        let snapshot = try EraAttemptStore.snapshot(stateRoot: root)
        func list(_ o: AnalysisResultsReport.Outcome) async throws -> AnalysisResultsReport.FileList {
            try await repository.read { try AnalysisResultsReport.files(reader: $0, signer: Self.seated, outcome: o, attempts: snapshot) }
        }
        let gave = try await list(.gaveUp)
        #expect(gave.rows.map(\.filename) == ["Delta.mov", "Echo.mov"])
        #expect(gave.rows.allSatisfy { $0.reason == reason && $0.value == "given up" })
        #expect(gave.rows.first?.recordID == UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 4)))

        let found = try await list(.eraFound)
        #expect(found.rows.map(\.filename) == ["Alpha.mov", "Bravo.mov", "Kilo.mov"])
        #expect(found.rows.map(\.value) == ["early 1990s (1991–1995)", "1960s (1960–1969)", "early 1990s (1991–1995)"])
        #expect(found.rows.map(\.removed) == [false, false, true])

        let none = try await list(.eraNone)
        #expect(none.rows.map(\.filename) == ["Charlie.mov", "Lima.mov"], "content 12 stands as its LIVE copy, not the removed AAA.mov")
        #expect(none.rows.allSatisfy { $0.value == "no usable era" && $0.reason == "no era window passed the contract" })
        #expect(none.rows.allSatisfy { $0.value.rangeOfCharacter(from: .decimalDigits) == nil }, "era.none is never shown as an era")

        let trying = try await list(.inProgress)
        #expect(trying.rows.map(\.filename) == ["Golf.mov", "Hotel.mov"])
        #expect(trying.rows.map(\.value) == ["tried 2 of 3 times", "tried 1 of 3 times"])
        #expect(trying.rows.map(\.reason) == ["1 of 8 frames would not decode", "the model never answered"])

        let toDo = try await list(.stillToDo)
        #expect(toDo.rows.map(\.filename) == ["Golf.mov", "Hotel.mov", "India.mov"])
        await repository.close()
    }

    @Test func theAgreementIsCatalogStatussConvergenceOnTheSameCatalog() async throws {
        let (fixture, repository, root) = try await Self.scene()
        defer { fixture.remove() }
        // Single-signer catalog for the comparison: Catalog Status takes the newest era of ANY signer.
        let eras = try await repository.read { try MachineEraResolver.eras(in: $0) }
            .mapValues { $0.filter { $0.by == Self.seated } }.filter { !$0.value.isEmpty }
        // Rick's years as the app derives them (user_dates, live files only — the records the app holds).
        let years: [String: Int] = [Self.hex(1): 1993, Self.hex(2): 1990]
        let status = MachineEraResolver.convergence(eras: eras, rickYears: years)
        let report = try await Self.report(repository, root)
        #expect(report.analyzers.first?.agreement == status)
        await repository.close()
    }

    // MARK: SCALE

    @Test(.tags(.scale), .timeLimit(.minutes(5)))
    func oneHundredThousandContentsBuildWithinBudget() async throws {
        let count = 100_000
        let fixture = try await EraFixture.catalog((1...count).map {
            .init(n: $0, path: "/V/\($0 % 100)/clip-\($0).mov", userYear: $0 % 5 == 0 ? "\(1962 + $0 % 45)" : nil)
        })
        defer { fixture.remove() }
        try EraFixture.seedEraVerdicts(fixture, count: count, now: Self.now)
        let repository = try await Self.open(fixture)
        let root = try EraFixture.stateRoot()
        try Self.attempts(root, (1...200).map { ($0 * 10 - 1, Self.seated, 1, "t") })      // n % 10 == 9: no verdict
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var report = AnalysisResultsReport()
        var list: AnalysisResultsReport.FileList?
        let took = try await clock.measure {
            report = try await Self.report(repository, root)
            list = try await repository.read { try AnalysisResultsReport.files(reader: $0, signer: Self.seated, outcome: .eraFound, attempts: nil) }
        }
        let a = try #require(report.analyzers.first)
        #expect(a.eraFound == 60_000 && a.eraNone == 20_000 && a.gaveUp == 10_000 && a.stillToDo == 10_000)
        #expect(a.triesInProgress == 200)
        #expect(a.agreement.total == 20_000, "n % 5 == 0 is n % 10 ∈ {0, 5}: every dated content has a fused era")
        #expect(list?.rows.count == AnalysisResultsReport.listLimit && list?.truncated == true)
        print("AnalysisResultsReport scale: 100k contents (≈ 200k rows) report + one 10k list in \(took)")
        expectWithinTimingBudget("100k contents: Results report + one 10k list", measured: took,
                                 budget: TimingBudget.debugCeiling(.seconds(2)), loadBefore: load)
        await repository.close()
    }

    /// Review 11/05 (C): a 100k "still to do" is listed with its LIMIT in SQL —
    /// one 10k page, never 100k rows read then cut — inside the same budget.
    @Test(.tags(.scale), .timeLimit(.minutes(5)))
    func oneHundredThousandStillToDoListsOnePageWithinBudget() async throws {
        let count = 100_000
        let fixture = try await EraFixture.catalog((1...count).map { .init(n: $0, path: "/V/\($0 % 100)/clip-\($0).mov") })
        defer { fixture.remove() }
        let repository = try await Self.open(fixture)
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var list: AnalysisResultsReport.FileList?
        let took = try await clock.measure {
            list = try await repository.read { try AnalysisResultsReport.files(reader: $0, signer: Self.seated, outcome: .stillToDo, attempts: nil) }
        }
        #expect(list?.rows.count == AnalysisResultsReport.listLimit && list?.truncated == true)
        print("AnalysisResultsReport scale: 100k still to do, one 10k page in \(took)")
        expectWithinTimingBudget("100k still to do: one 10k list", measured: took,
                                 budget: TimingBudget.debugCeiling(.seconds(2)), loadBefore: load)
        await repository.close()
    }

    // MARK: ISOLATION

    @Test func anUnreadableTryCountFileLeavesTheReportStandingAndTheFileUntouched() async throws {
        let (fixture, repository, root) = try await Self.scene()
        defer { fixture.remove() }
        let url = EraAttemptStore.url(stateRoot: root)
        let poisoned = Data("{\"k\":\"x\",\"t\":1}\nnot json at all\n{\"k\":\"y\",\"t\":2}\n".utf8)
        try poisoned.write(to: url)
        let report = try await Self.report(repository, root)
        let a = try #require(report.analyzers.first)
        #expect(a.triesInProgress == nil)
        #expect(report.countWords(a, .inProgress) == "unavailable")
        #expect(report.triesProblem?.contains("unreadable (line 2 is not a try record)") == true)
        #expect(a.eraFound == 3 && a.stillToDo == 3, "the rest of the sheet still loads")
        #expect(try Data(contentsOf: url) == poisoned, "reading never rewrites the file")
        await repository.close()
    }

    @Test func theReadOnlySnapshotNeverCompactsWhereTheJobWould() throws {
        let root = try EraFixture.stateRoot()
        let url = EraAttemptStore.url(stateRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Many dead lines (the job compacts at > 2 × live + 64) and a torn tail (it compacts that too).
        var text = ""
        for i in 0..<100 { text += "{\"k\":\"\(Self.seated) \(Self.hex(i))\",\"t\":1,\"r\":\"r\",\"a\":1}\n{\"k\":\"\(Self.seated) \(Self.hex(i))\",\"clear\":true}\n" }
        text += "{\"k\":\"\(Self.seated) \(Self.hex(500))\",\"t\":2,\"r\":\"why\",\"a\":3}\n{\"k\":\"torn"
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        let snapshot = try EraAttemptStore.snapshot(stateRoot: root)
        #expect(snapshot.attempts(signer: Self.seated) == [Self.hex(500): EraAttempt(tries: 2, lastReason: "why", lastAt: 3)])
        #expect(try Data(contentsOf: url) == bytes, "the snapshot left every byte")
        _ = try EraAttemptStore(stateRoot: root)
        #expect(try Data(contentsOf: url) != bytes, "the job's own open does compact — the read path is different on purpose")
    }

    @Test func aMissingTryCountFileIsNoTriesAndCreatesNothing() throws {
        let root = try EraFixture.stateRoot()
        let read = AnalysisResultsReport.readAttempts(stateRoot: root)
        #expect((try? read.get())?.entries.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("attempts").path))
    }

    @Test func anEmptyCatalogShowsTheSeatedAnalyzerWithNothingYet() async throws {
        let fixture = try await EraFixture.catalog([])
        defer { fixture.remove() }
        let repository = try await Self.open(fixture)
        let report = try await Self.report(repository, try EraFixture.stateRoot())
        #expect(report.analyzers.count == 1)
        let a = try #require(report.analyzers.first)
        #expect(a.signer == Self.seated && a.analyzed == 0 && a.eraFound == 0 && a.stillToDo == 0 && a.triesInProgress == 0)
        #expect(AnalysisResultsReport.etaWords(stillToDo: a.stillToDo, rate: a.rate) == "nothing left to analyze")
        #expect(AnalysisResultsReport.agreementWords(a.agreement).hasPrefix("no file with your confirmed date"))
        for outcome in AnalysisResultsReport.Outcome.allCases {
            let list = try await repository.read { try AnalysisResultsReport.files(reader: $0, signer: Self.seated, outcome: outcome, attempts: nil) }
            #expect(list.rows.isEmpty)
        }
        await repository.close()
    }

    @Test func anUnknownSignerAppearsWithItsOwnCountsAndNoPlan() async throws {
        let fixture = try await EraFixture.catalog([.init(n: 1, path: "/V/1.mov"), .init(n: 2, path: "/V/2.mov")])
        defer { fixture.remove() }
        let repository = try await Self.open(fixture)
        let mystery = "machine:mystery-model/odd-v9/whole@r9"
        try Self.put(repository, [try ObservationLine(subjectID: Self.hex(1), field: "era.fused", value: "1980-1984", by: mystery,
                                                      at: Self.now - 10, confidence: 0.5, evidence: [:], job: "J", unit: 0),
                                  try ObservationLine(subjectID: Self.hex(2), field: "scene.kind", value: "beach", by: mystery,
                                                      at: Self.now - 10, confidence: 0.5, evidence: [:], job: "J", unit: 0)])
        let report = try await Self.report(repository, try EraFixture.stateRoot())
        #expect(report.analyzers.map(\.signer) == [Self.seated, mystery])
        let m = try #require(report.analyzers.last)
        #expect(!m.isSeated && m.modelShortName == "mystery-model")
        #expect(m.analyzed == 2 && m.eraFound == 1 && m.other == 1 && m.stillToDo == nil)
        #expect(m.rate.lastHour == 2)
        #expect(AnalysisResultsReport.etaWords(stillToDo: m.stillToDo, rate: m.rate).hasPrefix("not planned"))
        #expect(report.analyzers.first?.stillToDo == 2, "the seated analyzer has done neither")
        await repository.close()
    }
}
