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
        #expect(rec.filename.isEmpty)
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

    // MARK: - Threshold & confidence banding regression tests
    //
    // These guard the numeric boundaries in the scoring table: the
    // threshold (7) below which no group is formed, and the two band
    // cut-offs (9 and 12) that separate low / medium / high. If a future
    // refactor tweaks a rule's point value without updating these bands,
    // one of these tests will fail.

    @Test func scoreBelowThresholdProducesNoGroup() {
        // Only filename(3) + duration-exact(3) = 6 → below threshold (7).
        // Audio codecs differ so the audio signature does NOT match.
        let a = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 200,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "mp3"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 0)
        #expect(a.duplicateDisposition == .none)
        #expect(b.duplicateDisposition == .none)
    }

    @Test func scoreInLowBandProducesLowConfidenceGroup() {
        // filename(3) + duration-exact(3) + audio(2) = 8 → low band (7-8).
        // Matching audioCodec makes the audio signature match.
        let a = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 200,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "aac"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 1)
        #expect(summary.lowConfidenceGroups == 1)
        #expect(summary.mediumConfidenceGroups == 0)
        #expect(summary.highConfidenceGroups == 0)
    }

    @Test func scoreInMediumBandProducesMediumConfidenceGroup() {
        // filename(3) + duration-exact(3) + audio(2) + resolution(2) = 10 → medium (9-11).
        let a = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 30.0,
            partialMD5: "",
            resolution: "1920x1080",
            audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 200,
            durationSeconds: 30.0,
            partialMD5: "",
            resolution: "1920x1080",
            audioCodec: "aac"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 1)
        #expect(summary.mediumConfidenceGroups == 1)
        #expect(summary.lowConfidenceGroups == 0)
        #expect(summary.highConfidenceGroups == 0)
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
        #expect(rec.duplicateReasons.isEmpty)
        #expect(rec.duplicateBestMatchFilename.isEmpty)
        #expect(rec.duplicateGroupCount == 0)
    }
}

// MARK: - RecognitionEngine Tests

struct RecognitionEngineTests {

    @Test func allCasesExist() {
        let engines = RecognitionEngine.allCases
        #expect(engines.count == 4)
        #expect(engines.contains(.vision))
        #expect(engines.contains(.arcface))
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
        #expect(result.isEmpty)
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
        #expect(m.codecLabel.isEmpty)
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

// MARK: - Media Fixture Tests (ffprobe integration)

/// Tests that exercise ffprobe against real media files in tests/fixtures/videos/.
/// These are 5-second SMPTE color bar + sine tone files generated via ffmpeg.
@MainActor
struct FFProbeIntegrationTests {

    /// Path to the test fixtures directory.
    /// Works from both Xcode (srcroot) and command-line (relative to repo root).
    static let fixturesDir: String = {
        // Walk up from the test bundle to find the repo root
        let thisFile = #filePath
        // thisFile = .../VideoScan/VideoScanTests/VideoScanTests.swift
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()  // VideoScanTests/
            .deletingLastPathComponent()  // VideoScan/
            .deletingLastPathComponent()  // repo root
        return repoRoot.appendingPathComponent("tests/fixtures/videos").path
    }()

    private func fixturePath(_ name: String) -> String {
        "\(Self.fixturesDir)/\(name)"
    }

    // MARK: - Video + Audio

    @Test func probeMP4VideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mp4"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MP4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(!rec.resolution.isEmpty)
        #expect(rec.durationSeconds > 4.0 && rec.durationSeconds < 6.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    @Test func probeMOVVideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mov"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MOV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(rec.durationSeconds > 4.0)
    }

    @Test func probeMKVVideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mkv"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MKV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
    }

    @Test func probeMXFVideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mxf"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.durationSeconds > 4.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    // MARK: - Video Only

    @Test func probeMP4VideoOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_only.mp4"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse video-only MP4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(rec.videoCodec == "h264")
        #expect(rec.audioCodec.isEmpty)
    }

    @Test func probeMXFVideoOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_only.mxf"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse video-only MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.audioCodec.isEmpty)
    }

    // MARK: - Audio Only

    @Test func probeM4AAudioOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_audio_only.m4a"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse M4A: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(rec.audioCodec == "aac")
        #expect(rec.videoCodec.isEmpty)
    }

    @Test func probeWAVAudioOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_audio_only.wav"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse WAV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(!rec.audioCodec.isEmpty)
        #expect(rec.videoCodec.isEmpty)
    }

    // MARK: - Real Avid MXF files (skipped if not present)

    @Test func probeAvidMXFVideoOnly() async {
        let path = fixturePath("video-only-test-1.mxf")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse Avid video MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(!rec.videoCodec.isEmpty)
        #expect(rec.audioCodec.isEmpty)
        #expect(rec.durationSeconds > 0)
    }

    @Test func probeAvidMXFAudioOnly() async {
        let path = fixturePath("audio-only-test-1.mxf")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse Avid audio MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(!rec.audioCodec.isEmpty)
        #expect(rec.videoCodec.isEmpty)
    }

    // MARK: - Full probeFile pipeline

    @Test func probeFilePipelineMP4() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mp4"))
        let rec = await model.probeFile(url: url)
        #expect(rec.filename == "test_video_audio.mp4")
        #expect(rec.ext == "MP4")
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.fullPath == url.path)
        #expect(rec.sizeBytes > 0)
        #expect(rec.durationSeconds > 4.0)
        #expect(!rec.partialMD5.isEmpty)
    }

    @Test func probeFilePipelineMXF() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mxf"))
        let rec = await model.probeFile(url: url)
        #expect(rec.filename == "test_video_audio.mxf")
        #expect(rec.ext == "MXF")
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.sizeBytes > 0)
    }

    @Test func probeFileNonexistent() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: "/nonexistent/file_\(UUID()).mp4")
        let rec = await model.probeFile(url: url)
        #expect(rec.streamType == .ffprobeFailed || rec.streamType == .noStreams)
    }
}

// MARK: - CombineEngine Tests

struct CombineEngineTests {

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/videos").path
    }()

    @Test func combineMP4VideoWithM4AAudio() async throws {
        let videoPath = "\(Self.fixturesDir)/test_video_only.mp4"
        let audioPath = "\(Self.fixturesDir)/test_audio_only.m4a"
        let outputPath = NSTemporaryDirectory() + "combine_test_\(UUID()).mov"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        var logLines: [String] = []
        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: { logLines.append($0) }
        )

        #expect(result.success, "Combine should succeed: exit \(result.exitCode)\n\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: outputPath))

        // Verify the output has both streams
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        proc.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", outputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let types = (json.streams ?? []).compactMap { $0.codec_type }
        #expect(types.contains("video"), "Output should have video stream")
        #expect(types.contains("audio"), "Output should have audio stream")
    }

    @Test func combineFailsWithMissingInput() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "/nonexistent/video.mp4",
            audioPath: "/nonexistent/audio.m4a",
            outputPath: NSTemporaryDirectory() + "should_not_exist.mov",
            log: { _ in }
        )
        #expect(!result.success)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("No such file"))
    }

    @Test func combineResultCapturesStderr() async {
        // Even successful runs produce stderr (ffmpeg version info)
        let videoPath = "\(Self.fixturesDir)/test_video_only.mp4"
        let audioPath = "\(Self.fixturesDir)/test_audio_only.m4a"
        let outputPath = NSTemporaryDirectory() + "combine_stderr_\(UUID()).mov"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: { _ in }
        )
        // ffmpeg always writes version/config info to stderr
        #expect(!result.stderr.isEmpty, "stderr should capture ffmpeg output")
    }

    @Test func combineAvidMXFPair() async throws {
        let videoPath = "\(Self.fixturesDir)/video-only-test-1.mxf"
        let audioPath = "\(Self.fixturesDir)/audio-only-test-1.mxf"

        // Skip if real Avid MXF fixtures aren't present (too large for git)
        guard FileManager.default.fileExists(atPath: videoPath),
              FileManager.default.fileExists(atPath: audioPath) else {
            return  // silently skip — CI won't have these files
        }

        let outputPath = NSTemporaryDirectory() + "combine_avid_mxf_\(UUID()).mov"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: { _ in }
        )

        #expect(result.success, "Avid MXF combine should succeed: exit \(result.exitCode)\n\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: outputPath))

        // Verify output has both streams
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        proc.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", outputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let types = (json.streams ?? []).compactMap { $0.codec_type }
        #expect(types.contains("video"), "Combined output should have video stream")
        #expect(types.contains("audio"), "Combined output should have audio stream")
    }
}

// MARK: - MXF Header Parser with Real MXF Files

struct MxfParserIntegrationTests {

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/videos").path
    }()

    @Test func parseMXFVideoAudio() {
        let path = "\(Self.fixturesDir)/test_video_audio.mxf"
        // Our generated MXF is standard MPEG-2 — the native parser is designed
        // for Avid MXF, so it may return nil or partial results. The key assertion
        // is that it doesn't crash on valid MXF data.
        _ = MxfHeaderParser.parse(fileAt: path)
        // No crash = pass
    }

    @Test func parseMXFVideoOnly() {
        let path = "\(Self.fixturesDir)/test_video_only.mxf"
        let result = MxfHeaderParser.parse(fileAt: path)
        if let meta = result {
            #expect(meta.audioChannels == 0, "Video-only MXF should have no audio channels")
        }
    }
}

// MARK: - CombinePairItem Tests

struct CombinePairItemTests {

    @Test func storesVideoAndAudio() {
        let v = VideoRecord()
        v.filename = "video.mxf"
        v.fullPath = "/Volumes/Drive/video.mxf"
        let a = VideoRecord()
        a.filename = "audio.mxf"
        a.fullPath = "/Volumes/Drive/audio.mxf"

        let item = CombinePairItem(video: v, audio: a)
        #expect(item.video.filename == "video.mxf")
        #expect(item.audio.fullPath == "/Volumes/Drive/audio.mxf")
        #expect(item.id != UUID()) // has a unique ID
    }
}

// MARK: - PersonFinder Scan Configuration Tests

/// Tests that verify the correct engine, thresholds, and reference faces
/// are wired through to a scan job. Catches regressions where profile
/// settings are silently lost or overridden.
@MainActor
struct ScanConfigurationTests {

    /// Path to test reference photos.
    static let photosDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()  // VideoScanTests/
            .deletingLastPathComponent()  // VideoScan/
            .deletingLastPathComponent()  // repo root
        return repoRoot.appendingPathComponent("tests/fixtures/photos").path
    }()

    /// True when running on CI (GitHub Actions) where Vision/ANE is too slow
    /// for face-loading tests. The pure logic tests still run everywhere.
    /// GitHub Actions sets CI=true globally — inherited by the test host process.
    nonisolated static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Time limit for Vision-heavy tests. Locally they finish in ~2s.
    /// If they exceed this, something is wrong (hung, no ANE, etc.)
    static let visionTimeLimit = TimeLimitTrait.Duration.minutes(2)

    // MARK: applyProfile

    @Test func applyProfileSetsEngine() {
        var settings = PersonFinderSettings()
        settings.recognitionEngine = .vision
        let profile = POIProfile(name: "Test", referencePath: "/tmp",
                                 engine: RecognitionEngine.dlib.rawValue)
        settings.applyProfile(profile)
        #expect(settings.recognitionEngine == .dlib)
    }

    @Test func applyProfileSetsThresholds() {
        var settings = PersonFinderSettings()
        let profile = POIProfile(name: "Test", referencePath: "/tmp",
                                 visionThreshold: 0.35, arcfaceThreshold: 0.22,
                                 minFaceConfidence: 0.70)
        settings.applyProfile(profile)
        #expect(settings.threshold == 0.35)
        #expect(settings.arcfaceThreshold == 0.22)
        #expect(settings.minFaceConfidence == 0.70)
    }

    @Test func applyProfileSetsRejectedFiles() {
        var settings = PersonFinderSettings()
        settings.rejectedReferenceFiles = []
        let profile = POIProfile(name: "Test", referencePath: "/tmp",
                                 rejectedFiles: ["bad1.jpg", "bad2.jpg"])
        settings.applyProfile(profile)
        #expect(settings.rejectedReferenceFiles == ["bad1.jpg", "bad2.jpg"])
    }

    @Test func applyProfileSetsPersonName() {
        var settings = PersonFinderSettings()
        settings.personName = "OldName"
        let profile = POIProfile(name: "NewName", referencePath: "/some/path")
        settings.applyProfile(profile)
        #expect(settings.personName == "NewName")
        #expect(settings.referencePath == "/some/path")
    }

    // MARK: Per-job engine resolution

    @Test func effectiveEngineDefaultsToVision() {
        let job = ScanJob(searchPath: "/tmp")
        #expect(job.effectiveEngine == .vision)
    }

    @Test func effectiveEngineUsesProfileEngine() {
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: "/tmp",
                                         engine: RecognitionEngine.arcface.rawValue)
        #expect(job.effectiveEngine == .arcface)
    }

    @Test func effectiveEngineJobOverrideTakesPriority() {
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: "/tmp",
                                         engine: RecognitionEngine.vision.rawValue)
        job.assignedEngine = .dlib
        #expect(job.effectiveEngine == .dlib)
    }

    // MARK: Face loading with rejection filtering
    // These tests run Vision face detection on real photos — too slow for CI runners
    // without ANE. They run locally and catch regressions before push.

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func loadFacesForJobFiltersRejectedFiles() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        // Create profile with some rejected files
        job.assignedProfile = POIProfile(
            name: "Donna",
            referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg", "IMG_3091.jpeg"]
        )

        await model.loadFacesForJob(job)

        // Verify no rejected files made it through
        let loadedFilenames = Set(job.assignedFaces.map(\.sourceFilename))
        #expect(!loadedFilenames.contains("DSCN3603.jpeg"))
        #expect(!loadedFilenames.contains("IMG_0145.jpeg"))
        #expect(!loadedFilenames.contains("IMG_3091.jpeg"))
        #expect(!job.assignedFaces.isEmpty, "Should have loaded some faces")
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func loadFacesForJobLoadsAllWhenNoRejections() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Donna", referencePath: photosDir,
                                         rejectedFiles: [])

        await model.loadFacesForJob(job)

        let jobWithRejections = ScanJob(searchPath: "/tmp")
        jobWithRejections.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg"]
        )
        await model.loadFacesForJob(jobWithRejections)

        #expect(job.assignedFaces.count > jobWithRejections.assignedFaces.count,
                "No rejections should load more faces than with rejections")
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func loadFacesForJobSetsStatusBackToIdle() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: photosDir)
        #expect(job.status == .idle)

        await model.loadFacesForJob(job)

        #expect(job.status == .idle, "Status should return to idle after loading")
    }

    @Test func loadFacesForJobSkipsNonIdleJob() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: Self.photosDir)
        job.status = .cancelled

        await model.loadFacesForJob(job)

        #expect(job.assignedFaces.isEmpty, "Should not load faces for non-idle job")
    }

    // MARK: startJobAfterLoad console log verification
    // These also load faces via Vision — skipped on CI.

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobLogsCorrectEngine() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp/nonexistent_scan_path")
        model.jobs.append(job)

        // Set up with a Vision profile
        let profile = POIProfile(name: "TestPerson", referencePath: photosDir,
                                 engine: RecognitionEngine.vision.rawValue,
                                 visionThreshold: 0.48, minFaceConfidence: 0.60)
        job.assignedProfile = profile
        await model.loadFacesForJob(job)

        // Start the job — it will begin scanning (will fail quickly on nonexistent path)
        model.startJob(job)

        // Give the async Task a moment to write logs
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Engine: VISION"), "Console should log the engine; got: \(log)")
        #expect(log.contains("Person: TestPerson"), "Console should log person name")
        #expect(log.contains("Threshold: 0.48"), "Console should log threshold from profile")
        #expect(log.contains("Confidence: 0.60"), "Console should log confidence from profile")
        #expect(log.contains("Feature prints for matching:"), "Console should log print count")

        // Verify it did NOT log DLIB or ARCFACE
        #expect(!log.contains("Engine: DLIB"), "Should not log dlib engine")
        #expect(!log.contains("Engine: ARCFACE"), "Should not log arcface engine")

        model.stopJob(job)
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobWithEngineOverride() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp/nonexistent")
        model.jobs.append(job)

        // Profile says Vision, but job overrides to ArcFace
        let profile = POIProfile(name: "Test", referencePath: photosDir,
                                 engine: RecognitionEngine.vision.rawValue)
        job.assignedProfile = profile
        job.assignedEngine = .arcface
        await model.loadFacesForJob(job)

        model.startJob(job)
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Engine: ARCFACE"),
                "Job engine override should take priority; got: \(log)")

        model.stopJob(job)
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobLogsPrintCount() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp/nonexistent")
        model.jobs.append(job)

        let profile = POIProfile(name: "Test", referencePath: photosDir,
                                 rejectedFiles: [])
        job.assignedProfile = profile
        await model.loadFacesForJob(job)

        let expectedPrintCount = job.assignedFaces.count
        #expect(expectedPrintCount > 0, "Should have loaded faces")

        model.startJob(job)
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Feature prints for matching: \(expectedPrintCount)"),
                "Print count should match loaded faces; got: \(log)")
        #expect(log.contains("References loaded: \(expectedPrintCount)"),
                "References loaded count should match; got: \(log)")

        model.stopJob(job)
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobWithNoProfileUsesGlobalFaces() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp/nonexistent")
        model.jobs.append(job)

        // No assigned profile — load global reference faces
        model.settings.referencePath = photosDir
        model.settings.rejectedReferenceFiles = []
        model.settings.recognitionEngine = .vision
        await model.loadReference()

        let globalCount = model.referenceFaces.count
        #expect(globalCount > 0, "Should have loaded global faces")

        model.startJob(job)
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Feature prints for matching: \(globalCount)"),
                "Should use global face count; got: \(log)")

        model.stopJob(job)
    }

    // MARK: Rejected files regression guard

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func profileRejectedFilesAppliedDuringScan() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()

        // Job with rejections
        let jobRejected = ScanJob(searchPath: "/tmp/nonexistent")
        model.jobs.append(jobRejected)
        jobRejected.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg", "IMG_3091.jpeg"]
        )
        await model.loadFacesForJob(jobRejected)
        let rejectedCount = jobRejected.assignedFaces.count

        // Job without rejections (same person, same photos)
        let jobAll = ScanJob(searchPath: "/tmp/nonexistent2")
        model.jobs.append(jobAll)
        jobAll.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: []
        )
        await model.loadFacesForJob(jobAll)
        let allCount = jobAll.assignedFaces.count

        // Start both — verify each logs its own correct count
        model.startJob(jobRejected)
        model.startJob(jobAll)
        try? await Task.sleep(for: .milliseconds(200))

        let logRejected = jobRejected.consoleLines.joined(separator: "\n")
        let logAll = jobAll.consoleLines.joined(separator: "\n")

        #expect(logRejected.contains("Feature prints for matching: \(rejectedCount)"),
                "Rejected job should use filtered count; got: \(logRejected)")
        #expect(logAll.contains("Feature prints for matching: \(allCount)"),
                "Unfiltered job should use full count; got: \(logAll)")
        #expect(allCount > rejectedCount,
                "Unfiltered (\(allCount)) should have more faces than filtered (\(rejectedCount))")

        model.stopAll()
    }
}

// MARK: - Catalog Skip Set Tests

struct CatalogSkipSetTests {

    @Test func skipSetFiltersAudioOnly() async {
        // Create records with various stream types
        let rec1 = VideoRecord()
        rec1.fullPath = "/vol/video1.mov"
        rec1.streamTypeRaw = StreamType.videoAndAudio.rawValue

        let rec2 = VideoRecord()
        rec2.fullPath = "/vol/audio.wav"
        rec2.streamTypeRaw = StreamType.audioOnly.rawValue

        let rec3 = VideoRecord()
        rec3.fullPath = "/vol/broken.mxf"
        rec3.streamTypeRaw = StreamType.ffprobeFailed.rawValue

        let rec4 = VideoRecord()
        rec4.fullPath = "/vol/empty.avi"
        rec4.streamTypeRaw = StreamType.noStreams.rawValue

        let rec5 = VideoRecord()
        rec5.fullPath = "/vol/video2.mp4"
        rec5.streamTypeRaw = StreamType.videoOnly.rawValue

        // Build skip set the same way pfCatalogSkipSet does
        var skip = Set<String>()
        for rec in [rec1, rec2, rec3, rec4, rec5] {
            switch rec.streamType {
            case .audioOnly, .noStreams, .ffprobeFailed:
                if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
            case .videoAndAudio, .videoOnly:
                break
            }
        }

        #expect(skip.count == 3)
        #expect(skip.contains("/vol/audio.wav"))
        #expect(skip.contains("/vol/broken.mxf"))
        #expect(skip.contains("/vol/empty.avi"))
        #expect(!skip.contains("/vol/video1.mov"))
        #expect(!skip.contains("/vol/video2.mp4"))
    }

    @Test func skipSetFilteringReducesFileList() async {
        let allFiles = [
            "/vol/video1.mov",
            "/vol/audio.wav",
            "/vol/broken.mxf",
            "/vol/video2.mp4",
            "/vol/empty.avi"
        ]
        let skipSet: Set<String> = ["/vol/audio.wav", "/vol/broken.mxf", "/vol/empty.avi"]

        var filtered = allFiles
        filtered.removeAll { skipSet.contains($0) }

        #expect(filtered.count == 2)
        #expect(filtered.contains("/vol/video1.mov"))
        #expect(filtered.contains("/vol/video2.mp4"))
    }

    @Test func skipSetEmptyWhenNoBadFiles() async {
        let rec1 = VideoRecord()
        rec1.fullPath = "/vol/good1.mov"
        rec1.streamTypeRaw = StreamType.videoAndAudio.rawValue

        let rec2 = VideoRecord()
        rec2.fullPath = "/vol/good2.mp4"
        rec2.streamTypeRaw = StreamType.videoOnly.rawValue

        var skip = Set<String>()
        for rec in [rec1, rec2] {
            switch rec.streamType {
            case .audioOnly, .noStreams, .ffprobeFailed:
                if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
            case .videoAndAudio, .videoOnly:
                break
            }
        }

        #expect(skip.isEmpty)
    }

    @Test func skipSetIgnoresEmptyPaths() async {
        let rec = VideoRecord()
        rec.fullPath = ""
        rec.streamTypeRaw = StreamType.audioOnly.rawValue

        var skip = Set<String>()
        switch rec.streamType {
        case .audioOnly, .noStreams, .ffprobeFailed:
            if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
        case .videoAndAudio, .videoOnly:
            break
        }

        #expect(skip.isEmpty, "Empty paths should not be added to skip set")
    }

    @Test func settingDefaultsToTrue() {
        let settings = PersonFinderSettings()
        #expect(settings.skipCatalogBadFiles == true)
    }
}

// MARK: - Volume Compare Tests

struct VolumeCompareTests {

    private func makeRecord(filename: String, path: String, md5: String, size: Int64, streamType: StreamType = .videoAndAudio) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = filename
        rec.fullPath = path
        rec.partialMD5 = md5
        rec.sizeBytes = size
        rec.streamTypeRaw = streamType.rawValue
        return rec
    }

    @Test func identicalFilesAreAlreadySafe() {
        let src = [makeRecord(filename: "clip.mov", path: "/Volumes/Old/clip.mov", md5: "abc123", size: 1000)]
        let dst = [makeRecord(filename: "clip.mov", path: "/Volumes/New/clip.mov", md5: "abc123", size: 1000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    @Test func renamedFileMatchesByHash() {
        let src = [makeRecord(filename: "original.mov", path: "/Volumes/Old/original.mov", md5: "abc123", size: 5000)]
        let dst = [makeRecord(filename: "renamed.mov", path: "/Volumes/New/renamed.mov", md5: "abc123", size: 5000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    @Test func uniqueFileIsMissing() {
        let src = [
            makeRecord(filename: "shared.mov", path: "/Volumes/Old/shared.mov", md5: "aaa", size: 1000),
            makeRecord(filename: "unique.mov", path: "/Volumes/Old/unique.mov", md5: "bbb", size: 2000)
        ]
        let dst = [makeRecord(filename: "shared.mov", path: "/Volumes/New/shared.mov", md5: "aaa", size: 1000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 1)
        #expect(result.missingFiles.first?.filename == "unique.mov")
        #expect(result.missingBytes == 2000)
    }

    @Test func fallbackMatchesByNameAndSize() {
        // No MD5 on source — should still match by filename + size
        let src = [makeRecord(filename: "clip.mov", path: "/Volumes/Old/clip.mov", md5: "", size: 3000)]
        let dst = [makeRecord(filename: "clip.mov", path: "/Volumes/New/clip.mov", md5: "xyz", size: 3000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.alreadySafeCount == 1)
        #expect(result.sourceOnly == 0)
    }

    @Test func differentSizeSameNameIsMissing() {
        let src = [makeRecord(filename: "clip.mov", path: "/Volumes/Old/clip.mov", md5: "aaa", size: 3000)]
        let dst = [makeRecord(filename: "clip.mov", path: "/Volumes/New/clip.mov", md5: "bbb", size: 5000)]

        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst, sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.sourceOnly == 1, "Same filename but different size+hash should be missing")
    }

    @Test func emptyDestinationMeansAllMissing() {
        let src = [
            makeRecord(filename: "a.mov", path: "/Volumes/Old/a.mov", md5: "x", size: 100),
            makeRecord(filename: "b.mov", path: "/Volumes/Old/b.mov", md5: "y", size: 200)
        ]
        let result = VolumeComparer.compare(sourceRecords: src, destRecords: [], sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.sourceOnly == 2)
        #expect(result.missingBytes == 300)
    }

    // MARK: - Audit mode (issue #33 — "has a copy on ANY other volume")

    @Test func auditMode_fileFoundOnAnyDestinationIsSafe() {
        // Source on MacPro; two other volumes contribute possible backups.
        // File A appears on SSD, file B appears on Backup — both should be "safe".
        let src = [
            makeRecord(filename: "A.mov", path: "/Volumes/MacPro/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/MacPro/B.mov", md5: "b2", size: 200)
        ]
        // Union of every other volume's catalog records:
        let dstUnion = [
            makeRecord(filename: "A.mov", path: "/Volumes/SSD/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/Backup/B.mov", md5: "b2", size: 200)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dstUnion,
            sourcePath: "/Volumes/MacPro", destPath: "",
            destLabel: "any other cataloged volume", isAuditMode: true
        )

        #expect(result.isAuditMode == true)
        #expect(result.alreadySafeCount == 2)
        #expect(result.sourceOnly == 0)
        #expect(result.destLabel == "any other cataloged volume")
    }

    @Test func auditMode_fileOnNoOtherVolumeIsFlagged() {
        // File C is on MacPro only — no backup anywhere. Audit must flag it.
        let src = [
            makeRecord(filename: "A.mov", path: "/Volumes/MacPro/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "C.mov", path: "/Volumes/MacPro/C.mov", md5: "c3", size: 300)
        ]
        let dstUnion = [
            makeRecord(filename: "A.mov", path: "/Volumes/SSD/A.mov", md5: "a1", size: 100)
            // no record of C.mov anywhere
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dstUnion,
            sourcePath: "/Volumes/MacPro", destPath: "",
            destLabel: "any other cataloged volume", isAuditMode: true
        )

        #expect(result.sourceOnly == 1)
        #expect(result.missingFiles.first?.filename == "C.mov")
        #expect(result.missingBytes == 300)
    }

    @Test func auditMode_sameFileOnMultipleDestsCountsOnceAsSafe() {
        // A file that exists on 3 backup volumes shouldn't inflate the "safe" count.
        let src = [makeRecord(filename: "A.mov", path: "/Volumes/MacPro/A.mov", md5: "a1", size: 100)]
        let dstUnion = [
            makeRecord(filename: "A.mov", path: "/Volumes/SSD/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "A.mov", path: "/Volumes/Backup/A.mov", md5: "a1", size: 100),
            makeRecord(filename: "A.mov", path: "/Volumes/Archive/A.mov", md5: "a1", size: 100)
        ]
        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dstUnion,
            sourcePath: "/Volumes/MacPro", destPath: "",
            destLabel: "any other cataloged volume", isAuditMode: true
        )

        #expect(result.alreadySafeCount == 1, "Safe count follows source side, not dest multiplicity")
        #expect(result.sourceOnly == 0)
    }

    @Test func auditMode_defaultsPreserveNonAuditBehavior() {
        // Calling compare without specifying audit flags must preserve old semantics.
        let src = [makeRecord(filename: "A.mov", path: "/Volumes/Old/A.mov", md5: "a1", size: 100)]
        let dst = [makeRecord(filename: "A.mov", path: "/Volumes/New/A.mov", md5: "a1", size: 100)]
        let result = VolumeComparer.compare(sourceRecords: src, destRecords: dst,
                                            sourcePath: "/Volumes/Old", destPath: "/Volumes/New")

        #expect(result.isAuditMode == false)
        #expect(result.destLabel == "New", "Label defaults to the last path component of destPath")
        #expect(result.alreadySafeCount == 1)
    }

    // MARK: - Multi-source / multi-dest (issue #33 — local-vs-remote audit)

    /// Mirrors the UI's "union records under any of these paths" logic.
    private func recordsUnder(_ paths: [String], from all: [VideoRecord]) -> [VideoRecord] {
        all.filter { rec in paths.contains(where: { rec.fullPath.hasPrefix($0) }) }
    }

    @Test func multiSource_sameMachineDuplicatesDoNotCountAsBackup() {
        // Rick's real case: InternalRaid + ExternalRaid both live on MacPro.
        // A file that exists on both should STILL flag as missing when the "dest"
        // is "anything outside the MacPro volume set" — the same machine dying
        // kills both copies.
        let allRecords = [
            makeRecord(filename: "precious.mov", path: "/Volumes/InternalRaid/precious.mov", md5: "p1", size: 1000),
            makeRecord(filename: "precious.mov", path: "/Volumes/ExternalRaid/precious.mov", md5: "p1", size: 1000)
            // No copy anywhere off-MacPro.
        ]
        let macProVolumes = ["/Volumes/InternalRaid", "/Volumes/ExternalRaid"]

        let src = recordsUnder(macProVolumes, from: allRecords)
        let dst = allRecords.filter { rec in
            !macProVolumes.contains(where: { rec.fullPath.hasPrefix($0) })
        }
        #expect(dst.isEmpty, "No off-MacPro records means nothing can count as backup")

        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "InternalRaid, ExternalRaid", destPath: "",
            destLabel: "any volume outside the source set", isAuditMode: true
        )

        #expect(result.sourceOnly == 2, "Both copies should flag as missing — neither is off-MacPro")
        #expect(result.alreadySafeCount == 0)
    }

    @Test func multiSource_backupOnOffMachineVolumeCountsAsSafe() {
        // Same MacPro file, but this time MyBook3Terabytes (external to MacPro) has it.
        let allRecords = [
            makeRecord(filename: "precious.mov", path: "/Volumes/InternalRaid/precious.mov", md5: "p1", size: 1000),
            makeRecord(filename: "precious.mov", path: "/Volumes/ExternalRaid/precious.mov", md5: "p1", size: 1000),
            makeRecord(filename: "precious.mov", path: "/Volumes/MyBook3TB/precious.mov", md5: "p1", size: 1000)
        ]
        let macProVolumes = ["/Volumes/InternalRaid", "/Volumes/ExternalRaid"]

        let src = recordsUnder(macProVolumes, from: allRecords)
        let dst = allRecords.filter { rec in
            !macProVolumes.contains(where: { rec.fullPath.hasPrefix($0) })
        }

        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "InternalRaid, ExternalRaid", destPath: "",
            destLabel: "any volume outside the source set", isAuditMode: true
        )

        #expect(result.sourceOnly == 0, "Both MacPro copies are safe — MyBook has a copy")
        #expect(result.alreadySafeCount == 2)
    }

    @Test func multiDest_checkAgainstExplicitBackupSet() {
        // "Are MacPro files backed up on MacStudio or MyBook, specifically?"
        // This is the explicit-dest version: treat a file as safe only if it
        // exists on one of the declared backup volumes.
        let allRecords = [
            makeRecord(filename: "A.mov", path: "/Volumes/InternalRaid/A.mov", md5: "a", size: 100),
            makeRecord(filename: "B.mov", path: "/Volumes/InternalRaid/B.mov", md5: "b", size: 200),
            makeRecord(filename: "C.mov", path: "/Volumes/InternalRaid/C.mov", md5: "c", size: 300),

            makeRecord(filename: "A.mov", path: "/Volumes/MacStudio/A.mov", md5: "a", size: 100),  // safe
            makeRecord(filename: "B.mov", path: "/Volumes/MyBook3TB/B.mov", md5: "b", size: 200),  // safe
            // C.mov has no backup on declared destinations
            makeRecord(filename: "C.mov", path: "/Volumes/SomeOtherDrive/C.mov", md5: "c", size: 300)  // ignored — not a picked dest
        ]
        let srcVols = ["/Volumes/InternalRaid"]
        let dstVols = ["/Volumes/MacStudio", "/Volumes/MyBook3TB"]

        let src = recordsUnder(srcVols, from: allRecords)
        let dst = recordsUnder(dstVols, from: allRecords)

        let result = VolumeComparer.compare(
            sourceRecords: src, destRecords: dst,
            sourcePath: "InternalRaid", destPath: "",
            destLabel: "MacStudio, MyBook3TB", isAuditMode: true
        )

        #expect(result.sourceOnly == 1, "C.mov has no copy on the declared backup set")
        #expect(result.missingFiles.first?.filename == "C.mov")
        #expect(result.alreadySafeCount == 2)
    }
}

// MARK: - Test Media Generator Tests

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
        // MXF audio-only not supported by ffmpeg; use MXF video + WAV audio (real Avid workflow)
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

// MARK: - Catalog Import/Export Tests
//
// Covers the cross-machine catalog sharing feature: records exported from
// one Mac and imported on another should merge without creating duplicates,
// while records genuinely new to the local catalog should be added and
// tagged with the source host.

@MainActor
struct CatalogImportExportTests {

    /// Helper: build a minimal record with content identity.
    private func makeRec(name: String, md5: String, size: Int64, duration: Double = 10) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.partialMD5 = md5
        r.sizeBytes = size
        r.durationSeconds = duration
        r.streamTypeRaw = "Video+Audio"
        r.fullPath = "/Volumes/RemoteDrive/\(name)"
        return r
    }

    /// Round-trip: export, import into an empty catalog, confirm all records land.
    @Test func exportThenImportIntoEmptyCatalogAddsEverything() throws {
        let source = VideoScanModel()
        // Isolate the test from any persisted catalog on this machine.
        source.records = []
        source.records = [
            makeRec(name: "a.mov", md5: "AAAA", size: 100),
            makeRec(name: "b.mov", md5: "BBBB", size: 200)
        ]

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try source.exportCatalog(to: tmp)

        let dest = VideoScanModel()
        dest.records = []
        let result = try dest.importCatalog(from: tmp)

        #expect(result.added == 2)
        #expect(result.skipped == 0)
        #expect(dest.records.count == 2)
        // Imported records get stamped with the exporting host.
        #expect(dest.records.allSatisfy { !$0.sourceHost.isEmpty })
    }

    /// Content-identity dedup: importing a record the local catalog already has
    /// (same partialMD5 + sizeBytes) must skip it rather than duplicating.
    @Test func importSkipsRecordsAlreadyPresentByContentIdentity() throws {
        let source = VideoScanModel()
        source.records = [
            makeRec(name: "shared.mov", md5: "SAME", size: 500),
            makeRec(name: "new.mov", md5: "NEW", size: 700)
        ]

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try source.exportCatalog(to: tmp)

        // Destination already has the same file (same MD5 + size), different path.
        let dest = VideoScanModel()
        let existing = makeRec(name: "shared.mov", md5: "SAME", size: 500)
        existing.fullPath = "/Volumes/LocalDrive/shared.mov"
        dest.records = [existing]

        let result = try dest.importCatalog(from: tmp)

        #expect(result.added == 1)
        #expect(result.skipped == 1)
        #expect(dest.records.count == 2)
        // The local record was preserved — the import did not overwrite its path.
        #expect(dest.records.contains { $0.fullPath == "/Volumes/LocalDrive/shared.mov" })
        // The new record from the import is present.
        #expect(dest.records.contains { $0.partialMD5 == "NEW" })
    }
}

// MARK: - ScanContext Tests
//
// Phase 1 provenance capture. These tests cover:
//   - Struct defaults & isPopulated heuristic
//   - Codable round-trip (must decode cleanly from JSON that omits the field)
//   - parseRemoteServer for SMB/NFS/AFP/WebDAV/local mount strings
//   - capture() against a local path produces a populated, non-remote context
//
// No real remote mounts are required — parseRemoteServer is pure and runs
// against synthetic mntfromname strings.

struct ScanContextTests {

    @Test func defaultsAreEmpty() {
        let ctx = ScanContext()
        #expect(ctx.scanHost.isEmpty)
        #expect(ctx.volumeUUID.isEmpty)
        #expect(ctx.volumeMountType.isEmpty)
        #expect(ctx.remoteServerName.isEmpty)
        #expect(ctx.scannedAt == nil)
        #expect(ctx.isPopulated == false)
        #expect(ctx.isRemoteMount == false)
    }

    @Test func isPopulatedFlipsOnAnyField() {
        var ctx = ScanContext()
        ctx.scanHost = "MacStudio"
        #expect(ctx.isPopulated == true)

        ctx = ScanContext()
        ctx.volumeUUID = "ABCD-1234"
        #expect(ctx.isPopulated == true)

        ctx = ScanContext()
        ctx.volumeMountType = "apfs"
        #expect(ctx.isPopulated == true)
    }

    @Test func isRemoteMountDetectsNetworkFilesystems() {
        for fs in ["smbfs", "nfs", "afpfs", "webdav"] {
            var ctx = ScanContext()
            ctx.volumeMountType = fs
            #expect(ctx.isRemoteMount == true, "\(fs) should be remote")
        }
        for fs in ["apfs", "hfs", "msdos", "exfat", ""] {
            var ctx = ScanContext()
            ctx.volumeMountType = fs
            #expect(ctx.isRemoteMount == false, "\(fs) should be local")
        }
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        var ctx = ScanContext()
        ctx.scanHost = "MacStudio"
        ctx.volumeUUID = "A8F2-1234-5678-9ABC"
        ctx.volumeMountType = "smbfs"
        ctx.remoteServerName = "macpro.local"
        ctx.scannedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(ctx)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let round = try dec.decode(ScanContext.self, from: data)

        #expect(round == ctx)
    }

    @Test func decodeFromEmptyJSONYieldsDefaults() throws {
        // Forward compatibility: an object with no known keys must decode to defaults.
        let data = Data("{}".utf8)
        let ctx = try JSONDecoder().decode(ScanContext.self, from: data)
        #expect(ctx == ScanContext())
    }

    // MARK: parseRemoteServer

    @Test func parseRemoteServerSMB() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "smbfs", mntFromName: "//macpro.local/FamilyMedia") == "macpro.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "smbfs", mntFromName: "//rick@macpro.local/share") == "macpro.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "smbfs", mntFromName: "//DOMAIN;user@host/share") == "host")
    }

    @Test func parseRemoteServerNFS() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "nfs", mntFromName: "nas.local:/export/media") == "nas.local")
    }

    @Test func parseRemoteServerAFP() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "afpfs", mntFromName: "afp://oldserver.local/Share") == "oldserver.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "afpfs", mntFromName: "afp://rick@oldserver.local/Share") == "oldserver.local")
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "afpfs", mntFromName: "//oldserver.local/Share") == "oldserver.local")
    }

    @Test func parseRemoteServerWebDAV() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "webdav", mntFromName: "https://cloud.example.com/dav/files") == "cloud.example.com")
    }

    @Test func parseRemoteServerLocalReturnsEmpty() {
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "apfs", mntFromName: "/dev/disk3s1").isEmpty)
        #expect(VolumeReachability.parseRemoteServer(
            fsType: "hfs", mntFromName: "/dev/disk4").isEmpty)
    }

    // MARK: capture (integration)

    @Test func captureForLocalTempDirectoryPopulatesContext() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ScanContext.capture(for: tmp)

        // scanHost must be set — CatalogHost.currentName is never empty on macOS.
        #expect(!ctx.scanHost.isEmpty)
        // /tmp on macOS is apfs or hfs — in any case, not a network FS.
        #expect(ctx.isRemoteMount == false)
        // Mount type should be non-empty on any working Mac.
        #expect(!ctx.volumeMountType.isEmpty)
        // Remote server name must be empty for local mounts.
        #expect(ctx.remoteServerName == "")
        #expect(ctx.scannedAt != nil)
        #expect(ctx.isPopulated == true)
    }
}

// MARK: - ScanEngine.humanReadableDiagnosis Tests
//
// humanReadableDiagnosis translates raw ffprobe stderr into a human-readable
// (label, detail) pair used in the catalog's "Is Playable" and "Notes" columns.
// Pure function — no I/O — covers corrupted, truncated, permission, network,
// missing, empty, and fallback cases.

struct HumanReadableDiagnosisTests {

    @Test func moovAtomNotFoundReportsDamaged() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "moov atom not found")
        #expect(d.label == "Damaged file")
        #expect(d.detail.contains("moov atom not found"))
    }

    @Test func moovAtomMatchesCaseInsensitively() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "ERROR: MOOV ATOM NOT FOUND in stream")
        #expect(d.label == "Damaged file")
    }

    @Test func invalidDataReportsDamaged() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "Invalid data found when processing input")
        #expect(d.label == "Damaged file")
        #expect(d.detail.contains("invalid data found"))
    }

    @Test func endOfFileReportsTruncated() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "unexpected end of file")
        #expect(d.label == "Truncated file")
        // detail includes the raw stderr so the user can see what ffmpeg said
        #expect(d.detail.contains("unexpected end of file"))
    }

    @Test func truncatedKeywordReportsTruncated() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "stream is truncated at byte 12345")
        #expect(d.label == "Truncated file")
    }

    @Test func permissionDeniedReportsAccess() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "Permission denied opening file")
        #expect(d.label == "Access denied")
    }

    @Test func timeoutReportsNetworkTimeout() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "read: Operation timed out")
        #expect(d.label == "Network timeout")
    }

    @Test func noSuchFileReportsFileNotFound() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "open: No such file or directory")
        #expect(d.label == "File not found")
    }

    @Test func emptyStderrReportsUnreadableWithoutDetail() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "")
        #expect(d.label == "Unreadable file")
        #expect(d.detail.contains("no additional details"))
    }

    @Test func unknownStderrFallsBackToRawStderr() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "some unrecognized ffmpeg warning")
        #expect(d.label == "Unreadable file")
        // Fallback should include the raw stderr for the user
        #expect(d.detail.contains("some unrecognized ffmpeg warning"))
    }

    @Test func priorityMoovBeforeTruncated() {
        // If multiple patterns match, the earlier check wins. moov atom is
        // checked before truncated — stderr containing both should be classified
        // as "Damaged file" (more specific) not "Truncated file".
        let d = ScanEngine.humanReadableDiagnosis(stderr: "moov atom not found; stream appears truncated")
        #expect(d.label == "Damaged file")
    }
}

// MARK: - ScanEngine.extractMetadata Tests
//
// extractMetadata populates a VideoRecord from an FFProbeOutput. Covers:
// - video+audio, video-only, audio-only, no-streams classification
// - format-level fields (duration, bitrate, container)
// - format tag fallback for timecode/tapeName across different tag keys
// - stream-level tag fallback when format has no timecode
// - missing/empty field handling

struct ExtractMetadataTests {

    /// Build an FFProbeOutput from a JSON literal — avoids memberwise init
    /// since FFStream/FFFormat are all optionals.
    private static func probe(_ json: String) throws -> FFProbeOutput {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(FFProbeOutput.self, from: data)
    }

    @Test func videoAndAudioClassifiedCorrectly() throws {
        let probe = try Self.probe("""
        {
          "format": {"format_name": "mov,mp4,m4a", "duration": "12.5", "bit_rate": "5000000"},
          "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
             "r_frame_rate": "30000/1001"},
            {"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000"}
          ]
        }
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(rec.videoCodec == "h264")
        #expect(rec.audioCodec == "aac")
        #expect(rec.resolution == "1920x1080")
        #expect(rec.audioChannels == "2")
        #expect(rec.audioSampleRate == "48000 Hz")
        #expect(rec.durationSeconds == 12.5)
        #expect(rec.totalBitrate == "5000 kbps")
        #expect(rec.isPlayable == "Yes")
    }

    @Test func videoOnlyClassifiedCorrectly() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "prores", "width": 1280, "height": 720,
                      "r_frame_rate": "24/1"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoOnly.rawValue)
        #expect(rec.videoCodec == "prores")
        #expect(rec.audioCodec.isEmpty)
        #expect(rec.isPlayable == "Yes")
    }

    @Test func audioOnlyClassifiedCorrectly() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "audio", "codec_name": "pcm_s24le", "channels": 2, "sample_rate": "48000"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.audioOnly.rawValue)
        #expect(rec.audioCodec == "pcm_s24le")
        #expect(rec.videoCodec.isEmpty)
        #expect(rec.isPlayable == "Yes")
    }

    @Test func noStreamsReportsNoStreams() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "unknown"}, "streams": []}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.noStreams.rawValue)
        #expect(rec.isPlayable == "No streams")
    }

    @Test func missingResolutionLeavesFieldEmpty() throws {
        // Zero dimensions should not produce "0x0"
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "h264", "width": 0, "height": 0,
                      "r_frame_rate": "30/1"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.resolution.isEmpty)
    }

    @Test func timecodeFromFormatTags() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "mov", "tags": {"timecode": "01:00:00:00"}},
         "streams": [{"codec_type": "video", "codec_name": "h264"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.timecode == "01:00:00:00")
    }

    @Test func timecodeFromStreamTagsWhenFormatLacksIt() throws {
        // Format has no timecode tag — should fall through to stream tags
        let probe = try Self.probe("""
        {"format": {"format_name": "mov"},
         "streams": [{"codec_type": "video", "codec_name": "h264",
                      "tags": {"timecode": "02:00:00:00"}}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.timecode == "02:00:00:00")
    }

    @Test func tapeNameFromReelNameTag() throws {
        // Avid MXF files use "reel_name" rather than "tape_name"
        let probe = try Self.probe("""
        {"format": {"format_name": "mxf", "tags": {"reel_name": "REEL007"}},
         "streams": [{"codec_type": "video", "codec_name": "dnxhd"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.tapeName == "REEL007")
    }

    @Test func tapeNameFromAppleReelNameTag() throws {
        // QuickTime exports use a com.apple.quicktime key
        let probe = try Self.probe("""
        {"format": {"format_name": "mov",
                    "tags": {"com.apple.quicktime.reelname": "APPLE_REEL"}},
         "streams": [{"codec_type": "video", "codec_name": "h264"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.tapeName == "APPLE_REEL")
    }

    @Test func frameRateParsedFromRational() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "h264",
                      "r_frame_rate": "30000/1001"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        // 30000/1001 ≈ 29.97
        #expect(rec.frameRate == "29.97")
    }

    @Test func falsybitRateDoesNotCrash() throws {
        // Non-numeric bit_rate string should be silently ignored, not crash
        let probe = try Self.probe("""
        {"format": {"format_name": "mov", "bit_rate": "N/A"},
         "streams": [{"codec_type": "video", "codec_name": "h264", "bit_rate": "N/A"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.totalBitrate.isEmpty)
        #expect(rec.videoBitrate.isEmpty)
    }

    @Test func multipleVideoStreamsUseFirstOnly() throws {
        // Record model stores a single video codec — subsequent video streams ignored
        let probe = try Self.probe("""
        {"format": null,
         "streams": [
           {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080},
           {"codec_type": "video", "codec_name": "prores", "width": 3840, "height": 2160}
         ]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.videoCodec == "h264")
        #expect(rec.resolution == "1920x1080")
    }
}

// MARK: - POIStorage Tests

/// Tests for POIStorage path derivation and legacy-layout migration
/// (issue #35). Uses scratch directories under /tmp so tests don't
/// interfere with the real user-data store.
struct POIStorageTests {

    @Test func sanitizeNormalizesName() {
        #expect(POIStorage.sanitize("Rick") == "rick")
        #expect(POIStorage.sanitize("Mary Beth") == "mary_beth")
        #expect(POIStorage.sanitize("  Timmy  ") == "timmy")
        #expect(POIStorage.sanitize("") == "reference")
        #expect(POIStorage.sanitize("   ") == "reference")
    }

    @Test func folderForReturnsPerPersonPath() {
        let donna = POIStorage.folder(for: "Donna")
        let rick = POIStorage.folder(for: "Rick")
        #expect(donna.lastPathComponent == "donna")
        #expect(rick.lastPathComponent == "rick")
        // Same person with different casing → same folder.
        #expect(POIStorage.folder(for: "DONNA").path == donna.path)
    }

    @Test func profileURLEndsWithProfileJson() {
        let url = POIStorage.profileURL(for: "Rick")
        #expect(url.lastPathComponent == "profile.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "rick")
    }

    @Test func storeDirIsUnderApplicationSupport() {
        let dir = POIStorage.storeDir
        #expect(dir.path.contains("Application Support"))
        #expect(dir.path.contains("VideoScan"))
        #expect(dir.lastPathComponent == "POI")
    }

    /// End-to-end: write a legacy-shaped JSON + photos to a scratch tree,
    /// run the migrator pointed at it, verify the new layout comes out
    /// right. We exercise the migration by calling migrateOne indirectly
    /// through a temp-directory reroute — but since POIStorage hardcodes
    /// paths, we verify via a self-contained integration check instead:
    /// the migrator is idempotent when the new store is empty AND no
    /// legacy data exists, so calling it repeatedly in a clean env must
    /// return .notNeeded without side effects.
    @Test func migrationIdempotentWhenNothingToDo() {
        // First call — might migrate real legacy data if present, or not.
        let first = POIStorage.migrateLegacyIfNeeded()
        // Second call must be a no-op because the store now has entries
        // (either pre-existing or just-migrated).
        let second = POIStorage.migrateLegacyIfNeeded()
        _ = first  // silence unused warning; its value depends on dev env
        #expect(second == .notNeeded)
    }
}

// MARK: - CombineJobStatus Tests

struct CombineJobStatusTests {

    @Test func defaultPhaseIsQueued() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(job.phase == .queued)
        #expect(job.progressFraction == 0)
        #expect(job.isPaused == false)
        #expect(job.technique == .streamCopy)
    }

    @Test func estimatedBytes() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1_000_000, audioSizeBytes: 500_000,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(job.estimatedBytes == 1_500_000)
    }

    @Test func bothOnlineRequiresBoth() {
        let online = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(online.bothOnline == true)

        let partial = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: false
        )
        #expect(partial.bothOnline == false)
    }

    @Test func elapsedNilWhenNotStarted() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        #expect(job.elapsed == nil)
    }

    @Test func elapsedComputesWhenStarted() {
        var job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )
        job.startTime = Date().addingTimeInterval(-5)
        let elapsed = job.elapsed!
        #expect(elapsed >= 4.5 && elapsed <= 6.0)
    }

    @Test func phaseRawValues() {
        #expect(CombineJobStatus.CombinePhase.queued.rawValue == "Queued")
        #expect(CombineJobStatus.CombinePhase.buffering.rawValue == "Buffering")
        #expect(CombineJobStatus.CombinePhase.muxing.rawValue == "Muxing")
        #expect(CombineJobStatus.CombinePhase.verifying.rawValue == "Verifying")
        #expect(CombineJobStatus.CombinePhase.done.rawValue == "Verified")
        #expect(CombineJobStatus.CombinePhase.failed.rawValue == "Failed")
        #expect(CombineJobStatus.CombinePhase.skipped.rawValue == "Already Combined")
    }

    @Test func techniqueRawValues() {
        #expect(CombineJobStatus.CombineTechnique.streamCopy.rawValue == "Stream Copy")
        #expect(CombineJobStatus.CombineTechnique.reencodeProRes.rawValue == "Re-encode → ProRes")
        #expect(CombineJobStatus.CombineTechnique.reencodeH264.rawValue == "Re-encode → H.264")
    }
}

// MARK: - CombineEngine Extended Tests

struct CombineEngineExtendedTests {

    /// Helper: attempt to decode one frame of a given stream type.
    /// Mirrors the app's decodeTestFrame logic so tests verify the same thing.
    private static func canDecodeFrame(path: String, streamType: String) async -> Bool {
        let args: [String]
        if streamType == "v" {
            args = ["-v", "error", "-i", path, "-map", "0:v:0", "-vframes", "1", "-f", "null", "-"]
        } else {
            args = ["-v", "error", "-i", path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CombineEngine.ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return proc.terminationStatus == 0 && errStr.isEmpty
    }

    /// Full verification matching the app's verifyCombineOutput:
    /// probe streams, check dimensions, decode one video frame, decode one audio frame.
    private static func fullVerify(path: String, expectedDuration: Double) async -> (ok: Bool, reason: String) {
        let (probe, _) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: path))
        let streams = probe?.streams ?? []
        guard let vStream = streams.first(where: { $0.codec_type == "video" }) else {
            return (false, "no video stream")
        }
        guard streams.contains(where: { $0.codec_type == "audio" }) else {
            return (false, "no audio stream")
        }
        if (vStream.width ?? 0) == 0 || (vStream.height ?? 0) == 0 {
            return (false, "video has no dimensions")
        }
        let outDuration = Double(probe?.format?.duration ?? "0") ?? 0
        let tolerance = max(expectedDuration * 0.1, 2.0)
        if expectedDuration > 0 && outDuration > 0 && abs(outDuration - expectedDuration) > tolerance {
            return (false, "duration mismatch: expected \(expectedDuration), got \(outDuration)")
        }
        if !(await canDecodeFrame(path: path, streamType: "v")) {
            return (false, "video frame decode failed")
        }
        if !(await canDecodeFrame(path: path, streamType: "a")) {
            return (false, "audio frame decode failed")
        }
        return (true, "")
    }

    /// Helper: run ffmpeg volumedetect and return mean_volume in dB.
    private static func detectMeanVolume(path: String) async -> Double? {
        let args = ["-v", "info", "-i", path, "-map", "0:a:0",
                    "-af", "volumedetect", "-f", "null", "-"]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CombineEngine.ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: .newlines) {
            if line.contains("mean_volume:") {
                let parts = line.components(separatedBy: "mean_volume:")
                if parts.count > 1 {
                    let dbStr = parts[1].trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " dB", with: "")
                    return Double(dbStr)
                }
            }
        }
        return nil
    }

    // MARK: - Positive Tests

    @Test func combineValidPairStreamCopy() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 3.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_test_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        #expect(result.success == true)
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outPath))

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 3.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")
    }

    @Test func combineWithProgressReporting() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 3.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_progress_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        var progressValues: [Double] = []
        let lock = NSLock()

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            durationSeconds: 3.0,
            onProgress: { frac in
                lock.lock()
                progressValues.append(frac)
                lock.unlock()
            },
            log: { _ in }
        )

        #expect(result.success == true)
        #expect(progressValues.count > 0)

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 3.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")
    }

    @Test func combineReencodeH264() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 2.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_h264_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .reencodeH264,
            log: { _ in }
        )

        #expect(result.success == true)
        #expect(FileManager.default.fileExists(atPath: outPath))

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 2.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")

        let (probe, _) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: outPath))
        let streams = probe?.streams ?? []
        let vCodec = streams.first(where: { $0.codec_type == "video" })?.codec_name
        let aCodec = streams.first(where: { $0.codec_type == "audio" })?.codec_name
        #expect(vCodec == "h264")
        #expect(aCodec == "aac")
    }

    @Test func verifyDurationWithinTolerance() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 5.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_dur_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 5.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")
    }

    // MARK: - Negative Tests: Missing Inputs

    @Test func combineFailsMissingVideoFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audio = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(audio) }

        let outPath = NSTemporaryDirectory() + "combine_fail_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: "/tmp/nonexistent_video_\(UUID()).mp4",
            audioPath: audio,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        #expect(result.success == false)
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: outPath))
    }

    @Test func combineFailsMissingAudioFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let video = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(video) }

        let outPath = NSTemporaryDirectory() + "combine_fail2_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: video,
            audioPath: "/tmp/nonexistent_audio_\(UUID()).m4a",
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        #expect(result.success == false)
        #expect(result.exitCode != 0)
    }

    // MARK: - Negative Tests: Stream Content Validation

    @Test func verifyDetectsVideoOnlyOutput() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let videoOnly = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(videoOnly) }

        let verify = await Self.fullVerify(path: videoOnly, expectedDuration: 2.0)
        #expect(verify.ok == false)
        #expect(verify.reason.contains("no audio"))
    }

    @Test func verifyDetectsAudioOnlyOutput() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audioOnly = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(audioOnly) }

        let verify = await Self.fullVerify(path: audioOnly, expectedDuration: 2.0)
        #expect(verify.ok == false)
        #expect(verify.reason.contains("no video"))
    }

    @Test func verifyDetectsTwoAudioFilesMuxedAsVideoAudio() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audio1 = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0, prefix: "test_fake_v"
        )
        let audio2 = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0, prefix: "test_fake_a"
        )
        defer { TestMediaGenerator.cleanup(audio1, audio2) }

        let outPath = NSTemporaryDirectory() + "combine_2audio_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: audio1,
            audioPath: audio2,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        if result.success && FileManager.default.fileExists(atPath: outPath) {
            let verify = await Self.fullVerify(path: outPath, expectedDuration: 2.0)
            #expect(verify.ok == false, "Should fail: two audio files muxed together have no real video")
        }
    }

    @Test func verifyDecodesRealFramesInValidCombine() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 2.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_decode_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let canVideo = await Self.canDecodeFrame(path: outPath, streamType: "v")
        let canAudio = await Self.canDecodeFrame(path: outPath, streamType: "a")
        #expect(canVideo == true, "Must be able to decode a real video frame")
        #expect(canAudio == true, "Must be able to decode a real audio frame")
    }

    @Test func cannotDecodeVideoFromAudioOnlyFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audioOnly = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(audioOnly) }

        let canVideo = await Self.canDecodeFrame(path: audioOnly, streamType: "v")
        #expect(canVideo == false, "Audio-only file should fail video decode")
    }

    @Test func cannotDecodeAudioFromVideoOnlyFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let videoOnly = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(videoOnly) }

        let canAudio = await Self.canDecodeFrame(path: videoOnly, streamType: "a")
        #expect(canAudio == false, "Video-only file should fail audio decode")
    }

    // MARK: - Silence Detection

    @Test func realAudioHasAudibleLevel() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 2.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_audible_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let meanDB = await Self.detectMeanVolume(path: outPath)
        #expect(meanDB != nil, "Should detect audio level")
        #expect(meanDB! > -60, "440Hz sine tone should be well above silence threshold, got \(meanDB!) dB")
    }

    @Test func silentAudioDetectedBelowThreshold() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let video = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        let tmpDir = NSTemporaryDirectory()
        let silentAudio = tmpDir + "silent_audio_\(UUID().uuidString.prefix(8)).m4a"
        defer {
            TestMediaGenerator.cleanup(video)
            try? FileManager.default.removeItem(atPath: silentAudio)
        }

        let silProc = Process()
        silProc.executableURL = URL(fileURLWithPath: CombineEngine.ffmpegPath)
        silProc.arguments = ["-y", "-hide_banner", "-loglevel", "error",
                             "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                             "-t", "2", "-c:a", "aac", silentAudio]
        silProc.standardOutput = FileHandle.nullDevice
        silProc.standardError = FileHandle.nullDevice
        try silProc.run()
        silProc.waitUntilExit()

        let outPath = tmpDir + "combine_silent_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: video,
            audioPath: silentAudio,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let meanDB = await Self.detectMeanVolume(path: outPath)
        #expect(meanDB != nil, "Should detect audio level even for silence")
        #expect(meanDB! < -60, "Silent audio should be below -60 dB, got \(meanDB!) dB")
    }

    // MARK: - Buffered Copy

    @Test func bufferedCopyProducesIdenticalFile() async throws {
        let srcPath = NSTemporaryDirectory() + "buf_src_\(UUID().uuidString.prefix(8)).bin"
        let dstPath = NSTemporaryDirectory() + "buf_dst_\(UUID().uuidString.prefix(8)).bin"
        defer {
            try? FileManager.default.removeItem(atPath: srcPath)
            try? FileManager.default.removeItem(atPath: dstPath)
        }

        let testData = Data(repeating: 0xAB, count: 1024 * 1024)
        try testData.write(to: URL(fileURLWithPath: srcPath))

        try await CombineEngine.bufferedCopy(
            from: URL(fileURLWithPath: srcPath),
            to: URL(fileURLWithPath: dstPath)
        )

        let copied = try Data(contentsOf: URL(fileURLWithPath: dstPath))
        #expect(copied == testData)
    }

    @Test func bufferedCopyFailsForMissingSource() async {
        let dstPath = NSTemporaryDirectory() + "buf_dst_missing_\(UUID().uuidString.prefix(8)).bin"
        defer { try? FileManager.default.removeItem(atPath: dstPath) }

        do {
            try await CombineEngine.bufferedCopy(
                from: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID()).bin"),
                to: URL(fileURLWithPath: dstPath)
            )
            #expect(Bool(false), "should have thrown")
        } catch {
            #expect(true)
        }
    }
}

// MARK: - DashboardState Combine Counter Tests

struct DashboardCombineCounterTests {

    @Test @MainActor func resetForCombineClearsCounters() {
        let dash = DashboardState()
        dash.combineSucceeded = 5
        dash.combineFailed = 2
        dash.combineSkipped = 3
        dash.combineCompleted = 10
        dash.combineCurrentFile = "foo.mov"
        dash.combineJobs = [CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )]

        dash.resetForCombine(total: 7)

        #expect(dash.combineTotal == 7)
        #expect(dash.combineCompleted == 0)
        #expect(dash.combineSucceeded == 0)
        #expect(dash.combineFailed == 0)
        #expect(dash.combineSkipped == 0)
        #expect(dash.combineCurrentFile == "")
        #expect(dash.combineJobs.isEmpty)
        #expect(dash.combineStartTime != nil)
    }

    @Test @MainActor func countersAddUpToCompleted() {
        let dash = DashboardState()
        dash.resetForCombine(total: 6)

        dash.combineSucceeded = 3
        dash.combineFailed = 1
        dash.combineSkipped = 2
        dash.combineCompleted = 6

        #expect(dash.combineSucceeded + dash.combineFailed + dash.combineSkipped == dash.combineCompleted)
    }
}

// MARK: - Catalog Navigation Tests (Issue #39)

struct CatalogNavigationTests {

    @Test func singleRecordNoPairMode() {
        let rec = VideoRecord()
        rec.filename = "test.mov"
        let ids = VideoScanModel.catalogFilterIDs(for: rec.id, pairMode: false, in: [rec])
        #expect(ids == [rec.id])
    }

    @Test func pairModeWithPairedWith() {
        let video = VideoRecord()
        video.filename = "clip.V1A.mxf"
        video.streamTypeRaw = "Video only"
        let audio = VideoRecord()
        audio.filename = "clip.A1A.mxf"
        audio.streamTypeRaw = "Audio only"
        video.pairedWith = audio

        let ids = VideoScanModel.catalogFilterIDs(for: video.id, pairMode: true, in: [video, audio])
        #expect(ids.count == 2)
        #expect(ids.contains(video.id))
        #expect(ids.contains(audio.id))
    }

    @Test func pairModeWithPairGroupIDFallback() {
        // This is the bug case: pairedWith is nil but pairGroupID links them
        let gid = UUID()
        let video = VideoRecord()
        video.filename = "clip.V1A.mxf"
        video.streamTypeRaw = "Video only"
        video.pairGroupID = gid

        let audio = VideoRecord()
        audio.filename = "clip.A1A.mxf"
        audio.streamTypeRaw = "Audio only"
        audio.pairGroupID = gid

        // pairedWith is nil on both — only pairGroupID connects them
        #expect(video.pairedWith == nil)
        #expect(audio.pairedWith == nil)

        let ids = VideoScanModel.catalogFilterIDs(for: video.id, pairMode: true, in: [video, audio])
        #expect(ids.count == 2, "Should find partner via pairGroupID when pairedWith is nil")
        #expect(ids.contains(video.id))
        #expect(ids.contains(audio.id))
    }

    @Test func pairModeFromAudioSide() {
        // Navigate from the audio record — should still find the video partner
        let gid = UUID()
        let video = VideoRecord()
        video.filename = "clip.V1A.mxf"
        video.streamTypeRaw = "Video only"
        video.pairGroupID = gid

        let audio = VideoRecord()
        audio.filename = "clip.A1A.mxf"
        audio.streamTypeRaw = "Audio only"
        audio.pairGroupID = gid

        let ids = VideoScanModel.catalogFilterIDs(for: audio.id, pairMode: true, in: [video, audio])
        #expect(ids.count == 2)
        #expect(ids.contains(video.id))
        #expect(ids.contains(audio.id))
    }

    @Test func pairModeRecordNotFound() {
        let bogusID = UUID()
        let ids = VideoScanModel.catalogFilterIDs(for: bogusID, pairMode: true, in: [])
        #expect(ids == [bogusID], "Should return the requested ID even if record isn't found")
    }

    @Test func pairModeNoPairAtAll() {
        // Record exists but has no pair info — should just return the one record
        let rec = VideoRecord()
        rec.filename = "standalone.mov"
        rec.streamTypeRaw = "Video+Audio"

        let ids = VideoScanModel.catalogFilterIDs(for: rec.id, pairMode: true, in: [rec])
        #expect(ids == [rec.id])
    }

    @Test func pairGroupIDDoesNotLeakOtherGroups() {
        let gid1 = UUID()
        let gid2 = UUID()

        let v1 = VideoRecord(); v1.pairGroupID = gid1; v1.streamTypeRaw = "Video only"
        let a1 = VideoRecord(); a1.pairGroupID = gid1; a1.streamTypeRaw = "Audio only"
        let v2 = VideoRecord(); v2.pairGroupID = gid2; v2.streamTypeRaw = "Video only"
        let a2 = VideoRecord(); a2.pairGroupID = gid2; a2.streamTypeRaw = "Audio only"

        let ids = VideoScanModel.catalogFilterIDs(for: v1.id, pairMode: true, in: [v1, a1, v2, a2])
        #expect(ids.count == 2, "Should only include records from the same pairGroupID")
        #expect(ids.contains(v1.id))
        #expect(ids.contains(a1.id))
        #expect(!ids.contains(v2.id))
        #expect(!ids.contains(a2.id))
    }
}

// MARK: - Combine Technique Propagation Tests (Issue #41)

// MARK: - Codec Compatibility Tests (Issue #1)

@Suite struct CodecCompatibilityTests {

    // --- Positive: safe codec combos ---

    @Test func h264AacIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: "aac")
        #expect(check.streamCopySafe == true)
        #expect(check.warning == nil)
    }

    @Test func hevcPcmIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "hevc", audioCodec: "pcm_s24le")
        #expect(check.streamCopySafe == true)
    }

    @Test func proresAlacIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "prores", audioCodec: "alac")
        #expect(check.streamCopySafe == true)
    }

    @Test func dnxhdMp3IsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "dnxhd", audioCodec: "mp3")
        #expect(check.streamCopySafe == true)
    }

    @Test func mjpegFlacIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "mjpeg", audioCodec: "flac")
        #expect(check.streamCopySafe == true)
    }

    @Test func dvvideoAc3IsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "dvvideo", audioCodec: "ac3")
        #expect(check.streamCopySafe == true)
    }

    @Test func rawvideoOpusIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "rawvideo", audioCodec: "opus")
        #expect(check.streamCopySafe == true)
    }

    // --- Negative: unsafe codec combos ---

    @Test func mpeg2VideoNotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "mpeg2video", audioCodec: "aac")
        #expect(check.streamCopySafe == false)
        #expect(check.warning != nil)
        #expect(check.warning!.contains("mpeg2video"))
    }

    @Test func wmv3NotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "wmv3", audioCodec: "wma")
        #expect(check.streamCopySafe == false)
        #expect(check.warning!.contains("wmv3"))
        #expect(check.warning!.contains("wma"))
    }

    @Test func vp9NotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "vp9", audioCodec: "vorbis")
        #expect(check.streamCopySafe == false)
    }

    @Test func safeVideoUnsafeAudio() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: "wma")
        #expect(check.streamCopySafe == false)
        #expect(check.warning!.contains("wma"))
        #expect(!check.warning!.contains("h264"))
    }

    @Test func unsafeVideoSafeAudio() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "theora", audioCodec: "aac")
        #expect(check.streamCopySafe == false)
        #expect(check.warning!.contains("theora"))
    }

    // --- Edge cases ---

    @Test func bothCodecsNilNotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: nil, audioCodec: nil)
        #expect(check.streamCopySafe == false)
    }

    @Test func emptyStringsNotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "", audioCodec: "")
        #expect(check.streamCopySafe == false)
    }

    @Test func videoOnlyIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: nil)
        #expect(check.streamCopySafe == true)
    }

    @Test func audioOnlyIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: nil, audioCodec: "aac")
        #expect(check.streamCopySafe == true)
    }

    @Test func caseInsensitive() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "H264", audioCodec: "AAC")
        #expect(check.streamCopySafe == true)
    }
}

@Suite @MainActor struct CombineTechniquePropagationTests {

    @Test func techniqueSetAtJobCreation() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true,
            technique: .reencodeProRes
        )
        #expect(job.technique == .reencodeProRes)
    }

    @Test func techniqueH264SetAtJobCreation() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true,
            technique: .reencodeH264
        )
        #expect(job.technique == .reencodeH264)
    }

    @Test func techniqueDefaultsToStreamCopy() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true
        )
        #expect(job.technique == .streamCopy)
    }

    @Test func dashboardResetClearsJobsAndCounters() {
        let dash = DashboardState()
        dash.combineCompleted = 5
        dash.combineSucceeded = 3
        dash.combineFailed = 1
        dash.combineSkipped = 1
        dash.combineJobs = [CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true
        )]
        dash.resetForCombine(total: 10)
        #expect(dash.combineTotal == 10)
        #expect(dash.combineCompleted == 0)
        #expect(dash.combineSucceeded == 0)
        #expect(dash.combineFailed == 0)
        #expect(dash.combineSkipped == 0)
        #expect(dash.combineJobs.isEmpty)
    }

    @Test func techniquePreservedAcrossMultipleJobs() {
        let dash = DashboardState()
        dash.resetForCombine(total: 3)
        for i in 0..<3 {
            dash.combineJobs.append(CombineJobStatus(
                pairIndex: i, videoFilename: "v\(i).mxf", audioFilename: "a\(i).mxf",
                outputFilename: "out\(i).mov", outputPath: "/tmp/out\(i).mov",
                videoSizeBytes: 1000, audioSizeBytes: 500,
                totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true,
                technique: .reencodeProRes
            ))
        }
        for job in dash.combineJobs {
            #expect(job.technique == .reencodeProRes)
        }
    }
}
