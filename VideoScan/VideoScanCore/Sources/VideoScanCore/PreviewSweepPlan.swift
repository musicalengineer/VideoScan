// PreviewSweepPlan.swift (VideoScanCore)
// Background preview sweep — the PURE half, lifted from the app target
// (2026-07-28, Stage 0 of the out-of-process helper). No I/O, no UI, no
// model: the persisted setting, the one-listing cache index, the
// in-memory work-plan diff, and the pause/proceed pacing decision. The
// orchestration (tasks, gates, rendering) stays in the app's
// PreviewSweepService.swift, which drives this planner and (Stage 1) so
// will the CLI helper — one planner, zero drift.
//
// CRITICAL SCALE INVARIANT (pinned by PreviewSweepScaleTests): the work
// plan is O(cacheFiles + records) with ONE cache-directory listing. The
// service lists the cache dir once, this planner parses the filenames
// (via VideoScanCore's PreviewCacheFormat parsers) into an in-memory key
// index (Sets of key hashes), and each record's key is computed off-main
// from one stat — the diff is then pure Set lookups. For Rick: build a
// hash_set from one readdir(), then join against it, instead of 17k
// readdir()s.

import Foundation

// MARK: - Volume root (pure)

/// "/Volumes/MyBook/sub/file.mov" → "/Volumes/MyBook"; anything not under
/// /Volumes (internal disk) → "/". The per-volume serialization key for
/// the sweep (MediaVolumeGate pattern — never two sweep workers hammering
/// one spindle). Lifted here so the sweep planner (Core) needs no app
/// type; the app's `MediaVolumeGatePolicy.volumeRoot` forwards to this.
public func previewVolumeRoot(forPath path: String) -> String {
    if path.hasPrefix("/Volumes/") {
        let parts = path.split(separator: "/", maxSplits: 3)
        if parts.count >= 2 { return "/Volumes/" + String(parts[1]) }
    }
    return "/"
}

// MARK: - Persisted setting (explicit-save pattern)

/// Persisted wrapper for the sweep preference. Follows the
/// CatalogKindFacetSetting explicit-save pattern: restored(from:) at
/// startup, save(to:) on every user change, defaults INJECTED so tests
/// never touch the real preferences plist (settings-pollution class).
/// No didSet magic — the @Published owner (VideoScanModel) must call
/// savePreviewSweepSettings() explicitly.
public struct PreviewSweepSettings: Equatable {

    /// OFF by default — the sweep reads the whole catalog's media files
    /// over hours; that must be an explicit opt-in. Sensor test pins
    /// this default (PreviewSweepServiceTests).
    public var enabled: Bool = false

    public static let enabledKey = "previewSweepEnabled"

    public init() {}

    public static func restored(from defaults: UserDefaults) -> PreviewSweepSettings {
        var s = PreviewSweepSettings()
        // Missing key → the off default. `bool(forKey:)` returns false
        // for junk types too, which is the fail-safe direction here.
        s.enabled = defaults.bool(forKey: enabledKey)
        return s
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

// MARK: - Candidate / work-item value types

/// Sendable value snapshot of the record fields a sweep item needs —
/// VideoRecord instances never cross into the sweep task (same
/// convention as ThumbnailPrecache's PrecacheItem / FilmstripWorkItem).
public struct PreviewSweepCandidate: Sendable, Equatable {
    public let path: String
    public let container: String
    public let videoCodec: String
    public let likelyUnanalyzable: Bool
    public let durationSeconds: Double

    public init(path: String, container: String, videoCodec: String,
                likelyUnanalyzable: Bool, durationSeconds: Double) {
        self.path = path
        self.container = container
        self.videoCodec = videoCodec
        self.likelyUnanalyzable = likelyUnanalyzable
        self.durationSeconds = durationSeconds
    }
}

/// A candidate plus its computed disk-cache key (SHA256 of
/// path|mtime|size — the service stats each file ONCE off-main and calls
/// `previewCacheKey`). Keeping the key alongside the candidate is what
/// makes the diff below pure and I/O-free.
public struct PreviewSweepKeyedCandidate: Sendable {
    public let candidate: PreviewSweepCandidate
    public let key: String

    public init(candidate: PreviewSweepCandidate, key: String) {
        self.candidate = candidate
        self.key = key
    }
}

/// One unit of sweep work: what THIS record is still missing.
public struct PreviewSweepWorkItem: Sendable {
    public let candidate: PreviewSweepCandidate
    public let key: String
    /// Best-tier still absent (fast-tier or nothing on disk).
    public let needsBestStill: Bool
    /// .ffmpegDirect route AND no complete strip set on disk. Strips are
    /// generated ONLY for ffmpegDirect records — strips-for-everything
    /// would blow the 2 GB cache cap for zero benefit (AVPlayer plays
    /// the rest natively).
    public let needsFilmstrip: Bool

    public init(candidate: PreviewSweepCandidate, key: String,
                needsBestStill: Bool, needsFilmstrip: Bool) {
        self.candidate = candidate
        self.key = key
        self.needsBestStill = needsBestStill
        self.needsFilmstrip = needsFilmstrip
    }

    /// Per-volume serialization key (MediaVolumeGate pattern — never two
    /// sweep workers hammering one spindle).
    public var volumeRoot: String { previewVolumeRoot(forPath: candidate.path) }
}

// MARK: - Cache index (one listing → in-memory sets)

/// The preview disk cache's contents, parsed from ONE directory listing
/// into membership sets keyed by cache-key hash. Strip completeness
/// mirrors PreviewDiskCache.completeStripSet's strictness exactly:
/// a key with mixed count fields, duplicate indices, a gap, or an
/// unparseable "-strip-" filename under its prefix is NOT complete
/// (lookupFilmstrip would miss, so the sweep must regenerate).
public struct PreviewSweepCacheIndex: Sendable {
    public var bestKeys: Set<String> = []
    public var fastKeys: Set<String> = []
    public var completeStripKeys: Set<String> = []
    /// Total payload bytes at listing time — the cap-awareness baseline.
    public var totalBytes: Int64 = 0

    public init() {}
}

// MARK: - Planner (pure)

public enum PreviewSweepPlanner {

    /// Build the index from a cache-directory listing. `files` is
    /// (filename, sizeBytes) — the service gets sizes for free from the
    /// same contentsOfDirectory call. Poisoned/foreign filenames
    /// (tmp- leftovers, .DS_Store, hand-crafted junk) are tolerated:
    /// they count toward totalBytes (they ARE disk usage under the cap)
    /// but never index as payloads.
    public static func buildCacheIndex(files: [(name: String, size: Int64)]) -> PreviewSweepCacheIndex {
        var index = PreviewSweepCacheIndex()

        // Per-key strip bookkeeping for the completeness check.
        struct StripAgg {
            var counts: Set<Int> = []
            var indices: Set<Int> = []
            var poisoned = false
        }
        var strips: [String: StripAgg] = [:]

        for file in files {
            index.totalBytes += max(0, file.size)
            let name = file.name
            if name.hasPrefix("tmp-") { continue }

            if let tier = previewParseTierFilename(name) {
                switch tier.tier {
                case .best: index.bestKeys.insert(tier.key)
                case .fast: index.fastKeys.insert(tier.key)
                }
                continue
            }
            if let strip = previewParseStripFilename(name) {
                var agg = strips[strip.key] ?? StripAgg()
                agg.counts.insert(strip.count)
                if !agg.indices.insert(strip.index).inserted {
                    agg.poisoned = true   // duplicate index — ambiguous set
                }
                strips[strip.key] = agg
                continue
            }
            // Unparseable name that still claims a strip prefix: mirror
            // completeStripSet, which returns nil for the whole key when
            // ANY "-strip-" file under it doesn't parse — that key's set
            // must read as incomplete here too.
            if let marker = name.range(of: "-strip-") {
                let key = String(name[..<marker.lowerBound])
                var agg = strips[key] ?? StripAgg()
                agg.poisoned = true
                strips[key] = agg
            }
            // Anything else (junk, .DS_Store) — bytes counted above, ignored.
        }

        for (key, agg) in strips {
            // parseStripFilename already enforces 0 <= index < count per
            // file, so ONE consistent count + `count` DISTINCT indices ⇒
            // exactly 0..<count (same argument as completeStripSet).
            if !agg.poisoned,
               agg.counts.count == 1,
               let count = agg.counts.first,
               agg.indices.count == count {
                index.completeStripKeys.insert(key)
            }
        }
        return index
    }

    /// The in-memory diff: which keyed candidates still need work.
    /// PURE — Set lookups only; the scale sensor pins this at 100k
    /// records + 20k cache files. Route comes from the same pure
    /// PreviewFrameRouter decision the interactive paths use.
    public static func workItems(candidates: [PreviewSweepKeyedCandidate],
                                 index: PreviewSweepCacheIndex) -> [PreviewSweepWorkItem] {
        var items: [PreviewSweepWorkItem] = []
        items.reserveCapacity(candidates.count / 4)
        for keyed in candidates {
            let c = keyed.candidate
            let needsBest = !index.bestKeys.contains(keyed.key)
            let route = PreviewFrameRouter.previewRoute(container: c.container,
                                                        videoCodec: c.videoCodec,
                                                        likelyUnanalyzable: c.likelyUnanalyzable)
            let needsStrip = route == .ffmpegDirect
                && !index.completeStripKeys.contains(keyed.key)
            if needsBest || needsStrip {
                items.append(PreviewSweepWorkItem(candidate: c,
                                                  key: keyed.key,
                                                  needsBestStill: needsBest,
                                                  needsFilmstrip: needsStrip))
            }
        }
        return items
    }
}

// MARK: - Pacing decision (pure)

public enum PreviewSweepPacing {

    /// What the dispatch loop should do before starting the next item.
    public enum Action: Equatable, Sendable {
        case proceed
        /// An interactive preview/filmstrip request happened within the
        /// quiet window — the user is browsing; their rips come first.
        case pauseForInteraction
        /// ProcessInfo thermal pressure is .serious/.critical — park.
        case pauseForThermal
    }

    /// Seconds of interactive quiet required before the sweep resumes.
    public static let defaultQuietSeconds: Double = 10

    /// PURE decision over sampled inputs so the state machine is
    /// unit-testable without clocks or hardware. Interaction wins over
    /// thermal in the reported reason (the user-facing text should say
    /// "while you browse" when both are true — browsing is the state
    /// Rick can see).
    ///
    /// `externallyBusy` (QA MAJOR-1 fix, 2026-07-27) is the "the
    /// volume-click precacher is running" signal — it must DEFER the
    /// sweep (park + re-poll), NOT make the sweep consume the whole plan
    /// as per-item skips (which discarded coverage until relaunch AND
    /// burst ~17k main-actor hops). It maps to `.pauseForInteraction`
    /// because the precacher only runs in response to a user click, so
    /// "paused while you browse" is the honest reported reason. Highest
    /// priority so the sweep truly stands down while the precacher owns
    /// the same caches.
    public static func action(lastInteraction: CFAbsoluteTime?,
                              now: CFAbsoluteTime,
                              quietSeconds: Double,
                              thermalState: ProcessInfo.ThermalState,
                              externallyBusy: Bool = false) -> Action {
        if externallyBusy {
            return .pauseForInteraction
        }
        if let last = lastInteraction, now - last < quietSeconds {
            return .pauseForInteraction
        }
        if thermalState == .serious || thermalState == .critical {
            return .pauseForThermal
        }
        return .proceed
    }
}
