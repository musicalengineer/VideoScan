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
func audioTrackIsPresent(at videoPath: String) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: videoPath) else {
        throw AudioTranscriberError.audioUnreadable(path: videoPath)
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    do {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        return !tracks.isEmpty
    } catch {
        throw AudioTranscriberError.audioUnreadable(path: videoPath)
    }
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [
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
        // Hardcoded ≈ a #define in C — fine for this narrow fix; if we ever
        // need a generic Homebrew-prefix detector we'll lift it then.
        env["PATH"] = augmentedPathWithHomebrew(
            inheriting: ProcessInfo.processInfo.environment["PATH"]
        )
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Cap captured stderr so a chatty model load doesn't leak
        // unbounded memory if something goes wrong upstream. 64 KB is
        // more than enough to identify the failure mode.
        let stderrCapMax = 64 * 1024

        // Run the subprocess on a background queue so we can `await`
        // its completion via continuation. Swift's `withCheckedThrowingContinuation`
        // ≈ a C++ promise/future bridge between callback APIs and
        // coroutines.
        do {
            try proc.run()
        } catch {
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: error.localizedDescription
            )
        }

        // Track which reason killed the subprocess. The cancelTask
        // races between Swift-level cancellation (user clicks Skip /
        // batch cancel / shutdown drain) and the wall-clock deadline,
        // and we need to disambiguate after waitUntilExit so the
        // caller throws the right typed error. `@unchecked Sendable`
        // is fine here — we mutate it from one Task and read it
        // exactly once after that Task has finished.
        final class KillReason: @unchecked Sendable {
            var deadlineHit = false
        }
        let killReason = KillReason()

        // Honor cancellation AND the wall-clock deadline. Single poll
        // loop checks both every 200ms. On either trip: SIGTERM, then
        // a brief grace period, then SIGKILL if the subprocess
        // ignored the soft signal. Same TERM→KILL escalation pattern
        // as ProcessRunner (which we'll migrate this code onto later
        // per docs/refactor_suggestions.md item #3).
        let killGraceSeconds: Double = 2.0
        let cancelTask = Task {
            while proc.isRunning {
                if Task.isCancelled {
                    transcribeLogger.notice("whisper subprocess cancelled for \(filename, privacy: .public) — sending SIGTERM")
                    proc.terminate()
                    try? await Task.sleep(for: .seconds(killGraceSeconds))
                    if proc.isRunning {
                        transcribeLogger.warning("whisper subprocess ignored SIGTERM for \(filename, privacy: .public) — sending SIGKILL")
                        kill(proc.processIdentifier, SIGKILL)
                    }
                    return
                }
                if let deadline = deadlineSeconds,
                   CFAbsoluteTimeGetCurrent() - started > deadline {
                    killReason.deadlineHit = true
                    transcribeLogger.warning("whisper subprocess exceeded \(deadline, format: .fixed(precision: 0), privacy: .public)s deadline for \(filename, privacy: .public) — sending SIGTERM")
                    proc.terminate()
                    try? await Task.sleep(for: .seconds(killGraceSeconds))
                    if proc.isRunning {
                        transcribeLogger.warning("whisper subprocess ignored SIGTERM (deadline) for \(filename, privacy: .public) — sending SIGKILL")
                        kill(proc.processIdentifier, SIGKILL)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { cancelTask.cancel() }

        // Drain stdout to the app log line-by-line so progress shows up
        // alongside other engines' output. Same line-buffer trick the
        // captioning runner uses.
        let stdoutData = await Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        let stderrData = await Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        proc.waitUntilExit()
        try Task.checkCancellation()

        let exitCode = proc.terminationStatus
        let stderrTail: String = {
            let bytes = stderrData.suffix(stderrCapMax)
            return String(data: bytes, encoding: .utf8) ?? ""
        }()

        // Stream stdout into the log for diagnostic context. Bounded
        // memory: we already have it all in stdoutData; we just split.
        if let stdoutText = String(data: stdoutData, encoding: .utf8) {
            for line in stdoutText.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    appLog.write("whisper[\(filename)]: \(trimmed)")
                }
            }
        }

        // Deadline kill MUST be checked before the generic subprocessFailed
        // branch — a TERM-killed Python exits with non-zero, but the
        // semantic cause is "we asked for it," not engine failure.
        if killReason.deadlineHit, let dl = deadlineSeconds {
            throw AudioTranscriberError.deadlineExceeded(seconds: dl)
        }

        if exitCode != 0 {
            transcribeLogger.error("whisper subprocess exited \(exitCode) for \(filename, privacy: .public): \(stderrTail, privacy: .public)")
            throw AudioTranscriberError.subprocessFailed(
                exitCode: exitCode, stderrTail: stderrTail
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
