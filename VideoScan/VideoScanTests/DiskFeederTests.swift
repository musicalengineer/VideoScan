import Foundation
import Testing
@testable import VideoScan

@Suite struct DiskFeederTests {

    private func makeTempFiles(count: Int, sizeKB: Int = 64) -> (URL, [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFeederTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(repeating: 0xAB, count: sizeKB * 1024)
        var paths: [String] = []
        for i in 0..<count {
            let file = dir.appendingPathComponent("test_\(i).bin")
            try! data.write(to: file)
            paths.append(file.path)
        }
        return (dir, paths)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Sequential warming

    @Test func warmsAllFilesSequentially() async {
        let (dir, paths) = makeTempFiles(count: 5, sizeKB: 32)
        defer { cleanup(dir) }

        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()

        // Wait for all files — should not hang
        for i in 0..<5 {
            await feeder.waitForWarm(i)
        }

        let warmed = await feeder.bytesWarmed
        // 5 files × 32KB = 160KB
        #expect(warmed >= 5 * 32 * 1024)
        await feeder.cancel()
    }

    @Test func waitForWarmReturnsImmediatelyIfAlreadyWarmed() async {
        let (dir, paths) = makeTempFiles(count: 2, sizeKB: 16)
        defer { cleanup(dir) }

        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()

        // Wait for file 1 (which means file 0 is also done since feeder is sequential)
        await feeder.waitForWarm(1)

        // Now file 0 should return instantly (already warmed)
        let start = CFAbsoluteTimeGetCurrent()
        await feeder.waitForWarm(0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(elapsed < 0.01)
        await feeder.cancel()
    }

    @Test func bytesWarmedMatchesActualFileSizes() async {
        let sizeKB = 128
        let count = 3
        let (dir, paths) = makeTempFiles(count: count, sizeKB: sizeKB)
        defer { cleanup(dir) }

        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()

        for i in 0..<count {
            await feeder.waitForWarm(i)
        }

        let warmed = await feeder.bytesWarmed
        let expected = UInt64(count * sizeKB * 1024)
        #expect(warmed == expected)
        await feeder.cancel()
    }

    // MARK: - Cancellation

    @Test func cancelReleasesBlockedWaiters() async {
        let (dir, paths) = makeTempFiles(count: 100, sizeKB: 256)
        defer { cleanup(dir) }

        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        // Don't start the feeder — waiters will block

        // Spawn a waiter for file 99 (feeder hasn't started, so it blocks)
        let waiterDone = ManagedAtomic(false)
        let waiterTask = Task {
            await feeder.waitForWarm(99)
            waiterDone.store(true)
        }

        // Give a moment for the waiter to register
        try? await Task.sleep(for: .milliseconds(50))
        #expect(waiterDone.load() == false)

        // Cancel should release the waiter
        await feeder.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(waiterDone.load() == true)
        waiterTask.cancel()
    }

    // MARK: - VolumeSpeed detection

    @Test func internalVolumeDetectedAsFast() {
        // The root filesystem on Apple Silicon is always internal SSD
        let speed = VolumeSpeed.detect(path: "/Applications")
        #expect(speed == .fast)
    }

    @Test func tmpVolumeDetectedAsFast() {
        let speed = VolumeSpeed.detect(path: NSTemporaryDirectory())
        #expect(speed == .fast)
    }

    // MARK: - Empty file list

    @Test func emptyFileListCompletesImmediately() async {
        let feeder = DiskFeeder(files: [], budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()
        let warmed = await feeder.bytesWarmed
        #expect(warmed == 0)
        await feeder.cancel()
    }

    // MARK: - Nonexistent files are skipped gracefully

    @Test func nonexistentFilesSkipped() async {
        let paths = ["/tmp/nonexistent_\(UUID().uuidString).bin"]
        let feeder = DiskFeeder(files: paths, budgetBytes: 1 * 1024 * 1024 * 1024)
        await feeder.start()
        await feeder.waitForWarm(0)
        let warmed = await feeder.bytesWarmed
        #expect(warmed == 0)
        await feeder.cancel()
    }
}

// Minimal lock-free atomic for test synchronization
private final class ManagedAtomic<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    func store(_ value: T) { lock.lock(); _value = value; lock.unlock() }
    func load() -> T { lock.lock(); defer { lock.unlock() }; return _value }
}
