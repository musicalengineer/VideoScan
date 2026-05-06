import Foundation

/// Shared scan helpers used by the live scanner and tests.
///
/// Directory walking, cache checks, prefetch, and hashing now live in
/// `VideoScanModel`, `FilesystemWalker`, and `FileHasher`. Keeping only the
/// shared ffprobe decoding/fallback behavior here avoids maintaining two scan
/// pipelines that can drift.
enum ScanEngine {

    // MARK: - Configuration

    static var ffprobePath: String { ToolLocator.ffprobePath }

    // MARK: - ffprobe Execution

    /// Run ffprobe and parse JSON output into `FFProbeOutput`.
    /// Returns (output, stderrDetail) — stderr is non-empty when ffprobe reports warnings/errors.
    static func runFFProbe(url: URL) async -> (output: FFProbeOutput?, stderr: String) {
        let args = ["-v", "warning", "-probesize", "50M", "-analyzeduration", "10M",
                    "-print_format", "json", "-show_format", "-show_streams", url.path]
        let result = await ProcessRunner.runCapturingStderr(executable: ffprobePath, arguments: args)
        guard let json = result.stdout, let data = json.data(using: .utf8) else {
            return (nil, result.stderr)
        }
        let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data)
        return (output, result.stderr)
    }

    /// Translate raw ffprobe stderr into a human-readable label + detail.
    /// Used to classify failed probes (damaged file, truncated, access denied, timeout…)
    /// for display in the catalog's "Is Playable" and "Notes" columns.
    /// Pure — no I/O, no globals. Safe to call from any actor.
    static func humanReadableDiagnosis(stderr: String) -> (label: String, detail: String) {
        let lower = stderr.lowercased()

        if lower.contains("moov atom not found") {
            return ("Damaged file",
                    "File is corrupt or incomplete — missing media index (moov atom not found)")
        }
        if lower.contains("invalid data found") {
            return ("Damaged file",
                    "File contains invalid or unreadable data (invalid data found when processing input)")
        }
        if lower.contains("end of file") || lower.contains("truncated") {
            return ("Truncated file",
                    "File appears to be cut short or incomplete (\(stderr))")
        }
        if lower.contains("permission denied") {
            return ("Access denied",
                    "Cannot read file — permission denied")
        }
        if lower.contains("operation timed out") {
            return ("Network timeout",
                    "File read timed out — network volume may be slow or unreachable")
        }
        if lower.contains("no such file") {
            return ("File not found",
                    "File was discovered during scan but is no longer accessible")
        }
        if stderr.isEmpty {
            return ("Unreadable file",
                    "File could not be analyzed — no additional details available")
        }
        // Fallback: use the raw stderr but prefix with a human label
        return ("Unreadable file",
                "File could not be analyzed — \(stderr)")
    }

    /// Extract metadata fields from ffprobe output into a `VideoRecord`.
    static func extractMetadata(probe: FFProbeOutput, into rec: VideoRecord) {
        let fmt     = probe.format
        let streams = probe.streams ?? []
        let fmtTags = fmt?.tags ?? [:]

        rec.container = fmt?.format_long_name ?? fmt?.format_name ?? ""
        if let d = Double(fmt?.duration ?? "") {
            rec.durationSeconds = d
            rec.duration = Formatting.duration(d)
        }
        if let br = fmt?.bit_rate, let bri = Int(br) {
            rec.totalBitrate = "\(bri / 1000) kbps"
        }

        rec.timecode = fmtTags["timecode"] ?? fmtTags["Timecode"] ?? ""
        rec.tapeName = fmtTags["tape_name"] ?? fmtTags["reel_name"]
                       ?? fmtTags["com.apple.quicktime.reelname"] ?? ""

        var hasVideo = false
        var hasAudio = false

        for s in streams {
            let stags = s.tags ?? [:]
            if rec.timecode.isEmpty { rec.timecode = stags["timecode"] ?? "" }

            if s.codec_type == "video" && !hasVideo {
                hasVideo       = true
                rec.videoCodec = s.codec_name ?? ""
                let w = s.width ?? 0; let h = s.height ?? 0
                if w > 0 && h > 0 { rec.resolution = "\(w)x\(h)" }
                rec.frameRate  = Formatting.fraction(s.r_frame_rate ?? s.avg_frame_rate ?? "")
                if let vbr = s.bit_rate, let vbri = Int(vbr) {
                    rec.videoBitrate = "\(vbri / 1000) kbps"
                }
                rec.colorSpace = s.color_space ?? ""
                rec.bitDepth   = s.bits_per_raw_sample ?? ""
                rec.scanType   = s.field_order ?? ""
            }

            if s.codec_type == "audio" && !hasAudio {
                hasAudio          = true
                rec.audioCodec    = s.codec_name ?? ""
                rec.audioChannels = s.channels.map { String($0) } ?? ""
                if let sr = s.sample_rate { rec.audioSampleRate = "\(sr) Hz" }
            }
        }

        if hasVideo && hasAudio { rec.streamTypeRaw = StreamType.videoAndAudio.rawValue } else if hasVideo { rec.streamTypeRaw = StreamType.videoOnly.rawValue } else if hasAudio { rec.streamTypeRaw = StreamType.audioOnly.rawValue } else { rec.streamTypeRaw = StreamType.noStreams.rawValue }

        rec.isPlayable = (rec.streamTypeRaw == StreamType.noStreams.rawValue)
            ? "No streams" : "Yes"
    }

    // MARK: - MXF Header Fallback

    /// Apply metadata extracted from MXF header when ffprobe fails.
    static func applyMxfMetadata(_ mxf: MxfHeaderParser.MxfMetadata, into rec: VideoRecord) {
        if mxf.width > 0 && mxf.height > 0 {
            rec.resolution = "\(mxf.width)x\(mxf.height)"
        }
        rec.videoCodec = mxf.codecLabel
        rec.frameRate = mxf.frameRate

        if mxf.durationSeconds > 0 {
            rec.durationSeconds = mxf.durationSeconds
            rec.duration = Formatting.duration(mxf.durationSeconds)
        }

        if mxf.hasVideo && mxf.hasAudio {
            rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        } else if mxf.hasVideo {
            rec.streamTypeRaw = StreamType.videoOnly.rawValue
        } else if mxf.hasAudio {
            rec.streamTypeRaw = StreamType.audioOnly.rawValue
        } else {
            rec.streamTypeRaw = StreamType.noStreams.rawValue
        }

        if mxf.audioChannels > 0 {
            rec.audioChannels = "\(mxf.audioChannels)"
        }
        if mxf.audioSampleRate > 0 {
            rec.audioSampleRate = "\(mxf.audioSampleRate) Hz"
        }
        if mxf.audioBitDepth > 0 {
            rec.audioCodec = "PCM \(mxf.audioBitDepth)-bit"
        }

        // Pixel layout info (e.g., "RGBF 10+10+10+2")
        if !mxf.pixelLayout.isEmpty {
            rec.bitDepth = mxf.pixelLayout
        }

        rec.isPlayable = "Codec unsupported"
        rec.container = "MXF (\(mxf.descriptorType))"
    }

    /// Apply ffprobe output to a record. On ffprobe failure, try MXF header
    /// fallback or produce a human-readable diagnosis. Mutates `rec` in place.
    /// Used by `VideoScanModel.probeFile` — richer error messages than the
    /// inline branch inside `ScanEngine.probeFile`.
    static func applyProbeOrFallback(
        rec: VideoRecord,
        url: URL,
        path: String,
        probe: FFProbeOutput?,
        stderrTrimmed: String
    ) {
        if let probe, probe.format != nil || !(probe.streams ?? []).isEmpty {
            autoreleasepool {
                extractMetadata(probe: probe, into: rec)
            }
            if !stderrTrimmed.isEmpty {
                rec.notes = stderrTrimmed
            }
            return
        }
        if url.pathExtension.lowercased() == "mxf" {
            if let mxf = MxfHeaderParser.parse(fileAt: path) {
                applyMxfMetadata(mxf, into: rec)
                let reason = stderrTrimmed.isEmpty ? "ffprobe could not decode" : stderrTrimmed
                rec.notes = "MXF header parsed (ffprobe failed: \(reason))"
            } else {
                rec.isPlayable    = "Damaged MXF file"
                rec.notes         = stderrTrimmed.isEmpty
                    ? "Neither ffprobe nor MXF header parser could read this file"
                    : "Damaged MXF — both ffprobe and header parser failed (\(stderrTrimmed))"
                rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }
            return
        }
        let diagnosis = humanReadableDiagnosis(stderr: stderrTrimmed)
        rec.isPlayable    = diagnosis.label
        rec.notes         = diagnosis.detail
        rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
    }
}
