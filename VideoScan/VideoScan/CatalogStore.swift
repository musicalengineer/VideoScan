// CatalogStore.swift
// Persists the catalog (records + scan target paths metadata) as JSON to
// ~/Library/Application Support/VideoScan/catalog.json so the user can
// relaunch the app and still see results from offline volumes.
//
// Save policy: debounced 2s after the last mutation, plus a synchronous
// save() on app termination via the AppDelegate. The store deliberately
// runs off the main actor for I/O.

import Foundation

/// On-disk shape. Versioned so future schema changes can migrate cleanly.
///
/// Versions:
///  - v1: records only.
///  - v2: adds `savedFromHost` so cross-machine imports can tag records with
///    their machine of origin. v1 snapshots still load: missing keys decode
///    as defaults.
struct CatalogSnapshot: Codable {
    static let currentVersion = 2

    var version: Int = Self.currentVersion
    var savedAt: Date = Date()
    var records: [VideoRecord] = []
    var savedFromHost: String = ""

    private enum CodingKeys: String, CodingKey {
        case version, savedAt, records, savedFromHost
    }

    init(version: Int = Self.currentVersion,
         savedAt: Date = Date(),
         records: [VideoRecord] = [],
         savedFromHost: String = "") {
        self.version = version
        self.savedAt = savedAt
        self.records = records
        self.savedFromHost = savedFromHost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version       = try c.decodeIfPresent(Int.self,    forKey: .version)       ?? 1
        savedAt       = try c.decodeIfPresent(Date.self,   forKey: .savedAt)       ?? Date()
        records       = try c.decodeIfPresent([VideoRecord].self, forKey: .records) ?? []
        savedFromHost = try c.decodeIfPresent(String.self, forKey: .savedFromHost) ?? ""
    }
}

/// Human-readable name of the machine this app is running on. Used to tag
/// exported catalogs and imported records.
enum CatalogHost {
    static var currentName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

@MainActor
final class CatalogStore {
    static let shared = CatalogStore()

    /// True when the current process is a unit-test host. Under tests we
    /// neither load nor save, so constructing a `VideoScanModel` doesn't
    /// pull in the user's real catalog and an `importCatalog` test doesn't
    /// overwrite `~/Library/Application Support/VideoScan/catalog.json`.
    ///
    /// Check both XCTest (legacy) and Swift Testing signals — Swift Testing
    /// tests don't necessarily link XCTest.
    private static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        // Fallback: detect an .xctest bundle loaded into the process.
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    private let fileURL: URL
    private var debounceTask: Task<Void, Never>?

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("catalog.json")
    }

    var fileLocation: String { fileURL.path }

    // MARK: - Load

    /// Load records from disk. Resolves `pairedWith` back-references after
    /// the array is fully decoded. Returns an empty array if the file is
    /// missing or unreadable — never throws into the caller, since a
    /// missing snapshot on first launch is normal.
    func load() -> [VideoRecord] {
        if Self.isRunningTests { return [] }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
            // Build id → record map and rewire pairedWith references.
            let byID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            for rec in snapshot.records {
                if let pid = rec.pendingPairedWithID {
                    rec.pairedWith = byID[pid]
                    rec.pendingPairedWithID = nil
                }
            }
            return snapshot.records
        } catch {
            NSLog("VideoScan: failed to load catalog snapshot: %@", String(describing: error))
            return []
        }
    }

    // MARK: - Save

    /// Save synchronously. Use from `applicationWillTerminate` so the file
    /// is flushed before the process exits.
    func saveNow(records: [VideoRecord]) {
        if Self.isRunningTests { return }
        debounceTask?.cancel()
        debounceTask = nil
        writeToDisk(records: records)
    }

    /// Schedule a save 2 seconds after the most recent call. Repeated calls
    /// reset the timer so a burst of mutations only triggers one disk write.
    func scheduleSave(records: [VideoRecord]) {
        if Self.isRunningTests { return }
        debounceTask?.cancel()
        let snapshot = records  // capture the array reference; elements are classes
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            self?.writeToDisk(records: snapshot)
        }
    }

    private func writeToDisk(records: [VideoRecord]) {
        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: records,
            savedFromHost: CatalogHost.currentName
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            // Atomic write so a crash mid-write doesn't truncate the file.
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            NSLog("VideoScan: failed to save catalog snapshot: %@", String(describing: error))
        }
    }
}
