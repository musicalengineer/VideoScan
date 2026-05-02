import Testing
import Foundation
@testable import VideoScan

// MARK: - AsyncSemaphore Tests

struct AsyncSemaphoreTests {

    @Test func basicWaitAndSignal() async {
        let sem = AsyncSemaphore(limit: 2)
        await sem.wait()
        await sem.wait()
        await sem.signal()
        await sem.signal()
        await sem.wait()
        await sem.signal()
    }

    @Test func concurrencyLimiting() async {
        let sem = AsyncSemaphore(limit: 3)
        let counter = TestCounter()
        let iterations = 20

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await sem.withPermit {
                        let current = await counter.increment()
                        #expect(current <= 3, "Semaphore allowed more than 3 concurrent tasks")
                        try? await Task.sleep(for: .milliseconds(5))
                        await counter.decrement()
                    }
                }
            }
        }
    }
}

// MARK: - MemoryPressureMonitor Tests

struct MemoryPressureMonitorTests {

    @Test func availableMemoryReturnsNonZero() {
        let mem = MemoryPressureMonitor.shared.availableMemory()
        #expect(mem > 0, "availableMemory should return positive value on a running system")
    }

    @Test func availableMemoryStringFormats() {
        let str = MemoryPressureMonitor.shared.availableMemoryString()
        #expect(str.hasSuffix("GB") || str.hasSuffix("MB"),
                "Expected memory string to end with GB or MB, got: \(str)")
    }

    @Test func setFloorGB() async {
        await MemoryPressureMonitor.shared.setFloorGB(8)
        let threshold = await MemoryPressureMonitor.shared.thresholdBytes()
        #expect(threshold == 8 * 1024 * 1024 * 1024)
        await MemoryPressureMonitor.shared.setFloorGB(4)
    }
}

// MARK: - PauseGate Tests

struct PauseGateTests {

    @Test func initiallyNotPaused() async {
        let gate = PauseGate()
        let paused = await gate.isPaused
        #expect(paused == false)
    }

    @Test func pauseAndResume() async {
        let gate = PauseGate()
        await gate.pause()
        #expect(await gate.isPaused == true)
        await gate.resume()
        #expect(await gate.isPaused == false)
    }

    @Test func toggle() async {
        let gate = PauseGate()
        let result1 = await gate.toggle()
        #expect(result1 == true)
        let result2 = await gate.toggle()
        #expect(result2 == false)
    }

    @Test func waitIfPausedReturnsImmediatelyWhenNotPaused() async {
        let gate = PauseGate()
        await gate.setAutoPause(false)
        await gate.waitIfPaused()
    }
}

// MARK: - pfFindVideoFiles Tests

struct VideoDiscoveryTests {

    @Test func findsVideoFilesInDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScanTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.appendingPathComponent("clip.mov").path, contents: Data([0]))
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("clip.mp4").path, contents: Data([0]))
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("photo.jpg").path, contents: Data([0]))
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("readme.txt").path, contents: Data([0]))

        let found = pfFindVideoFiles(at: tmp.path, skipBundles: false)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.hasSuffix(".mov") || $0.hasSuffix(".mp4") })
    }

    @Test func returnsEmptyForNonexistentPath() {
        let found = pfFindVideoFiles(at: "/nonexistent/path/\(UUID())", skipBundles: false)
        #expect(found.isEmpty)
    }

    @Test func singleFileInput() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScanTest_\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let found = pfFindVideoFiles(at: tmp.path, skipBundles: false)
        #expect(found.count == 1)
        #expect(found[0] == tmp.path)
    }

    @Test func skipsSystemDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScanTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let trashDir = tmp.appendingPathComponent(".Trashes")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.appendingPathComponent("good.mov").path, contents: Data([0]))
        FileManager.default.createFile(atPath: trashDir.appendingPathComponent("hidden.mov").path, contents: Data([0]))

        let found = pfFindVideoFiles(at: tmp.path, skipBundles: false)
        #expect(found.count == 1)
        #expect(found[0].contains("good.mov"))
    }
}

// MARK: - VolumeReachability Tests

struct VolumeReachabilityTests {

    @Test func emptyPathIsUnreachable() {
        #expect(VolumeReachability.isReachable(path: "") == false)
    }

    @Test func nonexistentPathIsUnreachable() {
        #expect(VolumeReachability.isReachable(path: "/Volumes/NoSuchVolume_\(UUID())") == false)
    }

    @Test func existingPathIsReachable() {
        #expect(VolumeReachability.isReachable(path: NSTemporaryDirectory()) == true)
    }

    @Test func volumeNameFromVolumePath() {
        #expect(VolumeReachability.volumeName(forPath: "/Volumes/MediaArchive/clips/foo.mov") == "MediaArchive")
        #expect(VolumeReachability.volumeName(forPath: "/Volumes/Backup") == "Backup")
    }

    @Test func volumeNameFromLocalPath() {
        let name = VolumeReachability.volumeName(forPath: "/Users/rick/videos/clip.mov")
        #expect(name == "clip.mov")
    }
}

// MARK: - Memory Pressure Free Function Tests

struct MemoryPressureFunctionTests {

    @Test func totalPhysicalMemoryIsPositive() {
        #expect(totalPhysicalMemoryGB() > 0)
    }

    @Test func usedMemoryIsPositive() {
        #expect(usedMemoryGB() > 0)
    }

    @Test func processResidentMemoryIsPositive() {
        #expect(processResidentMemoryMB() > 0)
    }

    @Test func cpuLoadReturnsThreeValues() {
        let load = systemCPULoadAverage()
        #expect(load.one >= 0)
        #expect(load.five >= 0)
        #expect(load.fifteen >= 0)
    }

    @Test func thermalStateReturnsLabel() {
        let state = systemThermalState()
        #expect(!state.label.isEmpty)
    }
}

// MARK: - VideoScanModel Volume Tests

@MainActor
struct VolumeRootTests {

    @Test func volumePathExtraction() {
        let model = VideoScanModel()
        #expect(model.volumeRoot(for: "/Volumes/MyDrive/folder/file.mov") == "/Volumes/MyDrive")
        #expect(model.volumeRoot(for: "/Volumes/Backup/deep/nested/file.mxf") == "/Volumes/Backup")
    }

    @Test func nonVolumePath() {
        let model = VideoScanModel()
        let result = model.volumeRoot(for: "/Users/test/Videos/file.mov")
        #expect(result == "/Users/test/Videos")
    }
}

// MARK: - CatalogScanTarget Tests

@MainActor
struct CatalogScanTargetStatusExtendedTests {

    @Test func scanTargetInitialState() {
        let target = CatalogScanTarget(searchPath: NSTemporaryDirectory())
        #expect(target.searchPath == NSTemporaryDirectory())
        #expect(target.status == .idle)
        #expect(target.filesFound == 0)
        #expect(target.filesScanned == 0)
        #expect(target.isReachable == true)
    }

    @Test func scanTargetOfflineVolume() {
        let target = CatalogScanTarget(searchPath: "/Volumes/NoSuchVolume_\(UUID())")
        #expect(target.status == .idle)
        #expect(target.isReachable == false)
    }
}

// MARK: - TestMediaGenerator Tests

struct TestMediaGeneratorTests {

    @Test func ffmpegAvailable() {
        #expect(TestMediaGenerator.isAvailable, "ffmpeg must be installed for media generation tests")
    }

    @Test func generateVideoAndAudio() throws {
        guard TestMediaGenerator.isAvailable else { return }
        let path = try TestMediaGenerator.generate(container: "mp4", streams: .videoAndAudio, duration: 2.0)
        defer { TestMediaGenerator.cleanup(path) }

        #expect(FileManager.default.fileExists(atPath: path))
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        #expect(size > 1000, "Generated file should have meaningful content, got \(size) bytes")
    }

    @Test func generateVideoOnly() throws {
        guard TestMediaGenerator.isAvailable else { return }
        let path = try TestMediaGenerator.generate(container: "mp4", streams: .videoOnly, duration: 2.0)
        defer { TestMediaGenerator.cleanup(path) }

        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func generateAudioOnly() throws {
        guard TestMediaGenerator.isAvailable else { return }
        let path = try TestMediaGenerator.generate(container: "wav", streams: .audioOnly, duration: 2.0)
        defer { TestMediaGenerator.cleanup(path) }

        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func generateMXFVideoAndWAVAudio() throws {
        guard TestMediaGenerator.isAvailable else { return }
        let (video, audio) = try TestMediaGenerator.createPair(
            videoCodec: "mpeg2video",
            audioCodec: "pcm_s16le",
            videoContainer: "mxf",
            audioContainer: "wav",
            duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(video, audio) }

        #expect(FileManager.default.fileExists(atPath: video))
        #expect(FileManager.default.fileExists(atPath: audio))
    }

    @Test func generatedFileProbesCorrectly() async throws {
        guard TestMediaGenerator.isAvailable else { return }
        let path = try TestMediaGenerator.generate(container: "mov", streams: .videoAndAudio, duration: 3.0)
        defer { TestMediaGenerator.cleanup(path) }

        let model = await VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse generated MOV: \(stderr)")
    }

    @Test func cleanupRemovesFiles() throws {
        guard TestMediaGenerator.isAvailable else { return }
        let path = try TestMediaGenerator.generate(container: "mp4", streams: .videoOnly, duration: 1.0)
        #expect(FileManager.default.fileExists(atPath: path))

        TestMediaGenerator.cleanup(path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
