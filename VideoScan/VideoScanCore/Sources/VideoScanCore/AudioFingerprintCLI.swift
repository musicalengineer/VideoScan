// AudioFingerprintCLI.swift (VideoScanCore)
// ONE SENTENCE: the testable body of `videoscan-audio-match` — decode,
// fingerprint, match, print — so main.swift stays a three-line shim (the
// videoscan-preview-sweep pattern).
//
//   videoscan-audio-match fingerprint <file>
//       duration, landmark count, encoded bytes, timings
//   videoscan-audio-match match <query> <master>
//       verdict, offset, coverage, density, matched landmarks, timings
//
// READ-ONLY: every file goes through AudioPCMDecoder (ffmpeg reads it,
// writes to a pipe); nothing is written anywhere. Memory per run: the two
// PCM buffers (≈ 1 MB per minute of audio each) plus the fingerprints.
//
// (For Rick: `out` is an injected sink — a function pointer for stdout —
// so a test can capture the report without a pipe.)

import Foundation

public enum AudioFingerprintCLI {

    public static let usage = """
        usage: videoscan-audio-match fingerprint <file>
               videoscan-audio-match match <query> <master>
        Decodes through ffmpeg (VS_FFMPEG_PATH overrides), 8 kHz mono. Read-only.
        """

    /// Exit code: 0 ok, 2 usage, 3 decode failure.
    public static func run(_ arguments: [String], out: (String) -> Void = { print($0) }) async -> Int32 {
        switch arguments.first {
        case "fingerprint" where arguments.count == 2:
            return await fingerprint(path: arguments[1], out: out)
        case "match" where arguments.count == 3:
            return await match(query: arguments[1], master: arguments[2], out: out)
        default:
            out(usage)
            return 2
        }
    }

    struct Timed {
        let pcm: AudioPCM
        let fingerprint: AudioFingerprint
        let decodeSeconds: Double
        let fingerprintSeconds: Double
    }

    private static func load(_ path: String, out: (String) -> Void) async -> Timed? {
        let clock = ContinuousClock()
        let start = clock.now
        let pcm: AudioPCM
        do {
            pcm = try await AudioPCMDecoder().decode(path: path)
        } catch {
            out("\(name(path)): \(error)")
            return nil
        }
        let decoded = clock.now
        let fingerprint = AudioFingerprint.compute(pcm)
        let done = clock.now
        return Timed(pcm: pcm, fingerprint: fingerprint,
                     decodeSeconds: seconds(decoded - start), fingerprintSeconds: seconds(done - decoded))
    }

    private static func fingerprint(path: String, out: (String) -> Void) async -> Int32 {
        guard let t = await load(path, out: out) else { return 3 }
        let f = t.fingerprint
        out(String(format: "%@: %.1f s, %d landmarks (%.1f/s), %d bytes; decode %.2f s, fingerprint %.2f s",
                   name(path), f.durationSeconds, f.landmarkCount,
                   f.durationSeconds > 0 ? Double(f.landmarkCount) / f.durationSeconds : 0,
                   f.estimatedBytes, t.decodeSeconds, t.fingerprintSeconds))
        return 0
    }

    private static func match(query: String, master: String, out: (String) -> Void) async -> Int32 {
        guard let q = await load(query, out: out), let m = await load(master, out: out) else { return 3 }
        let clock = ContinuousClock()
        let start = clock.now
        let index = AudioFingerprintIndex(master: m.fingerprint)
        let indexed = clock.now
        let result = index.match(q.fingerprint)
        let matched = clock.now
        out(report(query: query, master: master, q: q, m: m, result: result,
                   indexSeconds: seconds(indexed - start), matchSeconds: seconds(matched - indexed)))
        return 0
    }

    static func report(query: String, master: String, q: Timed, m: Timed, result: AudioMatch,
                       indexSeconds: Double, matchSeconds: Double) -> String {
        var lines: [String] = []
        lines.append(String(format: "query  %@: %.1f s, %d landmarks (decode %.2f s, fingerprint %.2f s)",
                            name(query), q.fingerprint.durationSeconds, q.fingerprint.landmarkCount,
                            q.decodeSeconds, q.fingerprintSeconds))
        lines.append(String(format: "master %@: %.1f s, %d landmarks (decode %.2f s, fingerprint %.2f s)",
                            name(master), m.fingerprint.durationSeconds, m.fingerprint.landmarkCount,
                            m.decodeSeconds, m.fingerprintSeconds))
        lines.append("verdict   \(describe(result.verdict))")
        lines.append(String(format: "offset    %.3f s (query start in master)", result.offsetSeconds))
        lines.append(String(format: "matched   %d of %d query landmarks (density %.3f)",
                            result.matchedLandmarks, result.queryLandmarks, result.density))
        lines.append(String(format: "coverage  %.2f of the overlap (%.1f s); longest run %.0f s at %.1f–%.1f s of master",
                            result.coverage, result.evidence.overlapSeconds, result.spanSeconds,
                            result.spanStartInMasterSeconds, result.spanEndInMasterSeconds))
        lines.append(String(format: "timing    index %.3f s, match %.3f s", indexSeconds, matchSeconds))
        return lines.joined(separator: "\n")
    }

    static func describe(_ verdict: AudioMatchVerdict) -> String {
        switch verdict {
        case .sameRecording: return "SAME RECORDING"
        case .containedInMaster(let o): return String(format: "CLIP OF MASTER (starts at %.1f s)", o)
        case .masterContainedInQuery(let o): return String(format: "MASTER IS A CLIP OF QUERY (starts at %.1f s)", o)
        case .overlap(let o, let s): return String(format: "OVERLAP %.0f s (query starts at %.1f s in master)", s, o)
        case .different: return "DIFFERENT"
        }
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func seconds(_ d: Duration) -> Double { TimingBudget.seconds(d) }
}
