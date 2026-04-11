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
    static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var val = Double(bytes)
        for unit in units {
            if abs(val) < 1024 { return String(format: "%.1f \(unit)", val) }
            val /= 1024
        }
        return String(format: "%.1f PB", val)
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
