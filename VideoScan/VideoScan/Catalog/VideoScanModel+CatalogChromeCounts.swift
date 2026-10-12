// VideoScanModel+CatalogChromeCounts.swift
// Cached catalog-wide counts the Catalog toolbar shows — the 2026-10-11
// resize-beachball fix.
//
// CatalogToolbar.body used to call
// `VideoScanModel.unreadableExtensionlessIDs(in: model.records).count`
// — a full pass over every record — on EVERY body evaluation. The toolbar
// observes the whole model, so every publish (a dossier writeback, a full-
// hash checkpoint save, a progress flag) re-ran it, and a window resize
// re-ran it on every layout pass. A 1 s main-thread sample during a resize
// with 13.8k records put the Show menu's builder (CatalogToolbar.swift:419
// → unreadableExtensionlessIDs) at the top of the app's own frames.
//
// Same discipline as `dossierCounts` and the volume-status cache: the
// model owns the number, recomputes it once per burst of catalog changes
// (250 ms debounce off `noteCatalogMutated()`, which every array mutation
// and every save already passes through), and publishes only when the
// value actually changed. The view reads an Int — O(1).
//
// Storage is a small reference-type cache held by the model (one stored
// line in the class); a changed value is announced through the model's
// own objectWillChange, so views that observe the model see it exactly as
// they would a @Published property.
//
// (For Rick: the debounce is a one-shot timer that re-arms only after it
// fires — like a dirty flag plus a deferred repaint. Ten saves inside the
// window cost one recount, not ten.)

import Foundation
import Combine

/// The cached values + debounce bookkeeping. Main-actor, like the model.
@MainActor
final class CatalogChromeCountsCache {
    /// Active rows that are extensionless AND unreadable by ffprobe.
    fileprivate(set) var unreadableExtensionless = 0
    /// Test hooks: full passes paid for / changes announced.
    fileprivate(set) var recomputeCount = 0
    fileprivate(set) var publishCount = 0
    fileprivate var refreshScheduled = false
}

extension VideoScanModel {

    /// O(1) — what the Catalog toolbar's "Remove N Unreadable
    /// Extensionless Files" item reads. Never compute this in a body.
    var unreadableExtensionlessCount: Int { catalogChromeCounts.unreadableExtensionless }

    /// Mark the toolbar counts stale. O(1); safe from per-record loops.
    func noteCatalogChromeCountsStale() {
        guard !catalogChromeCounts.refreshScheduled else { return }
        catalogChromeCounts.refreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.catalogChromeCounts.refreshScheduled = false
            self.refreshCatalogChromeCountsNow()
        }
    }

    /// One pass over the catalog. Public so tests can settle the cache
    /// without waiting on the debounce. Announces only on change, so an
    /// unchanged count never invalidates a view.
    func refreshCatalogChromeCountsNow() {
        catalogChromeCounts.recomputeCount += 1
        let fresh = Self.unreadableExtensionlessCount(in: records)
        guard fresh != catalogChromeCounts.unreadableExtensionless else { return }
        objectWillChange.send()   // what @Published does, before the write
        catalogChromeCounts.unreadableExtensionless = fresh
        catalogChromeCounts.publishCount += 1
    }

    /// Count-only twin of `unreadableExtensionlessIDs(in:)` — same
    /// predicate, no array of IDs built just to read `.count`.
    nonisolated static func unreadableExtensionlessCount(in records: [VideoRecord]) -> Int {
        var n = 0
        for rec in records where rec.purgedAt == nil
            && !shouldCatalogProbeResult(ext: rec.ext, streamTypeRaw: rec.streamTypeRaw) {
            n += 1
        }
        return n
    }
}
