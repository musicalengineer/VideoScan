// CatalogPerfMemo.swift
// Small memoization helpers behind the 2026-06-10 catalog-browsing perf
// batch. Each arrow-key step in the catalog publishes 2-3 objectWillChange
// events, and every one re-evaluates the full ContentView/CatalogContent
// body. The audit found several O(n)-per-render computations riding on
// that — full-catalog filters, a linear selected-record scan, a statfs
// per render. These helpers turn them into O(1) lookups that recompute
// only when their inputs actually change.
//
// All types here are PURE — no SwiftUI, no model references — so the
// invalidation logic is unit-testable (CatalogPerfMemoTests /
// RecordPathIndexTests).

import Foundation

// MARK: - RecordsVersion

/// Cheap composite "version" of the catalog records array, used as a memo
/// key component. `count` catches add/remove; `revision` is the model's
/// `volumeAggregatesRevision`, bumped on bulk in-place mutations that
/// don't change count (Bucket-D adoption rewriting fullPath, etc.).
///
/// `// In C++ terms: a generation counter — compare two snapshots to know
/// // whether a cached derivation is still valid.`
struct RecordsVersion: Equatable {
    let count: Int
    let revision: Int
}

// MARK: - RenderMemo

/// Single-entry memo for values derived inside a SwiftUI `body`.
///
/// `// In C++ terms: a one-slot cache — `value(for:)` is get-or-compute,
/// // keyed invalidation instead of explicit dirty flags.`
///
/// Stored in a view as `@State private var memo = RenderMemo<...>()`.
/// Because this is a *class* held by @State, mutating its internals during
/// body evaluation does NOT trigger a view update (no @Published, no
/// struct copy) — which is exactly what a render-time memo needs. SwiftUI
/// keeps the same instance alive across body re-evaluations.
///
/// NOT thread-safe — main-thread (render) use only.
final class RenderMemo<Key: Equatable, Value> {
    private var key: Key?
    private var stored: Value?

    /// Computation counter, exposed for unit tests ("did the memo actually
    /// avoid recomputing?"). Costs one Int; not worth #if DEBUG gymnastics.
    private(set) var computeCount = 0

    /// Get-or-compute. Recomputes only when `key` differs from the cached
    /// key (e.g. selection changed, records version bumped).
    func value(for key: Key, compute: () -> Value) -> Value {
        if let stored, self.key == key {
            return stored
        }
        computeCount += 1
        let fresh = compute()
        self.key = key
        self.stored = fresh
        return fresh
    }

    /// Drop the cached entry; next `value(for:)` recomputes.
    func invalidate() {
        key = nil
        stored = nil
    }
}

// MARK: - RecordIDIndex

/// O(1) `UUID → VideoRecord` lookup over the model's records array.
/// Replaces the `records.first(where: { $0.id == id })` linear scans that
/// ran several times per arrow-key step (selection handler, volume
/// highlight, inspector's selectedRecord) — ~27K iterations each on
/// Rick's catalog.
///
/// Laziness contract: the index rebuilds itself whenever the passed-in
/// array's count differs from the count it was built against. VideoRecord
/// is a class, so in-place field mutations are visible through the index
/// without a rebuild. The one hole — a same-count membership swap (old
/// instance out, new instance in, e.g. a rescan that lands on the exact
/// prior count) — is covered by the miss fallback: an id the map doesn't
/// know triggers one linear scan + rebuild, so worst case degrades to the
/// pre-index behavior instead of returning a stale/missing answer.
///
/// NOT thread-safe — designed to live on the @MainActor model.
final class RecordIDIndex {
    private var map: [UUID: VideoRecord] = [:]
    private var builtForCount = -1

    /// Rebuild counter, exposed for unit tests.
    private(set) var rebuildCount = 0

    func record(forID id: UUID, in records: [VideoRecord]) -> VideoRecord? {
        if records.count != builtForCount {
            rebuild(records)
        }
        if let hit = map[id] {
            return hit
        }
        // Miss: either the id is genuinely absent, or a same-count
        // replacement slipped past the count check. One linear scan
        // disambiguates; if found, the index was stale — rebuild.
        if let found = records.first(where: { $0.id == id }) {
            rebuild(records)
            return found
        }
        return nil
    }

    func invalidate() {
        map.removeAll()
        builtForCount = -1
    }

    private func rebuild(_ records: [VideoRecord]) {
        rebuildCount += 1
        map = Dictionary(records.map { ($0.id, $0) },
                         uniquingKeysWith: { first, _ in first })
        builtForCount = records.count
    }
}

// MARK: - RecordPathIndex

/// O(1) `fullPath → VideoRecord` lookup over the model's records array
/// (perf ride-along 2026-07-14). Replaces the per-file
/// `records.first(where: { $0.fullPath == path })` scan in applyDossier
/// and the full-catalog candidate pass in single-file startAnalyzing —
/// on Rick's ~103k-record catalog every multi-selected Analyze file paid
/// two O(records) MainActor passes.
///
/// Staleness contract — STRICTER than RecordIDIndex, because unlike ids,
/// paths persist across rescans (a rescan builds NEW VideoRecord
/// instances with the SAME fullPaths, so a same-count swap would HIT the
/// stale map and hand back an orphaned instance — a writeback to it
/// would be silently lost). Three layers:
///
///   1. Rebuild when count OR `revision` (the model's
///      volumeAggregatesRevision) differs from what the map was built
///      against — covers add/remove and bulk in-place fullPath rewrites.
///   2. The model's `records.didSet` calls `invalidate()` — covers
///      array replacement (rescan/import/restore) even at identical
///      count with no revision bump. O(1): just un-latches the version.
///   3. Self-verifying hit: an entry is returned only if its record's
///      CURRENT fullPath still equals the queried path (VideoRecord is
///      a class — `hit.fullPath` reads live state), plus the same
///      miss-fallback linear-scan-then-rebuild as RecordIDIndex.
///
/// NOT thread-safe — designed to live on the @MainActor model.
final class RecordPathIndex {
    private var map: [String: VideoRecord] = [:]
    private var builtForCount = -1
    private var builtForRevision = Int.min

    /// Rebuild counter, exposed for unit tests.
    private(set) var rebuildCount = 0

    func record(forPath path: String,
                in records: [VideoRecord],
                revision: Int) -> VideoRecord? {
        if records.count != builtForCount || revision != builtForRevision {
            rebuild(records, revision: revision)
        }
        if let hit = map[path], hit.fullPath == path {
            return hit
        }
        // Miss (or a hit whose record's path moved under us): one
        // linear scan disambiguates; if found, the index was stale —
        // rebuild. Worst case degrades to the pre-index behavior
        // instead of returning a stale/missing answer.
        if let found = records.first(where: { $0.fullPath == path }) {
            rebuild(records, revision: revision)
            return found
        }
        return nil
    }

    /// O(1) un-latch — next lookup rebuilds. Called from the model's
    /// `records.didSet`, which fires on every array-level mutation
    /// including per-file live-reload appends, so this must stay cheap
    /// (no map churn here; the rebuild replaces it wholesale).
    func invalidate() {
        builtForCount = -1
        builtForRevision = Int.min
    }

    private func rebuild(_ records: [VideoRecord], revision: Int) {
        rebuildCount += 1
        map = Dictionary(records.map { ($0.fullPath, $0) },
                         uniquingKeysWith: { first, _ in first })
        builtForCount = records.count
        builtForRevision = revision
    }
}

// MARK: - Stream-type counts

/// The toolbar's "video-only / audio-only" badge counts. Previously two
/// full `records.filter{}.count` passes per ContentView render (~54K
/// iterations per arrow key). Now computed in ONE pass, only when records
/// change — recomputed alongside `recomputeVolumeAggregates()` in
/// ContentView, which is already wired to every records-change trigger.
struct CatalogStreamTypeCounts: Equatable {
    var videoOnly: Int = 0
    var audioOnly: Int = 0

    static func compute(_ records: [VideoRecord]) -> CatalogStreamTypeCounts {
        var out = CatalogStreamTypeCounts()
        for r in records {
            switch r.streamType {
            case .videoOnly: out.videoOnly += 1
            case .audioOnly: out.audioOnly += 1
            default: break
            }
        }
        return out
    }
}

// MARK: - Volume disk-size cache

/// Stale-while-revalidate cache for `attributesOfFileSystem` (statfs)
/// volume-size lookups. The preview pane's "Volume Size:" line was paying
/// a statfs PER RENDER — same blocking-syscall-on-sleeping-HDD class of
/// bug as the VolumeReachability fixes in commit 109cc36, and this reuses
/// that commit's SWRProbeCache engine (see VolumeReachability.swift).
///
/// Key: volume root path ("/Volumes/X" or "/"). Value: total bytes, nil
/// when the probe ran and failed (offline volume). Invalidated on mount /
/// unmount notifications (VideoScanModel+VolumeLifecycle) — sizes don't
/// change while mounted, so the TTL is long.
enum VolumeStatsCache {
    static let diskSizeBytes = SWRProbeCache<Int64?>(
        label: "Rick-Breen.VideoScan.volumeStats.diskSize",
        ttl: 120.0,
        probe: { path in
            guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
                  let total = attrs[.systemSize] as? Int64, total > 0 else { return nil }
            return total
        }
    )

    /// Call on volume mount/unmount, next to VolumeReachability.invalidateCache().
    static func invalidate() {
        diskSizeBytes.invalidateAll()
    }
}
