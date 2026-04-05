import Foundation

/// Handles batch remuxing of correlated audio/video MXF pairs into MOV containers.
/// Uses ffmpeg stream copy (no re-encode), with RAM disk buffering for network sources.
enum CombineEngine {

    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    // MARK: - ffmpeg Remux

    /// Run ffmpeg to remux video+audio into MOV. Returns true on success.
    /// Cancellation-aware: terminates ffmpeg immediately when task is cancelled.
    static func runFFMpeg(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
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

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { log(text.trimmingCharacters(in: .newlines)) }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        DispatchQueue.main.async { log(text.trimmingCharacters(in: .newlines)) }
                    }
                    continuation.resume(returning: p.terminationStatus == 0)
                }
                do    { try proc.run() }
                catch { continuation.resume(returning: false) }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
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
