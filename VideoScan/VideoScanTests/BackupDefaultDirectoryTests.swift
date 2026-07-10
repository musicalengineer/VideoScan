import Testing
import Foundation
@testable import VideoScan

// Covers VideoScanModel.defaultBackupDirectory — the pure helper that
// pre-aims the Back Up Catalog… save panel at the last backup's parent
// folder (2026-07 backup-badge simplification: badge click and ⌘E share
// exportBundleViaPanel, so repeat backups should be click → Return →
// done). All filesystem probing happens in per-test temp dirs; the
// helper is nonisolated and takes an injected FileManager, so no
// UserDefaults or model state is touched.
@Suite struct BackupDefaultDirectoryTests {

    /// Fresh temp directory per test; caller cleans up.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupDefaultDirTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    @Test func nilPathGivesNil() {
        #expect(VideoScanModel.defaultBackupDirectory(lastBackupPath: nil) == nil)
    }

    @Test func emptyPathGivesNil() {
        #expect(VideoScanModel.defaultBackupDirectory(lastBackupPath: "") == nil)
    }

    @Test func existingParentDirectoryIsReturned() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The bundle itself doesn't need to exist — only its parent
        // folder does (the previous bundle may have been moved/renamed
        // but the destination folder is still the right default).
        let bundlePath = dir.appendingPathComponent("VideoScan_M4_2026-07-01.videoscanbundle").path
        let result = VideoScanModel.defaultBackupDirectory(lastBackupPath: bundlePath)
        #expect(result?.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func missingParentDirectoryGivesNil() throws {
        let dir = try makeTempDir()
        try FileManager.default.removeItem(at: dir)

        // Parent folder is gone (ejected drive / deleted folder) — the
        // panel must fall back to its own default, not point nowhere.
        let bundlePath = dir.appendingPathComponent("gone.videoscanbundle").path
        #expect(VideoScanModel.defaultBackupDirectory(lastBackupPath: bundlePath) == nil)
    }

    @Test func parentThatIsAFileGivesNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Degenerate case: something occupies the parent path but it's a
        // plain file, not a directory — NSSavePanel can't open there.
        let filePath = dir.appendingPathComponent("not-a-folder")
        try Data().write(to: filePath)
        let bundlePath = filePath.appendingPathComponent("x.videoscanbundle").path
        #expect(VideoScanModel.defaultBackupDirectory(lastBackupPath: bundlePath) == nil)
    }
}
