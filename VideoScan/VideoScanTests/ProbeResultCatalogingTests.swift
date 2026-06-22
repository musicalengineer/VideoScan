// ProbeResultCatalogingTests.swift
// The "Scan Files With No Extension" pass admits data blobs that ffprobe can't
// read; those must NOT bloat the catalog (a backup-drive sweep produced ~4.9k
// junk "ffprobe failed" rows). They're dropped (and logged), while extensioned
// damaged media stays cataloged so it remains visible.

import Testing
@testable import VideoScan

@Suite("Probe-result cataloging decision")
struct ProbeResultCatalogingTests {

    private func decide(ext: String, _ stream: StreamType) -> Bool {
        VideoScanModel.shouldCatalogProbeResult(ext: ext, streamTypeRaw: stream.rawValue)
    }

    @Test("Extensionless + ffprobe-failed is dropped (the junk case)")
    func extensionlessUnidentifiedDropped() {
        #expect(decide(ext: "", .ffprobeFailed) == false)
        #expect(decide(ext: "   ", .ffprobeFailed) == false)   // whitespace == empty
    }

    @Test("Extensionless but real media is kept (e.g. iMovie video-only t2-v)")
    func extensionlessRealMediaKept() {
        #expect(decide(ext: "", .videoOnly))
        #expect(decide(ext: "", .audioOnly))
        #expect(decide(ext: "", .videoAndAudio))
    }

    @Test("Extensioned damaged media is still cataloged (real Avid .mxf)")
    func extensionedDamagedKept() {
        #expect(decide(ext: "MXF", .ffprobeFailed))
        #expect(decide(ext: "mov", .ffprobeFailed))
    }

    @Test("Normal extensioned media is cataloged")
    func normalMediaKept() {
        #expect(decide(ext: "MOV", .videoAndAudio))
        #expect(decide(ext: "WAV", .audioOnly))
    }

    @Test("Bulk cleanup selector picks only extensionless+unreadable active rows")
    func bulkSelector() {
        func mk(_ ext: String, _ stream: StreamType, purged: Bool = false) -> VideoRecord {
            let r = VideoRecord()
            r.ext = ext
            r.streamTypeRaw = stream.rawValue
            if purged { r.purgedAt = Date() }
            return r
        }
        let junk1 = mk("", .ffprobeFailed)
        let junk2 = mk("", .ffprobeFailed)
        let realExtensionless = mk("", .videoOnly)        // extensionless but real media — keep
        let damagedMxf = mk("MXF", .ffprobeFailed)        // extensioned damaged — keep
        let normal = mk("MOV", .videoAndAudio)
        let alreadyPurged = mk("", .ffprobeFailed, purged: true)  // skip — already removed

        let ids = Set(VideoScanModel.unreadableExtensionlessIDs(
            in: [junk1, junk2, realExtensionless, damagedMxf, normal, alreadyPurged]))
        #expect(ids == Set([junk1.id, junk2.id]))
    }
}
