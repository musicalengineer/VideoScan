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
    /// catalog.json was written by a NEWER build (GH #167, Rick 2026-10-02):
    /// its records are shown for browsing, every write is refused, and the
    /// app says so. Never an error, never a downgrade.
    case openedReadOnlyNewerVersion(found: Int)
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
///    See docs/design/scene_captions_plan.md.
///  - v5: VideoRecord gains `originalFullPath: String?` and `originVolume:
///    String?` for Relocate Volume provenance, plus two new `ArchiveStage`
///    cases (`manuallyDeleted`, `salvageFailed`). Pure additive — v4 loads
///    unchanged. See docs/design/relocate_volume_plan.md.
///  - v6: Companion to Relocate §1B Retire Volume. No catalog.json schema
///    change — the retire fields (`retiredAt`, `retiredReason`,
///    `retiredWitnesses`) live on `CatalogScanTarget` in UserDefaults and
///    in `VolumeMetadataSnapshot` for bundle export. The version bump is
///    a marker so a v6-aware build knows the parallel volume metadata
///    layer *may* carry retire fields; v5 catalog.json files load
///    unchanged (no record-level fields were added).
///  - v7 (GH #167, 2026-10-02): unknown keys are PRESERVED from here on —
///    top level and per record (`unknownFields`), written back verbatim.
///    No field changed. The bump exists so builds from before today, which
///    silently DROP keys they do not know (how masterArchive /
///    archiveFixity could vanish), see a newer catalog and refuse to save
///    it. Builds that predate the version check itself (before v2-era
///    `refusedNewerVersion`) cannot be protected by any bump.
///
/// WHEN TO BUMP (docs/practices/invariants/Catalog.md, CAT-4): only when an
/// EXISTING field's meaning or type changes, or one is removed/renamed.
/// ADDING a field never needs a bump — every v7+ build carries keys it does
/// not know through untouched. The key-snapshot sensor in
/// CatalogVersioningTests fails when a key is added, to make the addition
/// a deliberate one-line edit, not to demand a bump.
/// A build that opens a catalog NEWER than `currentVersion` shows it
/// read-only (`CatalogStore.newerCatalogVersion`) and never writes it.
struct CatalogSnapshot: Decodable {
    static let currentVersion = 7

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
    /// as nil; emitted only when set, so a catalog with no master archive
    /// carries no key. No version bump. On disk it sits in the hand-built
    /// header BEFORE `records` (it is a few hundred bytes), see
    /// `CatalogSnapshotDTO.encoded(using:)`.
    var masterArchive: MasterArchiveDesignation?
    /// Top-level keys a NEWER build wrote that this build does not know
    /// (GH #167). Kept verbatim; written back after `records`.
    var unknownFields: [String: CatalogJSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, generation, savedAt, records, savedFromHost, masterArchive
    }

    /// Every top-level key this build reads or writes. Anything else at the
    /// top of catalog.json is a future field, preserved in `unknownFields`.
    static let topLevelKeyNames: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

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
        // GH #167: top-level keys from a newer build ride along verbatim.
        unknownFields = try CatalogUnknownFields.capture(from: decoder, known: Self.topLevelKeyNames)
    }

    /// Bytes read from each end of the file by `headerProbe`. The header
    /// keys (`version`, `generation`, `savedAt`, `savedFromHost`,
    /// `masterArchive`) total well under 1 KB, so whichever side of the
    /// records array they land on, a 4 KB window sees them.
    static let probeWindowBytes = 4096

    /// Cheap OCC read: extract version + generation WITHOUT decoding 36+ MB
    /// of records. Reads the first 4 KB and, if either key is missing
    /// there, the last 4 KB.
    ///
    /// Why both ends (GH #165): JSONEncoder on this OS builds keyed objects
    /// in a Dictionary, so key order is per-process random — CodingKeys
    /// order is NOT honoured. Every catalog file written before the fix is
    /// some permutation of the six top-level keys around the records
    /// array: keys that sorted before `records` are in the head, the rest
    /// are in the tail. The app's own writer now emits a hand-built header
    /// (`CatalogSnapshotDTO.encoded(using:)`) with `version` and
    /// `generation` first, so new files always hit the head path; the tail
    /// path is for history and for foreign writers (python json.dump of a
    /// pre-generation file appends `generation` at the END).
    ///
    /// TOP-LEVEL keys only (codex review 2026-10-02 #2): a record's own
    /// "version" key — before the catalog's in the head, or after it in
    /// the tail — is not the catalog's version. `CatalogHeaderScanner`
    /// tracks strings and object depth to tell them apart, and when the
    /// version is in neither window (a hand-made layout) it scans the whole
    /// file, streamed in constant memory, rather than guess "old".
    ///
    /// The version is a THREE-WAY verdict (codex cycle #29 F1): read,
    /// confirmed absent (a complete object with no such key — a v0
    /// catalog), or UNKNOWN (the file is not something the scanner can
    /// follow: BOM-less garbage, UTF-16, an array root, truncated, bytes
    /// after the object, a non-integer version). Unknown is never "old";
    /// the write gates hold on it (`CatalogWriteHold.from`).
    struct Header: Equatable, Sendable {
        var version: CatalogVersionVerdict
        var generation: Int?
    }

    /// nil ONLY when there is no file (or a DIRECTORY sits at the path — not
    /// a catalog of any version; the write then fails honestly with EISDIR,
    /// `CatalogWriteObservabilityTests`). A file that exists but cannot be
    /// opened or followed is `.unknown`, not absent.
    static func header(at url: URL) -> Header? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        guard let found = CatalogHeaderScanner.probe(fileAt: url, window: probeWindowBytes) else {
            return Header(version: .unknown, generation: nil)
        }
        return Header(version: found.verdict, generation: found.generation)
    }

    /// Legacy tuple view of `header(at:)` for GENERATION readers (OCC
    /// baseline, sidecar bootstrap, tests). nil (not 0) when the file is
    /// missing or carries NEITHER stamp, so callers can distinguish "no
    /// file / pre-generation" from "generation 0". `version` is 0 unless
    /// the key was actually read — never use it as a write gate; gates
    /// take the verdict from `header(at:)`.
    static func headerProbe(at url: URL) -> (version: Int, generation: Int)? {
        guard let h = header(at: url) else { return nil }
        let v = h.version.number
        // EITHER key is enough. Only a file with NEITHER reads as "no header".
        guard v != nil || h.generation != nil else { return nil }
        return (v ?? 0, h.generation ?? 0)
    }
}

/// Why writes are held for the rest of the session (GH #167). One type
/// for the main-actor latch, its write-queue mirror and the gate, so the
/// three cannot disagree about what a hold is. (≈ a small tagged union.)
enum CatalogWriteHold: Equatable, Sendable {
    /// catalog.json carries a top-level `version` above `currentVersion`.
    case newerVersion(Int)
    /// catalog.json's version could not be DETERMINED (codex cycle #29
    /// F1) — see `CatalogVersionVerdict.unknown`. The file may be a newer
    /// catalog in a shape this build cannot follow; it is not replaced.
    case versionUnknown

    var newerVersion: Int? { if case .newerVersion(let v) = self { return v }; return nil }

    /// The one-line reason journalled and shown with the refusal.
    var reason: String {
        switch self {
        case .newerVersion(let v): return CatalogStore.newerCatalogReason(v)
        case .versionUnknown: return CatalogStore.unreadableCatalogReason
        }
    }

    /// Two holds, one answer: a KNOWN newer version is the more
    /// informative; between two versions the higher wins.
    func merged(with other: CatalogWriteHold) -> CatalogWriteHold {
        switch (self, other) {
        case (.newerVersion(let a), .newerVersion(let b)): return .newerVersion(max(a, b))
        case (.newerVersion, _): return self
        case (_, .newerVersion): return other
        default: return self
        }
    }

    /// The hold a probe verdict imposes, if any. nil = the file is ours to
    /// write (current or older version, or a confirmed v0 catalog).
    static func from(_ verdict: CatalogVersionVerdict) -> CatalogWriteHold? {
        switch verdict {
        case .version(let v): return v > CatalogSnapshot.currentVersion ? .newerVersion(v) : nil
        case .confirmedAbsent: return nil
        case .unknown: return .versionUnknown
        }
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

/// The newer-catalog latch, readable OFF the main actor (GH #167, codex
/// review 2026-10-02 #1). The authoritative latch lives on the main actor
/// (`CatalogStore.newerCatalogVersion`); this mirror lets a write that was
/// QUEUED before the latch fired see it on the write queue, and lets the
/// write queue record a newer catalog it discovers itself.
/// (≈ a mutex-guarded `std::optional<Hold>` shared with the writer thread.)
final class CatalogNewerLatchMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var latched: CatalogWriteHold?
    var hold: CatalogWriteHold? { lock.lock(); defer { lock.unlock() }; return latched }
    func note(_ hold: CatalogWriteHold) {
        lock.lock(); latched = latched.map { $0.merged(with: hold) } ?? hold; lock.unlock()
    }
}

/// The last check before bytes land (GH #167, codex review 2026-10-02 #1):
/// run on the write queue, after encoding and immediately before the
/// atomic write — under the per-write advisory lock for live saves. The
/// main-actor `writePrecondition` runs when the save is QUEUED; a newer
/// build can replace catalog.json (a sync, another Mac) between then and
/// now. Refuses when the latch is set or the primary on disk is newer —
/// or cannot be told from newer (codex cycle #29 F1).
/// Residual: the window between this probe and rename(2) is microseconds
/// and cannot be closed — rename is not conditional.
struct CatalogWriteGate: Sendable {
    let primaryURL: URL
    let latch: CatalogNewerLatchMirror
    /// Test seam: runs on the write queue AFTER the on-disk probe and
    /// before the gate answers, so a test can latch the main actor in
    /// exactly that window (codex cycle #29 F2). Always nil in production.
    var testAfterProbe: (@Sendable () -> Void)? = nil

    /// nil = write; otherwise why not.
    func writeHold() -> CatalogWriteHold? {
        if let h = latch.hold { return h }
        let verdict = CatalogSnapshot.header(at: primaryURL)?.version
        testAfterProbe?()
        // The probe can be long (a whole-file pass on a legacy layout).
        // A latch the main actor raised MEANWHILE outranks whatever the
        // probe read of the file as it was (codex cycle #29 F2): read the
        // mirror again, immediately before answering.
        if let h = latch.hold { return h }
        guard let verdict, let h = CatalogWriteHold.from(verdict) else { return nil }
        latch.note(h)
        return h
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
    var masterArchive: MasterArchiveDesignation? {
        didSet {
            // A designation set again cancels a pending clear: only the
            // save that follows Clear itself may carry the removal.
            if masterArchive != nil { designationClearAuthorized = false }
        }
    }

    // MARK: - Master Archive designation guard (GH #167)
    //
    // On 2026-08-20 catalog.json lost its designation with nothing logged.
    // Whatever the writer, the rule is: a LIVE catalog save may change the
    // designation from set to unset only right after the user cleared it.
    // Any other null in the slot is a bug, and the save is refused before
    // a byte is written — catalog.json keeps the designation. Every change
    // of the designation on disk gets a START line before the write and an
    // OUTCOME line after it.

    /// The designation in the catalog file this session last loaded or
    /// durably wrote — what is on disk as far as we know. nil = the file
    /// carries none.
    private(set) var persistedMasterArchive: MasterArchiveDesignation?

    /// The designation carried by the NEWEST write this session ACCEPTED —
    /// past the precondition, generation claimed — whether or not it has
    /// landed yet (codex 2026-10-02 #2). An async save's completion runs
    /// later on the main actor, so `persistedMasterArchive` alone misses a
    /// first designation still in flight: a nil save without Clear passed
    /// the guard, queued behind it on the serial write queue and overwrote
    /// it. The guard refuses when EITHER this or the persisted value
    /// carries a designation. Seeded by `load()`; never cleared by a failed
    /// write (refusing more is the safe direction).
    private(set) var acceptedMasterArchive: MasterArchiveDesignation?

    /// Set by `authorizeDesignationClear` (Clear Master Archive); consumed
    /// by the first durable write that carries no designation; cancelled
    /// when a designation is set again.
    private(set) var designationClearAuthorized = false

    /// The refusal is reported (audit line + journal) once until a save
    /// succeeds again, so a debounced save every few seconds cannot flood
    /// catalog.log or the journal.
    private var designationRefusalReported = false

    /// Where START / OUTCOME / REFUSED lines go besides os_log. The model
    /// installs one writing the console + catalog.log (`log`) and
    /// videoscan.log (`appLog`) — the one sink. nil (tests, bare stores):
    /// os_log only.
    var designationAudit: (@MainActor (String) -> Void)?

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

    /// Highest generation EVER observed for this catalog on this machine
    /// — the `catalog.generation.max` sidecar (GH #165), loaded by
    /// `load()`, advanced by every successful write. It is a FLOOR for
    /// allocation, not the OCC comparison value: `loadedGeneration` stays
    /// at what is really on disk so a foreign writer bumping the file is
    /// still detected as stale, while the next stamp is guaranteed to land
    /// above anything this catalog has ever carried. That is what turns a
    /// silent 248 → 1 reset into a logged anomaly followed by 249.
    private(set) var generationFloor: Int = 0

    /// Human-readable note about the most recent generation anomaly seen
    /// by `load()` (probe miss on a file that decodes with a generation, or
    /// an on-disk generation below the sidecar). nil when the last load was
    /// clean. Inspectable by tests and a future diagnostics panel; the same
    /// text is logged at error/fault level when it is set.
    private(set) var lastGenerationAnomaly: String?

    /// The generation the next write will stamp. Always strictly greater
    /// than anything this session has loaded or claimed AND than the
    /// sidecar's high-water mark.
    private func allocateGeneration() -> Int {
        let next = max(loadedGeneration, claimedGeneration, generationFloor) + 1
        claimedGeneration = next
        return next
    }

    /// The generation the in-memory records are known to derive from: the
    /// last generation this session loaded or durably wrote. Stamped into
    /// safety snapshots (`writeSnapshot*`) so forensics can tie a
    /// `catalog.pre-*.json` back to the catalog.json it was cut from.
    var currentGeneration: Int { loadedGeneration }

    /// Non-nil when load() refused the on-disk catalog (written by a NEWER
    /// build). While set, EVERY write path refuses — otherwise the
    /// unconditional quit-time save overwrites a future-schema catalog
    /// with an empty current-schema one. Codex blocker 3 (#377): a live
    /// data-loss path independent of concurrency, present on main.
    private(set) var writesDisabledReason: String?

    /// Set when load() found a catalog.json written by a NEWER build (GH
    /// #167): the version it carries. The records are browsable; every
    /// write path refuses (`writesDisabledReason` is latched alongside).
    /// nil while the hold is `.versionUnknown` — see `writeHold`.
    private(set) var newerCatalogVersion: Int?

    /// The session's write hold, if any (GH #167; codex cycle #29 F1): a
    /// newer catalog, or one whose version cannot be determined. Never
    /// cleared within a session. `writesDisabledReason` is its wording.
    private(set) var writeHold: CatalogWriteHold?

    /// The banner words for the current hold (nil = no banner).
    var pauseNotice: String? {
        switch writeHold {
        case .newerVersion?: return Self.newerCatalogNotice
        case .versionUnknown?: return Self.unreadableCatalogNotice
        case nil: return nil
        }
    }

    /// Off-main mirror of the latch for the write queue (codex #1).
    private let newerLatchMirror = CatalogNewerLatchMirror()

    /// The gate every `encodeAndWrite` call carries (codex #1 / #5).
    private var writeGate: CatalogWriteGate {
        CatalogWriteGate(primaryURL: fileURL, latch: newerLatchMirror,
                         testAfterProbe: testGateAfterProbe)
    }

    /// Test seam handed to every `CatalogWriteGate` this store builds (see
    /// `CatalogWriteGate.testAfterProbe`). Always nil in production.
    internal var testGateAfterProbe: (@Sendable () -> Void)?

    /// Test seam (codex cycle #29 F4): runs on the write queue after the
    /// read-back verification PASSED and before the write's completion
    /// reaches the main actor — the window in which a landed save's
    /// bookkeeping (`finishWrite`) has not yet run. Always nil in
    /// production; same nil-default protection as
    /// `testAfterWriteBeforeVerify`.
    internal var testAfterVerifyBeforeCompletion: (@Sendable (URL) -> Void)?

    /// Why writes are held, worded once for the latch and the write queue.
    nonisolated static func newerCatalogReason(_ version: Int) -> String {
        "catalog.json was saved by a newer VideoScan (catalog v\(version); this build reads up to v\(CatalogSnapshot.currentVersion))"
    }

    /// The hold for a file whose version cannot be determined (codex
    /// cycle #29 F1): not a JSON object this build can follow, truncated,
    /// bytes after the object, a non-integer version…
    nonisolated static let unreadableCatalogReason = "catalog.json could not be read as a catalog (its version could not be determined), so it is not replaced"

    /// The words the app shows while a newer catalog is open (Rick
    /// 2026-10-02). One constant so the banner, the console line and the
    /// tests agree.
    static let newerCatalogNotice = "This catalog was last saved by a newer VideoScan — you can browse, but saving is paused until you update this Mac's copy."

    /// The words for an unreadable catalog.json (codex cycle #29 F1). It
    /// says what happened and what to do; it never claims "newer".
    static let unreadableCatalogNotice = "This catalog file could not be read — you can browse what was recovered, but saving is paused so the file is not replaced. Restore catalog.json from catalog.json.prev or a backup to resume."

    /// The held-save line is said once per session (not once per debounced
    /// save) — same etiquette as the designation refusal.
    private var writesDisabledReported = false

    /// Top-level catalog.json keys a NEWER build wrote that this build does
    /// not know (GH #167). Loaded by `load()`, stamped into every payload by
    /// `makePayload`, so they are written back verbatim. Merged forward by
    /// the live reload when an external writer adds one mid-session.
    private(set) var unknownTopLevelFields: [String: CatalogJSONValue] = [:]

    /// Latch read-only for a catalog written by a newer build. Idempotent;
    /// never cleared within a session (a relaunch with a build that reads
    /// that version is the only way out — refuse over guess).
    private func latchNewerCatalog(found version: Int) {
        latchWrites(off: .newerVersion(version))
    }

    /// Latch every write off for the session (GH #167). Idempotent; a
    /// second hold only ever upgrades the wording (`merged(with:)`).
    private func latchWrites(off hold: CatalogWriteHold) {
        let before = writeHold
        writeHold = before.map { $0.merged(with: hold) } ?? hold
        newerCatalogVersion = writeHold?.newerVersion
        newerLatchMirror.note(hold)   // queued writes see it (codex #1)
        writesDisabledReason = writeHold?.reason
        guard writeHold != before else { return }
        switch writeHold {
        case .newerVersion(let version)?:
            NSLog("VideoScan: catalog.json version %d is newer than this build (v%d) — opened read-only; every save is held",
                  version, CatalogSnapshot.currentVersion)
            catalogStoreLog.notice("catalog: v\(version) is newer than this build (v\(CatalogSnapshot.currentVersion)) — read-only, saves held (GH #167)")
        case .versionUnknown?:
            NSLog("VideoScan: catalog.json's version cannot be determined — opened read-only; every save is held so the file is not replaced")
            catalogStoreLog.notice("catalog: version unknown (not a catalog this build can follow) — read-only, saves held (GH #167, codex cycle #29 F1)")
        case nil:
            break
        }
        // Tell the owner NOW, whichever path latched (load, the write
        // probe, live reload) — so the banner and model.isReadOnly
        // (which gates every background job) follow immediately rather
        // than at the next live-reload tick.
        onNewerCatalogLatched?()
    }

    /// Called once, on the main actor, the first time this store latches
    /// read-only for a newer catalog (GH #167). Installed by the model.
    /// (≈ a C++ std::function callback member; nil = nobody listening.)
    var onNewerCatalogLatched: (@MainActor () -> Void)?

    /// Merge top-level unknown keys an external writer put on disk (live
    /// reload, GH #167): theirs replace ours key by key, ours stay.
    func mergeUnknownTopLevelFields(_ incoming: [String: CatalogJSONValue]) {
        unknownTopLevelFields = CatalogUnknownFields.merged(unknownTopLevelFields, with: incoming,
                                                            known: CatalogSnapshot.topLevelKeyNames)
    }

    /// Live reload saw a catalog.json NEWER than this build on disk:
    /// latch exactly as `load()` would (GH #167). Writes were already
    /// refused by `writePrecondition`'s version probe; this makes the
    /// state visible before the next save tries.
    func noteNewerCatalogOnDisk(version: Int) {
        guard version > CatalogSnapshot.currentVersion else { return }
        latchNewerCatalog(found: version)
    }

    /// The newer-catalog gate for writers that do NOT go through
    /// `writePrecondition` — safety snapshots and the notes-repair backup /
    /// marker (codex review 2026-10-02 #5). A held latch refuses; otherwise
    /// the primary's header is probed NOW, so a newer catalog that replaced
    /// ours since the last save or reload is discovered (and latched)
    /// before any sibling file is touched. nil = go.
    func refuseIfNewerCatalogOnDisk() -> CatalogWriteError? {
        adoptLatchFromWriteQueue()
        if let held = heldWriteRefusal() { return held }
        if let hold = holdFromPrimaryOnDisk() {
            latchWrites(off: hold)
            return heldWriteRefusal()
        }
        return nil
    }

    /// Probe catalog.json NOW and say whether it may be written: nil = ours
    /// (current/older version, or a confirmed v0 catalog, or no file);
    /// otherwise the hold (newer, or version unknown — codex cycle #29 F1).
    /// Pure read; the caller latches.
    private func holdFromPrimaryOnDisk() -> CatalogWriteHold? {
        guard let h = CatalogSnapshot.header(at: fileURL) else { return nil }
        return CatalogWriteHold.from(h.version)
    }

    /// After a write the write queue REFUSED (codex #1): carry a hold it
    /// discovered into the main-actor latch, so the banner, `isReadOnly`
    /// and every later save follow at once.
    private func adoptLatchFromWriteQueue() {
        if let h = newerLatchMirror.hold, h != writeHold {
            latchWrites(off: h)
        }
    }

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

        adoptLatchFromWriteQueue()
        if let refusal = heldWriteRefusal() { return refusal }

        // GH #167 — before the lock, before any byte: never drop a
        // designation nobody cleared.
        if let refusal = designationLossRefusal() {
            lastWriteError = refusal
            if !designationRefusalReported {
                designationRefusalReported = true
                CatalogWriteJournal.record(refusal, catalogURL: fileURL)
                auditDesignation("Master Archive designation: REFUSED catalog save — it would remove \(Self.describe(persistedMasterArchive ?? acceptedMasterArchive)) but nobody cleared it. Nothing was written; \(fileURL.lastPathComponent) keeps the designation. Later saves stay refused until the designation is set again (Archive tab ▸ Initialize) or cleared on purpose (GH #167).")
            }
            return refusal
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
        let header = CatalogSnapshot.header(at: fileURL)
        // GH #167 — never downgrade. A NEWER build may have replaced the
        // file since we loaded it (same machine, or a sync), possibly at a
        // generation the staleness check below cannot tell from ours. The
        // version in the same probe settles it: latch read-only and hold,
        // before a byte is written. A version that cannot be DETERMINED
        // holds too (codex cycle #29 F1) — unknown is never "old".
        if let header, let hold = CatalogWriteHold.from(header.version) {
            lock.release()
            latchWrites(off: hold)
            return heldWriteRefusal()
        }
        let onDisk = header?.generation ?? 0
        if onDisk > max(loadedGeneration, claimedGeneration) {
            lock.release()   // we will not be writing; do not squat on it
            return fail(.staleGeneration(loaded: loadedGeneration, onDisk: onDisk))
        }
        return nil
    }

    /// The write latch (newer catalog, codex #377 / GH #167). nil when
    /// writes may proceed. The refusal is journalled and announced through
    /// the audit sink ONCE per session — a debounced save every few seconds
    /// must not flood catalog.log or the journal — and always left in
    /// `lastWriteError` for the UI.
    private func heldWriteRefusal() -> CatalogWriteError? {
        guard let reason = writesDisabledReason else { return nil }
        let e = CatalogWriteError.writesDisabled(reason)
        lastWriteError = e
        if !writesDisabledReported {
            writesDisabledReported = true
            CatalogWriteJournal.record(e, catalogURL: fileURL)
            let wayOut = writeHold == .versionUnknown
                ? "until catalog.json is restored from catalog.json.prev or a backup"
                : "until this Mac runs a VideoScan that can read this catalog"
            auditCatalog("Catalog save held — \(reason). Nothing was written; \(fileURL.lastPathComponent) is untouched. Browsing works; saving (and every background job that would save) stays paused \(wayOut) (GH #167).")
        }
        return e
    }

    /// Balances a successful writePrecondition(). Releases the per-write
    /// lock and, on success, advances the session generation to what the
    /// write stamped on disk.
    private func finishWrite(success: Bool, wroteGeneration: Int,
                             wroteDesignation: MasterArchiveDesignation?,
                             designationChanging: Bool,
                             error: CatalogWriteError? = nil) {
        if success {
            designationRefusalReported = false
            // Only the NEWEST durable write says what is on disk: an async
            // save's completion can land after a later saveNow's (see the
            // max() below), and must not resurrect the designation it
            // carried over the newer write's.
            let newest = wroteGeneration > loadedGeneration
            if newest, wroteDesignation != persistedMasterArchive {
                auditDesignation("Master Archive designation: OUTCOME durable — catalog.json generation \(wroteGeneration) now carries \(Self.describe(wroteDesignation)) (was \(Self.describe(persistedMasterArchive))). The previous catalog is catalog.json.prev / the catalog.pre-* snapshots beside it.")
                persistedMasterArchive = wroteDesignation
            } else if !newest, designationChanging {
                auditDesignation("Master Archive designation: OUTCOME superseded — catalog save generation \(wroteGeneration) landed, but a newer save already wrote \(Self.describe(persistedMasterArchive)).")
            }
            if newest, wroteDesignation == nil { designationClearAuthorized = false }
            // max(): completions can arrive out of order (an async save's
            // main-actor completion may land AFTER a later saveNow already
            // advanced us). Never regress -- a regression would make the
            // next save see its own predecessor as a foreign, newer write.
            loadedGeneration = max(loadedGeneration, wroteGeneration)
            lastWriteError = nil
            // High-water mark (GH #165). One tiny atomic write per save;
            // never decrements. Skipped when nothing advanced.
            if wroteGeneration > generationFloor {
                // codex cycle #29 F4: the write landed, but this byte beside
                // catalog.json is written LATER (an async save's completion).
                // If a newer — or unreadable — catalog replaced ours
                // meanwhile, or the latch fired, the sidecar is not ours.
                if sidecarMayAdvance() {
                    generationFloor = CatalogGenerationSidecar.recordMax(wroteGeneration,
                                                                         besideCatalogAt: fileURL)
                } else {
                    catalogStoreLog.notice("catalog OCC: generation \(wroteGeneration) landed, but catalog.json has since been replaced or writes are held — \(CatalogGenerationSidecar.fileName, privacy: .public) left untouched (GH #167)")
                }
            }
        } else if let error, case .writesDisabled = error {
            // The write queue's last-moment gate refused (codex #1): latch
            // (if it discovered the newer catalog itself) and report it
            // through the one-shot held line, like every other refusal.
            adoptLatchFromWriteQueue()
            _ = heldWriteRefusal()
        } else if let error {
            // An attempted write that FAILED is the current truth, so it
            // outranks whatever was in lastWriteError. The case that makes
            // this matter (codex QA of 4fc11741): `lockUnavailable` is
            // deliberately FAIL-OPEN — writePrecondition records it and then
            // proceeds with the write anyway. On an unwritable directory both
            // steps fail, and the old "only fill if empty" guard meant the
            // user was told "Could not obtain the catalog lock" while the
            // real, worse fact — the catalog did not persist — was dropped.
            // A prior error may also simply be stale from an earlier attempt.
            //
            // Refusals are unaffected: when writePrecondition refuses,
            // encodeAndWrite never runs, so `error` is nil and the refusal
            // below is preserved.
            lastWriteError = error
        } else if lastWriteError == nil {
            lastWriteError = .writeFailed("encode or atomic write failed")
        }
        if !success && designationChanging {
            auditDesignation("Master Archive designation: OUTCOME FAILED — catalog save generation \(wroteGeneration) did not land (\(lastWriteError?.persistentDescription ?? "unknown")); catalog.json still carries \(Self.describe(persistedMasterArchive)).")
        }
        lock.release()
    }

    /// May a landed write's completion still touch catalog.generation.max?
    /// Re-checks the latch (including what the write queue discovered) and
    /// probes the primary NOW — the same gate as `refuseIfNewerCatalogOnDisk`
    /// minus its "nothing was written" refusal line, because this write
    /// DID land (codex cycle #29 F4). Latches what it finds.
    private func sidecarMayAdvance() -> Bool {
        adoptLatchFromWriteQueue()
        if writeHold != nil { return false }
        if let hold = holdFromPrimaryOnDisk() {
            latchWrites(off: hold)
            return false
        }
        return true
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
        // GH #167: writes are held — this session will never save, so
        // there is nothing to adopt, and the sidecar is not ours to bump.
        guard writeHold == nil else { return }
        let header = CatalogSnapshot.header(at: fileURL)
        // The file may have become newer (or unreadable) since the reload
        // decoded it.
        if let header, let hold = CatalogWriteHold.from(header.version) {
            latchWrites(off: hold)
            return
        }
        let onDisk = header?.generation ?? 0
        if onDisk > loadedGeneration {
            catalogStoreLog.info("catalog OCC: adopting on-disk generation \(onDisk) after live reconcile (was \(self.loadedGeneration))")
            loadedGeneration = onDisk
            if onDisk > generationFloor {
                generationFloor = CatalogGenerationSidecar.recordMax(onDisk, besideCatalogAt: fileURL)
            }
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
    /// missing or unreadable with no usable backup — never throws into the
    /// caller, since a missing snapshot on first launch is normal.
    ///
    /// Side-effects:
    ///   - On a successful primary load, the primary is rotated to
    ///     `catalog.json.prev` BEFORE decoding so the previous good copy is
    ///     preserved one generation back. (We copy, not move — keeps the
    ///     primary in place so a power-loss between rotate and any future
    ///     save still leaves a real catalog.json on disk.)
    ///   - On a corrupt primary, we attempt to decode `.prev` and use it.
    ///   - On a newer-version primary (GH #167) the records are returned
    ///     for BROWSING and every write is latched off for the session, so
    ///     no save can overwrite or downgrade the newer file. The primary
    ///     is NOT rotated (zero bytes written), so a downgrade-then-upgrade
    ///     cycle still sees the original catalog. Same latch when the
    ///     newer primary cannot even be decoded (.prev shown, read-only).
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
        lastGenerationAnomaly = nil
        // High-water mark from the sidecar (bootstrapped from sibling
        // catalog files on first run). Read BEFORE decode so the floor is
        // known even if decode falls back to .prev — and even if there is
        // no catalog.json at all: a catalog that carried generation N
        // before must not restart at 1 just because the file was removed.
        // GH #167 (codex review 2026-10-02 #2): NOTHING is written beside
        // the catalog until the authoritative decode below has said it is
        // not newer — the first-run bootstrap is computed now but persisted
        // only by `persistBootstrappedFloorIfNeeded()` on the writable
        // branches. (Previously a cheap probe decided, and a probe can be
        // fooled; the decode cannot.)
        let sidecarExisted = CatalogGenerationSidecar.read(besideCatalogAt: fileURL) != nil
        generationFloor = CatalogGenerationSidecar.load(besideCatalogAt: fileURL, persistBootstrap: false)
        func persistBootstrappedFloorIfNeeded() {
            // Never a byte beside a held catalog (codex cycle #29 F1): the
            // next writable load bootstraps for real.
            if !sidecarExisted, writeHold == nil {
                CatalogGenerationSidecar.seedIfAbsent(generationFloor, besideCatalogAt: fileURL)
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSLog("VideoScan: CatalogStore.load() — no catalog file at %@", fileURL.path)
            persistBootstrappedFloorIfNeeded()
            lastLoadOutcome = .missing
            return []
        }
        // Try primary first. The OCC baseline (`loadedGeneration`) is the
        // generation of the file we DECODED — the records we actually hold
        // — never the cheap probe's (codex #500): catalog.json can be
        // atomically replaced between the probe and Data(contentsOf:), and
        // baselining on the older probe would let a later foreign bump of
        // the replacement slip under the staleness check. The probe is
        // taken before AND after the decode purely to make that race
        // visible: a disagreement means the file moved under us, and we
        // reload once.
        if let primary = decodePrimaryStable() {
            if primary.version > CatalogSnapshot.currentVersion {
                // GH #167 (Rick 2026-10-02): a newer catalog is READ-ONLY,
                // not an error. Show its records for browsing; LATCH every
                // write off (codex #377 blocker 3 — the quit-time save must
                // never replace a newer catalog). No rotation, no OCC
                // adoption: this session writes no catalog bytes.
                latchNewerCatalog(found: primary.version)
                lastLoadOutcome = .openedReadOnlyNewerVersion(found: primary.version)
                masterArchive = primary.masterArchive   // shown, never saved
                unknownTopLevelFields = primary.unknownTopLevel
                return primary.records
            }
            persistBootstrappedFloorIfNeeded()
            reconcileLoadedGeneration(decoded: primary.generation,
                                      probed: lastPrimaryProbe,
                                      source: fileURL.lastPathComponent)
            // Rotate primary → .prev on every successful load. Copy (not move)
            // so primary stays in place; replace any stale .prev.
            rotateBackup()
            masterArchive = primary.masterArchive
            persistedMasterArchive = primary.masterArchive
            acceptedMasterArchive = primary.masterArchive
            unknownTopLevelFields = primary.unknownTopLevel
            lastLoadOutcome = .loaded(fromBackup: false)
            return primary.records
        }
        // Primary undecodable. If its header says a NEWER build wrote it
        // (a newer build changed a field's type — exactly when it bumps),
        // falling back to .prev with writes enabled would let the next save
        // overwrite it with older data. Latch read-only first; .prev is
        // shown for browsing only (GH #167 — refuse over guess).
        // A version that cannot be DETERMINED latches the same way (codex
        // cycle #29 F1): the recovery below still shows .prev, but this
        // session writes nothing — not the sidecar, not catalog.json. The
        // way out is restoring the file, and the banner says so.
        if let hold = holdFromPrimaryOnDisk() {
            latchWrites(off: hold)
            if case .newerVersion(let probed) = hold {
                lastLoadOutcome = .openedReadOnlyNewerVersion(found: probed)
                if FileManager.default.fileExists(atPath: backupURL.path),
                   let prev = decode(url: backupURL) {
                    masterArchive = prev.masterArchive   // shown, never saved
                    return prev.records
                }
                return []
            }
        }
        // Primary unreadable — try .prev.
        NSLog("VideoScan: primary catalog.json unreadable; trying %@", backupURL.path)
        if FileManager.default.fileExists(atPath: backupURL.path),
           let prev = decode(url: backupURL),
           prev.version <= CatalogSnapshot.currentVersion {
            NSLog("VideoScan: recovered catalog from %@ (%d records)", backupURL.path, prev.records.count)
            persistBootstrappedFloorIfNeeded()
            // The records we hold are .prev's; baseline on ITS generation
            // (probe of the corrupt primary may well have been nil).
            reconcileLoadedGeneration(decoded: prev.generation,
                                      probed: CatalogSnapshot.headerProbe(at: backupURL)?.generation,
                                      source: backupURL.lastPathComponent)
            masterArchive = prev.masterArchive
            persistedMasterArchive = prev.masterArchive
            acceptedMasterArchive = prev.masterArchive
            unknownTopLevelFields = prev.unknownTopLevel
            lastLoadOutcome = .loaded(fromBackup: true)
            return prev.records
        }
        NSLog("VideoScan: no usable backup catalog; starting with empty records")
        persistBootstrappedFloorIfNeeded()
        lastLoadOutcome = .corruptNoBackup
        return []
    }

    /// Test seam (codex #500): runs between the pre-decode probe and the
    /// decode, so a test can atomically replace catalog.json in exactly the
    /// window the race lives in. Always nil in production.
    internal var testBetweenProbeAndDecode: (() -> Void)?

    /// Test seam (codex #934): runs after the atomic write and fsync but
    /// BEFORE the read-back verification, so a test can corrupt the file in
    /// exactly the window `verificationFailed` exists to catch. There is no
    /// other way to induce that path deterministically — the atomic write is
    /// temp-file + rename(2), so anything pre-planted at the destination is
    /// replaced before the verify reads it.
    ///
    /// The real safety is that it defaults to nil and production never
    /// assigns it. The TestEnvironment.isTestHost gate at the call site is a
    /// second layer, NOT an absolute boundary (codex QA): that predicate
    /// trusts launch markers — VS_UI_TEST=1 among them — so a shipped app
    /// launched with one set would satisfy it. The gate narrows the window;
    /// the nil default is what closes it.
    ///
    /// Passed EXPLICITLY into `encodeAndWrite` rather than read from a
    /// static: encodeAndWrite is nonisolated static, and a static mutable
    /// hook would be both a Swift 6 concurrency hazard and shared state that
    /// leaks between tests. `@Sendable` because it is invoked on the write
    /// queue.
    internal var testAfterWriteBeforeVerify: (@Sendable (URL) -> Void)?

    /// Probe value that accompanied the decode `load()` accepted (the
    /// post-decode probe of the final attempt). nil when the probe found no
    /// stamp. Diagnostic only — never an OCC input.
    private var lastPrimaryProbe: Int?

    /// How many times `decodePrimaryStable` will re-read when the file
    /// visibly changed during the decode. One retry is enough to turn a
    /// single concurrent replacement into a clean read; a file that keeps
    /// changing is accepted as-is (decoded values win) and logged.
    static let loadRetryLimit = 1

    /// Decode catalog.json, probing the header before and after. If the
    /// two probes disagree the file was replaced mid-read — log it and read
    /// again (once). Returns the decode result; `lastPrimaryProbe` is left
    /// at the post-decode probe of the accepted read.
    private func decodePrimaryStable() -> DecodedCatalog? {
        var attempt = 0
        var before = CatalogSnapshot.headerProbe(at: fileURL)?.generation
        while true {
            testBetweenProbeAndDecode?()
            let result = decode(url: fileURL)
            let after = CatalogSnapshot.headerProbe(at: fileURL)?.generation
            lastPrimaryProbe = after
            // Only a CHANGE between the two probes signals a move; a probe
            // that is nil both times (pre-generation / pathological layout)
            // is handled by reconcileLoadedGeneration, not here.
            if before == after || attempt >= Self.loadRetryLimit {
                if before != after {
                    let msg = "catalog OCC: \(fileURL.lastPathComponent) kept changing during load (probe \(String(describing: before)) → \(String(describing: after))); accepting the decoded read as-is (#165/#500)"
                    lastGenerationAnomaly = msg
                    NSLog("VideoScan: %@", msg)
                    catalogStoreLog.error("\(msg, privacy: .public)")
                }
                return result
            }
            attempt += 1
            let msg = "catalog OCC: \(fileURL.lastPathComponent) changed during load (probe \(String(describing: before)) → \(String(describing: after))); re-reading (#165/#500)"
            NSLog("VideoScan: %@", msg)
            catalogStoreLog.notice("\(msg, privacy: .public)")
            before = after
        }
    }

    /// Settle `loadedGeneration` once the full decode has spoken, and
    /// refuse to silently downgrade (GH #165):
    ///
    ///  - `loadedGeneration` IS the decoded generation — the records we
    ///    hold — full stop. The probe is a diagnostic here, never an input
    ///    (codex #500: a probe-before-decode baseline can exceed what was
    ///    actually read if the file is replaced mid-load, and then a later
    ///    foreign bump is not seen as stale).
    ///  - Probe found nothing but the file DECODES with a generation → log
    ///    at error level (a layout the head+tail probe cannot see is worth
    ///    knowing about).
    ///  - On-disk generation is BELOW the sidecar's high-water mark → the
    ///    counter regressed (the 8/18 incident). Log at fault level and
    ///    leave `generationFloor` in charge of ALLOCATION only: the next
    ///    write stamps max(seen, onDisk)+1, so the sequence resumes above
    ///    the old maximum instead of restarting at 1, while staleness is
    ///    still judged against the true on-disk value.
    ///  - Otherwise advance the sidecar to what we loaded.
    private func reconcileLoadedGeneration(decoded: Int, probed: Int?, source: String) {
        if probed == nil, decoded > 0 {
            let msg = "catalog OCC: header probe found no generation in the head or tail of \(source) but the file decodes with generation \(decoded) — using the decoded value (#165)"
            lastGenerationAnomaly = msg
            NSLog("VideoScan: %@", msg)
            catalogStoreLog.error("\(msg, privacy: .public)")
        } else if let probed, probed != decoded {
            let msg = "catalog OCC: header probe of \(source) read generation \(probed) but the decode read \(decoded) — trusting the decode"
            lastGenerationAnomaly = msg
            NSLog("VideoScan: %@", msg)
            catalogStoreLog.error("\(msg, privacy: .public)")
        }
        loadedGeneration = decoded

        if loadedGeneration < generationFloor {
            let msg = "catalog OCC: \(source) is at generation \(loadedGeneration) but this catalog has carried generation \(generationFloor) before (\(CatalogGenerationSidecar.fileName)) — the counter regressed; re-seeding so the next write stamps \(generationFloor + 1) (#165)"
            lastGenerationAnomaly = msg
            NSLog("VideoScan: %@", msg)
            catalogStoreLog.fault("\(msg, privacy: .public)")
        } else if loadedGeneration > generationFloor, writeHold == nil {
            // (held: the sidecar beside an unreadable primary is not ours
            // to touch — codex cycle #29 F1; in memory the floor is moot.)
            generationFloor = CatalogGenerationSidecar.recordMax(loadedGeneration, besideCatalogAt: fileURL)
        }
    }

    /// What `decode(url:)` hands back. (≈ a plain C struct return instead
    /// of a growing tuple.)
    private struct DecodedCatalog {
        let records: [VideoRecord]
        let version: Int
        let masterArchive: MasterArchiveDesignation?
        let generation: Int
        let unknownTopLevel: [String: CatalogJSONValue]
    }

    /// Decode helper — nil on any failure (missing file, malformed JSON,
    /// malformed snapshot). Resolves `pairedWith` references against the
    /// decoded array.
    private func decode(url: URL) -> DecodedCatalog? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
            // One UUID = one record. A file that carries twins (the 8/17
            // live-reload re-append incident) must LOAD — the old
            // Dictionary(uniqueKeysWithValues:) trapped on the first
            // duplicate and the app crashed at launch. Dedupe here with
            // the same policy the model uses (keep the current home:
            // relinked twin, else the one whose file exists, else first);
            // the model's repair then finds nothing to do.
            let records = Self.dedupingByID(snapshot.records, sourceName: url.lastPathComponent)
            // Build id → record map and rewire pairedWith references.
            var byID: [UUID: VideoRecord] = [:]
            byID.reserveCapacity(records.count)
            for r in records { byID[r.id] = r }
            for rec in records {
                if let pid = rec.pendingPairedWithID {
                    rec.pairedWith = byID[pid]
                    rec.pendingPairedWithID = nil
                    if rec.pairedWith == nil {
                        rec.pairGroupID = nil
                        rec.pairConfidence = nil
                    }
                }
            }
            let cleared = CorrelationScorer.revalidateExistingPairs(in: records)
            if cleared > 0 {
                NSLog("VideoScan: cleared %d invalid persisted A/V pair endpoint(s) while loading %@",
                      cleared, url.lastPathComponent)
            }
            return DecodedCatalog(records: records, version: snapshot.version,
                                  masterArchive: snapshot.masterArchive,
                                  generation: snapshot.generation,
                                  unknownTopLevel: snapshot.unknownFields)
        } catch {
            NSLog("VideoScan: failed to decode catalog at %@: %@", url.path, String(describing: error))
            return nil
        }
    }

    /// Dedupe by record id, keeping the current home. Pure; logs a summary
    /// when it drops anything.
    nonisolated static func dedupingByID(_ records: [VideoRecord], sourceName: String) -> [VideoRecord] {
        var index: [UUID: Int] = [:]
        var kept: [VideoRecord] = []
        kept.reserveCapacity(records.count)
        var dropped = 0
        for rec in records {
            if let i = index[rec.id] {
                dropped += 1
                let current = kept[i]
                let recRelinked = rec.originalFullPath != nil, curRelinked = current.originalFullPath != nil
                if recRelinked != curRelinked {
                    if recRelinked { kept[i] = rec }
                } else if FileManager.default.fileExists(atPath: rec.fullPath)
                            && !FileManager.default.fileExists(atPath: current.fullPath) {
                    kept[i] = rec
                }
            } else {
                index[rec.id] = kept.count
                kept.append(rec)
            }
        }
        if dropped > 0 {
            NSLog("VideoScan: %@ carried duplicate record id(s) — kept the current home for each, dropped %d stale twin(s) (files untouched)", sourceName, dropped)
            catalogStoreLog.notice("decode: dropped \(dropped) duplicate-id twin(s) from \(sourceName, privacy: .public)")
        }
        return kept
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
        guard let d = decode(url: URL(fileURLWithPath: path)),
              d.version <= CatalogSnapshot.currentVersion else { return nil }
        return d.records
    }

    /// The records currently in catalog.json (or .prev when the primary is
    /// unreadable) for a READ-ONLY query, WITHOUT adopting the file as this
    /// session's state (GH #167).
    ///
    /// `load()` is the SESSION load: it replaces the designation slot the
    /// next save serialises, re-baselines the OCC generation and rotates
    /// catalog.json → .prev. Person Finder used to call it at every job
    /// start just to build a skip set, which nulled a designation set
    /// inside the save debounce, reverted a rehomed one, adopted a foreign
    /// writer's generation without merging (so our next save clobbered
    /// it) and overwrote the one-generation-back backup. This read touches
    /// none of that. Same test-host gate as `load()` for the shared store.
    /// (≈ a const member function: it only reads the file.)
    func readRecordsWithoutAdopting() -> [VideoRecord] {
        if Self.isRunningTests && self === CatalogStore.shared { return [] }
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path),
           let records = loadRecords(fromSnapshotAtPath: fileURL.path) {
            return records
        }
        if fm.fileExists(atPath: backupURL.path),
           let records = loadRecords(fromSnapshotAtPath: backupURL.path) {
            return records
        }
        return []
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
            ViewerWriteGuard.refuse("CatalogStore.saveNow")
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
                                       masterArchive: masterArchive,
                                       unknownTopLevel: unknownTopLevelFields)
        let designationChanging = noteDesignationWriteStart(payload.masterArchive,
                                                            generation: nextGeneration)
        var writeError: CatalogWriteError?
        // Captured on the main actor; the closure crosses to writeQueue.
        let seam = testAfterWriteBeforeVerify
        let gate = writeGate
        // BEGIN line before a synchronous, unbounded write. Everything inside
        // writeQueue.sync — encode, atomic write, F_FULLFSYNC, SHA-256 re-read
        // — can block forever on a stalling volume, and this call happens on
        // the main thread during applicationWillTerminate.
        // os.Logger's message is an autoclosure, so the capture must be explicit.
        let destName = fileURL.lastPathComponent
        catalogStoreLog.notice("catalog save: BEGIN \(records.count) records → \(destName, privacy: .public)")
        writeQueue.sync {
            writeError = Self.encodeAndWrite(payload: payload, to: fileURL,
                                             purpose: .liveCatalog, gate: gate,
                                             afterWriteBeforeVerify: seam)
        }
        let ok = writeError == nil
        // Releases the per-write lock in both outcomes. The error is carried
        // through so lastWriteError names the real cause instead of a fixed
        // "encode or atomic write failed".
        finishWrite(success: ok, wroteGeneration: nextGeneration,
                    wroteDesignation: payload.masterArchive,
                    designationChanging: designationChanging, error: writeError)
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
            ViewerWriteGuard.refuse("CatalogStore.scheduleSave")
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

    /// ACKNOWLEDGED durable save (codex #1659): the same write as `saveNow`
    /// — ownership/staleness gate, snapshot on the main actor, encode +
    /// atomic write + F_FULLFSYNC + verify on `writeQueue` — but the main
    /// actor AWAITS the write instead of blocking on `writeQueue.sync`, so a
    /// caller that must know the data is on disk (the Archive Angel's
    /// rollback journal) never freezes the UI. FIFO on the serial write
    /// queue orders it after any async save already running, exactly as
    /// `saveNow` is ordered. Any pending debounced / coalesced save is
    /// superseded by this snapshot (as in `saveNow`).
    /// - Returns: true only when the snapshot durably reached disk.
    func saveAcknowledged(records: [VideoRecord]) async -> Bool {
        if Self.isRunningTests && self === CatalogStore.shared { return false }
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.saveAcknowledged refused — read-only viewer mode")
            ViewerWriteGuard.refuse("CatalogStore.saveAcknowledged")
            lastWriteError = .readOnlyViewer
            CatalogWriteJournal.record(.readOnlyViewer, catalogURL: fileURL)
            return false
        }
        if writePrecondition() != nil { return false }
        debounceTask?.cancel()
        debounceTask = nil
        pendingRecords = nil  // superseded by this save
        let nextGeneration = allocateGeneration()
        let payload = Self.makePayload(records: records, generation: nextGeneration,
                                       masterArchive: masterArchive,
                                       unknownTopLevel: unknownTopLevelFields)
        let designationChanging = noteDesignationWriteStart(payload.masterArchive,
                                                            generation: nextGeneration)
        let dest = fileURL
        let seam = testAfterWriteBeforeVerify
        let afterVerify = testAfterVerifyBeforeCompletion
        let gate = writeGate
        catalogStoreLog.notice("catalog save (acknowledged): BEGIN \(records.count) records → \(dest.lastPathComponent, privacy: .public)")
        let writeError: CatalogWriteError? = await withCheckedContinuation { cont in
            writeQueue.async {
                cont.resume(returning: Self.encodeAndWrite(payload: payload, to: dest,
                                                           purpose: .liveCatalog, gate: gate,
                                                           afterWriteBeforeVerify: seam,
                                                           afterVerify: afterVerify))
            }
        }
        let ok = writeError == nil
        finishWrite(success: ok, wroteGeneration: nextGeneration,
                    wroteDesignation: payload.masterArchive,
                    designationChanging: designationChanging, error: writeError)
        if ok { observer?.catalogStoreDidWrite(self) }
        catalogStoreLog.notice("catalog save (acknowledged): \(ok ? "durable" : "FAILED", privacy: .public)")
        return ok
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
                                       masterArchive: masterArchive,
                                       unknownTopLevel: unknownTopLevelFields)
        let designationChanging = noteDesignationWriteStart(payload.masterArchive,
                                                            generation: nextGeneration)
        let wroteDesignation = payload.masterArchive
        let snapshotMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        catalogStoreLog.debug("catalog save: snapshot of \(records.count) records took \(snapshotMs, format: .fixed(precision: 1)) ms")

        let dest = fileURL
        let delay = testWriteDelay
        let seam = testAfterWriteBeforeVerify
        let afterVerify = testAfterVerifyBeforeCompletion
        let gate = writeGate
        writeQueue.async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let writeError = Self.encodeAndWrite(payload: payload, to: dest,
                                                 purpose: .liveCatalog, gate: gate,
                                                 afterWriteBeforeVerify: seam,
                                                 afterVerify: afterVerify)
            Task { @MainActor [weak self] in
                self?.asyncSaveDidFinish(success: writeError == nil,
                                         wroteGeneration: nextGeneration,
                                         wroteDesignation: wroteDesignation,
                                         designationChanging: designationChanging,
                                         error: writeError)
            }
        }
    }

    /// Back on the main actor after a background write. Releases the
    /// per-write lock, fires the observer, and, if anything went dirty
    /// while we were writing, starts the follow-up save.
    private func asyncSaveDidFinish(success: Bool, wroteGeneration: Int,
                                    wroteDesignation: MasterArchiveDesignation?,
                                    designationChanging: Bool,
                                    error: CatalogWriteError? = nil) {
        saveInFlight = false
        finishWrite(success: success, wroteGeneration: wroteGeneration,
                    wroteDesignation: wroteDesignation,
                    designationChanging: designationChanging, error: error)
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
        // GH #167: a newer catalog is open — or has just replaced ours on
        // disk (codex review 2026-10-02 #5) — no catalog bytes of any kind.
        // Callers already treat false as "no snapshot → do not destroy".
        if refuseIfNewerCatalogOnDisk() != nil { return false }
        // Real generation, never 0 (GH #165): the snapshot records which
        // catalog.json generation its contents derive from.
        let wrote = Self.encodeAndWrite(payload: Self.makePayload(records: records,
                                                                  generation: currentGeneration,
                                                                  masterArchive: masterArchive,
                                                                  unknownTopLevel: unknownTopLevelFields),
                                        to: URL(fileURLWithPath: path),
                                        purpose: .snapshot, gate: writeGate,
                                        afterWriteBeforeVerify: testAfterWriteBeforeVerify) == nil
        if !wrote { adoptLatchFromWriteQueue() }
        return wrote
    }

    /// Same contract as `writeSnapshot`, but only the DTO map (the ONE
    /// place the live records are read) runs on the main actor; JSON
    /// encode + atomic write + fsync run detached (codex review D,
    /// 2026-08-18 — a library-scale synchronous snapshot on main is a
    /// beachball). Callers `await` it as a barrier before any unlink.
    func writeSnapshotAsync(records: [VideoRecord], toPath path: String) async -> Bool {
        if isReadOnly {
            NSLog("VideoScan: CatalogStore.writeSnapshotAsync refused — read-only viewer mode")
            return false
        }
        if refuseIfNewerCatalogOnDisk() != nil { return false }   // GH #167, as above
        let payload = Self.makePayload(records: records, generation: currentGeneration,
                                       masterArchive: masterArchive,
                                       unknownTopLevel: unknownTopLevelFields)
        let url = URL(fileURLWithPath: path)
        let seam = testAfterWriteBeforeVerify
        let gate = writeGate
        let wrote = await Task.detached(priority: .userInitiated) {
            Self.encodeAndWrite(payload: payload, to: url, purpose: .snapshot, gate: gate,
                                afterWriteBeforeVerify: seam) == nil
        }.value
        // The detached write may have discovered a newer primary (codex #1).
        if !wrote { adoptLatchFromWriteQueue() }
        return wrote
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
                                    masterArchive: MasterArchiveDesignation? = nil,
                                    unknownTopLevel: [String: CatalogJSONValue] = [:]) -> CatalogSnapshotDTO {
        CatalogSnapshotDTO(
            version: CatalogSnapshot.currentVersion,
            generation: generation,
            savedAt: Date(),
            records: records.map(VideoRecordDTO.init),
            savedFromHost: CatalogHost.currentName,
            masterArchive: masterArchive,
            unknownFields: unknownTopLevel   // GH #167: written back verbatim
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

    /// What a given `encodeAndWrite` call is persisting. The two cases fail
    /// with very different consequences, and until 2026-08-29 the log could
    /// not tell them apart: a live catalog.json failure was reported with
    /// the words "failed to save catalog snapshot", which reads as "a
    /// recovery copy was skipped" rather than "the catalog did not persist".
    /// That understatement on the app's most important file is the whole
    /// reason this parameter exists.
    enum WritePurpose: Sendable {
        /// catalog.json itself. Failure means the catalog did not persist.
        case liveCatalog
        /// A `catalog.<prefix>.<stamp>.json` recovery copy. Failure means a
        /// safety net is missing; callers degrade rather than destroy.
        case snapshot
    }

    /// Encode and atomically write `payload`. Returns nil on success, or the
    /// error that describes the failure — the caller decides what to do with
    /// it. Returning the error rather than a bare Bool is what lets a live
    /// failure carry its real cause (ENOSPC, EIO, EPERM) into
    /// `lastWriteError` and the write journal; previously the cause reached
    /// the log only, and the UI got a fixed "encode or atomic write failed".
    ///
    /// `gate` is REQUIRED (no default) so no call site can forget it: the
    /// newer-catalog check runs here, after the encode and immediately
    /// before the bytes land (codex review 2026-10-02 #1).
    nonisolated private static func encodeAndWrite(payload: CatalogSnapshotDTO,
                                                   to fileURL: URL,
                                                   purpose: WritePurpose,
                                                   gate: CatalogWriteGate,
                                                   afterWriteBeforeVerify: (@Sendable (URL) -> Void)? = nil,
                                                   afterVerify: (@Sendable (URL) -> Void)? = nil) -> CatalogWriteError? {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try payload.encoded(using: encoder)
            // GH #167: last check before any byte lands. The main actor's
            // precondition ran when this write was QUEUED; a newer build may
            // have replaced catalog.json since, or the latch fired. Not
            // journalled here — the main-actor completion reports it once
            // through `heldWriteRefusal` (no flooding).
            if let hold = gate.writeHold() {
                catalogStoreLog.notice("catalog write refused on the write queue: \(hold.reason, privacy: .public) — nothing written to \(fileURL.lastPathComponent, privacy: .public) (GH #167)")
                return .writesDisabled(hold.reason)
            }
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
            // The verification window. The isTestHost gate is defence in
            // depth, not a guarantee — see the property's documentation:
            // the predicate trusts launch markers. Nothing assigns the
            // property in production, which is the actual protection.
            if TestEnvironment.isTestHost, let corrupt = afterWriteBeforeVerify {
                corrupt(fileURL)
            }
            let actual = try Self.sha256HexStreaming(fileURL: fileURL)
            guard expected == actual else {
                let err = CatalogWriteError.verificationFailed(
                    expectedSHA256: expected, actualSHA256: actual, bytes: data.count)
                // Journalled for BOTH purposes, unlike the I/O failure below:
                // a checksum mismatch is a corruption signal whatever file it
                // lands on, and dropping snapshot coverage here would be a
                // silent reduction in what the journal can see.
                CatalogWriteJournal.record(err, catalogURL: fileURL)
                NSLog("VideoScan: CATALOG VERIFICATION FAILED — %@", err.userFacingDescription)
                catalogStoreLog.fault("catalog verification failed: expected \(expected, privacy: .public) got \(actual, privacy: .public)")
                return err
            }
            // Post-verification window (codex cycle #29 F4): the bytes are
            // proven on disk; the caller's completion has not run yet.
            if TestEnvironment.isTestHost, let hold = afterVerify {
                hold(fileURL)
            }

            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            // .notice, not .debug: debug is streamed live but NOT persisted by
            // the unified log, so it cannot be read back after a hang — which is
            // the only time anyone wants this line.
            catalogStoreLog.notice("catalog save: encode+write+verify of \(data.count) bytes took \(ms, format: .fixed(precision: 1)) ms, sha256 \(expected.prefix(12), privacy: .public)")
            return nil
        } catch {
            let err = CatalogWriteError.writeFailed(String(describing: error))
            // Name the file, not the directory: the last path component is
            // exactly what distinguishes catalog.json from a
            // catalog.<prefix>.<stamp>.json recovery copy.
            //
            // NOT a privacy guarantee, and an earlier revision of this
            // comment wrongly implied it was (codex QA): `error` is the
            // underlying NSError, whose description carries NSFilePath —
            // the full path — and it is interpolated below. The short form
            // is for readability at the front of the line, nothing more.
            let which = fileURL.lastPathComponent
            switch purpose {
            case .liveCatalog:
                // Journalled: this is the audit trail that exists because of
                // #167, and ordinary I/O failure was the one class it could
                // not see. Best-effort by nature — when the failure IS an
                // unwritable directory, the journal sits in that same
                // directory and cannot be appended either.
                // emitLog: false — the journal's own unified-log line says
                // "catalog write refused", which is wrong for a write that
                // was attempted and failed, and its detail would duplicate
                // the accurate line emitted immediately below. The journal
                // ENTRY is still written; only the generic log line is
                // suppressed, so the global journal format is untouched.
                CatalogWriteJournal.record(err, catalogURL: fileURL, emitLog: false)
                NSLog("VideoScan: FAILED TO SAVE %@ — the catalog did not persist: %@",
                      which, String(describing: error))
                catalogStoreLog.error("live catalog write failed for \(which, privacy: .public): \(String(describing: error), privacy: .public)")
            case .snapshot:
                // NOT journalled: the journal lives beside the catalog, and a
                // snapshot may be written anywhere. Callers treat nil as
                // "no recovery copy -> do not destroy", which is the real
                // safety mechanism; this line is diagnosis, not audit.
                NSLog("VideoScan: failed to write catalog snapshot %@: %@",
                      which, String(describing: error))
                catalogStoreLog.error("catalog snapshot write failed for \(which, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return err
        }
    }
}

// MARK: - Master Archive designation guard (GH #167) — behaviour
//
// The state lives in the class above (stored properties cannot live in an
// extension); the rules live here. Same file so `private` members stay
// shared (≈ C++ member functions defined outside the class body).

extension CatalogStore {

    fileprivate func auditDesignation(_ line: String) {
        catalogStoreLog.notice("\(line, privacy: .public)")
        designationAudit?(line)
    }

    /// Catalog-level audit line through the SAME one sink (console +
    /// catalog.log + videoscan.log, installed by the model). GH #167's
    /// "saving held" line uses it.
    fileprivate func auditCatalog(_ line: String) {
        auditDesignation(line)
    }

    /// The user cleared the Master Archive designation (and only that).
    /// Authorizes the NEXT durable save to write the catalog without it.
    func authorizeDesignationClear(reason: String) {
        designationClearAuthorized = true
        auditDesignation("Master Archive designation: clear authorized (\(reason)); the next catalog save removes \(persistedMasterArchive == nil ? "nothing — none on disk" : Self.describe(persistedMasterArchive)).")
    }

    /// nil = this save may proceed as far as the designation goes.
    fileprivate func designationLossRefusal() -> CatalogWriteError? {
        // Baseline = what is on disk OR what an accepted write still in
        // flight will put there (codex 2026-10-02 #2).
        guard let was = persistedMasterArchive ?? acceptedMasterArchive, masterArchive == nil,
              !designationClearAuthorized else { return nil }
        return .designationLossRefused(targetPath: was.targetPath)
    }

    /// How a designation appears in the audit lines — which go to
    /// catalog.log, videoscan.log and the unified log. By VOLUME UUID only:
    /// the target and root paths name a volume and the family archive
    /// folder (codex 2026-10-02 #7). The Archive tab shows the paths.
    nonisolated static func describe(_ d: MasterArchiveDesignation?) -> String {
        guard let d else { return "none" }
        return "the designation on volume UUID \(d.volumeUUID ?? "unknown")"
    }

    /// START line for a save whose payload changes the designation on disk.
    /// Returns whether it does, so the OUTCOME line can be paired with it.
    fileprivate func noteDesignationWriteStart(_ payloadDesignation: MasterArchiveDesignation?,
                                               generation: Int) -> Bool {
        // Accepted from here on (codex 2026-10-02 #2): whatever this payload
        // carries is what the disk will say once the queue reaches it.
        acceptedMasterArchive = payloadDesignation
        guard payloadDesignation != persistedMasterArchive else { return false }
        auditDesignation("Master Archive designation: START catalog save generation \(generation) changes it \(Self.describe(persistedMasterArchive)) → \(Self.describe(payloadDesignation)) in \(fileURL.lastPathComponent).")
        return true
    }
}

/// Sendable, encode-only mirror of `CatalogSnapshot` used by the off-main
/// save path (`makePayload` → `encodeAndWrite`) AND by every other catalog
/// writer (snapshots, catalog export, bundle export). It replaces the
/// former `SnapshotBox: @unchecked Sendable` transport: because every field
/// is a value type (and `records` is `[VideoRecordDTO]`, itself Sendable),
/// the whole payload crosses to the write queue as a TRUE value type — no
/// unsafe hatch, and no live VideoRecord off the main actor.
///
/// DELIBERATELY NOT `Encodable` (GH #165). JSONEncoder on this OS stores
/// keyed objects in a Dictionary and emits them in per-process-random
/// order — the `CodingKeys` order was never honoured, which is how
/// `generation` ended up 36 MB deep and the OCC probe reset 248 → 1. The
/// ONLY way to turn this DTO into bytes is `encoded(using:)`, which
/// hand-builds the top-level object in a FIXED order:
///
///     {"version":V,"generation":G,"savedAt":…,"savedFromHost":…
///      [,"masterArchive":{…}],"records":[…]}
///
/// so `CatalogSnapshot.headerProbe` always finds both stamps in the first
/// 4 KB, whoever the writer was. Removing the conformance is what makes
/// "all catalog writers agree" a compile-time fact rather than a review
/// checklist item. (`// For Rick: the class has no operator<<; there is
/// one named serialize() and the header is written by hand.`)
///
/// BYTE-IDENTITY: each `VideoRecordDTO` still encodes through the
/// caller's JSONEncoder (honouring its date strategy / sortedKeys /
/// prettyPrinted), byte-identical to its `VideoRecord` (the class
/// delegates its encoder to the DTO). Pinned by CatalogStoreAsyncSaveTests'
/// golden tests. `masterArchive` is emitted only when set, so a catalog
/// with no designation is unchanged apart from the header order.
///
/// Decode still goes through `CatalogSnapshot` / `VideoRecord` on the main
/// actor (see `CatalogStore.decode(url:)`), so there is no DTO decoder.
struct CatalogSnapshotDTO: Sendable {
    var version: Int = CatalogSnapshot.currentVersion
    /// OCC stamp (design doc §4.1). Emitted SECOND, right after `version`,
    /// so `CatalogSnapshot.headerProbe` reads it from the file's first 4 KB.
    var generation: Int = 0
    var savedAt: Date = Date()
    var records: [VideoRecordDTO] = []
    var savedFromHost: String = ""
    /// Master Archive designation — additive optional. Emitted only when
    /// set, so a catalog with no master archive carries no key.
    var masterArchive: MasterArchiveDesignation? = nil
    /// Top-level keys from a NEWER build (GH #167), written back verbatim
    /// AFTER `records` so the header stays a few hundred bytes.
    var unknownFields: [String: CatalogJSONValue] = [:]

    /// THE catalog.json serializer — the single place catalog bytes are
    /// produced. Top-level key order is fixed (see the type comment); the
    /// scalar header values and the records array are encoded through
    /// `encoder` so its strategies apply uniformly.
    ///
    /// Memory: the records array is encoded once (the big allocation) and
    /// appended into a pre-sized buffer — one extra copy of the records
    /// bytes, no intermediate String of the whole file.
    func encoded(using encoder: JSONEncoder) throws -> Data {
        // Scalars as top-level JSON fragments (supported since macOS 10.15),
        // so `savedAt` follows the encoder's dateEncodingStrategy exactly as
        // it would nested, and `savedFromHost` is escaped by the encoder.
        func fragment<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }

        var header = Data()
        header.append(contentsOf: Array("{\"version\":\(version),\"generation\":\(generation),\"savedAt\":".utf8))
        header.append(try fragment(savedAt))
        header.append(contentsOf: Array(",\"savedFromHost\":".utf8))
        header.append(try fragment(savedFromHost))
        if let masterArchive {
            header.append(contentsOf: Array(",\"masterArchive\":".utf8))
            header.append(try fragment(masterArchive))
        }
        header.append(contentsOf: Array(",\"records\":".utf8))

        let body = try encoder.encode(records)

        // GH #167: top-level keys a NEWER build wrote, written back after
        // the records so the header the probe reads stays small. A known
        // name is never emitted from here (it would duplicate — and could
        // contradict — the typed value above). Sorted for stable bytes.
        var tail = Data()
        for (key, value) in unknownFields.sorted(by: { $0.key < $1.key })
        where !CatalogSnapshot.topLevelKeyNames.contains(key) {
            tail.append(UInt8(ascii: ","))
            tail.append(try fragment(key))
            tail.append(UInt8(ascii: ":"))
            tail.append(try fragment(value))
        }

        var out = Data(capacity: header.count + body.count + tail.count + 1)
        out.append(header)
        out.append(body)
        out.append(tail)
        out.append(UInt8(ascii: "}"))
        return out
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
                  masterArchive: snapshot.masterArchive,
                  unknownFields: snapshot.unknownFields)
    }
}
