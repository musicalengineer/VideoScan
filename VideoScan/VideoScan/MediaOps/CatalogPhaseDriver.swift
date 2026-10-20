// CatalogPhaseDriver.swift
// The one way a composite Media File Operation runs an existing job as one
// of its PHASES (2026-10-20, extracted from Import to SQLite when Validate
// Catalog became its second user). One sentence: start the phase job,
// forward Stop / Pause / Resume to it while it runs, await its end, and let
// the parent row mirror its line and bar scaled into the parent's share.
//
// Users:
//   • ImportToSQLiteJob — audit (0–40 %), Verify (40–50 %), then the importer.
//   • ValidateCatalogJob — the audit (0–80 %), then Verify (80–100 %).
// Both hand it the existing CatalogAuditJob / VerifyCatalogJob unchanged
// (ImportPhaseJob); the phase job is never added to the center — it is the
// parent row's phase, not a row of its own.
//
// What the driver does NOT decide: what a finished phase means (the parent
// reads `ImportPhaseVerdict.of(state, step:)`), the words, the logging.
//
// Memory: one reference to the phase job in flight. Nothing grows.
//
// (For Rick: this is composition over inheritance — a small helper object
// the two parent classes each HOLD, like a C++ member object both classes
// embed instead of a shared base class. `any ImportPhaseJob` ≈ a pointer to
// an abstract interface.)

import Foundation

@MainActor
final class CatalogPhaseDriver {

    /// The phase job in flight (nil between phases).
    private(set) var active: (any ImportPhaseJob)?
    /// The active phase's share of the parent's bar.
    private var span: ClosedRange<Double> = 0...0

    init() {}

    /// Run `child` to its end and return its terminal state. A Stop the
    /// parent took before the phase began (`stopRequested`) is handed to
    /// the child first, so it ends at its first boundary.
    func run(_ child: any ImportPhaseJob, span: ClosedRange<Double>, stopRequested: Bool) async -> MediaFileOperationState {
        active = child
        self.span = span
        if stopRequested { child.cancel() }
        child.start()
        await child.task?.value
        active = nil
        return child.state
    }

    func cancel() { active?.cancel() }
    func pause() { active?.pause() }
    func resume() { active?.resume() }
    var canPause: Bool { active?.canPause ?? false }
    var isPaused: Bool { active?.isPaused ?? false }

    /// The phase job's own line, and its fraction scaled into this phase's
    /// share of the parent's bar; nil between phases.
    var progress: (subtitle: String, fraction: Double)? {
        guard let child = active else { return nil }
        return (child.subtitle, span.lowerBound + child.fraction * (span.upperBound - span.lowerBound))
    }

    /// Every `milliseconds`, hand `progress` to the parent (`apply`) — the
    /// parent decides whether its row is still running and what to prefix.
    /// Cancel the returned task when the phases are over.
    func mirror(every milliseconds: Int = 250,
                _ apply: @escaping @MainActor (_ subtitle: String, _ fraction: Double) -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let p = self?.progress { apply(p.subtitle, p.fraction) }
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
        }
    }
}
