// BundleExporter.swift
// The export half of the bundle "whole shebang" feature — extracted verbatim
// from BundleExportImport.swift (refactor 2026-06-25). Writes the
// <name>.videoscanbundle/ tree (manifest/catalog/volumes/settings JSON plus
// the people/ and deltas/ subtrees). Serialization formats, file paths,
// symlink-resolution and skip/warning logic are load-bearing and were moved
// byte-for-byte. See the file-header comment in BundleExportImport.swift for
// the export-safety story (symlink dereferencing, profile.json validation)
// in BundleExportImport.swift.
// (Swift `enum` with only static members ≈ a C++ namespace of free functions.)

import Foundation
import AppKit

// MARK: - Dossier delta location (testable indirection)

/// Source location of the dossier JSONL deltas that workers append to.
/// Wrapped in a namespace so tests can stub the directory; production
/// always reads from `/Volumes/Crucial2TB/dossier-deltas/`.
///
/// The deltas are the write-ahead log behind catalog.json's dossier
/// fields — see docs/database_design.md. Bundling them belt-and-suspenders
/// covers the case where catalog.json itself is corrupt at restore time.
enum DossierDeltaPaths {
    /// Live source directory in production. Tests override via
    /// `BundleExporter.writeBundle(..., dossierDeltaDirOverride:)`.
    static let liveDir = URL(fileURLWithPath: "/Volumes/Crucial2TB/dossier-deltas",
                             isDirectory: true)

    /// On-disk path of the integrity manifest the merger keeps in lock-step
    /// with catalog.json. Optional: a missing file is skipped quietly
    /// (some installs don't have one yet).
    static let liveManifestSha256: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("VideoScan/manifest.sha256")
    }()
}

// MARK: - Exporter

enum BundleExporter {

    struct Summary {
        var path: URL
        var manifest: BundleManifest
        /// Files we tried to bundle but couldn't (typically symlinks whose
        /// target is unreachable on this machine). Each entry is
        /// (relative path inside POI, reason). Surfaced in the post-export
        /// alert so Rick knows the bundle is missing a few photos.
        var exportWarnings: [(path: String, reason: String)]

        /// Reason string used by the export-time profile.json validator.
        /// Stable substring — the post-export alert checks for it to decide
        /// whether to lead with the loud "re-export recommended" banner.
        static let missingProfileJSONReason =
            "profile.json missing after export — POI not safely importable"

        /// Count of POIs whose profile.json failed the export-time validator.
        /// Drives the warning banner in the post-export alert.
        var missingProfileJSONCount: Int {
            exportWarnings.filter {
                $0.reason.contains(Self.missingProfileJSONReason)
            }.count
        }
    }

    /// Write a complete bundle. `bundleURL` should end in `.videoscanbundle`.
    /// Overwrites any existing bundle at the same path.
    ///
    /// Purge policy: removed-from-catalog records are LOCAL-ONLY. They are
    /// stripped from the bundled catalog.json (and the manifest's record
    /// count) so a bundle moved to another Mac mirrors the user's curated
    /// view, not their personal trash bin. The caller can compute the
    /// excluded count from `records.count - summary.manifest.counts.records`
    /// and log it for discoverability.
    @MainActor
    static func writeBundle(records inputRecords: [VideoRecord],
                            scanTargets: [CatalogScanTarget],
                            to bundleURL: URL,
                            dossierDeltaDirOverride: URL? = nil,
                            catalogManifestOverride: URL? = nil) throws -> Summary {
        guard bundleURL.pathExtension == "videoscanbundle" else {
            throw BundleError.badExtension
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // Global-inert filter applied before serialization — purged records
        // never cross the bundle boundary. Single filter site keeps the
        // record-count math in the manifest consistent with what's actually
        // encoded in catalog.json.
        let records = pfActiveRecords(inputRecords)

        // 1. Catalog — same shape as the standalone catalog export so a
        //    catalog.json pulled out of a bundle could be imported via the
        //    existing "Import Catalog…" entry point.
        let catalogSnapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: records,
            savedFromHost: CatalogHost.currentName
        )
        // Encode through the Sendable DTO — VideoRecord is Decodable-only
        // (step 5b); CatalogSnapshotDTO owns the single encoder.
        try encoder.encode(CatalogSnapshotDTO(catalogSnapshot))
            .write(to: bundleURL.appendingPathComponent("catalog.json"), options: .atomic)

        // 2. Volumes — exclude the RAM scratch volume (it's plumbing, not
        //    archive metadata, and its path is machine-specific anyway).
        let volumeSnapshots = scanTargets
            .filter { !$0.searchPath.contains("VideoScan_Temp") }
            .map(VolumeMetadataSnapshot.init(from:))
        let volumesSnapshot = VolumesSnapshot(savedAt: Date(), volumes: volumeSnapshots)
        try encoder.encode(volumesSnapshot)
            .write(to: bundleURL.appendingPathComponent("volumes.json"), options: .atomic)

        // 3. Settings — pull current PersonFinderSettings from UserDefaults.
        //    No need for a live PersonFinderModel; restored() reads from
        //    the same prefix the model writes to.
        let settings = PersonFinderSettings.restored()
        let settingsSnapshot = SettingsSnapshot(from: settings)
        try encoder.encode(settingsSnapshot)
            .write(to: bundleURL.appendingPathComponent("settings.json"), options: .atomic)

        // 4. People — copy each POI folder verbatim, BUT resolve symlinks at
        //    copy time. profile.json + photos travel together; referencePath
        //    in the JSON gets re-derived on the destination machine, so we
        //    don't have to rewrite it here.
        let peopleDir = bundleURL.appendingPathComponent("people", isDirectory: true)
        try fm.createDirectory(at: peopleDir, withIntermediateDirectories: true)
        var photoCount = 0
        var photoBytes: Int64 = 0
        var warnings: [(String, String)] = []
        let poiFolders = POIStorage.allPOIFolders()
        for src in poiFolders {
            let dest = peopleDir.appendingPathComponent(src.lastPathComponent, isDirectory: true)
            let perPOIWarnings = try copyResolvingSymlinks(from: src, to: dest)
            for w in perPOIWarnings {
                warnings.append(("\(src.lastPathComponent)/\(w.relPath)", w.reason))
            }

            // Validate that profile.json made it into `dest`. This catches the
            // failure mode behind the 2026-05-15 MS→M5 incident, where the
            // old exporter shipped POI folders containing only photos. The
            // importer caught it then, but only after a half-broken bundle
            // had already been moved between machines; this pass catches it
            // at export time so Rick can re-export immediately. Per spec we
            // DO NOT fail the export or delete the partial folder.
            if let reason = profileJSONValidationReason(dest: dest) {
                warnings.append(("\(src.lastPathComponent)/profile.json", reason))
            }

            // Tally photo size for the manifest sizes block (recursive walk).
            if let it = fm.enumerator(at: dest,
                                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let k as URL in it {
                    guard referencePhotoExts.contains(k.pathExtension.lowercased()) else { continue }
                    photoCount += 1
                    if let v = try? k.resourceValues(forKeys: [.fileSizeKey]),
                       let s = v.fileSize {
                        photoBytes += Int64(s)
                    }
                }
            }
        }

        // 5. Dossier JSONL deltas — the worker write-ahead log. catalog.json
        //    already carries the dossier fields, but the deltas are the
        //    durable source-of-truth that survives a corrupted catalog.
        //    See docs/database_design.md for the recovery story. Resilient:
        //    if the source dir is missing (Crucial2TB unmounted), the export
        //    still succeeds — Rick gets a warning, not a thrown error.
        let deltaSrcDir = dossierDeltaDirOverride ?? DossierDeltaPaths.liveDir
        let deltaSummary = copyDossierDeltas(from: deltaSrcDir,
                                             into: bundleURL,
                                             warnings: &warnings)

        // 6. Catalog integrity manifest (manifest.sha256). Optional: a
        //    missing file is skipped silently — some installs predate the
        //    merger's manifest writer.
        let manifestSrc = catalogManifestOverride ?? DossierDeltaPaths.liveManifestSha256
        copyCatalogManifestIfPresent(from: manifestSrc, into: bundleURL)

        // 7. Manifest — written last so a partial bundle without manifest.json
        //    is unambiguously detectable on import.
        let totalBytes = directorySize(bundleURL)
        let manifest = BundleManifest(
            bundleVersion: BundleManifest.currentVersion,
            exportedAt: Date(),
            exportedFromHost: CatalogHost.currentName,
            appVersion: BuildInfo.version,
            appBuild: BuildInfo.build,
            counts: .init(
                records: records.count,
                volumes: volumeSnapshots.count,
                people: poiFolders.count,
                referencePhotos: photoCount,
                dossierDeltaLines: deltaSummary.lineCount
            ),
            sizes: .init(totalBytes: totalBytes,
                         referencePhotoBytes: photoBytes,
                         dossierDeltaBytes: deltaSummary.byteCount)
        )
        try encoder.encode(manifest)
            .write(to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)

        return Summary(path: bundleURL, manifest: manifest, exportWarnings: warnings)
    }

    /// Inspect the just-copied POI directory and return a warning reason if
    /// profile.json is missing, empty, unreadable, or fails to decode as a
    /// `POIProfile`. Returns nil when the POI is safely importable.
    ///
    /// This is the export-time mirror of `BundleImporter.validatePOIDir`.
    /// We deliberately catch the same failure modes at export so a broken
    /// bundle never crosses machine boundaries undetected — the 2026-05-15
    /// incident burned three POIs because the breakage was only visible on
    /// the receiving Mac.
    static func profileJSONValidationReason(dest: URL) -> String? {
        let fm = FileManager.default
        let profileURL = dest.appendingPathComponent("profile.json")
        guard fm.fileExists(atPath: profileURL.path) else {
            return Summary.missingProfileJSONReason
        }
        guard let data = try? Data(contentsOf: profileURL), !data.isEmpty else {
            return Summary.missingProfileJSONReason + " (file empty)"
        }
        guard (try? JSONDecoder().decode(POIProfile.self, from: data)) != nil else {
            return Summary.missingProfileJSONReason + " (file did not decode)"
        }
        return nil
    }

    /// Summary returned by `copyDossierDeltas`. Drives manifest counters
    /// and the post-export alert. `lineCount` is the total non-blank
    /// JSONL lines successfully copied (0 if no deltas were available);
    /// `byteCount` is on-disk bytes inside the bundle's deltas/ subdir.
    struct DossierDeltaSummary {
        var lineCount: Int
        var byteCount: Int64
    }

    /// Copy the worker dossier JSONL deltas from `srcDir` into
    /// `bundleURL/deltas/`. Returns counts for the manifest. Failures
    /// are surfaced as bundle export warnings, NEVER as thrown errors —
    /// the catalog.json already carries the dossier fields, so a missing
    /// delta dir reduces redundancy but doesn't lose data.
    ///
    /// `nonisolated` static — pure file IO, callable from tests off the
    /// main actor.
    nonisolated static func copyDossierDeltas(
        from srcDir: URL,
        into bundleURL: URL,
        warnings: inout [(String, String)]
    ) -> DossierDeltaSummary {
        let fm = FileManager.default

        // Source dir missing (Crucial2TB unmounted, or fresh install): warn
        // and return empty. The bundle still has catalog.json with dossier
        // fields embedded; this just means no belt for the suspenders.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: srcDir.path, isDirectory: &isDir), isDir.boolValue else {
            warnings.append(("deltas/",
                             "dossier delta dir not available at \(srcDir.path) — " +
                             "bundle ships catalog only; no JSONL belt for the suspenders"))
            return DossierDeltaSummary(lineCount: 0, byteCount: 0)
        }

        // Destination dir inside the bundle.
        let destDir = bundleURL.appendingPathComponent("deltas", isDirectory: true)
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            warnings.append(("deltas/",
                             "could not create deltas/ in bundle: \(error.localizedDescription)"))
            return DossierDeltaSummary(lineCount: 0, byteCount: 0)
        }

        // Enumerate *.jsonl files at the top level only — workers don't
        // create subdirs. Sorted for deterministic copy order (eases test
        // assertions and audit log scanning).
        let entries: [URL]
        do {
            let kids = try fm.contentsOfDirectory(at: srcDir,
                                                  includingPropertiesForKeys: [.isRegularFileKey])
            entries = kids
                .filter { $0.pathExtension.lowercased() == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            warnings.append(("deltas/",
                             "could not enumerate \(srcDir.path): \(error.localizedDescription)"))
            return DossierDeltaSummary(lineCount: 0, byteCount: 0)
        }

        var totalLines = 0
        var totalBytes: Int64 = 0
        for src in entries {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            do {
                try fm.copyItem(at: src, to: dest)
            } catch {
                warnings.append(("deltas/\(src.lastPathComponent)",
                                 "copy failed: \(error.localizedDescription)"))
                continue
            }
            // Count lines for the manifest. Streaming line count avoids
            // loading huge JSONLs into RAM (Rick's m4.jsonl was 18 MB at
            // first audit and grows).
            if let lc = countJSONLLines(at: dest) {
                totalLines += lc
            }
            if let v = try? dest.resourceValues(forKeys: [.fileSizeKey]),
               let bytes = v.fileSize {
                totalBytes += Int64(bytes)
            }
        }

        return DossierDeltaSummary(lineCount: totalLines, byteCount: totalBytes)
    }

    /// Streaming non-blank line count for a JSONL file. Returns nil if
    /// the file can't be opened.
    nonisolated static func countJSONLLines(at url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var count = 0
        var leftover = ""
        let chunkSize = 64 * 1024
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let text = leftover + (String(data: chunk, encoding: .utf8) ?? "")
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            for piece in parts.dropLast() {
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    count += 1
                }
            }
            leftover = String(parts.last ?? "")
        }
        if !leftover.trimmingCharacters(in: .whitespaces).isEmpty {
            count += 1
        }
        return count
    }

    /// Copy `~/Library/Application Support/VideoScan/manifest.sha256`
    /// into the bundle as `catalog-manifest.sha256` if it exists. Silent
    /// on failure — this is a nice-to-have, not load-bearing.
    nonisolated static func copyCatalogManifestIfPresent(from src: URL, into bundleURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        let dest = bundleURL.appendingPathComponent("catalog-manifest.sha256")
        try? fm.copyItem(at: src, to: dest)
    }

    /// Recursively sum file sizes under `url`. Used for the manifest size
    /// block; precise enough for the post-export "size on disk" alert.
    /// Was `fileprivate` in BundleExportImport.swift; relaxed to internal so
    /// the importer's legacy-manifest synthesizer (now in its own file) can
    /// reuse it.
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let it = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        for case let item as URL in it {
            guard let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true,
                  let s = v.fileSize else { continue }
            total += Int64(s)
        }
        return total
    }

    /// Recursively copy `src` to `dest`, but dereference any symlinks
    /// encountered. Plain `copyItem(at:to:)` preserves symlinks, which is
    /// useless when the bundle is going to another Mac that doesn't have the
    /// symlink target. We walk the tree ourselves and copy file contents.
    ///
    /// Returns warnings for entries we couldn't materialize (dangling
    /// symlinks, unreadable files). The export still succeeds — Rick gets a
    /// list of what was skipped in the post-export alert.
    ///
    /// Memory: copies file-by-file via FileManager.copyItem (which streams
    /// internally — no whole-file buffering in Swift land). Worst case is
    /// one file's transfer buffer at a time. Safe for any size POI folder.
    ///
    /// Swift's `URL.resolvingSymlinksInPath()` ≈ C's `realpath()`.
    private static func copyResolvingSymlinks(from src: URL,
                                              to dest: URL) throws
        -> [(relPath: String, reason: String)]
    {
        let fm = FileManager.default
        var warnings: [(String, String)] = []

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // Walk src non-recursively first, then recurse into subdirs we create.
        guard let entries = try? fm.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return warnings
        }

        for entry in entries {
            let name = entry.lastPathComponent
            let outURL = dest.appendingPathComponent(name)

            // Use destinationOfSymbolicLink to check rather than resourceValues
            // because resourceValues follows the link transparently on macOS.
            let attrs = try? fm.attributesOfItem(atPath: entry.path)
            let typeRaw = attrs?[.type] as? FileAttributeType
            let isSymlink = (typeRaw == .typeSymbolicLink)

            if isSymlink {
                // Resolve the link target and copy the underlying file/dir.
                let resolved = entry.resolvingSymlinksInPath()
                guard fm.fileExists(atPath: resolved.path) else {
                    warnings.append((name, "dangling symlink → \(resolved.path)"))
                    continue
                }
                let resolvedAttrs = try? fm.attributesOfItem(atPath: resolved.path)
                let resolvedIsDir = (resolvedAttrs?[.type] as? FileAttributeType) == .typeDirectory
                do {
                    if resolvedIsDir {
                        // Recurse into the resolved directory to also dereference
                        // any inner symlinks. Rare but possible.
                        let sub = try copyResolvingSymlinks(from: resolved, to: outURL)
                        for s in sub {
                            warnings.append(("\(name)/\(s.relPath)", s.reason))
                        }
                    } else {
                        try fm.copyItem(at: resolved, to: outURL)
                    }
                } catch {
                    warnings.append((name, "copy of symlink target failed: \(error.localizedDescription)"))
                }
                continue
            }

            // Regular file or directory.
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            do {
                if isDir {
                    let sub = try copyResolvingSymlinks(from: entry, to: outURL)
                    for s in sub {
                        warnings.append(("\(name)/\(s.relPath)", s.reason))
                    }
                } else {
                    try fm.copyItem(at: entry, to: outURL)
                }
            } catch {
                warnings.append((name, "copy failed: \(error.localizedDescription)"))
            }
        }

        return warnings
    }
}
