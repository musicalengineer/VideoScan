import Foundation

/// Handles batch remuxing of correlated audio/video MXF pairs into MOV containers.
/// Uses ffmpeg stream copy (no re-encode), with RAM disk buffering for network sources.
enum CombineEngine {

    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    struct CombineResult: Sendable {
        let success: Bool
        let stderr: String
        let exitCode: Int32
    }

    // MARK: - ffmpeg Remux

    /// Run ffmpeg to remux video+audio into MOV. Returns result with success/failure and stderr.
    /// Cancellation-aware: terminates ffmpeg immediately when task is cancelled.
    static func runFFMpeg(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> CombineResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y",
            "-probesize", "50M",
            "-analyzeduration", "10M",
            "-i", videoPath,
            "-i", audioPath,
            "-map", "0:v",
            "-map", "1:a",
            "-c:v", "copy",
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-f", "mov",
            outputPath
        ]

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        let collected = StderrCollector()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .newlines)
                collected.append(trimmed)
                DispatchQueue.main.async { log(trimmed) }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
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
                do    { try proc.run() }
                catch {
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
