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
// Debounced saves now snapshot the record graph on the main actor by
// building a Sendable `CatalogSnapshotDTO` (each VideoRecord copied by
// value into a `VideoRecordDTO` — tens of ms for ~13.5K records) and
// encode+write that DTO on a serial background queue. The DTO IS the
// race-free copy and is a true value type, so it crosses the actor
// boundary with no `@unchecked Sendable` hatch and no live VideoRecord off
// the main actor. All file writes are serialized through that one queue so
// a terminal `saveNow` (queue.sync) always lands LAST and the freshest
// content wins. See `makePayload` / VideoRecordDTO for the race-freedom and
// byte-identity contracts. (`deepCopySnapshot` remains as a tested utility
// but is no longer on the save path.)
//
// Crash-safety: writes are atomic (temp file + rename via Data's atomic
// option, which writes to a sibling tmp and posix-renames into place);
// load rotates the prior catalog.json → catalog.json.prev so a corrupt
// primary can fall back one generation. See docs (issue tracker) and
// CatalogStoreHardeningTests for the locked-down contract.

import CryptoKit
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
struct CatalogSnapshot: Decodable {
    static let currentVersion = 6

    var version: Int = Self.currentVersion
    /// Monotonic write counter — the optimistic-concurrency stamp
    /// (design doc §4.1). Every successful save writes generation+1;
    /// a writer whose loaded generation no longer matches disk must
    /// reconcile before writing. Additive + optional: absent (old
    /// catalogs) decodes as 0, so no version bump and no migration.
    var generation: Int = 0
    var savedAt: Date = Date()
    var records: [VideoRecord] = []
    var savedFromHost: String = ""
    /// Master Archive designation (docs/archive_promotion_workflow.md §3).
    /// ADDITIVE + optional: absent in every pre-8/15 catalog and decodes
    /// as nil; encoded only when set (encodeIfPresent), so a catalog with
    /// no master archive is byte-identical to before. No version bump.
    /// Placed AFTER `records` in key order so the 4 KB header probe
    /// (version/generation) is unaffected.
    var masterArchive: MasterArchiveDesignation?

    private enum CodingKeys: String, CodingKey {
        case version, generation, savedAt, records, savedFromHost, masterArchive
    }

    init(version: Int = Self.currentVersion,
         generation: Int = 0,
         savedAt: Date = Date(),
         records: [VideoRecord] = [],
         savedFromHost: String = "",
         masterArchive: MasterArchiveDesignation? = nil) {
        self.version = version
        self.generation = generation
        self.savedAt = savedAt
        self.records = records
        self.savedFromHost = savedFromHost
        self.masterArchive = masterArchive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version       = try c.decodeIfPresent(Int.self, forKey: .version)       ?? 1
        generation    = try c.decodeIfPresent(Int.self, forKey: .generation)    ?? 0
        savedAt       = try c.decodeIfPresent(Date.self, forKey: .savedAt)       ?? Date()
        records       = try c.decodeIfPresent([VideoRecord].self, forKey: .records) ?? []
        savedFromHost = try c.decodeIfPresent(String.self, forKey: .savedFromHost) ?? ""
        masterArchive = try c.decodeIfPresent(MasterArchiveDesignation.self, forKey: .masterArchive)
    }

    /// Cheap header read: extract version + generation from the first few
    /// KB of the file WITHOUT decoding 41 MB of records. Works because the
    /// encoder emits these keys first (see CatalogSnapshotDTO.CodingKeys).
    /// Falls back to nil (not 0) when the file is missing or unparseable so
    /// callers can distinguish "no file" from "generation 0".
    static func headerProbe(at url: URL) -> (version: Int, generation: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return nil }
        func intAfter(_ key: String) -> Int? {
            guard let r = text.range(of: "\"\(key)\":") else { return nil }
            let tail = text[r.upperBound...].drop(while: { $0 == " " })
            let digits = tail.prefix(while: { $0.isNumber })
            return Int(digits)
        }
        // EITHER key in the head is enough. A sorted-keys encoder puts
        // "version" alphabetically LAST — after 41 MB of records — while
        // "generation" still lands in the head (g < r). Requiring version
        // here would silently disable OCC for any sorted-keys writer.
        // Only a file with NEITHER key in its head reads as "no header".
        let v = intAfter("version")
        let g = intAfter("generation")
        guard v != nil || g != nil else { return nil }
        return (v ?? 0, g ?? 0)
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
    /// Detection itself lives in TestEnvironment so CatalogSync and any
    /// future startup subsystem share ONE definition of "test host".
    private static var isRunningTests: Bool { TestEnvironment.isTestHost }

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

    /// Catalog-level Master Archive designation (design v2 §3). Loaded
    /// from the snapshot's additive `masterArchive` key by `load()` and
    /// stamped into every subsequent payload by `makePayload`. The model
    /// owns the user-facing value (`VideoScanModel.masterArchive`) and
    /// mirrors it here on every change — this is the persistence slot,
    /// not the source of truth for the UI.
    /// (For Rick: ≈ a member the serializer reads; the model writes it.)
    var masterArchive: MasterArchiveDesignation?

    // MARK: - Cross-process write safety
    //
    // Added 2026-08-14 after an external maintenance script's 52% catalog
    // reduction was silently reverted: the app was launched mid-operation,
    // loaded the pre-reduction file, and wrote its stale copy back over the
    // result. Nothing errored. See CatalogLock / CatalogWriteError.

    /// Ownership lock over catalog.json. Acquired lazily on the first write
    /// attempt rather than in `init` so viewers and test hosts — neither of
    /// which write — never contend for it.
    private lazy var lock = CatalogLock(besideCatalogAt: fileURL)

    /// The generation this session last loaded or successfully wrote. If
    /// the on-disk header carries a HIGHER generation, somebody else wrote
    /// the file and our in-memory copy is stale. This is the LOST-UPDATE
    /// guard; the lock alone does not catch it, because each writer's
    /// write is individually well-formed and correctly serialised.
    ///
    /// Generation, NOT mtime (design doc §4.1). mtime failed open on stat
    /// nil, coarse timestamps, equal-or-older replacements, and preserved
    /// timestamps — `shutil.copy2`, used by the very script that caused
    /// the 8/14 incident, preserves mtime BY DESIGN, so the old guard
    /// could never have caught the incident it was written for.
    private(set) var loadedGeneration: Int = 0

    /// Highest generation this session has CLAIMED -- stamped into a
    /// payload that may or may not have landed yet. Single allocator for
    /// both save paths (codex #385 tie race): before this, `saveNow` and
    /// `saveAsync` each computed `loadedGeneration + 1` independently, so a
    /// terminal save issued while an async save was in flight stamped the
    /// SAME generation as the in-flight write. Monotonic within a session;
    /// gaps (a failed write) are harmless because the OCC check is `>`.
    private var claimedGeneration: Int = 0

    /// The generation the next write will stamp. Always strictly greater
    /// than anything this session has loaded or claimed.
    private func allocateGeneration() -> Int {
        let next = max(loadedGeneration, claimedGeneration) + 1
        claimedGeneration = next
        return next
    }

    /// Non-nil when load() refused the on-disk catalog (written by a NEWER
    /// build). While set, EVERY write path refuses — otherwise the
    /// unconditional quit-time save overwrites a future-schema catalog
    /// with an empty current-schema one. Codex blocker 3 (#377): a live
    /// data-loss path independent of concurrency, present on main.
    private(set) var writesDisabledReason: String?

    /// Most recent refusal or failure, for UI surfacing. Cleared on success.
    private(set) var lastWriteError: CatalogWriteError?

    /// Gate for every write path. Returns nil when it is safe to proceed,
    /// otherwise the error — already journalled — to hand back to the
    /// caller. On success the LOCK IS HELD: the caller must release via
    /// finishWrite(...) whether the write succeeds or fails. Per-write
    /// lock, not process-lifetime (design doc §4.2) — a session-long hold
    /// would block the supported live dossier-merge workflow.
    ///
    /// Order: latch → ownership → staleness. If another process owns the
    /// catalog, "your copy is stale" is a confusing way to say "you are
    /// not the writer".
    private func writePrecondition() -> CatalogWriteError? {
        func fail(_ e: CatalogWriteError) -> CatalogWriteError {
            lastWriteError = e
            CatalogWriteJournal.record(e, catalogURL: fileURL)
            return e
        }

        if let reason = writesDisabledReason {
            return fail(.writesDisabled(reason))
        }

        switch lock.acquire() {
        case .acquired:
            break
        case .heldByAnother(let owner):
            return fail(.lockedByAnotherProcess(owner: owner))
        case .unavailable(let reason):
            // FAIL OPEN, deliberately. If the lock file cannot even be
            // created (permissions, missing dir, read-only volume) then
            // refusing every save turns an unlikely filesystem hiccup into
            // guaranteed total data loss — far worse than the rare clobber
            // the lock exists to prevent. Journal loudly and proceed: an
            // ADVISORY mechanism that bricks saving when it malfunctions
            // is a worse bug than the one it fixes.
            lastWriteError = .lockUnavailable(reason)
            CatalogWriteJournal.record(.lockUnavailable(reason), catalogURL: fileURL)
        }

        // OCC check, from the file's first 4 KB — no 41 MB decode. A file
        // that does not exist yet cannot be stale; a header we cannot
        // parse is treated as generation 0 rather than a refusal, because
        // pre-generation catalogs are legitimate.
        // Compare against everything WE have claimed, not just what we
        // have loaded: an in-flight async save that has already landed but
        // whose main-actor completion has not run yet is our own write, and
        // must not make the quit-time saveNow refuse itself as "stale".
        let onDisk = CatalogSnapshot.headerProbe(at: fileURL)?.generation ?? 0
        if onDisk > max(loadedGeneration, claimedGeneration) {
            lock.release()   // we will not be writing; do not squat on it
            return fail(.staleGeneration(loaded: loadedGeneration, onDisk: onDisk))
        }
        return nil
    }

    /// Balances a successful writePrecondition(). Releases the per-write
    /// lock and, on success, advances the session generation to what the
    /// write stamped on disk.
    private func finishWrite(success: Bool, wroteGeneration: Int) {
        if success {
            // max(): completions can arrive out of order (an async save's
            // main-actor completion may land AFTER a later saveNow already
            // advanced us). Never regress -- a regression would make the
            // next save see its own predecessor as a foreign, newer write.
            loadedGeneration = max(loadedGeneration, wroteGeneration)
            lastWriteError = nil
        } else if lastWriteError == nil {
            lastWriteError = .writeFailed("encode or atomic write failed")
        }
        lock.release()
    }

    /// Adopt the on-disk generation after in-memory state has been
    /// RECONCILED with the file — i.e. the live dossier reload decoded the
    /// current catalog.json and merged its fields onto our records. This
    /// is the design doc's "reconcile-then-save" path: a cooperating
    /// external writer (merge_dossier_jsonl) bumps `generation`; without
    /// this call the OCC guard would then refuse every save for the rest
    /// of the session. Only ever moves forward. Callers MUST have merged
    /// first — adopting without merging is exactly the lost update the
    /// guard exists to prevent.
    func adoptOnDiskGenerationAfterReconcile() {
        let onDisk = CatalogSnapshot.headerProbe(at: fileURL)?.generation ?? 0
        if onDisk > loadedGeneration {
            catalogStoreLog.info("catalog OCC: adopting on-disk generation \(onDisk) after live reconcile (was \(self.loadedGeneration))")
            loadedGeneration = onDisk
        }
    }

    /// Release ownership on orderly shutdown. The kernel releases it anyway
    /// if we die without getting here — that is the point of flock.
    func relinquishLock() {
        lock.release()
    }

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
        // Baseline for the lost-update guard: the generation of the file we
        // are about to read (design doc §4.1). Captured BEFORE decoding so
        // a slow decode cannot let another writer slip in unnoticed. Absent
        // header (pre-generation catalog) baselines at 0.
        loadedGeneration = CatalogSnapshot.headerProbe(at: fileURL)?.generation ?? 0

        // Try primary first.
        if let (records, version, master) = decode(url: fileURL) {
            if version > CatalogSnapshot.currentVersion {
                NSLog("VideoScan: catalog.json version %d is newer than this build (v%d) — refusing to load; not overwriting on next save",
                      version, CatalogSnapshot.currentVersion)
                lastLoadOutcome = .refusedNewerVersion(found: version)
                // LATCH writes off (codex #377 blocker 3). The old comment
                // said "not overwriting on next save" but nothing enforced
                // it — the quit-time save would replace the future-schema
                // catalog with an empty current-schema one. Now enforced by
                // writePrecondition.
                writesDisabledReason = "catalog.json was written by a newer build (v\(version) > v\(CatalogSnapshot.currentVersion))"
                return []
            }
            // Rotate primary → .prev on every successful load. Copy (not move)
            // so primary stays in place; replace any stale .prev.
            rotateBackup()
            masterArchive = master
            lastLoadOutcome = .loaded(fromBackup: false)
            return records
        }
        // Primary unreadable — try .prev.
        NSLog("VideoScan: primary catalog.json unreadable; trying %@", backupURL.path)
        if FileManager.default.fileExists(atPath: backupURL.path),
           let (records, version, master) = decode(url: backupURL),
           version <= CatalogSnapshot.currentVersion {
            NSLog("VideoScan: recovered catalog from %@ (%d records)", backupURL.path, records.count)
            masterArchive = master
            lastLoadOutcome = .loaded(fromBackup: true)
            return records
        }
        NSLog("VideoScan: no usable backup catalog; starting with empty records")
        lastLoadOutcome = .corruptNoBackup
        return []
    }

    /// Decode helper — returns (records, version, masterArchive) on
    /// success, nil on any failure (missing file, malformed JSON, malformed
    /// snapshot). Resolves `pairedWith` references against the decoded
    /// array.
    private func decode(url: URL) -> ([VideoRecord], Int, MasterArchiveDesignation?)? {
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
                    if rec.pairedWith == nil {
                        rec.pairGroupID = nil
                        rec.pairConfidence = nil
                    }
                }
            }
            let cleared = CorrelationScorer.revalidateExistingPairs(in: snapshot.records)
            if cleared > 0 {
                NSLog("VideoScan: cleared %d invalid persisted A/V pair endpoint(s) while loading %@",
                      cleared, url.lastPathComponent)
            }
            return (snapshot.records, snapshot.version, snapshot.masterArchive)
        } catch {
            NSLog("VideoScan: failed to decode catalog at %@: %@", url.path, String(describing: error))
            return nil
        }
    }

    /// Decode a catalog snapshot at an ARBITRARY path — the timestamped
    /// safety copies (`catalog.pre-merge.*.json`,
    /// `catalog.pre-volume-rename.*.json`, …) written by snapshotCatalog.
    /// Same decoder + pairedWith rewiring as `load()`, but with NO side
    /// effects: no rotation, no lastLoadOutcome change, no test-host gate
    /// (the caller passes an explicit path — there's nothing implicit to
    /// protect). Returns nil on any failure or a newer-version snapshot.
    /// Used by the volume-rename Undo to restore the pre-migration catalog.
    func loadRecords(fromSnapshotAtPath path: String) -> [VideoRecord]? {
        guard let (records, version, _) = decode(url: URL(fileURLWithPath: path)),
              version <= CatalogSnapshot.currentVersion else { return nil }
        return records
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
    /// - Returns: true when the snapshot durably reached disk. Refusals
    ///   (read-only viewer, test host) and write failures return false —
    ///   callers whose OWN durability bookkeeping depends on this save
    ///   (findtagd journal-ingest cursor, codex QA #277 blocker A) must
    ///   check it; fire-and-forget callers may ignore it.
    @discardableResult
    func saveNow(records: [VideoRecord]) -> Bool {
        if Self.isRunningTests && self === CatalogStore.shared { return false }
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.saveNow refused — read-only viewer mode")
            lastWriteError = .readOnlyViewer
            CatalogWriteJournal.record(.readOnlyViewer, catalogURL: fileURL)
            return false
        }
        // Ownership + staleness. Refusals are journalled by the precondition
        // and left in `lastWriteError` for the UI to surface.
        if writePrecondition() != nil { return false }
        debounceTask?.cancel()
        debounceTask = nil
        pendingRecords = nil  // superseded by this synchronous save
        // Build the Sendable DTO payload ON the main actor (the only place
        // VideoRecord is read), then encode it off-thread on the write queue.
        // CAS stamp: this write claims the next generation (design doc §4.1).
        let nextGeneration = allocateGeneration()
        let payload = Self.makePayload(records: records, generation: nextGeneration,
                                       masterArchive: masterArchive)
        var ok = false
        writeQueue.sync {
            ok = Self.encodeAndWrite(payload: payload, to: fileURL)
        }
        // Releases the per-write lock in both outcomes.
        finishWrite(success: ok, wroteGeneration: nextGeneration)
        if ok {
            observer?.catalogStoreDidWrite(self)
        }
        return ok
    }

    /// The catalog file this store owns — exposed for identity checks
    /// (findtagd ingest refuses journals produced against a DIFFERENT
    /// catalog file, codex QA #277 blocker C).
    var catalogFileURL: URL { fileURL }

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
            lastWriteError = .readOnlyViewer
            CatalogWriteJournal.record(.readOnlyViewer, catalogURL: fileURL)
            return
        }
        // Same ownership + staleness gate as saveNow. Checked before taking
        // the in-flight slot so a refusal cannot strand `saveInFlight`.
        if writePrecondition() != nil { return }
        if saveInFlight {
            pendingRecords = records
            return
        }
        saveInFlight = true

        // Snapshot ON the main actor — see makePayload for why. Building the
        // DTO array copies every persisted field by value (String/Array CoW),
        // yielding a fully-independent Sendable payload that crosses the actor
        // boundary with no @unchecked hatch and no live VideoRecord.
        let t0 = CFAbsoluteTimeGetCurrent()
        // CAS stamp: this write claims the next generation (design doc §4.1).
        let nextGeneration = allocateGeneration()
        let payload = Self.makePayload(records: records, generation: nextGeneration,
                                       masterArchive: masterArchive)
        let snapshotMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        catalogStoreLog.debug("catalog save: snapshot of \(records.count) records took \(snapshotMs, format: .fixed(precision: 1)) ms")

        let dest = fileURL
        let delay = testWriteDelay
        writeQueue.async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let ok = Self.encodeAndWrite(payload: payload, to: dest)
            Task { @MainActor [weak self] in
                self?.asyncSaveDidFinish(success: ok, wroteGeneration: nextGeneration)
            }
        }
    }

    /// Back on the main actor after a background write. Releases the
    /// per-write lock, fires the observer, and, if anything went dirty
    /// while we were writing, starts the follow-up save.
    private func asyncSaveDidFinish(success: Bool, wroteGeneration: Int) {
        saveInFlight = false
        finishWrite(success: success, wroteGeneration: wroteGeneration)
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

    /// Write a snapshot of `records` to an ARBITRARY path using the same
    /// makePayload → encodeAndWrite pipeline as catalog.json saves, so the
    /// bytes are format-identical (decodable via CatalogSnapshot). Used by
    /// the scan-merge tripwire for catalog.pre-merge.<stamp>.json siblings
    /// (QA #7, 2026-07-02: the snapshot must capture IN-MEMORY state — a
    /// disk copy of catalog.json lags by the 2 s save debounce).
    ///
    /// Synchronous ON PURPOSE: the tripwire must know the snapshot landed
    /// before deciding whether to prune (fail-safe contract: no snapshot →
    /// no prune). It never writes catalog.json itself, so it does not
    /// contend with writeQueue's debounced saves. Returns true on success.
    /// Read-only guard (QA 2026-07-02, fix/qa-minors): this was the ONE
    /// write path missing the check saveNow/scheduleSave/saveAsync all
    /// enforce — a read-only viewer could still write catalog.pre-merge.*
    /// siblings. Returning false feeds the tripwire's existing fail-safe:
    /// no snapshot → degrade to no-prune (retainedNoSnapshot semantics).
    func writeSnapshot(records: [VideoRecord], toPath path: String) -> Bool {
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.writeSnapshot refused — read-only viewer mode")
            return false
        }
        return Self.encodeAndWrite(payload: Self.makePayload(records: records,
                                                             masterArchive: masterArchive),
                                   to: URL(fileURLWithPath: path))
    }

    /// Build the on-disk payload as a Sendable DTO. Must run on the main
    /// actor — `VideoRecordDTO(_:)` is the ONLY place the live (non-Sendable)
    /// VideoRecord is read on the save path. Each DTO copies every persisted
    /// field BY VALUE (String/Array CoW), so the resulting payload is a
    /// fully-independent, race-free snapshot the background encoder owns
    /// outright. This supersedes the old deepCopySnapshot-then-encode dance:
    /// the DTO construction IS the race-free copy, and ships across the actor
    /// boundary as a true value type (no @unchecked Sendable box).
    private static func makePayload(records: [VideoRecord],
                                    generation: Int = 0,
                                    masterArchive: MasterArchiveDesignation? = nil) -> CatalogSnapshotDTO {
        CatalogSnapshotDTO(
            version: CatalogSnapshot.currentVersion,
            generation: generation,
            savedAt: Date(),
            records: records.map(VideoRecordDTO.init),
            savedFromHost: CatalogHost.currentName,
            masterArchive: masterArchive
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
                let stub = VideoRecord(id: partner.id)
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
    /// SHA-256 as lowercase hex. Used to prove a write landed intact.
    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-256 of a file in 1 MB chunks -- constant memory
    /// regardless of catalog size. (Deliberately its own copy rather than
    /// calling CatalogSync's: the dependency direction is CatalogSync →
    /// CatalogStore, never the reverse.)
    nonisolated static func sha256HexStreaming(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort durability barrier for a just-renamed file: F_FULLFSYNC
    /// the file, then fsync its parent directory. Failures are logged, not
    /// thrown -- a filesystem that refuses the barrier (some network/USB
    /// volumes) must not turn a successful save into a reported failure.
    nonisolated static func fullFsync(fileURL: URL) {
        let fd = open(fileURL.path, O_RDONLY)
        if fd >= 0 {
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
            close(fd)
        }
        let dirFD = open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 {
            fsync(dirFD)
            close(dirFD)
        }
    }

    nonisolated private static func encodeAndWrite(payload: CatalogSnapshotDTO, to fileURL: URL) -> Bool {
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

            // Durability. Foundation's atomic write renames a temp file into
            // place but makes no promise the bytes -- or the new directory
            // entry -- have reached stable storage. Codex #385: "durability
            // claim unproven". F_FULLFSYNC (macOS: fsync alone only reaches
            // the drive cache) on the file, then fsync the parent directory
            // so the rename itself is durable. Runs on the write queue, so
            // the cost is off the UI thread except for the quit-time save,
            // where durability is the whole point.
            Self.fullFsync(fileURL: fileURL)

            // Read-back verification. The atomic rename guarantees readers
            // never see a partial file, but it does NOT guarantee the bytes
            // that landed are the bytes we produced -- truncation, a media
            // error, or a filesystem that lied about durability all survive
            // an atomic write. For the one file that is the entire catalog,
            // paying one re-read to prove it is cheap insurance.
            //
            // The re-read is STREAMED (1 MB chunks) rather than loaded as a
            // second Data: at the pre-reduction size the old whole-file
            // re-read doubled peak memory per save (#161 suspect 3).
            let expected = Self.sha256Hex(data)
            let actual = try Self.sha256HexStreaming(fileURL: fileURL)
            guard expected == actual else {
                let err = CatalogWriteError.verificationFailed(
                    expectedSHA256: expected, actualSHA256: actual, bytes: data.count)
                CatalogWriteJournal.record(err, catalogURL: fileURL)
                NSLog("VideoScan: CATALOG VERIFICATION FAILED — %@", err.userFacingDescription)
                catalogStoreLog.fault("catalog verification failed: expected \(expected, privacy: .public) got \(actual, privacy: .public)")
                return false
            }

            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            catalogStoreLog.debug("catalog save: encode+write+verify of \(data.count) bytes took \(ms, format: .fixed(precision: 1)) ms, sha256 \(expected.prefix(12), privacy: .public)")
            return true
        } catch {
            NSLog("VideoScan: failed to save catalog snapshot: %@", String(describing: error))
            catalogStoreLog.error("catalog save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// Sendable, encode-only mirror of `CatalogSnapshot` used solely by the
/// off-main save path (`makePayload` → `encodeAndWrite`). It replaces the
/// former `SnapshotBox: @unchecked Sendable` transport: because every field
/// is a value type (and `records` is `[VideoRecordDTO]`, itself Sendable),
/// the whole payload crosses to the write queue as a TRUE value type — no
/// unsafe hatch, and no live VideoRecord off the main actor.
///
/// BYTE-IDENTITY: its keys, order, and per-field encoding mirror
/// `CatalogSnapshot` exactly — same CodingKeys (`version`, `savedAt`,
/// `records`, `savedFromHost`), same property order, all unconditional —
/// and each `VideoRecordDTO` encodes byte-identically to its `VideoRecord`
/// (the class delegates its encoder to the DTO). The on-disk catalog.json
/// is therefore unchanged. Pinned by CatalogStoreAsyncSaveTests'
/// byte-identity regression test.
///
/// Decode still goes through `CatalogSnapshot` / `VideoRecord` on the main
/// actor (see `CatalogStore.decode(url:)`), so there is no DTO decoder.
struct CatalogSnapshotDTO: Sendable, Encodable {
    var version: Int = CatalogSnapshot.currentVersion
    /// OCC stamp (design doc §4.1). Encoded SECOND, before the 41 MB of
    /// records, so `CatalogSnapshot.headerProbe` can read it from the
    /// file's first 4 KB. JSONEncoder emits keys in CodingKeys order.
    var generation: Int = 0
    var savedAt: Date = Date()
    var records: [VideoRecordDTO] = []
    var savedFromHost: String = ""
    /// Master Archive designation — additive optional. Synthesized
    /// Encodable uses encodeIfPresent for optionals, so a nil value emits
    /// NO key and the on-disk bytes are unchanged for every catalog that
    /// has no master archive (byte-identity test still holds).
    var masterArchive: MasterArchiveDesignation? = nil

    private enum CodingKeys: String, CodingKey {
        case version, generation, savedAt, records, savedFromHost, masterArchive
    }
}

extension CatalogSnapshotDTO {
    /// Convenience: snapshot live records into the encode-only DTO. Each
    /// `VideoRecord` is copied BY VALUE into a `VideoRecordDTO` (the ONLY
    /// place the non-Sendable class is read), so the result is a true
    /// Sendable value safe to ship off the main actor — and it is the
    /// SINGLE encoder for catalog.json. Used by the synchronous export /
    /// bundle paths that previously encoded a `CatalogSnapshot` directly
    /// (refactor 2026-06-29, step 5b). Preserves the source snapshot's
    /// version / savedAt / host verbatim so the on-disk bytes are unchanged.
    ///
    /// Runs on the main actor (step 5c onward) — `VideoRecordDTO(_:)` reads
    /// the main-actor-isolated VideoRecord.
    init(_ snapshot: CatalogSnapshot) {
        self.init(version: snapshot.version,
                  generation: snapshot.generation,
                  savedAt: snapshot.savedAt,
                  records: snapshot.records.map(VideoRecordDTO.init),
                  savedFromHost: snapshot.savedFromHost,
                  masterArchive: snapshot.masterArchive)
    }
}
