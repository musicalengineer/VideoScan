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
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    init(
        reader: AVAssetReader,
        trackOutput: AVAssetReaderTrackOutput,
        frameInterval: Double,
        bufferCapacity: Int = 4
    ) {
        self.reader = reader
        self.trackOutput = trackOutput
        self.frameInterval = frameInterval
        self.slots = DispatchSemaphore(value: bufferCapacity)
    }

    func releaseSlot() {
        slots.signal()
    }

    func frames() -> AsyncStream<PrefetchedFrame> {
        let output = self.trackOutput
        let interval = self.frameInterval
        let assetReader = self.reader
        let sem = self.slots
        let flag = self.cancelFlag

        return AsyncStream<PrefetchedFrame> { continuation in
            let queue = DispatchQueue(label: "com.videoscan.frame-prefetch", qos: .userInitiated)

            continuation.onTermination = { @Sendable _ in
                flag.withLock { $0 = true }
                sem.signal()
            }

            queue.async {
                var lastEmittedTime = -interval

                while assetReader.status == .reading {
                    let done = flag.withLock { $0 }
                    if done { break }

                    sem.wait()
                    let doneAfterWait = flag.withLock { $0 }
                    if doneAfterWait { break }

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
