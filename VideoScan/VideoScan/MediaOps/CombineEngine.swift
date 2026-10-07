import Foundation
import os

/// Handles batch remuxing of correlated audio/video MXF pairs into MOV containers.
/// Supports stream copy (no re-encode) and re-encode modes, with RAM disk buffering for network sources.
enum CombineEngine {

    static var ffmpegPath: String { ToolLocator.ffmpegPath }

    struct CombineResult: Sendable {
        let success: Bool
        let stderr: String
        let exitCode: Int32
        /// Set when the stall watchdog killed ffmpeg (N1014-F3): the
        /// specific reason, with volume-drop vs read-error attribution.
        var stallReason: String? = nil
    }

    // MARK: - ffmpeg Remux

    /// Run ffmpeg to combine video+audio. Returns result with success/failure and stderr.
    /// Supports progress reporting via `-progress pipe:1` when a progress callback is provided.
    /// Cancellation-aware: terminates ffmpeg immediately when task is cancelled
    /// (with SIGKILL escalation via ProcessRunner if ffmpeg ignores SIGTERM).
    ///
    /// Stall watchdog (N1014-F3, 2026-10-07): the mux runs under a
    /// StallMonitor (the pattern every other MFO ffmpeg job uses). Every
    /// line ffmpeg prints kicks it — `-progress pipe:1` is always requested
    /// while it is armed, so a healthy mux prints several lines a second. A
    /// drive that stops answering leaves ffmpeg blocked in read(2), silent;
    /// past `stallThresholdSeconds` the watchdog kills ffmpeg and the result
    /// carries `stallReason`. Before this a wedged mux sat "muxing" forever
    /// and the rest of an overnight batch never ran. nil = no watchdog.
    ///
    /// Progress is ANY of: an ffmpeg output line, or the output file's size
    /// or mtime changing (OutputFileHeartbeat). The second is load-bearing
    /// (QA, 2026-10-07): `-movflags +faststart` ends with a pass that
    /// rewrites the whole output in place to move the index to the front,
    /// printing nothing — ~22 GB at 75 MB/s is past the 5-minute threshold,
    /// so a long healthy pair on a spinning or network drive would be killed
    /// as "stalled" on every retry. That pass changes the file's mtime; a
    /// truly wedged ffmpeg changes neither.
    ///
    /// Subprocess plumbing consolidated onto ProcessRunner (codex finding #3):
    /// same arguments, same stderr→log routing, same exit-code semantics —
    /// only the pipe/termination machinery is shared now.
    static func runFFMpeg(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        technique: CombineJobStatus.CombineTechnique = .streamCopy,
        durationSeconds: Double = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        stallThresholdSeconds: Double? = StallMonitor.defaultStallThresholdSeconds,
        log: @escaping @Sendable (String) -> Void
    ) async -> CombineResult {
        let arguments = buildArgs(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            technique: technique,
            withProgress: onProgress != nil || stallThresholdSeconds != nil
        )
        let watched = await runWatched(
            arguments: arguments,
            outputPath: outputPath,
            stallThresholdSeconds: stallThresholdSeconds,
            stdoutLine: progressParser(onProgress: onProgress, durationSeconds: durationSeconds),
            log: log
        )
        let result = watched.result

        if let silentFor = watched.stalledAfterSeconds {
            let attribution = StallMonitor.attribution(forPaths: [videoPath, audioPath])
            return CombineResult(
                success: false,
                stderr: result.stderr,
                exitCode: result.exitCode,
                stallReason: "no ffmpeg progress for \(Int(silentFor))s during the mux — \(attribution)"
            )
        }

        // Launch failure (stdout nil + synthetic -1, not user cancellation):
        // preserve the historical message prefix that callers/logs expect.
        if result.exitCode == -1, result.stdout == nil, result.stderr != "cancelled" {
            return CombineResult(
                success: false,
                stderr: "Failed to launch ffmpeg: \(result.stderr)",
                exitCode: -1
            )
        }

        return CombineResult(
            success: result.exitCode == 0,
            stderr: result.stderr,
            exitCode: result.exitCode
        )
    }

    /// Parse `-progress pipe:1` key=value lines (out_time_us=<microsecs>)
    /// into a 0…1 fraction. nil when there is nothing to report to.
    private static func progressParser(onProgress: (@Sendable (Double) -> Void)?,
                                       durationSeconds: Double) -> (@Sendable (String) -> Void)? {
        guard let onProgress, durationSeconds > 0 else { return nil }
        return { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                let seconds = us / 1_000_000
                onProgress(min(seconds / durationSeconds, 1.0))
            }
        }
    }

    /// The mux Task (for the watchdog to cancel) and when the watchdog fired.
    private struct MuxWatch: Sendable {
        var task: Task<ProcessRunner.Result, Never>?
        var stalledAfterSeconds: Double?
    }

    /// Run ffmpeg as a child Task under the stall watchdog. The watchdog
    /// does not own the Process: on silence it cancels the Task, which
    /// reaches ProcessRunner's SIGTERM → SIGKILL → abandon escalation. The
    /// caller's own cancellation (the user's Stop) is forwarded to the same
    /// Task. (For Rick: ≈ a std::thread + watchdog timer, where the timer's
    /// reset handler sets a flag and signals the worker to abort.)
    private static func runWatched(
        arguments: [String],
        outputPath: String,
        stallThresholdSeconds: Double?,
        stdoutLine: (@Sendable (String) -> Void)?,
        log: @escaping @Sendable (String) -> Void
    ) async -> (result: ProcessRunner.Result, stalledAfterSeconds: Double?) {
        let label = (outputPath as NSString).lastPathComponent
        let watch = OSAllocatedUnfairLock(initialState: MuxWatch())
        let monitor = stallThresholdSeconds.map { threshold in
            StallMonitor(label: "combine mux \(label)",
                         thresholdSeconds: threshold,
                         pollIntervalSeconds: watchIntervalSeconds(threshold: threshold)) { silentFor in
                let task = watch.withLock { state -> Task<ProcessRunner.Result, Never>? in
                    state.stalledAfterSeconds = silentFor
                    return state.task
                }
                appLog.write("combine watchdog: \(label) — no ffmpeg progress for \(Int(silentFor))s; killing ffmpeg")
                task?.cancel()
            }
        }
        let executable = ffmpegPath
        let mux = Task.detached {
            await ProcessRunner.runProcess(
                executable: executable,
                arguments: arguments,
                stdoutLine: { line in
                    monitor?.tick()
                    stdoutLine?(line)
                },
                stderrLine: { line in
                    monitor?.tick()
                    DispatchQueue.main.async { log(line) }
                },
                stderrLimitBytes: nil   // callers keep the full transcript (pre-refactor behavior)
            )
        }
        // Stored BEFORE the watchdog starts, so a firing watchdog always
        // finds the Task to cancel.
        watch.withLock { $0.task = mux }
        let heartbeat = monitor.map { monitor in
            OutputFileHeartbeat(path: outputPath,
                                intervalSeconds: watchIntervalSeconds(threshold: stallThresholdSeconds ?? 0),
                                onChange: { monitor.tick() })
        }
        monitor?.start()
        heartbeat?.start()
        let result = await withTaskCancellationHandler {
            await mux.value
        } onCancel: {
            mux.cancel()
        }
        heartbeat?.stop()
        monitor?.stop()
        return (result, watch.withLock { $0.stalledAfterSeconds })
    }

    /// Poll cadence for both the watchdog and the file heartbeat: a quarter
    /// of the threshold, between 0.25 s and StallMonitor's 15 s default
    /// (15 s for the 5-minute production threshold — 20 samples per window).
    static func watchIntervalSeconds(threshold: Double) -> Double {
        min(StallMonitor.defaultPollIntervalSeconds, max(threshold / 4, 0.25))
    }

    // MARK: - Argument Construction
    //
    // Pulled out as a pure function so the encoder choice + flag set for
    // each technique can be unit-tested without spawning ffmpeg. If you
    // change an encoder string here, the matching test in CombineEngineArgsTests
    // will catch it on the next run.
    //
    // Encoder choice notes (2026-05-27):
    //   .reencodeProRes uses prores_videotoolbox (hardware) instead of
    //     prores_ks (software). M-series Macs all have a dedicated ProRes
    //     hardware encoder on the Media Engine — roughly 3-5× faster than
    //     prores_ks at equivalent quality for archival mezzanine work.
    //   .reencodeH264 uses h264_videotoolbox instead of libx264. Same
    //     reasoning — leaves the dedicated H.264 hardware encoder idle
    //     otherwise. -q:v 70 is a constant-quality target that produces
    //     visually-very-good results at ~25-40 Mbps for 1080p, matching
    //     the "smaller files" intent of this case while still substantially
    //     smaller than ProRes (220 Mbps).
    //   .streamCopy is unchanged — it's pure mux, zero encoding, nothing
    //     to accelerate.
    static func buildArgs(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        technique: CombineJobStatus.CombineTechnique,
        withProgress: Bool
    ) -> [String] {
        var args = [
            "-y",
            "-probesize", "50M",
            "-analyzeduration", "10M",
            "-i", videoPath,
            "-i", audioPath,
            "-map", "0:v",
            "-map", "1:a",
        ]

        switch technique {
        case .streamCopy:
            args += ["-c:v", "copy", "-c:a", "copy"]
        case .reencodeProRes:
            args += ["-c:v", "prores_videotoolbox", "-profile:v", "3", "-c:a", "pcm_s24le"]
        case .reencodeH264:
            args += ["-c:v", "h264_videotoolbox", "-q:v", "70", "-c:a", "aac", "-b:a", "256k"]
        }

        args += ["-movflags", "+faststart", "-f", "mov"]
        if withProgress {
            args += ["-progress", "pipe:1"]
        }
        args.append(outputPath)
        return args
    }

    // MARK: - Codec Compatibility

    struct CodecCheck: Sendable {
        let streamCopySafe: Bool
        let warning: String?
    }

    private static let movSafeVideoCodecs: Set<String> = [
        "h264", "hevc", "prores", "mpeg4", "mjpeg", "dnxhd",
        "rawvideo", "v210", "v410", "dvvideo", "cfhd",
        "ap4h", "ap4x", "apcn", "apch", "apcs", "apco",
    ]

    private static let movSafeAudioCodecs: Set<String> = [
        "aac", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be",
        "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f64le",
        "mp3", "ac3", "eac3", "alac", "opus", "flac",
        "pcm_mulaw", "pcm_alaw",
    ]

    static func checkStreamCopyCompatibility(
        videoCodec: String?,
        audioCodec: String?
    ) -> CodecCheck {
        let vc = (videoCodec ?? "").lowercased()
        let ac = (audioCodec ?? "").lowercased()

        if vc.isEmpty && ac.isEmpty {
            return CodecCheck(streamCopySafe: false, warning: "No codecs detected")
        }

        var warnings: [String] = []

        if !vc.isEmpty && !movSafeVideoCodecs.contains(vc) {
            warnings.append("Video codec '\(vc)' may not be compatible with MOV container")
        }
        if !ac.isEmpty && !movSafeAudioCodecs.contains(ac) {
            warnings.append("Audio codec '\(ac)' may not be compatible with MOV container")
        }

        if warnings.isEmpty {
            return CodecCheck(streamCopySafe: true, warning: nil)
        }
        return CodecCheck(streamCopySafe: false, warning: warnings.joined(separator: "; "))
    }

    // MARK: - Buffered Copy

    /// Large-buffer async file copy (4 MB chunks) for network reliability.
    static func bufferedCopy(
        from src: URL,
        to dst: URL,
        bufferSize: Int = 4 * 1024 * 1024
    ) async throws {
        try await Task.detached {
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: src.path))
            defer { try? reader.close() }

            FileManager.default.createFile(atPath: dst.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: URL(fileURLWithPath: dst.path)) else {
                throw NSError(
                    domain: "VideoScan", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot write \(dst.lastPathComponent)"]
                )
            }
            defer { try? writer.close() }

            while true {
                try Task.checkCancellation()
                guard let chunk = try reader.read(upToCount: bufferSize),
                      !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
            }
        }.value
    }
}

// MARK: - OutputFileHeartbeat

/// Calls `onChange` whenever the file at `path` changes size or mtime,
/// polled every `intervalSeconds` — the "still writing" signal for ffmpeg
/// phases that print nothing (faststart's in-place rewrite, see
/// CombineEngine.runFFMpeg).
///
/// Polls on its OWN serial GCD queue, never the Swift concurrency pool: a
/// stat(2) on a drive that stopped answering can block in the kernel, and
/// that must pin one private queue thread, not one of the pool's few
/// threads. The watchdog fires independently of it either way.
/// (For Rick: ≈ a POSIX timer thread doing stat() and comparing st_size /
/// st_mtimespec against the last sample.)
final class OutputFileHeartbeat: @unchecked Sendable {

    struct Signature: Equatable, Sendable {
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
    }

    /// Size + mtime of `path`, or nil when it can't be stat'ed (not there yet).
    static func signature(_ path: String) -> Signature? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Signature(size: Int64(st.st_size),
                         mtimeSeconds: Int(st.st_mtimespec.tv_sec),
                         mtimeNanoseconds: Int(st.st_mtimespec.tv_nsec))
    }

    private let path: String
    private let intervalSeconds: Double
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Rick-Breen.VideoScan.combine-output-heartbeat", qos: .utility)
    /// `last` is touched only on `queue`; `timer` is guarded by `lock`
    /// (start/stop run on the caller's thread).
    private var last: Signature?
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(path: String, intervalSeconds: Double, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.intervalSeconds = max(intervalSeconds, 0.05)
        self.onChange = onChange
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: intervalSeconds)
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    private func sample() {
        let now = Self.signature(path)
        defer { last = now }
        if let last, now != last { onChange() }
    }
}
