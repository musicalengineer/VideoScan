import Testing
import Foundation
@testable import VideoScan

// MARK: - VolumeKeepalive Tests

@Suite("VolumeKeepalive")
struct VolumeKeepaliveTests {

    @Test func startsAndStopsCleanly() async {
        let ka = VolumeKeepalive(volumePath: NSTemporaryDirectory()) { _ in }
        let gate = PauseGate()
        await ka.start(pauseGate: gate)
        try? await Task.sleep(for: .milliseconds(100))
        let isDown = await ka.volumeIsDown
        #expect(!isDown)
        await ka.stop()
    }

    @Test func reachableVolumeStaysUp() async {
        let ka = VolumeKeepalive(
            volumePath: NSTemporaryDirectory(),
            pollInterval: 0.1,
            recoveryPollInterval: 0.05
        ) { _ in }
        let gate = PauseGate()
        await ka.start(pauseGate: gate)
        try? await Task.sleep(for: .milliseconds(300))
        let isDown = await ka.volumeIsDown
        #expect(!isDown)
        let isPaused = await gate.isPaused
        #expect(!isPaused)
        await ka.stop()
    }

    @Test func unreachableVolumeDetected() async {
        var logMessages: [String] = []
        let ka = VolumeKeepalive(
            volumePath: "/Volumes/NoSuchVolume_\(UUID().uuidString)",
            pollInterval: 0.1,
            recoveryPollInterval: 0.05
        ) { msg in logMessages.append(msg) }
        let gate = PauseGate()
        await ka.start(pauseGate: gate)
        try? await Task.sleep(for: .milliseconds(300))
        let isDown = await ka.volumeIsDown
        #expect(isDown)
        let isPaused = await gate.isPaused
        #expect(isPaused)
        await ka.stop()
        #expect(logMessages.contains { $0.contains("unreachable") })
    }
}

// MARK: - ScanCheckpoint Tests

@Suite("ScanCheckpoint")
struct ScanCheckpointTests {

    private let testVolume = "/Volumes/TestCheckpoint_\(UUID().uuidString.prefix(8))"

    @Test func saveAndLoad() {
        let cp = ScanCheckpoint(
            volumePath: testVolume,
            startedAt: Date(),
            discoveredPaths: ["/Volumes/X/a.mov", "/Volumes/X/b.mov"],
            totalDiscovered: 2,
            skipChecksums: true
        )
        ScanCheckpointStorage.save(cp)
        defer { ScanCheckpointStorage.delete(for: testVolume) }

        let loaded = ScanCheckpointStorage.load(for: testVolume)
        #expect(loaded != nil)
        #expect(loaded?.totalDiscovered == 2)
        #expect(loaded?.discoveredPaths.count == 2)
        #expect(loaded?.skipChecksums == true)
    }

    @Test func deleteRemovesCheckpoint() {
        let cp = ScanCheckpoint(
            volumePath: testVolume,
            startedAt: Date(),
            discoveredPaths: [],
            totalDiscovered: 0
        )
        ScanCheckpointStorage.save(cp)
        #expect(ScanCheckpointStorage.exists(for: testVolume))
        ScanCheckpointStorage.delete(for: testVolume)
        #expect(!ScanCheckpointStorage.exists(for: testVolume))
    }

    @Test func loadNonexistent() {
        let cp = ScanCheckpointStorage.load(for: "/Volumes/NeverSaved_\(UUID())")
        #expect(cp == nil)
    }

    @Test func listAllIncludesSaved() {
        let cp = ScanCheckpoint(
            volumePath: testVolume,
            startedAt: Date(),
            discoveredPaths: ["/a.mov"],
            totalDiscovered: 1
        )
        ScanCheckpointStorage.save(cp)
        defer { ScanCheckpointStorage.delete(for: testVolume) }

        let all = ScanCheckpointStorage.listAll()
        #expect(all.contains { $0.volumePath == testVolume })
    }

    @Test func ageReturnsNonNilForExisting() {
        let cp = ScanCheckpoint(
            volumePath: testVolume,
            startedAt: Date().addingTimeInterval(-3600),
            discoveredPaths: [],
            totalDiscovered: 0
        )
        ScanCheckpointStorage.save(cp)
        defer { ScanCheckpointStorage.delete(for: testVolume) }

        let age = ScanCheckpointStorage.age(for: testVolume)
        #expect(age != nil)
        #expect(age! >= 3500)
    }

    @Test func roundTripPreservesAllFields() throws {
        let cp = ScanCheckpoint(
            volumePath: "/Volumes/MyDrive",
            startedAt: Date(timeIntervalSince1970: 1700000000),
            discoveredPaths: ["/Volumes/MyDrive/a.mov", "/Volumes/MyDrive/sub/b.avi"],
            totalDiscovered: 2,
            skipChecksums: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cp)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanCheckpoint.self, from: data)

        #expect(decoded.volumePath == cp.volumePath)
        #expect(decoded.totalDiscovered == cp.totalDiscovered)
        #expect(decoded.discoveredPaths == cp.discoveredPaths)
        #expect(decoded.skipChecksums == cp.skipChecksums)
    }
}

// MARK: - CatalogTargetStatus Robust Scan Tests

@Suite("CatalogTargetStatus Resilience")
struct CatalogTargetStatusResilienceTests {

    @Test func resumableIsIdle() {
        #expect(CatalogTargetStatus.resumable.isIdle)
    }

    @Test func waitingForVolumeIsActive() {
        #expect(CatalogTargetStatus.waitingForVolume.isActive)
    }

    @Test func resumableHasColor() {
        #expect(CatalogTargetStatus.resumable.color != CatalogTargetStatus.idle.color)
    }
}

// MARK: - Detect Resumable Targets

@Suite("Detect Resumable Targets")
@MainActor
struct DetectResumableTargetTests {

    @Test func marksTargetAsResumable() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()

        let testPath = "/Volumes/DetectResume_\(UUID().uuidString.prefix(8))"
        let target = CatalogScanTarget(searchPath: testPath)
        target.status = .idle
        model.scanTargets.append(target)

        let cp = ScanCheckpoint(
            volumePath: testPath,
            startedAt: Date(),
            discoveredPaths: ["\(testPath)/a.mov", "\(testPath)/b.mov"],
            totalDiscovered: 2
        )
        ScanCheckpointStorage.save(cp)
        defer { ScanCheckpointStorage.delete(for: testPath) }

        model.detectResumableTargets()
        #expect(target.status == .resumable)
    }

    @Test func cleansUpFullyScannedCheckpoint() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()

        let testPath = "/Volumes/FullyScan_\(UUID().uuidString.prefix(8))"
        let target = CatalogScanTarget(searchPath: testPath)
        target.status = .idle
        model.scanTargets.append(target)

        let rec1 = VideoRecord(); rec1.fullPath = "\(testPath)/a.mov"
        let rec2 = VideoRecord(); rec2.fullPath = "\(testPath)/b.mov"
        model.records.append(contentsOf: [rec1, rec2])

        let cp = ScanCheckpoint(
            volumePath: testPath,
            startedAt: Date(),
            discoveredPaths: ["\(testPath)/a.mov", "\(testPath)/b.mov"],
            totalDiscovered: 2
        )
        ScanCheckpointStorage.save(cp)

        model.detectResumableTargets()
        #expect(target.status == .idle)
        #expect(!ScanCheckpointStorage.exists(for: testPath))
    }
}
