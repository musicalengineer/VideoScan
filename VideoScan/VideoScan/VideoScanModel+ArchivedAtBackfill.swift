// VideoScanModel+ArchivedAtBackfill.swift
// One-time backfill of `archivedAt` for archive copies promoted before the
// field existed (Rick 2026-09-09: "find in the log the date/time archived
// for all files and backfill 'em this once"). Evidence, best first:
//   1. the copy's Promote note   "Promote 2026-08-16T20:11:03Z: promoted from …"
//   2. the manifest row          column 0 = promotedAt, keyed by record id
//   3. archiveFixity.verifiedAt  (Verify may have refreshed it — last resort)
// Idempotent: only copies with archivedAt == nil are touched; runs after
// catalog load and costs O(archive copies). Never writes to disk except the
// catalog save it already owes.

import Foundation
import VideoScanCore

enum ArchivedAtBackfill {

    struct Tally: Equatable, Sendable {
        var fromNote = 0, fromManifest = 0, fromFixity = 0, unresolved = 0
        var filled: Int { fromNote + fromManifest + fromFixity }
        var line: String {
            "Backfilled archived dates for \(filled) archive cop\(filled == 1 ? "y" : "ies") "
                + "(note \(fromNote), manifest \(fromManifest), fixity \(fromFixity); \(unresolved) with no trace)"
        }
    }

    /// Manifest text → record id → promotedAt. Pure. Column layout is the
    /// same one VerifyArchiveManifestIndex.parse reads (promotedAt first,
    /// record id at index 6).
    nonisolated static func manifestDates(text: String) -> [UUID: Date] {
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [UUID: Date] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = ArchiveManifestCSV.fields(ofLine: String(line))
            guard f.count >= 12, let id = UUID(uuidString: f[6]),
                  let d = iso.date(from: f[0]) ?? isoFractional.date(from: f[0]) else { continue }
            if out[id] == nil { out[id] = d }   // first promotion wins
        }
        return out
    }

    /// Apply to a set of copies. Pure over the records handed in. Returns
    /// the tally; mutates `archivedAt` on the copies it could resolve.
    @MainActor
    static func apply(to copies: [VideoRecord], manifest: [UUID: Date]) -> Tally {
        var t = Tally()
        for copy in copies where copy.archivedAt == nil {
            if let d = VideoRecord.promoteStamp(inNotes: copy.notes) {
                copy.archivedAt = d; t.fromNote += 1
            } else if let d = manifest[copy.id] {
                copy.archivedAt = d; t.fromManifest += 1
            } else if let d = copy.archiveFixity?.verifiedAt {
                copy.archivedAt = d; t.fromFixity += 1
            } else {
                t.unresolved += 1
            }
        }
        return t
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadManifestDatesOffMain(rootPath: String) async -> [UUID: Date] {
        guard let fd = try? ArchivePromoteEngine.openIndexFile(
            root: rootPath, name: MasterArchiveLayout.manifestFilename,
            mustExist: true, expectedHeaders: MasterArchiveLayout.acceptedManifestHeaders) else { return [:] }
        defer { close(fd) }
        guard let data = try? ArchivePromoteEngine.readAll(fd: fd),
              let text = String(bytes: data, encoding: .utf8) else { return [:] }
        return manifestDates(text: text)
    }
}

extension VideoScanModel {

    /// Called once after catalog load. No-op when every copy already has a
    /// date, so it costs nothing on a migrated catalog.
    func backfillArchivedAtIfNeeded() {
        let copies = records.filter { isArchiveCopy($0) && $0.archivedAt == nil }
        guard !copies.isEmpty else { return }
        let root = masterArchiveRootPath
        Task { @MainActor in
            var manifest: [UUID: Date] = [:]
            if let root { manifest = await ArchivedAtBackfill.loadManifestDatesOffMain(rootPath: root) }
            let tally = ArchivedAtBackfill.apply(to: copies, manifest: manifest)
            guard tally.filled > 0 else {
                log("Archived dates: \(copies.count) archive copies have no Promote trace (note, manifest or fixity) — left blank")
                return
            }
            noteCatalogRecordsMutated()
            saveCatalogDebounced()
            log(tally.line)
            appLog.write(tally.line)
        }
    }
}
