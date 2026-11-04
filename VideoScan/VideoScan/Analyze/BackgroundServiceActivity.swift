// BackgroundServiceActivity.swift — is the background helper on the content
// work? (Rick 2026-11-01 evening: Catalog Status's Content line is "in
// progress" when work is left and an analyzer OR the background service is
// running or scheduled; yellow only when nothing will do it.)
//
// A feature store (rule 12), owned by the App, feeding one Bool into the
// Catalog Status snapshot (`setBackgroundServiceActive`). Every 60 s it asks
// the helper for its status over XPC (BackgroundServiceClient.status) — but
// ONLY when the service is enabled (`background.service.enabled`): an XPC
// message makes launchd start the helper, and asking must never start it.
// Not enabled, no answer, or an error = not running.
//
// "Active" (Codex 11/03 F2 — was "any job not done") = the helper is RUNNING
// a unit of a job that feeds one of the analyzers the Content line COUNTS
// (`feedsCountedAnalyzers`): state `.running`, not waiting on Backoff. A
// queued, paused or waiting job cannot move the numerator, so it must not
// light "Analyzing N of M". The era job feeds none of them (machine era is
// not a counted analysis; AnalyzeCoverage has no per-file era stamp), so it
// never lights it; instead its own line rides under Content:
// "Machine era: N of M files (VideoScan Background — running)".
//
// Memory: one status reply at a time (a few KB), dropped after the read.
//
// (For Rick: the `Task` loop ≈ a timer thread that sleeps 60 s between
// polls; cancelling it is the RAII stop.)

import Foundation
import VideoScanCore

@MainActor
final class BackgroundServiceActivity {

    /// Helper job kinds whose units stamp an analyzer the Content line counts
    /// (AnalyzeCoverageReport.contentAnalyzers). None today: the era job writes
    /// machine-era observations, which no counted analyzer reads. A kind that
    /// stamps captions, transcripts, sound prints… is added here with it.
    nonisolated static let feedsCountedAnalyzers: Set<JobKind> = []

    /// The one rule (pure): a running, not-waiting job of a kind that feeds
    /// the counted analyzers.
    nonisolated static func isActive(_ reply: Result<ServiceStatus, Refusal>?) -> Bool {
        guard case .success(let status)? = reply else { return false }
        return status.jobs.contains { $0.state == .running && !$0.isWaiting && feedsCountedAnalyzers.contains($0.kind) }
    }

    /// The era job's own line under Content (nil = no era job not done):
    /// the helper's numbers and its state in the snapshot's own words.
    nonisolated static func eraLine(_ reply: Result<ServiceStatus, Refusal>?) -> String? {
        guard case .success(let status)? = reply,
              let era = status.jobs.filter({ $0.kind == .era && $0.state.isActive })
                .max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) else { return nil }
        let counts = era.totalUnits > 0 ? "\(era.completedUnits.formatted()) of \(era.totalUnits.formatted()) files" : era.stateWords
        return "Machine era: \(counts) (VideoScan Background — \(era.stateWords))"
    }

    /// What one poll says to Catalog Status.
    struct Reading: Equatable, Sendable {
        var active: Bool
        var eraLine: String?
        nonisolated static let none = Reading(active: false, eraLine: nil)
        nonisolated init(active: Bool, eraLine: String?) { self.active = active; self.eraLine = eraLine }
        nonisolated init(_ reply: Result<ServiceStatus, Refusal>?) {
            self.init(active: BackgroundServiceActivity.isActive(reply), eraLine: BackgroundServiceActivity.eraLine(reply))
        }
    }

    private var task: Task<Void, Never>?
    /// Injected for tests; production = the XPC client, only when enabled.
    var ask: @MainActor () async -> Result<ServiceStatus, Refusal>? = {
        guard BackgroundServiceRegistrar.isEnabled else { return nil }
        return await BackgroundServiceClient().status()
    }

    init() {}

    /// Poll every `seconds` and hand each answer to `onChange` (the
    /// snapshot is equality-gated, so an unchanged answer costs nothing).
    func start(every seconds: Double = 60, onChange: @escaping @MainActor (Reading) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                onChange(Reading(await self.ask()))
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
