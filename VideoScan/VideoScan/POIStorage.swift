// POIStorage.swift
// Single source of truth for where Person-of-Interest (POI) data lives.
//
// Layout (issue #35, re-keyed by uuid 2026-09-12 — docs/people_uuid_folders_design.md):
//
//     ~/Library/Application Support/VideoScan/
//     ├── catalog.json
//     ├── metadata_cache.sqlite
//     ├── POI/
//     │   ├── .uuid-migration.json                  ← audit of the name→uuid move
//     │   ├── 2E6B1D2C-9F8A-4C61-8B7A-0C1D3E4F5A6B/ ← one folder per profile (uppercase uuid)
//     │   │   ├── profile.json
//     │   │   ├── apple_1234_0.heic
//     │   │   └── apple_1234_1.jpeg
//     │   └── FF6C5474-EBB4-4D32-A9EF-B2D38647A146/
//     └── POI-backup-20260913-021500/               ← APFS clone taken before the migration
//
// Why this layout:
//   * Apple File System Programming Guide puts user-generated app-specific
//     data (not user-browsable documents) in Application Support — exactly
//     what POI data is.
//   * Co-located with catalog.json + metadata_cache.sqlite the app already
//     stores there.
//   * Each POI is self-contained in its own folder — trivial to zip and send
//     to another Mac for cross-machine sharing.
//   * profile.json living next to its photos makes referencePath implicit:
//     even if the user moves their home directory or the app bundle, the
//     POI auto-heals because its folder is always the folder containing
//     its profile.json.
//   * The folder is named by the profile's durable uuid, never by the name
//     (Rick's ruling 2026-09-12): two Richards — Jr is Rick, Sr is Dad —
//     used to collide on `richard/`; a rename is now a JSON write and never
//     moves a photo.
//
// Before this file existed, POI data lived in the git repo at
// ~/dev/VideoScan/poi_profiles/ + ~/dev/VideoScan/poi_photos/, which
// cluttered git status and embedded absolute paths in JSON. migrateLegacyIfNeeded()
// handles that one-shot move; migrateToUUIDFoldersIfNeeded() handles the
// name-folder → uuid-folder move that followed.

import Foundation
import Darwin
import os

private let storageLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "POIStorage")

enum POIStorage {

    // MARK: - Paths

    /// Root directory for all POI data. Created on first access.
    /// Test hosts (unit AND UI — TestEnvironment.isTestHost covers both)
    /// are diverted to a per-process temp dir so no test can ever touch
    /// the user's real POI store (settings-pollution class; same pattern
    /// as MetadataCache / ScanJobsStorage / PersistentLog.logDir).
    static var storeDir: URL {
        if TestEnvironment.isTestHost {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "VideoScanTestPOI-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("POI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The on-disk folder name for a profile: its uuid, uppercase, exactly
    /// as `UUID.uuidString` prints it. One spelling everywhere so a folder
    /// can be matched to its profile by string compare alone.
    static func folderName(for uuid: UUID) -> String {
        uuid.uuidString.uppercased()
    }

    /// Folder holding one POI's profile.json + photos, keyed by uuid.
    static func folder(forUUID uuid: UUID) -> URL {
        storeDir.appendingPathComponent(folderName(for: uuid), isDirectory: true)
    }

    /// Folder for a profile — the ONLY resolver production code should use.
    static func folder(for profile: POIProfile) -> URL {
        folder(forUUID: profile.uuid)
    }

    /// Full path to a POI's profile.json file.
    static func profileURL(forUUID uuid: UUID) -> URL {
        folder(forUUID: uuid).appendingPathComponent("profile.json")
    }

    static func profileURL(for profile: POIProfile) -> URL {
        profileURL(forUUID: profile.uuid)
    }

    /// COMPATIBILITY ONLY. The pre-2026-09-12 folder for a short name
    /// (lowercased, spaces → underscores). Kept so the uuid migration can
    /// read legacy folders and so a legacy job descriptor / bundle can be
    /// matched; never a place to WRITE a profile. New code wants
    /// `folder(for:)`.
    static func legacyFolder(forName name: String) -> URL {
        storeDir.appendingPathComponent(sanitize(name), isDirectory: true)
    }

    /// Canonical short-name sanitization. Still the spelling used for the
    /// human-readable trash folder (`POI-<name>-<UTC>`), cluster run tags
    /// and legacy folder lookups.
    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return trimmed.isEmpty ? "reference" : trimmed
    }

    /// Whether a folder name is already a uuid spelling (either case — APFS
    /// is case-insensitive by default, so `2e6b…` and `2E6B…` are one folder).
    static func uuid(fromFolderName name: String) -> UUID? {
        UUID(uuidString: name)
    }

    // MARK: - Enumeration

    /// Returns the list of POI folders directly under storeDir (subfolders
    /// only; ignores stray files). Ensures both migrations have run first.
    static func allPOIFolders() -> [URL] {
        _ = migrateLegacyIfNeeded()
        _ = migrateToUUIDFoldersIfNeeded()
        return poiFolders(in: storeDir)
    }

    /// Raw listing of POI-shaped folders under `root` — no migration, no
    /// writes. The `.poi-rename-*` staging dirs of the 2026-09-12 rename fix
    /// are excluded so a crashed rename never shows up as a person.
    static func poiFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.filter { url in
            !url.lastPathComponent.hasPrefix(".poi-rename-")
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    // MARK: - Safe trash (NEVER rm -rf, per project policy)

    /// Root for "soft-deleted" POI folders. Lives inside the working tree so
    /// `git status` makes it findable, but the path is .gitignore'd via the
    /// leading dot. Mirrors the trashTarget used by the bundle importer.
    static var trashDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/VideoScan/.trash", isDirectory: true)
    }

    /// Filename-safe UTC timestamp (no colons — Finder dislikes them).
    /// Format: yyyyMMdd-HHmmss (e.g. `20260515-184213`).
    static func trashTimestamp(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: now)
    }

    /// Move a POI folder into the project-local .trash/ rather than deleting
    /// it outright. Project policy (MANAGER.md) forbids `rm`-style POI
    /// deletion — the user can always recover from .trash/ for as long as
    /// they have disk space, and an explicit `rm -rf ~/dev/VideoScan/.trash`
    /// is the only way data ever physically goes away.
    ///
    /// The source is the uuid folder; the trash folder is named after the
    /// person (`POI-<sanitized name>-<UTC>`) so Rick can find it by eye. The
    /// uuid travels inside profile.json.
    ///
    /// Returns the destination URL inside .trash on success, or nil if the
    /// source didn't exist or the move failed. The caller is responsible for
    /// logging / surfacing the failure to the user.
    ///
    /// Test override: pass `storeOverride` / `trashOverride` to redirect
    /// both ends to a sandbox. Production callers pass nil for both.
    @discardableResult
    static func trashPOIFolder(
        uuid: UUID,
        displayName: String,
        now: Date = Date(),
        storeOverride: URL? = nil,
        trashOverride: URL? = nil
    ) -> URL? {
        let fm = FileManager.default
        let label = sanitize(displayName)
        let src = (storeOverride ?? storeDir)
            .appendingPathComponent(folderName(for: uuid), isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return nil }

        let trashRoot = trashOverride ?? trashDir
        let stamp = trashTimestamp(now)
        let dest = trashRoot.appendingPathComponent("POI-\(label)-\(stamp)",
                                                    isDirectory: true)

        // Ensure trash root exists (creates intermediate `dev/VideoScan/.trash`).
        do {
            try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // If the destination already exists (sub-second collision in a test
        // loop, or two people with one display name), append a uniquifier
        // rather than overwrite.
        var finalDest = dest
        if fm.fileExists(atPath: finalDest.path) {
            finalDest = trashRoot.appendingPathComponent(
                "POI-\(label)-\(stamp)-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        }

        do {
            try fm.moveItem(at: src, to: finalDest)
            return finalDest
        } catch {
            return nil
        }
    }

    // MARK: - Undo (move back out of .trash/)

    /// Outcome of an undo attempt. Distinguishes the "can't overwrite an
    /// existing POI" case from generic IO failure so the UI can show a
    /// specific message ("'<name>' was re-created") instead of a generic
    /// error.
    enum RestoreResult: Equatable {
        case restored(URL)              // success — folder now lives at this URL
        case sourceMissing              // trash folder no longer exists
        case destinationExists          // a POI with this uuid was re-created
        case ioError                    // moveItem threw for some other reason
    }

    /// Inverse of `trashPOIFolder`: moves a trashed POI folder back into
    /// `storeDir/<UUID>/`. Refuses to overwrite an existing POI folder — if
    /// the uuid folder reappeared between delete and undo (a bundle import,
    /// say), the caller must surface that to the user (non-destructive abort).
    ///
    /// Test override: pass `storeOverride` to redirect the destination
    /// into a sandbox. Production callers pass nil.
    ///
    /// Why this lives in POIStorage (not PersonFinderModel): the same
    /// safety rules apply (project policy forbids `rm` on POI data, and
    /// the folder naming has to match trashPOIFolder). Keeping the inverse
    /// next to the forward op makes both easier to audit.
    static func restorePOIFolder(
        from trashURL: URL,
        uuid: UUID,
        storeOverride: URL? = nil
    ) -> RestoreResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashURL.path) else { return .sourceMissing }

        let dest = (storeOverride ?? storeDir)
            .appendingPathComponent(folderName(for: uuid), isDirectory: true)

        // Refuse to clobber. The user may have re-created the person while
        // the undo banner was still up — overwriting would silently destroy
        // their new work. Hand the situation back to the caller.
        if fm.fileExists(atPath: dest.path) {
            return .destinationExists
        }

        // Ensure parent exists (storeDir's getter already does this for
        // the production path, but storeOverride sandboxes may not).
        let parent = dest.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            try fm.moveItem(at: trashURL, to: dest)
            return .restored(dest)
        } catch {
            return .ioError
        }
    }

    // MARK: - Migration 1: repo-local layout → Application Support (issue #35)

    /// Legacy locations the app created before issue #35. Both under the
    /// working-tree repo, which is why they cluttered git.
    static var legacyProfilesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/VideoScan/poi_profiles", isDirectory: true)
    }
    static var legacyPhotosDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/VideoScan/poi_photos", isDirectory: true)
    }

    /// Result of a migration run. `.migrated` carries the count of POIs
    /// moved — useful for logging / diagnostics.
    enum MigrationResult: Equatable {
        case notNeeded           // nothing legacy, or new store already populated
        case migrated(Int)       // moved N POIs
        case skippedAlreadyRun   // a .migration_completed marker was found
    }

    /// One-shot migration from the legacy layout. Idempotent: safe to call
    /// on every app start. Will NOT overwrite an existing populated POI
    /// folder — if the new store already has any subfolders, we assume
    /// migration has run (or the user is starting fresh) and bail.
    ///
    /// Leaves legacy files in place on purpose — the user can delete them
    /// manually after verifying everything looks right in the app. Safer
    /// than silently removing files during migration.
    ///
    /// Writes into the uuid layout directly (the profile JSON carries a
    /// freshly minted uuid) so the second migration has nothing to do for it.
    @discardableResult
    static func migrateLegacyIfNeeded() -> MigrationResult {
        let fm = FileManager.default

        // If the new store already has POI folders, skip. This is the
        // common steady-state path on every launch.
        let existing = (try? fm.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let hasExistingPOI = existing.contains { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        if hasExistingPOI { return .notNeeded }

        // Check for legacy profiles.
        guard fm.fileExists(atPath: legacyProfilesDir.path),
              let legacyFiles = try? fm.contentsOfDirectory(
                at: legacyProfilesDir, includingPropertiesForKeys: nil
              )
        else {
            return .notNeeded
        }

        let jsons = legacyFiles.filter { $0.pathExtension == "json" }
        guard !jsons.isEmpty else { return .notNeeded }

        var migrated = 0
        for jsonURL in jsons {
            if migrateOne(legacyProfileURL: jsonURL) {
                migrated += 1
            }
        }
        return .migrated(migrated)
    }

    /// Migrate a single legacy profile JSON and its associated photo folder
    /// into the new layout. Returns true on success.
    private static func migrateOne(legacyProfileURL: URL) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: legacyProfileURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["name"] as? String
        else {
            return false
        }

        let uuid = (json["uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        json["uuid"] = uuid.uuidString
        let newFolder = folder(forUUID: uuid)
        try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)

        // Copy photos from legacy referencePath (or legacy_photos/<name>/)
        // into the new folder. Prefer the explicit referencePath from the
        // old JSON; fall back to the naming convention if missing.
        let legacyRefPath = (json["referencePath"] as? String) ?? ""
        let sourceDir: URL
        if !legacyRefPath.isEmpty, fm.fileExists(atPath: legacyRefPath) {
            sourceDir = URL(fileURLWithPath: legacyRefPath)
        } else {
            sourceDir = legacyPhotosDir.appendingPathComponent(sanitize(name))
        }
        if fm.fileExists(atPath: sourceDir.path),
           let photos = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) {
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]
            for photo in photos where imageExts.contains(photo.pathExtension.lowercased()) {
                let dest = newFolder.appendingPathComponent(photo.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: photo, to: dest)
                }
            }
        }

        // Rewrite referencePath in the JSON to the new folder, then write
        // it as profile.json inside the POI's own folder.
        json["referencePath"] = newFolder.path
        let newProfileURL = newFolder.appendingPathComponent("profile.json")
        if let rewritten = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? rewritten.write(to: newProfileURL, options: .atomic)
            return true
        }
        return false
    }

    // MARK: - Migration 2: name-keyed folders → uuid-keyed folders (2026-09-12)

    /// One move the migration intends to make, persisted BEFORE the first
    /// rename so a crash mid-way leaves a record a later run can reconcile.
    struct PlannedMove: Codable, Hashable {
        let old: String
        let new: String
        let uuid: String
    }

    /// Audit record for the name→uuid move, written to `POI/.uuid-migration.json`.
    /// `planned` is written before the first rename; `mapping` (old folder
    /// name → new folder name) grows as moves land; a later run merges into
    /// both, so the file always lists everything that was ever planned or
    /// moved and can drive `rollbackUUIDMigration`.
    struct UUIDMigrationReport: Codable, Equatable {
        struct Skipped: Codable, Equatable {
            let folder: String
            let reason: String
            let detail: String
        }
        var startedAt: Date
        var finishedAt: Date?
        var planned: [PlannedMove] = []
        var mapping: [String: String] = [:]
        var skipped: [Skipped] = []
        var backupPath: String?
        var backupMethod: String?
        var backupVerified: Bool = false
        var backupSeconds: Double = 0
        var renameSeconds: Double = 0
        var elapsedSeconds: Double = 0
        /// False when any folder had to be skipped — Rick has something to
        /// look at, and the file says what.
        var complete: Bool = false
        /// Sensor for the settings-pollution and ordering tests: the number
        /// of POI-shaped folders seen before and after this run. Never
        /// smaller after (nothing is deleted).
        var foldersBefore: Int = 0
        var foldersAfter: Int = 0
        /// Planned moves a previous run had already made (folder renamed,
        /// mapping not yet written when it stopped) that this run recognised
        /// by the uuid at the destination.
        var reconciled: [String] = []
        /// Old folder names whose moved folder has had its internal ABSOLUTE
        /// symlinks rebased (…/<old>/x → …/<UUID>/x). A mapping entry not
        /// listed here is unfinished work a later run completes — the rebase
        /// is idempotent, so a crash between rename and rebase is safe.
        var linksRebased: [String] = []

        enum CodingKeys: String, CodingKey {
            case startedAt, finishedAt, planned, mapping, skipped, backupPath, backupMethod
            case backupVerified, backupSeconds, renameSeconds, elapsedSeconds, complete
            case foldersBefore, foldersAfter, reconciled, linksRebased
        }

        init(startedAt: Date) { self.startedAt = startedAt }

        /// Tolerant decode: an audit file written by an earlier build of this
        /// branch (no `planned` / `reconciled`) still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
            finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
            planned = try c.decodeIfPresent([PlannedMove].self, forKey: .planned) ?? []
            mapping = try c.decodeIfPresent([String: String].self, forKey: .mapping) ?? [:]
            skipped = try c.decodeIfPresent([Skipped].self, forKey: .skipped) ?? []
            backupPath = try c.decodeIfPresent(String.self, forKey: .backupPath)
            backupMethod = try c.decodeIfPresent(String.self, forKey: .backupMethod)
            backupVerified = try c.decodeIfPresent(Bool.self, forKey: .backupVerified) ?? false
            backupSeconds = try c.decodeIfPresent(Double.self, forKey: .backupSeconds) ?? 0
            renameSeconds = try c.decodeIfPresent(Double.self, forKey: .renameSeconds) ?? 0
            elapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .elapsedSeconds) ?? 0
            complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
            foldersBefore = try c.decodeIfPresent(Int.self, forKey: .foldersBefore) ?? 0
            foldersAfter = try c.decodeIfPresent(Int.self, forKey: .foldersAfter) ?? 0
            reconciled = try c.decodeIfPresent([String].self, forKey: .reconciled) ?? []
            linksRebased = try c.decodeIfPresent([String].self, forKey: .linksRebased) ?? []
        }
    }

    /// What a call to `migrateToUUIDFoldersIfNeeded` did.
    enum UUIDMigrationOutcome: Equatable {
        /// Every folder is already keyed by uuid (or the store is empty).
        case notNeeded
        /// Refused before any I/O: a live-shaped root under a test host, or
        /// a remote viewer (POI/ is synced from the master there).
        case refused(String)
        /// Ran; the report says what moved and what was skipped.
        case ran(UUIDMigrationReport)
    }

    static let uuidMigrationFileName = ".uuid-migration.json"

    /// Skip reasons — string-typed so they read well in the audit file.
    enum UUIDMigrationSkip {
        static let symlink = "symlink"
        static let noProfile = "noProfile"
        static let malformedJSON = "malformedJSON"
        static let duplicateUUID = "duplicateUUID"
        static let destinationExists = "destinationExists"
        static let uuidWriteFailed = "uuidWriteFailed"
        static let renameFailed = "renameFailed"
    }

    /// What the last migration run in this process concluded about a root.
    /// Drives `legacyWritesPermitted`: the read-path uuid writers may touch
    /// a not-yet-migrated (legacy) folder only when a verified backup exists
    /// or there was never anything to move.
    enum MigrationState: Equatable {
        /// No legacy folders at all.
        case clean
        /// Legacy folders remain but none will move (all skipped); nothing
        /// in the store was mutated by the migration.
        case nothingToMove
        /// A verified backup exists at this path; moves happened after it.
        case backedUp(String)
        /// The backup could not be taken or verified — nothing moved, and
        /// nothing else may write into a legacy folder either.
        case backupFailed
        /// Refused before any I/O (live root under a test host, viewer).
        case refused
    }

    /// Serializes migration runs in-process. `NSLock` ≈ a C++ std::mutex;
    /// the migration is called from `listAll()` on whatever actor the caller
    /// is on, so the lock — not an actor — is what makes two concurrent
    /// callers see one run.
    private static let uuidMigrationLock = NSLock()

    /// Per-root state (keyed by standardized path).
    private static var migrationStates: [String: MigrationState] = [:]

    /// The last known state for `root`, nil when no run has looked at it in
    /// this process.
    static func migrationState(root: URL? = nil) -> MigrationState? {
        uuidMigrationLock.lock()
        defer { uuidMigrationLock.unlock() }
        return migrationStates[(root ?? storeDir).standardizedFileURL.path]
    }

    /// May a read path (`POIProfile.load`, `listAll`'s uuid persistence)
    /// write a minted uuid INTO A LEGACY FOLDER under `root`? Only when the
    /// migration has looked at the root and found nothing to move, or has a
    /// verified backup of it. Unknown, refused and backup-failed all mean
    /// no — the original stays byte-identical until a backup exists.
    static func legacyWritesPermitted(root: URL? = nil) -> Bool {
        switch migrationState(root: root) {
        case .clean?, .nothingToMove?, .backedUp?: return true
        case .backupFailed?, .refused?, nil: return false
        }
    }

    /// Summary lines for catalog.log, buffered until DashboardState has
    /// opened the file (the migration can run before the dashboard exists —
    /// PersonFinderModel's `savedProfiles` initializer calls `listAll()`).
    /// Drained by `drainPendingCatalogLogLines()`.
    private static var pendingCatalogLogLines: [String] = []

    static func drainPendingCatalogLogLines() -> [String] {
        uuidMigrationLock.lock()
        defer { uuidMigrationLock.unlock() }
        let lines = pendingCatalogLogLines
        pendingCatalogLogLines.removeAll()
        return lines
    }

    /// Folders that were reported as skipped this process, so a skipped
    /// folder is logged once per launch — not on every `listAll()`.
    private static var reportedSkips = Set<String>()

    /// Why a legacy folder under `root` is still there, from the audit file:
    /// the skip reason and detail, or "not migrated yet" when the audit does
    /// not mention it. Used to refuse edits of a quarantined profile with an
    /// actionable message.
    static func quarantineReason(forLegacyFolder name: String, root: URL? = nil) -> String {
        if let entry = readUUIDMigrationReport(root: root)?.skipped.last(where: { $0.folder == name }) {
            return "\(entry.reason): \(entry.detail)"
        }
        return "not migrated yet"
    }

    /// One-shot, idempotent move of every name-keyed profile folder under
    /// `root` to `root/<UUID>/`. Safe to call before every enumeration: when
    /// every folder is already uuid-named it costs one directory listing.
    ///
    /// Order of operations (docs/people_uuid_folders_design.md, hardened
    /// after codex review 2026-09-12):
    ///   1. refuse a live root under a test host and any viewer;
    ///   2. reconcile a previous run's plan (a folder it renamed but never
    ///      recorded is recognised by the uuid at the destination);
    ///   3. classify every candidate IN MEMORY, reading only profile.json;
    ///   4. when at least one folder will move: clone the whole directory
    ///      to a backup, VERIFY it, and only then write anything;
    ///   5. persist the plan (old → new → uuid) to the audit file;
    ///   6. rename with RENAME_EXCL, checkpointing each move in the audit;
    ///   7. rewrite referencePath / legacyFolderName in the moved JSON.
    /// Nothing is ever deleted. A failed or unverified backup means zero
    /// writes, and `legacyWritesPermitted` stays false for the root.
    ///
    /// Memory: bounded by the number of profiles (a few dozen dictionaries);
    /// photo bytes are never read — the clone is a metadata operation.
    @discardableResult
    static func migrateToUUIDFoldersIfNeeded(
        root: URL? = nil,
        backupParent: URL? = nil,
        now: Date = Date()
    ) -> UUIDMigrationOutcome {
        uuidMigrationLock.lock()
        defer { uuidMigrationLock.unlock() }

        let root = (root ?? storeDir).standardizedFileURL
        let fm = FileManager.default

        // 1. Refuse the real store under a test host — same predicate the
        // file store uses — and any viewer (POI/ is synced from the master).
        do { try POIProfileFileStore.guardRoot(root) } catch {
            migrationStates[root.path] = .refused
            return .refused(error.localizedDescription)
        }
        if ViewerWriteGuard.refuse("POIStorage.migrateToUUIDFolders") {
            migrationStates[root.path] = .refused
            return .refused("viewer")
        }

        let folders = poiFolders(in: root)
        let previousReport = readUUIDMigrationReport(root: root)
        // A folder whose name is its own uuid is done. Only the rest are
        // candidates — the steady-state answer is "no candidates" and costs
        // nothing beyond the listing we needed anyway.
        let candidates = folders.filter { uuid(fromFolderName: $0.lastPathComponent) == nil }
        let unreconciled = (previousReport?.planned ?? []).filter { previousReport?.mapping[$0.old] == nil }
        let rebasedBefore = Set(previousReport?.linksRebased ?? [])
        let pendingRebase = (previousReport?.mapping ?? [:]).filter { !rebasedBefore.contains($0.key) }
        if candidates.isEmpty && unreconciled.isEmpty && pendingRebase.isEmpty {
            migrationStates[root.path] = .clean
            return .notNeeded
        }

        let clock = ContinuousClock()
        let started = clock.now
        var report = UUIDMigrationReport(startedAt: now)
        report.foldersBefore = folders.count
        // A link rebase that failed is NOT recorded in linksRebased and
        // makes the run incomplete; the next run retries it (codex
        // post-merge review 2026-09-13, People #3).
        var rebaseFailed = false
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line)
            appLog.write("[people] migration: \(line)")
            storageLog.notice("migration: \(line, privacy: .public)")
        }
        func skip(_ folder: URL, _ reason: String, _ detail: String) {
            report.skipped.append(.init(folder: folder.lastPathComponent, reason: reason, detail: detail))
            let key = root.path + "/" + folder.lastPathComponent + "#" + reason
            if !reportedSkips.contains(key) {
                reportedSkips.insert(key)
                log("skipped '\(folder.lastPathComponent)' (\(reason)): \(detail)")
            }
        }
        func finish(_ state: MigrationState) -> UUIDMigrationOutcome {
            report.finishedAt = Date()
            report.elapsedSeconds = seconds(clock.now - started)
            report.foldersAfter = poiFolders(in: root).count
            migrationStates[root.path] = state
            pendingCatalogLogLines.append(contentsOf: lines.map { "People migration: \($0)" })
            return .ran(report)
        }

        // 2. Reconcile: a previous run planned a move, renamed the folder,
        // and stopped before recording it. The uuid at the destination is
        // the proof; the mapping gets the entry it was owed.
        for planned in unreconciled {
            let old = root.appendingPathComponent(planned.old, isDirectory: true)
            let new = root.appendingPathComponent(planned.new, isDirectory: true)
            guard !fm.fileExists(atPath: old.path), fm.fileExists(atPath: new.path),
                  let json = readProfileJSON(in: new),
                  (json["uuid"] as? String)?.uppercased() == planned.uuid.uppercased()
            else { continue }
            report.mapping[planned.old] = planned.new
            report.reconciled.append(planned.old)
            log("reconciled '\(planned.old)' → \(planned.new) (renamed by an earlier run that stopped before recording it)")
            do {
                let n = try rebaseInternalLinks(in: new, from: old.path, to: new.path)
                report.linksRebased.append(planned.old)
                if n > 0 { log("rebased \(n) internal link(s) in \(planned.new)") }
            } catch {
                rebaseFailed = true
                log("links in \(planned.new) not rebased — \(error.localizedDescription); retried on the next run")
            }
        }
        // Moves an earlier run recorded but never finished rebasing.
        for (old, new) in pendingRebase where !report.linksRebased.contains(old) {
            let folder = root.appendingPathComponent(new, isDirectory: true)
            guard fm.fileExists(atPath: folder.path) else { continue }
            do {
                let n = try rebaseInternalLinks(in: folder, from: root.appendingPathComponent(old, isDirectory: true).path, to: folder.path)
                report.linksRebased.append(old)
                if n > 0 { log("rebased \(n) internal link(s) in \(new) (left over from an earlier run)") }
            } catch {
                rebaseFailed = true
                log("links in \(new) not rebased — \(error.localizedDescription); retried on the next run")
            }
        }
        if candidates.isEmpty {
            // Only reconciliation / link rebasing was owed. Record it and stop.
            try? writeUUIDMigrationReport(merged(previousReport, with: report), root: root)
            report.complete = !rebaseFailed
            return finish(.clean)
        }

        // 3. Classify IN MEMORY. `plan` holds the folders that will move;
        // every profile.json is read once, nothing is written.
        struct Move {
            let source: URL
            let uuid: UUID
            var json: [String: Any]
            let mintedUUID: Bool
        }
        var plan: [Move] = []
        var ownersByUUID: [UUID: [URL]] = [:]
        // Folders already keyed by uuid own that uuid too — a legacy folder
        // pointing at one of them must not be renamed onto it.
        for folder in folders {
            if let id = uuid(fromFolderName: folder.lastPathComponent) {
                ownersByUUID[id, default: []].append(folder)
            }
        }
        for folder in candidates {
            if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                skip(folder, UUIDMigrationSkip.symlink, "a symbolic link is never moved")
                continue
            }
            let profileURL = folder.appendingPathComponent("profile.json")
            guard fm.fileExists(atPath: profileURL.path) else {
                skip(folder, UUIDMigrationSkip.noProfile, "no profile.json — left in place")
                continue
            }
            guard let json = readProfileJSON(in: folder), json["name"] is String else {
                skip(folder, UUIDMigrationSkip.malformedJSON, "profile.json could not be read — left in place, not deleted")
                continue
            }
            let existing = (json["uuid"] as? String).flatMap(UUID.init(uuidString:))
            let id = existing ?? UUID()
            ownersByUUID[id, default: []].append(folder)
            plan.append(Move(source: folder, uuid: id, json: json, mintedUUID: existing == nil))
        }
        // Duplicate uuids: skip every legacy folder that shares one, name them all.
        let duplicates = ownersByUUID.filter { $0.value.count > 1 }
        for (id, owners) in duplicates {
            let paths = owners.map(\.path).sorted().joined(separator: " | ")
            for owner in owners where uuid(fromFolderName: owner.lastPathComponent) == nil {
                skip(owner, UUIDMigrationSkip.duplicateUUID,
                     "uuid \(id.uuidString) is claimed by more than one folder: \(paths)")
            }
        }
        plan.removeAll { duplicates[$0.uuid] != nil }
        // A destination that already exists (a uuid folder from another
        // source) is refused up front — it would fail RENAME_EXCL anyway,
        // and the plan must not promise a move that cannot happen.
        plan.removeAll { move in
            let destination = root.appendingPathComponent(folderName(for: move.uuid), isDirectory: true)
            guard fm.fileExists(atPath: destination.path) else { return false }
            skip(move.source, UUIDMigrationSkip.destinationExists,
                 "\(destination.lastPathComponent) already exists — left in place")
            return true
        }

        guard !plan.isEmpty else {
            // Everything left is quarantined; the migration wrote nothing
            // into any profile folder (only the audit file).
            try? writeUUIDMigrationReport(merged(previousReport, with: report), root: root)
            return finish(.nothingToMove)
        }

        // 4. BACKUP FIRST — the whole directory, verified, before any write.
        let stamp = trashTimestamp(now)
        let parent = (backupParent ?? defaultBackupParent(for: root)).standardizedFileURL
        var backup = parent.appendingPathComponent("POI-backup-\(stamp)", isDirectory: true)
        if fm.fileExists(atPath: backup.path) {
            backup = parent.appendingPathComponent("POI-backup-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        let backupStart = clock.now
        switch cloneOrCopyDirectory(from: root, to: backup) {
        case .success(let method):
            report.backupSeconds = seconds(clock.now - backupStart)
            let verified = verifyBackup(of: root, at: backup, folders: plan.map(\.source))
            report.backupPath = backup.path
            report.backupMethod = method
            report.backupVerified = verified
            guard verified else {
                log("BACKUP NOT VERIFIED at \(backup.path) (via \(method)) — nothing moved, nothing written")
                return finish(.backupFailed)
            }
            log("backup of \(folders.count) folder(s) at \(backup.path) via \(method) in \(format(report.backupSeconds)) s, verified")
        case .failure(let error):
            // No backup, no migration. Everything stays as it was.
            log("BACKUP FAILED, nothing moved, nothing written: \(error.localizedDescription)")
            return finish(.backupFailed)
        }

        // 5. Durable plan BEFORE the first rename.
        report.planned = plan.map {
            PlannedMove(old: $0.source.lastPathComponent, new: folderName(for: $0.uuid), uuid: $0.uuid.uuidString)
        }
        do {
            try writeUUIDMigrationReport(merged(previousReport, with: report), root: root)
        } catch {
            log("could not write the plan to \(uuidMigrationFileName) — nothing moved: \(error.localizedDescription)")
            return finish(.backupFailed)
        }

        // 6./7. Rename, one folder at a time, checkpointing each move.
        let renameStart = clock.now
        for var move in plan {
            let destination = root.appendingPathComponent(folderName(for: move.uuid), isDirectory: true)
            // A minted uuid is written into the OLD location first (after the
            // backup, before the rename) so the identity is durable even if
            // the rename below fails.
            if move.mintedUUID {
                move.json["uuid"] = move.uuid.uuidString
                do {
                    try writeJSON(move.json, to: move.source.appendingPathComponent("profile.json"))
                } catch {
                    skip(move.source, UUIDMigrationSkip.uuidWriteFailed,
                         "could not persist a minted uuid: \(error.localizedDescription)")
                    continue
                }
            }
            let rc = renamex_np(move.source.path, destination.path, UInt32(RENAME_EXCL))
            if rc != 0 {
                let err = String(cString: strerror(errno))
                skip(move.source, UUIDMigrationSkip.renameFailed, "rename(2) failed: \(err)")
                continue
            }
            // Checkpoint the move before anything else touches the folder.
            report.mapping[move.source.lastPathComponent] = destination.lastPathComponent
            try? writeUUIDMigrationReport(merged(previousReport, with: report), root: root)
            // Rewrite referencePath and keep the old name for the audit.
            move.json["referencePath"] = destination.path
            if move.json["legacyFolderName"] == nil {
                move.json["legacyFolderName"] = move.source.lastPathComponent
            }
            do {
                try writeJSON(move.json, to: destination.appendingPathComponent("profile.json"))
            } catch {
                // The folder moved; referencePath is healed on every load, so
                // this is an audit gap, not a data problem. Say so.
                log("moved '\(move.source.lastPathComponent)' → \(destination.lastPathComponent) but could not rewrite profile.json: \(error.localizedDescription)")
            }
            // Internal absolute symlinks (dad/cover.jpg → …/dad/original.jpg)
            // follow the folder; recorded ONLY once every link is verifiably
            // rewritten, so a crash or a failure here is finished later.
            var rebased = 0
            do {
                rebased = try rebaseInternalLinks(in: destination, from: move.source.path, to: destination.path)
                report.linksRebased.append(move.source.lastPathComponent)
            } catch {
                rebaseFailed = true
                log("links in \(destination.lastPathComponent) not rebased — \(error.localizedDescription); retried on the next run")
            }
            try? writeUUIDMigrationReport(merged(previousReport, with: report), root: root)
            let name = (move.json["name"] as? String) ?? "?"
            log("'\(move.source.lastPathComponent)' → \(destination.lastPathComponent) (\(name))\(move.mintedUUID ? " [uuid minted]" : "")\(rebased > 0 ? " [\(rebased) link(s) rebased]" : "")")
        }
        report.renameSeconds = seconds(clock.now - renameStart)

        // Final record + summary.
        report.complete = report.skipped.isEmpty && !rebaseFailed
        let outcome = finish(.backedUp(backup.path))
        do { try writeUUIDMigrationReport(merged(previousReport, with: report), root: root) } catch {
            log("could not write \(uuidMigrationFileName): \(error.localizedDescription)")
        }
        let summary = "People migration: \(report.mapping.count) folder(s) → UUID"
            + (report.reconciled.isEmpty ? "" : " (\(report.reconciled.count) reconciled)")
            + ", \(report.skipped.count) skipped, backup at \(report.backupPath ?? "(none)"), "
            + "took \(format(report.elapsedSeconds)) s (rename \(format(report.renameSeconds)) s, "
            + "backup \(format(report.backupSeconds)) s)"
        appLog.write("[people] \(summary)")
        storageLog.notice("\(summary, privacy: .public)")
        pendingCatalogLogLines.append(summary)
        return outcome
    }

    /// Reverse every move recorded in `.uuid-migration.json` under `root`:
    /// rename `<UUID>/` back to its legacy name (RENAME_EXCL — a re-created
    /// legacy folder is never clobbered) and restore referencePath. Entries
    /// whose reverse rename fails are RETAINED in the audit file so a later
    /// attempt can retry them; the file is moved aside as
    /// `.uuid-migration-rolledback-<stamp>.json` only when nothing remains.
    /// Test-only entry point (no menu item); the backup clone is untouched.
    /// Returns the number of folders renamed back.
    @discardableResult
    static func rollbackUUIDMigration(root: URL? = nil, now: Date = Date()) throws -> Int {
        uuidMigrationLock.lock()
        defer { uuidMigrationLock.unlock() }
        let root = (root ?? storeDir).standardizedFileURL
        try POIProfileFileStore.guardRoot(root)
        try ViewerWriteGuard.check("POIStorage.rollbackUUIDMigration")
        guard var report = readUUIDMigrationReport(root: root) else { return 0 }
        let fm = FileManager.default
        var restored = 0
        var remaining: [String: String] = [:]
        for (old, new) in report.mapping {
            let source = root.appendingPathComponent(new, isDirectory: true)
            let destination = root.appendingPathComponent(old, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else {
                // Nothing to move back (already rolled back, or trashed by
                // the user). If the legacy folder is back, finish any links
                // an earlier rollback could not rebase (the entry was
                // retained for exactly this); otherwise keep the audit
                // honest but do not retry forever.
                if fm.fileExists(atPath: destination.path) {
                    do {
                        _ = try rebaseInternalLinks(in: destination, from: source.path, to: destination.path)
                    } catch {
                        appLog.write("[people] rollback: '\(old)' is back but its links are not — \(error.localizedDescription); entry retained")
                        remaining[old] = new
                    }
                } else {
                    appLog.write("[people] rollback: \(new) is gone; '\(old)' not restored")
                }
                continue
            }
            let rc = renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
            guard rc == 0 else {
                appLog.write("[people] rollback: could not rename \(new) back to '\(old)': \(String(cString: strerror(errno))) — entry retained")
                remaining[old] = new
                continue
            }
            let profileURL = destination.appendingPathComponent("profile.json")
            if var json = readProfileJSON(in: destination) {
                json["referencePath"] = destination.path
                try? writeJSON(json, to: profileURL)
            }
            restored += 1
            do {
                _ = try rebaseInternalLinks(in: destination, from: source.path, to: destination.path)
            } catch {
                // The folder is back; its links still name the uuid path.
                // Retained so the next rollback finishes them (codex
                // post-merge review 2026-09-13, People #3).
                appLog.write("[people] rollback: \(new) → '\(old)' but its links could not be rebased — \(error.localizedDescription); entry retained")
                remaining[old] = new
                continue
            }
            appLog.write("[people] rollback: \(new) → '\(old)'")
        }
        report.linksRebased = report.linksRebased.filter { remaining[$0] != nil }
        if remaining.isEmpty {
            let aside = root.appendingPathComponent(".uuid-migration-rolledback-\(trashTimestamp(now)).json")
            try? fm.moveItem(at: root.appendingPathComponent(uuidMigrationFileName), to: aside)
            appLog.write("[people] rollback: \(restored) folder(s) renamed back; audit moved to \(aside.lastPathComponent)")
        } else {
            report.mapping = remaining
            report.planned = report.planned.filter { remaining[$0.old] != nil }
            try writeUUIDMigrationReport(report, root: root)
            appLog.write("[people] rollback: \(restored) folder(s) renamed back; \(remaining.count) entr\(remaining.count == 1 ? "y" : "ies") retained for retry")
        }
        migrationStates[root.path] = nil
        return restored
    }

    /// The audit file under `root`, if one exists and decodes.
    static func readUUIDMigrationReport(root: URL? = nil) -> UUIDMigrationReport? {
        let url = (root ?? storeDir).appendingPathComponent(uuidMigrationFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UUIDMigrationReport.self, from: data)
    }

    private static func writeUUIDMigrationReport(_ report: UUIDMigrationReport, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: root.appendingPathComponent(uuidMigrationFileName), options: .atomic)
    }

    /// A later run keeps every earlier mapping and plan entry (rollback and
    /// reconciliation need all of them) and otherwise describes the latest run.
    private static func merged(_ previous: UUIDMigrationReport?, with latest: UUIDMigrationReport) -> UUIDMigrationReport {
        guard let previous else { return latest }
        var out = latest
        out.mapping = previous.mapping.merging(latest.mapping) { _, new in new }
        var planned = previous.planned
        for move in latest.planned where !planned.contains(move) { planned.append(move) }
        out.planned = planned
        var rebased = previous.linksRebased
        for old in latest.linksRebased where !rebased.contains(old) { rebased.append(old) }
        out.linksRebased = rebased
        return out
    }

    /// Thrown by `rebaseInternalLinks`: every link that could not be
    /// replaced, with why. The links named here still point where they
    /// did — nothing is half-done.
    struct LinkRebaseFailure: LocalizedError {
        let folder: String
        let failures: [(link: String, error: String)]
        var errorDescription: String? {
            "could not rebase \(failures.count) link(s) in \(folder): "
                + failures.map { "\($0.link): \($0.error)" }.joined(separator: "; ")
        }
    }

    /// Rewrite every symlink directly inside `folder` (and its
    /// subfolders) whose ABSOLUTE target starts with `oldPath/` so it points
    /// at the same file under `newPath/`. Relative links and links pointing
    /// elsewhere are untouched. Idempotent: a link already under `newPath`
    /// is skipped, so this can run again after a crash. The same rule the
    /// 2026-09-12 rename fix applies (POIProfileFileStore.save). Returns
    /// the number of links rewritten.
    ///
    /// Each link is replaced ATOMICALLY (`replaceSymbolicLink`) and a link
    /// that cannot be replaced is left exactly as it was; when any link
    /// fails the error is THROWN after the rest were attempted, so a
    /// caller never records the folder as rebased on partial work (codex
    /// post-merge review 2026-09-13, People #3).
    @discardableResult
    static func rebaseInternalLinks(in folder: URL, from oldPath: String, to newPath: String) throws -> Int {
        let fm = FileManager.default
        // macOS spells temp/var paths two ways (/var/… and /private/var/…);
        // a link written with one spelling must still be recognised when the
        // folder path arrives in the other.
        let oldPrefixes = pathSpellings(oldPath).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let newPrefix = newPath.hasSuffix("/") ? newPath : newPath + "/"
        guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return 0 }
        // Collect first: each replacement is prepared BESIDE its link, and a
        // still-running enumeration must not see the temporary entry.
        var links: [(link: URL, rebased: String)] = []
        for case let link as URL in entries {
            guard (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  let oldPrefix = oldPrefixes.first(where: { target.hasPrefix($0) })
            else { continue }
            links.append((link, newPrefix + target.dropFirst(oldPrefix.count)))
        }
        var count = 0
        var failures: [(link: String, error: String)] = []
        for (link, rebased) in links {
            do {
                try replaceSymbolicLink(at: link, withDestinationPath: rebased)
                count += 1
            } catch {
                failures.append((link.lastPathComponent, error.localizedDescription))
                appLog.write("[people] migration: could not rebase link \(link.lastPathComponent) in \(folder.lastPathComponent): \(error.localizedDescription)")
                storageLog.error("migration: could not rebase link \(link.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if !failures.isEmpty {
            throw LinkRebaseFailure(folder: folder.lastPathComponent, failures: failures)
        }
        return count
    }

    /// Replace the symlink at `link` so it names `destination`, atomically:
    /// the new link is created beside it under a temporary name and
    /// `rename(2)`d over it, so at every instant a link exists under the
    /// old name (before: the old target; after: the new one). The result
    /// is read back and must name `destination`. A target that does not
    /// exist is logged, not failed: it was dangling before the folder
    /// moved too, and failing it would be retried forever. (Remove-then-
    /// create lost the link to a crash between the two — codex post-merge
    /// review 2026-09-13, People #3.)
    static func replaceSymbolicLink(at link: URL, withDestinationPath destination: String) throws {
        let fm = FileManager.default
        let temp = link.deletingLastPathComponent()
            .appendingPathComponent(".\(link.lastPathComponent).rebase-\(UUID().uuidString.prefix(8))")
        try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: destination)
        guard rename(temp.path, link.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let readBack = try fm.destinationOfSymbolicLink(atPath: link.path)
        guard readBack == destination else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "\(link.lastPathComponent) reads back as \(readBack), not \(destination)",
            ])
        }
        if !fm.fileExists(atPath: link.path) {
            appLog.write("[people] migration: \(link.lastPathComponent) now names \(destination), which does not exist (it was dangling before the move too)")
        }
    }

    /// `/private/var/x` and `/var/x` (also /tmp, /etc) name the same place on
    /// macOS; both spellings of `path`, the given one first.
    static func pathSpellings(_ path: String) -> [String] {
        var out = [path]
        if path.hasPrefix("/private/") {
            out.append(String(path.dropFirst("/private".count)))
        } else if ["/var/", "/tmp/", "/etc/"].contains(where: { path.hasPrefix($0) }) {
            out.append("/private" + path)
        }
        return out
    }

    /// profile.json in `folder` as a dictionary — nil when missing or unreadable.
    private static func readProfileJSON(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Where `POI-backup-<stamp>` lands by default: beside the store in
    /// production; under a per-process sibling folder for a test host.
    static func defaultBackupParent(for root: URL) -> URL {
        let parent = root.deletingLastPathComponent()
        guard TestEnvironment.isTestHost else { return parent }
        return parent.appendingPathComponent("\(root.lastPathComponent)-backups", isDirectory: true)
    }

    /// Clone a directory hierarchy with `clonefile(2)` (APFS: shares blocks,
    /// metadata-only, seconds for thousands of photos), falling back to a
    /// real copy on a volume that cannot clone. Returns the method used.
    static func cloneOrCopyDirectory(from source: URL, to destination: URL) -> Result<String, Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        let supportsCloning = (try? source.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning ?? false
        if supportsCloning, clonefile(source.path, destination.path, 0) == 0 {
            return .success("clonefile")
        }
        let cloneErrno = errno
        do {
            try fm.copyItem(at: source, to: destination)
            return .success(supportsCloning
                            ? "copy (clonefile failed: \(String(cString: strerror(cloneErrno))))"
                            : "copy (volume does not clone)")
        } catch {
            return .failure(error)
        }
    }

    /// The backup is trusted only when it lists the same top-level entries
    /// as the store and, for every folder about to move, carries the same
    /// profile.json bytes and the same number of entries. Photo bytes are
    /// not compared — a clone shares them by construction, and reading
    /// thousands of photos here would be the memory hazard this file avoids.
    static func verifyBackup(of root: URL, at backup: URL, folders: [URL]) -> Bool {
        let fm = FileManager.default
        guard let rootNames = try? fm.contentsOfDirectory(atPath: root.path),
              let backupNames = try? fm.contentsOfDirectory(atPath: backup.path),
              Set(rootNames) == Set(backupNames)
        else { return false }
        for folder in folders {
            let mirror = backup.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            guard let original = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
                  let copy = try? Data(contentsOf: mirror.appendingPathComponent("profile.json")),
                  original == copy,
                  let a = try? fm.contentsOfDirectory(atPath: folder.path),
                  let b = try? fm.contentsOfDirectory(atPath: mirror.path),
                  a.count == b.count
            else { return false }
        }
        return true
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private static func format(_ s: Double) -> String { String(format: "%.3f", s) }
}
