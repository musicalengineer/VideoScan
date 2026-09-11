// VideoRecord+ArchivedAt.swift
// "We need to see the date a file or media artefact was archived" (Rick
// 2026-09-09). Promote now stamps `archivedAt` on the archive copy. Copies
// promoted before that field existed still carry the date twice: in the
// Promote note ("Promote 2026-08-16T20:11:03Z: promoted from …") and in
// `archiveFixity.verifiedAt` (which Verify Archive Copies may refresh, so
// it is the LAST resort, not the first).

import Foundation
import VideoScanCore

extension VideoRecord {

    /// The date this copy landed in the Master Archive, from the best
    /// available evidence. nil for a record that is not an archive copy
    /// (or a copy with no trace at all).
    var resolvedArchivedAt: Date? {
        if let archivedAt { return archivedAt }
        if let fromNote = VideoRecord.promoteStamp(inNotes: notes) { return fromNote }
        return archiveFixity?.verifiedAt
    }

    /// Earliest "Promote <ISO-8601>:" stamp in a notes field. Pure.
    nonisolated static func promoteStamp(inNotes notes: String) -> Date? {
        guard !notes.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var earliest: Date?
        for line in notes.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Promote "), let colon = t.firstIndex(of: ":") else { continue }
            // The stamp itself contains colons ("20:11:03Z"), so take the
            // token after "Promote " up to the first space instead.
            let afterPrefix = t.dropFirst("Promote ".count)
            let token = afterPrefix.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let stamp = token.hasSuffix(":") ? String(token.dropLast()) : token
            _ = colon
            guard let d = iso.date(from: stamp) ?? isoFractional.date(from: stamp) else { continue }
            if earliest == nil || d < earliest! { earliest = d }
        }
        return earliest
    }

    /// Sort key for the Archive tab's "Archived" column (GH #175). A
    /// KeyPathComparator needs a key path on the row type; the REAL date
    /// for a source row lives on its master copy and needs the model, so
    /// ArchiveView sorts through ArchiveSortPolicy when this key path is
    /// selected — this value is only the marker (and the copy's own date).
    var archivedSortDate: Date { resolvedArchivedAt ?? .distantPast }

    /// "2026-08-16" — the archive view's column text; "—" when unknown.
    var archivedDateText: String {
        guard let d = resolvedArchivedAt else { return "—" }
        return VideoRecord.archivedDayFormatter.string(from: d)
    }

    nonisolated static let archivedDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
