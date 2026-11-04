import Foundation
import VideoScanCore

// MARK: - Subprocess environment helpers
//
// The app's name for the one PATH rule, which lives in VideoScanCore's
// `SubprocessEnvironment` (moved 2026-11-04 so VideoScan Background builds
// its worker's environment the same way — the 2026-11-03 launchd bug: the
// helper's Python worker could not find `ffmpeg`). Call sites
// (AudioTranscriber, IdentifyFamilyModel, …) keep this name; there is no
// second builder.

/// Homebrew's bin folders (`/opt/homebrew/bin`, then `/usr/local/bin`)
/// ahead of the inherited PATH; nil/empty falls back to the POSIX default
/// with no trailing colon. See `SubprocessEnvironment.augmentedPath`.
internal func augmentedPathWithHomebrew(inheriting inheritedPath: String?) -> String {
    SubprocessEnvironment.augmentedPath(inheriting: inheritedPath)
}
