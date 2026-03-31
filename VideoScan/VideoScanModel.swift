import Foundation
import CryptoKit
import SwiftUI
import Combine

// MARK: - Stream Type

enum StreamType: String {
    case videoAndAudio = "Video+Audio"
    case videoOnly     = "Video only"
    case audioOnly     = "Audio only"
    case noStreams      = "No A/V streams"
    case ffprobeFailed = "ffprobe failed"

    var needsCorrelation: Bool {
        self == .videoOnly || self == .audioOnly
    }
}

// MARK: - Video Record

class VideoRecord: Identifiable {
    let id = UUID()

    var filename: String = ""
    var ext: String = ""
    var streamTypeRaw: String = ""
    var size: String = ""
    var sizeBytes: Int64 = 0
    var duration: String = ""
    var dateCreated: String = ""
    var dateModified: String = ""
    var container: String = ""
    var videoCodec: String = ""
    var resolution: String = ""
    var frameRate: String = ""
    var videoBitrate: String = ""
    var totalBitrate: String = ""
    var colorSpace: String = ""
    var bitDepth: String = ""
    var scanType: String = ""
    var audioCodec: String = ""
    var audioChannels: String = ""
    var audioSampleRate: String = ""
    var timecode: String = ""
    var tapeName: String = ""
    var isPlayable: String = ""
    var partialMD5: String = ""
    var fullPath: String = ""
    var directory: String = ""
    var notes: String = ""

    var pairedWith: VideoRecord? = nil
    var pairGroupID: UUID? = nil

    var streamType: StreamType {
        StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed
    }

    var rowColor: Color {
        if let gid = pairGroupID {
            let colors: [Color] = [
                Color.green.opacity(0.18),
                Color.blue.opacity(0.18),
                Color.purple.opacity(0.18),
                Color.orange.opacity(0.18),
                Color.teal.opacity(0.18),
            ]
            let idx = abs(gid.hashValue) % colors.count
            return colors[idx]
        }
        switch streamType {
        case .videoOnly:     return Color.yellow.opacity(0.25)
        case .audioOnly:     return Color.yellow.opacity(0.25)
        case .noStreams:     return Color.gray.opacity(0.15)
        case .ffprobeFailed: return Color.red.opacity(0.15)
        default:             return Color.clear
        }
    }
}

// MARK: - ffprobe Codable

struct FFProbeOutput: Codable {
    let streams: [FFStream]?
    let format: FFFormat?
}

struct FFStream: Codable {
    let codec_type: String?
    let codec_name: String?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let bit_rate: String?
    let color_space: String?
    let bits_per_raw_sample: String?
    let field_order: String?
    let channels: Int?
    let sample_rate: String?
    let tags: [String: String]?
}

struct FFFormat: Codable {
    let format_name: String?
    let format_long_name: String?
    let duration: String?
    let size: String?
    let bit_rate: String?
    let tags: [String: String]?
}

// MARK: - Model

@MainActor
final class VideoScanModel: ObservableObject {
    @Published var records: [VideoRecord] = []
    @Published var consoleOutput: String = ""
    @Published var isScanning: Bool = false
    @Published var isCombining: Bool = false
    @Published var outputCSVPath: String = ""

    let ffprobePath = "/opt/homebrew/bin/ffprobe"
    let ffmpegPath  = "/opt/homebrew/bin/ffmpeg"

    let videoExtensions: Set<String> = [
        "mov","mp4","m4v","avi","mkv","mxf","mts","m2ts","ts","mpg","mpeg",
        "m2v","vob","wmv","asf","webm","ogv","ogg","rm","rmvb","divx","flv",
        "f4v","3gp","3g2","dv","dif","braw","r3d","vro","mod","tod"
    ]

    let skipDirs: Set<String> = [
        ".spotlight-v100",".fseventsd",".trashes",".temporaryitems",
        ".documentrevisions-v100",".vol","automount"
    ]

    private var scanTask: Task<Void, Never>?

    // MARK: - Logging

    func log(_ msg: String) {
        consoleOutput += msg + "\n"
    }

    // MARK: - Scan

    func startScan(root: String) {
        records = []
        consoleOutput = ""
        outputCSVPath = ""
        isScanning = true

        scanTask = Task {
            await runScan(root: root)
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        log("--- Scan stopped by user ---")
        isScanning = false
    }

    func runScan(root: String) async {
        log("Scanning: \(root)\n")

        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            log("ERROR: ffprobe not found at \(ffprobePath)\nInstall with: brew install ffmpeg")
            isScanning = false
            return
        }

        // Directory walk — mirrors Python os.walk
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

        log("Found \(videoFiles.count) video files. Probing with ffprobe...\n")

        if videoFiles.isEmpty {
            log("No video files found.")
            isScanning = false
            return
        }

        let total = videoFiles.count
        var allRecords: [VideoRecord] = []

        for (i, url) in videoFiles.enumerated() {
            if Task.isCancelled { break }
            log("  [\(i+1)/\(total)] \(url.lastPathComponent)")

            let rec = VideoRecord()
            rec.filename  = url.lastPathComponent
            rec.ext       = url.pathExtension.uppercased()
            rec.fullPath  = url.path
            rec.directory = url.deletingLastPathComponent().path

            if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                rec.sizeBytes    = (attrs[.size] as? Int64) ?? 0
                rec.size         = humanSize(rec.sizeBytes)
                rec.dateModified = (attrs[.modificationDate] as? Date).map { df.string(from: $0) } ?? ""
                rec.dateCreated  = (attrs[.creationDate]    as? Date).map { df.string(from: $0) } ?? ""
            }

            rec.partialMD5 = partialMD5(path: url.path)

            if let probe = await runFFProbe(url: url) {
                extractMetadata(probe: probe, into: rec)
            } else {
                rec.isPlayable    = "ffprobe failed"
                rec.notes         = "ffprobe could not read file"
                rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }

            allRecords.append(rec)
        }

        // Write CSV
        let csvPath = writeCSV(records: allRecords, root: root)
        records = allRecords
        outputCSVPath = csvPath ?? ""
        if let p = csvPath { log("CSV saved to:\n\(p)") }

        let va = allRecords.filter { $0.streamTypeRaw == StreamType.videoAndAudio.rawValue }.count
        let vo = allRecords.filter { $0.streamTypeRaw == StreamType.videoOnly.rawValue }.count
        let ao = allRecords.filter { $0.streamTypeRaw == StreamType.audioOnly.rawValue }.count
        let ff = allRecords.filter { $0.isPlayable.contains("ffprobe") }.count

        log("""

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Scan Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Total:          \(allRecords.count)
  Video+Audio:    \(va)
  Video only:     \(vo)
  Audio only:     \(ao)
  ffprobe failed: \(ff)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")
        isScanning = false
    }

    // MARK: - Correlate

    func correlate() {
        for r in records { r.pairedWith = nil; r.pairGroupID = nil }

        let needsPairing = records.filter { $0.streamType.needsCorrelation }
        var matched: Set<UUID> = []

        // Pass 1 — filename similarity
        var filenameGroups: [String: [VideoRecord]] = [:]
        for rec in needsPairing {
            let key = filenameCorrelationKey(rec.filename)
            filenameGroups[key, default: []].append(rec)
        }

        for (_, group) in filenameGroups {
            let videos = group.filter { $0.streamType == .videoOnly }
            let audios = group.filter { $0.streamType == .audioOnly }
            guard !videos.isEmpty && !audios.isEmpty else { continue }

            let pairCount = min(videos.count, audios.count)
            for i in 0..<pairCount {
                let v = videos[i]; let a = audios[i]
                let gid = UUID()
                v.pairedWith = a; v.pairGroupID = gid
                a.pairedWith = v; a.pairGroupID = gid
                matched.insert(v.id); matched.insert(a.id)
                log("  Paired (filename): \(v.filename)  ↔  \(a.filename)")
            }
        }

        // Pass 2 — timecode fallback
        let unmatched = needsPairing.filter { !matched.contains($0.id) }
        let tcVideos  = unmatched.filter { $0.streamType == .videoOnly && !$0.timecode.isEmpty }
        let tcAudios  = unmatched.filter { $0.streamType == .audioOnly && !$0.timecode.isEmpty }

        for v in tcVideos {
            if let a = tcAudios.first(where: {
                !matched.contains($0.id) &&
                $0.timecode == v.timecode &&
                $0.duration == v.duration
            }) {
                let gid = UUID()
                v.pairedWith = a; v.pairGroupID = gid
                a.pairedWith = v; a.pairGroupID = gid
                matched.insert(v.id); matched.insert(a.id)
                log("  Paired (timecode): \(v.filename)  ↔  \(a.filename)")
            }
        }

        let totalPairs     = matched.count / 2
        let stillUnmatched = needsPairing.filter { !matched.contains($0.id) }.count
        log("Correlation complete: \(totalPairs) pairs found, \(stillUnmatched) unmatched.")

        // Force table refresh
        let tmp = records
        records = []
        records = tmp
    }

    func filenameCorrelationKey(_ filename: String) -> String {
        var parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices {
            let p = parts[i]
            if p.count > 1,
               let first = p.first,
               (first == "V" || first == "A" || first == "v" || first == "a"),
               p.dropFirst().allSatisfy({ $0.isHexDigit || $0.isLetter }) {
                parts[i] = "_" + p.dropFirst()
                break
            }
        }
        return parts.joined(separator: ".")
    }

    // MARK: - Combine

    func combine(video: VideoRecord, audio: VideoRecord, outputURL: URL, container: String) {
        isCombining = true
        log("\nCombining:")
        log("  Video: \(video.filename)")
        log("  Audio: \(audio.filename)")
        log("  Output: \(outputURL.lastPathComponent)\n")

        Task {
            let args = [
                "-y",
                "-i", video.fullPath,
                "-i", audio.fullPath,
                "-map", "0:v",
                "-map", "1:a",
                "-c", "copy",
                outputURL.path
            ]
            await runFFMpegStreaming(arguments: args)
            log("\n✓ Done: \(outputURL.path)")
            isCombining = false
        }
    }

    func runFFMpegStreaming(arguments: [String]) async {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = arguments

            let pipe = Pipe()
            proc.standardError  = pipe
            proc.standardOutput = Pipe()

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                    DispatchQueue.main.async { self?.consoleOutput += text }
                }
            }

            proc.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                    DispatchQueue.main.async { self.consoleOutput += text }
                }
                continuation.resume()
            }

            do    { try proc.run() }
            catch { continuation.resume() }
        }
    }

    // MARK: - ffprobe

    func runFFProbe(url: URL) async -> FFProbeOutput? {
        let args = ["-v","quiet","-print_format","json","-show_format","-show_streams", url.path]
        guard let json = await runProcess(executable: ffprobePath, arguments: args),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FFProbeOutput.self, from: data)
    }

    func extractMetadata(probe: FFProbeOutput, into rec: VideoRecord) {
        let fmt     = probe.format
        let streams = probe.streams ?? []
        let fmtTags = fmt?.tags ?? [:]

        rec.container = fmt?.format_long_name ?? fmt?.format_name ?? ""
        if let d = Double(fmt?.duration ?? "") { rec.duration = formatDuration(d) }
        if let br = fmt?.bit_rate, let bri = Int(br) { rec.totalBitrate = "\(bri/1000) kbps" }

        rec.timecode = fmtTags["timecode"] ?? fmtTags["Timecode"] ?? ""
        rec.tapeName = fmtTags["tape_name"] ?? fmtTags["reel_name"] ??
                       fmtTags["com.apple.quicktime.reelname"] ?? ""

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
                rec.frameRate  = parseFraction(s.r_frame_rate ?? s.avg_frame_rate ?? "")
                if let vbr = s.bit_rate, let vbri = Int(vbr) { rec.videoBitrate = "\(vbri/1000) kbps" }
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

        rec.isPlayable = (rec.streamTypeRaw == StreamType.noStreams.rawValue) ? "No streams" : "Yes"
    }

    // MARK: - Process runner

    func runProcess(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL  = URL(fileURLWithPath: executable)
            proc.arguments      = arguments
            let pipe            = Pipe()
            proc.standardOutput = pipe
            proc.standardError  = Pipe()
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
            do    { try proc.run() }
            catch { continuation.resume(returning: nil) }
        }
    }

    // MARK: - Partial MD5

    func partialMD5(path: String, chunkSize: Int = 65536) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { fh.closeFile() }
        var md5 = Insecure.MD5()
        md5.update(data: fh.readData(ofLength: chunkSize))
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        if size > Int64(chunkSize * 2) {
            fh.seek(toFileOffset: UInt64(size) - UInt64(chunkSize))
            md5.update(data: fh.readData(ofLength: chunkSize))
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - CSV

    func writeCSV(records: [VideoRecord], root: String) -> String? {
        let headers = [
            "Filename","Extension","Stream Type","Size","Size (Bytes)","Duration",
            "Date Created","Date Modified","Container","Video Codec","Resolution",
            "Frame Rate","Video Bitrate","Total Bitrate","Color Space","Bit Depth",
            "Scan Type","Audio Codec","Audio Channels","Audio Sample Rate","Timecode",
            "Tape Name","Is Playable","Partial MD5","Full Path","Directory","Notes"
        ]
        var lines = [headers.joined(separator: ",")]
        for r in records {
            let row = [
                r.filename, r.ext, r.streamTypeRaw, r.size, String(r.sizeBytes),
                r.duration, r.dateCreated, r.dateModified, r.container,
                r.videoCodec, r.resolution, r.frameRate, r.videoBitrate,
                r.totalBitrate, r.colorSpace, r.bitDepth, r.scanType,
                r.audioCodec, r.audioChannels, r.audioSampleRate, r.timecode,
                r.tapeName, r.isPlayable, r.partialMD5, r.fullPath, r.directory, r.notes
            ].map { csvEscape($0) }.joined(separator: ",")
            lines.append(row)
        }

        let folderName = URL(fileURLWithPath: root).lastPathComponent
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let outURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("VideoScan_\(folderName)_\(df.string(from: Date())).csv")
        do {
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            return outURL.path
        } catch { return nil }
    }

    // MARK: - Helpers

    func formatDuration(_ secs: Double) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
    }

    func parseFraction(_ fr: String) -> String {
        let parts = fr.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return fr }
        var s = String(format: "%.3f", parts[0]/parts[1])
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    func humanSize(_ bytes: Int64) -> String {
        let units = ["B","KB","MB","GB","TB"]
        var val = Double(bytes)
        for unit in units {
            if abs(val) < 1024 { return String(format: "%.1f \(unit)", val) }
            val /= 1024
        }
        return String(format: "%.1f PB", val)
    }

    func csvEscape(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
