import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateIntegrationTests
//
// End-to-end pipeline test: reconcile → snapshot → engine → catalog
// mutation. Builds a synthetic source folder + dest folder under /tmp,
// synthesizes VideoRecords, runs `relocateVolume`, then asserts the
// catalog and on-disk state are exactly what the plan promises.
//
// Hermetic — never touches /Volumes, never touches the real catalog
// in ~/Library/Application Support/VideoScan. Uses a CatalogStore
// pointed at a test directory.
//
// All tests are @MainActor because relocateVolume is.

@Suite(.serialized) @MainActor
struct RelocateIntegrationTests {

    // MARK: - Fixtures

    /// Build a unique /tmp test dir with source/, dest/, catalog/.
    private static func makeWorkspace() throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-integ-\(UUID().uuidString)",
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

    /// Write `count` deterministic bytes, return size + partial-MD5.
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

    /// Poll until the post-flight summary lands. Under the §3 queue
    /// (2026-05-31) `isRelocating` stays true through `.awaitingDone`
    /// until the user dismisses the summary, so the canonical "work is
    /// finished" signal is `pendingRelocateSummary != nil`. Same
    /// observable outcome as the pre-queue test (catalog mutated, dest
    /// written) — just a different waypoint.
    private func waitForRelocateDone(_ model: VideoScanModel, timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
    }

    // MARK: - Tests

    @Test
    func happyPath_migratesEveryReadyRecord_andStampsProvenance() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Three source files of varying sizes.
        let a = ws.source.appendingPathComponent("a.bin")
        let b = ws.source.appendingPathComponent("sub/b.bin")
        let c = ws.source.appendingPathComponent("c.bin")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let (sa, ha) = try writeFile(at: a, bytes: 1024)
        let (sb, hb) = try writeFile(at: b, bytes: 4096)
        let (sc, hc) = try writeFile(at: c, bytes: 32)

        let recs = [
            makeRecord(fullPath: a.path, size: sa, md5: ha),
            makeRecord(fullPath: b.path, size: sb, md5: hb),
            makeRecord(fullPath: c.path, size: sc, md5: hc)
        ]

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = recs
        // Mimic real flow: catalog.json on disk before mutation, so the
        // pre-relocate snapshot has something to copy.
        model.catalogStore.saveNow(records: recs)

        let options = RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        )
        model.relocateVolume(options)
        await waitForRelocateDone(model)

        // Every record's fullPath now points under dest, provenance stamped.
        for rec in model.records {
            #expect(rec.fullPath.hasPrefix(ws.dest.path))
            #expect(rec.originalFullPath != nil)
            #expect(rec.originalFullPath?.hasPrefix(ws.source.path) == true)
            #expect(FileManager.default.fileExists(atPath: rec.fullPath))
        }

        // Subdirectory layout preserved.
        let bDest = ws.dest.appendingPathComponent("sub/b.bin")
        #expect(FileManager.default.fileExists(atPath: bDest.path))

        // Dashboard counters reflect 3 successes.
        #expect(model.dashboard.relocateSucceeded == 3)
        #expect(model.dashboard.relocateSalvageFailed == 0)
        #expect(model.dashboard.relocateBytesCopied == sa + sb + sc)

        // Pre-relocate snapshot landed in the catalog dir.
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: ws.catalog.path)
        #expect(snapshots.contains(where: { $0.hasPrefix("catalog.pre-relocate.") }))
    }

    @Test
    func salvageFailed_recordedWhenSourceMissing_recordPathUnchanged() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // One good file + one record whose source path doesn't exist.
        let good = ws.source.appendingPathComponent("good.bin")
        let (sg, hg) = try writeFile(at: good, bytes: 256)
        let missingPath = ws.source.appendingPathComponent("missing.bin").path
        let recs = [
            makeRecord(fullPath: good.path, size: sg, md5: hg),
            makeRecord(fullPath: missingPath, size: 999, md5: "DEADBEEFDEADBEEFDEADBEEFDEADBEEF")
        ]

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = recs

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        ))
        await waitForRelocateDone(model)

        // Good record migrated.
        let goodRec = try #require(model.records.first { $0.filename == "good.bin" })
        #expect(goodRec.fullPath.hasPrefix(ws.dest.path))
        #expect(goodRec.originalFullPath == good.path)

        // Missing record: reconcile classifies it as manuallyDeleted
        // (no match on source, no match at dest, no plausible find).
        // Its fullPath stays pointing at the missing source.
        let missingRec = try #require(model.records.first { $0.filename == "missing.bin" })
        #expect(missingRec.archiveStage == .manuallyDeleted)
        #expect(missingRec.fullPath == missingPath)
        #expect(missingRec.originalFullPath == nil)
    }

    @Test
    func dryRun_makesNoChangesOnDisk_orInCatalogPaths() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        let src = ws.source.appendingPathComponent("x.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 512)
        let rec = makeRecord(fullPath: src.path, size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: true,
            skipAlreadyRelocated: true
        ))
        await waitForRelocateDone(model)

        // Record path UNCHANGED.
        #expect(rec.fullPath == src.path)
        #expect(rec.originalFullPath == nil)
        // No dest file was created.
        let destFile = ws.dest.appendingPathComponent("x.bin")
        #expect(!FileManager.default.fileExists(atPath: destFile.path))
    }

    @Test
    func adopted_skipsCopy_butStampsProvenanceAndRewritesPath() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Rick has already pre-copied this file to dest during triage.
        let src = ws.source.appendingPathComponent("pre.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 1024)
        let preCopiedDest = ws.dest.appendingPathComponent("pre.bin")
        try FileManager.default.copyItem(at: src, to: preCopiedDest)

        let rec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        // Delete the source so reconcile can't see it on the source
        // side — only the dest side has it. Without removing the source
        // the file would just be in Bucket A (ready) and we wouldn't
        // exercise the adopt path.
        try FileManager.default.removeItem(at: src)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        ))
        await waitForRelocateDone(model)

        #expect(rec.fullPath == preCopiedDest.path)
        #expect(rec.originalFullPath == src.path)
        #expect(model.dashboard.relocateAdopted == 1)
        #expect(model.dashboard.relocateSucceeded == 0)  // no copy needed
    }

    // Regression: a record left .salvageFailed by a PRIOR attempt (e.g. the
    // source drive was momentarily unreadable) must have that stale terminal
    // stage CLEARED when a later run successfully re-copies and verifies it.
    // Mirrors the real RicksBackups batch (2026-06-19): 97 files copied +
    // verified but stayed flagged "Salvage Failed" because the success path
    // rewrote fullPath/hash without resetting archiveStage. Note the record
    // has originalFullPath == nil — a failed attempt never set it — so it is
    // still in scope even with skipAlreadyRelocated: true.
    @Test
    func successClearsStaleSalvageFailedStageFromPriorAttempt() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        let src = ws.source.appendingPathComponent("recovered.bin")
        let (sz, md5) = try writeFile(at: src, bytes: 2048)
        let rec = makeRecord(fullPath: src.path, size: sz, md5: md5)
        // Simulate the leftover state from a prior failed salvage.
        rec.archiveStage = .salvageFailed
        rec.notes = "Migrate 2026-06-16T00:00:00Z: preRead — cannot open source: No such file or directory"

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]
        model.catalogStore.saveNow(records: [rec])

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        ))
        await waitForRelocateDone(model)

        // File moved + verified...
        #expect(rec.fullPath.hasPrefix(ws.dest.path))
        #expect(FileManager.default.fileExists(atPath: rec.fullPath))
        #expect(rec.originalFullPath == src.path)
        #expect(model.dashboard.relocateSucceeded == 1)
        #expect(model.dashboard.relocateSalvageFailed == 0)
        // ...and the stale terminal stage is cleared, with a recovery note.
        #expect(rec.archiveStage == .none)
        #expect(rec.notes.contains("salvage recovered"))
    }

    @Test
    func previouslyRelocatedRecordIsSkippedWhenOptionSet() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        let src = ws.source.appendingPathComponent("done.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 128)
        let rec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        rec.originalFullPath = "/Volumes/SomePastVolume/done.bin"
        rec.originVolume = "SomePastVolume"

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        ))
        await waitForRelocateDone(model)

        #expect(model.dashboard.relocateSkipped == 1)
        #expect(rec.fullPath == src.path)  // unchanged
    }
}
