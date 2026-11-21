// ProbeFixtureTests.swift — the recorded ffprobe fixtures (ProbeFixtures.swift).
//
//   ProbeFixtureMatrixTests (unit, no ffmpeg): each fixture, fed through a
//     mocked ffprobe, decodes into the scan's FFProbeOutput with the codecs
//     the matrix promises — the five containers reach a probe consumer
//     without a single real launch.
//   ProbeFixtureDriftTests (ProbeFixtureDriftTests.swift, integration stage).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ffprobe fixtures — the media matrix through a mocked ffprobe")
struct ProbeFixtureMatrixTests {

    static let expected: [String: (format: String, video: String, audio: String)] = [
        "h264.mp4": ("mov,mp4,m4a,3gp,3g2,mj2", "h264", "aac"),
        "prores.mov": ("mov,mp4,m4a,3gp,3g2,mj2", "prores", "pcm_s16le"),
        "ffv1.mkv": ("matroska,webm", "ffv1", "pcm_s16le"),
        "mpeg2.mxf": ("mxf", "mpeg2video", "pcm_s16le"),
        "dv.avi": ("avi", "dvvideo", "pcm_s16le"),
    ]

    @Test("every matrix fixture decodes through a mocked ffprobe into the codecs it was made with", arguments: ProbeFixtures.matrix.map(\.name))
    func fixtureDecodes(name: String) async throws {
        let json = try ProbeFixtures.json(name)
        let mock = ScriptedExecutor().on("ffprobe", containing: [name], .output(stdout: json))
        let stdout = await mock.scoped {
            await ProcessRunner.run(executable: "/opt/homebrew/bin/ffprobe", arguments: ProbeFixtures.probeArguments("/v/\(name)"))
        }
        let probe = try JSONDecoder().decode(FFProbeOutput.self, from: Data(try #require(stdout).utf8))
        let want = try #require(Self.expected[name])
        #expect(probe.format?.format_name == want.format)
        #expect(probe.streams?.first { $0.codec_type == "video" }?.codec_name == want.video)
        #expect(probe.streams?.first { $0.codec_type == "audio" }?.codec_name == want.audio)
        let seconds = Double(probe.format?.duration ?? "") ?? 0
        #expect(abs(seconds - 2) < 0.2, "\(name): \(seconds) s")
        #expect(mock.calls.count == 1)
    }

    @Test("the fixtures carry no machine path")
    func fixturesAreAnonymized() throws {
        for (name, _) in ProbeFixtures.matrix {
            let json = try ProbeFixtures.json(name)
            #expect(json.contains("<fixture>/\(name)"), "\(name)")
            #expect(!json.contains("/Users/") && !json.contains("/var/folders/") && !json.contains("/private/"), "\(name)")
        }
    }
}
