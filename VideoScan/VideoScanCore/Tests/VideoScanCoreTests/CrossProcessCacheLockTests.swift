// CrossProcessCacheLockTests.swift
// Concurrency/isolation dimension for Stage 1: with the app AND the CLI both
// alive, two writers hit the SAME cache dir. PreviewDiskCache now guards every
// write with an advisory FILE lock (flock LOCK_EX on a hidden lockfile) in
// ADDITION to its in-process NSLock. These pin that concurrent writers never
// corrupt a payload or a strip set: every published tier payload decodes and
// every strip key resolves to a COMPLETE set (never a torn/partial one).
//
// Two concurrent Swift tasks each open their own fd and flock — a different
// open-file-description per call, so the flock genuinely serializes them
// (the same mechanism that serializes two processes). A truly two-process run
// is exercised by-hand (app + CLI share the dir); this is the automated,
// fast, deterministic sensor.

import XCTest
import CoreGraphics
@testable import VideoScanCore

final class CrossProcessCacheLockTests: XCTestCase {

    private func makeCacheDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xproc-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Many concurrent tier + filmstrip stores to one cache — everything must
    /// read back intact.
    func testConcurrentWritersProduceNoCorruption() async throws {
        let dir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two independent cache handles over the SAME directory — modeling the
        // app and the CLI each holding their own PreviewDiskCache instance.
        let cacheA = PreviewDiskCache(rootURL: dir)
        let cacheB = PreviewDiskCache(rootURL: dir)

        let keyCount = 40
        let img = PreviewCLITestSupport.solidCGImage()
        func strip() -> [(offsetSeconds: Double, image: CGImage)] {
            (0..<8).map { (Double($0) * 0.5 + 0.1, PreviewCLITestSupport.solidCGImage()) }
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<keyCount {
                let path = "/writerA/file-\(i).mov"
                group.addTask {
                    _ = cacheA.store(img, path: path, mtime: 1000, size: Int64(i + 1), tier: .best)
                    _ = cacheA.storeFilmstrip(strip(), path: path, mtime: 1000, size: Int64(i + 1))
                }
            }
            for i in 0..<keyCount {
                let path = "/writerB/file-\(i).mov"
                group.addTask {
                    _ = cacheB.store(img, path: path, mtime: 2000, size: Int64(i + 1), tier: .best)
                    _ = cacheB.storeFilmstrip(strip(), path: path, mtime: 2000, size: Int64(i + 1))
                }
            }
            // Both writers contend on the SAME keys too (last-writer-wins, but
            // never a torn/partial payload).
            for i in 0..<keyCount {
                let path = "/shared/file-\(i).mov"
                group.addTask {
                    _ = cacheA.store(img, path: path, mtime: 3000, size: Int64(i + 1), tier: .best)
                }
                group.addTask {
                    _ = cacheB.storeFilmstrip(strip(), path: path, mtime: 3000, size: Int64(i + 1))
                }
            }
        }

        // Verify every writer-A/B entry: best decodes AND strip is complete.
        for (prefix, mtime) in [("/writerA", TimeInterval(1000)), ("/writerB", TimeInterval(2000))] {
            for i in 0..<keyCount {
                let path = "\(prefix)/file-\(i).mov"
                let size = Int64(i + 1)
                XCTAssertNotNil(cacheA.lookup(path: path, mtime: mtime, size: size),
                                "best payload torn/missing for \(path)")
                XCTAssertNotNil(cacheA.lookupFilmstrip(path: path, mtime: mtime, size: size),
                                "strip set incomplete/torn for \(path)")
            }
        }
        // Shared keys: both a best still and a complete strip landed.
        for i in 0..<keyCount {
            let path = "/shared/file-\(i).mov"
            let size = Int64(i + 1)
            XCTAssertNotNil(cacheA.lookup(path: path, mtime: 3000, size: size),
                            "shared best payload torn/missing for \(path)")
            XCTAssertNotNil(cacheA.lookupFilmstrip(path: path, mtime: 3000, size: size),
                            "shared strip set incomplete/torn for \(path)")
        }

        // No orphaned temp files should survive a clean run (rename consumed
        // them); the lockfile is hidden and excluded from listings.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("tmp-") },
                       "no crashed-write temp files should remain")
    }
}
