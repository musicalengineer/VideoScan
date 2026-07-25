import Foundation

// MARK: - Repair lifecycle (GH #132)
//
// identify → repair → confirm → supersede. This file owns the catalog-
// level state transitions: confirming a repair (Commit 4) and restoring
// a superseded original. The app NEVER touches the original's bytes —
// retire/restore are catalog-only, exactly like purge and set-aside.

extension VideoScanModel {

    /// Clear the superseded marker on a single record — "Restore
    /// Original (Un-supersede)" on a superseded row. The original
    /// returns to the default view and to correlate/dup candidacy; the
    /// repair record keeps its confirmation and its Confirm stamps (the
    /// history stays honest — un-supersede writes NO journey stamp,
    /// mirroring purge restore; Manager decision 2026-07-24 #4).
    /// Returns true when a record was actually mutated.
    @discardableResult
    func unsupersede(id: UUID) -> Bool {
        guard let rec = records.first(where: { $0.id == id }),
              rec.supersededByID != nil else { return false }
        rec.supersededByID = nil
        searchIndex.update(rec)
        saveCatalogDebounced()
        return true
    }
}
