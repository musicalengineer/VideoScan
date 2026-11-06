import Testing
@testable import VideoScan

/// The Realtime Catalog Scan's one counting rule (Rick 2026-11-05: a red
/// "Failed 11,927" beside "Errors 4"; 11,923 were sniff-rejected non-media).
/// The real-scan truth test is DiscoveryCompletenessPipelineTests
/// .tripAcrossCountryShapeCatalogsExactlyTheValidMedia (tiles vs the audit).
@MainActor
struct ScanTileTallyTests {

    private let failed = StreamType.ffprobeFailed.rawValue

    @Test func sniffRejectedIsNotMediaNeverAFailureNeverFFprobed() {
        let t = ScanTileTally.tally(streamTypeRaw: failed, wasCacheHit: false,
                                    sniffRejected: true, stillBeingWritten: false)
        #expect(t == .init(tileKey: ScanTileTally.notMediaKey, ranFFprobe: false, isProbeError: false))
    }

    @Test func stillBeingWrittenIsItsOwnTileNeverAFailure() {
        let t = ScanTileTally.tally(streamTypeRaw: failed, wasCacheHit: false,
                                    sniffRejected: false, stillBeingWritten: true)
        #expect(t == .init(tileKey: ScanTileTally.stillBeingWrittenKey, ranFFprobe: false, isProbeError: false))
    }

    @Test func aRealFFprobeFailureIsFailedAndAnError() {
        let t = ScanTileTally.tally(streamTypeRaw: failed, wasCacheHit: false,
                                    sniffRejected: false, stillBeingWritten: false)
        #expect(t == .init(tileKey: failed, ranFFprobe: true, isProbeError: true))
    }

    @Test func aCacheHitIsNotFFprobed() {
        let va = StreamType.videoAndAudio.rawValue
        #expect(ScanTileTally.tally(streamTypeRaw: va, wasCacheHit: true, sniffRejected: false,
                                    stillBeingWritten: false)
                == .init(tileKey: va, ranFFprobe: false, isProbeError: false))
    }

    /// The screenshot's shape, scaled down: the tiles add up, Failed equals
    /// Errors, and ffprobed counts only files ffprobe ran on.
    @Test func theScreenshotShapeAddsUpThroughTheDashboard() {
        let ds = DashboardState()
        ds.resetForScan()
        let gen = ds.scanGeneration
        ds.beginVolumeWalk(volumeRoot: "/Volumes/W", volumeName: "W", generation: gen)
        func one(_ type: String, hit: Bool, sniff: Bool = false, writing: Bool = false) {
            ds.recordFileDiscovered(volumeRoot: "/Volumes/W", generation: gen)
            ds.recordProbeCompletion(volumeRoot: "/Volumes/W", wasCacheHit: hit,
                                     tally: ScanTileTally.tally(streamTypeRaw: type, wasCacheHit: hit,
                                                                sniffRejected: sniff, stillBeingWritten: writing),
                                     generation: gen)
        }
        for _ in 0..<6 { one(StreamType.videoAndAudio.rawValue, hit: true) }
        for _ in 0..<2 { one(StreamType.audioOnly.rawValue, hit: false) }
        for _ in 0..<9 { one(failed, hit: false, sniff: true) }
        one(failed, hit: false)
        one(failed, hit: false, writing: true)
        ds.flushScanProgress()
        #expect(ds.liveStreamCounts[ScanTileTally.notMediaKey] == 9)
        #expect(ds.liveStreamCounts[failed] == 1)
        #expect(ds.scanErrors == 1)
        #expect(ds.liveStreamCounts[ScanTileTally.stillBeingWrittenKey] == 1)
        #expect(ds.scanCacheHits == 6)
        #expect(ds.scanCacheMisses == 3, "2 audio + 1 real failure; never the 9 non-media or the busy file")
        #expect(ds.liveStreamCounts.values.reduce(0, +) == ds.scanCompleted)
    }
}
