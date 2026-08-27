import Combine
import Foundation
import os

// MARK: - RebuildAudioJob
//
// "Rebuild Audio Track" — the Verify Audio repair verb (GH #128, Rick
// 2026-07-24). For files whose audio codec is unsupported (qdm2 / mace
// / other AVFoundation-dead formats) or undecodable, this remuxes the
// file with the VIDEO STREAM-COPIED (`-c:v copy` — the video is NEVER
// re-encoded) and ONLY the audio re-encoded to pcm_s16le, published as
// a QuickTime (.mov) container. PCM in .mov is the most universally
// playable lossless-audio combination on a Mac.
//
// Safety discipline (BalanceAudioJob's, adapted):
//   - SOURCE NEVER MODIFIED — the pipeline only reads it.
//   - Output `<stem>_RepairedAudio.mov` BESIDE the source (spec: the
//     repaired copy sorts adjacent to the bad one so Rick can spot-play
//     and then manually remove the bogus original). ffmpeg writes to
//     the `.vs-partial` sibling; promotion is a NON-CLOBBERING rename
//     re-uniquified at publish time (CleanupJob's M3 TOCTOU guard).
//   - Read-only-volume and free-space pre-checks with clear messages.
//   - Stall watchdog on ffmpeg's progress stream.
//   - POST-REPAIR VERIFICATION before promotion: ffprobe on the partial
//     must show exactly one pcm_s16le audio stream, the video codec
//     unchanged, and duration within tolerance.
//   - Catalog insertion with full provenance: derivedFrom + a
//     "rebuildAudio" derivationKind + "Verify Audio <ISO8601>: …" File
//     Journey stamps on BOTH records (the verb is registered in
//     UserNotesMigration.journeyStampVerbs — lock-step requirement, or
//     the stamps would migrate into userNotes).
//
// Raw-DV gotcha: raw `.dv` sources report a bogus avg_frame_rate that
// makes the mov muxer fail at trailer-write; the probed r_frame_rate is
// fed back as an input-side `-r` override (BalanceAudioFix's rule,
// reused verbatim). `-c:v copy` means the rate is cosmetic either way.
//
// Memory: ffmpeg streams; this process holds only progress lines
// (bounded by ProcessRunner's 256 KB stderr cap) plus the verification
// probe JSON (~KBs). Worst-case in-process footprint < 1 MB.

private let verifyLog = Logger(subsystem: "Rick-Breen.VideoScan",
                               category: "verifyAudio")

// MARK: - Pure fix rules

/// PURE decision tables for the rebuild — no I/O, fully unit-testable
/// (the BalanceAudioFix/TrimEngine split).
enum RebuildAudioFix {

    /// The provenance tag written to `VideoRecord.derivationKind`.
    static let derivationKind = "rebuildAudio"

    /// Verification tolerance on the output's duration vs the source's.
    static let durationToleranceSeconds: Double = 1.0

    /// The one audio codec the rebuild ever writes — uncompressed
    /// 16-bit PCM (lossless from the decoded samples, plays anywhere).
    static let outputAudioCodec = "pcm_s16le"

    /// `<stem>_RepairedAudio.mov` beside the source — ALWAYS .mov (the
    /// spec's container: pcm_s16le rides in QuickTime). Finder-style
    /// counters on collision (`<stem>_RepairedAudio 2.mov`, …).
    /// `fileExists` injected so the uniquify loop is pure-testable and
    /// the publish path can fold "partial exists" into "taken".
    static func repairedOutputURL(
        forSourcePath path: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let src = URL(fileURLWithPath: path)
        let dir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem)_RepairedAudio.mov")
        var n = 2
        while fileExists(candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)_RepairedAudio \(n).mov")
            n += 1
        }
        return candidate
    }

    /// Input-side args: the raw-DV `-r` override, reusing the balance
    /// fix's probed-r_frame_rate rule (never hardcoded — NTSC DV is
    /// 30000/1001, PAL is 25/1). Empty for every other container. Pure.
    static func inputArgs(containerFormat: String, rFrameRate: String?) -> [String] {
        guard BalanceAudioFix.isRawDVContainer(containerFormat),
              let rate = rFrameRate,
              let numerator = rate.split(separator: "/").first.flatMap({ Int($0) }),
              numerator > 0
        else { return [] }
        return ["-r", rate]
    }

    /// Full ffmpeg argument vector. `-map 0:v?` is the optional-map
    /// form (matches zero video streams without erroring, for
    /// audio-only sources); only the FIRST audio stream is carried —
    /// this is a playable repair copy, not an archival mirror.
    /// `-c:v copy` stream-copies the picture verbatim; ONLY the audio
    /// is re-encoded. Pure — tested as strings.
    static func ffmpegArgs(input: String,
                           output: String,
                           inputArgs: [String] = []) -> [String] {
        var args: [String] = ["-hide_banner", "-nostdin", "-y"]
        args += inputArgs
        args += ["-i", input]
        args += [
            "-map", "0:v?",
            "-map", "0:a:0",
            "-c:v", "copy",
            "-c:a", outputAudioCodec,
            "-map_metadata", "0",
            "-progress", "pipe:2",
            output
        ]
        return args
    }

    /// Free-space requirement: video copied ≈ source size, plus the
    /// rebuilt audio at worst-case stereo 48 kHz 16-bit PCM (192 KB/s),
    /// plus a 64 MB muxer/headroom cushion. Pure.
    static func requiredFreeBytes(sourceBytes: Int64,
                                  durationSeconds: Double) -> Int64 {
        let audioBytes = Int64(max(0, durationSeconds) * 192_000)
        return sourceBytes + audioBytes + (64 << 20)
    }

    /// Post-repair contract on the ffprobe'd partial: exactly one audio
    /// stream in pcm_s16le, video codec unchanged when the source had
    /// one. nil = acceptable; non-nil = the breach message. Pure.
    static func outputMismatch(observed: AudioVerifyShape,
                               sourceVideoCodec: String?) -> String? {
        guard observed.audioStreams == 1 else {
            return "output carries \(observed.audioStreams) audio stream(s), expected exactly 1"
        }
        guard observed.audioCodec == outputAudioCodec else {
            return "output audio codec is \(observed.audioCodec.isEmpty ? "unknown" : observed.audioCodec), expected \(outputAudioCodec)"
        }
        if let src = sourceVideoCodec, !src.isEmpty,
           observed.videoCodec != src {
            return "video codec changed (\(src) → \(observed.videoCodec ?? "none"))"
        }
        return nil
    }

    /// Truncated-audio guard (QA finding 2, 2026-07-24): container
    /// duration is the LONGEST track — the video is stream-copied full
    /// length, so if ffmpeg's decode of the (by definition damaged)
    /// source audio dies partway but exits 0, the container-duration
    /// check alone would pass a repair carrying the exact #125-class
    /// defect this feature exists to catch. Compare the AUDIO stream's
    /// OWN duration against the picture (falling back to the source
    /// duration for audio-only outputs), using the same >10% rule the
    /// diagnosis uses. An UNKNOWN audio duration (0) never fires —
    /// consistent with the diagnosis rule's "never manufacture a
    /// verdict from a guess" (and .mov/pcm outputs always report it).
    /// nil = acceptable; non-nil = the breach message. Pure.
    static func truncatedAudioMismatch(observed: AudioVerifyShape,
                                       sourceDuration: Double) -> String? {
        let target = observed.videoDurationSeconds > 0
            ? observed.videoDurationSeconds
            : sourceDuration
        guard VerifyAudioRules.hasDurationMismatch(
            audioSeconds: observed.audioDurationSeconds,
            videoSeconds: target) else { return nil }
        return String(format: "rebuilt audio track runs %.1fs but the picture runs %.1fs — the audio re-encode died partway through",
                      observed.audioDurationSeconds, target)
    }
}

// MARK: - Job

// The conformance itself is isolated to the main actor (SE-0470 —
// `@MainActor` before the protocol name) so the "conformance crosses
// into main actor-isolated code" warning the older jobs still emit
// doesn't spread to this one. (For Rick: ≈ declaring that this
// interface may only be used from the UI thread, checked statically.)
@MainActor
final class RebuildAudioJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .rebuildAudio
    let startedAt = Date()

    /// Source record. READ ONLY on disk.
    let record: VideoRecord

    /// Why the rebuild was offered ("invalid codec (qdm2)") — surfaced
    /// in the derived record's File Journey stamp.
    let reason: String

    /// The diagnosed shape (container format + r_frame_rate feed the
    /// raw-DV input override; durations feed progress + verification).
    let shape: AudioVerifyShape

    /// PLANNED `<stem>_RepairedAudio.mov` beside the source (shared
    /// with the sheet so it never promises a name the job doesn't plan
    /// to use). Publish re-uniquifies — see `publishedURL`.
    let outputURL: URL

    /// Where the repaired copy actually landed; nil until promotion.
    private(set) var publishedURL: URL?

    /// Test seam: overrides ToolLocator's ffmpeg (failure injection).
    private let ffmpegPathOverride: String?

    /// Per-disk pacing (GH #132): the render is a long sequential
    /// read+write against the source's volume — held for the whole run
    /// via PairCompareJob's recursive withPermit idiom so a batch of
    /// rebuilds against one HDD runs one at a time. Empty = ungated
    /// (SSD/internal, and legacy test call sites).
    private let gates: [MediaVolumeGate]

    private weak var model: VideoScanModel?

    /// Pause via SIGSTOP/SIGCONT on the live ffmpeg child (GH #150) —
    /// JobPauseCoordinator parks the stall watchdog while suspended.
    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()

    /// One serial chain for slot operations — rapid Pause→Resume must
    /// lend-then-reacquire in order (codex #289/#292).
    private var gateOpsChain: Task<Void, Never>?

    private func enqueueGateOp(_ op: @escaping @MainActor () async -> Void) {
        let previous = gateOpsChain
        gateOpsChain = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
        // Step aside (2026-08-07 compare-starvation incident): SIGSTOP
        // first, THEN lend the slots.
        enqueueGateOp { [weak self] in
            guard let self else { return }
            for entry in self.gatePermits {
                await entry.permit.releaseForPause()
                VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: self.id)
            }
        }
    }

    func resume() {
        guard isPausedValue else { return }
        // Re-acquire EVERY slot BEFORE SIGCONT; a resume that could not
        // re-hold (cancel/close raced it) leaves the job paused — the
        // cancel path owns the unwind.
        enqueueGateOp { [weak self] in
            guard let self else { return }
            var allHeld = true
            for entry in self.gatePermits {
                try? await entry.permit.reacquireForResume()
                if await entry.permit.currentPhase == .held {
                    VolumeGateBoard.shared.claim(root: entry.gate.root,
                                                 jobID: self.id,
                                                 name: self.gateHolderName)
                } else {
                    allHeld = false
                }
            }
            guard allHeld, self.pauser.resume() else { return }
            self.isPausedValue = false
        }
    }

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Set by the stall watchdog; wins over the generic cancel branch.
    /// Set-once ledger of the first terminal cause (watchdog stall vs the
    /// user's Stop) — see MFOTerminalCause. `stallReason` reads through it.
    private var terminalCause = MFOTerminalCause()
    private var stallReason: String? { terminalCause.stallReason }

    var title: String { record.filename }
    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label,
                                                root: waitingForVolumeRoot ?? "")
        }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    init(record: VideoRecord,
         reason: String,
         shape: AudioVerifyShape,
         model: VideoScanModel,
         plannedOutput: URL? = nil,
         gates: [MediaVolumeGate] = [],
         ffmpegPathOverride: String? = nil) {
        self.record = record
        self.reason = reason
        self.shape = shape
        self.model = model
        self.gates = gates
        self.ffmpegPathOverride = ffmpegPathOverride
        self.subtitleText = "Preparing to rebuild the audio track…"
        self.outputURL = plannedOutput
            ?? RebuildAudioFix.repairedOutputURL(forSourcePath: record.fullPath)
    }

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates(self.gates[...])
        }
    }

    /// Acquire each volume gate in order, then run the rebuild while
    /// holding all of them. PausableGatePermit (2026-08-07) replaced
    /// the recursive withPermit idiom so pause can lend the held slots
    /// to the queue and resume can take them back — the permit actor
    /// owns the exactly-one-signal-per-wait discipline. While queued
    /// the row reads "Waiting for <volume>…".
    private var gatePermits: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []

    private var gateHolderName: String { "Rebuild \(record.filename)" }

    /// Live waiting state (codex #292: a snapshotted string is not a
    /// live subtitle — the getter consults the board every render).
    @Published private(set) var waitingForVolumeLabel: String?
    private var waitingForVolumeRoot: String?

    private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>) async {
        for gate in remaining {
            waitingForVolumeLabel = gate.label
            waitingForVolumeRoot = gate.root
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
                gatePermits.append((gate, permit))
                VolumeGateBoard.shared.claim(root: gate.root, jobID: id,
                                             name: gateHolderName)
                // codex #295: a pause that landed while we were
                // suspended acquiring THIS gate has already lent the
                // earlier permits — this one must join the paused set,
                // and the loop must hold here (a paused job may not
                // advance toward spawning new work). The lend op is
                // chain-ordered and re-checks paused state at execution:
                // if resume won the race it no-ops and the permit stays
                // held, exactly matching what resume re-acquired.
                if isPausedValue {
                    let lentEntry = (gate: gate, permit: permit)
                    enqueueGateOp { [weak self] in
                        guard let self, self.isPausedValue else { return }
                        await lentEntry.permit.releaseForPause()
                        VolumeGateBoard.shared.clear(root: lentEntry.gate.root,
                                                     jobID: self.id)
                    }
                    while isPausedValue, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if Task.isCancelled {
                        await closeGatePermits()
                        finishCancelled()
                        return
                    }
                }
            } catch {
                // Only CancellationError escapes wait() — the user
                // cancelled while queued behind another job.
                waitingForVolumeLabel = nil
                waitingForVolumeRoot = nil
                await closeGatePermits()
                finishCancelled()
                return
            }
        }
        waitingForVolumeLabel = nil
        waitingForVolumeRoot = nil
        await runRebuild()
        await closeGatePermits()
    }

    /// Release every held slot, reverse order — paused (lent) and
    /// never-acquired permits owe nothing by the phase machine.
    private func closeGatePermits() async {
        for entry in gatePermits.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: id)
        }
        gatePermits = []
    }

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

    // MARK: Run

    private func runRebuild() async {
        guard state != .cancelling else {
            finishCancelled()
            return
        }
        let inputPath = record.fullPath
        verifyLog.info("rebuild START: \(self.record.filename, privacy: .public) (\(self.reason, privacy: .public)) → \(self.outputURL.lastPathComponent, privacy: .public)")

        guard FileManager.default.fileExists(atPath: inputPath) else {
            finish(failed: "Source file missing on disk")
            return
        }
        let ffmpeg = ffmpegPathOverride ?? ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            finish(failed: "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
            return
        }

        // ---- Destination pre-checks (spec: read-only or full volumes
        // fail with a clear message).
        let fm = FileManager.default
        let destDir = outputURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: destDir.path) else {
            finish(failed: "The volume holding the original is read-only — the repaired copy can't be written next to it. Copy the file to a writable disk first.")
            return
        }
        let sourceDuration = shape.containerDurationSeconds > 0
            ? shape.containerDurationSeconds
            : max(0, record.durationSeconds)
        let required = RebuildAudioFix.requiredFreeBytes(
            sourceBytes: record.sizeBytes,
            durationSeconds: sourceDuration)
        if let free = BalanceAudioJob.freeBytes(forDirectory: destDir), free < required {
            finish(failed: "Not enough free space next to the original — need about \(Self.humanBytes(required)), only \(Self.humanBytes(free)) available")
            return
        }

        // ---- Publish-time re-uniquify (M3 pattern): the planned name
        // is only a plan; a name whose partial exists is taken.
        let taken: (String) -> Bool = { path in
            fm.fileExists(atPath: path)
                || fm.fileExists(atPath: ReformatJob.partialURL(for: URL(fileURLWithPath: path)).path)
        }
        var candidate = outputURL
        if taken(candidate.path) {
            candidate = RebuildAudioFix.repairedOutputURL(
                forSourcePath: inputPath, fileExists: taken)
        }
        let partialURL = ReformatJob.partialURL(for: candidate)

        // Any exit before promotion must leave no partial behind.
        var promoted = false
        defer {
            if !promoted { try? fm.removeItem(at: partialURL) }
        }

        subtitleText = "Rebuilding the audio track — the picture is copied unchanged…"
        isIndeterminateValue = (sourceDuration == 0)

        // ---- Stall watchdog fed by ffmpeg's -progress stream.
        let monitor = StallMonitor(label: "rebuild \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(silentFor: silentFor)
            }
        }
        let progressSink: @Sendable (Double) -> Void = { [weak self] fraction in
            monitor.tick()
            guard fraction >= 0, let self else { return }
            Task { @MainActor in
                self.applyProgressFraction(fraction)
            }
        }

        let args = RebuildAudioFix.ffmpegArgs(
            input: inputPath,
            output: partialURL.path,
            inputArgs: RebuildAudioFix.inputArgs(
                containerFormat: shape.containerFormat,
                rFrameRate: shape.videoRFrameRate))
        verifyLog.info("rebuild render: ffmpeg \(args.joined(separator: " "), privacy: .public)")

        monitor.start()
        pauser.register(monitor)
        let renderError = await Self.renderOffMain(ffmpeg: ffmpeg,
                                                   arguments: args,
                                                   durationSeconds: sourceDuration,
                                                   control: pauser.control,
                                                   progress: progressSink)
        if let stallReason {
            monitor.stop()
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            monitor.stop()
            finishCancelled()
            return
        }
        if let renderError {
            monitor.stop()
            finish(failed: renderError)
            return
        }

        // ---- POST-REPAIR VERIFICATION on the partial, before promotion.
        subtitleText = "Verifying the repaired copy…"
        monitor.tick()
        do {
            try await Self.verifyOffMain(partialPath: partialURL.path,
                                         sourceVideoCodec: shape.videoCodec,
                                         sourceDuration: sourceDuration)
        } catch {
            monitor.stop()
            if error is CancellationError || Task.isCancelled || state == .cancelling {
                finishCancelled()
            } else {
                let msg = (error as? RebuildVerificationError)?.message
                    ?? error.localizedDescription
                verifyLog.error("rebuild VERIFY FAILED: \(self.record.filename, privacy: .public) — \(msg, privacy: .public)")
                finish(failed: "Verification failed — the repaired copy was discarded. \(msg)")
            }
            return
        }
        monitor.stop()
        if Task.isCancelled || state == .cancelling {
            finishCancelled()
            return
        }

        // ---- NON-CLOBBERING promote (rename only; retry the uniquify
        // on a raced-in collision, bounded).
        var attempts = 0
        while true {
            do {
                try fm.moveItem(at: partialURL, to: candidate)
                promoted = true
                break
            } catch {
                attempts += 1
                guard attempts < 100, fm.fileExists(atPath: candidate.path) else {
                    finish(failed: "Could not place the repaired copy next to the original: \(error.localizedDescription)")
                    return
                }
                candidate = RebuildAudioFix.repairedOutputURL(
                    forSourcePath: inputPath, fileExists: taken)
            }
        }
        publishedURL = candidate
        if candidate != outputURL {
            verifyLog.notice("rebuild publish: planned name \(self.outputURL.lastPathComponent, privacy: .public) was taken — published as \(candidate.lastPathComponent, privacy: .public)")
        }

        let attrs = try? fm.attributesOfItem(atPath: candidate.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // ---- Catalog + provenance + persistence.
        await catalogRebuildOutput(publishedURL: candidate)

        verifyLog.info("rebuild DONE: \(self.record.filename, privacy: .public) → \(candidate.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public))")
        finish(success: "Rebuilt → \(candidate.lastPathComponent) (\(Self.humanBytes(size))). Original untouched.")
    }

    /// m2 guard: progress beats arrive via unstructured Tasks and can
    /// land after a terminal state — a straggler must never drag a
    /// finished bar backwards.
    func applyProgressFraction(_ fraction: Double) {
        guard state.isActive else { return }
        fractionValue = fraction
        isIndeterminateValue = false
    }

    // MARK: Off-main hops
    //
    // Same `@concurrent` idiom as BalanceAudioJob: this repo's
    // Approachable Concurrency runs `nonisolated async` on the CALLER's
    // actor — calling ffmpeg supervision from this @MainActor job
    // without `@concurrent` would run it on main (the documented trap).

    /// Run the ffmpeg remux. Returns nil on success, or a
    /// user-presentable failure message.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func renderOffMain(
        ffmpeg: String,
        arguments: [String],
        durationSeconds: Double,
        control: ProcessControl? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> String? {
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: arguments,
            stderrLine: { line in
                guard let sec = ReformatJob.parseProgressSeconds(line: line),
                      durationSeconds > 0 else {
                    progress(-1)   // watchdog-only heartbeat
                    return
                }
                progress(min(1.0, sec / durationSeconds))
            },
            control: control
        )
        if Task.isCancelled { return nil }   // caller handles cancel
        guard result.exitCode == 0 else {
            let tail = result.stderr.split(separator: "\n").suffix(4).joined(separator: " · ")
            return "ffmpeg exited with status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")"
        }
        return nil
    }

    /// ffprobe the rendered partial and enforce the post-repair
    /// contract: one pcm_s16le audio stream, video codec unchanged,
    /// duration within tolerance.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func verifyOffMain(
        partialPath: String,
        sourceVideoCodec: String?,
        sourceDuration: Double
    ) async throws {
        let ffprobe = ToolLocator.ffprobePath
        let result = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: VerifyAudioProbe.shapeArgs(input: partialPath),
            stdoutLimitBytes: 1 << 20,
            deadlineSeconds: 60)
        guard result.exitCode == 0, let stdout = result.stdout,
              let data = stdout.data(using: .utf8) else {
            throw RebuildVerificationError(
                message: "ffprobe could not read the repaired copy (status \(result.exitCode))")
        }
        let observed = try VerifyAudioProbe.shape(fromProbeJSON: data)
        if let mismatch = RebuildAudioFix.outputMismatch(
            observed: observed, sourceVideoCodec: sourceVideoCodec) {
            throw RebuildVerificationError(message: mismatch)
        }
        // Truncated-audio guard (QA finding 2): the container check
        // below reads the LONGEST track, which the full-length
        // stream-copied video always satisfies — the AUDIO stream's own
        // duration is what catches a decode that died partway.
        if let mismatch = RebuildAudioFix.truncatedAudioMismatch(
            observed: observed, sourceDuration: sourceDuration) {
            throw RebuildVerificationError(message: mismatch)
        }
        if sourceDuration > 0, observed.containerDurationSeconds > 0 {
            let delta = abs(observed.containerDurationSeconds - sourceDuration)
            guard delta <= RebuildAudioFix.durationToleranceSeconds else {
                throw RebuildVerificationError(
                    message: String(format: "duration drifted %.2fs", delta))
            }
        }
    }

    // MARK: Stall handling

    func handleStall(silentFor: Double) {
        guard state.isActive, terminalCause.first == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no progress for \(Int(silentFor))s while rebuilding the audio track. \(attribution)"
        terminalCause.record(.stall(reason: reason))
        subtitleText = "Stalled — stopping…"
        verifyLog.error("rebuild WATCHDOG: killing \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("rebuild audio watchdog: \(record.filename) stalled \(Int(silentFor))s — \(attribution); killing job")
        task?.cancel()
    }

    // MARK: Catalog + provenance

    /// Probe the repaired file and register it with full provenance:
    /// `derivedFrom` = source id, `derivationKind` = "rebuildAudio",
    /// "Verify Audio" File Journey stamps on both records (the verb is
    /// in UserNotesMigration.journeyStampVerbs — lock-step), search-
    /// index updates, and the catalog-mutated notification (debounced
    /// save) — the same M1/M2 pattern BalanceAudioJob documents.
    private func catalogRebuildOutput(publishedURL: URL) async {
        guard let model else { return }
        let newRec = await model.probeFile(url: publishedURL)

        newRec.derivedFrom = record.id
        newRec.derivationKind = RebuildAudioFix.derivationKind
        // A rebuilt copy is the same footage — Rick's hand-entered date
        // carries over with its confidence (GH #117 convention).
        newRec.userDate = record.userDate
        newRec.userDateConfidence = record.userDateConfidence

        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Verify Audio \(stamp): repaired copy written to \(publishedURL.lastPathComponent)"
        let derivedNote = "Verify Audio \(stamp): rebuilt audio track from \(record.filename) (\(reason))"

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
        model.searchIndex.update(newRec)
        model.searchIndex.update(record)
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)

        verifyLog.info("rebuild: catalogued \(publishedURL.lastPathComponent, privacy: .public) (derivedFrom=\(self.record.id.uuidString, privacy: .public), kind=\(RebuildAudioFix.derivationKind, privacy: .public))")
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        // Rick 2026-08-26: a job whose cancel was the FIRST terminal cause
        // NEVER ends .failed — the SIGTERM'd child's non-zero exit, or any
        // typed error thrown while the Task unwinds, is the user's Stop,
        // not a failure. A stall recorded before the Stop is not diverted
        // (codex gate 2026-08-26) — see MFOTerminalCause.
        if terminalCause.isCancel { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        verifyLog.warning("rebuild failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        // An earlier stall is the cause of THIS cancellation (the watchdog
        // cancelled the Task) — report it, not "Cancelled".
        if let reason = terminalCause.stallReason { finish(failed: reason); return }
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }
}

/// Typed verification failure so the job can surface the exact contract
/// breach.
private struct RebuildVerificationError: Error {
    let message: String
}
