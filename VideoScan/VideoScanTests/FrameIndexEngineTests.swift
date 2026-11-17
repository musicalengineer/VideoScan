// FrameIndexEngineTests.swift — the Index Frames engine and job, case by case
// (Observations/FrameSearch/FrameIndexJob.swift), beyond the runs in
// FrameSearchTests.swift.
//
//   ENGINE     `FrameIndexEngine.outcome` — every way one file can end, and
//              WHOSE FAULT each is: the file's (recorded), its drive's or
//              path's (left for the next run), the model's (the run stops),
//              a Stop's (nothing said). TRUTH: a frame that did not decode
//              drops out with ITS time — the vectors kept stay paired with
//              the times they were decoded at.
//   JOB        refusals read and write nothing; a damaged index on disk is
//              said and replaced; a file not at its path is counted, not
//              recorded, and indexed when it is back; the decode pool never
//              exceeds `concurrency`; the time checkpoint saves; a pause whose
//              save fails ends the run FAILED; the guards on Pause / Resume /
//              Stop / a second start hold.
//   CENTER     `startFrameIndex`: one job at a time through the MFO center.
// Stub decode and stub model; every index folder is a temp folder.

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// A model whose every answer the test chooses.
private struct ScriptedEmbedder: FrameEmbedding {
    let modelID = "test/stub-siglip"
    let dims = 8
    var images: @Sendable ([CGImage]) async throws -> [[Float]]
    func embed(images: [CGImage]) async throws -> [[Float]] { try await self.images(images) }
    func embed(text: String) async throws -> [Float] { ObsStubEmbedder.axis(0) }
}

private struct DecoderSaysNo: LocalizedError {
    var errorDescription: String? { "the decoder gave up at byte 4,096" }
}

private func card(_ width: Int) -> CGImage { FrameSearchTestCards.solid(9, 9, 9, size: width) }

// MARK: - The engine

@Suite("Frames mode — the per-file engine")
struct FrameIndexEngineTests {

    private static let here: FrameIndexEngine.Whereabouts = { _ in nil }

    private static func outcome(extract: @escaping FrameIndexEngine.Extract, embedder: any FrameEmbedding = ObsStubEmbedder(),
                                whereabouts: @escaping FrameIndexEngine.Whereabouts = here) async -> FrameIndexFileOutcome {
        await FrameIndexEngine.outcome(path: "/V/a.mov", durationSeconds: 10, framesPerFile: 3, extract: extract, embedder: embedder, whereabouts: whereabouts)
    }

    // MARK: Truth

    @Test func aFrameThatDidNotDecodeDropsOutWithItsTimeAndTheRestStayPaired() async {
        // Three times asked; the middle one does not decode. Each card's width picks its axis, so a vector names its frame.
        let result = await Self.outcome(extract: { _, times in [(times[0], card(17)), (times[1], nil), (times[2], card(19))] })
        guard case .indexed(let frames) = result else { Issue.record("a file with two readable frames must be indexed: \(result)"); return }
        let times = FrameIndexEngine.timestamps(durationSeconds: 10, framesPerFile: 3)
        #expect(frames.map(\.seconds) == [times[0], times[2]], "the times kept are the times that decoded")
        #expect(frames.map(\.vector) == [ObsStubEmbedder.axis(1), ObsStubEmbedder.axis(3)], "and each vector is the one made from the frame at that time")
    }

    @Test func theTimesAreInsideTheClipInOrderAndAZeroDurationStillLooksSomewhere() {
        let times = FrameIndexEngine.timestamps(durationSeconds: 100)
        #expect(times.count == FrameIndexEngine.framesPerFile && times.count == 8)
        #expect(times == times.sorted() && Set(times).count == 8)
        #expect((times.first ?? 0) >= 5 && (times.last ?? 100) <= 95, "the first and last 5 % are leader and trailer")
        for unknown in [0.0, -3.0] {
            let t = FrameIndexEngine.timestamps(durationSeconds: unknown, framesPerFile: 3)
            #expect(t.count == 3 && t.allSatisfy { $0 > 0 && $0 < 0.5 }, "a file with no stated length is looked at inside its first half second: \(t)")
        }
    }

    // MARK: Whose fault (stage 1 — the decode)

    @Test func aDecodeThatFailsIsTheFilesFaultOnlyWhenTheFileIsThere() async {
        let failing: FrameIndexEngine.Extract = { _, _ in throw DecoderSaysNo() }
        guard case .unreadable(let why) = await Self.outcome(extract: failing) else { Issue.record("there and undecodable = the file's fault"); return }
        #expect(why == "the decoder gave up at byte 4,096", "the decoder's own words are what is recorded")

        #expect(await Self.deferral(extract: failing, whereabouts: { _ in .driveNotConnected }) == .driveNotConnected)
        #expect(await Self.deferral(extract: failing, whereabouts: { _ in .notAtPath }) == .notAtPath)

        let nothing: FrameIndexEngine.Extract = { _, times in times.map { ($0, nil) } }
        guard case .unreadable(let none) = await Self.outcome(extract: nothing) else { Issue.record("no frame at all = the file's fault"); return }
        #expect(none == "no frame of 3 could be decoded")
        #expect(await Self.deferral(extract: nothing, whereabouts: { _ in .driveNotConnected }) == .driveNotConnected,
                "no frame because the drive went away is not the file's fault")
        #expect(await Self.deferral(extract: { _, _ in [] }) == nil, "an empty answer from the decoder is the file's too")
    }

    @Test func aDecodeCutByStopBlamesNobody() async {
        #expect(await Self.deferral(extract: { _, _ in throw CancellationError() }) == .stopped)
        // The decoder failed in its own words BECAUSE the run was cut: still nobody's fault.
        let cut = Task { await Self.outcome(extract: { _, _ in
            while !Task.isCancelled { await Task.yield() }
            throw DecoderSaysNo()
        }) }
        cut.cancel()
        guard case .deferred(.stopped) = await cut.value else { Issue.record("a decode that failed after the cut must be 'stopped'"); return }
    }

    // MARK: Whose fault (stage 2 — the model)

    @Test func aModelFailureIsNeverTheFilesBarThePixelDoor() async {
        let decodes: FrameIndexEngine.Extract = { _, times in times.map { ($0, card(16)) } }
        func ending(_ images: @escaping @Sendable ([CGImage]) async throws -> [[Float]]) async -> FrameIndexFileOutcome {
            await Self.outcome(extract: decodes, embedder: ScriptedEmbedder(images: images))
        }
        guard case .deferred(.modelUnavailable(let why)) = await ending({ _ in throw SigLIPError.loadFailed("out of memory") }) else {
            Issue.record("a model that threw is the model's fault"); return
        }
        #expect(why == "SigLIP 2 could not be loaded: out of memory")

        guard case .unreadable(let pixels) = await ending({ _ in throw SigLIPError.badImage }) else { Issue.record("the pixel door refusing a frame is the file's"); return }
        #expect(pixels == "a frame could not be converted to pixels")

        guard case .deferred(.stopped) = await ending({ _ in throw CancellationError() }) else { Issue.record("inference cut by Stop blames nobody"); return }

        // A model that answers with the wrong number of vectors, or the wrong width, has not answered: nothing is indexed from it.
        guard case .deferred(.modelUnavailable(let short)) = await ending({ _ in [ObsStubEmbedder.axis(0)] }) else { Issue.record("one vector for three frames"); return }
        #expect(short == "the model returned 1 vectors for 3 frames, or not 8 wide")
        guard case .deferred(.modelUnavailable(let narrow)) = await ending({ $0.map { _ in [1, 0, 0] } }) else { Issue.record("three floats, not eight"); return }
        #expect(narrow == "the model returned 3 vectors for 3 frames, or not 8 wide")
    }

    @Test func theSmokeDoorThrowsTheSameVerdictInWords() async throws {
        let frames = try await FrameIndexEngine.frames(path: "/V/a.mov", durationSeconds: 10, framesPerFile: 2,
                                                        extract: { _, times in times.map { ($0, card(18)) } }, embedder: ObsStubEmbedder())
        #expect(frames.count == 2 && frames.allSatisfy { $0.vector == ObsStubEmbedder.axis(2) })

        do {
            _ = try await FrameIndexEngine.frames(path: "/V/a.mov", durationSeconds: 10, extract: { _, _ in throw DecoderSaysNo() }, embedder: ObsStubEmbedder())
            Issue.record("an undecodable file must throw")
        } catch let failure as FrameIndexFailure {
            guard case .unreadable = failure else { Issue.record("\(failure)"); return }
            #expect(failure.localizedDescription == "the decoder gave up at byte 4,096")
        }
        do {
            _ = try await FrameIndexEngine.frames(path: "/V/a.mov", durationSeconds: 10, extract: { _, times in times.map { ($0, card(16)) } },
                                                  embedder: ScriptedEmbedder(images: { _ in throw SigLIPError.unavailable }))
            Issue.record("a model that is not there must throw")
        } catch let failure as FrameIndexFailure {
            guard case .deferred(.modelUnavailable) = failure else { Issue.record("\(failure)"); return }
            #expect(failure.localizedDescription == "this build has no MLX")
        }
        #expect(FrameIndexDeferral.driveNotConnected.words == "its drive is not connected" && FrameIndexDeferral.notAtPath.words == "it is not at its path")
        #expect(FrameIndexDeferral.stopped.words == "stopped before it was read" && FrameIndexDeferral.modelUnavailable("why").words == "why")
        #expect(FrameIndexFailure.deferred(.notAtPath).localizedDescription == "it is not at its path")
    }

    private static func deferral(extract: @escaping FrameIndexEngine.Extract, whereabouts: @escaping FrameIndexEngine.Whereabouts = here) async -> FrameIndexDeferral? {
        if case .deferred(let d) = await outcome(extract: extract, whereabouts: whereabouts) { return d }
        return nil
    }

    // MARK: The two small rules

    @Test func theDriveIsAskedBeforeThePath() {
        let asked = ObsAsked()
        func rule(online: Bool, exists: Bool) -> FrameIndexDeferral? {
            FrameIndexEngine.whereabouts(volumeOnline: { asked.add("drive \($0)"); return online }, fileExists: { asked.add("path \($0)"); return exists })("/Tape/a.mov")
        }
        #expect(rule(online: false, exists: false) == .driveNotConnected)
        #expect(asked.all == ["drive /Tape/a.mov"], "a drive that is not connected is not asked about its files (no spin-up, no false 'missing')")
        #expect(rule(online: true, exists: false) == .notAtPath)
        #expect(rule(online: true, exists: true) == nil)
    }

    @Test func aBigFrameIsShrunkToTheEdgeKeepingItsShapeAndASmallOneIsLeftAlone() throws {
        let wide = FrameIndexEngine.thumbnail(FrameSearchTestCards.pixels(size: 800) { x, _ in (UInt8(x % 256), 0, 0) }, maxEdge: 336)
        #expect(wide.width == 336 && wide.height == 336)
        let small = card(64)
        let kept = FrameIndexEngine.thumbnail(small, maxEdge: 336)
        #expect(kept === small, "nothing to shrink: the same image, not a copy")
        // 400 × 100 → 320 × 80 (the grid's thumbnails).
        let ctx = try #require(CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        let strip = FrameIndexEngine.thumbnail(try #require(ctx.makeImage()), maxEdge: 320)
        #expect(strip.width == 320 && strip.height == 80)
        let px = SigLIPPixels.normalizedHWC(strip, size: 4) ?? []
        #expect(px.count == 48 && px[0] > 0.95 && px[1] < -0.95 && px[2] < -0.95, "the picture survives the shrink (red stays red): \(px.prefix(3))")
    }
}

// MARK: - The job

@Suite("Frames mode — Index Frames job, hardening") @MainActor
struct FrameIndexJobBehaviourTests {

    typealias Notes = FrameIndexJobTests.Notes
    typealias Flag = FrameIndexJobTests.Flag

    nonisolated static func three() -> [CatalogRow.FrameIndexFile] {
        [ObsFixture.row(1, path: "/V/a.mov"), ObsFixture.row(2, path: "/V/b.mov"), ObsFixture.row(3, path: "/V/c.mov")]
    }

    // MARK: Refusals read and write nothing

    @Test func aRefusedJobNeverStartsReadsNothingAndTheOutcomeLineSaysRefused() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = ObsCounter()
        let job = FrameIndexJob(scope: .folder("/V"), loadFiles: { _ in reads.bump(); return Self.three() }, embedder: ObsStubEmbedder())
        job.root = root
        #expect(job.title == "Index frames (SigLIP 2) — the folder /V" && job.isIndeterminate && job.canPause)
        job.refuseToStart(reason: "Index Frames runs on the Mac that holds the catalog — this one is a viewer.")
        job.start()
        await job.task?.value
        #expect(job.wasRefused && job.state == .failed(message: "Index Frames runs on the Mac that holds the catalog — this one is a viewer."))
        #expect(job.outcome == .refused("Index Frames runs on the Mac that holds the catalog — this one is a viewer.") && job.finishedAt != nil)
        #expect(reads.value == 0 && ObsFixture.onDisk(root) == .notBuilt, "refused = nothing read, nothing written")
        let line = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title, state: job.state, wasRefused: job.wasRefused)
        #expect(line == "index frames refused: Index frames (SigLIP 2) — the folder /V — Index Frames runs on the Mac that holds the catalog — this one is a viewer.")
        #expect(!job.canPause)
        job.pause(); job.cancel(); job.refuseToStart(reason: "again")
        #expect(!job.isPaused && job.state == .failed(message: "Index Frames runs on the Mac that holds the catalog — this one is a viewer."), "an ended job stays ended")
    }

    @Test func aCatalogThatCannotBeReadRefusesAndWritesNothing() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notes()
        let job = FrameIndexJob(scope: .everything, loadFiles: { _ in throw DecoderSaysNo() }, embedder: ObsStubEmbedder())
        job.root = root
        job.note = { notes.lines.append($0) }
        job.start()
        await job.task?.value
        #expect(job.wasRefused && job.state == .failed(message: "Refused — the catalog could not be read: the decoder gave up at byte 4,096"))
        #expect(job.outcome == .refused("Refused — the catalog could not be read: the decoder gave up at byte 4,096"))
        #expect(notes.lines == ["refused — the catalog could not be read (the decoder gave up at byte 4,096). Nothing was read or written."])
        #expect(job.planned == 0 && job.savePoints.isEmpty && ObsFixture.onDisk(root) == .notBuilt)
    }

    // MARK: Poisoned state

    @Test func aDamagedIndexOnDiskIsSaidAndReplacedByAGoodOne() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = FrameIndexStore.directory(root: root, model: "test/stub-siglip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("index.json"))
        guard case .unreadable = ObsFixture.onDisk(root) else { Issue.record("the fixture must be unreadable"); return }
        let notes = Notes()
        let job = ObsFixture.job(Self.three(), root: root, notes: notes)
        job.start()
        await job.task?.value
        #expect(job.outcome == .finished && job.indexed == 3 && job.alreadyDone == 0)
        #expect(notes.lines.contains { $0.hasPrefix("the index on disk could not be read (the index's sidecar does not parse") && $0.contains("starting a new one") }, "\(notes.lines)")
        #expect(ObsFixture.onDisk(root).index?.indexedDigests == Set((1...3).map(ObsFixture.digest)), "what is on disk afterwards is a whole, readable index")
    }

    @Test func anIndexMadeByAnotherModelIsNotResumedFrom() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // The stub model's folder holds a sidecar that names a different model (a renamed folder, a hand copy).
        var other = FrameIndexBuilder(model: "someone/else", dims: 8)
        other.add(digest: ObsFixture.digest(1), frames: [(1, ObsStubEmbedder.axis(5))])
        try FrameIndexStore.save(other.snapshot(), root: root)
        try FileManager.default.moveItem(at: FrameIndexStore.directory(root: root, model: "someone/else"),
                                         to: FrameIndexStore.directory(root: root, model: "test/stub-siglip"))
        let notes = Notes()
        let job = ObsFixture.job(Self.three(), root: root, notes: notes)
        job.start()
        await job.task?.value
        #expect(job.alreadyDone == 0 && job.indexed == 3, "another model's vectors are never counted as this model's work")
        #expect(notes.lines.contains { $0.contains("the index was made by someone/else, not test/stub-siglip") }, "\(notes.lines)")
        let index = try #require(ObsFixture.onDisk(root).index)
        #expect(index.model == "test/stub-siglip" && index.count == 9)
        #expect((0..<index.count).allSatisfy { Array(index.vector(at: $0)) == ObsStubEmbedder.axis(0) }, "truth: no row of the other model's survives in the matrix")
    }

    // MARK: Where the file is

    @Test func aFileNotAtItsPathIsCountedNotRecordedNotDecodedAndIndexedWhenItIsBack() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let back = Flag()
        let decoded = ObsAsked()
        let notes = Notes()
        func run() async -> FrameIndexJob {
            let job = ObsFixture.job(Self.three(), root: root, notes: notes)
            job.fileExists = { !$0.hasSuffix("b.mov") || back.isSet }
            job.extract = { path, times in decoded.add(path); return times.map { ($0, card(16)) } }
            job.start()
            await job.task?.value
            return job
        }
        let first = await run()
        guard case .finished(let summary) = first.state else { Issue.record("ended \(first.state)"); return }
        #expect(first.indexed == 2 && first.missing == 1 && first.offline == 0 && first.unreadable == 0 && first.done == 3)
        #expect(summary.contains("2 files indexed (6 frames") && summary.contains("1 not at their path") && summary.hasSuffix("the index holds 6 frames"), "\(summary)")
        #expect(!decoded.all.contains("/V/b.mov"), "a file that is not there is not handed to the decoder")
        #expect(ObsFixture.onDisk(root).index?.failures.isEmpty == true, "and nothing is recorded against it")
        back.set()
        let second = await run()
        #expect(second.planned == 1 && second.alreadyDone == 2 && second.indexed == 1 && second.missing == 0)
        #expect(ObsFixture.onDisk(root).index?.count == 9)
    }

    @Test func aFileThatVanishesMidDecodeIsLeftForTheNextRunInWords() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = Flag()
        let notes = Notes()
        let job = ObsFixture.job([ObsFixture.row(1, path: "/V/a.mov")], root: root, notes: notes)
        job.fileExists = { _ in !gone.isSet }
        job.extract = { _, _ in gone.set(); throw DecoderSaysNo() }
        job.start()
        await job.task?.value
        #expect(job.missing == 1 && job.unreadable == 0 && job.indexed == 0 && job.outcome == .finished)
        #expect(notes.lines.contains("left for the next run — a.mov: it is not at its path"), "\(notes.lines)")
        #expect(ObsFixture.onDisk(root) == .notBuilt, "nothing was indexed and nothing recorded: there is no index to write")
    }

    @Test func removedCopiesAndSoundOnlyFilesAreNotPlanned() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notes()
        let rows = [ObsFixture.row(1, path: "/V/a.mov"), ObsFixture.row(2, path: "/V/gone.mov", removed: true),
                    ObsFixture.row(3, path: "/V/song.wav", stream: "Audio only")]
        let job = ObsFixture.job(rows, root: root, notes: notes)
        job.start()
        await job.task?.value
        #expect(job.planned == 1 && job.indexed == 1 && !job.isIndeterminate && job.fraction == 1)
        let start = try #require(notes.lines.first)
        #expect(start.hasPrefix("index frames: Index frames (SigLIP 2) — everything in the catalog — 1 file to index, 3 frames each with test/stub-siglip "
                                + "(0 already indexed, 2 without a picture) → "), "\(start)")
        #expect(start.hasSuffix(FrameIndexStore.directory(root: root, model: "test/stub-siglip").path), "the START line names the folder it writes")
    }

    // MARK: The model answers wrongly

    @Test func aModelThatAnswersWithTheWrongShapeFailsTheRunAndBlamesNoFile() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = ObsFixture.job(Self.three(), root: root, embedder: ScriptedEmbedder(images: { $0.map { _ in [1, 0] } }))
        job.start()
        await job.task?.value
        #expect(job.outcome == .modelUnavailable("the model returned 3 vectors for 3 frames, or not 8 wide"))
        #expect(job.indexed == 0 && job.unreadable == 0 && job.savePoints.isEmpty && ObsFixture.onDisk(root) == .notBuilt)
        guard case .failed(let message) = job.state else { Issue.record("ended \(job.state)"); return }
        #expect(message.contains("3 files left for the next run, nothing recorded against them"), "\(message)")
    }

    // MARK: Bounds, checkpoints, progress

    @Test func noMoreFilesAreDecodedAtOnceThanTheJobsConcurrency() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        /// In flight now and the most ever (≈ a mutex-guarded high-water mark).
        final class Pool: @unchecked Sendable {
            private let lock = NSLock()
            private var now = 0
            private(set) var most = 0
            func enter() { lock.withLock { now += 1; most = max(most, now) } }
            func leave() { lock.withLock { now -= 1 } }
            var highWater: Int { lock.withLock { most } }
        }
        let pool = Pool()
        let rows = (1...12).map { ObsFixture.row($0, path: "/V/\($0).mov") }
        let job = ObsFixture.job(rows, root: root)
        job.concurrency = 3
        job.extract = { _, times in
            pool.enter()
            try await Task.sleep(for: .milliseconds(20))
            pool.leave()
            return times.map { ($0, card(16)) }
        }
        job.start()
        await job.task?.value
        #expect(job.indexed == 12 && job.outcome == .finished)
        #expect(pool.highWater == 3, "the memory bound in the file header is `concurrency` files in flight: saw \(pool.highWater)")
    }

    @Test func theTimeCheckpointSavesEvenWhenTheFileCountIsFarOff() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notes()
        let job = ObsFixture.job(Self.three(), root: root, notes: notes)
        job.checkpointFiles = 1_000
        job.checkpointSeconds = 0          // "a minute has passed" after every file
        job.progressLogSeconds = 0
        var subtitles: [String] = []
        var onDisk: [Int] = []
        job.onSaved = { _ in
            subtitles.append(job.subtitle)
            onDisk.append(ObsFixture.onDisk(root).index?.count ?? 0)
        }
        job.start()
        await job.task?.value
        #expect(job.savePoints == [.checkpoint, .checkpoint, .checkpoint] && onDisk == [3, 6, 9], "a crash loses at most one checkpoint")
        #expect(subtitles.first?.hasPrefix("1 of 3 · a.mov · ") == true && subtitles.last?.hasPrefix("3 of 3 · c.mov · ") == true, "\(subtitles)")
        #expect(subtitles.first?.contains(" left") == true && subtitles.last?.contains(" left") == false, "time left is said only while files are left")
        let progress = notes.lines.filter { $0.hasPrefix("progress: ") }
        #expect(progress.count == 3 && progress.last?.hasPrefix("progress: 3 of 3 files, 9 frames (") == true, "\(notes.lines)")
        #expect(progress.last?.hasSuffix("0 unreadable, 0 on drives not connected") == true)
        #expect(job.fraction == 1 && FrameIndexSavePoint.finished.writesWithNothingNew && !FrameIndexSavePoint.checkpoint.writesWithNothingNew)
    }

    @Test func aPauseWhoseSaveFailsEndsTheRunFailedAndSaysWhatIsNotOnDisk() async throws {
        let dir = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: root)   // the index folder cannot be made under a plain file
        let (job, _, inHand, release) = FrameIndexJobTests.gated(root: root)
        job.start()
        try await FrameIndexJobTests.until("the first file is in hand") { inHand.isSet }
        job.pause()
        job.pause()
        #expect(job.isPaused)
        release.set()
        await job.task?.value
        guard case .saveFailed(at: .paused, why: _) = job.outcome else { Issue.record("ended \(String(describing: job.outcome))"); return }
        guard case .failed(let message) = job.state else { Issue.record("ended \(job.state)"); return }
        #expect(message.contains("(paused)") && message.contains("1 result since the last save is not on disk"), "\(message)")
        #expect(job.indexed == 1 && job.savePoints.isEmpty, "a paused job that cannot save does not sit there holding results it cannot keep")
    }

    @Test func resumeWithoutAPauseAndASecondStartChangeNothing() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = ObsCounter()
        let rows = Self.three()
        let job = ObsFixture.job(rows, root: root)
        job.loadFiles = { _ in reads.bump(); return rows }
        job.resume()
        #expect(job.subtitle == "Reading the catalog…" && !job.isPaused, "nothing was paused: Resume says nothing")
        job.start()
        job.start()
        await job.task?.value
        #expect(reads.value == 1 && job.indexed == 3, "one run, however many times Start is pressed")
        job.cancel()
        #expect(job.state != .cancelling && job.outcome == .finished, "Stop after the end is not a Stop")
    }

    // MARK: The center

    @Test func theCenterRunsOneIndexJobAtATimeAndHandsBackTheRunningOne() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = MediaFileOperationsCenter()
        let release = Flag()
        let notes = Notes()
        let rows = [ObsFixture.row(1, path: root.appendingPathComponent("nowhere/a.mov").path)]
        let load: FrameIndexJob.LoadFiles = { _ in
            while !release.isSet { try await Task.sleep(for: .milliseconds(5)) }
            return rows
        }
        let first = center.startFrameIndex(scope: .folder("/V"), loadFiles: load, embedder: ObsStubEmbedder(), root: root, note: { notes.lines.append($0) }, onSaved: nil)
        #expect(first.root == root)
        #expect(first.state == .running && center.jobs.contains { $0.id == first.id })
        let second = center.startFrameIndex(scope: .everything, loadFiles: { _ in [] }, embedder: ObsStubEmbedder(), root: root, note: { _ in }, onSaved: nil)
        #expect(second === first && center.jobs.count == 1, "a second request while one runs is the running one — never two writers of one index")
        release.set()
        await first.task?.value
        #expect(first.outcome == .finished && first.missing + first.offline == 1 && first.indexed == 0, "a file that is not there is left for the next run: \(first.state)")
        #expect(notes.lines.first?.hasPrefix("index frames: Index frames (SigLIP 2) — the folder /V — 1 file to index") == true, "\(notes.lines)")
        #expect(ObsFixture.onDisk(root) == .notBuilt)

        let third = center.startFrameIndex(scope: .everything, loadFiles: { _ in [] }, embedder: ObsStubEmbedder(), root: root, note: { _ in }, onSaved: nil)
        #expect(third !== first && center.jobs.count == 2, "the first one ended: a new request is a new job")
        await third.task?.value
        #expect(third.outcome == .finished && third.subtitle == "Nothing to index")
    }
}
