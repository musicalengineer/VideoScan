import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateSummarySheetTests
//
// Coverage for the two fixes that landed alongside the post-Apply
// summary sheet:
//
//   1. Dry-run no longer mutates Bucket B/D/E disposition.
//   2. After a real run, `pendingRelocateSummary` is set BEFORE
//      `pendingRetireOffer`. The retire offer doesn't fire until the
//      summary's Done button calls `acknowledgeRelocateSummary()`.
//   3. Witness samples are extracted from the safelyRedundant entries
//      and presented as `source → witness` pairs in the summary.
//   4. Even very fast runs (Bucket E only, <100 ms wall clock) hold
//      the progress UI on screen for at least 800 ms before publishing
//      the summary (Fix 2 — min-visible delay).
//   5. relocate.log is opened and written to (Fix 3 — log routing was
//      a no-op before because PersistentLog needs start()).
//
// Hermetic — /tmp workspaces, never touches /Volumes or the real
// catalog dir.

@Suite(.serialized) @MainActor
struct RelocateSummarySheetTests {

    // MARK: - Fixtures (same pattern as the other Relocate test suites)

    private static func makeWorkspace() throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-summary-\(UUID().uuidString)",
                                    isDirectory: true)
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("dest")
        let catalog = root.appendingPathComponent("catalog")
        let fm = FileManager.default
        for url in [source, dest, catalog] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (root, source, dest, catalog)
    }

    @discardableResult
    private func writeFile(at url: URL, bytes: Int) throws -> (size: Int64, md5: String) {
        var buf = Data(count: bytes)
        for i in 0..<bytes { buf[i] = UInt8((i &* 17) % 251) }
        try buf.write(to: url)
        return (Int64(bytes), FileHasher.partialMD5(path: url.path))
    }

    private func makeRecord(fullPath: String, size: Int64, md5: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    /// Poll until the summary sheet binding is populated (the run has
    /// completed AND the min-visible pad has elapsed). Single timeout
    /// covers the worst case of an E-only run (~0.8 s) plus margin.
    private func waitForSummary(_ model: VideoScanModel, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)  // 25 ms
        }
    }

    // MARK: - 1. Dry-run mutation gate

    @Test
    func dryRun_doesNotMutateBucketBDEDispositions() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Three records exercising each catalog-only bucket:
        //
        //   B: file missing on disk → manuallyDeleted target
        //   D: file already at dest → adopted target
        //   E: file dup'd on a third (offline) catalogued volume
        //
        // All three would normally trigger archiveStage writes in
        // runRelocate. With the dry-run gate they must stay .none.

        // B — missing file. No disk presence anywhere.
        let bPath = ws.source.appendingPathComponent("b-missing.bin").path
        let bRec = makeRecord(fullPath: bPath, size: 1024,
                              md5: "DEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        // D — file already at dest, removed from source so reconcile
        // can't see it on the source side.
        let dSrc = ws.source.appendingPathComponent("d-already.bin")
        let (dSize, dHash) = try writeFile(at: dSrc, bytes: 512)
        let dDest = ws.dest.appendingPathComponent("d-already.bin")
        try FileManager.default.copyItem(at: dSrc, to: dDest)
        try FileManager.default.removeItem(at: dSrc)
        let dRec = makeRecord(fullPath: dSrc.path, size: dSize, md5: dHash)

        // E — file on source + duplicated on a third volume.
        let eSrc = ws.source.appendingPathComponent("e-dup.bin")
        let (eSize, eHash) = try writeFile(at: eSrc, bytes: 256)
        let eRec = makeRecord(fullPath: eSrc.path, size: eSize, md5: eHash)
        let witness = makeRecord(fullPath: "/Volumes/MyBook/e-dup.bin",
                                 size: eSize, md5: eHash)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [bRec, dRec, eRec, witness]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: true,                // <-- the headline of the test
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        // None of the three target records changed disposition. They
        // are all still .none. This is the regression the fix prevents.
        #expect(bRec.archiveStage == .none, "Bucket B record mutated in dry-run")
        #expect(dRec.archiveStage == .none, "Bucket D record mutated in dry-run")
        #expect(eRec.archiveStage == .none, "Bucket E record mutated in dry-run")
        // Paths likewise untouched.
        #expect(bRec.fullPath == bPath)
        #expect(dRec.fullPath == dSrc.path)
        #expect(eRec.fullPath == eSrc.path)
        // Provenance not stamped on the adopted candidate.
        #expect(dRec.originalFullPath == nil)

        // Summary title flag is set.
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.isDryRun == true)
        // Dry-run summary counts come from reconcile, so we should see
        // the three catalog-only bucket members reflected in the
        // dashboard counters that fed the summary.
        #expect(summary.manuallyDeletedCount == 1)
        #expect(summary.adoptedCount == 1)
        #expect(summary.safelyRedundantCount == 1)
        // Dry-run never fires retire.
        #expect(model.pendingRetireOffer == nil)
    }

    // MARK: - 2. Trigger ordering — summary before retire

    @Test
    func apply_setsPendingRelocateSummary_andDoesNotFireRetireUntilDone() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // One Bucket E record → after Apply, the source is 100%
        // disposed (.manuallyDeleted), so the §1B retire path SHOULD
        // be eligible. The fix makes sure it doesn't fire until the
        // summary is acknowledged.
        let src = ws.source.appendingPathComponent("safe.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 1024)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/safe.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.scanTargets = [CatalogScanTarget(searchPath: ws.source.path)]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        // Trigger ordering — summary present, retire offer NOT yet set.
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.isDryRun == false)
        #expect(summary.sourceVolumeRootPath == ws.source.path)
        #expect(model.pendingRetireOffer == nil,
                "Retire offer fired before summary was acknowledged")

        // Now simulate the user clicking Done. This is what the sheet
        // calls in its button handler.
        model.acknowledgeRelocateSummary()

        // Summary is cleared; retire offer IS now set.
        #expect(model.pendingRelocateSummary == nil)
        let offer = try #require(model.pendingRetireOffer)
        #expect(offer.volumeRootPath == ws.source.path)
        #expect(offer.recordCount == 1)
    }

    // MARK: - 3. Witness sample extraction

    @Test
    func summarySheet_witnessDisclosure_extractsSourceWitnessPairsFromBucketE() {
        // Pure helper test: build a synthetic reconcile result with two
        // Bucket E entries and confirm witnessSamples pulls the first
        // witness from each.
        let r1 = VideoRecord()
        r1.fullPath = "/Volumes/Old/a.bin"
        r1.filename = "a.bin"
        let r2 = VideoRecord()
        r2.fullPath = "/Volumes/Old/b.bin"
        r2.filename = "b.bin"

        let entries: [SafelyRedundantEntry] = [
            .init(rec: r1,
                  witnesses: ["/Volumes/MyBook/a.bin", "/Volumes/Backup/a.bin"],
                  totalWitnessCount: 2),
            .init(rec: r2,
                  witnesses: ["/Volumes/MyBook/b.bin"],
                  totalWitnessCount: 1)
        ]
        let samples = VideoScanModel.witnessSamples(from: entries, limit: 10)
        #expect(samples.count == 2)
        #expect(samples[0].sourcePath == "/Volumes/Old/a.bin")
        #expect(samples[0].witnessPath == "/Volumes/MyBook/a.bin")
        #expect(samples[1].sourcePath == "/Volumes/Old/b.bin")
        #expect(samples[1].witnessPath == "/Volumes/MyBook/b.bin")

        // Cap: 12 entries, limit 10 → only 10 samples.
        let many: [SafelyRedundantEntry] = (0..<12).map { i in
            let r = VideoRecord()
            r.fullPath = "/Volumes/Old/x\(i).bin"
            r.filename = "x\(i).bin"
            return .init(rec: r,
                         witnesses: ["/Volumes/MyBook/x\(i).bin"],
                         totalWitnessCount: 1)
        }
        let capped = VideoScanModel.witnessSamples(from: many, limit: 10)
        #expect(capped.count == 10)
    }

    // MARK: - 4. Minimum visible delay

    @Test
    func progressUI_shortRun_paddedToMin800ms() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Bucket E only: catalog-only mutation, no copies. Whole run is
        // typically <100 ms on a /tmp workspace. We measure the wall
        // clock from kickoff to summary-published to confirm the pad
        // fires.
        let src = ws.source.appendingPathComponent("blip.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 64)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/blip.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)

        let kickoff = Date()
        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)
        let elapsed = Date().timeIntervalSince(kickoff)

        // Allow a small jitter floor (~50 ms) under the 800 ms target
        // to account for scheduler imprecision on a busy host. The
        // important bit is "much longer than the actual work would
        // otherwise take", not literal 0.8s to the millisecond.
        #expect(elapsed >= 0.75, "Run finished in \(elapsed)s — min-visible pad isn't firing")
        // Sanity bound — should NOT be padded to many seconds.
        #expect(elapsed < 5.0)
    }

    // MARK: - 5. relocate.log routing

    @Test
    func relocateLog_writesToRelocateLogFile_notCatalogLog() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Capture the size of relocate.log before the run. PersistentLog
        // appends to ~/Library/Logs/VideoScan/relocate.log; the test
        // can't redirect that, but it CAN measure growth.
        let logURL = PersistentLog.logDir.appendingPathComponent("relocate.log")
        let sizeBefore: Int = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                  let n = attrs[.size] as? Int else { return 0 }
            return n
        }()

        // Drive a minimal run through. Bucket E is the cheapest
        // catalog-only path.
        let src = ws.source.appendingPathComponent("logged.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 32)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/logged.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)
        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        // Force any final flush.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // File must now exist + have grown.
        #expect(FileManager.default.fileExists(atPath: logURL.path),
                "relocate.log was not created at \(logURL.path)")

        let sizeAfter: Int = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                  let n = attrs[.size] as? Int else { return 0 }
            return n
        }()
        #expect(sizeAfter > sizeBefore,
                "relocate.log did not grow (\(sizeBefore) → \(sizeAfter)) — log routing broken")

        // Spot-check the contents: the per-session header is the
        // signature of Fix 3 (header was new in this change, so finding
        // it proves we landed there). We decode the whole file as UTF-8
        // rather than a tail slice — slicing mid-stream can land in the
        // middle of a multi-byte sequence (the log uses `─` separators,
        // 3 bytes each) and `String(data: encoding: .utf8)` returns nil
        // on those, which would falsely trip this assertion. File is
        // small (<100 KB even after a long suite); reading whole is cheap.
        let body: String = {
            guard let data = try? Data(contentsOf: logURL) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }()
        #expect(body.contains("Relocate session started"),
                "Header line missing — relocate.log open or header write failed")
    }
}
