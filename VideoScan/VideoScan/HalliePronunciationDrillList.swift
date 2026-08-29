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
                // Legacy name anchors resolve like the kinship overlay does:
                // by stable ID, then by canonical spelling / alias.
                let key = PersonResolver.normalize(name)
                if PersonResolver.normalize(profile.stableID) == key { return true }
                return ([profile.canonicalName] + profile.aliases).contains { PersonResolver.normalize($0) == key }
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
        // Everything below works on array INDICES, not ids or copies of
        // `Person` (each carries three arrays): 39k people order in well
        // under the 200 ms budget even in a Debug build. Keys are
        // normalized exactly once per word.
        let taught = Set(lexicon.entries.map { FamilyIdentityText.normalized($0.written) })
        let indexByID: [String: Int] = Dictionary(
            people.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var keys: [[String]] = []
        keys.reserveCapacity(people.count)
        var surnameKeys: [String?] = []
        surnameKeys.reserveCapacity(people.count)
        for person in people {
            let personKeys = person.words.map { FamilyIdentityText.normalized($0) }
            keys.append(personKeys)
            surnameKeys.append(person.surname.map { FamilyIdentityText.normalized($0) } ?? personKeys.last)
        }
        let profileWords = profiles.names.map { FamilyTreePronunciationChips.nameWords($0) }
        let profileKeys = profileWords.map { $0.map { FamilyIdentityText.normalized($0) } }

        // Carrier counts per word over everyone (tree + profiles).
        var carriers: [String: Int] = [:]
        for personKeys in keys { for key in personKeys { carriers[key, default: 0] += 1 } }
        for personKeys in profileKeys { for key in personKeys { carriers[key, default: 0] += 1 } }

        var items: [Item] = []
        var placed: Set<String> = []
        func placeWord(_ word: String, key: String, kind: Kind, source: Source) {
            guard placed.insert(key).inserted else { return }
            if taught.contains(key), store.status(for: key) != .alternativesPending { return }
            items.append(Item(key: key, name: word, kind: kind, source: source, carriers: carriers[key] ?? 1))
        }
        /// Given names first, then the surname — the order a name is said.
        func place(_ words: [String], keys wordKeys: [String], surnameKey: String?, source: Source) {
            var surnameAt: Int?
            for (at, key) in wordKeys.enumerated() {
                if key == surnameKey { if surnameAt == nil { surnameAt = at }; continue }
                placeWord(words[at], key: key, kind: .given, source: source)
            }
            if let surnameAt { placeWord(words[surnameAt], key: wordKeys[surnameAt], kind: .surname, source: source) }
        }
        func place(_ index: Int, source: Source) {
            place(people[index].words, keys: keys[index], surnameKey: surnameKeys[index], source: source)
        }

        // 1. People-tab household.
        for (at, words) in profileWords.enumerated() {
            place(words, keys: profileKeys[at], surnameKey: nil, source: .peopleTab)
        }

        // 2. Roots' near ancestry: breadth-first up to N generations,
        //    spouses beside each person (a spouse's surname is said as often).
        var frontier = rootIDs.compactMap { indexByID[$0] }
        var visited = Set(frontier)
        for _ in 0...nearAncestryGenerations {
            guard !frontier.isEmpty else { break }
            var next: [Int] = []
            for index in frontier {
                place(index, source: .nearAncestry)
                for spouse in people[index].spouseIDs.compactMap({ indexByID[$0] }) {
                    place(spouse, source: .nearAncestry)
                }
                for parent in people[index].parentIDs.compactMap({ indexByID[$0] }) where visited.insert(parent).inserted {
                    next.append(parent)
                }
            }
            frontier = next
        }

        // 3. Everyone else by descendant count (memoized DFS — O(people);
        //    pedigree collapse double-counts a little, which only affects
        //    ORDER). `-1` = not yet counted, `-2` = on the current path
        //    (cycle guard); a plain array beats a hash map here.
        var descendantCount = [Int](repeating: -1, count: people.count)
        func count(_ index: Int) -> Int {
            let known = descendantCount[index]
            if known >= 0 { return known }
            if known == -2 { return 0 }
            descendantCount[index] = -2
            var total = 0
            for child in people[index].childIDs {
                if let childIndex = indexByID[child] { total += 1 + count(childIndex) }
            }
            descendantCount[index] = total
            return total
        }
        for index in people.indices { _ = count(index) }
        // Bucket by count (a counting sort: O(people), no comparator
        // closure); ties keep the input order, which is the graph's own
        // deterministic order.
        var buckets: [Int: [Int]] = [:]
        for index in people.indices { buckets[descendantCount[index], default: []].append(index) }
        for total in buckets.keys.sorted(by: >) {
            for index in buckets[total] ?? [] { place(index, source: .tree) }
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
    /// How a respelling came to be on the record (phoneme-ready for the
    /// variations picker, Rick 2026-08-29): typed by Rick, derived from a
    /// descriptive hint, picked from offered variations, or matched from a
    /// recording of his voice.
    enum Origin: String, Codable, Sendable, Equatable {
        case taught, derived, picked, recorded
    }

    struct Record: Codable, Equatable, Sendable {
        /// The spelling as shown to Rick.
        var name: String
        var status: PronunciationDrillStatus
        /// The respelling the voice uses (first alternative).
        var respelling: String?
        /// Optional phoneme string (misaki / IPA) for an inline override;
        /// nothing writes it yet.
        var phonemes: String?
        /// Every kept alternative, first = spoken.
        var alternatives: [String]
        /// Where the respelling came from; nil when only judged/skipped.
        var source: Origin?
        /// Where the name sits on the sheet (people-tab / near-ancestry / tree).
        var listSource: PronunciationDrillList.Source?
        /// When Rick last attested this record.
        var attestedAt: Date
        /// Rick's raw descriptive hint ("La (as in Lag) and Tah"), kept even
        /// when it could not be mapped so the picker can use it.
        var hint: String?

        init(name: String, status: PronunciationDrillStatus, respelling: String? = nil, phonemes: String? = nil,
             alternatives: [String] = [], source: Origin? = nil, listSource: PronunciationDrillList.Source? = nil,
             attestedAt: Date, hint: String? = nil) {
            self.name = name
            self.status = status
            self.respelling = respelling ?? alternatives.first
            self.phonemes = phonemes
            self.alternatives = alternatives.isEmpty ? (respelling.map { [$0] } ?? []) : alternatives
            self.source = source
            self.listSource = listSource
            self.attestedAt = attestedAt
            self.hint = hint
        }

        private enum CodingKeys: String, CodingKey {
            case name, status, respelling, phonemes, alternatives, source, listSource, attestedAt, hint
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try c.decode(String.self, forKey: .name),
                status: try c.decode(PronunciationDrillStatus.self, forKey: .status),
                respelling: try c.decodeIfPresent(String.self, forKey: .respelling),
                phonemes: try c.decodeIfPresent(String.self, forKey: .phonemes),
                alternatives: try c.decodeIfPresent([String].self, forKey: .alternatives) ?? [],
                source: try c.decodeIfPresent(Origin.self, forKey: .source),
                listSource: try c.decodeIfPresent(PronunciationDrillList.Source.self, forKey: .listSource),
                attestedAt: try c.decode(Date.self, forKey: .attestedAt),
                hint: try c.decodeIfPresent(String.self, forKey: .hint))
        }
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

    /// Record a judgement or a teach for a name on the sheet. Fields not
    /// given keep their previous value (a "right" after a teach keeps the
    /// respelling; a hint keeps the status).
    mutating func set(_ item: PronunciationDrillList.Item, status: PronunciationDrillStatus,
                      alternatives: [String]? = nil, phonemes: String? = nil, origin: Origin? = nil,
                      hint: String? = nil, at date: Date = Date()) {
        set(key: item.key, name: item.name, status: status, alternatives: alternatives, phonemes: phonemes,
            origin: origin, listSource: item.source, hint: hint, at: date)
    }

    /// Set by normalized key for a name that is not on the sheet (a one-off
    /// "pronounce X like Y" for a name the list did not carry).
    mutating func set(name: String, status: PronunciationDrillStatus,
                      alternatives: [String]? = nil, phonemes: String? = nil, origin: Origin? = nil,
                      hint: String? = nil, at date: Date = Date()) {
        set(key: FamilyIdentityText.normalized(name), name: name, status: status,
            alternatives: alternatives, phonemes: phonemes, origin: origin, listSource: nil, hint: hint, at: date)
    }

    private mutating func set(key: String, name: String, status: PronunciationDrillStatus,
                              alternatives: [String]?, phonemes: String?, origin: Origin?,
                              listSource: PronunciationDrillList.Source?, hint: String?, at date: Date) {
        let previous = names[key]
        // New alternatives without phonemes drop the old phonemes: they
        // described the old respelling.
        let keptPhonemes = phonemes ?? (alternatives == nil ? previous?.phonemes : nil)
        names[key] = Record(
            name: name, status: status,
            phonemes: keptPhonemes,
            alternatives: alternatives ?? previous?.alternatives ?? [],
            source: origin ?? previous?.source,
            listSource: listSource ?? previous?.listSource,
            attestedAt: date,
            hint: hint ?? previous?.hint)
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
        /// Where the name sits on the sheet, or the lexicon layer for a
        /// taught name that is off the sheet.
        let source: String
        /// taught | derived | picked | recorded, when a respelling exists.
        let origin: PronunciationDrillStore.Origin?
        let phonemes: String?
        /// Rick's raw descriptive hint, if any.
        let hint: String?
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
                source: item.source.rawValue,
                origin: record?.source, phonemes: record?.phonemes, hint: record?.hint,
                carriers: item.carriers))
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
                origin: record?.source ?? .taught, phonemes: record?.phonemes, hint: record?.hint,
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
