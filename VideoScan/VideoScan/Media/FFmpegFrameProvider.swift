// FFmpegFrameProvider.swift
// ffmpeg rawvideo-pipe frame source for clips AVFoundation cannot open —
// mkv containers (no Matroska support in AVURLAsset at all) and codecs
// AVAssetReader won't start on (MPEG-2 in QuickTime, the DVD-rip case).
// Both are common in this archive's RESCUED material, which is exactly
// the material the person search must not silently skip (the 2026-08-03
// 9-of-9 "Cannot Open" Find Donna failure).
//
// Yields the same AsyncStream<PrefetchedFrame> + slot-semaphore contract
// as FramePrefetcher, so NativeRecipeScorer's frame loop is source-
// agnostic. The decode chain is the python reference engine's transport
// (`ffmpeg -vf yadif,fps=N`): deinterlace + sample at the recipe rate —
// NV12 raw frames over a pipe instead of jpgs on disk. Note this also
// closes the "no deinterlacing" gap listed in NativeRecipeScorer's
// header, but only for fallback-decoded clips.
//
// Shell-out note: ffprobe goes through ProcessRunner as usual. The frame
// pipe itself manages a Process directly — ProcessRunner's contract is
// collect-or-line-stream text, and bolting bounded binary streaming with
// consumer backpressure onto it would grow the shared primitive for one
// caller. The fd lifecycle here is simple by construction: one stdout
// pipe drained to EOF by the producer thread, one stderr handler cleared
// on exit, waitUntilExit before the stream finishes.
//
// Memory: identical budget to FramePrefetcher — at most `bufferCapacity`
// (16) decoded NV12 frames in flight, enforced by the same lent-slot
// semaphore (and the same drain-on-termination debt accounting; see
// FramePrefetcher's crash note on DispatchSemaphore disposal).

import CoreVideo
import Darwin
import Foundation
import os

private let ffFrameLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "ffmpeg-frame-provider")

final class FFmpegFrameProvider: @unchecked Sendable {

    /// Output geometry + duration, resolved by ffprobe before spawn.
    /// Width/height are post-autorotate and evenified — the exact frame
    /// dimensions ffmpeg is told to emit, so the byte math below is
    /// deterministic rather than inferred.
    struct ProbeInfo: Sendable {
        let width: Int
        let height: Int
        let duration: Double
    }

    /// Media duration in seconds (for the caller's stall watchdog).
    let duration: Double

    private let width: Int
    private let height: Int
    private let frameInterval: Double
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let slots: DispatchSemaphore
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    /// Same lent-slot debt tracking as FramePrefetcher — see its comment
    /// for the semaphore-disposal crash this prevents.
    private let outstandingSlots = OSAllocatedUnfairLock(initialState: 0)

    private struct ExitState: Sendable {
        var finished = false
        var status: Int32 = 0
        var stderrTail = ""
    }
    private let exitState = OSAllocatedUnfairLock(initialState: ExitState())
    /// Signaled by terminationHandler when the child is reaped. The
    /// producer waits on this BOUNDED — never Process.waitUntilExit,
    /// which can wedge forever after stdout EOF even with the child gone
    /// (codex stress repro 2026-08-03: ~48 sequential scans, thread
    /// parked in NSConcreteTask.waitUntilExit, no ffmpeg in ps).
    private let exited = DispatchSemaphore(value: 0)

    /// Probe the clip and spawn ffmpeg, or explain why we can't. Async
    /// only for the ffprobe subprocess; the ffmpeg spawn is immediate.
    static func open(clip: URL, frameInterval: Double) async
        -> Result<FFmpegFrameProvider, RecipeError> {
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            return .failure(RecipeError("ffmpeg not found"))
        }
        switch await probe(clip: clip) {
        case .failure(let error):
            return .failure(error)
        case .success(let info):
            let provider = FFmpegFrameProvider(clip: clip, probe: info,
                                               frameInterval: frameInterval,
                                               ffmpegPath: ffmpeg)
            do {
                try provider.process.run()
            } catch {
                return .failure(RecipeError("ffmpeg spawn failed: \(error.localizedDescription)"))
            }
            return .success(provider)
        }
    }

    private init(clip: URL, probe: ProbeInfo, frameInterval: Double,
                 ffmpegPath: String, bufferCapacity: Int = 16) {
        self.width = probe.width
        self.height = probe.height
        self.duration = probe.duration
        self.frameInterval = frameInterval
        self.slots = DispatchSemaphore(value: bufferCapacity)

        // yadif,fps mirrors the python engine's sampling; the explicit
        // scale pins the emitted dimensions to the probed (evenified)
        // ones so a frame is always exactly width*height*3/2 bytes.
        let fps = String(format: "%g", 1.0 / frameInterval)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-nostdin", "-v", "error",
            "-i", clip.path,
            "-map", "0:v:0",
            "-vf", "yadif,fps=\(fps),scale=\(width):\(height)",
            "-pix_fmt", "nv12",
            "-f", "rawvideo", "pipe:1"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Record the exit the moment the child is reaped — this, not
        // waitUntilExit, is the exit-detection mechanism (see `exited`).
        let state = exitState
        let exitedSem = exited
        process.terminationHandler = { proc in
            state.withLock { s in
                s.finished = true
                s.status = proc.terminationStatus
            }
            exitedSem.signal()
        }

        // Drain stderr as it arrives (ffmpeg blocks if the pipe fills),
        // keeping only a tail for the failure message.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                state.withLock { s in
                    s.stderrTail = String((s.stderrTail + text).suffix(2048))
                }
            }
        }
    }

    func releaseSlot() {
        outstandingSlots.withLock { $0 = max(0, $0 - 1) }
        slots.signal()
    }

    /// Post-stream verdict: non-nil when ffmpeg itself failed. Valid only
    /// after the stream finished naturally (the producer records the exit
    /// status before finishing); returns nil while decode is in flight or
    /// after a consumer-side cancellation.
    func failureMessage() -> String? {
        exitState.withLock { s in
            guard s.finished, s.status != 0 else { return nil }
            let tail = s.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "ffmpeg decode failed (exit \(s.status))"
                + (tail.isEmpty ? "" : ": \(tail)")
        }
    }

    func frames() -> AsyncStream<PrefetchedFrame> {
        let sem = slots
        let flag = cancelFlag
        let owed = outstandingSlots
        let proc = process
        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        let exitedSem = exited
        let frameSize = width * height * 3 / 2
        let w = width, h = height
        let interval = frameInterval

        return AsyncStream<PrefetchedFrame> { continuation in
            let queue = DispatchQueue(label: "com.videoscan.ffmpeg-frame-provider",
                                      qos: .userInitiated)

            continuation.onTermination = { @Sendable _ in
                flag.withLock { $0 = true }
                if proc.isRunning { proc.terminate() }
                let drainCount = owed.withLock { d -> Int in
                    let v = d
                    d = 0
                    return v
                }
                for _ in 0..<drainCount { sem.signal() }
                sem.signal()
            }

            queue.async {
                var frameIndex = 0

                while true {
                    if flag.withLock({ $0 }) { break }
                    sem.wait()
                    if flag.withLock({ $0 }) {
                        sem.signal()
                        break
                    }

                    let t0 = CFAbsoluteTimeGetCurrent()
                    // Assemble exactly one frame; readData can return
                    // short chunks, empty means EOF.
                    var frameData = Data(capacity: frameSize)
                    while frameData.count < frameSize {
                        let chunk = stdout.readData(ofLength: frameSize - frameData.count)
                        if chunk.isEmpty { break }
                        frameData.append(chunk)
                    }
                    guard frameData.count == frameSize else {
                        sem.signal()
                        break
                    }
                    guard let buffer = Self.makeNV12Buffer(from: frameData,
                                                           width: w, height: h) else {
                        sem.signal()
                        continue
                    }
                    let decodeTime = CFAbsoluteTimeGetCurrent() - t0

                    owed.withLock { $0 += 1 }
                    continuation.yield(PrefetchedFrame(
                        pixelBuffer: buffer,
                        presentationTime: Double(frameIndex) * interval,
                        decodeSeconds: decodeTime
                    ))
                    frameIndex += 1
                }

                if proc.isRunning, flag.withLock({ $0 }) { proc.terminate() }
                // Bounded wait for the terminationHandler, escalating
                // SIGTERM → SIGKILL. Stdout EOF already means ffmpeg is
                // done writing, so if the exit notification never comes
                // (the waitUntilExit wedge this replaces) we log and
                // finish anyway — an unrecorded exit degrades to "no
                // failure message", never to a hung scan.
                if exitedSem.wait(timeout: .now() + 5) == .timedOut {
                    if proc.isRunning { proc.terminate() }
                    if exitedSem.wait(timeout: .now() + 2) == .timedOut {
                        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                        if exitedSem.wait(timeout: .now() + 2) == .timedOut {
                            ffFrameLog.warning("ffmpeg exit notification never arrived — finishing stream without status")
                        }
                    }
                }
                stderr.readabilityHandler = nil
                try? stdout.close()
                continuation.finish()
            }
        }
    }

    // MARK: - Probe

    /// ffprobe pass for output geometry + duration. Rotation matters:
    /// ffmpeg autorotates on decode (matching what AVFoundation's
    /// preferredTransform path would have shown Vision), so a ±90°
    /// displaymatrix swaps the emitted width/height.
    private static func probe(clip: URL) async -> Result<ProbeInfo, RecipeError> {
        let result = await ProcessRunner.runProcess(
            executable: ToolLocator.ffprobePath,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height:stream_side_data=rotation:format=duration",
                "-of", "json",
                clip.path
            ],
            deadlineSeconds: 60)
        guard result.exitCode == 0, let stdout = result.stdout,
              let data = stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let stderr = (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RecipeError("ffprobe failed"
                + (stderr.isEmpty ? "" : ": \(stderr.suffix(300))")))
        }
        guard let stream = (json["streams"] as? [[String: Any]])?.first,
              var w = stream["width"] as? Int,
              var h = stream["height"] as? Int, w > 0, h > 0 else {
            return .failure(RecipeError("ffprobe: no video stream dimensions"))
        }
        let rotation = (stream["side_data_list"] as? [[String: Any]])?
            .compactMap { $0["rotation"] as? Int }.first ?? 0
        if abs(rotation) % 180 == 90 { swap(&w, &h) }
        // NV12 needs even dimensions; the scale filter is pinned to these.
        w = max(2, (w / 2) * 2)
        h = max(2, (h / 2) * 2)

        let duration = ((json["format"] as? [String: Any])?["duration"] as? String)
            .flatMap(Double.init) ?? 0
        guard duration > 0 else {
            return .failure(RecipeError("ffprobe: unknown duration"))
        }
        return .success(ProbeInfo(width: w, height: h, duration: duration))
    }

    // MARK: - NV12 wrap

    /// Copy one raw NV12 frame (Y plane then interleaved UV) into a
    /// CVPixelBuffer of the SAME format the AVAssetReader path emits
    /// (420YpCbCr8BiPlanarVideoRange), row-by-row because the buffer's
    /// plane strides may exceed the packed width.
    private static func makeNV12Buffer(from data: Data,
                                       width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attrs, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yDest = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvDest = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let src = raw.baseAddress else { return }
            for row in 0..<height {
                memcpy(yDest + row * yStride, src + row * width, width)
            }
            let uvSrc = src + width * height
            for row in 0..<(height / 2) {
                memcpy(uvDest + row * uvStride, uvSrc + row * width, width)
            }
        }
        return buffer
    }
}
