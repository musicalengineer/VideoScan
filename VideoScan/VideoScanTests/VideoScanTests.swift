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
        #expect(rec.duplicateGroupID == nil)
        #expect(rec.duplicateConfidence == nil)
        #expect(rec.duplicateDisposition == .none)
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

// MARK: - DuplicateConfidence Tests

struct DuplicateConfidenceTests {

    @Test func ordering() {
        #expect(DuplicateConfidence.low < DuplicateConfidence.medium)
        #expect(DuplicateConfidence.medium < DuplicateConfidence.high)
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

// MARK: - DuplicateDetector Tests

struct DuplicateDetectorTests {

    @Test func exactDuplicateHashProducesKeeperAndExtraCopy() {
        let original = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 5_000_000_000,
            durationSeconds: 60,
            partialMD5: "abc123",
            resolution: "1920x1080",
            videoCodec: "prores",
            audioCodec: "pcm_s16le"
        )

        let copy = makeDuplicateRecord(
            filename: "clip copy.mov",
            streamType: .videoAndAudio,
            sizeBytes: 5_000_000_000,
            durationSeconds: 60,
            partialMD5: "abc123",
            resolution: "1920x1080",
            videoCodec: "prores",
            audioCodec: "pcm_s16le"
        )

        let summary = DuplicateDetector.analyze(records: [original, copy])

        #expect(summary.groups == 1)
        #expect(summary.highConfidenceGroups == 1)
        #expect(original.duplicateDisposition == .keep || copy.duplicateDisposition == .keep)
        #expect(original.duplicateDisposition == .extraCopy || copy.duplicateDisposition == .extraCopy)
        #expect(original.duplicateGroupID == copy.duplicateGroupID)
    }

    @Test func metadataOnlyDuplicateWithStrongSignals() {
        // No hash match, but timecode + filename + duration + resolution + codec + audio
        // all match. Durations must be close enough to land in the same bucket
        // (durationBucket = Int((secs*2).rounded()), so 42.0→84 and 42.1→84 = same bucket).
        let a = makeDuplicateRecord(
            filename: "Interview_01.mov",
            streamType: .videoAndAudio,
            sizeBytes: 1_000_000_000,
            durationSeconds: 42.0,
            partialMD5: "",
            resolution: "1280x720",
            videoCodec: "h264",
            audioCodec: "aac",
            timecode: "01:00:00:00"
        )

        let b = makeDuplicateRecord(
            filename: "Interview_01 (1).mov",
            streamType: .videoAndAudio,
            sizeBytes: 995_000_000,
            durationSeconds: 42.1,  // same duration bucket as 42.0
            partialMD5: "",
            resolution: "1280x720",
            videoCodec: "h264",
            audioCodec: "aac",
            timecode: "01:00:00:00"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        // timecode(4) + filename(3) + duration-exact(3) + resolution(2) + vcodec(2) + audio(2) = 16 → high
        #expect(summary.groups == 1)
        #expect(summary.highConfidenceGroups == 1)
        #expect(summary.extraCopies == 1)
        #expect(a.duplicateDisposition == .keep || b.duplicateDisposition == .keep)
        #expect(a.duplicateDisposition == .extraCopy || b.duplicateDisposition == .extraCopy)
    }

    @Test func mismatchedStreamTypesDoNotGroup() {
        let withAudio = makeDuplicateRecord(
            filename: "same.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 10,
            partialMD5: "samehash"
        )

        let videoOnly = makeDuplicateRecord(
            filename: "same_copy.mov",
            streamType: .videoOnly,
            sizeBytes: 100,
            durationSeconds: 10,
            partialMD5: "samehash"
        )

        let summary = DuplicateDetector.analyze(records: [withAudio, videoOnly])

        #expect(summary.groups == 0)
        #expect(withAudio.duplicateDisposition == .none)
        #expect(videoOnly.duplicateDisposition == .none)
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

private func makeDuplicateRecord(
    filename: String,
    streamType: StreamType,
    sizeBytes: Int64,
    durationSeconds: Double,
    partialMD5: String,
    resolution: String = "",
    videoCodec: String = "",
    audioCodec: String = "",
    timecode: String = ""
) -> VideoRecord {
    let record = VideoRecord()
    record.filename = filename
    record.streamTypeRaw = streamType.rawValue
    record.sizeBytes = sizeBytes
    record.durationSeconds = durationSeconds
    record.duration = Formatting.duration(durationSeconds)
    record.partialMD5 = partialMD5
    record.resolution = resolution
    record.videoCodec = videoCodec
    record.audioCodec = audioCodec
    record.audioChannels = audioCodec.isEmpty ? "" : "2"
    record.audioSampleRate = audioCodec.isEmpty ? "" : "48000 Hz"
    record.timecode = timecode
    record.isPlayable = "Yes"
    return record
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
        #expect(name == "clip.mov") // lastPathComponent for non-Volume paths
    }
}

// MARK: - DuplicateDetector Same-Volume Safety Tests

struct DuplicateDeletionSafetyTests {

    @Test func keeperOnSameVolumeIsDeletable() {
        let keeper = makeDuplicateRecord(
            filename: "original.mov", streamType: .videoAndAudio,
            sizeBytes: 5_000_000, durationSeconds: 60,
            partialMD5: "aaa", resolution: "1920x1080",
            videoCodec: "h264", audioCodec: "aac"
        )
        keeper.fullPath = "/Volumes/MyDrive/videos/original.mov"

        let extra = makeDuplicateRecord(
            filename: "original copy.mov", streamType: .videoAndAudio,
            sizeBytes: 5_000_000, durationSeconds: 60,
            partialMD5: "aaa", resolution: "1920x1080",
            videoCodec: "h264", audioCodec: "aac"
        )
        extra.fullPath = "/Volumes/MyDrive/videos/original copy.mov"

        let summary = DuplicateDetector.analyze(records: [keeper, extra])
        #expect(summary.groups == 1)
        #expect(summary.highConfidenceGroups == 1)

        // Both files on same volume — the extra copy should be identified
        let keepRec = [keeper, extra].first { $0.duplicateDisposition == .keep }
        let extraRec = [keeper, extra].first { $0.duplicateDisposition == .extraCopy }
        #expect(keepRec != nil)
        #expect(extraRec != nil)
        #expect(keepRec?.duplicateGroupID == extraRec?.duplicateGroupID)
    }

    @Test func duplicateGroupIDAssignment() {
        let a = makeDuplicateRecord(
            filename: "clip.mov", streamType: .videoAndAudio,
            sizeBytes: 1_000_000, durationSeconds: 30,
            partialMD5: "hash1", resolution: "1280x720",
            videoCodec: "h264", audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip (1).mov", streamType: .videoAndAudio,
            sizeBytes: 1_000_000, durationSeconds: 30,
            partialMD5: "hash1", resolution: "1280x720",
            videoCodec: "h264", audioCodec: "aac"
        )
        let c = makeDuplicateRecord(
            filename: "unrelated.mov", streamType: .videoAndAudio,
            sizeBytes: 2_000_000, durationSeconds: 120,
            partialMD5: "hash2", resolution: "1920x1080",
            videoCodec: "prores", audioCodec: "pcm_s16le"
        )

        _ = DuplicateDetector.analyze(records: [a, b, c])

        // a and b should share a group ID
        #expect(a.duplicateGroupID != nil)
        #expect(a.duplicateGroupID == b.duplicateGroupID)
        // c should not be in any group
        #expect(c.duplicateGroupID == nil)
    }

    @Test func clearResetsAllDuplicateFields() {
        let rec = makeDuplicateRecord(
            filename: "test.mov", streamType: .videoAndAudio,
            sizeBytes: 1_000, durationSeconds: 10, partialMD5: "x"
        )
        rec.duplicateGroupID = UUID()
        rec.duplicateConfidence = .high
        rec.duplicateDisposition = .extraCopy
        rec.duplicateReasons = "hash+duration"
        rec.duplicateBestMatchFilename = "other.mov"
        rec.duplicateGroupCount = 2

        DuplicateDetector.clear(records: [rec])

        #expect(rec.duplicateGroupID == nil)
        #expect(rec.duplicateConfidence == nil)
        #expect(rec.duplicateDisposition == .none)
        #expect(rec.duplicateReasons == "")
        #expect(rec.duplicateBestMatchFilename == "")
        #expect(rec.duplicateGroupCount == 0)
    }
}

// MARK: - RecognitionEngine Tests

struct RecognitionEngineTests {

    @Test func allCasesExist() {
        let engines = RecognitionEngine.allCases
        #expect(engines.count == 3)
        #expect(engines.contains(.vision))
        #expect(engines.contains(.dlib))
        #expect(engines.contains(.hybrid))
    }

    @Test func titlesAreNonEmpty() {
        for engine in RecognitionEngine.allCases {
            #expect(!engine.title.isEmpty, "\(engine) has empty title")
            #expect(!engine.shortLabel.isEmpty, "\(engine) has empty shortLabel")
        }
    }

    @Test func symbolNamesAreValid() {
        for engine in RecognitionEngine.allCases {
            #expect(!engine.symbolName.isEmpty, "\(engine) has empty symbolName")
        }
    }
}

// MARK: - CatalogScanTarget Tests

@MainActor
struct CatalogScanTargetStatusExtendedTests {

    @Test func scanTargetInitialState() {
        // Use /tmp which exists, so isReachable == true
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

// MARK: - Formatting Extended Tests

struct FormattingExtendedTests {

    @Test func durationEdgeCases() {
        #expect(Formatting.duration(0) == "00:00:00")
        #expect(Formatting.duration(0.5) == "00:00:00") // Int truncation
        #expect(Formatting.duration(59) == "00:00:59")
        #expect(Formatting.duration(60) == "00:01:00")
        #expect(Formatting.duration(3600) == "01:00:00")
        #expect(Formatting.duration(3661) == "01:01:01")
        #expect(Formatting.duration(86400) == "24:00:00") // full day
    }

    @Test func humanSizeEdgeCases() {
        #expect(Formatting.humanSize(0) == "0.0 B")
        #expect(Formatting.humanSize(1) == "1.0 B")
        #expect(Formatting.humanSize(1023) == "1023.0 B")
        #expect(Formatting.humanSize(2_500_000_000) == "2.3 GB")
    }
}

// MARK: - MXF Header Parser Tests

struct MxfBinaryHelperTests {

    @Test func readU16BE() {
        let data = Data([0x01, 0x02])
        #expect(MxfHeaderParser.readU16BE(data: data, pos: 0) == 0x0102)
    }

    @Test func readU32BE() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(MxfHeaderParser.readU32BE(data: data, pos: 0) == 0xDEADBEEF)
    }

    @Test func readU64BE() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(MxfHeaderParser.readU64BE(data: data, pos: 0) == 0x00000000DEADBEEF)
    }

    @Test func readU32BEAtOffset() {
        let data = Data([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01])
        #expect(MxfHeaderParser.readU32BE(data: data, pos: 2) == 1)
    }

    @Test func readBERShortForm() {
        // Short form: length < 0x80 is stored in a single byte
        let data = Data([0x42])
        let result = MxfHeaderParser.readBER(data: data, pos: 0)
        #expect(result != nil)
        #expect(result!.0 == 0x42)  // length
        #expect(result!.1 == 1)     // new position
    }

    @Test func readBERLongForm() {
        // Long form: 0x82 means 2 bytes follow for the length
        let data = Data([0x82, 0x01, 0x00])
        let result = MxfHeaderParser.readBER(data: data, pos: 0)
        #expect(result != nil)
        #expect(result!.0 == 256)   // 0x0100
        #expect(result!.1 == 3)     // past the 3 bytes
    }

    @Test func readBEREmptyData() {
        let data = Data()
        #expect(MxfHeaderParser.readBER(data: data, pos: 0) == nil)
    }
}

struct MxfCodecIdentificationTests {

    @Test func identifyDNxHD() {
        // The function checks ul.contains("0371") for DNxHD.
        // Must not trigger earlier checks (Avid byte8, DV essenceArea).
        // Byte 8 (chars 14-15) must not be "0e"; essenceArea (chars 16-23) must not match DV/Uncompressed.
        let ul = "060e2b340401010a00000000037100xx"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "DNxHD")
    }

    @Test func identifyH264() {
        // H.264 triggers on ul.contains("04010203")
        let ul = "060e2b340401010a0000000004010203"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "H.264")
    }

    @Test func identifyUncompressed() {
        // essenceArea (chars 16-23) starts with "04010201" → Uncompressed
        // Byte 8 (chars 14-15) must not be "0e"
        let ul = "060e2b340401010a0401020100000000"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "Uncompressed")
    }

    @Test func identifyAvidUncompressed() {
        // Byte 8 = 0e: chars 14-15 of the hex string must be "0e"
        // Requires hasPrefix("060e2b340401") and count >= 20
        let ul = "060e2b340401010e0000000000000000"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "Avid Uncompressed")
    }

    @Test func unknownCodecIncludesPrefix() {
        // essenceArea won't match any known pattern, no "0371"/"0301"/"04010203" in string
        let ul = "060e2b340401010a9999999999999999"
        let result = MxfHeaderParser.identifyCodec(ul: ul)
        #expect(result.hasPrefix("Unknown ("))
    }
}

struct MxfPixelLayoutTests {

    @Test func rgbaLayout() {
        // R=0x52 8bit, G=0x47 8bit, B=0x42 8bit, A=0x41 8bit, terminated by 0x00 0x00
        let data = Data([0x52, 8, 0x47, 8, 0x42, 8, 0x41, 8, 0x00, 0x00])
        let result = MxfHeaderParser.decodePixelLayout(data: data, pos: 0, len: data.count)
        #expect(result == "RGBA 8+8+8+8")
    }

    @Test func yuvLayout() {
        let data = Data([0x59, 10, 0x42, 10, 0x52, 10, 0x00, 0x00])
        let result = MxfHeaderParser.decodePixelLayout(data: data, pos: 0, len: data.count)
        #expect(result == "YBR 10+10+10")
    }

    @Test func emptyLayout() {
        let data = Data([0x00, 0x00])
        let result = MxfHeaderParser.decodePixelLayout(data: data, pos: 0, len: data.count)
        #expect(result == "")
    }

    @Test func parseNonexistentFile() {
        let result = MxfHeaderParser.parse(fileAt: "/nonexistent/file.mxf")
        #expect(result == nil)
    }
}

// MARK: - MXF Metadata Struct Tests

struct MxfMetadataTests {

    @Test func defaultValues() {
        let m = MxfHeaderParser.MxfMetadata()
        #expect(m.width == 0)
        #expect(m.height == 0)
        #expect(m.codecLabel == "")
        #expect(m.hasVideo == false)
        #expect(m.hasAudio == false)
        #expect(m.audioChannels == 0)
        #expect(m.durationSeconds == 0)
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
        // No scan targets set, so it falls back to deletingLastPathComponent
        let result = model.volumeRoot(for: "/Users/test/Videos/file.mov")
        #expect(result == "/Users/test/Videos")
    }
}

@MainActor
struct KeepersByGroupIDTests {

    @Test func findsKeepers() {
        let model = VideoScanModel()
        let groupID = UUID()

        let keeper = VideoRecord()
        keeper.fullPath = "/Volumes/Drive/keeper.mov"
        keeper.duplicateGroupID = groupID
        keeper.duplicateDisposition = .keep

        let extra = VideoRecord()
        extra.fullPath = "/Volumes/Drive/extra.mov"
        extra.duplicateGroupID = groupID
        extra.duplicateDisposition = .extraCopy

        model.records = [keeper, extra]

        let result = model.keepersByGroupID()
        #expect(result.count == 1)
        #expect(result[groupID]?.fullPath == "/Volumes/Drive/keeper.mov")
    }

    @Test func emptyRecordsReturnsEmpty() {
        let model = VideoScanModel()
        model.records = []
        #expect(model.keepersByGroupID().isEmpty)
    }
}

@MainActor
struct VolumesWithDeletableDuplicatesTests {

    @Test func sameVolumeIsReported() {
        let model = VideoScanModel()
        let groupID = UUID()

        let keeper = VideoRecord()
        keeper.fullPath = "/Volumes/Drive/folder1/keeper.mov"
        keeper.duplicateGroupID = groupID
        keeper.duplicateDisposition = .keep

        let extra = VideoRecord()
        extra.fullPath = "/Volumes/Drive/folder2/extra.mov"
        extra.duplicateGroupID = groupID
        extra.duplicateDisposition = .extraCopy
        extra.duplicateConfidence = .high

        model.records = [keeper, extra]

        let result = model.volumesWithDeletableDuplicates()
        #expect(result.count == 1)
        #expect(result.first?.path == "/Volumes/Drive")
        #expect(result.first?.count == 1)
    }

    @Test func crossVolumeDupsNotReported() {
        let model = VideoScanModel()
        let groupID = UUID()

        let keeper = VideoRecord()
        keeper.fullPath = "/Volumes/Primary/keeper.mov"
        keeper.duplicateGroupID = groupID
        keeper.duplicateDisposition = .keep

        let extra = VideoRecord()
        extra.fullPath = "/Volumes/Backup/extra.mov"
        extra.duplicateGroupID = groupID
        extra.duplicateDisposition = .extraCopy
        extra.duplicateConfidence = .high

        model.records = [keeper, extra]

        let result = model.volumesWithDeletableDuplicates()
        #expect(result.isEmpty)
    }
}

// MARK: - Discovered Volume Tests

struct DiscoveredVolumeTests {

    @Test func formattedSizes() {
        let vol = DiscoveredVolume(
            name: "TestDrive",
            path: "/Volumes/TestDrive",
            isNetwork: false,
            totalBytes: 1_000_000_000_000,  // ~1 TB
            freeBytes: 500_000_000_000,
            alreadyAdded: false
        )
        #expect(!vol.totalFormatted.isEmpty)
        #expect(!vol.usedFormatted.isEmpty)
        #expect(vol.isNetwork == false)
        #expect(vol.alreadyAdded == false)
    }

    @Test func networkVolumeFlag() {
        let vol = DiscoveredVolume(
            name: "NAS",
            path: "/Volumes/NAS",
            isNetwork: true,
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_000_000_000_000,
            alreadyAdded: true
        )
        #expect(vol.isNetwork == true)
        #expect(vol.alreadyAdded == true)
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
        // Load averages should be non-negative
        #expect(load.one >= 0)
        #expect(load.five >= 0)
        #expect(load.fifteen >= 0)
    }

    @Test func thermalStateReturnsLabel() {
        let state = systemThermalState()
        #expect(!state.label.isEmpty)
    }
}

// MARK: - AvbParser Tests

struct AvbParserTests {

    @Test func parseNonexistentFile() {
        let result = AvbParser.parse(fileAt: "/nonexistent/file.avb")
        #expect(result.clips.isEmpty)
        #expect(!result.errors.isEmpty)
    }

    @Test func scanEmptyDirectory() {
        let tmpDir = NSTemporaryDirectory() + "avb_test_\(UUID().uuidString)"
        FileManager.default.createFile(atPath: tmpDir, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        // Not a directory, so should return empty
        let results = AvbParser.scanDirectory(tmpDir)
        #expect(results.isEmpty)
    }

    @Test func parseEmptyData() {
        // Create a temp file with garbage data — parser should handle gracefully
        let tmpPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).avb"
        FileManager.default.createFile(atPath: tmpPath, contents: Data([0x00, 0x01, 0x02]))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let result = AvbParser.parse(fileAt: tmpPath)
        #expect(result.clips.isEmpty)
    }
}

// MARK: - AvbClip / AvbTrack Tests

struct AvbDataModelTests {

    @Test func avbTrackProperties() {
        let track = AvbTrack(
            index: 1,
            mediaKind: "picture",
            startPos: 0,
            length: 900,
            sourceClipMobID: "urn:smpte:umid:test",
            sourceTrackID: 1
        )
        #expect(track.index == 1)
        #expect(track.mediaKind == "picture")
        #expect(track.length == 900)
    }

    @Test func avbBinResultProperties() {
        let result = AvbBinResult(
            filePath: "/test/bin.avb",
            binName: "TestBin",
            creatorVersion: "22.0",
            lastSave: nil,
            clips: [],
            errors: []
        )
        #expect(result.binName == "TestBin")
        #expect(result.clips.isEmpty)
        #expect(result.errors.isEmpty)
    }
}
