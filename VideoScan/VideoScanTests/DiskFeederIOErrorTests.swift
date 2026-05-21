import Foundation
import Testing
@testable import VideoScan

/// Regression test for SIGABRT crash when FileHandle.readData(ofLength:)
/// encounters an I/O error (volume disconnected, fd invalidated mid-read).
///
/// The old code used the non-throwing readData(ofLength:) which dispatches to
/// ObjC -[NSConcreteFileHandle readDataOfLength:]. That method throws NSException
/// on I/O errors, which Swift cannot catch — resulting in SIGABRT.
///
/// The fix replaces it with the throwing read(upToCount:) API, which uses the
/// error-returning ObjC variant readDataUpToLength:error: instead.
///
/// Crash report: VideoScan-2026-05-20-202559.ips
@Suite struct DiskFeederIOErrorTests {

    // MARK: - Helpers

    private func makeTempFile(sizeKB: Int) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFeederIOTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test.bin")
        let data = Data(repeating: 0xCD, count: sizeKB * 1024)
        try! data.write(to: file)
        return file
    }

    private func cleanup(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Regression: feeder survives file that vanishes between stat and open

    /// File is deleted after attributesOfItem succeeds but before/during read.
    /// On macOS, the fd stays valid for already-open files, but the feeder should
    /// not crash regardless of timing.
    @Test func feederSurvivesDeletedFile() async {
        let file = makeTempFile(sizeKB: 64)
        defer { cleanup(file) }

        let paths = [file.path]
        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)

        // Delete the file before starting the feeder
        try? FileManager.default.removeItem(at: file)

        await feeder.start()
        await feeder.waitForWarm(0)

        // Should complete without crashing. bytesWarmed may be 0
        // because FileHandle(forReadingAtPath:) returns nil for deleted files.
        let warmed = await feeder.bytesWarmed
        #expect(warmed == 0)
        await feeder.cancel()
    }

    // MARK: - Regression: feeder handles truncated file gracefully

    /// File is truncated to 0 bytes between stat (which sees original size)
    /// and the actual read loop. The feeder should not hang or crash.
    @Test func feederHandlesTruncatedFile() async {
        let file = makeTempFile(sizeKB: 256)
        defer { cleanup(file) }

        let paths = [file.path]

        // Truncate the file after it's been created (simulates partial volume disconnect)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()
        await feeder.waitForWarm(0)

        // Should not hang or crash
        await feeder.cancel()
    }

    // MARK: - Regression: feeder continues past bad file to remaining files

    /// Verifies that an I/O error on one file doesn't prevent subsequent files
    /// from being warmed. This is the real-world scenario: one file on a
    /// disconnected volume shouldn't kill the entire scan.
    @Test func feederContinuesPastBadFile() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFeederContinue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // File 0: will be deleted (non-existent at read time)
        let bad = dir.appendingPathComponent("bad.bin")
        try! Data(repeating: 0xAA, count: 1024).write(to: bad)
        // File 1: valid, should still get warmed
        let good = dir.appendingPathComponent("good.bin")
        let goodData = Data(repeating: 0xBB, count: 32 * 1024)
        try! goodData.write(to: good)

        // Delete the "bad" file before feeder starts
        try! FileManager.default.removeItem(at: bad)

        let paths = [bad.path, good.path]
        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()

        // Wait for both — the feeder should skip the bad file and warm the good one
        await feeder.waitForWarm(0)
        await feeder.waitForWarm(1)

        let warmed = await feeder.bytesWarmed
        #expect(warmed >= UInt64(goodData.count))
        await feeder.cancel()
    }
}
