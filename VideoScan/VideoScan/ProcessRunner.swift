import Foundation

// NOTE (2026-07-28, Stage 1 of the out-of-process preview helper):
// `ProcessRunner` moved to VideoScanCore (Sources/VideoScanCore/ProcessRunner.swift)
// so the CLI helper — which links only the domain package, not this app —
// shells out through the SAME runner. Every `ProcessRunner.*` call site in
// the app still resolves unchanged via `@_exported import VideoScanCore`
// (VideoScanCoreExports.swift). Only `ToolLocator` remains here, because it
// still knows app-specific tool layout (the venv/whisper script paths). Its
// ffmpeg/ffprobe knowledge now FORWARDS to `FFmpegLocator` (Core) — one
// candidate list shared by the app and the CLI, no drift.

/// Resolves filesystem paths for external command-line tools (ffmpeg, ffprobe,
/// Python) that VideoScan shells out to. Single source of truth so hard-coded
/// candidate lists don't spread through the codebase.
///
/// Resolution order for each tool:
///   1. Environment variable override (e.g. `VS_FFMPEG_PATH`) — wins if set
///      AND the path is executable. Lets users point at a non-standard
///      install (Nix, manual build, etc.) without recompiling.
///   2. First executable candidate from the built-in list.
///   3. Fallback string (preserves prior behavior — callers see a "command
///      not found" error rather than an empty-string crash).
///
/// Tested in `ToolLocatorTests`.
enum ToolLocator {
    // MARK: - Env-var override names (public for tests + docs)
    // ffmpeg/ffprobe env-var names + candidate lists live in FFmpegLocator
    // (VideoScanCore) now; these forward so app call sites are unchanged.
    static var ffmpegEnvVar: String { FFmpegLocator.ffmpegEnvVar }
    static var ffprobeEnvVar: String { FFmpegLocator.ffprobeEnvVar }
    static let pythonEnvVar = "VS_PYTHON_PATH"
    static let python312EnvVar = "VS_PYTHON312_PATH"
    /// MLX-side Python — separate venv (`venv-mlx`) because mlx-whisper
    /// requires numpy>=2 while the dlib face-recognition env is pinned
    /// to numpy<2. Resolved independently from the dlib venv above.
    static let mlxPythonEnvVar = "VS_MLX_PYTHON_PATH"
    /// Path to scripts/whisper_transcribe.py — Whisper transcription
    /// driver run by `PythonSubprocessAudioTranscriber`. Env override
    /// lets test machines / CI point at the shipped script directly.
    static let whisperScriptEnvVar = "VS_WHISPER_SCRIPT_PATH"
    /// Path to scripts/whisper_worker.py — the persistent Whisper
    /// worker run by `WhisperWorkerTranscriber` (one model load per
    /// batch instead of one per file). Mirrors the whisper script
    /// entry above.
    static let whisperWorkerScriptEnvVar = "VS_WHISPER_WORKER_SCRIPT_PATH"

    static var ffmpegCandidates: [String] { FFmpegLocator.ffmpegCandidates }
    static var ffprobeCandidates: [String] { FFmpegLocator.ffprobeCandidates }
    static let pythonCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/venv/bin/python3",
        FileManager.default.currentDirectoryPath + "/.venv/bin/python",
        FileManager.default.currentDirectoryPath + "/venv/bin/python",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3"
    ]
    static let python312Candidates = [
        NSHomeDirectory() + "/dev/VideoScan/venv/bin/python3.12",
        FileManager.default.currentDirectoryPath + "/venv/bin/python3.12",
        "/opt/homebrew/bin/python3.12",
        "/usr/local/bin/python3.12"
    ]
    static let mlxPythonCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/venv-mlx/bin/python",
        NSHomeDirectory() + "/dev/VideoScan/venv-mlx/bin/python3",
        FileManager.default.currentDirectoryPath + "/venv-mlx/bin/python"
    ]
    static let whisperScriptCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/scripts/whisper_transcribe.py",
        FileManager.default.currentDirectoryPath + "/scripts/whisper_transcribe.py"
    ]
    static let whisperWorkerScriptCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/scripts/whisper_worker.py",
        FileManager.default.currentDirectoryPath + "/scripts/whisper_worker.py"
    ]

    /// First candidate path that is an executable file, or nil. Forwards to
    /// FFmpegLocator's pure helper (one implementation, shared with the CLI).
    static func firstExecutable(
        in candidates: [String],
        fileManager: FileManager = .default
    ) -> String? {
        FFmpegLocator.firstExecutable(in: candidates, fileManager: fileManager)
    }

    /// Resolve a tool path: env-var override (if set & executable) wins,
    /// otherwise first executable candidate, otherwise the supplied fallback.
    /// Exposed for tests; production accessors below use a default environment.
    static func resolve(
        envVar: String,
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallback: String
    ) -> String {
        FFmpegLocator.resolve(envVar: envVar, candidates: candidates,
                              environment: environment, fileManager: fileManager,
                              fallback: fallback)
    }

    static var ffmpegPath: String { FFmpegLocator.ffmpegPath }

    static var ffprobePath: String { FFmpegLocator.ffprobePath }

    /// pythonPath returns "" if nothing resolves — callers gate on this
    /// (rather than failing when the binary doesn't exist).
    static var pythonPath: String {
        resolve(envVar: pythonEnvVar, candidates: pythonCandidates, fallback: "")
    }

    static var python312Path: String {
        resolve(envVar: python312EnvVar, candidates: python312Candidates, fallback: python312Candidates[0])
    }

    /// MLX venv Python — empty if not present. Used by the Whisper
    /// transcription subprocess (mlx-whisper) and any future MLX-side
    /// Python script that can't be ported to mlx-swift yet.
    static var mlxPythonPath: String {
        resolve(envVar: mlxPythonEnvVar, candidates: mlxPythonCandidates, fallback: "")
    }

    /// Resolve a SCRIPT path: file-existence check, not executable bit
    /// — .py files aren't executable, the Python interpreter is.
    /// Same override-then-candidates order as `resolve`, but "" on
    /// miss (callers gate on empty). Injectable environment /
    /// FileManager for tests; production accessors below use defaults.
    static func resolveExistingFile(
        envVar: String,
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let override = environment[envVar],
           !override.isEmpty,
           fileManager.fileExists(atPath: override) {
            return override
        }
        for candidate in candidates where fileManager.fileExists(atPath: candidate) {
            return candidate
        }
        return ""
    }

    /// Path to the Whisper transcription script. Empty if not findable
    /// — caller must gate. Same shape as `pythonPath` (returns "" on
    /// miss rather than fabricating a path that won't exist).
    static var whisperScriptPath: String {
        resolveExistingFile(envVar: whisperScriptEnvVar,
                            candidates: whisperScriptCandidates)
    }

    /// Path to the persistent Whisper worker script. Empty if not
    /// findable — the transcriber resolution falls back to the
    /// per-file `whisperScriptPath` when this is missing.
    static var whisperWorkerScriptPath: String {
        resolveExistingFile(envVar: whisperWorkerScriptEnvVar,
                            candidates: whisperWorkerScriptCandidates)
    }
}
