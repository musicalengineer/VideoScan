import Foundation
import AVFoundation
import os

// MARK: - Audio Transcriber
//
// Engine-agnostic abstraction for on-device speech-to-text. Sibling to
// CaptionRunner: where CaptionRunner turns video frames into prose,
// AudioTranscriber turns audio tracks into prose. The shape is
// deliberately a near-mirror of CaptionRunner so the orchestration
// layer (Phase 2 — "Transcribe Audio" button, progress sheet, cancel)
// can model the two pipelines with the same patterns.
//
// Phase 1 scope: protocol + two implementations + writeback + search.
// No UI. The orchestration layer is a separate later dispatch.
//
// Engine selection rationale (engine-wiring report, Phase 1):
//
//   mlx-swift-examples 2.29.1 exposes MLXLLM, MLXVLM, MLXLMCommon,
//   MLXMNIST, MLXEmbedders, StableDiffusion. **No Whisper module.**
//   Verified by inspecting the package's Package.swift after Xcode
//   resolved deps. There is no `MLXWhisper` product to import.
//
//   So the primary working path in Phase 1 is the Python subprocess
//   runner against `mlx-whisper` in the venv-mlx environment — same
//   isolation pattern Rick already accepted for vlm_caption.py. When
//   mlx-swift-examples (or a third-party MLX Swift Whisper port)
//   ships a real Swift Whisper module, the `MLXWhisperTranscriber`
//   stub here flips to a real implementation behind the same
//   `#if canImport(...)` fence the captioning code uses.
//
// Build-config note: `MLXWhisperTranscriber` is structurally a stub
// that throws `.notImplemented` today. We keep the type alive so
// orchestration code can already pattern-match on the engine choice
// and the file already exports the shape we'll wire to once an MLX
// Whisper Swift port lands. The Python subprocess runner is the one
// you actually call right now.

/// Speech-to-text interface. Implementations should be `Sendable` so
/// the transcription loop can ferry them across actors (mirrors
/// CaptionRunner).
protocol AudioTranscriber: Sendable {

    /// Identifier written into `VideoRecord.audioTranscriptModel` as
    /// provenance. Suggested format: short, stable, machine-readable
    /// (e.g. "whisper-medium-mlx-q4",
    /// "python-whisper-medium-mlx-q4"). Lets the UI later filter
    /// "transcribed with X" or offer a "re-transcribe with current
    /// model" action.
    var modelID: String { get }

    /// Transcribe the audio track of the file at `videoPath`. For
    /// audio-only files this is the entire content; for video+audio
    /// files, just the audio track is transcribed. Returns the full
    /// transcript as a single string.
    ///
    /// An empty string is a valid return value — it means "speech
    /// recognition ran and found nothing recognizable" (e.g. ambient
    /// noise, music with no vocals). The writeback layer distinguishes
    /// that case from "never transcribed" via `audioTranscriptModel ==
    /// nil`.
    ///
    /// Throws `AudioTranscriberError` on engine failure (model load,
    /// out-of-memory, inability to open the file). Cancellation
    /// honored via `Task.checkCancellation()` between chunks so the
    /// orchestrator's "Cancel Transcription" can stop a run mid-file.
    ///
    /// `deadlineSeconds`, when non-nil, bounds the wall-clock time
    /// spent on this file. On expiry the implementation must terminate
    /// any subprocesses (SIGTERM then SIGKILL after a brief grace
    /// period) and throw `AudioTranscriberError.deadlineExceeded`.
    /// Default `nil` preserves backward compatibility for stubs.
    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String
}

extension AudioTranscriber {
    /// Default forwarding so existing call sites and stubs that don't
    /// care about the deadline keep compiling. Concrete production
    /// implementations override the deadlined form.
    func transcribe(videoPath: String) async throws -> String {
        try await transcribe(videoPath: videoPath, deadlineSeconds: nil)
    }
}

// MARK: - Errors

/// Typed errors the orchestration UI can pattern-match on for user
/// messaging. Mirrors `CaptionRunnerError`.
enum AudioTranscriberError: Error, CustomStringConvertible {
    /// Engine not yet wired — stub implementation. Today this fires
    /// from MLXWhisperTranscriber because mlx-swift-examples 2.29.1
    /// has no Whisper module; will go away if/when an MLX Swift
    /// Whisper port lands.
    case notImplemented(engine: String)

    /// Whisper model couldn't be loaded (missing weights, version
    /// mismatch, OOM during weight load).
    case modelLoadFailed(reason: String)

    /// Audio could not be read (file missing, unreadable, no audio
    /// stream, decoder failure during extraction).
    case audioUnreadable(path: String)

    /// Python subprocess for the Python path could not be launched
    /// (missing interpreter, missing script, exec failure). Distinct
    /// from `modelLoadFailed` because the failure is at the process
    /// boundary, not inside the Python.
    case subprocessLaunchFailed(reason: String)

    /// Python subprocess exited with non-zero status. The captured
    /// stderr tail is surfaced to help diagnose.
    case subprocessFailed(exitCode: Int32, stderrTail: String)

    /// Subprocess exceeded the wall-clock deadline the caller passed
    /// (auto-kill via SIGTERM → SIGKILL). Distinct from `subprocessFailed`
    /// so the orchestrator can render "whisper timed out" instead of
    /// "transcript failed" in the activity feed.
    case deadlineExceeded(seconds: Double)

    /// Engine threw something unrecognized; preserves the underlying
    /// error for diagnostic logging.
    case underlying(Error)

    var description: String {
        switch self {
        case .notImplemented(let engine):
            return "Audio transcriber '\(engine)' is not yet implemented."
        case .modelLoadFailed(let reason):
            return "Whisper model load failed: \(reason)"
        case .audioUnreadable(let path):
            return "Could not read audio at \(path)"
        case .subprocessLaunchFailed(let reason):
            return "Transcription subprocess could not start: \(reason)"
        case .subprocessFailed(let exit, let tail):
            return "Transcription subprocess exited \(exit). stderr: \(tail)"
        case .deadlineExceeded(let secs):
            return "Transcription subprocess exceeded its \(Int(secs))s deadline and was killed."
        case .underlying(let err):
            return "Transcription engine error: \(err)"
        }
    }
}

/// The orchestrator logs a failure as `error.localizedDescription`. Without
/// LocalizedError that is Foundation's "The operation couldn't be completed.
/// (VideoScan.AudioTranscriberError error 4.)" and the reason — e.g. the
/// script's "model … is not on this Mac" — is lost (2026-11-05).
/// LocalizedError ≈ overriding std::exception::what(): the generic catch site
/// now prints the specific message.
extension AudioTranscriberError: LocalizedError {
    var errorDescription: String? { description }
}

// MARK: - Shared logger

private let transcribeLogger = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "transcription")

// MARK: - Reachability helper
//
// Cheap up-front check shared by both engines. Either we have a file
// with at least one audio track that AVFoundation can read, or we
// throw `.audioUnreadable` before paying any model-load cost.
//
// Worst-case memory footprint: AVURLAsset metadata load only — no
// PCM buffered. Track listing is a few KB.

/// True if `videoPath` exists, is openable as an AVAsset, and exposes
/// at least one audio track. Used as a fail-fast gate so the
/// expensive Whisper model load only happens on files we can actually
/// hand it audio for.
///
/// Swift's `async` on a free function ≈ a C++ coroutine — caller does
/// `try await` to consume.
/// Two-tier (2026-07-05): AVFoundation answers for the containers it
/// can parse; when it can't open the file at all — Rick's FFV1+PCM
/// Matroska masters, which AVFoundation has zero support for — ffprobe
/// is the arbiter. The downstream decode is mlx-whisper's own internal
/// ffmpeg, so "ffprobe sees audio" is exactly the right admission test.
/// Pinned by MKVDossierPipelineTests.
func audioTrackIsPresent(at videoPath: String) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: videoPath) else {
        throw AudioTranscriberError.audioUnreadable(path: videoPath)
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    do {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if !tracks.isEmpty { return true }
        // Container parsed, zero audio tracks: usually a genuinely
        // video-only clip — but some AVF versions report "no tracks"
        // instead of throwing for containers they can't fully read.
        // ffprobe settles it either way (video-only stays false).
        return await ffprobeReportsAudioStream(at: videoPath)
    } catch {
        // AVFoundation can't open the container. If ffprobe can see an
        // audio stream, the file is fine — the container is just
        // AVFoundation-hostile (mkv / FFV1).
        if await ffprobeReportsAudioStream(at: videoPath) {
            transcribeLogger.notice("AVFoundation can't open \((videoPath as NSString).lastPathComponent, privacy: .public) — ffprobe confirms an audio stream, admitting for transcription")
            return true
        }
        throw AudioTranscriberError.audioUnreadable(path: videoPath)
    }
}

/// ffprobe arbiter for the preflight above: does the file contain at
/// least one audio stream? Missing ffprobe or a probe failure returns
/// false (callers keep AVFoundation's verdict). Deadline guards the
/// classic dead-network-volume hang.
private func ffprobeReportsAudioStream(at videoPath: String) async -> Bool {
    let ffprobe = ToolLocator.ffprobePath
    guard FileManager.default.isExecutableFile(atPath: ffprobe) else { return false }
    let result = await ProcessRunner.runProcess(
        executable: ffprobe,
        arguments: ["-v", "error",
                    "-select_streams", "a",
                    "-show_entries", "stream=index",
                    "-of", "csv=p=0",
                    videoPath],
        deadlineSeconds: 30)
    guard result.exitCode == 0, let out = result.stdout else { return false }
    return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - MLX Whisper engine (stub awaiting upstream Swift port)
//
// Stub today. mlx-swift-examples 2.29.1 ships no Whisper module —
// confirmed by inspecting the package's Package.swift. When/if a Swift
// Whisper module ships (either in mlx-swift-examples or as a separate
// SPM dep), the `#if canImport(MLXWhisper)` fence below activates and
// the body will mirror MLXVLMCaptionRunner's shape:
//
//   1. Extract 16 kHz mono PCM from the audio track via AVAssetReader.
//   2. runMLX { try await model.transcribe(pcm) } — same crash-safety
//      wrapper captioning uses, same SIGTRAP class applies.
//   3. Return the full transcript string.
//
// Until then this throws `.notImplemented` so the orchestration layer
// can already enumerate engines without compile errors. Phase-1
// callers should use `PythonSubprocessAudioTranscriber`.

#if canImport(MLXWhisper)

#error("MLX Whisper Swift module became available — implement MLXWhisperTranscriber body")

#else

/// Placeholder for a future MLX-swift Whisper engine. Throws
/// `.notImplemented` today. See file header for why.
struct MLXWhisperTranscriber: AudioTranscriber {
    let modelID: String = "whisper-medium-mlx-q4"

    init() {}

    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String {
        let filename = (videoPath as NSString).lastPathComponent
        appLog.write("AudioTranscriber(MLXWhisper) stub for \(filename) — no Swift Whisper module in mlx-swift-examples 2.29.1; use PythonSubprocessAudioTranscriber")
        _ = deadlineSeconds  // stub never runs; would honor the deadline if it did.
        throw AudioTranscriberError.notImplemented(engine: "MLXWhisper")
    }
}

#endif

// MARK: - Python subprocess engine
//
// Primary working implementation for Phase 1. Shells out to
// `scripts/whisper_transcribe.py` running inside the venv-mlx
// environment. Same isolation strategy Rick adopted for VLM
// captioning: keep MLX-Python (numpy>=2, transformers>=5) away from
// the dlib/facenet venv that needs numpy<2.
//
// Worst-case memory footprint:
//   * Swift side: at most one chunk of stdout/stderr in flight per
//     readability handler. Whisper transcripts are kilobytes, not
//     megabytes — bounded.
//   * Python side: model weights (medium-q4 ≈ 244 MB) + decoded PCM
//     for the input file. mlx-whisper streams 30-second windows
//     internally, so even an hour-long MXF stays in the low GB.
//
// Output protocol: the Python script writes the transcript to a
// temp file (path passed via --out) so we don't have to parse mixed
// progress + transcript on stdout. Stdout/stderr are surfaced to
// the app log for diagnostic context.

// NOTE: `augmentedPathWithHomebrew(inheriting:)` used to live here.
// It moved to SubprocessEnv.swift in fix/identify-family-path so
// IdentifyFamilyModel (and any future Process()-launching code that
// shells out to Homebrew tools) can share the same helper. Behavior
// and ordering contract are unchanged — see SubprocessEnv.swift for
// the doc comment.

/// The last `capBytes` of the subprocess's stderr, kept line by line as the
/// runner delivers it (ProcessRunner's own cap keeps the FIRST bytes; a
/// failure's cause is at the END of a chatty model load). Memory: at most
/// `capBytes` plus one line.
/// (C++: a mutex-guarded std::deque<std::string> trimmed from the front.)
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private let capBytes: Int
    private var lines: [String] = []
    private var bytes = 0

    init(capBytes: Int) { self.capBytes = capBytes }

    func add(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        bytes += line.utf8.count + 1
        while bytes > capBytes, lines.count > 1 {
            bytes -= lines.removeFirst().utf8.count + 1
        }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(lines.joined(separator: "\n").suffix(capBytes))
    }
}

struct PythonSubprocessAudioTranscriber: AudioTranscriber {

    let modelID: String = "python-whisper-medium-mlx-q4"

    /// Path to the Python executable that has `mlx-whisper` installed.
    /// User-configured (mirrors PersonFinder's `pythonPath` setting).
    let pythonPath: String

    /// Path to `scripts/whisper_transcribe.py` in the repo / user env.
    let scriptPath: String

    /// HuggingFace model id passed through to mlx-whisper. Default is
    /// the q4 medium model — good quality/size balance per the spec.
    let hfModel: String

    init(
        pythonPath: String,
        scriptPath: String,
        hfModel: String = "mlx-community/whisper-medium-mlx-q4"
    ) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.hfModel = hfModel
    }

    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String {
        let filename = (videoPath as NSString).lastPathComponent
        let started = CFAbsoluteTimeGetCurrent()

        // Fail-fast gate. Throws `.audioUnreadable` for missing files or
        // files with no audio track — saves us a multi-hundred-MB Whisper
        // weight download for inputs we can't transcribe anyway.
        let hasAudio = try await audioTrackIsPresent(at: videoPath)
        guard hasAudio else {
            throw AudioTranscriberError.audioUnreadable(path: videoPath)
        }

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: "Python interpreter missing: \(pythonPath)"
            )
        }
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: "Script missing: \(scriptPath)"
            )
        }

        // Output goes to a sandboxed temp file. We don't try to parse
        // the transcript out of stdout because progress + diagnostics
        // also land there.
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-transcribe-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: "Could not create scratch dir: \(error.localizedDescription)"
            )
        }
        let outFile = outDir.appendingPathComponent("transcript.txt")
        defer {
            // Best-effort cleanup — scratch under /tmp gets cleaned by
            // macOS eventually anyway, but be tidy.
            try? FileManager.default.removeItem(at: outDir)
        }

        // One shot through ProcessRunner (2026-11-21; this was a hand-rolled
        // `Process()` with its own deadline poll and kill escalation). Same
        // executable, argv and environment; the runner now owns what the
        // hand-rolled code did by hand:
        //   • deadline → SIGTERM → (2 s) SIGKILL → abandon   (`deadlineSeconds`,
        //     `killGraceSeconds`; `Result.timedOut` says it was ours)
        //   • task cancellation (skipLane) → SIGTERM → (2 s) SIGKILL
        //   • both pipes drained continuously (a chatty child cannot block)
        // and a ScriptedExecutor can answer it in a test.
        let arguments = [
            "-u",                 // unbuffered stdout/stderr — matches
            scriptPath,           // IdentifyFamilyModel.swift pattern
            videoPath,
            "--model", hfModel,
            "--out", outFile.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // mlx-whisper shells out to `ffmpeg` internally for audio decoding.
        // When the app is launched from Xcode or Finder, the inherited PATH
        // typically doesn't include /opt/homebrew/bin (or /usr/local/bin on
        // Intel), so the Python child fails with `[Errno 2] No such file or
        // directory: 'ffmpeg'`. Prepending Homebrew prefixes makes the
        // lookup work regardless of how the parent app was launched.
        env["PATH"] = augmentedPathWithHomebrew(
            inheriting: ProcessInfo.processInfo.environment["PATH"]
        )

        // Cap captured stderr so a chatty model load doesn't leak
        // unbounded memory if something goes wrong upstream. 64 KB is
        // more than enough to identify the failure mode.
        let stderrTail = StderrTail(capBytes: 64 * 1024)

        // The deadline has always been measured from the top of this
        // function (the audio preflight spends part of it); keep that.
        // 0.2 s floor = the old watcher's first poll.
        let remaining = deadlineSeconds.map { max(0.2, $0 - (CFAbsoluteTimeGetCurrent() - started)) }

        let result = await ProcessRunner.runProcess(
            executable: pythonPath,
            arguments: arguments,
            environment: env,
            // Progress + diagnostics go to the app log as they are printed,
            // alongside the other engines' output; nothing is collected.
            stdoutLine: { line in appLog.write("whisper[\(filename)]: \(line)") },
            stderrLine: { line in stderrTail.add(line) },
            stdoutLimitBytes: 0,
            stderrLimitBytes: 0,
            deadlineSeconds: remaining,
            killGraceSeconds: 2.0)

        // A cancelled parent (skipLane) is our signal to the orchestrator
        // to bank VLM-only and tag "user skipped" — before any other
        // reading of the result (a cancel also makes the exit nonzero, and
        // a cancel before the launch leaves `launched` false).
        try Task.checkCancellation()

        guard result.launched else {
            throw AudioTranscriberError.subprocessLaunchFailed(reason: result.stderr)
        }

        if result.exitCode != 0 {
            // Deadline kill MUST be checked before the generic
            // subprocessFailed — a TERM-killed Python exits non-zero, but
            // the cause is "we asked for it," not engine failure. (Exit
            // status first: a child that finished as the deadline fired
            // did its work — see ProcessRunner.Result.timedOut.)
            if result.timedOut, let dl = deadlineSeconds {
                transcribeLogger.warning("whisper subprocess exceeded \(dl, format: .fixed(precision: 0), privacy: .public)s deadline for \(filename, privacy: .public) — stopped")
                throw AudioTranscriberError.deadlineExceeded(seconds: dl)
            }
            let tail = stderrTail.text
            transcribeLogger.error("whisper subprocess exited \(result.exitCode) for \(filename, privacy: .public): \(tail, privacy: .public)")
            throw AudioTranscriberError.subprocessFailed(
                exitCode: result.exitCode, stderrTail: tail
            )
        }

        // Read the transcript file the script wrote.
        let transcript: String
        do {
            transcript = try String(contentsOf: outFile, encoding: .utf8)
        } catch {
            throw AudioTranscriberError.underlying(error)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        appLog.write(String(format: "AudioTranscriber(Python) transcribed %@ — %d chars in %.1fs",
                            filename, cleaned.count, elapsed))
        return cleaned
    }
}
