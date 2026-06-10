import Testing
import Foundation
@testable import VideoScan

// MARK: - MediaPairComparator tests (2026-06-10)
//
// Quick Two-File Check ("Compare These Two Files…"). The engine was
// deliberately layered so the decision logic is pure:
//
//   - PairCompareLogic.parseStreamHashes — ffmpeg streamhash stdout parser
//   - PairCompareLogic.streamContentMatches — per-type digest multiset compare
//   - PairCompareLogic.verdict — tier evidence → verdict fold
//   - PairCompareLogic.metadataDiff — side-by-side VideoRecord field diff
//
// Plus two I/O helpers testable with tiny temp files (no media fixtures):
//
//   - MediaPairComparator.fileSize(atPath:)
//   - MediaPairComparator.sha256OfFile(atPath:...) — chunked async hasher
//
// Per the project's safety-critical testing policy, every behavior gets
// positive AND negative coverage — especially "empty never matches",
// which is the difference between "identical" and "we hashed nothing".
//
// (Swift Testing notes for C++ readers: `#expect(x == y)` ≈ EXPECT_EQ;
// `#expect(throws:)` ≈ EXPECT_THROW; `@Suite`/`@Test` ≈ test fixtures
// and TEST_F, but each @Test gets a fresh struct instance.)

// MARK: - Stream hash parsing

@Suite("PairCompareLogic.parseStreamHashes")
struct ParseStreamHashesTests {

    typealias StreamHash = PairCompareLogic.StreamHash

    // Positive: a normal two-stream file (video + audio).
    @Test func wellFormedMultiStreamOutput() {
        let output = """
        0,v,SHA256=58f8c2fabc123
        1,a,SHA256=99aa00bb
        """
        let hashes = PairCompareLogic.parseStreamHashes(output)
        #expect(hashes == [
            StreamHash(index: 0, type: "v", digest: "58f8c2fabc123"),
            StreamHash(index: 1, type: "a", digest: "99aa00bb"),
        ])
    }

    // Negative: garbage lines interleaved must be skipped, valid kept.
    @Test func garbageLinesAreSkipped() {
        let output = """
        this is not a hash line
        0,v,SHA256=aaaa

        not,enough
        x,v,SHA256=bbbb
        1,a,SHA256=cccc
        ,,,
        """
        let hashes = PairCompareLogic.parseStreamHashes(output)
        #expect(hashes == [
            StreamHash(index: 0, type: "v", digest: "aaaa"),
            StreamHash(index: 1, type: "a", digest: "cccc"),
        ])
    }

    // Negative: empty input yields nothing (and must not crash).
    @Test func emptyStringYieldsNoHashes() {
        #expect(PairCompareLogic.parseStreamHashes("").isEmpty)
        #expect(PairCompareLogic.parseStreamHashes("\n\n   \n").isEmpty)
    }

    // Negative: a line whose third segment has no "=" is malformed.
    @Test func lineWithoutEqualsIsSkipped() {
        let hashes = PairCompareLogic.parseStreamHashes("0,v,SHA256aaaa")
        #expect(hashes.isEmpty)
    }

    // Positive: uppercase hex (and type letter) are normalized to lowercase.
    @Test func uppercaseDigestAndTypeNormalized() {
        let hashes = PairCompareLogic.parseStreamHashes("0,V,SHA256=ABCDEF0123")
        #expect(hashes == [StreamHash(index: 0, type: "v", digest: "abcdef0123")])
    }

    // Positive: "=" characters inside the digest segment survive, because
    // the comma split uses maxSplits and the digest is taken as everything
    // after the FIRST "=". (Base64-style padding defensiveness.)
    @Test func equalsInsideDigestPreserved() {
        let hashes = PairCompareLogic.parseStreamHashes("0,v,SHA256=ab=cd==")
        #expect(hashes == [StreamHash(index: 0, type: "v", digest: "ab=cd==")])
    }

    // Positive: surrounding whitespace on a line is tolerated.
    @Test func whitespacePaddedLineParses() {
        let hashes = PairCompareLogic.parseStreamHashes("  1 , a , SHA256=ff00  ")
        #expect(hashes == [StreamHash(index: 1, type: "a", digest: "ff00")])
    }
}

// MARK: - Stream content matching

@Suite("PairCompareLogic.streamContentMatches")
struct StreamContentMatchesTests {

    typealias StreamHash = PairCompareLogic.StreamHash

    private func sh(_ index: Int, _ type: String, _ digest: String) -> StreamHash {
        StreamHash(index: index, type: type, digest: digest)
    }

    // Positive: identical stream sets match.
    @Test func identicalSetsMatch() {
        let a = [sh(0, "v", "aaa"), sh(1, "a", "bbb")]
        let b = [sh(0, "v", "aaa"), sh(1, "a", "bbb")]
        #expect(PairCompareLogic.streamContentMatches(a, b))
    }

    // Positive: a rewrap that reorders streams (audio before video, new
    // indexes) still matches — comparison is order-independent per type.
    @Test func reorderedStreamsStillMatch() {
        let a = [sh(0, "v", "aaa"), sh(1, "a", "bbb")]
        let b = [sh(0, "a", "bbb"), sh(1, "v", "aaa")]
        #expect(PairCompareLogic.streamContentMatches(a, b))
    }

    // Negative: same digests under DIFFERENT type letters must not match —
    // a video stream's bytes showing up as an audio stream is not "same".
    @Test func sameDigestsDifferentTypesDoNotMatch() {
        let a = [sh(0, "v", "aaa"), sh(1, "a", "bbb")]
        let b = [sh(0, "v", "bbb"), sh(1, "a", "aaa")]
        #expect(!PairCompareLogic.streamContentMatches(a, b))
    }

    // Negative: one differing digest means different media.
    @Test func differingDigestDoesNotMatch() {
        let a = [sh(0, "v", "aaa"), sh(1, "a", "bbb")]
        let b = [sh(0, "v", "aaa"), sh(1, "a", "ccc")]
        #expect(!PairCompareLogic.streamContentMatches(a, b))
    }

    // Negative (safety-critical): "we couldn't hash anything" must NEVER
    // read as "identical". Empty vs non-empty and empty vs empty.
    @Test func emptyInputsNeverMatch() {
        let a = [sh(0, "v", "aaa")]
        #expect(!PairCompareLogic.streamContentMatches([], a))
        #expect(!PairCompareLogic.streamContentMatches(a, []))
        #expect(!PairCompareLogic.streamContentMatches([], []))
    }

    // Negative: duplicate digests per type require matching multiplicity —
    // two identical audio streams on one side vs one on the other is a
    // real structural difference (multiset, not set, semantics).
    @Test func duplicateDigestMultiplicityMustMatch() {
        let twoAudio = [sh(0, "v", "vvv"), sh(1, "a", "ddd"), sh(2, "a", "ddd")]
        let oneAudio = [sh(0, "v", "vvv"), sh(1, "a", "ddd")]
        #expect(!PairCompareLogic.streamContentMatches(twoAudio, oneAudio))
        #expect(!PairCompareLogic.streamContentMatches(oneAudio, twoAudio))
    }

    // Positive companion to the above: equal multiplicity DOES match,
    // even with reordered indexes.
    @Test func equalDuplicateMultiplicityMatches() {
        let a = [sh(0, "v", "vvv"), sh(1, "a", "ddd"), sh(2, "a", "ddd")]
        let b = [sh(0, "a", "ddd"), sh(1, "a", "ddd"), sh(2, "v", "vvv")]
        #expect(PairCompareLogic.streamContentMatches(a, b))
    }
}

// MARK: - Verdict fold

@Suite("PairCompareLogic.verdict")
struct VerdictTests {

    // Table-driven over the tier truth table. `nil` = "tier didn't run"
    // (Tier 1 skipped on size mismatch; Tier 2 skipped after byte match).
    struct Case: CustomStringConvertible {
        let sizes: Bool
        let bytes: Bool?
        let streams: Bool?
        let expected: PairCompareVerdict
        var description: String {
            "sizes=\(sizes) bytes=\(String(describing: bytes)) "
            + "streams=\(String(describing: streams)) → \(expected.title)"
        }
    }

    static let table: [Case] = [
        // Byte-identical files: strongest claim, Tier 2 never runs.
        Case(sizes: true, bytes: true, streams: nil, expected: .exactDuplicates),
        // Same size, different bytes, but identical stream content → rewrap.
        Case(sizes: true, bytes: false, streams: true, expected: .sameContentDifferentContainer),
        // Different size (Tier 1 skipped) but stream content matches → rewrap.
        Case(sizes: false, bytes: nil, streams: true, expected: .sameContentDifferentContainer),
        // Different sizes, different streams → genuinely different.
        Case(sizes: false, bytes: nil, streams: false, expected: .differentMedia),
        // Same size coincidence, different bytes, different streams.
        Case(sizes: true, bytes: false, streams: false, expected: .differentMedia),
        // Nil stream evidence must NOT be promoted to a match.
        Case(sizes: true, bytes: false, streams: nil, expected: .differentMedia),
        Case(sizes: false, bytes: nil, streams: nil, expected: .differentMedia),
    ]

    @Test(arguments: table)
    func truthTable(_ c: Case) {
        let v = PairCompareLogic.verdict(sizesMatch: c.sizes,
                                         bytesMatch: c.bytes,
                                         streamsMatch: c.streams)
        #expect(v == c.expected, "\(c)")
    }

    // Negative guard: byte equality alone (without size equality) must not
    // claim exact duplicates — different-size files can't be byte-identical,
    // so this combination indicates a logic error upstream; the fold should
    // still not over-claim.
    @Test func bytesTrueWithoutSizesTrueIsNotExact() {
        let v = PairCompareLogic.verdict(sizesMatch: false,
                                         bytesMatch: true,
                                         streamsMatch: false)
        #expect(v != .exactDuplicates)
    }
}

// MARK: - Metadata diff

@Suite("PairCompareLogic.metadataDiff")
struct MetadataDiffTests {

    /// Two fully-populated records that should read as identical.
    private func makeRecord() -> VideoRecord {
        let r = VideoRecord()
        r.duration = "0:01:30"
        r.durationSeconds = 90
        r.videoCodec = "DV"
        r.audioCodec = "PCM"
        r.resolution = "720x480"
        r.frameRate = "29.97"
        r.totalBitrate = "28.8 Mb/s"
        r.dateCreated = "1995-06-30"
        r.container = "QuickTime"
        r.ext = "mov"
        r.size = "1.2 GB"
        r.sizeBytes = 1_288_490_189
        return r
    }

    private func row(_ rows: [PairCompareLogic.MetadataDiffRow],
                     _ label: String) -> PairCompareLogic.MetadataDiffRow? {
        rows.first { $0.label == label }
    }

    // Positive baseline: identical records → no row flagged.
    @Test func identicalRecordsHaveNoDifferingRows() {
        let rows = PairCompareLogic.metadataDiff(makeRecord(), makeRecord())
        #expect(!rows.isEmpty)
        for r in rows {
            #expect(!r.differs, "Row '\(r.label)' flagged on identical records")
        }
    }

    // Whitespace- or case-only differences are normalization noise, not
    // real metadata differences.
    @Test func whitespaceAndCaseOnlyDifferenceNotFlagged() {
        let a = makeRecord()
        let b = makeRecord()
        b.videoCodec = "  dv "
        b.audioCodec = "pcm"
        let rows = PairCompareLogic.metadataDiff(a, b)
        #expect(row(rows, "Picture codec")?.differs == false)
        #expect(row(rows, "Sound codec")?.differs == false)
    }

    // Negative (the trap the design comment calls out): rounded display
    // sizes can collide ("1.2 GB" both) while the byte counts differ.
    // The File size row must compare sizeBytes, not the display string.
    @Test func sameDisplaySizeDifferentBytesIsFlagged() {
        let a = makeRecord()
        let b = makeRecord()
        b.sizeBytes = a.sizeBytes + 1   // same "1.2 GB" string, different bytes
        let rows = PairCompareLogic.metadataDiff(a, b)
        #expect(row(rows, "File size")?.differs == true)
    }

    // Positive companion: identical sizeBytes with identical display → same.
    @Test func sameBytesNotFlagged() {
        let rows = PairCompareLogic.metadataDiff(makeRecord(), makeRecord())
        #expect(row(rows, "File size")?.differs == false)
    }

    // Empty-vs-value is a genuine difference (and renders as "—" vs value).
    @Test func emptyVersusValueIsFlagged() {
        let a = makeRecord()
        let b = makeRecord()
        a.duration = ""
        let rows = PairCompareLogic.metadataDiff(a, b)
        let lengthRow = row(rows, "Length")
        #expect(lengthRow?.differs == true)
        #expect(lengthRow?.valueA == "—")
        #expect(lengthRow?.valueB == "0:01:30")
    }

    // Empty-vs-empty is "we know nothing about either" — NOT a difference.
    @Test func emptyVersusEmptyNotFlagged() {
        let a = makeRecord()
        let b = makeRecord()
        a.frameRate = ""
        b.frameRate = ""
        let rows = PairCompareLogic.metadataDiff(a, b)
        let frRow = row(rows, "Frame rate")
        #expect(frRow?.differs == false)
        #expect(frRow?.valueA == "—")
        #expect(frRow?.valueB == "—")
    }

    // File type falls back to the uppercased extension when the container
    // string is empty — same logical container must not be flagged just
    // because one record predates container probing.
    @Test func fileTypeUsesExtensionFallback() {
        let a = makeRecord()
        let b = makeRecord()
        a.container = ""
        a.ext = "mxf"
        b.container = ""
        b.ext = "mxf"
        let rows = PairCompareLogic.metadataDiff(a, b)
        let ft = row(rows, "File type")
        #expect(ft?.differs == false)
        #expect(ft?.valueA == "MXF")
    }
}

// MARK: - File I/O helpers (tiny temp files, not media fixtures)

@Suite("MediaPairComparator file helpers")
struct MediaPairComparatorFileTests {

    // Canonical NIST SHA-256 test vectors.
    private static let sha256OfABC =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private static let sha256OfEmpty =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Make a unique temp file with the given bytes; caller cleans up the
    /// returned directory via defer.
    private func makeTempFile(_ data: Data) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pair-compare-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("blob.bin")
        try data.write(to: file)
        return (dir, file)
    }

    /// Thread-safe progress recorder; the hash callback is @Sendable.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int64] = []
        func record(_ v: Int64) {
            lock.lock(); defer { lock.unlock() }
            _values.append(v)
        }
        var values: [Int64] {
            lock.lock(); defer { lock.unlock() }
            return _values
        }
    }

    // MARK: fileSize

    @Test func fileSizeReturnsExactByteCount() async throws {
        let (dir, file) = try makeTempFile(Data(repeating: 0x41, count: 1234))
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = try await MediaPairComparator.fileSize(atPath: file.path)
        #expect(size == 1234)
    }

    @Test func fileSizeThrowsForMissingFile() async {
        await #expect(throws: PairCompareError.self) {
            _ = try await MediaPairComparator.fileSize(
                atPath: "/nonexistent/pair-compare-\(UUID().uuidString).bin")
        }
    }

    // MARK: sha256OfFile — digest correctness

    // "abc" hashed with chunkSize 2 exercises BOTH the known-vector check
    // and a file whose length (3) is not a multiple of the chunk size.
    @Test func sha256MatchesKnownVectorAcrossChunkBoundary() async throws {
        let (dir, file) = try makeTempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: dir) }
        let digest = try await MediaPairComparator.sha256OfFile(
            atPath: file.path,
            chunkSize: 2,                  // chunks of 2 + trailing 1 byte
            progressGranularity: 1,
            onBytesHashed: { _ in })
        #expect(digest == Self.sha256OfABC)
    }

    @Test func sha256OfEmptyFileMatchesKnownVector() async throws {
        let (dir, file) = try makeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: dir) }
        let digest = try await MediaPairComparator.sha256OfFile(
            atPath: file.path,
            chunkSize: 1024,
            progressGranularity: 1,
            onBytesHashed: { _ in })
        #expect(digest == Self.sha256OfEmpty)
    }

    // Chunking must be an implementation detail: any chunk size yields the
    // same digest, including a non-divisor of the file length.
    @Test func sha256IsChunkSizeIndependent() async throws {
        // 1000 bytes of varied content; 1000 % 64 != 0, 1000 % 333 != 0.
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        let (dir, file) = try makeTempFile(data)
        defer { try? FileManager.default.removeItem(at: dir) }

        var digests: Set<String> = []
        for chunkSize in [64, 333, 1000, 4096] {
            let d = try await MediaPairComparator.sha256OfFile(
                atPath: file.path,
                chunkSize: chunkSize,
                progressGranularity: .max,  // suppress mid-stream callbacks
                onBytesHashed: { _ in })
            digests.insert(d)
        }
        #expect(digests.count == 1,
                "Digest varied with chunk size: \(digests)")
    }

    // Negative: different content must produce a different digest (guards
    // against a hasher that ignores its input).
    @Test func sha256DiffersForDifferentContent() async throws {
        let (dirA, fileA) = try makeTempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: dirA) }
        let (dirB, fileB) = try makeTempFile(Data("abd".utf8))
        defer { try? FileManager.default.removeItem(at: dirB) }
        let dA = try await MediaPairComparator.sha256OfFile(
            atPath: fileA.path, chunkSize: 1024,
            progressGranularity: 1, onBytesHashed: { _ in })
        let dB = try await MediaPairComparator.sha256OfFile(
            atPath: fileB.path, chunkSize: 1024,
            progressGranularity: 1, onBytesHashed: { _ in })
        #expect(dA != dB)
    }

    @Test func sha256ThrowsForMissingFile() async {
        await #expect(throws: PairCompareError.self) {
            _ = try await MediaPairComparator.sha256OfFile(
                atPath: "/nonexistent/pair-compare-\(UUID().uuidString).bin",
                chunkSize: 1024,
                progressGranularity: 1,
                onBytesHashed: { _ in })
        }
    }

    // MARK: sha256OfFile — progress contract

    // Callbacks must be monotonically non-decreasing and the final call
    // must report the full byte count (the UI derives the bar from this).
    @Test func sha256ProgressIsMonotonicAndEndsAtTotal() async throws {
        let totalBytes = 1000
        let data = Data((0..<totalBytes).map { UInt8($0 % 256) })
        let (dir, file) = try makeTempFile(data)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = ProgressRecorder()
        _ = try await MediaPairComparator.sha256OfFile(
            atPath: file.path,
            chunkSize: 64,               // many chunks
            progressGranularity: 128,    // callback roughly every 2 chunks
            onBytesHashed: { recorder.record($0) })

        let values = recorder.values
        #expect(!values.isEmpty, "Expected at least the final progress callback")
        #expect(values == values.sorted(),
                "Progress went backwards: \(values)")
        #expect(values.last == Int64(totalBytes),
                "Final progress \(String(describing: values.last)) != file size \(totalBytes)")
        // Mid-stream callbacks should exist with this granularity (1000/128).
        #expect(values.count > 1,
                "Expected mid-stream progress callbacks, got only \(values)")
    }

    // Even when granularity suppresses every mid-stream callback, the
    // final full-byte-count callback must still fire.
    @Test func sha256FinalCallbackFiresDespiteLargeGranularity() async throws {
        let (dir, file) = try makeTempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ProgressRecorder()
        _ = try await MediaPairComparator.sha256OfFile(
            atPath: file.path,
            chunkSize: 1024,
            progressGranularity: .max,
            onBytesHashed: { recorder.record($0) })
        #expect(recorder.values == [3])
    }
}
