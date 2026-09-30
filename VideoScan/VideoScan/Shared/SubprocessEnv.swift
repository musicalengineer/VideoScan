import Foundation

// MARK: - Subprocess environment helpers
//
// Shared utilities for setting up the environment dictionary that gets
// handed to `Process()` instances launched by VideoScan. Pulled out of
// AudioTranscriber.swift in fix/identify-family-path so sibling
// subprocess launchers (IdentifyFamilyModel, future Python runners,
// etc.) can apply the same PATH-augmentation fix without duplicating
// the helper. Keep additions here narrow and orthogonal — this is not a
// catch-all utility file.

/// Build a PATH string that prefixes the standard Homebrew prefixes
/// onto whatever the parent process inherited. Exposed at file scope
/// (rather than buried in any one launcher) so a unit test can pin the
/// ordering contract without spawning a real subprocess, and so any
/// `Process()` caller that shells out to a Homebrew-installed tool
/// (ffmpeg, ffprobe, hdiutil — actually those last two live under
/// /usr/bin, but any tool the child Python may itself `subprocess` to)
/// can reach those tools regardless of how the parent app was launched.
///
/// Order matters: `/opt/homebrew/bin` is checked first (Apple Silicon),
/// then `/usr/local/bin` (Intel / older installs), then the inherited
/// PATH. A nil/empty inherited PATH falls back to the POSIX default so
/// we never produce a string with a trailing colon (which on some
/// shells implicitly means "include cwd" — not what we want).
///
/// Background: when the app is launched from Xcode or Finder the
/// inherited PATH typically doesn't include `/opt/homebrew/bin`. Any
/// Python child that shells out to e.g. `ffmpeg` (mlx-whisper does
/// this internally, as does facenet preprocessing in cluster_faces.py)
/// fails with `[Errno 2] No such file or directory: 'ffmpeg'`.
/// Prepending the Homebrew prefixes here makes the lookup work
/// regardless of how the parent app was launched.
internal func augmentedPathWithHomebrew(inheriting inheritedPath: String?) -> String {
    let inherited: String = {
        if let p = inheritedPath, !p.isEmpty { return p }
        return "/usr/bin:/bin:/usr/sbin:/sbin"
    }()
    return "/opt/homebrew/bin:/usr/local/bin:" + inherited
}
