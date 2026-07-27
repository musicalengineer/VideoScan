// BundleModels.swift
// Codable snapshot/manifest models plus the shared error and size helper for
// the bundle export/import flow — extracted verbatim from
// BundleExportImport.swift (refactor 2026-06-25). These are the on-disk JSON
// shapes (manifest.json / volumes.json / settings.json) the exporter writes
// and the importer reads, so the serialization format is load-bearing: moved
// byte-for-byte, no field or key changes. (Swift `struct: Codable` ≈ a C++
// POD with auto-generated (de)serialization.)

import Foundation

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
        /// Total non-blank lines across all bundled dossier JSONL files.
        /// Optional for back-compat: bundles from before 2026-06-07 don't
        /// have this field and decode it as nil.
        var dossierDeltaLines: Int? = nil
    }

    struct Sizes: Codable {
        /// Total size of the bundle on disk in bytes (whole tree).
        var totalBytes: Int64
        /// Bytes occupied by reference photos (the bulky part).
        var referencePhotoBytes: Int64
        /// Bytes occupied by the bundled dossier JSONL deltas. Optional
        /// for back-compat (see Counts.dossierDeltaLines).
        var dossierDeltaBytes: Int64? = nil
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
        if let eng = RecognitionEngine.migratePersisted(recognitionEngine) {
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

// Was `private` in BundleExportImport.swift; relaxed to internal so the
// exporter and importer (now in their own files) can both reference the
// shared whitelist.
let referencePhotoExts: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"
]

// MARK: - Helpers (formatting)

enum BundleSize {
    static func human(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB, .useKB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
