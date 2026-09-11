// VideoScanModel+NotesRepair.swift
// One-time repair of machine text that landed in `userNotes` (GH #176,
// Rick's ruling 2026-09-11: "author of notes was not clear. Now it will
// be clear: ffmpeg said, Rick said, user said, etc.").
//
// How the pollution happened: the lazy notes→userNotes split
// (migrateLegacyUserNotes, 2026-07-23) knew three machine shapes. Every
// OTHER line a machine wrote to `notes` — ffprobe stderr that does not
// start with "[" ("Unsupported codec with id …", "Last message repeated
// N times", "Could not open codec …"), the Find-and-Tag recipe line, the
// duplicate-cleanup provenance line — looked human to it and was moved
// into `userNotes` on the next catalog load. Census 2026-09-11: 9,988
// records with userNotes, 9,979 of them all-machine, 9 with a line Rick
// typed. This repair moves the machine lines back to `notes`, signed
// with their recognized author ("ffprobe: Unsupported codec …"), and
// leaves the human lines where they are.
//
// Safety shape — same as the other one-shot catalog repairs:
//   * runs once per catalog: a marker file beside catalog.json
//     (`notes-repair.v1.done`); the marker travels with the catalog, not
//     the machine, so a test's temp catalog and Rick's real one never
//     share state (no UserDefaults — settings-pollution class)
//   * backup FIRST: catalog.pre-notes-repair.<stamp>.json via the shared
//     snapshotCatalog(prefix:) path (same writer as pre-merge /
//     pre-volume-rename); no backup → no mutation, no marker, retry next
//     launch
//   * idempotent by construction as well: NotesRepair.apply never leaves
//     a machine line in userNotes, and it skips a signed line `notes`
//     already holds — a second run finds nothing to do
//   * never runs against the shared store from a test host, never in
//     read-only viewer mode (the save would be refused and the marker
//     would then hide the repair from the next writable launch)

import Foundation

extension VideoScanModel {

    struct NotesRepairSummary: Equatable {
        /// Records whose userNotes lost at least one machine line.
        var recordsCleaned: Int
        /// Machine lines moved (or already present in `notes`, deduped).
        var linesMoved: Int
        /// Records that still hold a (human) userNotes after the repair.
        var humanNotesKept: Int
        /// Path of the pre-repair snapshot; nil when nothing needed moving.
        var backupPath: String?
    }

    static let notesRepairMarkerFilename = "notes-repair.v1.done"

    /// Marker beside catalog.json — the persisted "already ran" flag.
    var notesRepairMarkerPath: String {
        ((catalogStore.fileLocation as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(Self.notesRepairMarkerFilename)
    }

    /// Run the repair over `records` once. Returns nil when it did not run
    /// (marker present, test-host shared store, read-only viewer, or the
    /// backup could not be written); otherwise the summary — with
    /// recordsCleaned == 0 when the catalog was already clean (the marker
    /// is still written so the scan is never repeated).
    ///
    /// Caller (restoreCatalogFromDisk) runs this right after
    /// migrateLegacyUserNotes and BEFORE the search index is built, so the
    /// haystacks see the repaired fields.
    @discardableResult
    func repairMachineTextInUserNotes() -> NotesRepairSummary? {
        if TestEnvironment.isTestHost && catalogStore === CatalogStore.shared { return nil }
        if catalogStore.isReadOnly { return nil }
        let marker = notesRepairMarkerPath
        let fm = FileManager.default
        if fm.fileExists(atPath: marker) { return nil }

        var plan: [(VideoRecord, NotesRepair.Change)] = []
        var humanKept = 0
        for rec in records {
            if let change = NotesRepair.apply(notes: rec.notes, userNotes: rec.userNotes) {
                plan.append((rec, change))
                if !change.userNotes.isEmpty { humanKept += 1 }
            } else if !rec.userNotes.isEmpty {
                humanKept += 1
            }
        }

        guard !plan.isEmpty else {
            writeNotesRepairMarker(at: marker, summary: "clean")
            return NotesRepairSummary(recordsCleaned: 0, linesMoved: 0, humanNotesKept: humanKept, backupPath: nil)
        }

        guard let backup = snapshotCatalog(prefix: "pre-notes-repair") else {
            log("  ⚠ notes repair: could not write catalog.pre-notes-repair snapshot — nothing changed (will retry next launch)")
            appLog.write("NOTES REPAIR (DEGRADED): pre-notes-repair snapshot failed; \(plan.count) record(s) left as-is")
            return nil
        }

        var moved = 0
        for (rec, change) in plan {
            rec.notes = change.notes
            rec.userNotes = change.userNotes
            moved += change.movedLines
        }
        catalogStore.scheduleSave(records: records)
        let line = "notes repair: \(plan.count) records cleaned, \(humanKept) human notes kept, \(moved) machine lines moved back to notes, backup at \(backup)"
        writeNotesRepairMarker(at: marker, summary: line)
        log(line)
        appLog.write(line)
        return NotesRepairSummary(recordsCleaned: plan.count, linesMoved: moved,
                                  humanNotesKept: humanKept, backupPath: backup)
    }

    private func writeNotesRepairMarker(at path: String, summary: String) {
        let body = "\(ISO8601DateFormatter().string(from: Date()))\n\(summary)\n"
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // A missing marker only means the (idempotent) scan runs again
            // next launch — log it, never block the load.
            appLog.write("NOTES REPAIR: could not write marker \(path): \(error.localizedDescription)")
        }
    }
}
