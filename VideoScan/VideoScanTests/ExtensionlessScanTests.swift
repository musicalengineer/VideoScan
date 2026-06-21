// ExtensionlessScanTests.swift
// Regression for the catalog discovery gap: files with NO extension (e.g.
// Avid/QuickTime video-only exports like ".../TripAcrossCountry_1995_video-only/
// t2-v") were silently dropped because discovery gated on a media-extension
// allowlist. The "Scan files with no extension" option admits them so ffprobe
// can arbitrate downstream.
//
// Red/green: probeScanDiscoversExtensionless FAILS before the fix (the
// extensionless file isn't discovered) and PASSES after.

import Testing
import Foundation
@testable import VideoScan

@Suite("Extensionless media discovery — Scan files with no extension")
struct ExtensionlessScanTests {

    private let videoExtensions: Set<String> = ["mov", "mp4", "mxf"]

    /// Temp dir holding a media-extension file, an extensionless file (the
    /// t2-v case), and a non-media-extension file.
    private func makeFixture() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_extensionless_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0, count: 16)
        try bytes.write(to: dir.appendingPathComponent("clip.mov"))
        try bytes.write(to: dir.appendingPathComponent("t2-v"))      // no extension — the bug
        try bytes.write(to: dir.appendingPathComponent("notes.txt"))
        return dir
    }

    @Test("Default scan skips the extensionless file (current behavior, preserved)")
    func defaultScanSkipsExtensionless() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: false
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names.contains("clip.mov"))
        #expect(!names.contains("t2-v"))
        #expect(!names.contains("notes.txt"))
    }

    @Test("Extensionless-probe scan discovers the extensionless file (t2-v)")
    func probeScanDiscoversExtensionless() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: true
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names.contains("t2-v"), "extensionless media must be discovered in probe mode")
        // Additive: the normal video allowlist is still honored alongside the
        // extensionless pass. Only the non-media file stays excluded.
        #expect(names.contains("clip.mov"))
        #expect(!names.contains("notes.txt"))
    }
}
