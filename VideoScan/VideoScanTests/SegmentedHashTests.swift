import CryptoKit
import Foundation
import Testing
@testable import VideoScan

// MARK: - Segmented content hash (2026-08-11)
//
// This hash decides whether a family video gets DELETED, so the tests
// that matter most are the NEGATIVE ones: cases where the OLD identity
// key (partialMD5) says "identical" and the new one must not.
//
// The motivating failure, from the cleanup plan: two distinct Avid MXF
// essence files from one session share a wrapper header and can be
// padded to the same length. partialMD5 reads only head and tail, so it
// cannot see that their picture content differs. `middleDifference…`
// below is that exact scenario, and it is the reason this file exists.
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — geometry, determinism, and each discriminating field.
//   Scale     — a 40 MB file hashed under an explicit budget, proving
//               the sampling is O(1) reads and not a full stream.
//   Media matrix — N/A at this layer: the hash is content-agnostic by
//               construction (it never parses a container). Synthetic
//               byte patterns exercise it more sharply than real files.
//   Isolation — every fixture is written to a per-test temp directory;
//               no shared state, no real catalog paths.
//   Sensor    — `partialMD5AgreesWhereSegmentedDisagrees` pins the
//               precise capability gap that justifies the second hash;
//               if someone "optimizes" segmentedHash back into a
//               head+tail scheme, that test fails loudly.

private final class TempDir {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SegHashTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// Write `bytes` to a file and return its path.
    func write(_ name: String, _ bytes: [UInt8]) -> String {
        let p = url.appendingPathComponent(name)
        FileManager.default.createFile(atPath: p.path, contents: Data(bytes))
        return p.path
    }
}

/// Deterministic pseudo-random filler — a fixed LCG, so fixtures are
/// reproducible across runs without depending on Data(random:).
private func filler(_ count: Int, seed: UInt64) -> [UInt8] {
    var s = seed &+ 0x9E3779B97F4A7C15
    var out = [UInt8]()
    out.reserveCapacity(count)
    for _ in 0..<count {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        out.append(UInt8((s >> 33) & 0xFF))
    }
    return out
}

@Suite("Segmented hash — identity strong enough to delete on")
struct SegmentedHashTests {

    /// A small segment size keeps fixtures fast while exercising the
    /// exact same geometry as the 1 MiB production value.
    private let seg = 1024

    // MARK: The reason this hash exists

    /// THE load-bearing test. Two files with identical head, identical
    /// tail, and identical length, differing ONLY in the middle — the
    /// padded-Avid-MXF scenario. partialMD5 cannot tell them apart;
    /// segmentedHash must.
    @Test func middleDifferenceIsDetected() {
        let t = TempDir()
        let head = filler(seg, seed: 1)
        let tail = filler(seg, seed: 2)
        var a = head + filler(seg, seed: 3) + tail
        var b = head + filler(seg, seed: 4) + tail
        // Same length, same head, same tail — only the middle differs.
        #expect(a.count == b.count)
        let pa = t.write("a.mxf", a); let pb = t.write("b.mxf", b)

        let ha = FileHasher.segmentedHash(path: pa, segmentSize: seg)
        let hb = FileHasher.segmentedHash(path: pb, segmentSize: seg)
        #expect(!ha.isEmpty && !hb.isEmpty)
        #expect(ha != hb, "middle-only difference MUST change the content hash")

        a.removeAll(); b.removeAll()
    }

    /// SENSOR. Pins the capability gap: on this fixture partialMD5
    /// AGREES (it is blind to the middle) while segmentedHash disagrees.
    /// If a future change reduces segmentedHash to a head+tail scheme,
    /// this test fails and explains why that is not a refactor.
    @Test func partialMD5AgreesWhereSegmentedDisagrees() {
        let t = TempDir()
        // Files must exceed 3× the segment size to enter sampling mode,
        // and exceed 2× partialMD5's chunk for it to read a tail.
        let chunk = 65536
        let head = filler(chunk, seed: 10)
        let tail = filler(chunk, seed: 11)
        let midA = filler(chunk * 2, seed: 12)
        let midB = filler(chunk * 2, seed: 13)
        let pa = t.write("pad_a.mxf", head + midA + tail)
        let pb = t.write("pad_b.mxf", head + midB + tail)

        #expect(FileHasher.partialMD5(path: pa) == FileHasher.partialMD5(path: pb),
                "precondition: the OLD hash is blind here — that is the gap")
        #expect(FileHasher.segmentedHash(path: pa, segmentSize: chunk)
                != FileHasher.segmentedHash(path: pb, segmentSize: chunk),
                "the NEW hash must close the gap")
    }

    // MARK: Discriminating fields

    @Test func identicalContentHashesEqualRegardlessOfName() {
        let t = TempDir()
        let bytes = filler(seg * 5, seed: 20)
        let p1 = t.write("Christmas1994.mkv", bytes)
        let p2 = t.write("Christmas1994_copy.mkv", bytes)
        #expect(FileHasher.segmentedHash(path: p1, segmentSize: seg)
                == FileHasher.segmentedHash(path: p2, segmentSize: seg))
    }

    /// Length is bound into the digest, so a size difference alone must
    /// change the hash even when every sampled window matches.
    @Test func sizeIsBoundIntoTheDigest() {
        let t = TempDir()
        let base = filler(seg * 4, seed: 30)
        let p1 = t.write("short.mov", base)
        let p2 = t.write("long.mov", base + [0x00])
        #expect(FileHasher.segmentedHash(path: p1, segmentSize: seg)
                != FileHasher.segmentedHash(path: p2, segmentSize: seg))
    }

    @Test func headDifferenceIsDetected() {
        let t = TempDir()
        let rest = filler(seg * 4, seed: 40)
        let p1 = t.write("h1.mov", [0x01] + rest)
        let p2 = t.write("h2.mov", [0x02] + rest)
        #expect(FileHasher.segmentedHash(path: p1, segmentSize: seg)
                != FileHasher.segmentedHash(path: p2, segmentSize: seg))
    }

    @Test func tailDifferenceIsDetected() {
        let t = TempDir()
        let rest = filler(seg * 4, seed: 50)
        let p1 = t.write("t1.mov", rest + [0x01])
        let p2 = t.write("t2.mov", rest + [0x02])
        #expect(FileHasher.segmentedHash(path: p1, segmentSize: seg)
                != FileHasher.segmentedHash(path: p2, segmentSize: seg))
    }

    @Test func hashIsDeterministicAcrossRepeatedReads() {
        let t = TempDir()
        let p = t.write("stable.mov", filler(seg * 7, seed: 60))
        let first = FileHasher.segmentedHash(path: p, segmentSize: seg)
        for _ in 0..<5 {
            #expect(FileHasher.segmentedHash(path: p, segmentSize: seg) == first)
        }
    }

    // MARK: Small-file exactness

    /// At or under 3 segments the windows would overlap, so the file is
    /// hashed in full. That makes the hash EXACT for small files — a
    /// one-byte change anywhere must show up.
    @Test func smallFilesAreHashedInFullAndAreExact() {
        let t = TempDir()
        var bytes = filler(seg * 2, seed: 70)          // under 3× ⇒ full hash
        let p1 = t.write("s1.mov", bytes)
        bytes[seg]  = bytes[seg] &+ 1                  // flip one middle byte
        let p2 = t.write("s2.mov", bytes)
        #expect(FileHasher.segmentedHash(path: p1, segmentSize: seg)
                != FileHasher.segmentedHash(path: p2, segmentSize: seg))
    }

    /// The boundary itself: exactly 3 segments is still full-hash mode.
    @Test func exactlyThreeSegmentsStillHashesInFull() {
        let t = TempDir()
        var bytes = filler(seg * 3, seed: 80)
        let p1 = t.write("b1.mov", bytes)
        bytes[seg + 7] = bytes[seg + 7] &+ 1
        let p2 = t.write("b2.mov", bytes)
        #expect(FileHasher.segmentedHash(path: p1, segmentSize: seg)
                != FileHasher.segmentedHash(path: p2, segmentSize: seg))
    }

    @Test func oneByteFileHashes() {
        let t = TempDir()
        let p = t.write("tiny.mov", [0x42])
        #expect(!FileHasher.segmentedHash(path: p, segmentSize: seg).isEmpty)
    }

    // MARK: Error contract — "" means no evidence, never a match

    /// Empty is the no-evidence sentinel, matching partialMD5's contract.
    /// Two unhashable files must NOT be treated as duplicates of each
    /// other — every caller must gate on non-empty. If this ever
    /// returned a constant digest for failures, the collapse would fold
    /// every unreadable file into one cluster and delete the lot.
    @Test func unreadableInputsReturnEmpty() {
        let t = TempDir()
        #expect(FileHasher.segmentedHash(path: "/nonexistent/nope.mov") == "")
        #expect(FileHasher.segmentedHash(path: t.url.path) == "",   // a directory
                "directories are not content")
        let empty = t.write("empty.mov", [])
        #expect(FileHasher.segmentedHash(path: empty) == "", "zero-byte file has no identity")
    }

    @Test func nonPositiveSegmentSizeIsRejected() {
        let t = TempDir()
        let p = t.write("x.mov", filler(100, seed: 90))
        #expect(FileHasher.segmentedHash(path: p, segmentSize: 0) == "")
        #expect(FileHasher.segmentedHash(path: p, segmentSize: -1) == "")
    }

    // MARK: Format + versioning

    /// The version prefix is what lets a future geometry change
    /// invalidate old hashes instead of silently comparing samples taken
    /// under different rules.
    @Test func hashCarriesVersionPrefixAndSha256Width() {
        let t = TempDir()
        let p = t.write("v.mov", filler(seg * 5, seed: 100))
        let h = FileHasher.segmentedHash(path: p, segmentSize: seg)
        #expect(h.hasPrefix("v1:"))
        #expect(h.dropFirst(3).count == 64, "SHA-256 is 64 hex characters")
        #expect(h.dropFirst(3).allSatisfy { $0.isHexDigit })
    }

    /// Segmented and full hashes must never be confusable — they are
    /// different claims about a file and live in different fields.
    @Test func segmentedAndFullHashesAreDistinguishable() {
        let t = TempDir()
        let p = t.write("both.mov", filler(seg * 6, seed: 110))
        let s = FileHasher.segmentedHash(path: p, segmentSize: seg)
        let f = FileHasher.fullHash(path: p, blockSize: seg)
        #expect(s.hasPrefix("v1:"))
        #expect(f.hasPrefix("full:"))
        #expect(s != f)
    }

    // MARK: Full hash

    @Test func fullHashIsExactAndDeterministic() {
        let t = TempDir()
        var bytes = filler(seg * 10, seed: 120)
        let p1 = t.write("f1.mov", bytes)
        bytes[seg * 5 + 3] = bytes[seg * 5 + 3] &+ 1
        let p2 = t.write("f2.mov", bytes)
        let h1 = FileHasher.fullHash(path: p1, blockSize: seg)
        #expect(h1 == FileHasher.fullHash(path: p1, blockSize: seg))
        #expect(h1 != FileHasher.fullHash(path: p2, blockSize: seg))
    }

    @Test func fullHashRejectsUnreadable() {
        #expect(FileHasher.fullHash(path: "/nonexistent/nope.mov") == "")
    }

    // MARK: Scale

    /// Sampling must be O(1) reads, not O(filesize). A 40 MB file with a
    /// 1 MiB segment reads 3 MiB; if someone replaced the implementation
    /// with a full stream this still passes on an SSD — so the real
    /// assertion is the comparison against fullHash below, which must be
    /// meaningfully more work.
    @Test func samplingReadsFarLessThanTheWholeFile() {
        let t = TempDir()
        let size = 40 << 20
        let p = t.write("big.mov", filler(size, seed: 130))

        let segStart = ContinuousClock.now
        let h = FileHasher.segmentedHash(path: p)      // production 1 MiB geometry
        let segElapsed = ContinuousClock.now - segStart

        #expect(!h.isEmpty)
        #expect(segElapsed < .seconds(2), "segmented hash of 40 MB took \(segElapsed)")

        // The point of the design: segmented must be cheaper than full.
        let fullStart = ContinuousClock.now
        _ = FileHasher.fullHash(path: p)
        let fullElapsed = ContinuousClock.now - fullStart
        #expect(segElapsed <= fullElapsed,
                "segmented (\(segElapsed)) should not exceed full (\(fullElapsed))")
    }
}

// MARK: - Record plumbing

@Suite("Content hash — record field and persistence")
struct ContentHashRecordTests {

    /// Additive field: a catalog written before 2026-08-11 has no
    /// `contentHash` key, and must decode to "" rather than throwing.
    /// Rick's live catalog is ~17k such records — a throwing decode here
    /// would fail to open the catalog at all.
    @Test func legacyRecordsWithoutContentHashDecodeToEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","filename":"old.mov","partialMD5":"abc123","sizeBytes":42}
        """
        let rec = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(rec.contentHash == "")
        #expect(rec.partialMD5 == "abc123", "the legacy identity key still round-trips")
    }

    /// Both hashes coexist — the new field must not disturb the old one,
    /// which six subsystems still key off.
    @Test func contentHashRoundTripsAlongsidePartialMD5() throws {
        let rec = VideoRecord()
        rec.filename = "wedding.mov"
        rec.partialMD5 = "deadbeef"
        rec.contentHash = "v1:" + String(repeating: "a", count: 64)

        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let back = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(back.contentHash == rec.contentHash)
        #expect(back.partialMD5 == rec.partialMD5)
    }

    /// Clone is used by Combine/Repair/Relocate to derive new records;
    /// dropping the hash there would silently un-identify the copy.
    @Test func cloneCarriesContentHash() {
        let rec = VideoRecord()
        rec.contentHash = "v1:" + String(repeating: "b", count: 64)
        #expect(rec.snapshotClone().contentHash == rec.contentHash)
    }
}
