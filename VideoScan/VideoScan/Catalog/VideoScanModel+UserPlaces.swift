// VideoScanModel+UserPlaces.swift
// Event-driven refresh of the Place picker roster (Rick 2026-09-12).
// The storage (`userPlaceRoster`, `userPlaceRosterTask`) lives in
// VideoScanModel.swift; the trigger is refreshDossierCountsNow(), the
// debounced catalog-change pass that already runs after every records
// swap and every `.videoScanCatalogMutated` post — including the
// inspector's own Save, so a newly typed place appears in the picker on
// the next selection. NO O(records) work in a view body: InspectorPlaceView
// reads `model.userPlaceRoster` and nothing else.

import Foundation

extension VideoScanModel {

    /// Project on the main actor, count off it, publish under a
    /// cancellation guard so a stale pass can never overwrite a newer one
    /// (same shape as CatalogView.scheduleSizeTotals).
    func scheduleUserPlaceRosterRefresh() {
        userPlaceRosterTask?.cancel()
        let places = UserPlaceRoster.project(records)
        userPlaceRosterTask = Task { [weak self] in
            // (`Task.detached` ≈ a worker thread that does NOT inherit the
            // caller's actor; only Sendable values cross.)
            let roster = await Task.detached(priority: .utility) {
                UserPlaceRoster.compute(places)
            }.value
            guard !Task.isCancelled, let self else { return }
            if roster != self.userPlaceRoster {
                self.userPlaceRoster = roster
            }
        }
    }
}
