// CatalogVersioningTests.swift
// GH #167 catalog versioning (Rick 2026-10-02: "make sure we don't run
// into forward/backward compat issues, so we don't need to be psychotic
// about it, just polite").
//
// The rules under test:
//   1. Unknown keys — top level and per record, nested values included —
//      survive a load → save round trip unchanged, and NEVER override a
//      known field.
//   2. A catalog written by a NEWER build opens read-only: its records are
//      browsable, catalog.json / .prev get zero bytes, every save path is
//      refused, and the model shows the banner and reads as read-only.
//   3. Every older catalog version loads and upgrades on the next save.
//   4. Sensor: the set of Codable keys is pinned; a new key fails the
//      sensor with instructions (add it here — NO bump for additions).
//
// Five dimensions: logic (most suites), scale (100k records with unknown
// keys inside the save/load budget), media matrix (n/a — no media opened),
// isolation (scratch CatalogStore(directory:) only; the shared store under
// the test host never loads), sensor (key snapshot + version pin).

import Foundation
import os
import Testing
@testable import VideoScan

// MARK: - Helpers

@MainActor
private func scratch(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_167v_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func catalogURL(_ dir: URL) -> URL { dir.appendingPathComponent("catalog.json") }
private func prevURL(_ dir: URL) -> URL { dir.appendingPathComponent("catalog.json.prev") }

/// Parse catalog bytes as a plain JSON tree (independent of the app's
/// decoder, so a decoder bug cannot hide an encoder bug).
private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Every catalog*.json-ish file in `dir` and its bytes — the "zero bytes
/// written" witness. The OCC sidecar and the write journal are bookkeeping
/// beside the catalog, not catalog content, and are excluded.
private func catalogFiles(_ dir: URL) -> [String: Data] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    var out: [String: Data] = [:]
    for n in names where n.hasPrefix("catalog") && (n.hasSuffix(".json") || n.hasSuffix(".prev")) {
        out[n] = try? Data(contentsOf: dir.appendingPathComponent(n))
    }
    return out
}

private let fixedID1 = "11111111-1111-1111-1111-111111111111"
private let fixedID2 = "22222222-2222-2222-2222-222222222222"

/// A record object a newer build might write: known fields plus keys this
/// build has never heard of, with nested values of every JSON shape.
private let futureRecordJSON = """
{"id":"\(fixedID1)","filename":"future.mov","fullPath":"/Volumes/TestVol167/future.mov",
 "sizeBytes":1234,
 "futureRecordField":{"a":[1,2.5,"x",null,true,{"b":{"c":"deep"}}],"n":-7},
 "futureFlag":true,
 "futureList":["one","two"],
 "futureNull":null}
"""

private func futureCatalogJSON(version: Int, generation: Int = 5) -> String {
    """
    {"version":\(version),"generation":\(generation),"savedAt":"2026-10-01T12:00:00Z","savedFromHost":"FutureMac",
     "futureTopLevel":{"people":[{"name":"x","born":1930}],"ok":false},
     "futureScalar":42,
     "records":[\(futureRecordJSON),
       {"id":"\(fixedID2)","filename":"plain.mov","fullPath":"/Volumes/TestVol167/plain.mov"}]}
    """
}

/// The three nested values the round trip must preserve, as JSON trees.
private let expectedRecordUnknowns: [String: Any] = [
    "futureRecordField": ["a": [1, 2.5, "x", NSNull(), true, ["b": ["c": "deep"]]], "n": -7],
    "futureFlag": true,
    "futureList": ["one", "two"],
    "futureNull": NSNull(),
]
private let expectedTopUnknowns: [String: Any] = [
    "futureTopLevel": ["people": [["name": "x", "born": 1930]], "ok": false],
    "futureScalar": 42,
]

/// Canonical JSON bytes of a value (sorted keys). Two values are "the
/// same" only if they serialize identically — stricter than NSDictionary
/// equality, which would call `true` and `1` equal.
private func canon(_ v: Any) -> Data? {
    try? JSONSerialization.data(withJSONObject: [v], options: [.sortedKeys, .fragmentsAllowed])
}

private func same(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    guard let ca = canon(a), let cb = canon(b) else { return false }
    return ca == cb
}

/// EVERY file in `dir` and its bytes, minus the two bookkeeping files a
/// refused write is allowed to touch: the refusal journal (it must record
/// the refusal) and the advisory flock file. Anything else appearing,
/// vanishing or changing is a write.
private let allowedBookkeeping: Set<String> = ["catalog-write-errors.jsonl", "catalog.lock"]
private func everyFile(_ dir: URL) -> [String: Data] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    var out: [String: Data] = [:]
    for n in names where !allowedBookkeeping.contains(n) {
        out[n] = (try? Data(contentsOf: dir.appendingPathComponent(n))) ?? Data()
    }
    return out
}

/// Records every URL CatalogStore.encodeAndWrite reached (its test seam
/// fires after the bytes land). Any hit while a newer catalog is open is a
/// write that got past the latch. (≈ a mutex-guarded vector the writer
/// thread appends to.)
private final class WriteTripwire: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [URL] = []
    func hit(_ u: URL) { lock.lock(); hits.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return hits }
}

// MARK: - 1. Unknown keys survive

@Suite("GH #167 — unknown catalog keys survive a round trip", .serialized)
@MainActor
struct CatalogUnknownKeyPreservationTests {

    @Test("top-level and per-record unknown keys (nested) are written back unchanged")
    func roundTripPreservesUnknownKeys() throws {
        let dir = scratch("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(futureCatalogJSON(version: CatalogSnapshot.currentVersion).utf8).write(to: catalogURL(dir))

        let store = CatalogStore(directory: dir)
        let records = store.load()
        #expect(records.count == 2)
        // EDIT a known field on the record that carries unknown keys — the
        // round trip must be load → edit → save, not a no-op re-encode.
        let edited = try #require(records.first { $0.id.uuidString == fixedID1 })
        edited.userNotes = "edited by this build"
        edited.starRating = 3
        #expect(store.saveNow(records: records), "a current-version catalog must save")

        let top = try jsonObject(Data(contentsOf: catalogURL(dir)))
        for (k, v) in expectedTopUnknowns {
            #expect(same(top[k], v), "top-level unknown key \(k) was lost or changed: \(String(describing: top[k]))")
        }
        let recs = try #require(top["records"] as? [[String: Any]])
        let future = try #require(recs.first { $0["id"] as? String == fixedID1 })
        for (k, v) in expectedRecordUnknowns {
            #expect(same(future[k], v), "record unknown key \(k) was lost or changed: \(String(describing: future[k]))")
        }
        // Known fields still come from the typed properties — edits land.
        #expect(future["userNotes"] as? String == "edited by this build")
        #expect(future["starRating"] as? Int == 3)
        #expect(future["filename"] as? String == "future.mov")
        #expect(future["sizeBytes"] as? Int == 1234)
        // A record that carried no unknown keys gains none.
        let plain = try #require(recs.first { $0["id"] as? String == fixedID2 })
        #expect(Set(plain.keys).isSubset(of: VideoRecord.persistedKeyNames))

        // And a second generation keeps them too (load → save → load → save).
        let again = CatalogStore(directory: dir)
        #expect(again.saveNow(records: again.load()))
        let top2 = try jsonObject(Data(contentsOf: catalogURL(dir)))
        #expect(same(top2["futureTopLevel"], expectedTopUnknowns["futureTopLevel"]))
        let future2 = try #require((top2["records"] as? [[String: Any]])?.first { $0["id"] as? String == fixedID1 })
        #expect(same(future2["futureRecordField"], expectedRecordUnknowns["futureRecordField"]))
    }

    @Test("decode captures only keys this build does not know")
    func captureExcludesKnownKeys() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(VideoRecord.self, from: Data(futureRecordJSON.utf8))
        #expect(Set(rec.unknownFields.keys) == ["futureRecordField", "futureFlag", "futureList", "futureNull"])
        #expect(rec.unknownFields.keys.allSatisfy { !VideoRecord.persistedKeyNames.contains($0) })
        #expect(rec.filename == "future.mov")
        // A record a current build wrote carries none (no cost, no bytes).
        let plain = try decoder.decode(VideoRecord.self,
                                       from: Data(#"{"id":"\#(fixedID2)","filename":"p.mov"}"#.utf8))
        #expect(plain.unknownFields.isEmpty)
    }

    @Test("an unknown key can never override a known field — record and top level")
    func unknownNeverOverridesKnown() throws {
        let rec = VideoRecord(id: UUID(uuidString: fixedID1)!)
        rec.filename = "real.mov"
        rec.unknownFields = ["filename": .string("EVIL"), "id": .string("EVIL"), "futureOK": .int(1)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let recText = String(decoding: try encoder.encode(VideoRecordDTO(rec)), as: UTF8.self)
        #expect(!recText.contains("EVIL"), "\(recText)")
        #expect(recText.contains("\"futureOK\":1"), "\(recText)")

        var dto = CatalogSnapshotDTO(version: CatalogSnapshot.currentVersion, generation: 3,
                                     savedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                     records: [VideoRecordDTO(rec)], savedFromHost: "T")
        dto.unknownFields = ["version": .int(999), "generation": .int(999), "records": .array([]),
                             "masterArchive": .string("EVIL"), "futureTop": .bool(true)]
        let data = try dto.encoded(using: encoder)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"version\":").count == 2, "exactly one version key: \(text)")
        #expect(text.components(separatedBy: "\"generation\":").count == 2, "exactly one generation key")
        #expect(!text.contains("EVIL"))
        let top = try jsonObject(data)
        #expect(top["version"] as? Int == CatalogSnapshot.currentVersion)
        #expect(top["generation"] as? Int == 3)
        #expect((top["records"] as? [Any])?.count == 1)
        #expect(top["futureTop"] as? Bool == true)
        // The header probe still finds the real stamps in the first bytes.
        let dir = scratch("probe")
        defer { try? FileManager.default.removeItem(at: dir) }
        try data.write(to: catalogURL(dir))
        let probe = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(probe.version == CatalogSnapshot.currentVersion && probe.generation == 3)
    }

    @Test("unknown keys survive the async, acknowledged and snapshot write paths")
    func everyWritePathPreserves() async throws {
        let dir = scratch("paths")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(futureCatalogJSON(version: CatalogSnapshot.currentVersion).utf8).write(to: catalogURL(dir))
        let store = CatalogStore(directory: dir)
        let records = store.load()

        #expect(await store.saveAcknowledged(records: records))
        var top = try jsonObject(Data(contentsOf: catalogURL(dir)))
        #expect(same(top["futureScalar"], 42))

        // ASYNC-specific (codex cycle #28): an edit only saveAsync can have
        // written, and the generation must advance — otherwise this would
        // pass against the acknowledged save above even with saveAsync gone.
        let target = try #require(records.first { $0.id.uuidString == fixedID1 })
        target.userNotes = "written by saveAsync only"
        let g = store.currentGeneration
        store.saveAsync(records: records)
        for _ in 0..<300 where store.currentGeneration == g { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(store.currentGeneration > g, "saveAsync never completed")
        top = try jsonObject(Data(contentsOf: catalogURL(dir)))
        #expect(top["generation"] as? Int == store.currentGeneration)
        let asyncRec = try #require((top["records"] as? [[String: Any]])?.first { $0["id"] as? String == fixedID1 })
        #expect(asyncRec["userNotes"] as? String == "written by saveAsync only", "the async write did not land")
        #expect(same(asyncRec["futureRecordField"], expectedRecordUnknowns["futureRecordField"]))
        #expect(same(top["futureTopLevel"], expectedTopUnknowns["futureTopLevel"]))

        let snap = dir.appendingPathComponent("catalog.pre-test.json").path
        #expect(store.writeSnapshot(records: records, toPath: snap))
        let snapTop = try jsonObject(Data(contentsOf: URL(fileURLWithPath: snap)))
        #expect(same(snapTop["futureScalar"], 42))
        let rec = try #require((snapTop["records"] as? [[String: Any]])?.first { $0["id"] as? String == fixedID1 })
        #expect(same(rec["futureList"], ["one", "two"]))

        // ASYNC snapshot — its own payload (codex cycle #29 predicted that
        // dropping unknownTopLevel from writeSnapshotAsync alone survives:
        // the async-snapshot suites check refusal, not content).
        let snapAsync = dir.appendingPathComponent("catalog.pre-test-async.json").path
        #expect(await store.writeSnapshotAsync(records: records, toPath: snapAsync))
        let asyncSnapTop = try jsonObject(Data(contentsOf: URL(fileURLWithPath: snapAsync)))
        #expect(same(asyncSnapTop["futureScalar"], 42), "writeSnapshotAsync dropped a top-level unknown key")
        #expect(same(asyncSnapTop["futureTopLevel"], expectedTopUnknowns["futureTopLevel"]))
        let asyncSnapRec = try #require((asyncSnapTop["records"] as? [[String: Any]])?.first { $0["id"] as? String == fixedID1 })
        #expect(same(asyncSnapRec["futureList"], ["one", "two"]))
    }

    @Test("live reload carries an external writer's new unknown keys onto in-memory records")
    func liveReloadMergesUnknownKeys() throws {
        let m = VideoScanModel()
        let dir = scratch("live")
        defer { try? FileManager.default.removeItem(at: dir) }
        m.catalogStore = CatalogStore(directory: dir)
        let mem = VideoRecord(id: UUID(uuidString: fixedID1)!)
        mem.fullPath = "/Volumes/TestVol167/future.mov"
        mem.unknownFields = ["keptOnlyInMemory": .int(1)]
        m.records = [mem]

        let fresh = VideoRecord(id: UUID(uuidString: fixedID1)!)
        fresh.fullPath = mem.fullPath
        fresh.unknownFields = ["futureFromDisk": .string("hello"), "filename": .string("EVIL")]
        _ = m.mergeDossierFields(from: [fresh])

        #expect(mem.unknownFields["futureFromDisk"] == .string("hello"))
        #expect(mem.unknownFields["keptOnlyInMemory"] == .int(1))
        #expect(mem.unknownFields["filename"] == nil, "a known key is never admitted")
    }

    @Test("a rescan's fresh record keeps the unknown keys of the record it replaces")
    func rescanPreservesUnknownKeys() {
        let old = VideoRecord()
        old.fullPath = "/Volumes/TestVol167/a.mov"
        old.unknownFields = ["futureUserMark": .object(["by": .string("Rick")])]
        let snap = RescanPreservedFields(from: old)
        #expect(snap.isWorthRestoring, "a record carrying only future data is still worth restoring")
        let fresh = VideoRecord()
        fresh.fullPath = old.fullPath
        snap.apply(to: fresh)
        #expect(fresh.unknownFields == old.unknownFields)
    }

    @Test("snapshotClone carries unknown keys")
    func cloneCarriesUnknownKeys() {
        let r = VideoRecord()
        r.unknownFields = ["x": .array([.null, .double(1.5)])]
        #expect(r.snapshotClone().unknownFields == r.unknownFields)
    }
}

// MARK: - 2. A newer catalog is read-only, not an error

@Suite("GH #167 — a catalog from a newer build opens read-only", .serialized)
@MainActor
struct CatalogNewerVersionReadOnlyTests {

    @Test("load shows the records, writes zero bytes, and every save path refuses")
    func newerCatalogOpensReadOnly() async throws {
        let dir = scratch("newer")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = CatalogSnapshot.currentVersion + 1
        try Data(futureCatalogJSON(version: future).utf8).write(to: catalogURL(dir))
        let before = catalogFiles(dir)

        let store = CatalogStore(directory: dir)
        let records = store.load()
        #expect(records.count == 2, "a newer catalog is browsable, not empty")
        #expect(store.lastLoadOutcome == .openedReadOnlyNewerVersion(found: future))
        #expect(store.newerCatalogVersion == future)
        #expect(store.writesDisabledReason != nil)
        #expect(catalogFiles(dir) == before, "load must not rotate or rewrite anything")

        #expect(store.saveNow(records: records) == false)
        #expect(store.lastWriteError?.kind == "writesDisabled")
        #expect(await store.saveAcknowledged(records: records) == false)
        store.saveAsync(records: records)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.writeSnapshot(records: records,
                                    toPath: dir.appendingPathComponent("catalog.pre-x.json").path) == false)
        #expect(await store.writeSnapshotAsync(records: records,
                                               toPath: dir.appendingPathComponent("catalog.pre-y.json").path) == false)
        #expect(catalogFiles(dir) == before, "zero bytes written to any catalog file")
        let probe = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(probe.version == future, "never downgraded")
    }

    @Test("the model shows the banner, reads as read-only, and the quit-time save is held")
    func modelShowsBannerAndHoldsSaves() throws {
        let dir = scratch("model")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(futureCatalogJSON(version: CatalogSnapshot.currentVersion + 1).utf8).write(to: catalogURL(dir))
        let before = catalogFiles(dir)

        let store = CatalogStore(directory: dir)
        let records = store.load()
        let m = VideoScanModel()
        var lines: [String] = []
        m.catalogStore = store
        m.catalogStore.designationAudit = { lines.append($0) }
        m.records = records

        #expect(m.catalogSavingPausedNotice == CatalogStore.newerCatalogNotice)
        #expect(m.isReadOnly)
        // Viewer-mode bookkeeping must not un-pause it (OR, not overwrite).
        m.applyReadOnlyMode(false)
        #expect(m.isReadOnly, "a master Mac with a newer catalog is still read-only")
        #expect(m.saveCatalogNow() == false)
        m.saveCatalogDebounced()
        #expect(catalogFiles(dir) == before)
        #expect(lines.contains { $0.contains("held") }, "the hold is said out loud: \(lines)")
        #expect(lines.filter { $0.contains("held") }.count == 1, "said once, not per save: \(lines)")
    }

    @Test("the banner words are Rick's")
    func bannerWords() {
        #expect(CatalogStore.newerCatalogNotice
                == "This catalog was last saved by a newer VideoScan — you can browse, but saving is paused until you update this Mac's copy.")
    }

    @Test("a newer catalog this build cannot even decode still latches read-only (no fallback writes)")
    func undecodableNewerCatalogStaysReadOnly() throws {
        let dir = scratch("undecodable")
        defer { try? FileManager.default.removeItem(at: dir) }
        // .prev: a perfectly good older catalog. Falling back to it with
        // writes ENABLED would overwrite the newer catalog.json on the next
        // save — the exact downgrade this guard exists to stop.
        try Data(#"{"version":6,"generation":2,"records":[{"id":"\#(fixedID2)","filename":"old.mov"}]}"#.utf8)
            .write(to: prevURL(dir))
        // The newer build changed sizeBytes' TYPE — this build cannot decode it.
        let future = CatalogSnapshot.currentVersion + 1
        try Data(#"{"version":\#(future),"generation":9,"records":[{"id":"\#(fixedID1)","sizeBytes":"big"}]}"#.utf8)
            .write(to: catalogURL(dir))
        let before = catalogFiles(dir)

        let store = CatalogStore(directory: dir)
        _ = store.load()
        #expect(store.newerCatalogVersion == future)
        #expect(store.lastLoadOutcome == .openedReadOnlyNewerVersion(found: future))
        #expect(store.saveNow(records: []) == false)
        #expect(catalogFiles(dir) == before)
    }

    @Test("a newer catalog that appears mid-session is never overwritten")
    func newerCatalogMidSessionRefused() throws {
        let dir = scratch("midsession")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        // Another (newer) build replaces the file with the SAME generation
        // our session last wrote, so the staleness check alone cannot see it.
        let g = store.currentGeneration
        let future = CatalogSnapshot.currentVersion + 1
        try Data(#"{"version":\#(future),"generation":\#(g),"records":[]}"#.utf8).write(to: catalogURL(dir))
        let before = try Data(contentsOf: catalogURL(dir))

        #expect(store.saveNow(records: []) == false)
        #expect(store.newerCatalogVersion == future)
        #expect(try Data(contentsOf: catalogURL(dir)) == before)
    }

    @Test("isolation: one store's newer catalog does not pause another store")
    func pauseIsPerStore() throws {
        let newerDir = scratch("iso_newer"), okDir = scratch("iso_ok")
        defer {
            try? FileManager.default.removeItem(at: newerDir)
            try? FileManager.default.removeItem(at: okDir)
        }
        try Data(futureCatalogJSON(version: CatalogSnapshot.currentVersion + 1).utf8).write(to: catalogURL(newerDir))
        let a = CatalogStore(directory: newerDir)
        _ = a.load()
        let b = CatalogStore(directory: okDir)
        _ = b.load()
        #expect(a.newerCatalogVersion != nil)
        #expect(b.newerCatalogVersion == nil)
        #expect(b.saveNow(records: []))
    }

    @Test("isolation: the shared store never loads under the test host")
    func sharedStoreNeverLoadsUnderTests() {
        #expect(CatalogStore.shared.load().isEmpty)
        #expect(CatalogStore.shared.newerCatalogVersion == nil)
        #expect(CatalogStore.shared.lastLoadOutcome == .missing)
    }
}

// MARK: - 3. Older catalogs load and upgrade in place

@Suite("GH #167 — every older catalog version loads and upgrades on save", .serialized)
@MainActor
struct CatalogOlderVersionUpgradeTests {

    struct Fixture: Sendable, CustomStringConvertible {
        let label: String
        let json: String
        var description: String { label }
    }

    static let fixtures: [Fixture] = [
        Fixture(label: "v0 (no version key)",
                json: #"{"records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov"}]}"#),
        Fixture(label: "v1",
                json: #"{"version":1,"savedAt":"2025-01-01T00:00:00Z","records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov","detectedPeople":["Donna"]}]}"#),
        Fixture(label: "v2 savedFromHost",
                json: #"{"version":2,"savedAt":"2025-02-01T00:00:00Z","savedFromHost":"OldMac","records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov","detectedPeople":["Donna"]}]}"#),
        Fixture(label: "v3 suspectedPeople",
                json: #"{"version":3,"savedAt":"2025-03-01T00:00:00Z","savedFromHost":"OldMac","records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov","detectedPeople":["Donna"],"suspectedPeople":["Rick"]}]}"#),
        Fixture(label: "v4 sceneCaptions",
                json: #"{"version":4,"savedAt":"2025-04-01T00:00:00Z","records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov","detectedPeople":["Donna"],"sceneCaptions":[{"timestamp":1.5,"text":"a beach"}],"sceneCaptionModel":"qwen"}]}"#),
        Fixture(label: "v5 relocate provenance",
                json: #"{"version":5,"savedAt":"2025-05-01T00:00:00Z","records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov","detectedPeople":["Donna"],"originalFullPath":"/Old/a.mov","originVolume":"Old"}]}"#),
        Fixture(label: "v6 generation + masterArchive",
                json: #"{"version":6,"generation":12,"savedAt":"2026-08-23T01:31:09Z","savedFromHost":"M4","masterArchive":{"targetPath":"/Volumes/TestArchive167","rootPath":"/Volumes/TestArchive167/Breen_Family_Archive","volumeUUID":"TEST-UUID-167","designatedAt":"2026-08-21T00:28:35Z"},"records":[{"id":"\#(fixedID1)","filename":"a.mov","fullPath":"/V/a.mov","detectedPeople":["Donna"],"archiveFixity":{"algorithm":"sha256","digest":"abc","sizeBytes":10,"verifiedAt":"2026-08-21T00:28:35Z"}}]}"#),
    ]

    @Test("loads, keeps its data, and the next save writes the current version", arguments: fixtures)
    func olderVersionLoadsAndUpgrades(_ f: Fixture) throws {
        let dir = scratch("old")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(f.json.utf8).write(to: catalogURL(dir))

        let store = CatalogStore(directory: dir)
        let records = store.load()
        #expect(store.lastLoadOutcome == .loaded(fromBackup: false), "\(f)")
        #expect(store.newerCatalogVersion == nil)
        #expect(records.count == 1)
        let r = try #require(records.first)
        #expect(r.filename == "a.mov")
        #expect(r.unknownFields.isEmpty, "an older catalog has nothing this build does not know")
        #expect(store.saveNow(records: records), "an older catalog upgrades on the next save")

        let probe = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(probe.version == CatalogSnapshot.currentVersion)
        // Nothing lost: the load rotated the ORIGINAL old file, byte for
        // byte, to .prev before the upgrade save replaced the primary.
        #expect(try Data(contentsOf: prevURL(dir)) == Data(f.json.utf8), "\(f): .prev must hold the pre-upgrade bytes")
        let back = CatalogStore(directory: dir)
        let again = try #require(back.load().first)
        #expect(again.filename == "a.mov")
        if f.json.contains("detectedPeople") { #expect(again.detectedPeople == ["Donna"]) }
        if f.json.contains("suspectedPeople") { #expect(again.suspectedPeople == ["Rick"]) }
        if f.json.contains("sceneCaptions") { #expect(again.sceneCaptions.first?.text == "a beach") }
        if f.json.contains("originVolume") { #expect(again.originVolume == "Old") }
        if f.json.contains("masterArchive") { #expect(back.masterArchive?.volumeUUID == "TEST-UUID-167") }
        if f.json.contains("archiveFixity") { #expect(again.archiveFixity?.digest == "abc") }

        // ONCE: a second load → save of the upgraded file changes nothing
        // but the stamps (generation / savedAt). No re-migration, no drift.
        let upgradedRecords = try #require((try jsonObject(Data(contentsOf: catalogURL(dir))))["records"] as? [Any])
        let third = CatalogStore(directory: dir)
        #expect(third.saveNow(records: third.load()))
        let top3 = try jsonObject(Data(contentsOf: catalogURL(dir)))
        #expect(top3["version"] as? Int == CatalogSnapshot.currentVersion)
        #expect(same(top3["records"], upgradedRecords), "\(f): second save must not re-migrate")
    }
}

// MARK: - 2b. Poisoned state: no path writes while a newer catalog is open

@Suite("GH #167 — poisoned state: zero writes from every save path while a newer catalog is open", .serialized)
@MainActor
struct CatalogNewerVersionNoWritePathTests {

    @Test("manual, debounced, acknowledged, async, rescan snapshots, notes repair, live reload: zero bytes, encodeAndWrite never reached")
    func everyPathIsHeld() async throws {
        let dir = scratch("poison")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = CatalogSnapshot.currentVersion + 1
        try Data(futureCatalogJSON(version: future).utf8).write(to: catalogURL(dir))
        try Data(#"{"version":6,"generation":4,"records":[]}"#.utf8).write(to: prevURL(dir))
        let before = everyFile(dir)

        let store = CatalogStore(directory: dir)
        let tripwire = WriteTripwire()
        store.testAfterWriteBeforeVerify = { url in tripwire.hit(url) }
        let records = store.load()
        #expect(records.count == 2)

        let m = VideoScanModel()
        m.catalogStore = store
        m.records = records
        #expect(m.isReadOnly, "the flag every background job checks")
        #expect(m.catalogSavingPausedNotice == CatalogStore.newerCatalogNotice)

        // A user edit while paused — the thing a save would try to persist.
        records[0].userNotes = "typed while paused"
        records[0].unknownFields["mine"] = .string("not saved")

        // Manual save (Save menu / quit-time applicationWillTerminate).
        #expect(m.saveCatalogNow() == false)
        // Autosave: debounced → saveAsync after 2 s.
        m.saveCatalogDebounced()
        // Acknowledged save (Archive Angel journal, Promote).
        #expect(await m.saveCatalogAcknowledged() == false)
        // Direct async + coalesced follow-up.
        store.saveAsync(records: records)
        store.saveAsync(records: records)
        // Rescan / scan-merge / target-removal safety snapshots.
        #expect(m.snapshotCatalog(prefix: "pre-merge") == nil)
        #expect(await m.snapshotCatalogAsync(prefix: "pre-target-removal") == nil)
        // One-time notes repair (writes a backup + marker when it runs).
        #expect(m.repairMachineTextInUserNotes() == nil)
        // Viewer-mode bookkeeping cannot lift the pause.
        m.applyReadOnlyMode(false)
        #expect(m.isReadOnly)
        #expect(m.saveCatalogNow() == false)

        // Let the debounce (2 s) and any queued async write run out.
        try await Task.sleep(nanoseconds: 2_700_000_000)

        #expect(tripwire.urls.isEmpty, "a catalog write got past the latch: \(tripwire.urls)")
        #expect(everyFile(dir) == before,
                "files changed while paused: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted()) / bytes differ")
        let probe = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(probe.version == future && probe.generation == 5, "never downgraded, never re-stamped")
        #expect(store.lastWriteError?.kind == "writesDisabled")

        // Live reload: the NEWER build saves again (generation 6, a new
        // dossier field) while we browse. The tick must show it and write
        // nothing — in particular no generation adoption into the sidecar.
        let next = futureCatalogJSON(version: future, generation: 6)
            .replacingOccurrences(of: #""filename":"plain.mov""#,
                                  with: #""filename":"plain.mov","audioTranscript":"hello from the newer build","dossierProcessedAt":"2026-10-01T13:00:00Z""#)
        try Data(next.utf8).write(to: catalogURL(dir))
        let beforeReload = everyFile(dir)
        m.lastLiveReloadMtime = .distantPast
        await m.pollAndMergeDossierFromDisk()
        #expect(m.records.first { $0.id.uuidString == fixedID2 }?.audioTranscript == "hello from the newer build",
                "browsing shows what the newer build wrote")
        #expect(everyFile(dir) == beforeReload,
                "live reload wrote while paused: \(Set(everyFile(dir).keys).symmetricDifference(beforeReload.keys).sorted())")
        #expect(m.saveCatalogNow() == false)
        #expect(tripwire.urls.isEmpty)
    }

    @Test("a newer catalog that appears mid-session flips the banner and isReadOnly at once (not at the next live-reload tick)")
    func midSessionLatchReachesTheModelImmediately() throws {
        let dir = scratch("midmodel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let m = VideoScanModel()
        m.catalogStore = store
        #expect(m.saveCatalogNow(), "a fresh current-version catalog saves")
        #expect(!m.isReadOnly)
        #expect(m.catalogSavingPausedNotice == nil)

        // Another Mac's newer build replaces catalog.json.
        let future = CatalogSnapshot.currentVersion + 1
        try Data(#"{"version":\#(future),"generation":\#(store.currentGeneration),"records":[]}"#.utf8)
            .write(to: catalogURL(dir))
        let newerBytes = try Data(contentsOf: catalogURL(dir))

        #expect(m.saveCatalogNow() == false)
        #expect(m.catalogSavingPausedNotice == CatalogStore.newerCatalogNotice, "banner up on the refused save itself")
        #expect(m.isReadOnly, "background jobs gate on this — it must flip now")
        #expect(try Data(contentsOf: catalogURL(dir)) == newerBytes)
    }

    @Test("isolation: a model on a newer-catalog store does not pause a model on a healthy store")
    func pauseDoesNotLeakAcrossModels() throws {
        let newerDir = scratch("leak_newer"), okDir = scratch("leak_ok")
        defer {
            try? FileManager.default.removeItem(at: newerDir)
            try? FileManager.default.removeItem(at: okDir)
        }
        try Data(futureCatalogJSON(version: CatalogSnapshot.currentVersion + 1).utf8).write(to: catalogURL(newerDir))
        let a = VideoScanModel()
        let sa = CatalogStore(directory: newerDir)
        _ = sa.load()
        a.catalogStore = sa
        let b = VideoScanModel()
        b.catalogStore = CatalogStore(directory: okDir)
        #expect(a.isReadOnly && a.catalogSavingPausedNotice != nil)
        #expect(!b.isReadOnly && b.catalogSavingPausedNotice == nil)
        #expect(b.saveCatalogNow())
    }
}

// MARK: - 4. Sensor: the Codable key set is pinned

@Suite("GH #167 — catalog key snapshot sensor")
struct CatalogKeySnapshotSensorTests {

    /// How to fix a red here. Additions are cheap ON PURPOSE: unknown-key
    /// preservation means an older build carries a new key through
    /// untouched, so adding a field needs NO version bump.
    static let howToFix = """
    The catalog's Codable key set changed. If you ADDED a field: add its key to the \
    snapshot in CatalogVersioningTests.swift — that is all (no version bump; unknown-key \
    preservation covers additions). If you changed an existing field's MEANING or TYPE, or \
    removed/renamed one: bump CatalogSnapshot.currentVersion as well (rule: \
    docs/practices/invariants/Catalog.md, CAT-4).
    """

    static let recordKeys: Set<String> = [
        "id", "filename", "ext", "streamTypeRaw", "size", "sizeBytes", "duration",
        "durationSeconds", "dateCreated", "dateModified", "dateCreatedRaw",
        "dateModifiedRaw", "container", "videoCodec", "resolution", "frameRate",
        "videoBitrate", "totalBitrate", "colorSpace", "bitDepth", "scanType",
        "audioCodec", "audioChannels", "audioSampleRate", "timecode", "tapeName",
        "isPlayable", "partialMD5", "fullPath", "directory", "notes", "contentHash",
        "contentHashAt", "embeddedCreationDate", "embeddedCreationSource",
        "originMake", "originModel", "originEncoder", "originalFullPath",
        "originVolume", "avidClipName", "avidMobID", "avidMaterialUUID", "avidBinFile",
        "avidMobType", "avidMediaPath", "avidTapeName", "avidEditRate", "avidTracks",
        "materialPackageUMID", "pairedWithID", "pairGroupID", "pairConfidence",
        "duplicateGroupID", "duplicateConfidence", "duplicateDisposition",
        "duplicateReasons", "duplicateBestMatchFilename", "duplicateGroupCount",
        "dupAnalyzedAt", "lifecycleStage", "mediaDisposition", "archiveStage",
        "masterLocation", "backupDestinations", "junkScore", "junkReasons",
        "starRating", "detectedPeople", "suspectedPeople", "combinedFromPairID",
        "confirmedByUserPeople", "rejectedPeople", "sceneCaptions",
        "sceneCaptionModel", "sceneCaptionDate", "ocrDateCandidates", "ocrText",
        "inferredRecordDate", "inferredDateConfidence", "inferredDateSource",
        "inferredDateRange", "inferredDateReason", "dossierProcessedAt",
        "dossierProcessedBy", "audioTranscript", "audioTranscriptModel",
        "audioTranscriptDate", "sourceHost", "scanContext", "purgedAt",
        "setAsideReason", "drmProtected", "needsReformat", "derivedFrom",
        "cleanupRecipeID", "cleanupRecipeVersion", "derivationKind", "trimInSeconds",
        "trimOutSeconds", "userDate", "userDateConfidence", "userPlace",
        "userPlaceConfidence", "backupAttestations", "workspaceActive", "userNotes",
        "tags", "audioVerifyStatus", "audioVerifyNote", "audioVerifyDate",
        "videoVerifyStatus", "videoVerifyNote", "videoVerifyDate", "supersededByID",
        "repairConfirmedDate", "archiveFixity", "contentFixity", "archivedAt",
        "proAppsMediaIdentifier", "footage", "footageDecisions", "familyMusic",
    ]

    static let topLevelKeys: Set<String> = [
        "version", "generation", "savedAt", "records", "savedFromHost", "masterArchive",
    ]

    @Test("VideoRecord's Codable keys match the snapshot")
    func recordKeysPinned() {
        let live = VideoRecord.persistedKeyNames
        #expect(live == Self.recordKeys,
                "added: \(live.subtracting(Self.recordKeys).sorted()) removed: \(Self.recordKeys.subtracting(live).sorted()). \(Self.howToFix)")
    }

    @Test("CatalogSnapshot's Codable keys match the snapshot")
    func topLevelKeysPinned() {
        let live = CatalogSnapshot.topLevelKeyNames
        #expect(live == Self.topLevelKeys,
                "added: \(live.subtracting(Self.topLevelKeys).sorted()) removed: \(Self.topLevelKeys.subtracting(live).sorted()). \(Self.howToFix)")
    }

    /// The body of the 4-space-indented method whose signature starts with
    /// `signature`, up to its closing brace.
    private static func methodBody(_ signature: String, in src: String) -> String? {
        guard let start = src.range(of: signature),
              let end = src.range(of: "\n    }\n", range: start.upperBound..<src.endIndex) else { return nil }
        return String(src[start.lowerBound..<end.upperBound])
    }

    @Test("every catalog write entry point passes the newer-catalog latch; no unguarded writer exists")
    func writeEntryPointsAreLatched() throws {
        let src = try SourceTree.appSource(named: "CatalogStore.swift")
        let gated: [(String, String)] = [
            ("func saveNow(records:", "writePrecondition()"),
            ("func saveAcknowledged(records:", "writePrecondition()"),
            ("func saveAsync(records:", "writePrecondition()"),
            ("func writeSnapshot(records:", "refuseIfNewerCatalogOnDisk()"),
            ("func writeSnapshotAsync(records:", "refuseIfNewerCatalogOnDisk()"),
        ]
        for (sig, gate) in gated {
            let body = try #require(Self.methodBody(sig, in: src), "\(sig) not found in CatalogStore.swift")
            #expect(body.contains(gate), "\(sig) no longer calls \(gate) — a newer catalog could be overwritten (GH #167)")
        }
        // writePrecondition itself starts with the latch.
        let pre = try #require(Self.methodBody("private func writePrecondition()", in: src))
        #expect(pre.contains("heldWriteRefusal()"), "writePrecondition lost the latch check")
        #expect(pre.contains("CatalogWriteHold.from(header.version)"), "writePrecondition lost the mid-session version probe (three-way verdict, codex cycle #29 F1)")
        // Exactly the five gated entry points reach the byte writer. A sixth
        // call site is a new write path: gate it, then update this count.
        let calls = src.components(separatedBy: "Self.encodeAndWrite(").count - 1
        #expect(calls == 5, "encodeAndWrite has \(calls) call sites (expected 5) — is the new one latched?")
        // ...and the byte writer itself re-checks on the write queue, after
        // the encode and before the write (codex cycle #28 #1). `gate` is a
        // required parameter, so every call site carries it.
        let writer = try #require(Self.methodBody("nonisolated private static func encodeAndWrite(", in: src))
        let encode = try #require(writer.range(of: "payload.encoded(using:"), "encodeAndWrite no longer encodes via payload.encoded(using:)")
        let check = try #require(writer.range(of: "gate.writeHold()"), "encodeAndWrite lost its last-moment newer-catalog check")
        let write = try #require(writer.range(of: "data.write(to:"))
        // Both sides pinned (codex cycle #29 predicted a surviving mutation):
        // moved BEFORE the encode, the check still precedes the write but the
        // window it closes grows by the whole encode time (seconds at 73 MB).
        #expect(encode.lowerBound < check.lowerBound, "the newer-catalog check must run AFTER the encode (as late as possible)")
        #expect(check.lowerBound < write.lowerBound, "the newer-catalog check must run BEFORE the bytes land")
        #expect(writer.contains("gate: CatalogWriteGate,"), "gate must stay a required parameter")
        // load() never rotates (.prev copy) a newer catalog.
        let load = try #require(Self.methodBody("func load() -> [VideoRecord]", in: src))
        let newer = try #require(load.range(of: "openedReadOnlyNewerVersion"))
        let rotate = try #require(load.range(of: "rotateBackup()"))
        #expect(newer.lowerBound < rotate.lowerBound, "load must decide newer-version BEFORE rotating")
    }

    @Test("currentVersion is 7 — bumped once for GH #167 (builds before it strip unknown keys)")
    func currentVersionPinned() {
        #expect(CatalogSnapshot.currentVersion == 7, """
        currentVersion changed. Bump ONLY when an existing field's meaning or type changes \
        (docs/practices/invariants/Catalog.md, CAT-4), and update this pin with the reason.
        """)
    }
}

// MARK: - 5. Scale

@Suite("GH #167 — 100k records with unknown keys stay inside the save/load budget", .serialized)
@MainActor
struct CatalogUnknownKeyScaleTests {

    @Test("100k records, every one carrying unknown keys: save ≤ 20 s, load ≤ 20 s (Debug), nothing lost")
    func hundredThousandRecordsWithUnknownKeys() throws {
        let dir = scratch("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 100_000
        let records: [VideoRecord] = (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"
            r.fullPath = "/Volumes/TestScaleVol167/clips/clip_\(i).mov"
            r.unknownFields = ["futureScore": .int(Int64(i)),
                               "futureNested": .object(["tags": .array([.string("a"), .bool(true)])])]
            return r
        }
        let store = CatalogStore(directory: dir)
        let t0 = CFAbsoluteTimeGetCurrent()
        #expect(store.saveNow(records: records))
        let save = CFAbsoluteTimeGetCurrent() - t0
        #expect(save < 20.0, "100k-record save with unknown keys took \(save) s")

        let back = CatalogStore(directory: dir)
        let t1 = CFAbsoluteTimeGetCurrent()
        let loaded = back.load()
        let load = CFAbsoluteTimeGetCurrent() - t1
        #expect(load < 20.0, "100k-record load with unknown keys took \(load) s")
        #expect(loaded.count == n)
        #expect(loaded.allSatisfy { $0.unknownFields.count == 2 }, "every record kept its unknown keys")
        #expect(loaded.last?.unknownFields["futureScore"] == .int(Int64(n - 1)))
        print("GH #167 scale: save \(String(format: "%.2f", save)) s, load \(String(format: "%.2f", load)) s for \(n) records with unknown keys")
    }
}

// MARK: - 6. Codex review 2026-10-02 (cycle #28) — one red test per finding
//
// docs/reviews/codex/codex-review-catalog-versioning-167-2026-10-02.md.
// Each test failed on d4a678f6 before its fix landed.

/// A v(current+1) catalog with the given generation and no records — the
/// bytes a newer build writes over ours mid-session.
private func newerBytes(generation: Int) -> Data {
    Data(#"{"version":\#(CatalogSnapshot.currentVersion + 1),"generation":\#(generation),"records":[]}"#.utf8)
}

@MainActor
private func waitUntil(_ seconds: Double, _ done: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
}

@Suite("GH #167 codex #1 — a queued save re-checks the newer-catalog latch before it writes", .serialized)
@MainActor
struct CatalogQueuedWriteLatchTests {

    @Test("saveAsync queued, then a newer build replaces catalog.json and the latch fires: the queued write refuses")
    func queuedAsyncSaveRefusesAfterLatch() async throws {
        let dir = scratch("q_async")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let g = store.currentGeneration

        store.testWriteDelay = 0.3
        store.saveAsync(records: [VideoRecord()])      // passes the gate on main, sleeps on the queue
        try newerBytes(generation: g).write(to: catalogURL(dir), options: .atomic)
        store.noteNewerCatalogOnDisk(version: CatalogSnapshot.currentVersion + 1)
        let newer = try Data(contentsOf: catalogURL(dir))

        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(try Data(contentsOf: catalogURL(dir)) == newer, "the queued write overwrote a newer catalog")
        #expect(store.currentGeneration == g, "a refused write must not advance the generation")
    }

    @Test("saveAsync queued, then a newer build replaces catalog.json (latch NOT yet set): the queued write discovers it and refuses")
    func queuedAsyncSaveDiscoversNewerOnDisk() async throws {
        let dir = scratch("q_disk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let g = store.currentGeneration

        store.testWriteDelay = 0.3
        store.saveAsync(records: [VideoRecord()])
        try newerBytes(generation: g).write(to: catalogURL(dir), options: .atomic)
        let newer = try Data(contentsOf: catalogURL(dir))

        await waitUntil(3) { store.newerCatalogVersion != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try Data(contentsOf: catalogURL(dir)) == newer, "the queued write overwrote a newer catalog")
        #expect(store.newerCatalogVersion == CatalogSnapshot.currentVersion + 1,
                "the write queue's discovery must latch the store")
        #expect(store.lastWriteError?.kind == "writesDisabled")
    }

    @Test("latch set while the write is queued (file untouched): the queued write still refuses")
    func queuedAsyncSaveHonoursLatchAlone() async throws {
        let dir = scratch("q_latch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let before = try Data(contentsOf: catalogURL(dir))

        store.testWriteDelay = 0.3
        store.saveAsync(records: [VideoRecord()])
        store.noteNewerCatalogOnDisk(version: CatalogSnapshot.currentVersion + 1)

        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(try Data(contentsOf: catalogURL(dir)) == before, "a write queued before the latch landed after it")
    }

    @Test("saveAcknowledged and saveNow queued behind a slow write: a newer catalog that lands meanwhile is never overwritten")
    func acknowledgedAndTerminalSavesRecheck() async throws {
        let dir = scratch("q_ack")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let g = store.currentGeneration
        let url = catalogURL(dir)
        let bytes = newerBytes(generation: g)

        // Occupy the serial write queue for 0.4 s; the newer build's file
        // lands at 0.15 s, AFTER both saves below passed their main-actor
        // gate and BEFORE either reached the queue.
        store.testWriteDelay = 0.4
        store.saveAsync(records: [VideoRecord()])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            try? bytes.write(to: url, options: .atomic)
        }
        async let ack = store.saveAcknowledged(records: [VideoRecord()])
        #expect(await ack == false, "an acknowledged save reported durable over a newer catalog")
        #expect(try Data(contentsOf: url) == bytes)

        // Terminal (quit-time) save: the latch is now set, so the gate on
        // main refuses outright.
        #expect(store.saveNow(records: [VideoRecord()]) == false)
        #expect(try Data(contentsOf: url) == bytes)
    }
}

@Suite("GH #167 codex #2 — the version probe reads only the TOP-LEVEL version", .serialized)
@MainActor
struct CatalogVersionProbeDepthTests {

    /// A record field named "version" BEFORE the top-level one (codex's
    /// reproduction — valid JSON any other writer may produce).
    static let nestedDecoy = #"{"records":[{"id":"\#(fixedID1)","version":1}],"version":\#(CatalogSnapshot.currentVersion + 1),"generation":0}"#

    @Test("head window: a record's \"version\" is not the catalog's")
    func headProbeIgnoresNestedVersion() throws {
        let dir = scratch("probe_head")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.nestedDecoy.utf8).write(to: catalogURL(dir))
        let probe = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(probe.version == CatalogSnapshot.currentVersion + 1)
    }

    @Test("saveNow without a load refuses a newer catalog whose first \"version\" is a record's")
    func saveWithoutLoadRefusesDecoy() throws {
        let dir = scratch("probe_save")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.nestedDecoy.utf8).write(to: catalogURL(dir))
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []) == false)
        #expect(everyFile(dir) == before)
        #expect(store.newerCatalogVersion == CatalogSnapshot.currentVersion + 1)
    }

    @Test("tail window: the LAST \"version\" in the tail is a record's, the top-level one is mid-file")
    func tailProbeIgnoresNestedVersion() throws {
        let dir = scratch("probe_tail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pad = String(repeating: "p", count: 6000)
        let json = #"{"padA":"\#(pad)","version":\#(CatalogSnapshot.currentVersion + 1),"generation":4,"padB":"\#(pad)","records":[{"id":"\#(fixedID1)","version":1}]}"#
        try Data(json.utf8).write(to: catalogURL(dir))
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []) == false, "a nested tail \"version\" read as the catalog's lets v7 overwrite v8")
        #expect(everyFile(dir) == before)
    }

    @Test("a top-level version more than 4 KB from both ends is still found; load writes no sidecar before the decode decides")
    func midFileVersionLoadWritesNothing() throws {
        let dir = scratch("probe_mid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pad = String(repeating: "p", count: 6000)
        let future = CatalogSnapshot.currentVersion + 1
        let json = #"{"padA":"\#(pad)","version":\#(future),"generation":3,"padB":"\#(pad)","records":[]}"#
        try Data(json.utf8).write(to: catalogURL(dir))
        #expect(CatalogSnapshot.headerProbe(at: catalogURL(dir))?.version == future)
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        _ = store.load()
        #expect(store.newerCatalogVersion == future)
        #expect(everyFile(dir) == before,
                "load wrote beside a newer catalog: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted())")
    }

    @Test("strings are opaque to the probe: an escaped \"version\" inside a value is not a key")
    func probeIgnoresVersionInsideStrings() throws {
        let dir = scratch("probe_str")
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"savedFromHost":"x\",\"version\":1,\"y","version":\#(CatalogSnapshot.currentVersion + 1),"generation":2,"records":[]}"#
        try Data(json.utf8).write(to: catalogURL(dir))
        #expect(CatalogSnapshot.headerProbe(at: catalogURL(dir))?.version == CatalogSnapshot.currentVersion + 1)
        #expect(CatalogSnapshot.headerProbe(at: catalogURL(dir))?.generation == 2)
    }

    @Test("escaped header keys: \"vers\\u0069on\" at the top level IS the catalog's version (head and tail); the same spelling inside a record is not")
    func escapedHeaderKeysRecognised() throws {
        // codex cycle #29 predicted that dropping the escape decoding in
        // slot(forKeyBytes:) would survive: the fixtures escaped VALUES, not
        // header KEYS. python json.dumps(ensure_ascii=True) never escapes
        // ASCII, but any writer MAY spell a key this way and Foundation
        // reads it as "version".
        let dir = scratch("probe_esc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = CatalogSnapshot.currentVersion + 1
        // The escaped spellings are BUILT from a character code, not typed:
        // a typed backslash-u sequence was silently unescaped on its way
        // into this file once (2026-10-02), which made this test vacuous
        // and let the mutation it exists to kill survive. The guards below
        // prove the fixture is what it claims to be.
        let backslash = String(UnicodeScalar(92))                       // "\"
        let escVersion = "vers" + backslash + "u0069on"                 // version
        let escGeneration = "gener" + backslash + "u0061tion"           // generation
        #expect(!escVersion.contains("version") && escVersion.utf8.count == 12, "fixture must really be escaped")
        // Head window.
        let head = #"{"\#(escVersion)":\#(future),"\#(escGeneration)":3,"records":[{"id":"\#(fixedID1)","\#(escVersion)":1}]}"#
        #expect(!head.contains(#""version""#), "the plain key must appear nowhere in the fixture")
        #expect(try JSONDecoder().decode(CatalogSnapshot.self, from: Data(head.utf8)).version == future,
                "Foundation reads the escaped key as the catalog's version — so must the probe")
        try Data(head.utf8).write(to: catalogURL(dir))
        var p = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(p.version == future && p.generation == 3, "escaped header keys in the head: \(p)")
        let before = everyFile(dir)
        let s1 = CatalogStore(directory: dir)
        #expect(s1.saveNow(records: []) == false, "an escaped top-level \"version\" is still the catalog's version")
        #expect(everyFile(dir) == before)
        s1.relinquishLock()
        // Tail window (backward pass), keys after > 4 KB of records.
        let pad = String(repeating: "p", count: 6000)
        let tail = #"{"padA":"\#(pad)","records":[{"id":"\#(fixedID1)","\#(escVersion)":1}],"\#(escGeneration)":4,"\#(escVersion)":\#(future)}"#
        try Data(tail.utf8).write(to: catalogURL(dir))
        p = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(p.version == future && p.generation == 4, "escaped header keys in the tail: \(p)")
        // Decoy: the escaped spelling ONLY at depth 2; a plain current
        // version at the top — this file is ours to write.
        let decoy = #"{"version":\#(CatalogSnapshot.currentVersion),"generation":1,"records":[{"id":"\#(fixedID1)","\#(escVersion)":\#(future)}]}"#
        try Data(decoy.utf8).write(to: catalogURL(dir))
        #expect(CatalogSnapshot.headerProbe(at: catalogURL(dir))?.version == CatalogSnapshot.currentVersion)
        let s2 = CatalogStore(directory: dir)
        #expect(s2.saveNow(records: s2.load()), "a record's escaped \"version\" must not hold the catalog")
    }

    @Test("our own encoder's header still probes at once, and a v0 file (no version key) still reads as old")
    func probeKeepsOrdinaryLayouts() throws {
        let dir = scratch("probe_ord")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: [VideoRecord()]))
        let p = try #require(CatalogSnapshot.headerProbe(at: catalogURL(dir)))
        #expect(p.version == CatalogSnapshot.currentVersion && p.generation == store.currentGeneration)
        try Data(#"{"records":[{"id":"\#(fixedID1)","version":99}]}"#.utf8).write(to: catalogURL(dir))
        #expect((CatalogSnapshot.headerProbe(at: catalogURL(dir))?.version ?? 0) <= CatalogSnapshot.currentVersion,
                "a v0 file's record \"version\" must not make it look newer either")
    }
}

@Suite("GH #167 codex #3 — rescan carries the LIVE unknown keys, not the scan-start copy", .serialized)
@MainActor
struct RescanUnknownFieldsLiveRefreshTests {

    @Test("live reload changes a key and adds one during the scan: the fresh record gets the live values")
    func liveReloadDuringRescanWins() {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/TestVol167")
        let old = VideoRecord(id: UUID(uuidString: fixedID1)!)
        old.fullPath = "/Volumes/TestVol167/a.mov"
        old.unknownFields = ["future": .string("old")]
        model.records = [old]
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)

        // Live reload while the scan walks: the external writer changed
        // `future` and added `futureAdded`.
        let disk = VideoRecord(id: old.id)
        disk.fullPath = old.fullPath
        disk.unknownFields = ["future": .string("new"), "futureAdded": .bool(true)]
        _ = model.mergeDossierFields(from: [disk])
        #expect(old.unknownFields["future"] == .string("new"))

        let fresh = VideoRecord()
        fresh.fullPath = old.fullPath
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        #expect(fresh.unknownFields == ["future": .string("new"), "futureAdded": .bool(true)],
                "scan-start snapshot overwrote live-reloaded unknown keys: \(fresh.unknownFields)")
    }

    @Test("a record that gains its FIRST unknown key during the scan keeps it")
    func firstUnknownKeyDuringRescanKept() {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/TestVol167")
        let old = VideoRecord(id: UUID(uuidString: fixedID2)!)
        old.fullPath = "/Volumes/TestVol167/plain.mov"
        model.records = [old]
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)   // nothing worth restoring yet

        let disk = VideoRecord(id: old.id)
        disk.fullPath = old.fullPath
        disk.unknownFields = ["futureFirst": .int(1)]
        _ = model.mergeDossierFields(from: [disk])

        let fresh = VideoRecord()
        fresh.fullPath = old.fullPath
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        #expect(fresh.unknownFields == ["futureFirst": .int(1)])
    }

    @Test("an old instance already gone keeps the scan-start copy (fallback unchanged)")
    func goneOldInstanceKeepsSnapshot() {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/TestVol167")
        let old = VideoRecord()
        old.fullPath = "/Volumes/TestVol167/b.mov"
        old.unknownFields = ["future": .string("kept")]
        model.records = [old]
        model.snapshotPreservedFieldsForRescan(of: target)
        model.records.removeAll()
        let fresh = VideoRecord()
        fresh.fullPath = old.fullPath
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        #expect(fresh.unknownFields == ["future": .string("kept")])
    }
}

@Suite("GH #167 codex #4 — unknown numbers keep their exact value through a catalog save", .serialized)
@MainActor
struct CatalogUnknownNumberExactnessTests {

    @Test("UInt64.max, < Int64.min, 35-digit decimal, exponents — top level, per record and nested — survive load → save")
    func exactNumbersSurviveCatalogSave() throws {
        let dir = scratch("numbers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let nums = #"{"u":18446744073709551615,"neg":-9223372036854775809,"big":-99999999999999999999999,"dec":3.14159265358979323846264338327950288,"tiny":5e-324,"huge":1.5e300,"mixed":12345678901234567890.123456789,"nearInt":1.0000000000000001}"#
        let json = #"{"version":\#(CatalogSnapshot.currentVersion),"generation":1,"futureNums":\#(nums),"records":[{"id":"\#(fixedID1)","futureNums":\#(nums),"futureList":[\#(nums)]}]}"#
        try Data(json.utf8).write(to: catalogURL(dir))
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: store.load()))
        let text = String(decoding: try Data(contentsOf: catalogURL(dir)), as: UTF8.self)
        for literal in ["18446744073709551615", "-9223372036854775809", "-99999999999999999999999",
                        "3.14159265358979323846264338327950288", "12345678901234567890.123456789",
                        "1.0000000000000001" /* codex cycle #29 F3: Double rounds it to 1 */] {
            // Three copies: top level, record, nested inside an array.
            #expect(text.components(separatedBy: literal).count - 1 == 3, "\(literal) not preserved exactly: \(text)")
        }
        let top = try jsonObject(Data(text.utf8))
        let n = try #require(top["futureNums"] as? [String: Any])
        #expect((n["tiny"] as? Double) == 5e-324)
        #expect((n["huge"] as? Double) == 1.5e300)
    }
}

@Suite("GH #167 codex #5 — snapshots and notes repair discover a newer primary before touching siblings", .serialized)
@MainActor
struct CatalogSiblingWritersDiscoverNewerTests {

    /// Healthy v7 catalog saved, then a newer build replaces it — nothing
    /// in this session has noticed yet.
    private func replacedByNewer(_ tag: String) throws -> (URL, CatalogStore) {
        let dir = scratch(tag)
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: [VideoRecord()]))
        try newerBytes(generation: store.currentGeneration).write(to: catalogURL(dir), options: .atomic)
        #expect(store.newerCatalogVersion == nil, "precondition: not yet discovered")
        return (dir, store)
    }

    @Test("writeSnapshot refuses and latches; no catalog.pre-* appears")
    func writeSnapshotDiscoversNewer() throws {
        let (dir, store) = try replacedByNewer("sib_snap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = everyFile(dir)
        #expect(store.writeSnapshot(records: [VideoRecord()],
                                    toPath: dir.appendingPathComponent("catalog.pre-x.json").path) == false)
        #expect(everyFile(dir) == before)
        #expect(store.newerCatalogVersion == CatalogSnapshot.currentVersion + 1)
    }

    @Test("writeSnapshotAsync refuses and latches; no catalog.pre-* appears")
    func writeSnapshotAsyncDiscoversNewer() async throws {
        let (dir, store) = try replacedByNewer("sib_snap_async")
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = everyFile(dir)
        #expect(await store.writeSnapshotAsync(records: [VideoRecord()],
                                               toPath: dir.appendingPathComponent("catalog.pre-y.json").path) == false)
        #expect(everyFile(dir) == before)
        #expect(store.newerCatalogVersion == CatalogSnapshot.currentVersion + 1)
    }

    @Test("notes repair on an empty catalog (clean-plan branch) writes no marker beside a newer primary")
    func notesRepairCleanPlanDiscoversNewer() throws {
        let (dir, store) = try replacedByNewer("sib_notes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = VideoScanModel()
        m.catalogStore = store
        m.records = []
        let before = everyFile(dir)
        #expect(m.repairMachineTextInUserNotes() == nil)
        #expect(!FileManager.default.fileExists(atPath: m.notesRepairMarkerPath), "notes-repair.v1.done written beside a newer catalog")
        #expect(everyFile(dir) == before)
        #expect(m.isReadOnly, "the discovery reaches the model at once")
    }

    @Test("a healthy primary still gets its snapshot and its notes-repair marker")
    func healthyPrimaryUnaffected() async throws {
        let dir = scratch("sib_ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: [VideoRecord()]))
        #expect(store.writeSnapshot(records: [VideoRecord()], toPath: dir.appendingPathComponent("catalog.pre-a.json").path))
        #expect(await store.writeSnapshotAsync(records: [VideoRecord()], toPath: dir.appendingPathComponent("catalog.pre-b.json").path))
        let m = VideoScanModel()
        m.catalogStore = store
        m.records = []
        #expect(m.repairMachineTextInUserNotes() != nil)
        #expect(FileManager.default.fileExists(atPath: m.notesRepairMarkerPath))
    }
}

@Suite("GH #167 — live reload while a newer catalog is open: READS and merges in memory, WRITES nothing", .serialized)
@MainActor
struct CatalogReadOnlyLiveReloadTickTests {

    @Test("the tick shows the newer build's fields; catalog.generation.max and every other file stay byte-identical")
    func readOnlyTickReadsButNeverWrites() async throws {
        let dir = scratch("ro_tick")
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = CatalogSnapshot.currentVersion + 1
        try Data(futureCatalogJSON(version: future, generation: 5).utf8).write(to: catalogURL(dir))
        // An existing high-water mark BELOW what the newer build will stamp:
        // adopting the on-disk generation would advance (rewrite) it.
        try Data("5\n".utf8).write(to: dir.appendingPathComponent(CatalogGenerationSidecar.fileName))
        let store = CatalogStore(directory: dir)
        let m = VideoScanModel()
        m.catalogStore = store
        m.records = store.load()
        #expect(m.isReadOnly)

        let next = futureCatalogJSON(version: future, generation: 9)
            .replacingOccurrences(of: #""filename":"plain.mov""#,
                                  with: #""filename":"plain.mov","audioTranscript":"read while paused","dossierProcessedAt":"2026-10-01T13:00:00Z""#)
        try Data(next.utf8).write(to: catalogURL(dir))
        let before = everyFile(dir)
        m.lastLiveReloadMtime = .distantPast
        await m.pollAndMergeDossierFromDisk()

        #expect(m.records.first { $0.id.uuidString == fixedID2 }?.audioTranscript == "read while paused",
                "reading is allowed in read-only — the tick merges into memory")
        #expect(everyFile(dir) == before, "the read-only tick wrote: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted()) / bytes differ")
        #expect(CatalogGenerationSidecar.read(besideCatalogAt: catalogURL(dir)) == 5)
        #expect(store.currentGeneration == 0, "no generation adopted while paused")
    }
}

// MARK: - 7. Codex review 2026-10-02 (cycle #29) — one red test per finding
//
// docs/reviews/codex/codex-review-catalog-versioning-167-r2-2026-10-02.md.
// Each test failed on b912eb4d before its fix landed.

private let futureVersion = CatalogSnapshot.currentVersion + 1

@Suite("GH #167 codex #29 F1 — an UNKNOWN version is never 'old': every write gate refuses", .serialized)
@MainActor
struct CatalogVersionUnknownRefusesTests {

    /// Files whose top-level `version` the probe cannot DETERMINE. Not one
    /// of them is a confirmed pre-versioning catalog, so not one may be
    /// replaced. (Foundation's own view differs per fixture — it reads the
    /// BOM and the UTF-16 file, rejects the rest — which is exactly why the
    /// probe must say "unknown" rather than guess either way.)
    static let unknownFixtures = ["truncated", "array-root", "trailing-bytes", "utf16-bom",
                                  "string-version", "unterminated-string", "empty"]

    static func fixture(_ name: String) -> Data {
        switch name {
        case "truncated":           // EOF mid-object; the version (if any) was cut off
            return Data(#"{"records":[{"id":"\#(fixedID1)","filename":"a.mov""#.utf8)
        case "array-root":
            return Data(#"[{"version":\#(futureVersion),"records":[]}]"#.utf8)
        case "trailing-bytes":      // a complete object with no version, then more
            return Data(#"{"records":[]} {"version":\#(futureVersion)}"#.utf8)
        case "utf16-bom":           // Foundation decodes this as v(current+1); the byte scanner cannot follow it
            var d = Data([0xFF, 0xFE])
            d.append(#"{"version":\#(futureVersion),"generation":0,"records":[]}"#.data(using: .utf16LittleEndian)!)
            return d
        case "string-version":      // the key is there; its value is not an integer
            return Data(#"{"version":"\#(futureVersion)","records":[]}"#.utf8)
        case "unterminated-string":
            return Data(#"{"savedFromHost":"abc"#.utf8)
        case "empty":
            return Data()
        default:
            fatalError("unknown fixture \(name)")
        }
    }

    @Test("codex's reproduction: a UTF-8 BOM before a newer catalog — Foundation reads it, the probe must too")
    func bomNewerCatalogCannotBeOverwritten() throws {
        let dir = scratch("bom")
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data(#"{"version":\#(futureVersion),"generation":0,"records":[]}"#.utf8))
        #expect(try JSONDecoder().decode(CatalogSnapshot.self, from: bytes).version == futureVersion)
        try bytes.write(to: catalogURL(dir))
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []) == false)
        #expect(everyFile(dir) == before)
        #expect(store.newerCatalogVersion == futureVersion, "the BOM file is a NEWER catalog and must latch as one")
    }

    @Test("a version the probe cannot determine refuses saveNow, saveAcknowledged, writeSnapshot and writeSnapshotAsync; zero bytes",
          arguments: unknownFixtures)
    func unknownVersionRefusesEveryPath(_ name: String) async throws {
        let dir = scratch("unk_\(name)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.fixture(name).write(to: catalogURL(dir))
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []) == false, "\(name): saveNow replaced a file whose version is unknown")
        #expect(await store.saveAcknowledged(records: []) == false, "\(name): saveAcknowledged")
        #expect(store.writeSnapshot(records: [], toPath: dir.appendingPathComponent("catalog.pre-u.json").path) == false, "\(name): writeSnapshot")
        #expect(await store.writeSnapshotAsync(records: [], toPath: dir.appendingPathComponent("catalog.pre-v.json").path) == false, "\(name): writeSnapshotAsync")
        #expect(everyFile(dir) == before, "\(name): bytes changed: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted())")
        #expect(store.writesDisabledReason != nil, "\(name): the hold must be latched for the session")
        #expect(store.lastWriteError?.kind == "writesDisabled")
    }

    @Test("a genuine pre-versioning catalog (complete object, no version key) still upgrades on save; a missing file still saves")
    func confirmedAbsentAndMissingStillWrite() throws {
        let dir = scratch("absent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store0 = CatalogStore(directory: dir)
        #expect(store0.saveNow(records: []), "no file: the first save must succeed")
        store0.relinquishLock()
        try Data(#"{"records":[{"id":"\#(fixedID1)","version":99}]}"#.utf8).write(to: catalogURL(dir))
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: store.load()), "a v0 catalog is confirmed OLD, not unknown — it upgrades")
        #expect(try jsonObject(Data(contentsOf: catalogURL(dir)))["version"] as? Int == CatalogSnapshot.currentVersion)
    }

    @Test("codex's variant: BOM + undecodable newer primary — load latches read-only and writes nothing (no sidecar)")
    func bomUndecodableNewerLoadWritesNothing() throws {
        let dir = scratch("bom_undecodable")
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data(#"{"version":\#(futureVersion),"generation":0,"records":"not an array"}"#.utf8))
        try bytes.write(to: catalogURL(dir))
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        _ = store.load()
        #expect(store.newerCatalogVersion == futureVersion)
        #expect(everyFile(dir) == before, "load wrote beside a newer catalog: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted())")
        #expect(store.saveNow(records: []) == false)
        #expect(everyFile(dir) == before)
    }

    @Test("an undecodable primary whose version is UNKNOWN: load persists no sidecar and holds writes; .prev is still shown")
    func unknownUndecodableLoadWritesNothing() throws {
        let dir = scratch("unk_load")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A healthy .prev to recover from, then an unreadable primary.
        let s0 = CatalogStore(directory: dir)
        let r = VideoRecord(); r.filename = "kept.mov"
        #expect(s0.saveNow(records: [r]))
        s0.relinquishLock()
        try FileManager.default.copyItem(at: catalogURL(dir), to: prevURL(dir))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(CatalogGenerationSidecar.fileName))
        try Self.fixture("unterminated-string").write(to: catalogURL(dir))
        let before = everyFile(dir)
        let store = CatalogStore(directory: dir)
        let shown = store.load()
        #expect(shown.first?.filename == "kept.mov", "browsing .prev is still allowed")
        #expect(store.lastLoadOutcome == .loaded(fromBackup: true))
        #expect(everyFile(dir) == before, "load wrote beside an unreadable catalog: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted())")
        #expect(store.saveNow(records: shown) == false, "the recovered records must not replace a file whose version is unknown")
        #expect(everyFile(dir) == before)
    }

    @Test("the model says what happened — 'could not be read', never 'newer' — and reads as read-only")
    func unknownHoldHasItsOwnWords() throws {
        let dir = scratch("unk_words")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.fixture("truncated").write(to: catalogURL(dir))
        let store = CatalogStore(directory: dir)
        let m = VideoScanModel()
        m.catalogStore = store
        m.records = store.load()
        #expect(m.isReadOnly)
        #expect(m.catalogSavingPausedNotice == CatalogStore.unreadableCatalogNotice)
        #expect(m.catalogSavingPausedNotice != CatalogStore.newerCatalogNotice)
        #expect(store.newerCatalogVersion == nil, "an unknown version is not a known newer one")
        #expect(store.writeHold == .versionUnknown)
        #expect(CatalogStore.unreadableCatalogNotice.contains("catalog.json.prev"), "the words must say how to recover")
    }

    @Test("cost bound: an unknown file > both windows triggers the whole-file pass ONCE per session, not once per refused save")
    func wholeFilePassRunsOncePerSession() throws {
        let dir = scratch("unk_bound")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pad = String(repeating: "p", count: 6000)
        try Data(#"{"padA":"\#(pad)","records":[{"id":"\#(fixedID1)","padB":"\#(pad)""#.utf8).write(to: catalogURL(dir))
        let store = CatalogStore(directory: dir)
        let n0 = CatalogHeaderScanner.wholeFilePasses.withLock { $0 }
        for _ in 0..<3 { #expect(store.saveNow(records: []) == false) }
        let passes = CatalogHeaderScanner.wholeFilePasses.withLock { $0 } - n0
        #expect(passes == 1, "whole-file pass ran \(passes) times for three refused saves against one unchanged file")
    }
}

@Suite("GH #167 codex #29 F2 — a latch that fires DURING the write gate's probe is honoured", .serialized)
@MainActor
struct CatalogGateLatchDuringProbeTests {

    @Test("saveAsync: the gate's probe sees an OLD file, the main actor latches before the gate answers — the write refuses")
    func latchDuringProbeRefuses() async throws {
        let dir = scratch("gate_probe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let before = try Data(contentsOf: catalogURL(dir))
        let g = store.currentGeneration

        // Runs on the write queue between the probe and the gate's answer.
        // The main actor is free (this test is suspended in waitUntil), so
        // hopping to it is deadlock-free; it would not be from saveNow.
        store.testGateAfterProbe = {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { store.noteNewerCatalogOnDisk(version: futureVersion) }
            }
        }
        store.saveAsync(records: [VideoRecord()])
        await waitUntil(3) { store.lastWriteError != nil || store.currentGeneration > g }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(try Data(contentsOf: catalogURL(dir)) == before, "a latch raised during the probe was missed — the write landed")
        #expect(store.currentGeneration == g)
        #expect(store.lastWriteError?.kind == "writesDisabled")
        #expect(store.newerCatalogVersion == futureVersion)
    }
}

@Suite("GH #167 codex #29 F4 — deferred sibling writes re-check at the mutation boundary", .serialized)
@MainActor
struct CatalogDeferredSiblingWritesTests {

    /// A landed async save, parked after verification and before its
    /// completion runs on the main actor. Returns the semaphore that
    /// releases it and the generation it wrote.
    private func parkLandedAsyncSave(_ store: CatalogStore, at url: URL) async throws -> (DispatchSemaphore, Int) {
        #expect(store.saveNow(records: []))
        let g = store.currentGeneration
        let release = DispatchSemaphore(value: 0)
        store.testAfterVerifyBeforeCompletion = { _ in release.wait() }
        store.saveAsync(records: [VideoRecord()])
        await waitUntil(3) { CatalogSnapshot.headerProbe(at: url)?.generation == g + 1 }
        #expect(CatalogSnapshot.headerProbe(at: url)?.generation == g + 1, "precondition: the async write landed")
        #expect(CatalogGenerationSidecar.read(besideCatalogAt: url) == g, "precondition: sidecar not yet advanced")
        return (release, g + 1)
    }

    @Test("a landed async save whose completion runs AFTER the latch fired does not advance catalog.generation.max")
    func finishWriteSkipsSidecarAfterLatch() async throws {
        let dir = scratch("defer_latch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let url = catalogURL(dir)
        let (release, wrote) = try await parkLandedAsyncSave(store, at: url)
        let sidecarBefore = CatalogGenerationSidecar.read(besideCatalogAt: url)

        let newer = newerBytes(generation: wrote)
        try newer.write(to: url, options: .atomic)
        store.noteNewerCatalogOnDisk(version: futureVersion)
        let before = everyFile(dir)
        release.signal()
        await waitUntil(3) { store.currentGeneration == wrote }

        #expect(CatalogGenerationSidecar.read(besideCatalogAt: url) == sidecarBefore,
                "finishWrite advanced catalog.generation.max beside a newer catalog")
        #expect(everyFile(dir) == before, "completion wrote: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted()) / bytes differ")
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test("same window, no latch call: finishWrite discovers the newer primary itself and skips the sidecar")
    func finishWriteDiscoversNewerPrimary() async throws {
        let dir = scratch("defer_disc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let url = catalogURL(dir)
        let (release, wrote) = try await parkLandedAsyncSave(store, at: url)
        let sidecarBefore = CatalogGenerationSidecar.read(besideCatalogAt: url)

        try newerBytes(generation: wrote).write(to: url, options: .atomic)
        let before = everyFile(dir)
        release.signal()
        await waitUntil(3) { store.currentGeneration == wrote }

        #expect(CatalogGenerationSidecar.read(besideCatalogAt: url) == sidecarBefore)
        #expect(everyFile(dir) == before)
        #expect(store.newerCatalogVersion == futureVersion, "the completion must latch what it found")
    }

    @Test("notes repair: the primary is replaced after planning and before the clean-plan marker — no marker")
    func notesRepairRechecksBeforeMarker() throws {
        let dir = scratch("defer_notes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: [VideoRecord()]))
        let m = VideoScanModel()
        m.catalogStore = store
        m.records = []
        var before: [String: Data] = [:]
        let url = catalogURL(dir)
        let result = m.repairMachineTextInUserNotes(testAfterPlan: {
            try? newerBytes(generation: store.currentGeneration).write(to: url, options: .atomic)
            before = everyFile(dir)
        })
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: m.notesRepairMarkerPath), "notes-repair.v1.done written beside a newer catalog")
        #expect(everyFile(dir) == before)
        #expect(m.isReadOnly, "the discovery reaches the model at once")
    }
}

// MARK: - 8. Codex review 2026-10-02 (cycle #30) — one red test per finding
//
// docs/reviews/codex/codex-review-catalog-versioning-167-r3-2026-10-02.md.
// Each test failed on c283af00 before its fix landed.

private let currentVersion = CatalogSnapshot.currentVersion

@Suite("GH #167 codex #30 R1 — a verdict needs the WHOLE top-level object: no early stop, duplicate stamps merged, malformed = unknown", .serialized)
@MainActor
struct CatalogVerdictNeedsCompleteObjectTests {

    static let pad = String(repeating: "p", count: 6000)

    /// codex's four reproductions, plus the across-windows duplicate (an
    /// old stamp in the head window, a newer one in the tail window, > 8 KB
    /// apart), plus two more malformed shapes. Not one is a catalog this
    /// build may replace: Foundation reads the first as v(current+1) (it
    /// keeps the LAST duplicate key), and the rest are not catalogs at all.
    static let unsafe: [String] = [
        #"{"version":\#(currentVersion),"generation":0,"records":[],"version":\#(futureVersion)}"#,
        #"{"version":\#(currentVersion),"generation":0,"records":["#,
        #"{"version":\#(currentVersion),"generation":0,"records":[]} garbage"#,
        #"{"records":]"#,
        #"{"version":\#(currentVersion),"generation":0,"padA":"\#(pad)","records":[],"padB":"\#(pad)","version":\#(futureVersion)}"#,
        #"{"version":\#(currentVersion),"version":"x","records":[]}"#,
        #"{"version":\#(currentVersion),"records":[1}"#,
    ]

    @Test("codex's reproductions (+ across-windows duplicate, + two malformed): the gate holds and saveNow writes nothing", arguments: unsafe)
    func unsafeCatalogIsNotReplaced(_ text: String) throws {
        let dir = scratch("unsafe_header")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(text.utf8).write(to: catalogURL(dir))
        let before = everyFile(dir)
        let header = try #require(CatalogSnapshot.header(at: catalogURL(dir)))
        #expect(CatalogWriteHold.from(header.version) != nil,
                "verdict \(header.version) permits a write over: \(text.prefix(72))…")
        let store = CatalogStore(directory: dir)
        #expect(!store.saveNow(records: []), "replaced: \(text.prefix(72))…")
        #expect(everyFile(dir) == before)
    }

    @Test("duplicate top-level stamps: the HIGHER wins wherever it sits — later in the same window, across windows, or first")
    func duplicateStampsKeepTheHigher() throws {
        let dir = scratch("dup_stamps")
        defer { try? FileManager.default.removeItem(at: dir) }
        let later = #"{"version":\#(currentVersion),"generation":0,"records":[],"version":\#(futureVersion)}"#
        // Readers DISAGREE on duplicate keys: Foundation's JSONDecoder keeps
        // the FIRST (measured on macOS 26, 2026-10-02), python's json.load
        // keeps the LAST. The probe cannot know which reader wrote or will
        // read this file, so it takes the max — refusing is right either way.
        let foundation = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(later.utf8)).version
        #expect(foundation == currentVersion || foundation == futureVersion, "fixture: Foundation reads one of the two stamps, got \(foundation)")
        let across = #"{"version":\#(currentVersion),"padA":"\#(Self.pad)","records":[],"padB":"\#(Self.pad)","version":\#(futureVersion),"generation":2}"#
        // QA r4 7a: prove the two stamps really sit in DIFFERENT 4 KB windows
        // — the old one in the head, the newer one in the tail, > 8 KB apart.
        let acrossBytes = Array(across.utf8)
        let stamp = Array(#""version":"#.utf8)
        let stampOffsets = acrossBytes.indices.filter { $0 + stamp.count <= acrossBytes.count && Array(acrossBytes[$0..<($0 + stamp.count)]) == stamp }
        #expect(stampOffsets.count == 2, "fixture must hold exactly two top-level stamps")
        #expect(stampOffsets[0] < 4096, "the old stamp must be inside the head window (at \(stampOffsets[0]))")
        #expect(stampOffsets[1] > acrossBytes.count - 4096, "the newer stamp must be inside the tail window (at \(stampOffsets[1]) of \(acrossBytes.count))")
        #expect(stampOffsets[1] - stampOffsets[0] > 8192, "stamps must be > 8 KB apart")
        let first = #"{"version":\#(futureVersion),"generation":0,"records":[],"version":\#(currentVersion)}"#
        for (label, text) in [("later", later), ("across", across), ("first", first)] {
            try Data(text.utf8).write(to: catalogURL(dir))
            let h = try #require(CatalogSnapshot.header(at: catalogURL(dir)))
            #expect(h.version == .version(futureVersion), "\(label): \(h.version)")
        }
        try Data(#"{"version":\#(currentVersion),"generation":1,"padA":"\#(Self.pad)","records":[],"generation":9}"#.utf8).write(to: catalogURL(dir))
        #expect(CatalogSnapshot.header(at: catalogURL(dir))?.generation == 9, "the generation merges the same way")
    }

    static let complete: [String] = [
        #"{"records":[]}"#,
        #" {"records":[] } \#n"#,
        #"{"generation":4,"records":[{"id":"\#(fixedID1)","version":99}]}"#,
        #"{"padA":"\#(pad)","records":[],"padB":"\#(pad)"}"#,
    ]
    static let incomplete: [String] = [
        #"{"records":]"#, #"{"records":[}"#, #"{"records":[]"#, #"{"records":[]}x"#,
        #"{"records":[]}{}"#, #"{"records":[]}]"#, #"{"records":[[]}"#, "",
    ]

    @Test(".confirmedAbsent: a complete, well-formed object with no top-level version key", arguments: complete)
    func confirmedAbsentForCompleteObjects(_ text: String) throws {
        let dir = scratch("absent_ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(text.utf8).write(to: catalogURL(dir))
        #expect(CatalogSnapshot.header(at: catalogURL(dir))?.version == .confirmedAbsent, "\(text.prefix(40))")
    }

    @Test(".unknown: mismatched delimiters, unterminated, bytes after the object, empty", arguments: incomplete)
    func unknownForIncompleteObjects(_ text: String) throws {
        let dir = scratch("absent_no")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(text.utf8).write(to: catalogURL(dir))
        #expect(CatalogSnapshot.header(at: catalogURL(dir))?.version == .unknown, "\(text.prefix(40))")
    }
}

@Suite("GH #167 codex #30 R2 — load honours an UNKNOWN verdict even when Foundation decodes the file", .serialized)
@MainActor
struct CatalogLoadHonoursUnknownVerdictTests {

    @Test("UTF-16 BOM + current version: Foundation decodes it, the scanner cannot — load shows the records, holds, and writes no sibling")
    func decodableButUnknownLoadHolds() throws {
        let dir = scratch("unk_decodable")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A distinct .prev, no sidecar: both are exactly what an unheld load
        // would touch (rotation, first-run bootstrap).
        try Data(#"{"version":\#(currentVersion),"generation":1,"records":[{"id":"\#(fixedID2)","filename":"prev.mov"}]}"#.utf8).write(to: prevURL(dir))
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(#"{"version":\#(currentVersion),"generation":5,"records":[{"id":"\#(fixedID1)","filename":"utf16.mov"}]}"#.data(using: .utf16LittleEndian)!)
        try utf16.write(to: catalogURL(dir))
        #expect(try JSONDecoder().decode(CatalogSnapshot.self, from: utf16).records.count == 1, "fixture: Foundation reads it")
        #expect(CatalogSnapshot.header(at: catalogURL(dir))?.version == .unknown, "fixture: the scanner cannot follow it")
        let before = everyFile(dir)

        let store = CatalogStore(directory: dir)
        let shown = store.load()
        #expect(shown.first?.filename == "utf16.mov", "browsing what Foundation decoded is still allowed")
        #expect(store.writeHold == .versionUnknown, "load must adopt the scanner's hold, not override it with the decode")
        #expect(everyFile(dir) == before,
                "load wrote beside a held catalog: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted()) / bytes differ")
        #expect(store.pauseNotice == CatalogStore.unreadableCatalogNotice)
        #expect(store.lastLoadOutcome == .openedReadOnlyVersionUnknown)
        #expect(store.saveNow(records: shown) == false, "load and the save gate must agree")
        #expect(everyFile(dir) == before)
    }
}

@Suite("GH #167 codex #30 R3 — a landed save beside a replaced primary does not notify the observer (no deferred manifest refresh)", .serialized)
@MainActor
struct CatalogObserverGatedByHoldTests {

    private final class CountingObserver: CatalogStoreObserver {
        var callbacks = 0
        func catalogStoreDidWrite(_ store: CatalogStore) { callbacks += 1 }
    }

    /// A landed async save, parked after verification and before its
    /// completion; the observer is installed while it is parked.
    private func parkLandedAsyncSave(_ store: CatalogStore, at url: URL) async -> (DispatchSemaphore, Int) {
        #expect(store.saveNow(records: []))
        let g = store.currentGeneration
        let release = DispatchSemaphore(value: 0)
        store.testAfterVerifyBeforeCompletion = { _ in release.wait() }
        store.saveAsync(records: [VideoRecord()])
        await waitUntil(3) { CatalogSnapshot.headerProbe(at: url)?.generation == g + 1 }
        #expect(CatalogSnapshot.headerProbe(at: url)?.generation == g + 1, "precondition: the async write landed")
        return (release, g + 1)
    }

    @Test("async completion discovers the newer primary: 0 callbacks (codex's extension of finishWriteDiscoversNewerPrimary)")
    func asyncCompletionDoesNotNotifyBesideNewerPrimary() async throws {
        let dir = scratch("obs_async")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let url = catalogURL(dir)
        let (release, wrote) = await parkLandedAsyncSave(store, at: url)
        let observer = CountingObserver()
        store.observer = observer
        try newerBytes(generation: wrote).write(to: url, options: .atomic)
        release.signal()
        await waitUntil(3) { store.currentGeneration == wrote }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(observer.callbacks == 0, "catalogStoreDidWrite fired \(observer.callbacks)× for a save whose primary was replaced by a newer catalog")
        #expect(store.newerCatalogVersion == futureVersion)
    }

    @Test("acknowledged completion, same window: 0 callbacks; a healthy completion still notifies exactly once")
    func acknowledgedCompletionDoesNotNotifyBesideNewerPrimary() async throws {
        let dir = scratch("obs_ack")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let url = catalogURL(dir)
        let observer = CountingObserver()
        store.observer = observer
        #expect(store.saveNow(records: []))
        #expect(observer.callbacks == 1, "control: a healthy save notifies once")
        let g = store.currentGeneration
        // The seam runs on the write queue after verification: replace the
        // primary there, before the main-actor completion.
        let newer = newerBytes(generation: g + 1)
        store.testAfterVerifyBeforeCompletion = { written in try? newer.write(to: written, options: .atomic) }
        _ = await store.saveAcknowledged(records: [VideoRecord()])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(observer.callbacks == 1, "catalogStoreDidWrite fired \(observer.callbacks - 1)× for an acknowledged save whose primary was replaced")
        #expect(store.newerCatalogVersion == futureVersion, "the completion must latch what it found")
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test("source sensor: the observer is notified from ONE place, after the same check that guards the sidecar")
    func observerNotifiedFromOnePlace() throws {
        let src = try SourceTree.appSource(named: "CatalogStore.swift")
        let calls = src.components(separatedBy: "observer?.catalogStoreDidWrite(").count - 1
        #expect(calls == 1, "observer?.catalogStoreDidWrite( appears \(calls)× — the notification must be gated once, in finishWrite (GH #167, codex cycle #30 R3)")
    }
}

@Suite("GH #167 codex #30 R4 — the verdict is cached by (size, mtime, ctime, inode): one whole-file pass per file CHANGE, a stat otherwise", .serialized)
@MainActor
struct CatalogProbeCacheTests {

    /// ≥ 200k records / ≥ 50 MB, the top-level `version` BETWEEN two large
    /// arrays — more than 4 KB from either end, so no window can see it.
    /// Returns (bytes, offset of the version key).
    static func writeScaledFixture(to url: URL, records n: Int = 200_000) throws -> (size: Int, versionOffset: Int) {
        let notes = String(repeating: "n", count: 160)
        var data = Data()
        data.reserveCapacity(72 << 20)
        func append(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func record(_ i: Int) -> String {
            #"{"id":"\#(String(format: "%08d", i))-0000-4000-8000-000000000000","filename":"clip_\#(i).mov","fullPath":"/Volumes/TestScaleVol167/decade/year/event/clip_\#(i).mov","notes":"\#(notes)"}"#
        }
        append(#"{"generation":3,"records":["#)
        for i in 0..<(n / 2) {
            if i > 0 { data.append(UInt8(ascii: ",")) }
            append(record(i))
        }
        append("],")
        let versionOffset = data.count
        append(#""version":\#(currentVersion),"moreRecords":["#)
        for i in (n / 2)..<n {
            if i > n / 2 { data.append(UInt8(ascii: ",")) }
            append(record(i))
        }
        append("]}")
        try data.write(to: url)
        return (data.count, versionOffset)
    }

    @Test("scale: ≥ 200k records / ≥ 50 MB, version mid-file — first probe ≤ 2 s off-main, 20 repeated probes ≤ 5 ms each, ONE whole-file pass")
    func scaledProbeBudget() async throws {
        let dir = scratch("probe_scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = catalogURL(dir)
        let (size, versionOffset) = try Self.writeScaledFixture(to: url)
        #expect(size >= 50 << 20, "fixture is \(size) bytes")
        #expect(versionOffset > 4096 && versionOffset < size - 4096, "version must be out of both windows (at \(versionOffset) of \(size))")
        let passes0 = CatalogHeaderScanner.wholeFilePasses(for: url)

        let first: (CatalogSnapshot.Header?, Double) = await Task.detached {
            let t0 = CFAbsoluteTimeGetCurrent()
            let h = CatalogSnapshot.header(at: url)
            return (h, CFAbsoluteTimeGetCurrent() - t0)
        }.value
        #expect(first.0?.version == .version(currentVersion))
        #expect(first.0?.generation == 3)
        #expect(first.1 <= 2.0, "first probe of \(size) bytes took \(first.1) s")

        var worst = 0.0
        for _ in 0..<20 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let h = CatalogSnapshot.header(at: url)
            worst = max(worst, CFAbsoluteTimeGetCurrent() - t0)
            #expect(h?.version == .version(currentVersion))
        }
        #expect(worst <= 0.005, "a repeated probe of an unchanged \(size)-byte file took \(worst * 1000) ms")
        let passes = CatalogHeaderScanner.wholeFilePasses(for: url) - passes0
        #expect(passes == 1, "\(passes) whole-file passes for 21 probes of one unchanged file")
        print("GH #167 probe scale: \(size) bytes, first probe \(String(format: "%.3f", first.1)) s, worst repeated \(String(format: "%.3f", worst * 1000)) ms, \(passes) pass(es)")
    }

    @Test("the cache follows the file: an atomic replacement and an in-place same-size edit are both re-scanned; an unchanged file is not")
    func cacheFollowsTheFile() throws {
        let dir = scratch("probe_cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = catalogURL(dir)
        let pad = String(repeating: "p", count: 6000)
        try Data(#"{"padA":"\#(pad)","records":[],"padB":"\#(pad)"}"#.utf8).write(to: url)
        let p0 = CatalogHeaderScanner.wholeFilePasses(for: url)
        #expect(CatalogSnapshot.header(at: url)?.version == .confirmedAbsent)
        #expect(CatalogSnapshot.header(at: url)?.version == .confirmedAbsent)
        #expect(CatalogHeaderScanner.wholeFilePasses(for: url) - p0 == 1, "an unchanged file was re-scanned")

        // Atomic replacement (rename → new inode).
        let text = #"{"padA":"\#(pad)","records":[],"padB":"\#(pad)","version":\#(currentVersion)}"#
        try Data(text.utf8).write(to: url, options: .atomic)
        #expect(CatalogSnapshot.header(at: url)?.version == .version(currentVersion))
        #expect(CatalogHeaderScanner.wholeFilePasses(for: url) - p0 == 2, "a replaced file was not re-scanned")

        // In-place edit, same size, same inode: only the digit changes.
        let h = try FileHandle(forWritingTo: url)
        let digitOffset = text.utf8.count - 2   // …"version":7}
        #expect(Array(text.utf8)[digitOffset] == Array("\(currentVersion)".utf8)[0], "fixture: offset must point at the version digit")
        try h.seek(toOffset: UInt64(digitOffset))
        try h.write(contentsOf: Data("\(futureVersion)".utf8))
        try h.close()
        #expect(CatalogSnapshot.header(at: url)?.version == .version(futureVersion), "an in-place edit must invalidate the cache (mtime/ctime)")
        #expect(CatalogHeaderScanner.wholeFilePasses(for: url) - p0 == 3)
        #expect(CatalogSnapshot.header(at: url)?.version == .version(futureVersion))
        #expect(CatalogHeaderScanner.wholeFilePasses(for: url) - p0 == 3)
    }

    @Test("codex's residual: a v0 file > both windows whose saves are refused for a STALE generation is scanned once, not once per attempt")
    func staleGenerationRefusalsScanOnce() throws {
        let dir = scratch("probe_stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = catalogURL(dir)
        let pad = String(repeating: "p", count: 6000)
        try Data(#"{"generation":999,"padA":"\#(pad)","records":[],"padB":"\#(pad)"}"#.utf8).write(to: url)
        let store = CatalogStore(directory: dir)   // loadedGeneration 0: every save is stale
        let p0 = CatalogHeaderScanner.wholeFilePasses(for: url)
        for _ in 0..<3 {
            #expect(store.saveNow(records: []) == false)
            #expect(store.lastWriteError?.kind == "stale")
        }
        let passes = CatalogHeaderScanner.wholeFilePasses(for: url) - p0
        #expect(passes == 1, "\(passes) whole-file passes for three stale-refused saves against one unchanged file")
    }

    @Test("a v0 catalog > both windows: load + save run ONE whole-file pass in total (not before-probe, after-probe, precondition and gate each)")
    func v0LoadAndSaveScanOnce() throws {
        let dir = scratch("probe_v0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = catalogURL(dir)
        let pad = String(repeating: "p", count: 6000)
        try Data(#"{"padA":"\#(pad)","records":[{"id":"\#(fixedID1)","filename":"old.mov"}],"padB":"\#(pad)"}"#.utf8).write(to: url)
        let store = CatalogStore(directory: dir)
        let p0 = CatalogHeaderScanner.wholeFilePasses(for: url)
        let loaded = store.load()
        #expect(loaded.first?.filename == "old.mov")
        #expect(store.saveNow(records: loaded), "a v0 catalog upgrades")
        #expect(CatalogSnapshot.header(at: url)?.version == .version(currentVersion))
        let passes = CatalogHeaderScanner.wholeFilePasses(for: url) - p0
        #expect(passes == 1, "\(passes) whole-file passes for one load and one save of a v0 catalog (the verified write seeds the cache)")
    }
}

@Suite("GH #167 codex #30 — the three mutations codex predicted would survive", .serialized)
@MainActor
struct CatalogCycle30PredictedSurvivorTests {

    @Test("S1: a save queued against a HEALTHY file, replaced by an UNKNOWN one before the write queue's gate — refused on the queue, held")
    func queuedWriteRefusesUnknownDiscoveredOnTheQueue() async throws {
        let dir = scratch("q_unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let g = store.currentGeneration
        let url = catalogURL(dir)

        store.testWriteDelay = 0.3
        store.saveAsync(records: [VideoRecord()])          // passes the main-actor gate, sleeps on the queue
        let unknown = CatalogVersionUnknownRefusesTests.fixture("truncated")
        try unknown.write(to: url, options: .atomic)

        await waitUntil(3) { store.lastWriteError != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try Data(contentsOf: url) == unknown, "the queued write replaced a file whose version is unknown")
        #expect(store.writeHold == .versionUnknown, "the write queue's discovery must latch the store")
        #expect(store.currentGeneration == g)
        #expect(store.lastWriteError?.kind == "writesDisabled")
    }

    @Test("S3: notes repair, DIRTY plan — the primary is replaced after the backup snapshot and before the marker: no marker, store held")
    func dirtyPlanFinalRecheckBeforeMarker() throws {
        let dir = scratch("notes_dirty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: [VideoRecord()]))
        let m = VideoScanModel()
        m.catalogStore = store
        let dirty = VideoRecord()
        dirty.filename = "machine.mov"
        dirty.userNotes = "Unsupported codec with id 98314 for input stream 0"
        m.records = [dirty]
        let url = catalogURL(dir)
        let newer = newerBytes(generation: store.currentGeneration)
        // The only write before the marker on the dirty branch is the
        // pre-notes-repair snapshot; its seam fires on the main thread
        // (writeSnapshot is synchronous). Replace the PRIMARY there, leave
        // the snapshot intact so the repair proceeds to the marker.
        store.testAfterWriteBeforeVerify = { written in
            guard written.lastPathComponent != "catalog.json" else { return }
            try? newer.write(to: url, options: .atomic)
        }
        let result = m.repairMachineTextInUserNotes()
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("catalog.pre-notes-repair.") }
        #expect(backups.count == 1, "precondition: the dirty branch wrote its backup before the primary was replaced")
        #expect(result?.recordsCleaned == 1, "precondition: the dirty branch ran")
        #expect(!FileManager.default.fileExists(atPath: m.notesRepairMarkerPath),
                "notes-repair.v1.done written beside a newer catalog — the DIRTY branch's final re-check is missing")
        #expect(m.isReadOnly, "the discovery reaches the model")
        #expect(try Data(contentsOf: url) == newer)
    }
}

// MARK: - 9. QA review of round 4 (2026-10-02) — fail-closed tightenings
//
// Each test failed on 83a2ec70 before its fix landed (the controls did not).

/// Makes `CatalogHeaderScanner.probe` believe open(2) failed with `code`
/// for ONE url, for the first `times` attempts (default: every attempt),
/// and counts the attempts it refused. Scoped by path so parallel suites
/// probing other files are untouched. (≈ an errno-injecting LD_PRELOAD
/// shim, scoped to one path.)
private final class OpenFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return refused }
    init(url: URL, errno code: Int32, times: Int = .max) {
        let path = url.path
        CatalogHeaderScanner.testOpenErrno.withLock { seam in
            seam = { [self] u in
                guard u.path == path else { return nil }
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.refused < times else { return nil }
                self.refused += 1
                return code
            }
        }
    }
    func clear() { CatalogHeaderScanner.testOpenErrno.withLock { $0 = nil } }
}

@Suite("GH #167 QA r4 (1, 2) — non-canonical stamps and malformed bytes are unknown: negative, leading zero, control bytes, depth cap", .serialized)
@MainActor
struct CatalogScannerNonCanonicalStampTests {

    private func verdict(_ text: String, _ dir: URL) throws -> CatalogVersionVerdict {
        try Data(text.utf8).write(to: catalogURL(dir))
        return try #require(CatalogSnapshot.header(at: catalogURL(dir))).version
    }

    static let negative: [String] = [
        #"{"version":-1,"records":[]}"#,
        #"{"version":-\#(futureVersion),"records":[]}"#,
        #"{"version":\#(currentVersion),"version":-1,"records":[]}"#,
    ]

    @Test("A: a negative version is not a stamp this build can vouch for", arguments: negative)
    func negativeVersionIsUnknown(_ text: String) throws {
        let dir = scratch("neg")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try verdict(text, dir) == .unknown, "\(text)")
    }

    @Test("A control: 0 and a plain positive integer are stamps")
    func canonicalIntegersAreStamps() throws {
        let dir = scratch("neg_ctl")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try verdict(#"{"version":0,"records":[]}"#, dir) == .version(0))
        #expect(try verdict(#"{"version": 12 ,"records":[]}"#, dir) == .version(12))
    }

    static let malformed: [String] = [
        "{\"version\":\(currentVersion),\u{00}\"records\":[]}",        // NUL between tokens
        "{\"version\":\(currentVersion)\u{00}}",                         // NUL after a number
        "{\"version\":\(currentVersion),\"records\":[]\u{01}}",          // SOH before the closing brace
        "{\"version\":\(currentVersion),\"records\":[\"a\u{00}b\"]}",    // raw NUL inside a string (JSON forbids it; Foundation rejects the file)
        "{\"version\":0\(currentVersion),\"records\":[]}",               // leading zero
        "{\"version\":00,\"records\":[]}",
    ]

    @Test("B: control bytes anywhere but as escapes, and a leading zero, make the file unknown", arguments: malformed)
    func controlBytesAndLeadingZerosAreUnknown(_ text: String) throws {
        let dir = scratch("ctl")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try verdict(text, dir) == .unknown, "\(text.debugDescription)")
    }

    @Test("B control: JSON whitespace between tokens and ESCAPED control characters inside strings are fine")
    func whitespaceAndEscapesAreFine() throws {
        let dir = scratch("ctl_ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "{\n\t\"version\":\r\(currentVersion) ,\"note\":\"a\\u0000b\\n\\t\",\"records\":[]}\n"
        #expect(try JSONDecoder().decode(CatalogSnapshot.self, from: Data(text.utf8)).version == currentVersion, "fixture: Foundation reads it")
        #expect(try verdict(text, dir) == .version(currentVersion))
    }

    @Test("depth cap: 255 nested containers inside the root are followed; 256 abort (a 10 M-bracket file must not grow the stack)")
    func depthIsCapped() throws {
        let dir = scratch("depth")
        defer { try? FileManager.default.removeItem(at: dir) }
        func nested(_ n: Int) -> String {
            #"{"a":"# + String(repeating: "[", count: n) + String(repeating: "]", count: n) + "}"
        }
        #expect(try verdict(nested(255), dir) == .confirmedAbsent)
        #expect(try verdict(nested(256), dir) == .unknown)
        #expect(try verdict(nested(300_000), dir) == .unknown)
    }
}

@Suite("GH #167 QA r4 (3) — a TRANSIENT open failure refuses this write only; a permanent one holds the session", .serialized)
@MainActor
struct CatalogProbeOpenFailureTests {

    @Test("EMFILE on every attempt: saveNow refuses with catalogUnavailable, nothing written, NO session hold; the next save lands")
    func transientFailureRefusesWithoutLatching() throws {
        let dir = scratch("emfile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let before = everyFile(dir)
        let inj = OpenFailureInjector(url: catalogURL(dir), errno: EMFILE)
        defer { inj.clear() }
        #expect(store.saveNow(records: [VideoRecord()]) == false)
        #expect(store.lastWriteError?.kind == "catalogUnavailable", "\(String(describing: store.lastWriteError))")
        #expect(store.writeHold == nil, "a transient open failure must not hold the session")
        #expect(store.writesDisabledReason == nil)
        #expect(everyFile(dir) == before)
        #expect(inj.count >= 2, "the probe must retry once before giving up (\(inj.count) attempt(s))")
        inj.clear()
        #expect(store.saveNow(records: [VideoRecord()]), "\(String(describing: store.lastWriteError))")
        #expect(store.lastWriteError == nil)
    }

    @Test("EMFILE on the FIRST attempt only: the retry succeeds and the save lands")
    func firstAttemptFailureIsRetried() throws {
        let dir = scratch("emfile_once")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let inj = OpenFailureInjector(url: catalogURL(dir), errno: EMFILE, times: 1)
        defer { inj.clear() }
        #expect(store.saveNow(records: [VideoRecord()]) == true, "\(String(describing: store.lastWriteError))")
        #expect(inj.count == 1)
        #expect(store.writeHold == nil)
    }

    @Test("EACCES: a permanent open failure still holds the session (unknown), as before")
    func permanentFailureHolds() throws {
        let dir = scratch("eacces")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let inj = OpenFailureInjector(url: catalogURL(dir), errno: EACCES)
        defer { inj.clear() }
        #expect(store.saveNow(records: [VideoRecord()]) == false)
        #expect(store.writeHold == .versionUnknown)
        #expect(store.lastWriteError?.kind == "writesDisabled")
    }

    @Test("write-queue gate: a save queued against a healthy file hits EMFILE on the queue — refused, not held, bytes untouched; the next save lands")
    func queuedGateTransientRefusesWithoutLatching() async throws {
        let dir = scratch("emfile_queue")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let url = catalogURL(dir)
        let before = try Data(contentsOf: url)
        store.testWriteDelay = 0.3
        store.saveAsync(records: [VideoRecord()])          // passes the main-actor gate, sleeps on the queue
        let inj = OpenFailureInjector(url: url, errno: EMFILE)
        defer { inj.clear() }
        await waitUntil(3) { store.lastWriteError != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.lastWriteError?.kind == "catalogUnavailable", "\(String(describing: store.lastWriteError))")
        #expect(store.writeHold == nil)
        #expect(try Data(contentsOf: url) == before)
        inj.clear()
        #expect(store.saveNow(records: [VideoRecord()]), "\(String(describing: store.lastWriteError))")
    }

    @Test("snapshot writers: EMFILE in refuseIfNewerCatalogOnDisk refuses the snapshot, no latch; cleared, it writes")
    func snapshotTransientRefusesWithoutLatching() async throws {
        let dir = scratch("emfile_snap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        let inj = OpenFailureInjector(url: catalogURL(dir), errno: EMFILE)
        defer { inj.clear() }
        let snap = dir.appendingPathComponent("catalog.pre-emfile.json").path
        #expect(store.writeSnapshot(records: [], toPath: snap) == false)
        #expect(await store.writeSnapshotAsync(records: [], toPath: snap) == false)
        #expect(store.writeHold == nil)
        #expect(!FileManager.default.fileExists(atPath: snap))
        inj.clear()
        #expect(store.writeSnapshot(records: [], toPath: snap))
    }

    @Test("load: a healthy catalog whose probe hits EMFILE loads its records, writes no sibling THIS launch, does not hold; the next save lands")
    func loadTransientSkipsSiblingsWithoutLatching() throws {
        let dir = scratch("emfile_load")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s0 = CatalogStore(directory: dir)
        let r = VideoRecord(); r.filename = "kept.mov"
        #expect(s0.saveNow(records: [r]))
        s0.relinquishLock()
        try FileManager.default.removeItem(at: dir.appendingPathComponent(CatalogGenerationSidecar.fileName))
        let before = everyFile(dir)
        let inj = OpenFailureInjector(url: catalogURL(dir), errno: EMFILE)
        defer { inj.clear() }
        let store = CatalogStore(directory: dir)
        let shown = store.load()
        #expect(shown.first?.filename == "kept.mov")
        #expect(store.writeHold == nil, "a transient failure at load must not hold the session")
        #expect(store.lastLoadOutcome == .loaded(fromBackup: false))
        #expect(everyFile(dir) == before, "load wrote a sibling it could not vouch for: \(Set(everyFile(dir).keys).symmetricDifference(before.keys).sorted())")
        inj.clear()
        #expect(store.saveNow(records: shown), "\(String(describing: store.lastWriteError))")
    }

    @Test("fail-closed control: an UNDECODABLE primary whose probe hits EMFILE holds (nothing can be verified)")
    func undecodableAndUnavailableHolds() throws {
        let dir = scratch("emfile_corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        try CatalogVersionUnknownRefusesTests.fixture("truncated").write(to: catalogURL(dir))
        let inj = OpenFailureInjector(url: catalogURL(dir), errno: EMFILE)
        defer { inj.clear() }
        let store = CatalogStore(directory: dir)
        _ = store.load()
        #expect(store.writeHold == .versionUnknown)
    }
}

@Suite("GH #167 QA r4 (7b) — the FileKey needs ctime: an in-place edit with its mtime restored is still re-scanned", .serialized)
@MainActor
struct CatalogProbeCacheKeyCompositionTests {

    @Test("same inode, same size, mtime restored with utimensat(2): only ctime differs — the cache must miss")
    func restoredMtimeStillInvalidates() throws {
        let dir = scratch("key_ctime")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = catalogURL(dir)
        let text = #"{"records":[],"version":\#(currentVersion)}"#
        try Data(text.utf8).write(to: url)
        var st = stat()
        #expect(stat(url.path, &st) == 0)
        let originalMtime = st.st_mtimespec
        let p0 = CatalogHeaderScanner.wholeFilePasses(for: url)
        #expect(CatalogSnapshot.header(at: url)?.version == .version(currentVersion))
        #expect(CatalogHeaderScanner.wholeFilePasses(for: url) - p0 == 1)

        usleep(20_000)   // let the clock move so the edit's mtime differs before we restore it
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: UInt64(text.utf8.count - 2))
        try h.write(contentsOf: Data("\(futureVersion)}".utf8))   // 7} → 8} — same size
        try h.close()
        var times = [originalMtime, originalMtime]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        var st2 = stat()
        #expect(stat(url.path, &st2) == 0)
        #expect(st2.st_ino == st.st_ino && st2.st_size == st.st_size, "fixture: same inode, same size")
        #expect(st2.st_mtimespec.tv_sec == originalMtime.tv_sec && st2.st_mtimespec.tv_nsec == originalMtime.tv_nsec, "fixture: mtime restored to the nanosecond")
        #expect(st2.st_ctimespec.tv_sec != st.st_ctimespec.tv_sec || st2.st_ctimespec.tv_nsec != st.st_ctimespec.tv_nsec, "fixture: ctime moved")

        #expect(CatalogSnapshot.header(at: url)?.version == .version(futureVersion), "a cache keyed without ctime served the stale verdict")
        #expect(CatalogHeaderScanner.wholeFilePasses(for: url) - p0 == 2)
    }
}
