// MachineEraResolverTests.swift — what the app shows of the era job's
// observations (MachineEraResolver.swift; background step 1, item 8).
//   LOGIC      the newest era.fused per `by` (seq, not `at`); inferred
//              machine rows only; Rick's later "rejected" on the value hides
//              it; frame times come from the same run's window rows; the
//              model's short name from the approach id ("8B", "32B", "1.5B").
//   BOUNDARY   "close enough" = midpoint within 5 y (inclusive) AND width
//              ≤ 10 — each edge on both sides; the convergence count is nil
//              (absent) at M = 0.
//   WORDS      search words are decade words ("1990s", "90s", "early 90s")
//              and never the range, the field, the signer or a digest; a
//              range across a decade line gets both decades and no third.
//   TRUTH      the bulk read on a real catalog.sqlite (rows through the store's
//              door) returns exactly what was stored, keyed by digest; the
//              inspector line carries the model, the help carries the `by`.
//   SCALE      100k contents with a fused era (and window rows) read in one
//              streamed query inside the budget (TimingBudget rules).
//   ISOLATION  malformed rows (bad range, garbage evidence, a "rick" by, an
//              unknown state) never become an era and never throw.
//   MEDIA      N/A — rows only. SENSOR: see MachineEraStore (app) tests.
// Synthetic digests only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("MachineEraResolver")
struct MachineEraResolverTests {

    static let by8 = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"
    static let by32 = "machine:qwen3-vl-32b-4bit/era-v1/window-60s@r1"
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    static func row(_ seq: Int64, field: String = "era.fused", value: String = "1991-1995", state: String = "inferred",
                    by: String = by8, at: Int64 = 1_762_000_000, evidence: String = "{}") -> CatalogRow.ProvenanceAssertionReading {
        CatalogRow.ProvenanceAssertionReading(seq: seq, subjectKind: "content", subjectID: hex(1), field: field, value: value, state: state,
                                              by: by, at: at, confidence: 0.6, evidenceJSON: evidence)
    }

    static func era(_ lo: Int, _ hi: Int) -> MachineEra { MachineEra(lo: lo, hi: hi, by: by8, at: 0, seq: 1) }

    // MARK: The File Journey's sentence and the estimate folders' rule (Rick 2026-11-13)

    @Test func theJourneySentenceIsAGuessInItsOwnWords() {
        let plain = MachineEraResolver.journeySentence(era: Self.era(1980, 1995), rickYear: nil)
        #expect(plain == "Estimated era: 1980–1995 — the 8B model's guess from the pictures alone, not confirmed.")
        let read = MachineEra(lo: 1991, hi: 1991, by: Self.by8, at: 0, seq: 1, burnedInYears: [1991])
        #expect(MachineEraResolver.journeySentence(era: read, rickYear: nil)
                == "Estimated era: 1991 — the 8B model's guess from the pictures alone, not confirmed. On-screen years read: 1991.")
        #expect(MachineEraResolver.journeySentence(era: Self.era(1991, 1995), rickYear: 1993).hasSuffix("not confirmed."),
                "close enough to Rick's date: nothing more to say")
        #expect(MachineEraResolver.journeySentence(era: Self.era(1991, 1995), rickYear: 1970).hasSuffix("It disagrees with your date."))
        #expect(MachineEraResolver.journeySentence(era: Self.era(1980, 1995), rickYear: 1987).hasSuffix("It disagrees with your date."),
                "a 15-year range is too wide to agree with anything (the review page's rule)")
    }

    @Test(arguments: [
        (1991, 1991, MachineEraResolver.EstimateFolder.year(1991)),      // an on-screen date
        (1991, 1992, .year(1991)),                                       // one year wide: still a year
        (1991, 1993, .decade(1990)),                                     // two wide: a decade
        (1980, 1995, .decade(1980)),                                     // midpoint 1987.5
        (1980, 2000, .decade(1990)),                                     // midpoint 1990: the decade it starts
        (1985, 1995, .decade(1990)),                                     // midpoint 1990
        (1985, 1994, .decade(1980)),                                     // midpoint 1989.5
        (2010, 2025, .decade(2010)),
        (1895, 1905, .decade(1900)),
    ])
    func anEraFilesUnderItsYearOrTheDecadeOfItsMidpoint(lo: Int, hi: Int, folder: MachineEraResolver.EstimateFolder) {
        #expect(MachineEraResolver.estimateFolder(era: Self.era(lo, hi)) == folder)
    }

    @Test func estimateFoldersSortOldestFirstAndADecadeLeadsItsFirstYear() {
        let folders: [MachineEraResolver.EstimateFolder] = [.year(1991), .decade(2000), .year(1990), .decade(1990), .decade(1980)]
        #expect(folders.sorted() == [.decade(1980), .decade(1990), .year(1990), .year(1991), .decade(2000)])
        #expect(MachineEraResolver.EstimateFolder.decade(1990).title == "1990s (estimated)")
        #expect(MachineEraResolver.EstimateFolder.year(1991).title == "1991 (estimated)")
    }

    // MARK: Rows → eras

    @Test func theNewestFusedRowPerByWinsBySeqNotByAt() {
        let rows = [
            Self.row(1, value: "1980-1990", at: 900),
            Self.row(2, value: "1991-1995", at: 100),        // newer seq, older `at` — seq decides
            Self.row(3, value: "1970-1975", by: Self.by32),
            Self.row(4, field: "era.yearRange", value: "1960-1965"),
        ]
        let eras = MachineEraResolver.eras(fromRowsOfOneSubject: rows)
        #expect(eras.map(\.rangeText) == ["1970–1975", "1991–1995"])   // newest first across bys
        #expect(eras.map(\.by) == [Self.by32, Self.by8])
        #expect(eras.map(\.modelShortName) == ["32B", "8B"])
    }

    @Test func onlyInferredMachineRowsCountAndRicksRejectionHidesTheValue() {
        let rows = [
            Self.row(1, value: "1991-1995"),
            Self.row(2, value: "1991-1995", state: "rejected", by: "rick"),
            Self.row(3, value: "1980-1985", by: Self.by32),
            Self.row(4, value: "1950-1955", state: "confirmed", by: "rick"),
            Self.row(5, value: "1940-1945", by: "rick"),
        ]
        let eras = MachineEraResolver.eras(fromRowsOfOneSubject: rows)
        #expect(eras.map(\.rangeText) == ["1980–1985"])
        // A rejection OLDER than the observation does not hide a re-observation (the trigger already vetoed re-proposals).
        let reproposed = MachineEraResolver.eras(fromRowsOfOneSubject: [Self.row(1, value: "1991-1995", state: "rejected", by: "rick"),
                                                                        Self.row(2, value: "1991-1995")])
        #expect(reproposed.count == 1)
    }

    @Test func frameTimesComeFromTheSameRunsWindowRowsAndTheWindowsFromTheFusedRow() throws {
        let rows = [
            Self.row(1, field: "era.yearRange", value: "1990-1996", evidence: #"{"frameTimesS":[3.75,11.25],"window":[0,60]}"#),
            Self.row(2, field: "era.yearRange", value: "1991-1994", evidence: #"{"frameTimesS":[63.75,71.25],"window":[60,120]}"#),
            Self.row(3, field: "era.yearRange", value: "1960-1965", at: 5, evidence: #"{"frameTimesS":[999],"window":[0,60]}"#),   // another run
            Self.row(4, evidence: #"{"burnedInYears":[1993],"validEraWindows":2,"windows":[[0,60],[60,120]]}"#),
        ]
        let era = try #require(MachineEraResolver.eras(fromRowsOfOneSubject: rows).first)
        #expect(era.windowCount == 2)
        #expect(era.windows == [0...60, 60...120])
        #expect(era.frameTimesS == [3.75, 11.25, 63.75, 71.25])
        #expect(era.burnedInYears == [1993])
        let help = MachineEraResolver.inspectorHelp(era: era)
        #expect(help.contains("Windows: 2 (0 s–1:00, 1:00–2:00)"))
        #expect(help.contains("Frames: 4 at 4 s, 11 s, 1:04, 1:11"))
        #expect(help.contains(Self.by8))
    }

    @Test func frameTimesAreCappedAndTheRestCounted() throws {
        let many = (0..<40).map { Double($0) }
        let era = MachineEra(lo: 1990, hi: 1994, by: Self.by8, at: 0, seq: 1, frameTimesS: many)
        #expect(era.frameTimesS.count == MachineEraResolver.frameTimeCap)
        #expect(era.frameCount == 40)
        #expect(MachineEraResolver.inspectorHelp(era: era).contains("… 16 more"))
    }

    @Test func malformedRowsNeverBecomeAnEra() {
        let rows = [
            Self.row(1, value: "1995-1991"), Self.row(2, value: "1991"), Self.row(3, value: "abc-def"),
            Self.row(4, value: "1991-1995-1999"), Self.row(5, state: "unknown"), Self.row(6, by: "machine:"),
            Self.row(7, value: "1991-1995", evidence: "not json"),
        ]
        let eras = MachineEraResolver.eras(fromRowsOfOneSubject: rows)
        #expect(eras.count == 1)                       // seq 7: garbage evidence is no evidence, not no era
        #expect(eras.first?.windowCount == 0)
        #expect(eras.first?.frameCount == 0)
    }

    @Test func theModelShortNameIsTheParameterCount() {
        #expect(MachineEraResolver.modelShortName(by: Self.by8) == "8B")
        #expect(MachineEraResolver.modelShortName(by: Self.by32) == "32B")
        #expect(MachineEraResolver.modelShortName(by: "machine:qwen2.5-vl-1.5b-instruct/era@r2") == "1.5B")
        #expect(MachineEraResolver.modelShortName(by: "machine:smolvlm/era-v1@r1") == "smolvlm")
        #expect(MachineEraResolver.modelShortName(by: "machine:4bit-only/era@r1") == "4bit-only")   // "4bit" is not a size
    }

    // MARK: close enough — every boundary

    @Test(arguments: [
        // (lo, hi, rickYear, closeEnough)
        (1991, 1995, 1993, true),    // dead centre
        (1990, 2000, 2000, true),    // midpoint 1995: exactly 5 away; width exactly 10
        (1990, 2000, 1990, true),    // exactly 5 on the other side
        (1990, 2000, 2001, false),   // 6 away
        (1990, 2000, 1989, false),   // 6 away, other side
        (1990, 2001, 1995, false),   // width 11, midpoint 0.5 away: the width alone refuses
        (1985, 1995, 1990, true),    // width 10 at the centre
        (1975, 1985, 1965, false),   // Rick's 1965 film read as 1975–1985: 15 away
    ] as [(Int, Int, Int, Bool)])
    func closeEnoughBoundaries(lo: Int, hi: Int, year: Int, expected: Bool) {
        #expect(MachineEraResolver.closeEnough(era: Self.era(lo, hi), rickYear: year) == expected)
    }

    @Test func closeEnoughHalfYearEdges() {
        #expect(MachineEraResolver.closeEnough(era: Self.era(1991, 2000), rickYear: 2000))    // 4.5 away
        #expect(!MachineEraResolver.closeEnough(era: Self.era(1991, 2000), rickYear: 2001))   // 5.5 away
        #expect(MachineEraResolver.closeEnough(era: Self.era(1993, 1993), rickYear: 1998))    // one-year range, 5 away
        #expect(!MachineEraResolver.closeEnough(era: Self.era(1993, 1993), rickYear: 1999))   // 6 away
    }

    @Test func ricksYearComesFromHisSavedDateAtAnyPrecision() {
        #expect(MachineEraResolver.rickYear("1992") == 1992)
        #expect(MachineEraResolver.rickYear("1992-06") == 1992)
        #expect(MachineEraResolver.rickYear("1992-06-14") == 1992)
        #expect(MachineEraResolver.rickYear(nil) == nil)
        #expect(MachineEraResolver.rickYear("sometime") == nil)
    }

    // MARK: convergence

    @Test func convergenceCountsContentsWithBothAndIsAbsentAtZero() {
        let eras: [String: [MachineEra]] = [
            Self.hex(1): [Self.era(1991, 1995)],          // Rick 1993 → agrees
            Self.hex(2): [Self.era(1975, 1985)],          // Rick 1965 → disagrees (the 1965 film case)
            Self.hex(3): [Self.era(1990, 2005)],          // Rick 1997 → too wide
            Self.hex(4): [Self.era(2000, 2004)],          // no date from Rick → not in M
        ]
        let years = [Self.hex(1): 1993, Self.hex(2): 1965, Self.hex(3): 1997, Self.hex(9): 1990]
        let c = MachineEraResolver.convergence(eras: eras, rickYears: years)
        #expect(c == MachineEraConvergence(total: 3, agree: 1))
        #expect(c.map(MachineEraResolver.statusLine) == "Machine era agrees with your confirmed date within 5 y: 1 of 3 (33 %)")
        #expect(MachineEraResolver.convergence(eras: eras, rickYears: [:]) == nil)
        #expect(MachineEraResolver.convergence(eras: [:], rickYears: years) == nil)
    }

    // MARK: the inspector's words

    @Test func theInspectorLineSaysUnconfirmedAndDisagreementInWords() {
        let era = MachineEra(lo: 1991, hi: 1995, by: Self.by8, at: 0, seq: 1)
        #expect(MachineEraResolver.inspectorLine(era: era, rickYear: nil) == "Machine era: 1991–1995 · 8B, unconfirmed")
        #expect(MachineEraResolver.inspectorLine(era: era, rickYear: 1996) == "Machine era: 1991–1995 · 8B, unconfirmed")
        #expect(MachineEraResolver.inspectorLine(era: era, rickYear: 2001)
                == "Machine era: 1991–1995 · 8B, unconfirmed — disagrees with your date")
        #expect(MachineEraResolver.inspectorLine(era: MachineEra(lo: 1993, hi: 1993, by: Self.by8, at: 0, seq: 1), rickYear: nil)
                == "Machine era: 1993 · 8B, unconfirmed")
    }

    // MARK: search words

    @Test func searchWordsAreTheDecadeWordsAPersonTypes() {
        // The brief's own example: 1991–1995 (midpoint 1993) is "early 90s".
        #expect(MachineEraResolver.searchWords(era: Self.era(1991, 1995)) == ["1990s", "90s", "early 90s", "early 1990s"])
        #expect(MachineEraResolver.searchWords(era: Self.era(1991, 1993)) == ["1990s", "90s", "early 90s", "early 1990s"])
        #expect(MachineEraResolver.searchWords(era: Self.era(1994, 1996)) == ["1990s", "90s", "mid 90s", "mid 1990s"])
        #expect(MachineEraResolver.searchWords(era: Self.era(1997, 1999)) == ["1990s", "90s", "late 90s", "late 1990s"])
        #expect(MachineEraResolver.searchWords(era: Self.era(1965, 1965)) == ["1960s", "60s", "mid 60s", "mid 1960s"])
        #expect(MachineEraResolver.searchWords(era: Self.era(1990, 1999)) == ["1990s", "90s"])          // 9 wide: decade only
        #expect(MachineEraResolver.searchWords(era: Self.era(1988, 1992)) == ["1980s", "80s", "1990s", "90s"])
        #expect(MachineEraResolver.searchWords(era: Self.era(2001, 2003)) == ["2000s", "early 2000s"])  // no "00s"
        #expect(MachineEraResolver.searchYears(era: Self.era(1991, 1995)) == 1991...1995)
    }

    @Test(arguments: [
        // (lo, hi, third or nil): the midpoint edges 3.5 / 6.5 and the 5-year width edge
        (1990, 1997, nil),           // width 7: decade only
        (1990, 1995, "early"),       // width 5 (the edge), midpoint 2.5
        (1990, 1996, nil),           // width 6
        (1991, 1996, "early"),       // midpoint 3.5 — the edge stays early
        (1992, 1996, "mid"),         // midpoint 4
        (1994, 1998, "mid"),         // midpoint 6
        (1994, 1999, "late"),        // midpoint 6.5 — the edge goes late
    ] as [(Int, Int, String?)])
    func theThirdEdges(lo: Int, hi: Int, third: String?) {
        let words = MachineEraResolver.searchWords(era: Self.era(lo, hi))
        let found = ["early", "mid", "late"].first { t in words.contains { $0.hasPrefix(t + " ") } }
        #expect(found == third, "\(lo)–\(hi): \(words)")
    }

    @Test func searchWordsNeverCarryTheTechnicalForm() {
        let era = Self.era(1991, 1995)
        let text = MachineEraResolver.searchWords(era: era).joined(separator: " ")
        for forbidden in ["1991", "1995", "-", "era", "fused", "machine", "qwen", Self.hex(1), "8b"] {
            #expect(!text.lowercased().contains(forbidden), "search words carry \(forbidden)")
        }
    }

    // MARK: truth + scale on a real catalog.sqlite

    static func scene(contents: Int) async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        try EraFixture.seedContents(fixture, count: contents)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return (fixture, repository)
    }

    @Test func theBulkReadReturnsWhatTheDoorStoredKeyedByDigest() async throws {
        let (fixture, repository) = try await Self.scene(contents: 3)
        defer { fixture.remove() }
        let drafts = [
            CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: Self.hex(1), field: "era.yearRange", value: "1990-1996",
                                                state: "inferred", by: Self.by8, at: 7, confidence: 0.5,
                                                evidenceJSON: #"{"frameTimesS":[1.5,9],"window":[0,60]}"#),
            CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: Self.hex(1), field: "era.fused", value: "1991-1995",
                                                state: "inferred", by: Self.by8, at: 7, confidence: 0.5,
                                                evidenceJSON: #"{"validEraWindows":1,"windows":[[0,60]]}"#),
            CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: Self.hex(2), field: "ocr.date", value: "1994-07-04",
                                                state: "inferred", by: Self.by8, at: 7, confidence: 0.5, evidenceJSON: "{}"),
        ]
        let written = repository.writeBlocking(as: .ui) { tx in for d in drafts { _ = try tx.appendProvenanceAssertion(d) } }
        guard case .committed = written else { Issue.record("write: \(written)"); return }
        let eras = try await repository.read { try MachineEraResolver.eras(in: $0) }
        #expect(eras.keys.sorted() == [Self.hex(1)])                         // content 2 has no era; content 3 nothing
        let era = try #require(eras[Self.hex(1)]?.first)
        #expect(era.lo == 1991 && era.hi == 1995 && era.by == Self.by8 && era.at == 7)
        #expect(era.frameTimesS == [1.5, 9])
        #expect(MachineEraResolver.inspectorLine(era: era, rickYear: nil).contains("8B"))
        #expect(MachineEraResolver.inspectorHelp(era: era).contains(Self.by8))
        await repository.close()
    }

    @Test(.tags(.scale), .timeLimit(.minutes(5)))
    func oneHundredThousandErasInOneStreamedQueryWithinBudget() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try EraFixture.seedContents(fixture, count: 100_000)
        try EraFixture.seedFusedEras(fixture, count: 100_000, windowsPerEra: 2)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let years = Dictionary(uniqueKeysWithValues: (1...100_000).map { (Self.hex($0), 1962 + $0 % 45) })
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var eras: [String: [MachineEra]] = [:]
        var convergence: MachineEraConvergence?
        let took = try await clock.measure {
            eras = try await repository.read { try MachineEraResolver.eras(in: $0) }
            convergence = MachineEraResolver.convergence(eras: eras, rickYears: years)
        }
        #expect(eras.count == 100_000)
        #expect(eras[Self.hex(5)]?.first?.frameCount == 16)
        #expect(convergence?.total == 100_000)
        #expect(convergence?.agree == 100_000)              // Rick's year = lo + 2, the midpoint: every one close enough
        print("MachineEraResolver scale: 100k eras (300k rows) read + counted in \(took)")
        expectWithinTimingBudget("100k fused eras: one streamed read + the convergence count", measured: took,
                                 budget: TimingBudget.debugCeiling(.seconds(4)), loadBefore: load)
        await repository.close()
    }
}
