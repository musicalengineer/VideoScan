// FrameIndex.swift (VideoScanCore/Observations) — the SigLIP 2 frame index
// behind the Observations window's Frames mode (docs/design/file_dossier_view.md
// §II.7 item 2; Rick 2026-11-06: "build the next step siglip 2").
//
// One sentence: a frame the indexer looked at becomes one row of a flat,
// L2-normalised float matrix, keyed by (whole-file SHA-256, frame time in
// milliseconds, model id); a text query's vector is scored against every
// row by cosine (one matrix-vector product) and the best rows come back
// with the file and time that produced them.
//
// What this is NOT: a catalog table. The index is a REBUILDABLE CACHE in
// its own folder (`Application Support/VideoScan/observations/siglip2/
// <model slug>/`): `index.json` (the sidecar: model, dims, one [digest, ms]
// pair per row, the files that could not be read) + `vectors-a.f16` or
// `vectors-b.f16` (row-major IEEE half floats, little-endian). Nothing here
// opens catalog.sqlite; delete the folder and the next build starts over.
//
// Truth: row i of the matrix IS entry i of the sidecar — they are written
// together and loaded together, and a load whose matrix size is not exactly
// count × dims × 2 bytes, whose model differs, or whose JSON does not parse
// is `.unreadable` (the window says "index not built"), never a partial or
// stale answer. The save is crash-safe: the matrix goes to the generation
// file the CURRENT sidecar does not name, then the sidecar is replaced
// atomically, so a crash between the two leaves the old pair intact.
//
// Memory (worst case): the matrix is held as Float32 in RAM — dims × 4 B per
// frame (768 × 4 = 3 KB). 8 frames × 20,000 files = 160,000 frames ≈ 490 MB,
// plus the sidecar (~90 B per entry ≈ 14 MB). Search allocates one score per
// row (640 KB at 160k). On disk the matrix is half that (Float16).
//
// (For Rick: `vDSP_mmul` is BLAS sgemv — one N×D by D×1 product, ~1 ms per
// 10k rows on Apple Silicon. A Swift `struct` with `[Float]` ≈ a C++ value
// type holding a std::vector: copies are copy-on-write, so passing one
// around is a pointer copy until someone mutates it.)

import Accelerate
import Foundation

// MARK: - Entry and key

/// One indexed frame: the content it came from and when in the clip.
public struct FrameIndexEntry: Sendable, Equatable, Hashable, Codable {
    /// Whole-file SHA-256 (hex) — the content's identity (rule 6), never the path.
    public let digest: String
    /// Frame time in whole milliseconds (the key's time; see `seconds`).
    public let millis: Int64

    public init(digest: String, millis: Int64) {
        self.digest = digest
        self.millis = millis
    }

    public init(digest: String, seconds: Double) {
        self.init(digest: digest, millis: FrameIndex.millis(seconds))
    }

    public var seconds: Double { Double(millis) / 1000 }

    // Encoded as a two-element array [digest, ms] — ~half the sidecar size of an object.
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        digest = try c.decode(String.self)
        millis = try c.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(digest)
        try c.encode(millis)
    }
}

// MARK: - The index (pure value)

public struct FrameIndex: Sendable, Equatable {

    /// The model that made the vectors (HF repo id); a query must be embedded by the same model.
    public let model: String
    public let dims: Int
    /// Row i of `vectors` is `entries[i]`.
    public let entries: [FrameIndexEntry]
    /// count × dims, row-major, each row L2-normalised.
    public let vectors: [Float]
    /// Contents the indexer tried and could not read (digest → the reason in words); not retried by a resume.
    public let failures: [String: String]

    public var count: Int { entries.count }

    public init(model: String, dims: Int, entries: [FrameIndexEntry], vectors: [Float], failures: [String: String] = [:]) {
        precondition(dims > 0 && vectors.count == entries.count * dims, "FrameIndex: \(vectors.count) floats for \(entries.count) × \(dims)")
        self.model = model
        self.dims = dims
        self.entries = entries
        self.vectors = vectors
        self.failures = failures
    }

    public static func empty(model: String, dims: Int) -> FrameIndex {
        FrameIndex(model: model, dims: dims, entries: [], vectors: [])
    }

    /// The cache key of one frame: model, content and time (ms). Two frames with the same key are the same vector.
    public static func cacheKey(model: String, digest: String, seconds: Double) -> String {
        "\(model)|\(digest)|\(millis(seconds))"
    }

    /// Seconds → whole milliseconds (rounded, never negative).
    public static func millis(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 1000).rounded())
    }

    /// The digests with at least one row (a resume skips these).
    public var indexedDigests: Set<String> { Set(entries.map(\.digest)) }

    /// Row `i` as a vector (tests, the truth check).
    public func vector(at i: Int) -> ArraySlice<Float> { vectors[(i * dims)..<((i + 1) * dims)] }

    /// L2-normalise (a zero vector stays zero).
    public static func normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sumSquares.squareRoot()
        guard norm > 0, norm.isFinite else { return [Float](repeating: 0, count: v.count) }
        return v.map { $0 / norm }
    }
}

// MARK: - Search

public enum FrameSearch {

    /// One hit: the row, its frame, and the cosine similarity (−1…1).
    public struct Scored: Sendable, Equatable {
        public let row: Int
        public let entry: FrameIndexEntry
        public let score: Float
    }

    /// The best `k` rows for `query` (embedded by `index.model`), best first.
    /// - `allowed`: the scope's digests (nil = every row). A row whose content is not in scope is never a hit.
    /// - `perContent`: at most this many frames of one content (so one long tape does not fill the page); nil = no cap.
    /// Ties order by digest, then time, so the same query gives the same page.
    public static func topK(query: [Float], in index: FrameIndex, k: Int, allowed: Set<String>? = nil, perContent: Int? = nil) -> [Scored] {
        guard k > 0, !index.entries.isEmpty, query.count == index.dims else { return [] }
        let q = FrameIndex.normalized(query)
        let n = index.count
        var scores = [Float](repeating: 0, count: n)
        index.vectors.withUnsafeBufferPointer { m in
            q.withUnsafeBufferPointer { qp in
                scores.withUnsafeMutableBufferPointer { sp in
                    guard let mb = m.baseAddress, let qb = qp.baseAddress, let sb = sp.baseAddress else { return }
                    // (n × d) · (d × 1) → (n × 1)
                    vDSP_mmul(mb, 1, qb, 1, sb, 1, vDSP_Length(n), 1, vDSP_Length(index.dims))
                }
            }
        }
        var candidates: [Int] = []
        candidates.reserveCapacity(n)
        for i in 0..<n where allowed?.contains(index.entries[i].digest) ?? true { candidates.append(i) }
        candidates.sort { a, b in
            if scores[a] != scores[b] { return scores[a] > scores[b] }
            let ea = index.entries[a], eb = index.entries[b]
            if ea.digest != eb.digest { return ea.digest < eb.digest }
            return ea.millis < eb.millis
        }
        var out: [Scored] = []
        var perDigest: [String: Int] = [:]
        for i in candidates {
            let e = index.entries[i]
            if let cap = perContent {
                let seen = perDigest[e.digest, default: 0]
                if seen >= cap { continue }
                perDigest[e.digest] = seen + 1
            }
            out.append(Scored(row: i, entry: e, score: scores[i]))
            if out.count == k { break }
        }
        return out
    }
}

// MARK: - Builder (the indexer's working copy)

/// Grows an index file by file. Resumable: seeded from the index on disk, it knows what is done.
public struct FrameIndexBuilder: Sendable {
    public let model: String
    public let dims: Int
    private(set) var entries: [FrameIndexEntry]
    private(set) var vectors: [Float]
    private(set) var failures: [String: String]
    private var done: Set<String>
    /// Digests with at least one row.
    private var indexed: Set<String>

    public init(model: String, dims: Int, seed: FrameIndex? = nil) {
        self.model = model
        self.dims = dims
        if let seed, seed.model == model, seed.dims == dims {
            entries = seed.entries
            vectors = seed.vectors
            failures = seed.failures
        } else {
            entries = []
            vectors = []
            failures = [:]
        }
        indexed = Set(entries.map(\.digest))
        done = indexed.union(failures.keys)
    }

    /// True when the content has rows or a recorded failure (a resume skips it).
    public func isDone(_ digest: String) -> Bool { done.contains(digest) }

    public var frameCount: Int { entries.count }

    /// Add one content's frames. Each vector must have `dims` floats; it is stored normalised.
    /// A content already done is skipped whole; within one call a repeated key is kept once (same key = same vector).
    public mutating func add(digest: String, frames: [(seconds: Double, vector: [Float])]) {
        guard !indexed.contains(digest) else { return }
        var seen = Set<Int64>()
        for frame in frames where frame.vector.count == dims {
            let entry = FrameIndexEntry(digest: digest, seconds: frame.seconds)
            guard seen.insert(entry.millis).inserted else { continue }
            entries.append(entry)
            vectors.append(contentsOf: FrameIndex.normalized(frame.vector))
        }
        if !seen.isEmpty { indexed.insert(digest) }
        failures[digest] = nil
        done.insert(digest)
    }

    public mutating func fail(digest: String, reason: String) {
        failures[digest] = String(reason.prefix(300))
        done.insert(digest)
    }

    public func snapshot() -> FrameIndex {
        FrameIndex(model: model, dims: dims, entries: entries, vectors: vectors, failures: failures)
    }
}

// MARK: - On disk

/// What a load found.
public enum FrameIndexStatus: Sendable, Equatable {
    /// No index for this model in the folder.
    case notBuilt
    /// Something is there but it cannot be trusted (the reason in words). Shown as "index not built".
    case unreadable(String)
    case ready(FrameIndex)

    public var index: FrameIndex? { if case .ready(let i) = self { return i } else { return nil } }
}

public enum FrameIndexStore {

    public static let formatVersion = 1
    static let sidecarName = "index.json"

    /// `~/Library/Application Support/VideoScan/observations/siglip2` (the model's folder goes under it).
    public static var productionRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("VideoScan/observations/siglip2", isDirectory: true)
    }

    /// The model's own folder: its repo id with `/` → `--` (the HF cache's spelling).
    public static func directory(root: URL, model: String) -> URL {
        root.appendingPathComponent(model.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    struct Sidecar: Codable {
        var format: Int
        var model: String
        var dims: Int
        var count: Int
        var vectorsFile: String
        var savedAt: Double
        var entries: [FrameIndexEntry]
        var failures: [String: String]
    }

    /// Read the index for `model` under `root`. Never throws: every problem is a status.
    public static func load(root: URL, model: String) -> FrameIndexStatus {
        let dir = directory(root: root, model: model)
        let sidecarURL = dir.appendingPathComponent(sidecarName)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return .notBuilt }
        let sidecar: Sidecar
        do {
            sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: sidecarURL))
        } catch {
            return .unreadable("the index's sidecar does not parse (\(error.localizedDescription))")
        }
        guard sidecar.format == formatVersion else { return .unreadable("index format \(sidecar.format), this build reads \(formatVersion)") }
        guard sidecar.model == model else { return .unreadable("the index was made by \(sidecar.model), not \(model)") }
        guard sidecar.dims > 0, sidecar.count == sidecar.entries.count else {
            return .unreadable("the sidecar names \(sidecar.count) frames but lists \(sidecar.entries.count)")
        }
        guard ["vectors-a.f16", "vectors-b.f16"].contains(sidecar.vectorsFile) else { return .unreadable("unknown matrix file \(sidecar.vectorsFile)") }
        let data: Data
        do {
            data = try Data(contentsOf: dir.appendingPathComponent(sidecar.vectorsFile), options: .mappedIfSafe)
        } catch {
            return .unreadable("the matrix file cannot be read (\(error.localizedDescription))")
        }
        let expected = sidecar.count * sidecar.dims * 2
        guard data.count == expected else {
            return .unreadable("the matrix is \(data.count) bytes; \(sidecar.count) frames × \(sidecar.dims) need \(expected)")
        }
        let floats = halfToFloat(data, count: sidecar.count * sidecar.dims)
        guard !floats.contains(where: { !$0.isFinite }) else { return .unreadable("the matrix holds a non-finite value") }
        return .ready(FrameIndex(model: sidecar.model, dims: sidecar.dims, entries: sidecar.entries, vectors: floats, failures: sidecar.failures))
    }

    /// Write the index (crash-safe: the matrix to the generation the current sidecar does not name, then the sidecar atomically).
    public static func save(_ index: FrameIndex, root: URL, now: Date = Date()) throws {
        let dir = directory(root: root, model: index.model)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sidecarURL = dir.appendingPathComponent(sidecarName)
        var current: String?
        if let data = try? Data(contentsOf: sidecarURL), let old = try? JSONDecoder().decode(Sidecar.self, from: data) { current = old.vectorsFile }
        let next = current == "vectors-a.f16" ? "vectors-b.f16" : "vectors-a.f16"
        try floatToHalf(index.vectors).write(to: dir.appendingPathComponent(next), options: .atomic)
        let sidecar = Sidecar(format: formatVersion, model: index.model, dims: index.dims, count: index.count, vectorsFile: next,
                              savedAt: now.timeIntervalSince1970, entries: index.entries, failures: index.failures)
        try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic)
    }

    // MARK: Half floats (vImage: portable, no Float16 type needed on the 13.0 floor)

    static func floatToHalf(_ floats: [Float]) -> Data {
        guard !floats.isEmpty else { return Data() }
        var out = Data(count: floats.count * 2)
        floats.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(floats.count), rowBytes: floats.count * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(floats.count), rowBytes: floats.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
        }
        return out
    }

    static func halfToFloat(_ data: Data, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 2)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
        }
        return out
    }
}
