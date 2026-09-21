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
        var newPeople = people
        var newFamilies = families
        var lifeYearsChanged: Set<String> = []
        var indexStale = false

        for fsid in overlay.entries.keys.sorted() {
            let entry = overlay.entries[fsid]!
            guard let id = personIDByFamilySearchID[fsid], var person = newPeople[id] else {
                report.missingFamilySearchIDs.append(fsid)
                continue
            }
            var changedHere = 0
            for key in entry.facts.keys.sorted() {
                guard let field = PersonRefreshField(key: key) else { continue }  // unknown key: ignored
                let value = entry.facts[key]!.value
                switch field {
                case .name:
                    // A name is never erased by an overlay.
                    guard let value, !value.isEmpty, value != person.name else { continue }
                    person.name = value; indexStale = true
                case .surname:
                    guard value != person.surname else { continue }
                    person.surname = value; indexStale = true
                case .sex:
                    let sex = value ?? ""
                    guard sex != person.sex else { continue }
                    person.sex = sex; indexStale = true
                case .birthDate:
                    guard value != person.birthDate else { continue }
                    person.birthDate = value; lifeYearsChanged.insert(id)
                case .birthPlace:
                    guard value != person.birthPlace else { continue }
                    person.birthPlace = value
                case .deathDate:
                    guard value != person.deathDate else { continue }
                    person.deathDate = value; lifeYearsChanged.insert(id)
                case .deathPlace:
                    guard value != person.deathPlace else { continue }
                    person.deathPlace = value
                case .marriageDate(let spouseFSID):
                    // The family must already join these two people. A
                    // spouse the tree does not link is a relationship
                    // difference, and those are never applied.
                    guard let familyID = person.spouseOfFamilies.first(where: { familyID in
                        guard let family = newFamilies[familyID] else { return false }
                        let isHusband = family.husband == id, isWife = family.wife == id
                        guard isHusband != isWife,
                              let partner = isHusband ? family.wife : family.husband else { return false }
                        return newPeople[partner]?.familySearchID == spouseFSID
                    }), var family = newFamilies[familyID], family.marriageDate != value else { continue }
                    family.marriageDate = value
                    newFamilies[familyID] = family
                }
                changedHere += 1
            }
            if changedHere > 0 {
                newPeople[id] = person
                report.peopleChanged += 1
                report.fieldsChanged += changedHere
            }
        }
        guard report.fieldsChanged > 0 else { return (self, report) }

        // Keep the compiled index when only dates/places moved: patch the
        // life-years labels for the changed people (O(changed)). A name or
        // sex change touches postings, sidebar order and married-surname
        // tokens — drop the index and let it rebuild lazily.
        var patched: TreeIndex?
        if !indexStale, let index = indexBox.current {
            var updates: [Int: String] = [:]
            for id in lifeYearsChanged {
                guard let ordinal = index.ordinal(of: id), let person = newPeople[id] else { continue }
                updates[Int(ordinal)] = GedcomFamilyGraph.lifeYearsLabel(birth: person.birthDate,
                                                                         death: person.deathDate) ?? ""
            }
            patched = updates.isEmpty ? index : index.replacingLifeYears(updates)
        }
        report.indexDropped = indexStale && indexBox.current != nil
        return (replacingRecords(people: newPeople, families: newFamilies, index: patched), report)
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
/// deadlocks in Sandbox.kext; docs/incident_2026_09_14_sandbox_rename_wedge.md).
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

    /// The overlay on disk; empty when there is none. An unreadable file is
    /// logged and treated as empty (the tree then shows the pull's facts —
    /// the safe direction) and is NOT overwritten until the next apply.
    public func load() -> PersonFactOverlay {
        guard let data = try? Data(contentsOf: fileURL) else { return PersonFactOverlay() }
        do {
            return try PersonFactOverlay.decode(data)
        } catch {
            log("[fs-refresh] overlay \(fileURL.lastPathComponent) unreadable (\(error.localizedDescription)); applying none")
            return PersonFactOverlay()
        }
    }

    public func save(_ overlay: PersonFactOverlay) throws {
        try AtomicFilePublish.write(try overlay.encoded(), to: fileURL, durability: .fullFsync)
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
