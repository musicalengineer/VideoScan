// ProbeFixtures.swift — recorded ffprobe JSON for the five media-matrix
// containers, so a mocked ffprobe answers with what the REAL tool says
// (Rick 2026-11-20: mocks must stay honest).
//
// The files under Fixtures/ffprobe/ were captured from Homebrew ffprobe on
// two-second synthetic test patterns (lavfi testsrc + sine; no family
// media), with the arguments the scan uses (ScanEngine.runFFProbe):
//   -v warning -probesize 50M -analyzeduration 10M -print_format json
//   -show_format -show_streams <file>
// `format.filename` is replaced by `<fixture>/<name>` so the checked-in text
// carries no machine path.
//
// ProbeFixtureDriftTests (integration stage, needs ffmpeg) re-makes the
// media, re-probes it and fails when the normalized JSON differs — a
// Homebrew upgrade that changes what ffprobe reports turns red there, not
// silently inside every mocked test. To refresh after a reviewed change:
//   python3 - <<'PY'  (env VS_REGENERATE_PROBE_FIXTURES=1, then swift test
//   --filter ProbeFixtureDriftTests) — see the drift test's header.

import Foundation
@testable import VideoScanCore

enum ProbeFixtures {
    /// The media matrix (CLAUDE.md rule 8): name → ffmpeg arguments that make it.
    static let matrix: [(name: String, args: [String])] = {
        let src = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
                   "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000"]
        return [
            ("h264.mp4", src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("prores.mov", src + ["-c:v", "prores_ks", "-c:a", "pcm_s16le"]),
            ("ffv1.mkv", src + ["-c:v", "ffv1", "-c:a", "pcm_s16le"]),
            ("mpeg2.mxf", ["-f", "lavfi", "-i", "testsrc=size=720x576:rate=25:duration=2",
                           "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
                           "-c:v", "mpeg2video", "-b:v", "8M", "-c:a", "pcm_s16le"]),
            ("dv.avi", ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001:duration=2",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
                        "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"]),
        ]
    }()

    /// The scan's probe arguments for `path`.
    static func probeArguments(_ path: String) -> [String] {
        ["-v", "warning", "-probesize", "50M", "-analyzeduration", "10M",
         "-print_format", "json", "-show_format", "-show_streams", path]
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ffprobe", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }

    /// The recorded ffprobe stdout for one matrix file.
    static func json(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    /// ffprobe's JSON with the machine- and version-specific fields removed:
    /// the file's path, and any `encoder` tag (it names the libavformat
    /// version that wrote the file, not a property of the media).
    static func normalized(_ json: String) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return strip(object) as? NSDictionary ?? [:]
    }

    private static func strip(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, v) in dict where key != "filename" && key.lowercased() != "encoder" {
                out[key] = strip(v)
            }
            return out
        }
        if let array = value as? [Any] { return array.map(strip) }
        return value
    }

    /// Replace the probed path with the stable placeholder.
    static func anonymized(_ json: String, path: String, name: String) -> String {
        json.replacingOccurrences(of: path, with: "<fixture>/\(name)")
    }
}
