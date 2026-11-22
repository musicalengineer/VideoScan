// EncodeVerifyReformatCleanupMatrixTests.swift — GH #502 for the two other
// verbs that use FFmpegEncodeCheck: Reformat and Clean Up Video. Rick
// 2026-11-21 (after #500: "why would we keep a bad file? we must fail but
// fail and record the error clearly and log it clearly. The user must be
// told there's an issue"): an output that cannot be measured is not
// verified, and an unverified output is a FAILED job — removed, never
// published, never adopted into the catalog, and the row + OUTCOME line say
// why.
//
// THE BUG (same shape as plain Transcode): FFmpegEncodeCheck's "nil = not
// failed" answer was read as leave to publish, so an output ffprobe could
// not read (it crashed, could not start, answered garbage, said "Invalid
// data", or hung to its deadline) was published and reported "Reformatted"
// / returned as a good render — and a Stop during the probes read as
// "unmeasured", which was a pass.
//
// Reformat rows drive the production ReformatJob; Cleanup rows drive the
// engine's render (a throw is what keeps CleanupJob from publishing: it
// publishes only a returned URL — pinned by a source sensor below; a
// job-level run would mount a RAM disk). ffmpeg and ffprobe are answered by
// a strict ScriptedExecutor; sources are placeholder bytes, never decoded.
// The fault rows are TranscodeReplaceNegativeMatrixTests.Unmeasurable — the
// same five the #500 matrix uses.
//
// Parallel by design (each test binds its own mock). Memory: blobs of tens
// of KB.

import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

typealias EncodeProbeFault = TranscodeReplaceNegativeMatrixTests.Unmeasurable
private typealias MX = TranscodeReplaceNegativeMatrixTests

// MARK: - Reformat

@Suite("Reformat — an output that cannot be verified is failed, removed and never catalogued (GH #502)", .timeLimit(.minutes(1)))
@MainActor
struct ReformatUnverifiedOutputMatrixTests {

    static let sourceName = "test_rfmx_tape.avi"

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let source: VideoRecord

        @MainActor func catalogSnapshot() -> [String] {
            model.records.map { "\($0.fullPath)|\($0.notes)|\($0.derivedFrom?.uuidString ?? "-")" }.sorted()
        }

        /// Everything in the source's folder (Reformat writes beside it).
        func beside() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: sb.sources.path)) ?? ["unreadable"]).sorted()
        }
    }

    func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox("rfmx_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        let url = sb.sources.appendingPathComponent(Self.sourceName)
        _ = try MasterArchiveTestSupport.writeBlob(at: url, bytes: 64 * 1024, seed: 51)   // placeholder: never decoded
        let source = MasterArchiveTestSupport.makeRecord(path: url.path)
        source.durationSeconds = 12
        model.records = [source]
        return Bench(sb: sb, model: model, source: source)
    }

    func mock(_ b: Bench, encode: ScriptedExecutor.Behaviour = .writeOutputFile(Data(repeating: 0x5A, count: 20_000)),
              sourceProbe: ScriptedExecutor.Behaviour = MX.twelveSeconds,
              outputProbe: ScriptedExecutor.Behaviour = MX.twelveSeconds) throws -> ScriptedExecutor {
        try ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: [Self.sourceName], encode)
            .on("ffprobe", containing: ["format=duration", Self.sourceName], sourceProbe)
            .on("ffprobe", containing: ["format=duration", ".vs-partial."], outputProbe)
            .on("ffprobe", containing: ["-show_streams"], .output(stdout: MX.h264ProbeJSON()))
    }

    func run(_ b: Bench, _ mock: ScriptedExecutor,
             whileRunning: (@MainActor (ReformatJob) async -> Void)? = nil) async -> ReformatJob {
        let job = ReformatJob(record: b.source, model: b.model, orchestrator: nil)
        await mock.scoped {
            job.start()
            if let whileRunning { await whileRunning(job) }
            await job.task?.value
        }
        return job
    }

    func expectUnverifiedNotPublished(_ b: Bench, _ job: ReformatJob, _ m: ScriptedExecutor, catalogBefore: [String],
                                      file whose: String, cause: [String],
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        let plain = "Could not verify the new file — nothing was published or added to the catalog."
        guard case .failed(let message) = job.state else {
            Issue.record("an unverified output was reported as \(job.state)", sourceLocation: sourceLocation)
            #expect(b.catalogSnapshot() == catalogBefore, "…and adopted into the catalog", sourceLocation: sourceLocation)
            return
        }
        #expect(message.hasPrefix(plain), "\(message)", sourceLocation: sourceLocation)
        for words in [whose] + cause { #expect(message.contains(words), "the row lacks “\(words)”: \(message)", sourceLocation: sourceLocation) }
        #expect(message.hasSuffix("The unverified new file was removed."), "\(message)", sourceLocation: sourceLocation)
        #expect(!message.contains("Reformatted"), sourceLocation: sourceLocation)
        #expect(job.subtitle == message, sourceLocation: sourceLocation)
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title,
                                                                    state: job.state, wasRefused: job.wasRefused)
        #expect(outcome == "\(job.kind.logVerb) FAILED: \(Self.sourceName) — \(message)", "OUTCOME: \(outcome ?? "nil")", sourceLocation: sourceLocation)
        #expect((outcome ?? "").count < 900, sourceLocation: sourceLocation)
        #expect(b.beside() == [Self.sourceName], "published or left beside the source: \(b.beside())", sourceLocation: sourceLocation)
        #expect(b.catalogSnapshot() == catalogBefore, "the catalog recorded an unverified output", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty, sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffmpeg").count == 1, "\(m.calls)", sourceLocation: sourceLocation)
    }

    @Test("control: a verified reformat is published beside the source and catalogued as its derivative")
    func controlAVerifiedReformatPublishes() async throws {
        let b = try bench("ok"); defer { b.sb.cleanup() }
        let m = try mock(b)
        let job = await run(b, m)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("Reformatted → \(job.publishedURL.lastPathComponent)"), "\(summary)")
        #expect(b.beside() == [job.publishedURL.lastPathComponent, Self.sourceName].sorted(), "\(b.beside())")
        #expect(b.model.records.first { $0.fullPath == job.publishedURL.path }?.derivedFrom == b.source.id)
        #expect(m.calls(to: "ffprobe", containing: ["format=duration"]).count == 2, "source and output both measured")
    }

    @Test("an output whose length probe crashes / cannot launch / returns garbage / says Invalid data / hangs: FAILED, removed, never catalogued, the cause said",
          arguments: EncodeProbeFault.allCases)
    func anUnmeasurableReformatIsNeverAdopted(_ kind: EncodeProbeFault) async throws {
        let b = try bench("unmeasurable_\(kind.rawValue)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, outputProbe: kind.probe)
        let job = await run(b, m)
        expectUnverifiedNotPublished(b, job, m, catalogBefore: before,
                                     file: "the new file's length could not be read", cause: kind.causeWords)
    }

    // (A source with no readable duration is published with a note:
    // EncodeSourceWithoutDurationMatrixTests.)

    @Test("an output shorter than the source is still FAILED as 'stopped early' (the length rule itself is unchanged)")
    func aShortReformatIsStillRefused() async throws {
        let b = try bench("short"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, outputProbe: .output(stdout: "2.000000\n"))
        let job = await run(b, m)
        guard case .failed(let message) = job.state else { Issue.record("\(job.state)"); return }
        #expect(message.contains("stopped early") && message.contains("0:02") && message.contains("0:12"), "\(message)")
        #expect(b.beside() == [Self.sourceName] && b.catalogSnapshot() == before)
    }

    @Test("Stop while the output is being probed ends Cancelled: nothing published, nothing catalogued — a good answer does not publish over a Stop")
    func stopDuringTheProbesNeverPublishes() async throws {
        let b = try bench("stop_probes"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let probing = MX.Box<Bool>(), release = MX.Box<Bool>()
        let m = try mock(b, outputProbe: .custom { _ in
            probing.set(true)
            _ = await release.wait()
            return MX.twelveSecondsResult
        })
        let job = await run(b, m) { job in
            _ = await probing.wait()
            job.cancel()
            release.set(true)
        }
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(b.beside() == [Self.sourceName], "\(b.beside())")
        #expect(b.catalogSnapshot() == before)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty)
    }
}

// MARK: - Clean Up Video

@Suite("Clean Up Video — a render that cannot be verified is never returned for publishing (GH #502)", .timeLimit(.minutes(1)))
struct CleanupUnverifiedRenderMatrixTests {

    static let sourceName = "test_clmx_tape.mov"

    struct Bench {
        let dir: URL
        let scratch: URL
        let source: CleanupSource
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    static func bench(_ label: String) throws -> Bench {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_clmx_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent(sourceName)
        try Data(repeating: 0x33, count: 64 * 1024).write(to: src)   // placeholder: never decoded
        return Bench(dir: dir, scratch: scratch,
                     source: CleanupSource(path: src.path, durationSeconds: 60, fieldOrder: "progressive",
                                           hasAudio: true, audioCodec: "aac"))
    }

    static let sixtySeconds = ScriptedExecutor.Behaviour.output(stdout: "60.000000\n")

    static func mock(_ b: Bench, sourceProbe: ScriptedExecutor.Behaviour = sixtySeconds,
                     renderProbe: ScriptedExecutor.Behaviour = sixtySeconds) -> ScriptedExecutor {
        ScriptedExecutor(claiming: [b.dir.path])
            .on("ffmpeg", containing: [sourceName, "cleanup-render"], .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
            .on("ffprobe", containing: ["format=duration", "cleanup-render"], renderProbe)
            .on("ffprobe", containing: ["format=duration", sourceName], sourceProbe)
    }

    static func render(_ b: Bench, _ mock: ScriptedExecutor) async throws -> CleanupRender {
        try await mock.scoped {
            try await CleanupFFmpegEngine().render(recipe: CleanupRecipeRegistry.vhsQuickClean, source: b.source,
                                                   scratchDirectory: b.scratch, progress: { _ in })
        }
    }

    static func expectUnverified(_ b: Bench, _ mock: ScriptedExecutor, file whose: String, cause: [String],
                                 sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            let render = try await render(b, mock)
            Issue.record("a render nobody could measure was returned for publishing: \(render.url.lastPathComponent)", sourceLocation: sourceLocation)
        } catch CleanupEngineError.renderFailed(let detail) {
            #expect(detail.hasPrefix("Could not verify the cleaned copy — nothing was published or added to the catalog."),
                    "\(detail)", sourceLocation: sourceLocation)
            for words in [whose] + cause { #expect(detail.contains(words), "lacks “\(words)”: \(detail)", sourceLocation: sourceLocation) }
            #expect(detail.hasSuffix("The unverified render is only in the job's scratch folder; the original is untouched."),
                    "\(detail)", sourceLocation: sourceLocation)
            #expect(!detail.contains("discarded") && !detail.contains("was removed"), "the engine removes nothing and must not say it did: \(detail)",
                    sourceLocation: sourceLocation)
            #expect(detail.count < 800, "bounded: \(detail.count)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected renderFailed, got \(error)", sourceLocation: sourceLocation)
        }
        #expect(mock.calls(to: "ffmpeg").count == 1, "\(mock.calls)", sourceLocation: sourceLocation)
    }

    @Test("control: a render whose length is read and agrees is returned")
    func controlAVerifiedRenderIsReturned() async throws {
        let b = try Self.bench("ok"); defer { b.cleanup() }
        let m = Self.mock(b)
        let render = try await Self.render(b, m)
        #expect(FileManager.default.fileExists(atPath: render.url.path))
        #expect(render.isUnchanged, "the stamp returned is the render's")
        #expect(m.calls(to: "ffprobe").count == 2, "source and render both measured: \(m.calls)")
    }

    @Test("a render whose length probe crashes / cannot launch / returns garbage / says Invalid data / hangs is renderFailed with the cause, never returned",
          arguments: EncodeProbeFault.allCases)
    func anUnmeasurableRenderIsNeverReturned(_ kind: EncodeProbeFault) async throws {
        let b = try Self.bench("unmeasurable_\(kind.rawValue)"); defer { b.cleanup() }
        await Self.expectUnverified(b, Self.mock(b, renderProbe: kind.probe),
                                    file: "the cleaned copy's length could not be read", cause: kind.causeWords)
    }

    @Test("Stop while the render is being probed: the render throws CancellationError — a good answer does not return a render over a Stop")
    func stopDuringTheProbesNeverReturnsARender() async throws {
        let b = try Self.bench("stop_probes"); defer { b.cleanup() }
        let probing = MX.Box<Bool>(), release = MX.Box<Bool>()
        let m = Self.mock(b, renderProbe: .custom { _ in
            probing.set(true)
            _ = await release.wait()
            return ProcessRunner.Result(stdout: "60.000000\n", stderr: "", exitCode: 0, launched: true)   // a good answer
        })
        let task = Task { try await Self.render(b, m) }
        _ = await probing.wait()
        task.cancel()
        release.set(true)
        do {
            let render = try await task.value
            Issue.record("a render was returned over a Stop: \(render.url.lastPathComponent)")
        } catch is CancellationError {
            // the job's failOrCancel turns this into a Cancelled row
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    /// Codex r1 #4 (P0), as the Transcode swap test (GH #500 F2): the render
    /// probe measures render A; while the source probe is still out, B (a
    /// new inode, over 10 KB, never measured) is put at the render's name.
    /// A's length must not vouch for B: renderFailed, nothing returned.
    @Test("a render swapped while it was being verified is never returned — the length read belongs to another file")
    func aRenderSwappedDuringVerificationIsNeverReturned() async throws {
        let b = try Self.bench("swapped"); defer { b.cleanup() }
        let measured = MX.Box<URL>()
        let swapped = Data(repeating: 0x42, count: 20_000)
        let m = Self.mock(b,
                          sourceProbe: .custom { _ in
                              // Barrier: only after the render was measured.
                              if let render = await measured.wait() { try? swapped.write(to: render, options: .atomic) }
                              return ProcessRunner.Result(stdout: "60.000000\n", stderr: "", exitCode: 0, launched: true)
                          },
                          renderProbe: .custom { request in
                              measured.set(URL(fileURLWithPath: request.arguments.last ?? ""))
                              return ProcessRunner.Result(stdout: "60.000000\n", stderr: "", exitCode: 0, launched: true)
                          })
        await Self.expectUnverified(b, m, file: "the new file changed while it was being verified", cause: [])
        let render = try #require(measured.value)
        #expect((try? Data(contentsOf: render)) == swapped, "B is left where it is (the job's scratch removal takes it)")
    }

    /// Codex r1 #4, the handoff: the engine verified render A and returned
    /// A's stamp; B is put at the render's name before the publish. The job
    /// copies only the verified file: FAILED, nothing beside the original.
    @Test("CleanupJob: a render changed after the engine verified it is never published — FAILED, nothing beside the original")
    @MainActor
    func aRenderChangedAfterVerificationIsNeverPublished() async throws {
        let b = try Self.bench("changed_after"); defer { b.cleanup() }
        let model = VideoScanModel()
        // Duration 0: the scratch is the system temp folder, never a RAM disk.
        let record = makeCleanupSourceRecord(path: b.source.path, durationSeconds: 0, fieldOrder: "progressive")
        model.records = [record]
        var stub = StubCleanupEngine()
        stub.afterVerify = { render in try Data(repeating: 0x42, count: 20_000).write(to: render, options: .atomic) }
        let job = CleanupJob(record: record, recipe: CleanupRecipeRegistry.vhsQuickClean, model: model, engine: stub)
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else { Issue.record("a changed render was published: \(job.state)"); return }
        #expect(message.hasPrefix("Could not verify the cleaned copy — nothing was published or added to the catalog."), "\(message)")
        #expect(message.contains("Cause: the new file changed while it was being verified"), "\(message)")
        let beside = try FileManager.default.contentsOfDirectory(atPath: b.dir.path).sorted()
        #expect(beside == ["scratch", Self.sourceName], "\(beside)")
        #expect(model.records.count == 1, "nothing was catalogued")
    }

    /// An engine that leaves a render in the scratch folder and then says it
    /// could not be verified; `lockScratch` makes the folder unremovable
    /// (no write permission), as a disk returning EIO would.
    struct UnverifiedRenderEngine: CleanupRecipeEngine {
        let engineID = "unverified-test-engine"
        let lockScratch: Bool
        let seen: TranscodeReplaceNegativeMatrixTests.Box<URL>
        func canExecute(_ recipe: CleanupRecipe) -> Bool { true }
        func render(recipe: CleanupRecipe, source: CleanupSource, scratchDirectory: URL,
                    progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> CleanupRender {
            try Data(repeating: 0x5A, count: 20_000).write(to: scratchDirectory.appendingPathComponent("cleanup-render.mov"))
            seen.set(scratchDirectory)
            if lockScratch { chmod(scratchDirectory.path, 0o500) }
            throw CleanupEngineError.renderFailed(CleanupFFmpegEngine.unverifiedRenderMessage(cause: "ffprobe stopped with exit code 1"))
        }
    }

    /// Codex r1 #8 (P1): the row promised the scratch folder "is removed when
    /// the job ends" while the job discarded the removal's error. The job now
    /// says what its own removal did: removed, or NOT removed with the path.
    @Test("CleanupJob: an unverified render's row says whether the job's scratch folder was removed — or NOT, with its path",
          arguments: [false, true])
    @MainActor
    func theScratchFoldersFateIsSaid(_ lockScratch: Bool) async throws {
        let b = try Self.bench("scratch_\(lockScratch)"); defer { b.cleanup() }
        let seen = MX.Box<URL>()
        defer { if let dir = seen.value { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) } }
        let model = VideoScanModel()
        let record = makeCleanupSourceRecord(path: b.source.path, durationSeconds: 0, fieldOrder: "progressive")
        model.records = [record]
        let job = CleanupJob(record: record, recipe: CleanupRecipeRegistry.vhsQuickClean, model: model,
                             engine: UnverifiedRenderEngine(lockScratch: lockScratch, seen: seen))
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else { Issue.record("\(job.state)"); return }
        let scratch = try #require(seen.value)
        #expect(!message.contains("removed when the job ends"), "a promise, not a result: \(message)")
        if lockScratch {
            #expect(FileManager.default.fileExists(atPath: scratch.path))
            #expect(message.contains("The job's scratch folder \(scratch.path) was NOT removed: "), "\(message)")
        } else {
            #expect(!FileManager.default.fileExists(atPath: scratch.path))
            #expect(message.hasSuffix("the original is untouched. The job's scratch folder was removed."), "\(message)")
        }
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title, state: job.state, wasRefused: job.wasRefused)
        #expect(outcome?.contains(lockScratch ? "was NOT removed" : "scratch folder was removed") == true, "OUTCOME: \(outcome ?? "nil")")
    }

    /// Codex r2 #6 (P1): the removal failed (EIO) and the existence check
    /// that followed failed too (EIO) while the folder remained —
    /// `fileExists` said false, and the row said "was removed". Only a
    /// confirmed absence (ENOENT) is "removed"; anything else is NOT, with
    /// the removal's error and the path. (A failing disk cannot be made in a
    /// test; the decision is pure, and the caller hands it a fresh lstat's
    /// errno.)
    @Test("CleanupJob: a scratch removal that failed is \"removed\" only when a fresh lstat says ENOENT — an EIO answer is NOT removed, with the path and both errors")
    func aScratchRemovalIsRemovedOnlyWhenConfirmedAbsent() {
        let removal = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let path = "/Volumes/Work/.videoscan-cleanup-1234"
        #expect(CleanupJob.scratchRemovalLine(path: path, removalError: removal, lstatErrno: ENOENT) == nil, "confirmed absent: removed")
        let stillThere = CleanupJob.scratchRemovalLine(path: path, removalError: removal, lstatErrno: 0)
        #expect(stillThere == "The job's scratch folder \(path) was NOT removed: \(removal.localizedDescription).")
        for unreadable in [EIO, EACCES, ENOTDIR, ELOOP] {
            let line = CleanupJob.scratchRemovalLine(path: path, removalError: removal, lstatErrno: unreadable)
            #expect(line == "The job's scratch folder \(path) was NOT removed: \(removal.localizedDescription) "
                    + "(whether it is still there could not be read: \(String(cString: strerror(unreadable)))).",
                    "errno \(unreadable) after a failed removal was taken for \"removed\": \(line ?? "nil")")
        }
    }

    /// Sensor: why an engine throw is enough. CleanupJob publishes and
    /// catalogues only the URL `renderOffMain` RETURNED; a throw goes to
    /// failOrCancel and returns before the publish.
    @Test("sensor: CleanupJob publishes only a render the engine returned, and the engine's verdict is FFmpegEncodeCheck's three-answer one")
    func theJobPublishesOnlyAReturnedRender() throws {
        let job = try SourceTree.appSource(named: "CleanupJob.swift")
        let render = try #require(job.range(of: "rendered = try await Self.renderOffMain("))
        let failed = try #require(job.range(of: "failOrCancel(error, phase: \"render\")\n            return", range: render.upperBound..<job.endIndex))
        let publish = try #require(job.range(of: "try await Self.publishOffMain(render: rendered", range: failed.upperBound..<job.endIndex))
        let catalog = try #require(job.range(of: "await catalogCleanupOutput(publishedURL: published)", range: publish.upperBound..<job.endIndex))
        #expect(catalog.lowerBound > publish.lowerBound)
        let engine = try SourceTree.appSource(named: "CleanupFFmpegEngine.swift")
        #expect(engine.contains("FFmpegEncodeCheck.lengthVerification("))
        #expect(!engine.contains("probeDurationSeconds("), "the nil-means-pass length read is back")
    }
}
