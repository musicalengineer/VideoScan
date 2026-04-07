//
//  VideoScanTests.swift
//  VideoScanTests
//
//  Smoke tests for regression detection across core modules.
//

import Testing
import Foundation
@testable import VideoScan

// MARK: - StreamType Tests

struct StreamTypeTests {

    @Test func rawValues() {
        #expect(StreamType.videoAndAudio.rawValue == "Video+Audio")
        #expect(StreamType.videoOnly.rawValue == "Video only")
        #expect(StreamType.audioOnly.rawValue == "Audio only")
        #expect(StreamType.noStreams.rawValue == "No A/V streams")
        #expect(StreamType.ffprobeFailed.rawValue == "ffprobe failed")
    }

    @Test func needsCorrelation() {
        #expect(StreamType.videoOnly.needsCorrelation == true)
        #expect(StreamType.audioOnly.needsCorrelation == true)
        #expect(StreamType.videoAndAudio.needsCorrelation == false)
        #expect(StreamType.noStreams.needsCorrelation == false)
        #expect(StreamType.ffprobeFailed.needsCorrelation == false)
    }
}

// MARK: - VideoRecord Tests

struct VideoRecordTests {

    @Test func defaults() {
        let rec = VideoRecord()
        #expect(rec.filename == "")
        #expect(rec.sizeBytes == 0)
        #expect(rec.durationSeconds == 0)
        #expect(rec.streamType == .ffprobeFailed) // empty streamTypeRaw → fallback
        #expect(rec.pairedWith == nil)
        #expect(rec.pairGroupID == nil)
        #expect(rec.pairConfidence == nil)
        #expect(rec.wasCacheHit == false)
    }

    @Test func streamTypeParsing() {
        let rec = VideoRecord()
        rec.streamTypeRaw = "Video+Audio"
        #expect(rec.streamType == .videoAndAudio)

        rec.streamTypeRaw = "Video only"
        #expect(rec.streamType == .videoOnly)

        rec.streamTypeRaw = "Audio only"
        #expect(rec.streamType == .audioOnly)

        rec.streamTypeRaw = "garbage"
        #expect(rec.streamType == .ffprobeFailed) // unknown → fallback
    }

    @Test func uniqueIDs() {
        let a = VideoRecord()
        let b = VideoRecord()
        #expect(a.id != b.id)
    }
}

// MARK: - PairConfidence Tests

struct PairConfidenceTests {

    @Test func ordering() {
        #expect(PairConfidence.low < PairConfidence.medium)
        #expect(PairConfidence.medium < PairConfidence.high)
        #expect(!(PairConfidence.high < PairConfidence.low))
    }

    @Test func rawValues() {
        #expect(PairConfidence.high.rawValue == "High")
        #expect(PairConfidence.medium.rawValue == "Medium")
        #expect(PairConfidence.low.rawValue == "Low")
    }
}

// MARK: - CatalogTargetStatus Tests

struct CatalogTargetStatusTests {

    @Test func activeStates() {
        #expect(CatalogTargetStatus.scanning.isActive == true)
        #expect(CatalogTargetStatus.paused.isActive == true)
        #expect(CatalogTargetStatus.discovering.isActive == true)
        #expect(CatalogTargetStatus.idle.isActive == false)
        #expect(CatalogTargetStatus.complete.isActive == false)
        #expect(CatalogTargetStatus.stopped.isActive == false)
        #expect(CatalogTargetStatus.error.isActive == false)
    }

    @Test func isPaused() {
        #expect(CatalogTargetStatus.paused.isPaused == true)
        #expect(CatalogTargetStatus.scanning.isPaused == false)
    }

    @Test func isIdle() {
        #expect(CatalogTargetStatus.idle.isIdle == true)
        #expect(CatalogTargetStatus.scanning.isIdle == false)
    }
}

// MARK: - ScanPhase Tests

struct ScanPhaseTests {

    @Test func allPhases() {
        #expect(ScanPhase.idle.rawValue == "Idle")
        #expect(ScanPhase.discovering.rawValue == "Discovering")
        #expect(ScanPhase.probing.rawValue == "Probing")
        #expect(ScanPhase.writingCSV.rawValue == "Writing CSV")
        #expect(ScanPhase.complete.rawValue == "Complete")
    }
}

// MARK: - Formatting Tests

struct FormattingTests {

    @Test func durationFormatting() {
        #expect(Formatting.duration(0) == "00:00:00")
        #expect(Formatting.duration(59) == "00:00:59")
        #expect(Formatting.duration(60) == "00:01:00")
        #expect(Formatting.duration(3661) == "01:01:01")
        #expect(Formatting.duration(86399) == "23:59:59")
    }

    @Test func fractionParsing() {
        #expect(Formatting.fraction("30000/1001") == "29.97")
        #expect(Formatting.fraction("24000/1001") == "23.976")
        #expect(Formatting.fraction("30/1") == "30")
        #expect(Formatting.fraction("25/1") == "25")
        #expect(Formatting.fraction("0/0") == "0/0") // division by zero guard
        #expect(Formatting.fraction("notafraction") == "notafraction") // passthrough
    }

    @Test func humanSize() {
        #expect(Formatting.humanSize(0) == "0.0 B")
        #expect(Formatting.humanSize(512) == "512.0 B")
        #expect(Formatting.humanSize(1024) == "1.0 KB")
        #expect(Formatting.humanSize(1_048_576) == "1.0 MB")
        #expect(Formatting.humanSize(1_073_741_824) == "1.0 GB")
        #expect(Formatting.humanSize(1_099_511_627_776) == "1.0 TB")
    }

    @Test func csvEscape() {
        #expect(Formatting.csvEscape("hello") == "hello")
        #expect(Formatting.csvEscape("has,comma") == "\"has,comma\"")
        #expect(Formatting.csvEscape("has\"quote") == "\"has\"\"quote\"")
        #expect(Formatting.csvEscape("has\nnewline") == "\"has\nnewline\"")
    }
}

// MARK: - FFProbe JSON Decoding Tests

struct FFProbeDecodingTests {

    @Test func decodesMinimalJSON() throws {
        let json = """
        {"streams": [], "format": {"format_name": "mov", "duration": "10.5"}}
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        #expect(output.streams?.isEmpty == true)
        #expect(output.format?.format_name == "mov")
        #expect(output.format?.duration == "10.5")
    }

    @Test func decodesStreamFields() throws {
        let json = """
        {"streams": [{"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
                       "r_frame_rate": "30000/1001", "channels": null}],
         "format": null}
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let stream = try #require(output.streams?.first)
        #expect(stream.codec_type == "video")
        #expect(stream.codec_name == "h264")
        #expect(stream.width == 1920)
        #expect(stream.height == 1080)
        #expect(stream.r_frame_rate == "30000/1001")
        #expect(stream.channels == nil)
    }

    @Test func handlesNullTopLevel() throws {
        let json = """
        {"streams": null, "format": null}
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        #expect(output.streams == nil)
        #expect(output.format == nil)
    }
}

// MARK: - Correlator Tests

struct CorrelatorTests {

    @Test func filenameCorrelationKeyStripsAvidPrefix() {
        // Avid convention: V01A23BC.mxf and A01A23BC.mxf should match
        let vKey = Correlator.filenameCorrelationKey("V01A23BC.mxf")
        let aKey = Correlator.filenameCorrelationKey("A01A23BC.mxf")
        #expect(vKey == aKey)
    }

    @Test func filenameCorrelationKeyPreservesNonAvid() {
        let key = Correlator.filenameCorrelationKey("holiday_2005.mov")
        #expect(key == "holiday_2005.mov") // no V/A prefix → unchanged
    }

    @Test func filenameCorrelationKeyCaseVariants() {
        let v = Correlator.filenameCorrelationKey("v01AB.mxf")
        let a = Correlator.filenameCorrelationKey("a01AB.mxf")
        #expect(v == a)
    }

    @Test func correlateMatchesByFilenameAndDuration() {
        let video = VideoRecord()
        video.filename = "V01AB23.mxf"
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        video.durationSeconds = 30.0
        video.directory = "/vol/media"

        let audio = VideoRecord()
        audio.filename = "A01AB23.mxf"
        audio.streamTypeRaw = StreamType.audioOnly.rawValue
        audio.durationSeconds = 30.2 // within 1s tolerance
        audio.directory = "/vol/media"

        let records = [video, audio]
        Correlator.correlate(records: records)

        #expect(video.pairedWith === audio)
        #expect(audio.pairedWith === video)
        #expect(video.pairGroupID != nil)
        #expect(video.pairGroupID == audio.pairGroupID)
        #expect(video.pairConfidence != nil)
    }

    @Test func correlateRejectsLowScore() {
        let video = VideoRecord()
        video.filename = "completely_different.mov"
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        video.durationSeconds = 30.0

        let audio = VideoRecord()
        audio.filename = "unrelated_audio.wav"
        audio.streamTypeRaw = StreamType.audioOnly.rawValue
        audio.durationSeconds = 120.0 // way off

        let records = [video, audio]
        Correlator.correlate(records: records)

        #expect(video.pairedWith == nil)
        #expect(audio.pairedWith == nil)
    }

    @Test func correlatedPairsExtraction() {
        let video = VideoRecord()
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        let audio = VideoRecord()
        audio.streamTypeRaw = StreamType.audioOnly.rawValue

        // Manually pair them
        let gid = UUID()
        video.pairedWith = audio
        video.pairGroupID = gid
        audio.pairedWith = video
        audio.pairGroupID = gid

        let pairs = Correlator.correlatedPairs(from: [video, audio])
        #expect(pairs.count == 1)
        #expect(pairs[0].video === video)
        #expect(pairs[0].audio === audio)
    }
}

// MARK: - AsyncSemaphore Tests

struct AsyncSemaphoreTests {

    @Test func basicWaitAndSignal() async {
        let sem = AsyncSemaphore(limit: 2)
        // Should acquire two permits without blocking
        await sem.wait()
        await sem.wait()
        // Signal both back
        await sem.signal()
        await sem.signal()
        // Should be able to acquire again
        await sem.wait()
        await sem.signal()
    }

    @Test func concurrencyLimiting() async {
        let sem = AsyncSemaphore(limit: 3)
        let counter = Counter()
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

// Helper actor for counting concurrent tasks
private actor Counter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func decrement() {
        value -= 1
    }
}

// MARK: - ScanPerformanceSettings Tests

struct ScanPerformanceSettingsTests {

    @Test func defaultValues() {
        let s = ScanPerformanceSettings()
        #expect(s.probesPerVolume == 8)
        #expect(s.ramDiskGB == 16)
        #expect(s.prefetchMB == 50)
        #expect(s.combineConcurrency == 4)
        #expect(s.memoryFloorGB == 4)
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
        // Should end with GB or MB
        #expect(str.hasSuffix("GB") || str.hasSuffix("MB"),
                "Expected memory string to end with GB or MB, got: \(str)")
    }

    @Test func setFloorGB() async {
        await MemoryPressureMonitor.shared.setFloorGB(8)
        let threshold = await MemoryPressureMonitor.shared.thresholdBytes()
        #expect(threshold == 8 * 1024 * 1024 * 1024)
        // Restore default
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
        #expect(result1 == true) // was unpaused → now paused
        let result2 = await gate.toggle()
        #expect(result2 == false) // was paused → now unpaused
    }

    @Test func waitIfPausedReturnsImmediatelyWhenNotPaused() async {
        let gate = PauseGate()
        await gate.setAutoPause(false) // disable memory check for unit test
        // This should return instantly, not hang
        await gate.waitIfPaused()
    }
}

// MARK: - pfFindVideoFiles Tests

struct VideoDiscoveryTests {

    @Test func findsVideoFilesInDirectory() throws {
        // Create a temp directory with some test files
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScanTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create test files
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
