import Foundation

/// One missing external tool, ready to render as an information dialog.
///
/// When a required tool (ffmpeg, ffprobe, Python venv, …) is not on disk,
/// operations like Scan and Combine fall back to a path that does nothing
/// visible — every probe fails silently and the UI looks frozen. The model
/// surfaces a `MissingDependency` instead so the user sees *why*.
struct MissingDependency: Equatable, Sendable {
    /// Package name as the user knows it (e.g. "ffmpeg"). Not necessarily
    /// the binary we probed for — ffmpeg ships ffprobe, so the check looks
    /// for ffprobe but the dialog says "ffmpeg".
    let displayName: String
    /// What the user was trying to do. Slotted into the message as
    /// "Cannot \(context), dependency: …".
    let context: String
    /// Suggested fix, copy/pasteable into Terminal.
    let installHint: String
    /// Paths we looked in, for the dialog's "where we searched" block.
    let searchedPaths: [String]

    var alertTitle: String { "Cannot \(context) — \(displayName) not installed" }

    var alertMessage: String {
        var lines = [
            "VideoScan needs \(displayName) for this operation.",
            "",
            "To install:",
            "    \(installHint)"
        ]
        if !searchedPaths.isEmpty {
            lines.append("")
            lines.append("Searched:")
            for p in searchedPaths { lines.append("    \(p)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Reusable preflight check. Each high-level operation (scan, combine, …)
/// has its own entry point so callers don't repeat the candidate list.
/// `nil` means all dependencies satisfied; a non-nil result is the first
/// missing tool to surface to the user.
enum DependencyChecker {

    /// Scan reads codec metadata via ffprobe. Missing ffprobe = every
    /// probe fails and the scan appears to hang.
    static func checkScan() -> MissingDependency? {
        checkTool(
            displayName: "ffmpeg",
            context: "scan",
            candidates: ToolLocator.ffprobeCandidates,
            envVar: ToolLocator.ffprobeEnvVar,
            installHint: "brew install ffmpeg"
        )
    }

    /// Combine muxes A/V pairs via ffmpeg without re-encoding.
    static func checkCombine() -> MissingDependency? {
        checkTool(
            displayName: "ffmpeg",
            context: "combine A/V pairs",
            candidates: ToolLocator.ffmpegCandidates,
            envVar: ToolLocator.ffmpegEnvVar,
            installHint: "brew install ffmpeg"
        )
    }

    /// Filmstrip preview rips frames via ffmpeg — and for MKV/FFV1
    /// masters there is NO alternate play surface (AVKit can't decode
    /// them), so a missing ffmpeg must surface as the standard dialog,
    /// never a dead play click (codex review, 2026-07-27).
    /// `environment`/`fileManager` are injectable so tests can simulate
    /// a bare machine — on a host with Homebrew ffmpeg the candidate
    /// scan would otherwise always pass.
    static func checkFilmstripPreview(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MissingDependency? {
        checkTool(
            displayName: "ffmpeg",
            context: "play filmstrip preview",
            candidates: ToolLocator.ffmpegCandidates,
            envVar: ToolLocator.ffmpegEnvVar,
            installHint: "brew install ffmpeg",
            environment: environment,
            fileManager: fileManager
        )
    }

    /// Generic worker. A tool is "available" if either the env-var
    /// override points at an executable file, or one of the built-in
    /// candidate paths is executable — mirroring `ToolLocator.resolve`.
    private static func checkTool(
        displayName: String,
        context: String,
        candidates: [String],
        envVar: String,
        installHint: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MissingDependency? {
        if let override = environment[envVar],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return nil
        }
        if ToolLocator.firstExecutable(in: candidates, fileManager: fileManager) != nil {
            return nil
        }
        return MissingDependency(
            displayName: displayName,
            context: context,
            installHint: installHint,
            searchedPaths: candidates
        )
    }
}
