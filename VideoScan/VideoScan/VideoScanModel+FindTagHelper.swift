// VideoScanModel+FindTagHelper.swift
// Detached Find and Tag daemon — the app-side glue (2026-08-06).
//
// Mirrors VideoScanModel+PreviewSweep's Stage-2 wiring with the data
// flow Find and Tag demands: the daemon (this same app binary respawned
// headless with --find-tag, see FindTagCLI.swift) NEVER writes the
// catalog. It appends verdicts to per-run journals; THIS file is the
// consumer — it applies journaled verdicts through applyRecipeVerdict
// (tiers derived from current thresholds at apply time) and tracks a
// per-file seq cursor so ingest is idempotent across launches/polls.
//
// Lifecycle contract (same as the preview helper):
//   - Settings toggle ON  → spawn detached daemon (survives app quit)
//   - Settings toggle OFF → SIGTERM (daemon journals runEnd(terminated)
//     at the next clip boundary)
//   - App launch with flag ON and no live daemon → respawn (the resume
//     index makes the respawn cheap: prior successes reused by content
//     fingerprint, errors retried)
//   - Ingest runs at launch and on a 30 s poll while the flag is ON,
//     so tags appear in the running app as the daemon works.

import Foundation
import VideoScanCore

// MARK: - Persisted setting

/// The "Find people in the background" opt-in. Explicit save()
/// (@Published kills didSet — CatalogScopeSettings pattern).
struct FindTagBackgroundSetting: Equatable {
    var enabled = false      // DEFAULT OFF — sensor-pinned by codex suite

    private static let key = "findTag.backgroundEnabled"

    static func restored(from defaults: UserDefaults) -> FindTagBackgroundSetting {
        FindTagBackgroundSetting(enabled: defaults.bool(forKey: key))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.key)
    }
}

extension VideoScanModel {

    // MARK: Configure (called once at the end of init)

    func configureFindTagHelper() {
        guard !TestEnvironment.isTestHost else {
            findTagHelperCoordinator = nil
            return
        }
        let pidfileURL = FindTagPaths.pidfileURL()
        let launcher = PosixSpawnHelperLauncher(pidfileURL: pidfileURL)
        findTagHelperCoordinator = PreviewHelperCoordinator(
            spawner: launcher,
            stopper: launcher,
            runningPID: { PreviewHelperInstance.runningPID(pidfileURL: pidfileURL) },
            // The daemon IS this app binary in --find-tag mode — no
            // separate helper executable, no locator: Vision/CoreML and
            // the recipe engine live here, and a posix_spawned child is
            // TCC-attributed to the app, keeping its volume grants.
            executableProvider: {
                guard let url = Bundle.main.executableURL else {
                    throw PreviewHelperLocator.NotFound(searched: ["Bundle.main.executableURL"])
                }
                return url
            },
            arguments: { ["--find-tag", "--person", "Donna"] },
            logFileURL: FindTagPaths.logURL(),
            log: { appLog.write($0) })

        // Launch resume: respawn if ON and not already running…
        findTagHelperCoordinator?.handle(
            event: .launch, enabled: findTagBackgroundSetting.enabled)
        // …and apply anything journaled while the app was away. Runs
        // even when the flag is OFF: a toggle-off mid-run must not
        // strand the verdicts the daemon already earned.
        ingestFindTagJournals()
        if findTagBackgroundSetting.enabled { startFindTagIngestPolling() }
    }

    /// Settings checkbox handler: persist + spawn/stop + poll lifecycle.
    func setFindTagBackgroundEnabled(_ on: Bool) {
        findTagBackgroundSetting.enabled = on
        guard !TestEnvironment.isTestHost else { return }
        findTagBackgroundSetting.save(to: .standard)
        findTagHelperCoordinator?.handle(event: on ? .toggleOn : .toggleOff,
                                         enabled: on)
        if on {
            startFindTagIngestPolling()
        } else {
            stopFindTagIngestPolling()
            // Final sweep so a toggle-off lands whatever is already
            // journaled (the daemon's runEnd may add one more verdict;
            // the next launch's ingest catches that tail).
            ingestFindTagJournals()
        }
    }

    /// Is a live daemon currently holding the find-tag pidfile?
    var isFindTagHelperRunning: Bool {
        findTagHelperCoordinator?.isHelperRunning ?? false
    }

    // MARK: Ingest polling

    private func startFindTagIngestPolling() {
        guard findTagIngestTimer == nil else { return }
        findTagIngestTimer = Timer.scheduledTimer(withTimeInterval: 30,
                                                  repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.ingestFindTagJournals() }
        }
    }

    private func stopFindTagIngestPolling() {
        findTagIngestTimer?.invalidate()
        findTagIngestTimer = nil
    }

    // MARK: Journal ingest (the daemon→catalog write-back)

    /// Apply every not-yet-applied journaled verdict through
    /// applyRecipeVerdict, then advance the per-file cursor. Idempotent:
    /// re-running over the same journals is a no-op (cursor), and even a
    /// lost cursor only re-applies verdicts applyRecipeVerdict already
    /// treats idempotently (same tier → no change). Human tags always
    /// win — applyRecipeVerdict refuses confirmed/rejected records.
    ///
    /// Cost: one directory listing + full parse of each journal with
    /// pending lines (journals are a few hundred KB; the cursor makes
    /// the steady-state pass "parse, nothing pending, done").
    func ingestFindTagJournals() {
        guard !TestEnvironment.isTestHost else { return }
        let dir = FindTagPaths.journalDirectoryURL()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }

        let stateURL = FindTagIngestState.url(inJournalDirectory: dir)
        var state = FindTagIngestState.restored(from: stateURL)
        var applied = 0
        var orphaned = 0

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "jsonl" {
            let entries = FindTagJournalReader.entries(at: file)
            guard case .runStart(let start)? = entries.first else { continue }
            let pending = state.pendingVerdicts(in: entries,
                                                filename: file.lastPathComponent)
            guard !pending.isEmpty else { continue }
            for verdict in pending {
                defer {
                    state.markApplied(filename: file.lastPathComponent,
                                      through: verdict.seq)
                }
                // Error verdicts carry no score — nothing to apply
                // (the daemon retries them on its next run).
                guard let score = verdict.score else { continue }
                guard let rec = record(forID: UUID(uuidString: verdict.recordID) ?? UUID()) else {
                    // Record purged/re-cataloged since the scan. Not an
                    // error — the next daemon run scans the new record.
                    orphaned += 1
                    continue
                }
                if applyRecipeVerdict(person: start.person, record: rec,
                                      score: score, recipeID: start.recipeID) {
                    applied += 1
                }
            }
        }

        state.save(to: stateURL)
        if applied > 0 || orphaned > 0 {
            appLog.write("Find and Tag ingest: applied \(applied) journaled "
                + "verdict(s)\(orphaned > 0 ? ", \(orphaned) orphaned record id(s)" : "")")
        }
    }
}
