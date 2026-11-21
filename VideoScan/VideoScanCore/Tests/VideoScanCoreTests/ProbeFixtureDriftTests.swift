// ProbeFixtureDriftTests.swift — the recorded ffprobe fixtures
// (ProbeFixtures.swift) against the REAL tool: re-make the five synthetic
// media-matrix files, probe them with Homebrew ffprobe, and fail if the
// normalized JSON is not the checked-in fixture — so mocks built on the
// fixtures stay honest across Homebrew upgrades. Integration stage (needs
// ffmpeg; ~0.4 s).
//
// Refresh (only after reading the diff): run this suite with
// VS_REGENERATE_PROBE_FIXTURES=1 in the test environment; it rewrites
// Fixtures/ffprobe/*.json and ffprobe-version.txt, and still fails so a
// refresh is never silent — commit the new files, run it again.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ffprobe fixtures — drift against the real ffprobe")
struct ProbeFixtureDriftTests {

    static var regenerate: Bool { ProcessInfo.processInfo.environment["VS_REGENERATE_PROBE_FIXTURES"] == "1" }

    @Test("the real ffprobe still says what the checked-in fixtures say (all five containers)", .timeLimit(.minutes(2)))
    func fixturesMatchTheRealTool() async throws {
        try #require(FFmpegLocator.ffmpegIsAvailable(), "ffmpeg/ffprobe are required (Brewfile)")
        let ffmpeg = FFmpegLocator.ffmpegPath, ffprobe = FFmpegLocator.ffprobePath
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-probe-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let version = (await ProcessRunner.run(executable: ffprobe, arguments: ["-version"]))?
            .split(separator: "\n").first.map(String.init) ?? "unknown"

        for (name, args) in ProbeFixtures.matrix {
            let media = dir.appendingPathComponent(name)
            let made = await ProcessRunner.runProcess(
                executable: ffmpeg, arguments: ["-nostdin", "-y", "-loglevel", "error"] + args + ["-bitexact", "-shortest", media.path],
                deadlineSeconds: 60)
            try #require(made.exitCode == 0, "making \(name): \(made.stderr)")
            let probed = await ProcessRunner.runProcess(executable: ffprobe, arguments: ProbeFixtures.probeArguments(media.path),
                                                        deadlineSeconds: 60)
            try #require(probed.exitCode == 0, "probing \(name): \(probed.stderr)")
            let fresh = ProbeFixtures.anonymized(try #require(probed.stdout), path: media.path, name: name)
            if Self.regenerate {
                try fresh.write(to: ProbeFixtures.url(name), atomically: true, encoding: .utf8)
                continue
            }
            let recorded = try ProbeFixtures.json(name)
            #expect(try ProbeFixtures.normalized(fresh) == ProbeFixtures.normalized(recorded),
                    "\(name): the real ffprobe (\(version)) no longer matches Fixtures/ffprobe/\(name).json — mocks built on it would lie. Read the diff, then refresh (see header).\nfresh:\n\(fresh)")
        }
        if Self.regenerate {
            try (version + "\n").write(to: ProbeFixtures.directory.appendingPathComponent("ffprobe-version.txt"),
                                       atomically: true, encoding: .utf8)
            Issue.record("fixtures regenerated with \(version) — review and commit them, then run again without VS_REGENERATE_PROBE_FIXTURES")
        }
    }
}
