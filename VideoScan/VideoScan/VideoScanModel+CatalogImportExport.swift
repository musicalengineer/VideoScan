import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog Import / Export
//
// JSON catalog snapshot import/export — used to move a curated catalog
// between Macs (Mac Studio → MBP via AirDrop, for example). The richer
// "bundle" exporter lives in VideoScanModel+BundleImportExport.swift
// because it carries POIs + per-volume metadata as well, which is enough
// extra surface area to deserve its own file.
//
// Merge policy: content-identity dedup. `partialMD5 + sizeBytes` is the
// strong key; when the import has no MD5 (e.g. an ffprobe-failed row) we
// fall back to `filename + sizeBytes + floor(durationSeconds)`. Records
// with neither identity are always added — better a rare duplicate than
// a silently dropped row.

extension VideoScanModel {

    struct CatalogImportResult {
        var added: Int
        var skipped: Int
        var sourceHost: String
    }

    /// Write the current `records` array to `url` as a v2 snapshot tagged
    /// with the current machine's name. Throws on write failure.
    ///
    /// Purge policy: removed-from-catalog records are LOCAL-ONLY. They are
    /// stripped from every export path so a catalog moved to another Mac
    /// looks like the user's curated view, not their personal trash bin.
    /// Restoring is a per-machine action — exports never carry purge state.
    ///
    /// Set-aside policy (QA blocker fix, 2026-07-15): set-aside records
    /// travel WITH their `setAsideReason` — they are part of the catalog
    /// ("hidden, never deleted"), so an export/re-import must round-trip
    /// them. See `pfExportableRecords`.
    func exportCatalog(to url: URL) throws {
        let exportable = pfExportableRecords(records)
        let purgedExcluded = records.count - exportable.count
        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: exportable,
            savedFromHost: CatalogHost.currentName,
            masterArchive: masterArchive   // travels with the catalog (§3)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Encode through the Sendable DTO — VideoRecord is Decodable-only
        // (step 5b); CatalogSnapshotDTO owns the single encoder and is
        // byte-identical to the former CatalogSnapshot encoding.
        let data = try encoder.encode(CatalogSnapshotDTO(snapshot))
        try data.write(to: url, options: .atomic)
        if purgedExcluded > 0 {
            // The excluded set is exactly the purged records now — the log
            // label must say so (it used to lump set-aside records under
            // "removed", which both mislabeled them and hid the data loss).
            log("Exported \(exportable.count) records (\(purgedExcluded) removed-from-catalog record(s) excluded — local trash never travels)")
        } else {
            log("Exported \(exportable.count) records")
        }
    }

    /// Decode a catalog snapshot at `url` and merge its records into the
    /// current catalog, deduping by content identity. Each newly added
    /// record gets `sourceHost` stamped so the origin is traceable.
    /// Throws on decode failure.
    @discardableResult
    func importCatalog(from url: URL) throws -> CatalogImportResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)

        // Rewire pairedWith back-references within the imported array so
        // imported pairs keep pointing at each other, not at nothing.
        let importedByID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
        for rec in snapshot.records {
            if let pid = rec.pendingPairedWithID {
                rec.pairedWith = importedByID[pid]
                rec.pendingPairedWithID = nil
            }
        }

        // Seed identity set from existing records so an import can't create
        // a duplicate of something we already have locally.
        var seen = Set<String>()
        for rec in records {
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
        }

        // Fall back to filename-without-extension if the file forgot to stamp
        // savedFromHost (v1 snapshot or manual JSON).
        let effectiveHost: String = {
            if !snapshot.savedFromHost.isEmpty { return snapshot.savedFromHost }
            return url.deletingPathExtension().lastPathComponent
        }()

        var added = 0
        var skipped = 0
        for rec in snapshot.records {
            if let key = Self.identityKey(for: rec), seen.contains(key) {
                skipped += 1
                continue
            }
            if rec.sourceHost.isEmpty {
                rec.sourceHost = effectiveHost
            }
            records.append(rec)
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
            added += 1
        }

        let invalidPairEndpoints = CorrelationScorer.revalidateExistingPairs(in: records)
        if invalidPairEndpoints > 0 {
            log("Import released \(invalidPairEndpoints) invalid persisted A/V pair endpoint(s).")
        }
        adoptImportedMasterArchive(snapshot.masterArchive)
        saveCatalogNow()
        return CatalogImportResult(added: added, skipped: skipped, sourceHost: effectiveHost)
    }

    /// Shared alert helper. Internal (not private) so the bundle import/export
    /// extension can also use it — both code paths surface failures the same
    /// way and there's no benefit to duplicating the implementation.
    static func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Stable content identity for a record.
    /// Primary: partial-MD5 + size. Fallback: filename + size + duration.
    /// Returns nil if the record has no identifying info at all — such
    /// records are always added rather than silently dropped.
    static func identityKey(for rec: VideoRecord) -> String? {
        if !rec.partialMD5.isEmpty && rec.sizeBytes > 0 {
            return "md5:\(rec.partialMD5):\(rec.sizeBytes)"
        }
        if rec.sizeBytes > 0 && !rec.filename.isEmpty {
            return "fn:\(rec.filename):\(rec.sizeBytes):\(Int(rec.durationSeconds))"
        }
        return nil
    }

    /// Show a save panel, then export. UI entry point.
    func exportCatalogViaPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Catalog"
        panel.message = "Save the full catalog so you can import it on another Mac."
        let host = CatalogHost.currentName.replacingOccurrences(of: " ", with: "_")
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "VideoScan_catalog_\(host)_\(dateStr).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCatalog(to: url)
            log("Exported \(records.count) record(s) to \(url.lastPathComponent)")
        } catch {
            log("Export failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// Show an open panel, then import. UI entry point.
    func importCatalogViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Catalog"
        panel.message = "Import a catalog exported from another Mac. Records already present here are skipped."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try importCatalog(from: url)
            log("Imported \(result.added) new record(s) from \(result.sourceHost); skipped \(result.skipped) duplicate(s).")
            let alert = NSAlert()
            alert.messageText = "Catalog Imported"
            alert.informativeText = "Added \(result.added) new record(s) from \(result.sourceHost).\nSkipped \(result.skipped) record(s) already in this catalog."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            log("Import failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Catalog Navigation Helpers

    /// Find the set of record IDs that should be shown when navigating from
    /// Archive to Catalog for a given record. In pair mode, includes both the
    /// record and its partner (via `pairedWith` or `pairGroupID` fallback).
    // `@MainActor static`: reads `VideoRecord` (`id`, `pairedWith`,
    // `pairGroupID`), so it's main-actor work. Production callers
    // (`ContentView`) are MainActor views; the boundary/navigation test
    // suites are pinned `@MainActor` to match. Returns plain `UUID`s —
    // no `VideoRecord` escapes.
    @MainActor static func catalogFilterIDs(for recordID: UUID, pairMode: Bool, in records: [VideoRecord]) -> Set<UUID> {
        guard let rec = records.first(where: { $0.id == recordID }) else {
            // punch-list #5: a not-found id (e.g. a stale MFO-job id after
            // overnight live-reload identity churn) must NOT become the filter
            // set — that filters the table to a non-existent row and blanks it.
            // Return empty so the navigation handler clears the filter instead.
            return []
        }
        if !pairMode {
            return [recordID]
        }
        var ids: Set<UUID> = [recordID]
        if let partner = rec.pairedWith {
            ids.insert(partner.id)
        } else if let gid = rec.pairGroupID {
            for r in records where r.pairGroupID == gid && r.id != recordID {
                ids.insert(r.id)
            }
        }
        return ids
    }

    /// True iff `id` still resolves to a live catalog record. Used by the
    /// MFO "Show in Catalog" button to validate before navigating — the
    /// SwiftUI button isn't unit-testable, so the decision lives here.
    /// (punch-list #5: prevents navigating to a stale/orphan id that would
    /// blank the catalog table.)
    @MainActor func canNavigateToRecord(id: UUID) -> Bool {
        records.contains(where: { $0.id == id })
    }

    /// Expand a single record into a focus set: the record itself plus all
    /// duplicate-group members.
    func focusSet(for recordID: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [recordID]
        if let rec = records.first(where: { $0.id == recordID }),
           let gid = rec.duplicateGroupID {
            for r in records where r.duplicateGroupID == gid {
                ids.insert(r.id)
            }
        }
        return ids
    }

    // MARK: - Online Substitute Finder

    struct OnlineSubstitute {
        let original: VideoRecord
        let substitute: VideoRecord
        let volumeName: String
    }

    /// Find online content-identical copies of an offline record.
    /// Matches on partialMD5 + sizeBytes (byte-identical) only — no fuzzy matching.
    /// `@MainActor static`: reads `VideoRecord` and returns `VideoRecord`
    /// substitutes (so a snapshot signature can't carry the result back).
    /// Production callers (`CombineSheet`) are MainActor views; the
    /// substitute test suites are pinned `@MainActor` to match.
    @MainActor static func findOnlineSubstitutes(
        for record: VideoRecord,
        in allRecords: [VideoRecord]
    ) -> [OnlineSubstitute] {
        guard !record.partialMD5.isEmpty, record.sizeBytes > 0 else { return [] }

        return allRecords.compactMap { candidate in
            guard candidate.id != record.id,
                  candidate.partialMD5 == record.partialMD5,
                  candidate.sizeBytes == record.sizeBytes,
                  VolumeReachability.isReachable(path: candidate.fullPath)
            else { return nil }
            let vol = VolumeReachability.volumeName(forPath: candidate.fullPath)
            return OnlineSubstitute(original: record, substitute: candidate, volumeName: vol)
        }
    }
}
