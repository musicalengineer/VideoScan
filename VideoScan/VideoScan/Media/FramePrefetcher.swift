import AVFoundation
import CoreVideo
import Foundation
import os

struct PrefetchedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: Double
    let decodeSeconds: Double
}

final class FramePrefetcher: @unchecked Sendable {
    private let trackOutput: AVAssetReaderTrackOutput
    private let frameInterval: Double
    private let reader: AVAssetReader
    private let slots: DispatchSemaphore
    private let bufferCapacity: Int
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    /// Slots that have been "lent" to the consumer via `yield(...)` but
    /// not yet returned via `releaseSlot()`. Tracked so that on stream
    /// termination (e.g. user hits Stop, consumer abandons mid-iteration)
    /// we can signal the semaphore enough times to bring its counter back
    /// to its initial value before deinit. Without this, frames buffered
    /// inside AsyncStream that the consumer never read leave the counter
    /// permanently below the initial — and DispatchSemaphore's `dispose`
    /// crashes (`EXC_BREAKPOINT` in `_dispatch_semaphore_dispose.cold.1`)
    /// when deallocated below initial.
    private let outstandingSlots = OSAllocatedUnfairLock(initialState: 0)

    init(
        reader: AVAssetReader,
        trackOutput: AVAssetReaderTrackOutput,
        frameInterval: Double,
        bufferCapacity: Int = 16
    ) {
        self.reader = reader
        self.trackOutput = trackOutput
        self.frameInterval = frameInterval
        self.bufferCapacity = bufferCapacity
        self.slots = DispatchSemaphore(value: bufferCapacity)
    }

    func releaseSlot() {
        outstandingSlots.withLock { $0 = max(0, $0 - 1) }
        slots.signal()
    }

    func frames() -> AsyncStream<PrefetchedFrame> {
        let output = self.trackOutput
        let interval = self.frameInterval
        let assetReader = self.reader
        let sem = self.slots
        let flag = self.cancelFlag
        let owed = self.outstandingSlots

        return AsyncStream<PrefetchedFrame> { continuation in
            let queue = DispatchQueue(label: "com.videoscan.frame-prefetch", qos: .userInitiated)

            continuation.onTermination = { @Sendable _ in
                flag.withLock { $0 = true }
                // Drain the slot debt so the semaphore can dispose cleanly.
                // For every frame we yielded but the consumer hasn't (and
                // now won't) call `releaseSlot()` on, signal once.
                let drainCount = owed.withLock { d -> Int in
                    let v = d
                    d = 0
                    return v
                }
                for _ in 0..<drainCount { sem.signal() }
                // Plus one more to wake the producer if it's currently
                // blocked on `sem.wait()` for the next slot.
                sem.signal()
            }

            queue.async {
                var lastEmittedTime = -interval

                while assetReader.status == .reading {
                    if flag.withLock({ $0 }) { break }

                    sem.wait()

                    if flag.withLock({ $0 }) {
                        // Cancellation arrived while we were blocked; balance
                        // the wait we just completed so the counter doesn't
                        // accumulate a deficit on this exit path.
                        sem.signal()
                        break
                    }

                    let t0 = CFAbsoluteTimeGetCurrent()
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        sem.signal()
                        break
                    }
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

                    guard pts - lastEmittedTime >= interval else {
                        sem.signal()
                        continue
                    }
                    lastEmittedTime = pts

                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        sem.signal()
                        continue
                    }
                    let decodeTime = CFAbsoluteTimeGetCurrent() - t0

                    // Hand the slot to the consumer — releaseSlot() returns it.
                    owed.withLock { $0 += 1 }
                    continuation.yield(PrefetchedFrame(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts,
                        decodeSeconds: decodeTime
                    ))
                }
                continuation.finish()
            }
        }
    }
}
