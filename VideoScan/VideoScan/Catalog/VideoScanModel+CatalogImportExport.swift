import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Catalog Export
//
// JSON catalog snapshot export — once used to move a curated catalog
// between Macs (Mac Studio → MBP via AirDrop, for example). The richer
// "bundle" exporter lives in VideoScanModel+BundleImportExport.swift
// because it carries POIs + per-volume metadata as well, which is enough
// extra surface area to deserve its own file.
//
// JSON gone, slice 2b (2026-10-21): the single-file import
// (`importCatalog(from:)`, `importCatalogViaPanel`, and the content-identity
// dedup it used — `identityKey(for:)`, `localStandIn`,
// `relinkImportedProvenance`) is retired: no menu item called it, and it
// was a catalog.json reader. The export stays until slice 3.

extension VideoScanModel {

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
        let data = try CatalogSnapshotDTO(snapshot).encoded(using: encoder)
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
