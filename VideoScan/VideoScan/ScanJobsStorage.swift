// ScanJobsStorage.swift
// Tiny-descriptor persistence for completed Person Finder jobs.
//
// Goal: when the app re-launches, the most recent N searches reappear in
// the jobs list so the user doesn't lose context. We persist descriptors
// only (not result rows) — the per-video result payload already lives in
// the SQLite PersonFinderCache, keyed by (video + search params + refHash).
// On restore, the descriptor names the search; `restoreFromCache` fetches
// the actual results from SQLite.
//
// Layout:
//   ~/Library/Application Support/VideoScan/scan_jobs/
//     20260518T180423Z__<uuid>.json
//     20260518T184811Z__<uuid>.json
//     ...
//
// Filename format puts a sortable ISO-ish timestamp first so newest-first
// enumeration is a string sort. The UUID suffix disambiguates sub-second
// completions and lets us look up a specific descriptor without parsing.

import Foundation

/// Snapshot of a completed scan job, written to disk so it survives app
/// restart. Result rows are NOT included here — they're rehydrated from
/// PersonFinderCache on load via the existing `restoreFromCache` path.
struct PersistedJobDescriptor: Codable, Equatable, Identifiable {
    let id: UUID
    let personName: String
    let profileFolderName: String?
    let searchPath: String
    let engine: String
    let threshold: Float
    let referencePath: String
    let referenceFilenames: [String]
    let completedAt: Date

    // Summary stats — shown immediately in the UI before cache rehydration
    // finishes, so the row isn't blank for the first few hundred ms.
    let videosScanned: Int
    let videosTotal: Int
    let videosWithHits: Int
    let clipsFound: Int
    let presenceSecs: Double
    let elapsedSecs: Double

    /// Job's status at persist time. Optional so descriptors written before
    /// 2026-06-03 (when this field was added) decode as nil and are treated
    /// as `.done` for backward compat. New writes always set this. Stored
    /// as a String (the ScanJobStatus.label value) for forward portability
    /// — adding a new status case shouldn't break decoding old JSON.
    ///
    /// Currently the only states the UI actually cares about across an app
    /// restart are .done (normal-completion bookmark) and .paused (user
    /// paused mid-scan, expects to Resume). Other statuses are transient
    /// in-process states (.scanning, .compiling, .loading, etc.) that would
    /// never be persisted in practice.
    let statusRaw: String?

    /// Explicit init with `statusRaw` defaulted to nil so existing test
    /// fixtures that construct descriptors via the memberwise init don't
    /// have to be updated for the field added 2026-06-03. New production
    /// writers (makeDescriptor) always set statusRaw explicitly.
    init(
        id: UUID,
        personName: String,
        profileFolderName: String?,
        searchPath: String,
        engine: String,
        threshold: Float,
        referencePath: String,
        referenceFilenames: [String],
        completedAt: Date,
        videosScanned: Int,
        videosTotal: Int,
        videosWithHits: Int,
        clipsFound: Int,
        presenceSecs: Double,
        elapsedSecs: Double,
        statusRaw: String? = nil
    ) {
        self.id = id
        self.personName = personName
        self.profileFolderName = profileFolderName
        self.searchPath = searchPath
        self.engine = engine
        self.threshold = threshold
        self.referencePath = referencePath
        self.referenceFilenames = referenceFilenames
        self.completedAt = completedAt
        self.videosScanned = videosScanned
        self.videosTotal = videosTotal
        self.videosWithHits = videosWithHits
        self.clipsFound = clipsFound
        self.presenceSecs = presenceSecs
        self.elapsedSecs = elapsedSecs
        self.statusRaw = statusRaw
    }
}

enum ScanJobsStorage {

    /// Default cap on persisted descriptors. Older entries are evicted by
    /// `enforceLimit` after each save. N=10 chosen with Rick on 2026-05-18
    /// as a starting point — incremental; revisit after real-world use.
    static let defaultLimit = 10

    // MARK: - Paths

    /// True when this process is a unit-test host. Multi-signal because
    /// Swift Testing doesn't necessarily link XCTest, so a single env-var
    /// check isn't reliable. Mirrors `CatalogStore.isRunningTests`.
    private static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if env["VS_UI_TEST"] == "1" { return true } // UI-test target — see TestEnvironment.detect
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    /// Root directory for descriptor JSON files. Created on first access.
    ///
    /// Under tests, `storeDir` redirects to a per-process temp directory.
    /// This prevents tests that go through the no-arg convenience wrappers
    /// (e.g. `PersonFinderModel.init` → `restoreSessionFromDisk` →
    /// `listAll()`) from picking up Rick's real persisted search history,
    /// which would otherwise leak in as an off-by-one stray job. Tests
    /// that want pinpointed isolation still use the explicit-directory
    /// variants below.
    static var storeDir: URL {
        let base: URL
        if isRunningTests {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "VideoScanTests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        let dir = base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("scan_jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Filename helpers

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func filename(for descriptor: PersistedJobDescriptor) -> String {
        "\(timestampFormatter.string(from: descriptor.completedAt))__\(descriptor.id.uuidString).json"
    }

    // MARK: - Save / Load (instance directory variants for tests)

    /// Save a descriptor to disk. Existing files for the same job id are
    /// removed before write, so re-running a job updates its entry instead
    /// of accumulating duplicates.
    static func save(_ descriptor: PersistedJobDescriptor, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Remove any pre-existing file for the same job id (re-run case).
        let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in existing where url.lastPathComponent.contains(descriptor.id.uuidString) {
            try? fm.removeItem(at: url)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(descriptor)
        let dest = directory.appendingPathComponent(filename(for: descriptor))
        try data.write(to: dest, options: .atomic)
    }

    /// Load every descriptor in the directory, sorted newest-first by
    /// `completedAt`. Files that fail to decode are skipped silently —
    /// a single corrupt entry must never prevent loading the rest.
    static func listAll(in directory: URL) -> [PersistedJobDescriptor] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var descriptors: [PersistedJobDescriptor] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let descriptor = try? decoder.decode(PersistedJobDescriptor.self, from: data) else {
                continue
            }
            descriptors.append(descriptor)
        }
        return descriptors.sorted { $0.completedAt > $1.completedAt }
    }

    /// Remove the descriptor matching the given id, if present.
    @discardableResult
    static func delete(id: UUID, directory: URL) -> Bool {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        var removed = false
        for url in urls where url.lastPathComponent.contains(id.uuidString) {
            if (try? fm.removeItem(at: url)) != nil {
                removed = true
            }
        }
        return removed
    }

    /// Trim oldest descriptors until at most `keep` remain. Returns the
    /// number of descriptors removed — callers can surface this to the
    /// user so eviction isn't silent.
    @discardableResult
    static func enforceLimit(keep: Int = defaultLimit, directory: URL) -> Int {
        let all = listAll(in: directory)  // newest-first
        guard all.count > keep else { return 0 }
        let toRemove = all.suffix(from: keep)  // the older tail
        var removed = 0
        for descriptor in toRemove where delete(id: descriptor.id, directory: directory) {
            removed += 1
        }
        return removed
    }

    // MARK: - Production convenience wrappers

    /// Production save — uses the default `storeDir`. Wraps the directory
    /// variant so tests can target a sandbox without going through the
    /// real ~/Library path.
    static func save(_ descriptor: PersistedJobDescriptor) throws {
        try save(descriptor, directory: storeDir)
    }

    static func listAll() -> [PersistedJobDescriptor] {
        listAll(in: storeDir)
    }

    @discardableResult
    static func delete(id: UUID) -> Bool {
        delete(id: id, directory: storeDir)
    }

    @discardableResult
    static func enforceLimit(keep: Int = defaultLimit) -> Int {
        enforceLimit(keep: keep, directory: storeDir)
    }
}
