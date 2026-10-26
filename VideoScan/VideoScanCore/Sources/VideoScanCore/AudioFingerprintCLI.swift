// AudioFingerprintCLI.swift (VideoScanCore)
// ONE SENTENCE: the testable body of `videoscan-audio-match` — decode,
// fingerprint, match, print — so main.swift stays a three-line shim (the
// videoscan-preview-sweep pattern).
//
//   videoscan-audio-match fingerprint <file>
//       duration, landmark count, encoded bytes, timings
//   videoscan-audio-match match <query> <master>
//       verdict, offset, coverage, density, matched landmarks, timings
//   videoscan-audio-match find <file | sha256:<hex>:<size>> --sidecar <dir>
//       builds the catalog-wide sound index from the sidecar, asks
//       AudioMasterFinder, prints the build report and the ranked answers
//       (provenance_retroactive_2026_10_26 §Phase A). Opens the sidecar only
//       if it exists; reads it; writes nothing. Memory: the index (≈ 268 MB
//       for today's 25 M landmarks; the build refuses past ≈ 867 MB).
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
               videoscan-audio-match find <file | sha256:<hex>:<size>> --sidecar <dir>
        Decodes through ffmpeg (VS_FFMPEG_PATH overrides), 8 kHz mono. Read-only.
        """

    /// Exit code: 0 ok, 2 usage, 3 decode failure, 4 sidecar/index refusal.
    public static func run(_ arguments: [String], out: (String) -> Void = { print($0) }) async -> Int32 {
        switch arguments.first {
        case "fingerprint" where arguments.count == 2:
            return await fingerprint(path: arguments[1], out: out)
        case "match" where arguments.count == 3:
            return await match(query: arguments[1], master: arguments[2], out: out)
        case "find" where arguments.count == 4 && arguments[2] == "--sidecar":
            return await find(target: arguments[1], sidecar: URL(fileURLWithPath: arguments[3]), out: out)
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

    // MARK: find

    /// "sha256:<hex>:<size>" → a sidecar key; nil for anything else (a path).
    static func parseKey(_ text: String) -> AudioFingerprintStore.Key? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, parts[0] == "sha256", parts[1].count == 64,
              parts[1].allSatisfy(\.isHexDigit), let size = Int64(parts[2]), size > 0 else { return nil }
        return AudioFingerprintStore.Key(contentDigest: "sha256:" + parts[1].lowercased(), sizeBytes: size)
    }

    private static func find(target: String, sidecar: URL, out: (String) -> Void) async -> Int32 {
        let store: AudioFingerprintStore
        do { store = try AudioCatalogIndex.openSidecar(directory: sidecar) } catch {
            out("refused: \(error)")
            return 4
        }
        let query: AudioFingerprint
        let queryKey: AudioFingerprintStore.Key
        if let key = parseKey(target) {
            let print: AudioFingerprint?
            do { print = try store.decodedFingerprint(for: key) } catch {
                out("refused: the sound print for \(key.contentDigest.prefix(19))… could not be read: \(error)")
                return 4
            }
            guard let print else {
                out("refused: no sound print in the sidecar for \(key.contentDigest.prefix(19))… (\(key.sizeBytes) bytes)")
                return 4
            }
            (query, queryKey) = (print, key)
        } else {
            guard let t = await load(target, out: out) else { return 3 }
            // A file given by path is not hashed here: its key is a
            // placeholder that matches no row, so nothing is excluded.
            (query, queryKey) = (t.fingerprint, AudioFingerprintStore.Key(contentDigest: "file:" + target, sizeBytes: 0))
        }
        let clock = ContinuousClock()
        let before = residentMB()
        let start = clock.now
        let built: (AudioCatalogIndex, AudioCatalogIndex.BuildReport)
        do { built = try AudioCatalogIndex.build(store: store) } catch {
            out("refused: \(error)")
            return 4
        }
        let indexed = clock.now
        let search = AudioMasterFinder.find(query: query, queryKey: queryKey, in: built.0,
                                            load: { try store.decodedFingerprint(for: $0) })
        let searchedAt = clock.now
        out(findReport(index: built.0, report: built.1, search: search, buildSeconds: seconds(indexed - start),
                       searchSeconds: seconds(searchedAt - indexed), residentGrowthMB: residentMB() - before))
        return 0
    }

    static func findReport(index: AudioCatalogIndex, report r: AudioCatalogIndex.BuildReport, search: AudioMasterSearch,
                           buildSeconds: Double, searchSeconds: Double, residentGrowthMB: Double) -> String {
        var lines: [String] = []
        lines.append(String(format: "index     %d contents, %d landmarks, %.2f s, ≈ %d MB (resident +%.0f MB)",
                            r.indexed, r.landmarks, buildSeconds,
                            AudioCatalogIndex.megabytes(forPostings: index.postingCount), residentGrowthMB))
        lines.append("skipped   \(r.notWholeFileKey) sampled-hash keys, \(r.otherRecipe) older recipe, \(r.tooFewLandmarks) too little sound, \(r.unreadable) unreadable (of \(r.rowsRead) rows)")
        switch search {
        case .refused(.otherRecipe(let q, let i)):
            lines.append(String(format: "refused   the query's print is from another recipe (0x%08x; the index is 0x%08x)", q, i))
        case .refused(.tooLittleSound(let n)):
            lines.append("refused   too little sound to match (\(n) landmarks; \(AudioMatchPolicy.default.minMatchedLandmarks) needed)")
        case .noneFound(let searched, let unreadable):
            lines.append(unreadable.isEmpty
                ? "none      no content shares its sound (searched \(searched) sounded contents)"
                : "none      no READABLE content shares its sound (searched \(searched) sounded contents) — \(unreadable.count) candidate(s) could not be read, so this is not a negative")
            lines += unreadableLines(unreadable)
        case .found(let found, let searched, let unreadable):
            lines.append("found     \(found.count) of \(searched) sounded contents")
            for c in found {
                lines.append(String(format: "  %@…  %@  coverage %.2f, %d landmarks, span %.1f–%.1f s of the other",
                                    String(c.key.contentDigest.prefix(19)), describe(c.match.verdict), c.match.coverage,
                                    c.match.matchedLandmarks, c.match.spanStartInMasterSeconds, c.match.spanEndInMasterSeconds))
            }
            lines += unreadableLines(unreadable)
        }
        lines.append(String(format: "timing    build %.2f s, search %.3f s", buildSeconds, searchSeconds))
        return lines.joined(separator: "\n")
    }

    static func unreadableLines(_ unreadable: [AudioMasterUnreadable]) -> [String] {
        unreadable.map { "  unreadable \($0.key.contentDigest.prefix(19))…  \($0.reason)" }
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
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
        lines.append(String(format: "coverage  %.2f of the audible overlap (%.1f s); longest run %.0f s at %.1f–%.1f s of master; longest unmatched audible gap %.0f s",
                            result.coverage, result.evidence.overlapSeconds, result.spanSeconds,
                            result.spanStartInMasterSeconds, result.spanEndInMasterSeconds,
                            result.evidence.unmatchedGapSeconds))
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
        case .inconclusive(let reason): return "INCONCLUSIVE (\(reason))"
        }
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func seconds(_ d: Duration) -> Double { TimingBudget.seconds(d) }
}
