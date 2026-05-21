import Foundation
import Testing
@testable import VideoScan

// regression: crash VideoScan-2026-05-20-202559.ips
//
// FileHandle.readData(ofLength:) bridges to ObjC
// -[NSConcreteFileHandle readDataOfLength:] which throws NSException
// on I/O errors. Swift can't catch NSException → SIGABRT.
//
// Fix: use try fh.read(upToCount:) which bridges to the error-returning
// ObjC variant and produces a catchable Swift Error.
@Suite struct DiskFeederIOErrorTests {

    nonisolated static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    // ── Core proof: bad-fd read throws catchable error ──────────────

    /// Simulate a volume disconnect by closing the fd under the FileHandle.
    /// read(upToCount:) must throw a catchable Swift Error, not crash.
    /// This is the exact condition from the crash report.
    @Test func readUpToCountThrowsOnClosedFD() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-test-\(UUID().uuidString).bin")
        try Data(repeating: 0xAB, count: 64 * 1024).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fh = try #require(FileHandle(forReadingAtPath: tmp.path))

        // Pull the rug: close the fd, simulating volume disconnect mid-read
        close(fh.fileDescriptor)

        // read(upToCount:) must throw, not SIGABRT
        #expect(throws: (any Error).self) {
            _ = try fh.read(upToCount: 4096)
        }
    }

    /// Prove the OLD API (readData(ofLength:)) crashes on a closed fd.
    /// We run it in a subprocess so SIGABRT doesn't kill our test runner.
    @Test func readDataOfLengthCrashesOnClosedFD() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-crash-\(UUID().uuidString).bin")
        try Data(repeating: 0xAB, count: 64 * 1024).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Swift snippet that opens the file, closes the fd, then calls
        // the old readData(ofLength:) API. This should SIGABRT.
        let script = """
        import Foundation
        let fh = FileHandle(forReadingAtPath: "\(tmp.path)")!
        close(fh.fileDescriptor)
        let _ = fh.readData(ofLength: 4096)
        exit(0)
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        // SIGABRT = termination status is signal-based, not 0.
        // On macOS, uncaught NSException → abort() → exit status != 0.
        let status = proc.terminationStatus
        #expect(status != 0, "readData(ofLength:) on closed fd should crash (got exit \(status))")
    }

    // ── Integration: DiskFeeder survives I/O errors ─────────────────

    @Test(.disabled(if: isCI, "DiskFeeder memory-pressure check skips files on 7GB CI runner"))
    func feederSurvivesDeletedFile() async {
        let file = makeTempFile(sizeKB: 64)
        defer { cleanup(file) }

        try? FileManager.default.removeItem(at: file)

        let feeder = DiskFeeder(files: [file.path], budgetBytes: 1_073_741_824)
        await feeder.start()
        await feeder.waitForWarm(0)

        let warmed = await feeder.bytesWarmed
        #expect(warmed == 0)
        await feeder.cancel()
    }

    @Test(.disabled(if: isCI, "DiskFeeder memory-pressure check skips files on 7GB CI runner"))
    func feederContinuesPastBadFile() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFeederContinue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bad = dir.appendingPathComponent("bad.bin")
        try! Data(repeating: 0xAA, count: 1024).write(to: bad)
        let good = dir.appendingPathComponent("good.bin")
        let goodData = Data(repeating: 0xBB, count: 32 * 1024)
        try! goodData.write(to: good)

        try! FileManager.default.removeItem(at: bad)

        let feeder = DiskFeeder(files: [bad.path, good.path], budgetBytes: 1_073_741_824)
        await feeder.start()
        await feeder.waitForWarm(0)
        await feeder.waitForWarm(1)

        let warmed = await feeder.bytesWarmed
        #expect(warmed >= UInt64(goodData.count))
        await feeder.cancel()
    }

    // ── Helpers ─────────────────────────────────────────────────────

    private func makeTempFile(sizeKB: Int) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFeederIOTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test.bin")
        try! Data(repeating: 0xCD, count: sizeKB * 1024).write(to: file)
        return file
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
