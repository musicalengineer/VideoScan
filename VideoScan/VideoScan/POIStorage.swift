// POIStorage.swift
// Single source of truth for where Person-of-Interest (POI) data lives.
//
// Layout (issue #35):
//
//     ~/Library/Application Support/VideoScan/
//     ├── catalog.json
//     ├── metadata_cache.sqlite
//     └── POI/
//         ├── donna/
//         │   ├── profile.json
//         │   ├── apple_1234_0.heic
//         │   └── apple_1234_1.jpeg
//         ├── rick/
//         │   ├── profile.json
//         │   └── apple_5678_0.jpeg
//         └── ...
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
//
// Before this file existed, POI data lived in the git repo at
// ~/dev/VideoScan/poi_profiles/ + ~/dev/VideoScan/poi_photos/, which
// cluttered git status and embedded absolute paths in JSON. migrateLegacyIfNeeded()
// handles the one-shot move.

import Foundation

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

    /// Folder holding one POI's profile.json + photos. Name is normalized:
    /// lowercased, spaces → underscores. Matches the pre-migration convention.
    static func folder(for name: String) -> URL {
        let folderName = sanitize(name)
        return storeDir.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Full path to a POI's profile.json file.
    static func profileURL(for name: String) -> URL {
        folder(for: name).appendingPathComponent("profile.json")
    }

    /// Canonical folder-name sanitization — used for both lookup and the
    /// on-disk folder that was created when the POI was imported.
    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return trimmed.isEmpty ? "reference" : trimmed
    }

    // MARK: - Enumeration

    /// Returns the list of POI folders directly under storeDir (subfolders
    /// only; ignores stray files). Ensures migration has run first.
    static func allPOIFolders() -> [URL] {
        _ = migrateLegacyIfNeeded()
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: storeDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
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
    /// Returns the destination URL inside .trash on success, or nil if the
    /// source didn't exist or the move failed. The caller is responsible for
    /// logging / surfacing the failure to the user.
    ///
    /// Test override: pass `storeOverride` / `trashOverride` to redirect
    /// both ends to a sandbox. Production callers pass nil for both.
    @discardableResult
    static func trashPOIFolder(
        named name: String,
        now: Date = Date(),
        storeOverride: URL? = nil,
        trashOverride: URL? = nil
    ) -> URL? {
        let fm = FileManager.default
        let folderName = sanitize(name)
        let src = (storeOverride ?? storeDir)
            .appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return nil }

        let trashRoot = trashOverride ?? trashDir
        let stamp = trashTimestamp(now)
        let dest = trashRoot.appendingPathComponent("POI-\(folderName)-\(stamp)",
                                                    isDirectory: true)

        // Ensure trash root exists (creates intermediate `dev/VideoScan/.trash`).
        do {
            try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // If the destination already exists (sub-second collision in a test
        // loop), append a uniquifier rather than overwrite.
        var finalDest = dest
        if fm.fileExists(atPath: finalDest.path) {
            finalDest = trashRoot.appendingPathComponent(
                "POI-\(folderName)-\(stamp)-\(UUID().uuidString.prefix(8))",
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
        case destinationExists          // a POI with this name was re-created
        case ioError                    // moveItem threw for some other reason
    }

    /// Inverse of `trashPOIFolder`: moves a trashed POI folder back into
    /// `storeDir/<sanitized-name>/`. Refuses to overwrite an existing POI
    /// folder — if the user re-created the person between delete and undo,
    /// the caller must surface that to the user (non-destructive abort).
    ///
    /// Test override: pass `storeOverride` to redirect the destination
    /// into a sandbox. Production callers pass nil.
    ///
    /// Why this lives in POIStorage (not PersonFinderModel): the same
    /// safety rules apply (project policy forbids `rm` on POI data, and
    /// the sanitize() convention has to match deletePOI). Keeping the
    /// inverse next to the forward op makes both easier to audit.
    static func restorePOIFolder(
        from trashURL: URL,
        named name: String,
        storeOverride: URL? = nil
    ) -> RestoreResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashURL.path) else { return .sourceMissing }

        let folderName = sanitize(name)
        let dest = (storeOverride ?? storeDir)
            .appendingPathComponent(folderName, isDirectory: true)

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

    // MARK: - Migration

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

        let newFolder = folder(for: name)
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
}
