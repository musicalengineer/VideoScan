// MediaBytes.swift
// THE one place a byte count becomes a user-facing string.
//
// Rick 2026-08-18: the app had a dozen private `humanBytes` /
// `formatBytes` / `byteString` helpers. Several were base-1024 but
// printed "GB"/"TB", so the TOTAL MEDIA footer said "4.9 TB" for a
// drive that Finder, `df -H`, and the label on the enclosure all call
// 5.41 TB. Finder and drive vendors are DECIMAL (1 TB = 10^12 bytes);
// a number Rick will compare against Finder has to be decimal too, or
// every comparison looks like a 10% bug.
//
// Shape (Rick's requested look): "6.7 TB", "150 GB", "12 GB", "9.5 GB",
// "12 MB", "9.5 MB", "0 B".
//   * TB and PB always keep one decimal — that is where a purchase
//     decision lives and 0.1 TB is a real 100 GB.
//   * KB / MB / GB keep one decimal below 10, none at or above 10
//     ("150 GB", not "150.4 GB" — spurious precision on a planning
//     figure).
//   * A value that would ROUND to 1000 promotes to the next unit
//     ("1.0 TB", never "1000 GB").
//
// Not for: log lines and persisted CSV fixtures (churning those churns
// tests for no user benefit), byte-rate strings, and RAM figures (RAM is
// honestly binary — see MemoryPressure).
//
// (Swift `enum` with only static members ≈ a C++ namespace: no
// instances, just a scoping shell for a free function.)

import Foundation

enum MediaBytes {

    /// Decimal (1000-based) SI units — the same base as Finder and `df -H`.
    static let KB: Int64 = 1_000
    static let MB: Int64 = 1_000_000
    static let GB: Int64 = 1_000_000_000
    static let TB: Int64 = 1_000_000_000_000
    static let PB: Int64 = 1_000_000_000_000_000

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Format a byte count for display. Negative values keep their sign
    /// (a delta can legitimately be negative); the magnitude is formatted
    /// exactly like a positive count.
    static func display(_ bytes: Int64) -> String {
        if bytes < 0 {
            // `magnitude` (not `abs`) survives Int64.min without trapping.
            return "-" + display(magnitude: Double(bytes.magnitude))
        }
        return display(magnitude: Double(bytes))
    }

    /// Convenience for optional sizes: `nil` → "—".
    static func display(_ bytes: Int64?) -> String {
        bytes.map { display($0) } ?? "—"
    }

    // MARK: - Implementation

    private static func display(magnitude v: Double) -> String {
        guard v >= 1000 else { return "\(Int(v)) B" }

        var value = v / 1000
        var index = 1
        while index < units.count - 1 {
            // Promote when the ROUNDED figure would read as 1000 or more
            // in the current unit — the display precision (one decimal
            // for TB, otherwise one decimal below 10) is what decides.
            if roundedForDisplay(value, unitIndex: index) < 1000 { break }
            value /= 1000
            index += 1
        }
        return String(format: formatSpec(value, unitIndex: index), value, units[index])
    }

    /// One decimal for TB / PB always; for KB / MB / GB only below 10.
    /// Decided on the value AS IT WILL ROUND, so 9.96 GB reads "10 GB",
    /// not "10.0 GB".
    private static func wantsOneDecimal(_ value: Double, unitIndex: Int) -> Bool {
        unitIndex >= 4 || (value * 10).rounded() / 10 < 10
    }

    private static func formatSpec(_ value: Double, unitIndex: Int) -> String {
        wantsOneDecimal(value, unitIndex: unitIndex) ? "%.1f %@" : "%.0f %@"
    }

    private static func roundedForDisplay(_ value: Double, unitIndex: Int) -> Double {
        wantsOneDecimal(value, unitIndex: unitIndex)
            ? (value * 10).rounded() / 10
            : value.rounded()
    }
}

// MARK: - VideoRecord convenience

extension VideoRecord {
    /// The size string the UI should show for a record. Formats LIVE
    /// from `sizeBytes` so every row reads in the same decimal units,
    /// even though records scanned before 2026-08-18 still carry a
    /// base-1024 string in the persisted `size` field. Falls back to
    /// that persisted string only when the byte count is unknown.
    var sizeDisplay: String {
        sizeBytes > 0 ? MediaBytes.display(sizeBytes) : size
    }
}
