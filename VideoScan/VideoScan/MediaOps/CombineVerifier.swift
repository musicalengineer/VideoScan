import Foundation

/// Post-combine verification and I/O utilities for the Combine pipeline.
/// All methods are static and nonisolated — safe to call from any context.
enum CombineVerifier {

    struct VerifyResult {
        let ok: Bool
        let reason: String
        let summary: String
        var warning: String?
    }

    /// Deadline on each verify subprocess — the ffprobe, the one-frame
    /// decode tests (N1014-F3, 2026-10-07: none had one, so a wedged probe on
    /// a drive that stopped answering hung the pair, and the batch, forever).
    /// Each reads a header or one frame, so 2 minutes is far past healthy.
    /// volumedetect reads the whole audio stream: see `levelTimeoutSeconds`.
    static let toolTimeoutSeconds: Double = 120

    /// volumedetect's deadline: the tool deadline, or the program's own
    /// length if longer (decoding audio is far faster than real time, so a
    /// healthy run never gets near it). A timeout only loses the "may be
    /// silent" warning; it never fails or passes verification.
    static func levelTimeoutSeconds(base: Double, expectedDuration: Double) -> Double {
        guard expectedDuration.isFinite else { return base }
        return max(base, expectedDuration)
    }

    /// Probe the combined output to confirm it has both video and audio streams
    /// and a reasonable duration relative to the source. Every subprocess has
    /// a deadline (`CombineTestSeams.verifyToolTimeoutSeconds`, production =
    /// `toolTimeoutSeconds`); a probe or decode that times out fails verify.
    static func verifyCombineOutput(
        url: URL,
        expectedDuration: Double,
        ffprobePath: String,
        ffmpegPath: String
    ) async -> VerifyResult {
        let timeout = CombineTestSeams.verifyToolTimeoutSeconds
        let probed = await runFFProbeDetailed(url: url, ffprobePath: ffprobePath, timeoutSeconds: timeout)
        guard let probe = probed.output else {
            let why = probed.timedOut ? "timed out after \(Int(timeout))s" : probed.stderr
            return VerifyResult(ok: false, reason: "ffprobe failed: \(why)", summary: "")
        }

        let streams = probe.streams ?? []
        let vStream = streams.first(where: { $0.codec_type == "video" })
        let aStream = streams.first(where: { $0.codec_type == "audio" })

        guard let vStream else {
            return VerifyResult(ok: false, reason: "no video stream in output", summary: "")
        }
        guard let aStream else {
            return VerifyResult(ok: false, reason: "no audio stream in output", summary: "")
        }

        if (vStream.width ?? 0) == 0 || (vStream.height ?? 0) == 0 {
            return VerifyResult(ok: false, reason: "video stream has no dimensions (\(vStream.width ?? 0)x\(vStream.height ?? 0))", summary: "")
        }

        let outDuration = positiveFiniteDuration(probe.format?.duration)
        let validExpectedDuration = expectedDuration.isFinite && expectedDuration > 0
            ? expectedDuration
            : nil
        let tolerance = max((validExpectedDuration ?? 0) * 0.1, 2.0)
        if let validExpectedDuration, let outDuration,
           abs(outDuration - validExpectedDuration) > tolerance {
            return VerifyResult(
                ok: false,
                reason: String(format: "duration mismatch: expected %.1fs, got %.1fs", validExpectedDuration, outDuration),
                summary: ""
            )
        }

        guard let videoDuration = resolveComparisonVideoDuration(
            streamDuration: vStream.duration,
            formatDuration: probe.format?.duration,
            expectedDuration: expectedDuration
        ) else {
            return VerifyResult(
                ok: false,
                reason: "video duration unavailable; cannot verify audio coverage",
                summary: ""
            )
        }
        guard let audioDuration = positiveFiniteDuration(aStream.duration) else {
            return VerifyResult(
                ok: false,
                reason: "audio duration unavailable; cannot verify full-program coverage",
                summary: ""
            )
        }
        if let reason = audioCoverageMismatchReason(
            videoDuration: videoDuration,
            audioDuration: audioDuration
        ) {
            return VerifyResult(
                ok: false,
                reason: reason,
                summary: ""
            )
        }

        if let reason = await decodeFailure(url: url, ffmpegPath: ffmpegPath, timeoutSeconds: timeout) {
            return VerifyResult(ok: false, reason: reason, summary: "")
        }

        let meanDB = await detectAudioLevel(
            url: url, ffmpegPath: ffmpegPath,
            timeoutSeconds: levelTimeoutSeconds(base: timeout, expectedDuration: expectedDuration))
        var warning: String?
        if let db = meanDB, db < -60 {
            warning = String(format: "Audio may be silent (%.1f dB)", db)
        }

        let vCodec = vStream.codec_name ?? "?"
        let aCodec = aStream.codec_name ?? "?"
        let summary = String(format: "V:%@ %dx%d %.1fs + A:%@ %.1fs",
                             vCodec, vStream.width ?? 0, vStream.height ?? 0,
                             videoDuration, aCodec, audioDuration)
        return VerifyResult(ok: true, reason: "", summary: summary, warning: warning)
    }

    /// Select the best trustworthy duration for audio-coverage comparison.
    /// Stream metadata is most precise, then container metadata, then the
    /// caller's source duration. Invalid candidates are skipped, like walking
    /// a C++ initializer list and taking the first value that passes validation.
    static func resolveComparisonVideoDuration(
        streamDuration: String?,
        formatDuration: String?,
        expectedDuration: Double
    ) -> Double? {
        if let duration = positiveFiniteDuration(streamDuration) { return duration }
        if let duration = positiveFiniteDuration(formatDuration) { return duration }
        guard expectedDuration.isFinite, expectedDuration > 0 else { return nil }
        return expectedDuration
    }

    static func positiveFiniteDuration(_ value: String?) -> Double? {
        guard let value,
              let duration = Double(value),
              duration.isFinite,
              duration > 0 else { return nil }
        return duration
    }

    /// Return the same full-program audio-coverage failure used by both
    /// source-pair preflight and post-mux verification. Unknown source
    /// durations are not refused here: ffprobe may fill them in later, and
    /// the output verifier remains the final safety net.
    static func audioCoverageMismatchReason(
        videoDuration: Double,
        audioDuration: Double
    ) -> String? {
        guard videoDuration.isFinite, videoDuration > 0,
              audioDuration.isFinite, audioDuration > 0 else { return nil }
        let tolerance = max(videoDuration * 0.02, 2.0)
        guard audioDuration + tolerance < videoDuration else { return nil }
        return String(
            format: "audio duration mismatch: %.3fs covers %.1f%% of %.3fs video",
            audioDuration,
            audioDuration / videoDuration * 100,
            videoDuration
        )
    }

    // MARK: - Audio Level Detection

    /// Run ffmpeg volumedetect on the audio stream. Returns mean_volume in dB,
    /// or nil on failure. Uses the shared ProcessRunner so stderr is drained
    /// continuously — ffmpeg's `-v info` output for a long file can easily
    /// exceed the OS pipe buffer (~64KB on macOS) and deadlock if we only
    /// read after termination.
    static func detectAudioLevel(url: URL, ffmpegPath: String, timeoutSeconds: Double? = nil) async -> Double? {
        let args = ["-v", "info", "-i", url.path, "-map", "0:a:0",
                    "-af", "volumedetect", "-f", "null", "-"]
        let result = await ProcessRunner.runCapturingStderr(executable: ffmpegPath, arguments: args,
                                                            deadlineSeconds: timeoutSeconds)
        return parseMeanVolumeDB(from: result.stderr)
    }

    /// Pure helper — extracts the `mean_volume: -X.X dB` value from ffmpeg's
    /// volumedetect output. Pulled out so it's directly unit-testable.
    static func parseMeanVolumeDB(from ffmpegOutput: String) -> Double? {
        for line in ffmpegOutput.components(separatedBy: .newlines) {
            guard line.contains("mean_volume:") else { continue }
            let parts = line.components(separatedBy: "mean_volume:")
            guard parts.count > 1 else { continue }
            let dbStr = parts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " dB", with: "")
            if let v = Double(dbStr) { return v }
        }
        return nil
    }

    // MARK: - Decode Test

    /// Decode one video frame, then one audio frame. The failure reason
    /// (which stream, and why), or nil when both decode.
    static func decodeFailure(url: URL, ffmpegPath: String, timeoutSeconds: Double?) async -> String? {
        let video = await decodeTestFrame(url: url, streamType: "v", ffmpegPath: ffmpegPath, timeoutSeconds: timeoutSeconds)
        if !video.ok { return "video decode failed: \(video.reason)" }
        let audio = await decodeTestFrame(url: url, streamType: "a", ffmpegPath: ffmpegPath, timeoutSeconds: timeoutSeconds)
        if !audio.ok { return "audio decode failed: \(audio.reason)" }
        return nil
    }

    /// Attempt to decode one frame from the specified stream type ("v" or "a").
    /// `timeoutSeconds` bounds the subprocess; a run killed at its deadline
    /// fails as "timed out" (never as a decode error, never as a pass).
    static func decodeTestFrame(url: URL, streamType: String, ffmpegPath: String,
                                timeoutSeconds: Double? = nil) async -> (ok: Bool, reason: String) {
        let args: [String]
        if streamType == "v" {
            args = ["-v", "error", "-i", url.path, "-map", "0:v:0", "-vframes", "1", "-f", "null", "-"]
        } else {
            args = ["-v", "error", "-i", url.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]
        }

        // Use shared ProcessRunner: drains stderr continuously so a chatty
        // ffmpeg can't deadlock by filling the pipe buffer. Need the full
        // Result here (not runCapturingStderr) because we still want the
        // exit-code branch from the original implementation.
        let result = await ProcessRunner.runProcess(executable: ffmpegPath, arguments: args,
                                                    deadlineSeconds: timeoutSeconds)
        let errStr = result.stderr
        // Gate on a nonzero exit FIRST (ProcessRunner.Result's race note).
        if result.exitCode != 0, result.timedOut {
            return (false, "timed out after \(Int(timeoutSeconds ?? 0))s")
        }
        if result.exitCode != 0 {
            return (false, "exit \(result.exitCode): \(String(errStr.prefix(200)))")
        }
        if !errStr.isEmpty {
            return (false, "decode errors: \(String(errStr.prefix(200)))")
        }
        return (true, "")
    }

    // MARK: - FFProbe

    /// `timeoutSeconds` (optional) is a hard deadline on the ffprobe
    /// subprocess itself (SIGTERM → SIGKILL → abandon, see ProcessRunner).
    /// The scan path passes its per-file probe timeout here so an ffprobe
    /// wedged on dead-volume I/O can't outlive the timeout that's supposed
    /// to bound it.
    static func runFFProbe(url: URL, ffprobePath: String, timeoutSeconds: Double? = nil) async -> (output: FFProbeOutput?, stderr: String) {
        let probed = await runFFProbeDetailed(url: url, ffprobePath: ffprobePath, timeoutSeconds: timeoutSeconds)
        return (probed.output, probed.stderr)
    }

    /// `runFFProbe` plus whether THIS run was killed at its own deadline
    /// (gated on a nonzero exit first — ProcessRunner.Result's race note).
    /// Combine's verify uses it to say "timed out"; the scan path keeps
    /// `runFFProbe`, whose stderr becomes catalog notes unchanged.
    static func runFFProbeDetailed(url: URL, ffprobePath: String, timeoutSeconds: Double?) async
        -> (output: FFProbeOutput?, stderr: String, timedOut: Bool) {
        let args = ["-v", "warning", "-probesize", "50M", "-analyzeduration", "10M",
                    "-print_format", "json", "-show_format", "-show_streams", url.path]
        let result = await ProcessRunner.runProcess(executable: ffprobePath, arguments: args,
                                                    deadlineSeconds: timeoutSeconds)
        let timedOut = result.exitCode != 0 && result.timedOut
        guard let json = result.stdout, let data = json.data(using: .utf8) else {
            return (nil, result.stderr, timedOut)
        }
        let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data)
        return (output, result.stderr, timedOut)
    }

    // MARK: - Network Detection

    /// Detect network/remote mount paths
    static func isNetworkPath(_ path: String) -> Bool {
        let networkPrefixes = ["/Volumes/", "/private/var/automount/", "/net/"]
        guard networkPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return false }
        let fsType = withUnsafePointer(to: &stat.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        let networkFS = ["smbfs", "nfs", "afpfs", "webdav", "cifs"]
        return networkFS.contains(fsType)
    }

    // MARK: - Buffered Copy

    /// Large-buffer async file copy (4 MB chunks) for network reliability
    static func bufferedCopy(from src: URL, to dst: URL, bufferSize: Int = 4 * 1024 * 1024) async throws {
        try await Task.detached {
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: src.path))
            defer { try? reader.close() }

            FileManager.default.createFile(atPath: dst.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: URL(fileURLWithPath: dst.path)) else {
                throw NSError(domain: "VideoScan", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot write \(dst.lastPathComponent)"])
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
