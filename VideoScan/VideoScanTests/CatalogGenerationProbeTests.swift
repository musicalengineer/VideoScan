//
//  CatalogGenerationProbeTests.swift
//  VideoScanTests
//
//  GH #165 — the OCC generation counter reset 248 → 1 on 2026-08-18 because
//  `CatalogSnapshot.headerProbe` read only the first 4 KB and the encoder
//  had put `generation` after 36 MB of records (JSONEncoder key order is
//  per-process random on this OS; CodingKeys order is not honoured).
//
//  Dimensions (CLAUDE.md feature-test checklist):
//    logic     -- probe finds the stamps wherever a legacy/foreign writer
//                 put them (records-first, tail-only, pretty-printed)
//    scale     -- 100k-record encode + probe inside a stated budget; the
//                 probe itself is O(8 KB) regardless of file size
//    isolation -- every test uses its own temp dir; poisoned-layout files
//                 (keys reachable from NEITHER end) and a regressed
//                 counter are fed to a fresh store
//    sensor    -- every production writer (saveNow, saveAsync,
//                 writeSnapshot, writeSnapshotAsync, exportCatalog, bundle
//                 encoder config) emits `generation` inside the first 4 KB;
//                 a regressed on-disk generation re-seeds above the sidecar
//

import XCTest
@testable import VideoScan

private final class WriteWaiter: CatalogStoreObserver {
    private(set) var writeCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var target = Int.max
    func catalogStoreDidWrite(_ store: CatalogStore) {
        writeCount += 1
        if writeCount >= target, let c = continuation {
            continuation = nil; target = Int.max; c.resume()
        }
    }
    func waitForWrites(_ n: Int) async {
        if writeCount >= n { return }
        target = n
        await withCheckedContinuation { continuation = $0 }
    }
}

final class CatalogGenerationProbeTests: XCTestCase {

    private var dir: URL!
    private var catalogURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CatalogGenerationProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        catalogURL = dir.appendingPathComponent("catalog.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// Fat records: enough bytes that a records-first layout pushes every
    /// trailing key well past the 4 KB head window.
    @MainActor
    private func fatRecords(_ n: Int, notesBytes: Int = 600) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"
            r.fullPath = "/Volumes/Test/clip_\(i).mov"
            r.notes = String(repeating: "n", count: notesBytes)
            return r
        }
    }

    /// The records array as JSON bytes, encoded the way the app does, so
    /// hand-built wrappers around it decode through the real VideoRecord
    /// decoder.
    @MainActor
    private func recordsArrayJSON(_ records: [VideoRecord]) throws -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return try enc.encode(records.map(VideoRecordDTO.init))
    }

    /// Byte offset of the FIRST `"generation":` in the file, or nil.
    private func generationOffset(in url: URL) throws -> Int? {
        let data = try Data(contentsOf: url)
        return data.range(of: Data("\"generation\":".utf8))?.lowerBound
    }

    private func sidecarValue() -> Int? {
        CatalogGenerationSidecar.read(besideCatalogAt: catalogURL)
    }

    // MARK: - Logic: the probe is layout-independent

    @MainActor
    func testProbeFindsGenerationInARecordsFirstFile() throws {
        // The exact layout of the live catalog.json on 2026-08-18.
        let body = try recordsArrayJSON(fatRecords(20))
        var data = Data("{\"records\":".utf8)
        data.append(body)
        data.append(Data(",\"savedAt\":\"2026-08-18T20:23:00Z\",\"generation\":248,\"version\":6,\"savedFromHost\":\"RicksM4\"}".utf8))
        try data.write(to: catalogURL)
        XCTAssertGreaterThan(try XCTUnwrap(generationOffset(in: catalogURL)), 4096,
                             "fixture must put generation PAST the head window")

        let probe = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        XCTAssertEqual(probe.generation, 248)
        XCTAssertEqual(probe.version, 6)

        // And load() baselines on it — this is the line that reset to 1.
        let store = CatalogStore(directory: dir)
        XCTAssertEqual(store.load().count, 20)
        XCTAssertEqual(store.loadedGeneration, 248)
        XCTAssertNil(store.lastGenerationAnomaly)
        XCTAssertTrue(store.saveNow(records: []))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 249)
    }

    @MainActor
    func testProbeFindsGenerationOnlyInTheTail() throws {
        // python json.dump of a pre-generation file appends the new key LAST.
        let body = try recordsArrayJSON(fatRecords(20))
        var data = Data("{\"version\": 6, \"records\": ".utf8)
        data.append(body)
        data.append(Data(", \"savedFromHost\": \"py\", \"generation\": 23}".utf8))
        try data.write(to: catalogURL)

        let probe = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        XCTAssertEqual(probe.version, 6, "version from the head")
        XCTAssertEqual(probe.generation, 23, "generation from the tail")
    }

    func testProbeReadsPrettyPrintedLayouts() throws {
        try Data("{\n  \"generation\" : 5,\n  \"version\" : 6,\n  \"records\" : [\n\n  ]\n}\n".utf8)
            .write(to: catalogURL)
        let probe = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        XCTAssertEqual(probe.generation, 5)
        XCTAssertEqual(probe.version, 6)
    }

    func testProbeSurvivesAMultibyteCharacterSplitAtTheWindowEdge() throws {
        // 23 ASCII bytes then 2-byte "é"s: byte 4096 falls MID-character.
        // String(data:encoding:.utf8) returns nil for such a window; the
        // probe must decode lossily and still find the tail stamp.
        var data = Data("{\"records\":[{\"notes\":\"x".utf8)
        data.append(Data(String(repeating: "é", count: 3000).utf8))
        data.append(Data("\"}],\"generation\":9,\"version\":6}".utf8))
        try data.write(to: catalogURL)
        XCTAssertNil(String(data: data.prefix(4096), encoding: .utf8),
                     "fixture must really split a character at the window edge")
        let probe = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        XCTAssertEqual(probe.generation, 9)
    }

    func testProbeIsNilForMissingFileAndForAFileWithNoStamps() throws {
        XCTAssertNil(CatalogSnapshot.headerProbe(at: catalogURL))
        try Data("{\"records\":[]}".utf8).write(to: catalogURL)
        XCTAssertNil(CatalogSnapshot.headerProbe(at: catalogURL),
                     "pre-generation catalog: nil, not 0 — callers distinguish the two")
    }

    // MARK: - Isolation: poisoned layouts never silently downgrade

    @MainActor
    func testLoadUsesDecodedGenerationWhenProbeMissesBothWindowsAndLogsAnomaly() throws {
        // Pathological layout: stamps after the records AND buried behind a
        // 6 KB host string, so they are > 4 KB from BOTH ends.
        let body = try recordsArrayJSON(fatRecords(20))
        var data = Data("{\"records\":".utf8)
        data.append(body)
        data.append(Data(",\"generation\":31,\"version\":6,\"savedFromHost\":\"".utf8))
        data.append(Data(String(repeating: "h", count: 6000).utf8))
        data.append(Data("\"}".utf8))
        try data.write(to: catalogURL)
        XCTAssertNil(CatalogSnapshot.headerProbe(at: catalogURL), "fixture must defeat the probe")

        let store = CatalogStore(directory: dir)
        XCTAssertEqual(store.load().count, 20)
        XCTAssertEqual(store.loadedGeneration, 31, "the full decode is the truth when the probe cannot see")
        let anomaly = try XCTUnwrap(store.lastGenerationAnomaly, "a probe miss on a stamped file must be recorded")
        XCTAssertTrue(anomaly.contains("decodes with generation 31"), anomaly)

        XCTAssertTrue(store.saveNow(records: []))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 32,
                       "and the rewrite is back in canonical layout, readable from the head")
        XCTAssertLessThan(try XCTUnwrap(generationOffset(in: catalogURL)), 4096)
    }

    @MainActor
    func testRegressedOnDiskGenerationIsLoggedAndReseededAboveTheSidecar() throws {
        // Session 1: a healthy catalog at 50 → save → 51. Sidecar = 51.
        try Data("{\"version\":6,\"generation\":50,\"records\":[]}".utf8).write(to: catalogURL)
        let s1 = CatalogStore(directory: dir)
        _ = s1.load()
        XCTAssertTrue(s1.saveNow(records: []))
        XCTAssertEqual(sidecarValue(), 51)
        s1.relinquishLock()

        // The incident: the file on disk now says generation 3.
        try Data("{\"version\":6,\"generation\":3,\"records\":[]}".utf8).write(to: catalogURL)

        // Session 2 must notice, say so, and NOT continue 3, 4, 5…
        let s2 = CatalogStore(directory: dir)
        _ = s2.load()
        XCTAssertEqual(s2.loadedGeneration, 3, "OCC comparison value stays honest about what is on disk")
        XCTAssertEqual(s2.generationFloor, 51)
        let anomaly = try XCTUnwrap(s2.lastGenerationAnomaly)
        XCTAssertTrue(anomaly.contains("regressed"), anomaly)
        XCTAssertTrue(anomaly.contains("52"), "must name the re-seed target: \(anomaly)")

        XCTAssertTrue(s2.saveNow(records: []))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 52,
                       "next write resumes above the high-water mark, not at 4")
        XCTAssertEqual(sidecarValue(), 52)

        // A foreign writer bumping the (regressed) file is STILL detected.
        try Data("{\"version\":6,\"generation\":53,\"records\":[]}".utf8).write(to: catalogURL)
        XCTAssertFalse(s2.saveNow(records: []), "staleness detection must survive the re-seed")
        XCTAssertEqual(s2.lastWriteError?.kind, "stale")
    }

    @MainActor
    func testSidecarBootstrapsFromSiblingCatalogFilesOnFirstRun() throws {
        // No sidecar yet; catalog.json says 2 but a safety copy in the same
        // directory (records-first layout, like the real ones) says 77.
        try Data("{\"version\":6,\"generation\":2,\"records\":[]}".utf8).write(to: catalogURL)
        let body = try recordsArrayJSON(fatRecords(20))
        var snap = Data("{\"records\":".utf8)
        snap.append(body)
        snap.append(Data(",\"generation\":77,\"version\":6}".utf8))
        try snap.write(to: dir.appendingPathComponent("catalog.pre-relocate.2026-08-18T18-45-48Z.json"))
        // Decoys the bootstrap must ignore.
        try Data("{\"generation\":9999}".utf8).write(to: dir.appendingPathComponent("catalog-write-errors.jsonl"))
        try Data("{\"generation\":8888}".utf8).write(to: dir.appendingPathComponent("notes.json"))
        XCTAssertNil(sidecarValue())

        let store = CatalogStore(directory: dir)
        _ = store.load()
        XCTAssertEqual(store.generationFloor, 77)
        XCTAssertEqual(sidecarValue(), 77, "bootstrap persists the mark so the directory scan runs once")
        XCTAssertTrue(store.saveNow(records: []))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 78)
    }

    @MainActor
    func testHandSeededSidecarIsHonoured() throws {
        // The operator affordance: a one-line text file beside catalog.json.
        try Data("{\"version\":6,\"generation\":9,\"records\":[]}".utf8).write(to: catalogURL)
        try Data("248\n".utf8).write(to: CatalogGenerationSidecar.url(besideCatalogAt: catalogURL))
        let store = CatalogStore(directory: dir)
        _ = store.load()
        XCTAssertEqual(store.generationFloor, 248)
        XCTAssertTrue(store.saveNow(records: []))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 249)
    }

    @MainActor
    func testMissingCatalogStillHonoursTheSidecarFloor() throws {
        // catalog.json gone (manual cleanup, a restore that forgot it…) but
        // the mark remains: the first save must not restart at 1.
        try Data("17\n".utf8).write(to: CatalogGenerationSidecar.url(besideCatalogAt: catalogURL))
        let store = CatalogStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(store.lastLoadOutcome, .missing)
        XCTAssertTrue(store.saveNow(records: []))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 18)
    }

    @MainActor
    func testSidecarNeverDecrements() throws {
        CatalogGenerationSidecar.recordMax(40, besideCatalogAt: catalogURL)
        XCTAssertEqual(CatalogGenerationSidecar.recordMax(12, besideCatalogAt: catalogURL), 40)
        XCTAssertEqual(sidecarValue(), 40)
        XCTAssertEqual(CatalogGenerationSidecar.recordMax(41, besideCatalogAt: catalogURL), 41)
        XCTAssertEqual(sidecarValue(), 41)
    }

    // MARK: - Sensor: every writer, generation inside the first 4 KB

    @MainActor
    func testEveryCatalogWriterEmitsGenerationInsideTheFirst4KB() async throws {
        let records = fatRecords(40)   // ~30 KB of records: the head window cannot hold them
        try Data("{\"version\":6,\"generation\":41,\"records\":[]}".utf8).write(to: catalogURL)
        let store = CatalogStore(directory: dir)
        _ = store.load()

        func assertHeader(_ url: URL, generation: Int, _ label: String,
                          file: StaticString = #filePath, line: UInt = #line) throws {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 4096, "\(label): fixture must be bigger than the head window", file: file, line: line)
            let off = try XCTUnwrap(generationOffset(in: url), "\(label): no generation key at all", file: file, line: line)
            XCTAssertLessThan(off, 4096, "\(label): generation at byte \(off) — outside the head window", file: file, line: line)
            let head = String(decoding: try Data(contentsOf: url).prefix(64), as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("{\"version\":6,\"generation\":\(generation),"),
                          "\(label): canonical header order, got \(head)", file: file, line: line)
            XCTAssertEqual(CatalogSnapshot.headerProbe(at: url)?.generation, generation, label, file: file, line: line)
        }

        // 1. saveNow
        XCTAssertTrue(store.saveNow(records: records))
        try assertHeader(catalogURL, generation: 42, "saveNow")

        // 2. saveAsync
        let waiter = WriteWaiter(); store.observer = waiter
        store.saveAsync(records: records)
        await waiter.waitForWrites(1)
        try assertHeader(catalogURL, generation: 43, "saveAsync")

        // 3. writeSnapshot — carries the REAL generation, never 0
        let snap = dir.appendingPathComponent("catalog.pre-merge.test.json")
        XCTAssertTrue(store.writeSnapshot(records: records, toPath: snap.path))
        try assertHeader(snap, generation: 43, "writeSnapshot")

        // 4. writeSnapshotAsync
        let snapAsync = dir.appendingPathComponent("catalog.pre-dup.test.json")
        let ok = await store.writeSnapshotAsync(records: records, toPath: snapAsync.path)
        XCTAssertTrue(ok)
        try assertHeader(snapAsync, generation: 43, "writeSnapshotAsync")

        // 5. Catalog export (pretty-printed + sortedKeys encoder, generation 0 by design)
        let model = VideoScanModel()
        model.records = records
        let export = dir.appendingPathComponent("export.json")
        try model.exportCatalog(to: export)
        try assertHeader(export, generation: 0, "exportCatalog")

        // 6. Bundle export's exact encoder configuration (the full writeBundle
        //    reads the real POIStorage tree — isolation rule — so drive the
        //    DTO with its encoder, same precedent as CatalogScopeExportTests).
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let bundleCatalog = dir.appendingPathComponent("bundle-catalog.json")
        try CatalogSnapshotDTO(CatalogSnapshot(records: records, savedFromHost: "h"))
            .encoded(using: enc).write(to: bundleCatalog)
        try assertHeader(bundleCatalog, generation: 0, "bundle encoder config")

        // Everything above must still DECODE through the real decoder.
        for url in [catalogURL!, snap, snapAsync, export, bundleCatalog] {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let back = try dec.decode(CatalogSnapshot.self, from: Data(contentsOf: url))
            XCTAssertEqual(back.records.count, 40, url.lastPathComponent)
        }
    }

    @MainActor
    func testSnapshotsCarryTheCurrentGenerationAndMasterArchive() async throws {
        try Data("{\"version\":6,\"generation\":41,\"records\":[]}".utf8).write(to: catalogURL)
        let store = CatalogStore(directory: dir)
        _ = store.load()
        store.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                                      rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive",
                                                      volumeUUID: "ABCD")
        let snap = dir.appendingPathComponent("catalog.pre-x.json")
        XCTAssertTrue(store.writeSnapshot(records: [], toPath: snap.path))
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: snap)?.generation, 41)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(CatalogSnapshot.self, from: Data(contentsOf: snap))
        XCTAssertEqual(back.generation, 41)
        XCTAssertEqual(back.masterArchive?.volumeUUID, "ABCD")
        XCTAssertEqual(back.version, CatalogSnapshot.currentVersion)

        let snap2 = dir.appendingPathComponent("catalog.pre-y.json")
        let ok = await store.writeSnapshotAsync(records: [], toPath: snap2.path)
        XCTAssertTrue(ok)
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: snap2)?.generation, 41)
    }

    /// The encoder's own options still govern the records and the scalar
    /// header values (date strategy), while the wrapper order is fixed.
    @MainActor
    func testEncoderStrategiesApplyInsideTheFixedHeader() throws {
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        let dto = CatalogSnapshotDTO(version: 6, generation: 3, savedAt: when, records: [],
                                     savedFromHost: "Mac \"Studio\" \\ ünïcode")
        let iso = JSONEncoder(); iso.dateEncodingStrategy = .iso8601
        let text = String(decoding: try dto.encoded(using: iso), as: UTF8.self)
        XCTAssertEqual(text, "{\"version\":6,\"generation\":3,\"savedAt\":\"2025-06-15T15:06:40Z\",\"savedFromHost\":\"Mac \\\"Studio\\\" \\\\ ünïcode\",\"records\":[]}")

        let secs = JSONEncoder(); secs.dateEncodingStrategy = .secondsSince1970
        let text2 = String(decoding: try dto.encoded(using: secs), as: UTF8.self)
        XCTAssertTrue(text2.hasPrefix("{\"version\":6,\"generation\":3,\"savedAt\":1750000000"), text2)
    }

    // MARK: - Scale

    @MainActor
    func testHundredThousandRecordEncodeAndProbeWithinBudget() throws {
        // 100k slim records (the M4 catalog is ~8.8k fat ones; this is the
        // checklist's scale bar). Budget: encode+write ≤ 20 s in Debug,
        // probe ≤ 50 ms because it reads 8 KB whatever the file size.
        let records: [VideoRecord] = (0..<100_000).map { i in
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"
            r.fullPath = "/Volumes/Big/clip_\(i).mov"
            return r
        }
        let store = CatalogStore(directory: dir)
        let t0 = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(store.saveNow(records: records))
        let encodeWrite = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertLessThan(encodeWrite, 20.0, "100k-record save took \(encodeWrite)s")

        let size = try FileManager.default.attributesOfItem(atPath: catalogURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 10_000_000, "scale fixture should be tens of MB, got \(size)")

        let t1 = CFAbsoluteTimeGetCurrent()
        let probe = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        let probeTime = CFAbsoluteTimeGetCurrent() - t1
        XCTAssertEqual(probe.generation, 1)
        XCTAssertLessThan(probeTime, 0.05, "probe of a \(size)-byte file took \(probeTime)s — it must not scale with file size")
        XCTAssertLessThan(try XCTUnwrap(generationOffset(in: catalogURL)), 64)
    }
}
