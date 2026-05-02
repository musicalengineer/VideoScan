import Testing
import Foundation
@testable import VideoScan

// MARK: - Correlator Tests

struct CorrelatorTests {

    @Test func filenameCorrelationKeyStripsAvidPrefix() {
        let vKey = Correlator.filenameCorrelationKey("V01A23BC.mxf")
        let aKey = Correlator.filenameCorrelationKey("A01A23BC.mxf")
        #expect(vKey == aKey)
    }

    @Test func filenameCorrelationKeyPreservesNonAvid() {
        let key = Correlator.filenameCorrelationKey("holiday_2005.mov")
        #expect(key == "holiday_2005.mov")
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
        audio.durationSeconds = 30.2
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
        audio.durationSeconds = 120.0

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
