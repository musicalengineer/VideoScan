import Foundation
import Combine
import os

// MARK: - AllFramesRipper
//
// "Extract Frames…" (verb split 2026-06-10) — export frames from a
// video as PNGs using ffmpeg ONLY. No Vision, no scoring, no ranking:
// either every frame, every Nth frame, or N frames per second,
// straight from the decoder to disk.
//
// Counterpart to FrameRipper ("Extract Facial Frames…"), which keeps
// the Vision face-quality gate. The two never share output folders:
// FrameRipper writes "<stem>-frames/", this writes "<stem>-allframes/".
//
// Disk-bomb awareness (Rick's explicit worry): a 10-minute DV tape at
// 29.97 fps is ~18,000 PNGs and several GB. RipAllFramesSheet shows a
// live frame-count + disk estimate BEFORE start, and the job subtitle
// repeats the estimate while running so a runaway export is visible.
//
// Memory footprint: O(1). ffmpeg streams decoded frames straight to
// PNG files — nothing is buffered app-side. We hold two Int counters,
// a bounded stderr tail (last `stderrTailMax` lines), and one Pipe
// buffer's worth of progress text. Worst case well under 1 MB
// regardless of source length.
//
// Split across two types:
//   - `AllFramesRipPlanner` — PURE helpers (argv construction, frame /
//     byte estimation). No I/O, no Process — unit-testable.
//   - `AllFramesRipper`     — the runner. Owns the ffmpeg Process,
//     parses `-progress pipe:1` output, publishes progress for the
//     operations-window row (via RipAllFramesJob's change forwarding).

private let allFramesLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "fileOps")

// MARK: - Planner (pure — no I/O)

enum AllFramesRipPlanner {

    /// Sampling strategy picked in RipAllFramesSheet.
    /// (≈ a C++ std::variant<EveryFrame, EveryNth, Fps> — the cases
    /// with payloads carry their own parameter.)
    enum Sampling: Equatable {
        /// One PNG per source frame. The disk-bomb mode — default, per
        /// Rick, but always behind the estimate in the options sheet.
        case everyFrame
        /// Keep frame indices where n % step == 0 (step ≥ 2).
        case everyNth(step: Int)
        /// Resample to a fixed rate (ffmpeg `fps=` filter), 1…60.
        case framesPerSecond(fps: Int)

        /// Short human label for log lines.
        var logDescription: String {
            switch self {
            case .everyFrame: return "every frame"
            case .everyNth(let step): return "every \(step)th frame"
            case .framesPerSecond(let fps): return "\(fps) fps"
            }
        }
    }

    /// "<stem>-allframes" — deliberately distinct from FrameRipper's
    /// "<stem>-frames" so the two verbs never collide on disk.
    static func destinationDirName(forStem stem: String) -> String {
        "\(stem)-allframes"
    }

    /// ffmpeg argv for one export. Pure function so the flag set per
    /// sampling mode is unit-testable without spawning ffmpeg (same
    /// rationale as CombineEngine.buildArgs).
    ///
    /// Mode → argv:
    ///   everyFrame      → -fps_mode passthrough   (one PNG per decoded
    ///                     frame; the modern spelling of -vsync 0)
    ///   everyNth(N)     → -vf select=not(mod(n\,N)) -fps_mode vfr
    ///                     (the \, is ffmpeg filtergraph escaping — a
    ///                     bare comma would split the filter chain; no
    ///                     shell is involved, Process passes the argv
    ///                     verbatim)
    ///   framesPerSecond → -vf fps=N (CFR resample; default fps_mode)
    ///
    /// `-progress pipe:1 -nostats` moves machine-readable progress
    /// (`frame=N` lines) to stdout and silences the human stderr
    /// spinner; `-nostdin` stops ffmpeg from eating the app's stdin.
    static func buildArgs(inputPath: String,
                          destinationDir: URL,
                          sampling: Sampling) -> [String] {
        var args = ["-y", "-nostdin", "-i", inputPath]
        switch sampling {
        case .everyFrame:
            args += ["-fps_mode", "passthrough"]
        case .everyNth(let step):
            args += ["-vf", "select=not(mod(n\\,\(step)))", "-fps_mode", "vfr"]
        case .framesPerSecond(let fps):
            args += ["-vf", "fps=\(fps)"]
        }
        args += ["-progress", "pipe:1", "-nostats"]
        args.append(destinationDir.appendingPathComponent("frame_%06d.png").path)
        return args
    }

    /// Parse the catalog's frame-rate string ("29.97" from ffprobe via
    /// Formatting.fraction, or a raw "30000/1001" from the combine
    /// refresh path). nil when the metadata is missing/unparseable.
    static func sourceFPS(fromCatalogString raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed), direct > 0 { return direct }
        let parts = trimmed.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 {
            let fps = parts[0] / parts[1]
            return fps > 0 ? fps : nil
        }
        return nil
    }

    /// Estimated output frame count, or nil when the needed metadata
    /// is missing (caller shows "unknown" and the row goes
    /// indeterminate). framesPerSecond only needs duration; the other
    /// two modes also need the source rate.
    static func estimatedFrames(durationSeconds: Double,
                                sourceFPS: Double?,
                                sampling: Sampling) -> Int? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        switch sampling {
        case .everyFrame:
            guard let fps = sourceFPS else { return nil }
            return max(1, Int(durationSeconds * fps))
        case .everyNth(let step):
            guard let fps = sourceFPS, step > 0 else { return nil }
            return max(1, Int(durationSeconds * fps / Double(step)))
        case .framesPerSecond(let fps):
            guard fps > 0 else { return nil }
            return max(1, Int(durationSeconds * Double(fps)))
        }
    }

    /// Rough PNG bytes per frame from a "WxH" resolution string.
    /// Heuristic: 3 bytes/pixel RGB × ~0.45 PNG deflate ratio for
    /// natural video content. Sanity-checked against Rick's reference
    /// point — 720×480 DV ⇒ ~466 KB/frame ⇒ 10 min ≈ 18k frames ≈
    /// 8 GB ("several GB" ✓). An estimate, not a promise — the sheet
    /// labels it "~".
    static func estimatedBytesPerFrame(resolution: String) -> Int64? {
        let parts = resolution.lowercased().split(separator: "x")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return Int64(Double(parts[0]) * Double(parts[1]) * 3.0 * 0.45)
    }

    /// Total disk estimate, nil when either input is unknown.
    static func estimatedTotalBytes(frames: Int?, resolution: String) -> Int64? {
        guard let frames, let perFrame = estimatedBytesPerFrame(resolution: resolution) else {
            return nil
        }
        return Int64(frames) * perFrame
    }
}

// MARK: - Ripper (runs ffmpeg)

@MainActor
final class AllFramesRipper: ObservableObject {

    // MARK: Published state (drives the operations-window row via
    // RipAllFramesJob's change forwarding — same contract FrameRipper
    // has with ExtractFramesJob)

    /// True while ffmpeg is in flight.
    @Published var isRunning = false

    /// Live status line for the row subtitle.
    @Published var statusText = ""

    /// Frames written so far, parsed from ffmpeg's `frame=` progress
    /// lines (updates ~2×/second).
    @Published var framesWritten = 0

    /// Last non-recoverable error message, or nil.
    @Published var lastError: String?

    /// Output folder once the run reaches a terminal state with any
    /// frames on disk. Set on success AND on cancel-with-partials so
    /// the row's Reveal button works either way (mirrors FrameRipper).
    @Published var completedDestination: URL?

    /// True between user-pressed Cancel and ffmpeg actually exiting.
    @Published var isCancelling = false

    /// Actual bytes on disk, measured ONCE at the end of the run by
    /// summing the output folder (cheap directory walk; never during).
    @Published var bytesWritten: Int64 = 0

    // MARK: Options

    struct Options {
        var sampling: AllFramesRipPlanner.Sampling = .everyFrame
        /// Pre-computed estimates from the options sheet (nil ⇒
        /// metadata was missing; progress runs indeterminate). Carried
        /// here so the fraction and subtitles don't re-derive them.
        var estimatedFrames: Int?
        var estimatedBytes: Int64?
    }

    private(set) var options = Options()

    /// Keep only the tail of ffmpeg's stderr for the failure message —
    /// the useful part of an ffmpeg error is always the last few lines.
    /// `nonisolated`: the class is @MainActor but this constant is read
    /// from the nonisolated process runner — an immutable Int is safe
    /// from any thread (≈ a C++ static constexpr).
    private nonisolated static let stderrTailMax = 30

    // MARK: Entry point

    /// Run one export inline in the caller's task (RipAllFramesJob owns
    /// that Task — survives window close). Cancellation arrives via the
    /// caller's Task being cancelled: the cancellation handler SIGTERMs
    /// ffmpeg, which exits cleanly; PNGs already written stay on disk.
    func run(videoURL: URL, intoParent parentDir: URL, options: Options) async {
        self.options = options
        isRunning = true
        isCancelling = false
        statusText = "Preparing…"
        framesWritten = 0
        bytesWritten = 0
        lastError = nil
        completedDestination = nil

        // Build output dir: <parent>/<videoStem>-allframes/
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let destDir = parentDir.appendingPathComponent(
            AllFramesRipPlanner.destinationDirName(forStem: stem),
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destDir,
                                                    withIntermediateDirectories: true)
        } catch {
            finish(error: "Couldn't create folder: \(error.localizedDescription)",
                   destDir: nil)
            return
        }

        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            finish(error: "ffmpeg not found — install via Homebrew or set VS_FFMPEG_PATH.",
                   destDir: nil)
            return
        }

        let args = AllFramesRipPlanner.buildArgs(inputPath: videoURL.path,
                                                 destinationDir: destDir,
                                                 sampling: options.sampling)
        allFramesLog.info("ripFrames ffmpeg argv: \(args.joined(separator: " "), privacy: .public)")
        statusText = "Starting ffmpeg…"

        let result = await Self.runFFmpeg(
            executable: ffmpeg,
            arguments: args,
            onFrameProgress: { [weak self] frame in
                // Pipe handlers fire on a background queue; hop to the
                // main actor for the @Published writes (same pattern as
                // CombineEngine's log callback).
                Task { @MainActor [weak self] in
                    self?.noteFrameProgress(frame)
                }
            })

        // Terminal bookkeeping — count what actually landed on disk
        // (progress lines can lag the truth by a flush interval).
        let (fileCount, fileBytes) = Self.tallyOutput(in: destDir)
        framesWritten = max(framesWritten, fileCount)
        bytesWritten = fileBytes

        if Task.isCancelled || isCancelling {
            // SIGTERM path — ffmpeg exits non-zero, but that's not a
            // failure. Keep partial output discoverable via Reveal.
            finish(error: nil, destDir: fileCount > 0 ? destDir : nil, cancelled: true)
            return
        }
        if result.exitCode != 0 {
            finish(error: "ffmpeg exited with status \(result.exitCode)"
                        + (result.stderrTail.isEmpty ? "" : " — \(result.stderrTail)"),
                   destDir: fileCount > 0 ? destDir : nil)
            return
        }
        finish(error: nil, destDir: destDir)
    }

    /// User-facing cancel hint mirrored from the job (the actual stop
    /// is the job's task.cancel() reaching the cancellation handler).
    func markCancelling() {
        isCancelling = true
        statusText = "Stopping…"
    }

    // MARK: Progress

    private func noteFrameProgress(_ frame: Int) {
        guard isRunning, !isCancelling else { return }
        framesWritten = frame
        if let total = options.estimatedFrames {
            var line = "Frame \(frame.formatted()) of ~\(total.formatted())"
            if let bytes = options.estimatedBytes {
                line += " — est. \(Formatting.humanSize(bytes)) total"
            }
            statusText = line
        } else {
            statusText = "Frame \(frame.formatted()) written…"
        }
    }

    private func finish(error: String?,
                        destDir: URL?,
                        cancelled: Bool = false) {
        isRunning = false
        isCancelling = false
        if let error {
            statusText = "Error"
            lastError = error
        } else if cancelled {
            statusText = "Cancelled"
        } else {
            statusText = "Done — \(framesWritten.formatted()) frame(s), \(Formatting.humanSize(bytesWritten))"
        }
        completedDestination = destDir
    }

    // MARK: ffmpeg process (CombineEngine's launch pattern)

    private struct FFmpegResult: Sendable {
        let exitCode: Int32
        let stderrTail: String
    }

    /// Launch ffmpeg, stream `frame=` progress from stdout, keep a
    /// bounded stderr tail, and await termination. Cancellation-aware:
    /// `proc.terminate()` (SIGTERM) on task cancel — ffmpeg flushes the
    /// current PNG and exits. The terminationHandler resumes the
    /// continuation, so the process is reaped without a blocked thread
    /// (≈ SIGCHLD + waitpid handled by Foundation for us).
    nonisolated private static func runFFmpeg(
        executable: String,
        arguments: [String],
        onFrameProgress: @escaping @Sendable (Int) -> Void
    ) async -> FFmpegResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let stderrTail = LineTail(maxLines: stderrTailMax)
        let progressParser = ProgressLineParser(onFrame: onFrameProgress)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { progressParser.append(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8),
               !text.isEmpty {
                stderrTail.append(text)
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain whatever the handlers hadn't consumed yet.
                    let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        stderrTail.append(text)
                    }
                    continuation.resume(returning: FFmpegResult(
                        exitCode: p.terminationStatus,
                        stderrTail: stderrTail.joined))
                }
                do {
                    try proc.run()
                    // Cancel raced the launch — kill the child we just
                    // started (the onCancel below already ran and found
                    // nothing to terminate).
                    if Task.isCancelled, proc.isRunning { proc.terminate() }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: FFmpegResult(
                        exitCode: -1,
                        stderrTail: "Failed to launch ffmpeg: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Count PNGs + total bytes in the output folder (shallow — ffmpeg
    /// writes a flat directory). One pass at end-of-run only.
    nonisolated private static func tallyOutput(in dir: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for name in names where name.hasSuffix(".png") {
            count += 1
            let path = dir.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                bytes += size
            }
        }
        return (count, bytes)
    }

    // MARK: Pipe-side helpers (thread-safe, bounded)

    /// Keeps only the last N lines of stderr — ffmpeg failure output is
    /// tail-heavy and we must not buffer unbounded text.
    private final class LineTail: @unchecked Sendable {
        private let lock = NSLock()
        private let maxLines: Int
        private var lines: [String] = []

        init(maxLines: Int) { self.maxLines = maxLines }

        func append(_ text: String) {
            lock.lock()
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            lock.unlock()
        }

        var joined: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.suffix(5).joined(separator: " | ")
        }
    }

    /// Accumulates `-progress pipe:1` output and emits the frame number
    /// from each complete `frame=N` line.
    private final class ProgressLineParser: @unchecked Sendable {
        private let lock = NSLock()
        private let onFrame: @Sendable (Int) -> Void
        private var pending = ""

        init(onFrame: @escaping @Sendable (Int) -> Void) {
            self.onFrame = onFrame
        }

        func append(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            pending += text
            let parts = pending.components(separatedBy: "\n")
            pending = parts.last ?? ""
            let complete = parts.dropLast()
            lock.unlock()

            // Progress blocks repeat ~2×/s; only the newest frame=
            // value in this chunk matters.
            var newest: Int?
            for line in complete where line.hasPrefix("frame=") {
                if let n = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                    newest = n
                }
            }
            if let newest { onFrame(newest) }
        }
    }
}
