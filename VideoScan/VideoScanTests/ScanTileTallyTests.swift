import Testing
@testable import VideoScan

/// The Realtime Catalog Scan's one counting rule (Rick 2026-11-05: a red
/// "Failed 11,927" beside "Errors 4"; 11,923 were sniff-rejected non-media).
/// The real-scan truth test is DiscoveryCompletenessPipelineTests
/// .tripAcrossCountryShapeCatalogsExactlyTheValidMedia (tiles vs the audit);
/// the vanished-file truth test is ScanCounterInvariantTests
/// .perFileProbeCounterPublishesAreBatched (100 missing files through
/// probeAndRecord: zero ffprobed, zero errors, 100 Gone).
@MainActor
struct ScanTileTallyTests {

    private let failed = StreamType.ffprobeFailed.rawValue

    private func tally(_ type: String, ran: Bool, sniff: Bool = false, writing: Bool = false,
                       gone: Bool = false) -> ScanTileTally.Tally {
        ScanTileTally.tally(streamTypeRaw: type, ffprobeRan: ran, sniffRejected: sniff,
                            stillBeingWritten: writing, fileNotFound: gone)
    }

    @Test func sniffRejectedIsNotMediaNeverAFailureNeverFFprobed() {
        #expect(tally(failed, ran: false, sniff: true)
                == .init(tileKey: ScanTileTally.notMediaKey, ranFFprobe: false, isProbeError: false))
    }

    @Test func stillBeingWrittenIsItsOwnTileNeverAFailure() {
        #expect(tally(failed, ran: false, writing: true)
                == .init(tileKey: ScanTileTally.stillBeingWrittenKey, ranFFprobe: false, isProbeError: false))
    }

    /// Codex 2026-11-05 (P0): the file changed AFTER ffprobe ran. It is still
    /// skipped, still not a failure — and that execution counts as ffprobed.
    @Test func stillBeingWrittenAfterFFprobeRanCountsTheExecution() {
        #expect(tally(failed, ran: true, writing: true)
                == .init(tileKey: ScanTileTally.stillBeingWrittenKey, ranFFprobe: true, isProbeError: false))
    }

    /// Codex 2026-11-05 (P0): a file that vanished between discovery and probe
    /// was never opened by ffprobe. Gone, not Failed; not ffprobed; no error.
    @Test func aVanishedFileIsGoneNeverFFprobedNeverAnError() {
        #expect(tally(failed, ran: false, gone: true)
                == .init(tileKey: ScanTileTally.goneKey, ranFFprobe: false, isProbeError: false))
    }

    @Test func aRealFFprobeFailureIsFailedAndAnError() {
        #expect(tally(failed, ran: true) == .init(tileKey: failed, ranFFprobe: true, isProbeError: true))
    }

    @Test func aCacheHitIsNotFFprobed() {
        let va = StreamType.videoAndAudio.rawValue
        #expect(tally(va, ran: false) == .init(tileKey: va, ranFFprobe: false, isProbeError: false))
    }

    /// The screenshot's shape, scaled down: the tiles add up, Failed equals
    /// Errors, and ffprobed counts exactly the files ffprobe ran on.
    @Test func theScreenshotShapeAddsUpThroughTheDashboard() {
        let ds = DashboardState()
        ds.resetForScan()
        let gen = ds.scanGeneration
        ds.beginVolumeWalk(volumeRoot: "/Volumes/W", volumeName: "W", generation: gen)
        func one(_ type: String, hit: Bool, ran: Bool, sniff: Bool = false, writing: Bool = false,
                 gone: Bool = false) {
            ds.recordFileDiscovered(volumeRoot: "/Volumes/W", generation: gen)
            ds.recordProbeCompletion(volumeRoot: "/Volumes/W", wasCacheHit: hit,
                                     tally: tally(type, ran: ran, sniff: sniff, writing: writing, gone: gone),
                                     generation: gen)
        }
        for _ in 0..<6 { one(StreamType.videoAndAudio.rawValue, hit: true, ran: false) }
        for _ in 0..<2 { one(StreamType.audioOnly.rawValue, hit: false, ran: true) }
        for _ in 0..<9 { one(failed, hit: false, ran: false, sniff: true) }
        one(failed, hit: false, ran: true)                      // a real ffprobe failure
        one(failed, hit: false, ran: false, writing: true)      // caught by the settle window
        one(failed, hit: false, ran: true, writing: true)       // changed under ffprobe
        for _ in 0..<3 { one(failed, hit: false, ran: false, gone: true) }
        ds.flushScanProgress()
        #expect(ds.liveStreamCounts[ScanTileTally.notMediaKey] == 9)
        #expect(ds.liveStreamCounts[failed] == 1)
        #expect(ds.scanErrors == 1)
        #expect(ds.liveStreamCounts[ScanTileTally.stillBeingWrittenKey] == 2)
        #expect(ds.liveStreamCounts[ScanTileTally.goneKey] == 3)
        #expect(ds.scanCacheHits == 6)
        #expect(ds.scanCacheMisses == 4,
                "2 audio + 1 real failure + 1 changed under ffprobe; never the 9 non-media, the settle skip or the 3 gone")
        #expect(ds.liveStreamCounts.values.reduce(0, +) == ds.scanCompleted)
        #expect(ds.scanCompleted == 23)
    }
}
