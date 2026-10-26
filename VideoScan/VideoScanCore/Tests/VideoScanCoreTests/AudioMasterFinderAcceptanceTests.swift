// AudioMasterFinderAcceptanceTests.swift — media-matrix acceptance for
// Find Master by sound (design provenance_retroactive_2026_10_26 §Phase A).
//
// SYNTHETIC ONLY: 30 masters (60–900 s, seeded, `SyntheticSpeech` — the
// audio-fingerprint fixture renderer), 100 clips cut at seeded off-grid
// offsets, wrapped with a generated picture as mp4/h264+AAC (64k and 128k
// alternating), mov/prores+PCM, mkv/ffv1+PCM, mxf/mpeg2+PCM 48k and
// avi/dv+PCM 48k; plus 10 MUTED clips (a silent track) across the same five
// containers. Every clip goes through the real decoder (ffmpeg → 8 kHz) and
// the finder against an index of the 30 masters only.
//
// BARS (frozen with the design; never loosened to go green):
//   • recall ≥ 0.95 — the true master is found, as "inside", for sounded
//     clips ≥ 10 s (all of them here);
//   • zero false containers — no other master is ever called the clip's
//     container or the same recording;
//   • |offset error| ≤ 0.1 s wherever the true master is found;
//   • muted clips are REFUSED, never "none found".
// Numbers are printed per container and quality.
//
// Slow (≈ 4 h of audio rendered and printed, 110 ffmpeg encodes): tagged
// `.scale`, so the sensor lane skips it; the gauntlet runs it in Release.
// MEMORY: one master's PCM at a time (≤ 900 s × 8 kHz × 2 B ≈ 14 MB) plus
// 30 prints (≈ 2 MB each at most) and the index (≈ 70 MB, mostly offsets).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AudioMasterFinder acceptance (media matrix)", .tags(.scale), .serialized)
struct AudioMasterFinderAcceptanceTests {

    static let masterCount = 30, clipCount = 100, mutedCount = 10
    static let rate = 8_000

    enum Container: String, CaseIterable, Sendable { case mp4, mov, mkv, mxf, avi }

    struct Clip: Sendable {
        let index: Int
        let master: Int
        let offset: Double
        let seconds: Double
        let container: Container
        let quality: String      // "aac64k" | "aac128k" | "pcm" | "muted"
        var muted: Bool { quality == "muted" }
    }

    struct Outcome: Sendable {
        let clip: Clip
        let search: AudioMasterSearch?
        let decodeError: String?
    }

    static func masterKey(_ m: Int) -> AudioFingerprintStore.Key {
        AudioFingerprintStore.Key(contentDigest: "sha256:" + String(format: "%064x", 0xACC0_0000 + m), sizeBytes: Int64(m + 1))
    }

    @Test("30 masters × 100 clips × 5 containers: recall ≥ 0.95, no false container, offsets ≤ 0.1 s, muted refused")
    func mediaMatrix() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_findmaster_acceptance_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SplitMix64(seed: 0xF1_AD_3A57E5)

        // Masters: render, print, write WAV, drop the PCM.
        var lengths: [Double] = [], prints: [AudioFingerprint] = []
        for m in 0..<Self.masterCount {
            let seconds = (rng.range(60, 900)).rounded()
            let pcm = SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: seconds, seed: 0xACC0_0000 + UInt64(m), sampleRate: Self.rate))
            prints.append(AudioFingerprint.compute(AudioPCM(sampleRate: Self.rate, samples: pcm)))
            try WAVWriter.write(pcm, sampleRate: Self.rate, to: dir.appendingPathComponent("master\(m).wav"))
            lengths.append(seconds)
        }
        let rows = prints.enumerated().map { (Self.masterKey($0.offset), Result<AudioFingerprint, Error>.success($0.element)) }
        let (index, report) = try AudioCatalogIndex.build(rows: CatalogIndexFixtures.rows(rows), expectedRows: rows.count)
        #expect(report.indexed == Self.masterCount)
        let byKey = Dictionary(uniqueKeysWithValues: rows.compactMap { k, r in (try? r.get()).map { (k, $0) } })

        // Clips: seeded master, length 10–60 s, off-grid offset (0.1 s steps).
        var clips: [Clip] = []
        for i in 0..<(Self.clipCount + Self.mutedCount) {
            let m = Int(rng.next() % UInt64(Self.masterCount))
            let seconds = min((rng.range(10, 60) * 10).rounded() / 10, lengths[m] - 1)
            let offset = (rng.range(0, lengths[m] - seconds) * 10).rounded(.down) / 10
            let container = Container.allCases[i % Container.allCases.count]
            let quality = i >= Self.clipCount ? "muted" : container == .mp4 ? ((i / 5) % 2 == 0 ? "aac64k" : "aac128k") : "pcm"
            clips.append(Clip(index: i, master: m, offset: offset, seconds: seconds, container: container, quality: quality))
        }

        // Encode, decode, search — 8 at a time.
        let outcomes = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
            var out: [Outcome] = [], next = 0
            func add() {
                guard next < clips.count else { return }
                let clip = clips[next]; next += 1
                group.addTask { await Self.run(clip, dir: dir, index: index, prints: byKey) }
            }
            for _ in 0..<8 { add() }
            for await o in group { out.append(o); add() }
            return out.sorted { $0.clip.index < $1.clip.index }
        }

        // Score.
        var score = Score()
        for o in outcomes { score.add(o) }
        let recall = score.sounded > 0 ? Double(score.found) / Double(score.sounded) : 0
        print(String(format: "Find Master acceptance: recall %.3f (%d/%d sounded clips), max |offset error| %.3f s, false containers %d, muted refused %d/%d",
                     recall, score.found, score.sounded, score.maxOffsetError, score.falseContainers.count,
                     score.mutedRefused, Self.mutedCount))
        for (group, tally) in score.perGroup.sorted(by: { $0.key < $1.key }) {
            print("Find Master acceptance: \(group) \(tally.hit)/\(tally.of)")
        }
        for miss in score.misses { print("Find Master acceptance MISS: \(miss)") }
        for problem in score.problems { Issue.record(Comment(rawValue: problem)) }
        #expect(score.sounded == Self.clipCount)
        #expect(recall >= 0.95)
        #expect(score.falseContainers.isEmpty, "\(score.falseContainers)")
        #expect(score.maxOffsetError <= 0.1)
        #expect(score.mutedRefused == Self.mutedCount)
    }

    /// The bars' numbers, accumulated one outcome at a time.
    struct Score {
        var found = 0, sounded = 0, mutedRefused = 0, maxOffsetError = 0.0
        var falseContainers: [String] = [], misses: [String] = [], problems: [String] = []
        var perGroup: [String: (hit: Int, of: Int)] = [:]

        mutating func add(_ o: Outcome) {
            let c = o.clip
            if let error = o.decodeError { problems.append("clip \(c.index) \(c.container) \(c.quality): \(error)"); return }
            guard let search = o.search else { return }
            if c.muted {
                if case .refused = search { mutedRefused += 1 } else { problems.append("muted clip \(c.index) \(c.container) must be refused, got \(search)") }
                return
            }
            sounded += 1
            let group = "\(c.container.rawValue)/\(c.quality)"
            let hit = judge(c, search)
            if hit { found += 1 } else { misses.append("clip \(c.index) \(group) \(c.seconds) s at \(c.offset): \(search)") }
            perGroup[group, default: (0, 0)].of += 1
            if hit { perGroup[group, default: (0, 0)].hit += 1 }
        }

        /// True when the clip's own master is found as its container; any
        /// OTHER master called container or same recording is recorded.
        mutating func judge(_ c: Clip, _ search: AudioMasterSearch) -> Bool {
            guard case .found(let candidates, _, _) = search else { return false }
            var hit = false
            for candidate in candidates {
                let isTrue = candidate.key == AudioMasterFinderAcceptanceTests.masterKey(c.master)
                switch candidate.match.verdict {
                case .containedInMaster(let offset) where isTrue:
                    hit = true
                    maxOffsetError = max(maxOffsetError, abs(offset - c.offset))
                case .containedInMaster, .sameRecording:
                    if !isTrue { falseContainers.append("clip \(c.index) → master \(candidate.key.contentDigest.suffix(4))") }
                default: break
                }
            }
            return hit
        }
    }

    /// Encode one clip with ffmpeg, decode it through the real decoder, ask the finder.
    static func run(_ c: Clip, dir: URL, index: AudioCatalogIndex, prints: [AudioFingerprintStore.Key: AudioFingerprint]) async -> Outcome {
        let out = dir.appendingPathComponent("test_clip\(c.index).\(c.container.rawValue)")
        let master = dir.appendingPathComponent("master\(c.master).wav").path
        let size = c.container == .avi ? "720x480" : "64x64"
        let rateArg = c.container == .avi ? "30000/1001" : "25"
        var args = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=\(size):r=\(rateArg)"]
        args += c.muted ? ["-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono"] : ["-ss", String(format: "%.1f", c.offset), "-i", master]
        args += ["-map", "0:v", "-map", "1:a", "-t", String(format: "%.1f", c.seconds)]
        switch c.container {
        case .mp4: args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
            args += c.quality == "muted" ? ["-c:a", "aac", "-b:a", "64k"] : ["-c:a", "aac", "-b:a", c.quality == "aac64k" ? "64k" : "128k"]
        case .mov: args += ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le"]
        case .mkv: args += ["-c:v", "ffv1", "-c:a", "pcm_s16le"]
        case .mxf: args += ["-c:v", "mpeg2video", "-ar", "48000", "-c:a", "pcm_s16le"]
        case .avi: args += ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-ar", "48000", "-c:a", "pcm_s16le"]
        }
        args += ["-y", out.path]
        let encoded = await ProcessRunner.runProcess(executable: FFmpegLocator.ffmpegPath, arguments: args, deadlineSeconds: 180)
        guard encoded.exitCode == 0 else {
            return Outcome(clip: c, search: nil, decodeError: "ffmpeg exit \(encoded.exitCode): \(encoded.stderr.suffix(300))")
        }
        do {
            let pcm = try await AudioPCMDecoder().decode(path: out.path)
            let query = AudioFingerprint.compute(pcm)
            let key = AudioFingerprintStore.Key(contentDigest: "sha256:" + String(format: "%064x", 0xC11B_0000 + c.index), sizeBytes: 1)
            let search = AudioMasterFinder.find(query: query, queryKey: key, in: index, load: { prints[$0] })
            try? FileManager.default.removeItem(at: out)
            return Outcome(clip: c, search: search, decodeError: nil)
        } catch {
            return Outcome(clip: c, search: nil, decodeError: "\(error)")
        }
    }
}
