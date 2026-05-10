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
        slots.signal()
    }

    func frames() -> AsyncStream<PrefetchedFrame> {
        let asset = self.asset
        let dur = self.duration
        let interval = self.frameInterval
        let sem = self.slots
        let flag = self.cancelFlag

        return AsyncStream<PrefetchedFrame> { continuation in
            let queue = DispatchQueue(
                label: "com.videoscan.seeking-frames", qos: .userInitiated)

            continuation.onTermination = { @Sendable _ in
                flag.withLock { $0 = true }
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
                    if doneAfterWait { break }

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
