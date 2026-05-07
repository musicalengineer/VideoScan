import Testing
import Foundation
import AVFoundation
@testable import VideoScan

@Suite("FramePrefetcher")
struct FramePrefetcherTests {

    private func makeVideoAndReader(
        container: String = "mp4",
        duration: Double = 2.0,
        frameRate: Int = 25
    ) throws -> (path: String, reader: AVAssetReader, output: AVAssetReaderTrackOutput, fps: Double) {
        guard TestMediaGenerator.isAvailable else {
            throw TestSkipError()
        }
        let path = try TestMediaGenerator.generate(
            container: container,
            streams: .videoOnly,
            duration: duration,
            frameRate: frameRate,
            prefix: "test_prefetch"
        )
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw TestSetupError(message: "no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw TestSetupError(message: "reader failed to start")
        }
        return (path, reader, output, Double(track.nominalFrameRate))
    }

    @Test("Yields frames from a generated MOV")
    func yieldsFramesFromMOV() async throws {
        let (path, reader, output, fps) = try makeVideoAndReader(container: "mov", duration: 2.0)
        defer { TestMediaGenerator.cleanup(path) }

        let frameInterval = 5.0 / fps
        let prefetcher = FramePrefetcher(
            reader: reader, trackOutput: output,
            frameInterval: frameInterval
        )
        var count = 0
        var lastPTS: Double = -1
        for await frame in prefetcher.frames() {
            #expect(frame.presentationTime > lastPTS, "Frames must arrive in PTS order")
            #expect(frame.decodeSeconds >= 0, "Decode time must be non-negative")
            lastPTS = frame.presentationTime
            count += 1
            prefetcher.releaseSlot()
        }
        #expect(count > 0, "Should yield at least one frame from a 2s video")
        #expect(reader.status == .completed || reader.status == .cancelled)
    }

    @Test("Yields frames from a generated MPEG-TS")
    func yieldsFramesFromTS() async throws {
        let (path, reader, output, fps) = try makeVideoAndReader(container: "ts", duration: 2.0)
        defer { TestMediaGenerator.cleanup(path) }

        let frameInterval = 5.0 / fps
        let prefetcher = FramePrefetcher(
            reader: reader, trackOutput: output,
            frameInterval: frameInterval
        )
        var count = 0
        for await frame in prefetcher.frames() {
            #expect(frame.presentationTime >= 0)
            count += 1
            prefetcher.releaseSlot()
        }
        #expect(count > 0, "Should yield frames from MPEG-TS container")
    }

    @Test("Frame skipping respects frameInterval")
    func frameSkipping() async throws {
        let (path, reader, output, _) = try makeVideoAndReader(container: "mov", duration: 2.0, frameRate: 25)
        defer { TestMediaGenerator.cleanup(path) }

        let largeInterval = 1.0
        let prefetcher = FramePrefetcher(
            reader: reader, trackOutput: output,
            frameInterval: largeInterval
        )
        var count = 0
        var prevTime: Double = -largeInterval
        for await frame in prefetcher.frames() {
            #expect(frame.presentationTime - prevTime >= largeInterval * 0.95,
                    "Gap between frames should be >= frameInterval")
            prevTime = frame.presentationTime
            count += 1
            prefetcher.releaseSlot()
        }
        #expect(count >= 1 && count <= 3, "With 1s interval on 2s video, expect 1-3 frames, got \(count)")
    }

    @Test("Backpressure: producer blocks when buffer is full")
    func backpressure() async throws {
        let (path, reader, output, fps) = try makeVideoAndReader(container: "mov", duration: 3.0, frameRate: 25)
        defer { TestMediaGenerator.cleanup(path) }

        let bufferSize = 2
        let prefetcher = FramePrefetcher(
            reader: reader, trackOutput: output,
            frameInterval: 1.0 / fps,
            bufferCapacity: bufferSize
        )

        var count = 0
        for await _ in prefetcher.frames() {
            count += 1
            prefetcher.releaseSlot()
            if count >= 10 { break }
        }
        #expect(count == 10, "Should get exactly 10 frames before breaking")
    }

    @Test("Cancellation stops the stream")
    func cancellation() async throws {
        let (path, reader, output, fps) = try makeVideoAndReader(container: "mov", duration: 5.0, frameRate: 25)
        defer { TestMediaGenerator.cleanup(path) }

        let prefetcher = FramePrefetcher(
            reader: reader, trackOutput: output,
            frameInterval: 1.0 / fps
        )

        var count = 0
        let task = Task {
            for await _ in prefetcher.frames() {
                count += 1
                prefetcher.releaseSlot()
                if count >= 5 { break }
            }
        }
        await task.value
        #expect(count >= 5)
        #expect(count < 125, "Should not have consumed all 125 frames (5s × 25fps)")
    }

    @Test("Decode time is plausible")
    func decodeTimePlausible() async throws {
        let (path, reader, output, fps) = try makeVideoAndReader(container: "mov", duration: 1.0)
        defer { TestMediaGenerator.cleanup(path) }

        let prefetcher = FramePrefetcher(
            reader: reader, trackOutput: output,
            frameInterval: 5.0 / fps
        )
        for await frame in prefetcher.frames() {
            #expect(frame.decodeSeconds >= 0, "Decode time must be non-negative")
            #expect(frame.decodeSeconds < 5.0, "Single frame decode shouldn't take 5 seconds")
            prefetcher.releaseSlot()
        }
    }
}

private struct TestSkipError: Error {}
private struct TestSetupError: Error {
    let message: String
}
