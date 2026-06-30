// LocalProbeGroupCatalogGateTests.swift
// Punch-list #1 (code portion): the LOCAL scan path (runTargetProbeGroup) must
// apply the SAME junk-admission gate (shouldCatalogProbeResult) that the
// network-resume path (runResumedProbeGroup) already applies. Without the gate
// a local scan — especially with the "Scan files with no extension" toggle on —
// admits ffprobe-FAILED, extensionless data blobs into the catalog, while the
// identical file coming through the resume path would be dropped.
//
// Red/green:
//   - localScanDropsExtensionlessJunk FAILS before the fix (the zero-byte
//     extensionless blob ffprobe can't read gets a record) and PASSES after.
//   - localScanKeepsRealExtensionlessMedia guards against over-filtering: a real
//     media file with NO extension that ffprobe SUCCESSFULLY decodes must still
//     be cataloged (the iPhoto MJPEG / Avid t2-v case).

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Local probe-group cataloging gate — parity with network-resume path")
struct LocalProbeGroupCatalogGateTests {

    /// Real, ffprobe-decodable media fixture (checked into the repo).
    private static let realMediaFixture: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()   // VideoScanTests
            .deletingLastPathComponent()   // VideoScan
            .deletingLastPathComponent()   // repo root
        return repoRoot.appendingPathComponent("tests/fixtures/videos/test_video_audio.mp4").path
    }()

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_localgate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Drives the real local probe path against `dir` with the extensionless
    /// toggle on and checksums off (fast). Returns the catalog records produced.
    private func runLocalScan(_ dir: URL) async -> [VideoRecord] {
        let model = VideoScanModel()
        model.scanOptions.probeExtensionless = true
        model.scanOptions.skipChecksums = true
        model.scanOptions.skipSmallFiles = false
        let target = CatalogScanTarget(searchPath: dir.path)
        let result = await model.runTargetProbeGroup(
            target: target,
            root: dir.path,
            volName: "TestVol",
            rootIsNetwork: false,
            ramMountPoint: nil
        )
        return result.records
    }

    @Test("Local scan drops extensionless + ffprobe-failed junk (parity with resume path)")
    func localScanDropsExtensionlessJunk() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A zero-byte-content blob with no extension: ffprobe cannot identify it
        // as media, so streamType == ffprobeFailed and ext == "". This is the
        // exact junk shape the gate must reject.
        try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("junk-blob"))

        let records = await runLocalScan(dir)
        let names = Set(records.map { $0.filename })
        #expect(!names.contains("junk-blob"),
                "extensionless + ffprobe-failed blob must NOT be cataloged on the local path")
    }

    @Test("Local scan keeps real extensionless media ffprobe can decode (no over-filtering)")
    func localScanKeepsRealExtensionlessMedia() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.realMediaFixture),
                     "fixture test_video_audio.mp4 must exist")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Copy a real, decodable media file to a name WITHOUT an extension. ffprobe
        // succeeds → streamType is real media → the gate must keep it even though
        // ext == "".
        let dest = dir.appendingPathComponent("real-media-noext")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.realMediaFixture), to: dest)

        let records = await runLocalScan(dir)
        let kept = records.first { $0.filename == "real-media-noext" }
        let rec = try #require(kept,
                               "ffprobe-successful extensionless media must STILL be cataloged")
        #expect(rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue,
                "the kept record should be ffprobe-successful media, not a failure")
    }
}
