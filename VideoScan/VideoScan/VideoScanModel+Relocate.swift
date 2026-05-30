import Foundation

// Dedicated persistent log for Relocate runs. Lands at
// ~/Library/Logs/VideoScan/relocate.log. Outlives the in-app console,
// so post-mortems on a long overnight run are possible.
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
    /// previously salvage-failed records that you've since worked around.
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
    /// Matching uses a trailing slash so `/Volumes/Mini2TB-backup` does
    /// not false-match `/Volumes/Mini2TB`.
    nonisolated static func recordsScoped(to sourceVolumeRootPath: String,
                                          in all: [VideoRecord]) -> [VideoRecord] {
        let prefix = sourceVolumeRootPath.hasSuffix("/")
            ? sourceVolumeRootPath
            : sourceVolumeRootPath + "/"
        return all.filter { $0.fullPath.hasPrefix(prefix) }
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

    // MARK: - Public entry

    /// Kick off a Relocate Volume run. Fire-and-forget — sets
    /// `isRelocating = true` and spawns a Task that does reconcile →
    /// snapshot → per-record copy → catalog mutation → summary.
    /// Refuses to start when `isReadOnly`, already running, or scope
    /// is empty.
    func relocateVolume(_ options: RelocateOptions) {
        guard !isReadOnly else {
            log("Relocate refused: read-only viewer mode.")
            return
        }
        guard !isRelocating else {
            log("Relocate refused: already running.")
            return
        }

        let scope = Self.recordsScoped(to: options.sourceVolumeRootPath, in: records)
        guard !scope.isEmpty else {
            log("Relocate: no catalogued files under \(options.sourceVolumeRootPath).")
            return
        }

        isRelocating = true
        dashboard.resetForRelocate(total: scope.count)
        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Relocate Volume — \(options.sourceVolumeRootPath)
          → \(options.destinationRoot.path)
          (\(scope.count) catalogued file(s))
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRelocate(scope: scope, options: options)
            self.isRelocating = false
        }
    }

    // MARK: - Run

    private func runRelocate(scope: [VideoRecord], options: RelocateOptions) async {
        relocateLog.write("─── Relocate started: source=\(options.sourceVolumeRootPath) dest=\(options.destinationRoot.path) scope=\(scope.count) dryRun=\(options.dryRun) skipDupsOnOtherVolumes=\(options.skipDupsOnOtherVolumes)")

        // 1A. Reconcile pre-flight.
        let reconcile = performReconcile(scope: scope, options: options)
        logReconcileSummary(reconcile)
        relocateLog.write("Reconcile: ready=\(reconcile.ready.count) adopted=\(reconcile.adopted.count) sourceMoves=\(reconcile.sourceSideMoves.count) safelyRedundant=\(reconcile.safelyRedundant.count) manuallyDeleted=\(reconcile.manuallyDeleted.count) previouslyRelocated=\(reconcile.previouslyRelocated.count)")

        // Track salvageFailed for the final summary block.
        var salvageFailedPaths: [String] = []

        // Snapshot catalog.json before any mutation.
        snapshotCatalogPreRelocate()

        // Apply zero-copy mutations: Bucket B (manuallyDeleted),
        // Bucket C (rewrite path then queue for migration),
        // Bucket D (adopt — stamp provenance, skip copy),
        // Bucket E (safelyRedundant — mark as manuallyDeleted with witness audit).
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
            dashboard.relocateAdopted += 1
            dashboard.relocateCompleted += 1
        }
        // Bucket E: safely redundant. Catalog-only mark-as-deleted with
        // structured audit trail. Source file is NEVER touched — the
        // failing drive doesn't get another read. Same disposition
        // mutation as Bucket B so the snapshot rollback path treats them
        // identically (restore archiveStage + notes from snapshot copy).
        var safelyRedundantBytes: Int64 = 0
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
        // Bucket C: rewrite path to the in-source new location THEN
        // queue for migration (treat as Bucket A from here on).
        var toMigrate: [VideoRecord] = reconcile.ready
        for (r, newSrc) in reconcile.sourceSideMoves {
            relocateLog.write("[RECONCILE] source-move: \(r.fullPath) → \(newSrc)")
            r.fullPath = newSrc
            r.directory = (newSrc as NSString).deletingLastPathComponent
            r.notes = appendNote(r.notes, "Reconcile \(stamp()): source-side move detected")
            dashboard.relocateSourceMoves += 1
            toMigrate.append(r)
        }
        // Previously-relocated short-circuit
        for r in reconcile.previouslyRelocated where options.skipAlreadyRelocated {
            relocateLog.write("[RECONCILE] previously-relocated, skipping: \(r.fullPath)")
            dashboard.relocateSkipped += 1
            dashboard.relocateCompleted += 1
            _ = r  // record left alone
        }
        catalogStore.scheduleSave(records: records)

        if options.dryRun {
            log("[DRY RUN] No files copied. Would have migrated \(toMigrate.count) record(s).")
            relocateLog.write("[DRY RUN] no copies; would migrate \(toMigrate.count) record(s)")
            logRelocateSummary(salvageFailedPaths: [])
            return
        }

        // 4. Per-record copy + verify + commit.
        for (i, rec) in toMigrate.enumerated() {
            let newPath = Self.rewrittenPath(
                forSourcePath: rec.fullPath,
                sourceRoot: options.sourceVolumeRootPath,
                destRoot: options.destinationRoot.path
            )
            dashboard.relocateCurrentFile = rec.filename
            log("  [\(i + 1)/\(toMigrate.count)] \(rec.filename)")
            log("    \(rec.fullPath) → \(newPath)")

            let job = RelocateJob(
                recordID: rec.id,
                sourcePath: rec.fullPath,
                destPath: newPath,
                expectedBytes: rec.sizeBytes,
                expectedPartialMD5: rec.partialMD5
            )
            let outcome = await RelocateEngine.runOne(job)
            switch outcome {
            case .success(let bytes, let newHash, let dur):
                if rec.originalFullPath == nil { rec.originalFullPath = rec.fullPath }
                if rec.originVolume == nil { rec.originVolume = rec.volumeName }
                let oldPath = rec.fullPath
                rec.fullPath = newPath
                rec.directory = (newPath as NSString).deletingLastPathComponent
                rec.partialMD5 = newHash
                dashboard.relocateSucceeded += 1
                dashboard.relocateBytesCopied += bytes
                log("    ✓ copied \(bytes) bytes in \(String(format: "%.1f", dur))s")
                relocateLog.write("[OK] \(oldPath) → \(newPath) (\(bytes) bytes, \(String(format: "%.2f", dur))s, hash=\(newHash.prefix(8)))")
            case .salvageFailed(let reason, let stage):
                rec.archiveStage = .salvageFailed
                rec.notes = appendNote(rec.notes, "Relocate \(stamp()): \(stage.rawValue) — \(reason)")
                dashboard.relocateSalvageFailed += 1
                log("    ✗ SALVAGE FAILED at \(stage.rawValue): \(reason)")
                relocateLog.write("[FAIL/\(stage.rawValue)] \(rec.fullPath) — \(reason)")
                salvageFailedPaths.append(rec.fullPath)
            }
            dashboard.relocateCompleted += 1
            // Debounced disk write — not per record, but frequent enough
            // that a crash loses no more than ~2s of state.
            catalogStore.scheduleSave(records: records)
        }
        catalogStore.scheduleSave(records: records)
        logRelocateSummary(salvageFailedPaths: salvageFailedPaths)

        // §1B Retire Volume offer. If every catalogued record on the
        // source volume is now `.manuallyDeleted` (Bucket B + Bucket E
        // disposed 100%), surface the retire modal. Pure check; no
        // mutation here — the user clicks Retire / Skip from the sheet.
        maybeOfferRetire(for: options.sourceVolumeRootPath)
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

    private func performReconcile(scope: [VideoRecord],
                                  options: RelocateOptions) -> ReconcileResult {
        let sourceFiles = enumerateFiles(at: options.sourceVolumeRootPath)
        let destFiles = enumerateFiles(at: options.destinationRoot.path)
        return RelocateReconcile.reconcile(
            records: scope,
            allCatalogRecords: records,
            sourceVolumeRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            sourceFiles: sourceFiles,
            destFiles: destFiles,
            skipDupsOnOtherVolumes: options.skipDupsOnOtherVolumes,
            hash: { FileHasher.partialMD5(path: $0) }
        )
    }

    private func enumerateFiles(at root: String) -> [ReconcileFileEntry] {
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

    private func snapshotCatalogPreRelocate() {
        let dst = (catalogStore.fileLocation as NSString).deletingLastPathComponent
        let snap = (dst as NSString).appendingPathComponent("catalog.pre-relocate.\(snapshotStamp()).json")
        do {
            if FileManager.default.fileExists(atPath: catalogStore.fileLocation) {
                try FileManager.default.copyItem(atPath: catalogStore.fileLocation, toPath: snap)
                log("Pre-relocate snapshot: \(snap)")
            }
        } catch {
            log("⚠ Pre-relocate snapshot failed: \(error.localizedDescription) — proceeding anyway")
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

    private func logRelocateSummary(salvageFailedPaths: [String]) {
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

        let snapshotHint = "\n  Pre-relocate snapshot kept in app support — restore via `cp` if needed."

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Relocate Complete
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
        relocateLog.write("─── Relocate complete: succeeded=\(dashboard.relocateSucceeded) adopted=\(dashboard.relocateAdopted) safelyRedundant=\(dashboard.relocateSafelyRedundant) sourceMoves=\(dashboard.relocateSourceMoves) manuallyDeleted=\(dashboard.relocateManuallyDeleted) salvageFailed=\(dashboard.relocateSalvageFailed) skipped=\(dashboard.relocateSkipped) bytes=\(dashboard.relocateBytesCopied) elapsed=\(String(format: "%.1f", elapsed))s")
    }
}
