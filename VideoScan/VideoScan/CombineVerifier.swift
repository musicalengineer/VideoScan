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

    /// Probe the combined output to confirm it has both video and audio streams
    /// and a reasonable duration relative to the source.
    static func verifyCombineOutput(
        url: URL,
        expectedDuration: Double,
        ffprobePath: String,
        ffmpegPath: String
    ) async -> VerifyResult {
        let (probe, stderr) = await runFFProbe(url: url, ffprobePath: ffprobePath)
        guard let probe else {
            return VerifyResult(ok: false, reason: "ffprobe failed: \(stderr)", summary: "")
        }

        let streams = probe.streams ?? []
        let vStream = streams.first(where: { $0.codec_type == "video" })
        let aStream = streams.first(where: { $0.codec_type == "audio" })

        guard let vStream else {
            return VerifyResult(ok: false, reason: "no video stream in output", summary: "")
        }
        guard aStream != nil else {
            return VerifyResult(ok: false, reason: "no audio stream in output", summary: "")
        }

        if (vStream.width ?? 0) == 0 || (vStream.height ?? 0) == 0 {
            return VerifyResult(ok: false, reason: "video stream has no dimensions (\(vStream.width ?? 0)x\(vStream.height ?? 0))", summary: "")
        }

        let outDuration = Double(probe.format?.duration ?? "0") ?? 0
        let tolerance = max(expectedDuration * 0.1, 2.0)
        if expectedDuration > 0 && outDuration > 0 && abs(outDuration - expectedDuration) > tolerance {
            return VerifyResult(
                ok: false,
                reason: String(format: "duration mismatch: expected %.1fs, got %.1fs", expectedDuration, outDuration),
                summary: ""
            )
        }

        let vDecode = await decodeTestFrame(url: url, streamType: "v", ffmpegPath: ffmpegPath)
        if !vDecode.ok {
            return VerifyResult(ok: false, reason: "video decode failed: \(vDecode.reason)", summary: "")
        }
        let aDecode = await decodeTestFrame(url: url, streamType: "a", ffmpegPath: ffmpegPath)
        if !aDecode.ok {
            return VerifyResult(ok: false, reason: "audio decode failed: \(aDecode.reason)", summary: "")
        }

        let meanDB = await detectAudioLevel(url: url, ffmpegPath: ffmpegPath)
        var warning: String?
        if let db = meanDB, db < -60 {
            warning = String(format: "Audio may be silent (%.1f dB)", db)
        }

        let vCodec = vStream.codec_name ?? "?"
        let aCodec = aStream?.codec_name ?? "?"
        let summary = String(format: "V:%@ %dx%d + A:%@, %.1fs",
                             vCodec, vStream.width ?? 0, vStream.height ?? 0, aCodec, outDuration)
        return VerifyResult(ok: true, reason: "", summary: summary, warning: warning)
    }

    // MARK: - Audio Level Detection

    /// Run ffmpeg volumedetect on the audio stream. Returns mean_volume in dB, or nil on failure.
    static func detectAudioLevel(url: URL, ffmpegPath: String) async -> Double? {
        let args = ["-v", "info", "-i", url.path, "-map", "0:a:0",
                    "-af", "volumedetect", "-f", "null", "-"]
        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = args
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice

            proc.terminationHandler = { _ in
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                var meanDB: Double?
                for line in text.components(separatedBy: .newlines) {
                    if line.contains("mean_volume:") {
                        let parts = line.components(separatedBy: "mean_volume:")
                        if parts.count > 1 {
                            let dbStr = parts[1].trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: " dB", with: "")
                            meanDB = Double(dbStr)
                        }
                    }
                }
                continuation.resume(returning: meanDB)
            }
            do { try proc.run() } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Decode Test

    /// Attempt to decode one frame from the specified stream type ("v" or "a").
    static func decodeTestFrame(url: URL, streamType: String, ffmpegPath: String) async -> (ok: Bool, reason: String) {
        let args: [String]
        if streamType == "v" {
            args = ["-v", "error", "-i", url.path, "-map", "0:v:0", "-vframes", "1", "-f", "null", "-"]
        } else {
            args = ["-v", "error", "-i", url.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]
        }

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = args
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice

            proc.terminationHandler = { p in
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 {
                    continuation.resume(returning: (false, "exit \(p.terminationStatus): \(String(errStr.prefix(200)))"))
                } else if !errStr.isEmpty {
                    continuation.resume(returning: (false, "decode errors: \(String(errStr.prefix(200)))"))
                } else {
                    continuation.resume(returning: (true, ""))
                }
            }
            do { try proc.run() } catch {
                continuation.resume(returning: (false, "launch failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - FFProbe

    static func runFFProbe(url: URL, ffprobePath: String) async -> (output: FFProbeOutput?, stderr: String) {
        let args = ["-v", "warning", "-probesize", "50M", "-analyzeduration", "10M",
                    "-print_format", "json", "-show_format", "-show_streams", url.path]
        let result = await ProcessRunner.runCapturingStderr(executable: ffprobePath, arguments: args)
        guard let json = result.stdout, let data = json.data(using: .utf8) else {
            return (nil, result.stderr)
        }
        let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data)
        return (output, result.stderr)
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
                let chunk = reader.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
            }
        }.value
    }
}
