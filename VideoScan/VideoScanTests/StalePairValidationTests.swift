import Foundation
import Testing
@testable import VideoScan

// Regression: a pair persisted before the duration gate was introduced could
// remain "settled" forever. Catalog load trusted the stored object link, and
// incremental Correlate All skipped both records, while an on-demand search
// rejected the same pair. Known-impossible stored pairs must be released so
// every entry point sees the same evidence.
@Suite(.serialized) @MainActor
struct StalePairValidationTests {
    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_stale_pair_\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func makeRecord(
        _ filename: String,
        streamType: StreamType,
        duration: Double,
        directory: String = "/Volumes/Avid/MediaFiles/MXF/1"
    ) -> VideoRecord {
        let record = VideoRecord()
        record.filename = filename
        record.directory = directory
        record.fullPath = directory + "/" + filename
        record.streamTypeRaw = streamType.rawValue
        record.durationSeconds = duration
        return record
    }

    private func link(_ video: VideoRecord, _ audio: VideoRecord) {
        let groupID = UUID()
        video.pairedWith = audio
        video.pairGroupID = groupID
        video.pairConfidence = .medium
        audio.pairedWith = video
        audio.pairGroupID = groupID
        audio.pairConfidence = .medium
    }

    @Test func catalogLoadClearsKnownIncompatiblePersistedPairSymmetrically() throws {
        let directory = scratchDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(directory: directory)
        let video = makeRecord("00001.V14D1BBD3F.mxf", streamType: .videoOnly,
                               duration: 3808.271)
        let audio = makeRecord("00047.PHYSA01.8D8520.mxf", streamType: .audioOnly,
                               duration: 125.6255)
        link(video, audio)
        store.saveNow(records: [video, audio])

        let loaded = CatalogStore(directory: directory).load()
        let loadedVideo = try #require(loaded.first { $0.streamType == .videoOnly })
        let loadedAudio = try #require(loaded.first { $0.streamType == .audioOnly })

        #expect(loadedVideo.pairedWith == nil)
        #expect(loadedAudio.pairedWith == nil)
        #expect(loadedVideo.pairGroupID == nil && loadedAudio.pairGroupID == nil)
        #expect(loadedVideo.pairConfidence == nil && loadedAudio.pairConfidence == nil)
    }

    @Test func catalogLoadPreservesPersistedPairWhenDurationIsUnknown() throws {
        let directory = scratchDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(directory: directory)
        let video = makeRecord("00001.V14D1BBD3F.mxf", streamType: .videoOnly, duration: 0)
        let audio = makeRecord("00001.A14D1BBD3F.mxf", streamType: .audioOnly, duration: 0)
        link(video, audio)
        let originalGroupID = video.pairGroupID
        store.saveNow(records: [video, audio])

        let loaded = CatalogStore(directory: directory).load()
        let loadedVideo = try #require(loaded.first { $0.streamType == .videoOnly })
        let loadedAudio = try #require(loaded.first { $0.streamType == .audioOnly })

        #expect(loadedVideo.pairedWith === loadedAudio)
        #expect(loadedAudio.pairedWith === loadedVideo)
        #expect(loadedVideo.pairGroupID == originalGroupID)
    }

    @Test func incrementalCorrelateReleasesStalePairAndUsesCompatibleAlternative() async {
        let model = VideoScanModel()
        let video = makeRecord("00001.V14D1BBD3F.mxf", streamType: .videoOnly,
                               duration: 3808.271)
        let staleAudio = makeRecord("00047.PHYSA01.8D8520.mxf", streamType: .audioOnly,
                                    duration: 125.6255)
        let compatibleAudio = makeRecord("00001.A14D1BBD3F.mxf", streamType: .audioOnly,
                                         duration: 3798.261)
        link(video, staleAudio)
        model.records = [video, staleAudio, compatibleAudio]

        await model.correlate()

        #expect(video.pairedWith === compatibleAudio)
        #expect(compatibleAudio.pairedWith === video)
        #expect(staleAudio.pairedWith == nil)
        #expect(staleAudio.pairGroupID == nil && staleAudio.pairConfidence == nil)
    }
}
