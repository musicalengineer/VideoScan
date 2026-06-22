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
}
