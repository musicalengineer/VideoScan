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
    ///
    /// Thin wrapper over `extractMetadata(probe:) -> ProbeResult`: it computes
    /// the Sendable value and stamps it onto `rec` via the single authoritative
    /// copy point (`VideoRecord.apply`). The golden test drives THIS entry
    /// point, so its observable behavior is unchanged. `apply` is unconditional
    /// and `ProbeResult`'s defaults match `VideoRecord`'s, so a field the probe
    /// didn't populate still lands as the same fresh-construction default.
    static func extractMetadata(probe: FFProbeOutput, into rec: VideoRecord) {
        rec.apply(extractMetadata(probe: probe))
    }

    /// Pure metadata extraction: ffprobe output → Sendable `ProbeResult`.
    /// No reference-type mutation, so it is safe to run off the main actor and
    /// hand the result across the actor boundary. Logic is verbatim from the
    /// old in-place version — the only change is that each field lands in a
    /// local `ProbeResult` instead of being written straight onto a VideoRecord.
    static func extractMetadata(probe: FFProbeOutput) -> ProbeResult {
        let fmt     = probe.format
        let streams = probe.streams ?? []
        let fmtTags = fmt?.tags ?? [:]

        var r = ProbeResult()

        r.container = fmt?.format_long_name ?? fmt?.format_name ?? ""
        if let d = Double(fmt?.duration ?? "") {
            r.durationSeconds = d
            r.duration = Formatting.duration(d)
        }
        if let br = fmt?.bit_rate, let bri = Int(br) {
            r.totalBitrate = "\(bri / 1000) kbps"
        }

        r.timecode = fmtTags["timecode"] ?? fmtTags["Timecode"] ?? ""
        r.tapeName = fmtTags["tape_name"] ?? fmtTags["reel_name"]
                     ?? fmtTags["com.apple.quicktime.reelname"] ?? ""
        // MXF MaterialPackage UMID. ffprobe emits this as a "0x..."-prefixed
        // 32-byte hex string in the format-level tags for MXF files. We
        // store it verbatim — the substitute-file resolver matches by
        // exact string, no normalization needed.
        r.materialPackageUMID = fmtTags["material_package_umid"] ?? ""

        // Embedded creation date + origin (2026-08-16): the container's own
        // creation stamp (survives copies, unlike filesystem dates) and the
        // device / program that wrote the file. Both come from tags already
        // in this JSON — no second ffprobe run. Sanity-filtered here so a
        // stored value is always believable (EmbeddedDateSanity).
        let allStreamTags = streams.map { $0.tags ?? [:] }
        if let cap = EmbeddedCreationDate.extract(formatTags: fmtTags, streamTags: allStreamTags) {
            r.embeddedCreationDate   = cap.date
            r.embeddedCreationSource = cap.source
        }
        let origin = EmbeddedOriginTags.extract(formatTags: fmtTags, streamTags: allStreamTags)
        r.originMake    = origin.make
        r.originModel   = origin.model
        r.originEncoder = origin.encoder

        var hasVideo = false
        var hasAudio = false

        for s in streams {
            let stags = s.tags ?? [:]
            if r.timecode.isEmpty { r.timecode = stags["timecode"] ?? "" }

            // A stream counts as real video only if it is NOT embedded cover
            // art. ffprobe reports iTunes album art (mjpeg/png still) as a
            // "video" stream with disposition.attached_pic == 1; counting it
            // would mis-classify a pure-audio file (e.g. purchased MP3/M4A) as
            // video and pollute the video catalog. See fix/attached-pic-classify.
            if s.codec_type == "video" && s.disposition?.attached_pic != 1 && !hasVideo {
                hasVideo     = true
                r.videoCodec = s.codec_name ?? ""
                let w = s.width ?? 0; let h = s.height ?? 0
                if w > 0 && h > 0 { r.resolution = "\(w)x\(h)" }
                r.frameRate  = Formatting.fraction(s.r_frame_rate ?? s.avg_frame_rate ?? "")
                if let vbr = s.bit_rate, let vbri = Int(vbr) {
                    r.videoBitrate = "\(vbri / 1000) kbps"
                }
                r.colorSpace = s.color_space ?? ""
                r.bitDepth   = s.bits_per_raw_sample ?? ""
                r.scanType   = s.field_order ?? ""
            }

            if s.codec_type == "audio" && !hasAudio {
                hasAudio        = true
                r.audioCodec    = s.codec_name ?? ""
                r.audioChannels = s.channels.map { String($0) } ?? ""
                if let sr = s.sample_rate { r.audioSampleRate = "\(sr) Hz" }
            }
        }

        if hasVideo && hasAudio { r.streamTypeRaw = StreamType.videoAndAudio.rawValue } else if hasVideo { r.streamTypeRaw = StreamType.videoOnly.rawValue } else if hasAudio { r.streamTypeRaw = StreamType.audioOnly.rawValue } else { r.streamTypeRaw = StreamType.noStreams.rawValue }

        r.isPlayable = (r.streamTypeRaw == StreamType.noStreams.rawValue)
            ? "No streams" : "Yes"

        return r
    }

    // MARK: - MXF Header Fallback

    /// Apply metadata extracted from MXF header when ffprobe fails. Writes into
    /// the Sendable `ProbeResult` carrier — every field it touches is one of the
    /// 19 metadata fields, so it never needs a VideoRecord. (`inout` here ≈ a
    /// C++ non-const reference parameter on a value struct.)
    static func applyMxfMetadata(_ mxf: MxfHeaderParser.MxfMetadata, into r: inout ProbeResult) {
        if mxf.width > 0 && mxf.height > 0 {
            r.resolution = "\(mxf.width)x\(mxf.height)"
        }
        r.videoCodec = mxf.codecLabel
        r.frameRate = mxf.frameRate

        if mxf.durationSeconds > 0 {
            r.durationSeconds = mxf.durationSeconds
            r.duration = Formatting.duration(mxf.durationSeconds)
        }

        if mxf.hasVideo && mxf.hasAudio {
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        } else if mxf.hasVideo {
            r.streamTypeRaw = StreamType.videoOnly.rawValue
        } else if mxf.hasAudio {
            r.streamTypeRaw = StreamType.audioOnly.rawValue
        } else {
            r.streamTypeRaw = StreamType.noStreams.rawValue
        }

        if mxf.audioChannels > 0 {
            r.audioChannels = "\(mxf.audioChannels)"
        }
        if mxf.audioSampleRate > 0 {
            r.audioSampleRate = "\(mxf.audioSampleRate) Hz"
        }
        if mxf.audioBitDepth > 0 {
            r.audioCodec = "PCM \(mxf.audioBitDepth)-bit"
        }

        // Pixel layout info (e.g., "RGBF 10+10+10+2")
        if !mxf.pixelLayout.isEmpty {
            r.bitDepth = mxf.pixelLayout
        }

        r.isPlayable = "Codec unsupported"
        r.container = "MXF (\(mxf.descriptorType))"
    }

    /// Apply ffprobe output to a probe outcome. On ffprobe failure, try MXF
    /// header fallback or produce a human-readable diagnosis. Mutates the
    /// Sendable `ProbeOutcome` in place (no VideoRecord), so it runs off-actor.
    /// Used by `VideoScanModel.probeFileOutcome` — richer error messages than
    /// the inline branch inside the engine.
    static func applyProbeOrFallback(
        outcome o: inout ProbeOutcome,
        url: URL,
        path: String,
        probe: FFProbeOutput?,
        stderrTrimmed: String
    ) {
        if let probe, probe.format != nil || !(probe.streams ?? []).isEmpty {
            autoreleasepool {
                // Replaces the (default) metadata block wholesale — equivalent
                // to the old unconditional VideoRecord.apply(extractMetadata()).
                o.probe = extractMetadata(probe: probe)
            }
            if !stderrTrimmed.isEmpty {
                o.notes = stderrTrimmed
            }
            return
        }
        if url.pathExtension.lowercased() == "mxf" {
            if let mxf = MxfHeaderParser.parse(fileAt: path) {
                applyMxfMetadata(mxf, into: &o.probe)
                let reason = stderrTrimmed.isEmpty ? "ffprobe could not decode" : stderrTrimmed
                o.notes = "MXF header parsed (ffprobe failed: \(reason))"
            } else {
                o.probe.isPlayable    = "Damaged MXF file"
                o.notes               = stderrTrimmed.isEmpty
                    ? "Neither ffprobe nor MXF header parser could read this file"
                    : "Damaged MXF — both ffprobe and header parser failed (\(stderrTrimmed))"
                o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }
            return
        }
        let diagnosis = humanReadableDiagnosis(stderr: stderrTrimmed)
        o.probe.isPlayable    = diagnosis.label
        o.notes               = diagnosis.detail
        o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
    }
}
