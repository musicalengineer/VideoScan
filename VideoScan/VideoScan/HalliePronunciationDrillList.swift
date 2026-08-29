// HalliePronunciationDrillList.swift
// The "sheet" for Hallie's pronunciation drill (Rick, 2026-08-29: "we have
// the most common pronunciations in a sheet and have hallie go through it
// until I judge it correct"). The machine builds the sheet, Rick judges,
// Hallie confirms by saying it back. Nothing derived here is ever spoken
// as if correct — the list only decides the ORDER Rick hears names in.
//
// Three pieces, all pure (no I/O except the explicit store load/save):
//   * `PronunciationDrillList` — distinct given names and surnames from the
//     compiled tree and the People tab, ordered by expected utterance
//     frequency: the People-tab family first (owner, spouse, parents,
//     siblings, children, then the other profiles), then the tree roots'
//     near ancestry (≤ 4 generations up), then everyone else by how many
//     descendants carry the name. Names the voice already has a taught
//     entry for are left out unless their status is `alternatives-pending`.
//   * `PronunciationDrillStore` — the judged status per normalized name,
//     kept in Hallie/pronunciation-drill.json next to pronunciations.json.
//     Explicit `save()`, injected URL, so tests never touch the real one.
//   * `PronunciationDrillManifest` — the machine-readable sheet (name →
//     respelling → status → source) codex's nightly STT audit reads.
//
// Memory: one small struct per distinct name (a few dozen bytes); a 39k-
// person tree produces well under 10k distinct names, so the whole list is
// a few hundred KB at worst. Never built in a view body.

import Foundation
import VideoScanCore

// MARK: - Status

/// Where a name stands in the drill. Raw values are the on-disk strings.
enum PronunciationDrillStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Never put to Rick.
    case untested
    /// Rick heard the voice's own attempt and said "right".
    case judgedOk = "judged-ok"
    /// Rick gave a respelling; it is now in the lexicon.
    case taught
    /// Rick gave two respellings ("either MahGill or MicGill"); the first is
    /// spoken, both are kept, and the name stays on the sheet so the second
    /// can be tried later.
    case alternativesPending = "alternatives-pending"
    /// Rick passed on it.
    case skipped

    /// Names the drill still has to put to Rick.
    var isPending: Bool { self == .untested || self == .alternativesPending }
}

// MARK: - List

struct PronunciationDrillList: Equatable, Sendable {

    enum Kind: String, Codable, Sendable, Equatable {
        case given, surname
    }

    /// Why a name is where it is in the order.
    enum Source: String, Codable, Sendable, Equatable {
        /// A People-tab profile (the owner's household first).
        case peopleTab = "people-tab"
        /// Within four generations above a tree root.
        case nearAncestry = "near-ancestry"
        /// Everyone else, by descendant count.
        case tree
    }

    struct Item: Equatable, Sendable, Identifiable {
        /// Normalized key (FamilyIdentityText.normalized).
        var id: String { key }
        let key: String
        /// The spelling as first met (tree or profile spelling).
        let name: String
        let kind: Kind
        let source: Source
        /// How many people carry the word (tree + profiles).
        let carriers: Int
    }

    /// One person as the list sees them — the seam that keeps this pure and
    /// lets the scale test feed 39k synthetic people without a GEDCOM parse.
    struct Person: Sendable, Equatable {
        let id: String
        /// Name words in speaking order, suffixes and initials already
        /// dropped (FamilyTreePronunciationChips.nameWords).
        let words: [String]
        /// The family-name word, when known; else the last word is taken.
        let surname: String?
        let parentIDs: [String]
        let childIDs: [String]
        let spouseIDs: [String]
    }

    /// The People-tab side, already in household order.
    struct ProfileGroup: Sendable, Equatable {
        let names: [String]
    }

    let items: [Item]

    /// Near-ancestry depth above each root (parents = 1 … great-great-grandparents = 4).
    static let nearAncestryGenerations = 4

    // MARK: Building from live sources

    /// Everything the app has: the compiled tree, the People-tab profiles,
    /// and who "I" is (so the owner's household leads).
    static func build(
        graph: GedcomFamilyGraph?,
        profiles: [HallieTurnExecutor.ProfileSnapshot],
        speakers: HallieTurnExecutor.Speakers,
        lexicon: HalliePronunciationLexicon,
        store: PronunciationDrillStore
    ) -> PronunciationDrillList {
        let people: [Person] = (graph?.people.values ?? [String: GedcomFamilyGraph.Person]().values)
            .map { person in
                Person(
                    id: person.id,
                    words: FamilyTreePronunciationChips.nameWords(person.name),
                    surname: person.surname,
                    parentIDs: graph?.relatives(.parents, of: person).map(\.id) ?? [],
                    childIDs: graph?.relatives(.children, of: person).map(\.id) ?? [],
                    spouseIDs: graph?.relatives(.spouse, of: person).map(\.id) ?? [])
            }
        return build(
            people: people,
            rootIDs: graph?.rootPersonIDs ?? [],
            profiles: householdOrder(profiles, speakers: speakers),
            lexicon: lexicon,
            store: store)
    }

    /// People-tab profiles in expected-utterance order: the owner, then
    /// spouse, parents, siblings, children (from the typed kinships on
    /// either side), then every other profile in People-tab order.
    static func householdOrder(
        _ profiles: [HallieTurnExecutor.ProfileSnapshot],
        speakers: HallieTurnExecutor.Speakers
    ) -> ProfileGroup {
        guard !profiles.isEmpty else { return ProfileGroup(names: []) }
        func matches(_ profile: HallieTurnExecutor.ProfileSnapshot, anchor: KinshipAnchor) -> Bool {
            switch anchor {
            case .profile(let id): return profile.uuid == id
            case .profileName(let name):
                let key = FamilyIdentityText.normalized(name)
                return ([profile.canonicalName] + profile.aliases).contains { FamilyIdentityText.normalized($0) == key }
            case .treePerson, .treePointer: return false
            }
        }
        let owner = profiles.first { profile in
            guard let ownerName = speakers.ownerName else { return false }
            return ([profile.canonicalName] + profile.aliases).contains {
                HallieOwnerResolver.isOwnerSpelling($0, owner: ownerName)
            }
        } ?? profiles[0]

        // relation → the profiles that stand in that relation TO the owner.
        var byRelation: [KinshipRelation: [HallieTurnExecutor.ProfileSnapshot]] = [:]
        for profile in profiles where profile.stableID != owner.stableID {
            // "profile is R of owner"
            for kinship in profile.kinships where matches(owner, anchor: kinship.relativeTo) {
                byRelation[kinship.relation, default: []].append(profile)
            }
            // "owner is R of profile" ⇒ profile is R.inverse of owner
            for kinship in owner.kinships where matches(profile, anchor: kinship.relativeTo) {
                byRelation[kinship.relation.inverse, default: []].append(profile)
            }
        }
        var ordered: [HallieTurnExecutor.ProfileSnapshot] = [owner]
        var seen: Set<String> = [owner.stableID]
        for relation in [KinshipRelation.spouse, .parent, .sibling, .child] {
            for profile in byRelation[relation] ?? [] where seen.insert(profile.stableID).inserted {
                ordered.append(profile)
            }
        }
        for profile in profiles where seen.insert(profile.stableID).inserted {
            ordered.append(profile)
        }
        return ProfileGroup(names: ordered.map(\.canonicalName))
    }

    // MARK: Building from the pure inputs

    static func build(
        people: [Person],
        rootIDs: [String],
        profiles: ProfileGroup,
        lexicon: HalliePronunciationLexicon,
        store: PronunciationDrillStore
    ) -> PronunciationDrillList {
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let taught = Set(lexicon.entries.map { FamilyIdentityText.normalized($0.written) })

        // Carrier counts per word over everyone (tree + profiles).
        var carriers: [String: Int] = [:]
        for person in people { for word in person.words { carriers[FamilyIdentityText.normalized(word), default: 0] += 1 } }
        for name in profiles.names {
            for word in FamilyTreePronunciationChips.nameWords(name) { carriers[FamilyIdentityText.normalized(word), default: 0] += 1 }
        }

        var items: [Item] = []
        var placed: Set<String> = []
        func place(_ words: [String], surname: String?, source: Source) {
            let surnameKey = surname.map { FamilyIdentityText.normalized($0) }
                ?? words.last.map { FamilyIdentityText.normalized($0) }
            // Given names first, then the surname — the order a name is said.
            let ordered = words.filter { FamilyIdentityText.normalized($0) != surnameKey }
                + words.filter { FamilyIdentityText.normalized($0) == surnameKey }
            for word in ordered {
                let key = FamilyIdentityText.normalized(word)
                guard placed.insert(key).inserted else { continue }
                let status = store.status(for: key)
                if taught.contains(key), status != .alternativesPending { continue }
                items.append(Item(
                    key: key, name: word,
                    kind: key == surnameKey ? .surname : .given,
                    source: source, carriers: carriers[key] ?? 1))
            }
        }

        // 1. People-tab household.
        for name in profiles.names {
            place(FamilyTreePronunciationChips.nameWords(name), surname: nil, source: .peopleTab)
        }

        // 2. Roots' near ancestry: breadth-first up to N generations,
        //    spouses beside each person (a spouse's surname is said as often).
        var frontier = rootIDs.compactMap { byID[$0] }
        var visited: Set<String> = Set(frontier.map(\.id))
        for _ in 0...nearAncestryGenerations {
            guard !frontier.isEmpty else { break }
            var next: [Person] = []
            for person in frontier {
                place(person.words, surname: person.surname, source: .nearAncestry)
                for spouse in person.spouseIDs.compactMap({ byID[$0] }) {
                    place(spouse.words, surname: spouse.surname, source: .nearAncestry)
                }
                for parent in person.parentIDs.compactMap({ byID[$0] }) where visited.insert(parent.id).inserted {
                    next.append(parent)
                }
            }
            frontier = next
        }

        // 3. Everyone else by descendant count (memoized DFS — O(people);
        //    pedigree collapse double-counts a little, which only affects
        //    ORDER). `[String: Int]` memo ≈ std::unordered_map.
        var descendantCount: [String: Int] = [:]
        var onPath: Set<String> = []
        func count(_ id: String) -> Int {
            if let known = descendantCount[id] { return known }
            guard let person = byID[id], onPath.insert(id).inserted else { return 0 }
            var total = 0
            for child in person.childIDs { total += 1 + count(child) }
            onPath.remove(id)
            descendantCount[id] = total
            return total
        }
        let rest = people
            .map { ($0, count($0.id)) }
            .sorted { a, b in
                a.1 != b.1 ? a.1 > b.1 : a.0.id < b.0.id
            }
        for (person, _) in rest {
            place(person.words, surname: person.surname, source: .tree)
        }
        return PronunciationDrillList(items: items)
    }

    /// The first item Rick has not yet judged (or one waiting on its
    /// second alternative), at or after `index`.
    func nextPending(from index: Int, store: PronunciationDrillStore) -> Int? {
        guard index < items.count else { return nil }
        return items[index...].firstIndex { store.status(for: $0.key).isPending }
    }
}

// MARK: - Store

/// The judged status per normalized name. Value type + explicit save, like
/// the other Hallie JSON files (Settings Persistence rule: nothing writes
/// on mutation).
struct PronunciationDrillStore: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        /// The spelling as shown to Rick.
        var name: String
        var status: PronunciationDrillStatus
        /// The respelling Rick gave ("MahGill | MicGill" when two).
        var respelling: String?
        var source: PronunciationDrillList.Source?
        var updatedAt: Date
    }

    static let fileName = "pronunciation-drill.json"
    static let manifestFileName = "pronunciation-drill-manifest.json"
    static let currentVersion = 1

    static var defaultFileURL: URL {
        HalliePronunciationLexicon.defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    var version = currentVersion
    /// normalized name → record.
    var names: [String: Record] = [:]

    init() {}

    func status(for key: String) -> PronunciationDrillStatus {
        names[key]?.status ?? .untested
    }

    func record(for key: String) -> Record? { names[key] }

    mutating func set(_ item: PronunciationDrillList.Item, status: PronunciationDrillStatus,
                      respelling: String? = nil, at date: Date = Date()) {
        names[item.key] = Record(
            name: item.name, status: status,
            respelling: respelling ?? names[item.key]?.respelling,
            source: item.source, updatedAt: date)
    }

    /// Set by normalized key for a name that is not on the sheet (a one-off
    /// "pronounce X like Y" for a name the list did not carry).
    mutating func set(name: String, status: PronunciationDrillStatus,
                      respelling: String?, at date: Date = Date()) {
        let key = FamilyIdentityText.normalized(name)
        names[key] = Record(
            name: name, status: status,
            respelling: respelling ?? names[key]?.respelling,
            source: names[key]?.source, updatedAt: date)
    }

    /// Counts for the log line / closing sentence.
    var tally: (judgedOk: Int, taught: Int, skipped: Int) {
        var judged = 0, taught = 0, skipped = 0
        for record in names.values {
            switch record.status {
            case .judgedOk: judged += 1
            case .taught, .alternativesPending: taught += 1
            case .skipped: skipped += 1
            case .untested: break
            }
        }
        return (judged, taught, skipped)
    }

    // MARK: Files

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// A missing file is an empty store; an unreadable one is logged and
    /// treated as empty WITHOUT being overwritten until the next save.
    static func load(from url: URL = defaultFileURL, log: LogSink? = appLog) -> PronunciationDrillStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return PronunciationDrillStore() }
        do {
            return try decoder.decode(PronunciationDrillStore.self, from: Data(contentsOf: url))
        } catch {
            log?.write("[hallie-voice] drill: \(url.lastPathComponent) unreadable (\(error.localizedDescription)); starting an empty sheet")
            return PronunciationDrillStore()
        }
    }

    /// Atomic replace. Also writes the manifest beside it when a list is
    /// given, so the nightly audit always sees the sheet the drill used.
    func save(to url: URL = defaultFileURL, manifest: PronunciationDrillManifest? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
        if let manifest {
            try manifest.jsonData().write(
                to: url.deletingLastPathComponent().appendingPathComponent(Self.manifestFileName),
                options: .atomic)
        }
    }
}

// MARK: - Manifest

/// The sheet as codex's nightly STT audit wants it: every name the drill
/// knows about, with the respelling the voice will use, its status and where
/// it came from. Order = drill order, then taught names not on the sheet.
struct PronunciationDrillManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let key: String
        let kind: PronunciationDrillList.Kind?
        /// What the voice will say (first alternative), nil when it reads
        /// the spelling as is.
        let respelling: String?
        /// Every kept alternative, first = spoken.
        let alternatives: [String]
        let status: PronunciationDrillStatus
        let source: String
        let carriers: Int
    }

    let version: Int
    let generatedAt: Date
    let entries: [Entry]

    static func build(
        list: PronunciationDrillList,
        lexicon: HalliePronunciationLexicon,
        store: PronunciationDrillStore,
        at date: Date = Date()
    ) -> PronunciationDrillManifest {
        let lexiconByKey = Dictionary(
            lexicon.entries.map { (FamilyIdentityText.normalized($0.written), $0) },
            uniquingKeysWith: { first, _ in first })
        var entries: [Entry] = []
        var seen: Set<String> = []
        for item in list.items {
            seen.insert(item.key)
            let record = store.record(for: item.key)
            let spoken = lexiconByKey[item.key].map(\.spoken) ?? record?.respelling
            let alternatives = spoken.map(HalliePronunciationLexicon.alternatives) ?? []
            entries.append(Entry(
                name: item.name, key: item.key, kind: item.kind,
                respelling: alternatives.first, alternatives: alternatives,
                status: store.status(for: item.key),
                source: item.source.rawValue, carriers: item.carriers))
        }
        // Taught names that are off the sheet (already in the lexicon).
        for entry in lexicon.entries {
            let key = FamilyIdentityText.normalized(entry.written)
            guard seen.insert(key).inserted else { continue }
            let alternatives = HalliePronunciationLexicon.alternatives(entry.spoken)
            let record = store.record(for: key)
            entries.append(Entry(
                name: entry.written, key: key, kind: nil,
                respelling: entry.spoken == entry.written ? nil : alternatives.first,
                alternatives: alternatives,
                status: record?.status ?? .taught,
                source: lexicon.source(of: entry).description,
                carriers: record == nil ? 0 : 1))
        }
        return PronunciationDrillManifest(version: PronunciationDrillStore.currentVersion, generatedAt: date, entries: entries)
    }

    func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
