import Foundation
import Testing
@testable import VideoScan

// MARK: - CorrelationScorer Tests

@Suite struct FilenameCorrelationKeyTests {

    @Test func stripsVideoPrefixFromAvidMXF() {
        let result = CorrelationScorer.filenameCorrelationKey("V01A23BC.mxf")
        #expect(result == "_01A23BC.mxf")
    }

    @Test func stripsAudioPrefixFromAvidMXF() {
        let result = CorrelationScorer.filenameCorrelationKey("A01A23BC.mxf")
        #expect(result == "_01A23BC.mxf")
    }

    @Test func matchingVideoAndAudioProduceSameKey() {
        let vKey = CorrelationScorer.filenameCorrelationKey("V14D1BBD3F.mxf")
        let aKey = CorrelationScorer.filenameCorrelationKey("A14D1BBD3F.mxf")
        #expect(vKey == aKey)
    }

    @Test func lowercasePrefixAlsoStripped() {
        let result = CorrelationScorer.filenameCorrelationKey("v01a23bc.mxf")
        #expect(result == "_01a23bc.mxf")
    }

    @Test func nonHexSuffixNotStripped() {
        let result = CorrelationScorer.filenameCorrelationKey("Video.mov")
        #expect(result == "Video.mov")
    }

    @Test func emptyStringReturnsEmpty() {
        #expect(CorrelationScorer.filenameCorrelationKey("") == "")
    }

    @Test func noExtensionFile() {
        let result = CorrelationScorer.filenameCorrelationKey("V01AB")
        #expect(result == "_01AB")
    }

    @Test func multiDotFilename() {
        let result = CorrelationScorer.filenameCorrelationKey("00001.V14D1BBD3F.mxf")
        #expect(result == "00001._14D1BBD3F.mxf")
    }
}

@Suite struct AvidClipIDTests {

    @Test func extractsVideoClipID() {
        let result = CorrelationScorer.avidClipID(from: "00001.V14D1BBD3F.mxf")
        #expect(result != nil)
        #expect(result?.clipID == "14D1BBD3F")
        #expect(result?.isVideo == true)
    }

    @Test func extractsAudioClipID() {
        let result = CorrelationScorer.avidClipID(from: "00001.A14D1BBD3F.mxf")
        #expect(result != nil)
        #expect(result?.clipID == "14D1BBD3F")
        #expect(result?.isVideo == false)
    }

    @Test func nonMXFReturnsNil() {
        #expect(CorrelationScorer.avidClipID(from: "video.mov") == nil)
    }

    @Test func wrongPatternReturnsNil() {
        #expect(CorrelationScorer.avidClipID(from: "V14D1BBD3F.mxf") == nil)
    }

    @Test func emptyStringReturnsNil() {
        #expect(CorrelationScorer.avidClipID(from: "") == nil)
    }

    @Test func caseInsensitiveMXF() {
        let result = CorrelationScorer.avidClipID(from: "00001.V14D1BBD3F.MXF")
        #expect(result != nil)
        #expect(result?.clipID == "14D1BBD3F")
    }
}

@Suite struct ScoreCorrelatePairTests {

    private func makeRecord(
        filename: String = "test.mxf",
        directory: String = "/test",
        duration: Double = 60.0,
        streamType: StreamType = .videoOnly,
        timecode: String = "",
        tapeName: String = "",
        dateCreated: Date? = nil
    ) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = filename
        rec.directory = directory
        rec.durationSeconds = duration
        rec.streamTypeRaw = streamType.rawValue
        rec.timecode = timecode
        rec.tapeName = tapeName
        rec.dateCreatedRaw = dateCreated
        return rec
    }

    @Test func filenameMatchScores4() {
        let v = makeRecord(filename: "V01AB.mxf", streamType: .videoOnly)
        let a = makeRecord(filename: "A01AB.mxf", streamType: .audioOnly)
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result!.reasons.contains("filename"))
    }

    @Test func durationMatchScores3() {
        let v = makeRecord(duration: 60.0)
        let a = makeRecord(filename: "audio.wav", duration: 60.5)
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result!.reasons.contains("duration"))
    }

    @Test func timestampMatchScores3() {
        let now = Date()
        let v = makeRecord(dateCreated: now)
        let a = makeRecord(filename: "audio.wav", dateCreated: now.addingTimeInterval(2))
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result!.reasons.contains("timestamp"))
    }

    @Test func belowThresholdReturnsNil() {
        let v = makeRecord(directory: "/a")
        let a = makeRecord(filename: "other.wav", directory: "/b", duration: 999)
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result == nil)
    }

    @Test func highConfidenceAt7Plus() {
        let now = Date()
        let v = makeRecord(filename: "V01AB.mxf", directory: "/same", duration: 60.0,
                          timecode: "01:00:00:00", dateCreated: now)
        let a = makeRecord(filename: "A01AB.mxf", directory: "/same", duration: 60.0,
                          streamType: .audioOnly, timecode: "01:00:00:00", dateCreated: now)
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result!.confidence == .high)
    }

    @Test func timecodeMatchScores2() {
        let v = makeRecord(duration: 60.0, timecode: "01:00:00:00")
        let a = makeRecord(filename: "audio.wav", duration: 60.0, timecode: "01:00:00:00")
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result!.reasons.contains("timecode"))
    }

    @Test func tapeNameMatchScores1() {
        let v = makeRecord(duration: 60.0, tapeName: "TAPE01")
        let a = makeRecord(filename: "audio.wav", duration: 60.0, tapeName: "TAPE01")
        let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
        let result = CorrelationScorer.scoreCorrelatePair(
            video: v, audio: a, vKey: vKey,
            durationTolerance: 1.0, timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result!.reasons.contains("tape"))
    }
}

@Suite struct BuildAudioPoolsTests {

    private func makeAudio(filename: String, directory: String) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = filename
        rec.directory = directory
        rec.streamTypeRaw = StreamType.audioOnly.rawValue
        return rec
    }

    @Test func groupsByKeyAndDirectory() {
        let a1 = makeAudio(filename: "A01AB.mxf", directory: "/dir1")
        let a2 = makeAudio(filename: "A02CD.mxf", directory: "/dir1")
        let a3 = makeAudio(filename: "A01AB.mxf", directory: "/dir2")

        let pools = CorrelationScorer.buildAudioPools(from: [a1, a2, a3])

        let key = CorrelationScorer.filenameCorrelationKey("A01AB.mxf")
        #expect(pools.byKey[key]?.count == 2)
        #expect(pools.byDir["/dir1"]?.count == 2)
        #expect(pools.byDir["/dir2"]?.count == 1)
    }

    @Test func emptyInputReturnsEmptyPools() {
        let pools = CorrelationScorer.buildAudioPools(from: [])
        #expect(pools.byKey.isEmpty)
        #expect(pools.byDir.isEmpty)
    }
}

@Suite struct ResolveScopeTests {

    private func makeRecord() -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = "test.mxf"
        rec.pairConfidence = .high
        return rec
    }

    @Test func nilSelectedIDsReturnsAll() {
        let records = [makeRecord(), makeRecord(), makeRecord()]
        let result = CorrelationScorer.resolveCorrelateScope(records: records, selectedIDs: nil)
        #expect(result.count == 3)
    }

    @Test func emptySelectedIDsReturnsAll() {
        let records = [makeRecord(), makeRecord()]
        let result = CorrelationScorer.resolveCorrelateScope(records: records, selectedIDs: Set())
        #expect(result.count == 2)
    }

    @Test func specificIDsFilterSubset() {
        let r1 = makeRecord()
        let r2 = makeRecord()
        let r3 = makeRecord()
        let result = CorrelationScorer.resolveCorrelateScope(
            records: [r1, r2, r3], selectedIDs: [r1.id, r3.id]
        )
        #expect(result.count == 2)
    }

    @Test func clearsPriorPairing() {
        let rec = makeRecord()
        rec.pairedWith = makeRecord()
        rec.pairGroupID = UUID()
        rec.pairConfidence = .high

        _ = CorrelationScorer.resolveCorrelateScope(records: [rec], selectedIDs: nil)

        #expect(rec.pairedWith == nil)
        #expect(rec.pairGroupID == nil)
        #expect(rec.pairConfidence == nil)
    }
}

@Suite struct AssignCandidatesTests {

    private func makeRecord(filename: String) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = filename
        return rec
    }

    @Test func highestScoreWins() {
        let v1 = makeRecord(filename: "v1.mxf")
        let a1 = makeRecord(filename: "a1.mxf")
        let v2 = makeRecord(filename: "v2.mxf")

        let c1 = CorrelationScorer.Candidate(
            video: v1, audio: a1, score: 7, confidence: .high, reasons: ["filename", "duration"]
        )
        let c2 = CorrelationScorer.Candidate(
            video: v2, audio: a1, score: 4, confidence: .medium, reasons: ["duration"]
        )

        var matched = Set<UUID>()
        let logs = CorrelationScorer.assignCandidates([c1, c2], matched: &matched)

        #expect(matched.contains(v1.id))
        #expect(matched.contains(a1.id))
        #expect(!matched.contains(v2.id))
        #expect(logs.count == 1)
    }

    @Test func emptyInput() {
        var matched = Set<UUID>()
        let logs = CorrelationScorer.assignCandidates([], matched: &matched)
        #expect(logs.isEmpty)
        #expect(matched.isEmpty)
    }
}

// MARK: - FilesystemWalker Tests

@Suite struct IsMpegTSTests {

    @Test func nonexistentFileReturnsFalse() {
        let url = URL(fileURLWithPath: "/nonexistent/file.ts")
        #expect(FilesystemWalker.isMpegTS(url) == false)
    }
}

// MARK: - FileHasher Tests

@Suite struct FileHasherTests {

    @Test func nonexistentFileReturnsEmpty() {
        #expect(FileHasher.partialMD5(path: "/nonexistent/file.bin") == "")
    }

    @Test func emptyFileReturnsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehasher_test_empty_\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(FileHasher.partialMD5(path: tmp.path) == "")
    }

    @Test func smallFileProducesHash() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehasher_test_small_\(UUID().uuidString)")
        let data = Data(repeating: 0xAB, count: 100)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = FileHasher.partialMD5(path: tmp.path)
        #expect(!hash.isEmpty)
        #expect(hash.count == 32) // MD5 hex string
    }

    @Test func largeFileHashesHeadAndTail() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehasher_test_large_\(UUID().uuidString)")
        let data = Data(repeating: 0xCD, count: 200_000)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = FileHasher.partialMD5(path: tmp.path)
        #expect(!hash.isEmpty)
        #expect(hash.count == 32)
    }

    @Test func deterministic() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehasher_test_determ_\(UUID().uuidString)")
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash1 = FileHasher.partialMD5(path: tmp.path)
        let hash2 = FileHasher.partialMD5(path: tmp.path)
        #expect(hash1 == hash2)
    }
}

// MARK: - Formatting Tests (verify delegate matches)

@Suite struct FormattingDelegateTests {

    @Test func durationFormat() {
        #expect(Formatting.duration(3661) == "01:01:01")
        #expect(Formatting.duration(0) == "00:00:00")
        #expect(Formatting.duration(86399) == "23:59:59")
    }

    @Test func fractionParse() {
        #expect(Formatting.fraction("30000/1001") == "29.97")
        #expect(Formatting.fraction("24/1") == "24")
        #expect(Formatting.fraction("bad") == "bad")
        #expect(Formatting.fraction("10/0") == "10/0")
    }

    @Test func humanSizeFormat() {
        #expect(Formatting.humanSize(0) == "0.0 B")
        #expect(Formatting.humanSize(1024) == "1.0 KB")
        #expect(Formatting.humanSize(1_073_741_824) == "1.0 GB")
    }

    @Test func csvEscapeQuotesCommas() {
        #expect(Formatting.csvEscape("hello") == "hello")
        #expect(Formatting.csvEscape("hello,world") == "\"hello,world\"")
        #expect(Formatting.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }
}
