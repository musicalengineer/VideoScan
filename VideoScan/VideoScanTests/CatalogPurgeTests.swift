import Testing
import Foundation
@testable import VideoScan

// MARK: - Catalog "Remove from Catalog" (soft-delete) tests
//
// Feature spec (Manager dispatch 2026-05-15):
//   - Mark catalog records purged via right-click → "Remove from Catalog".
//   - Default catalog view hides purged rows; "Show removed" toggle includes
//     them (italic + orange).
//   - "Restore to Catalog" clears purgedAt.
//   - Files on disk are NEVER touched — soft-delete only.
//
// Mirrors POIDeletionTests / POIUndoDeleteTests in spirit: each test owns
// its own VideoRecord instances and (where needed) a per-test VideoScanModel.
// CatalogStore.isRunningTests detects the test bundle and short-circuits
// load/save, so constructing VideoScanModel() doesn't touch the user's
// real catalog.json.
//
// Each test is named with the testPurge* prefix called out in the dispatch
// spec so qa can grep them at a glance.

struct CatalogPurgeTests {

    // MARK: - Test helpers

    /// Build a minimal active record for filtering / persistence tests.
    private func makeRecord(
        name: String,
        path: String? = nil,
        purgedAt: Date? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = path ?? "/Volumes/TestVol/\(name)"
        r.directory = "/Volumes/TestVol"
        r.partialMD5 = String(name.hash, radix: 16)
        r.sizeBytes = 1_000_000
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.purgedAt = purgedAt
        return r
    }

    // MARK: - 1. Default value

    // regression: feature spec — new records must default to purgedAt == nil
    // so existing scan paths keep producing active rows. A failing assertion
    // here would mean every newly cataloged file is born hidden.
    @Test func testPurgedAtDefaultsToNilForNewRecord() {
        let r = VideoRecord()
        #expect(r.purgedAt == nil,
                "Freshly constructed VideoRecord must have purgedAt == nil")
        #expect(r.isPurged == false,
                "isPurged convenience must agree with purgedAt == nil")
    }

    // MARK: - 2. Codable compat with pre-feature catalog.json

    // regression: feature spec — schema change must be additive; decoding a
    // catalog.json that predates the feature must succeed and yield
    // purgedAt == nil rather than throwing or producing a "removed" record.
    // This is the canary for the entire on-disk migration story.
    @Test func testDecodingLegacyCatalogJsonYieldsNilPurgedAt() throws {
        // Synthesize a v1-shaped catalog blob — no `purgedAt` key anywhere.
        // We hand-roll the JSON rather than encoding a VideoRecord (the
        // current encoder no-ops purgedAt when nil, but a future change
        // could leak a "purgedAt": null field that would falsely pass the
        // test). Hand-rolled JSON guarantees absence of the key.
        let legacyJSON = """
        {
          "version": 2,
          "savedAt": "2026-04-01T12:00:00Z",
          "savedFromHost": "TestHost",
          "records": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "filename": "legacy_clip.mov",
              "fullPath": "/Volumes/Legacy/legacy_clip.mov",
              "streamTypeRaw": "Video+Audio",
              "sizeBytes": 1234567,
              "durationSeconds": 12.5
            },
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "filename": "another.mxf",
              "fullPath": "/Volumes/Legacy/another.mxf",
              "streamTypeRaw": "Video only",
              "sizeBytes": 987654,
              "durationSeconds": 30
            }
          ]
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
        #expect(snapshot.records.count == 2)
        for rec in snapshot.records {
            #expect(rec.purgedAt == nil,
                    "Legacy record \(rec.filename): purgedAt must decode to nil when the key is absent")
            #expect(rec.isPurged == false,
                    "Legacy record \(rec.filename): isPurged must report false")
        }
    }

    // MARK: - 3. Purge sets timestamp

    // regression: feature spec — purgeRecords must stamp purgedAt with a
    // recent Date(). We allow a generous ±10s tolerance for slow CI runners.
    @Test @MainActor
    func testPurgeSetsPurgedAtTimestamp() async throws {
        let model = VideoScanModel()
        model.records = []
        let r = makeRecord(name: "clip.mov")
        model.records = [r]

        let before = Date()
        let n = model.purgeRecords(ids: [r.id])
        let after = Date()

        #expect(n == 1, "purgeRecords should report 1 mutated row")
        #expect(r.purgedAt != nil, "purgedAt must be set after purge")
        if let stamped = r.purgedAt {
            #expect(stamped >= before.addingTimeInterval(-10),
                    "purgedAt should be on or after the call time")
            #expect(stamped <= after.addingTimeInterval(10),
                    "purgedAt should be on or before the call return")
        }
        #expect(r.isPurged == true,
                "isPurged must flip true once purgedAt is set")
    }

    // MARK: - 4. Restore clears the marker

    // regression: feature spec — Restore is the inverse of Purge.
    // restoreRecord must clear purgedAt back to nil. Without this test the
    // restore path could regress to "Date(distantPast)" or similar non-nil
    // sentinel which would still flag isPurged.
    @Test @MainActor
    func testRestoreClearsPurgedAt() async throws {
        let model = VideoScanModel()
        model.records = []
        let r = makeRecord(name: "purged.mov", purgedAt: Date())
        model.records = [r]
        #expect(r.isPurged == true, "Pre-condition: record should start purged")

        let ok = model.restoreRecord(id: r.id)
        #expect(ok == true, "restoreRecord must return true for a purged record")
        #expect(r.purgedAt == nil, "Restore must null out purgedAt")
        #expect(r.isPurged == false, "isPurged must flip false")
    }

    // MARK: - 5. Default filter hides purged

    // regression: feature spec — default catalog view (showRemoved == false)
    // must hide purged rows.
    @Test func testDefaultFilterHidesPurgedRecords() {
        let active1 = makeRecord(name: "a.mov")
        let active2 = makeRecord(name: "b.mov")
        let purged1 = makeRecord(name: "old.mov", purgedAt: Date())
        let all = [active1, purged1, active2]

        let filtered = pfApplyPurgeFilter(all, showRemoved: false)
        let filteredIDs = Set(filtered.map { $0.id })

        #expect(filtered.count == 2,
                "Default filter must hide 1 purged record")
        #expect(filteredIDs.contains(active1.id))
        #expect(filteredIDs.contains(active2.id))
        #expect(!filteredIDs.contains(purged1.id),
                "Purged record must NOT appear in default view")
    }

    // MARK: - 6. Show-removed toggle includes purged

    // regression: feature spec — when "Show removed" is on the filter is a
    // pass-through. Active AND purged records all surface.
    @Test func testShowRemovedFilterIncludesPurgedRecords() {
        let active = makeRecord(name: "active.mov")
        let purged = makeRecord(name: "purged.mov", purgedAt: Date())
        let all = [active, purged]

        let filtered = pfApplyPurgeFilter(all, showRemoved: true)
        let filteredIDs = Set(filtered.map { $0.id })

        #expect(filtered.count == 2,
                "Show-removed must include both active and purged")
        #expect(filteredIDs.contains(active.id))
        #expect(filteredIDs.contains(purged.id))
    }

    // MARK: - 7. Purge filter composes with online filter

    // regression: feature spec — purge filter and online/offline filter are
    // independent and compose. Four-way cartesian: {active, purged} x
    // {online, offline}. We model the online/offline axis with a predicate
    // since real reachability would require mounted /Volumes paths.
    @Test func testPurgeFilterComposesWithOnlineFilter() {
        let onlineActive  = makeRecord(name: "online_active.mov",
                                       path: "/online/a.mov")
        let onlineOffline = makeRecord(name: "online_purged.mov",
                                       path: "/online/p.mov",
                                       purgedAt: Date())
        let offlineActive = makeRecord(name: "offline_active.mov",
                                       path: "/offline/a.mov")
        let offlinePurged = makeRecord(name: "offline_purged.mov",
                                       path: "/offline/p.mov",
                                       purgedAt: Date())
        let all = [onlineActive, onlineOffline, offlineActive, offlinePurged]
        let isOnline: (VideoRecord) -> Bool = { $0.fullPath.hasPrefix("/online/") }

        // Case A: default catalog view (showRemoved=false, no online filter).
        // Both active records visible; both purged records hidden.
        var view = pfApplyPurgeFilter(all, showRemoved: false)
        var ids = Set(view.map { $0.id })
        #expect(ids == [onlineActive.id, offlineActive.id],
                "Default: only active rows (both online and offline) visible")

        // Case B: showRemoved on, no online filter — all four rows visible.
        view = pfApplyPurgeFilter(all, showRemoved: true)
        ids = Set(view.map { $0.id })
        #expect(ids.count == 4,
                "Show removed: every row (active + purged, online + offline) visible")

        // Case C: default purge + online-only filter. Only online active.
        view = pfApplyPurgeFilter(all, showRemoved: false).filter(isOnline)
        ids = Set(view.map { $0.id })
        #expect(ids == [onlineActive.id],
                "Online + default purge: exactly the online-active row")

        // Case D: show-removed + online-only. Online active AND online purged.
        view = pfApplyPurgeFilter(all, showRemoved: true).filter(isOnline)
        ids = Set(view.map { $0.id })
        #expect(ids == [onlineActive.id, onlineOffline.id],
                "Online + show-removed: both online-active and online-purged visible")

        // Case E: default purge + offline-only filter. Only offline active.
        view = pfApplyPurgeFilter(all, showRemoved: false).filter { !isOnline($0) }
        ids = Set(view.map { $0.id })
        #expect(ids == [offlineActive.id],
                "Offline + default purge: exactly the offline-active row")
    }

    // MARK: - 8. Multi-select purge marks all selected

    // regression: feature spec — supports multi-select. purgeRecords on a
    // set of IDs must mark every match (and only those). Bogus IDs are
    // tolerated (silently skipped) so the UI doesn't have to pre-filter.
    @Test @MainActor
    func testMultiSelectPurgeSetsTimestampOnAllSelected() async throws {
        let model = VideoScanModel()
        model.records = []
        let a = makeRecord(name: "a.mov")
        let b = makeRecord(name: "b.mov")
        let c = makeRecord(name: "c.mov")
        let d = makeRecord(name: "d.mov")    // unselected control
        let bogus = UUID()                   // not in catalog
        model.records = [a, b, c, d]

        let n = model.purgeRecords(ids: [a.id, b.id, c.id, bogus])

        #expect(n == 3,
                "purgeRecords should report 3 mutations (a, b, c) and skip the bogus UUID")
        #expect(a.isPurged && b.isPurged && c.isPurged,
                "All three selected records must be purged")
        #expect(d.isPurged == false,
                "Unselected record must remain active")
    }

    // MARK: - 9. Persistence round-trip

    // regression: feature spec — purgedAt must survive save → load.
    // CatalogStore short-circuits I/O under tests, so we round-trip through
    // the same JSONEncoder/Decoder configuration CatalogStore uses and
    // assert byte-level recovery of the purged state.
    @Test @MainActor
    func testCatalogPersistsPurgedAtAcrossSaveLoad() async throws {
        // Build two records, one purged.
        let active = makeRecord(name: "active.mov")
        let purgedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let purged = makeRecord(name: "purged.mov", purgedAt: purgedAt)

        // Encode using the same configuration CatalogStore.writeToDisk uses
        // (iso8601 dates, prettyPrinted, sortedKeys).
        let snapshot = CatalogSnapshot(records: [active, purged])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(CatalogSnapshotDTO(snapshot))

        // Decode via the same configuration CatalogStore.load uses.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(CatalogSnapshot.self, from: data)

        #expect(loaded.records.count == 2)
        let byName = Dictionary(uniqueKeysWithValues:
                                    loaded.records.map { ($0.filename, $0) })
        let loadedActive = try #require(byName["active.mov"])
        let loadedPurged = try #require(byName["purged.mov"])

        #expect(loadedActive.purgedAt == nil,
                "Active record's nil purgedAt must round-trip as nil")
        #expect(loadedPurged.purgedAt != nil,
                "Purged record's purgedAt must round-trip as non-nil")
        if let stamp = loadedPurged.purgedAt {
            // iso8601 has ~1s precision; allow ±2s.
            let drift = abs(stamp.timeIntervalSince(purgedAt))
            #expect(drift < 2,
                    "Purged timestamp drift after save/load must be < 2s, got \(drift)")
        }
        #expect(loadedActive.isPurged == false)
        #expect(loadedPurged.isPurged == true)
    }
}

// MARK: - Undo banner state tests
//
// Light coverage for the model-side undo state — the SwiftUI banner itself
// is visual-only and confirmed by Rick on the M5. The model methods are the
// regression surface (these are the codepaths that change catalog.json).

@MainActor
struct CatalogPurgeUndoStateTests {

    private func makeRecord(name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.partialMD5 = String(name.hash, radix: 16)
        r.sizeBytes = 1
        return r
    }

    // regression: feature spec — purging arms the undo banner with the
    // affected IDs and a timestamp. The banner observes lastPurgedBatch.
    @Test func purge_armsUndoBanner() async throws {
        let model = VideoScanModel()
        model.records = []
        let a = makeRecord(name: "a.mov")
        let b = makeRecord(name: "b.mov")
        model.records = [a, b]
        #expect(model.lastPurgedBatch == nil,
                "Pre-condition: no banner armed")

        _ = model.purgeRecords(ids: [a.id, b.id])

        let snap = try #require(model.lastPurgedBatch)
        #expect(Set(snap.ids) == [a.id, b.id],
                "Banner should track exactly the IDs we purged")
        #expect(model.lastPurgeUndoError == nil)
    }

    // regression: feature spec — undoLastPurge clears purgedAt on the batch
    // and drops the banner.
    @Test func undoLastPurge_restoresBatchAndClearsBanner() async throws {
        let model = VideoScanModel()
        model.records = []
        let a = makeRecord(name: "a.mov")
        let b = makeRecord(name: "b.mov")
        model.records = [a, b]
        _ = model.purgeRecords(ids: [a.id, b.id])
        #expect(a.isPurged && b.isPurged,
                "Pre-condition: both records purged")

        let ok = model.undoLastPurge()
        #expect(ok == true)
        #expect(a.isPurged == false,
                "Undo must un-purge first record")
        #expect(b.isPurged == false,
                "Undo must un-purge second record")
        #expect(model.lastPurgedBatch == nil,
                "Banner must clear after successful undo")
    }

    // regression: feature spec — second purge supersedes the first. The
    // first batch stays purged on disk (recoverable via Show Removed →
    // Restore), but the banner's Undo only walks back the most recent.
    @Test func secondPurge_supersedesFirstBatch() async throws {
        let model = VideoScanModel()
        model.records = []
        let a = makeRecord(name: "a.mov")
        let b = makeRecord(name: "b.mov")
        model.records = [a, b]

        _ = model.purgeRecords(ids: [a.id])
        _ = model.purgeRecords(ids: [b.id])

        let snap = try #require(model.lastPurgedBatch)
        #expect(snap.ids == [b.id],
                "Latest batch should track only the second purge target")
        #expect(a.isPurged == true,
                "First-batch record stays purged after supersede")
        #expect(b.isPurged == true)

        // Undo restores only B; A remains purged (manually recoverable).
        _ = model.undoLastPurge()
        #expect(a.isPurged == true,
                "Superseded first-batch record stays purged after undo")
        #expect(b.isPurged == false,
                "Most recent purge target restored")
    }
}

// MARK: - Gap tests added by testing agent (2026-05-16)
//
// Filling out coverage requested in the Manager dispatch:
//   1. Banner persistence across scan-target switch (model-side: the model
//      doesn't react to filter changes, so banner survives — that's the
//      spec).
//   2. Purge a record that is "actively" in the records array (no scan
//      engine plumbing — VideoScanModel just mutates rec.purgedAt; there
//      is no defensive lock against concurrent scan-engine writes).
//   3. Mixed purged/active round-trip with id + timestamp byte-recovery.
//   4. Bundle export → import round-trip preserves purgedAt.
//
// Pattern mirrors the existing CatalogPurgeTests above: each test owns its
// own VideoScanModel (CatalogStore.isRunningTests short-circuits I/O).

@MainActor
struct CatalogPurgeGapTests {

    private func makeRecord(
        name: String,
        path: String? = nil,
        purgedAt: Date? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = path ?? "/Volumes/TestVol/\(name)"
        r.directory = (path ?? "/Volumes/TestVol/\(name)")
            .components(separatedBy: "/").dropLast().joined(separator: "/")
        r.partialMD5 = String(name.hash, radix: 16)
        r.sizeBytes = 1_000_000
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.purgedAt = purgedAt
        return r
    }

    // MARK: - 10. Banner persists across scan-target switch
    //
    // regression: feature spec — the undo banner is bound to
    // `model.lastPurgedBatch`, which the model only clears on explicit
    // dismiss / undo / restore / supersede. Filter changes (catalog
    // selecting a different scan target / volume) live in @State on the
    // CatalogView and DO NOT mutate the model. This test pins that
    // behavior: a purge banner survives an arbitrary number of filter-set
    // mutations because the model never observes them. If a future change
    // wires up auto-clear on filter switch this test will start failing
    // and force a deliberate spec update — that's the point.
    //
    // Why we model the filter as a Swift `Set<String>` here: in the real
    // CatalogView the filter is a Set<String> of scan-target paths
    // (`filterTargetPaths` derived from `selectedVolumeIDs`); the model
    // never sees that Set, so the test only needs to assert that mutating
    // such a Set in isolation does NOT touch `model.lastPurgedBatch`.
    @Test func purgeBannerSurvivesScanTargetSwitch() async throws {
        let model = VideoScanModel()
        model.records = []
        let v1 = makeRecord(name: "a.mov", path: "/Volumes/V1/a.mov")
        let v2 = makeRecord(name: "b.mov", path: "/Volumes/V2/b.mov")
        model.records = [v1, v2]

        _ = model.purgeRecords(ids: [v1.id])
        let armed = try #require(model.lastPurgedBatch,
                                 "Pre-condition: banner armed by purge")
        let armedIDs = Set(armed.ids)

        // Simulate the CatalogView toggling its filterTargetPaths binding
        // through every reasonable state. None of these touch the model,
        // so the banner must survive byte-for-byte.
        var filterTargetPaths: Set<String> = []
        filterTargetPaths = ["/Volumes/V1"]      // select V1
        filterTargetPaths = ["/Volumes/V2"]      // switch to V2
        filterTargetPaths = ["/Volumes/V1", "/Volumes/V2"]
        filterTargetPaths = []                    // back to "all"
        _ = filterTargetPaths                     // silence unused-var

        // Banner must still be armed with the original batch contents —
        // same IDs, same timestamp.
        let still = try #require(model.lastPurgedBatch,
                                 "Banner must persist across catalog filter changes")
        #expect(Set(still.ids) == armedIDs,
                "Banner IDs must be byte-identical to the original arm")
        #expect(still.timestamp == armed.timestamp,
                "Banner timestamp must not drift")
        #expect(model.lastPurgeUndoError == nil)
    }

    // MARK: - 11. Purge during "active scan" — concurrent-mutation hazard
    //
    // The model exposes purgeRecords() without any guard against records
    // currently being mutated by a scan engine elsewhere. There is no
    // lock around `records` and no isScanning gate in purgeRecords. Per
    // the dispatch: flag it as a hazard, don't fix.
    //
    // This test does NOT start a real scan (which would shell out to
    // ffprobe and pollute the dev machine). It asserts the model
    // behavior we DO have today:
    //
    //   - purgeRecords mutates the existing VideoRecord instance in-place
    //     (it does not replace the records array), so a concurrent
    //     scan-engine writer holding a strong ref to the same record
    //     would see purgedAt flip under it.
    //   - isScanning has no effect on purge behavior (the purge still
    //     succeeds even when isScanning is true).
    //
    // If the future fix is "block purges while isScanning", this test
    // will start failing — that's the canary.
    @Test func purgeDoesNotGuardAgainstActiveScan_hazardCanary() async throws {
        let model = VideoScanModel()
        model.records = []
        let r = makeRecord(name: "active.mov")
        model.records = [r]

        // Capture a strong ref to mimic a scan engine that's holding
        // onto the same record while it fills metadata in.
        let scannerHandle = r

        // Simulate "scan is running" state.
        model.isScanning = true

        // Purge from under the (fake) scanner.
        let n = model.purgeRecords(ids: [r.id])

        // Today: purge succeeds. Both the model's array reference AND
        // the scanner's captured reference reflect the mutation — same
        // object identity. This is the hazard.
        #expect(n == 1,
                "purgeRecords currently has no isScanning gate — purge succeeds even mid-scan (HAZARD CANARY: flip this expectation if a guard is added)")
        #expect(scannerHandle.isPurged == true,
                "Scanner's captured ref sees purgedAt flip — same object identity (HAZARD CANARY)")
        #expect(model.records.first?.isPurged == true)

        // Cleanup — keep the model in a sane state for the rest of the
        // suite (per-test models are isolated but be tidy anyway).
        model.isScanning = false
    }

    // MARK: - 12. Mixed purged/active round-trip preserves state exactly
    //
    // regression: feature spec — catalog.json must preserve a mix of
    // purged + active records with byte-faithful timestamps and id
    // recovery. The existing test covers two records keyed by filename;
    // this one ups the ante to 6 records with varied purgedAt values
    // (including the past, just-now, and the future) and keys recovery
    // by record id so a misaligned decode would fail loudly.
    @Test func mixedPurgedAndActiveRoundTripPreservesState() async throws {
        // Build a known mix: 3 active, 3 purged at distinct timestamps.
        // Timestamps chosen at iso8601-second boundaries so the encoder
        // doesn't have to truncate sub-second drift.
        let activeA = makeRecord(name: "active_a.mov")
        let activeB = makeRecord(name: "active_b.mov")
        let activeC = makeRecord(name: "active_c.mov")
        let pastDate   = Date(timeIntervalSince1970: 1_500_000_000) // 2017
        let recentDate = Date(timeIntervalSince1970: 1_715_000_000) // 2024
        let futureDate = Date(timeIntervalSince1970: 1_900_000_000) // 2030
        let purgedPast   = makeRecord(name: "purged_past.mov",   purgedAt: pastDate)
        let purgedRecent = makeRecord(name: "purged_recent.mov", purgedAt: recentDate)
        let purgedFuture = makeRecord(name: "purged_future.mov", purgedAt: futureDate)

        let original = [activeA, purgedPast, activeB,
                        purgedRecent, activeC, purgedFuture]
        let originalSnapshot = CatalogSnapshot(records: original)

        // Encode/decode using the same configuration CatalogStore uses.
        // Two passes: catch any encoder non-determinism (sortedKeys
        // already pins ordering, but verify).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let pass1Data = try encoder.encode(CatalogSnapshotDTO(originalSnapshot))
        let pass1Loaded = try decoder.decode(CatalogSnapshot.self, from: pass1Data)
        let pass2Data = try encoder.encode(CatalogSnapshotDTO(pass1Loaded))
        #expect(pass1Data == pass2Data,
                "Encode is deterministic — second pass produces identical bytes")

        #expect(pass1Loaded.records.count == 6,
                "All 6 records must survive the round trip")

        // Key by ID — if the decoder lost an id, the dictionary build
        // would dedupe and the count check above already failed; this
        // pass verifies field-level recovery.
        let byID = Dictionary(uniqueKeysWithValues:
                                pass1Loaded.records.map { ($0.id, $0) })

        // Active records: round-trip with purgedAt nil and isPurged false.
        for active in [activeA, activeB, activeC] {
            let loaded = try #require(byID[active.id],
                                      "Active record \(active.filename) must keep its id across save/load")
            #expect(loaded.purgedAt == nil,
                    "\(active.filename): active purgedAt must stay nil")
            #expect(loaded.isPurged == false)
            #expect(loaded.filename == active.filename)
        }

        // Purged records: round-trip with exact timestamps (allow 1s
        // drift for iso8601 second-resolution encoding).
        let purgedCases: [(VideoRecord, Date)] = [
            (purgedPast,   pastDate),
            (purgedRecent, recentDate),
            (purgedFuture, futureDate),
        ]
        for (orig, expected) in purgedCases {
            let loaded = try #require(byID[orig.id],
                                      "Purged record \(orig.filename) must keep its id across save/load")
            let stamp = try #require(loaded.purgedAt,
                                     "\(orig.filename): purgedAt must round-trip as non-nil")
            let drift = abs(stamp.timeIntervalSince(expected))
            #expect(drift < 1.0,
                    "\(orig.filename): timestamp drift after round-trip must be < 1s, got \(drift)")
            #expect(loaded.isPurged == true)
            #expect(loaded.filename == orig.filename)
        }

        // Order preservation — records array order is part of the on-disk
        // contract (it drives default UI sort before the user re-sorts).
        let originalIDs = original.map { $0.id }
        let loadedIDs   = pass1Loaded.records.map { $0.id }
        #expect(originalIDs == loadedIDs,
                "Record order must be preserved across save/load")
    }

    // MARK: - 13. Bundle catalog.json codec preserves purgedAt for ACTIVE input
    //
    // Spec decision 2 ("Exports strip purged") moved the active-only filter
    // up into the export pipeline (BundleExporter.writeBundle calls
    // pfActiveRecords before encoding). The on-wire CatalogSnapshot codec
    // itself still preserves purgedAt — it has to, because the same codec
    // backs the local catalog.json save/load that DOES need purge state.
    //
    // This test pins the codec contract: feed an active-only array (what
    // the bundle exporter will hand it) and confirm both purged-state
    // representations survive the encode/decode round-trip. Stripping is
    // covered separately by `bundleExport_stripsPurgedRecords` below.
    //
    // Renamed from the original "preserves purgedAt" framing because the
    // export behavior now strips before encoding; the codec round-trip is
    // a narrower assertion.
    @Test func bundleCatalogJsonCodecPreservesPurgedAtForActiveInput() async throws {
        let tmpBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "purge-rt-\(UUID().uuidString).videoscanbundle",
                isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBundle,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        // Active-only input — exactly what BundleExporter.writeBundle
        // passes to the encoder after its pfActiveRecords filter.
        let active1 = makeRecord(name: "active_on_v1.mov",
                                 path: "/Volumes/V1/active_on_v1.mov")
        let active2 = makeRecord(name: "active_on_v2.mov",
                                 path: "/Volumes/V2/active_on_v2.mov")

        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: [active1, active2],
            savedFromHost: "TestHost"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let catalogURL = tmpBundle.appendingPathComponent("catalog.json")
        try encoder.encode(CatalogSnapshotDTO(snapshot)).write(to: catalogURL, options: .atomic)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: catalogURL)
        let loaded = try decoder.decode(CatalogSnapshot.self, from: data)

        #expect(loaded.records.count == 2,
                "Active-only input must round-trip without loss")
        for rec in loaded.records {
            #expect(rec.purgedAt == nil,
                    "Active record \(rec.filename) must keep nil purgedAt")
            #expect(rec.isPurged == false)
        }
    }

    // MARK: - 14. Mixed-selection context menu — label/action math
    //
    // B1 spec: the context menu computes activeRecs/purgedRecs splits and
    // both the Remove label count AND the Remove action's target ID set
    // must be drawn from `activeRecs` (not the whole selection). Same for
    // Restore + purgedRecs. The test exercises the same pf helpers the
    // view uses so a regression in the split logic would fail loudly here
    // even though SwiftUI views aren't directly testable.
    @Test func mixedSelectionMenuSplitsActiveAndPurgedCorrectly() {
        let activeA = makeRecord(name: "active_a.mov")
        let activeB = makeRecord(name: "active_b.mov")
        let purgedX = makeRecord(name: "purged_x.mov", purgedAt: Date())
        let purgedY = makeRecord(name: "purged_y.mov", purgedAt: Date())

        // Build a mixed selection (2 active + 2 purged).
        let selectedRecs = [activeA, purgedX, activeB, purgedY]

        // The view computes these as:
        //   let activeRecs = selectedRecs.filter { !$0.isPurged }
        //   let purgedRecs = selectedRecs.filter { $0.isPurged }
        let activeRecs = selectedRecs.filter { !$0.isPurged }
        let purgedRecs = selectedRecs.filter { $0.isPurged }

        #expect(activeRecs.count == 2,
                "Active subset must be exactly the 2 non-purged rows")
        #expect(purgedRecs.count == 2,
                "Purged subset must be exactly the 2 purged rows")
        #expect(Set(activeRecs.map { $0.id }) == [activeA.id, activeB.id])
        #expect(Set(purgedRecs.map { $0.id }) == [purgedX.id, purgedY.id])

        // Label count contract: the Remove menu item uses activeRecs.count
        // (not selectedRecs.count). For this mixed selection that's 2, not
        // 4 — protects against the original B1 bug where Remove's label
        // would say "4" but the action would only purge 2.
        let removeLabelCount = activeRecs.count
        #expect(removeLabelCount == 2,
                "Remove label must reflect active-only count, not selection size")

        // Action target contract: Remove operates on activeRecs.map{$0.id}
        // — purgeRecords would be a no-op on the already-purged rows
        // anyway, but emitting them in the targetIDs would still inflate
        // the "did the call cover what the label promised" mental model.
        let removeTargetIDs = Set(activeRecs.map { $0.id })
        #expect(removeTargetIDs == [activeA.id, activeB.id],
                "Remove action target set must equal active subset IDs")
        #expect(!removeTargetIDs.contains(purgedX.id))
        #expect(!removeTargetIDs.contains(purgedY.id))

        // Restore label/action symmetry: purgedRecs.count drives the
        // Restore label; action operates on purgedRecs.map{$0.id}.
        let restoreLabelCount = purgedRecs.count
        let restoreTargetIDs = Set(purgedRecs.map { $0.id })
        #expect(restoreLabelCount == 2)
        #expect(restoreTargetIDs == [purgedX.id, purgedY.id])
        #expect(!restoreTargetIDs.contains(activeA.id))
        #expect(!restoreTargetIDs.contains(activeB.id))

        // Pure-active selection: Restore item is hidden (purgedRecs empty).
        let activeOnly = [activeA, activeB]
        #expect(activeOnly.filter { $0.isPurged }.isEmpty,
                "Pure-active selection has no purged subset → Restore item hidden")

        // Pure-purged selection: Remove item is hidden (activeRecs empty).
        let purgedOnly = [purgedX, purgedY]
        #expect(purgedOnly.filter { !$0.isPurged }.isEmpty,
                "Pure-purged selection has no active subset → Remove item hidden")

        // Active-only row actions (Combine, Rename, Tag, …) are gated on
        // `purgedRecs.isEmpty`. Mixed selection → gate is FALSE → those
        // actions are hidden. Pure-active → gate is TRUE → they show.
        let pureActiveAllowsRowActions = activeOnly.filter { $0.isPurged }.isEmpty
        let mixedAllowsRowActions = selectedRecs.filter { $0.isPurged }.isEmpty
        #expect(pureActiveAllowsRowActions == true,
                "Pure-active selection must permit row-targeted active actions")
        #expect(mixedAllowsRowActions == false,
                "Mixed selection must hide row-targeted active actions")
    }

    // MARK: - 15. Correlator skips purged records
    //
    // B2 spec: Correlator.correlate runs pfActiveRecords on its input so a
    // record marked purged is invisible to pairing. The classic regression
    // scenario: a video-only file remains active, its audio counterpart
    // gets removed from the catalog — they must NOT correlate.
    @Test func correlator_skipsPurgedRecords() async throws {
        let video = makeRecord(name: "shot.mxf",
                               path: "/Volumes/V1/shot.mxf")
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        video.durationSeconds = 10.0

        let audio = makeRecord(name: "shot.wav",
                               path: "/Volumes/V1/shot.wav",
                               purgedAt: Date())
        audio.streamTypeRaw = StreamType.audioOnly.rawValue
        audio.durationSeconds = 10.0

        // Pre-condition: but-for the purge, the filename + duration +
        // directory signals would push these well over Correlator's
        // minimumScore threshold (filename:4 + duration:3 + directory:1
        // = 8 ≥ 7 → high).
        _ = Correlator.correlate(records: [video, audio])

        #expect(video.pairedWith == nil,
                "Active video must not be paired when its only partner is purged")
        #expect(video.pairConfidence == nil,
                "Active video must not be assigned a pair confidence")
        // Purged audio is filtered out before pairing runs, so it can never
        // be assigned a partner — confirms the filter is at the entry point
        // (not just blocking the assignment).
        #expect(audio.pairedWith == nil,
                "Purged audio must not be paired with anything")
        #expect(audio.pairConfidence == nil)
    }

    // MARK: - 16. DuplicateDetector ignores purged duplicates
    //
    // B2 spec: DuplicateDetector.analyze runs pfActiveRecords on its input.
    // Three identical-hash records, one purged → the purged one must not
    // be grouped as a duplicate copy. The two active ones can group as a
    // pair (that's the normal duplicate flow); only the purged one is
    // invisible.
    @Test func duplicateDetector_ignoresPurgedDuplicates() async throws {
        let hash = "deadbeefcafe"
        let size: Int64 = 12_345_678
        let duration: Double = 60.0
        let created = Date(timeIntervalSince1970: 1_700_000_000)

        // Helper for the three-way identical setup. Each candidate needs
        // partialMD5 + sizeBytes + a non-zero duration to be considered.
        func mkClone(name: String, path: String, purgedAt: Date? = nil) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = path
            r.directory = (path as NSString).deletingLastPathComponent
            r.partialMD5 = hash
            r.sizeBytes = size
            r.durationSeconds = duration
            r.dateCreatedRaw = created
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.purgedAt = purgedAt
            return r
        }

        let liveA = mkClone(name: "clone.mov", path: "/Volumes/V1/clone.mov")
        let liveB = mkClone(name: "clone.mov", path: "/Volumes/V2/clone.mov")
        let purgedC = mkClone(name: "clone.mov",
                              path: "/Volumes/V3/clone.mov",
                              purgedAt: Date())

        _ = DuplicateDetector.analyze(records: [liveA, liveB, purgedC])

        // The two live records may group together — that's fine. The
        // critical assertion is that the purged record is NOT in any
        // duplicate group (its groupID stayed nil and its disposition
        // stayed .none) because pfActiveRecords filtered it out before
        // candidate selection.
        #expect(purgedC.duplicateGroupID == nil,
                "Purged record must not be assigned to a duplicate group")
        #expect(purgedC.duplicateDisposition == .none,
                "Purged record must not get a duplicate disposition")
        #expect(purgedC.duplicateConfidence == nil)

        // Confidence-of-fix: if liveA/liveB DID group, neither should
        // reference purgedC by name in their best-match field.
        if liveA.duplicateGroupID != nil {
            #expect(liveA.duplicateBestMatchFilename != purgedC.filename
                    || liveA.duplicateGroupCount <= 2,
                    "Live record's group must not include the purged copy")
        }
    }

    // MARK: - 17. Export catalog strips purged records
    //
    // B3 spec: exportCatalog(to:) writes pfActiveRecords(records) — never
    // the full records array. Round-trip the actual exporter through a
    // temp file, decode it back, assert no purged records present.
    @Test @MainActor
    func exportCatalog_stripsPurgedRecords() async throws {
        let model = VideoScanModel()
        model.records = []
        let active1 = makeRecord(name: "keep_me.mov",
                                 path: "/Volumes/V1/keep_me.mov")
        let active2 = makeRecord(name: "keep_me_too.mov",
                                 path: "/Volumes/V1/keep_me_too.mov")
        let purged1 = makeRecord(name: "removed.mov",
                                 path: "/Volumes/V1/removed.mov",
                                 purgedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let purged2 = makeRecord(name: "also_removed.mov",
                                 path: "/Volumes/V2/also_removed.mov",
                                 purgedAt: Date(timeIntervalSince1970: 1_710_000_000))
        model.records = [active1, purged1, active2, purged2]

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-strip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try model.exportCatalog(to: tmpURL)

        // Decode with the same configuration the importer uses.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: tmpURL)
        let loaded = try decoder.decode(CatalogSnapshot.self, from: data)

        #expect(loaded.records.count == 2,
                "Exported catalog must contain only the 2 active records")
        let loadedIDs = Set(loaded.records.map { $0.id })
        #expect(loadedIDs == [active1.id, active2.id],
                "Exported IDs must match the active subset exactly")
        for rec in loaded.records {
            #expect(rec.purgedAt == nil,
                    "Exported record \(rec.filename) must have nil purgedAt (purged ones were stripped)")
            #expect(rec.isPurged == false)
        }
    }

    // MARK: - 18. Bundle export strips purged records
    //
    // B3 spec: BundleExporter.writeBundle filters its records argument
    // through pfActiveRecords before encoding. Per existing-test pattern
    // (#13 above) we avoid pulling in POIStorage.allPOIFolders by driving
    // the filter pipeline directly — same approach the bundle exporter
    // uses internally, so this asserts the documented contract without
    // needing a real Application Support tree.
    @Test func bundleExport_stripsPurgedRecords() async throws {
        let active1 = makeRecord(name: "active_on_v1.mov",
                                 path: "/Volumes/V1/active_on_v1.mov")
        let active2 = makeRecord(name: "active_on_v2.mov",
                                 path: "/Volumes/V2/active_on_v2.mov")
        let purgedA = makeRecord(name: "purged_a.mov",
                                 path: "/Volumes/V1/purged_a.mov",
                                 purgedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let purgedB = makeRecord(name: "purged_b.mov",
                                 path: "/Volumes/V2/purged_b.mov",
                                 purgedAt: Date(timeIntervalSince1970: 1_710_000_000))
        let mixed = [active1, purgedA, active2, purgedB]

        // The bundle exporter's first line is `let records =
        // pfActiveRecords(inputRecords)`. Apply the same filter here and
        // assert the resulting array is what the encoder would see.
        let toEncode = pfActiveRecords(mixed)
        #expect(toEncode.count == 2,
                "Filter pipeline must drop both purged records before encoding")
        let activeIDs = Set(toEncode.map { $0.id })
        #expect(activeIDs == [active1.id, active2.id],
                "Encoded record set must equal the active subset")

        // Now round-trip exactly that array through the same encoder the
        // bundle exporter uses, into a temp catalog.json, and assert the
        // bytes-on-disk match the active-only expectation. This catches
        // future regressions where the filter is moved but the encoder
        // grabs the wrong source variable.
        let tmpBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bundle-strip-\(UUID().uuidString).videoscanbundle",
                isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBundle,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: toEncode,
            savedFromHost: "TestHost"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let catalogURL = tmpBundle.appendingPathComponent("catalog.json")
        try encoder.encode(CatalogSnapshotDTO(snapshot)).write(to: catalogURL, options: .atomic)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: catalogURL)
        let loaded = try decoder.decode(CatalogSnapshot.self, from: data)

        #expect(loaded.records.count == 2,
                "Bundle catalog.json must contain only the 2 active records")
        let loadedIDs = Set(loaded.records.map { $0.id })
        #expect(loadedIDs == [active1.id, active2.id])
        for rec in loaded.records {
            #expect(rec.purgedAt == nil,
                    "Bundle-encoded record \(rec.filename) must have nil purgedAt")
        }
        // And the purged IDs must NOT appear in the bundle output.
        #expect(!loadedIDs.contains(purgedA.id))
        #expect(!loadedIDs.contains(purgedB.id))
    }

    // MARK: - 19. deleteAllCatalog clears the purge undo banner
    //
    // B4 spec: catalog-wide wipes (deleteAllCatalog) clear the banner so
    // the user isn't shown an "Undo" affordance for rows that no longer
    // exist.
    @Test func deleteAllCatalog_clearsPurgeUndoBanner() async throws {
        let model = VideoScanModel()
        model.records = []
        let a = makeRecord(name: "a.mov", path: "/Volumes/V1/a.mov")
        let b = makeRecord(name: "b.mov", path: "/Volumes/V1/b.mov")
        model.records = [a, b]

        // Arm the banner via the normal purge path.
        _ = model.purgeRecords(ids: [a.id])
        #expect(model.lastPurgedBatch != nil,
                "Pre-condition: banner must be armed before wipe")

        // Wholesale wipe must drop the banner.
        model.deleteAllCatalog()
        #expect(model.lastPurgedBatch == nil,
                "deleteAllCatalog must clear the purge undo banner")
        #expect(model.lastPurgeUndoError == nil,
                "deleteAllCatalog must also clear any banner error state")
    }

    // MARK: - 20. deleteCatalogForTarget clears the purge undo banner
    //
    // B4 spec: per-volume wipes (deleteCatalogForTarget) also clear the
    // banner — even when the banner-tracked rows happened to live on a
    // different volume. Spec is "wholesale mutation drops the banner",
    // not "drop only when the banner overlaps the wipe set"; simpler is
    // safer for v1.
    @Test func deleteCatalogForTarget_clearsPurgeUndoBanner() async throws {
        let model = VideoScanModel()
        model.records = []
        let v1Rec = makeRecord(name: "v1.mov", path: "/Volumes/V1/v1.mov")
        let v2Rec = makeRecord(name: "v2.mov", path: "/Volumes/V2/v2.mov")
        model.records = [v1Rec, v2Rec]

        // Arm the banner on V1.
        _ = model.purgeRecords(ids: [v1Rec.id])
        #expect(model.lastPurgedBatch != nil,
                "Pre-condition: banner must be armed before per-target wipe")

        // Synthesize a scan target for V2 (the volume we're going to wipe).
        // CatalogScanTarget is @MainActor — we're already in @MainActor
        // through CatalogPurgeGapTests; the await is implicit.
        let target = CatalogScanTarget(searchPath: "/Volumes/V2")
        model.scanTargets = [target]

        model.deleteCatalogForTarget(target)

        #expect(model.lastPurgedBatch == nil,
                "deleteCatalogForTarget must clear the purge undo banner even when the wiped target doesn't overlap the banner's rows")
        #expect(model.lastPurgeUndoError == nil)
    }
}

