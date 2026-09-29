import Foundation

/// Handles batch remuxing of correlated audio/video MXF pairs into MOV containers.
/// Supports stream copy (no re-encode) and re-encode modes, with RAM disk buffering for network sources.
enum CombineEngine {

    static var ffmpegPath: String { ToolLocator.ffmpegPath }

    struct CombineResult: Sendable {
        let success: Bool
        let stderr: String
        let exitCode: Int32
    }

    // MARK: - ffmpeg Remux

    /// Run ffmpeg to combine video+audio. Returns result with success/failure and stderr.
    /// Supports progress reporting via `-progress pipe:1` when a progress callback is provided.
    /// Cancellation-aware: terminates ffmpeg immediately when task is cancelled
    /// (with SIGKILL escalation via ProcessRunner if ffmpeg ignores SIGTERM).
    ///
    /// Subprocess plumbing consolidated onto ProcessRunner (codex finding #3):
    /// same arguments, same stderr→log routing, same exit-code semantics —
    /// only the pipe/termination machinery is shared now.
    static func runFFMpeg(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        technique: CombineJobStatus.CombineTechnique = .streamCopy,
        durationSeconds: Double = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async -> CombineResult {
        // Parse `-progress pipe:1` key=value lines (out_time_us=<microsecs>).
        var progressLine: (@Sendable (String) -> Void)?
        if let onProgress, durationSeconds > 0 {
            progressLine = { line in
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                    let seconds = us / 1_000_000
                    let frac = min(seconds / durationSeconds, 1.0)
                    onProgress(frac)
                }
            }
        }

        let result = await ProcessRunner.runProcess(
            executable: ffmpegPath,
            arguments: buildArgs(
                videoPath: videoPath,
                audioPath: audioPath,
                outputPath: outputPath,
                technique: technique,
                withProgress: onProgress != nil
            ),
            stdoutLine: progressLine,
            stderrLine: { line in DispatchQueue.main.async { log(line) } },
            stderrLimitBytes: nil   // callers keep the full transcript (pre-refactor behavior)
        )

        // Launch failure (stdout nil + synthetic -1, not user cancellation):
        // preserve the historical message prefix that callers/logs expect.
        if result.exitCode == -1, result.stdout == nil, result.stderr != "cancelled" {
            return CombineResult(
                success: false,
                stderr: "Failed to launch ffmpeg: \(result.stderr)",
                exitCode: -1
            )
        }

        return CombineResult(
            success: result.exitCode == 0,
            stderr: result.stderr,
            exitCode: result.exitCode
        )
    }

    // MARK: - Argument Construction
    //
    // Pulled out as a pure function so the encoder choice + flag set for
    // each technique can be unit-tested without spawning ffmpeg. If you
    // change an encoder string here, the matching test in CombineEngineArgsTests
    // will catch it on the next run.
    //
    // Encoder choice notes (2026-05-27):
    //   .reencodeProRes uses prores_videotoolbox (hardware) instead of
    //     prores_ks (software). M-series Macs all have a dedicated ProRes
    //     hardware encoder on the Media Engine — roughly 3-5× faster than
    //     prores_ks at equivalent quality for archival mezzanine work.
    //   .reencodeH264 uses h264_videotoolbox instead of libx264. Same
    //     reasoning — leaves the dedicated H.264 hardware encoder idle
    //     otherwise. -q:v 70 is a constant-quality target that produces
    //     visually-very-good results at ~25-40 Mbps for 1080p, matching
    //     the "smaller files" intent of this case while still substantially
    //     smaller than ProRes (220 Mbps).
    //   .streamCopy is unchanged — it's pure mux, zero encoding, nothing
    //     to accelerate.
    static func buildArgs(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        technique: CombineJobStatus.CombineTechnique,
        withProgress: Bool
    ) -> [String] {
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
            args += ["-c:v", "prores_videotoolbox", "-profile:v", "3", "-c:a", "pcm_s24le"]
        case .reencodeH264:
            args += ["-c:v", "h264_videotoolbox", "-q:v", "70", "-c:a", "aac", "-b:a", "256k"]
        }

        args += ["-movflags", "+faststart", "-f", "mov"]
        if withProgress {
            args += ["-progress", "pipe:1"]
        }
        args.append(outputPath)
        return args
    }

    // MARK: - Codec Compatibility

    struct CodecCheck: Sendable {
        let streamCopySafe: Bool
        let warning: String?
    }

    private static let movSafeVideoCodecs: Set<String> = [
        "h264", "hevc", "prores", "mpeg4", "mjpeg", "dnxhd",
        "rawvideo", "v210", "v410", "dvvideo", "cfhd",
        "ap4h", "ap4x", "apcn", "apch", "apcs", "apco",
    ]

    private static let movSafeAudioCodecs: Set<String> = [
        "aac", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be",
        "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f64le",
        "mp3", "ac3", "eac3", "alac", "opus", "flac",
        "pcm_mulaw", "pcm_alaw",
    ]

    static func checkStreamCopyCompatibility(
        videoCodec: String?,
        audioCodec: String?
    ) -> CodecCheck {
        let vc = (videoCodec ?? "").lowercased()
        let ac = (audioCodec ?? "").lowercased()

        if vc.isEmpty && ac.isEmpty {
            return CodecCheck(streamCopySafe: false, warning: "No codecs detected")
        }

        var warnings: [String] = []

        if !vc.isEmpty && !movSafeVideoCodecs.contains(vc) {
            warnings.append("Video codec '\(vc)' may not be compatible with MOV container")
        }
        if !ac.isEmpty && !movSafeAudioCodecs.contains(ac) {
            warnings.append("Audio codec '\(ac)' may not be compatible with MOV container")
        }

        if warnings.isEmpty {
            return CodecCheck(streamCopySafe: true, warning: nil)
        }
        return CodecCheck(streamCopySafe: false, warning: warnings.joined(separator: "; "))
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
                guard let chunk = try reader.read(upToCount: bufferSize),
                      !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
            }
        }.value
    }
}
