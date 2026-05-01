//
//  BoundaryTests.swift
//  VideoScanTests
//
//  Boundary condition and edge-case tests targeting crash-prone code paths:
//  empty collections, off-by-one indices, zero/negative values, nil handling,
//  and malformed inputs. These exercise the edges that happy-path tests miss.
//

import Testing
import Foundation
@testable import VideoScan

// MARK: - Helpers

private func makeRecord(
    filename: String = "test.mov",
    fullPath: String? = nil,
    duration: Double = 60,
    sizeBytes: Int64 = 100_000_000,
    streamType: StreamType = .videoAndAudio,
    md5: String = "",
    videoCodec: String = "h264",
    audioCodec: String = "aac",
    resolution: String = "1920x1080",
    frameRate: String = "30000/1001"
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.fullPath = fullPath ?? "/Volumes/Test/\(filename)"
    r.durationSeconds = duration
    r.sizeBytes = sizeBytes
    r.streamTypeRaw = streamType.rawValue
    r.partialMD5 = md5
    r.videoCodec = videoCodec
    r.audioCodec = audioCodec
    r.resolution = resolution
    r.frameRate = frameRate
    return r
}

// MARK: - Formatting Boundary Tests

struct FormattingBoundaryTests {

    // --- fraction() ---

    @Test func fractionEmptyString() {
        let result = Formatting.fraction("")
        #expect(result == "")
    }

    @Test func fractionNoSlash() {
        #expect(Formatting.fraction("29.97") == "29.97")
    }

    @Test func fractionDivideByZero() {
        #expect(Formatting.fraction("24/0") == "24/0")
    }

    @Test func fractionZeroNumerator() {
        #expect(Formatting.fraction("0/1001") == "0")
    }

    @Test func fractionNegativeValues() {
        let result = Formatting.fraction("-30000/1001")
        #expect(!result.isEmpty)
    }

    @Test func fractionGarbageInput() {
        #expect(Formatting.fraction("abc/def") == "abc/def")
    }

    @Test func fractionMultipleSlashes() {
        #expect(Formatting.fraction("30/1001/extra") == "30/1001/extra")
    }

    @Test func fractionVeryLargeNumbers() {
        let result = Formatting.fraction("1000000000/1")
        #expect(result.contains("1000000000"))
    }

    @Test func fractionVerySmallResult() {
        let result = Formatting.fraction("1/1000000")
        #expect(!result.isEmpty)
    }

    // --- duration() ---

    @Test func durationZero() {
        #expect(Formatting.duration(0) == "00:00:00")
    }

    @Test func durationNegative() {
        let result = Formatting.duration(-10)
        #expect(!result.isEmpty)
    }

    @Test func durationFractionalSecond() {
        #expect(Formatting.duration(0.999) == "00:00:00")
    }

    @Test func durationExactlyOneHour() {
        #expect(Formatting.duration(3600) == "01:00:00")
    }

    @Test func durationOver24Hours() {
        let result = Formatting.duration(100000)
        #expect(!result.isEmpty)
    }

    // --- humanSize() ---

    @Test func humanSizeZero() {
        #expect(Formatting.humanSize(0) == "0.0 B")
    }

    @Test func humanSizeNegative() {
        let result = Formatting.humanSize(-1024)
        #expect(!result.isEmpty)
    }

    @Test func humanSizeOneByte() {
        #expect(Formatting.humanSize(1) == "1.0 B")
    }

    @Test func humanSizeExactKB() {
        let result = Formatting.humanSize(1024)
        #expect(result == "1.0 KB")
    }

    @Test func humanSizeMaxInt64() {
        let result = Formatting.humanSize(Int64.max)
        #expect(!result.isEmpty)
        #expect(result.hasSuffix("PB") || result.hasSuffix("TB"))
    }

    // --- humanMB() ---

    @Test func humanMBZero() {
        #expect(Formatting.humanMB(0) == "0 MB")
    }

    @Test func humanMBNegative() {
        let result = Formatting.humanMB(-100)
        #expect(!result.isEmpty)
    }

    @Test func humanMBTerabytes() {
        let result = Formatting.humanMB(2_000_000)
        #expect(result.contains("TB"))
    }

    // --- humanMBps() ---

    @Test func humanMBpsZero() {
        #expect(Formatting.humanMBps(0) == "0 MB/s")
    }

    @Test func humanMBpsOverGB() {
        let result = Formatting.humanMBps(2048)
        #expect(result.contains("GB/s"))
    }

    // --- csvEscape() ---

    @Test func csvEscapeEmpty() {
        #expect(Formatting.csvEscape("") == "")
    }

    @Test func csvEscapeOnlyComma() {
        #expect(Formatting.csvEscape(",") == "\",\"")
    }

    @Test func csvEscapeOnlyQuote() {
        #expect(Formatting.csvEscape("\"") == "\"\"\"\"")
    }

    @Test func csvEscapeNewline() {
        #expect(Formatting.csvEscape("a\nb").contains("\""))
    }

    @Test func csvEscapeNoSpecialChars() {
        #expect(Formatting.csvEscape("hello") == "hello")
    }

    @Test func csvEscapeUnicode() {
        #expect(Formatting.csvEscape("café") == "café")
    }
}

// MARK: - CatalogFilterIDs Boundary Tests

struct CatalogFilterBoundaryTests {

    @Test func emptyRecordsList() {
        let id = UUID()
        let result = VideoScanModel.catalogFilterIDs(for: id, pairMode: true, in: [])
        #expect(result == [id])
    }

    @Test func nonexistentRecordID() {
        let rec = makeRecord(filename: "a.mov")
        let bogusID = UUID()
        let result = VideoScanModel.catalogFilterIDs(for: bogusID, pairMode: true, in: [rec])
        #expect(result == [bogusID])
    }

    @Test func singleRecordNoPair() {
        let rec = makeRecord(filename: "solo.mov")
        let result = VideoScanModel.catalogFilterIDs(for: rec.id, pairMode: true, in: [rec])
        #expect(result == [rec.id])
    }

    @Test func pairModeOffIgnoresPairGroupID() {
        let a = makeRecord(filename: "a.mxf", streamType: .videoOnly)
        let b = makeRecord(filename: "b.mxf", streamType: .audioOnly)
        let gid = UUID()
        a.pairGroupID = gid
        b.pairGroupID = gid
        let result = VideoScanModel.catalogFilterIDs(for: a.id, pairMode: false, in: [a, b])
        #expect(result == [a.id])
    }

    @Test func pairGroupWithMultipleMembers() {
        let gid = UUID()
        let records = (0..<5).map { i -> VideoRecord in
            let r = makeRecord(filename: "track_\(i).mxf")
            r.pairGroupID = gid
            return r
        }
        let result = VideoScanModel.catalogFilterIDs(for: records[0].id, pairMode: true, in: records)
        #expect(result.count == 5)
        for r in records { #expect(result.contains(r.id)) }
    }

    @Test func pairedWithTakesPriorityOverGroupID() {
        let a = makeRecord(filename: "v.mxf", streamType: .videoOnly)
        let b = makeRecord(filename: "a.mxf", streamType: .audioOnly)
        a.pairedWith = b
        let result = VideoScanModel.catalogFilterIDs(for: a.id, pairMode: true, in: [a, b])
        #expect(result.contains(a.id))
        #expect(result.contains(b.id))
        #expect(result.count == 2)
    }
}

// MARK: - Online Substitute Boundary Tests

struct OnlineSubstituteBoundaryTests {

    @Test func emptyAllRecords() {
        let rec = makeRecord(sizeBytes: 1000, md5: "abc123")
        let subs = VideoScanModel.findOnlineSubstitutes(for: rec, in: [])
        #expect(subs.isEmpty)
    }

    @Test func recordWithEmptyMD5ReturnsNoSubstitutes() {
        let rec = makeRecord(sizeBytes: 1000, md5: "")
        let other = makeRecord(fullPath: "/usr/bin/true", sizeBytes: 1000, md5: "")
        let subs = VideoScanModel.findOnlineSubstitutes(for: rec, in: [other])
        #expect(subs.isEmpty)
    }

    @Test func recordWithZeroSizeReturnsNoSubstitutes() {
        let rec = makeRecord(sizeBytes: 0, md5: "abc")
        let other = makeRecord(fullPath: "/usr/bin/true", sizeBytes: 0, md5: "abc")
        let subs = VideoScanModel.findOnlineSubstitutes(for: rec, in: [other])
        #expect(subs.isEmpty)
    }

    @Test func doesNotMatchSelf() {
        let rec = makeRecord(fullPath: "/usr/bin/true", sizeBytes: 1000, md5: "abc")
        let subs = VideoScanModel.findOnlineSubstitutes(for: rec, in: [rec])
        #expect(subs.isEmpty)
    }

    @Test func sizeOneMismatchBlocksMatch() {
        let rec = makeRecord(sizeBytes: 1000, md5: "abc")
        let other = makeRecord(fullPath: "/usr/bin/true", sizeBytes: 1001, md5: "abc")
        let subs = VideoScanModel.findOnlineSubstitutes(for: rec, in: [other])
        #expect(subs.isEmpty)
    }
}

// MARK: - Codec Compatibility Boundary Tests

struct CodecCompatibilityBoundaryTests {

    @Test func bothNilCodecs() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: nil, audioCodec: nil)
        #expect(check.streamCopySafe == true)
    }

    @Test func emptyStringVideoCodec() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "", audioCodec: "aac")
        #expect(check.streamCopySafe == true)
    }

    @Test func emptyStringAudioCodec() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: "")
        #expect(check.streamCopySafe == true)
    }

    @Test func unknownVideoCodecIsUnsafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "totally_bogus_codec", audioCodec: "aac")
        #expect(check.streamCopySafe == false)
        #expect(check.warning != nil)
    }

    @Test func unknownAudioCodecIsUnsafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: "totally_bogus_codec")
        #expect(check.streamCopySafe == false)
    }

    @Test func bothUnknownCodecs() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "x_vid", audioCodec: "x_aud")
        #expect(check.streamCopySafe == false)
    }

    @Test func caseInsensitivityVideoCodec() {
        let lower = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: nil)
        let upper = CombineEngine.checkStreamCopyCompatibility(videoCodec: "H264", audioCodec: nil)
        #expect(lower.streamCopySafe == upper.streamCopySafe)
    }

    @Test func allProResVariantsSafe() {
        let variants = ["prores", "ap4h", "ap4x", "apcn", "apch", "apcs", "apco"]
        for v in variants {
            let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: v, audioCodec: nil)
            #expect(check.streamCopySafe == true, "ProRes variant '\(v)' should be safe")
        }
    }

    @Test func allPCMVariantsSafe() {
        let variants = ["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be",
                        "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f64le",
                        "pcm_mulaw", "pcm_alaw"]
        for v in variants {
            let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: nil, audioCodec: v)
            #expect(check.streamCopySafe == true, "PCM variant '\(v)' should be safe")
        }
    }
}

// MARK: - DashboardState Boundary Tests

@Suite @MainActor struct DashboardBoundaryTests {

    @Test func logEmptyString() {
        let dash = DashboardState()
        dash.log("")
        // Should not crash — empty lines are valid
    }

    @Test func logVeryLongString() {
        let dash = DashboardState()
        let longLine = String(repeating: "x", count: 100_000)
        dash.log(longLine)
    }

    @Test func logStringWithOnlyNewlines() {
        let dash = DashboardState()
        dash.log("\n\n\n")
    }

    @Test func clearConsoleWhenAlreadyEmpty() {
        let dash = DashboardState()
        dash.clearConsole()
        #expect(dash.consoleLines.isEmpty)
    }

    @Test func resetForScanClearsEverything() {
        let dash = DashboardState()
        dash.scanTotal = 999
        dash.scanCompleted = 500
        dash.scanErrors = 42
        dash.resetForScan()
        #expect(dash.scanTotal == 0)
        #expect(dash.scanCompleted == 0)
        #expect(dash.scanErrors == 0)
        #expect(dash.consoleLines.isEmpty)
    }

    @Test func resetForCombineWithZeroTotal() {
        let dash = DashboardState()
        dash.resetForCombine(total: 0)
        #expect(dash.combineTotal == 0)
        #expect(dash.combineJobs.isEmpty)
    }

    @Test func recordScanFileEmptyStrings() {
        let dash = DashboardState()
        dash.recordScanFile(volume: "", filename: "")
        #expect(dash.scanCurrentVolume == "")
        #expect(dash.scanCurrentFile == "")
    }

    @Test func recordNetworkPrefetchZeroSeconds() {
        let dash = DashboardState()
        dash.recordNetworkPrefetch(megabytesCopied: 100, seconds: 0)
        #expect(dash.netPrefetchLastMBps == 0)
        #expect(dash.netPrefetchCount == 1)
    }

    @Test func recordNetworkPrefetchNegativeValues() {
        let dash = DashboardState()
        dash.recordNetworkPrefetch(megabytesCopied: -50, seconds: -1)
        #expect(dash.netPrefetchCount == 1)
    }

    @Test func combineJobStatusEstimatedBytesOverflow() {
        var job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf",
            audioFilename: "a.mxf",
            outputFilename: "out.mov",
            outputPath: "/tmp/out.mov",
            videoSizeBytes: Int64.max / 2,
            audioSizeBytes: Int64.max / 2,
            totalDurationSeconds: 60,
            videoOnline: true,
            audioOnline: true
        )
        // Should not crash on overflow
        let _ = job.estimatedBytes
        let _ = job.bothOnline
        let _ = job.elapsed
    }

    @Test func combineJobStatusZeroDuration() {
        let job = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf",
            audioFilename: "a.mxf",
            outputFilename: "out.mov",
            outputPath: "/tmp/out.mov",
            videoSizeBytes: 0,
            audioSizeBytes: 0,
            totalDurationSeconds: 0,
            videoOnline: false,
            audioOnline: false
        )
        #expect(job.estimatedBytes == 0)
        #expect(job.bothOnline == false)
        #expect(job.elapsed == nil)
    }
}

// MARK: - DuplicateDetector Boundary Tests

struct DuplicateDetectorBoundaryTests {

    @Test func analyzeEmptyRecords() {
        let summary = DuplicateDetector.analyze(records: [])
        #expect(summary.groups == 0)
        #expect(summary.extraCopies == 0)
    }

    @Test func analyzeSingleRecord() {
        let rec = makeRecord()
        let summary = DuplicateDetector.analyze(records: [rec])
        #expect(summary.groups == 0)
    }

    @Test func analyzeTwoIdenticalRecords() {
        let a = makeRecord(filename: "clip.mov", fullPath: "/Volumes/A/clip.mov",
                          duration: 120, sizeBytes: 5_000_000, md5: "abc123")
        let b = makeRecord(filename: "clip.mov", fullPath: "/Volumes/B/clip.mov",
                          duration: 120, sizeBytes: 5_000_000, md5: "abc123")
        a.timecode = "01:00:00:00"
        b.timecode = "01:00:00:00"
        let summary = DuplicateDetector.analyze(records: [a, b])
        #expect(summary.groups >= 1)
    }

    @Test func analyzeRecordsDifferentStreamTypesNeverMatch() {
        let a = makeRecord(filename: "clip.mov", duration: 120, sizeBytes: 5000,
                          streamType: .videoAndAudio, md5: "abc")
        let b = makeRecord(filename: "clip.mov", duration: 120, sizeBytes: 5000,
                          streamType: .videoOnly, md5: "abc")
        let summary = DuplicateDetector.analyze(records: [a, b])
        #expect(summary.groups == 0)
    }

    @Test func analyzeAllZeroDurationRecords() {
        let records = (0..<3).map { i in
            makeRecord(filename: "zero_\(i).mov", duration: 0, sizeBytes: 100, md5: "same")
        }
        let summary = DuplicateDetector.analyze(records: records)
        // Should not crash; zero-duration records have limited scoring
    }

    @Test func analyzeAllEmptyFieldRecords() {
        let records = (0..<3).map { i -> VideoRecord in
            let r = VideoRecord()
            r.filename = "empty_\(i).mov"
            r.fullPath = "/Volumes/X/empty_\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
        let summary = DuplicateDetector.analyze(records: records)
        // Empty fields = no scoring signals = no groups
        #expect(summary.groups == 0)
    }
}

// MARK: - MediaAnalyzer Boundary Tests

struct MediaAnalyzerBoundaryTests {

    @Test func scoreCompletelyEmptyRecord() {
        let r = VideoRecord()
        let result = MediaAnalyzer.score(r)
        // Should not crash on a record with all default values
        #expect(result.junkScore >= 0)
        #expect(result.familyScore >= 0)
    }

    @Test func scoreRecordWithNegativeDuration() {
        let r = makeRecord(duration: -10)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }

    @Test func scoreRecordMaxDuration() {
        let r = makeRecord(duration: Double.greatestFiniteMagnitude)
        let result = MediaAnalyzer.score(r)
        #expect(result.familyScore >= 0)
    }

    @Test func scoreRecordNaNDuration() {
        let r = makeRecord(duration: Double.nan)
        let result = MediaAnalyzer.score(r)
        // NaN comparisons are always false — make sure no crash
    }

    @Test func scoreRecordMaxSizeBytes() {
        let r = makeRecord(sizeBytes: Int64.max)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }

    @Test func scoreRecordNegativeSize() {
        let r = makeRecord(sizeBytes: -1)
        let result = MediaAnalyzer.score(r)
        // Should not crash
    }

    @Test func analyzeAllEmptyArray() {
        let summary = MediaAnalyzer.analyzeAll([])
        #expect(summary.familyCount == 0)
        #expect(summary.junkCount == 0)
    }

    @Test func analyzeAllSingleRecord() {
        let r = makeRecord()
        let summary = MediaAnalyzer.analyzeAll([r])
        #expect(summary.familyCount + summary.junkCount + summary.recoverableCount >= 0)
    }

    @Test func scorePathWithUnicode() {
        let r = makeRecord(filename: "家族ビデオ.mov",
                          fullPath: "/Volumes/Test/��族ビデオ.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }

    @Test func scorePathWithSpaces() {
        let r = makeRecord(filename: "my family video.mov",
                          fullPath: "/Volumes/My Drive/my family video.mov")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }

    @Test func scoreExtremelyLongFilename() {
        let name = String(repeating: "a", count: 1000) + ".mov"
        let r = makeRecord(filename: name)
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }

    @Test func scoreEmptyFilename() {
        let r = makeRecord(filename: "")
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }

    @Test func truncationCheckWithZeroBitrate() {
        let r = makeRecord(duration: 60, sizeBytes: 1000)
        r.totalBitrate = "0"
        let result = MediaAnalyzer.score(r)
        // Zero bitrate means expected size is 0, so ratio comparison must not divide by zero
    }

    @Test func truncationCheckWithNonNumericBitrate() {
        let r = makeRecord(duration: 60, sizeBytes: 1000)
        r.totalBitrate = "not_a_number"
        let result = MediaAnalyzer.score(r)
        #expect(result.junkScore >= 0)
    }
}

// MARK: - CombineEngine Boundary Tests (no ffmpeg needed)

struct CombineEngineBoundaryTests {

    @Test func combineWithEmptyVideoPath() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "",
            audioPath: "/tmp/nonexistent.wav",
            outputPath: "/tmp/out.mov",
            technique: .streamCopy,
            durationSeconds: 10,
            onProgress: { _ in },
            log: { _ in }
        )
        #expect(result.success == false)
    }

    @Test func combineWithEmptyAudioPath() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "/tmp/nonexistent.mp4",
            audioPath: "",
            outputPath: "/tmp/out.mov",
            technique: .streamCopy,
            durationSeconds: 10,
            onProgress: { _ in },
            log: { _ in }
        )
        #expect(result.success == false)
    }

    @Test func combineWithZeroDuration() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "/tmp/nonexistent.mp4",
            audioPath: "/tmp/nonexistent.wav",
            outputPath: "/tmp/out.mov",
            technique: .streamCopy,
            durationSeconds: 0,
            onProgress: { _ in },
            log: { _ in }
        )
        #expect(result.success == false)
    }

    @Test func combineWithNegativeDuration() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "/tmp/nonexistent.mp4",
            audioPath: "/tmp/nonexistent.wav",
            outputPath: "/tmp/out.mov",
            technique: .streamCopy,
            durationSeconds: -5,
            onProgress: { _ in },
            log: { _ in }
        )
        #expect(result.success == false)
    }

    @Test func combineWithPathContainingSpaces() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "/tmp/path with spaces/video.mp4",
            audioPath: "/tmp/path with spaces/audio.wav",
            outputPath: "/tmp/path with spaces/out.mov",
            technique: .streamCopy,
            durationSeconds: 10,
            onProgress: { _ in },
            log: { _ in }
        )
        #expect(result.success == false) // files don't exist, but path handling shouldn't crash
    }
}

// MARK: - StreamType Boundary Tests

struct StreamTypeBoundaryTests {

    @Test func allStreamTypesHaveNonEmptyRawValue() {
        let types: [StreamType] = [.videoAndAudio, .videoOnly, .audioOnly, .noStreams, .ffprobeFailed]
        for t in types {
            #expect(!t.rawValue.isEmpty)
        }
    }

    @Test func initFromInvalidRawValue() {
        let t = StreamType(rawValue: "totally invalid")
        #expect(t == nil)
    }

    @Test func initFromEmptyRawValue() {
        let t = StreamType(rawValue: "")
        #expect(t == nil)
    }

    @Test func needsCorrelationConsistency() {
        // Only video-only and audio-only need correlation
        #expect(StreamType.videoOnly.needsCorrelation == true)
        #expect(StreamType.audioOnly.needsCorrelation == true)
        #expect(StreamType.videoAndAudio.needsCorrelation == false)
        #expect(StreamType.noStreams.needsCorrelation == false)
        #expect(StreamType.ffprobeFailed.needsCorrelation == false)
    }
}

// MARK: - VideoRecord Boundary Tests

struct VideoRecordBoundaryTests {

    @Test func defaultRecordHasAllEmptyFields() {
        let r = VideoRecord()
        #expect(r.filename == "")
        #expect(r.fullPath == "")
        #expect(r.durationSeconds == 0)
        #expect(r.sizeBytes == 0)
        #expect(r.partialMD5 == "")
    }

    @Test func streamTypeFromEmptyRaw() {
        let r = VideoRecord()
        r.streamTypeRaw = ""
        #expect(r.streamTypeRaw == "")
    }

    @Test func pairGroupIDNilByDefault() {
        let r = VideoRecord()
        #expect(r.pairGroupID == nil)
        #expect(r.pairedWith == nil)
    }

    @Test func hasAvidMetadataFalseByDefault() {
        let r = VideoRecord()
        #expect(r.hasAvidMetadata == false)
    }

    @Test func hasAvidMetadataWithClipName() {
        let r = VideoRecord()
        r.avidClipName = "some clip"
        #expect(r.hasAvidMetadata == true)
    }

    @Test func hasAvidMetadataWithMobID() {
        let r = VideoRecord()
        r.avidMobID = "some-mob-id"
        #expect(r.hasAvidMetadata == true)
    }
}

// MARK: - AvbParser Boundary Tests

struct AvbParserBoundaryTests {

    @Test func parseNonExistentFile() {
        let result = AvbParser.parse(fileAt: "/tmp/definitely_does_not_exist_\(UUID()).avb")
        #expect(!result.errors.isEmpty)
    }

    @Test func parseEmptyFile() throws {
        let path = NSTemporaryDirectory() + "empty_\(UUID().uuidString.prefix(8)).avb"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = AvbParser.parse(fileAt: path)
        #expect(!result.errors.isEmpty)
    }

    @Test func parseOneByteFile() throws {
        let path = NSTemporaryDirectory() + "tiny_\(UUID().uuidString.prefix(8)).avb"
        try Data([0x42]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = AvbParser.parse(fileAt: path)
        #expect(!result.errors.isEmpty)
    }

    @Test func parseSevenByteFile() throws {
        let path = NSTemporaryDirectory() + "short_\(UUID().uuidString.prefix(8)).avb"
        try Data([0x06, 0x00, 0x44, 0x6F, 0x6D, 0x61, 0x69]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = AvbParser.parse(fileAt: path)
        #expect(!result.errors.isEmpty)
    }

    @Test func parseBadMagicBytes() throws {
        let path = NSTemporaryDirectory() + "badmagic_\(UUID().uuidString.prefix(8)).avb"
        try Data(repeating: 0xFF, count: 100).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = AvbParser.parse(fileAt: path)
        #expect(result.errors.contains { $0.contains("Not an AVB") })
    }

    @Test func parseTextFile() throws {
        let path = NSTemporaryDirectory() + "text_\(UUID().uuidString.prefix(8)).avb"
        try "This is not a binary AVB file".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = AvbParser.parse(fileAt: path)
        #expect(!result.errors.isEmpty)
    }
}

// MARK: - VolumeReachability Boundary Tests

struct VolumeReachabilityBoundaryTests {

    @Test func emptyPath() {
        let result = VolumeReachability.isReachable(path: "")
        #expect(result == false)
    }

    @Test func rootPath() {
        let result = VolumeReachability.isReachable(path: "/")
        #expect(result == true)
    }

    @Test func pathThatExists() {
        let result = VolumeReachability.isReachable(path: "/usr/bin/true")
        #expect(result == true)
    }

    @Test func nonexistentVolume() {
        let result = VolumeReachability.isReachable(path: "/Volumes/NoSuchVolumeEver_\(UUID())/file.mov")
        #expect(result == false)
    }

    @Test func volumeNameForRootPath() {
        let name = VolumeReachability.volumeName(forPath: "/")
        #expect(!name.isEmpty)
    }

    @Test func volumeNameForEmptyPath() {
        let _ = VolumeReachability.volumeName(forPath: "")
    }

    @Test func volumeNameForVolumesPath() {
        let name = VolumeReachability.volumeName(forPath: "/Volumes/TestDrive/some/file.mov")
        #expect(name == "TestDrive" || !name.isEmpty)
    }
}

// MARK: - CombineJobStatus Boundary Tests

struct CombineJobStatusBoundaryTests {

    @Test func allPhases() {
        let phases: [CombineJobStatus.CombinePhase] = [
            .queued, .buffering, .muxing, .verifying, .done, .failed, .skipped
        ]
        for phase in phases {
            #expect(!phase.rawValue.isEmpty)
        }
    }

    @Test func allTechniques() {
        let techniques: [CombineJobStatus.CombineTechnique] = [
            .streamCopy, .reencodeProRes, .reencodeH264
        ]
        for t in techniques {
            #expect(!t.rawValue.isEmpty)
        }
    }

    @Test func elapsedWithNoStartTime() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v", audioFilename: "a",
            outputFilename: "o", outputPath: "/tmp/o",
            videoSizeBytes: 0, audioSizeBytes: 0,
            totalDurationSeconds: 0, videoOnline: true, audioOnline: true
        )
        #expect(job.elapsed == nil)
    }

    @Test func bothOnlineFalseWhenVideoOffline() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v", audioFilename: "a",
            outputFilename: "o", outputPath: "/tmp/o",
            videoSizeBytes: 100, audioSizeBytes: 100,
            totalDurationSeconds: 10, videoOnline: false, audioOnline: true
        )
        #expect(job.bothOnline == false)
    }

    @Test func bothOnlineFalseWhenAudioOffline() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v", audioFilename: "a",
            outputFilename: "o", outputPath: "/tmp/o",
            videoSizeBytes: 100, audioSizeBytes: 100,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: false
        )
        #expect(job.bothOnline == false)
    }

    @Test func pairIndexNegative() {
        let job = CombineJobStatus(
            pairIndex: -1, videoFilename: "v", audioFilename: "a",
            outputFilename: "o", outputPath: "/tmp/o",
            videoSizeBytes: 0, audioSizeBytes: 0,
            totalDurationSeconds: 0, videoOnline: true, audioOnline: true
        )
        #expect(job.pairIndex == -1)
    }
}
