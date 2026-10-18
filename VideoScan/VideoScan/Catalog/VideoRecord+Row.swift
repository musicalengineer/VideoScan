// VideoRecord+Row.swift
// The record for one `catalog.sqlite` row (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2): Core's typed reverse of the
// importer's mapping (`VideoRecord(loaded:)`, VideoScanCore/Load/), plus the
// four display strings the app formats itself and the one non-persisted
// flag a load sets.
//
// The display strings are the contract's dropped copies (§a rows 5, 7, 9,
// 10): recomputed here with the scan's own formatters (Formatting.humanSize,
// Formatting.duration, the scan's "yyyy-MM-dd HH:mm:ss" local-time format —
// ScanWriteInProgress.swift), so a loaded row reads like a scanned one.
//
// (For Rick: a convenience init ≈ a C++ delegating constructor — it must
// call another init of the same class first, then may set members.)

import Foundation
import VideoScanCore

extension VideoRecord {

    /// The scan's date text format. One formatter per load, passed in:
    /// a `DateFormatter` per record would cost more than the record.
    static func makeRowDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    /// - Throws: `VideoRecord.LoadedRowFailure` when the row's id is not a
    ///   UUID or a stored value no longer decodes (the loader refuses).
    convenience init(row: CatalogLoadedRow, dateFormatter: DateFormatter) throws {
        try self.init(loaded: row)
        size = Formatting.humanSize(sizeBytes)
        duration = durationSeconds > 0 ? Formatting.duration(durationSeconds) : ""
        dateCreated = dateCreatedRaw.map(dateFormatter.string(from:)) ?? ""
        dateModified = dateModifiedRaw.map(dateFormatter.string(from:)) ?? ""
        derivedProvenanceUnverified = row.unverifiedDerived > 0
    }
}
