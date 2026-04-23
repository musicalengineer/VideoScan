import Foundation
import CryptoKit
import Darwin

/// Handles directory walking, ffprobe execution, metadata extraction, and file prefetching.
/// Designed to be called from `VideoScanModel` — reports progress via callbacks.
enum ScanEngine {

    // MARK: - Configuration

    static let ffprobePath = "/opt/homebrew/bin/ffprobe"

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts", "ts", "mpg", "mpeg",
        "m2v", "vob", "wmv", "asf", "webm", "ogv", "ogg", "rm", "rmvb", "divx", "flv",
        "f4v", "3gp", "3g2", "dv", "dif", "braw", "r3d", "vro", "mod", "tod"
    ]

    static let skipDirs: Set<String> = [
        ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
        ".documentrevisions-v100", ".vol", "automount"
    ]

    /// Bytes to prefetch from network files to RAM disk for ffprobe.
    static let prefetchBytes = 50 * 1024 * 1024  // 50 MB — covers high-bitrate DNxHD/ProRes headers

    /// Max concurrent ffprobe processes per volume.
    static let probesPerVolume = 8

    // MARK: - Directory Walking

    /// Walk a single directory tree and return all video file URLs.
    static func walkDirectory(root: String, log: @escaping @Sendable (String) -> Void) async -> [URL] {
        var videoFiles: [URL] = []
        let fm = FileManager.default
        var dirStack: [URL] = [URL(fileURLWithPath: root)]

        while !dirStack.isEmpty {
            if Task.isCancelled { break }
            let currentDir = dirStack.removeLast()
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: currentDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                log("  WARN: \(currentDir.lastPathComponent) — \(error.localizedDescription)")
                continue
            }

            for url in contents {
                if Task.isCancelled { break }
                guard let rv = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey]
                ) else { continue }

                if rv.isDirectory == true {
                    if !skipDirs.contains(url.lastPathComponent.lowercased()) {
                        dirStack.append(url)
                    }
                } else if rv.isRegularFile == true && rv.isReadable == true {
                    if videoExtensions.contains(url.pathExtension.lowercased()) {
                        videoFiles.append(url)
                    }
                }
            }
        }
        return videoFiles
    }

    // MARK: - File Probing

    /// Probe a single file and return a populated `VideoRecord`.
    /// Checks the metadata cache first; stores results on cache miss.
    static func probeFile(
        url: URL,
        cache: MetadataCache,
        prefetchToRAM: Bool = false,
        ramPath: String? = nil
    ) async -> VideoRecord {
        let fm = FileManager.default
        let path = url.path

        let attrs = try? fm.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        // Cache hit — skip ffprobe entirely. We still refresh scanContext so
        // provenance reflects the current scan (host / mount type / volume UUID
        // / remote server), letting old records backfill on rescan without
        // paying the ffprobe cost.
        if let cached = cache.lookup(path: path, fileSize: fileSize, modDate: modDate) {
            cached.scanContext = ScanContext.capture(for: url)
            return cached
        }

        let rec = VideoRecord()
        rec.filename  = url.lastPathComponent
        rec.ext       = url.pathExtension.uppercased()
        rec.fullPath  = path
        rec.directory = url.deletingLastPathComponent().path

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        rec.sizeBytes       = fileSize
        rec.size            = Formatting.humanSize(fileSize)
        rec.dateModifiedRaw = attrs?[.modificationDate] as? Date
        rec.dateCreatedRaw  = attrs?[.creationDate] as? Date
        rec.dateModified    = rec.dateModifiedRaw.map { df.string(from: $0) } ?? ""
        rec.dateCreated     = rec.dateCreatedRaw.map { df.string(from: $0) } ?? ""

        rec.partialMD5 = partialMD5(path: path)

        // Prefetch file header to RAM disk for fast ffprobe
        var probeURL = url
        var tempFile: URL?

        if prefetchToRAM, let rp = ramPath {
            let tmpName = "\(UUID().uuidString)_\(url.lastPathComponent)"
            let tmpURL = URL(fileURLWithPath: rp).appendingPathComponent(tmpName)
            if prefetchHeader(from: url, to: tmpURL, bytes: prefetchBytes) {
                probeURL = tmpURL
                tempFile = tmpURL
            }
        }

        let probeResult = await runFFProbe(url: probeURL)
        let stderrTrimmed = probeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let probe = probeResult.output,
           probe.format != nil || !(probe.streams ?? []).isEmpty {
            // Genuine success — ffprobe found format/stream data
            extractMetadata(probe: probe, into: rec)
            if !stderrTrimmed.isEmpty {
                rec.notes = stderrTrimmed
            }
        } else if url.pathExtension.lowercased() == "mxf" {
            // ffprobe failed on MXF — try native header parser
            if let mxf = MxfHeaderParser.parse(fileAt: path) {
                applyMxfMetadata(mxf, into: rec)
                let reason = stderrTrimmed.isEmpty ? "ffprobe could not decode" : stderrTrimmed
                rec.notes = "MXF header parsed (ffprobe failed: \(reason))"
            } else {
                rec.isPlayable    = "ffprobe failed"
                rec.notes         = stderrTrimmed.isEmpty ? "MXF header parse also failed" : "MXF fallback failed; \(stderrTrimmed)"
                rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }
        } else {
            // Either no stdout at all, or ffprobe returned empty JSON (no format, no streams)
            rec.isPlayable    = "ffprobe failed"
            rec.notes         = stderrTrimmed.isEmpty ? "ffprobe could not read file" : stderrTrimmed
            rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        }

        if let tmp = tempFile {
            try? fm.removeItem(at: tmp)
        }

        // Cache the result — but don't cache ffprobe failures, so future runs
        // with improved fallback parsers can retry them.
        if rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
            cache.store(record: rec, fileSize: fileSize, modDate: modDate)
        }
        // Stamp scan-time provenance. Done after caching so the SQLite cache
        // stays schema-stable — scanContext lives in catalog.json only and is
        // recaptured fresh on every scan (cheap: two syscalls).
        rec.scanContext = ScanContext.capture(for: url)
        return rec
    }

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

        if hasVideo && hasAudio { rec.streamTypeRaw = StreamType.videoAndAudio.rawValue }
        else if hasVideo        { rec.streamTypeRaw = StreamType.videoOnly.rawValue }
        else if hasAudio        { rec.streamTypeRaw = StreamType.audioOnly.rawValue }
        else                    { rec.streamTypeRaw = StreamType.noStreams.rawValue }

        rec.isPlayable = (rec.streamTypeRaw == StreamType.noStreams.rawValue)
            ? "No streams" : "Yes"
    }

    // MARK: - File Prefetch (mmap)

    /// Copy the first N bytes of a file to a destination via mmap.
    /// Used to prefetch network file headers to RAM disk for fast ffprobe access.
    static func prefetchHeader(from src: URL, to dst: URL, bytes: Int) -> Bool {
        // Use read() instead of mmap() — mmap on network files can SIGBUS
        // if the remote volume becomes unreachable mid-read.
        let fd = open(src.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var sb = Darwin.stat()
        guard fstat(fd, &sb) == 0 else { return false }
        let readLen = min(bytes, Int(sb.st_size))
        guard readLen > 0 else { return false }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: readLen, alignment: 16)
        defer { buf.deallocate() }

        var totalRead = 0
        while totalRead < readLen {
            let n = Darwin.read(fd, buf.advanced(by: totalRead), readLen - totalRead)
            if n <= 0 { break }
            totalRead += n
        }
        guard totalRead > 0 else { return false }

        let data = Data(bytesNoCopy: buf, count: totalRead, deallocator: .none)
        do {
            try data.write(to: dst)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Partial MD5

    /// Compute a partial MD5 hash (first + last 64KB) for duplicate detection.
    static func partialMD5(path: String, chunkSize: Int = 65536) -> String {
        // Use read() instead of mmap() — mmap on network files can SIGBUS.
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = Darwin.stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var md5 = Insecure.MD5()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buf.deallocate() }

        let headLen = min(chunkSize, fileSize)
        let headRead = Darwin.read(fd, buf, headLen)
        guard headRead > 0 else { return "" }
        md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: headRead))

        if fileSize > chunkSize * 2 {
            let tailOffset = off_t(fileSize - chunkSize)
            guard lseek(fd, tailOffset, SEEK_SET) == tailOffset else { return "" }
            let tailRead = Darwin.read(fd, buf, chunkSize)
            guard tailRead > 0 else { return "" }
            md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: tailRead))
        }

        return md5.finalize().map { String(format: "%02x", $0) }.joined()
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
}
