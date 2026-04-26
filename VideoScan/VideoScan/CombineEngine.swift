import Foundation

/// Handles batch remuxing of correlated audio/video MXF pairs into MOV containers.
/// Supports stream copy (no re-encode) and re-encode modes, with RAM disk buffering for network sources.
enum CombineEngine {

    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    struct CombineResult: Sendable {
        let success: Bool
        let stderr: String
        let exitCode: Int32
    }

    // MARK: - ffmpeg Remux

    /// Run ffmpeg to combine video+audio. Returns result with success/failure and stderr.
    /// Supports progress reporting via `-progress pipe:1` when a progress callback is provided.
    /// Cancellation-aware: terminates ffmpeg immediately when task is cancelled.
    static func runFFMpeg(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        technique: CombineJobStatus.CombineTechnique = .streamCopy,
        durationSeconds: Double = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async -> CombineResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)

        var args = [
            "-y",
            "-probesize", "50M",
            "-analyzeduration", "10M",
            "-i", videoPath,
            "-i", audioPath,
            "-map", "0:v",
            "-map", "1:a",
        ]

        switch technique {
        case .streamCopy:
            args += ["-c:v", "copy", "-c:a", "copy"]
        case .reencodeProRes:
            args += ["-c:v", "prores_ks", "-profile:v", "3", "-c:a", "pcm_s24le"]
        case .reencodeH264:
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-c:a", "aac", "-b:a", "256k"]
        }

        args += ["-movflags", "+faststart", "-f", "mov"]

        if onProgress != nil {
            args += ["-progress", "pipe:1"]
        }

        args.append(outputPath)
        proc.arguments = args

        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe

        let collected = StderrCollector()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .newlines)
                collected.append(trimmed)
                DispatchQueue.main.async { log(trimmed) }
            }
        }

        if let onProgress, durationSeconds > 0 {
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                    for line in text.components(separatedBy: .newlines) {
                        if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                            let seconds = us / 1_000_000
                            let frac = min(seconds / durationSeconds, 1.0)
                            onProgress(frac)
                        }
                    }
                }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        let trimmed = text.trimmingCharacters(in: .newlines)
                        collected.append(trimmed)
                        DispatchQueue.main.async { log(trimmed) }
                    }
                    let result = CombineResult(
                        success: p.terminationStatus == 0,
                        stderr: collected.text,
                        exitCode: p.terminationStatus
                    )
                    continuation.resume(returning: result)
                }
                do { try proc.run() } catch {
                    continuation.resume(returning: CombineResult(
                        success: false,
                        stderr: "Failed to launch ffmpeg: \(error.localizedDescription)",
                        exitCode: -1
                    ))
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Thread-safe stderr collector.
    private final class StderrCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Buffered Copy

    /// Large-buffer async file copy (4 MB chunks) for network reliability.
    static func bufferedCopy(
        from src: URL,
        to dst: URL,
        bufferSize: Int = 4 * 1024 * 1024
    ) async throws {
        try await Task.detached {
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: src.path))
            defer { try? reader.close() }

            FileManager.default.createFile(atPath: dst.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: URL(fileURLWithPath: dst.path)) else {
                throw NSError(
                    domain: "VideoScan", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot write \(dst.lastPathComponent)"]
                )
            }
            defer { try? writer.close() }

            while true {
                try Task.checkCancellation()
                let chunk = reader.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
            }
        }.value
    }
}
