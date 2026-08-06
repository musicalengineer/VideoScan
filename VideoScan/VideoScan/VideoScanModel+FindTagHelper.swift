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
// Durability ordering (codex QA #277 blocker A): the cursor may only
// advance past APPLIED verdicts after the catalog change is durably on
// disk (saveCatalogNow() == true). Cursor-then-crash-then-catalog-lost
// would orphan the tag forever; catalog-then-crash-then-cursor-lost
// merely re-applies idempotently on the next pass. Always err toward
// the second.
//
// Activation ordering (blocker B): the model's init builds the
// coordinator but performs NO spawn and NO ingest — viewer/read-only
// status isn't known until CatalogSync applies it (VideoScanApp calls
// applyReadOnlyMode later in launch). The app calls
// activateFindTagBackground() immediately AFTER that, and every
// entry point here re-checks isReadOnly: a viewer never spawns,
// never ingests, never mutates.
//
// Journal identity (blocker C): a journal is only consumed when its
// runStart.catalogPath is THIS store's catalog file — verdicts from a
// test/copied catalog with preserved UUIDs must never tag production.

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

    // MARK: Configure (init) + activate (post-sync-gate)

    /// Called once at the end of init: BUILDS the coordinator only.
    /// Spawning and ingest wait for activateFindTagBackground() — at
    /// init the CatalogSync viewer/read-only decision hasn't been made
    /// yet (codex QA #277 blocker B).
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
    }

    /// Called by VideoScanApp right after applyReadOnlyMode: the
    /// launch-resume respawn + the catch-up ingest, now that we KNOW
    /// whether this instance is the master or a read-only viewer.
    func activateFindTagBackground() {
        guard !TestEnvironment.isTestHost else { return }
        guard !isReadOnly else {
            if findTagBackgroundSetting.enabled {
                appLog.write("Find and Tag background: viewer mode — daemon not spawned, ingest disabled")
            }
            return
        }
        findTagHelperCoordinator?.handle(
            event: .launch, enabled: findTagBackgroundSetting.enabled)
        // Apply anything journaled while the app was away. Runs even
        // when the flag is OFF: a toggle-off mid-run must not strand
        // the verdicts the daemon already earned.
        ingestFindTagJournals()
        if findTagBackgroundSetting.enabled { startFindTagIngestPolling() }
    }

    /// Settings checkbox handler: persist + spawn/stop + poll lifecycle.
    /// Inert in viewer mode (the checkbox shouldn't be reachable there,
    /// but the guard makes it structural).
    func setFindTagBackgroundEnabled(_ on: Bool) {
        guard !isReadOnly else { return }
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
    /// applyRecipeVerdict, then — only after the catalog change is
    /// durably saved — advance the per-file cursor. Idempotent: a saved
    /// catalog with a lost cursor merely re-applies (no-ops); the
    /// reverse (cursor without catalog) cannot happen by construction.
    ///
    /// Steady-state cost: one directory listing + one stat per journal
    /// (the parse cache skips exhausted, unchanged files entirely).
    func ingestFindTagJournals() {
        guard !TestEnvironment.isTestHost, !isReadOnly else { return }
        let dir = FindTagPaths.journalDirectoryURL()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }

        let stateURL = FindTagIngestState.url(inJournalDirectory: dir)
        var state = FindTagIngestState.restored(from: stateURL)
        let activeCatalogPath = catalogStore.catalogFileURL.standardizedFileURL.path

        var appliedTotal = 0
        var orphaned = 0
        /// filename → seq to commit once (and only once) durability is
        /// established for this pass.
        var cursorAdvances: [String: Int] = [:]
        /// Lazy fingerprint → record index, built only when a UUID miss
        /// or mismatch needs the fallback (codex #277 MAJOR).
        var fingerprintIndex: [String: VideoRecord]?

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "jsonl" {
            let name = file.lastPathComponent
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0)
            if let cached = findTagIngestParseCache[name],
               cached.size == size, cached.exhausted {
                continue   // unchanged + already fully applied: skip the parse
            }

            let entries = FindTagJournalReader.entries(at: file)
            guard case .runStart(let start)? = entries.first else {
                findTagIngestParseCache[name] = (size, true)
                continue
            }
            // Blocker C: refuse journals produced against a different
            // catalog file — same-UUID records in a copied/test catalog
            // must never tag this one.
            guard URL(fileURLWithPath: start.catalogPath).standardizedFileURL.path
                    == activeCatalogPath else {
                appLog.write("Find and Tag ingest: skipping \(name) — journal is for a different catalog (\(start.catalogPath))")
                findTagIngestParseCache[name] = (size, true)
                continue
            }
            // Fail CLOSED on a recipeID this build doesn't know —
            // applying a future recipe's scores under some other
            // recipe's thresholds would mint wrong tiers (codex #277).
            guard VideoScanModel.recipeThresholds[start.recipeID] != nil else {
                appLog.write("Find and Tag ingest: skipping \(name) — unknown recipeID \(start.recipeID)")
                findTagIngestParseCache[name] = (size, true)
                continue
            }

            let pending = state.pendingVerdicts(in: entries, filename: name)
            guard !pending.isEmpty else {
                findTagIngestParseCache[name] = (size, true)
                continue
            }

            var lastSeq = 0
            var appliedThisFile = 0
            for verdict in pending {
                lastSeq = verdict.seq
                guard let score = verdict.score else { continue }   // error verdicts: nothing to apply

                // Resolve the record: UUID first, VERIFIED against the
                // content fingerprint when both sides have one — a
                // reused UUID over different bytes must not be tagged.
                var record = record(forID: UUID(uuidString: verdict.recordID) ?? UUID())
                if let rec = record, let vfp = verdict.fingerprint,
                   let rfp = FindPersonJob.fingerprintKey(for: rec), rfp != vfp {
                    record = nil
                }
                // Fallback: find the same CONTENT under a new identity
                // (re-cataloged file). Index built at most once per pass.
                if record == nil, let vfp = verdict.fingerprint {
                    if fingerprintIndex == nil {
                        var idx: [String: VideoRecord] = [:]
                        for rec in records {
                            if let fp = FindPersonJob.fingerprintKey(for: rec) { idx[fp] = rec }
                        }
                        fingerprintIndex = idx
                    }
                    record = fingerprintIndex?[vfp]
                }
                guard let rec = record else {
                    orphaned += 1
                    continue
                }
                if applyRecipeVerdict(person: start.person, record: rec,
                                      score: score, recipeID: start.recipeID) {
                    appliedThisFile += 1
                }
            }
            appliedTotal += appliedThisFile
            cursorAdvances[name] = lastSeq
            findTagIngestParseCache[name] = (size, false)   // exhausted set below on commit
        }

        // Blocker A ordering: catalog durability FIRST, cursor second.
        // Nothing applied → nothing to lose → commit cursors directly.
        let durable = appliedTotal == 0 ? true : saveCatalogNow()
        if durable {
            for (name, seq) in cursorAdvances {
                state.markApplied(filename: name, through: seq)
                if var cached = findTagIngestParseCache[name] {
                    cached.exhausted = true
                    findTagIngestParseCache[name] = cached
                }
            }
            state.save(to: stateURL)
        } else {
            appLog.write("Find and Tag ingest: catalog save refused/failed — cursor NOT advanced; will re-apply next pass")
        }
        if appliedTotal > 0 || orphaned > 0 {
            appLog.write("Find and Tag ingest: applied \(appliedTotal) journaled "
                + "verdict(s)\(orphaned > 0 ? ", \(orphaned) orphaned record(s)" : "")"
                + (durable ? "" : " [NOT yet durable]"))
        }
    }
}
