import Foundation
import Combine

extension VideoScanModel {

    // MARK: - Family Tagging Writeback
    //
    // Bridges PersonFinder's recognition results back into the catalog by
    // appending matched POI names to each VideoRecord's `detectedPeople`
    // list. Before this existed, a successful scan ("Donna found in
    // /v/family.mov") never produced a corresponding catalog tag — the
    // catalog filter "videos with Donna" came back empty even after a
    // green scan.

    /// Apply detected-person tags from a finished PersonFinder run to the
    /// catalog.
    ///
    /// For each entry in `matches` that has at least one presence segment,
    /// looks up the catalog record by `fullPath` and appends `person` to
    /// its `detectedPeople` list — case-insensitive dedup so a re-scan of
    /// an already-tagged file doesn't produce ["Donna", "Donna"]. Records
    /// with no matching catalog row are silently skipped: a folder scan
    /// can include files the user never cataloged.
    ///
    /// Returns the number of records updated (callers can log "tagged N
    /// videos with Donna"). If non-zero, the catalog is marked dirty via
    /// the debounced save so the change survives an app relaunch.
    ///
    /// Confirmed-tier only. Suspected-tier (score-based gray-zone tagging
    /// against a `suspectedPeople` sidecar) lands with the CatalogSnapshot
    /// v3 migration in a follow-up step.
    @discardableResult
    func applyDetectedPeople(
        matches: [pfVideoResult],
        person: String
    ) -> Int {
        guard !person.isEmpty else { return 0 }
        guard !matches.isEmpty else { return 0 }

        var byPath: [String: VideoRecord] = [:]
        byPath.reserveCapacity(records.count)
        for r in records { byPath[r.fullPath] = r }

        var updated = 0
        for match in matches where !match.segments.isEmpty {
            guard let record = byPath[match.filePath] else { continue }
            let alreadyTagged = record.detectedPeople.contains {
                $0.caseInsensitiveCompare(person) == .orderedSame
            }
            if !alreadyTagged {
                record.detectedPeople.append(person)
                updated += 1
            }
        }

        if updated > 0 {
            objectWillChange.send()
            saveCatalogDebounced()
        }
        return updated
    }
}
