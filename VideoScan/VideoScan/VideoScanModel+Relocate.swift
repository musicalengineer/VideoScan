import Foundation

// Dedicated persistent log for Relocate runs. Lands at
// ~/Library/Logs/VideoScan/relocate.log. Outlives the in-app console,
// so post-mortems on a long overnight run are possible.
//
// IMPORTANT: PersistentLog is a no-op until `start()` is called (the
// file handle is nil until then). Earlier wiring constructed the
// instance but never opened it, so every `relocateLog.write(...)`
// silently dropped while the same lines also flowed through `log()`
// into catalog.log. Fixed in `runRelocate` (Fix 3): we call
// `start(append: true)` once at the top of every run, write a session
// header, and let subsequent writes flush to disk.
private let relocateLog = PersistentLog(name: "relocate")

// MARK: - VideoScanModel+Relocate
//
// Implements the "Relocate Volume" feature: copy every catalogued file
// from a flaky source volume (e.g. an aging external HDD) onto a folder
// inside a healthier destination volume, rewrite each VideoRecord's
// fullPath to the new location, and preserve provenance via the new
// originalFullPath / originVolume fields.
//
// Source volume is NEVER deleted by this feature — Rick disconnects the
// old drive at his discretion after verifying the migration. See
// docs/relocate_volume_plan.md for the full spec.

// MARK: - Public types

/// Caller-facing options for a relocate run.
struct RelocateOptions {
    /// Absolute path of the source volume root, e.g. "/Volumes/Mini2TB".
    /// Records whose `fullPath` starts with "<sourceVolumeRootPath>/"
    /// (note trailing slash) are in scope.
    var sourceVolumeRootPath: String

    /// Destination directory under a healthier drive. Subdirectory
    /// structure under the source root is preserved beneath this folder.
    var destinationRoot: URL

    /// Concurrent file copies. Default 1 — the source is assumed slow
    /// and parallel reads make HDD thrashing worse. Caller can raise
    /// for SSD-to-SSD migrations.
    var maxConcurrency: Int = 1

    /// Reconcile + report buckets, then exit without copying or
    /// committing. Useful for previewing the impact before commit.
    var dryRun: Bool = false

    /// Skip records that have already been relocated once
    /// (`originalFullPath != nil`). Set false to force re-attempts on
    /// previously salvage-failed records that you've since worked around:
    /// they re-enter reconcile bucket classification, so a record whose
    /// copy already sits verified at the destination adopts (no re-copy)
    /// while one whose source is now readable is re-copied — and a
    /// verified outcome clears a stale `.salvageFailed` stage.
    var skipAlreadyRelocated: Bool = true

    /// When ON (default), reconcile classifies a record as
    /// `.safelyRedundant` if the same (sizeBytes, partialMD5) lives on
    /// any catalogued volume other than source + destination. Those
    /// records get a catalog-only mark-as-deleted with an audit trail;
    /// the source file is never read. Critical for retiring a failing
    /// drive when most of its content is already mirrored elsewhere
    /// (the Mini2TB scenario — 739/741 records dup'd on other drives).
    ///
    /// Toggle OFF to fall back to the legacy A/B/C/D rules; those
    /// records will copy normally (Bucket A) instead.
    var skipDupsOnOtherVolumes: Bool = true

    /// When ON (default), a RECOVERED file whose source has no usable
    /// filename extension gets the correct extension appended on the
    /// destination copy, derived from its probed container (punch-list #3).
    /// macOS routes file-open by extension/UTI, so an extensionless file
    /// that ffprobe decodes fine is still un-openable on double-click; the
    /// recovered copy should land openable. Only unambiguous container→ext
    /// mappings are applied; the source file is never renamed in place.
    /// Toggle OFF to preserve byte-for-byte filenames on the destination.
    var addInferredExtensionOnRecovery: Bool = true
}

/// Error surface for the public relocate entry point.
enum RelocateError: Error, Equatable {
    case sourceUnreachable(String)
    case destinationUnwritable(String)
    case insufficientSpace(needed: Int64, free: Int64)
    case noRecordsInScope
}

// MARK: - Pure helpers (testable without disk)

extension VideoScanModel {

    /// Records whose `fullPath` is under `sourceVolumeRootPath`.
    /// Component-boundary matching (PathScope) so `/Volumes/Mini2TB-backup`
    /// does not false-match `/Volumes/Mini2TB`, and an empty/"/" root never
    /// matches the whole catalog. This is the central scoping helper behind
    /// totalRecordsOn / relocate / retire accounting. // regression: codex C2
    nonisolated static func recordsScoped(to sourceVolumeRootPath: String,
                                          in all: [VideoRecord]) -> [VideoRecord] {
        all.filter { PathScope.contains($0.fullPath, within: sourceVolumeRootPath) }
    }

    /// Translate a source file's absolute path to its destination path
    /// under `destRoot`, preserving the subdirectory layout beneath
    /// `sourceRoot`. Trailing slashes on either input are normalized.
    nonisolated static func rewrittenPath(forSourcePath src: String,
                                          sourceRoot: String,
                                          destRoot: String) -> String {
        let normalizedSourceRoot = sourceRoot.hasSuffix("/")
            ? String(sourceRoot.dropLast())
            : sourceRoot
        let normalizedDestRoot = destRoot.hasSuffix("/")
            ? String(destRoot.dropLast())
            : destRoot
        // src must start with "<normalizedSourceRoot>/". If not, fall
        // back to placing the bare filename under destRoot (defensive —
        // should never happen given recordsScoped filtering).
        let withSlash = normalizedSourceRoot + "/"
        guard src.hasPrefix(withSlash) else {
            let leaf = (src as NSString).lastPathComponent
            return normalizedDestRoot + "/" + leaf
        }
        let relative = String(src.dropFirst(withSlash.count))
        return normalizedDestRoot + "/" + relative
    }

    /// Suggest a destination folder name like "from-Mini2TB-20260530".
    /// Stable across the same day; collisions are the user's problem to
    /// resolve via the dest-folder picker.
    nonisolated static func suggestDestinationName(forSourceVolumeName name: String,
                                                    now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone.current
        let stamp = fmt.string(from: now)
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: " ", with: "_")
        return "from-\(cleaned)-\(stamp)"
    }

    /// Render a structured audit-trail note for a safely-redundant
    /// classification. Format is a single line of `key=value`-ish JSON-lite
    /// so the catalog notes column stays one logical line per event but is
    /// still grep-able. The witness list is the same capped sample carried
    /// on the `SafelyRedundantEntry`. Pure & nonisolated so tests can call
    /// without a VideoScanModel.
    nonisolated static func formatSafelyRedundantNote(stamp: String,
                                                       witnesses: [String],
                                                       totalWitnessCount: Int) -> String {
        // Quote each witness path and join — avoids accidental field-break
        // on a literal comma in a filename. JSON-array shape, but inline.
        let quoted = witnesses.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                              .joined(separator: ", ")
        return "Reconcile \(stamp): reason=dup-on-other-volume witnesses=[\(quoted)] totalWitnesses=\(totalWitnessCount)"
    }

    /// Build the `(source → witness)` sample list for the post-Apply
    /// summary sheet. Walks Bucket E entries and pairs each source record
    /// with the HIGHEST-RANKED safe witness in its list (post-2026-05-30
    /// safety filter; pre-filter behavior was "first witness"). Capped
    /// at `limit` so the disclosure stays readable; the full audit trail
    /// remains in the catalog notes and relocate.log.
    ///
    /// Each sample carries the host volume's role + trust so the sheet
    /// can render the `✅ LaCieWorkspace · Offsite · Reliable`
    /// badge line. Pure / nonisolated for tests.
    nonisolated static func witnessSamples(
        from entries: [SafelyRedundantEntry],
        limit: Int = 10
    ) -> [RelocateSummary.WitnessSample] {
        // `prefix(limit)` would clip mid-record; here every record has at
        // least one safe witness (otherwise it wouldn't be in Bucket E),
        // so a straight prefix is the right call.
        entries.prefix(limit).compactMap { entry in
            // Prefer the safest witness. `safeWitnesses` is already
            // sorted highest-first by RelocateReconcile, so [0] is the
            // right pick. Legacy entries (no safeWitnesses populated)
            // fall back to the audit-trail `witnesses` string array.
            if let top = entry.safeWitnesses.first {
                return RelocateSummary.WitnessSample(
                    sourcePath: entry.rec.fullPath,
                    witnessPath: top.path,
                    witnessRole: top.role,
                    witnessTrust: top.trust,
                    witnessIsRetired: top.isRetired
                )
            }
            guard let first = entry.witnesses.first else { return nil }
            return RelocateSummary.WitnessSample(
                sourcePath: entry.rec.fullPath,
                witnessPath: first,
                witnessRole: .unassigned,
                witnessTrust: .unknown
            )
        }
    }

    // MARK: - Public entry

    /// Kick off a Relocate Volume run. As of §3 (Relocate Job Queue —
    /// 2026-05-31) this is a thin shim that routes through
    /// `enqueueRelocate(...)`. Behavior matches the pre-queue contract
    /// when nothing is currently running: a new task spawns and
    /// `isRelocating` (now computed) flips true. When something is
    /// already running, the new request slips into the queue and
    /// dequeues automatically when its turn arrives. Existing tests
    /// still poll `isRelocating` and that still works.
    func relocateVolume(_ options: RelocateOptions) {
        _ = enqueueRelocate(
            sourceRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            options: options
        )
    }

    // MARK: - Run

    /// Drive one queued job through reconcile → snapshot → per-record
    /// copy → catalog mutation → summary. Looks up the job by id at
    /// every transition so cancel-from-UI sees up-to-date state. Sets
    /// the job's terminal status to `.awaitingDone` so the user must
    /// dismiss the summary sheet before the queue advances.
    func runRelocate(jobID: UUID) async {
        guard let initialIdx = relocateQueue.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        let options = relocateQueue[initialIdx].options
        let scope = Self.recordsScoped(to: options.sourceVolumeRootPath, in: records)
        // Defensive — enqueueRelocate already guards on empty scope,
        // but races (e.g. records removed between enqueue and run) are
        // possible. Treat as a clean .failed transition.
        guard !scope.isEmpty else {
            updateJobStatus(id: jobID, status: .failed(reason: "no records in scope"))
            advanceQueueAfterCurrent()
            return
        }
        dashboard.resetForRelocate(total: scope.count)
        await runRelocate(scope: scope, options: options, jobID: jobID)
    }

    private func runRelocate(scope: [VideoRecord],
                              options: RelocateOptions,
                              jobID: UUID) async {
        // Fix 3 — open the dedicated relocate.log file. Without this,
        // every `relocateLog.write(...)` call is a silent no-op because
        // PersistentLog's file handle stays nil. We append-open so
        // sequential runs accumulate; the per-session header below lets
        // the post-mortem reader separate them.
        relocateLog.start(append: true)
        let host = ProcessInfo.processInfo.hostName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        relocateLog.write("── Migrate session started \(ISO8601DateFormatter().string(from: Date())) on \(host) v\(version)")
        relocateLog.write("─── Migrate started: source=\(options.sourceVolumeRootPath) dest=\(options.destinationRoot.path) scope=\(scope.count) dryRun=\(options.dryRun) skipDupsOnOtherVolumes=\(options.skipDupsOnOtherVolumes)")

        // Fix 2 — pin a minimum start time. A fast run (Bucket E only,
        // 0.5s on Maxtor500FW) used to flash past too quick for Rick to
        // register what happened. We hold the progress sheet up for at
        // least 800ms by deferring the summary publication until this
        // wall-clock budget is met. Real work, not theatre — the I/O
        // actually has to land first; we only pad if it finished early.
        let runStart = Date()
        let minVisibleSeconds: TimeInterval = 0.8

        // 1A. Reconcile pre-flight — runs OFF the main actor. The classify
        // phase does a full-volume FS walk + per-record partialMD5 disk reads;
        // on a flaky HDD that blocked the main thread for ~235s and beachballed
        // the UI with no responsive Hide/Cancel (perf analysis 2026-06-20).
        //
        // Seam D (VideoRecord-Sendable restructure): we project every record
        // the classify pass reads into Sendable `ReconcileRecordInput` values
        // ON THE MAIN ACTOR (scope = in-scope records; the full catalog =
        // Bucket-E witnesses) and build the volume-safety resolver here too,
        // then hand only those Sendable values to the detached task. The task
        // returns an id-keyed, Sendable `ReconcilePlan` — no `VideoRecord`
        // crosses the boundary. We re-materialize the plan against the live
        // records back here on main, then the apply phase below mutates those
        // records on the main actor exactly as before.
        let scopeInputs = scope.map(\.asReconcileInput)
        let witnessInputs = records.map(\.asReconcileInput)
        let resolver = makeVolumeSafetyResolver()
        // Honest progress (2026-07-06): the classify loop reports
        // (done, total) — the UI gets a determinate bar ≤4 Hz and
        // relocate.log gets a heartbeat every 5 s, so neither the modal
        // nor a log-watcher is ever left guessing "2 weeks or 20 minutes".
        reconcileProgress = (0, scopeInputs.count)
        relocateLog.write("Reconcile: enumerating volumes, then classifying \(scopeInputs.count) record(s)…")
        let throttle = ReconcileProgressThrottle()
        let progressSink: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            let gates = throttle.gate()
            guard gates.ui || gates.log || done == total else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileProgress = (done, total)
                if gates.log && total > 0 {
                    relocateLog.write("Reconcile progress: \(done)/\(total) (\(done * 100 / total)%)")
                }
            }
        }
        let plan = await Task.detached(priority: .userInitiated) {
            Self.performReconcilePlanOffActor(scopeInputs: scopeInputs,
                                              witnessInputs: witnessInputs,
                                              options: options,
                                              resolveVolumeSafety: resolver,
                                              progress: progressSink)
        }.value
        reconcileProgress = nil
        let reconcile = RelocateReconcile.materialize(plan, scope: scope)
        logReconcileSummary(reconcile)
        relocateLog.write("Reconcile: ready=\(reconcile.ready.count) adopted=\(reconcile.adopted.count) sourceMoves=\(reconcile.sourceSideMoves.count) safelyRedundant=\(reconcile.safelyRedundant.count) manuallyDeleted=\(reconcile.manuallyDeleted.count) previouslyRelocated=\(reconcile.previouslyRelocated.count)")

        // Cancellation check after reconcile (which can run minutes on a
        // flaky HDD): stop before touching the catalog so a cancel during
        // reconcile applies zero changes.
        if Task.isCancelled {
            relocateLog.write("Migrate canceled by user during reconcile — no changes applied.")
            log("Migrate canceled during reconcile — no changes applied.")
            updateJobStatus(id: jobID, status: .canceled)
            startNextQueuedJobIfIdle()
            return
        }

        // Track salvageFailed for the final summary block.
        var salvageFailedPaths: [String] = []

        // Snapshot catalog.json before any mutation — but only when a
        // mutation can actually happen. A dry-run promises zero side
        // effects, and the snapshot file itself is a side effect: the
        // old unconditional call left a misleading
        // catalog.pre-relocate.<stamp>.json behind on every preview
        // (QA P3, 2026-07-01). Placement matters: the apply phase for
        // Buckets B/D/E starts immediately below, so the snapshot must
        // stay HERE (not after the dry-run early-return further down,
        // which would put it after the first real mutation).
        let snapshotPath: String? = options.dryRun ? nil : snapshotCatalogPreRelocate()

        // Apply zero-copy mutations: Bucket B (manuallyDeleted),
        // Bucket C (rewrite path then queue for migration),
        // Bucket D (adopt — stamp provenance, skip copy),
        // Bucket E (safelyRedundant — mark as manuallyDeleted with witness audit).
        //
        // Fix 1 (dry-run mutation gate): in dry-run mode we must NOT
        // mutate the catalog at all. The previous code applied Bucket
        // B/D/E disposition writes BEFORE the dryRun early-return, which
        // was a latent bug — the dry-run record would silently flip to
        // .manuallyDeleted even though the "no copies happen" message
        // promised the catalog was untouched. We now wrap every
        // disposition write in `if !options.dryRun`, and for the dry-run
        // summary we drive the counts off `reconcile.*.count` instead.
        var safelyRedundantBytes: Int64 = 0
        if !options.dryRun {
            for r in reconcile.manuallyDeleted {
                r.archiveStage = .manuallyDeleted
                r.notes = appendNote(r.notes, "Reconcile \(stamp()): source file not found")
                relocateLog.write("[RECONCILE] manually-deleted: \(r.fullPath)")
                dashboard.relocateManuallyDeleted += 1
                dashboard.relocateCompleted += 1
            }
            for (r, dest) in reconcile.adopted {
                if r.originalFullPath == nil { r.originalFullPath = r.fullPath }
                if r.originVolume == nil { r.originVolume = r.volumeName }
                relocateLog.write("[RECONCILE] adopted: \(r.fullPath) → \(dest)")
                r.fullPath = dest
                r.directory = (dest as NSString).deletingLastPathComponent
                r.notes = appendNote(r.notes, "Reconcile \(stamp()): adopted existing copy at dest")
                // Adoption is hash-verified, so it clears a stale terminal
                // failure exactly like the copy-success path does (see the
                // 2026-06-19 fix in the migrate loop): a record left
                // .salvageFailed by a prior attempt, later worked around by
                // copying the file to dest by hand, must not stay labeled
                // "Salvage Failed" once we've verified the dest copy. This
                // is the force-retry (skipAlreadyRelocated=false) doc
                // scenario landing in Bucket D.
                if r.archiveStage == .salvageFailed {
                    r.archiveStage = .none
                    r.notes = appendNote(r.notes,
                        "Migrate \(stamp()): salvage recovered — verified existing copy at dest")
                }
                dashboard.relocateAdopted += 1
                dashboard.relocateCompleted += 1
            }
            // Bucket E: safely redundant. Catalog-only mark-as-deleted with
            // structured audit trail. Source file is NEVER touched — the
            // failing drive doesn't get another read. Same disposition
            // mutation as Bucket B so the snapshot rollback path treats them
            // identically (restore archiveStage + notes from snapshot copy).
            for entry in reconcile.safelyRedundant {
                let r = entry.rec
                r.archiveStage = .manuallyDeleted
                r.notes = appendNote(r.notes,
                    Self.formatSafelyRedundantNote(stamp: stamp(),
                                                   witnesses: entry.witnesses,
                                                   totalWitnessCount: entry.totalWitnessCount))
                relocateLog.write("[RECONCILE] safely-redundant: \(r.fullPath) — \(entry.totalWitnessCount) witness(es), first: \(entry.witnesses.first ?? "?")")
                dashboard.relocateSafelyRedundant += 1
                dashboard.relocateCompleted += 1
                safelyRedundantBytes += r.sizeBytes
            }
            dashboard.relocateSafelyRedundantBytes = safelyRedundantBytes
        } else {
            // Dry-run: just paint the counts without touching records.
            // Skipping the dashboard pre-population would leave the
            // progress sheet at 0 for the entire run; instead we drive
            // the same dashboard counters off the reconcile result so
            // the user sees what WOULD happen.
            dashboard.relocateManuallyDeleted = reconcile.manuallyDeleted.count
            dashboard.relocateAdopted = reconcile.adopted.count
            dashboard.relocateSafelyRedundant = reconcile.safelyRedundant.count
            safelyRedundantBytes = reconcile.safelyRedundant.reduce(0) { $0 + $1.rec.sizeBytes }
            dashboard.relocateSafelyRedundantBytes = safelyRedundantBytes
            dashboard.relocateCompleted = reconcile.manuallyDeleted.count
                + reconcile.adopted.count
                + reconcile.safelyRedundant.count
        }

        // Bucket C: rewrite path to the in-source new location THEN
        // queue for migration (treat as Bucket A from here on).
        // Path rewrites are mutations too — guard them off in dry-run.
        var toMigrate: [VideoRecord] = reconcile.ready
        if !options.dryRun {
            for (r, newSrc) in reconcile.sourceSideMoves {
                relocateLog.write("[RECONCILE] source-move: \(r.fullPath) → \(newSrc)")
                r.fullPath = newSrc
                r.directory = (newSrc as NSString).deletingLastPathComponent
                r.notes = appendNote(r.notes, "Reconcile \(stamp()): source-side move detected")
                dashboard.relocateSourceMoves += 1
                toMigrate.append(r)
            }
            // Previously-relocated short-circuit. The bucket is populated
            // only when options.skipAlreadyRelocated is true — with the
            // force-retry option (false) reconcile classifies those records
            // into the real buckets instead (QA fix 2026-07-01), so counting
            // every entry here unconditionally keeps relocateCompleted able
            // to reach relocateTotal in both modes.
            for r in reconcile.previouslyRelocated {
                relocateLog.write("[RECONCILE] previously-relocated, skipping: \(r.fullPath)")
                dashboard.relocateSkipped += 1
                dashboard.relocateCompleted += 1
                _ = r  // record left alone
            }
            catalogStore.scheduleSave(records: records)
        } else {
            dashboard.relocateSourceMoves = reconcile.sourceSideMoves.count
            // Same invariant as the real-run loop above: the bucket is
            // empty when skipAlreadyRelocated is false, so no option
            // check is needed here.
            dashboard.relocateSkipped = reconcile.previouslyRelocated.count
            dashboard.relocateCompleted += dashboard.relocateSkipped
        }

        if options.dryRun {
            log("[DRY RUN] No files copied. Would have migrated \(toMigrate.count) record(s).")
            // relocate.log filename is intentionally preserved (per renaming
            // policy log file paths stay the same).
            relocateLog.write("[DRY RUN] no copies; would migrate \(toMigrate.count) record(s)")
            logRelocateSummary(salvageFailedPaths: [], snapshotTaken: false)
            // Pad to min-visible window even on dry-run so a 50ms
            // reconcile doesn't blink past.
            await padToMinVisible(runStart: runStart, minVisibleSeconds: minVisibleSeconds)
            publishSummary(
                jobID: jobID,
                options: options,
                reconcile: reconcile,
                salvageFailedPaths: [],
                snapshotPath: snapshotPath,
                elapsed: Date().timeIntervalSince(runStart)
            )
            return
        }

        // 4. Per-record copy + verify + commit. The queue-level job
        // flips to .copying here so the Jobs panel's progress bar can
        // light up; reconcile-only runs (dry-run, or all-Bucket-B/D/E)
        // skip this loop and never see .copying.
        if !toMigrate.isEmpty {
            updateJobStatus(id: jobID, status: .copying)
            // Seed the Jobs-panel bar at 0/total immediately so it appears the
            // moment copying starts — not only after the first file lands.
            updateJobCopyProgress(id: jobID, done: 0, total: toMigrate.count,
                                  currentFile: toMigrate.first?.filename ?? "",
                                  bytesCopied: dashboard.relocateBytesCopied)
        }
        var canceledMidRun = false
        for (i, rec) in toMigrate.enumerated() {
            // Cooperative cancellation point — between atomic per-file copies.
            // Everything copied so far is committed + verified and the source
            // is untouched, so stopping here leaves a clean partial relocate.
            if Task.isCancelled {
                canceledMidRun = true
                relocateLog.write("Migrate canceled by user after \(i) of \(toMigrate.count) file(s) copied.")
                log("Migrate canceled — stopped after \(i) of \(toMigrate.count) file(s).")
                break
            }
            var newPath = Self.rewrittenPath(
                forSourcePath: rec.fullPath,
                sourceRoot: options.sourceVolumeRootPath,
                destRoot: options.destinationRoot.path
            )
            // Punch-list #3: a recovered file with no usable extension is
            // un-openable on macOS even when ffprobe decodes it. If the
            // probed container maps confidently to a canonical extension,
            // append it to the destination copy ONLY (source untouched). A
            // resulting X.mov collision is handled by the SAME mechanism as
            // every other dest collision — RelocateEngine.runOne Stage 1
            // returns .salvageFailed(.copy); we add no uniquing scheme here.
            switch Self.inferredRecoveryExtension(
                forDestinationPath: newPath,
                probedContainer: rec.container,
                enabled: options.addInferredExtensionOnRecovery
            ) {
            case .append(let appended, let fromExt, let toExt):
                let oldLeaf = (newPath as NSString).lastPathComponent
                let newLeaf = (appended as NSString).lastPathComponent
                let fromDesc = fromExt.isEmpty ? "no extension" : "extension .\(fromExt)"
                relocateLog.write("[EXT] recovered extensionless file \(oldLeaf) → \(newLeaf) (\(fromDesc); ffprobe format \"\(rec.container)\" → .\(toExt))")
                log("    + adding inferred extension .\(toExt) (\(fromDesc); container \"\(rec.container)\")")
                newPath = appended
            case .unchanged:
                break
            }
            dashboard.relocateCurrentFile = rec.filename
            // Panel tick BEFORE the copy so a long single-file copy (e.g. a
            // 16 GB master) still shows which file is in flight and holds the
            // bar at the completed count rather than going blank.
            updateJobCopyProgress(id: jobID, done: i, total: toMigrate.count,
                                  currentFile: rec.filename,
                                  bytesCopied: dashboard.relocateBytesCopied)
            log("  [\(i + 1)/\(toMigrate.count)] \(rec.filename)")
            log("    \(rec.fullPath) → \(newPath)")

            let perFileJob = RelocateJob(
                recordID: rec.id,
                sourcePath: rec.fullPath,
                destPath: newPath,
                expectedBytes: rec.sizeBytes,
                expectedPartialMD5: rec.partialMD5
            )
            let outcome = await RelocateEngine.runOne(perFileJob)
            switch outcome {
            case .success(let bytes, let newHash, let dur):
                if rec.originalFullPath == nil { rec.originalFullPath = rec.fullPath }
                if rec.originVolume == nil { rec.originVolume = rec.volumeName }
                let oldPath = rec.fullPath
                rec.fullPath = newPath
                rec.directory = (newPath as NSString).deletingLastPathComponent
                rec.partialMD5 = newHash
                // A verified copy clears a stale terminal failure left by a
                // PRIOR attempt: a record marked .salvageFailed when the
                // source drive was momentarily unreadable, now successfully
                // re-copied. Without this the record stays labeled "Salvage
                // Failed" forever despite being safely relocated — and worse,
                // could be swept up by any flow that targets salvage-failed
                // records. Fresh relocates never set archiveStage, so only
                // previously-failed records are touched. (Bug found 2026-06-19
                // after re-running the RicksBackups salvage batch: 97 files
                // copied + verified but stayed flagged Salvage Failed.)
                if rec.archiveStage == .salvageFailed {
                    rec.archiveStage = .none
                    rec.notes = appendNote(rec.notes,
                        "Migrate \(stamp()): salvage recovered — re-copied and verified")
                }
                dashboard.relocateSucceeded += 1
                dashboard.relocateBytesCopied += bytes
                log("    ✓ copied \(bytes) bytes in \(String(format: "%.1f", dur))s")
                relocateLog.write("[OK] \(oldPath) → \(newPath) (\(bytes) bytes, \(String(format: "%.2f", dur))s, hash=\(newHash.prefix(8)))")
            case .salvageFailed(let reason, let stage):
                rec.archiveStage = .salvageFailed
                // Note prefix is user-visible (rendered in FileJourneySheet),
                // so this writes "Migrate" going forward. The parser in
                // VideoScanModel+Provenance.swift still accepts the legacy
                // "Relocate" prefix so old catalogs keep rendering.
                rec.notes = appendNote(rec.notes, "Migrate \(stamp()): \(stage.rawValue) — \(reason)")
                dashboard.relocateSalvageFailed += 1
                log("    ✗ SALVAGE FAILED at \(stage.rawValue): \(reason)")
                relocateLog.write("[FAIL/\(stage.rawValue)] \(rec.fullPath) — \(reason)")
                salvageFailedPaths.append(rec.fullPath)
            }
            dashboard.relocateCompleted += 1
            // Push the per-file progress tick to the queued job so the
            // Jobs panel's bar moves. `dashboard.relocateCompleted`
            // already covers Bucket B/D/E pre-population for the
            // overall count; here we just mirror the live state onto
            // the job for the panel's local view.
            updateJobCopyProgress(
                id: jobID,
                done: i + 1,
                total: toMigrate.count,
                currentFile: rec.filename,
                bytesCopied: dashboard.relocateBytesCopied
            )
            // Debounced disk write — not per record, but frequent enough
            // that a crash loses no more than ~2s of state.
            catalogStore.scheduleSave(records: records)
        }
        catalogStore.scheduleSave(records: records)
        if canceledMidRun {
            // User canceled mid-copy. What landed is already persisted above;
            // mark the job canceled, refresh per-volume aggregates, and advance
            // the queue. No summary sheet — the user already chose to stop.
            updateJobStatus(id: jobID, status: .canceled)
            notifyVolumeAggregatesStale()
            startNextQueuedJobIfIdle()
            return
        }
        logRelocateSummary(salvageFailedPaths: salvageFailedPaths, snapshotTaken: snapshotPath != nil)

        // Fix 2 — minimum-visible padding before the summary sheet
        // pops. On a Bucket-E-heavy run with zero copies the entire
        // pipeline finishes in <100ms; pad up to 800ms so the user
        // actually sees the "Verifying audit trail…" spinner instead
        // of a flash.
        await padToMinVisible(runStart: runStart, minVisibleSeconds: minVisibleSeconds)

        // Bucket-D adoption and per-file copies rewrite `fullPath` and
        // `originalFullPath` on existing records — same array count, so
        // ContentView's count-based aggregate-cache triggers won't fire.
        // Bump the revision counter so the per-volume table totals
        // refresh now that records have moved between volume buckets.
        notifyVolumeAggregatesStale()

        // Fix 1 — set the summary sheet but do NOT call
        // `maybeOfferRetire` here. Trigger ordering: the user must
        // dismiss the summary first. The summary sheet's Done button
        // fires the retire offer instead. See ContentView wiring.
        publishSummary(
            jobID: jobID,
            options: options,
            reconcile: reconcile,
            salvageFailedPaths: salvageFailedPaths,
            snapshotPath: snapshotPath,
            elapsed: Date().timeIntervalSince(runStart)
        )
    }

    /// Pad to the min-visible window if the work finished early. Pure
    /// `Task.sleep` — no fake busy-loop, no UI tick. If the work already
    /// took longer than the budget this is a zero-cost no-op.
    private func padToMinVisible(runStart: Date,
                                  minVisibleSeconds: TimeInterval) async {
        let elapsed = Date().timeIntervalSince(runStart)
        let remaining = minVisibleSeconds - elapsed
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    /// Compose the summary payload and publish to
    /// `pendingRelocateSummary`. Caller passes in the just-finished
    /// reconcile + run telemetry; we extract witness samples from the
    /// Bucket E entries (or, on a dry-run, the same source).
    ///
    /// Driven by `@Published` so the sheet pops automatically. Also
    /// attaches the summary to the queued job and flips its status to
    /// `.awaitingDone` so the Jobs panel reflects the same state and
    /// the queue advance fires from the summary sheet's Done button.
    private func publishSummary(jobID: UUID,
                                 options: RelocateOptions,
                                 reconcile: ReconcileResult,
                                 salvageFailedPaths: [String],
                                 snapshotPath: String?,
                                 elapsed: TimeInterval) {
        let mb = Double(dashboard.relocateBytesCopied) / 1_048_576.0
        let mbps = elapsed > 0 ? mb / elapsed : 0

        let sourceName = (options.sourceVolumeRootPath as NSString).lastPathComponent
        let destFull = options.destinationRoot.path
        // Short display like "LaCieWorkspace/from-Maxtor500": last two
        // path components when available, else just the leaf.
        let destURL = options.destinationRoot
        let destLeaf = destURL.lastPathComponent
        let destParent = destURL.deletingLastPathComponent().lastPathComponent
        let destDisplay = destParent.isEmpty ? destLeaf : "\(destParent)/\(destLeaf)"

        // Cap the salvage-failed disclosure at 20 entries — same cap the
        // log block uses; full list is in relocate.log.
        let cappedFailedPaths = Array(salvageFailedPaths.prefix(20))

        let samples = Self.witnessSamples(from: reconcile.safelyRedundant, limit: 10)

        // Split safelyRedundant into "top witness is safe" vs "only
        // degraded witnesses exist." Post-2026-05-30 the reconcile gate
        // makes the latter group zero in practice (no safe witness ⇒
        // record falls to Bucket A). We still surface the split so the
        // sheet header is honest about what happened. Counting on the
        // entry — not the sample list — because samples are capped at 10.
        let backedUp = reconcile.safelyRedundant.filter {
            !$0.safeWitnesses.isEmpty
        }.count
        let degradedOnly = reconcile.safelyRedundant.count - backedUp

        let summary = RelocateSummary(
            isDryRun: options.dryRun,
            sourceVolumeName: sourceName.isEmpty ? options.sourceVolumeRootPath : sourceName,
            sourceVolumeRootPath: options.sourceVolumeRootPath,
            destinationDisplay: destDisplay,
            destinationRootPath: destFull,
            succeededCount: dashboard.relocateSucceeded,
            bytesCopied: dashboard.relocateBytesCopied,
            adoptedCount: dashboard.relocateAdopted,
            safelyRedundantCount: dashboard.relocateSafelyRedundant,
            safelyRedundantBytes: dashboard.relocateSafelyRedundantBytes,
            sourceMovesCount: dashboard.relocateSourceMoves,
            manuallyDeletedCount: dashboard.relocateManuallyDeleted,
            salvageFailedCount: dashboard.relocateSalvageFailed,
            skippedCount: dashboard.relocateSkipped,
            safelyBackedUpCount: backedUp,
            degradedOnlyCount: degradedOnly,
            salvageFailedPaths: cappedFailedPaths,
            witnessSamples: samples,
            elapsedSeconds: elapsed,
            averageMBps: mbps,
            snapshotPath: snapshotPath
        )
        pendingRelocateSummary = summary
        // Attach to the queued job and flip status. The job's summary
        // persists through .complete so the Jobs panel can re-open the
        // summary sheet later via its context menu.
        attachJobSummary(id: jobID, summary: summary)
        updateJobStatus(id: jobID, status: .awaitingDone)
    }

    /// Called from the summary sheet's Done button. Drops the summary
    /// and (as of §3 — 2026-05-31) advances the relocate queue: the
    /// `.awaitingDone` job flips to `.complete`, fires the user
    /// notification, and the next queued job starts. Without this call
    /// the queue would stall — a deliberate UX choice so the user can't
    /// miss a summary by walking away from the screen.
    ///
    /// As of 2026-05-30 this NO LONGER fires the §1B retire offer
    /// automatically — Rick asked for a quieter UX where the Volumes
    /// window is the explicit retire surface (per
    /// feedback_friendly_language.md). The `maybeOfferRetire(for:)`
    /// machinery is still here and still callable directly (tests use
    /// it; the programmatic path is fine), but the UI no longer fires
    /// it from the summary Done button.
    func acknowledgeRelocateSummary() {
        pendingRelocateSummary = nil
        advanceQueueAfterCurrent()
    }

    /// Set `pendingRetireOffer` if the source volume is 100% disposed.
    /// Internal so tests can drive the same logic directly. See
    /// docs/relocate_volume_plan.md §1B.
    func maybeOfferRetire(for volumeRootPath: String) {
        guard Self.shouldOfferRetire(volumeRootPath: volumeRootPath, in: records) else {
            return
        }
        // Skip the offer when the volume is already retired (idempotency
        // for re-running Relocate against a retired drive — rare, but
        // shouldn't double-prompt).
        if let target = scanTargets.first(where: { $0.searchPath == volumeRootPath }),
           target.isRetired {
            return
        }
        let total = Self.totalRecordsOn(volumeRootPath: volumeRootPath, in: records)
        let witnesses = Self.aggregateRetiredWitnesses(volumeRootPath: volumeRootPath, in: records)
        let volumeName = (volumeRootPath as NSString).lastPathComponent
        pendingRetireOffer = PendingRetireOffer(
            volumeRootPath: volumeRootPath,
            volumeName: volumeName.isEmpty ? volumeRootPath : volumeName,
            recordCount: total,
            suggestedReason: Self.defaultRetireReason(),
            witnesses: witnesses
        )
        log("Retire prompt: \(total) record(s) on \(volumeRootPath) are all marked deleted — offering retire.")
    }

    // MARK: - Reconcile FS walk

    /// Reconcile classify phase — designed to run OFF the main actor (see the
    /// `Task.detached` call site in `runRelocate`). Pure and `nonisolated`: it
    /// takes Sendable record projections plus a pre-built volume-safety
    /// resolver, walks the source/dest filesystems, and hashes candidate
    /// files. No `self` access and — as of Seam D — no `VideoRecord` either,
    /// so it can execute on a detached task without freezing the UI and
    /// without a non-Sendable class crossing the boundary. The caller
    /// re-materializes the returned `ReconcilePlan` into a `ReconcileResult`
    /// on the main actor; the apply phase (which mutates `VideoRecord`s)
    /// stays on the main actor.
    nonisolated private static func performReconcilePlanOffActor(
        scopeInputs: [ReconcileRecordInput],
        witnessInputs: [ReconcileRecordInput],
        options: RelocateOptions,
        resolveVolumeSafety: @escaping VolumeSafetyResolver,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> ReconcilePlan {
        let sourceFiles = enumerateFiles(at: options.sourceVolumeRootPath)
        let destFiles = enumerateFiles(at: options.destinationRoot.path)
        return RelocateReconcile.reconcilePlan(
            records: scopeInputs,
            witnesses: witnessInputs,
            sourceVolumeRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            sourceFiles: sourceFiles,
            destFiles: destFiles,
            skipDupsOnOtherVolumes: options.skipDupsOnOtherVolumes,
            skipAlreadyRelocated: options.skipAlreadyRelocated,
            resolveVolumeSafety: resolveVolumeSafety,
            hash: { FileHasher.partialMD5(path: $0) },
            progress: progress
        )
    }

    /// Sequentially-called throttle for reconcile progress (the classify
    /// loop is single-threaded, so plain vars are safe — @unchecked
    /// Sendable only because the box crosses into the detached task).
    /// UI updates ≤4 Hz; relocate.log heartbeat every 5 s (Rick's rule:
    /// long ops show honest progress in BOTH the UI and the log).
    final class ReconcileProgressThrottle: @unchecked Sendable {
        private var lastUI = Date.distantPast
        private var lastLog = Date.distantPast
        func gate() -> (ui: Bool, log: Bool) {
            let now = Date()
            let ui = now.timeIntervalSince(lastUI) >= 0.25
            if ui { lastUI = now }
            let log = now.timeIntervalSince(lastLog) >= 5.0
            if log { lastLog = now }
            return (ui, log)
        }
    }

    /// Build the witness-path → host-volume `VolumeSafety` resolver from
    /// the current `scanTargets`. Matches by longest prefix so a target
    /// at `/Volumes/MyBook` resolves a witness `/Volumes/MyBook/clip.mxf`
    /// correctly even when an unrelated target at `/Volumes/MyBook-extra`
    /// exists.
    ///
    /// Pre-computes the sorted target list once so the per-witness
    /// resolution is O(n_targets) (n_targets is ~10s, n_witnesses is the
    /// catalog size — keep this lookup tight).
    ///
    /// Worst-case footprint: one immutable `[(String, VolumeSafety)]`
    /// array sized to the active scan-target list. Fixed sub-KB allocation.
    func makeVolumeSafetyResolver() -> VolumeSafetyResolver {
        // Snapshot each target's path + role/trust/retired. Sorted descending by
        // path length so the longest-matching prefix wins on the first
        // hit. Empty paths excluded — they'd match every witness.
        let sorted = scanTargets
            .filter { !$0.searchPath.isEmpty }
            .map { (path: $0.searchPath, safety: VolumeSafety(role: $0.role, trust: $0.trust, isRetired: $0.isRetired)) }
            .sorted { $0.path.count > $1.path.count }
        return { witnessPath in
            for entry in sorted where witnessPath.hasPrefix(entry.path + "/")
                                   || witnessPath == entry.path {
                return entry.safety
            }
            return VolumeSafety.unknown
        }
    }

    nonisolated private static func enumerateFiles(at root: String) -> [ReconcileFileEntry] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        let fm = FileManager.default
        guard let it = fm.enumerator(atPath: root) else { return [] }
        var out: [ReconcileFileEntry] = []
        while let rel = it.nextObject() as? String {
            let path = (root as NSString).appendingPathComponent(rel)
            var sb = stat()
            guard stat(path, &sb) == 0 else { continue }
            // Skip directories — only files matter for size matching.
            if (sb.st_mode & S_IFMT) != S_IFREG { continue }
            out.append(.init(path: path, size: Int64(sb.st_size)))
        }
        return out
    }

    // MARK: - Snapshot

    /// Snapshot the live catalog.json into a sibling
    /// `catalog.pre-relocate.<stamp>.json`. Returns the absolute path of
    /// the snapshot on success, nil if no source catalog existed yet OR
    /// the copy threw. Path is surfaced in the post-Apply summary so
    /// Rick can click through to it in Finder.
    @discardableResult
    private func snapshotCatalogPreRelocate() -> String? {
        let dst = (catalogStore.fileLocation as NSString).deletingLastPathComponent
        let snap = (dst as NSString).appendingPathComponent("catalog.pre-relocate.\(snapshotStamp()).json")
        do {
            if FileManager.default.fileExists(atPath: catalogStore.fileLocation) {
                try FileManager.default.copyItem(atPath: catalogStore.fileLocation, toPath: snap)
                log("Pre-migrate snapshot: \(snap)")
                return snap
            }
            return nil
        } catch {
            log("⚠ Pre-migrate snapshot failed: \(error.localizedDescription) — proceeding anyway")
            return nil
        }
    }

    private func snapshotStamp() -> String {
        let fmt = ISO8601DateFormatter()
        return fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func appendNote(_ existing: String, _ msg: String) -> String {
        existing.isEmpty ? msg : existing + "\n" + msg
    }

    // MARK: - Logging

    private func logReconcileSummary(_ r: ReconcileResult) {
        log("""
          Reconcile:
            Ready to migrate:   \(r.ready.count)
            Already at dest:    \(r.adopted.count)   (adopt without copy)
            Safely redundant:   \(r.safelyRedundant.count)   (mark deleted with audit)
            Source-side moves:  \(r.sourceSideMoves.count)   (paths rewritten)
            Manually deleted:   \(r.manuallyDeleted.count)   (marked, kept for audit)
            Previously done:    \(r.previouslyRelocated.count)
        """)
    }

    private func logRelocateSummary(salvageFailedPaths: [String], snapshotTaken: Bool) {
        let mb = Double(dashboard.relocateBytesCopied) / 1_048_576.0
        let elapsed = dashboard.relocateStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let mbps = elapsed > 0 ? mb / elapsed : 0
        let savedMB = Double(dashboard.relocateSafelyRedundantBytes) / 1_048_576.0

        var failedBlock = ""
        if !salvageFailedPaths.isEmpty {
            let head = salvageFailedPaths.prefix(20).map { "    • " + $0 }.joined(separator: "\n")
            let more = salvageFailedPaths.count > 20
                ? "\n    …and \(salvageFailedPaths.count - 20) more — see ~/Library/Logs/VideoScan/relocate.log"
                : ""
            failedBlock = "\n  Salvage failed files:\n\(head)\(more)"
        }

        let snapshotHint = snapshotTaken
            ? "\n  Pre-migrate snapshot kept in app support — restore via `cp` if needed."
            : ""

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Migrate Complete
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Succeeded:        \(dashboard.relocateSucceeded)
          Adopted:          \(dashboard.relocateAdopted)
          Safely redundant: \(dashboard.relocateSafelyRedundant)   (\(String(format: "%.1f", savedMB)) MB not copied)
          Source moves:     \(dashboard.relocateSourceMoves)
          Manually deleted: \(dashboard.relocateManuallyDeleted)
          Salvage failed:   \(dashboard.relocateSalvageFailed)
          Skipped:          \(dashboard.relocateSkipped)
          Bytes copied:     \(String(format: "%.1f", mb)) MB
          Wall clock:       \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", mbps)) MB/s)\(failedBlock)\(snapshotHint)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)
        relocateLog.write("─── Migrate complete: succeeded=\(dashboard.relocateSucceeded) adopted=\(dashboard.relocateAdopted) safelyRedundant=\(dashboard.relocateSafelyRedundant) sourceMoves=\(dashboard.relocateSourceMoves) manuallyDeleted=\(dashboard.relocateManuallyDeleted) salvageFailed=\(dashboard.relocateSalvageFailed) skipped=\(dashboard.relocateSkipped) bytes=\(dashboard.relocateBytesCopied) elapsed=\(String(format: "%.1f", elapsed))s")
    }
}
