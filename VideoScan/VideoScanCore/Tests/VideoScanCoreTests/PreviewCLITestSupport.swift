// PreviewCLITestSupport.swift
// Shared helpers for the out-of-process preview-helper tests (Stage 1):
// a fake renderer (no ffmpeg), a solid-color CGImage factory, and a
// catalog.json writer that encodes through the byte-identical VideoRecordDTO
// (the same path the app persists), plus on-disk dummy media so the executor's
// signature/reachability stats succeed.

import Foundation
import CoreGraphics
@testable import VideoScanCore

enum PreviewCLITestSupport {

    /// A tiny solid-color CGImage — stands in for a ripped frame without a
    /// media file. RGB, non-empty, JPEG-encodable by PreviewDiskCache.
    static func solidCGImage(width: Int = 16, height: Int = 16) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Catalog top-level mirror — encodes via VideoRecordDTO (byte-identical
    /// to the app's persistence).
    private struct CatalogFileOut: Encodable { let records: [VideoRecordDTO] }

    static func makeRecord(path: String, stream: StreamType,
                           container: String, codec: String,
                           duration: Double) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = stream.rawValue
        r.container = container
        r.videoCodec = codec
        r.durationSeconds = duration
        return r
    }

    static func writeCatalog(_ records: [VideoRecord], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601  // matches CatalogStore
        try encoder.encode(CatalogFileOut(records: records.map(VideoRecordDTO.init))).write(to: url)
    }

    /// Create a non-empty dummy file at `path` so previewFileSignature /
    /// reachability succeed for the executor (the fake renderer never reads
    /// the bytes).
    @discardableResult
    static func touchDummyMedia(at path: String, bytes: Int = 64) -> Bool {
        let data = Data(repeating: 0xAB, count: bytes)
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// A `PreviewMediaRenderer` that fabricates frames without ffmpeg — for the
/// runner / cache-readback sensors that don't need real decoding.
struct FakePreviewRenderer: PreviewMediaRenderer {
    var frameCount: Int = 8
    /// When true, both entry points throw a generic (non-ffmpegUnavailable)
    /// error — lets a test exercise the executor's genuine-failure path.
    var failGenuinely: Bool = false

    struct FakeError: Error {}

    func renderBestStill(_ candidate: PreviewSweepCandidate) async throws -> CGImage {
        if failGenuinely { throw FakeError() }
        return PreviewCLITestSupport.solidCGImage()
    }

    func renderFilmstrip(_ candidate: PreviewSweepCandidate) async throws -> [PreviewFilmstripFrame] {
        if failGenuinely { throw FakeError() }
        return (0..<frameCount).map {
            PreviewFilmstripFrame(offsetSeconds: Double($0) * 0.5 + 0.1,
                                  image: PreviewCLITestSupport.solidCGImage())
        }
    }
}
