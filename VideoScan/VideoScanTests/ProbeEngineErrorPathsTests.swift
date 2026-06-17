// ProbeEngineErrorPathsTests.swift
// Covers the failure-record construction paths of VideoScanModel's
// probe engine. These run without requiring real ffprobe / Process
// machinery — they exercise the synthetic VideoRecord production
// branches that the engine relies on to report cancellation,
// non-existence, and timeout to the catalog. Rick 2026-06-17.
//
// Scope:
//   - cancelledProbeRecord(url:) — pre-permit cancellation shape
//   - probeFile(url:) — non-existent file → ffprobeFailed record
//     populated for VolumeComparer fallback matching
//   - probeFileWithTimeout(url:) — wraps the non-existent path with
//     the timeout race; same failure shape

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("ProbeEngine — error path records")
struct ProbeEngineErrorPathsTests {

    // MARK: - cancelledProbeRecord

    @Test func cancelledProbeRecord_populatesFilenameAndPath() {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: "/Volumes/X/clips/foo.mov")
        let rec = model.cancelledProbeRecord(url: url)
        #expect(rec.filename == "foo.mov")
        #expect(rec.ext == "MOV")
        #expect(rec.fullPath == "/Volumes/X/clips/foo.mov")
        #expect(rec.directory == "/Volumes/X/clips")
    }

    @Test func cancelledProbeRecord_marksCancelledAndFfprobeFailed() {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: "/tmp/anything.mp4")
        let rec = model.cancelledProbeRecord(url: url)
        // isPlayable "Cancelled" surfaces to the UI as a non-error
        // banner — distinguishes "we deliberately stopped" from
        // "ffprobe failed."
        #expect(rec.isPlayable == "Cancelled")
        #expect(rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue)
        #expect(rec.notes.contains("cancelled"))
    }

    @Test func cancelledProbeRecord_uppercasesExtension() {
        let model = VideoScanModel()
        // Lowercase ext on the URL — record should normalize to upper.
        let lower = model.cancelledProbeRecord(url: URL(fileURLWithPath: "/v/x.mov"))
        #expect(lower.ext == "MOV")
        let upper = model.cancelledProbeRecord(url: URL(fileURLWithPath: "/v/x.MP4"))
        #expect(upper.ext == "MP4")
    }

    // MARK: - probeFile non-existent file

    @Test func probeFile_nonExistentFileReturnsFailureRecord() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: "/tmp/vs-probe-test-does-not-exist-\(UUID().uuidString).mov")
        let rec = await model.probeFile(url: url)
        // The contract from the docstring: "skip immediately rather
        // than wasting time on ffprobe." The returned record must
        // still carry filename + path so the VolumeComparer
        // (filename, size) fallback can pair it; isPlayable should
        // signal failure.
        #expect(rec.filename == url.lastPathComponent)
        #expect(rec.fullPath == url.path)
        #expect(rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue)
    }

    // MARK: - probeFileWithTimeout for non-existent file

    @Test func probeFileWithTimeout_nonExistentFileBubblesFailureUp() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: "/tmp/vs-probe-timeout-test-\(UUID().uuidString).mov")
        let rec = await model.probeFileWithTimeout(url: url)
        // For a non-existent file, probeFile returns a failure record
        // BEFORE the timeout fires. The wrapper preserves that record's
        // failure marker — we never expect to return a "Timed out"
        // record here because the existence check inside probeFile is
        // synchronous and fast.
        #expect(rec.fullPath == url.path)
        #expect(rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue)
    }
}
