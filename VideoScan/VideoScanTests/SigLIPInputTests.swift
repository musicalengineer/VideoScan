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
        // 400 × 100: the left half red, the right half blue. Cropping to a square would lose one colour.
        let ctx = try #require(CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 100))
        let frame = try #require(ctx.makeImage())
        let px = try #require(SigLIPPixels.normalizedHWC(frame, size: 16))
        #expect(px.count == 16 * 16 * 3)
        let left = (8 * 16 + 2) * 3, right = (8 * 16 + 13) * 3
        #expect(px[left] > 0.9 && px[left + 2] < -0.9, "the left of the square is the left of the frame (red)")
        #expect(px[right] < -0.9 && px[right + 2] > 0.9, "the right of the square is the right of the frame (blue)")
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
