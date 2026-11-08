import Foundation

// Dedicated persistent log for Relocate runs. Lands at
// ~/Library/Logs/VideoScan/relocate.log. Outlives the in-app console,
// so post-mortems on a long overnight run are possible.
//
// IMPORTANT: PersistentLog is a no-op until `start()` is called (the
// file handle is nil until then). Earlier wiring constructed the
// instance but never opened it, so every `relocateLog.write(...)`
// silently dropped while the same lines also flowed through `log()`
// into catalog.log. Fixed in `openRelocateSession` (Fix 3): we call
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
// docs/design/relocate_volume_plan.md for the full spec.

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
    ///
    /// `source` (2026-10-11, QA round 1): the path the skip was decided FOR.
    /// The note travels with the record when a later Migrate copies or a
    /// relink moves it; only a line whose source is the record's CURRENT
    /// path means "this file, here, was skipped" (`ownSkipWitnesses`).
    /// Older lines carry no source and never count.
    nonisolated static func formatSafelyRedundantNote(stamp: String,
                                                       source: String? = nil,
                                                       witnesses: [String],
                                                       totalWitnessCount: Int) -> String {
        // Quote each witness path and join — avoids accidental field-break
        // on a literal comma in a filename. JSON-array shape, but inline.
        let quoted = witnesses.map(quoteNotePath).joined(separator: ", ")
        // nil = the pre-2026-10-11 shape (tests describing legacy notes).
        let sourceField = source.map { " source=\(quoteNotePath($0))" } ?? ""
        return "Reconcile \(stamp): reason=dup-on-other-volume\(sourceField) witnesses=[\(quoted)] totalWitnesses=\(totalWitnessCount)"
    }

    /// `"…"` with `\` → `\\`, `"` → `\"` and a newline → `\n`, so any path
    /// (a backslash in a filename, a newline that would split the note line)
    /// round-trips through `parseWitnessesFromNote` / `skipNoteSource`
    /// (QA round 2).
    nonisolated static func quoteNotePath(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// The inverse of `quoteNotePath`'s escapes for one escaped character.
    nonisolated static func unescapedNoteChar(_ ch: Character) -> Character {
        ch == "n" ? "\n" : ch
    }

    /// Build the `(source → witness)` sample list for the post-Apply
    /// summary sheet. Walks Bucket E entries and pairs each source record
    /// with the HIGHEST-RANKED safe witness in its list (post-2026-05-30
    /// safety filter; pre-filter behavior was "first witness"). Capped
    /// at `limit` so the disclosure stays readable; the full audit trail
    /// remains in the catalog notes and relocate.log.
    ///
    /// Each sample carries the host volume's role + trust so the sheet
    /// can render the `✅ LaCieWorkspace · Cloud · Reliable`
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
        // Defensive — enqueueRelocate already refuses both, but races are
        // possible: records removed between enqueue and run (empty scope),
        // or a mount changed so source and destination now overlap
        // (GH #109, job layer). Either is a clean .failed transition.
        let refusal = refuseOverlappingMigrate(source: options.sourceVolumeRootPath,
                                               destination: options.destinationRoot, when: "at start")
        guard refusal == nil, !scope.isEmpty else {
            updateJobStatus(id: jobID, status: .failed(reason: refusal ?? "no records in scope"))
            advanceQueueAfterCurrent()
            return
        }
        dashboard.resetForRelocate(total: scope.count)
        await runRelocate(scope: scope, options: options, jobID: jobID)
    }

    /// One Migrate run, in its steps: open the session log → reconcile off the
    /// main actor → (a cancel here applies nothing) → re-prove Bucket E →
    /// snapshot the catalog → apply the zero-copy buckets (or, on a dry run,
    /// only paint what they would do) → copy each ready file → summary.
    /// The source is never deleted. Each step below is one responsibility;
    /// RelocateRunCharacterizationTests pins the run end to end.
    private func runRelocate(scope: [VideoRecord],
                              options: RelocateOptions,
                              jobID: UUID) async {
        openRelocateSession(scope: scope, options: options)
        // Fix 2 — the progress sheet stays up at least `relocateMinVisible`
        // (see padToMinVisible); the clock starts here.
        let runStart = Date()
        var reconcile = await reconcileOffActor(scope: scope, options: options)

        // A cancel during reconcile (minutes on a flaky HDD) stops before
        // touching the catalog: zero changes.
        if Task.isCancelled {
            endRelocateCanceledDuringReconcile(jobID: jobID)
            return
        }
        // Prove the surviving copy at decision time (N1007-R F1): every
        // Bucket E record needs a safe witness still on disk NOW, or it goes
        // down the copy path instead.
        reproveSafelyRedundantBeforeApply(&reconcile, proof: RelocateReconcile.WitnessProof(
            independent: relocateWitnessIndependence, sourceRoot: options.sourceVolumeRootPath))

        // Bucket B presence is asked off the main actor BEFORE the snapshot,
        // so the snapshot → first mutation stretch stays await-free. A dry
        // run promises zero side effects, the snapshot file included (QA P3,
        // 2026-07-01), so it takes none.
        let bucketBPresence = await Self.bucketBPresence(for: reconcile, options: options)
        let snapshotPath: String? = options.dryRun ? nil : snapshotCatalogPreRelocate()

        // Fix 1 (dry-run mutation gate): a dry run mutates NO record; it only
        // paints the counters from the reconcile result.
        if options.dryRun {
            paintDryRunReconcileCounts(reconcile)
            await finishDryRunRelocate(reconcile, options: options, jobID: jobID, runStart: runStart)
            return
        }
        let toMigrate = applyZeroCopyBuckets(reconcile, presence: bucketBPresence)
        let copyPass = await copyEachReadyRecord(toMigrate, options: options, jobID: jobID)
        saveCatalogDebounced()   // one funnel: catalog.json, or catalog.sqlite after the switch (B2.1)
        if copyPass.canceled {
            // What landed is already persisted; no summary sheet — the user
            // already chose to stop.
            updateJobStatus(id: jobID, status: .canceled)
            notifyVolumeAggregatesStale()
            startNextQueuedJobIfIdle()
            return
        }
        logRelocateSummary(salvageFailedPaths: copyPass.salvageFailedPaths, snapshotTaken: snapshotPath != nil)
        await padToMinVisible(runStart: runStart, minVisibleSeconds: Self.relocateMinVisible)
        // Adoption and copies rewrite `fullPath` on existing records — same
        // array count, so count-based aggregate caches won't fire; bump the
        // revision so the per-volume totals refresh.
        notifyVolumeAggregatesStale()
        // Fix 1 — publish the summary but do NOT offer Retire here: the
        // user dismisses the summary first; its Done button drives the rest.
        await publishSummary(jobID: jobID, options: options, reconcile: reconcile,
                             salvageFailedPaths: copyPass.salvageFailedPaths, snapshotPath: snapshotPath,
                             elapsed: Date().timeIntervalSince(runStart))
    }

    /// Fix 2 — the least time the progress sheet stays up (a Bucket-E-only
    /// run finishes in under 100 ms and used to flash past).
    private static let relocateMinVisible: TimeInterval = 0.8

    /// Fix 3 — open relocate.log (PersistentLog is a no-op until `start`),
    /// append-mode so runs accumulate, with a session header per run.
    private func openRelocateSession(scope: [VideoRecord], options: RelocateOptions) {
        relocateLog.start(append: true)
        let host = ProcessInfo.processInfo.hostName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        relocateLog.write("── Migrate session started \(ISO8601DateFormatter().string(from: Date())) on \(host) v\(version)")
        relocateLog.write("─── Migrate started: source=\(options.sourceVolumeRootPath) dest=\(options.destinationRoot.path) scope=\(scope.count) dryRun=\(options.dryRun) skipDupsOnOtherVolumes=\(options.skipDupsOnOtherVolumes)")
    }

    /// 1A. Reconcile pre-flight, OFF the main actor: the classify phase walks
    /// the volume and reads partial hashes; on a flaky HDD that once blocked
    /// the main thread ~235 s (perf analysis 2026-06-20). Seam D: only
    /// Sendable projections (`ReconcileRecordInput`, the volume-safety
    /// resolver) cross into the detached task; the id-keyed `ReconcilePlan`
    /// comes back and is re-materialized against the live records here.
    /// Honest progress (2026-07-06): a determinate bar ≤ 4 Hz and a
    /// relocate.log heartbeat every 5 s.
    /// Memory: one Sendable input per catalog record (scope + witnesses).
    private func reconcileOffActor(scope: [VideoRecord], options: RelocateOptions) async -> ReconcileResult {
        let scopeInputs = scope.map(\.asReconcileInput)
        let witnessInputs = records.map(\.asReconcileInput)
        let resolver = makeVolumeSafetyResolver()
        let independence = relocateWitnessIndependence
        reconcileProgress = (0, scopeInputs.count)
        relocateLog.write("Reconcile: enumerating volumes, then classifying \(scopeInputs.count) record(s)…")
        let progressSink = reconcileProgressSink()
        let plan = await Task.detached(priority: .userInitiated) {
            Self.performReconcilePlanOffActor(scopeInputs: scopeInputs,
                                              witnessInputs: witnessInputs,
                                              options: options,
                                              resolveVolumeSafety: resolver,
                                              witnessIndependent: independence,
                                              progress: progressSink)
        }.value
        reconcileProgress = nil
        let reconcile = RelocateReconcile.materialize(plan, scope: scope)
        logReconcileSummary(reconcile)
        // Shared string builder with the sheet's preview (GH #162).
        relocateLog.write(ReconcileLogLines.summaryLine(reconcile))
        return reconcile
    }

    /// The classify loop's (done, total) callback, throttled: the UI bar
    /// and the relocate.log heartbeat each on their own gate, always the end.
    private func reconcileProgressSink() -> @Sendable (Int, Int) -> Void {
        let throttle = ReconcileProgressThrottle()
        return { [weak self] done, total in
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
    }

    private func endRelocateCanceledDuringReconcile(jobID: UUID) {
        relocateLog.write("Migrate canceled by user during reconcile — no changes applied.")
        log("Migrate canceled during reconcile — no changes applied.")
        updateJobStatus(id: jobID, status: .canceled)
        startNextQueuedJobIfIdle()
    }

    /// A dry run paints the counters a real run would reach, from the
    /// reconcile result alone — no record is touched. Without this the
    /// progress sheet would sit at 0 for the whole preview.
    private func paintDryRunReconcileCounts(_ reconcile: ReconcileResult) {
        dashboard.relocateManuallyDeleted = reconcile.manuallyDeleted.count
        dashboard.relocateAdopted = reconcile.adopted.count
        dashboard.relocateSafelyRedundant = reconcile.safelyRedundant.count
        dashboard.relocateSafelyRedundantBytes = reconcile.safelyRedundant.reduce(0) { $0 + $1.rec.sizeBytes }
        dashboard.relocateCompleted = reconcile.manuallyDeleted.count
            + reconcile.adopted.count
            + reconcile.safelyRedundant.count
        dashboard.relocateSourceMoves = reconcile.sourceSideMoves.count
        // The previously-relocated bucket is empty when skipAlreadyRelocated
        // is false, so no option check is needed.
        dashboard.relocateSkipped = reconcile.previouslyRelocated.count
        dashboard.relocateCompleted += dashboard.relocateSkipped
    }

    private func finishDryRunRelocate(_ reconcile: ReconcileResult, options: RelocateOptions, jobID: UUID,
                                      runStart: Date) async {
        log("[DRY RUN] No files copied. Would have migrated \(reconcile.ready.count) record(s).")
        // relocate.log keeps its name (log file paths stay the same).
        relocateLog.write("[DRY RUN] no copies; would migrate \(reconcile.ready.count) record(s)")
        logRelocateSummary(salvageFailedPaths: [], snapshotTaken: false)
        await padToMinVisible(runStart: runStart, minVisibleSeconds: Self.relocateMinVisible)
        await publishSummary(jobID: jobID, options: options, reconcile: reconcile, salvageFailedPaths: [],
                             snapshotPath: nil, elapsed: Date().timeIntervalSince(runStart))
    }

    /// The zero-copy buckets of a real run, in order: B (source not found:
    /// marked, through the presence answers asked off the main actor), D
    /// (adopt the verified copy already at the destination), E (skip — a
    /// proven copy lives elsewhere), C (follow a move inside the source,
    /// then copy), previously relocated (left alone). Returns the records to
    /// copy: Bucket A plus the followed moves. One debounced save at the end.
    private func applyZeroCopyBuckets(_ reconcile: ReconcileResult,
                                      presence: [String: JourneyPresence]) -> [VideoRecord] {
        markBucketBSourcesNotFound(reconcile.manuallyDeleted,
                                   presence: { presence[$0] ?? JourneyPresence.probe($0) })
        adoptVerifiedDestinationCopies(reconcile.adopted)
        dashboard.relocateSafelyRedundantBytes = skipSafelyRedundant(reconcile.safelyRedundant)
        let toMigrate = reconcile.ready + followSourceSideMoves(reconcile.sourceSideMoves)
        // Populated only when skipAlreadyRelocated is true (force-retry sends
        // those records through the real buckets — QA fix 2026-07-01), so
        // counting every entry keeps relocateCompleted able to reach the total.
        for r in reconcile.previouslyRelocated {
            relocateLog.write(ReconcileLogLines.previouslyRelocatedLine(path: r.fullPath))
            dashboard.relocateSkipped += 1
            dashboard.relocateCompleted += 1
        }
        saveCatalogDebounced()   // one funnel: catalog.json, or catalog.sqlite after the switch (B2.1)
        return toMigrate
    }

    /// Bucket D: the file already sits verified at its destination — stamp
    /// provenance, point the record there, skip the copy. Adoption is
    /// hash-verified, so it clears a stale `.salvageFailed` exactly like a
    /// verified copy does (the force-retry scenario).
    private func adoptVerifiedDestinationCopies(_ adopted: [(rec: VideoRecord, destPath: String)]) {
        for (r, dest) in adopted {
            if r.originalFullPath == nil { r.originalFullPath = r.fullPath }
            if r.originVolume == nil { r.originVolume = r.volumeName }
            relocateLog.write(ReconcileLogLines.adoptedLine(path: r.fullPath, dest: dest))
            r.fullPath = dest
            r.directory = (dest as NSString).deletingLastPathComponent
            r.notes = appendNote(r.notes, "Reconcile \(stamp()): adopted existing copy at dest")
            if r.archiveStage == .salvageFailed {
                r.archiveStage = .none
                r.notes = appendNote(r.notes,
                    "Migrate \(stamp()): salvage recovered — verified existing copy at dest")
            }
            dashboard.relocateAdopted += 1
            dashboard.relocateCompleted += 1
        }
    }

    /// Bucket E: safely redundant — SKIPPED, nothing more (2026-10-11). The
    /// failing source is never read or touched; the record keeps its label.
    /// A File Journey note names the witnesses (the retire check reads it,
    /// `isAccountedForRetire`) and relocate.log says so. Until 2026-10-11
    /// this stamped `.manuallyDeleted`, hiding ~950 live files behind a
    /// "deleted" label. Returns the bytes skipped.
    private func skipSafelyRedundant(_ entries: [SafelyRedundantEntry]) -> Int64 {
        var bytes: Int64 = 0
        for entry in entries {
            let r = entry.rec
            r.notes = appendNote(r.notes,
                Self.formatSafelyRedundantNote(stamp: stamp(),
                                               source: r.fullPath,
                                               witnesses: entry.witnesses,
                                               totalWitnessCount: entry.totalWitnessCount))
            relocateLog.write(ReconcileLogLines.safelyRedundantLine(path: r.fullPath,
                                                                    totalWitnessCount: entry.totalWitnessCount,
                                                                    firstWitness: entry.witnesses.first))
            dashboard.relocateSafelyRedundant += 1
            dashboard.relocateCompleted += 1
            bytes += r.sizeBytes
        }
        return bytes
    }

    /// Bucket C: the file moved inside the source volume — rewrite the path
    /// to where it is now; the record then copies like Bucket A.
    private func followSourceSideMoves(_ moves: [(rec: VideoRecord, newSourcePath: String)]) -> [VideoRecord] {
        moves.map { r, newSrc in
            relocateLog.write(ReconcileLogLines.sourceMoveLine(path: r.fullPath, newSourcePath: newSrc))
            r.fullPath = newSrc
            r.directory = (newSrc as NSString).deletingLastPathComponent
            r.notes = appendNote(r.notes, "Reconcile \(stamp()): source-side move detected")
            dashboard.relocateSourceMoves += 1
            return r
        }
    }

    /// What the copy pass leaves for the run's end.
    private struct RelocateCopyPass {
        var salvageFailedPaths: [String] = []
        var canceled = false
    }

    /// 4. Copy + verify + commit, one record at a time (RelocateEngine.runOne
    /// owns the no-clobber copy and the verify). Cancellation is cooperative,
    /// between files: everything copied so far is committed and verified and
    /// the source is untouched — a clean partial relocate. The job flips to
    /// `.copying` only when there is something to copy.
    private func copyEachReadyRecord(_ toMigrate: [VideoRecord], options: RelocateOptions,
                                     jobID: UUID) async -> RelocateCopyPass {
        var pass = RelocateCopyPass()
        if !toMigrate.isEmpty {
            updateJobStatus(id: jobID, status: .copying)
            // Seed the Jobs-panel bar at 0/total the moment copying starts.
            updateJobCopyProgress(id: jobID, done: 0, total: toMigrate.count,
                                  currentFile: toMigrate.first?.filename ?? "",
                                  bytesCopied: dashboard.relocateBytesCopied)
        }
        for (i, rec) in toMigrate.enumerated() {
            if Task.isCancelled {
                pass.canceled = true
                relocateLog.write("Migrate canceled by user after \(i) of \(toMigrate.count) file(s) copied.")
                log("Migrate canceled — stopped after \(i) of \(toMigrate.count) file(s).")
                break
            }
            let newPath = relocateDestinationPath(for: rec, options: options)
            dashboard.relocateCurrentFile = rec.filename
            // Panel tick BEFORE the copy, so a long single file still shows
            // which file is in flight.
            updateJobCopyProgress(id: jobID, done: i, total: toMigrate.count,
                                  currentFile: rec.filename,
                                  bytesCopied: dashboard.relocateBytesCopied)
            log("  [\(i + 1)/\(toMigrate.count)] \(rec.filename)")
            log("    \(rec.fullPath) → \(newPath)")
            let outcome = await RelocateEngine.runOne(RelocateJob(
                recordID: rec.id,
                sourcePath: rec.fullPath,
                destPath: newPath,
                expectedBytes: rec.sizeBytes,
                expectedPartialMD5: rec.partialMD5
            ))
            if let failedPath = applyRelocateOutcome(outcome, to: rec, newPath: newPath) {
                pass.salvageFailedPaths.append(failedPath)
            }
            dashboard.relocateCompleted += 1
            updateJobCopyProgress(id: jobID, done: i + 1, total: toMigrate.count,
                                  currentFile: rec.filename,
                                  bytesCopied: dashboard.relocateBytesCopied)
            // Debounced — a crash loses no more than ~2 s of state.
            saveCatalogDebounced()   // one funnel: catalog.json, or catalog.sqlite after the switch (B2.1)
        }
        return pass
    }

    /// Where `rec` lands: its path under the destination, keeping the layout
    /// beneath the source root. Punch-list #3: a recovered file with no
    /// usable extension gets its probed container's extension on the
    /// DESTINATION copy only (source untouched); a resulting collision is
    /// RelocateEngine's ordinary no-clobber refusal — no uniquing here.
    private func relocateDestinationPath(for rec: VideoRecord, options: RelocateOptions) -> String {
        let newPath = Self.rewrittenPath(forSourcePath: rec.fullPath,
                                         sourceRoot: options.sourceVolumeRootPath,
                                         destRoot: options.destinationRoot.path)
        guard case .append(let appended, let fromExt, let toExt) = Self.inferredRecoveryExtension(
            forDestinationPath: newPath, probedContainer: rec.container,
            enabled: options.addInferredExtensionOnRecovery) else { return newPath }
        let oldLeaf = (newPath as NSString).lastPathComponent
        let newLeaf = (appended as NSString).lastPathComponent
        let fromDesc = fromExt.isEmpty ? "no extension" : "extension .\(fromExt)"
        relocateLog.write("[EXT] recovered extensionless file \(oldLeaf) → \(newLeaf) (\(fromDesc); ffprobe format \"\(rec.container)\" → .\(toExt))")
        log("    + adding inferred extension .\(toExt) (\(fromDesc); container \"\(rec.container)\")")
        return appended
    }

    /// One file's outcome onto its record. Success: provenance stamped, the
    /// record points at the verified copy, a stale `.salvageFailed` from a
    /// PRIOR attempt cleared with a note (2026-06-19: 97 re-copied files
    /// stayed "Salvage Failed"). Failure: `.salvageFailed` with the stage
    /// and reason in a user-visible "Migrate" note; the record keeps its
    /// source path. Returns the failed source path, or nil on success.
    private func applyRelocateOutcome(_ outcome: RelocateOutcome, to rec: VideoRecord, newPath: String) -> String? {
        switch outcome {
        case .success(let bytes, let newHash, let dur):
            if rec.originalFullPath == nil { rec.originalFullPath = rec.fullPath }
            if rec.originVolume == nil { rec.originVolume = rec.volumeName }
            let oldPath = rec.fullPath
            rec.fullPath = newPath
            rec.directory = (newPath as NSString).deletingLastPathComponent
            rec.partialMD5 = newHash
            if rec.archiveStage == .salvageFailed {
                rec.archiveStage = .none
                rec.notes = appendNote(rec.notes,
                    "Migrate \(stamp()): salvage recovered — re-copied and verified")
            }
            dashboard.relocateSucceeded += 1
            dashboard.relocateBytesCopied += bytes
            log("    ✓ copied \(bytes) bytes in \(String(format: "%.1f", dur))s")
            relocateLog.write("[OK] \(oldPath) → \(newPath) (\(bytes) bytes, \(String(format: "%.2f", dur))s, hash=\(newHash.prefix(8)))")
            return nil
        case .salvageFailed(let reason, let stage):
            rec.archiveStage = .salvageFailed
            // "Migrate" prefix is user-visible (FileJourneySheet); the
            // provenance parser still accepts the legacy "Relocate".
            rec.notes = appendNote(rec.notes, "Migrate \(stamp()): \(stage.rawValue) — \(reason)")
            dashboard.relocateSalvageFailed += 1
            log("    ✗ SALVAGE FAILED at \(stage.rawValue): \(reason)")
            relocateLog.write("[FAIL/\(stage.rawValue)] \(rec.fullPath) — \(reason)")
            return rec.fullPath
        }
    }

    /// Of the Bucket E entries, how many have a backup PROVEN now
    /// (`ContentCopyProof`, Codex #150 F1/F5): a witness on a safe drive
    /// that is not marked Aging, whose catalog row carries the same
    /// whole-file SHA-256 as the source, both stamps still describing
    /// their files. The catalog half (row lookups) runs here on the main
    /// actor; the live stats run detached (a worker thread, then joined).
    /// Cost: one open+fstat per source and per candidate witness, no reads.
    /// Memory: O(entries × ≤5 witnesses) small Sendable claims.
    func provenBackupCount(_ entries: [SafelyRedundantEntry]) async -> Int {
        let claims: [RelocateClaimSet] = entries.compactMap { entry in
            guard let sourceDigest = ContentCopyProof.digest(entry.rec) else { return nil }
            let copies = entry.safeWitnesses
                .filter { $0.isSafe && $0.trust != .aging }
                .compactMap { w -> ContentCopyProof.Claim? in
                    guard let row = record(forPath: w.path), !row.isPurged,
                          let f = ContentCopyProof.digest(row) else { return nil }
                    return ContentCopyProof.Claim(path: w.path, fixity: f)
                }
            guard !copies.isEmpty else { return nil }
            return RelocateClaimSet(source: ContentCopyProof.Claim(path: entry.rec.fullPath, fixity: sourceDigest),
                                    copies: copies)
        }
        guard !claims.isEmpty else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            claims.reduce(0) { $0 + (ContentCopyProof.proven(source: $1.source, copies: $1.copies) ? 1 : 0) }
        }.value
    }

    /// Of the Bucket D adoptions, how many are PROVEN (Codex closing pass
    /// F1): the source row carries a whole-file SHA-256 on record and the
    /// adopted destination file hashes to it, fresh, now. Detached; cost =
    /// one full read of each adopted file (adoption is the rare bucket),
    /// memory one 1 MiB buffer at a time.
    /// Codex round 3: the source's stored digest counts only if its stamp
    /// still describes the SOURCE file now (captured before the path was
    /// rewritten — `reconcile.adoptionSources`; persistent digest policy,
    /// racily-clean rule included). A source that is gone or changed proves
    /// nothing, so its adoption needs attention.
    func provenAdoptedCount(_ reconcile: ReconcileResult) async -> Int {
        let pairs: [RelocateClaimSet] = reconcile.adopted.compactMap { entry in
            guard let source = reconcile.adoptionSources[entry.rec.id] else { return nil }
            return RelocateClaimSet(source: source,
                                    copies: [ContentCopyProof.Claim(path: entry.destPath, digest: source.digest,
                                                                    byteCount: source.byteCount)])
        }
        guard !pairs.isEmpty else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            pairs.reduce(0) { $0 + (ContentCopyProof.proven(source: $1.source, copies: $1.copies) ? 1 : 0) }
        }.value
    }

    /// Re-stat every Bucket E witness immediately before the apply phase.
    /// An entry whose safe witnesses are no longer on disk at the recorded
    /// size (drive unplugged, file moved, trashed or emptied since the
    /// classify pass) is NOT marked deleted: it moves to `ready` so the
    /// copy engine handles it, which itself refuses a missing source as
    /// salvage-failed rather than guessing. Logged per record.
    func reproveSafelyRedundantBeforeApply(
        _ reconcile: inout ReconcileResult,
        proof: RelocateReconcile.WitnessProof
    ) {
        guard !reconcile.safelyRedundant.isEmpty else { return }
        let split = RelocateReconcile.reproveSafelyRedundant(reconcile.safelyRedundant, proof: proof)
        for entry in split.refused {
            let line = "Reconcile: \(entry.rec.fullPath) — no safe copy is on disk now "
                + "(\(entry.witnesses.first ?? "no witness")); will copy instead of marking deleted"
            relocateLog.write(line)
            log(line)
        }
        reconcile.safelyRedundant = split.proven
        reconcile.ready.append(contentsOf: split.refused.map(\.rec))
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
                                 elapsed: TimeInterval) async {
        // Codex #150 F1/F5 and the closing pass F1: the "safe" and "retire"
        // words stand only on backups and adoptions PROVEN now (a dry run
        // proves nothing and never invites retiring).
        let provenBackups = options.dryRun ? 0 : await self.provenBackupCount(reconcile.safelyRedundant)
        let provenAdoptions = options.dryRun ? 0 : await self.provenAdoptedCount(reconcile)
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
            snapshotPath: snapshotPath,
            notMarkedCount: dashboard.relocateBucketBNotMarked,
            stillThereCount: dashboard.relocateBucketBStillThere,
            provenBackupCount: provenBackups,
            provenAdoptedCount: provenAdoptions
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
    /// docs/design/relocate_volume_plan.md §1B.
    func maybeOfferRetire(for volumeRootPath: String) {
        let retiredRoots = scanTargets.filter { $0.isRetired && !$0.searchPath.isEmpty }.map(\.searchPath)
        guard Self.shouldOfferRetire(volumeRootPath: volumeRootPath, in: records, retiredRoots: retiredRoots) else {
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
        let witnesses = Self.aggregateRetiredWitnesses(volumeRootPath: volumeRootPath, in: records,
                                                       retiredRoots: retiredRoots)
        let volumeName = (volumeRootPath as NSString).lastPathComponent
        pendingRetireOffer = PendingRetireOffer(
            volumeRootPath: volumeRootPath,
            volumeName: volumeName.isEmpty ? volumeRootPath : volumeName,
            recordCount: total,
            suggestedReason: Self.defaultRetireReason(),
            witnesses: witnesses
        )
        log("Retire prompt: \(total) record(s) on \(volumeRootPath) are all accounted for (missing, or skipped because a copy is elsewhere) — offering retire.")
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
        witnessIndependent: @escaping WitnessIndependenceProbe,
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
            witnessIndependent: witnessIndependent,
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

    /// The pre-migrate safety copy, through the ONE door every other safety
    /// copy uses (`snapshotCatalog`): under catalog.json, the in-memory
    /// records written to `catalog.pre-relocate.<stamp>.json`; under
    /// catalog.sqlite, what is in memory committed first and then a sealed
    /// `catalog.pre-relocate.<stamp>.sqlite`. Returns the path, or nil when
    /// no copy could be made (logged; Migrate proceeds, as it always has).
    ///
    /// Adversarial 2026-10-19 (MOPS-6): this used to `copyItem` the file at
    /// `catalogStore.fileLocation` — after the switch that is catalog.json as
    /// frozen at the switch, so the advertised "Pre-migrate snapshot" held
    /// none of the rows or edits made since, and restoring it would have put
    /// back the pre-switch catalog. Under JSON it also lagged memory by the
    /// save debounce.
    @discardableResult
    private func snapshotCatalogPreRelocate() -> String? {
        if let snap = snapshotCatalog(prefix: "pre-relocate") {
            log("Pre-migrate snapshot: \(snap)")
            return snap
        }
        log("⚠ Pre-migrate snapshot failed (no safety copy could be written) — proceeding anyway")
        return nil
    }

    private func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// What happened to one Bucket B row.
    enum BucketBMark: Equatable {
        /// Marked Missing / "source file not found".
        case marked
        /// The catalog refused the marker (B2.3: held / read-only
        /// catalog.sqlite); NOTHING was written.
        case refused(String)
        /// Something is at the path — not marked.
        case stillThere
        /// The disk would not say (I/O error, permission, volume away) —
        /// not marked; the reason in the system's words.
        case couldNotCheck(String)
    }

    /// Bucket B — Migrate could not match the source file. GH #143: the one
    /// removal marker says Missing (through the engine). The legacy
    /// `.manuallyDeleted` label is still written beside it because Retire's
    /// "disposed" rule reads it; retiring the label waits on Rick's sign-off
    /// for the 959 classification. Plus the audit note and the relocate log
    /// line, as before.
    ///
    /// Truth first (adversarial 2026-10-19, MOPS-7): Bucket B is "no other
    /// bucket fit", NOT "the file is absent" — a file edited in place (new
    /// size), or one whose partial-MD5 sample could not be read, lands here
    /// too. So the disk is asked: only "nothing is there" (ENOENT / ENOTDIR,
    /// or a link to nothing) marks. A file at the path, or a disk that would
    /// not answer, leaves the row exactly as it was.
    private func markSourceNotFound(_ r: VideoRecord, presence: JourneyPresence) -> BucketBMark {
        switch presence {
        case .missing, .brokenLink:
            break
        case .regularFile, .regularFileThroughLink, .linkToFile, .notAFile:
            return .stillThere
        case .unknown(let reason), .linkTargetUnknown(_, let reason):
            return .couldNotCheck(reason)
        case .volumeOffline(let volume):
            return .couldNotCheck("\(volume) is not connected")
        }
        if r.removal == nil,
           let why = Self.stampRemoval(r, .missing(noticedAt: Date(), lastSeen: nil, reason: .missingAtMigrate)) {
            return .refused(why)
        }
        r.archiveStage = .manuallyDeleted
        r.notes = appendNote(r.notes, "Reconcile \(stamp()): source file not found")
        relocateLog.write(ReconcileLogLines.manuallyDeletedLine(path: r.fullPath))
        return .marked
    }

    /// Ask the disk about every Bucket B source path OFF the main actor (an
    /// lstat per row plus the ancestor-link walk; on the failing drive
    /// Migrate is built for, a stat can be slow and the UI must not wait).
    /// The presence answers the apply phase needs: none for a dry run (it
    /// writes nothing, so it asks the drive nothing).
    static func bucketBPresence(for reconcile: ReconcileResult, options: RelocateOptions) async -> [String: JourneyPresence] {
        guard !options.dryRun else { return [:] }
        return await probeBucketBPresence(reconcile.manuallyDeleted.map(\.fullPath))
    }

    nonisolated static func probeBucketBPresence(_ paths: [String]) async -> [String: JourneyPresence] {
        await Task.detached(priority: .userInitiated) {
            var out: [String: JourneyPresence] = [:]
            out.reserveCapacity(paths.count)
            for path in paths where out[path] == nil { out[path] = JourneyPresence.probe(path) }
            return out
        }.value
    }

    /// Bucket B for a real run: mark each row whose source is not there.
    /// `relocateManuallyDeleted` counts only the rows actually marked. A row
    /// left unmarked still moves the progress bar (`relocateCompleted`) and
    /// is said ONCE per kind, as a count with the first reason, on the
    /// console and in relocate.log — never one line per row (adversarial
    /// 2026-10-18 #9). Refused rows count in `relocateBucketBNotMarked`;
    /// rows still on disk, or not checkable, in `relocateBucketBStillThere`
    /// (adversarial 2026-10-19) — both reach the closing summary.
    /// `presence` is injectable for tests; the live run passes answers it
    /// probed off the main actor.
    func markBucketBSourcesNotFound(_ rows: [VideoRecord],
                                    presence: (String) -> JourneyPresence = { JourneyPresence.probe($0) }) {
        var refused = 0, there = 0, unchecked = 0
        var firstRefusal: String?, firstUnchecked: String?
        for r in rows {
            switch markSourceNotFound(r, presence: presence(r.fullPath)) {
            case .marked:
                dashboard.relocateManuallyDeleted += 1
            case .refused(let why):
                refused += 1
                if firstRefusal == nil { firstRefusal = why }
            case .stillThere:
                there += 1
            case .couldNotCheck(let why):
                unchecked += 1
                if firstUnchecked == nil { firstUnchecked = why }
            }
            dashboard.relocateCompleted += 1
        }
        dashboard.relocateBucketBNotMarked += refused
        dashboard.relocateBucketBStillThere += there + unchecked
        if let firstRefusal {
            let line = "Reconcile: \(refused) row(s) whose source was not found were NOT marked Missing — \(firstRefusal). The next Reconcile asks again."
            log("  " + line)
            relocateLog.write(line)
        }
        if there + unchecked > 0 {
            var detail = "\(there) file(s) there"
            if let firstUnchecked { detail += "; \(unchecked) could not be checked: \(firstUnchecked)" }
            let line = "Reconcile: \(there + unchecked) row(s) Migrate could not match were NOT marked \"source file not found\" and not copied — still at their path, or the disk would not say (\(detail)). Rescan the drive, then Migrate again."
            log("  " + line)
            relocateLog.write(line)
        }
    }

    private func appendNote(_ existing: String, _ msg: String) -> String {
        existing.isEmpty ? msg : existing + "\n" + msg
    }

    // MARK: - Logging

    private func logReconcileSummary(_ r: ReconcileResult) {
        log("""
          Reconcile:
            Ready to migrate:   \(r.ready.count)
            Already at dest:    \(r.adopted.count)   (adopt without copy)
            Safely redundant:   \(r.safelyRedundant.count)   (skip — copy elsewhere, file untouched)
            Source-side moves:  \(r.sourceSideMoves.count)   (paths rewritten)
            Manually deleted:   \(r.manuallyDeleted.count)   (marked, kept for audit)
            Previously done:    \(r.previouslyRelocated.count)
        """)
    }

    /// Write a sheet-side "Reconcile preview" to relocate.log (GH #162,
    /// 2026-08-18). Same summary + per-file lines as the live run above,
    /// every one prefixed `[PREVIEW]` so it can never be read as a
    /// committed decision. `relocateLog` is file-private to this
    /// extension, hence the model-level entry point; RelocateSheet calls
    /// it back on the main actor AFTER its cancellation check, so a
    /// superseded/cancelled preview logs nothing.
    ///
    /// Session handling: writes are silent no-ops until `start(append:)`
    /// has run (Fix 3 above), so we open the file only if no session is
    /// open yet. Preview → preview reuses the open handle (no repeated
    /// "started" headers); preview → LIVE run does NOT — `runRelocate`
    /// unconditionally calls `start(append:)` and stamps its own session
    /// header, as it always has. A one-line `[PREVIEW] session` marker
    /// separates previews in the log.
    ///
    /// Main-actor cost (QA, 2026-08-18): the `[String]` is built HERE
    /// (cheap — string interpolation over the plan) and then written
    /// OFF-main in one `writeBatch` — one lock, one write, one fsync.
    /// The old per-line `write` did DateFormatter + write + fsync per
    /// record on the main actor; at whole-volume scale (thousands–100k
    /// records) that is a beachball. `relocateLog` is `@unchecked
    /// Sendable` and the lines are plain Strings, so the detached task
    /// carries nothing actor-bound.
    func logReconcilePreview(_ reconcile: ReconcileResult,
                             sourceVolumeRootPath: String,
                             destinationRoot: URL) {
        if !relocateLog.isOpen { relocateLog.start(append: true) }
        var lines = ["── [PREVIEW] session \(stamp()) source=\(sourceVolumeRootPath) dest=\(destinationRoot.path)"]
        lines += ReconcileLogLines.allLines(reconcile,
                                            prefix: ReconcileLogLines.previewPrefix,
                                            source: sourceVolumeRootPath,
                                            dest: destinationRoot.path)
        Task.detached(priority: .utility) {
            relocateLog.writeBatch(lines)
        }
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

        let lines = relocateClosingSummaryLines(elapsed: elapsed, savedMB: savedMB, mb: mb, mbps: mbps,
                                                failedBlock: failedBlock, snapshotHint: snapshotHint)
        log(lines.console)
        relocateLog.write(lines.log)
    }

    /// The closing block (console) and the "Migrate complete:" line
    /// (relocate.log), built from the dashboard counters. Internal so tests
    /// can read the words without running a whole Migrate.
    func relocateClosingSummaryLines(elapsed: Double, savedMB: Double, mb: Double, mbps: Double,
                                     failedBlock: String = "", snapshotHint: String = "") -> (console: String, log: String) {
        // Bucket B rows left unmarked, only when there are any, so the
        // categories add up to the total (adversarial 2026-10-19).
        var bucketBRows = ""
        if dashboard.relocateBucketBNotMarked > 0 {
            bucketBRows += "\n  Not marked:       \(dashboard.relocateBucketBNotMarked)   (the catalog could not save — the next Reconcile asks again)"
        }
        if dashboard.relocateBucketBStillThere > 0 {
            bucketBRows += "\n  Still at path:    \(dashboard.relocateBucketBStillThere)   (not matched, not marked, not copied — rescan, then Migrate again)"
        }
        let console = """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Migrate Complete
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Succeeded:        \(dashboard.relocateSucceeded)
          Adopted:          \(dashboard.relocateAdopted)
          Safely redundant: \(dashboard.relocateSafelyRedundant)   (\(String(format: "%.1f", savedMB)) MB not copied)
          Source moves:     \(dashboard.relocateSourceMoves)
          Manually deleted: \(dashboard.relocateManuallyDeleted)\(bucketBRows)
          Salvage failed:   \(dashboard.relocateSalvageFailed)
          Skipped:          \(dashboard.relocateSkipped)
          Bytes copied:     \(String(format: "%.1f", mb)) MB
          Wall clock:       \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", mbps)) MB/s)\(failedBlock)\(snapshotHint)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """
        let line = "─── Migrate complete: succeeded=\(dashboard.relocateSucceeded) adopted=\(dashboard.relocateAdopted) safelyRedundant=\(dashboard.relocateSafelyRedundant) sourceMoves=\(dashboard.relocateSourceMoves) manuallyDeleted=\(dashboard.relocateManuallyDeleted) notMarked=\(dashboard.relocateBucketBNotMarked) stillThere=\(dashboard.relocateBucketBStillThere) salvageFailed=\(dashboard.relocateSalvageFailed) skipped=\(dashboard.relocateSkipped) bytes=\(dashboard.relocateBytesCopied) elapsed=\(String(format: "%.1f", elapsed))s"
        return (console, line)
    }
}
