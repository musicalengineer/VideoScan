import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import os

final class SeekingFrameProvider: @unchecked Sendable {
    private let asset: AVURLAsset
    private let duration: Double
    private let frameInterval: Double
    private let slots: DispatchSemaphore
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    // Slots that have been "lent" to the consumer via `yield(...)` but
    // not yet returned via `releaseSlot()`. Tracked so that on stream
    // termination (e.g. Find Person job cancelled, consumer abandons
    // mid-iteration) we can signal the semaphore enough times to bring
    // its counter back to its initial value before deinit. Without
    // this, frames buffered inside AsyncStream that the consumer never
    // read leave the counter permanently below the initial — and
    // DispatchSemaphore's `dispose` crashes (EXC_BREAKPOINT in
    // _dispatch_semaphore_dispose.cold.1) when deallocated below initial.
    // Mirrors the pattern in FramePrefetcher.
    private let outstandingSlots = OSAllocatedUnfairLock(initialState: 0)

    private static let logger = Logger(
        subsystem: "Rick-Breen.VideoScan", category: "seeking-frames")
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(
        asset: AVURLAsset,
        duration: Double,
        frameInterval: Double,
        bufferCapacity: Int = 16
    ) {
        self.asset = asset
        self.duration = duration
        self.frameInterval = frameInterval
        self.slots = DispatchSemaphore(value: bufferCapacity)
    }

    func releaseSlot() {
        outstandingSlots.withLock { $0 = max(0, $0 - 1) }
        slots.signal()
    }

    func frames() -> AsyncStream<PrefetchedFrame> {
        let asset = self.asset
        let dur = self.duration
        let interval = self.frameInterval
        let sem = self.slots
        let flag = self.cancelFlag
        let owed = self.outstandingSlots

        return AsyncStream<PrefetchedFrame> { continuation in
            let queue = DispatchQueue(
                label: "com.videoscan.seeking-frames", qos: .userInitiated)

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
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = false
                let tolerance = CMTime(
                    seconds: min(interval * 0.4, 1.0), preferredTimescale: 600)
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance

                var t = 0.0
                var lastActualPTS = -interval
                var frameCount = 0

                while t < dur {
                    let done = flag.withLock { $0 }
                    if done { break }

                    sem.wait()
                    let doneAfterWait = flag.withLock { $0 }
                    if doneAfterWait {
                        // Cancellation arrived while we were blocked; balance
                        // the wait we just completed so the counter doesn't
                        // accumulate a deficit on this exit path.
                        sem.signal()
                        break
                    }

                    let requestTime = CMTime(seconds: t, preferredTimescale: 600)
                    let t0 = CFAbsoluteTimeGetCurrent()

                    var actualTime = CMTime.zero
                    let cgImage: CGImage
                    do {
                        cgImage = try generator.copyCGImage(
                            at: requestTime, actualTime: &actualTime)
                    } catch {
                        Self.logger.warning(
                            "Seek failed at \(String(format: "%.2f", t))s: \(error.localizedDescription)"
                        )
                        sem.signal()
                        t += interval
                        continue
                    }

                    let pts = CMTimeGetSeconds(actualTime)
                    if pts - lastActualPTS < interval * 0.5 {
                        sem.signal()
                        t += interval
                        continue
                    }
                    lastActualPTS = pts

                    guard let pixelBuffer = Self.pixelBuffer(from: cgImage) else {
                        sem.signal()
                        t += interval
                        continue
                    }

                    let decodeTime = CFAbsoluteTimeGetCurrent() - t0
                    frameCount += 1

                    // Hand the slot to the consumer — releaseSlot() returns it.
                    owed.withLock { $0 += 1 }
                    continuation.yield(
                        PrefetchedFrame(
                            pixelBuffer: pixelBuffer,
                            presentationTime: pts,
                            decodeSeconds: decodeTime
                        ))
                    t += interval
                }

                Self.logger.info("Seeking provider finished: \(frameCount) frames from \(String(format: "%.1f", dur))s video")
                continuation.finish()
            }
        }
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let w = image.width
        let h = image.height
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, w, h,
                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess,
            let buf = pb
        else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buf),
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
}
