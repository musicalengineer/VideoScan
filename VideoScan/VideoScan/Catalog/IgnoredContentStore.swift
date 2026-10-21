// IgnoredContentStore.swift
// Content-keyed ignore list (Rick 2026-09-11): "once an item is marked
// remove/delete/ignore, remember not to ingest it again… There should
// always be an override."
//
// THE FINDING (measured on Rick's catalog.json, 13,863 records): 2,030
// ACTIVE records match a purged or set-aside record by content, and ZERO
// of them are at the same path — 2,008 are on /Volumes/LaCieWorkspace.
// Rescan preservation (VideoScanModel+RescanPreservation.swift) already
// stops a same-path rescan from resurrecting a set-aside record; the junk
// comes back as ANOTHER COPY under a NEW path, which the catalog had no
// memory of. This sidecar is that memory: a small file keyed by CONTENT,
// not path.
//
// Key = (sizeBytes, partialMD5) — the same identity duplicate detection
// and the scan-merge move matcher already trust (ScanMergeFingerprint).
// Fallback when partialMD5 is empty (hashing skipped over SMB, an older
// catalog): (filename lowercased, sizeBytes). Every entry is indexed under
// BOTH keys it can form, so a hash-less rescan still recognises a file
// that was set aside from a hashed record.
//
// Same shape as ArchiveAngelEvidenceStore: a main-actor façade, a
// Sendable on-disk value, load/save off-main. The store is NOT the
// catalog schema — no VideoRecord field, no migration. Files on disk are
// never touched by anything here: an entry means "do not catalog this
// content again", nothing more.
//
// Every mutation is O(1) (dictionary keyed by id + key → id): Tidy's Undo
// forgets 80k entries one at a time in the 100k scale test, so a
// rebuild-per-removal would be quadratic.
//
// Worst-case memory: one entry (~250 B) + two dictionary slots per
// ignored content. At 100k entries that is ~40 MB, and the catalog has
// ~3k set-aside records today. Loaded once; lookups are O(1).
//
// WHERE IT LIVES (2026-10-19: "every decision Rick makes lives in
// catalog.sqlite"). Under catalog.sqlite the list is `ignored_content`
// (IgnoredContentCatalogBacking.swift): `attachCatalog` imports
// ignored-content.json once (IgnoredContentJSONImport.swift — idempotent,
// verified, findings named) and reads the table; from then on `save()`
// writes the DIFFERENCE since the last write through the session's
// committer — a new row per entry ignored, a put-back row per entry
// forgotten — and the JSON file is never written again. Under catalog.json
// (or a test's scratch folder) the file is the store, as before.

import Foundation
import Combine
import VideoScanCore

/// One identity a store entry answers to. (For Rick: a tagged union —
/// `enum` with associated values is Swift's `std::variant` with names.)
enum IgnoredContentKey: Hashable, Sendable {
    /// Primary: the fingerprint duplicate detection trusts.
    case content(partialMD5: String, sizeBytes: Int64)
    /// Fallback when no hash exists: filename (case-folded) + size.
    case name(filenameLower: String, sizeBytes: Int64)

    /// The ONE key to look up for a file with these facts: the content key
    /// when a hash exists, else the name key. nil for a zero-size file —
    /// an empty file must never match anything (same rule as
    /// ScanMergeFingerprint.isViable).
    static func lookupKey(partialMD5: String, sizeBytes: Int64, filename: String) -> IgnoredContentKey? {
        guard sizeBytes > 0 else { return nil }
        if !partialMD5.isEmpty { return .content(partialMD5: partialMD5, sizeBytes: sizeBytes) }
        let lower = filename.lowercased()
        guard !lower.isEmpty else { return nil }
        return .name(filenameLower: lower, sizeBytes: sizeBytes)
    }

    /// EVERY key an entry with these facts is indexed under (content key
    /// when hashed, name key always).
    static func indexKeys(partialMD5: String, sizeBytes: Int64, filename: String) -> [IgnoredContentKey] {
        guard sizeBytes > 0 else { return [] }
        var keys: [IgnoredContentKey] = []
        if !partialMD5.isEmpty { keys.append(.content(partialMD5: partialMD5, sizeBytes: sizeBytes)) }
        let lower = filename.lowercased()
        if !lower.isEmpty { keys.append(.name(filenameLower: lower, sizeBytes: sizeBytes)) }
        return keys
    }
}

/// One ignored content. `reason` is the set-aside reason key
/// (CatalogScopePolicy.SetAsideReason.rawValue) or "removed-by-user";
/// `samplePath` is where the file was when it was set aside — for the
/// override sheet, never for matching.
struct IgnoredContentEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var partialMD5: String
    var sizeBytes: Int64
    var filename: String
    var reason: String
    var addedAt: Date
    var samplePath: String

    init(id: UUID = UUID(), partialMD5: String, sizeBytes: Int64, filename: String,
         reason: String, addedAt: Date, samplePath: String) {
        self.id = id
        self.partialMD5 = partialMD5
        self.sizeBytes = sizeBytes
        self.filename = filename
        self.reason = reason
        self.addedAt = addedAt
        self.samplePath = samplePath
    }

    var indexKeys: [IgnoredContentKey] {
        IgnoredContentKey.indexKeys(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename)
    }

    /// Friendly label for the override sheet — the set-aside vocabulary
    /// the rest of the UI already uses.
    var friendlyReason: String {
        CatalogScopePolicy.SetAsideReason(rawValue: reason)?.friendlyLabel ?? reason
    }
}

/// On-disk shape. A file from another store version is ignored on load
/// (poisoned-state rule) — nothing is lost, the list simply starts empty.
struct IgnoredContentFile: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var storeVersion: Int = IgnoredContentFile.currentVersion
    var savedAt: Date
    var entries: [IgnoredContentEntry]

    init(savedAt: Date = Date(), entries: [IgnoredContentEntry] = []) {
        self.savedAt = savedAt
        self.entries = entries
    }
}

/// Sendable O(1) lookup snapshot for off-main work (the Tidy plan
/// builder). Built once per plan from the store's entries — plus, for
/// the RETROACTIVE "Junk that came back" category, from the catalog's
/// own purged / set-aside records (see VideoScanModel+IgnoredContent).
struct IgnoredContentIndex: Sendable {
    private var reasonByKey: [IgnoredContentKey: String] = [:]

    init() {}

    init(entries: [IgnoredContentEntry]) {
        reasonByKey.reserveCapacity(entries.count * 2)
        for e in entries { add(partialMD5: e.partialMD5, sizeBytes: e.sizeBytes, filename: e.filename, reason: e.reason) }
    }

    var isEmpty: Bool { reasonByKey.isEmpty }
    var keyCount: Int { reasonByKey.count }

    /// Index one content under every key it can form. First reason wins
    /// (an explicit store entry is added before the catalog's tombstones).
    mutating func add(partialMD5: String, sizeBytes: Int64, filename: String, reason: String) {
        for k in IgnoredContentKey.indexKeys(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename)
        where reasonByKey[k] == nil {
            reasonByKey[k] = reason
        }
    }

    /// The reason this content was set aside, or nil when it is not
    /// ignored. ONE dictionary lookup.
    func reason(partialMD5: String, sizeBytes: Int64, filename: String) -> String? {
        guard let k = IgnoredContentKey.lookupKey(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename)
        else { return nil }
        return reasonByKey[k]
    }
}

/// Main-actor façade over `ignored-content.json`. Reads are O(1); the file
/// is loaded and saved off-main. Directory is injectable so tests never
/// touch the real App Support (and under a test host the DEFAULT directory
/// is a per-process temp folder — see `defaultDirectory`).
@MainActor
final class IgnoredContentStore: ObservableObject {

    /// The sidecar's file name. `nonisolated` because `fileURL` (below) and
    /// the off-main load/save helpers read it from outside the main actor;
    /// a `static let` on a `@MainActor` class is otherwise main-actor-
    /// isolated, which Swift 6 makes an error. (For Rick: think of it as a
    /// `constexpr` — an immutable `String` is `Sendable`, so nothing can
    /// race on it and it needs no actor at all.)
    nonisolated static let filename = "ignored-content.json"

    /// App Support/VideoScan/ — the production home. Under a unit-test
    /// host this is a per-process scratch folder instead: ~200 tests
    /// construct a VideoScanModel, and Tidy / Remove from Catalog WRITE
    /// here, so the real file must be unreachable by default (the
    /// CatalogStore.isRunningTests discipline; pinned by
    /// IgnoredContentIsolationTests).
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/ignored-content-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
    }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    /// Why this SESSION may not write the JSON file (QA r1 F5, 2026-10-21):
    /// set by the model from its read-only facts — a viewer, or a launch
    /// that opened no catalog (no latch, or catalog.sqlite refused). nil =
    /// no session reason. Only the unattached (JSON) path consults it.
    var sessionRefusal: String?

    /// Bumped on every mutation (add / remove / replace / load) — the ONE
    /// published signal; the sheet re-reads `entries` on it.
    @Published private(set) var revision: Int = 0

    /// catalog.sqlite's backing once attached (nil = the JSON file).
    private(set) var catalog: IgnoredContentCatalogBacking?
    /// The attach's import + first read; saves wait for it.
    private var catalogLoad: Task<Void, Never>?
    /// Entry ids LIVE in catalog.sqlite as of the last read or write — the
    /// base `save()` writes the difference against.
    private var persisted: Set<UUID> = []
    /// Why the last catalog write did not land (nil = it did).
    private(set) var lastSaveFailure: String?
    /// What the catalog side says (console, catalog.log) — the model sets it.
    var note: (String) -> Void = { line in appLog.write("[ignored-content] " + line) }

    private var byID: [UUID: IgnoredContentEntry] = [:]
    /// key → entry id. Several keys point at one entry; a later add of an
    /// already-indexed key is a no-op.
    private var idByKey: [IgnoredContentKey: UUID] = [:]

    init(directory: URL = IgnoredContentStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Reads

    var count: Int { byID.count }
    var isEmpty: Bool { byID.isEmpty }

    /// Oldest first (stable, by addedAt then id). O(n log n) — for the
    /// sheet (on revision change) and save; never per record.
    var entries: [IgnoredContentEntry] {
        byID.values.sorted {
            $0.addedAt != $1.addedAt ? $0.addedAt < $1.addedAt : $0.id.uuidString < $1.id.uuidString
        }
    }

    func entry(id: UUID) -> IgnoredContentEntry? { byID[id] }

    /// The reason this content was set aside, or nil. O(1).
    func reason(partialMD5: String, sizeBytes: Int64, filename: String) -> String? {
        guard let k = IgnoredContentKey.lookupKey(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename),
              let id = idByKey[k] else { return nil }
        return byID[id]?.reason
    }

    func contains(partialMD5: String, sizeBytes: Int64, filename: String) -> Bool {
        reason(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename) != nil
    }

    /// Sendable snapshot for off-main lookups.
    func index() -> IgnoredContentIndex { IgnoredContentIndex(entries: Array(byID.values)) }

    // MARK: Writes (in memory — see `save`)

    /// Remember this content. Returns false when it was already known
    /// (no duplicate entry, the original reason and date stand). O(1).
    @discardableResult
    func add(partialMD5: String, sizeBytes: Int64, filename: String,
             reason: String, samplePath: String, now: Date = Date()) -> Bool {
        let keys = IgnoredContentKey.indexKeys(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename)
        guard !keys.isEmpty else { return false }
        if keys.contains(where: { idByKey[$0] != nil }) { return false }
        let entry = IgnoredContentEntry(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename,
                                        reason: reason, addedAt: now, samplePath: samplePath)
        byID[entry.id] = entry
        for k in keys { idByKey[k] = entry.id }
        revision &+= 1
        return true
    }

    /// THE OVERRIDE: forget every entry this content answers to (a
    /// rescan will catalog it again). Returns the number of entries
    /// removed. O(1).
    @discardableResult
    func remove(partialMD5: String, sizeBytes: Int64, filename: String) -> Int {
        var ids = Set<UUID>()
        for k in IgnoredContentKey.indexKeys(partialMD5: partialMD5, sizeBytes: sizeBytes, filename: filename) {
            if let id = idByKey[k] { ids.insert(id) }
        }
        guard !ids.isEmpty else { return 0 }
        for id in ids { removeEntry(id: id) }
        revision &+= 1
        return ids.count
    }

    /// Forget one entry by id (the sheet's Put back). Returns true when found.
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard byID[id] != nil else { return false }
        removeEntry(id: id)
        revision &+= 1
        return true
    }

    /// O(1): drop the entry and only the keys that point at it.
    private func removeEntry(id: UUID) {
        guard let entry = byID.removeValue(forKey: id) else { return }
        for k in entry.indexKeys where idByKey[k] == id {
            idByKey.removeValue(forKey: k)
        }
    }

    /// Replace the in-memory list (does not touch disk).
    func replace(with file: IgnoredContentFile) {
        byID.removeAll(keepingCapacity: true)
        idByKey.removeAll(keepingCapacity: true)
        byID.reserveCapacity(file.entries.count)
        idByKey.reserveCapacity(file.entries.count * 2)
        for e in file.entries {
            byID[e.id] = e
            for k in e.indexKeys where idByKey[k] == nil { idByKey[k] = e.id }
        }
        revision &+= 1
    }

    /// Forget everything (tests).
    func clear() {
        byID.removeAll()
        idByKey.removeAll()
        revision &+= 1
    }

    // MARK: Disk

    /// Load off-main and publish. Catalog: the attach's import + read
    /// (awaited). JSON: missing / malformed / wrong-version file → the store
    /// stays empty. Returns whether anything was loaded.
    @discardableResult
    func load() async -> Bool {
        if let catalogLoad {
            await catalogLoad.value
            return !byID.isEmpty
        }
        let url = fileURL
        guard let loaded = await Self.loadOffMain(url) else { return false }
        replace(with: loaded)
        return true
    }

    /// Save. Catalog: the difference since the last write, in ONE
    /// transaction through the committer (false = refused; the change stays
    /// in memory and the next save tries again). JSON: off-main atomic
    /// replace — an EMPTY list is written too, the last entry being put back
    /// must reach disk.
    @discardableResult
    func save() async -> Bool {
        if let catalog {
            if let catalogLoad { await catalogLoad.value }
            return saveToCatalog(catalog)
        }
        if let session = sessionRefusal {
            let why = "ignore-list changes refused — \(session); \(Self.filename) is never written"
            lastSaveFailure = why
            note("Ignored content: 🔴 " + why)
            return false
        }
        // catalog.cutover beside the file names catalog.sqlite the authority
        // and this store is not attached: refused, never the JSON file
        // (codex #113 P1-4).
        if CatalogAuthority.latchNamesSQLite(in: directory) {
            let why = CatalogAuthority.sideStoreRefusal("ignore-list changes", file: Self.filename)
            lastSaveFailure = why
            note("Ignored content: 🔴 " + why)
            return false
        }
        let file = IgnoredContentFile(entries: entries)
        return await Self.saveOffMain(file, to: fileURL)
    }

    // MARK: catalog.sqlite

    /// catalog.sqlite became the authority: import the JSON file once
    /// (idempotent), then read the table. Writes wait for that load.
    func attachCatalog(_ backing: IgnoredContentCatalogBacking) {
        catalog = backing
        let file = fileURL
        catalogLoad = Task { [weak self] in
            let outcome = await backing.importJSON(from: file) { self?.note($0) }
            guard let self else { return }
            var extra: [IgnoredContentEntry] = []
            if case .refused = outcome, let parsed = await Self.loadOffMain(file) {
                extra = parsed.entries   // honoured in memory; never written by a refused session
            }
            await self.readCatalog(backing, honouring: extra)
        }
    }

    /// The table's live rows become the list; an entry already in memory
    /// that the table lacks (ignored before this read) stays, unwritten, so
    /// the next save appends it.
    private func readCatalog(_ backing: IgnoredContentCatalogBacking, honouring extra: [IgnoredContentEntry]) async {
        switch await backing.read() {
        case .failure(let words):
            note("Ignored content: 🔴 the ignore list could not be read from catalog.sqlite (\(words)) — nothing will be written")
            lastSaveFailure = words
        case .success(let rows):
            let live = IgnoredContentCatalogRows.live(rows)
            let liveIDs = Set(live.entries.map(\.id))
            // An id with a put-back row was PUT BACK by a person: it never
            // comes back into memory from the file or a stale entry, or the
            // next save would ignore it again (codex #113 P1-2).
            let putBackIDs = Set(rows.filter(\.putBack).compactMap { UUID(uuidString: $0.entry.entryID) }).subtracting(liveIDs)
            // O(n): set lookups only (100k entries in the scale test).
            let pending = byID.values.filter { !liveIDs.contains($0.id) && !putBackIDs.contains($0.id) }
            let pendingIDs = Set(pending.map(\.id))
            let honoured = extra.filter { !liveIDs.contains($0.id) && !pendingIDs.contains($0.id) && !putBackIDs.contains($0.id) }
            replace(with: IgnoredContentFile(entries: live.entries + pending + honoured))
            persisted = liveIDs
            if live.unreadable + live.repeated > 0 {
                note("Ignored content: \(live.unreadable) row(s) with an unreadable id and \(live.repeated) repeated id(s) in catalog.sqlite — left as they are")
            }
        }
    }

    /// The difference since the last write → one transaction.
    private func saveToCatalog(_ backing: IgnoredContentCatalogBacking) -> Bool {
        let now = Set(byID.keys)
        let added = now.subtracting(persisted).compactMap { byID[$0] }.sorted { $0.addedAt < $1.addedAt }
        let putBack = persisted.subtracting(now).sorted { $0.uuidString < $1.uuidString }
        if let why = backing.write(adding: added, puttingBack: putBack) {
            lastSaveFailure = why
            note("Ignored content: 🔴 \(added.count) ignored / \(putBack.count) put back NOT saved to catalog.sqlite — \(why). It stays in memory; the next change tries again")
            return false
        }
        persisted = now
        lastSaveFailure = nil
        return true
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOffMain(_ url: URL) async -> IgnoredContentFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(IgnoredContentFile.self, from: data),
              f.storeVersion == IgnoredContentFile.currentVersion else { return nil }
        return f
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func saveOffMain(_ file: IgnoredContentFile, to url: URL) async -> Bool {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys]
            // Two saves in flight (an apply, then an immediate undo) are
            // safe here: AtomicFilePublish gives each its own temp and
            // publishes with rename(2) — last writer wins, neither fails.
            try AtomicFilePublish.write(try enc.encode(file), to: url, durability: .fullFsync)
            return true
        } catch {
            return false
        }
    }
}
