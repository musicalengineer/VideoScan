// CatalogStore.swift
// Persists the catalog (records + scan target paths metadata) as JSON to
// ~/Library/Application Support/VideoScan/catalog.json so the user can
// relaunch the app and still see results from offline volumes.
//
// Save policy: debounced 2s after the last mutation, plus a synchronous
// save() on app termination via the AppDelegate. The store deliberately
// runs off the main actor for I/O.
//
// Crash-safety: writes are atomic (temp file + rename via Data's atomic
// option, which writes to a sibling tmp and posix-renames into place);
// load rotates the prior catalog.json → catalog.json.prev so a corrupt
// primary can fall back one generation. See docs (issue tracker) and
// CatalogStoreHardeningTests for the locked-down contract.

import Foundation

// MARK: - CatalogLoadError
//
// Surfaced so the load path can distinguish "missing" (first launch — fine,
// start empty) from "newer than this build can read" (refuse — don't overwrite
// the user's data on the next debounced save) from "malformed but fell back to
// .prev". The load() entry point swallows these into log lines for the legacy
// callers; new code can call `loadWithDiagnostic()` for the typed result.

enum CatalogLoadOutcome: Equatable {
    case missing                            // no catalog.json present (first launch)
    case loaded(fromBackup: Bool)           // success — true if we read .prev because primary was corrupt
    case refusedNewerVersion(found: Int)    // catalog.json was written by a newer build; refuse to load
    case corruptNoBackup                    // primary unreadable AND no usable .prev backup
}

/// On-disk shape. Versioned so future schema changes can migrate cleanly.
///
/// Versions:
///  - v1: records only.
///  - v2: adds `savedFromHost` so cross-machine imports can tag records with
///    their machine of origin. v1 snapshots still load: missing keys decode
///    as defaults.
///  - v3: VideoRecord gains `suspectedPeople: [String]` (borderline-confidence
///    face matches). Migration is additive — v2 catalog.json files load
///    unchanged via decodeIfPresent ?? [] on the record decoder.
///  - v4: VideoRecord gains `sceneCaptions: [SceneCaption]`,
///    `sceneCaptionModel: String?`, `sceneCaptionDate: Date?` for VLM-generated
///    natural-language descriptions. Same additive Codable pattern as v3.
///    See docs/scene_captions_plan.md.
///  - v5: VideoRecord gains `originalFullPath: String?` and `originVolume:
///    String?` for Relocate Volume provenance, plus two new `ArchiveStage`
///    cases (`manuallyDeleted`, `salvageFailed`). Pure additive — v4 loads
///    unchanged. See docs/relocate_volume_plan.md.
struct CatalogSnapshot: Codable {
    static let currentVersion = 5

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
        version       = try c.decodeIfPresent(Int.self, forKey: .version)       ?? 1
        savedAt       = try c.decodeIfPresent(Date.self, forKey: .savedAt)       ?? Date()
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

/// Receives a notification after every successful catalog write. The
/// CatalogSync engine installs itself here so it can refresh
/// manifest.sha256 next to the freshly-rewritten catalog.json without
/// CatalogStore having to know about sync, hostnames, or rsync.
///
/// `// `protocol` ≈ a pure-virtual C++ base class — keeps the dependency
/// arrow pointing the right way (CatalogStore → CatalogStoreObserver,
/// never CatalogStore → CatalogSync).
@MainActor
protocol CatalogStoreObserver: AnyObject {
    func catalogStoreDidWrite(_ store: CatalogStore)
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
    private let backupURL: URL
    private var debounceTask: Task<Void, Never>?

    /// Belt-and-suspenders read-only guard for the viewer (non-master) Macs.
    /// When `true`, saveNow / scheduleSave early-return and log instead of
    /// writing. The UI also disables write affordances and shows a banner,
    /// but this is the last line of defense at the data layer — any future
    /// write path automatically picks up the guard without remembering to
    /// check `model.isReadOnly`. Set once at construction by the sync
    /// engine; never flips at runtime.
    var isReadOnly: Bool = false

    /// Notified after every successful write. Used by CatalogSync on the
    /// master to refresh manifest.sha256. Weak ref so the observer's
    /// lifetime isn't entangled with the singleton's.
    weak var observer: CatalogStoreObserver?

    /// Outcome of the most recent `load()` call. Inspectable by callers
    /// (or tests) that want to react to "newer version refused" or
    /// "fell back to .prev" without changing the legacy `load() -> [VideoRecord]`
    /// signature.
    private(set) var lastLoadOutcome: CatalogLoadOutcome = .missing

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("catalog.json")
        self.backupURL = dir.appendingPathComponent("catalog.json.prev")
    }

    /// Internal init for tests — pin the catalog to an arbitrary directory
    /// so unit tests don't touch `~/Library/Application Support/VideoScan/`.
    /// The directory is created if absent; `catalog.json` and
    /// `catalog.json.prev` live side-by-side inside it.
    internal init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("catalog.json")
        self.backupURL = directory.appendingPathComponent("catalog.json.prev")
    }

    var fileLocation: String { fileURL.path }
    var backupLocation: String { backupURL.path }

    // MARK: - Load

    /// Load records from disk. Resolves `pairedWith` back-references after
    /// the array is fully decoded. Returns an empty array if the file is
    /// missing, unreadable, or written by a newer build — never throws
    /// into the caller, since a missing snapshot on first launch is normal.
    ///
    /// Side-effects:
    ///   - On a successful primary load, the primary is rotated to
    ///     `catalog.json.prev` BEFORE decoding so the previous good copy is
    ///     preserved one generation back. (We copy, not move — keeps the
    ///     primary in place so a power-loss between rotate and any future
    ///     save still leaves a real catalog.json on disk.)
    ///   - On a corrupt primary, we attempt to decode `.prev` and use it.
    ///   - On a newer-version primary, we refuse to load (returning [])
    ///     so the next debounced save does NOT overwrite the user's data
    ///     with an empty array. The original primary is NOT rotated in
    ///     this case so a downgrade-then-upgrade cycle still sees the
    ///     original catalog.
    ///   - `lastLoadOutcome` is updated for diagnostics in all paths.
    func load() -> [VideoRecord] {
        if Self.isRunningTests && self === CatalogStore.shared {
            // Test-host short-circuit applies ONLY to the shared singleton.
            // Tests can still construct their own CatalogStore(directory:)
            // and exercise the real load path. (Narrow-gate per
            // feedback_test_isolation_narrow_gate.)
            NSLog("VideoScan: CatalogStore.load() skipped — test environment detected")
            lastLoadOutcome = .missing
            return []
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSLog("VideoScan: CatalogStore.load() — no catalog file at %@", fileURL.path)
            lastLoadOutcome = .missing
            return []
        }
        // Try primary first.
        if let (records, version) = decode(url: fileURL) {
            if version > CatalogSnapshot.currentVersion {
                NSLog("VideoScan: catalog.json version %d is newer than this build (v%d) — refusing to load; not overwriting on next save",
                      version, CatalogSnapshot.currentVersion)
                lastLoadOutcome = .refusedNewerVersion(found: version)
                return []
            }
            // Rotate primary → .prev on every successful load. Copy (not move)
            // so primary stays in place; replace any stale .prev.
            rotateBackup()
            lastLoadOutcome = .loaded(fromBackup: false)
            return records
        }
        // Primary unreadable — try .prev.
        NSLog("VideoScan: primary catalog.json unreadable; trying %@", backupURL.path)
        if FileManager.default.fileExists(atPath: backupURL.path),
           let (records, version) = decode(url: backupURL),
           version <= CatalogSnapshot.currentVersion {
            NSLog("VideoScan: recovered catalog from %@ (%d records)", backupURL.path, records.count)
            lastLoadOutcome = .loaded(fromBackup: true)
            return records
        }
        NSLog("VideoScan: no usable backup catalog; starting with empty records")
        lastLoadOutcome = .corruptNoBackup
        return []
    }

    /// Decode helper — returns (records, version) on success, nil on any
    /// failure (missing file, malformed JSON, malformed snapshot). Resolves
    /// `pairedWith` references against the decoded array.
    private func decode(url: URL) -> ([VideoRecord], Int)? {
        do {
            let data = try Data(contentsOf: url)
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
            return (snapshot.records, snapshot.version)
        } catch {
            NSLog("VideoScan: failed to decode catalog at %@: %@", url.path, String(describing: error))
            return nil
        }
    }

    /// Copy primary → .prev so the previous-good snapshot is preserved one
    /// generation back. Best-effort: errors are logged but never thrown —
    /// a load that can't make a backup still proceeds with the primary.
    /// `// `try?` ≈ C++ exception swallow — we want a missing/locked .prev
    /// to be non-fatal here.
    private func rotateBackup() {
        let fm = FileManager.default
        if fm.fileExists(atPath: backupURL.path) {
            do { try fm.removeItem(at: backupURL) }
            catch { NSLog("VideoScan: rotate-backup: failed to remove stale .prev: %@", String(describing: error)); return }
        }
        do {
            try fm.copyItem(at: fileURL, to: backupURL)
        } catch {
            NSLog("VideoScan: rotate-backup: failed to copy primary → .prev: %@", String(describing: error))
        }
    }

    // MARK: - Save

    /// Save synchronously. Use from `applicationWillTerminate` so the file
    /// is flushed before the process exits.
    func saveNow(records: [VideoRecord]) {
        if Self.isRunningTests && self === CatalogStore.shared { return }
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.saveNow refused — read-only viewer mode")
            return
        }
        debounceTask?.cancel()
        debounceTask = nil
        writeToDisk(records: records)
    }

    /// Schedule a save 2 seconds after the most recent call. Repeated calls
    /// reset the timer so a burst of mutations only triggers one disk write.
    func scheduleSave(records: [VideoRecord]) {
        if Self.isRunningTests && self === CatalogStore.shared { return }
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.scheduleSave refused — read-only viewer mode")
            return
        }
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
            // Foundation implements this as: write to a sibling tmp file,
            // fsync, then `rename(2)` into place — POSIX rename is atomic
            // within a filesystem, so readers see either the old file or
            // the new file, never a partial.
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
            // Notify the observer (CatalogSync on the master) so it can
            // refresh manifest.sha256. Skipped for the test singleton —
            // tests construct their own CatalogStore(directory:) and can
            // wire an observer if they need to assert the callback.
            observer?.catalogStoreDidWrite(self)
        } catch {
            NSLog("VideoScan: failed to save catalog snapshot: %@", String(describing: error))
        }
    }
}
