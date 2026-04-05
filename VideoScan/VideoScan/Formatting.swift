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

    /// Escape a value for CSV output.
    static func csvEscape(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
