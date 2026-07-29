// PreviewDiskCacheLockLocationTests.swift
// Regression sensor for the Stage-1 cross-process write lock: the advisory
// lockfile must live OUTSIDE the cache root, so a directory listing of the
// payload area is EXACTLY the payloads — nothing else. The app's
// PreviewDiskCache*Tests (now exercising the moved-to-Core type) assert exact
// directory contents with contentsOfDirectory(atPath:) (which does NOT skip
// hidden files); a lockfile in the root would fail them. This pins the fix at
// the Core level where it can run fast and hermetically.

import XCTest
import CoreGraphics
@testable import VideoScanCore

final class PreviewDiskCacheLockLocationTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lockloc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testWritesLeaveExactlyThePayloadsInTheRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let img = PreviewCLITestSupport.solidCGImage()

        cache.store(img, path: "/v/a.mov", mtime: 1, size: 1, tier: .best)
        cache.storeFilmstrip((0..<3).map { (Double($0) + 0.5, PreviewCLITestSupport.solidCGImage()) },
                             path: "/v/a.mkv", mtime: 1, size: 1)

        // contentsOfDirectory(atPath:) does NOT skip hidden files — a lockfile
        // in the root would show up here.
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents.count, 4, "exactly 1 best + 3 strip frames, no lockfile: \(contents)")
        XCTAssertFalse(contents.contains { $0.contains("lock") },
                       "no lock artifact may appear in the cache root")
    }

    func testOversizedOffsetPublishesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let img = PreviewCLITestSupport.solidCGImage()

        cache.storeFilmstrip([(Double.greatestFiniteMagnitude, img)], path: "/v/h.mkv", mtime: 1, size: 1)
        cache.storeFilmstrip([(0.5, img), (previewMaxSaneDurationSeconds + 1, img)],
                             path: "/v/h.mkv", mtime: 1, size: 1)
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(contents.isEmpty, "oversized-offset stores must publish nothing, found: \(contents)")
    }

    func testLockfileIsNotUnderTheCacheRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        cache.store(PreviewCLITestSupport.solidCGImage(), path: "/v/a.mov", mtime: 1, size: 1, tier: .best)
        // The lock lives in the OS temp dir keyed by the root path — never
        // inside the root. (Nothing named like a lock in the root.)
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents[0].hasSuffix("-best.jpg"))
    }
}
