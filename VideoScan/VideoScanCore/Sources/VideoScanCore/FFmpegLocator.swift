// FFmpegLocator.swift (VideoScanCore)
// The single source of truth for WHERE ffmpeg/ffprobe live on this machine,
// lifted out of the app's ToolLocator (2026-07-28, Stage 1) so the app AND
// the out-of-process preview helper resolve the exact same binary. The app's
// `ToolLocator.ffmpeg*`/`ffprobe*` members now forward here — no second
// candidate list, no drift on the env-var override contract.
//
// Resolution order (identical to the old ToolLocator behavior):
//   1. Env-var override (VS_FFMPEG_PATH / VS_FFPROBE_PATH) if set AND the
//      path is executable — lets a non-standard install win without a
//      recompile.
//   2. First executable candidate from the built-in Homebrew/system list.
//   3. Fallback (candidates[0]) so callers get a "command not found" error
//      rather than an empty-string crash.
//
// Foundation-only; the generic `resolve`/`firstExecutable` helpers are the
// same pure functions ToolLocator exposed (and ToolLocatorTests pins).

import Foundation

public enum FFmpegLocator {

    // MARK: - Env-var override names

    public static let ffmpegEnvVar = "VS_FFMPEG_PATH"
    public static let ffprobeEnvVar = "VS_FFPROBE_PATH"

    // MARK: - Built-in candidate lists

    public static let ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    public static let ffprobeCandidates = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe"
    ]

    // MARK: - Generic resolvers (pure)

    /// First candidate path that is an executable file, or nil.
    public static func firstExecutable(
        in candidates: [String],
        fileManager: FileManager = .default
    ) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Resolve a tool path: env-var override (if set & executable) wins,
    /// otherwise first executable candidate, otherwise the supplied fallback.
    public static func resolve(
        envVar: String,
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallback: String
    ) -> String {
        if let override = environment[envVar],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        if let found = firstExecutable(in: candidates, fileManager: fileManager) {
            return found
        }
        return fallback
    }

    // MARK: - Resolved paths

    public static var ffmpegPath: String {
        resolve(envVar: ffmpegEnvVar, candidates: ffmpegCandidates, fallback: ffmpegCandidates[0])
    }

    public static var ffprobePath: String {
        resolve(envVar: ffprobeEnvVar, candidates: ffprobeCandidates, fallback: ffprobeCandidates[0])
    }

    /// True when an executable ffmpeg is resolvable on this machine — the
    /// CLI's preflight (mirrors the app's DependencyChecker.checkFilmstripPreview
    /// intent without the app-side MissingDependency UI type).
    public static func ffmpegIsAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        if let override = environment[ffmpegEnvVar],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return true
        }
        return firstExecutable(in: ffmpegCandidates, fileManager: fileManager) != nil
    }
}
