import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Whole-shebang Bundle Import / Export
//
// The bundle format (see BundleExportImport.swift) wraps catalog +
// per-volume metadata + machine-portable PersonFinderSettings + the
// entire POI tree (profiles + reference photos) in a single
// `<name>.videoscanbundle/` directory. Goal: after pulling the latest
// code on the MBP and importing a bundle from the Mac Studio, the two
// machines look identical to the user.
//
// Split out from VideoScanModel.swift during the 2026-05 size-cap
// refactor — the JSON-only catalog import/export lives in
// VideoScanModel+CatalogImportExport.swift; this file is everything
// extra that the bundle format adds on top (POIs, audit log,
// confirmation dialogs).

extension VideoScanModel {

    /// Parent folder of the last successful backup, iff that folder still
    /// exists as a directory — used to pre-aim the save panel so the
    /// nagged user's flow is: click badge (or ⌘E), press Return, done.
    /// Returns nil when there's no prior backup or its folder is gone
    /// (drive ejected, folder deleted) so the panel falls back to its
    /// own default.
    ///
    /// Pure given (path, FileManager) so tests can drive it with temp
    /// dirs. `nonisolated` ≈ opting this static out of the class's
    /// @MainActor lock — in C++ terms, a free function that merely
    /// lives in the class's namespace and touches no member state.
    nonisolated static func defaultBackupDirectory(
        lastBackupPath: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let path = lastBackupPath, !path.isEmpty else { return nil }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return parent
    }

    /// UI entry point: show a save panel, write the bundle, summarize.
    /// Single backup code path — both File ▸ Back Up Catalog… (⌘E) and
    /// the catalog-header backup badge land here.
    func exportBundleViaPanel() {
        let panel = NSSavePanel()
        panel.title = "Back Up Catalog"
        panel.message = "Save a backup containing the catalog, volume metadata, settings, and reference photos for every person."
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.directory]
        let host = CatalogHost.currentName.replacingOccurrences(of: " ", with: "_")
        // Date AND time in the suggested name (Rick 2026-08-14): a second
        // same-day backup used to collide with the first, and replacing a
        // DIRECTORY bundle in an iCloud folder trips iCloud's
        // delete-then-copy semantics — the user got an error and had to
        // pick a new place. Unique-per-minute names never enter the
        // overwrite path at all.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        panel.nameFieldStringValue = "VideoScan_\(host)_\(df.string(from: Date())).videoscanbundle"
        // Default to wherever the last backup landed (when that folder
        // still exists) so repeat backups are click → Return → done.
        if let dir = Self.defaultBackupDirectory(lastBackupPath: lastBackupPath) {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // NSSavePanel can drop our extension if the user retypes the name.
        if url.pathExtension != "videoscanbundle" {
            url = url.appendingPathExtension("videoscanbundle")
        }
        do {
            let summary = try BundleExporter.writeBundle(records: records,
                                                         scanTargets: scanTargets,
                                                         to: url)
            // Stamp the backup-status badge — see VideoScanModel.lastBackupAt.
            // Doing this on the success path only so a thrown error doesn't
            // claim a backup that didn't complete.
            recordBackupSuccess(at: url)
            let m = summary.manifest
            // BundleExporter.writeBundle strips purged records before encoding.
            // Surface the excluded count so the local-only purge state is
            // discoverable in the log (matches CSV export logging).
            let excluded = records.count - m.counts.records
            if excluded > 0 {
                log("Exported bundle to \(url.lastPathComponent) — " +
                    "\(m.counts.records) records (\(excluded) removed records excluded), " +
                    "\(m.counts.volumes) volumes, " +
                    "\(m.counts.people) people, \(m.counts.referencePhotos) photos, " +
                    "\(BundleSize.human(m.sizes.totalBytes)).")
            } else {
                log("Exported bundle to \(url.lastPathComponent) — " +
                    "\(m.counts.records) records, \(m.counts.volumes) volumes, " +
                    "\(m.counts.people) people, \(m.counts.referencePhotos) photos, " +
                    "\(BundleSize.human(m.sizes.totalBytes)).")
            }
            // Surface export warnings (typically dangling symlinks) so Rick
            // knows the bundle is missing a few photos. Logged individually
            // for the audit trail; summarized in the alert.
            for w in summary.exportWarnings {
                log("Export warning: \(w.path) — \(w.reason)")
            }
            let warningsBlurb: String
            if summary.exportWarnings.isEmpty {
                warningsBlurb = ""
            } else {
                let preview = summary.exportWarnings.prefix(5)
                    .map { "  – \($0.path): \($0.reason)" }
                    .joined(separator: "\n")
                let more = summary.exportWarnings.count > 5
                    ? "\n  – …and \(summary.exportWarnings.count - 5) more (see log)"
                    : ""
                warningsBlurb = """


                Warnings (\(summary.exportWarnings.count)):
                \(preview)\(more)
                """
            }
            // Loud banner when ANY POI shipped without a valid profile.json —
            // that means the bundle is not safely importable on another Mac
            // (which is the bug that motivated this validator). Surfaced
            // ABOVE the normal counts so Rick can't miss it.
            let missingProfileBanner: String
            let missing = summary.missingProfileJSONCount
            if missing > 0 {
                let plural = missing == 1 ? "" : "s"
                missingProfileBanner =
                    "\u{26A0}\u{FE0F} \(missing) POI\(plural) shipped without profile.json — re-export recommended\n\n"
            } else {
                missingProfileBanner = ""
            }
            let alert = NSAlert()
            alert.messageText = "Backup Complete"
            let deltaLines = m.counts.dossierDeltaLines ?? 0
            let deltaBytes = m.sizes.dossierDeltaBytes ?? 0
            let deltaLine: String
            if deltaLines > 0 {
                deltaLine = "\n• \(deltaLines) dossier delta line(s) (\(BundleSize.human(deltaBytes))) — JSONL backup of expensive compute"
            } else {
                deltaLine = "\n• Dossier delta JSONLs: not bundled (delta dir unavailable — bundle still has catalog dossier fields)"
            }
            alert.informativeText = """
            \(missingProfileBanner)Saved \(url.lastPathComponent)

            • \(m.counts.records) catalog record(s)
            • \(m.counts.volumes) volume(s)
            • \(m.counts.people) person profile(s) with \(m.counts.referencePhotos) reference photo(s)\(deltaLine)
            • Total size: \(BundleSize.human(m.sizes.totalBytes)) (photos: \(BundleSize.human(m.sizes.referencePhotoBytes)))\(warningsBlurb)
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            // Backup is when the user is already caring for the catalog —
            // the right moment to nag about retired volumes still carrying
            // records (Rick 2026-08-14; the prompt performs the deletion).
            promptRetiredCatalogCleanup()
        } catch {
            log("Bundle export failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// UI entry point: show an open panel, parse the bundle, ask for
    /// confirmation, then merge into live state.
    ///
    /// POI install is `async` (iCloud materialization polls in the
    /// background). The open/confirm panels and the final alert run on the
    /// main actor; the polling loop is `await`ed off the main thread.
    func importBundleViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Catalog"
        panel.message = "Choose a VideoScan backup (.videoscanbundle) from another Mac."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let payload: BundleImporter.Payload
        do {
            payload = try BundleImporter.read(from: url)
        } catch {
            log("Bundle import failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
            return
        }

        // Confirmation dialog — bundles can be sizeable and this overwrites
        // POI folders, so make the user opt in deliberately.
        let confirm = NSAlert()
        confirm.messageText = "Import This Catalog Backup?"
        confirm.informativeText = """
        From: \(payload.manifest.exportedFromHost) on \(Self.shortDate(payload.manifest.exportedAt))
        App: v\(payload.manifest.appVersion) build \(payload.manifest.appBuild)

        • \(payload.manifest.counts.records) catalog record(s)
        • \(payload.manifest.counts.volumes) volume(s) of metadata
        • \(payload.manifest.counts.people) person profile(s) (\(payload.manifest.counts.referencePhotos) photo(s))

        Catalog records merge by content identity (no duplicates). \
        Volume metadata for matching paths is overwritten. \
        For each person, the version with MORE reference photos wins \
        (ties broken by newest first) — but details like birthdays and \
        notes are kept from both copies either way. Replaced POI folders \
        are moved to ~/dev/VideoScan/.trash/ for recovery.
        """
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else {
            log("Bundle import canceled.")
            return
        }

        // Hand off to async — POI install does iCloud polling that must not
        // block the main actor. The Task is @MainActor-isolated so we can
        // mutate model state safely; awaits inside hop to background work.
        // Swift's `Task { @MainActor in … }` ≈ "post this to the UI thread".
        Task { @MainActor in
            let result = await applyBundlePayload(payload, bundleURL: url)
            self.log("Imported bundle from \(payload.manifest.exportedFromHost): " +
                "\(result.recordsAdded) new records, \(result.recordsSkipped) duplicates skipped, " +
                "\(result.volumesUpdated) volume(s) updated, \(result.volumesAdded) added, " +
                "\(result.peopleInstalled.count) person profile(s) installed, " +
                "\(result.peopleSkipped.count) skipped, \(result.peopleFailed.count) failed, " +
                "\(result.peopleFieldMerged.count) with details filled in from the other copy.")

            // Build the user-visible alert body with all the POI buckets,
            // plus the audit log path.
            let installedLine = Self.formatPOIBucket(label: "Installed",
                                                     count: result.peopleInstalled.count,
                                                     names: result.peopleInstalled)
            let skippedLine = Self.formatPOIBucket(label: "Skipped (local copy preferred)",
                                                   count: result.peopleSkipped.count,
                                                   names: result.peopleSkipped.map { $0.name })
            let mergedLine = Self.formatFieldMerges(result.peopleFieldMerged)
            let failedLine = Self.formatPOIFailures(result.peopleFailed)
            var body = """
            Imported from \(url.lastPathComponent).

            • \(result.recordsAdded) new catalog record(s) (skipped \(result.recordsSkipped) already here)
            • \(result.volumesUpdated) volume(s) updated, \(result.volumesAdded) new volume(s) added
            • \(installedLine)
            • \(skippedLine)
            • \(mergedLine)
            """
            if !failedLine.isEmpty {
                body += "\n• \(failedLine)"
            }
            if let auditURL = result.auditLogURL {
                body += "\n\nAudit log: \(auditURL.path)"
            }
            body += "\n\nPerson Finder settings will take effect after relaunching VideoScan."

            let done = NSAlert()
            done.messageText = "Backup Imported"
            done.informativeText = body
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    struct BundleImportResult {
        var recordsAdded: Int
        var recordsSkipped: Int
        var volumesUpdated: Int
        var volumesAdded: Int
        /// POI folder names that won and were installed.
        var peopleInstalled: [String]
        /// POI folder names where the local copy was preferred (reason).
        var peopleSkipped: [(name: String, reason: String)]
        /// POI folder names that errored during materialize/copy/validate.
        var peopleFailed: [(name: String, reason: String)]
        /// POIs where identity details (birthdate, notes, …) from the losing
        /// side filled gaps on the winning side — the 2026-07-10 lost-birthdate
        /// fix. Surfaced in the alert so merges never hide in the log again.
        var peopleFieldMerged: [(name: String, fields: [String])]
        /// Path to the per-import audit log under ~/Library/Logs/VideoScan/.
        /// nil only if writing the log itself failed.
        var auditLogURL: URL?

        /// Back-compat shim: callers / tests that asked for `peopleInstalled`
        /// as an Int can use this. The new structured form is preferred.
        var peopleInstalledCount: Int { peopleInstalled.count }
    }

    /// Merge a parsed bundle payload into live model state. Async because
    /// POI install does iCloud-aware polling. Separated from
    /// `importBundleViaPanel` so tests can call it directly.
    @discardableResult
    func applyBundlePayload(_ payload: BundleImporter.Payload,
                            bundleURL: URL) async -> BundleImportResult {
        // Catalog — seed identity set from existing records, dedup on insert.
        var seen = Set<String>()
        for rec in records {
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
        }
        let effectiveHost = payload.catalog.savedFromHost.isEmpty
            ? payload.manifest.exportedFromHost
            : payload.catalog.savedFromHost
        var added = 0
        var skipped = 0
        for rec in payload.catalog.records {
            if let key = Self.identityKey(for: rec), seen.contains(key) {
                skipped += 1
                continue
            }
            if rec.sourceHost.isEmpty {
                rec.sourceHost = effectiveHost
            }
            records.append(rec)
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
            added += 1
        }
        let invalidPairEndpoints = CorrelationScorer.revalidateExistingPairs(in: records)
        if invalidPairEndpoints > 0 {
            log("Bundle import released \(invalidPairEndpoints) invalid persisted A/V pair endpoint(s).")
        }

        // Volumes — overwrite metadata on path match; add as offline target
        // when the path isn't present locally so the volume shows up in the
        // sidebar (grayed out until the drive is connected on this Mac).
        var updated = 0
        var addedVolumes = 0
        // Screen the RAM-disk scratch volume — the exporter has excluded it
        // since 2026-05, but bundles written by older builds may still
        // carry a VideoScan_Temp snapshot.
        for snap in payload.volumes.volumes where !CatalogScanTarget.isScratchVolumePath(snap.searchPath) {
            if let existing = scanTargets.first(where: { $0.searchPath == snap.searchPath }) {
                applyVolumeSnapshot(snap, to: existing)
                updated += 1
            } else {
                let t = CatalogScanTarget(searchPath: snap.searchPath)
                applyVolumeSnapshot(snap, to: t)
                scanTargets.append(t)
                addedVolumes += 1
            }
        }
        if updated > 0 || addedVolumes > 0 {
            persistScanTargets()
            persistScanDates()
            notifyTargetsChanged()
        }

        // Settings — merge portable fields onto current settings, save back.
        var current = PersonFinderSettings.restored()
        payload.settings.apply(to: &current)
        current.save()

        // POIs — safe install with iCloud materialization, validation, and
        // conflict resolution. Failures here are logged but don't roll back
        // the catalog/volumes/settings work above. See
        // `BundleImporter.installPOIs` for the gory details.
        let poiResult = await BundleImporter.installPOIs(
            from: payload.poiFoldersInBundle,
            bundleExportedAt: payload.bundleExportedAt
        )

        // Write per-import audit log so Rick can review every POI decision.
        let auditURL = Self.writeImportAuditLog(bundleURL: bundleURL,
                                                 payload: payload,
                                                 poiResult: poiResult)
        // Mirror the audit summary into the dashboard log too.
        for line in poiResult.auditLines {
            log(line)
        }

        saveCatalogNow()
        return BundleImportResult(
            recordsAdded: added,
            recordsSkipped: skipped,
            volumesUpdated: updated,
            volumesAdded: addedVolumes,
            peopleInstalled: poiResult.installed,
            peopleSkipped: poiResult.skipped,
            peopleFailed: poiResult.failed,
            peopleFieldMerged: poiResult.fieldMerged,
            auditLogURL: auditURL
        )
    }

    // MARK: - Bundle import: formatting helpers

    /// Render an "Installed: 8 (donna, timmy, ...)" style bucket. Truncates
    /// long lists with an ellipsis so the alert stays readable.
    fileprivate static func formatPOIBucket(label: String,
                                            count: Int,
                                            names: [String]) -> String {
        if count == 0 { return "\(label): 0" }
        let shown = names.prefix(8).joined(separator: ", ")
        if names.count > 8 {
            return "\(label): \(count) (\(shown), …)"
        }
        return "\(label): \(count) (\(shown))"
    }

    /// Render the field-merge bucket: which people got details (birthday,
    /// notes, …) filled in from whichever copy lost the folder contest.
    /// Casual wording on purpose — this is good news, not a warning.
    fileprivate static func formatFieldMerges(_ merges: [(name: String, fields: [String])]) -> String {
        let label = "Details filled in from the other copy"
        if merges.isEmpty { return "\(label): 0" }
        let shown = merges.prefix(8)
            .map { "\($0.name): \($0.fields.joined(separator: ", "))" }
            .joined(separator: "; ")
        if merges.count > 8 {
            return "\(label): \(merges.count) (\(shown); …see audit log)"
        }
        return "\(label): \(merges.count) (\(shown))"
    }

    /// Render the failed bucket with reasons inline — Rick needs the "why"
    /// to know whether to retry or investigate.
    fileprivate static func formatPOIFailures(_ failures: [(name: String, reason: String)]) -> String {
        guard !failures.isEmpty else { return "" }
        let shown = failures.prefix(5)
            .map { "\($0.name): \($0.reason)" }
            .joined(separator: "; ")
        if failures.count > 5 {
            return "Failed: \(failures.count) (\(shown); …see audit log)"
        }
        return "Failed: \(failures.count) (\(shown))"
    }

    /// Write a one-shot per-import audit log under
    /// `~/Library/Logs/VideoScan/import-<ISO8601-date>.log`. Returns the URL
    /// (or nil if writing failed — never throws to the caller).
    ///
    /// The audit log captures every POI decision verbatim plus a summary
    /// header — Rick wants to be able to answer "why didn't 'matt' come
    /// across?" weeks later. Format matches `PersistentLog` loosely but is
    /// written all-at-once (the import is short enough that crash-resilient
    /// streaming isn't worth the complexity).
    fileprivate static func writeImportAuditLog(bundleURL: URL,
                                                payload: BundleImporter.Payload,
                                                poiResult: BundleImporter.POIInstallResult) -> URL? {
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd-HHmmss"
        stampFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = stampFmt.string(from: Date())
        let url = PersistentLog.logDir.appendingPathComponent("import-\(stamp).log")

        var body = """
        VideoScan import audit log
        ─────────────────────────────────────────────
        Started:        \(ISO8601DateFormatter().string(from: Date()))
        Bundle path:    \(bundleURL.path)
        Bundle host:    \(payload.manifest.exportedFromHost)
        Bundle date:    \(ISO8601DateFormatter().string(from: payload.manifest.exportedAt))
        Bundle app:     v\(payload.manifest.appVersion) build \(payload.manifest.appBuild)
        Counts:         \(payload.manifest.counts.records) records, \
        \(payload.manifest.counts.volumes) volumes, \
        \(payload.manifest.counts.people) people, \
        \(payload.manifest.counts.referencePhotos) photos
        ─────────────────────────────────────────────
        POI decisions:

        """
        for line in poiResult.auditLines {
            body += line + "\n"
        }
        body += """

        ─────────────────────────────────────────────
        Summary:
          installed: \(poiResult.installed.count) — \(poiResult.installed.joined(separator: ", "))
          skipped:   \(poiResult.skipped.count) — \(poiResult.skipped.map { "\($0.name) (\($0.reason))" }.joined(separator: "; "))
          merged:    \(poiResult.fieldMerged.count) — \(poiResult.fieldMerged.map { "\($0.name): \($0.fields.joined(separator: ", "))" }.joined(separator: "; "))
          failed:    \(poiResult.failed.count) — \(poiResult.failed.map { "\($0.name): \($0.reason)" }.joined(separator: "; "))
        ─────────────────────────────────────────────
        """

        do {
            try FileManager.default.createDirectory(at: PersistentLog.logDir,
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            // Best-effort: log to dashboard via NSLog so we don't lose this
            // failure. Returning nil tells the alert to omit the audit line.
            NSLog("VideoScan: failed to write import audit log at \(url.path): \(error)")
            return nil
        }
    }

    fileprivate func applyVolumeSnapshot(_ s: VolumeMetadataSnapshot, to t: CatalogScanTarget) {
        ScanTargetPersistence.applyVolumeSnapshot(s, to: t)
    }

    fileprivate static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
