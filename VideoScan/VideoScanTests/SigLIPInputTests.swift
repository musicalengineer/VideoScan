// SigLIPInputTests.swift — what goes INTO SigLIP 2, and where its weights are
// looked for (Observations/FrameSearch/SigLIPEmbedder.swift). No model and no
// weights are needed, so this runs in every lane (the real-model parity suite,
// SigLIPEmbedderTests, needs ~1.5 GB in ~/.cache and is skipped without it).
//
//   TRUTH      a frame becomes 224 × 224 RGB in [-1, 1], top row first, red
//              first — the layout the image tower was trained on; a frame of
//              any shape is squashed to the square, never cropped.
//   LOGIC      token ids are padded or cut to exactly 64 (the text tower pools
//              the LAST position, so the padding is part of the input).
//   ISOLATION  a hub snapshot is used only when all three files are there —
//              a half-downloaded one is passed over, never loaded.
//   WORDS      each model error says what happened (the job's FAILED line and
//              the window show these as they are).
// Synthetic cards only; the "home" folder is a temp folder.

import CoreGraphics
import Foundation
import Testing
@testable import VideoScan

@Suite("SigLIP 2 — pixels, padding and the weights folder (no model needed)")
struct SigLIPInputTests {

    @Test func aFrameBecomesASquareOfRGBInMinusOneToOneTopRowFirst() throws {
        let red = try #require(SigLIPPixels.normalizedHWC(FrameSearchTestCards.solid(255, 0, 0)))
        #expect(red.count == 224 * 224 * 3)
        #expect(stride(from: 0, to: red.count, by: 3).allSatisfy { red[$0] == 1 && red[$0 + 1] == -1 && red[$0 + 2] == -1 }, "red is (1, −1, −1) at every pixel")

        let grey = try #require(SigLIPPixels.normalizedHWC(FrameSearchTestCards.solid(128, 128, 128), size: 8))
        #expect(grey.count == 8 * 8 * 3 && grey.allSatisfy { abs($0 - (128 / 127.5 - 1)) < 0.02 }, "(x / 255 − 0.5) / 0.5")

        // The reference gradient: green = x, blue = y. Row 0 of the output is the TOP row of the frame.
        let px = try #require(SigLIPPixels.normalizedHWC(FrameSearchTestCards.gradient()))
        func at(_ x: Int, _ y: Int) -> (r: Float, g: Float, b: Float) {
            let i = (y * 224 + x) * 3
            return (px[i], px[i + 1], px[i + 2])
        }
        for (x, y) in [(0, 0), (200, 0), (0, 200), (100, 50), (223, 223)] {
            let p = at(x, y)
            #expect(abs(p.r + 1) < 0.02 && abs(p.g - (Float(x) / 127.5 - 1)) < 0.02 && abs(p.b - (Float(y) / 127.5 - 1)) < 0.02,
                    "pixel (\(x), \(y)) reads \(p): a flipped or transposed frame would embed as a different picture")
        }
    }

    @Test func aFrameOfAnyShapeIsSquashedToTheSquareNotCropped() throws {
        // 400 × 100, four bands: green at the far left (50 px), red, blue, white at the far right (50 px).
        // A centre crop to a square keeps only the middle 100 px (red | blue) and loses BOTH outer bands — so the
        // outer bands landing in the outer columns is what tells squash from crop (Codex #302 finding 8: the old
        // red | blue card read the same either way).
        let ctx = try #require(CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bands: [(x: Int, width: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [(0, 50, 0, 1, 0), (50, 150, 1, 0, 0), (200, 150, 0, 0, 1), (350, 50, 1, 1, 1)]
        for band in bands {
            ctx.setFillColor(CGColor(srgbRed: band.r, green: band.g, blue: band.b, alpha: 1))
            ctx.fill(CGRect(x: band.x, y: 0, width: band.width, height: 100))
        }
        let frame = try #require(ctx.makeImage())
        let px = try #require(SigLIPPixels.normalizedHWC(frame, size: 16))
        #expect(px.count == 16 * 16 * 3)
        func colour(column: Int) -> String {
            let i = (8 * 16 + column) * 3
            let on = (px[i] > 0.8, px[i + 1] > 0.8, px[i + 2] > 0.8)
            switch on {
            case (false, true, false): return "green"
            case (true, false, false): return "red"
            case (false, false, true): return "blue"
            case (true, true, true): return "white"
            default: return "mixed"
            }
        }
        // 400 → 16 columns: 25 px each. Green fills columns 0–1, red 2–7, blue 8–13, white 14–15.
        #expect(colour(column: 0) == "green" && colour(column: 15) == "white", "the frame's outer edges are the square's outer columns: \(colour(column: 0)), \(colour(column: 15))")
        #expect(colour(column: 4) == "red" && colour(column: 11) == "blue", "and the middle keeps its order")
        #expect(!(0..<16).map(colour).contains("mixed") || (0..<16).map(colour).filter { $0 == "mixed" }.count <= 3, "four clean bands (a band edge may blend): \((0..<16).map(colour))")
    }

    @Test func tokenIdsArePaddedOrCutToExactlySixtyFour() {
        #expect(SigLIPPixels.padded([5, 6, 7]) == [5, 6, 7] + [Int](repeating: 0, count: 61))
        #expect(SigLIPPixels.padded([]) == [Int](repeating: 0, count: 64), "empty words are still 64 positions")
        #expect(SigLIPPixels.padded(Array(1...64)) == Array(1...64))
        #expect(SigLIPPixels.padded(Array(1...200)) == Array(1...64), "a long caption is cut, never wrapped")
        #expect(SigLIPPixels.padded([9], to: 4, pad: 1) == [9, 1, 1, 1])
        #expect(SigLIPConfig.maxTokens == 64 && SigLIPConfig.padToken == 0 && SigLIPConfig.dims == 768 && SigLIPConfig.imageSize == 224)
        #expect(SigLIPConfig.modelID == "google/siglip2-base-patch16-224", "the index folder and every hit's source words carry this id")
    }

    @Test func aHubSnapshotIsUsedOnlyWhenItIsComplete() throws {
        let home = try ObsFixture.tempDir("siglip-home")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(SigLIPConfig.hubCacheSnapshot(home: home) == nil, "no cache at all")

        let snapshots = home.appendingPathComponent(".cache/huggingface/hub/models--google--siglip2-base-patch16-224/snapshots", isDirectory: true)
        func snapshot(_ rev: String, _ files: [String]) throws {
            let dir = snapshots.appendingPathComponent(rev, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in files { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        }
        try snapshot("aaa", ["model.safetensors", "tokenizer_config.json"])            // the tokenizer never arrived
        #expect(SigLIPConfig.hubCacheSnapshot(home: home) == nil, "a half-downloaded snapshot is not weights")
        try snapshot("ccc", ["model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        #expect(SigLIPConfig.hubCacheSnapshot(home: home)?.lastPathComponent == "ccc", "the incomplete one is passed over")
        try snapshot("bbb", ["model.safetensors", "tokenizer.json", "tokenizer_config.json", "config.json"])
        #expect(SigLIPConfig.hubCacheSnapshot(home: home)?.lastPathComponent == "bbb", "of several complete ones, the same one every time (by name)")
    }

    @Test func everyModelErrorSaysWhatHappened() {
        #expect(SigLIPError.weightsMissing("no network").localizedDescription == "SigLIP 2 weights are not on this Mac (no network)")
        #expect(SigLIPError.loadFailed("a tensor is missing").localizedDescription == "SigLIP 2 could not be loaded: a tensor is missing")
        #expect(SigLIPError.badImage.localizedDescription == "a frame could not be converted to pixels")
        #expect(SigLIPError.unavailable.localizedDescription == "this build has no MLX")
    }

    @Test func noFramesAskNothingOfTheModel() async throws {
        let embedder = SigLIPEmbedder()
        #expect(try await embedder.embed(images: []) == [])
        #expect(await embedder.isLoaded == false, "an empty batch does not load 0.75 GB of weights")
        #expect(embedder.modelID == SigLIPConfig.modelID && embedder.dims == 768)
    }
}
