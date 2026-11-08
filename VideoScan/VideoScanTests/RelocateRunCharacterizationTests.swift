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
import os
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

    // MARK: Codex test-gap pass (2026-11-07) — order, continuation, provenance, caps, entry exits

    /// Finding 1: Bucket E is re-proved IN THE RUNNER, after classification
    /// and before anything is applied. The witness vouches while reconcile
    /// classifies, then stops vouching (the independence probe the runner
    /// reads at re-proof time): the source is copied instead of skipped.
    @Test func aWitnessThatStopsVouchingBeforeApplyMakesTheRunCopyInstead() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("kids.bin")
        let (size, md5) = try writeFile(at: src, bytes: 2048)
        let witnessVol = ws.root.appendingPathComponent("MyBook3Terabytes", isDirectory: true)
        try FileManager.default.createDirectory(at: witnessVol, withIntermediateDirectories: true)
        let witness = witnessVol.appendingPathComponent("kids.bin")
        try FileManager.default.copyItem(at: src, to: witness)
        let rec = makeRecord(src, size: size, md5: md5)
        let witnessRec = makeRecord(witness, size: size, md5: md5)
        let model = makeModel(ws, [rec, witnessRec])
        // Classification blocks inside its first independence question until
        // the test has swapped the probe the runner will re-prove with.
        let gate = DispatchSemaphore(value: 0)
        let first = OSAllocatedUnfairLock(initialState: true)
        model.relocateWitnessIndependence = { witnessPath, sourcePath, root in
            if first.withLock({ let f = $0; $0 = false; return f }) { gate.wait() }
            return RelocateReconcile.witnessIsNotTheSourceFile(witnessPath, sourcePath, root)
        }
        model.relocateVolume(options(ws))
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, model.reconcileProgress == nil { await Task.yield() }
        model.relocateWitnessIndependence = { _, _, _ in false }
        gate.signal()
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        #expect(rec.fullPath == ws.dest.appendingPathComponent("kids.bin").path, "copied instead: \(rec.fullPath)")
        #expect(!rec.notes.contains("reason=dup-on-other-volume"), "no redundancy note: \(rec.notes)")
        #expect(model.dashboard.relocateSafelyRedundant == 0 && model.dashboard.relocateSafelyRedundantBytes == 0)
        #expect(model.dashboard.relocateSucceeded == 1)
        #expect(model.pendingRelocateSummary?.witnessSamples.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: src.path) && FileManager.default.fileExists(atPath: witness.path))
        let text = await console(model)
        #expect(text.contains("no safe copy is on disk now"), "\(text)")
    }

    /// Findings 2 and 3: the snapshot holds every bucket's PRE-apply state
    /// (B not yet marked, C at its recorded path, D at its source path), and
    /// a dry run over the same rows changes none of them.
    private func bucketsBCD(_ ws: Workspace) throws -> (b: VideoRecord, c: VideoRecord, d: VideoRecord, cActual: URL, dDest: URL) {
        let bRec = makeRecord(ws.source.appendingPathComponent("gone.bin"), size: 11, md5: "22222222222222222222222222222222")
        let cRecorded = ws.source.appendingPathComponent("old/m.bin")
        let cActual = ws.source.appendingPathComponent("new/m.bin")
        let (cs, cm) = try writeFile(at: cActual, bytes: 3000, seed: 29)
        let cRec = makeRecord(cRecorded, size: cs, md5: cm)
        let dSrc = ws.source.appendingPathComponent("pre.bin")
        let (ds, dm) = try writeFile(at: dSrc, bytes: 1024, seed: 37)
        let dDest = ws.dest.appendingPathComponent("pre.bin")
        try FileManager.default.copyItem(at: dSrc, to: dDest)
        try FileManager.default.removeItem(at: dSrc)
        let dRec = makeRecord(dSrc, size: ds, md5: dm)
        for r in [bRec, cRec, dRec] { r.notes = "before" }
        return (bRec, cRec, dRec, cActual, dDest)
    }

    @Test func theSnapshotHoldsEveryBucketsStateBeforeTheFirstMutation() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let f = try bucketsBCD(ws)
        let model = makeModel(ws, [f.b, f.c, f.d])

        model.relocateVolume(options(ws))
        _ = try await runToEnd(model)

        #expect(f.b.archiveStage == .manuallyDeleted)
        #expect(f.c.notes.contains("source-side move detected") && f.c.fullPath.hasPrefix(ws.dest.path))
        #expect(f.d.fullPath == f.dDest.path && f.d.notes.contains("adopted existing copy at dest"))
        let name = try #require(snapshots(ws).first)
        let text = try String(contentsOf: ws.catalog.appendingPathComponent(name), encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(!text.contains("source-side move detected") && !text.contains("adopted existing copy"),
                "no note written before the snapshot")
        #expect(!text.contains(f.dDest.path) && !text.contains(f.cActual.path), "no path rewritten before the snapshot")
        #expect(!text.contains("manuallyDeleted"), "Bucket B not marked before the snapshot")
        #expect(text.contains(ws.source.appendingPathComponent("old/m.bin").path), "C at its recorded path")
        #expect(text.contains(ws.source.appendingPathComponent("pre.bin").path), "D at its source path")
    }

    @Test func aDryRunOverEveryBucketChangesNoRow() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let f = try bucketsBCD(ws)
        let before = [f.b, f.c, f.d].map { ($0.fullPath, $0.directory, $0.notes, $0.archiveStage, $0.originalFullPath, $0.originVolume) }
        let model = makeModel(ws, [f.b, f.c, f.d])

        model.relocateVolume(options(ws, dryRun: true))
        let status = try await runToEnd(model)

        #expect(status == .awaitingDone)
        let after = [f.b, f.c, f.d].map { ($0.fullPath, $0.directory, $0.notes, $0.archiveStage, $0.originalFullPath, $0.originVolume) }
        for (x, y) in zip(before, after) {
            #expect(x.0 == y.0 && x.1 == y.1 && x.2 == y.2 && x.3 == y.3 && x.4 == y.4 && x.5 == y.5, "\(x) → \(y)")
        }
        #expect(model.dashboard.relocateManuallyDeleted == 1 && model.dashboard.relocateSourceMoves == 1
                && model.dashboard.relocateAdopted == 1)
        #expect(model.dashboard.relocateCompleted == 2, "B + D painted; C would copy")
        #expect(snapshots(ws).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ws.dest.appendingPathComponent("new/m.bin").path))
    }

    /// Finding 4: a failure does not stop the run — the next file copies;
    /// a followed source-side move that then fails keeps the DISCOVERED path.
    @Test func aFailedCopyDoesNotStopTheNextAndAFollowedMoveKeepsItsDiscoveredPath() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let a = ws.source.appendingPathComponent("a.bin")
        let (sa, ma) = try writeFile(at: a, bytes: 1000)
        try writeFile(at: ws.dest.appendingPathComponent("a.bin"), bytes: 10, seed: 3)       // collision
        let b = ws.source.appendingPathComponent("b.bin")
        let (sb, mb) = try writeFile(at: b, bytes: 1200, seed: 41)
        let cActual = ws.source.appendingPathComponent("new/c.bin")
        let (sc, mc) = try writeFile(at: cActual, bytes: 1400, seed: 43)
        try writeFile(at: ws.dest.appendingPathComponent("new/c.bin"), bytes: 10, seed: 5)   // collision after the move
        let ra = makeRecord(a, size: sa, md5: ma), rb = makeRecord(b, size: sb, md5: mb)
        let rc = makeRecord(ws.source.appendingPathComponent("old/c.bin"), size: sc, md5: mc)
        let model = makeModel(ws, [ra, rb, rc])

        model.relocateVolume(options(ws))
        _ = try await runToEnd(model)

        #expect(ra.archiveStage == .salvageFailed && ra.fullPath == a.path)
        #expect(rb.fullPath == ws.dest.appendingPathComponent("b.bin").path && rb.archiveStage == .none, "the next file still copied")
        #expect(rc.archiveStage == .salvageFailed && rc.fullPath == cActual.path, "keeps the discovered source path: \(rc.fullPath)")
        #expect(rc.notes.contains("source-side move detected") && rc.notes.contains("destination already exists"))
        #expect(model.dashboard.relocateSalvageFailed == 2 && model.dashboard.relocateSucceeded == 1
                && model.dashboard.relocateBytesCopied == sb)
        #expect(model.dashboard.relocateCompleted == model.dashboard.relocateTotal)
        let failed = Set(model.pendingRelocateSummary?.salvageFailedPaths ?? [])
        #expect(failed == [a.path, cActual.path], "\(failed)")
        let job = try #require(model.relocateQueue.last)
        #expect(job.copyProgress?.done == 3 && job.copyProgress?.total == 3 && job.copyProgress?.bytesCopied == sb,
                "\(String(describing: job.copyProgress))")
    }

    /// Finding 7: what a successful copy writes on the record — directory,
    /// the destination's partial hash, provenance (first hop kept).
    @Test func aSuccessfulCopyRewritesDirectoryAndHashAndKeepsTheFirstHopsProvenance() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let a = ws.source.appendingPathComponent("deep/a.bin")
        let (sa, ma) = try writeFile(at: a, bytes: 1500)
        let b = ws.source.appendingPathComponent("b.bin")
        let (sb, mb) = try writeFile(at: b, bytes: 1600, seed: 47)
        let ra = makeRecord(a, size: sa, md5: ma), rb = makeRecord(b, size: sb, md5: mb)
        rb.originVolume = "EarlierDrive"
        rb.notes = "kept note"
        let originA = ra.volumeName
        let model = makeModel(ws, [ra, rb])

        model.relocateVolume(options(ws))
        _ = try await runToEnd(model)

        let destA = ws.dest.appendingPathComponent("deep/a.bin")
        #expect(ra.fullPath == destA.path && ra.directory == destA.deletingLastPathComponent().path)
        #expect(ra.partialMD5 == FileHasher.partialMD5(path: destA.path))
        #expect(ra.originalFullPath == a.path && ra.originVolume == originA)
        #expect(rb.originVolume == "EarlierDrive", "the first hop's origin is kept")
        #expect(rb.notes == "kept note", "a clean copy adds no note")
    }

    @Test func theInferredExtensionIsSkippedWhenOffAndACollisionOnTheNewNameIsRefused() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let off = ws.source.appendingPathComponent("clipA")
        let (so, mo) = try writeFile(at: off, bytes: 900)
        let ro = makeRecord(off, size: so, md5: mo); ro.container = "mov,mp4,m4a,3gp,3g2,mj2"
        let model = makeModel(ws, [ro])
        var opts = options(ws); opts.addInferredExtensionOnRecovery = false
        model.relocateVolume(opts)
        _ = try await runToEnd(model)
        #expect(ro.fullPath == ws.dest.appendingPathComponent("clipA").path, "OFF: byte-for-byte name: \(ro.fullPath)")

        let ws2 = try Self.makeWorkspace(); defer { ws2.cleanup() }
        let clip = ws2.source.appendingPathComponent("clip")
        let (sc, mc) = try writeFile(at: clip, bytes: 900)
        let occupant = ws2.dest.appendingPathComponent("clip.mov")
        try writeFile(at: occupant, bytes: 50, seed: 7)
        let occupantBytes = contents(occupant)
        let rc = makeRecord(clip, size: sc, md5: mc); rc.container = "mov,mp4,m4a,3gp,3g2,mj2"
        let model2 = makeModel(ws2, [rc])
        model2.relocateVolume(options(ws2))
        _ = try await runToEnd(model2)
        #expect(rc.archiveStage == .salvageFailed && rc.fullPath == clip.path)
        #expect(rc.notes.contains("destination already exists: \(occupant.path)"), "\(rc.notes)")
        #expect(contents(occupant) == occupantBytes, "no overwrite, no uniquing")
        #expect(!FileManager.default.fileExists(atPath: ws2.dest.appendingPathComponent("clip").path))
    }

    /// Finding 9: the summary lists the first 20 failed paths; the count is all.
    @Test func theSummaryCapsTheFailedPathListAtTwentyButCountsEveryFailure() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        var recs: [VideoRecord] = []
        for i in 0..<21 {
            let url = ws.source.appendingPathComponent(String(format: "f%02d.bin", i))
            let (s, m) = try writeFile(at: url, bytes: 300 + i, seed: 11 + i)
            try writeFile(at: ws.dest.appendingPathComponent(url.lastPathComponent), bytes: 5, seed: 2)
            recs.append(makeRecord(url, size: s, md5: m))
        }
        let model = makeModel(ws, recs)
        model.relocateVolume(options(ws))
        _ = try await runToEnd(model)

        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.salvageFailedCount == 21 && summary.salvageFailedPaths.count == 20)
        #expect(summary.salvageFailedPaths == Array(recs.map(\.fullPath).prefix(20)), "the first 20, in run order")
        #expect(recs.allSatisfy { $0.archiveStage == .salvageFailed })
    }

    /// Finding 10: the runner's own entry checks.
    @Test func recordsGoneBeforeTheRunnerStartsFailTheJobCleanly() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("x.bin")
        let (size, md5) = try writeFile(at: src, bytes: 512)
        let model = makeModel(ws, [makeRecord(src, size: size, md5: md5)])

        model.relocateVolume(options(ws))
        model.records = []                                // before the runner's first turn
        let status = try await runToEnd(model)

        #expect(status == .failed(reason: "no records in scope"), "\(String(describing: status))")
        #expect(model.pendingRelocateSummary == nil)
        #expect(snapshots(ws).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: ws.dest.path)) ?? []).isEmpty)
    }

    @Test func anUnknownJobIDDoesNothing() async throws {
        let ws = try Self.makeWorkspace(); defer { ws.cleanup() }
        let src = ws.source.appendingPathComponent("x.bin")
        let (size, md5) = try writeFile(at: src, bytes: 512)
        let rec = makeRecord(src, size: size, md5: md5)
        let model = makeModel(ws, [rec])

        await model.runRelocate(jobID: UUID())

        #expect(model.relocateQueue.isEmpty && model.pendingRelocateSummary == nil)
        #expect(rec.fullPath == src.path && rec.notes.isEmpty)
        #expect(snapshots(ws).isEmpty)
    }
}
