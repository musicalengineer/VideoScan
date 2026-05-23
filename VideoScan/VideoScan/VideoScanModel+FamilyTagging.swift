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
    /// Tier-aware writeback. Confirmed matches land in `detectedPeople`,
    /// suspected (gray-zone) matches in `suspectedPeople`. Re-scans can
    /// upgrade (suspected → confirmed) or downgrade (confirmed →
    /// suspected) — the inverse list is cleaned so a name never lives
    /// in both arrays simultaneously.
    ///
    /// Records present in neither `confirmed` nor `suspected` are left
    /// alone: a re-scan that finds nothing is more likely a sampling
    /// miss than evidence that an existing tag was wrong, so we don't
    /// auto-erase.
    ///
    /// Returns the count of records whose tags changed (added, moved
    /// between arrays, or removed from one array). Marks the catalog
    /// dirty when non-zero so the change survives an app relaunch.
    @discardableResult
    func applyDetectedPeople(
        confirmed: [pfVideoResult],
        suspected: [pfVideoResult],
        person: String
    ) -> Int {
        guard !person.isEmpty else { return 0 }
        if confirmed.isEmpty && suspected.isEmpty { return 0 }

        var byPath: [String: VideoRecord] = [:]
        byPath.reserveCapacity(records.count)
        for r in records { byPath[r.fullPath] = r }

        // Track confirmed/suspected counts separately so the log line at
        // the end can give the user a one-glance quality readout
        // ("Donna: 10 confirmed, 2 suspected" vs "Donna: 12 suspected").
        var confirmedChanged = 0
        var suspectedChanged = 0

        // Confirmed: ensure name is in detectedPeople, remove from
        // suspectedPeople if present (upgrade path).
        for match in confirmed where !match.segments.isEmpty {
            guard let record = byPath[match.filePath] else { continue }
            var didChange = false
            if let idx = record.suspectedPeople.firstIndex(where: {
                $0.caseInsensitiveCompare(person) == .orderedSame
            }) {
                record.suspectedPeople.remove(at: idx)
                didChange = true
            }
            let alreadyConfirmed = record.detectedPeople.contains {
                $0.caseInsensitiveCompare(person) == .orderedSame
            }
            if !alreadyConfirmed {
                record.detectedPeople.append(person)
                didChange = true
            }
            if didChange { confirmedChanged += 1 }
        }

        // Suspected: ensure name is in suspectedPeople, remove from
        // detectedPeople if present (downgrade path — Rick's "worst
        // case scenario you can say 'suspected Donna is in here'").
        for match in suspected where !match.segments.isEmpty {
            guard let record = byPath[match.filePath] else { continue }
            var didChange = false
            if let idx = record.detectedPeople.firstIndex(where: {
                $0.caseInsensitiveCompare(person) == .orderedSame
            }) {
                record.detectedPeople.remove(at: idx)
                didChange = true
            }
            let alreadySuspected = record.suspectedPeople.contains {
                $0.caseInsensitiveCompare(person) == .orderedSame
            }
            if !alreadySuspected {
                record.suspectedPeople.append(person)
                didChange = true
            }
            if didChange { suspectedChanged += 1 }
        }

        let changed = confirmedChanged + suspectedChanged
        if changed > 0 {
            objectWillChange.send()
            saveCatalogDebounced()
            // Narrative log line — one per writeback, suppressed when
            // nothing changed (no log spam on idempotent re-runs).
            // Goes to videoscan.log so Rick can skim the catalog story
            // without tailing the unified log.
            let breakdown: String
            if confirmedChanged > 0 && suspectedChanged > 0 {
                breakdown = " (\(confirmedChanged) confirmed, \(suspectedChanged) suspected)"
            } else if suspectedChanged > 0 {
                breakdown = " (suspected)"
            } else {
                breakdown = ""
            }
            appLog.write("Catalog: tagged \(person) on \(changed) record(s)\(breakdown)")
        }
        return changed
    }

    /// Backward-compat / single-tier convenience: routes every match to
    /// `detectedPeople` (confirmed). Used by call sites that don't have
    /// engine-threshold context, and by the original test suite. Returns
    /// the count of records updated.
    @discardableResult
    func applyDetectedPeople(
        matches: [pfVideoResult],
        person: String
    ) -> Int {
        applyDetectedPeople(confirmed: matches, suspected: [], person: person)
    }
}
