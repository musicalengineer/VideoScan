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
//   * JSON gone, slice 2b (2026-10-21): the old JSON merge (a catalog.json
//     bundle on a Mac still on catalog.json — `BundleImporter.read`,
//     `applyBundlePayload`) is retired; a JSON bundle is refused in words on
//     every Mac. BundleImporter.installPOIs (the People half) stays for the
//     future Restore.
//
// Split out from VideoScanModel.swift during the 2026-05 size-cap
// refactor — the JSON-only catalog export lives in
// VideoScanModel+CatalogImportExport.swift; this file is everything
// extra that the bundle format adds on top.

/// What Back Up Catalog did.
enum CatalogBackupOutcome {
    case backedUp(BundleExporter.Summary)
    /// Nothing usable was written; the words say why.
    case refused(String)
}

/// What Import Catalog may do with a chosen bundle. One case today — every
/// bundle is refused (the JSON merge left 2026-10-21); a Restore of a
/// catalog.sqlite bundle would be the next case. (A one-case enum ≈ a C++
/// tagged result whose other alternatives are not written yet.)
enum BundleImportDecision: Equatable {
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
                : "this Mac's catalog is still catalog.json, and backups now hold catalog.sqlite only"
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

    /// The refusal for a pre-switch (catalog.json) bundle — on every Mac
    /// since JSON gone, slice 2b (2026-10-21): no catalog.json backup is read.
    nonisolated static let jsonBundleRefusedWords =
        "this backup is from before the database switch (it holds catalog.json), and VideoScan no longer reads "
            + "catalog.json backups; nothing was changed — the backup is intact"

    /// File ▸ Import Catalog…'s help while it is disabled (QA r1 NIT on
    /// slice 2b): every bundle is refused until Restore exists.
    nonisolated static let importCatalogComingHelp = "Restore from a catalog.sqlite backup is coming (GH #343)"

    /// What Import Catalog may do with a bundle holding `kind` on a Mac
    /// whose authority is (or is not) catalog.sqlite: today, refuse — with
    /// words. Nothing is ever merged into catalog.sqlite, and a catalog.json
    /// bundle is never read (slice 2b retired the old JSON merge, the last
    /// reader of a catalog.json backup). A catalog.sqlite bundle is refused
    /// as well: a proper Restore would REPLACE the live database (close the
    /// store, keep this Mac's high-water witnesses so the restored copy
    /// opens read-only below them, then Adopt) — that is a new door with
    /// its own design, not a merge, and it does not exist yet.
    nonisolated static func bundleImportDecision(kind: BundleImporter.CatalogKind,
                                                 isSQLiteAuthority: Bool) -> BundleImportDecision {
        switch (kind, isSQLiteAuthority) {
        case (.legacyJSON, _):
            return .refuse(jsonBundleRefusedWords)
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

    /// UI entry point: show an open panel, decide, and say why nothing was
    /// imported (REFUSED line in the one sink + an alert). Nothing in the
    /// bundle is read beyond manifest.json and which catalog file it holds.
    func importBundleViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Catalog"
        panel.message = "Choose a VideoScan backup (.videoscanbundle) from another Mac."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch bundleImportDecision(for: url) {
        case .refuse(let words):
            catalogAuthorityNote("REFUSED Import Catalog of \(url.lastPathComponent) — \(words)")
            Self.showErrorAlert(title: "Not Imported", message: Self.sentence(words))
        }
    }
}
