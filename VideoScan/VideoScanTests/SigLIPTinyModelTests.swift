// SigLIPTinyModelTests.swift — the REAL SigLIP load path and both towers, run
// on a model a few kilobytes large that the test writes itself
// (Observations/FrameSearch/SigLIPEmbedder.swift; the seam is SigLIPShape /
// SigLIPSource). No 1.5 GB weights, no network, no HOME dependence — so what
// SigLIPEmbedderTests can only check where the published weights are (parity
// with the reference vectors) is joined here by everything about the loader
// that does not depend on WHICH numbers are in the checkpoint:
//
//   LOGIC      a checkpoint in the published (torch) layout loads: the extra
//              tensors a published file carries are left out, the patch
//              convolution is transposed, every vector comes back unit length,
//              the same picture or words give the same vector, different ones
//              differ; ids are padded to the model's length.
//   TRUTH      70 pictures across three batches come back in order — picture
//              i's vector is the one it gets alone; a checkpoint already in
//              MLX's conv layout gives the same vectors as the torch one.
//   ISOLATION  a missing tensor, an unknown tensor, a mis-shaped tensor, a
//              truncated file, no file, no tokenizer: "SigLIP 2 could not be
//              loaded: …" — never a crash, never a half-loaded model; weights
//              that cannot be found keep their own words; a failed load is
//              tried again, not remembered.
//   CANCEL     a cut run throws CancellationError (the job reads it as
//              "stopped", nobody's fault).
//   END TO END the tiny model through the job, the index on disk and the
//              window's search.
// The checkpoint's layout is spelled out HERE, independently of the Swift
// modules, so renaming a tower's member breaks this suite as it would break
// loading the published file.

#if canImport(MLX)

import CoreGraphics
import Foundation
import MLX
import Testing
import VideoScanCore
@testable import VideoScan

enum TinySigLIP {
    static let modelID = "test/tiny-siglip"
    static let shape = SigLIPShape(dims: 16, imageSize: 32, patchSize: 16, layers: 2, heads: 2, intermediate: 32, vocab: 40, maxTokens: 8)

    /// Every tensor of a SigLIP checkpoint as transformers' SiglipModel names and shapes it (torch layout).
    static func layout(_ s: SigLIPShape) -> [(key: String, shape: [Int])] {
        let d = s.dims, h = s.intermediate, p = s.patchSize
        let positions = (s.imageSize / p) * (s.imageSize / p)
        var keys: [(key: String, shape: [Int])] = []
        func linear(_ name: String, _ out: Int, _ input: Int) { keys += [(name + ".weight", [out, input]), (name + ".bias", [out])] }
        func norm(_ name: String) { keys += [(name + ".weight", [d]), (name + ".bias", [d])] }
        func mlp(_ name: String) { linear(name + ".fc1", h, d); linear(name + ".fc2", d, h) }
        func encoder(_ tower: String) {
            for i in 0..<s.layers {
                let layer = "\(tower).encoder.layers.\(i)"
                for projection in ["q_proj", "k_proj", "v_proj", "out_proj"] { linear("\(layer).self_attn.\(projection)", d, d) }
                norm("\(layer).layer_norm1")
                mlp("\(layer).mlp")
                norm("\(layer).layer_norm2")
            }
        }
        keys += [("vision_model.embeddings.patch_embedding.weight", [d, 3, p, p]), ("vision_model.embeddings.patch_embedding.bias", [d]),
                 ("vision_model.embeddings.position_embedding.weight", [positions, d])]
        encoder("vision_model")
        norm("vision_model.post_layernorm")
        keys += [("vision_model.head.probe", [1, 1, d]), ("vision_model.head.attention.in_proj_weight", [3 * d, d]),
                 ("vision_model.head.attention.in_proj_bias", [3 * d])]
        linear("vision_model.head.attention.out_proj", d, d)
        norm("vision_model.head.layernorm")
        mlp("vision_model.head.mlp")
        keys += [("text_model.embeddings.token_embedding.weight", [s.vocab, d]), ("text_model.embeddings.position_embedding.weight", [s.maxTokens, d])]
        encoder("text_model")
        norm("text_model.final_layer_norm")
        linear("text_model.head", d, d)
        return keys
    }

    static let patchKey = "vision_model.embeddings.patch_embedding.weight"

    /// Write `model.safetensors` into `folder`: the same numbers every run (a sine — weights about ±0.6, biases
    /// ±0.1, layer-norm gains about 1, so the model tells its inputs apart), plus the four tensors a published
    /// checkpoint carries that are not parameters. `edit` damages or rearranges it.
    static func write(to folder: URL, edit: (inout [String: MLXArray]) -> Void = { _ in }) throws {
        var tensors: [String: MLXArray] = [:]
        for (n, tensor) in layout(shape).enumerated() {
            let count = tensor.shape.reduce(1, *)
            let isGain = tensor.key.contains("norm") && tensor.key.hasSuffix(".weight")
            let amplitude: Float = tensor.shape.count >= 2 ? 0.6 : 0.1
            tensors[tensor.key] = MLXArray((0..<count).map { (isGain ? 1 : 0) + Float(sin(Double($0 * 7 + n * 13) * 0.37)) * amplitude }, tensor.shape)
        }
        tensors["logit_scale"] = MLXArray([Float(4.7)], [1])
        tensors["logit_bias"] = MLXArray([Float(-12.9)], [1])
        tensors["text_model.embeddings.position_ids"] = MLXArray((0..<shape.maxTokens).map(Int32.init), [1, shape.maxTokens])
        tensors["vision_model.embeddings.position_ids"] = MLXArray([Int32(0), 1, 2, 3], [1, 4])
        edit(&tensors)
        try save(arrays: tensors, url: folder.appendingPathComponent("model.safetensors"))
    }

    /// "3 9 27" → [3, 9, 27]: a tokenizer a test can read.
    static let tokenize: @Sendable (String) -> [Int] = { $0.split(separator: " ").compactMap { Int($0) } }

    static func embedder(_ folder: URL) -> SigLIPEmbedder {
        SigLIPEmbedder(source: SigLIPSource(modelID: modelID, shape: shape, weights: { folder }, tokenize: tokenize))
    }

    /// A folder with a good tiny checkpoint in it.
    static func folder(edit: (inout [String: MLXArray]) -> Void = { _ in }) throws -> URL {
        let dir = try ObsFixture.tempDir("tiny-siglip")
        try write(to: dir, edit: edit)
        return dir
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return dot / (length(a) * length(b))
    }

    static func length(_ v: [Float]) -> Float { v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot() }

    /// Picture `i` of a set no two of which are alike.
    static func picture(_ i: Int) -> CGImage {
        FrameSearchTestCards.pixels(size: 48) { x, y in (UInt8((i * 37 + x * 3) % 256), UInt8((i * 91 + y * 5) % 256), UInt8((i * 13 + x + y) % 256)) }
    }
}

/// Pictures that say when their pixels are read — the embedder reads a picture when it builds that picture's
/// batch — and that can hold the reader at one of them. (A CGImage over a callback data provider: CoreGraphics
/// asks for the bytes when the picture is first drawn.)
final class WatchedPictures: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    private var isHolding = false
    private var released = false
    private let holdAt: Int
    private(set) var images: [CGImage] = []

    /// One picture's bytes and its place in the set.
    private final class Source {
        let index: Int
        let bytes: [UInt8]
        unowned let owner: WatchedPictures
        init(index: Int, owner: WatchedPictures) {
            self.index = index
            self.owner = owner
            bytes = (0..<(16 * 16 * 4)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index &* 31) }
        }
    }

    init(count: Int, holdAt: Int) {
        self.holdAt = holdAt
        images = (0..<count).compactMap { index in
            let source = Source(index: index, owner: self)
            var callbacks = CGDataProviderDirectCallbacks(
                version: 0, getBytePointer: nil, releaseBytePointer: nil,
                getBytesAtPosition: { info, buffer, position, count in
                    guard let info else { return 0 }
                    let source = Unmanaged<Source>.fromOpaque(info).takeUnretainedValue()
                    source.owner.wasRead(source.index)
                    let start = Int(position), n = max(0, min(count, source.bytes.count - start))
                    source.bytes.withUnsafeBytes { raw in
                        if let base = raw.baseAddress, n > 0 { buffer.copyMemory(from: base.advanced(by: start), byteCount: n) }
                    }
                    return n
                },
                releaseInfo: { info in
                    if let info { Unmanaged<Source>.fromOpaque(info).release() }
                })
            guard let provider = CGDataProvider(directInfo: Unmanaged.passRetained(source).toOpaque(), size: off_t(source.bytes.count), callbacks: &callbacks) else { return nil }
            return CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// The pictures read so far, in order (a picture read twice is listed once).
    var read: [Int] { lock.withLock { seen } }
    /// True while the reader waits at `holdAt`.
    var holding: Bool { lock.withLock { isHolding } }
    func release() { lock.withLock { released = true } }

    private func wasRead(_ index: Int) {
        let first = lock.withLock { () -> Bool in
            guard !seen.contains(index) else { return false }
            seen.append(index)
            return true
        }
        guard first, index == holdAt else { return }
        lock.withLock { isHolding = true }
        while !lock.withLock({ released }) { usleep(1_000) }     // a gate inside a C callback: no await here
        lock.withLock { isHolding = false }
    }
}

@Suite("SigLIP — the real loader and towers on a tiny model", .serialized)
struct SigLIPTinyModelTests {

    // MARK: Logic

    @Test func aPublishedLayoutCheckpointLoadsAndBothTowersAnswerUnitVectors() async throws {
        let folder = try TinySigLIP.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let embedder = TinySigLIP.embedder(folder)
        #expect(embedder.modelID == "test/tiny-siglip" && embedder.dims == 16)
        #expect(await embedder.isLoaded == false, "nothing is loaded until something is asked")

        let pictures = [FrameSearchTestCards.solid(255, 0, 0, size: 64), FrameSearchTestCards.solid(0, 0, 255, size: 64), FrameSearchTestCards.gradient(size: 100)]
        let vectors = try await embedder.embed(images: pictures)
        #expect(vectors.count == 3 && vectors.allSatisfy { $0.count == 16 && $0.allSatisfy(\.isFinite) })
        #expect(vectors.allSatisfy { abs(TinySigLIP.length($0) - 1) < 0.005 }, "every vector is unit length: \(vectors.map(TinySigLIP.length))")
        #expect(TinySigLIP.cosine(vectors[0], vectors[1]) < 0.999 && TinySigLIP.cosine(vectors[0], vectors[2]) < 0.999,
                "different pictures, different vectors: \(TinySigLIP.cosine(vectors[0], vectors[1])), \(TinySigLIP.cosine(vectors[0], vectors[2]))")
        let alone = try await embedder.embed(images: [pictures[1]])
        #expect(TinySigLIP.cosine(alone[0], vectors[1]) > 0.9999, "a picture's vector does not depend on what it was batched with")

        let loaded = await embedder.isLoaded, from = await embedder.weightsFolder, took = await embedder.loadSeconds
        #expect(loaded && from == folder && (took ?? -1) >= 0, "loaded from the folder the source named")

        let words = try await embedder.embed(text: "3 9 27")
        #expect(words.count == 16 && abs(TinySigLIP.length(words) - 1) < 0.005)
        #expect(try await embedder.embed(text: "3 9 27") == words, "the same words, the same vector")
        let other = try await embedder.embed(text: "3 9 28")
        #expect(other != words, "other words, another vector — the padding does not hide what came before it")
        let full = try await embedder.embed(text: "1 2 3 4 5 6 7 8"), lastDiffers = try await embedder.embed(text: "1 2 3 4 5 6 7 9")
        #expect(TinySigLIP.cosine(full, lastDiffers) < 0.999, "the pooled (last) position counts: \(TinySigLIP.cosine(full, lastDiffers))")
        #expect(try await embedder.tokenIDs("3 9 27") == [3, 9, 27, 0, 0, 0, 0, 0], "padded to the model's length — the text tower pools the LAST position")
        #expect(try await embedder.tokenIDs("1 2 3 4 5 6 7 8 9 10") == [1, 2, 3, 4, 5, 6, 7, 8], "and cut at it")
    }

    @Test func warmingLoadsTheModelAndUnloadingDropsItUntilTheNextQuestion() async throws {
        let folder = try TinySigLIP.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let embedder = TinySigLIP.embedder(folder)
        try await embedder.prewarm()
        #expect(await embedder.isLoaded, "the window's background warm-up is a load")
        let before = try await embedder.embed(text: "5 6")
        await embedder.unload()
        #expect(await embedder.isLoaded == false)
        let after = try await embedder.embed(text: "5 6")
        let reloaded = await embedder.isLoaded
        #expect(reloaded && TinySigLIP.cosine(before, after) > 0.9999, "reloaded from the same file: the same vector")
    }

    // MARK: Truth

    @Test func seventyPicturesAcrossThreeBatchesComeBackInOrder() async throws {
        let folder = try TinySigLIP.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let embedder = TinySigLIP.embedder(folder)
        let pictures = (0..<70).map(TinySigLIP.picture)
        let all = try await embedder.embed(images: pictures)
        #expect(all.count == 70 && all.allSatisfy { $0.count == 16 })
        for i in [0, 31, 32, 63, 64, 69] {            // either side of each batch boundary (32 per batch)
            let alone = try await embedder.embed(images: [pictures[i]])
            #expect(TinySigLIP.cosine(alone[0], all[i]) > 0.999, "picture \(i)'s row is picture \(i)'s vector")
            let neighbour = all[(i + 1) % 70]
            #expect(TinySigLIP.cosine(alone[0], neighbour) < TinySigLIP.cosine(alone[0], all[i]), "and not its neighbour's")
        }
    }

    @Test func aCheckpointAlreadyInMLXConvLayoutGivesTheSameVectorsAsTheTorchOne() async throws {
        let torch = try TinySigLIP.folder()
        let mlx = try TinySigLIP.folder { tensors in
            // (out, in, kh, kw) → (out, kh, kw, in): what the loader does to a torch file, done here beforehand.
            if let w = tensors[TinySigLIP.patchKey] { tensors[TinySigLIP.patchKey] = w.transposed(0, 2, 3, 1) }
        }
        defer { try? FileManager.default.removeItem(at: torch); try? FileManager.default.removeItem(at: mlx) }
        let pictures = [TinySigLIP.picture(3), FrameSearchTestCards.gradient(size: 64)]
        let fromTorch = try await TinySigLIP.embedder(torch).embed(images: pictures)
        let fromMLX = try await TinySigLIP.embedder(mlx).embed(images: pictures)
        for i in 0..<2 {
            #expect(TinySigLIP.cosine(fromTorch[i], fromMLX[i]) > 0.9999, "picture \(i): the two layouts are the same model")
        }
    }

    // MARK: Isolation

    @Test(arguments: ["a tensor is missing", "an unknown tensor", "a tensor of the wrong shape", "the file is cut short", "there is no file", "there is no tokenizer"])
    func aDamagedCheckpointIsALoadFailureInWordsNeverACrashOrAHalfLoadedModel(_ damage: String) async throws {
        let folder: URL
        var source = SigLIPSource(modelID: TinySigLIP.modelID, shape: TinySigLIP.shape, weights: nil, tokenize: TinySigLIP.tokenize)
        switch damage {
        case "a tensor is missing":
            folder = try TinySigLIP.folder { $0["text_model.head.bias"] = nil }
        case "an unknown tensor":
            folder = try TinySigLIP.folder { $0["vision_model.rogue.weight"] = MLXArray([Float(1), 2], [2]) }
        case "a tensor of the wrong shape":
            folder = try TinySigLIP.folder { $0["text_model.head.weight"] = MLXArray([Float](repeating: 0.1, count: 16 * 17), [16, 17]) }
        case "the file is cut short":
            folder = try TinySigLIP.folder()
            let file = folder.appendingPathComponent("model.safetensors")
            try Data(try Data(contentsOf: file).prefix(300)).write(to: file)
        case "there is no file":
            folder = try ObsFixture.tempDir("tiny-siglip")
        default:   // the hub's tokenizer is asked for, and the folder has none
            folder = try TinySigLIP.folder()
            source.tokenize = nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        source.weights = { folder }
        let embedder = SigLIPEmbedder(source: source)
        do {
            _ = try await embedder.embed(text: "3 9")
            Issue.record("\(damage): the load must fail")
        } catch let error as SigLIPError {
            guard case .loadFailed(let why) = error else { Issue.record("\(damage): \(error)"); return }
            #expect(!why.isEmpty && error.localizedDescription.hasPrefix("SigLIP 2 could not be loaded: "), "\(damage): \(error.localizedDescription)")
        }
        #expect(await embedder.isLoaded == false, "\(damage): nothing half-loaded is kept")
        do {
            _ = try await embedder.embed(images: [TinySigLIP.picture(1)])
            Issue.record("\(damage): the image tower must not answer either")
        } catch {
            #expect(error is SigLIPError, "\(damage): \(error)")
        }
    }

    @Test func weightsThatCannotBeFoundKeepTheirOwnWordsAndAFailedLoadIsTriedAgain() async throws {
        let good = try TinySigLIP.folder()
        let empty = try ObsFixture.tempDir("tiny-siglip")
        defer { try? FileManager.default.removeItem(at: good); try? FileManager.default.removeItem(at: empty) }

        let unreachable = SigLIPEmbedder(source: SigLIPSource(modelID: TinySigLIP.modelID, shape: TinySigLIP.shape,
                                                              weights: { throw SigLIPError.weightsMissing("the hub is unreachable") }, tokenize: TinySigLIP.tokenize))
        do {
            try await unreachable.prewarm()
            Issue.record("no weights: the warm-up must fail")
        } catch {
            #expect(error.localizedDescription == "SigLIP 2 weights are not on this Mac (the hub is unreachable)", "not re-worded as a load failure")
        }

        let asked = ObsCounter()
        let recovering = SigLIPEmbedder(source: SigLIPSource(modelID: TinySigLIP.modelID, shape: TinySigLIP.shape,
                                                             weights: { asked.bump() == 1 ? empty : good }, tokenize: TinySigLIP.tokenize))
        await #expect(throws: SigLIPError.self) { try await recovering.embed(text: "3") }
        let vector = try await recovering.embed(text: "3")
        #expect(vector.count == 16 && asked.value == 2, "the first failure is not remembered: the next question looks for the weights again")
    }

    // MARK: Cancel

    /// Seventy pictures are three batches (32, 32, 6). The reader is held at picture 32 — the second batch is
    /// being built, its own cancellation check already passed — the run is cut there, and the reader released.
    /// The second batch's forward pass may finish; the THIRD batch must never be built (no picture from 64 on is
    /// read), so no later forward pass happens. A check made only on entry would run all three (Codex #302
    /// finding 10; seen RED with the check moved out of the loop).
    @Test func aRunCutMidwayStopsAtTheNextBatchBoundaryAndTheEngineCallsItStopped() async throws {
        let folder = try TinySigLIP.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let embedder = TinySigLIP.embedder(folder)
        try await embedder.prewarm()

        // Straight through the embedder.
        let direct = WatchedPictures(count: 70, holdAt: 32)
        let cut = Task { try await embedder.embed(images: direct.images).count }
        try await FrameIndexJobTests.until("the second batch is being built") { direct.holding }
        cut.cancel()
        direct.release()
        await #expect(throws: CancellationError.self) { try await cut.value }
        #expect(Set(direct.read) == Set(0..<64), "the first two batches were built and nothing after them: \(direct.read.filter { $0 >= 64 })")

        // Through the engine: the cancellation arrives while the model is working, not before the engine was entered.
        let viaEngine = WatchedPictures(count: 70, holdAt: 32)
        let pictures = viaEngine.images
        let engine = Task {
            await FrameIndexEngine.outcome(path: "/V/a.mov", durationSeconds: 700, framesPerFile: 70,
                                           extract: { _, times in zip(times, pictures).map { ($0, Optional($1)) } }, embedder: embedder, whereabouts: { _ in nil })
        }
        try await FrameIndexJobTests.until("the engine's second batch is being built") { viaEngine.holding }
        engine.cancel()
        viaEngine.release()
        guard case .deferred(.stopped) = await engine.value else { Issue.record("a run cut during inference blames nobody"); return }
        #expect(!viaEngine.read.contains { $0 >= 64 }, "and the third batch was never built")
    }

    // MARK: End to end

    @Test @MainActor func theTinyModelThroughTheJobTheIndexOnDiskAndTheWindowsSearch() async throws {
        let folder = try TinySigLIP.folder()
        let root = try ObsFixture.tempDir("tiny-index")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: root) }
        let embedder = TinySigLIP.embedder(folder)
        let rows = [ObsFixture.row(1, path: "/V/a.mov"), ObsFixture.row(2, path: "/V/b.mov")]
        let job = ObsFixture.job(rows, root: root, embedder: embedder)
        job.extract = { path, times in times.enumerated().map { ($0.element, TinySigLIP.picture(path.hasSuffix("a.mov") ? $0.offset : 40 + $0.offset)) } }
        job.start()
        await job.task?.value
        #expect(job.outcome == .finished && job.indexed == 2 && job.framesAdded == 6, "\(job.state)")
        let status = FrameIndexStore.load(root: root, model: TinySigLIP.modelID)
        let index = try #require(status.index, "\(status)")
        #expect(index.model == "test/tiny-siglip" && index.dims == 16 && index.count == 6)

        let store = FrameSearchStore(scope: .everything, loader: FrameSearchLoader(
            modelID: embedder.modelID, loadIndex: { status }, files: { _ in rows }, embedText: { try await embedder.embed(text: $0) },
            prewarm: { try await embedder.prewarm() }, thumbnail: { _, _ in nil }, startIndex: { _, _ in nil }, reveal: { _ in true }, note: { _ in }))
        await store.loadIndex()
        await store.search("3 9 27")
        #expect(store.failure == nil && store.hits.count == 4, "two per video: \(store.failure ?? "")")
        #expect(store.hits.allSatisfy { $0.score.isFinite && abs($0.score) <= 1.001 } && zip(store.hits, store.hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(store.hits.allSatisfy { $0.sourceWords.hasPrefix("SigLIP 2 (test/tiny-siglip), similarity ") })
    }
}

#endif
