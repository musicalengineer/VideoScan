// ConfirmedDateFilterTests.swift
// Rick's own date on a record, and the Show filter that reads dates.
//
// History: "Confirmed Date" was a Show filter (Rick 2026-10-31). On 2026-11-17
// the Show menu was cut to the bare minimum and the filter was INVERTED into
// "Needs a Date" (CatalogViewFilter.needsDate → pfRecordNeedsDate): the rows
// with no usable filing date. `pfRecordHasConfirmedDate` stays — the File
// Journey and the machine-era readers ask it — so its tests stay here, beside
// the truth test both predicates share.
//
// Dimensions:
//   LOGIC      pfRecordHasConfirmedDate keeps exactly the rows with Rick's own
//              date (either confidence). Needs a Date's membership, the held
//              row and the 100k budget are in CatalogRowsTests.swift.
//   TRUTH      production shape: records dated through the model, committed to
//              catalog.sqlite by the one committer, reloaded by the one loader —
//              the confirmed-date count equals a direct SQL count of
//              `user_dates` rows on live files, and no row the store holds a
//              date for is listed under Needs a Date.
//   SCALE      ConfirmedDateFilterScaleTests.swift (the confirmed-date
//              predicate); CatalogRowsScaleTests (Needs a Date in the pass).
//   ISOLATION  a malformed user date ("banana", "", "19", "1992-13") never
//              counts and never crashes; a removed row is not in the table.
//   SENSOR     (ConfirmedDateFilterSensorTests) Needs a Date is a filter case
//              the Show menu iterates, applied in the ONE rows function
//              through the predicate table, and it is the Archive tab's rule.
//   MEDIA      N/A — no media is opened.

import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - LOGIC + ISOLATION

@Suite("Confirmed date — the predicate")
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

@Suite("Confirmed date and Needs a Date — truth against catalog.sqlite", .serialized)
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

    @Test("TRUTH: Needs a Date on the reloaded catalog — a file Rick dated leaves the list, and no listed row has a stored date")
    func needsDateFollowsTheStoredDates() async throws {
        let scene = try CutoverScene.make("needs_a_date"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.catalogCutover.isSQLiteAuthority)

        // The Catalog's own pass: every kind, no reachability probes, the one filter on.
        func needsDate(_ records: [VideoRecord]) -> [VideoRecord] {
            var state = CatalogRows.State()
            state.showDisconnectedMedia = true
            state.filters = [.needsDate]
            return CatalogRows.rows(records, state).rows
        }
        let before = Set(needsDate(try await scene.sqliteLoad().records).map(\.id.uuidString))

        try scene.record(.healthy).userDate = "1992-06-14"
        try scene.record(.healthy).userDateConfidence = "known"
        try scene.record(.stalePrint).userDate = "1991"
        try scene.record(.stalePrint).userDateConfidence = "estimated"
        #expect(scene.model.saveCatalogNow())

        let snapshot = try await scene.sqliteLoad()
        let listed = needsDate(snapshot.records)
        let after = Set(listed.map(\.id.uuidString))
        #expect(!after.contains(PoisonedCatalogFixture.id(.healthy)), "Rick dated it: it has a filing date")
        #expect(!after.contains(PoisonedCatalogFixture.id(.stalePrint)), "his best guess is a filing date too")
        #expect(after.isSubset(of: before), "dating files can only shorten the list")
        // No listed row carries a date the store holds for it; every listed
        // row is one the Archive tab's own rule would list.
        for r in listed {
            #expect(!pfRecordHasConfirmedDate(r), "\(r.filename) is listed as needing a date but has Rick's")
            #expect(ArchiveCategorySnapshot.needsDate(r))
            #expect(!r.isPurged)
        }
        let live = pfApplyPurgeFilter(snapshot.records, showRemoved: false)
        let dated = live.filter(pfRecordHasConfirmedDate)
        #expect(dated.count == (try storedConfirmedDateCount(scene.databaseURL)))
        #expect(Set(dated.map(\.id)).isDisjoint(with: listed.map(\.id)))
    }
}

// MARK: - SENSOR (source-reading: Needs a Date is in the filter row)

@Suite("Needs a Date filter — chip-in-the-row sensor")
struct ConfirmedDateFilterSensorTests {

    @Test("SENSOR: Needs a Date is a CatalogViewFilter case the Show menu iterates, applied in the one rows function, by the Archive tab's rule")
    func chipExistsInTheFilterRow() throws {
        // The enum the Show menu draws (one Toggle per case), keyed by a stable raw value.
        let store = try SourceTree.appCode(named: "CatalogShowFilterStore.swift")
        #expect(store.contains("case needsDate"))
        #expect(store.contains("case .needsDate:          return \"Needs a Date\""))
        #expect(!store.contains("confirmedDate"), "the inverted filter is gone, not kept beside its opposite")
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        #expect(toolbar.contains("Section(\"Show files — filters\")"))
        #expect(toolbar.contains("ForEach(CatalogViewFilter.allCases, id: \\.self) { filter in"),
                "the Show menu draws every CatalogViewFilter case — the chip rides allCases")
        #expect(toolbar.contains("Label(filter.title, systemImage: filter.icon)"), "the menu says the filter's title")
        // The Showing box says the same words: it has no vocabulary of its own.
        let summary = try SourceTree.appCode(named: "CatalogShowingSummary.swift")
        #expect(summary.contains("static func words(for filter: CatalogViewFilter) -> String { filter.title }"))
        // Applied in the ONE rows function, through the enum's predicate table, never in a body.
        #expect(store.contains("case .needsDate:          return pfRecordNeedsDate"))
        let rows = try SourceTree.appCode(named: "CatalogRows.swift")
        #expect(rows.contains("for filter in CatalogViewFilter.ordered(state.filters) {"))
        #expect(rows.contains("if let keep = filter.recordPredicate { out = out.filter(keep) }"))
        #expect(!rows.contains("contains(.needsDate)"), "no hand-written branch beside the table")
        // ONE rule: the predicate is the Archive tab's Needs a Date, which asks Promote's resolver.
        let queries = try SourceTree.appCode(named: "CatalogQueries.swift")
        let start = try #require(queries.range(of: "func pfRecordNeedsDate("))
        let body = String(queries[start.lowerBound...].prefix(160))
        #expect(body.contains("ArchiveCategorySnapshot.needsDate(rec)"))
        let categories = try SourceTree.appCode(named: "ArchiveView+Categories.swift")
        let rule = try #require(categories.range(of: "static func needsDate(_ f: DateFacts) -> Bool {"))
        #expect(String(categories[rule.lowerBound...].prefix(260)).contains("RecordDateResolver.resolve("))
    }
}
