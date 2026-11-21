// CatalogOutOfRangeStarCommitTests.swift
//
// A side observation from the debounce-seam work (2026-11-20) — "setting
// starRating = 5 made the whole next commit not land, including an unrelated
// notes edit" — reproduced in the smallest form, and found NOT to be what it
// looked like. Pinned here so the next reader does not chase it again.
//
// What is true:
//   - 5 is out of range. The schema is `stars.rating INTEGER CHECK (rating
//     IS NULL OR rating BETWEEN 1 AND 3)` (CatalogDataSchema+Knowledge.swift)
//     and the one star control offers 1…3 (InspectorPanel `maxStars = 3`).
//     The observation came from a test that wrote 5 straight into the model.
//   - The commit door refuses PER ROW, not per commit. The record carrying
//     the 5 is refused with SQLite's own words; every other changed record
//     in the same commit is written and the generation advances.
//   - The "unrelated notes edit" in the observation was on the SAME record
//     as the 5. A row is stored or refused as a unit, so that note waited
//     with it. It is not lost: it stays pending in memory, the save reports
//     false, and both land as soon as the rating is back in range.
//
// One thing found by reading, not tested here (Archive/, data-risk):
// `registerOrphanPromotedCopy` sets `copy.starRating = max(3, stars)` from a
// manifest row (VideoScanModel+MasterArchive.swift) — a manifest that says 4
// or 5 would put that record into exactly the refused state below.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog commit — one record's out-of-range star rating", .serialized)
@MainActor
struct CatalogOutOfRangeStarCommitTests {

    @Test("the record with the bad rating is refused in SQLite's words; ANOTHER record's edit in the same commit is stored")
    func onlyTheBadRowIsRefused() async throws {
        let scene = try CutoverScene.make("star_range"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        let generation = committer.knownGeneration
        let bad = try scene.record(.healthy)

        bad.starRating = 5                                      // out of range (schema and UI: 1…3)
        try scene.record(.curatedConflictA).userNotes = "an unrelated edit on another record"
        #expect(scene.model.saveCatalogNow() == false, "the save reports that not everything landed")

        guard case .committed(_, let rows) = try #require(committer.lastOutcome) else {
            Issue.record("expected .committed with per-row results, got \(String(describing: committer.lastOutcome))")
            return
        }
        let badRow = try #require(rows.first { $0.id == bad.id })
        guard case .refused(let words) = badRow.landing else {
            Issue.record("expected the bad row refused, got \(badRow.landing)")
            return
        }
        #expect(words.contains("CHECK constraint failed: rating IS NULL OR rating BETWEEN 1 AND 3"))
        #expect(committer.knownGeneration == generation + 1, "the rest of the commit landed")
        #expect(try await scene.reloaded(.curatedConflictA).userNotes == "an unrelated edit on another record")
        #expect(try await scene.reloaded(.healthy).starRating != 5, "the out-of-range value never reaches catalog.sqlite")
        #expect(committer.changedRecordCount() == 1, "only the refused record is still pending")

        bad.starRating = 3                                      // back in range
        #expect(scene.model.saveCatalogNow(), "no poisoned state: the same session stores it")
        #expect(try await scene.reloaded(.healthy).starRating == 3)
        #expect(committer.changedRecordCount() == 0)
    }

    @Test("the original observation: a note on the SAME record waits with it (a row is stored or refused whole), and lands once the rating is in range")
    func anEditOnTheSameRecordWaitsWithIt() async throws {
        let scene = try CutoverScene.make("star_range_same"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        let bad = try scene.record(.healthy)

        bad.userNotes = "typed on the record with the bad rating"
        bad.starRating = 5
        #expect(scene.model.saveCatalogNow() == false)
        #expect(scene.model.saveCatalogNow() == false, "and again: every save meets the same row")
        #expect(try await scene.reloaded(.healthy).userNotes != "typed on the record with the bad rating")
        #expect(committer.changedRecordCount() == 1, "the note is still pending in memory, not lost")

        bad.starRating = 3
        #expect(scene.model.saveCatalogNow())
        let stored = try await scene.reloaded(.healthy)
        #expect(stored.userNotes == "typed on the record with the bad rating")
        #expect(stored.starRating == 3)
    }
}
