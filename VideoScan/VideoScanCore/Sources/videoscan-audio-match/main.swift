// videoscan-audio-match — demo CLI for the audio-fingerprint engine
// (2026-10-14). Read-only: decodes through ffmpeg to a pipe, prints a
// report, writes nothing. All logic lives in VideoScanCore's
// AudioFingerprintCLI so it is testable without spawning a process.

import Foundation
import VideoScanCore

exit(await AudioFingerprintCLI.run(Array(CommandLine.arguments.dropFirst())))
