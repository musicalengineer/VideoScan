// AudioCatalogIndex.swift (VideoScanCore)
// ONE SENTENCE: one inverted index over EVERY comparable sound print in the
// sidecar — landmark hash → (which content, at which frame) — so "which
// contents could share this file's sound?" is a few lookups instead of
// 5,000 pair matches (design provenance_retroactive_2026_10_26 §Phase A).
//
// It never gives a verdict. It only lets `AudioMasterFinder` choose which
// pairs to ask; the verdict is always `AudioFingerprintIndex.match` (rule 4).
//
// SHAPE: compressed sparse rows (CSR). `offsets` has one UInt32 per possible
// hash (the hash is 24 bits: f1 9 | f2 9 | dt 6) plus one; the postings of
// hash h are `postings[offsets[h] ..< offsets[h+1]]`. Built by counting
// sort in two keyset-paged passes over the sidecar — pass 1 counts per
// hash, pass 2 fills — so the decoded prints are never all in memory at
// once, and there is no per-hash heap array (unlike `AudioFingerprintIndex`,
// whose dictionary of arrays costs ≈ 60–70 B per landmark).
// (For Rick: `std::vector<uint32_t> offsets(1<<24 + 1)` plus one flat
// `std::vector<Posting>`, filled by the decrement-cursor counting sort.)
//
// What is NOT indexed, and is counted in `BuildReport` instead:
//   • a key that is not "sha256:" (a sampled "v1:" hash is a hint, never
//     identity — rule 6);
//   • a print made by another recipe (its hashes mean something else);
//   • a print with fewer than `minLandmarks` landmarks (can never reach the
//     matcher's 20-landmark floor);
//   • a blob that will not decode, or carries a hash ≥ 2^24 (that print is
//     refused, never the build), or changed between the two passes.
//
// MEMORY (worst case, documented per CLAUDE.md): `offsets` 2^24 × 4 B =
// 67 MB fixed, plus 8 B per posting, plus ≈ 40 B per document. Today's
// sidecar, 25.1 M landmarks → ≈ 268 MB; twice today's archive ≈ 470 MB. A
// hard cap, `defaultMaxPostings` = 100 M (≈ 867 MB), REFUSES the build with
// the MB figure rather than grow without bound. Transient during the build:
// one page of blobs (≤ 16 MB, AudioFingerprintStore.maxPageBytes) and one
// decoded print. Freed when the job drops the index.

import Foundation

public struct AudioCatalogIndex: Sendable {

    /// One indexed content. Its ordinal is its position in `documents`.
    public struct Document: Sendable, Equatable {
        public let key: AudioFingerprintStore.Key
        public let durationSeconds: Double
        public let complete: Bool
        /// Landmarks posted for this content (0 = refused in pass 2: it
        /// changed or stopped decoding between the passes; never matched).
        public let landmarks: Int
    }

    public struct BuildReport: Sendable, Equatable {
        public var indexed = 0
        public var landmarks = 0
        /// 'v1:' (sampled) keys: a hint, never identity (rule 6).
        public var notWholeFileKey = 0
        /// Made by another recipe: not comparable.
        public var otherRecipe = 0
        /// < minLandmarks: can never match.
        public var tooFewLandmarks = 0
        /// Blob failed to decode, carried a hash ≥ 2^24, or changed between
        /// the passes; listed by key in `unreadableKeys`.
        public var unreadable = 0
        public var unreadableKeys: [AudioFingerprintStore.Key] = []
        /// Rows visited in pass 1.
        public var rowsRead = 0
        public init() {}
    }

    /// Why a build was refused. Every case is a sentence.
    public enum BuildFailure: Error, Equatable, Sendable, CustomStringConvertible {
        /// No sidecar file yet: nothing has been fingerprinted.
        case noSidecar(path: String)
        /// The postings would pass the cap.
        case tooLarge(postings: Int, cap: Int, megabytes: Int)

        public var description: String {
            switch self {
            case .noSidecar(let path):
                return "there are no sound prints yet (no \(AudioFingerprintStore.fileName) at \(path)) — run Fingerprint Sound"
            case .tooLarge(let postings, let cap, let megabytes):
                return "the sound index would need \(megabytes) MB (\(postings) landmarks; the cap is \(cap)) — refused rather than grow without bound"
            }
        }
    }

    /// One (content, anchor frame) pair. 8 bytes.
    public struct Posting: Sendable, Equatable {
        public let document: UInt32
        public let frame: UInt32
        public init(document: UInt32, frame: UInt32) {
            self.document = document
            self.frame = frame
        }
        /// A slot reserved in pass 1 and never filled in pass 2 (its print
        /// changed in between). Readers skip it.
        public static let unfilled = Posting(document: .max, frame: 0)
    }

    /// The hash space: 24 bits.
    public static let hashSpace = 1 << 24
    /// ≈ 867 MB of postings + offsets.
    public static let defaultMaxPostings = 100_000_000
    public static let bytesPerPosting = MemoryLayout<Posting>.stride
    static let offsetsBytes = (hashSpace + 1) * MemoryLayout<UInt32>.stride

    public let recipeID: UInt32
    public let documents: [Document]
    private let offsets: [UInt32]
    private let postingStore: [Posting]
    private let ordinals: [AudioFingerprintStore.Key: Int]

    public var postingCount: Int { postingStore.count }

    /// The postings of `hash` (empty for a hash outside the 24-bit space).
    public func postings(of hash: UInt32) -> ArraySlice<Posting> {
        guard Int(hash) < Self.hashSpace else { return [] }
        return postingStore[Int(offsets[Int(hash)]) ..< Int(offsets[Int(hash) + 1])]
    }

    /// Number of postings of `hash`, without touching them.
    public func postingCount(of hash: UInt32) -> Int {
        guard Int(hash) < Self.hashSpace else { return 0 }
        return Int(offsets[Int(hash) + 1] &- offsets[Int(hash)])
    }

    public func ordinal(of key: AudioFingerprintStore.Key) -> Int? { ordinals[key] }

    /// Documents that can be matched (landmarks > 0).
    public var searchableCount: Int { documents.reduce(0) { $0 + ($1.landmarks > 0 ? 1 : 0) } }

    /// MB the index would hold for `postings` (offsets + postings).
    public static func megabytes(forPostings postings: Int) -> Int {
        (offsetsBytes + postings * bytesPerPosting + (1 << 20) - 1) >> 20
    }

    // MARK: Open (refuses before reading)

    /// The sidecar in `directory`, opened only when the file EXISTS — this
    /// index is a reader, so it never creates an empty sidecar. Throws
    /// `BuildFailure.noSidecar` or the store's named `Failure` (not
    /// writable, not a database, newer schema) before any row is read.
    public static func openSidecar(directory: URL) throws -> AudioFingerprintStore {
        let file = directory.appendingPathComponent(AudioFingerprintStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BuildFailure.noSidecar(path: directory.path)
        }
        return try AudioFingerprintStore(directory: directory)
    }

    // MARK: Build

    /// A source of rows: calls its argument once per row, in a STABLE order
    /// (the same rows in the same order on both passes, apart from rows a
    /// concurrent writer adds — those are ignored by pass 2). The argument
    /// returns false to stop.
    public typealias RowSource = ((AudioFingerprintStore.Key, Result<AudioFingerprint, Error>) throws -> Bool) throws -> Void

    /// Build from the sidecar (two keyset-paged passes, lock per page).
    /// `progress(rowsDone, rowsTotal)` counts both passes; `isCancelled` is
    /// asked once per row and may BLOCK (the job's pause gate) — a true
    /// answer throws `CancellationError`.
    public static func build(store: AudioFingerprintStore,
                             recipeID: UInt32 = AudioFingerprintParameters.default.recipeID,
                             minLandmarks: Int = AudioMatchPolicy.default.minMatchedLandmarks,
                             maxPostings: Int = defaultMaxPostings,
                             progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                             isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> (AudioCatalogIndex, BuildReport) {
        let rows = try store.count(engineVersion: Int(AudioFingerprint.currentVersion))
        return try build(rows: { body in try store.forEachFingerprint(body) }, expectedRows: rows,
                         recipeID: recipeID, minLandmarks: minLandmarks, maxPostings: maxPostings,
                         progress: progress, isCancelled: isCancelled)
    }

    /// Build from any row source (tests feed crafted rows).
    public static func build(rows: RowSource, expectedRows: Int,
                             recipeID: UInt32 = AudioFingerprintParameters.default.recipeID,
                             minLandmarks: Int = AudioMatchPolicy.default.minMatchedLandmarks,
                             maxPostings: Int = defaultMaxPostings,
                             progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                             isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> (AudioCatalogIndex, BuildReport) {
        let total = max(1, expectedRows) * 2
        var census = Census(recipeID: recipeID, minLandmarks: minLandmarks)
        var done = 0
        // Pass 1: decide which prints are indexed, count postings per hash.
        try rows { key, result in
            guard !isCancelled() else { throw CancellationError() }
            census.admit(key: key, result: result)
            done += 1
            progress(min(done, total), total)
            return true
        }
        guard census.postings <= maxPostings else {
            throw BuildFailure.tooLarge(postings: census.postings, cap: maxPostings,
                                        megabytes: megabytes(forPostings: census.postings))
        }
        // Inclusive prefix sum: counts[h] = END of bucket h.
        var offsets = census.counts
        census.counts = []
        var running: UInt32 = 0
        for h in 0..<hashSpace {
            running &+= offsets[h]
            offsets[h] = running
        }
        offsets[hashSpace] = running
        var postings = [Posting](repeating: .unfilled, count: Int(running))
        var landmarks = census.documents.map(\.landmarks)
        var filled = [Bool](repeating: false, count: landmarks.count)
        // Pass 2: fill by decrementing each bucket's cursor; afterwards
        // offsets[h] is the START of bucket h and offsets[h+1] its end.
        done = expectedRows
        try rows { key, result in
            guard !isCancelled() else { throw CancellationError() }
            done += 1
            progress(min(done, total), total)
            guard let ordinal = census.ordinals[key], !filled[ordinal] else { return true }
            filled[ordinal] = true
            guard case .success(let print) = result, print.landmarkCount == landmarks[ordinal],
                  Census.checksum(print.hashes) == census.checksums[ordinal] else {
                landmarks[ordinal] = 0      // slots stay `.unfilled`; never matched
                census.report.unreadable += 1
                census.report.unreadableKeys.append(key)
                return true
            }
            let doc = UInt32(ordinal)
            for (hash, frame) in zip(print.hashes, print.times) {
                offsets[Int(hash)] -= 1
                postings[Int(offsets[Int(hash)])] = Posting(document: doc, frame: frame)
            }
            return true
        }
        // A row pass 1 counted and pass 2 never saw: its slots stay unfilled.
        for i in filled.indices where !filled[i] && landmarks[i] > 0 {
            landmarks[i] = 0
            census.report.unreadable += 1
            census.report.unreadableKeys.append(census.documents[i].key)
        }
        let documents = census.documents.enumerated().map { i, d in
            Document(key: d.key, durationSeconds: d.durationSeconds, complete: d.complete, landmarks: landmarks[i])
        }
        var report = census.report
        report.indexed = documents.reduce(0) { $0 + ($1.landmarks > 0 ? 1 : 0) }
        report.landmarks = documents.reduce(0) { $0 + $1.landmarks }
        let index = AudioCatalogIndex(recipeID: recipeID, documents: documents, offsets: offsets,
                                      postingStore: postings, ordinals: census.ordinals)
        return (index, report)
    }

    /// Pass 1's bookkeeping: which rows are admitted and how many postings
    /// each hash will hold.
    private struct Census {
        let recipeID: UInt32
        let minLandmarks: Int
        var counts = [UInt32](repeating: 0, count: AudioCatalogIndex.hashSpace + 1)
        var documents: [Document] = []
        var checksums: [UInt64] = []
        var ordinals: [AudioFingerprintStore.Key: Int] = [:]
        var postings = 0
        var report = BuildReport()

        init(recipeID: UInt32, minLandmarks: Int) {
            self.recipeID = recipeID
            self.minLandmarks = minLandmarks
        }

        mutating func admit(key: AudioFingerprintStore.Key, result: Result<AudioFingerprint, Error>) {
            report.rowsRead += 1
            guard AudioFingerprintStamp.isFullDigest(key.contentDigest) else { report.notWholeFileKey += 1; return }
            guard ordinals[key] == nil else { return }
            guard case .success(let print) = result, print.hashes.allSatisfy({ Int($0) < AudioCatalogIndex.hashSpace }) else {
                report.unreadable += 1
                report.unreadableKeys.append(key)
                return
            }
            let reference = AudioFingerprintParameters.default
            guard print.recipeID == recipeID, print.sampleRate == reference.sampleRate,
                  print.hopSamples == reference.hopSamples, print.frameSize == reference.frameSize else {
                report.otherRecipe += 1
                return
            }
            guard print.landmarkCount >= minLandmarks else { report.tooFewLandmarks += 1; return }
            for hash in print.hashes { counts[Int(hash)] &+= 1 }
            ordinals[key] = documents.count
            documents.append(Document(key: key, durationSeconds: print.durationSeconds,
                                      complete: print.complete, landmarks: print.landmarkCount))
            checksums.append(Self.checksum(print.hashes))
            postings += print.landmarkCount
        }

        /// FNV-1a over the hashes: pass 2 fills a document only when its
        /// print is the one pass 1 counted (a re-`put` with other landmarks
        /// would otherwise spill into a neighbour's bucket).
        static func checksum(_ hashes: [UInt32]) -> UInt64 {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            for value in hashes {
                h ^= UInt64(value)
                h = h &* 0x0000_0100_0000_01B3
            }
            return h
        }
    }
}
