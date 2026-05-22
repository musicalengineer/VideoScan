// CatalogHealthReport.swift
// Quick verification of catalog records without running ffprobe.
// Checks for missing provenance, changed files, and deleted files.

import Foundation

struct CatalogHealthReport {
    let volumePath: String
    let volumeName: String
    let totalRecords: Int
    let checkedAt: Date = Date()

    var missingVolumeName: Int = 0
    var missingProvenance: Int = 0
    var filesDeleted: Int = 0
    var sizeChanged: Int = 0
    var healthy: Int = 0
    var volumeOffline: Bool = false
    var provenanceBackfilled: Int = 0

    var issues: Int { missingVolumeName + missingProvenance + filesDeleted + sizeChanged }
    var isHealthy: Bool { issues == 0 }

    var recommendation: String {
        if volumeOffline { return "Volume is offline — connect it to verify" }
        if filesDeleted > 0 && filesDeleted == totalRecords { return "All files missing — rescan recommended" }
        if filesDeleted > totalRecords / 2 { return "Over half the files are missing — rescan recommended" }
        if sizeChanged > 0 { return "\(sizeChanged) file(s) changed on disk — rescan recommended to update metadata" }
        if filesDeleted > 0 { return "\(filesDeleted) file(s) deleted — rescan to clean up catalog" }
        if provenanceBackfilled > 0 { return "Backfilled \(provenanceBackfilled) record(s) — catalog is now up to date" }
        return "Catalog is healthy — no rescan needed"
    }

    var summary: String {
        var lines: [String] = []
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("  Verify: \(volumeName)")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("  Records:           \(totalRecords)")
        lines.append("  Healthy:           \(healthy)")
        if missingVolumeName > 0 { lines.append("  Missing vol name:  \(missingVolumeName)") }
        if missingProvenance > 0 { lines.append("  Missing provenance:\(missingProvenance)") }
        if filesDeleted > 0      { lines.append("  Files deleted:     \(filesDeleted)") }
        if sizeChanged > 0       { lines.append("  Size changed:      \(sizeChanged)") }
        if provenanceBackfilled > 0 { lines.append("  Backfilled:        \(provenanceBackfilled)") }
        lines.append("  ──────────────────────────────────")
        lines.append("  \(recommendation)")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }
}
