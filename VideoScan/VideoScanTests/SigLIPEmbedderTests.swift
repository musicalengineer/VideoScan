// SigLIPEmbedderTests.swift — the Frames mode's REAL model (SigLIP 2, native MLX):
// parity with the reference implementation and one end-to-end smoke.
// Split from FrameSearchTests.swift on 2026-11-10 with no change to the tests.
//
// Why its own file: both tests need the public weights in ~/.cache/huggingface
// and are SKIPPED (counted as such) without them. The Release gauntlet gives
// the test host a sandboxed HOME, the weights are not there, the suite skips,
// and the gauntlet fails a stage on ANY skipped test — it was RED for four
// days (11/06 … 11/09) for these two skips alone, with nothing saying which
// tests. The gauntlet's manifest lists a FILE as not runnable in the sandbox,
// so the suite needs a file of its own (scripts/gauntlet/manifest.json).
// They run in the nightly all-tests pass on both Macs, where the weights are.
//
//   PARITY     the native MLX SigLIP 2 matches the reference implementation
//              (transformers' SiglipModel, fp32) on synthetic cards: the
//              same token ids, cosine ≥ 0.99 per vector.
//   SMOKE      three synthetic clips (ffmpeg lavfi: solid red, solid blue,
//              a white card with black text) through the job's one engine
//              (the captioner's frame door + SigLIP 2): "a red image" ranks
//              the red clip first. Skipped without ffmpeg.
// Synthetic pictures only.

import AppKit
import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private struct Reference: Decodable {
    struct Text: Decodable { let text: String; let ids: [Int]; let vector: [Float] }
    struct Card: Decodable { let card: String; let vector: [Float] }
    let model: String
    let texts: [Text]
    let images: [Card]

    static func load() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/siglip2_reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    let na = a.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot(), nb = b.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return dot / (na * nb)
}

private enum SigLIPTestEnv {
    static let weights = SigLIPConfig.hubCacheSnapshot() != nil
    static let ffmpeg = FileManager.default.isExecutableFile(atPath: ToolLocator.ffmpegPath)

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framesearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("SigLIP 2 — native MLX parity and smoke", .serialized, .enabled(if: SigLIPTestEnv.weights, "SigLIP 2 weights are not in ~/.cache/huggingface"))
struct SigLIPEmbedderTests {

    @Test func tokensAndVectorsMatchTheReferenceImplementation() async throws {
        let ref = try Reference.load()
        let embedder = SigLIPEmbedder.shared
        #expect(ref.model == embedder.modelID)
        for t in ref.texts {
            let ids = try await embedder.tokenIDs(t.text)
            #expect(ids == t.ids, "Gemma tokenizer ids for \"\(t.text)\"")
            let v = try await embedder.embed(text: t.text)
            #expect(v.count == 768)
            let c = cosine(v, t.vector)
            #expect(c >= 0.99, "text \"\(t.text)\": cosine \(c) with the reference")
        }
        let cards = ["red": FrameSearchTestCards.solid(255, 0, 0), "gradient_g_x_b_y": FrameSearchTestCards.gradient()]
        for card in ref.images {
            let image = try #require(cards[card.card])
            let v = try #require(try await embedder.embed(images: [image]).first)
            let c = cosine(v, card.vector)
            #expect(c >= 0.99, "image \(card.card): cosine \(c) with the reference")
        }
    }

    @Test(.enabled(if: SigLIPTestEnv.ffmpeg, "ffmpeg is not installed"))
    func aRedImageRanksTheRedClipFirst() async throws {
        let dir = try SigLIPTestEnv.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clips: [(String, String)] = [("red.mp4", "color=c=red:s=320x240:d=2"),
                                         ("blue.mp4", "color=c=blue:s=320x240:d=2"),
                                         ("card.mp4", "color=c=white:s=320x240:d=2,drawtext=text='HELLO':fontsize=60:fontcolor=black:x=40:y=90")]
        var b = FrameIndexBuilder(model: SigLIPConfig.modelID, dims: SigLIPConfig.dims)
        var digests: [String: String] = [:]
        for (n, (name, source)) in clips.enumerated() {
            let path = dir.appendingPathComponent(name).path
            var made = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath,
                                                      arguments: ["-v", "error", "-f", "lavfi", "-i", source, "-pix_fmt", "yuv420p", "-y", path], deadlineSeconds: 60)
            if made.exitCode != 0, source.contains("drawtext") {
                // An ffmpeg without libfreetype: a grey card stands in for the text card.
                made = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath,
                                                      arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=320x240:d=2", "-pix_fmt", "yuv420p", "-y", path],
                                                      deadlineSeconds: 60)
            }
            try #require(made.exitCode == 0, "ffmpeg made \(name): \(made.stderr)")
            let digest = String(format: "%064x", n + 1)
            digests[digest] = name
            let frames = try await FrameIndexEngine.frames(path: path, durationSeconds: 2, framesPerFile: 2,
                                                           extract: FrameIndexEngine.productionExtract, embedder: SigLIPEmbedder.shared)
            #expect(frames.count == 2)
            b.add(digest: digest, frames: frames)
        }
        let query = try await SigLIPEmbedder.shared.embed(text: "a red image")
        let hits = FrameSearch.topK(query: query, in: b.snapshot(), k: 6, perContent: 1)
        #expect(hits.map { digests[$0.entry.digest] ?? "?" }.first == "red.mp4", "ranking: \(hits.map { "\(digests[$0.entry.digest] ?? "?") \($0.score)" })")
        let blue = FrameSearch.topK(query: try await SigLIPEmbedder.shared.embed(text: "a blue image"), in: b.snapshot(), k: 1)
        #expect(blue.first.map { digests[$0.entry.digest] } == "blue.mp4")
    }
}
