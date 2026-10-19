import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Whole-shebang Bundle Import / Export
//
// The bundle format (see BundleExportImport.swift) wraps the catalog +
// per-volume metadata + machine-portable PersonFinderSettings + the
// entire POI tree (profiles + reference photos) in a single
// `<name>.videoscanbundle/` directory.
//
// Since 2026-10-19 (bundle v2, "JSON gone by Friday"):
//   * Back Up Catalog seals catalog.sqlite into the bundle (CatalogBackupSeal):
//     memory committed first, VACUUM INTO off the main actor, the copy
//     reopened read-only and checked. A held, blocked or read-only catalog —
//     or a Mac whose catalog is not catalog.sqlite — refuses in words.
//   * Import Catalog never merges into catalog.sqlite. A JSON bundle is
//     refused ("from before the database switch"); a catalog.sqlite bundle
//     is refused too, because there is no safe Restore yet (replacing the
//     live database needs its own design — see `bundleImportDecision`).
//     A Mac still on catalog.json can still merge an old JSON bundle.
//
// Split out from VideoScanModel.swift during the 2026-05 size-cap
// refactor — the JSON-only catalog import/export lives in
// VideoScanModel+CatalogImportExport.swift; this file is everything
// extra that the bundle format adds on top (POIs, audit log,
// confirmation dialogs).

/// What Back Up Catalog did.
enum CatalogBackupOutcome {
    case backedUp(BundleExporter.Summary)
    /// Nothing usable was written; the words say why.
    case refused(String)
}

/// What Import Catalog may do with a chosen bundle.
enum BundleImportDecision: Equatable {
    /// A catalog.json bundle on a Mac still on catalog.json: the old merge.
    case mergeLegacyJSON
    /// Nothing is imported; the words say why.
    case refuse(String)
}

/// The files around the catalog that a backup also carries. Production
/// reads the real places; tests point every one at a sandbox.
struct BackupSideFiles: Sendable {
    var poiFolders: [URL]
    var dossierDeltaDir: URL
    var catalogManifest: URL

    static func production() -> BackupSideFiles {
        BackupSideFiles(poiFolders: POIStorage.allPOIFolders(),
                        dossierDeltaDir: DossierDeltaPaths.liveDir,
                        catalogManifest: DossierDeltaPaths.liveManifestSha256)
    }
}

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

    // MARK: - Back Up Catalog

    /// One backup at a time (a second ⌘E while one runs is refused).
    /// A static stored property, because Swift extensions cannot add
    /// instance storage (≈ a file-scope `static bool` owned by the UI thread).
    private static var backupRunning = false

    /// UI entry point: show a save panel, write the bundle, summarize.
    /// Single backup code path — both File ▸ Back Up Catalog… (⌘E) and
    /// the catalog-header backup badge land here.
    func exportBundleViaPanel() {
        guard let url = askWhereToSaveBackup() else { return }
        // Swift's `Task { @MainActor in … }` ≈ "post this to the UI thread";
        // the awaits inside hop to worker threads for the seal and copies.
        Task { @MainActor in
            switch await backUpCatalog(to: url) {
            case .refused(let words):
                Self.showErrorAlert(title: "Backup Not Made", message: Self.sentence(words))
            case .backedUp(let summary):
                presentBackupSummary(summary)
                // Backup is when the user is already caring for the catalog —
                // the right moment to nag about retired volumes still carrying
                // records (Rick 2026-08-14; the prompt performs the deletion).
                promptRetiredCatalogCleanup()
            }
        }
    }

    /// The save panel. nil = cancelled.
    private func askWhereToSaveBackup() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Back Up Catalog"
        panel.message = "Save a backup containing the catalog database, volume metadata, settings, and reference photos for every person."
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.directory]
        let host = CatalogHost.currentName.replacingOccurrences(of: " ", with: "_")
        // Date AND time in the suggested name (Rick 2026-08-14): a second
        // same-day backup used to collide with the first, and replacing a
        // DIRECTORY bundle in an iCloud folder trips iCloud's
        // delete-then-copy semantics. Unique-per-minute names never enter
        // the overwrite path at all.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        panel.nameFieldStringValue = "VideoScan_\(host)_\(df.string(from: Date())).videoscanbundle"
        // Default to wherever the last backup landed (when that folder
        // still exists) so repeat backups are click → Return → done.
        if let dir = Self.defaultBackupDirectory(lastBackupPath: lastBackupPath) {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        // NSSavePanel can drop our extension if the user retypes the name.
        if url.pathExtension != "videoscanbundle" {
            url = url.appendingPathExtension("videoscanbundle")
        }
        return url
    }

    /// Back up the catalog to `url`: what is in memory is committed to
    /// catalog.sqlite first (here, on the main actor), then the bundle is
    /// written off it (`BundleExporter.writeBundle`). START / phase /
    /// OUTCOME or REFUSED lines go to the one sink (console, catalog.log,
    /// videoscan.log). The backup badge is stamped on success only.
    func backUpCatalog(to url: URL, sideFiles: BackupSideFiles? = nil) async -> CatalogBackupOutcome {
        guard !Self.backupRunning else { return refuseBackup("a backup is already being made") }
        guard url.pathExtension == "videoscanbundle" else {
            return refuseBackup(BundleError.badExtension.localizedDescription)
        }
        let source: CatalogBackupSeal.Source
        switch catalogBackupSource() {
        case .success(let ready): source = ready
        case .failure(let refusal): return refuseBackup(refusal.words)
        }
        Self.backupRunning = true
        defer { Self.backupRunning = false }
        let side = sideFiles ?? .production()
        let inputs = BundleExporter.Inputs(
            catalog: source,
            volumes: CatalogScanTarget.excludingScratch(scanTargets).map(VolumeMetadataSnapshot.init(from:)),
            settings: SettingsSnapshot(from: PersonFinderSettings.restored()),
            poiFolders: side.poiFolders,
            dossierDeltaDir: side.dossierDeltaDir,
            catalogManifest: side.catalogManifest)
        catalogAuthorityNote("START Back Up Catalog to \(url.path)")
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let summary = try await BundleExporter.writeBundle(inputs, to: url, progress: { [weak self] phase in
                Task { @MainActor in self?.catalogAuthorityNote("Back Up Catalog: \(phase)") }
            })
            recordBackupSuccess(at: url)
            logBackupOutcome(summary, elapsed: clock.now - started)
            return .backedUp(summary)
        } catch {
            return refuseBackup("the backup could not be written: \(error.localizedDescription)")
        }
    }

    /// Why Back Up Catalog can't run, in the person's words.
    struct BackupRefusal: Error {
        let words: String
    }

    /// The store to seal, after committing what is in memory — or why not.
    /// Refuses: no catalog.sqlite authority (a viewer, or a Mac still on
    /// catalog.json), and every reason the commit-first door refuses (held
    /// by a job, read-only, blocked, being reopened).
    func catalogBackupSource() -> Result<CatalogBackupSeal.Source, BackupRefusal> {
        guard let committer = catalogCutover.committer, let databaseURL = catalogCutover.databaseURL else {
            let words = ViewerModeCenter.shared.isViewer
                ? "this Mac is a viewer — back up on the master, where catalog.sqlite lives"
                : "this Mac's catalog is still catalog.json, and backups now hold catalog.sqlite only — "
                  + "switch first (Catalog ▸ Switch Catalog to SQLite…)"
            return .failure(BackupRefusal(words: words))
        }
        if let why = committer.commitBeforeSafetyCopy() {
            return .failure(BackupRefusal(words: "what is in memory could not be saved to catalog.sqlite first: \(why)"))
        }
        let latch = databaseURL.deletingLastPathComponent().appendingPathComponent(CatalogAuthority.latchFileName)
        return .success(CatalogBackupSeal.Source(repository: committer.repository, databaseURL: databaseURL, latchURL: latch))
    }

    private func refuseBackup(_ words: String) -> CatalogBackupOutcome {
        catalogAuthorityNote("REFUSED Back Up Catalog — \(words). No backup was made.")
        return .refused(words)
    }

    private func logBackupOutcome(_ summary: BundleExporter.Summary, elapsed: Duration) {
        let m = summary.manifest
        let db = m.catalogDatabase.map { "catalog.sqlite generation \($0.generation), \($0.files) file rows, "
            + "\($0.quarantine) quarantined, sha256 \($0.sha256.prefix(12))…" } ?? "no catalog.sqlite"
        catalogAuthorityNote("OUTCOME Back Up Catalog to \(summary.path.lastPathComponent) — \(db); "
            + "\(m.counts.volumes) volumes, \(m.counts.people) people, \(m.counts.referencePhotos) photos, "
            + "\(BundleSize.human(m.sizes.totalBytes)), in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))")
        // Logged individually for the audit trail; summarized in the alert.
        for w in summary.exportWarnings {
            log("Export warning: \(w.path) — \(w.reason)")
        }
    }

    /// The post-backup alert.
    private func presentBackupSummary(_ summary: BundleExporter.Summary) {
        let m = summary.manifest
        let alert = NSAlert()
        alert.messageText = "Backup Complete"
        alert.informativeText = Self.missingProfileBanner(summary)
            + "Saved \(summary.path.lastPathComponent)\n\n"
            + Self.backupDatabaseLine(m.catalogDatabase)
            + "\n• \(m.counts.volumes) volume(s)"
            + "\n• \(m.counts.people) person profile(s) with \(m.counts.referencePhotos) reference photo(s)"
            + Self.backupDeltaLine(m)
            + "\n• Total size: \(BundleSize.human(m.sizes.totalBytes)) (photos: \(BundleSize.human(m.sizes.referencePhotoBytes)))"
            + Self.backupWarningsBlurb(summary.exportWarnings)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func backupDatabaseLine(_ db: CatalogBackupSeal.Sealed?) -> String {
        guard let db else { return "• catalog.sqlite: missing" }
        return "• catalog.sqlite — generation \(db.generation), \(db.files) file row(s) including removed ones, "
            + "\(db.quarantine) quarantined, \(BundleSize.human(db.bytes)), checked"
    }

    private static func backupDeltaLine(_ m: BundleManifest) -> String {
        let lines = m.counts.dossierDeltaLines ?? 0
        guard lines > 0 else {
            return "\n• Dossier delta JSONLs: not bundled (delta dir unavailable — catalog.sqlite has the dossier fields)"
        }
        return "\n• \(lines) dossier delta line(s) (\(BundleSize.human(m.sizes.dossierDeltaBytes ?? 0))) — JSONL backup of expensive compute"
    }

    /// Loud banner when ANY POI shipped without a valid profile.json — the
    /// bundle is then not safely importable on another Mac. Above the counts.
    private static func missingProfileBanner(_ summary: BundleExporter.Summary) -> String {
        let missing = summary.missingProfileJSONCount
        guard missing > 0 else { return "" }
        let plural = missing == 1 ? "" : "s"
        return "\u{26A0}\u{FE0F} \(missing) POI\(plural) shipped without profile.json — re-export recommended\n\n"
    }

    private static func backupWarningsBlurb(_ warnings: [(path: String, reason: String)]) -> String {
        guard !warnings.isEmpty else { return "" }
        let preview = warnings.prefix(5).map { "  – \($0.path): \($0.reason)" }.joined(separator: "\n")
        let more = warnings.count > 5 ? "\n  – …and \(warnings.count - 5) more (see log)" : ""
        return "\n\nWarnings (\(warnings.count)):\n\(preview)\(more)"
    }

    /// "words" → "Words." for an alert body.
    private static func sentence(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst() + (words.hasSuffix(".") ? "" : ".")
    }

    // MARK: - Import Catalog

    /// The refusal for a pre-switch (catalog.json) bundle under catalog.sqlite.
    nonisolated static let jsonBundleUnderSQLiteWords =
        "this backup is from before the database switch; it can't be merged into catalog.sqlite"

    /// What Import Catalog may do with a bundle holding `kind` on a Mac
    /// whose authority is (or is not) catalog.sqlite. Nothing is ever merged
    /// into catalog.sqlite. A catalog.sqlite bundle is refused as well:
    /// a proper Restore would REPLACE the live database (close the store,
    /// keep this Mac's high-water witnesses so the restored copy opens
    /// read-only below them, then Adopt) — that is a new door with its own
    /// design, not a merge, and it does not exist yet.
    nonisolated static func bundleImportDecision(kind: BundleImporter.CatalogKind,
                                                 isSQLiteAuthority: Bool) -> BundleImportDecision {
        switch (kind, isSQLiteAuthority) {
        case (.legacyJSON, true):
            return .refuse(jsonBundleUnderSQLiteWords)
        case (.legacyJSON, false):
            return .mergeLegacyJSON
        case (.sqlite(let generation), true):
            let at = generation.map { " (generation \($0))" } ?? ""
            return .refuse("this backup holds a sealed catalog.sqlite\(at); backups are never merged into catalog.sqlite, "
                + "and VideoScan has no safe Restore yet, so nothing was changed — the backup is intact")
        case (.sqlite, false):
            return .refuse("this backup holds catalog.sqlite, but this Mac's catalog is still catalog.json; "
                + "it can't be merged into catalog.json, so nothing was changed")
        case (.none, _):
            return .refuse("this folder is not a VideoScan backup — it has neither catalog.sqlite nor catalog.json")
        }
    }

    /// `bundleImportDecision` for the bundle at `url` on this Mac now.
    func bundleImportDecision(for url: URL) -> BundleImportDecision {
        Self.bundleImportDecision(kind: BundleImporter.catalogKind(of: url),
                                  isSQLiteAuthority: catalogCutover.isSQLiteAuthority)
    }

    /// UI entry point: show an open panel, decide, then (old JSON bundles
    /// on a catalog.json Mac only) parse, confirm and merge.
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

        if case .refuse(let words) = bundleImportDecision(for: url) {
            catalogAuthorityNote("REFUSED Import Catalog of \(url.lastPathComponent) — \(words)")
            Self.showErrorAlert(title: "Not Imported", message: Self.sentence(words))
            return
        }

        let payload: BundleImporter.Payload
        do {
            payload = try BundleImporter.read(from: url)
        } catch {
            log("Bundle import failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
            return
        }
        guard Self.confirmLegacyImport(payload) else {
            log("Bundle import canceled.")
            return
        }
        // Hand off to async — POI install does iCloud polling that must not
        // block the main actor.
        Task { @MainActor in
            let result = await applyBundlePayload(payload, bundleURL: url)
            presentImportResult(result, payload: payload, url: url)
        }
    }

    /// Confirmation dialog — bundles can be sizeable and this overwrites
    /// POI folders, so make the user opt in deliberately.
    private static func confirmLegacyImport(_ payload: BundleImporter.Payload) -> Bool {
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
        return confirm.runModal() == .alertFirstButtonReturn
    }

    /// The post-import log line and alert.
    private func presentImportResult(_ result: BundleImportResult, payload: BundleImporter.Payload, url: URL) {
        if let refusal = result.refusal {
            Self.showErrorAlert(title: "Not Imported", message: Self.sentence(refusal))
            return
        }
        log("Imported bundle from \(payload.manifest.exportedFromHost): " +
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
        /// Set when nothing was merged (catalog.sqlite is this Mac's
        /// catalog): the words why. Every count above is then zero.
        var refusal: String? = nil

        /// Back-compat shim: callers / tests that asked for `peopleInstalled`
        /// as an Int can use this. The new structured form is preferred.
        var peopleInstalledCount: Int { peopleInstalled.count }
    }

    /// Merge a parsed (catalog.json) bundle payload into live model state.
    /// Async because POI install does iCloud-aware polling. Separated from
    /// `importBundleViaPanel` so tests can call it directly.
    ///
    /// Refuses outright — nothing merged, nothing installed, nothing saved —
    /// while catalog.sqlite is this Mac's catalog: JSON records are never
    /// merged into the database (the panel already refuses; this is the
    /// door's own guard for any other caller).
    @discardableResult
    func applyBundlePayload(_ payload: BundleImporter.Payload,
                            bundleURL: URL) async -> BundleImportResult {
        if catalogCutover.isSQLiteAuthority {
            let words = Self.jsonBundleUnderSQLiteWords
            catalogAuthorityNote("REFUSED Import Catalog of \(bundleURL.lastPathComponent) — \(words)")
            return BundleImportResult(recordsAdded: 0, recordsSkipped: 0, volumesUpdated: 0, volumesAdded: 0,
                                      peopleInstalled: [], peopleSkipped: [], peopleFailed: [],
                                      peopleFieldMerged: [], auditLogURL: nil, refusal: words)
        }
        // Catalog — seed identity set from existing records, dedup on insert.
        var seen = Set<String>()
        var localsByKey: [String: [VideoRecord]] = [:]
        for rec in records {
            if let key = Self.identityKey(for: rec) { seen.insert(key); localsByKey[key, default: []].append(rec) }
        }
        let effectiveHost = payload.catalog.savedFromHost.isEmpty
            ? payload.manifest.exportedFromHost
            : payload.catalog.savedFromHost
        var added = 0
        var skipped = 0
        var addedRecords: [VideoRecord] = []
        var idRemap: [UUID: UUID] = [:]
        for rec in payload.catalog.records {
            if let key = Self.identityKey(for: rec), seen.contains(key) {
                skipped += 1
                if let local = Self.localStandIn(for: rec, candidates: localsByKey[key] ?? []),
                   local.id != rec.id { idRemap[rec.id] = local.id }
                continue
            }
            if rec.sourceHost.isEmpty {
                rec.sourceHost = effectiveHost
            }
            records.append(rec)
            addedRecords.append(rec)
            if let key = Self.identityKey(for: rec) { seen.insert(key); localsByKey[key, default: []].append(rec) }
            added += 1
        }
        // Archive copies whose source was deduped keep a resolvable
        // derivedFrom (codex R4-D).
        Self.relinkImportedProvenance(addedRecords, idRemap: idRemap)
        let invalidPairEndpoints = CorrelationScorer.revalidateExistingPairs(in: records)
        if invalidPairEndpoints > 0 {
            log("Bundle import released \(invalidPairEndpoints) invalid persisted A/V pair endpoint(s).")
        }
        // Master Archive designation rides the bundle's catalog.json (§3).
        adoptImportedMasterArchive(payload.catalog.masterArchive)

        let volumes = mergeBundleVolumes(payload.volumes.volumes)

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
            volumesUpdated: volumes.updated,
            volumesAdded: volumes.added,
            peopleInstalled: poiResult.installed,
            peopleSkipped: poiResult.skipped,
            peopleFailed: poiResult.failed,
            peopleFieldMerged: poiResult.fieldMerged,
            auditLogURL: auditURL
        )
    }

    /// Merge a bundle's volume metadata: overwrite metadata on path match;
    /// add as an offline target when the path isn't present locally so the
    /// volume shows up in the sidebar (grayed out until the drive is
    /// connected on this Mac). Returns how many were updated / added.
    private func mergeBundleVolumes(_ snapshots: [VolumeMetadataSnapshot]) -> (updated: Int, added: Int) {
        var updated = 0
        var added = 0
        // Screen the RAM-disk scratch volume — the exporter has excluded it
        // since 2026-05, but bundles written by older builds may still
        // carry a VideoScan_Temp snapshot.
        for snap in snapshots where !CatalogScanTarget.isScratchVolumePath(snap.searchPath) {
            if let existing = scanTargets.first(where: { $0.searchPath == snap.searchPath }) {
                // codex m5: the designated Master Archive keeps its role
                // whatever an older snapshot says; an existing target never
                // gets a retiredAt stamp from a legacy "Retired" role
                // string (only from an explicit retiredAt field).
                ScanTargetPersistence.applyVolumeSnapshot(
                    snap, to: existing,
                    isNewTarget: false,
                    preserveRole: isMasterArchive(existing))
                updated += 1
            } else {
                let t = CatalogScanTarget(searchPath: snap.searchPath)
                applyVolumeSnapshot(snap, to: t)
                scanTargets.append(t)
                added += 1
            }
        }
        if updated > 0 || added > 0 {
            // Imported snapshots may carry pre-taxonomy roles (legacy
            // "Archive" on a non-master volume) — same idempotent pass
            // the launch path runs.
            migrateVolumeRoles()
            persistScanTargets()
            persistScanDates()
            notifyTargetsChanged()
        }
        return (updated, added)
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
