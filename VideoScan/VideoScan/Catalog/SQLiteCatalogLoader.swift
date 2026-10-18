// SQLiteCatalogLoader.swift
// Records out of `catalog.sqlite` (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2): Core reads (the one-time
// display pass, then one snapshot of every `files` row, off the main
// actor); this file turns the rows into the same main-actor `VideoRecord`s
// catalog.json gives today, rewires the A/V pair references exactly as
// `CatalogStore`'s load does, and says what it found beside the records.
//
// What the counts mean (the words Catalog Status will show, B4):
//   quarantineCount — import rows that are NOT records (no digest, gone,
//                     a finding); they wait for a rescan or a person;
//   conflictCount   — display rows shown EMPTY because copies disagree
//                     (Rick's go 2026-10-17, decision 1);
//   unverifiedCount — derived values imported from catalog.json that the
//                     cyclers have not regenerated against the bytes yet.
//
// Memory: the Core snapshot holds one row value per record while the
// records are built, so the peak is about twice the loaded catalog for the
// length of `build` (≈ 15k rows on Rick's catalog; 100k measured in
// CatalogLoadScaleTests).
//
// (For Rick: `@MainActor` ≈ "runs on the UI thread"; the `async` read hops
// to the store's own queue and comes back with plain values.)

import Foundation
import VideoScanCore

@MainActor
enum SQLiteCatalogLoader {

    struct LoadResult {
        var records: [VideoRecord]
        var quarantineCount: Int
        var conflictCount: Int
        var unverifiedCount: Int
        var displayPass: CatalogLoad.DisplayPass
        var generation: Int

        /// One line for the console, catalog.log and videoscan.log.
        var summary: String {
            "\(records.count) records from catalog.sqlite (generation \(generation)) · quarantine \(quarantineCount)"
                + " · conflicts \(conflictCount) · values from before the port \(unverifiedCount)"
        }
    }

    /// Display pass + snapshot (off the main actor), then the records.
    static func load(repository: any CatalogRepository) async throws -> LoadResult {
        try build(try await CatalogLoad.read(repository))
    }

    /// The records for a snapshot, pairs rewired.
    static func build(_ snapshot: CatalogLoad.Snapshot) throws -> LoadResult {
        let formatter = VideoRecord.makeRowDateFormatter()
        var records: [VideoRecord] = []
        records.reserveCapacity(snapshot.rows.count)
        var unverified = 0
        for row in snapshot.rows {
            records.append(try VideoRecord(row: row, dateFormatter: formatter))
            unverified += row.unverifiedDerived
        }
        rewirePairs(records)
        return LoadResult(records: records, quarantineCount: snapshot.counts.quarantineOpen,
                          conflictCount: snapshot.counts.conflicts, unverifiedCount: unverified,
                          displayPass: snapshot.displayPass, generation: snapshot.generation)
    }

    /// `pendingPairedWithID` → `pairedWith`, the same rule as
    /// CatalogStore.decode: a partner that did not load (quarantined)
    /// leaves no half-pair behind; then the persisted pairs are
    /// re-validated like every other load.
    static func rewirePairs(_ records: [VideoRecord]) {
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(records.count)
        for record in records { byID[record.id] = record }
        for record in records {
            guard let partnerID = record.pendingPairedWithID else { continue }
            record.pairedWith = byID[partnerID]
            record.pendingPairedWithID = nil
            if record.pairedWith == nil {
                record.pairGroupID = nil
                record.pairConfidence = nil
            }
        }
        _ = CorrelationScorer.revalidateExistingPairs(in: records)
    }
}
