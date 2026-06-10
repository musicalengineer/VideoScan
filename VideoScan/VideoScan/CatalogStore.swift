// CatalogStore.swift
// Persists the catalog (records + scan target paths metadata) as JSON to
// ~/Library/Application Support/VideoScan/catalog.json so the user can
// relaunch the app and still see results from offline volumes.
//
// Save policy: debounced 2s after the last mutation, plus a synchronous
// save() on app termination via the AppDelegate.
//
// Threading (perf fix 2026-06-10): catalog.json is ~73 MB with dossier
// transcripts/captions inline, so encode+write must NOT run on the main
// actor (it was a multi-second beachball per tag/rating/note edit).
// Debounced saves now snapshot the record graph on the main actor (cheap
// deep copy — tens of ms for ~13.5K records) and encode+write the snapshot
// on a serial background queue. All file writes are serialized through
// that one queue so a terminal `saveNow` (queue.sync) always lands LAST
// and the freshest content wins. See `deepCopySnapshot` for why the copy
// is required for race-freedom.
//
// Crash-safety: writes are atomic (temp file + rename via Data's atomic
// option, which writes to a sibling tmp and posix-renames into place);
// load rotates the prior catalog.json → catalog.json.prev so a corrupt
// primary can fall back one generation. See docs (issue tracker) and
// CatalogStoreHardeningTests for the locked-down contract.

import Foundation
import os

/// File-scope so the nonisolated background encode path can log without
/// touching @MainActor state. Logger is Sendable.
private let catalogStoreLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogStore")

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
///  - v6: Companion to Relocate §1B Retire Volume. No catalog.json schema
///    change — the retire fields (`retiredAt`, `retiredReason`,
///    `retiredWitnesses`) live on `CatalogScanTarget` in UserDefaults and
///    in `VolumeMetadataSnapshot` for bundle export. The version bump is
///    a marker so a v6-aware build knows the parallel volume metadata
///    layer *may* carry retire fields; v5 catalog.json files load
///    unchanged (no record-level fields were added).
struct CatalogSnapshot: Codable {
    static let currentVersion = 6

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

    /// Serial queue that owns ALL writes to catalog.json. Debounced saves
    /// hop onto it async; the terminal `saveNow` hops on sync — so writes
    /// are strictly ordered and a terminal save always lands last.
    /// `// In C++ terms: a single dedicated writer thread fed by a FIFO.`
    private let writeQueue = DispatchQueue(label: "Rick-Breen.VideoScan.catalogStore.write",
                                           qos: .utility)

    /// True while a background encode+write is running. Guarded by the
    /// main actor (all mutations happen there).
    private var saveInFlight = false

    /// Records re-marked dirty while a save was in flight. The follow-up
    /// save starts the moment the in-flight one finishes — a second edit
    /// during a save is never lost. Holds the LATEST array reference only;
    /// intermediate ones are superseded (same coalescing the debounce does).
    private var pendingRecords: [VideoRecord]?

    /// Test seam: artificial delay (seconds) applied on the write queue
    /// before encoding. Lets tests deterministically create the
    /// "save in flight" window for coalescing / snapshot-independence
    /// assertions. Always 0 in production.
    internal var testWriteDelay: TimeInterval = 0

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
    ///
    /// Ordering vs in-flight async saves: this hops onto `writeQueue` with
    /// `sync`, which FIFO-serializes behind any background write already
    /// running — so the terminal save's (freshest) content always lands
    /// last. Any coalesced follow-up is cleared first: this save supersedes
    /// it.
    func saveNow(records: [VideoRecord]) {
        if Self.isRunningTests && self === CatalogStore.shared { return }
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.saveNow refused — read-only viewer mode")
            return
        }
        debounceTask?.cancel()
        debounceTask = nil
        pendingRecords = nil  // superseded by this synchronous save
        let payload = Self.makePayload(records: records)
        let box = SnapshotBox(payload: payload)
        var ok = false
        writeQueue.sync {
            ok = Self.encodeAndWrite(payload: box.payload, to: fileURL)
        }
        if ok {
            observer?.catalogStoreDidWrite(self)
        }
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
        let captured = records  // capture the array reference; elements are classes
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            self?.saveAsync(records: captured)
        }
    }

    /// Off-main save: snapshot on the main actor, encode+write on
    /// `writeQueue`. Internal (not private) so tests can drive the async
    /// path without waiting out the 2 s debounce.
    ///
    /// Coalescing: if a save is already in flight, remember the latest
    /// records array and run a follow-up save the moment the in-flight one
    /// completes. A dirty mark during a save is therefore never lost.
    func saveAsync(records: [VideoRecord]) {
        if Self.isRunningTests && self === CatalogStore.shared { return }
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.saveAsync refused — read-only viewer mode")
            return
        }
        if saveInFlight {
            pendingRecords = records
            return
        }
        saveInFlight = true

        // Snapshot ON the main actor — see deepCopySnapshot for why.
        let t0 = CFAbsoluteTimeGetCurrent()
        let payload = Self.makePayload(records: records)
        let snapshotMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        catalogStoreLog.debug("catalog save: snapshot of \(records.count) records took \(snapshotMs, format: .fixed(precision: 1)) ms")

        let box = SnapshotBox(payload: payload)
        let dest = fileURL
        let delay = testWriteDelay
        writeQueue.async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let ok = Self.encodeAndWrite(payload: box.payload, to: dest)
            Task { @MainActor [weak self] in
                self?.asyncSaveDidFinish(success: ok)
            }
        }
    }

    /// Back on the main actor after a background write. Fires the observer
    /// and, if anything went dirty while we were writing, starts the
    /// follow-up save.
    private func asyncSaveDidFinish(success: Bool) {
        saveInFlight = false
        if success {
            // Notify the observer (CatalogSync on the master) so it can
            // refresh manifest.sha256. Skipped for the test singleton —
            // tests construct their own CatalogStore(directory:) and can
            // wire an observer if they need to assert the callback.
            observer?.catalogStoreDidWrite(self)
        }
        if let pending = pendingRecords {
            pendingRecords = nil
            saveAsync(records: pending)
        }
    }

    /// Build the on-disk payload from a RACE-FREE deep copy of the live
    /// records. Must run on the main actor (it reads live mutable state).
    private static func makePayload(records: [VideoRecord]) -> CatalogSnapshot {
        CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: deepCopySnapshot(records: records),
            savedFromHost: CatalogHost.currentName
        )
    }

    /// Deep-copy the record graph so the background encoder never reads an
    /// object the main actor can mutate. VideoRecord is a mutable class —
    /// encoding the LIVE array off-main would race with tag/note/rescan
    /// mutations (torn reads, or worse, crashes inside JSONEncoder).
    ///
    /// Two passes, mirroring `decode`'s pendingPairedWithID resolution:
    ///   1. `snapshotClone()` every record (field-by-field copy; String/
    ///      Array CoW makes the copies immutable views — see Models.swift).
    ///   2. Rewire `pairedWith` so each clone points at its partner's CLONE.
    ///      A partner missing from the array (shouldn't happen, but be
    ///      defensive) gets an id-only stub — `encode` only reads
    ///      `pairedWith?.id`.
    ///
    /// Internal so tests can assert clone parity + rewiring directly.
    static func deepCopySnapshot(records: [VideoRecord]) -> [VideoRecord] {
        let clones = records.map { $0.snapshotClone() }
        var cloneByID = [UUID: VideoRecord](minimumCapacity: clones.count)
        for clone in clones { cloneByID[clone.id] = clone }
        for (original, clone) in zip(records, clones) {
            guard let partner = original.pairedWith else { continue }
            if let mapped = cloneByID[partner.id] {
                clone.pairedWith = mapped
            } else {
                let stub = VideoRecord()
                stub.id = partner.id
                clone.pairedWith = stub
            }
        }
        return clones
    }

    /// Encode + atomically write. Runs OFF the main actor (writeQueue) for
    /// debounced saves; runs synchronously via writeQueue.sync for the
    /// terminal saveNow. Returns true on success.
    ///
    /// Encoding is compact — no .prettyPrinted / .sortedKeys. At ~73 MB
    /// pretty-printed, indentation alone was ~30-40% of the file; every
    /// downstream consumer (Python merge/dossier scripts, LiveReload,
    /// CatalogSync) parses JSON and never diffs the text form.
    nonisolated private static func encodeAndWrite(payload: CatalogSnapshot, to fileURL: URL) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            // Atomic write so a crash mid-write doesn't truncate the file.
            // Foundation implements this as: write to a sibling tmp file,
            // fsync, then `rename(2)` into place — POSIX rename is atomic
            // within a filesystem, so readers see either the old file or
            // the new file, never a partial.
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            catalogStoreLog.debug("catalog save: encode+write of \(data.count) bytes took \(ms, format: .fixed(precision: 1)) ms")
            return true
        } catch {
            NSLog("VideoScan: failed to save catalog snapshot: %@", String(describing: error))
            catalogStoreLog.error("catalog save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// Transport box for handing the snapshot payload to the write queue.
/// `@unchecked Sendable` is justified because the boxed records are the
/// deep copies produced by `deepCopySnapshot` — after construction they are
/// exclusively owned by the save pipeline; no other thread holds a
/// reference, and nothing mutates them. (The live records the UI mutates
/// are different objects.)
private struct SnapshotBox: @unchecked Sendable {
    let payload: CatalogSnapshot
}
