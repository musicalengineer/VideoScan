import Testing
import Foundation
import AVFoundation
@testable import VideoScan

@Suite("SeekingFrameProvider")
struct SeekingFrameProviderTests {

    nonisolated static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    private func makeAsset(
        container: String = "mp4",
        duration: Double = 2.0,
        frameRate: Int = 25
    ) throws -> (path: String, asset: AVURLAsset, duration: Double) {
        guard TestMediaGenerator.isAvailable else {
            throw TestSkipError()
        }
        let path = try TestMediaGenerator.generate(
            container: container,
            streams: .videoOnly,
            duration: duration,
            frameRate: frameRate,
            prefix: "test_seeking"
        )
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        return (path, asset, duration)
    }

    @Test("Yields frames from a generated MOV",
          .disabled(if: isCI, "AVFoundation frame decoding unavailable on virtualized CI runner"))
    func yieldsFramesFromMOV() async throws {
        let (path, asset, dur) = try makeAsset(container: "mov", duration: 2.0)
        defer { TestMediaGenerator.cleanup(path) }

        let provider = SeekingFrameProvider(
            asset: asset, duration: dur, frameInterval: 0.5
        )
        var count = 0
        for await frame in provider.frames() {
            #expect(frame.presentationTime >= 0)
            #expect(frame.decodeSeconds >= 0)
            count += 1
            provider.releaseSlot()
        }
        #expect(count > 0, "Should yield at least one frame from a 2s video")
    }

    // Regression: parallel-load trace 2026-05-26 caught
    // `_dispatch_semaphore_dispose.cold.1` aborting VS when a Find Person
    // job was cancelled with frames still buffered inside the
    // SeekingFrameProvider's AsyncStream. The semaphore's counter ended up
    // permanently below initial because onTermination signalled exactly
    // once regardless of how many slots were owed to un-released frames.
    //
    // Sibling class FramePrefetcher had already been fixed (see
    // FramePrefetcherTests.abandonedMidStreamDisposesCleanly) but the fix
    // was never back-ported here. This test reproduces the pattern: yield
    // several frames, abandon iteration *without* calling releaseSlot()
    // on the unread frames, let the provider go out of scope. Reaching
    // the end of the test without a libdispatch abort is the assertion.
    //
    // NOTE: deliberately runs everywhere (no .disabled(if: isCI)). The
    // dispose semantics this test exercises are independent of the codec
    // path's CI quirks — what matters is that the producer queue gets
    // the semaphore's slot debt cleared before deinit.
    @Test("Abandoned mid-stream consumer does not crash on dispose")
    func abandonedMidStreamDisposesCleanly() async throws {
        let (path, asset, dur) = try makeAsset(
            container: "mov", duration: 5.0, frameRate: 25
        )
        defer { TestMediaGenerator.cleanup(path) }

        // Tight scope: provider exists only inside this block. When it
        // exits, ARC frees the provider and DispatchSemaphore.dispose
        // runs — must not crash even with frames still in flight.
        do {
            let provider = SeekingFrameProvider(
                asset: asset, duration: dur,
                frameInterval: 0.2,
                bufferCapacity: 4
            )

            var count = 0
            let task = Task { () -> Int in
                for await _ in provider.frames() {
                    count += 1
                    // Deliberately do NOT call releaseSlot() — simulate
                    // the consumer being cancelled before it can return
                    // the slot. Producer keeps yielding into the buffer
                    // until full, then blocks.
                    if count >= 2 { break }
                }
                return count
            }
            _ = await task.value
            // Provider falls out of scope here.
        }

        // Give the producer queue a beat to fully unwind onTermination
        // (drain owed slots + signal to wake) before the test ends.
        try await Task.sleep(for: .milliseconds(100))
        // Reaching this line without crashing is the assertion.
        #expect(true)
    }

    @Test("Cancellation stops the stream",
          .disabled(if: isCI, "AVFoundation frame decoding unavailable on virtualized CI runner"))
    func cancellation() async throws {
        let (path, asset, dur) = try makeAsset(container: "mov", duration: 5.0, frameRate: 25)
        defer { TestMediaGenerator.cleanup(path) }

        let provider = SeekingFrameProvider(
            asset: asset, duration: dur, frameInterval: 0.1
        )

        var count = 0
        let task = Task {
            for await _ in provider.frames() {
                count += 1
                provider.releaseSlot()
                if count >= 5 { break }
            }
        }
        await task.value
        #expect(count >= 5)
        #expect(count < 50, "Should not have consumed all frames")
    }
}

private struct TestSkipError: Error {}
private struct TestSetupError: Error {
    let message: String
}
