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

    /// Thin adapter over FindTagIngestEngine.pass (VideoScanCore) —
    /// the pure policy owns ALL the ordering rules (codex QA #279:
    /// applicable-forces-save, staged cursors, incremental offsets,
    /// sticky rejection); this wrapper only supplies the real
    /// dependencies. Idempotent: a saved catalog with a lost cursor
    /// merely re-applies (no-ops); the reverse cannot happen by
    /// construction.
    func ingestFindTagJournals() {
        guard !TestEnvironment.isTestHost, !isReadOnly else { return }
        let dir = FindTagPaths.journalDirectoryURL()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        let journalFiles: [(url: URL, size: Int64)] = urls
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) }

        let stateURL = FindTagIngestState.url(inJournalDirectory: dir)
        var cursor = FindTagIngestState.restored(from: stateURL)
        /// Lazy fingerprint → record fallback index (re-cataloged
        /// content), built at most once per pass.
        var fingerprintIndex: [String: VideoRecord]?

        let result = FindTagIngestEngine.pass(
            journalFiles: journalFiles,
            fileStates: &findTagIngestFileStates,
            cursor: &cursor,
            activeCatalogPath: catalogStore.catalogFileURL.standardizedFileURL.path,
            isKnownRecipeID: { VideoScanModel.recipeThresholds[$0] != nil },
            currentGalleryDigest: currentFindTagGalleryDigest(),
            currentParamsDigest: FindTagCLI.currentParamsDigest(),
            readData: { url, offset in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
                return try? handle.readToEnd() ?? Data()
            },
            resolveRecord: { [weak self] recordID, fingerprint in
                self?.resolveFindTagRecord(recordID: recordID,
                                           fingerprint: fingerprint,
                                           fingerprintIndex: &fingerprintIndex)
            },
            apply: { [weak self] person, rec, score, recipeID in
                self?.applyRecipeVerdict(person: person, record: rec,
                                         score: score, recipeID: recipeID) ?? false
            },
            saveCatalog: { [weak self] in self?.saveCatalogNow() ?? false },
            persistCursor: { $0.save(to: stateURL) },
            log: { appLog.write($0) })

        if result.applied > 0 || result.orphaned > 0 {
            appLog.write("Find and Tag ingest: applied \(result.applied) journaled "
                + "verdict(s)\(result.orphaned > 0 ? ", \(result.orphaned) orphaned record(s)" : "")"
                + (result.durable ? "" : " [NOT durable — retrying next pass]"))
        }
    }

    /// Trustworthy record resolution (codex #277/#279): UUID hit is
    /// verified against the verdict's content fingerprint — full
    /// size|duration|md5 when the record has a hash, size|duration
    /// prefix when it doesn't (a hashless record can still refute a
    /// wrong-content UUID reuse). Verified mismatch → fingerprint
    /// fallback (re-cataloged content) → orphan.
    private func resolveFindTagRecord(
        recordID: String, fingerprint: String?,
        fingerprintIndex: inout [String: VideoRecord]?
    ) -> VideoRecord? {
        var candidate = record(forID: UUID(uuidString: recordID) ?? UUID())
        if let rec = candidate, let vfp = fingerprint {
            if let rfp = FindPersonJob.fingerprintKey(for: rec) {
                if rfp != vfp { candidate = nil }
            } else if rec.sizeBytes > 0,
                      !vfp.hasPrefix("\(rec.sizeBytes)|\(rec.durationSeconds)|") {
                candidate = nil   // partial check refutes the UUID match
            }
        }
        if candidate == nil, let vfp = fingerprint {
            if fingerprintIndex == nil {
                var idx: [String: VideoRecord] = [:]
                for rec in records {
                    if let fp = FindPersonJob.fingerprintKey(for: rec) { idx[fp] = rec }
                }
                fingerprintIndex = idx
            }
            candidate = fingerprintIndex?[vfp]
        }
        return candidate
    }

    /// Current gallery digest for provenance-mismatch logging —
    /// computed once per app launch (reads the gallery files).
    private func currentFindTagGalleryDigest() -> String? {
        if let cached = findTagGalleryDigestCache { return cached }
        let digest = FindTagCLI.galleryDigest(atPath: FindPersonJob.galleryPath)
        findTagGalleryDigestCache = .some(digest)
        return digest
    }
}
