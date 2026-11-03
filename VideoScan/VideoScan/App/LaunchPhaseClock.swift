// LaunchPhaseClock.swift
// One OUTCOME line per launch saying where the main thread's launch time
// went (launch-time report 2026-11-02, fix D; rule 5 "nothing runs
// silently"). A 3–4 s regression hid for three days because no line named
// the phases; this one does, so a budget can be put on it.
//
//   launch phases: catalog 3120ms · repair 41ms · search index 2870ms · find-tag 7400ms · total 18010ms
//
// The marks sit at the existing phase boundaries; no work is added.
//   catalog      — `loadCatalogAtLaunch()` (catalog.sqlite → records)
//   repair       — the load-time repair block in `restoreCatalogAtLaunch`
//                  (identity repair, lifecycle backfill, dossier backfill,
//                  date unwind + catch-up)
//   search index — load-from-disk or rebuild + save, in `init`
//   find-tag     — `activateFindTagBackground()` (journal catch-up ingest)
//   total        — model init start → end of find-tag activation, the last
//                  synchronous launch step the model owns (onAppear work
//                  between the phases is inside the total, not named)
//
// Memory: four Durations and one Instant.
// C++ analogy: a struct of std::chrono::steady_clock time_points held by the
// model, printed once through the log sink.

import Foundation

@MainActor
final class LaunchPhaseClock {

    enum Phase: String, CaseIterable {
        case catalog
        case repair
        case searchIndex = "search index"
        case findTag = "find-tag"
    }

    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var spans: [Phase: Duration] = [:]
    private var reported = false

    init() { start = clock.now }

    /// Now, for a phase that is closed with `record(_:since:)`.
    var now: ContinuousClock.Instant { clock.now }

    /// Close a phase. Recording a phase twice keeps the last span (a test
    /// that re-runs `restoreCatalogAtLaunch` must not double-count).
    func record(_ phase: Phase, since mark: ContinuousClock.Instant) {
        spans[phase] = mark.duration(to: clock.now)
    }

    /// The launch line, the first time only; nil afterwards (the main
    /// window's onAppear can run again when a window is reopened).
    func takeReportLine() -> String? {
        guard !reported else { return nil }
        reported = true
        return Self.line(spans: spans, total: start.duration(to: clock.now))
    }

    /// The pure format. Every phase is printed, in order, with a number: a
    /// phase that did not run (an empty catalog has no repair block) reads 0ms.
    static func line(spans: [Phase: Duration], total: Duration) -> String {
        let parts = Phase.allCases.map { "\($0.rawValue) \(milliseconds(spans[$0] ?? .zero))ms" }
        return "launch phases: " + parts.joined(separator: " · ") + " · total \(milliseconds(total))ms"
    }

    /// Whole milliseconds, rounded down.
    static func milliseconds(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1_000 + c.attoseconds / 1_000_000_000_000_000
    }
}
