// PersonFactOverlay.swift (VideoScanCore)
// The applied half of "Refresh from FamilySearch…" for one person
// (Rick, 2026-09-21). See PersonFactRefresh.swift for the diff.
//
// WHAT AN APPLY WRITES: one entry in an additive OVERLAY keyed by
// FamilySearch ID — `family-tree/person-refresh/overlay.json` in the app —
// and nothing else. No .ged is written, copied or renamed; the compiled
// generation is not touched; the overlay is laid over the loaded tree at
// READ time (FamilyGraphSharedCache, the one door Hallie, kinship, the
// People tab and the Family Tree all get their tree through).
//
// WHY AN OVERLAY AND NOT A PATCHED GEDCOM: the 2026-09-17 narrowing. The
// loader once rebuilt the whole tree from a single visible .ged and shrank
// 39,250 people to a handful. A one-person export must never be anywhere a
// loader looks, and a patched tree file would be one more thing competing
// for "newest valid .ged wins". An overlay cannot narrow anything: it can
// only change fact fields on people the loaded tree already has.
//
// RELATIONSHIPS CANNOT BE EXPRESSED HERE. An entry is a map of
// `PersonRefreshField` keys → values; there is no field for a parent, a
// spouse link or a child, and an unknown key is ignored on apply. The only
// family-level fact is a marriage DATE on a family the person is already
// in, found by the spouse's FamilySearch ID.
//
// SUPERSEDE: a full pull NEWER than an entry replaces it (the entry is
// retired with a log line) so an overlay can never fight a fresh pull.
//
// UNDO: each entry keeps its earlier states (≤ `historyLimit`); undo pops
// one, and undoing the first apply removes the entry.
//
// MEMORY: the overlay is a handful of people × a handful of strings — a
// few KB even after years of use. Applying it copies the person/family
// tables once (copy-on-write: O(people) pointer copies, ~ms for 40k) and
// patches the compiled index's life-years table in place when only dates
// and places changed; a name/sex change drops the index so it is rebuilt
// lazily (~100–300 ms Release for 16k–100k people), off the main actor.
//
// (For Rick: `Codable` ≈ a serializer generated from the member list;
// `mutating func` ≈ a non-const member function on a value type.)

import Foundation

public struct PersonFactOverlay: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Undo depth per person.
    public static let historyLimit = 10
    /// Retired entries kept for the record (oldest dropped first).
    public static let retiredLimit = 200

    public var version: Int = PersonFactOverlay.currentVersion
    /// FamilySearch ID → the facts applied for that person.
    public var entries: [String: Entry] = [:]
    /// Entries superseded by a newer full pull, newest last.
    public var retired: [RetiredEntry] = []

    public init() {}

    /// One applied fact. `value == nil` = FamilySearch no longer records
    /// it (the tree's view shows none). `before` = what the tree showed
    /// when this fact was applied — the audit trail and the manual undo.
    public struct Fact: Codable, Equatable, Sendable {
        public var value: String?
        public var before: String?
        public init(value: String?, before: String?) {
            self.value = value
            self.before = before
        }
    }

    /// An earlier state of an entry (for undo).
    public struct Snapshot: Codable, Equatable, Sendable {
        public var appliedAt: Date
        public var facts: [String: Fact]
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var familySearchID: String
        /// For humans reading the file and the log; never a key.
        public var displayName: String
        /// When the newest apply for this person happened. Compared with
        /// the newest full pull for supersede.
        public var appliedAt: Date
        /// Field key (`PersonRefreshField.key`) → fact.
        public var facts: [String: Fact]
        public var history: [Snapshot] = []
    }

    public struct RetiredEntry: Codable, Equatable, Sendable {
        public var familySearchID: String
        public var displayName: String
        public var appliedAt: Date
        public var facts: [String: Fact]
        public var retiredAt: Date
        public var reason: String
    }

    // MARK: Edits (pure)

    /// Record an apply. Merges into an existing entry for the same person
    /// (a later apply wins per field) and pushes the previous state onto
    /// that entry's undo history. Returns (before, after) for the journal.
    @discardableResult
    public mutating func record(_ changes: [PersonRefreshChange], familySearchID raw: String,
                                displayName: String, at date: Date) -> (before: Entry?, after: Entry) {
        let fsid = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let before = entries[fsid]
        var entry = before ?? Entry(familySearchID: fsid, displayName: displayName, appliedAt: date, facts: [:])
        if let before {
            entry.history.append(Snapshot(appliedAt: before.appliedAt, facts: before.facts))
            if entry.history.count > Self.historyLimit {
                entry.history.removeFirst(entry.history.count - Self.historyLimit)
            }
        }
        for change in changes {
            entry.facts[change.field.key] = Fact(value: change.new, before: change.old)
        }
        entry.displayName = displayName
        entry.appliedAt = date
        entries[fsid] = entry
        return (before, entry)
    }

    /// Undo the newest apply for one person. Nil when there is nothing to
    /// undo; `after == nil` means the entry is gone (the tree shows what the
    /// pull says again).
    @discardableResult
    public mutating func undoLast(familySearchID raw: String) -> (before: Entry, after: Entry?)? {
        let fsid = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard var entry = entries[fsid] else { return nil }
        let before = entry
        guard let previous = entry.history.popLast() else {
            entries[fsid] = nil
            return (before, nil)
        }
        entry.facts = previous.facts
        entry.appliedAt = previous.appliedAt
        entries[fsid] = entry
        return (before, entry)
    }

    /// FamilySearch IDs whose entry is OLDER than a full pull installed at
    /// `pullDate` — the pull is the fresher snapshot and wins.
    public func superseded(byPullAt pullDate: Date) -> [String] {
        entries.values.filter { $0.appliedAt < pullDate }.map(\.familySearchID).sorted()
    }

    /// Move entries to `retired` (kept for the record, never applied).
    public mutating func retire(_ ids: [String], at date: Date, reason: String) {
        for fsid in ids {
            guard let entry = entries.removeValue(forKey: fsid) else { continue }
            retired.append(RetiredEntry(familySearchID: fsid, displayName: entry.displayName,
                                        appliedAt: entry.appliedAt, facts: entry.facts,
                                        retiredAt: date, reason: reason))
        }
        if retired.count > Self.retiredLimit {
            retired.removeFirst(retired.count - Self.retiredLimit)
        }
    }

    // MARK: Codec

    public static func decode(_ data: Data) throws -> PersonFactOverlay {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersonFactOverlay.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Apply at read time

/// What an apply did, for the log line.
public struct PersonFactOverlayReport: Equatable, Sendable {
    public var peopleChanged = 0
    public var fieldsChanged = 0
    /// Entries whose person the loaded tree does not carry.
    public var missingFamilySearchIDs: [String] = []
    /// True when a name/sex change made the index stale (rebuilt lazily).
    public var indexDropped = false
    public init() {}
}

extension GedcomFamilyGraph {

    /// The tree with the overlay's facts laid over it. Pure. Only person
    /// fact fields and the marriage date of a family the person ALREADY
    /// belongs to can change; pointers, FAMC/FAMS, HUSB/WIFE/CHIL, roots,
    /// FamilySearch IDs and provenance are carried unchanged. Returns
    /// `self` untouched (same index) when nothing differs.
    public func applyingFactOverlay(_ overlay: PersonFactOverlay) -> (graph: GedcomFamilyGraph, report: PersonFactOverlayReport) {
        var report = PersonFactOverlayReport()
        guard !overlay.entries.isEmpty else { return (self, report) }
        var edit = FactOverlayEdit(people: people, families: families)
        for fsid in overlay.entries.keys.sorted() {
            guard let id = personIDByFamilySearchID[fsid], edit.people[id] != nil else {
                report.missingFamilySearchIDs.append(fsid)
                continue
            }
            let changed = edit.apply(overlay.entries[fsid]!.facts, toPersonID: id)
            if changed > 0 {
                report.peopleChanged += 1
                report.fieldsChanged += changed
            }
        }
        guard report.fieldsChanged > 0 else { return (self, report) }
        report.indexDropped = edit.indexStale && indexBox.current != nil
        let index = edit.indexStale ? nil : indexPatchingLifeYears(of: edit.lifeYearsChanged, in: edit.people)
        return (replacingRecords(people: edit.people, families: edit.families, index: index), report)
    }

    /// Keep the compiled index when only dates/places moved: the current
    /// index with the life-years labels of `ids` re-derived from `people`
    /// (O(changed)); the index itself when no label moved; nil when no
    /// index is built (it is then built lazily, as before). The caller
    /// drops the index instead when a name or sex changed.
    func indexPatchingLifeYears(of ids: Set<String>, in people: [String: Person]) -> TreeIndex? {
        guard let index = indexBox.current else { return nil }
        var updates: [Int: String] = [:]
        for id in ids {
            guard let ordinal = index.ordinal(of: id), let person = people[id] else { continue }
            updates[Int(ordinal)] = GedcomFamilyGraph.lifeYearsLabel(birth: person.birthDate,
                                                                     death: person.deathDate) ?? ""
        }
        return updates.isEmpty ? index : index.replacingLifeYears(updates)
    }

    /// The person and family tables while an overlay is laid over them,
    /// and what the changes mean for the compiled index.
    struct FactOverlayEdit {
        var people: [String: Person]
        var families: [String: Family]
        /// People whose birth or death date changed (their label is patched).
        var lifeYearsChanged: Set<String> = []
        /// A name, surname or sex changed: the index must be rebuilt.
        var indexStale = false

        /// Apply one entry's facts to the person `id` (who must be in
        /// `people`), in key order. Unknown keys are ignored. Returns how
        /// many fields changed; the person is written back only then.
        mutating func apply(_ facts: [String: PersonFactOverlay.Fact], toPersonID id: String) -> Int {
            guard var person = people[id] else { return 0 }
            var changed = 0
            for key in facts.keys.sorted() {
                guard let field = PersonRefreshField(key: key) else { continue }  // unknown key: ignored
                if apply(field, value: facts[key]!.value, to: &person) { changed += 1 }
            }
            if changed > 0 { people[id] = person }
            return changed
        }

        /// One fact. A marriage date lands on the family; every other field
        /// on the person. True when something changed.
        mutating func apply(_ field: PersonRefreshField, value: String?, to person: inout Person) -> Bool {
            let changed: Bool
            if case .marriageDate(let spouseFSID) = field {
                changed = setMarriageDate(value, of: person, spouseFamilySearchID: spouseFSID)
            } else {
                changed = person.assignOverlayFact(field, value)
            }
            guard changed else { return false }
            switch field.overlayIndexEffect {
            case .rebuild: indexStale = true
            case .patchLifeYears: lifeYearsChanged.insert(person.id)
            case .unindexed: break
            }
            return true
        }

        /// The family must already join these two people. A spouse the tree
        /// does not link is a relationship difference, and those are never
        /// applied.
        mutating func setMarriageDate(_ value: String?, of person: Person, spouseFamilySearchID: String) -> Bool {
            guard let familyID = person.spouseOfFamilies.first(where: {
                partnerFamilySearchID(inFamily: $0, of: person.id) == spouseFamilySearchID
            }), var family = families[familyID], family.marriageDate != value else { return false }
            family.marriageDate = value
            families[familyID] = family
            return true
        }

        /// The FamilySearch ID of `id`'s partner in a family. Nil when the
        /// family is unknown, has no partner, or names `id` as both or
        /// neither spouse.
        func partnerFamilySearchID(inFamily familyID: String, of id: String) -> String? {
            guard let family = families[familyID] else { return nil }
            let isHusband = family.husband == id, isWife = family.wife == id
            guard isHusband != isWife, let partner = isHusband ? family.wife : family.husband else { return nil }
            return people[partner]?.familySearchID
        }
    }
}

/// What a changed overlay field does to a compiled TreeIndex.
enum OverlayIndexEffect: Equatable, Sendable {
    /// Name, surname or sex: postings, sidebar order and married-surname
    /// tokens move — drop the index and let it rebuild lazily.
    case rebuild
    /// Birth or death date: patch that person's life-years label.
    case patchLifeYears
    /// Places and marriage dates are not indexed.
    case unindexed
}

extension PersonRefreshField {
    var overlayIndexEffect: OverlayIndexEffect {
        switch self {
        case .name, .surname, .sex: return .rebuild
        case .birthDate, .deathDate: return .patchLifeYears
        case .birthPlace, .deathPlace, .marriageDate: return .unindexed
        }
    }
}

extension GedcomFamilyGraph.Person {
    /// Set one person fact from an overlay value. True when it changed.
    /// A name is never erased (nil or empty is ignored); a nil sex is "".
    /// A marriage date is a family fact: never set here (false).
    mutating func assignOverlayFact(_ field: PersonRefreshField, _ value: String?) -> Bool {
        switch field {
        case .name:
            guard let value, !value.isEmpty else { return false }
            return Self.assign(value, to: &name)
        case .surname: return Self.assign(value, to: &surname)
        case .sex: return Self.assign(value ?? "", to: &sex)
        case .birthDate: return Self.assign(value, to: &birthDate)
        case .birthPlace: return Self.assign(value, to: &birthPlace)
        case .deathDate: return Self.assign(value, to: &deathDate)
        case .deathPlace: return Self.assign(value, to: &deathPlace)
        case .marriageDate: return false
        }
    }

    private static func assign<Value: Equatable>(_ value: Value, to slot: inout Value) -> Bool {
        guard slot != value else { return false }
        slot = value
        return true
    }
}

extension GedcomFamilyGraph.TreeIndex {
    /// A copy with some life-years labels replaced (ordinal → label).
    /// Every other table is shared (copy-on-write arrays).
    func replacingLifeYears(_ updates: [Int: String]) -> GedcomFamilyGraph.TreeIndex {
        var years = lifeYears
        for (ordinal, label) in updates where years.indices.contains(ordinal) { years[ordinal] = label }
        return GedcomFamilyGraph.TreeIndex(
            ids: ids, nameRank: nameRank,
            parentStart: parentStart, parents: parents, motherOffset: motherOffset,
            childStart: childStart, children: children,
            spouseStart: spouseStart, spouses: spouses,
            tokens: tokens, likeTokens: likeTokens, surnames: surnames,
            givenNames: givenNames, familySearchIDs: familySearchIDs,
            recordStart: recordStart, recordTokenStart: recordTokenStart,
            recordTokenIDs: recordTokenIDs, recordLikeIDs: recordLikeIDs,
            marriedStart: marriedStart, marriedIDs: marriedIDs,
            surnameStart: surnameStart, surnameIDs: surnameIDs,
            sidebarOrder: sidebarOrder, sidebarHaystack: sidebarHaystack, sidebarStart: sidebarStart,
            identityKeys: identityKeys, givenStart: givenStart, givenIDs: givenIDs,
            surnameTokenStart: surnameTokenStart, surnameTokenIDs: surnameTokenIDs, suffixIDs: suffixIDs,
            lifeYears: years)
    }
}

// MARK: - Store

/// The overlay file on disk. Every path comes from the injected
/// `directory`; nothing else is consulted. Writes go through
/// `AtomicFilePublish` (plain rename(2) — never `replaceItemAt`, which
/// deadlocks in Sandbox.kext; docs/ops/incident_2026_09_14_sandbox_rename_wedge.md).
///
/// The directory also holds each refresh's staging folder
/// (`<FSID>-<stamp>/person.ged`). It must stay OUTSIDE every tree
/// discovery path — the app puts it at family-tree/person-refresh/, a
/// sibling of the originals and compiled folders, which the loader lists
/// non-recursively and never here.
public struct PersonFactOverlayStore: Sendable {
    public static let fileName = "overlay.json"

    public let directory: URL
    public var log: @Sendable (String) -> Void

    public init(directory: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.directory = directory
        self.log = log
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Why the overlay on disk cannot be used for a read-modify-write.
    /// "No file yet" is NOT an error (an empty overlay is the truth then);
    /// only a file that exists and cannot be read or decoded is.
    public struct UnreadableOverlay: Error, LocalizedError, Equatable, Sendable {
        public let fileName: String
        public let reason: String
        public var errorDescription: String? { "\(fileName) can't be read (\(reason))" }
    }

    /// The overlay on disk, for SHOWING the tree: empty when there is none.
    /// An unreadable file (bad JSON, or any read error other than "no such
    /// file") is logged one line and treated as empty — the tree then shows
    /// the pull's facts, the safe direction. Never use this before a save:
    /// use `loadForUpdate()` / `update(_:)`, which refuse instead.
    public func load() -> PersonFactOverlay {
        do {
            return try loadForUpdate()
        } catch let unreadable as UnreadableOverlay {
            log("[fs-refresh] overlay \(unreadable.fileName) unreadable (\(unreadable.reason)); applying none")
            return PersonFactOverlay()
        } catch {
            // loadForUpdate throws only UnreadableOverlay; keep the log honest anyway.
            log("[fs-refresh] overlay \(Self.fileName) unreadable (\(error.localizedDescription)); applying none")
            return PersonFactOverlay()
        }
    }

    /// The overlay on disk, for a read-modify-write. Empty when there is no
    /// file; throws `UnreadableOverlay` when a file exists but cannot be read
    /// or decoded — the caller must refuse rather than save a smaller
    /// overlay over it (reflection review F1, 2026-09-21).
    public func loadForUpdate() throws -> PersonFactOverlay {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if Self.isNoSuchFile(error) { return PersonFactOverlay() }
            throw UnreadableOverlay(fileName: Self.fileName, reason: error.localizedDescription)
        }
        do {
            return try PersonFactOverlay.decode(data)
        } catch {
            throw UnreadableOverlay(fileName: Self.fileName, reason: error.localizedDescription)
        }
    }

    /// Publish `overlay`. Refuses (throws `UnreadableOverlay`) when the file
    /// already on disk cannot be read: whatever the caller loaded, it cannot
    /// have included that file's entries, so writing would erase them. The
    /// check is one read + decode of a small JSON file.
    public func save(_ overlay: PersonFactOverlay) throws {
        _ = try loadForUpdate()
        // The caller's bound permit, asked at the write (codex #193 F3).
        try WritePermit.current.withWrite("overlay save") {
            try AtomicFilePublish.write(try overlay.encoded(), to: fileURL, durability: .fullFsync)
        }
    }

    /// Read-modify-write in one call: load (refusing an unreadable file),
    /// let `mutate` change it, and save — unless `mutate` returns nil, which
    /// means "nothing to write" (e.g. no refresh to undo). Blocking file
    /// I/O with a full fsync: call it OFF the main actor.
    public func update<T>(_ mutate: (inout PersonFactOverlay) throws -> T?) throws -> T? {
        var overlay = try loadForUpdate()
        guard let result = try mutate(&overlay) else { return nil }
        try WritePermit.current.withWrite("overlay update") {
            try AtomicFilePublish.write(try overlay.encoded(), to: fileURL, durability: .fullFsync)
        }
        return result
    }

    /// Move an unreadable overlay aside as `overlay.json.bad-<UTC stamp>`
    /// (plain rename(2) in the same folder — never deleted, never
    /// `replaceItemAt`). The next apply then starts a fresh overlay while
    /// the old bytes stay on disk for a human to inspect. Returns the new
    /// URL. Throws when there is nothing to move or the rename fails.
    public func setAsideUnreadable(at date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = Self.fileName + ".bad-" + formatter.string(from: date)
        var target = directory.appendingPathComponent(base)
        var n = 2
        while fileManager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try WritePermit.current.withWrite("overlay set-aside") { try fileManager.moveItem(at: fileURL, to: target) }
        return target
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    /// "mtime|size" of the overlay file (or "none") — part of the shared
    /// graph cache's key, so an apply or undo reaches Hallie's next turn.
    public func stamp() -> String {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return "none" }
        return "\(modified.timeIntervalSince1970)|\(values.fileSize ?? -1)"
    }

    /// The overlay to lay over a tree whose newest full pull is dated
    /// `newestPullAt`. Entries older than that pull are superseded: never
    /// applied, logged one line each, and — when `canWrite` — moved to
    /// `retired` on disk so the file says what happened.
    public func effective(newestPullAt: Date?, canWrite: Bool, now: Date = Date()) -> PersonFactOverlay {
        var overlay = load()
        guard let newestPullAt else { return overlay }
        let stale = overlay.superseded(byPullAt: newestPullAt)
        guard !stale.isEmpty else { return overlay }
        for fsid in stale {
            let entry = overlay.entries[fsid]!
            log("[fs-refresh] retired overlay for \(entry.displayName) (\(fsid)): applied "
                + "\(Self.iso(entry.appliedAt)), superseded by a full pull dated \(Self.iso(newestPullAt)); "
                + "fields were \(entry.facts.keys.sorted().joined(separator: ", "))")
        }
        overlay.retire(stale, at: now, reason: "superseded by a full pull dated \(Self.iso(newestPullAt))")
        if canWrite {
            do { try save(overlay) } catch {
                log("[fs-refresh] could not record the retirement in \(Self.fileName): \(error.localizedDescription) "
                    + "(the superseded entries are still not applied)")
            }
        }
        return overlay
    }

    /// Newest modification date among the regular `.ged` files directly in
    /// `directory` — the tree's discovery folder. Non-recursive on purpose:
    /// it must see exactly what the loader sees. Nil when there are none.
    public static func newestPullDate(in directory: URL, fileManager: FileManager = .default) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        return files.compactMap { url -> Date? in
            guard url.pathExtension.lowercased() == "ged",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return values.contentModificationDate
        }.max()
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
