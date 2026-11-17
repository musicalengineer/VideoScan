// SigLIPEmbedder.swift — SigLIP 2 (google/siglip2-base-patch16-224) in MLX
// Swift, in-process: the image tower for the frame indexer, the text tower
// for the Frames search (docs/design/file_dossier_view.md §II.7 item 2;
// Rick 2026-11-06: "use a public model … fall back to python if we need to").
//
// Path taken: NATIVE. The app already links mlx-swift (Qwen captioning), and
// the 224 fixed-resolution SigLIP 2 checkpoints are plain SigLIP
// (`model_type: siglip`): a ViT-B/16 image tower with an attention-pooling
// head and a 12-layer text tower pooled at the last token. ~250 lines of MLX
// modules below, loaded from the public safetensors; the Gemma tokenizer
// comes from swift-transformers (already linked through MLXLMCommon). No
// Python at runtime, nothing leaves the Mac. Parity with the reference
// implementation (transformers' SiglipModel) is pinned by
// SigLIPEmbedderTests against vectors computed once from synthetic cards.
//
// Weights: the HF hub cache (`~/.cache/huggingface/hub/models--google--
// siglip2-base-patch16-224/snapshots/<rev>/`) when it is there, else
// swift-transformers' HubApi downloads the same public files (one time,
// ~1.5 GB fp32).
//
// Compute: the GPU through MLX (Metal), float16. The model is loaded once
// per process and kept warm (`shared`), so a query after the first costs a
// text-tower pass (~10 ms) — no helper process, no socket.
//
// Memory (worst case): the fp32 safetensors are read once (1.5 GB transient,
// freed after the cast); the warm model is ~0.75 GB in float16 (text 0.56 GB
// — the 256k-token embedding is most of it — image 0.19 GB). An image batch
// of 32 holds 32 × 3 × 224 × 224 floats in (19 MB) plus activations
// (~32 × 197 × 3072 × 2 B ≈ 39 MB per layer, transient). MLX's buffer cache
// is capped at 256 MB while this model runs.
//
// Seam (2026-11-16): the towers take their sizes from a `SigLIPShape` and the
// embedder its weights folder and tokenizer from a `SigLIPSource`. The app has
// exactly one of each (`.base`, `.hub` — the published model, as before). A
// test builds a SigLIP a few kilobytes large in the same checkpoint layout
// and runs the REAL load path and both towers on it (SigLIPTinyModelTests),
// so the key filter, the conv transposition, `verify: [.all]`, batching and
// cancellation are exercised in every lane, not only where the 1.5 GB
// weights are. (For Rick: an injected interface in place of a hard-wired
// dependency; the sizes are constructor parameters, not compile-time constants.)
//
// (For Rick: an MLX `Module` is a C++ class whose members are tensors; the
// `@ModuleInfo(key:)` wrappers name each member exactly as the safetensors
// file does, so `update(parameters:)` is a by-name memcpy. `actor` ≈ a class
// with an implicit mutex: one embedding call at a time.)

import CoreGraphics
import Foundation
import os
import VideoScanCore

#if canImport(MLX)
import Hub
import MLX
import MLXFast
import MLXNN
import Tokenizers
#endif

private let siglipLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "siglip")

/// What the Frames mode needs from an embedding model (tests substitute a stub).
protocol FrameEmbedding: Sendable {
    var modelID: String { get }
    var dims: Int { get }
    /// One L2-normalised vector per image, in order.
    func embed(images: [CGImage]) async throws -> [[Float]]
    /// The query's L2-normalised vector.
    func embed(text: String) async throws -> [Float]
    /// Load the model ahead of the first question (the window asks for this in the background).
    func prewarm() async throws
}

extension FrameEmbedding {
    /// A model with nothing to load.
    func prewarm() async throws {}
}

enum SigLIPError: LocalizedError {
    case weightsMissing(String)
    case loadFailed(String)
    case badImage
    case unavailable

    var errorDescription: String? {
        switch self {
        case .weightsMissing(let why): return "SigLIP 2 weights are not on this Mac (\(why))"
        case .loadFailed(let why): return "SigLIP 2 could not be loaded: \(why)"
        case .badImage: return "a frame could not be converted to pixels"
        case .unavailable: return "this build has no MLX"
        }
    }
}

enum SigLIPConfig {
    static let modelID = "google/siglip2-base-patch16-224"
    static let dims = 768
    static let imageSize = 224
    static let patchSize = 16
    static let layers = 12
    static let heads = 12
    static let intermediate = 3072
    static let vocab = 256_000
    static let maxTokens = 64
    static let padToken = 0
    static let layerNormEps: Float = 1e-6

    /// The python hub cache's snapshot folder for the model, if one is complete there.
    static func hubCacheSnapshot(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        let snapshots = home.appendingPathComponent(".cache/huggingface/hub/models--google--siglip2-base-patch16-224/snapshots", isDirectory: true)
        guard let revs = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else { return nil }
        return revs.sorted { $0.lastPathComponent < $1.lastPathComponent }.first { rev in
            ["model.safetensors", "tokenizer.json", "tokenizer_config.json"].allSatisfy {
                FileManager.default.fileExists(atPath: rev.appendingPathComponent($0).path)
            }
        }
    }
}

/// The sizes of one SigLIP. `.base` is google/siglip2-base-patch16-224 as published.
struct SigLIPShape: Sendable, Equatable {
    var dims = SigLIPConfig.dims
    var imageSize = SigLIPConfig.imageSize
    var patchSize = SigLIPConfig.patchSize
    var layers = SigLIPConfig.layers
    var heads = SigLIPConfig.heads
    var intermediate = SigLIPConfig.intermediate
    var vocab = SigLIPConfig.vocab
    var maxTokens = SigLIPConfig.maxTokens

    static let base = SigLIPShape()
}

/// Where a SigLIP comes from: its id, its sizes, the folder its `model.safetensors` is in and how words become
/// token ids. The app uses `.hub` and nothing else.
struct SigLIPSource: Sendable {
    var modelID = SigLIPConfig.modelID
    var shape = SigLIPShape.base
    /// The folder holding `model.safetensors`; nil = the hub cache's snapshot, else a one-time download.
    var weights: (@Sendable () async throws -> URL)?
    /// Words → token ids (before padding); nil = the Gemma tokenizer beside the weights.
    var tokenize: (@Sendable (String) -> [Int])?

    static let hub = SigLIPSource()
}

// MARK: - Pixels (shared with the tests)

enum SigLIPPixels {
    /// 224 × 224 RGB, resized without keeping the aspect (the processor's `do_resize` to a square),
    /// scaled to [-1, 1] ((x / 255 − 0.5) / 0.5), HWC order. nil when the image cannot be drawn.
    static func normalizedHWC(_ image: CGImage, size: Int = SigLIPConfig.imageSize) -> [Float]? {
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        var out = [Float](repeating: 0, count: size * size * 3)
        for p in 0..<(size * size) {
            out[p * 3] = Float(rgba[p * 4]) / 127.5 - 1
            out[p * 3 + 1] = Float(rgba[p * 4 + 1]) / 127.5 - 1
            out[p * 3 + 2] = Float(rgba[p * 4 + 2]) / 127.5 - 1
        }
        return out
    }

    /// Token ids padded (or cut) to exactly `maxTokens`: SigLIP was trained on max-length padding and
    /// pools the LAST position, so the padding is part of the model's input, not a detail.
    static func padded(_ ids: [Int], to n: Int = SigLIPConfig.maxTokens, pad: Int = SigLIPConfig.padToken) -> [Int] {
        ids.count >= n ? Array(ids.prefix(n)) : ids + [Int](repeating: pad, count: n - ids.count)
    }
}

#if canImport(MLX)

// MARK: - The towers

private final class SigAttention: Module {
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "out_proj") var out: Linear
    let heads: Int
    let scale: Float

    init(dims: Int, heads: Int) {
        self.heads = heads
        self.scale = pow(Float(dims / heads), -0.5)
        _q.wrappedValue = Linear(dims, dims)
        _k.wrappedValue = Linear(dims, dims)
        _v.wrappedValue = Linear(dims, dims)
        _out.wrappedValue = Linear(dims, dims)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        let qs = q(x).reshaped(b, l, heads, -1).transposed(0, 2, 1, 3)
        let ks = k(x).reshaped(b, l, heads, -1).transposed(0, 2, 1, 3)
        let vs = v(x).reshaped(b, l, heads, -1).transposed(0, 2, 1, 3)
        let o = MLXFast.scaledDotProductAttention(queries: qs, keys: ks, values: vs, scale: scale, mask: .none)
        return out(o.transposed(0, 2, 1, 3).reshaped(b, l, -1))
    }
}

private final class SigMLP: Module, UnaryLayer {
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    init(dims: Int, hidden: Int) {
        fc1 = Linear(dims, hidden)
        fc2 = Linear(hidden, dims)
    }
    // gelu_pytorch_tanh = the tanh approximation.
    func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(geluApproximate(fc1(x))) }
}

private final class SigLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: SigAttention
    @ModuleInfo(key: "layer_norm1") var norm1: LayerNorm
    @ModuleInfo var mlp: SigMLP
    @ModuleInfo(key: "layer_norm2") var norm2: LayerNorm

    init(_ s: SigLIPShape) {
        let d = s.dims
        _attention.wrappedValue = SigAttention(dims: d, heads: s.heads)
        _norm1.wrappedValue = LayerNorm(dimensions: d, eps: SigLIPConfig.layerNormEps)
        mlp = SigMLP(dims: d, hidden: s.intermediate)
        _norm2.wrappedValue = LayerNorm(dimensions: d, eps: SigLIPConfig.layerNormEps)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = x + attention(norm1(x))
        return h + mlp(norm2(h))
    }
}

private final class SigEncoder: Module {
    var layers: [SigLayer]
    init(_ s: SigLIPShape) { layers = (0..<s.layers).map { _ in SigLayer(s) } }
    func callAsFunction(_ x: MLXArray) -> MLXArray { layers.reduce(x) { $1($0) } }
}

private final class SigVisionEmbeddings: Module {
    @ModuleInfo(key: "patch_embedding") var patch: Conv2d
    @ModuleInfo(key: "position_embedding") var position: Embedding
    let positions: Int

    init(_ s: SigLIPShape) {
        let d = s.dims, p = s.patchSize
        positions = (s.imageSize / p) * (s.imageSize / p)
        _patch.wrappedValue = Conv2d(inputChannels: 3, outputChannels: d, kernelSize: .init(p), stride: .init(p))
        _position.wrappedValue = Embedding(embeddingCount: positions, dimensions: d)
    }

    /// NHWC pixels → (B, 196, D), patches in row-major order (as the reference flattens them).
    func callAsFunction(_ pixels: MLXArray) -> MLXArray {
        patch(pixels).flattened(start: 1, end: 2) + position(MLXArray(0..<positions)[.newAxis, 0...])
    }
}

/// The attention-pooling head: one learned probe attends over the patches (torch nn.MultiheadAttention weights).
private final class SigPoolingHead: Module {
    @ParameterInfo var probe: MLXArray
    @ModuleInfo var attention: SigHeadAttention
    @ModuleInfo var layernorm: LayerNorm
    @ModuleInfo var mlp: SigMLP
    let dims: Int

    init(_ s: SigLIPShape) {
        let d = s.dims
        dims = d
        _probe.wrappedValue = MLXArray.zeros([1, 1, d])
        attention = SigHeadAttention(s)
        layernorm = LayerNorm(dimensions: d, eps: SigLIPConfig.layerNormEps)
        mlp = SigMLP(dims: d, hidden: s.intermediate)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0)
        let q = MLX.broadcast(probe, to: [b, 1, dims])
        let h = attention(query: q, keyValue: x)
        return (h + mlp(layernorm(h)))[0..., 0, 0...]
    }
}

private final class SigHeadAttention: Module {
    @ParameterInfo(key: "in_proj_weight") var inWeight: MLXArray
    @ParameterInfo(key: "in_proj_bias") var inBias: MLXArray
    @ModuleInfo(key: "out_proj") var out: Linear
    let dims: Int
    let heads: Int

    init(_ s: SigLIPShape) {
        let d = s.dims
        dims = d
        heads = s.heads
        _inWeight.wrappedValue = MLXArray.zeros([3 * d, d])
        _inBias.wrappedValue = MLXArray.zeros([3 * d])
        _out.wrappedValue = Linear(d, d)
    }

    func callAsFunction(query: MLXArray, keyValue x: MLXArray) -> MLXArray {
        let d = dims
        let wq = inWeight[0..<d], wk = inWeight[d..<(2 * d)], wv = inWeight[(2 * d)...]
        let bq = inBias[0..<d], bk = inBias[d..<(2 * d)], bv = inBias[(2 * d)...]
        let (b, l, s) = (query.dim(0), query.dim(1), x.dim(1))
        let qs = (matmul(query, wq.T) + bq).reshaped(b, l, heads, -1).transposed(0, 2, 1, 3)
        let ks = (matmul(x, wk.T) + bk).reshaped(b, s, heads, -1).transposed(0, 2, 1, 3)
        let vs = (matmul(x, wv.T) + bv).reshaped(b, s, heads, -1).transposed(0, 2, 1, 3)
        let o = MLXFast.scaledDotProductAttention(queries: qs, keys: ks, values: vs, scale: pow(Float(d / heads), -0.5), mask: .none)
        return out(o.transposed(0, 2, 1, 3).reshaped(b, l, -1))
    }
}

private final class SigVisionTransformer: Module {
    @ModuleInfo var embeddings: SigVisionEmbeddings
    @ModuleInfo var encoder: SigEncoder
    @ModuleInfo(key: "post_layernorm") var postNorm: LayerNorm
    @ModuleInfo var head: SigPoolingHead

    init(_ s: SigLIPShape) {
        embeddings = SigVisionEmbeddings(s)
        encoder = SigEncoder(s)
        _postNorm.wrappedValue = LayerNorm(dimensions: s.dims, eps: SigLIPConfig.layerNormEps)
        head = SigPoolingHead(s)
    }

    func callAsFunction(_ pixels: MLXArray) -> MLXArray { head(postNorm(encoder(embeddings(pixels)))) }
}

private final class SigTextEmbeddings: Module {
    @ModuleInfo(key: "token_embedding") var token: Embedding
    @ModuleInfo(key: "position_embedding") var position: Embedding

    init(_ s: SigLIPShape) {
        _token.wrappedValue = Embedding(embeddingCount: s.vocab, dimensions: s.dims)
        _position.wrappedValue = Embedding(embeddingCount: s.maxTokens, dimensions: s.dims)
    }

    func callAsFunction(_ ids: MLXArray) -> MLXArray {
        token(ids) + position(MLXArray(0..<ids.dim(1))[.newAxis, 0...])
    }
}

private final class SigTextTransformer: Module {
    @ModuleInfo var embeddings: SigTextEmbeddings
    @ModuleInfo var encoder: SigEncoder
    @ModuleInfo(key: "final_layer_norm") var finalNorm: LayerNorm
    @ModuleInfo var head: Linear

    init(_ s: SigLIPShape) {
        embeddings = SigTextEmbeddings(s)
        encoder = SigEncoder(s)
        _finalNorm.wrappedValue = LayerNorm(dimensions: s.dims, eps: SigLIPConfig.layerNormEps)
        head = Linear(s.dims, s.dims)
    }

    /// (B, maxTokens) ids → (B, D): no attention mask, pooled at the LAST position (the reference's rule).
    func callAsFunction(_ ids: MLXArray) -> MLXArray {
        let h = finalNorm(encoder(embeddings(ids)))
        return head(h[0..., -1, 0...])
    }
}

private final class SigLIP: Module {
    @ModuleInfo(key: "vision_model") var vision: SigVisionTransformer
    @ModuleInfo(key: "text_model") var text: SigTextTransformer

    init(_ s: SigLIPShape) {
        _vision.wrappedValue = SigVisionTransformer(s)
        _text.wrappedValue = SigTextTransformer(s)
    }
}

// MARK: - The embedder (one per process, kept warm)

actor SigLIPEmbedder: FrameEmbedding {

    static let shared = SigLIPEmbedder()

    nonisolated let modelID: String
    nonisolated let dims: Int
    /// Images per forward pass (memory: see the file header).
    let batchSize = 32

    private let source: SigLIPSource
    private var model: SigLIP?
    /// The Gemma tokenizer; stays nil when the source brings its own `tokenize`.
    private var tokenizer: Tokenizer?
    /// Seconds the last load took (the report's cold number).
    private(set) var loadSeconds: Double?

    /// Where the weights came from (logged once).
    private(set) var weightsFolder: URL?

    init(source: SigLIPSource = .hub) {
        self.source = source
        modelID = source.modelID
        dims = source.shape.dims
    }

    func prewarm() async throws { _ = try await ensureLoaded() }

    var isLoaded: Bool { model != nil }

    /// Drop the model (frees ~0.75 GB); the next call reloads.
    func unload() {
        model = nil
        tokenizer = nil
        MLX.GPU.clearCache()
    }

    private func ensureLoaded() async throws -> SigLIP {
        if let model { return model }
        let started = CFAbsoluteTimeGetCurrent()
        noteMLXInferenceUsed()   // AppDelegate's quit path synchronises the GPU stream (MLXShutdown.swift)
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        let folder = try await (source.weights ?? Self.hubWeights)()
        do {
            let tok: Tokenizer? = try await source.tokenize == nil ? AutoTokenizer.from(modelFolder: folder) : nil
            let m = SigLIP(source.shape)
            try runMLX {
                var weights = try loadArrays(url: folder.appendingPathComponent("model.safetensors"))
                weights = weights.filter { !$0.key.contains("position_ids") && $0.key != "logit_scale" && $0.key != "logit_bias" }
                if let w = weights["vision_model.embeddings.patch_embedding.weight"], w.dim(1) == 3 {
                    // torch conv (out, in, kh, kw) → MLX conv (out, kh, kw, in)
                    weights["vision_model.embeddings.patch_embedding.weight"] = w.transposed(0, 2, 3, 1)
                }
                for (k, v) in weights { weights[k] = v.asType(.float16) }
                try m.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
                eval(m)
            }
            model = m
            tokenizer = tok
            weightsFolder = folder
            loadSeconds = CFAbsoluteTimeGetCurrent() - started
            siglipLog.info("SigLIP 2 loaded from \(folder.path, privacy: .public) in \(self.loadSeconds ?? 0, format: .fixed(precision: 2)) s")
            return m
        } catch {
            throw SigLIPError.loadFailed(error.localizedDescription)
        }
    }

    /// The hub cache's snapshot, else a one-time download of the same public files through swift-transformers.
    private static let hubWeights: @Sendable () async throws -> URL = {
        if let cached = SigLIPConfig.hubCacheSnapshot() { return cached }
        do {
            return try await HubApi().snapshot(from: SigLIPConfig.modelID,
                                               matching: ["model.safetensors", "*.json", "tokenizer.model"])
        } catch {
            throw SigLIPError.weightsMissing("not in ~/.cache/huggingface and the download failed: \(error.localizedDescription)")
        }
    }

    func embed(images: [CGImage]) async throws -> [[Float]] {
        guard !images.isEmpty else { return [] }
        let m = try await ensureLoaded()
        let size = source.shape.imageSize
        var out: [[Float]] = []
        out.reserveCapacity(images.count)
        var start = 0
        while start < images.count {
            try Task.checkCancellation()
            let batch = images[start..<min(start + batchSize, images.count)]
            var flat: [Float] = []
            flat.reserveCapacity(batch.count * size * size * 3)
            for image in batch {
                guard let px = SigLIPPixels.normalizedHWC(image, size: size) else { throw SigLIPError.badImage }
                flat.append(contentsOf: px)
            }
            let rows: [Float] = try runMLX {
                let pixels = MLXArray(flat, [batch.count, size, size, 3]).asType(.float16)
                let e = m.vision(pixels).asType(.float32)
                let n = e / sqrt((e * e).sum(axis: -1, keepDims: true))
                eval(n)
                return n.asArray(Float.self)
            }
            for i in 0..<batch.count { out.append(Array(rows[(i * dims)..<((i + 1) * dims)])) }
            start += batch.count
        }
        return out
    }

    /// The text exactly as typed (no prompt template; SigLIP 2 is trained on plain captions).
    func embed(text: String) async throws -> [Float] {
        let m = try await ensureLoaded()
        let ids = tokens(text)
        return try runMLX {
            let e = m.text(MLXArray(ids.map(Int32.init), [1, ids.count])).asType(.float32)
            let n = e / sqrt((e * e).sum(axis: -1, keepDims: true))
            eval(n)
            return n.asArray(Float.self)
        }
    }

    /// The ids the text tower sees (tests: parity with the reference tokenizer).
    func tokenIDs(_ text: String) async throws -> [Int] {
        _ = try await ensureLoaded()
        return tokens(text)
    }

    /// Words → ids, padded or cut to the model's length. Call after `ensureLoaded`.
    private func tokens(_ text: String) -> [Int] {
        SigLIPPixels.padded(source.tokenize?(text) ?? tokenizer?.encode(text: text) ?? [], to: source.shape.maxTokens)
    }
}

#else

actor SigLIPEmbedder: FrameEmbedding {
    static let shared = SigLIPEmbedder()
    nonisolated let modelID: String
    nonisolated let dims: Int
    init(source: SigLIPSource = .hub) {
        modelID = source.modelID
        dims = source.shape.dims
    }
    func prewarm() async throws { throw SigLIPError.unavailable }
    func embed(images: [CGImage]) async throws -> [[Float]] { throw SigLIPError.unavailable }
    func embed(text: String) async throws -> [Float] { throw SigLIPError.unavailable }
}

#endif
