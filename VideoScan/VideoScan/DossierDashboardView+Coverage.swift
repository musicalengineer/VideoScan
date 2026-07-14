// DossierDashboardView+Coverage.swift
// The two pure value types behind the dashboard's numbers — extracted
// verbatim from DossierDashboardView.swift (refactor 2026-06-25):
// CatalogCoverage (per-volume channel counting) and RateTracker
// (sliding-window files/min + ETA). Both were already `internal` (not
// `private`) so their unit tests — CatalogCoverageTests and
// RateTrackerTests — and DossierDashboardView's @State could reach
// them; the move is purely mechanical, no access changes.
// (Swift file split ≈ C++ splitting a translation unit.)
//
// 2026-07-14 (perf/dashboard-render):
//   - CatalogCoverage gained Equatable so the dashboard can compare
//     before writing @State (a write of an equal value still
//     invalidates the body).
//   - RateTracker.record is sample-gated: a tick reporting the SAME
//     count as the last sample no longer appends — an idle dashboard
//     tick leaves the tracker value-identical, so the @State write
//     (and the body re-evaluation it forces) is skipped entirely.
//   - pfRefreshVolumeCoverage is the extracted, testable core of the
//     view's refreshCounts: returns nil when NOTHING changed so the
//     caller performs zero @State writes on a no-change tick.

import SwiftUI

// MARK: - Catalog coverage (pure value type)

/// `internal` (not `private`) so unit tests in CatalogCoverageTests
/// can exercise the channel-counting logic without spinning a window.
/// Equatable (all-Int synthesis) for the compare-before-write gate.
struct CatalogCoverage: Equatable {
    /// All non-junk, non-purged records on this volume. Inflated by
    /// DRM and missing-on-disk records — kept around because the
    /// catalog still has metadata about them, but the orchestrator
    /// CAN'T act on them. This number alone makes the dial look stuck.
    let total: Int
    let dossiered: Int
    /// Records the orchestrator's candidate filter would actually
    /// process: total minus DRM-flagged, minus retired lifecycle
    /// stages, minus records the Analysis Scope sets aside (audio-only
    /// by default) and still images. (Junk + purged are already
    /// excluded by `total`.) This is the honest denominator for
    /// "are we done yet?" — when `dossiered == eligible` and
    /// `missing == 0`, the volume is genuinely complete.
    /// Rick 2026-06-13: switching the dashboard display to use this
    /// so "4228 / 4419" doesn't read as "still 1355 to do."
    /// 2026-07-14: scope-aware — 81k music files no longer inflate it.
    let eligible: Int
    let scenes: Int
    let ocrDates: Int
    let transcripts: Int
    let strongDates: Int
    /// DRM-flagged records (excluded from eligible).
    let drmCount: Int

    // MARK: Skip-reason tallies (2026-07-14) — WHY records aren't in
    // `eligible`, so the row can say where the volume's files went
    // instead of quietly shrinking the denominator. All four count
    // non-junk, non-purged records only; a record can appear in more
    // than one bucket (e.g. an archived photo).

    /// Retired lifecycle stages (archived / trashed / in-triage /
    /// deleted) — dispositioned elsewhere, not part of the pool.
    let archivedCount: Int
    /// confirmedJunk records — the ONE tally counted from records
    /// that `total` excludes, so the user sees the cull pile's size.
    let junkCount: Int
    /// Audio-classified records the current Analysis Scope sets aside.
    /// Reversible — flipping the scope toggle moves these into
    /// `eligible` on the next refresh. NOT junk.
    let outOfScopeCount: Int
    /// Still images / camera raw — never video-analysis candidates.
    let photoCount: Int

    static let empty = CatalogCoverage()
    var remaining: Int { max(0, eligible - dossiered) }

    init(total: Int = 0, dossiered: Int = 0, eligible: Int = 0, scenes: Int = 0,
         ocrDates: Int = 0, transcripts: Int = 0, strongDates: Int = 0,
         drmCount: Int = 0, archivedCount: Int = 0, junkCount: Int = 0,
         outOfScopeCount: Int = 0, photoCount: Int = 0) {
        self.total = total; self.dossiered = dossiered; self.eligible = eligible
        self.scenes = scenes
        self.ocrDates = ocrDates; self.transcripts = transcripts; self.strongDates = strongDates
        self.drmCount = drmCount
        self.archivedCount = archivedCount; self.junkCount = junkCount
        self.outOfScopeCount = outOfScopeCount; self.photoCount = photoCount
    }

    /// `scope` defaults to the app default (audio-only set aside) so
    /// existing call sites / tests keep their meaning; the dashboard
    /// passes the orchestrator's live scope.
    init(records: [VideoRecord], scope: AnalysisScope = AnalysisScope()) {
        var t = 0, d = 0, e = 0, s = 0, o = 0, x = 0, sd = 0, drm = 0
        var arch = 0, junk = 0, oos = 0, photo = 0
        for r in records {
            // Skip records that are out of scope for dossier work.
            // confirmedJunk: user has already decided to delete
            // (tallied so the row can show the cull pile).
            // purgedAt: tombstones from prior removals.
            if r.mediaDisposition == .confirmedJunk { junk += 1; continue }
            if r.purgedAt != nil { continue }
            t += 1
            // `eligible` mirrors the FULL orchestrator candidate
            // filter (pfCatalogWideMetadataCandidates + the Analysis
            // Scope gate), not just junk/purged. Additional gates:
            //   - lifecycleStage in {cataloged, workbench} —
            //     archived / deletedPermanently / trashed / inTriage
            //     records have already been dispositioned elsewhere
            //     and aren't part of the dossier pool.
            //   - drmProtected: the pipeline can't decrypt them.
            //   - Analysis Scope: audio-only set aside (reversible)
            //     and still images / camera raw (never candidates).
            //   - (reachability is handled at refreshCounts time
            //     via the prefix filter — paths outside the volume
            //     never enter `records` here.)
            //
            // dossiered only counts eligible records — otherwise
            // a record with dossierProcessedAt set but stage=archived
            // would push dossiered > eligible and break the
            // "Analyze Complete" check. Rick 2026-06-13.
            let lifecycleOK = r.lifecycleStage == .cataloged
                || r.lifecycleStage == .workbench
            if !lifecycleOK { arch += 1 }
            if r.drmProtected { drm += 1 }
            let inScope: Bool
            switch AnalysisScope.classify(streamTypeRaw: r.streamTypeRaw,
                                          filename: r.filename) {
            case .photo:
                photo += 1
                inScope = false
            case .audio(let ext):
                inScope = scope.includeAudioOnly
                    && !scope.excludedAudioExtensions.contains(ext)
                if !inScope { oos += 1 }
            case .analyzable:
                inScope = true
            }
            if lifecycleOK && !r.drmProtected && inScope {
                e += 1
                if r.dossierProcessedAt != nil { d += 1 }
            }
            // Scene/OCR/transcript channels tally across the whole
            // non-junk non-purged set so the Total Processed panel
            // doesn't artificially shrink.
            if !r.sceneCaptions.isEmpty { s += 1 }
            if !r.ocrDateCandidates.isEmpty { o += 1 }
            if !(r.audioTranscript ?? "").isEmpty { x += 1 }
            if let conf = r.inferredDateConfidence, conf >= 0.85 { sd += 1 }
        }
        total = t; dossiered = d; eligible = e; scenes = s
        ocrDates = o; transcripts = x; strongDates = sd; drmCount = drm
        archivedCount = arch; junkCount = junk
        outOfScopeCount = oos; photoCount = photo
    }
}

// MARK: - Sliding-window rate tracker

/// Records (count, timestamp) samples over a sliding window and
/// reports the average rate of growth as files per minute. Designed
/// for the dashboard refresh tick — pure value semantics so it
/// works as @State and is easy to unit-test.
///
/// `internal` (not `private`) so RateTrackerTests can drive it
/// without spinning a window.
struct RateTracker: Equatable {

    /// Default sliding-window size — 5 minutes. Short enough that the
    /// rate is responsive to "still cooking?" questions; long enough
    /// that one slow file doesn't dip the number to zero.
    static let defaultWindow: TimeInterval = 300

    private struct Sample: Equatable {
        let count: Int
        let at: Date
    }

    private var samples: [Sample] = []
    let window: TimeInterval

    init(window: TimeInterval = RateTracker.defaultWindow) {
        self.window = window
    }

    /// Add a new sample. Older samples outside the window are trimmed.
    /// If the count went down (e.g. catalog reset), we drop the
    /// stale samples and start fresh — otherwise a reset would
    /// produce a negative rate which is meaningless to the user.
    ///
    /// Sample-gated (2026-07-14 render-loop fix): a tick reporting the
    /// SAME count as the last sample appends nothing — the pre-fix
    /// behavior appended an identical-count sample every second, which
    /// made every dashboard tick a guaranteed @State mutation even on
    /// a fully idle catalog. Trimming still runs against `at`, so a
    /// stalled volume's rate still decays to "—" as its samples age
    /// out of the window (and each trim IS a value change, so the
    /// caller's compare-before-write gate lets those through).
    mutating func record(count: Int, at: Date) {
        // Detect a reset (count went down) and clear the window.
        if let last = samples.last, count < last.count {
            samples.removeAll()
        }
        if samples.last?.count != count {
            samples.append(Sample(count: count, at: at))
        }
        // Trim anything outside the window.
        let cutoff = at.addingTimeInterval(-window)
        samples.removeAll { $0.at < cutoff }
    }

    /// Average rate over the recorded window, expressed as files
    /// per minute. Returns 0 if there's only one sample (need a
    /// delta) or if the elapsed time is zero.
    var perMinute: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed > 0 else { return 0 }
        let delta = Double(last.count - first.count)
        return delta / elapsed * 60.0
    }

    /// True once we have at least two samples in the window — i.e.
    /// enough to compute a real rate.
    var hasEnoughSamples: Bool { samples.count >= 2 }

    /// User-facing label. Prefers files/min for human-scale rates,
    /// switches to files/sec when the rate is high enough that
    /// "per second" is more readable. Uses "—" until two samples
    /// land so we don't flash a misleading "0/min" on first paint.
    var displayText: String {
        guard hasEnoughSamples else { return "—" }
        let perMin = perMinute
        if perMin >= 60 {
            return String(format: "%.1f/s", perMin / 60)
        }
        if perMin >= 10 {
            return String(format: "%.0f/min", perMin)
        }
        return String(format: "%.1f/min", perMin)
    }

    /// Quick traffic-light color hint for the StatRow. Green when the
    /// fleet is actively producing (>= 1 file/min), gray when it's
    /// idle, secondary while we wait for the second sample.
    var color: Color {
        guard hasEnoughSamples else { return .secondary }
        if perMinute >= 1 { return .green }
        return .gray
    }

    // MARK: - ETA
    //
    // Rick 2026-06-09: "estimated time to completion, just a rough
    // guess." Computed from the rolling rate × remaining records.
    // Caveats baked into the display string so the user trusts it:
    //   - Returns nil if rate is 0 (would be ∞) or if we don't have
    //     enough samples yet — the dashboard then shows "—".
    //   - Rounds aggressively: "~3h", "~45m" — not "3 hours 14 minutes
    //     22 seconds" which would just be misleading precision.

    /// Estimated wall-clock time to dossier `remaining` more records,
    /// at the current rolling rate. Nil when the rate is too low to
    /// be meaningful or when there's nothing left to do.
    func eta(remaining: Int) -> TimeInterval? {
        guard remaining > 0, hasEnoughSamples else { return nil }
        let rateMin = perMinute
        guard rateMin > 0.1 else { return nil }  // <0.1/min ≈ "forever"
        let minutes = Double(remaining) / rateMin
        return minutes * 60   // seconds
    }

    /// User-facing rough ETA string. Bands chosen so the precision
    /// matches the uncertainty:
    ///   <  1 m  → "<1m"
    ///   <  1 h  → "~Nm"
    ///   <  1 d  → "~Nh"  (1h granularity is enough; we don't know
    ///                     to the minute over hours-long horizons)
    ///   ≥  1 d  → "~Nd Mh"
    /// Returns "—" for nil ETA (rate too low or nothing left).
    func etaDisplayText(remaining: Int) -> String {
        guard let secs = eta(remaining: remaining) else { return "—" }
        let mins = secs / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "~\(Int(mins.rounded()))m" }
        let hours = mins / 60
        if hours < 24 { return "~\(Int(hours.rounded()))h" }
        let days = Int(hours / 24)
        let leftover = Int(hours.rounded()) - days * 24
        return leftover > 0 ? "~\(days)d \(leftover)h" : "~\(days)d"
    }
}

// MARK: - Refresh core (extracted from the view, 2026-07-14)

/// The result of one coverage-refresh pass — the three pieces of
/// @State the dashboard owns. Returned ONLY when something changed.
struct DossierCoverageRefreshResult {
    let coverage: [String: CatalogCoverage]
    let rates: [String: RateTracker]
    let lastKey: [Int]
}

/// The testable core of DossierDashboardView.refreshCounts.
///
/// Contract (the render-loop fix, invalidation source #2): a 1 s tick
/// where the catalog signature (`key`) is unchanged AND every rate
/// tracker is value-identical returns **nil**, and the caller performs
/// ZERO @State writes — the tick costs O(volumes) tracker checks and
/// invalidates nothing. The O(records × volumes) refilter runs only
/// when `key` moved (same gate as before; the gate itself is
/// unchanged, the WRITES are now conditional too).
///
/// NO O(records) work happens in the view body — this runs from the
/// timer callback, and only when the key moves.
@MainActor
func pfRefreshVolumeCoverage(
    coverage: [String: CatalogCoverage],
    rates: [String: RateTracker],
    lastKey: [Int],
    key: [Int],
    volumePrefixes: [String],
    records: [VideoRecord],
    scope: AnalysisScope,
    now: Date
) -> DossierCoverageRefreshResult? {
    let catalogChanged = key != lastKey
    var newCoverage = coverage
    var newRates = rates
    var changed = catalogChanged   // a moved key must persist even if
                                   // counts happen to come out equal —
                                   // otherwise every later tick re-runs
                                   // the O(records) refilter.
    for prefix in volumePrefixes {
        let cov: CatalogCoverage
        if catalogChanged || newCoverage[prefix] == nil {
            let subset = records.filter { $0.fullPath.hasPrefix(prefix) }
            let fresh = CatalogCoverage(records: subset, scope: scope)
            if newCoverage[prefix] != fresh {
                newCoverage[prefix] = fresh
                changed = true
            }
            cov = fresh
        } else {
            cov = newCoverage[prefix] ?? .empty
        }
        var tracker = newRates[prefix] ?? RateTracker()
        let before = newRates[prefix]
        tracker.record(count: cov.dossiered, at: now)
        if before == nil || tracker != before {
            newRates[prefix] = tracker
            changed = true
        }
    }
    guard changed else { return nil }
    return DossierCoverageRefreshResult(coverage: newCoverage,
                                        rates: newRates,
                                        lastKey: key)
}
