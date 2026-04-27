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
    var concatOutput: Bool
    var decadeChapters: Bool
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
        self.concatOutput = settings.concatOutput
        self.decadeChapters = settings.decadeChapters
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
        settings.concatOutput = concatOutput
        settings.decadeChapters = decadeChapters
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
        }
    }
}

// MARK: - Exporter

enum BundleExporter {

    struct Summary {
        var path: URL
        var manifest: BundleManifest
    }

    /// Write a complete bundle. `bundleURL` should end in `.videoscanbundle`.
    /// Overwrites any existing bundle at the same path.
    @MainActor
    static func writeBundle(records: [VideoRecord],
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

        // 4. People — copy each POI folder verbatim. profile.json + photos
        //    travel together; referencePath in the JSON gets re-derived on
        //    the destination machine, so we don't have to rewrite it here.
        let peopleDir = bundleURL.appendingPathComponent("people", isDirectory: true)
        try fm.createDirectory(at: peopleDir, withIntermediateDirectories: true)
        var photoCount = 0
        var photoBytes: Int64 = 0
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]
        let poiFolders = POIStorage.allPOIFolders()
        for src in poiFolders {
            let dest = peopleDir.appendingPathComponent(src.lastPathComponent, isDirectory: true)
            try fm.copyItem(at: src, to: dest)
            // Tally photo size for the manifest sizes block.
            if let kids = try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.fileSizeKey]) {
                for k in kids where imageExts.contains(k.pathExtension.lowercased()) {
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

        return Summary(path: bundleURL, manifest: manifest)
    }

    /// Recursively sum file sizes under `url`. Used for the manifest size
    /// block; precise enough for the post-export "size on disk" alert.
    private static func directorySize(_ url: URL) -> Int64 {
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
}

// MARK: - Importer

enum BundleImporter {

    struct Payload {
        var manifest: BundleManifest
        var catalog: CatalogSnapshot
        var volumes: VolumesSnapshot
        var settings: SettingsSnapshot
        var poiFoldersInBundle: [URL]
    }

    /// Read and decode a bundle directory. Returns the parsed payload — the
    /// caller (VideoScanModel) is responsible for merging into live state.
    /// Throws if the bundle is malformed or from a newer format version.
    static func read(from bundleURL: URL) throws -> Payload {
        let fm = FileManager.default
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw BundleError.manifestMissing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest: BundleManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try decoder.decode(BundleManifest.self, from: data)
        } catch {
            throw BundleError.decode("manifest.json — \(error.localizedDescription)")
        }
        guard manifest.bundleVersion <= BundleManifest.currentVersion else {
            throw BundleError.manifestVersionUnsupported(manifest.bundleVersion)
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
                       poiFoldersInBundle: poiFolders)
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

    /// Copy the bundle's POI folders into ~/Library/Application Support/
    /// VideoScan/POI/, overwriting any same-named folder. Returns the
    /// number of POIs installed.
    @discardableResult
    static func installPOIs(from poiFoldersInBundle: [URL]) throws -> Int {
        let fm = FileManager.default
        var installed = 0
        for src in poiFoldersInBundle {
            let dest = POIStorage.storeDir.appendingPathComponent(src.lastPathComponent,
                                                                  isDirectory: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
            installed += 1
        }
        return installed
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
