import Combine
import Foundation
import os

// MARK: - TrimJob
//
// "Trim Master…" — Rick 2026-07-16. Cuts the static/garbage head and tail
// off an archival capture with a pure ffmpeg STREAM COPY (`-map 0 -c copy`
// — video, audio, subtitles, data all carried; zero generation loss). The
// canonical case: a 2-hour VHS capture digitized to a ~100 GB FFV1/MKV
// master, with junk before the tape starts and after it ends. The trimmed
// file becomes the clean archival version; the ORIGINAL IS NEVER MODIFIED
// (regression sensor: source SHA-256 identical before/after).
//
// Sibling of TranscodeJob/CleanupJob in the Media File Operations window:
// same state machine, same StallMonitor watchdog, same `.vs-partial` →
// atomic-promote output discipline (a cancel/crash can never leave a
// plausible-looking truncated file at the final name), same non-clobbering
// publish (CleanupJob's M3 pattern — moveItem FAILS if the destination
// exists; on a raced-in collision we re-uniquify and retry the rename).
//
// Accuracy contract (see TrimEngine.swift for the measured -ss study):
//   - intra-only codecs (ffv1 -g1 / prores / dv / …) → frame-accurate cut
//   - long-GOP (h264 / mpeg2 / …) → the cut snaps BACK to the nearest
//     earlier keyframe; honest warning in the sheet, never silent.
//   v1 is stream-copy ONLY — this job never re-encodes, by design.
//
// Post-trim verification: the PARTIAL is ffprobed before promotion —
// video codec unchanged, stream count matches the source, duration within
// the codec-class tolerance of (out − in). A verification failure deletes
// the partial and fails loudly; nothing unverified ever lands at the
// final name. The verification verdict is surfaced in the row summary
// and the trim log.
//
// Memory: ffmpeg streams — a 100 GB trim is I/O-bound and holds no media
// in-process. Worst case in-process is the progress lines plus the
// 256 KB stderr collection cap in ProcessRunner (≈ a few hundred KB).
//
// Cancellation: Task.cancel → ProcessRunner's SIGTERM→SIGKILL escalation
// kills the ffmpeg child; the partial output is removed (the ONE deletion
// this feature performs — a partial temp file of our own making).

private let trimLog = Logger(subsystem: "Rick-Breen.VideoScan",
                             category: "trim")

@MainActor
final class TrimJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .trim
    let startedAt = Date()

    /// Source record being trimmed. READ ONLY on disk.
    let record: VideoRecord

    /// The requested cut, in source seconds.
    let range: TrimRange

    /// PLANNED destination — `<stem>_trimmed.<same ext>` beside the
    /// original, uniquified against files existing at init. The publish
    /// step re-uniquifies (TOCTOU guard, CleanupJob's M3 pattern), so the
    /// ACTUAL destination can differ — see `publishedURL`.
    let outputURL: URL

    /// Where the trimmed file actually landed. nil until publish
    /// succeeds. Equals `outputURL` unless a publish-time collision
    /// forced a bump.
    private(set) var publishedURL: URL?

    /// Codec accuracy class BY NAME, captured at init.
    let codecClass: TrimCodecClass

    /// Packet-flag keyframe probe verdict, when a caller ran the probe
    /// (the trim sheet does): true = all sampled packets are seek points,
    /// false = at least one isn't (the default-GOP FFV1 case), nil =
    /// probe unavailable/undecidable. QA MAJOR 1 (2026-07-17): the sheet
    /// used to run the probe for its banner and throw the verdict away —
    /// the job then worded the DONE summary and sized the verification
    /// tolerance from the codec NAME alone.
    let probedIntra: Bool?

    /// The accuracy class the job actually operates under: the probe can
    /// DOWNGRADE a by-name intra claim (default-GOP FFV1 snaps like
    /// long-GOP, and its verification tolerance must widen with it),
    /// never upgrade one — 60 all-K packets don't prove a long-GOP file
    /// is intra. Drives BOTH the summary wording and the verification
    /// tolerance.
    var effectiveCodecClass: TrimCodecClass {
        if codecClass == .intraOnly, probedIntra == false { return .longGOP }
        return codecClass
    }

    /// The honest accuracy word in the DONE log / appLog summary.
    var accuracySummaryWord: String {
        effectiveCodecClass.claimsFrameAccuracy ? "frame-accurate" : "keyframe-aligned"
    }

    /// Weak — the model owns jobs via MediaFileOperationsCenter.
    private weak var model: VideoScanModel?

    #if DEBUG
    /// TEST SEAM ONLY: extra ffmpeg INPUT options inserted before `-ss`.
    /// The cancel-mid-trim tests pass `["-readrate", "0.1"]` to slow the
    /// copy to 10% realtime so a cancel deterministically lands mid-run;
    /// the exit-code sensor injects an unknown input format. `#if DEBUG`
    /// makes "never in production" a compiler guarantee, not a comment
    /// (QA MINOR 5, 2026-07-17 — the test target builds Debug).
    var debugExtraInputArgs: [String] = []
    #endif

    /// Pause via SIGSTOP/SIGCONT on the live ffmpeg child (GH #150) —
    /// JobPauseCoordinator parks the stall watchdog while suspended.
    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
    }

    func resume() {
        guard pauser.resume() else { return }
        isPausedValue = false
    }

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    /// Terminal-transition stamp — freezes the row clock (see
    /// MediaFileOperationClock). Set exactly once by state's didSet.
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String = "Preparing trim…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Set by the stall watchdog; wins over the generic cancel branch
    /// (the watchdog cancels the Task, which also trips Task.isCancelled).
    private var stallReason: String?

    /// True when the Center's dedupe guard refused this job before it
    /// ever ran — flips the file-log OUTCOME line from "trim FAILED:"
    /// to "trim refused:" (see MediaFileOperationJob.wasRefused).
    private(set) var wasRefused = false

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    /// `plannedOutput` lets the trim sheet hand over the exact destination
    /// it displayed (computed once in TrimRequest); nil (programmatic
    /// callers, tests) computes it here.
    init(record: VideoRecord,
         range: TrimRange,
         model: VideoScanModel,
         plannedOutput: URL? = nil,
         probedIntra: Bool? = nil) {
        self.record = record
        self.range = range
        self.model = model
        self.codecClass = TrimCodecClassifier.classify(videoCodec: record.videoCodec)
        self.probedIntra = probedIntra
        self.outputURL = plannedOutput
            ?? Self.trimmedOutputURL(forSourcePath: record.fullPath)
    }

    /// Start the trim. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runTrim()
        }
    }

    /// Refusal path for MediaFileOperationsCenter's same-record dedupe
    /// guard (QA MAJOR 2, 2026-07-17): two concurrent trims of one record
    /// share the `.vs-partial` path — the second job's stale-partial
    /// cleanup would unlink the first job's in-flight output. The Center
    /// parks the refused job as a visible FAILED row (same loud-reason
    /// discipline as the preflight guards) without ever starting it.
    /// The no-op task makes a later `start()` inert and lets callers
    /// `await job.task?.value` uniformly.
    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    /// Cancel the in-flight ffmpeg. Task.cancel propagates into
    /// ProcessRunner, which terminates the child (SIGTERM → SIGKILL).
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Run

    private func runTrim() async {
        let inputPath = record.fullPath
        let partialPath = ReformatJob.partialURL(for: outputURL).path
        let volumeLabel = VolumeReachability.displayLabel(forPath: inputPath)
        // (videoscan.log START line is written by the Center's
        // startTrim — one choke point for every MFO verb.)
        trimLog.info("trim START: \(self.record.filename, privacy: .public) [\(TrimTimecode.format(self.range.inSeconds), privacy: .public) → \(TrimTimecode.format(self.range.outSeconds), privacy: .public)] on \(volumeLabel, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public) (codec class \(self.codecClass.rawValue, privacy: .public))")

        // ---- Preflight guards (each fails loudly with a specific reason).

        // Video stream required — the menu gates on it, but programmatic
        // callers must not slip an audio-only record through.
        guard record.streamType == .videoAndAudio || record.streamType == .videoOnly else {
            finish(failed: "Trim Master needs a video stream — \(record.filename) has none (\(record.streamTypeRaw.isEmpty ? "unknown streams" : record.streamTypeRaw))")
            return
        }
        guard FileManager.default.fileExists(atPath: inputPath) else {
            finish(failed: "Source file missing on disk")
            return
        }
        let ffmpeg = ToolLocator.ffmpegPath
        guard !ffmpeg.isEmpty, FileManager.default.fileExists(atPath: ffmpeg) else {
            finish(failed: "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
            return
        }
        let ffprobe = ToolLocator.ffprobePath
        guard !ffprobe.isEmpty, FileManager.default.fileExists(atPath: ffprobe) else {
            finish(failed: "ffprobe not found (set VS_FFPROBE_PATH or install via Homebrew) — trims are always verified, so ffprobe is required")
            return
        }

        // Range validation against the cataloged duration (0 = unknown —
        // in<out still enforced, the out-bound check is skipped).
        do {
            try TrimPlan.validate(range: range, sourceDuration: record.durationSeconds)
        } catch let err as TrimPlanError {
            finish(failed: err.friendlyMessage)
            return
        } catch {
            finish(failed: error.localizedDescription)
            return
        }

        // Free-space precheck: estimated output = source × kept fraction
        // + margin (TrimPlan). Unavailable capacity info ⇒ proceed (the
        // write itself will fail loudly if space runs out).
        let estimate = TrimPlan.estimatedOutputBytes(sourceBytes: record.sizeBytes,
                                                     sourceDuration: record.durationSeconds,
                                                     range: range)
        let destDir = outputURL.deletingLastPathComponent()
        if let values = try? destDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available > 0 {
            if estimate > available {
                finish(failed: "Not enough free space on \(VolumeReachability.displayLabel(forPath: destDir.path)) — the trimmed file needs about \(Formatting.humanSize(estimate)), only \(Formatting.humanSize(available)) is free")
                return
            }
        } else {
            // Leave a trail: a skipped precheck is a diagnosis clue when
            // the write later dies mid-copy on a full volume.
            trimLog.notice("trim: free-space precheck skipped — volume capacity unavailable for \(destDir.path, privacy: .public)")
        }

        // Clean up a stale partial from a prior cancelled run. The FINAL
        // name is never pre-deleted — publish is non-clobbering.
        await Self.removeFileOffMain(atPath: partialPath)

        // ---- ffmpeg stream-copy trim (input seek — see TrimEngine.swift).
        #if DEBUG
        var args = TrimPlan.ffmpegArgs(input: inputPath,
                                       partialOutput: partialPath,
                                       range: range)
        if !debugExtraInputArgs.isEmpty {
            // Test seam: input options must precede -ss/-i. Index 3 =
            // right after "-hide_banner -nostdin -y".
            args.insert(contentsOf: debugExtraInputArgs, at: 3)
        }
        #else
        let args = TrimPlan.ffmpegArgs(input: inputPath,
                                       partialOutput: partialPath,
                                       range: range)
        #endif

        subtitleText = "Trimming — copying the good part, no re-encode…"
        isIndeterminateValue = (range.duration <= 0)
        trimLog.info("trim: ffmpeg \(args.joined(separator: " "), privacy: .public)")

        // Stall watchdog: every ffmpeg progress line kicks it; silence past
        // the threshold (sleeping /Volumes drive) kills the job with
        // attribution instead of hanging.
        let monitor = StallMonitor(label: "trim \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(silentFor: silentFor)
            }
        }
        let cutDuration = range.duration
        let progressUpdater: @Sendable (String) -> Void = { [weak self] line in
            monitor.tick()
            guard let self else { return }
            guard let sec = ReformatJob.parseProgressSeconds(line: line),
                  cutDuration > 0 else { return }
            Task { @MainActor in
                self.applyProgressFraction(min(1.0, sec / cutDuration))
            }
        }

        let copyStart = Date()
        monitor.start()
        pauser.register(monitor)
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: args,
            stderrLine: progressUpdater,
            control: pauser.control
        )
        monitor.stop()
        let elapsed = Date().timeIntervalSince(copyStart)

        // Watchdog stall wins over a generic cancel (the watchdog cancels
        // the Task) — surface the specific cause, not "Cancelled".
        if let stallReason {
            await Self.removeFileOffMain(atPath: partialPath)
            trimLog.error("trim FAILED (stall): \(self.record.filename, privacy: .public) — \(stallReason, privacy: .public)")
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            // The ONE deletion this feature performs: our own partial.
            await Self.removeFileOffMain(atPath: partialPath)
            trimLog.info("trim cancelled: \(self.record.filename, privacy: .public) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s — partial removed, nothing at the final name")
            finishCancelled()
            return
        }
        guard result.exitCode == 0 else {
            await Self.removeFileOffMain(atPath: partialPath)
            let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
            finish(failed: "ffmpeg failed (exit \(result.exitCode))\(tail.isEmpty ? "" : ": \(tail)")")
            return
        }
        guard FileManager.default.fileExists(atPath: partialPath) else {
            finish(failed: "ffmpeg finished but no output file was produced")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: partialPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 10_000 {
            await Self.removeFileOffMain(atPath: partialPath)
            finish(failed: "ffmpeg output too small (\(size) bytes) — likely a muxer failure")
            return
        }

        // ---- Verify the PARTIAL before promotion: codec unchanged,
        // stream count matches, duration within the codec-class tolerance.
        subtitleText = "Verifying the trimmed copy…"
        let verification = await verifyTrim(ffprobe: ffprobe,
                                            source: inputPath,
                                            output: partialPath)
        if Task.isCancelled || state == .cancelling {
            await Self.removeFileOffMain(atPath: partialPath)
            finishCancelled()
            return
        }
        let verifyDetail: String
        switch verification {
        case .failed(let reason):
            await Self.removeFileOffMain(atPath: partialPath)
            trimLog.error("trim VERIFY FAILED: \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
            // (The Center's "trim FAILED:" OUTCOME line carries this
            // same reason — no separate appLog write here.)
            finish(failed: "Verification failed — \(reason). No file was published; the original is untouched.")
            return
        case .verified(let detail):
            trimLog.info("trim verify PASS: \(self.outputURL.lastPathComponent, privacy: .public) — \(detail, privacy: .public)")
            verifyDetail = detail
        }

        // ---- Non-clobbering promote (CleanupJob's M3 pattern): rename
        // the verified partial to a freshly-uniquified final name.
        let published: URL
        do {
            published = try await Self.promoteOffMain(partialPath: partialPath,
                                                      preferredOutput: outputURL,
                                                      sourcePath: inputPath)
        } catch {
            await Self.removeFileOffMain(atPath: partialPath)
            finish(failed: "Could not finalize output file: \(error.localizedDescription)")
            return
        }
        publishedURL = published
        if published != outputURL {
            trimLog.notice("trim publish: planned name \(self.outputURL.lastPathComponent, privacy: .public) was taken — published as \(published.lastPathComponent, privacy: .public)")
        }

        // ---- Catalog + provenance.
        await catalogTrimOutput(publishedURL: published)

        let accuracy = accuracySummaryWord
        trimLog.info("trim DONE: \(self.record.filename, privacy: .public) → \(published.lastPathComponent, privacy: .public) (\(Formatting.humanSize(size), privacy: .public)) copy \(elapsed, format: .fixed(precision: 1), privacy: .public)s — \(accuracy, privacy: .public)")
        // (The Center's "trim done:" OUTCOME line carries this same
        // summary — no separate appLog write here.)
        finish(success: "Trimmed → \(published.lastPathComponent) (\(Formatting.humanSize(size))). Verified: \(verifyDetail). Original untouched.")
    }

    // MARK: Verification

    enum TrimVerification: Equatable {
        case verified(detail: String)
        case failed(reason: String)
    }

    /// ffprobe both files (header reads — cheap even on 100 GB) and check
    /// the three invariants of a faithful stream-copy trim.
    private func verifyTrim(ffprobe: String,
                            source: String,
                            output: String) async -> TrimVerification {
        guard let srcProbe = await Self.probeStreams(ffprobe: ffprobe, path: source) else {
            return .failed(reason: "could not re-read the source file's streams")
        }
        guard let outProbe = await Self.probeStreams(ffprobe: ffprobe, path: output) else {
            return .failed(reason: "could not read the trimmed file's streams")
        }
        return Self.evaluateVerification(source: srcProbe,
                                         output: outProbe,
                                         expectedDuration: range.duration,
                                         codecClass: effectiveCodecClass)
    }

    /// PURE verdict logic — unit-tested without subprocesses.
    nonisolated static func evaluateVerification(source: StreamProbe,
                                                 output: StreamProbe,
                                                 expectedDuration: Double,
                                                 codecClass: TrimCodecClass) -> TrimVerification {
        if let srcCodec = source.videoCodecName {
            guard output.videoCodecName == srcCodec else {
                return .failed(reason: "video codec changed (\(srcCodec) → \(output.videoCodecName ?? "none")) — a stream copy must never re-encode")
            }
        }
        guard output.streamCount == source.streamCount else {
            return .failed(reason: "stream count changed (\(source.streamCount) → \(output.streamCount)) — all source streams must be carried")
        }
        let tolerance = TrimPlan.verificationTolerance(for: codecClass)
        if expectedDuration > 0 {
            // A file we JUST wrote whose duration can't be read (≤ 0 —
            // exactly what an in-flight/truncated MKV reports) is
            // suspicious, not a free pass. Fail-honest is the feature's
            // contract (QA MAJOR 2, 2026-07-17).
            guard output.durationSeconds > 0 else {
                return .failed(reason: "the trimmed file reports no readable duration — a freshly written file with an unreadable duration is treated as truncated")
            }
            let delta = abs(output.durationSeconds - expectedDuration)
            guard delta <= tolerance else {
                return .failed(reason: "duration off by \(String(format: "%.1f", delta))s (got \(TrimTimecode.format(output.durationSeconds)), asked \(TrimTimecode.format(expectedDuration)), tolerance \(String(format: "%.1f", tolerance))s)")
            }
        }
        let codec = output.videoCodecName ?? "video"
        return .verified(detail: "\(codec) unchanged, \(output.streamCount) stream\(output.streamCount == 1 ? "" : "s") carried, duration \(TrimTimecode.format(output.durationSeconds))")
    }

    /// Minimal stream/format probe — codec of v:0, total stream count,
    /// container duration.
    struct StreamProbe: Equatable, Sendable {
        let videoCodecName: String?
        let streamCount: Int
        let durationSeconds: Double
    }

    private struct ProbeJSON: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]?
        let format: Format?
    }

    /// Runs ffprobe with a deadline (dead-volume guard) and decodes the
    /// JSON. nil on any failure — callers treat that as a loud verify fail.
    nonisolated static func probeStreams(ffprobe: String, path: String) async -> StreamProbe? {
        let result = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: ["-v", "error",
                        "-show_entries", "stream=codec_type,codec_name",
                        "-show_entries", "format=duration",
                        "-of", "json", path],
            deadlineSeconds: 60)
        guard result.exitCode == 0,
              let stdout = result.stdout,
              let parsed = try? JSONDecoder().decode(ProbeJSON.self, from: Data(stdout.utf8)),
              let streams = parsed.streams, !streams.isEmpty else { return nil }
        let videoCodec = streams.first { $0.codec_type == "video" }?.codec_name
        let duration = Double(parsed.format?.duration ?? "") ?? 0
        return StreamProbe(videoCodecName: videoCodec,
                           streamCount: streams.count,
                           durationSeconds: duration)
    }

    // MARK: Off-main file-system hops (QA MINOR 6)

    // FileManager calls made straight from @MainActor runTrim execute ON
    // the main thread — `nonisolated` runs on the CALLER's actor in this
    // repo's Approachable Concurrency configuration (the documented
    // trap). These `@concurrent` statics force the global executor;
    // runTrim awaits each one, so the state machine's ORDERING is
    // unchanged — every state transition still happens on MainActor,
    // after the file work completes. The thread assertions turn every
    // Debug end-to-end trim test into a regression sensor for this.

    /// Delete our own partial (the ONE deletion this feature performs)
    /// off the main actor. Internal so the thread-discipline test can
    /// drive it directly.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func removeFileOffMain(atPath path: String) async {
        #if compiler(>=6.2)
        assert(!Thread.isMainThread,
               "trim cleanup must not run file deletion on the main thread (QA MINOR 6)")
        #endif
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The non-clobbering promote, hopped off the main actor (the rename
    /// is instant same-volume, but the uniquify loop stats the directory
    /// — none of it belongs on main). Internal for the same test reason.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func promoteOffMain(partialPath: String,
                               preferredOutput: URL,
                               sourcePath: String) async throws -> URL {
        #if compiler(>=6.2)
        assert(!Thread.isMainThread,
               "trim publish must not run rename/stat work on the main thread (QA MINOR 6)")
        #endif
        return try promoteNonClobbering(partialPath: partialPath,
                                        preferredOutput: preferredOutput,
                                        sourcePath: sourcePath)
    }

    // MARK: Publish

    /// Rename the verified partial to a final name that is guaranteed not
    /// to overwrite anything. Re-uniquifies at publish time (the name
    /// planned at sheet time is stale after a minutes-long copy), and
    /// retries the (same-volume, instant) rename on a raced-in collision.
    /// Deliberately NOT ReformatJob.atomicPublish — that helper replaces
    /// an existing destination, which is wrong here.
    nonisolated static func promoteNonClobbering(partialPath: String,
                                                 preferredOutput: URL,
                                                 sourcePath: String) throws -> URL {
        let fm = FileManager.default
        // A name is taken when the final exists, or when ANOTHER job's
        // partial sits beside it. Our OWN partial (the payload being
        // promoted) must not count — otherwise every publish would bump
        // one name past its plan.
        let taken: (String) -> Bool = { path in
            if fm.fileExists(atPath: path) { return true }
            let siblingPartial = ReformatJob.partialURL(for: URL(fileURLWithPath: path)).path
            return siblingPartial != partialPath && fm.fileExists(atPath: siblingPartial)
        }
        var candidate = preferredOutput
        if taken(candidate.path) {
            candidate = trimmedOutputURL(forSourcePath: sourcePath, fileExists: taken)
        }
        var attempts = 0
        while true {
            do {
                try fm.moveItem(atPath: partialPath, toPath: candidate.path)
                return candidate
            } catch {
                attempts += 1
                guard attempts < 100, fm.fileExists(atPath: candidate.path) else {
                    throw error
                }
                candidate = trimmedOutputURL(forSourcePath: sourcePath, fileExists: taken)
            }
        }
    }

    // MARK: Output naming

    /// `<stem>_trimmed.<same container ext>` beside the original; on
    /// collision, Finder-style counters: `<stem>_trimmed 2.<ext>`, ….
    /// Same shape as CleanupJob.cleanedOutputURL, but the extension is
    /// PRESERVED — a stream copy keeps the container, so the trimmed
    /// FFV1/MKV master stays a `.mkv`. `fileExists` is injected so the
    /// uniquify loop is pure-testable.
    nonisolated static func trimmedOutputURL(
        forSourcePath path: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let src = URL(fileURLWithPath: path)
        let dir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        func candidateURL(_ base: String) -> URL {
            let name = ext.isEmpty ? base : "\(base).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var candidate = candidateURL("\(stem)_trimmed")
        var n = 2
        while fileExists(candidate.path) {
            candidate = candidateURL("\(stem)_trimmed \(n)")
            n += 1
        }
        return candidate
    }

    // MARK: Progress

    /// Single, state-guarded write path for progress fractions — a
    /// straggler beat must never drag a finished bar back below 1.0
    /// (CleanupJob's m2 guard). Internal so tests can pin it.
    func applyProgressFraction(_ fraction: Double) {
        guard state.isActive else { return }
        fractionValue = fraction
        isIndeterminateValue = false
    }

    // MARK: Stall handling

    private func handleStall(silentFor: Double) {
        guard state.isActive, stallReason == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no ffmpeg progress for \(Int(silentFor))s during trim. \(attribution)"
        stallReason = reason
        subtitleText = "Stalled — stopping…"
        trimLog.error("trim WATCHDOG: killing \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("trim watchdog: \(record.filename) stalled \(Int(silentFor))s — \(attribution); killing ffmpeg")
        task?.cancel()
    }

    // MARK: Catalog + provenance

    /// Probe the trimmed file and register it in the catalog with full
    /// provenance: `derivationKind` = "trim" (the universal which-verb
    /// marker, shared with Balance Audio et al.), `derivedFrom` = source
    /// record id, plus the trim-specific payload
    /// (trimInSeconds/trimOutSeconds — present only on trim derivatives;
    /// all additive-optional schema fields). File Journey
    /// notes on BOTH records, a search-index update so the new file is
    /// findable immediately, and a catalog-mutated notification so the
    /// debounced save persists it.
    /// The ORIGINAL record's disposition is untouched — Rick decides
    /// separately what happens to the raw capture.
    private func catalogTrimOutput(publishedURL: URL) async {
        guard let model else { return }
        let newRec = await model.probeFile(url: publishedURL)

        newRec.derivationKind = TrimPlan.derivationKind
        newRec.derivedFrom = record.id
        newRec.trimInSeconds = range.inSeconds
        newRec.trimOutSeconds = range.outSeconds
        // Estimated date (GH #117): a trimmed master is the same footage,
        // so Rick's hand-entered date carries over with its confidence.
        newRec.userDate = record.userDate
        newRec.userDateConfidence = record.userDateConfidence

        let stamp = ISO8601DateFormatter().string(from: Date())
        let rangeText = "\(TrimTimecode.format(range.inSeconds))–\(TrimTimecode.format(range.outSeconds))"
        let sourceNote = "Trim \(stamp): Created trimmed master \(publishedURL.lastPathComponent) (kept \(rangeText), stream copy — no re-encode)"
        let derivedNote = "Trim \(stamp): Trimmed from \(record.filename) (kept \(rangeText), stream copy — no re-encode)"

        record.notes = record.notes.isEmpty
            ? sourceNote
            : "\(record.notes)\n\(sourceNote)"
        newRec.notes = newRec.notes.isEmpty
            ? derivedNote
            : "\(newRec.notes)\n\(derivedNote)"

        if let existing = model.records.firstIndex(where: { $0.fullPath == publishedURL.path }) {
            model.records[existing] = newRec
        } else {
            model.records.append(newRec)
        }
        // Index the new record (and the source's updated notes) so the
        // trimmed file is searchable without a relaunch, then post one
        // mutation notification → debounced catalog save (a crash after
        // a long trim must not orphan the provenance).
        model.searchIndex.update(newRec)
        model.searchIndex.update(record)
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)

        trimLog.info("trim: catalogued \(publishedURL.lastPathComponent, privacy: .public) (derivedFrom=\(self.record.id.uuidString, privacy: .public), range \(TrimTimecode.format(self.range.inSeconds), privacy: .public)–\(TrimTimecode.format(self.range.outSeconds), privacy: .public))")
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        trimLog.warning("trim failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        state = .cancelled
        subtitleText = "Cancelled — nothing was written"
        isIndeterminateValue = false
    }

}
