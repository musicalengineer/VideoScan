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

private func same(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
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
        // Known fields still come from the typed properties.
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

        store.saveAsync(records: records)
        let g = store.currentGeneration
        for _ in 0..<200 where store.currentGeneration == g { try await Task.sleep(nanoseconds: 10_000_000) }
        top = try jsonObject(Data(contentsOf: catalogURL(dir)))
        #expect(same(top["futureTopLevel"], expectedTopUnknowns["futureTopLevel"]))

        let snap = dir.appendingPathComponent("catalog.pre-test.json").path
        #expect(store.writeSnapshot(records: records, toPath: snap))
        let snapTop = try jsonObject(Data(contentsOf: URL(fileURLWithPath: snap)))
        #expect(same(snapTop["futureScalar"], 42))
        let rec = try #require((snapTop["records"] as? [[String: Any]])?.first { $0["id"] as? String == fixedID1 })
        #expect(same(rec["futureList"], ["one", "two"]))
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
        let back = CatalogStore(directory: dir)
        let again = try #require(back.load().first)
        #expect(again.filename == "a.mov")
        if f.json.contains("detectedPeople") { #expect(again.detectedPeople == ["Donna"]) }
        if f.json.contains("suspectedPeople") { #expect(again.suspectedPeople == ["Rick"]) }
        if f.json.contains("sceneCaptions") { #expect(again.sceneCaptions.first?.text == "a beach") }
        if f.json.contains("originVolume") { #expect(again.originVolume == "Old") }
        if f.json.contains("masterArchive") { #expect(back.masterArchive?.volumeUUID == "TEST-UUID-167") }
        if f.json.contains("archiveFixity") { #expect(again.archiveFixity?.digest == "abc") }
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
