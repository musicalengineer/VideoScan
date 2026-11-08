// RelocateRunCharacterizationTests.swift
// Characterization of one Migrate (Relocate Volume) run end to end —
// `VideoScanModel.runRelocate(scope:options:jobID:)`, written against the code
// before its 2026-11-07 decomposition and green on it. Each test pins what a
// person can check afterwards: where every file is (source never touched,
// nothing half-written at the destination), what each record says (path,
// provenance, stage, note), the dashboard counters, the job's status, the
// summary sheet's numbers, and the console line that explains it.
//
// Paths covered here (the refusal and failure paths first):
//   a destination collision · an unreadable source (not matched, not marked) · a read-only destination
//   folder · a source missing at reconcile (Bucket B) · a cancel during
//   reconcile · a cancel between files · a dry run · a source-side move
//   (Bucket C) · an extensionless recovered file · a clean run.
// Already pinned elsewhere and re-run with this suite: adoption (Bucket D),
// force-retry, the snapshot-before-first-mutation order
// (RelocateIntegrationTests); safely redundant (Bucket E) and its re-proof
// (RelocateSafelyRedundantTests, RelocateWitnessLivenessTests); source/dest
// overlap refusals (RelocateSourceDestGuardTests); the queue (RelocateQueueTests).
//
// Hermetic: a fresh /tmp workspace per test, a CatalogStore inside it; never
// /Volumes, never App Support.

import Foundation
import Testing
@testable import VideoScan

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct RelocateRunCharacterizationTests {

    private struct Workspace {
        let root: URL, source: URL, dest: URL, catalog: URL
        func cleanup() {
            // Undo any permission a test set, then remove.
            if let e = FileManager.default.enumerator(atPath: root.path) {
                for case let rel as String in e {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: root.appendingPathComponent(rel).path)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func makeWorkspace() throws -> Workspace {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-char-\(UUID().uuidString)", isDirectory: true)
        let ws = Workspace(root: root, source: root.appendingPathComponent("source"),
                           dest: root.appendingPathComponent("dest"), catalog: root.appendingPathComponent("catalog"))
        for url in [ws.source, ws.dest, ws.catalog] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return ws
    }

    @discardableResult
    private func writeFile(at url: URL, bytes: Int, seed: Int = 17) throws -> (size: Int64, md5: String) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var buf = Data(count: bytes)
        for i in 0..<bytes { buf[i] = UInt8((i &* seed) % 251) }
        try buf.write(to: url)
        return (Int64(bytes), FileHasher.partialMD5(path: url.path))
    }

    private func makeRecord(_ url: URL, size: Int64, md5: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = url.lastPathComponent
        r.fullPath = url.path
        r.directory = url.deletingLastPathComponent().path
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    private func makeModel(_ ws: Workspace, _ recs: [VideoRecord]) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = recs
        model.catalogStore.saveNow(records: recs)
        return model
    }

    private func options(_ ws: Workspace, dryRun: Bool = false) -> RelocateOptions {
        RelocateOptions(sourceVolumeRootPath: ws.source.path, destinationRoot: ws.dest,
                        maxConcurrency: 1, dryRun: dryRun, skipAlreadyRelocated: true)
    }

    /// Await the runner; returns the job's final status.
    private func runToEnd(_ model: VideoScanModel) async throws -> RelocateJobStatus? {
        let runner = try #require(model.relocateRunnerTask, "relocateVolume installs its runner synchronously")
        await runner.value
        return model.relocateQueue.last?.status
    }

    private func console(_ model: VideoScanModel) async -> String {
        try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce
        return model.dashboard.consoleLines.joined(separator: "\n")
    }

    private func snapshots(_ ws: Workspace) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ws.catalog.path)) ?? [])
            .filter { $0.hasPrefix("catalog.pre-relocate.") }
    }

    private func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: refusal and failure paths

    @Test func aDestinationCollisionFailsTheCopyAndTouchesNeitherFile() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("x.bin")
        let (size, md5) = try writeFile(at: src, bytes: 4096)
        let occupant = ws.dest.appendingPathComponent("x.bin")
        try writeFile(at: occupant, bytes: 1000, seed: 31)          // a different file already there
        let srcBytes = contents(src), occupantBytes = contents(occupant)
        let rec = makeRecord(src, size: size, md5: md5)
        let model = makeModel(ws, [rec])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(rec.fullPath == src.path && rec.originalFullPath == nil, "the record keeps its source path")
        #expect(rec.archiveStage == .salvageFailed)
        #expect(rec.notes.contains("Migrate ") && rec.notes.contains("destination already exists: \(occupant.path)"), "\(rec.notes)")
        #expect(contents(src) == srcBytes, "the source is never touched")
        #expect(contents(occupant) == occupantBytes, "the file already at the destination is never overwritten")
        #expect(model.dashboard.relocateSalvageFailed == 1 && model.dashboard.relocateSucceeded == 0)
        #expect(model.dashboard.relocateCompleted == 1)
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.salvageFailedCount == 1 && summary.salvageFailedPaths == [src.path] && summary.succeededCount == 0)
        #expect(summary.snapshotPath != nil, "a real run snapshots the catalog first")
        let text = await console(model)
        #expect(text.contains("✗ SALVAGE FAILED at "), "\(text)")
        #expect(text.contains("destination already exists"))
    }

    /// A source that cannot be read cannot be matched at reconcile (no
    /// partial hash): it is NOT copied, NOT marked "source file not found"
    /// (it is still at its path), and the run says so once.
    @Test func anUnreadableSourceIsNeitherCopiedNorMarkedAndTheRunSaysSo() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("locked.bin")
        let (size, md5) = try writeFile(at: src, bytes: 2048)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
        let rec = makeRecord(src, size: size, md5: md5)
        let model = makeModel(ws, [rec])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(rec.fullPath == src.path && rec.originalFullPath == nil)
        #expect(rec.archiveStage == .none, "never marked missing while it is still there: \(rec.archiveStage)")
        #expect(FileManager.default.fileExists(atPath: src.path), "the source stays")
        #expect(!FileManager.default.fileExists(atPath: ws.dest.appendingPathComponent("locked.bin").path))
        #expect(model.dashboard.relocateSalvageFailed == 0 && model.dashboard.relocateSucceeded == 0)
        #expect(model.dashboard.relocateManuallyDeleted == 0 && model.dashboard.relocateBucketBStillThere == 1)
        #expect(model.dashboard.relocateCompleted == 1)
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.stillThereCount == 1 && summary.salvageFailedPaths.isEmpty)
        let text = await console(model)
        #expect(text.contains("row(s) Migrate could not match were NOT marked \"source file not found\" and not copied"), "\(text)")
    }

    @Test func aReadOnlyDestinationFolderFailsTheCopyAndLeavesNothingBehind() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("sub/y.bin")
        let (size, md5) = try writeFile(at: src, bytes: 4096)
        let destSub = ws.dest.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: destSub, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destSub.path)
        let srcBytes = contents(src)
        let rec = makeRecord(src, size: size, md5: md5)
        let model = makeModel(ws, [rec])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(rec.fullPath == src.path && rec.originalFullPath == nil)
        #expect(rec.archiveStage == .salvageFailed)
        #expect(rec.notes.contains("Migrate "), "\(rec.notes)")
        #expect(contents(src) == srcBytes)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: destSub.path)) ?? []).isEmpty,
                "no partial copy at the destination")
        #expect(model.dashboard.relocateSalvageFailed == 1 && model.dashboard.relocateBytesCopied == 0)
        #expect(model.pendingRelocateSummary?.salvageFailedPaths == [src.path])
    }

    @Test func aSourceMissingAtReconcileIsMarkedAndNothingIsCopied() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let good = ws.source.appendingPathComponent("good.bin")
        let (gs, gm) = try writeFile(at: good, bytes: 512)
        let missing = ws.source.appendingPathComponent("gone.bin")
        let goodRec = makeRecord(good, size: gs, md5: gm)
        let goneRec = makeRecord(missing, size: 777, md5: "DEADBEEFDEADBEEFDEADBEEFDEADBEEF")
        let model = makeModel(ws, [goodRec, goneRec])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(goneRec.archiveStage == .manuallyDeleted && goneRec.fullPath == missing.path && goneRec.originalFullPath == nil)
        #expect(!FileManager.default.fileExists(atPath: ws.dest.appendingPathComponent("gone.bin").path))
        #expect(goodRec.fullPath == ws.dest.appendingPathComponent("good.bin").path && goodRec.originalFullPath == good.path)
        #expect(FileManager.default.fileExists(atPath: good.path), "a copied source stays on the source drive")
        #expect(model.dashboard.relocateManuallyDeleted == 1 && model.dashboard.relocateSucceeded == 1)
        #expect(model.dashboard.relocateCompleted == model.dashboard.relocateTotal)
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.manuallyDeletedCount == 1 && summary.succeededCount == 1 && summary.bytesCopied == gs)
    }

    // MARK: cancel

    @Test func aCancelDuringReconcileAppliesNothing() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("c.bin")
        let (size, md5) = try writeFile(at: src, bytes: 1024)
        let missing = ws.source.appendingPathComponent("missing.bin")
        let rec = makeRecord(src, size: size, md5: md5)
        let goneRec = makeRecord(missing, size: 9, md5: "00000000000000000000000000000000")
        let model = makeModel(ws, [rec, goneRec])

        model.relocateVolume(options(ws))
        model.relocateRunnerTask?.cancel()                 // lands before the reconcile check
        let status = try await runToEnd(model)

        #expect(status == .canceled)
        #expect(model.pendingRelocateSummary == nil, "no summary after a cancel")
        #expect(rec.fullPath == src.path && rec.originalFullPath == nil && rec.notes.isEmpty)
        #expect(goneRec.archiveStage != .manuallyDeleted, "not even the zero-copy buckets are applied")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: ws.dest.path)) ?? []).isEmpty)
        #expect(snapshots(ws).isEmpty, "no snapshot: nothing was about to change")
        let text = await console(model)
        #expect(text.contains("Migrate canceled during reconcile — no changes applied."), "\(text)")
    }

    @Test func aCancelBetweenFilesStopsCleanlyAndKeepsWhatLanded() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        var recs: [VideoRecord] = []
        for i in 0..<5 {
            let url = ws.source.appendingPathComponent("f\(i).bin")
            let (s, m) = try writeFile(at: url, bytes: 4 * 1024 * 1024, seed: 17 + i)
            recs.append(makeRecord(url, size: s, md5: m))
        }
        let sources = recs.map(\.fullPath)
        let model = makeModel(ws, recs)

        model.relocateVolume(options(ws))
        let jobID = try #require(model.relocateQueue.last?.id)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, model.dashboard.relocateSucceeded < 1 { await Task.yield() }
        #expect(model.cancelRelocateJob(id: jobID))
        let status = try await runToEnd(model)

        #expect(status == .canceled)
        #expect(model.pendingRelocateSummary == nil, "no summary sheet after a cancel")
        let moved = recs.filter { $0.fullPath.hasPrefix(ws.dest.path) }
        #expect(moved.count == model.dashboard.relocateSucceeded)
        #expect(moved.count >= 1 && moved.count < 5, "stopped between files: \(moved.count)")
        for (rec, src) in zip(recs, sources) {
            #expect(FileManager.default.fileExists(atPath: src), "every source stays: \(src)")
            if rec.fullPath.hasPrefix(ws.dest.path) {
                #expect(FileManager.default.fileExists(atPath: rec.fullPath) && rec.originalFullPath == src)
            } else {
                #expect(rec.fullPath == src && rec.originalFullPath == nil && rec.archiveStage != .salvageFailed)
            }
        }
        let text = await console(model)
        #expect(text.contains("Migrate canceled — stopped after \(moved.count) of 5 file(s)."), "\(text)")
    }

    // MARK: dry run

    @Test func aDryRunPaintsTheCountsAndChangesNothing() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("d.bin")
        let (size, md5) = try writeFile(at: src, bytes: 512)
        let missing = ws.source.appendingPathComponent("gone.bin")
        let rec = makeRecord(src, size: size, md5: md5)
        let goneRec = makeRecord(missing, size: 5, md5: "11111111111111111111111111111111")
        let model = makeModel(ws, [rec, goneRec])

        model.relocateVolume(options(ws, dryRun: true))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(rec.fullPath == src.path && rec.originalFullPath == nil && rec.notes.isEmpty)
        #expect(goneRec.archiveStage != .manuallyDeleted, "a dry run marks nothing")
        #expect(model.dashboard.relocateManuallyDeleted == 1 && model.dashboard.relocateCompleted == 1)
        #expect(model.dashboard.relocateSucceeded == 0)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: ws.dest.path)) ?? []).isEmpty)
        #expect(snapshots(ws).isEmpty)
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.isDryRun && summary.snapshotPath == nil && summary.manuallyDeletedCount == 1)
        #expect(summary.provenBackupCount == 0 && summary.provenAdoptedCount == 0, "a dry run proves nothing")
        let text = await console(model)
        #expect(text.contains("[DRY RUN] No files copied. Would have migrated 1 record(s)."), "\(text)")
    }

    // MARK: rewrites before the copy

    @Test func aSourceSideMoveIsFollowedThenCopied() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let recorded = ws.source.appendingPathComponent("old/m.bin")
        let actual = ws.source.appendingPathComponent("new/m.bin")
        let (size, md5) = try writeFile(at: actual, bytes: 3000)
        let rec = makeRecord(recorded, size: size, md5: md5)
        let model = makeModel(ws, [rec])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(model.dashboard.relocateSourceMoves == 1, "\(model.dashboard.relocateSourceMoves)")
        #expect(rec.notes.contains("source-side move detected"), "\(rec.notes)")
        #expect(rec.fullPath == ws.dest.appendingPathComponent("new/m.bin").path, "\(rec.fullPath)")
        #expect(rec.originalFullPath == actual.path, "provenance names where the file really was")
        #expect(FileManager.default.fileExists(atPath: actual.path))
        #expect(model.pendingRelocateSummary?.sourceMovesCount == 1)
    }

    @Test func anExtensionlessRecoveredFileLandsWithItsInferredExtension() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("clip")
        let (size, md5) = try writeFile(at: src, bytes: 2048)
        let rec = makeRecord(src, size: size, md5: md5)
        rec.container = "mov,mp4,m4a,3gp,3g2,mj2"
        let model = makeModel(ws, [rec])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        let landed = ws.dest.appendingPathComponent("clip.mov")
        #expect(rec.fullPath == landed.path, "\(rec.fullPath)")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(FileManager.default.fileExists(atPath: src.path), "the source is never renamed")
        let text = await console(model)
        #expect(text.contains("+ adding inferred extension .mov (no extension; container \"mov,mp4,m4a,3gp,3g2,mj2\")"), "\(text)")
    }

    // MARK: a clean run

    @Test func aCleanRunCopiesVerifiesAndPublishesTheSummary() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let a = ws.source.appendingPathComponent("a.bin"), b = ws.source.appendingPathComponent("deep/b.bin")
        let (sa, ma) = try writeFile(at: a, bytes: 1500)
        let (sb, mb) = try writeFile(at: b, bytes: 2500, seed: 23)
        let ra = makeRecord(a, size: sa, md5: ma), rb = makeRecord(b, size: sb, md5: mb)
        let model = makeModel(ws, [ra, rb])

        model.relocateVolume(options(ws))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(model.relocateQueue.last?.summary != nil, "the summary is attached to the job")
        for (rec, src) in [(ra, a), (rb, b)] {
            #expect(rec.originalFullPath == src.path && rec.fullPath.hasPrefix(ws.dest.path))
            #expect(contents(URL(fileURLWithPath: rec.fullPath)) == contents(src), "verified copy")
            #expect(FileManager.default.fileExists(atPath: src.path), "Migrate never removes the source")
            #expect(rec.archiveStage == .none)
        }
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.succeededCount == 2 && summary.bytesCopied == sa + sb && summary.salvageFailedPaths.isEmpty)
        #expect(summary.snapshotPath != nil && snapshots(ws).count == 1)
        #expect(model.dashboard.relocateCompleted == 2 && model.dashboard.relocateTotal == 2)
        let text = await console(model)
        #expect(text.contains("[1/2] "), "\(text)")
        #expect(text.contains("✓ copied 1500 bytes") || text.contains("✓ copied 2500 bytes"))
    }
}
