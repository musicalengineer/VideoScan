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

        // Cache hit — skip ffprobe entirely
        if let cached = cache.lookup(path: path, fileSize: fileSize, modDate: modDate) {
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

        if let probe = await runFFProbe(url: probeURL) {
            extractMetadata(probe: probe, into: rec)
        } else {
            rec.isPlayable    = "ffprobe failed"
            rec.notes         = "ffprobe could not read file"
            rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        }

        if let tmp = tempFile {
            try? fm.removeItem(at: tmp)
        }

        // Cache the result for next time
        cache.store(record: rec, fileSize: fileSize, modDate: modDate)
        return rec
    }

    // MARK: - ffprobe Execution

    /// Run ffprobe and parse JSON output into `FFProbeOutput`.
    static func runFFProbe(url: URL) async -> FFProbeOutput? {
        let args = ["-v", "quiet", "-probesize", "50M", "-analyzeduration", "10M",
                    "-print_format", "json", "-show_format", "-show_streams", url.path]
        guard let json = await ProcessRunner.run(executable: ffprobePath, arguments: args),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(FFProbeOutput.self, from: data)
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
        let fd = open(src.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var sb = Darwin.stat()
        guard fstat(fd, &sb) == 0 else { return false }
        let readLen = min(bytes, Int(sb.st_size))

        guard let ptr = mmap(nil, readLen, PROT_READ, MAP_PRIVATE, fd, 0),
              ptr != MAP_FAILED else { return false }
        defer { munmap(ptr, readLen) }

        let data = Data(bytesNoCopy: ptr, count: readLen, deallocator: .none)
        do {
            try data.write(to: dst)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Partial MD5 (mmap-based)

    /// Compute a partial MD5 hash (first + last 64KB) for duplicate detection.
    static func partialMD5(path: String, chunkSize: Int = 65536) -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = Darwin.stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var md5 = Insecure.MD5()

        let headLen = min(chunkSize, fileSize)
        if let ptr = mmap(nil, headLen, PROT_READ, MAP_PRIVATE, fd, 0) {
            if ptr != MAP_FAILED {
                md5.update(bufferPointer: UnsafeRawBufferPointer(start: ptr, count: headLen))
                munmap(ptr, headLen)
            }
        }

        if fileSize > chunkSize * 2 {
            let tailOffset = fileSize - chunkSize
            let pageSize = Int(getpagesize())
            let alignedOffset = (tailOffset / pageSize) * pageSize
            let mapLen = fileSize - alignedOffset
            let offsetInMap = tailOffset - alignedOffset

            if let ptr = mmap(nil, mapLen, PROT_READ, MAP_PRIVATE, fd, off_t(alignedOffset)) {
                if ptr != MAP_FAILED {
                    md5.update(bufferPointer: UnsafeRawBufferPointer(
                        start: ptr.advanced(by: offsetInMap), count: chunkSize))
                    munmap(ptr, mapLen)
                }
            }
        }

        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
