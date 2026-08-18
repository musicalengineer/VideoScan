import Foundation

/// Shared formatting utilities used across the catalog pipeline.
enum Formatting {

    /// Format seconds as HH:MM:SS.
    static func duration(_ secs: Double) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Parse a rational frame rate string (e.g. "30000/1001") into decimal.
    static func fraction(_ fr: String) -> String {
        let parts = fr.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return fr }
        var s = String(format: "%.3f", parts[0] / parts[1])
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Format byte count as human-readable size (KB, MB, GB, etc.).
    ///
    /// Routes through `MediaBytes` (Rick 2026-08-18): DECIMAL units,
    /// the same base Finder and `df -H` use. This helper used to be
    /// base-1024 with "GB" labels, so a freshly scanned record's Size
    /// column disagreed with Finder's Get Info by ~7%. Records scanned
    /// before this change keep their persisted base-1024 `size` string
    /// until rescanned; the catalog table now formats from `sizeBytes`
    /// so the column reads consistently regardless.
    static func humanSize(_ bytes: Int64) -> String {
        MediaBytes.display(bytes)
    }

    /// Human-readable size from megabytes (e.g., 12587 MB → "12.3 GB").
    static func humanMB(_ mb: Double) -> String {
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        let gb = mb / 1024
        if gb < 1024 { return String(format: "%.1f GB", gb) }
        return String(format: "%.2f TB", gb / 1024)
    }

    /// Human-readable transfer rate from MB/s (e.g., 1200 MB/s → "1.2 GB/s").
    static func humanMBps(_ mbps: Double) -> String {
        if mbps < 1024 { return String(format: "%.0f MB/s", mbps) }
        return String(format: "%.1f GB/s", mbps / 1024)
    }

    /// Escape a value for CSV output.
    static func csvEscape(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}

enum CatalogCSVWriter {
    static let headers = [
        "Filename", "Extension", "Stream Type", "Size", "Size (Bytes)", "Duration",
        "Date Created", "Date Modified", "Container", "Video Codec", "Resolution",
        "Frame Rate", "Video Bitrate", "Total Bitrate", "Color Space", "Bit Depth",
        "Scan Type", "Audio Codec", "Audio Channels", "Audio Sample Rate", "Timecode",
        "Tape Name", "Is Playable", "Partial MD5", "Duplicate Group", "Duplicate Confidence",
        "Duplicate Disposition", "Duplicate Match", "Duplicate Reasons", "Full Path", "Directory", "Notes"
    ]

    static func csvText(records: [VideoRecord]) -> String {
        var lines = [headers.joined(separator: ",")]
        for record in records {
            lines.append(row(for: record))
        }
        return lines.joined(separator: "\n")
    }

    static func row(for record: VideoRecord) -> String {
        [
            record.filename, record.ext, record.streamTypeRaw, record.size, String(record.sizeBytes),
            record.duration, record.dateCreated, record.dateModified, record.container,
            record.videoCodec, record.resolution, record.frameRate, record.videoBitrate,
            record.totalBitrate, record.colorSpace, record.bitDepth, record.scanType,
            record.audioCodec, record.audioChannels, record.audioSampleRate, record.timecode,
            record.tapeName, record.isPlayable, record.partialMD5, record.duplicateGroupID?.uuidString ?? "",
            record.duplicateConfidence?.rawValue ?? "", record.duplicateDisposition.rawValue,
            record.duplicateBestMatchFilename, record.duplicateReasons, record.fullPath, record.directory, record.notes
        ].map { Formatting.csvEscape($0) }.joined(separator: ",")
    }

    static func outputURL(root: String, date: Date = Date()) -> URL {
        let folderName = URL(fileURLWithPath: root).lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("VideoScan_\(folderName)_\(formatter.string(from: date)).csv")
    }

    static func write(records: [VideoRecord], root: String, date: Date = Date()) -> String? {
        let outURL = outputURL(root: root, date: date)
        do {
            try csvText(records: records).write(to: outURL, atomically: true, encoding: .utf8)
            return outURL.path
        } catch {
            return nil
        }
    }
}
