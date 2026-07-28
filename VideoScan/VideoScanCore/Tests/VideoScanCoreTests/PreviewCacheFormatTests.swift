// PreviewCacheFormatTests.swift
// GOLDEN sensor for the preview cache-key + filename contract that the
// app AND the future out-of-process helper share (PreviewCacheFormat.swift).
//
// The point of the golden: `previewCacheKey` names every payload on Rick's
// warmed disk cache. If ANY future edit changes the digest, the whole
// cache silently misses and re-rips — so the exact hex string is pinned
// here. A drift fails loudly instead of quietly invalidating the cache.

import XCTest
@testable import VideoScanCore

final class PreviewCacheFormatTests: XCTestCase {

    // MARK: - Golden cache key

    func testGoldenCacheKey() {
        // SHA256 of the literal material "path|mtime|size":
        //   "/Volumes/LaCie/Home/1998/birthday.mov|902934000|734003200"
        // Independently reproducible:
        //   printf '%s' '/Volumes/LaCie/Home/1998/birthday.mov|902934000|734003200' | shasum -a 256
        let key = previewCacheKey(path: "/Volumes/LaCie/Home/1998/birthday.mov",
                                  mtime: 902_934_000,
                                  size: 734_003_200)
        XCTAssertEqual(
            key,
            "861c9251e8c95031d3e4f8eb327e1eb32d52417034ac84a0eee3d7c14e48028e",
            "cache-key derivation drifted — Rick's warmed preview cache would silently miss"
        )
    }

    func testCacheKeyTruncatesSubSecondMtime() {
        // Whole-second truncation is part of the contract (SMB vs APFS
        // mtime granularity). 902934000.0 and 902934000.999 key the same.
        let a = previewCacheKey(path: "/x/y.mov", mtime: 902_934_000.0, size: 10)
        let b = previewCacheKey(path: "/x/y.mov", mtime: 902_934_000.999, size: 10)
        XCTAssertEqual(a, b)
    }

    // MARK: - Tier filename round-trip

    func testTierFilenameRoundTrip() {
        for tier in PreviewCacheTier.allCases {
            let name = previewTierFilename(key: "abc123", tier: tier)
            let parsed = previewParseTierFilename(name)
            XCTAssertEqual(parsed?.key, "abc123")
            XCTAssertEqual(parsed?.tier, tier)
        }
        XCTAssertNil(previewParseTierFilename("abc123-strip-0-of-4-500.jpg"),
                     "strip payloads must not parse as tier payloads")
        XCTAssertNil(previewParseTierFilename("-best.jpg"), "empty key rejected")
        XCTAssertNil(previewParseTierFilename("tmp-1234"), "junk rejected")
    }

    // MARK: - Strip filename round-trip + guards

    func testStripFilenameRoundTrip() {
        let name = previewStripFilename(key: "k9", index: 3, count: 16, offsetMillis: 4200)
        let parsed = previewParseStripFilename(name)
        XCTAssertEqual(parsed?.key, "k9")
        XCTAssertEqual(parsed?.index, 3)
        XCTAssertEqual(parsed?.count, 16)
        XCTAssertEqual(parsed?.offsetMillis, 4200)
    }

    func testStripFilenameRejectsInsaneAndMalformed() {
        // Index >= count.
        XCTAssertNil(previewParseStripFilename("k-strip-4-of-4-100.jpg"))
        // Offset past the sane ceiling (the SIGTRAP guard).
        let insane = previewMaxStripOffsetMillis + 1
        XCTAssertNil(previewParseStripFilename("k-strip-0-of-4-\(insane).jpg"))
        // Missing "of".
        XCTAssertNil(previewParseStripFilename("k-strip-0-x-4-100.jpg"))
        // Empty key.
        XCTAssertNil(previewParseStripFilename("-strip-0-of-4-100.jpg"))
    }
}
