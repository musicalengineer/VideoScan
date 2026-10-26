// SQLiteCatalogLoader.swift
// Records out of `catalog.sqlite` (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2): Core reads (the one-time
// display pass, then one snapshot of every `files` row, off the main
// actor); this file turns the rows into the same main-actor `VideoRecord`s
// catalog.json gives today, rewires the A/V pair references exactly as
// `CatalogStore`'s load does, and says what it found beside the records.
//
// B2.1: rows the app purged (Delete All, a prune) are not records — Core
// skips them; the new records HELD in `pending_rows` (no whole-file hash
// yet) come back as records from their stored payload, and `heldIDs` names
// them so the committer keeps them changed and Fill In Full Hashes is queued.
// A held payload that no longer decodes is left in the table and counted.
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
        /// Records that came from `pending_rows` (no whole-file hash yet).
        var heldIDs: Set<UUID> = []
        /// The per-row lock of every loaded row, from the store (codex
        /// #143): the committer's expectation for the row until it lands.
        var locks: [UUID: CatalogRowLock.Value] = [:]
        /// Held payloads that did not decode (left in the table).
        var unreadableHeld = 0
        /// Rows skipped because the app had purged them.
        var purgedCount = 0

        /// One line for the console, catalog.log and videoscan.log.
        var summary: String {
            "\(records.count) records from catalog.sqlite (generation \(generation)) · quarantine \(quarantineCount)"
                + " · conflicts \(conflictCount) · values from before the port \(unverifiedCount)"
                + " · held for a whole-file hash \(heldIDs.count) · purged \(purgedCount)"
                + (unreadableHeld > 0 ? " · held rows that would not decode \(unreadableHeld)" : "")
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
        let held = heldRecords(snapshot.pending, stored: Set(records.map(\.id)))
        records += held.records
        rewirePairs(records)
        var result = LoadResult(records: records, quarantineCount: snapshot.counts.quarantineOpen,
                                conflictCount: snapshot.counts.conflicts, unverifiedCount: unverified,
                                displayPass: snapshot.displayPass, generation: snapshot.generation)
        result.heldIDs = Set(held.records.map(\.id))
        result.unreadableHeld = held.unreadable
        result.purgedCount = snapshot.purged
        result.locks = rowLocks(snapshot.rows)
        return result
    }

    /// One lock per loaded row (the cores share the hashing; ≈ 10 µs a row).
    static func rowLocks(_ rows: [CatalogLoadedRow]) -> [UUID: CatalogRowLock.Value] {
        var locks: [UUID: CatalogRowLock.Value] = [:]
        locks.reserveCapacity(rows.count)
        for (row, lock) in zip(rows, CatalogRowLock.locks(of: rows)) {
            if let id = UUID(uuidString: row.file.id) { locks[id] = lock }
        }
        return locks
    }

    /// The held records, from their stored payload (the app's own decoder);
    /// an id that is already a `files` row is not held twice.
    static func heldRecords(_ rows: [CatalogRow.PendingRow], stored: Set<UUID>) -> (records: [VideoRecord], unreadable: Int) {
        var out: [VideoRecord] = []
        var unreadable = 0
        for row in rows {
            guard let record = try? CatalogPendingRecord.record(row.json) else {
                unreadable += 1
                continue
            }
            if !stored.contains(record.id) { out.append(record) }
        }
        return (out, unreadable)
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
