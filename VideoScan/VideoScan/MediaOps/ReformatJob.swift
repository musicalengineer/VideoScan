import Combine
import Foundation
import os

// MARK: - ReformatJob
//
// "Reformat and Analyze" — Rick 2026-06-14. One ffmpeg subprocess that
// transcodes a legacy-codec source (svq3 / qdm2 / cinepak / indeo / rpza /
// etc.) into a modern HEVC/AAC .mp4 with conventional ffmpeg quality
// filters in line, then auto-catalogs the output and queues it for the
// in-app analyzer.
//
// Why this exists: VideoScan's analyzer goes through AVFoundation, which
// stopped decoding several proprietary QuickTime codecs in macOS 10.15.
// ffmpeg still decodes them fine — so a one-pass transcode bridges old
// archival captures into the analyzable pool. The output file lands
// beside the original (same directory, `<stem>.vs.hevc.<timestamp>.mp4`);
// the original is left untouched.
//
// ffmpeg pipeline (chosen for typical 1990s-2000s home-video captures):
//   - bwdif=mode=send_field:parity=auto   Bob Weaver deinterlace,
//                                         output every field as a frame.
//                                         Drops to no-op on progressive.
//   - hqdn3d=4:3:6:4.5                    Moderate 3D denoise — luma
//                                         spatial 4, chroma spatial 3,
//                                         luma temporal 6, chroma 4.5.
//   - hevc_videotoolbox                   Hardware HEVC on Apple Silicon.
//                                         -q:v 65 constant-quality knob.
//   - aac_at 192k                         Modern audio. Avoids the qdm2
//                                         double-lossy reuse trap.
//
// Cancellation: the job owns its run Task. Task.cancel() propagates into
// ProcessRunner, which terminates the ffmpeg subprocess. This run's own
// partial is removed in the cleanup path so a cancelled job doesn't leave a
// truncated file masquerading as a successful reformat.
//
// Progress: parsed from ffmpeg's stderr `out_time` / `time=` lines
// against the input duration. Indeterminate during model load / probe.
//
// Stall watchdog (#6, Rick 2026-06-30): the encode runs under a
// `StallMonitor`. Every ffmpeg progress line kicks the watchdog; if the
// op flatlines for `StallMonitor.defaultStallThresholdSeconds` (a sleeping
// /Volumes drive mid-read), the watchdog cancels the run — which kills the
// ffmpeg child via ProcessRunner's SIGTERM→SIGKILL escalation — and the job
// fails CLEANLY with a specific reason instead of hanging for hours.
//
// Atomic output (#6.3): ffmpeg writes to a partial beside the output and
// the partial is published to the final name ONLY after the encode passes
// the exit-code, length and size checks. A killed/stalled op leaves only
// the partial (which we remove) — never a truncated file at the real name.
//
// The partial is RESERVED per run (N1014-F1, 2026-10-07):
// `<output stem>.<8 hex>.vs-partial.mp4`, created O_EXCL and registered live
// through DerivativeOutputPublish.reservePartial — the publisher Transcode
// and Combine use — and removed only through PartialFileNaming.remove.
// It used to be the fixed `<output stem>.vs-partial.mp4`, cleared with an
// unconditional removeItem before every encode. The output stem is the
// SOURCE stem plus a one-second timestamp, so a batch Reformat of `a.avi`
// and `a.mov` gave both jobs the same partial: job B's start unlinked the
// file job A's ffmpeg was writing, A could then publish B's half-written
// encode, and either job's cleanup could delete the other's work.
// (For Rick: O_EXCL reservation ≈ mkstemp — the name is ours alone before
// ffmpeg opens it with `-y`.)

private let reformatLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                 category: "fileOps")

@MainActor
final class ReformatJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .reformat
    let startedAt = Date()

    /// Source record being reformatted.
    let record: VideoRecord

    /// Where the new .mp4 will land. Computed once at init.
    let outputURL: URL

    /// Where it actually landed: `outputURL`, or "name 2.mp4" beside it
    /// when that name was taken (2026-09-22 — the finished encode is kept,
    /// never deleted, and nothing already there is replaced).
    private(set) var publishedURL: URL

    /// Weak reference to the model so the success-side wiring can
    /// catalog the new file and queue it for analyze. Avoids a retain
    /// cycle since the model holds Jobs via MediaFileOperationsCenter.
    private weak var model: VideoScanModel?
    private weak var orchestrator: CaptionOrchestrator?

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
    @Published private(set) var subtitleText: String = "Preparing ffmpeg…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Total source duration in seconds, set after probe. Used for the
    /// fraction calculation.
    private var totalDurationSeconds: Double = 0

    /// Set-once ledger of the first terminal cause (watchdog stall vs the
    /// user's Stop) — see MFOTerminalCause. `stallReason` reads through it.
    /// A watchdog kill ends `.failed` with a specific reason; a user cancel
    /// ends `.cancelled`. Checked before the generic cancel branch because
    /// the watchdog cancels the Task, which also sets `Task.isCancelled`.
    private var terminalCause = MFOTerminalCause()
    private var stallReason: String? { terminalCause.stallReason }

    /// MediaFileOperationJob requires `objectWillChange` ==
    /// ObservableObjectPublisher, which is the default for ObservableObject.

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    init(record: VideoRecord,
         model: VideoScanModel,
         orchestrator: CaptionOrchestrator?) {
        self.record = record
        self.model = model
        self.orchestrator = orchestrator
        // Standardized derived-URL convention (Rick 2026-06-14):
        //   <stem>.vs.hevc.<YYYYMMDD-HHMMSS>.mp4
        // beside the source. See DerivedFileNaming.swift. A file already
        // at that name is never replaced: the publish lands beside it.
        let srcURL = URL(fileURLWithPath: record.fullPath)
        self.outputURL = derivedFileURL(
            source: srcURL,
            codec: "hevc",
            ext: "mp4"
        )
        self.publishedURL = self.outputURL
    }

    /// Start the reformat. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runReformat()
        }
    }

    /// Cancel the in-flight ffmpeg. Task.cancel propagates into
    /// ProcessRunner.runStreaming which terminates the subprocess.
    func cancel() {
        guard state.isActive else { return }
        // A stall recorded first owns the terminal (codex gate 2026-08-26):
        // the watchdog is already killing the Task, the row keeps
        // "Stalled — stopping…" and ends Failed with the stall reason —
        // never Cancelled. Otherwise the user's Stop is the first cause.
        if terminalCause.record(.cancel) {
            state = .cancelling
            subtitleText = "Cancelling…"
        }
        task?.cancel()
    }

    // MARK: Reformat run

    private func runReformat() async {
        // The record already carries durationSeconds from the catalog scan;
        // 0 (missing) just means indeterminate progress.
        totalDurationSeconds = max(0, record.durationSeconds)

        let inputPath = record.fullPath
        let volumeLabel = VolumeReachability.displayLabel(forPath: inputPath)
        reformatLog.info("reformat START: \(self.record.filename, privacy: .public) on \(volumeLabel, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")

        guard FileManager.default.fileExists(atPath: inputPath) else {
            await finish(failed: "Source file missing on disk")
            return
        }

        let ffmpeg = ToolLocator.ffmpegPath
        guard !ffmpeg.isEmpty, FileManager.default.fileExists(atPath: ffmpeg) else {
            await finish(failed: "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
            return
        }

        // Reserve THIS run's partial (O_EXCL + registered live — see the
        // file header, N1014-F1). Every exit of this run releases it;
        // removals go through PartialFileNaming.remove.
        let partialURL: URL
        do {
            partialURL = try DerivativeOutputPublish.reservePartial(for: outputURL)
        } catch {
            reformatLog.error("reformat FAILED (reserve partial): \(self.record.filename, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            await finish(failed: "Could not create the output file: \(error.localizedDescription)")
            return
        }
        defer { PartialFileNaming.unregisterLive(partialURL) }
        let partialPath = partialURL.path

        let args = Self.reformatArgs(input: inputPath, output: partialPath)
        subtitleText = "Transcoding to H.264/AAC…"
        isIndeterminateValue = (totalDurationSeconds == 0)

        reformatLog.info("reformat: ffmpeg \(args.joined(separator: " "), privacy: .public)")

        let encodeStart = Date()
        let encodeResult = await runEncode(ffmpeg: ffmpeg, args: args, inputPath: inputPath)
        let elapsed = Date().timeIntervalSince(encodeStart)

        // Watchdog stall wins over a generic cancel: the watchdog cancels
        // the Task (setting Task.isCancelled), so check stallReason FIRST so
        // the user sees the specific cause, not "Cancelled".
        if let stallReason {
            discardPartial(partialURL)
            reformatLog.error("reformat FAILED (stall): \(self.record.filename, privacy: .public) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s — \(stallReason, privacy: .public)")
            await finish(failed: stallReason)
            return
        }

        // Was it cancelled mid-run?
        if Task.isCancelled || state == .cancelling {
            discardPartial(partialURL)
            reformatLog.info("reformat cancelled: \(self.record.filename, privacy: .public) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
            await finish(cancelled: true)
            return
        }

        // Gate, then publish — or the job has been finished as failed /
        // cancelled there and nothing was published.
        guard let published = await verifyThenPublish(encodeResult, inputPath: inputPath, partialURL: partialURL) else { return }
        let size = published.size

        // Catalog + queue for analyze.
        await catalogAndQueueAnalyze()

        reformatLog.info("reformat DONE: \(self.record.filename, privacy: .public) → \(self.publishedURL.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public)) in \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
        await finish(success: "Reformatted → \(publishedURL.lastPathComponent) (\(Self.humanBytes(size))). Queued for analysis.\(published.note)")
    }

    /// The gate between the finished encode and its publish, then the
    /// publish itself. Returns the new file's size once it is PUBLISHED
    /// (and the note for a source whose length could not be compared —
    /// Reformat never replaces, so that is a note, not a refusal); nil
    /// when the job has been finished here (failed, unverified, stopped)
    /// — in which case nothing was published.
    private func verifyThenPublish(_ encodeResult: ProcessRunner.Result, inputPath: String,
                                   partialURL: URL) async -> (size: Int64, note: String)? {
        let partialPath = partialURL.path
        // The ONE gate Transcode uses (TranscodeJob+EncodeGate.swift): exit
        // code, then length, then "something was written" and the 10 KB
        // floor — and VERIFIED: both lengths read and in agreement (GH
        // #502, Rick 2026-11-21). THE BUG: the old "failure or nil" check
        // answered nil when a length could not be read, and nil was read
        // as leave to publish — an output ffprobe could not measure was
        // published, reported "Reformatted" and adopted into the catalog.
        // A partial that fails the gate is removed; nothing is published.
        let size: Int64
        let verified: PartialFileNaming.FileStamp
        var note = ""
        switch await TranscodeJob.encodeGate(encodeResult, inputPath: inputPath, partialPath: partialPath) {
        case .failed(let failure, let stage):
            discardPartial(partialURL)
            reformatLog.error("reformat FAILED (\(stage, privacy: .public)): \(self.record.filename, privacy: .public) — \(failure, privacy: .public)")
            await finish(failed: failure)
            return nil
        case .unverified(let cause):
            await refuseUnverified(cause: cause, partial: partialURL)
            return nil
        case .passed(let bytes, let stamp):
            size = bytes
            verified = stamp
        case .notCompared(let bytes, let stamp, let why):
            size = bytes
            verified = stamp
            note = " " + FFmpegEncodeCheck.lengthNotComparedNote
            appLog.write("reformat: \(record.filename) has no readable duration (\(why)) — the new file's length was read but not compared")
        }

        // A Stop (or a stall) that landed while the gate's probes were out
        // is still a Stop: a good answer does not publish over it.
        if await stoppedBeforePublish(partialURL) { return nil }

        // Atomic publish: the encode is complete, non-trivial and verified
        // — promote the partial to the real output name in one rename
        // (#6.3), after checking it is still the file that was verified.
        // A taken name keeps BOTH files: the new one lands beside it.
        do {
            let outcome = try await TranscodeJob.publishVerified(
                partial: partialPath, final: outputURL, policy: .keep(reason: "a file already has that name"),
                archiveCheck: nil, trash: { _ in nil }, verified: verified)
            publishedURL = outcome.url
            if case .publishedBeside(let url, let kept, _) = outcome {
                reformatLog.notice("reformat: \(kept.lastPathComponent, privacy: .public) already existed — kept; new file published as \(url.lastPathComponent, privacy: .public)")
            }
        } catch is CancellationError {
            // Stop before anything was renamed: nothing was published.
            if !(await stoppedBeforePublish(partialURL)) {
                discardPartial(partialURL)
                await finish(cancelled: true)
            }
            return nil
        } catch is TranscodeJob.ChangedSinceVerified {
            await refuseUnverified(cause: TranscodeJob.changedAfterVerification, partial: partialURL)
            return nil
        } catch {
            // The finished encode is kept — moved OFF the partial pattern
            // (`.vs-kept.`, no-clobber) so no stale sweep can remove it once
            // this run releases its reservation — and its path is named.
            let kept = await Self.keepUnpublishedOffMain(partialURL)
            reformatLog.error("reformat FAILED (publish): \(self.record.filename, privacy: .public) — \(error.localizedDescription, privacy: .public) — encode kept at \(kept.path, privacy: .public)")
            appLog.write("reformat: \(record.filename) finished but not published (\(error.localizedDescription)) — encode kept at \(kept.path)")
            await finish(failed: "Could not finalize output file: \(error.localizedDescription) — the encode is kept at \(kept.path)")
            return nil
        }
        return (size, note)
    }

    /// Apple Silicon optimization (Rick 2026-06-14):
    ///   - hevc_videotoolbox encodes ~30-40% smaller than h264 for
    ///     equivalent quality, using the same M-series media engine
    ///     (no extra CPU/GPU cost on M4).
    ///   - "-tag:v hvc1" so QuickTime Player decodes natively on
    ///     macOS / iOS / AppleTV. Without this, the default "hev1"
    ///     tag forces software fallback on some Apple players even
    ///     though the bitstream is identical.
    ///   - aac_at uses Apple AudioToolbox's AAC encoder — slightly
    ///     better quality than libavcodec's aac at the same bitrate
    ///     and offloads to the audio coprocessor.
    /// `-y` only lets ffmpeg open this run's 0-byte reservation. Pure.
    nonisolated static func reformatArgs(input: String, output: String) -> [String] {
        [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-hwaccel", "videotoolbox",
            "-i", input,
            "-vf", "bwdif=mode=send_field:parity=auto,hqdn3d=4:3:6:4.5",
            "-c:v", "hevc_videotoolbox",
            "-q:v", "65",
            "-tag:v", "hvc1",
            "-c:a", "aac_at",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-progress", "pipe:2",
            output
        ]
    }

    /// Run the encode under the stall watchdog. Every stderr line (ffmpeg
    /// emits progress blocks continuously while it makes forward progress)
    /// kicks the monitor; silence past the threshold ⇒ the volume stalled ⇒
    /// kill + fail. Both `time=HH:MM:SS.xx` and `out_time=HH:MM:SS.xxxxx`
    /// count as progress (`-progress pipe:2` emits the structured lines).
    /// The exit status is returned — it is the verdict's first half
    /// (2026-09-19: it used to be thrown away).
    private func runEncode(ffmpeg: String, args: [String], inputPath: String) async -> ProcessRunner.Result {
        let totalDur = totalDurationSeconds  // capture for the closure
        let monitor = StallMonitor(label: "reformat \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(inputPath: inputPath, silentFor: silentFor)
            }
        }
        let progressUpdater: @Sendable (String) -> Void = { [weak self] line in
            monitor.tick()
            guard let self else { return }
            let sec = Self.parseProgressSeconds(line: line)
            guard let sec, totalDur > 0 else { return }
            Task { @MainActor in
                self.fractionValue = min(1.0, sec / totalDur)
                self.isIndeterminateValue = false
            }
        }
        monitor.start()
        pauser.register(monitor)
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater,
            control: pauser.control
        )
        monitor.stop()
        return result
    }

    /// Remove this run's own partial after a stall / cancel / failed or
    /// unverified encode (name- AND identity-guarded: only the file this
    /// run reserved; releases the reservation). Returns what actually
    /// happened — the refusal's sentence reports it. A failure is logged,
    /// never swallowed; a leftover is a later sweep's to remove.
    @discardableResult
    private func discardPartial(_ partial: URL) -> TranscodeJob.PartialCleanup {
        do {
            return try PartialFileNaming.remove(partial) == .removed ? .removed : .alreadyGone
        } catch {
            reformatLog.error("reformat: could not remove partial \(partial.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .notRemoved(error.localizedDescription)
        }
    }

    /// The new file could not be verified (GH #502): the job FAILS, the
    /// new file is removed, nothing is published or catalogued, and the
    /// row + OUTCOME line carry the cause and what the cleanup did.
    private func refuseUnverified(cause: String, partial: URL) async {
        let cleanup = discardPartial(partial)
        let message = TranscodeJob.unverifiedMessage(cause: cause, cleanup: cleanup)
        reformatLog.error("reformat FAILED (verify): \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        await finish(failed: message)
    }

    /// Stop, or a watchdog stall, seen after the encode and before the
    /// publish: the partial is discarded and the job ends Cancelled — or
    /// Failed with the stall that caused it. True = the run is over.
    private func stoppedBeforePublish(_ partial: URL) async -> Bool {
        guard stallReason != nil || Task.isCancelled || state == .cancelling else { return false }
        discardPartial(partial)
        if let stallReason {
            reformatLog.error("reformat FAILED (stall): \(self.record.filename, privacy: .public) — \(stallReason, privacy: .public)")
            await finish(failed: stallReason)
        } else {
            await finish(cancelled: true)
        }
        return true
    }

    @concurrent
    nonisolated private static func keepUnpublishedOffMain(_ partial: URL) async -> URL {
        DerivativeOutputPublish.keepUnpublished(partial)
    }

    // MARK: Stall handling

    /// Invoked (on the main actor) by the StallMonitor when the encode
    /// flatlines. Records a SPECIFIC failure reason — with volume-drop vs
    /// file-error attribution (#6.4) — and cancels the run, which kills the
    /// ffmpeg child through ProcessRunner's SIGTERM→SIGKILL escalation.
    func handleStall(inputPath: String, silentFor: Double) {
        guard state.isActive, terminalCause.first == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [inputPath])
        let reason = "Stalled — no ffmpeg progress for \(Int(silentFor))s during reformat. \(attribution)"
        terminalCause.record(.stall(reason: reason))
        subtitleText = "Stalled — stopping…"
        reformatLog.error("reformat WATCHDOG: killing \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("reformat watchdog: \(record.filename) stalled \(Int(silentFor))s — \(attribution); killing ffmpeg")
        task?.cancel()
    }

    /// Probe the new file, append to the catalog, kick off an analyze
    /// pass for it. The original record stays in the catalog with
    /// needsReformat = true so the user can decide what to do with it
    /// after the reformat lands.
    private func catalogAndQueueAnalyze() async {
        guard let model = model else { return }
        let newURL = publishedURL
        // Probe synchronously (well, async-await) — same path the
        // catalog scan uses.
        let newRec = await model.probeFile(url: newURL)
        // Lineage: tag the new record as a derivative of the source.
        // Future UI (catalog disclosure-triangle grouping) reads this
        // to show "thanksgiving.mov → [vs.hevc derivative]" pairs.
        newRec.derivedFrom = record.id

        // File Journey events on BOTH records so the user can see
        // the rescue happen in the timeline. Rick 2026-06-14:
        // "can we record, in This File's journey, if we reformat/
        // convert a video, show that we did it… the journey when
        // we add to catalog automatically?"
        //
        //   Source record gets:  Reformat <ISO>: Reformatted to HEVC as <newfile>
        //   Derived record gets: Reformat <ISO>: Derived from <sourcefile> via Reformat (HEVC)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Reformat \(stamp): Reformatted to HEVC as \(newURL.lastPathComponent)"
        let derivedNote = "Reformat \(stamp): Derived from \(record.filename) via Reformat (HEVC)"
        await MainActor.run {
            record.notes = record.notes.isEmpty
                ? sourceNote
                : "\(record.notes)\n\(sourceNote)"
            newRec.notes = newRec.notes.isEmpty
                ? derivedNote
                : "\(newRec.notes)\n\(derivedNote)"

            // The one door into the catalog for a derivative (replace at
            // the path, else append); the Catalog pane reveals the row.
            model.adoptDerivative(newRec, at: newURL.path, from: record.id)
            reformatLog.info("reformat: catalogued \(newURL.lastPathComponent, privacy: .public) (\(model.records.count) records total) — journey events added to source + derived")
        }
        // Queue analyze: kick the orchestrator on this single record's
        // volume prefix. The candidate filter will pick it up and the
        // standard pipeline runs.
        if let orchestrator = orchestrator {
            // Determine the volume prefix from the source's catalog
            // entry — the new file is in the same directory tree.
            let prefix = (newURL.path as NSString).deletingLastPathComponent
            Task { @MainActor in
                // Only fire if nothing else is currently analyzing.
                // The user can manually trigger Analyze on the volume
                // row later if the orchestrator's busy.
                if !orchestrator.currentStatus.isActive {
                    await orchestrator.startAnalyzing(volumePrefix: prefix, model: model)
                }
            }
        }
    }

    // MARK: Finish helpers

    private func finish(success: String) async {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) async {
        // Rick 2026-08-26: a job whose cancel was the FIRST terminal cause
        // NEVER ends .failed — the SIGTERM'd child's non-zero exit, or any
        // typed error thrown while the Task unwinds, is the user's Stop,
        // not a failure. A stall recorded before the Stop is not diverted
        // (codex gate 2026-08-26) — see MFOTerminalCause.
        if terminalCause.isCancel { await finish(cancelled: true); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        reformatLog.warning("reformat failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Bool) async {
        // An earlier stall is the cause of THIS cancellation (the watchdog
        // cancelled the Task) — report it, not "Cancelled".
        if let reason = terminalCause.stallReason { await finish(failed: reason); return }
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    // MARK: Progress-line parsing
    //
    // ffmpeg emits via `-progress pipe:2` lines like:
    //
    //   out_time=00:01:23.456789
    //   out_time_us=83456789
    //
    // We also accept the unstructured `time=HH:MM:SS.xx` that appears
    // when -progress isn't honored by an older ffmpeg.

    /// Returns the number of seconds elapsed in the encode, or nil if
    /// the line doesn't match a known progress format. Pure for tests.
    nonisolated static func parseProgressSeconds(line: String) -> Double? {
        // Structured `out_time=HH:MM:SS.us`.
        if let range = line.range(of: "out_time=") {
            let tail = line[range.upperBound...]
            return parseHHMMSS(String(tail))
        }
        // Fallback `time=HH:MM:SS.xx`.
        if let range = line.range(of: "time=") {
            let tail = line[range.upperBound...]
                .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return parseHHMMSS(tail)
        }
        return nil
    }

    nonisolated private static func parseHHMMSS(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let secs = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + secs
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }

    // MARK: - Atomic output helpers (#6.3)

    /// The FIXED sibling `.vs-partial` name (`stem.vs-partial.<ext>`) that
    /// Trim, Cleanup and Rebuild still use, each behind its own `taken()`
    /// / per-record guard. Reformat itself no longer uses it: its partial
    /// is reserved per run (N1014-F1). Keeps the FINAL extension so ffmpeg
    /// still infers the muxer, and lands in the same directory so the
    /// promote is a metadata-only rename. Pure — unit-testable.
    nonisolated static func partialURL(for output: URL) -> URL {
        let ext = output.pathExtension
        return output
            .deletingPathExtension()
            .appendingPathExtension("vs-partial")
            .appendingPathExtension(ext)
    }

    /// Promote a completed partial to its final name in one atomic,
    /// NO-CLOBBER rename (`RENAME_EXCL`). A file already at `to` is never
    /// replaced (2026-09-22: this used to `removeItem` it first — a
    /// permanent delete of whatever had the name, catalogued or not); the
    /// publish fails loudly instead and the partial stays for the caller.
    nonisolated static func atomicPublish(from partialPath: String, to finalPath: String) throws {
        guard try DerivativeOutputPublish.renameNoClobber(partialPath, finalPath) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: finalPath])
        }
    }
}
