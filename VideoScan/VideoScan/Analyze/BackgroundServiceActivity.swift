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
// "Active" = the helper holds a job that is not done: queued, running,
// pausing or paused (the helper's own JobRunState.isActive — a job paused by
// its backoff resumes by itself).
//
// Memory: one status reply at a time (a few KB), dropped after the read.
//
// (For Rick: the `Task` loop ≈ a timer thread that sleeps 60 s between
// polls; cancelling it is the RAII stop.)

import Foundation
import VideoScanCore

@MainActor
final class BackgroundServiceActivity {

    /// The one rule (pure): an answer with a job that is not done.
    nonisolated static func isActive(_ reply: Result<ServiceStatus, Refusal>?) -> Bool {
        guard case .success(let status)? = reply else { return false }
        return status.jobs.contains { $0.state.isActive }
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
    func start(every seconds: Double = 60, onChange: @escaping @MainActor (Bool) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                onChange(Self.isActive(await self.ask()))
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
