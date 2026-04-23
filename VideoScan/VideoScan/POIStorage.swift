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
    static var storeDir: URL {
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
