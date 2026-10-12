// RemovalMarkerMigrationTests.swift
// GH #143 step 3 (docs/design/one_removal_marker_and_trash_engine.md §2):
// the one removal marker and the load-time migration of every older
// "gone" encoding onto it.
//
// Dimensions:
//   - logic: the migration table, cell by cell, and exhaustively over every
//     LifecycleStage × ArchiveStage × purged/not purged;
//   - isolation: a poisoned catalog (a damaged or unknown marker) loads,
//     falling back to the legacy fields;
//   - scale: 100k records through the real CatalogStore load under a budget;
//   - round trip: every state survives save → load, with `purgedAt` still
//     on disk for an older build.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Removal marker — migration and persistence (GH #143)", .serialized)
@MainActor
struct RemovalMarkerMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let loaded = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_removal_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Logic — the table

    @Test func theMigrationTableCellByCell() {
        func m(_ purged: Date?, _ ls: LifecycleStage, _ asg: ArchiveStage = .none) -> RemovalMarker? {
            RemovalMarker.migrated(stored: nil, purgedAt: purged, lifecycleStage: ls, archiveStage: asg, loadedAt: loaded)
        }
        #expect(m(t0, .trashed) == .inTrash(movedAt: t0, trashPath: nil, reason: .legacyTrashed))
        #expect(m(t0, .deletedPermanently) == .missing(noticedAt: t0, lastSeen: t0, reason: .legacyDeleted))
        for stage in [LifecycleStage.cataloged, .reviewing, .workbench, .archived] {
            #expect(m(t0, stage) == .removedFromCatalog(at: t0, reason: .legacyPurged), "\(stage)")
        }
        #expect(m(nil, .cataloged, .manuallyDeleted) == .removedFromCatalog(at: loaded, reason: .legacyDeletedLabel))
        // A purge wins over the label: its date and stage are the real record.
        #expect(m(t0, .trashed, .manuallyDeleted)?.state == .inTrash)
        // A stage with no purge (CatalogAuditFixer residue) never newly hides a row.
        #expect(m(nil, .trashed) == nil)
        #expect(m(nil, .deletedPermanently) == nil)
        #expect(m(nil, .cataloged) == nil)
        // A stored marker is kept whatever the legacy fields say.
        let stored = RemovalMarker.inTrash(movedAt: t0, trashPath: "/x/.Trash/a.mov", reason: .duplicate)
        #expect(RemovalMarker.migrated(stored: stored, purgedAt: nil, lifecycleStage: .cataloged,
                                       archiveStage: .none, loadedAt: loaded) == stored)
    }

    @Test func everyLegacyCombinationMapsToExactlyTheRuledState() {
        for purged in [nil, t0] as [Date?] {
            for ls in LifecycleStage.allCases {
                for asg in ArchiveStage.allCases {
                    let got = RemovalMarker.migrated(stored: nil, purgedAt: purged, lifecycleStage: ls,
                                                     archiveStage: asg, loadedAt: loaded)
                    let want: RemovalMarker.State?
                    if purged != nil {
                        want = ls == .trashed ? .inTrash : (ls == .deletedPermanently ? .missing : .removedFromCatalog)
                    } else {
                        want = asg == .manuallyDeleted ? .removedFromCatalog : nil
                    }
                    #expect(got?.state == want, "purged=\(purged != nil) \(ls) \(asg)")
                    // Hidden exactly when the old build hid it by purge, plus the label.
                    #expect((got != nil) == (purged != nil || asg == .manuallyDeleted))
                }
            }
        }
    }

    @Test func purgedAtIsDerivedAndItsSetterIsAShim() {
        let r = VideoRecord()
        #expect(r.purgedAt == nil && r.removal == nil)
        r.purgedAt = t0
        #expect(r.removal == .removedFromCatalog(at: t0, reason: .unspecified))
        r.removal = .inTrash(movedAt: t0, trashPath: "/T/a.mov", reason: .junk)
        let later = t0.addingTimeInterval(60)
        r.purgedAt = later
        #expect(r.removal?.state == .inTrash && r.removal?.trashPath == "/T/a.mov" && r.purgedAt == later,
                "a date write moves only `since`")
        r.purgedAt = nil
        #expect(r.removal == nil, "nil is Restore")
    }

    @Test func trashEmptiedIsRecordedOnceAndOnlyForAKnownTrashPath() {
        var m = RemovalMarker.inTrash(movedAt: t0, trashPath: "/T/a.mov", reason: .junk)
        let first = m.noteTrashEmptied(at: loaded)
        let second = m.noteTrashEmptied(at: loaded.addingTimeInterval(5))
        #expect(first)
        #expect(!second, "the first sighting wins")
        #expect(m.trashEmptiedSeenAt == loaded)
        var unknown = RemovalMarker.inTrash(movedAt: t0, trashPath: nil, reason: .legacyTrashed)
        let unknownChanged = unknown.noteTrashEmptied(at: loaded)
        #expect(!unknownChanged)
        var removed = RemovalMarker.removedFromCatalog(at: t0, reason: .userRemoved)
        let removedChanged = removed.noteTrashEmptied(at: loaded)
        #expect(!removedChanged)
    }

    // MARK: Decode from an older catalog's JSON

    private func decode(_ fields: String) throws -> VideoRecord {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"filename\":\"a.mov\",\"fullPath\":\"/x/a.mov\"\(fields)}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: Data(json.utf8))
    }

    @Test func aPreMarkerCatalogIsConvertedOnLoad() throws {
        let trashed = try decode(",\"purgedAt\":\"2023-11-14T22:13:20Z\",\"lifecycleStage\":\"Trashed\"")
        #expect(trashed.removal == .inTrash(movedAt: t0, trashPath: nil, reason: .legacyTrashed))
        #expect(trashed.purgedAt == t0)
        let removed = try decode(",\"purgedAt\":\"2023-11-14T22:13:20Z\"")
        #expect(removed.removal?.state == .removedFromCatalog)
        let label = try decode(",\"archiveStage\":\"Manually Deleted\"")
        #expect(label.removal?.state == .removedFromCatalog && label.removal?.reason == .legacyDeletedLabel)
        #expect(label.isPurged, "the label's rows stay hidden")
        let live = try decode("")
        #expect(live.removal == nil && !live.isPurged)
    }

    // MARK: Isolation — a poisoned catalog

    @Test func aDamagedOrUnknownMarkerFallsBackToTheLegacyFields() throws {
        let garbage = try decode(",\"purgedAt\":\"2023-11-14T22:13:20Z\",\"lifecycleStage\":\"Trashed\",\"removal\":42")
        #expect(garbage.removal?.state == .inTrash, "a damaged marker reads as absent; the legacy fields decide")
        let future = try decode(",\"removal\":{\"state\":\"vaporised\",\"since\":\"2023-11-14T22:13:20Z\",\"reason\":\"x\"}")
        #expect(future.removal == nil, "an unknown state never hides a live row by guesswork")
        let unknownReason = try decode(",\"removal\":{\"state\":\"missing\",\"since\":\"2023-11-14T22:13:20Z\",\"reason\":\"fromTheFuture\"}")
        #expect(unknownReason.removal?.state == .missing && unknownReason.removal?.reason.rawValue == "fromTheFuture")
    }

    @Test func aPoisonedCatalogFileStillLoadsEveryRow() throws {
        let dir = try scratch("poison"); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = (0..<3).map { _ in UUID().uuidString }
        let json = """
        {"version": 6, "records": [
          {"id":"\(ids[0])","filename":"a.mov","fullPath":"/x/a.mov","removal":{"state":42}},
          {"id":"\(ids[1])","filename":"b.mov","fullPath":"/x/b.mov","purgedAt":"2023-11-14T22:13:20Z","removal":"nonsense"},
          {"id":"\(ids[2])","filename":"c.mov","fullPath":"/x/c.mov","archiveStage":"Manually Deleted","removal":[]}
        ]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("catalog.json"))
        let loaded = CatalogStore(directory: dir).load()
        #expect(loaded.count == 3, "every row loads")
        let byName = Dictionary(uniqueKeysWithValues: loaded.map { ($0.filename, $0) })
        #expect(byName["a.mov"]?.removal == nil)
        #expect(byName["b.mov"]?.removal?.state == .removedFromCatalog)
        #expect(byName["c.mov"]?.removal?.reason == .legacyDeletedLabel)
    }

    // MARK: Round trip

    @Test func everyStateRoundTripsAndPurgedAtStaysOnDiskForAnOlderBuild() throws {
        let dir = try scratch("roundtrip"); defer { try? FileManager.default.removeItem(at: dir) }
        var trashed = RemovalMarker.inTrash(movedAt: t0, trashPath: "/Volumes/A/.Trashes/501/a.mov", reason: .duplicate)
        trashed.noteTrashEmptied(at: loaded)
        let markers: [RemovalMarker?] = [
            nil,
            trashed,
            .removedFromCatalog(at: t0, reason: .userRemoved),
            .missing(noticedAt: loaded, lastSeen: t0, reason: .missingOnDisk),
        ]
        let recs = markers.enumerated().map { i, m -> VideoRecord in
            let r = VideoRecord(); r.filename = "f\(i).mov"; r.fullPath = "/x/f\(i).mov"; r.removal = m; return r
        }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: recs))
        let text = try String(contentsOf: dir.appendingPathComponent("catalog.json"), encoding: .utf8)
        #expect(text.components(separatedBy: "\"purgedAt\"").count - 1 == 3, "derived purgedAt written for each removed row")
        let reader = CatalogStore(directory: dir)
        let back = reader.load()
        let byID = Dictionary(uniqueKeysWithValues: back.map { ($0.id, $0) })
        for r in recs {
            #expect(byID[r.id]?.removal == r.removal, "\(r.filename)")
        }
        let restored = try #require(byID[recs[1].id])
        restored.removal = nil
        #expect(reader.saveNow(records: back))
        let again = Dictionary(uniqueKeysWithValues: CatalogStore(directory: dir).load().map { ($0.id, $0) })
        #expect(again[recs[1].id]?.removal == nil && again[recs[1].id]?.purgedAt == nil, "Restore drops both keys")
    }

    // MARK: Scale — 100k records through the real load

    @Test func a100kCatalogMigratesOnLoadWithinBudget() throws {
        let dir = try scratch("scale"); defer { try? FileManager.default.removeItem(at: dir) }
        // Mixed legacy shapes, written as an older build would: no `removal` key.
        var body = ""
        body.reserveCapacity(100_000 * 120)
        for i in 0..<100_000 {
            let tail: String
            switch i % 5 {
            case 0: tail = ",\"purgedAt\":\"2023-11-14T22:13:20Z\",\"lifecycleStage\":\"Trashed\""
            case 1: tail = ",\"purgedAt\":\"2023-11-14T22:13:20Z\""
            case 2: tail = ",\"archiveStage\":\"Manually Deleted\""
            default: tail = ""
            }
            if i > 0 { body += "," }
            body += "{\"id\":\"\(UUID().uuidString)\",\"filename\":\"f\(i).mov\",\"fullPath\":\"/Volumes/V/f\(i).mov\"\(tail)}"
        }
        try Data("{\"version\":6,\"records\":[\(body)]}".utf8).write(to: dir.appendingPathComponent("catalog.json"))
        let clock = ContinuousClock()
        var result: [VideoRecord] = []
        let elapsed = clock.measure { result = CatalogStore(directory: dir).load() }
        let all = result
        let inTrash = all.count { $0.removal?.state == .inTrash }
        let removed = all.count { $0.removal?.state == .removedFromCatalog }
        let live = all.count { $0.removal == nil }
        #expect(all.count == 100_000)
        #expect(inTrash == 20_000)
        #expect(removed == 40_000)
        #expect(live == 40_000)
        // Debug build, whole load (JSON + dedupe + pair rewiring), ~1.7 s on
        // the M4 (2026-10-11); 8 s leaves CI room. The
        // migration itself is O(1) per row and touches no disk.
        #expect(elapsed < .seconds(8), "100k load took \(elapsed)")
    }
}
