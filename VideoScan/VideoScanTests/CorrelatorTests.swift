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
        #expect(key == "holiday_2005")
    }

    @Test func filenameCorrelationKeyCaseVariants() {
        let v = Correlator.filenameCorrelationKey("v01AB.mxf")
        let a = Correlator.filenameCorrelationKey("a01AB.mxf")
        #expect(v == a)
    }

    // MARK: - OMFI Tape-Name Pattern

    @Test func omfiTapeNameVideoMatchesAudio() {
        let vKey = CorrelationScorer.filenameCorrelationKey("NewTape9V01.4B9C1586.8D8520.mxf")
        let a1Key = CorrelationScorer.filenameCorrelationKey("NewTape9A01.4B9C1586.8D8510.wav")
        let a2Key = CorrelationScorer.filenameCorrelationKey("NewTape9A02.4B9C1586.8D8500.wav")
        #expect(vKey == a1Key)
        #expect(vKey == a2Key)
        #expect(vKey == "NewTape9.4B9C1586")
    }

    @Test func omfiDifferentClipIDsDoNotMatch() {
        let clip1 = CorrelationScorer.filenameCorrelationKey("NewTape9V01.4B9C1586.8D8520.mxf")
        let clip2 = CorrelationScorer.filenameCorrelationKey("NewTape9V01.DEADBEEF.112233.mxf")
        #expect(clip1 != clip2)
    }

    @Test func omfiDifferentTapeNamesDoNotMatch() {
        let tape9 = CorrelationScorer.filenameCorrelationKey("NewTape9V01.4B9C1586.8D8520.mxf")
        let tape10 = CorrelationScorer.filenameCorrelationKey("NewTape10V01.4B9C1586.8D8520.mxf")
        #expect(tape9 != tape10)
    }

    @Test func omfiMixedExtensionsMxfAndWav() {
        let mxf = CorrelationScorer.filenameCorrelationKey("UntitledV01.4E9A71FB.AABB00.mxf")
        let wav = CorrelationScorer.filenameCorrelationKey("UntitledA01.4E9A71FB.43A460.wav")
        #expect(mxf == wav)
    }

    @Test func omfiCorrelateEndToEnd() {
        let video = VideoRecord()
        video.filename = "NewTape9V01.4B9C1586.8D8520.mxf"
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        video.durationSeconds = 1324.556
        video.directory = "/vol/Avid MediaFiles/MXF/1"

        let audio = VideoRecord()
        audio.filename = "NewTape9A01.4B9C1586.8D8510.wav"
        audio.streamTypeRaw = StreamType.audioOnly.rawValue
        audio.durationSeconds = 1324.567
        audio.directory = "/vol/OMFI MediaFiles"

        Correlator.correlate(records: [video, audio])

        #expect(video.pairedWith === audio)
        #expect(audio.pairedWith === video)
        #expect(video.pairConfidence != nil)
    }

    @Test func omfiCorrelateDoesNotFalsePairDifferentClips() {
        let video = VideoRecord()
        video.filename = "NewTape9V01.4B9C1586.8D8520.mxf"
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        video.durationSeconds = 1324.556

        let audio = VideoRecord()
        audio.filename = "NewTape9A01.DEADBEEF.112233.wav"
        audio.streamTypeRaw = StreamType.audioOnly.rawValue
        audio.durationSeconds = 60.0

        Correlator.correlate(records: [video, audio])

        #expect(video.pairedWith == nil)
        #expect(audio.pairedWith == nil)
    }

    // MARK: - End-to-End Correlation

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
