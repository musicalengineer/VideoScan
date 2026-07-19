//
//  GauntletFixtures.swift
//  VideoScanUITests — Gauntlet v1
//
//  Runner-side fixture synthesis. The INVOCATIONS are planned by the
//  pure GauntletFixturePlan (VideoScanCore — unit-tested there); this
//  file only locates ffmpeg, spawns it, and verifies a file landed.
//  The UI-test runner process is unsandboxed, so Process is fine here —
//  the app under test never generates fixtures.
//
//  Conventions follow BalanceAudioTestSupport: temp-dir output, `test_`
//  filename prefixes (enforced by the plan), throws with a stderr tail
//  on failure.
//

import Foundation
import VideoScanCore

enum GauntletFixtures {

    // MARK: ffmpeg

    /// The UI bundle can't reach the app's ToolLocator, so resolve the
    /// Homebrew install directly. VS_GAUNTLET_FFMPEG overrides for
    /// nonstandard installs.
    static var ffmpegPath: String? {
        if let override = ProcessInfo.processInfo.environment["VS_GAUNTLET_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return [
            "/opt/homebrew/bin/ffmpeg",   // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg"       // Intel Homebrew
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var toolsAvailable: Bool { ffmpegPath != nil }

    // MARK: Reference photo

    /// A known-good face photo for flow 1. The repo's fixture photo is
    /// resolved via #filePath (works on any machine that built the test
    /// bundle from a checkout — the M1 runner syncs via git, per the
    /// MBP-runner convention). VS_GAUNTLET_PHOTO overrides.
    static func referencePhoto() -> URL? {
        if let override = ProcessInfo.processInfo.environment["VS_GAUNTLET_PHOTO"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        // …/VideoScan/VideoScanUITests/Gauntlet/GauntletFixtures.swift
        // → repo root is four levels up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Gauntlet/
            .deletingLastPathComponent()   // VideoScanUITests/
            .deletingLastPathComponent()   // VideoScan/ (project dir)
            .deletingLastPathComponent()   // repo root
        let candidate = repoRoot
            .appendingPathComponent("tests/fixtures/photos/DonnaFaceDetectionTest.png")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: Rendering

    /// Render one planned invocation into `dir`. Returns the output URL.
    @discardableResult
    static func render(_ invocation: GauntletFixturePlan.Invocation,
                       into dir: URL) throws -> URL {
        guard let ffmpeg = ffmpegPath else {
            throw FixtureError.ffmpegMissing
        }
        let out = dir.appendingPathComponent(invocation.outputFilename)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-hide_banner", "-loglevel", "error"]
            + invocation.arguments + [out.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else {
            let err = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            throw FixtureError.ffmpegFailed(status: proc.terminationStatus,
                                            stderr: String(err.suffix(400)))
        }
        return out
    }

    enum FixtureError: Error, CustomStringConvertible {
        case ffmpegMissing
        case ffmpegFailed(status: Int32, stderr: String)
        var description: String {
            switch self {
            case .ffmpegMissing:
                return "ffmpeg not found (checked Homebrew paths; set VS_GAUNTLET_FFMPEG)"
            case .ffmpegFailed(let s, let e):
                return "ffmpeg failed (\(s)): \(e)"
            }
        }
    }
}
