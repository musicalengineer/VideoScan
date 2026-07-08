import Combine
import Foundation
import os

// MARK: - ReformatJob
//
// "Reformat and Analyze" — Rick 2026-06-14. One ffmpeg subprocess that
// transcodes a legacy-codec source (svq3 / qdm2 / cinepak / indeo / rpza /
// etc.) into a modern H.264/AAC .mp4 with conventional ffmpeg quality
// filters in line, then auto-catalogs the output and queues it for the
// in-app analyzer.
//
// Why this exists: VideoScan's analyzer goes through AVFoundation, which
// stopped decoding several proprietary QuickTime codecs in macOS 10.15.
// ffmpeg still decodes them fine — so a one-pass transcode bridges old
// archival captures into the analyzable pool. The output file lands
// beside the original (same directory, `<stem>_reformatted.mp4`); the
// original is left untouched.
//
// ffmpeg pipeline (chosen for typical 1990s-2000s home-video captures):
//   - bwdif=mode=send_field:parity=auto   Bob Weaver deinterlace,
//                                         output every field as a frame.
//                                         Drops to no-op on progressive.
//   - hqdn3d=4:3:6:4.5                    Moderate 3D denoise — luma
//                                         spatial 4, chroma spatial 3,
//                                         luma temporal 6, chroma 4.5.
//   - h264_videotoolbox                   Hardware H.264 on Apple Silicon
//                                         (matches CombineEngine /
//                                         PersonFinderCompilation choice).
//                                         CRF-equivalent quality knob via
//                                         -q:v 65 (≈ CRF 18-20).
//   - aac 192k                            Modern audio. Avoids the qdm2
//                                         double-lossy reuse trap.
//
// Cancellation: the job owns its run Task. Task.cancel() propagates into
// ProcessRunner, which terminates the ffmpeg subprocess. Partial output
// is deleted in the cleanup path so a cancelled job doesn't leave a
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
// Atomic output (#6.3): ffmpeg writes to a `.vs-partial` sibling; we
// atomic-rename to the final name ONLY after the encode completes and the
// size check passes. A killed/stalled op leaves only the partial (which we
// delete) — never a truncated file at the real output path.

private let reformatLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                 category: "fileOps")

@MainActor
final class ReformatJob: MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .reformat
    let startedAt = Date()

    /// Source record being reformatted.
    let record: VideoRecord

    /// Where the new .mp4 will land. Computed once at init.
    let outputURL: URL

    /// Weak reference to the model so the success-side wiring can
    /// catalog the new file and queue it for analyze. Avoids a retain
    /// cycle since the model holds Jobs via MediaFileOperationsCenter.
    private weak var model: VideoScanModel?
    private weak var orchestrator: CaptionOrchestrator?

    /// Pause is OFF for reformat — ffmpeg has no clean
    /// suspend/resume contract that survives the subprocess's
    /// thread/buffer state. Cancel + restart is the right idiom.
    let canPause = false

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

    /// Set by the stall watchdog when the encode flatlines. Distinguishes a
    /// watchdog kill (→ `.failed` with a specific reason) from a user cancel
    /// (→ `.cancelled`). Checked before the generic cancel branch because
    /// the watchdog cancels the Task, which also sets `Task.isCancelled`.
    private var stallReason: String?

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
        // Output beside original: <stem>_reformatted.mp4. Same dir,
        // simpler to find. If a previous reformat exists we overwrite
        // it — the older one was either better or worse, but keeping
        // multiple variants around without UX confuses the catalog.
        let srcURL = URL(fileURLWithPath: record.fullPath)
        // Standardized derived-URL convention (Rick 2026-06-14):
        //   <stem>.vs.hevc.<YYYYMMDD-HHMMSS>.mp4
        // beside the source. See DerivedFileNaming.swift. Every
        // future recipe gets the format for free.
        self.outputURL = derivedFileURL(
            source: srcURL,
            codec: "hevc",
            ext: "mp4"
        )
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
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Reformat run

    private func runReformat() async {
        // Probe the duration for the fraction calculation. The record
        // already carries durationSeconds from the catalog scan, so we
        // trust it. Falls back to 0 (indeterminate progress) if it's
        // missing.
        totalDurationSeconds = max(0, record.durationSeconds)
        if totalDurationSeconds == 0 {
            // Fine — UI stays indeterminate, ffmpeg will run, just no
            // % progress.
        }

        let inputPath = record.fullPath
        let outputPath = outputURL.path
        // ffmpeg writes here; we atomic-rename to outputPath only on success
        // (#6.3). A killed/stalled op leaves only this partial, which we
        // delete — never a truncated file at the real output path.
        let partialPath = Self.partialURL(for: outputURL).path

        // Clean up any prior derivative + stale partial (resumed from a cancel).
        try? FileManager.default.removeItem(atPath: outputPath)
        try? FileManager.default.removeItem(atPath: partialPath)

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

        // Apple Silicon optimization (Rick 2026-06-14):
        //   - hevc_videotoolbox encodes ~30-40% smaller than h264 for
        //     equivalent quality, using the same M-series media engine
        //     (no extra CPU/GPU cost on M4).
        //   - "-tag:v hvc1" so QuickTime Player decodes natively on
        //     macOS / iOS / AppleTV. Without this, the default "hev1"
        //     tag forces software fallback on some Apple players even
        //     though the bitstream is identical.
        //   - aac_at uses Apple AudioToolbox's AAC encoder — slightly
        //     better quality than libavcodec's aac at the same bitrate
        //     and offloads to the audio coprocessor.
        let args: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-hwaccel", "videotoolbox",
            "-i", inputPath,
            "-vf", "bwdif=mode=send_field:parity=auto,hqdn3d=4:3:6:4.5",
            "-c:v", "hevc_videotoolbox",
            "-q:v", "65",
            "-tag:v", "hvc1",
            "-c:a", "aac_at",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-progress", "pipe:2",
            partialPath
        ]

        subtitleText = "Transcoding to H.264/AAC…"
        isIndeterminateValue = (totalDurationSeconds == 0)

        reformatLog.info("reformat: ffmpeg \(args.joined(separator: " "), privacy: .public)")

        // Stderr parsing for progress. Both `time=HH:MM:SS.xx` and
        // `out_time=HH:MM:SS.xxxxx` appear in ffmpeg output — the
        // -progress pipe:2 flag emits the structured lines. We accept
        // either to be robust.
        let totalDur = totalDurationSeconds  // capture for the closure

        // Stall watchdog: every stderr line (ffmpeg emits progress blocks
        // continuously while it makes forward progress) kicks the monitor.
        // Silence past the threshold ⇒ the volume stalled ⇒ kill + fail.
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

        let encodeStart = Date()
        monitor.start()
        let _ = await ProcessRunner.runStreaming(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater
        )
        monitor.stop()
        let elapsed = Date().timeIntervalSince(encodeStart)

        // Watchdog stall wins over a generic cancel: the watchdog cancels
        // the Task (setting Task.isCancelled), so check stallReason FIRST so
        // the user sees the specific cause, not "Cancelled".
        if let stallReason {
            try? FileManager.default.removeItem(atPath: partialPath)
            reformatLog.error("reformat FAILED (stall): \(self.record.filename, privacy: .public) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s — \(stallReason, privacy: .public)")
            await finish(failed: stallReason)
            return
        }

        // Was it cancelled mid-run?
        if Task.isCancelled || state == .cancelling {
            try? FileManager.default.removeItem(atPath: partialPath)
            reformatLog.info("reformat cancelled: \(self.record.filename, privacy: .public) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
            await finish(cancelled: true)
            return
        }

        // Verify output exists + is non-trivial. ffmpeg sometimes
        // returns 0 but writes a 1KB header-only file on early failure
        // (codec library unavailable, etc.); reject those.
        guard FileManager.default.fileExists(atPath: partialPath) else {
            await finish(failed: "ffmpeg finished but no output file was produced")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: partialPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 10_000 {
            try? FileManager.default.removeItem(atPath: partialPath)
            await finish(failed: "ffmpeg output too small (\(size) bytes) — likely a codec failure")
            return
        }

        // Atomic publish: the encode is complete and non-trivial — promote
        // the partial to the real output name in one rename (#6.3).
        do {
            try Self.atomicPublish(from: partialPath, to: outputPath)
        } catch {
            try? FileManager.default.removeItem(atPath: partialPath)
            await finish(failed: "Could not finalize output file: \(error.localizedDescription)")
            return
        }

        // Catalog + queue for analyze.
        await catalogAndQueueAnalyze()

        reformatLog.info("reformat DONE: \(self.record.filename, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public)) in \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
        await finish(success: "Reformatted → \(outputURL.lastPathComponent) (\(Self.humanBytes(size))). Queued for analysis.")
    }

    // MARK: Stall handling

    /// Invoked (on the main actor) by the StallMonitor when the encode
    /// flatlines. Records a SPECIFIC failure reason — with volume-drop vs
    /// file-error attribution (#6.4) — and cancels the run, which kills the
    /// ffmpeg child through ProcessRunner's SIGTERM→SIGKILL escalation.
    private func handleStall(inputPath: String, silentFor: Double) {
        guard state.isActive, stallReason == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [inputPath])
        let reason = "Stalled — no ffmpeg progress for \(Int(silentFor))s during reformat. \(attribution)"
        stallReason = reason
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
        let newURL = outputURL
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

            if let existing = model.records.firstIndex(where: { $0.fullPath == newURL.path }) {
                model.records[existing] = newRec
            } else {
                model.records.append(newRec)
            }
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
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        reformatLog.warning("reformat failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Bool) async {
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
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // MARK: - Atomic output helpers (#6.3)

    /// Sibling `.vs-partial` URL ffmpeg writes to. Keeps the FINAL extension
    /// (`stem.vs.hevc.<ts>.vs-partial.mp4`) so ffmpeg still infers the muxer
    /// from `.mp4`, and lands in the same directory so the promote is a
    /// metadata-only rename (atomic on the same filesystem). Pure —
    /// unit-testable. Rick 2026-06-30.
    nonisolated static func partialURL(for output: URL) -> URL {
        let ext = output.pathExtension
        return output
            .deletingPathExtension()
            .appendingPathExtension("vs-partial")
            .appendingPathExtension(ext)
    }

    /// Promote a completed partial to its final name in one atomic rename.
    /// If a file already sits at `to` (a prior derivative we cleaned up but
    /// that reappeared), it's replaced. Throws on failure so the caller
    /// fails loudly rather than catalog a file that isn't there.
    nonisolated static func atomicPublish(from partialPath: String, to finalPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: finalPath) {
            try fm.removeItem(atPath: finalPath)
        }
        try fm.moveItem(atPath: partialPath, toPath: finalPath)
    }
}
