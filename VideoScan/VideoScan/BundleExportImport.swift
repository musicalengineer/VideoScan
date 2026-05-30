// BundleExportImport.swift
// One-shot "whole shebang" export/import so the user can move their entire
// VideoScan world from one Mac to another (Mac Studio → MacBook Pro is the
// driving scenario). The bundle is a directory `<name>.videoscanbundle/`
// containing four JSON files plus the wholesale POI folder tree:
//
//     <name>.videoscanbundle/
//     ├── manifest.json     // version, host, counts, total size
//     ├── catalog.json      // existing CatalogSnapshot — records
//     ├── volumes.json      // per-volume metadata (role, trust, media, …)
//     ├── settings.json     // machine-portable PersonFinderSettings only
//     └── people/
//         └── <sanitized-name>/
//             ├── profile.json
//             └── reference photos (jpg/heic/…)
//
// "Machine-portable" means we deliberately drop fields that mean different
// things on different machines: pythonPath, recognitionScript, referencePath
// (re-derived from POI folder layout on import), outputDir.
//
// IMPORT SAFETY (post May-2026 incident):
//   The previous version of installPOIs did a naive
//       removeItem(dest); copyItem(src, dest)
//   loop. When the bundle lived on iCloud Drive, iCloud-evicted reference
//   photos enumerated fine but copyItem produced an empty destination with no
//   thrown error — 5 of Rick's 13 POIs were destroyed on M5 import. The
//   importer now:
//     A. Materializes (downloads) iCloud-evicted POI contents before copying
//     B. Wraps each POI in try/catch so one failure doesn't kill the run
//     C. Copies to a sibling temp dir, validates, then atomically swaps;
//        the displaced original is moved to ~/dev/VideoScan/.trash/ rather
//        than rm -rf'd, per project policy
//     D. Validates profile.json decodes after copy before swapping in
//   Plus conflict resolution: when bundle and local both have a POI of the
//   same name, the side with MORE reference photos wins (with mtime tiebreak),
//   so a stale/empty bundle entry can never silently overwrite richer local
//   data.
//
// EXPORT SAFETY:
//   POI folders frequently contain symlinks pointing at Mac-Studio-only paths
//   (e.g. ~/dev/VideoScan/output/cluster_faces/...). copyItem preserves the
//   symlink, which is dead on every other machine. The exporter now resolves
//   symlinks and copies the target's bytes; unreachable targets are logged
//   and reported in the export result.

import Foundation
import AppKit

// MARK: - Snapshot Types

struct BundleManifest: Codable {
    static let currentVersion = 1

    var bundleVersion: Int = Self.currentVersion
    var exportedAt: Date
    var exportedFromHost: String
    var appVersion: String
    var appBuild: String
    var counts: Counts
    var sizes: Sizes

    struct Counts: Codable {
        var records: Int
        var volumes: Int
        var people: Int
        var referencePhotos: Int
    }

    struct Sizes: Codable {
        /// Total size of the bundle on disk in bytes (whole tree).
        var totalBytes: Int64
        /// Bytes occupied by reference photos (the bulky part).
        var referencePhotoBytes: Int64
    }
}

struct VolumeMetadataSnapshot: Codable {
    var searchPath: String
    var phase: String          // VolumePhase rawValue
    var role: String           // VolumeRole rawValue
    var trust: String          // VolumeTrust rawValue
    var mediaTech: String      // VolumeMediaTech rawValue
    var filesystem: String
    var purchaseYear: Int?
    var capacityTB: Double?
    var notes: String
    var lastScannedDate: Date?
    // §1B Retire — three optional fields. Legacy bundles (pre-§1B) decode
    // these as nil via decodeIfPresent and round-trip cleanly.
    var retiredAt: Date?
    var retiredReason: String?
    var retiredWitnesses: [String]?

    @MainActor
    init(from target: CatalogScanTarget) {
        self.searchPath = target.searchPath
        self.phase = target.phase.rawValue
        self.role = target.role.rawValue
        self.trust = target.trust.rawValue
        self.mediaTech = target.mediaTech.rawValue
        self.filesystem = target.filesystem
        self.purchaseYear = target.purchaseYear
        self.capacityTB = target.capacityTB
        self.notes = target.notes
        self.lastScannedDate = target.lastScannedDate
        self.retiredAt = target.retiredAt
        self.retiredReason = target.retiredReason
        self.retiredWitnesses = target.retiredWitnesses
    }
}

struct VolumesSnapshot: Codable {
    var version: Int = 1
    var savedAt: Date
    var volumes: [VolumeMetadataSnapshot]
}

/// Subset of `PersonFinderSettings` that's portable between machines. We
/// skip pythonPath / recognitionScript (auto-detected per-machine),
/// referencePath (re-derived from the POI folder), and outputDir
/// (machine-specific).
struct SettingsSnapshot: Codable {
    var version: Int = 1
    var savedAt: Date

    var personName: String
    var threshold: Float
    var minFaceConfidence: Float
    var frameStep: Int
    var pad: Double
    var minDuration: Double
    var minPresenceSecs: Double
    var requirePrimary: Bool
    var concurrency: Int
    var skipBundles: Bool
    var skipCatalogBadFiles: Bool
    var largestFaceOnly: Bool
    var previewRate: Int
    var arcfaceThreshold: Float
    var recognitionEngine: String

    init(from settings: PersonFinderSettings) {
        self.savedAt = Date()
        self.personName = settings.personName
        self.threshold = settings.threshold
        self.minFaceConfidence = settings.minFaceConfidence
        self.frameStep = settings.frameStep
        self.pad = settings.pad
        self.minDuration = settings.minDuration
        self.minPresenceSecs = settings.minPresenceSecs
        self.requirePrimary = settings.requirePrimary
        self.concurrency = settings.concurrency
        self.skipBundles = settings.skipBundles
        self.skipCatalogBadFiles = settings.skipCatalogBadFiles
        self.largestFaceOnly = settings.largestFaceOnly
        self.previewRate = settings.previewRate
        self.arcfaceThreshold = settings.arcfaceThreshold
        self.recognitionEngine = settings.recognitionEngine.rawValue
    }

    /// Apply portable fields onto a target settings instance, leaving
    /// machine-specific fields (pythonPath, etc.) untouched.
    func apply(to settings: inout PersonFinderSettings) {
        settings.personName = personName
        settings.threshold = threshold
        settings.minFaceConfidence = minFaceConfidence
        settings.frameStep = frameStep
        settings.pad = pad
        settings.minDuration = minDuration
        settings.minPresenceSecs = minPresenceSecs
        settings.requirePrimary = requirePrimary
        settings.concurrency = concurrency
        settings.skipBundles = skipBundles
        settings.skipCatalogBadFiles = skipCatalogBadFiles
        settings.largestFaceOnly = largestFaceOnly
        settings.previewRate = previewRate
        settings.arcfaceThreshold = arcfaceThreshold
        if let eng = RecognitionEngine(rawValue: recognitionEngine) {
            settings.recognitionEngine = eng
        }
    }
}

// MARK: - Errors

enum BundleError: LocalizedError {
    case badExtension
    case manifestMissing
    case manifestVersionUnsupported(Int)
    case decode(String)
    case iCloudDownloadTimeout(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .badExtension:
            return "Bundle path must end in “.videoscanbundle”."
        case .manifestMissing:
            return "Selected folder isn’t a VideoScan bundle (no manifest.json found)."
        case .manifestVersionUnsupported(let v):
            return "Bundle was made with a newer VideoScan format (v\(v)). Update VideoScan and try again."
        case .decode(let msg):
            return "Failed to read bundle: \(msg)"
        case .iCloudDownloadTimeout(let path):
            return "Timed out waiting for iCloud to download: \(path)"
        case .validationFailed(let msg):
            return "Validation failed: \(msg)"
        }
    }
}

// MARK: - Image-extension whitelist (shared by exporter, importer, ref counter)

private let referencePhotoExts: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"
]

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
                            to bundleURL: URL) throws -> Summary {
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
        try encoder.encode(catalogSnapshot)
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

        // 5. Manifest — written last so a partial bundle without manifest.json
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
                referencePhotos: photoCount
            ),
            sizes: .init(totalBytes: totalBytes, referencePhotoBytes: photoBytes)
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

    /// Recursively sum file sizes under `url`. Used for the manifest size
    /// block; precise enough for the post-export "size on disk" alert.
    /// fileprivate so the importer's legacy-manifest synthesizer can reuse it.
    fileprivate static func directorySize(_ url: URL) -> Int64 {
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

// MARK: - Importer

enum BundleImporter {

    struct Payload {
        var manifest: BundleManifest
        var catalog: CatalogSnapshot
        var volumes: VolumesSnapshot
        var settings: SettingsSnapshot
        var poiFoldersInBundle: [URL]
        /// Manifest export timestamp — falls back to manifest.exportedAt when
        /// per-file mtimes aren't available (e.g. all-iCloud-evicted source).
        var bundleExportedAt: Date
    }

    /// Per-POI conflict-resolution timeout for iCloud materialization.
    /// 60s per POI is generous; the typical POI is a few MB of HEIC photos.
    static let iCloudMaterializeTimeoutSeconds: TimeInterval = 60

    /// Read and decode a bundle directory. Returns the parsed payload — the
    /// caller (VideoScanModel) is responsible for merging into live state.
    /// Throws if the bundle is malformed or from a newer format version.
    ///
    /// Tolerates bundles without `manifest.json` (legacy or partial exports
    /// where the manifest write was interrupted): a placeholder manifest is
    /// synthesized so the rest of the import flow works. A bundle without
    /// `catalog.json` is still considered malformed and rejects below.
    static func read(from bundleURL: URL) throws -> Payload {
        let fm = FileManager.default

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let manifest: BundleManifest
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                manifest = try decoder.decode(BundleManifest.self, from: data)
            } catch {
                throw BundleError.decode("manifest.json — \(error.localizedDescription)")
            }
            guard manifest.bundleVersion <= BundleManifest.currentVersion else {
                throw BundleError.manifestVersionUnsupported(manifest.bundleVersion)
            }
        } else {
            manifest = synthesizeLegacyManifest(bundleURL: bundleURL, fm: fm)
        }

        let catalog: CatalogSnapshot = try decode(decoder, at: bundleURL.appendingPathComponent("catalog.json"),
                                                  label: "catalog.json")
        let volumes: VolumesSnapshot = try decode(decoder, at: bundleURL.appendingPathComponent("volumes.json"),
                                                  label: "volumes.json")
        let settings: SettingsSnapshot = try decode(decoder, at: bundleURL.appendingPathComponent("settings.json"),
                                                    label: "settings.json")

        // Resolve pairedWith back-references inside the imported records,
        // matching the standalone import path.
        let importedByID = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
        for rec in catalog.records {
            if let pid = rec.pendingPairedWithID {
                rec.pairedWith = importedByID[pid]
                rec.pendingPairedWithID = nil
            }
        }

        // Enumerate people/* subfolders.
        let peopleDir = bundleURL.appendingPathComponent("people", isDirectory: true)
        let poiFolders: [URL]
        if let kids = try? fm.contentsOfDirectory(at: peopleDir,
                                                  includingPropertiesForKeys: [.isDirectoryKey]) {
            poiFolders = kids.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        } else {
            poiFolders = []
        }

        return Payload(manifest: manifest,
                       catalog: catalog,
                       volumes: volumes,
                       settings: settings,
                       poiFoldersInBundle: poiFolders,
                       bundleExportedAt: manifest.exportedAt)
    }

    private static func decode<T: Decodable>(_ decoder: JSONDecoder,
                                             at url: URL,
                                             label: String) throws -> T {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BundleError.decode("\(label) — \(error.localizedDescription)")
        }
    }

    /// Build a placeholder `BundleManifest` for a bundle that lacks one. Used
    /// for legacy bundles produced before the manifest was added, and for
    /// bundles whose export was interrupted before the final manifest write.
    /// Fields are populated from filesystem inspection so the rest of the
    /// import flow has reasonable values (counts/sizes drive the success
    /// alert; `exportedAt` is the mtime tiebreaker on the bundle side).
    private static func synthesizeLegacyManifest(bundleURL: URL,
                                                 fm: FileManager) -> BundleManifest {
        let peopleDir = bundleURL.appendingPathComponent("people", isDirectory: true)
        var peopleCount = 0
        var refPhotoCount = 0
        var refPhotoBytes: Int64 = 0
        if let kids = try? fm.contentsOfDirectory(at: peopleDir,
                                                  includingPropertiesForKeys: [.isDirectoryKey]) {
            for kid in kids where (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                peopleCount += 1
                if let enumerator = fm.enumerator(at: kid,
                                                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let url as URL in enumerator {
                        let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard rv?.isRegularFile == true else { continue }
                        if url.lastPathComponent == "profile.json" { continue }
                        refPhotoCount += 1
                        refPhotoBytes += Int64(rv?.fileSize ?? 0)
                    }
                }
            }
        }

        let totalBytes = BundleExporter.directorySize(bundleURL)
        let bundleMtime = (try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        return BundleManifest(
            bundleVersion: 0,
            exportedAt: bundleMtime,
            exportedFromHost: "unknown (legacy bundle, no manifest)",
            appVersion: "legacy",
            appBuild: "legacy",
            counts: BundleManifest.Counts(records: 0,
                                          volumes: 0,
                                          people: peopleCount,
                                          referencePhotos: refPhotoCount),
            sizes: BundleManifest.Sizes(totalBytes: totalBytes,
                                        referencePhotoBytes: refPhotoBytes)
        )
    }

    // MARK: - Result types

    /// Per-POI installation outcome from `installPOIs`. The caller folds
    /// these into a user-facing alert and an audit log line.
    struct POIInstallResult {
        /// Names that were copied into POIStorage.storeDir (bundle won).
        var installed: [String]
        /// Names where the local copy was preferred (kept untouched).
        var skipped: [(name: String, reason: String)]
        /// Names that errored during materialize/copy/validate.
        var failed: [(name: String, reason: String)]
        /// Per-POI decisions, in bundle-iteration order, suitable for an
        /// audit log line. One string per POI.
        var auditLines: [String]
    }

    // MARK: - Public entry point

    /// Copy the bundle's POI folders into ~/Library/Application Support/
    /// VideoScan/POI/, applying iCloud-aware safe-swap and richer-wins
    /// conflict resolution. The previous implementation destroyed local POIs
    /// when bundle sources were iCloud-evicted — see file-header comment.
    ///
    /// This is `async` because iCloud materialization is a polling wait that
    /// MUST NOT block the main actor. Callers `await` it from a Task.
    static func installPOIs(from poiFoldersInBundle: [URL],
                            bundleExportedAt: Date) async -> POIInstallResult {
        let fm = FileManager.default
        var installed: [String] = []
        var skipped: [(String, String)] = []
        var failed: [(String, String)] = []
        var auditLines: [String] = []

        for src in poiFoldersInBundle {
            let folderName = src.lastPathComponent
            let dest = POIStorage.storeDir.appendingPathComponent(folderName,
                                                                  isDirectory: true)

            // -- Part 1.A: materialize iCloud-evicted contents --
            //
            // Only relevant if the bundle was opened from iCloud Drive. Local
            // paths skip this step entirely (cheap check).
            do {
                try await materializeIfUbiquitous(at: src)
            } catch {
                let reason = "iCloud materialize failed: \(error.localizedDescription)"
                failed.append((folderName, reason))
                auditLines.append("[import] POI \(folderName): FAILED — \(reason)")
                continue
            }

            // -- Part 2: conflict resolution --
            let bundleRefCount = countReferencePhotos(under: src)
            let localRefCount = fm.fileExists(atPath: dest.path)
                ? countReferencePhotos(under: dest)
                : 0
            let bundleMtime = effectiveMTime(of: src, fallback: bundleExportedAt)
            let localMtime: Date? = fm.fileExists(atPath: dest.path)
                ? effectiveMTime(of: dest, fallback: nil)
                : nil

            let decision = decideWinner(
                bundleRefCount: bundleRefCount,
                localRefCount: localRefCount,
                bundleMtime: bundleMtime,
                localMtime: localMtime,
                localExists: fm.fileExists(atPath: dest.path)
            )

            let auditPrefix = "[import] POI \(folderName): " +
                "bundle=(\(bundleRefCount) photos, \(formatMTime(bundleMtime))) " +
                "local=(\(localRefCount) photos, \(formatMTime(localMtime)))"

            switch decision {
            case .preferLocal(let reason):
                skipped.append((folderName, reason))
                auditLines.append("\(auditPrefix) → chose LOCAL (\(reason))")
                continue
            case .preferBundle(let reason):
                auditLines.append("\(auditPrefix) → chose BUNDLE (\(reason))")
            }

            // -- Part 1.C: copy-then-rename with .trash/ safe-swap + 1.D validate --
            do {
                try safeInstallPOI(src: src, dest: dest, folderName: folderName)
                installed.append(folderName)
            } catch {
                failed.append((folderName, error.localizedDescription))
                auditLines.append("[import]   ↳ install failed: \(error.localizedDescription)")
            }
        }

        return POIInstallResult(installed: installed,
                                skipped: skipped,
                                failed: failed,
                                auditLines: auditLines)
    }

    // MARK: - Part 1.A: iCloud materialization

    /// If `dir` lives on iCloud Drive, recursively start downloads on any
    /// non-current files and poll until they reach `.current` or we hit the
    /// per-POI timeout. No-op for local files.
    ///
    /// We do this per-POI rather than for the whole bundle so memory and
    /// time stay bounded — only one POI's worth of files are in-flight at
    /// any moment. Worst-case in-memory footprint: a URL list for one POI
    /// (typically <100 entries).
    private static func materializeIfUbiquitous(at dir: URL) async throws {
        let fm = FileManager.default
        guard fm.isUbiquitousItem(at: dir) else { return }

        // Enumerate every file in the POI dir, kick off downloads on
        // anything not-current.
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return }

        var pending: [URL] = []
        for case let url as URL in it {
            guard
                let vals = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .ubiquitousItemDownloadingStatusKey
                ]),
                vals.isRegularFile == true
            else { continue }

            if vals.ubiquitousItemDownloadingStatus != .current {
                // Try to start the download — even on a current file this is
                // a cheap no-op.
                try? fm.startDownloadingUbiquitousItem(at: url)
                pending.append(url)
            }
        }
        if pending.isEmpty { return }

        // Poll until every pending file reaches .current, or we exceed the
        // timeout. The poll interval is short enough to feel responsive but
        // not so tight that we burn CPU.
        let deadline = Date().addingTimeInterval(iCloudMaterializeTimeoutSeconds)
        while Date() < deadline {
            var stillPending: [URL] = []
            for url in pending {
                let status = (try? url.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]
                ).ubiquitousItemDownloadingStatus) ?? .notDownloaded
                if status != .current { stillPending.append(url) }
            }
            if stillPending.isEmpty { return }
            pending = stillPending

            // `Task.sleep` is the async equivalent of usleep — releases the
            // thread back to the executor instead of blocking.
            try await Task.sleep(nanoseconds: 250_000_000) // 0.25s
        }

        // Timed out — surface the first still-pending path so the caller
        // logs something useful.
        if let stuck = pending.first {
            throw BundleError.iCloudDownloadTimeout(stuck.path)
        }
    }

    // MARK: - Part 1.C & 1.D: safe-swap install

    /// Copy `src` to a sibling temp dir, validate, then atomically swap into
    /// `dest`. The displaced original is moved to ~/dev/VideoScan/.trash/
    /// rather than rm -rf'd so Rick can recover.
    ///
    /// On any failure between copy and swap, the temp dir is removed and
    /// `dest` is left untouched. This is what was missing before — the old
    /// path destroyed `dest` first and then a no-op copy left an empty hole.
    private static func safeInstallPOI(src: URL, dest: URL, folderName: String) throws {
        let fm = FileManager.default
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent("\(folderName).import-\(UUID().uuidString)",
                                    isDirectory: true)

        // Copy.
        do {
            try fm.copyItem(at: src, to: temp)
        } catch {
            // Make sure we don't leave a half-copied temp around.
            try? fm.removeItem(at: temp)
            throw error
        }

        // Validate.
        do {
            try validatePOIDir(temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        // Swap. Move-aside (NOT rm -rf) any existing dest, then move temp into place.
        if fm.fileExists(atPath: dest.path) {
            let trashURL = trashTarget(forPOI: folderName)
            try fm.createDirectory(at: trashURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: dest, to: trashURL)
            } catch {
                // If we can't move the existing dest aside, ABORT — don't
                // proceed to wipe it. Leave temp around so a human can
                // inspect it.
                throw BundleError.validationFailed(
                    "could not move existing POI aside to \(trashURL.path): \(error.localizedDescription)"
                )
            }
        }
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            // Catastrophic but recoverable: temp still exists at its sibling
            // path; the prior dest is in .trash/. Surface both paths in the
            // error so Rick can recover by hand if needed.
            throw BundleError.validationFailed(
                "swap-in failed; temp left at \(temp.path): \(error.localizedDescription)"
            )
        }
    }

    /// Validate a freshly-copied POI directory before swapping it into place.
    /// Requires profile.json to exist, be non-empty, and decode as POIProfile.
    /// Reference photo count is NOT required (>= 0 is fine) — the structure
    /// just needs to be intact.
    private static func validatePOIDir(_ dir: URL) throws {
        let fm = FileManager.default
        let profileURL = dir.appendingPathComponent("profile.json")
        guard fm.fileExists(atPath: profileURL.path) else {
            throw BundleError.validationFailed("profile.json missing after copy")
        }
        let data: Data
        do {
            data = try Data(contentsOf: profileURL)
        } catch {
            throw BundleError.validationFailed("profile.json unreadable: \(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            throw BundleError.validationFailed("profile.json is empty (likely iCloud-evicted)")
        }
        do {
            _ = try JSONDecoder().decode(POIProfile.self, from: data)
        } catch {
            throw BundleError.validationFailed("profile.json failed to decode: \(error.localizedDescription)")
        }
        // Reference photo count >= 0 is implicit; we don't require any photos.
    }

    /// Build a unique target inside the project-local .trash/ for the
    /// displaced POI dir. Format: ~/dev/VideoScan/.trash/POI-<name>-<isoTimestamp>/
    private static func trashTarget(forPOI folderName: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stamp = isoStamp(Date())
        return home
            .appendingPathComponent("dev/VideoScan/.trash", isDirectory: true)
            .appendingPathComponent("POI-\(folderName)-\(stamp)", isDirectory: true)
    }

    // MARK: - Part 2: conflict resolution

    fileprivate enum Decision {
        case preferLocal(reason: String)
        case preferBundle(reason: String)
    }

    /// Pure decision function — easy to unit-test independently.
    fileprivate static func decideWinner(bundleRefCount: Int,
                                         localRefCount: Int,
                                         bundleMtime: Date?,
                                         localMtime: Date?,
                                         localExists: Bool) -> Decision {
        // Fast path: nothing local → bundle always wins.
        if !localExists {
            return .preferBundle(reason: "no local copy")
        }

        // Photo-count comparison is the primary signal because "newer" via
        // mtime is too easy to spoof by an accidental touch / iCloud sync
        // metadata change. More data wins.
        if bundleRefCount > localRefCount {
            return .preferBundle(reason: "more reference photos (\(bundleRefCount) > \(localRefCount))")
        }
        if localRefCount > bundleRefCount {
            return .preferLocal(reason: "local has more reference photos (\(localRefCount) > \(bundleRefCount))")
        }

        // Tie on count — mtime decides, with bundle winning a true tie.
        let bm = bundleMtime ?? .distantPast
        let lm = localMtime ?? .distantPast
        if bm > lm {
            return .preferBundle(reason: "equal photo count, bundle is newer")
        }
        if lm > bm {
            return .preferLocal(reason: "equal photo count, local is newer")
        }
        return .preferBundle(reason: "equal photo count and mtime; bundle wins by default")
    }

    /// Recursively count reference photos under `dir`. Used by conflict
    /// resolution and as a smoke-test for "did the iCloud download actually
    /// produce real files."
    private static func countReferencePhotos(under dir: URL) -> Int {
        let fm = FileManager.default
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var count = 0
        for case let url as URL in it {
            guard referencePhotoExts.contains(url.pathExtension.lowercased()) else { continue }
            // Require non-zero size — an iCloud placeholder is technically a
            // file but it's a 0-byte stub.
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if vals?.isRegularFile == true, (vals?.fileSize ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }

    /// Pick the most-recent mtime under `dir`. We use the max of mtimes
    /// across the whole subtree — that captures "this POI was last
    /// meaningfully touched at T" better than the folder's own mtime, which
    /// is just last-directory-mutation.
    ///
    /// Returns `fallback` if the directory exists but no usable mtimes can
    /// be read. Returns nil only if `fallback` is also nil.
    private static func effectiveMTime(of dir: URL, fallback: Date?) -> Date? {
        let fm = FileManager.default
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return fallback }
        var best: Date? = nil
        for case let url as URL in it {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                if best == nil || d > best! { best = d }
            }
        }
        return best ?? fallback
    }

    private static func formatMTime(_ d: Date?) -> String {
        guard let d else { return "n/a" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func isoStamp(_ d: Date) -> String {
        let f = DateFormatter()
        // Filename-safe: ISO-ish but no colons (which trip the Finder).
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }
}

// MARK: - Helpers (formatting)

enum BundleSize {
    static func human(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB, .useKB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
