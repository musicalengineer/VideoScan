// ConfirmedDateFilterTests.swift
// "Confirmed date" Show filter (Rick 2026-10-31: "a view filter in the media
// catalog 'Show Confirmed Date' … so I can quickly scroll through and double
// check the dates are consistent"). One chip in the EXISTING filter row
// (CatalogViewFilter.confirmedDate), one predicate (pfRecordHasConfirmedDate),
// applied where every other additive filter is applied (computeFiltered).
//
// Five dimensions + TRUTH:
//   LOGIC      the predicate keeps exactly the rows with Rick's own date
//              (either confidence), none without; the chip's words, icon and
//              persisted raw value round-trip like its neighbours.
//   TRUTH      production shape: records dated through the model, committed to
//              catalog.sqlite by the one committer, reloaded by the one loader —
//              the chip's count equals a direct SQL count of `user_dates` rows
//              on live files (the loader's own join), on the same snapshot.
//   SCALE      ConfirmedDateFilterScaleTests.swift (gauntlet performance
//              stage): 100k records through the predicate inside the
//              Catalog's filter budget — TimingBudget's judge, never a raw assert.
//   ISOLATION  a malformed user date ("banana", "", "19", "1992-13") never
//              counts and never crashes; a removed row with a confirmed date
//              is not in the table.
//   SENSOR     (ConfirmedDateFilterSensorTests) the chip exists in the filter
//              row's source — the enum case the Show menu iterates, the words,
//              the filter pass — and the predicate reads the user date, never
//              a machine date.
//   MEDIA      N/A — no media is opened.

import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - LOGIC + ISOLATION

@Suite("Confirmed date filter — the predicate and the chip")
struct ConfirmedDateFilterTests {

    private func rec(_ name: String, date: String? = nil, confidence: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.userDate = date
        r.userDateConfidence = confidence
        return r
    }

    @Test("LOGIC: a record with Rick's date counts at either confidence; a record without never does")
    func predicateFollowsTheUserDate() {
        #expect(pfRecordHasConfirmedDate(rec("known.mov", date: "1992-06-14", confidence: "known")))
        #expect(pfRecordHasConfirmedDate(rec("guess.mov", date: "1992", confidence: "estimated")))
        #expect(pfRecordHasConfirmedDate(rec("month.mov", date: "1992-06", confidence: nil)),
                "a missing confidence string reads as estimated — still Rick's date")
        #expect(!pfRecordHasConfirmedDate(rec("none.mov")))
        // A machine date is not a confirmed date: inferred and container stamps never count.
        let machine = rec("inferred.mov")
        machine.inferredRecordDate = Date(timeIntervalSince1970: 650_000_000)
        machine.inferredDateConfidence = 0.9
        machine.embeddedCreationDate = Date(timeIntervalSince1970: 700_000_000)
        machine.dateCreatedRaw = Date(timeIntervalSince1970: 750_000_000)
        #expect(!pfRecordHasConfirmedDate(machine))
        #expect(machine.resolvedDateDisplay != "", "the machine dates do resolve — they are just not Rick's")
    }

    @Test("LOGIC: the filter keeps exactly the dated rows, in order")
    func filterKeepsExactlyTheDatedRows() {
        let rows = [
            rec("a.mov", date: "1991"), rec("b.mov"), rec("c.mov", date: "1992-06", confidence: "known"),
            rec("d.mov"), rec("e.mov", date: "2001-12-25", confidence: "estimated"),
        ]
        #expect(rows.filter(pfRecordHasConfirmedDate).map(\.filename) == ["a.mov", "c.mov", "e.mov"])
    }

    @Test("LOGIC: the chip is a CatalogViewFilter case with plain words, an icon and a persisted raw value")
    func chipIsAFilterCase() {
        #expect(CatalogViewFilter.allCases.contains(.confirmedDate))
        #expect(CatalogShowingSummary.words(for: .confirmedDate) == "Confirmed date")
        #expect(!CatalogViewFilter.confirmedDate.icon.isEmpty)
        #expect(CatalogViewFilter(rawValue: "Confirmed Date") == .confirmedDate, "persisted filter round trip")
        let encoded = CatalogShowingSummary.encode([.confirmedDate, .ratedOnly])
        #expect(CatalogShowingSummary.decode(encoded) == [.confirmedDate, .ratedOnly])
    }

    @Test("LOGIC: the predicate table — every pure filter has one, the model-backed and group filters do not")
    func predicateTableCoversEveryFilter() {
        let modelBacked: Set<CatalogViewFilter> = [.notYetArchived, .hasMasterCopy, .archiveCandidates, .onePerFootage]
        for f in CatalogViewFilter.allCases {
            #expect((f.recordPredicate == nil) == modelBacked.contains(f), "\(f)")
        }
        let keep = CatalogViewFilter.confirmedDate.recordPredicate
        #expect(keep?(rec("dated.mov", date: "1992")) == true)
        #expect(keep?(rec("undated.mov")) == false)
        // The table and the loop give the same rows the hand-written branches gave.
        let rows = [rec("a.mov", date: "1991"), rec("b.mov"), rec("c.mov", date: "1992")]
        rows[2].starRating = 4
        var out = rows
        for f in CatalogViewFilter.allCases where Set<CatalogViewFilter>([.confirmedDate, .ratedOnly]).contains(f) {
            if let keep = f.recordPredicate { out = out.filter(keep) }
        }
        #expect(out.map(\.filename) == ["c.mov"])
    }

    @Test("LOGIC: the Showing box names the chip beside its neighbours, in declaration order")
    func showingBoxNamesTheChip() {
        let s = CatalogShowingSummary.State(viewFilters: [.confirmedDate, .ratedOnly])
        #expect(CatalogShowingSummary.pills(for: s).map(\.text) == ["Videos", "Starred", "Confirmed date", "Connected drives"])
        #expect(CatalogShowingSummary.sentence(for: s) == "Showing Videos, Starred, Confirmed date, Connected drives")
    }

    @Test("ISOLATION: a malformed user date never counts and never crashes")
    func malformedUserDateNeverCounts() {
        for bad in ["banana", "", "   ", "19", "1992-13", "1992-02-30", "6/1992/x", "1992/06", "92"] {
            #expect(!pfRecordHasConfirmedDate(rec("bad.mov", date: bad, confidence: "known")), "counted \"\(bad)\"")
        }
        // A confidence with no date is not a date (the schema allows the row; the predicate does not count it).
        #expect(!pfRecordHasConfirmedDate(rec("conf-only.mov", date: nil, confidence: "known")))
    }

    @Test("ISOLATION: a removed row with a confirmed date is not in the table")
    func removedRowIsNotInTheTable() {
        let kept = rec("kept.mov", date: "1992")
        let gone = rec("gone.mov", date: "1992")
        gone.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let table = pfApplyPurgeFilter([kept, gone], showRemoved: false).filter(pfRecordHasConfirmedDate)
        #expect(table.map(\.filename) == ["kept.mov"])
        // Show Removed is an explicit reveal: the removed row comes back, still dated.
        let revealed = pfApplyPurgeFilter([kept, gone], showRemoved: true).filter(pfRecordHasConfirmedDate)
        #expect(revealed.map(\.filename) == ["kept.mov", "gone.mov"])
    }
}

// MARK: - TRUTH (production shape, sandboxed catalog.sqlite)

@Suite("Confirmed date filter — truth against catalog.sqlite", .serialized)
@MainActor
struct ConfirmedDateFilterTruthTests {

    /// A direct count of the catalog's confirmed-date fact: one `user_dates`
    /// row with a value, not in conflict, on a live `files` row — the loader's
    /// own join (`GRDBCatalogRepository+Load`), through a second, read-only
    /// connection.
    private func storedConfirmedDateCount(_ databaseURL: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CutoverFailure(words: "sqlite3_open_v2 failed on the sandbox database")
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT count(*) FROM files f
              JOIN user_dates ud ON ud.digest = f.content_digest
             WHERE f.removal_state IS NULL AND ud.conflict = 0 AND ud.value IS NOT NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CutoverFailure(words: "sqlite3_prepare_v2 failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CutoverFailure(words: "sqlite3_step returned no row") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test("TRUTH: the chip's count equals the store's count of confirmed dates on the same snapshot — before and after Rick dates two records")
    func chipCountEqualsTheStoresCount() async throws {
        let scene = try CutoverScene.make("confirmed_date"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.catalogCutover.isSQLiteAuthority)

        // The table's own first pass (removed rows out), then the chip.
        func chipRows(_ records: [VideoRecord]) -> [VideoRecord] {
            pfApplyPurgeFilter(records, showRemoved: false).filter(pfRecordHasConfirmedDate)
        }

        // The fixture's only user dates are the two copies in CONFLICT: shown
        // empty by the loader, conflict = 1 in the store — zero on both sides.
        let before = chipRows(try await scene.sqliteLoad().records).count
        #expect(before == 0)
        #expect(before == (try storedConfirmedDateCount(scene.databaseURL)))

        try scene.record(.healthy).userDate = "1992-06-14"
        try scene.record(.healthy).userDateConfidence = "known"
        try scene.record(.stalePrint).userDate = "1991"
        try scene.record(.stalePrint).userDateConfidence = "estimated"
        // A removed row Rick dated: a fact in the store, not a row in the table — neither side counts it.
        try scene.record(.tombstonedWithDigest).userDate = "1990"
        try scene.record(.tombstonedWithDigest).userDateConfidence = "known"
        #expect(try scene.record(.tombstonedWithDigest).isPurged, "the fixture's tombstoned row is removed")
        #expect(scene.model.saveCatalogNow())

        let snapshot = try await scene.sqliteLoad()
        let chip = chipRows(snapshot.records)
        let stored = try storedConfirmedDateCount(scene.databaseURL)
        #expect(chip.count == 2, "the two live records Rick dated")
        #expect(chip.count == stored, "chip \(chip.count) vs user_dates on live files \(stored)")
        #expect(Set(chip.map(\.id.uuidString)) == [PoisonedCatalogFixture.id(.healthy), PoisonedCatalogFixture.id(.stalePrint)])
    }
}

// MARK: - SENSOR (source-reading: the chip exists in the filter row)

@Suite("Confirmed date filter — chip-in-the-row sensor")
struct ConfirmedDateFilterSensorTests {

    @Test("SENSOR: the chip is a CatalogViewFilter case the Show menu iterates, with words, and the filter pass applies it")
    func chipExistsInTheFilterRow() throws {
        // The enum the Show menu draws (one Toggle per case).
        let content = try SourceTree.appCode(named: "ContentView.swift")
        #expect(content.contains("case confirmedDate = \"Confirmed Date\""))
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        #expect(toolbar.contains("Section(\"Show files — filters\")"))
        #expect(toolbar.contains("ForEach(CatalogViewFilter.allCases, id: \\.self) { filter in"),
                "the Show menu draws every CatalogViewFilter case — the chip rides allCases")
        // The words in the Showing box (compiler-enforced switch, pinned here by name).
        let summary = try SourceTree.appCode(named: "CatalogShowingSummary.swift")
        #expect(summary.contains("case .confirmedDate:"))
        #expect(summary.contains("\"Confirmed date\""))
        // Applied in the ONE filter pass, through the enum's predicate table, never in a body.
        #expect(content.contains("case .confirmedDate:        return pfRecordHasConfirmedDate"))
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        #expect(helpers.contains("for filter in CatalogViewFilter.allCases where viewFilters.contains(filter) {"))
        #expect(helpers.contains("if let keep = filter.recordPredicate { out = out.filter(keep) }"))
        #expect(!helpers.contains("viewFilters.contains(.confirmedDate)"), "no hand-written branch beside the table")
        // The predicate reads Rick's date — never a machine date.
        let queries = try SourceTree.appCode(named: "CatalogQueries.swift")
        let start = try #require(queries.range(of: "func pfRecordHasConfirmedDate("))
        let body = String(queries[start.lowerBound...].prefix(400))
        #expect(body.contains("userDateStatus"))
        #expect(body.contains("UserDateEntry.canonicalize"))
        for machine in ["inferredRecordDate", "embeddedCreationDate", "dateCreatedRaw", "dateModifiedRaw", "resolvedDate"] {
            #expect(!body.contains(machine), "the predicate must not read \(machine)")
        }
    }
}
