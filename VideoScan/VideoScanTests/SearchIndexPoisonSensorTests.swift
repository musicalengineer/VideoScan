// SearchIndexPoisonSensorTests.swift
// GH #123 PR A — regression sensors for the search-index poisoning class.
//
// The escaped bug (found 2026-07-19): VideoScanModel.init's index
// load/rebuild/save block had no test-host guard, so EVERY unit-test run
// on Rick's machine overwrote the real
// ~/Library/Application Support/VideoScan/catalog.search-index.v1.plist
// with a 0-record file — and loadFromDisk accepted it on the next app
// launch (version + mtime checks only, no recordCount sanity). Result:
// every query fell into the inline-buildHaystack fallback, 5.4 s of
// main-thread work per settled keystroke at 103k records.
//
// Two independent defenses, each pinned here (checklist dimension 4 —
// isolation — plus dimension 5 — sensors):
//   1. defaultPersistenceURL() diverts test hosts to a per-process temp
//      dir (POIStorage.storeDir pattern) — pinned by the write-isolation
//      tests.
//   2. loadFromDisk rejects a persisted index whose record count is
//      grossly inconsistent with the live catalog — pinned by the
//      poisoned-state tests.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("SearchIndexPoisonSensors")
struct SearchIndexPoisonSensorTests {

    // MARK: - Helpers

    private func makeRecords(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "Clip\(i) Christmas1993.mov"
            r.directory = "/Volumes/SensorTestVol/Family/\(i % 7)"
            r.fullPath = r.directory + "/" + r.filename
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
    }

    private func makeTempURL(name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_poison_sensor_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Write a structurally VALID current-version index file containing
    /// zero records — byte-for-byte the shape of the poison observed on
    /// Rick's machine (110-byte plist, recordCount 0, empty haystacks),
    /// upgraded to the current persisted version so ONLY the count
    /// sanity check can reject it.
    private func writeZeroRecordPoison(to url: URL) throws {
        let payload: [String: Any] = [
            "version": CatalogSearchIndex.persistedVersion,
            "savedAt": Date().timeIntervalSince1970,
            "recordCount": 0,
            "haystacks": [String: String](),
            "years": [String: [Int]](),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// The REAL production plist path, computed independently of
    /// defaultPersistenceURL() (which is deliberately redirected under
    /// test — that redirect is exactly what these sensors verify).
    private var realProductionPlistPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("catalog.search-index.v1.plist").path
    }

    // MARK: - Poisoned-state sensors (defense 2: reject at load)

    /// THE bug: a 0-record index file vs a non-empty catalog MUST be
    /// rejected so the caller falls through to rebuild. This was the
    /// exact state on Rick's machine 2026-07-19 (accepted three times
    /// that day → 5.4 s per settled keystroke).
    @Test func zeroRecordPoisonIsRejectedForNonEmptyCatalog() throws {
        let url = makeTempURL(name: "poison.plist")
        try writeZeroRecordPoison(to: url)
        let idx = CatalogSearchIndex()
        let accepted = idx.loadFromDisk(at: url,
                                        catalogModifiedAt: nil,
                                        expectedRecordCount: 100)
        #expect(!accepted, "a 0-record index must never be accepted for a non-empty catalog")
    }

    /// Launch-path shape: reject → rebuild → save → the SAVED index is
    /// accepted on the next load. Recovery must be automatic, not a
    /// one-way trip into rebuild-every-launch.
    @Test func rejectionRecoversViaRebuildAndResave() throws {
        let url = makeTempURL(name: "poison-then-heal.plist")
        try writeZeroRecordPoison(to: url)
        let records = makeRecords(60)

        let idx = CatalogSearchIndex()
        // Mirrors VideoScanModel.init: load, and on failure rebuild+save.
        let loaded = idx.loadFromDisk(at: url,
                                      catalogModifiedAt: nil,
                                      expectedRecordCount: records.count)
        #expect(!loaded, "poison must be rejected on the launch path")
        idx.rebuild(records: records)
        try idx.saveToDisk(at: url)

        let next = CatalogSearchIndex()
        let healthy = next.loadFromDisk(at: url,
                                        catalogModifiedAt: nil,
                                        expectedRecordCount: records.count)
        #expect(healthy, "the freshly rebuilt index must be accepted next launch")
        #expect(next.recordCount() == records.count)
        // And it actually answers queries (no silent empty acceptance).
        #expect(next.filter(records: records, query: "christmas").count == records.count)
    }

    /// Tolerance bounds: counts outside [50%, 200%] of the catalog are
    /// rejected; counts inside are accepted. Both directions tested so
    /// a future edit can't silently invert a comparison.
    @Test func recordCountToleranceBounds() throws {
        let records = makeRecords(10)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: records)
        let url = makeTempURL(name: "ten.plist")
        try idx.saveToDisk(at: url)

        let probe = CatalogSearchIndex()
        // Exact match: accepted.
        #expect(probe.loadFromDisk(at: url, expectedRecordCount: 10))
        // Grossly under (10 indexed vs 100 expected → < 50%): rejected.
        #expect(!probe.loadFromDisk(at: url, expectedRecordCount: 100))
        // Grossly over (10 indexed vs 4 expected → > 200%): rejected.
        #expect(!probe.loadFromDisk(at: url, expectedRecordCount: 4))
        // Within tolerance both ways: accepted.
        #expect(probe.loadFromDisk(at: url, expectedRecordCount: 15))
        #expect(probe.loadFromDisk(at: url, expectedRecordCount: 6))
        // Empty catalog (expected 0): sanity check is skipped — a stale
        // index against an empty catalog is harmless because `records`
        // drives every filter.
        #expect(probe.loadFromDisk(at: url, expectedRecordCount: 0))
        // nil: check skipped (compatibility with pre-#123 callers/tests).
        #expect(probe.loadFromDisk(at: url, expectedRecordCount: nil))
    }

    /// Legacy v1 files (no "years" payload) must be rejected by the
    /// version gate → one rebuild upgrades them to v2. Guards the PR D
    /// on-disk layout change.
    @Test func legacyV1FileIsRejected() throws {
        let url = makeTempURL(name: "v1.plist")
        let payload: [String: Any] = [
            "version": 1,
            "savedAt": Date().timeIntervalSince1970,
            "recordCount": 2,
            "haystacks": ["/a": "alpha", "/b": "beta"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)

        let idx = CatalogSearchIndex()
        #expect(!idx.loadFromDisk(at: url, catalogModifiedAt: nil, expectedRecordCount: 2),
                "v1 layout (no year sets) must be rejected → rebuild")
    }

    // MARK: - Write-isolation sensors (defense 1: test hosts can't touch the real plist)

    /// The default persistence path under a test host MUST be a
    /// per-process temp location, never the user's Application Support.
    @Test func defaultPersistenceURLIsRedirectedUnderTestHost() {
        #expect(TestEnvironment.isTestHost, "this suite must run as a test host")
        let url = CatalogSearchIndex.defaultPersistenceURL()
        #expect(url.path != realProductionPlistPath,
                "test host must NOT resolve the real production plist path")
        #expect(url.path.contains("VideoScanTestSearchIndex-"),
                "test-host redirect should use the per-process temp dir marker")
        #expect(!url.path.contains("Application Support"),
                "test-host index path must live outside Application Support")
    }

    /// End-to-end: a default-path save (exactly what VideoScanModel.init
    /// and the volume-rename migration do) must leave the user's real
    /// plist byte-identical — the mtime/size comparison is the sensor
    /// the 2026-07-19 poisoning would have tripped three times in one
    /// day. Also proves the redirected write actually landed somewhere.
    @Test func defaultPathSaveLeavesRealPlistUntouched() throws {
        let fm = FileManager.default
        let real = realProductionPlistPath
        let before = try? fm.attributesOfItem(atPath: real)
        let beforeMTime = before?[.modificationDate] as? Date
        let beforeSize = before?[.size] as? Int

        let idx = CatalogSearchIndex()
        idx.rebuild(records: makeRecords(5))
        try idx.saveToDisk()   // DEFAULT path — the poisoning vector

        let after = try? fm.attributesOfItem(atPath: real)
        #expect((after?[.modificationDate] as? Date) == beforeMTime,
                "test-host save must not touch the real plist's mtime")
        #expect((after?[.size] as? Int) == beforeSize,
                "test-host save must not change the real plist's size")
        #expect(fm.fileExists(atPath: CatalogSearchIndex.defaultPersistenceURL().path),
                "the redirected save must land in the temp location")
    }
}
