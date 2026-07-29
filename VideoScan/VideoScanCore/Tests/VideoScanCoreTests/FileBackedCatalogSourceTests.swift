// FileBackedCatalogSourceTests.swift
// The file-backed catalog reader is the linchpin of the out-of-process
// preview-sweep design (Stage 1 injects it to drive the engine from a CLI
// with zero live app state). These pin, at the Core level:
//   - eligibility: only video-bearing (videoOnly / videoAndAudio) records
//     on reachable volumes become candidates;
//   - the decode path: a catalog.json written with the app's .iso8601
//     date strategy round-trips into the same eligible set;
//   - reachability is a RUNTIME check inside the impl (injected).

import XCTest
@testable import VideoScanCore

final class FileBackedCatalogSourceTests: XCTestCase {

    /// Minimal mirror of catalog.json's top level for the write side.
    /// VideoRecord itself is Decodable-only; the app persists via the
    /// byte-identical VideoRecordDTO, so the fixture encodes the same way.
    private struct CatalogFileOut: Encodable {
        let records: [VideoRecordDTO]
    }

    private func record(path: String, stream: StreamType,
                        container: String = "QuickTime / MOV",
                        codec: String = "h264",
                        duration: Double = 60) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = stream.rawValue
        r.container = container
        r.videoCodec = codec
        r.durationSeconds = duration
        return r
    }

    private func writeCatalog(_ records: [VideoRecord]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filebacked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // matches CatalogStore
        try encoder.encode(CatalogFileOut(records: records.map(VideoRecordDTO.init))).write(to: url)
        return url
    }

    func testEligibilityFiltersToVideoBearingReachable() async throws {
        let records = [
            record(path: "/Volumes/A/v1.mov", stream: .videoAndAudio),
            record(path: "/Volumes/A/v2.mkv", stream: .videoOnly,
                   container: "Matroska / WebM", codec: "ffv1"),
            record(path: "/Volumes/A/a1.wav", stream: .audioOnly),       // excluded: no video
            record(path: "/Volumes/A/x1.bin", stream: .ffprobeFailed),   // excluded
            record(path: "/Volumes/A/n1.dat", stream: .noStreams),       // excluded
        ]
        let url = try writeCatalog(records)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let source = FileBackedCatalogSource(catalogURL: url, isReachable: { _ in true })
        let candidates = await source.eligibleCandidates()

        XCTAssertEqual(Set(candidates.map(\.path)),
                       ["/Volumes/A/v1.mov", "/Volumes/A/v2.mkv"])
        // Fields survive the decode round-trip.
        let mkv = candidates.first { $0.path == "/Volumes/A/v2.mkv" }
        XCTAssertEqual(mkv?.container, "Matroska / WebM")
        XCTAssertEqual(mkv?.videoCodec, "ffv1")
        XCTAssertEqual(mkv?.durationSeconds, 60)
    }

    func testReachabilityIsARuntimeCheckInsideTheImpl() async throws {
        let records = [
            record(path: "/Volumes/Mounted/v.mov", stream: .videoAndAudio),
            record(path: "/Volumes/Ejected/v.mov", stream: .videoAndAudio),
        ]
        let url = try writeCatalog(records)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Only /Volumes/Mounted is reachable — the ejected one drops out
        // even though it's on disk in the catalog.
        let source = FileBackedCatalogSource(catalogURL: url,
                                             isReachable: { $0.hasPrefix("/Volumes/Mounted/") })
        let candidates = await source.eligibleCandidates()
        XCTAssertEqual(candidates.map(\.path), ["/Volumes/Mounted/v.mov"])
    }

    func testMissingCatalogYieldsEmpty() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)/catalog.json")
        let source = FileBackedCatalogSource(catalogURL: url, isReachable: { _ in true })
        let candidates = await source.eligibleCandidates()
        XCTAssertTrue(candidates.isEmpty)
    }
}
