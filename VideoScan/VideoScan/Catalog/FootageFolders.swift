// FootageFolders.swift
// Footage folders — the Catalog shows events and copies the way the Finder
// shows folders (docs/design/footage_folders_2026_10_16.md §3 and §4).
//
// This file is the JOIN, pure and off the main actor: values in, values
// out, no record, no model, no disk.
//
//   index(rows:events:)   ONE O(records) pass: which records are copies of
//                         each other (the stored whole-file SHA-256 + size,
//                         else the duplicate group — never a sampled `v1:`
//                         hash), which were made from which (`derivedFrom`),
//                         which confirmed events (folders) each content
//                         belongs to — one content may be in several
//                         (2026-10-19: "a file in many folders").
//                         The union of copies and lineage is a FAMILY; the
//                         family's recording is its keeper (the archived
//                         file, else the better transfer by
//                         RelatedLadder.betterTransfer's order, else the
//                         longest). A copy or a version outside any event
//                         follows its original into its folder(s). Per folder:
//                         the summary (files · copies · running time ·
//                         archived · date).
//   compose(index:…)      The FLAT display for what the table shows right
//                         now: the visible rows (the filter's survivors, in
//                         the table's order), the sort, the open folders,
//                         the scope. Folders and loose files merge in sort
//                         order; inside a folder the family order wins
//                         (recording · ↳ made from it · = copies · ⊂ clips),
//                         then the sort. A file shown under two folders gets
//                         ONE row per folder: its first row keeps the record
//                         id, every later one an alias id
//                         (`FootageFolderRowID`) — Table identity must be
//                         unique. O(visible + folders present).
//
// Memory: the index keeps one SortKeys per record (~200 B) plus the
// families — ~30 MB at 100k rows; the display is one small row per visible
// record. Nothing is retained per compose.
//
// (For Rick: everything here is a `struct`/`enum` — value semantics, copied
// like a C++ POD — and `Sendable`, so the work runs on a worker thread. The
// union–find below is the classic disjoint-set forest with path halving.)

import Foundation
import VideoScanCore

enum FootageFolders {

    // MARK: - Inputs

    /// The sortable facts of a row or a folder, one per table column that
    /// sorts. A folder fills the ones it has (title, running time, size,
    /// date) and leaves the rest empty.
    struct SortKeys: Sendable, Equatable {
        var filename = ""
        var volume = ""
        var stream = ""
        var duration = 0.0
        var pixels = 0
        var codec = ""
        var dossier = 0
        var size: Int64 = 0
        var date = Date.distantPast
        var place = ""
        var people = ""
    }

    /// The table's sort columns, by name (the KeyPathComparator ↔ key
    /// mapping lives in FootageFolderTableRow.swift, beside the row type).
    enum SortKey: String, CaseIterable, Sendable {
        case filename, volume, stream, duration, resolution, codec, dossier, size, date, place, people
    }

    /// The table's current sort as a value.
    struct Sort: Sendable, Equatable {
        var key: SortKey = .filename
        var ascending = true

        static let byName = Sort()

        /// Does `a` come before `b` under this sort? Ties keep their
        /// incoming order (every caller sorts stably or merges).
        func precedes(_ a: SortKeys, _ b: SortKeys) -> Bool {
            let r = Self.comparators[key]?(a, b) ?? .orderedSame
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }

        /// One comparator per column (data, not a switch): strings compare
        /// the way the table's KeyPathComparator does (localized standard).
        static let comparators: [SortKey: @Sendable (SortKeys, SortKeys) -> ComparisonResult] = [
            .filename: { $0.filename.localizedStandardCompare($1.filename) },
            .volume: { $0.volume.localizedStandardCompare($1.volume) },
            .stream: { $0.stream.localizedStandardCompare($1.stream) },
            .duration: { compare($0.duration, $1.duration) },
            .resolution: { compare($0.pixels, $1.pixels) },
            .codec: { $0.codec.localizedStandardCompare($1.codec) },
            .dossier: { compare($0.dossier, $1.dossier) },
            .size: { compare($0.size, $1.size) },
            .date: { compare($0.date, $1.date) },
            .place: { $0.place.localizedStandardCompare($1.place) },
            .people: { $0.people.localizedStandardCompare($1.people) },
        ]

        private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
    }

    /// One catalog record as the join reads it. Copied on the main actor
    /// (`VideoScanModel.footageFolderRows()`), built by hand in tests.
    struct Row: Sendable, Equatable, Identifiable {
        let id: UUID
        /// The Events identity: the stored full SHA-256, "pair:<id>" for
        /// an A/V half, "id:<record>" when neither (VideoScanModel.eventsContentKey).
        var contentKey: String
        /// The stored WHOLE-FILE digest (never a sampled `v1:` hash).
        var digest: String?
        var sizeBytes: Int64
        var durationSeconds: Double
        var derivedFrom: UUID?
        var derivationKind: String?
        var duplicateGroupID: UUID?
        /// Purged or set aside — in the catalog, not in a folder's summary.
        var isHidden: Bool
        var isSuperseded: Bool
        /// The archive holds this content (this file or an identical one).
        var isArchived: Bool
        /// This file IS the archive's copy.
        var isArchiveFile: Bool
        var codec: CodecGeneration
        var frameHeight: Int?
        var bitRate: Int64?
        var volume: String
        var displayCodec: String
        var keys: SortKeys

        init(id: UUID = UUID(), contentKey: String? = nil, digest: String? = nil, sizeBytes: Int64 = 0,
             durationSeconds: Double = 0, derivedFrom: UUID? = nil, derivationKind: String? = nil,
             duplicateGroupID: UUID? = nil, isHidden: Bool = false, isSuperseded: Bool = false,
             isArchived: Bool = false, isArchiveFile: Bool = false, codec: CodecGeneration = .unknown,
             frameHeight: Int? = nil, bitRate: Int64? = nil, volume: String = "", displayCodec: String = "",
             keys: SortKeys = SortKeys()) {
            self.id = id
            self.digest = digest
            self.sizeBytes = sizeBytes
            self.durationSeconds = durationSeconds
            self.derivedFrom = derivedFrom
            self.derivationKind = derivationKind
            self.duplicateGroupID = duplicateGroupID
            self.isHidden = isHidden
            self.isSuperseded = isSuperseded
            self.isArchived = isArchived
            self.isArchiveFile = isArchiveFile
            self.codec = codec
            self.frameHeight = frameHeight
            self.bitRate = bitRate
            self.volume = volume
            self.displayCodec = displayCodec
            self.keys = keys
            // The Events rule minus the pair case (a test's default).
            self.contentKey = contentKey ?? Self.wholeFileDigest(digest) ?? "id:" + id.uuidString
        }

        /// `digest` when it is a whole-file one; nil for a sampled `v1:` hash.
        static func wholeFileDigest(_ digest: String?) -> String? {
            guard let d = digest, !d.isEmpty, !d.hasPrefix("v1:") else { return nil }
            return d.lowercased()
        }

        /// The copy identity: the whole-file digest + size, else the
        /// duplicate group, else none (§3.2). A `v1:` hash is never one.
        var copyKey: String? {
            if let d = Self.wholeFileDigest(digest), sizeBytes > 0 { return "d:\(d):\(sizeBytes)" }
            if let g = duplicateGroupID { return "g:\(g.uuidString)" }
            return nil
        }

        /// Copies are proven by bytes when the key is a digest.
        var copyIsByteForByte: Bool { copyKey?.hasPrefix("d:") ?? false }

        /// Counted in a folder's summary.
        var isActive: Bool { !isHidden && !isSuperseded }
    }

    /// A confirmed event: its title and the content keys Rick accepted.
    struct Event: Sendable, Equatable, Identifiable {
        let id: UUID
        var title: String
        /// The Events page's date words when a plan has them; nil → the
        /// folder dates itself from its members.
        var dateWords: String?
        var contentKeys: [String]
        /// Event / person / other — the folder's colour (2026-10-19).
        var kind: FolderKind

        init(id: UUID = UUID(), title: String, dateWords: String? = nil, contentKeys: [String], kind: FolderKind = .event) {
            self.id = id
            self.title = title
            self.dateWords = dateWords
            self.contentKeys = contentKeys
            self.kind = kind
        }

        init(_ e: ConfirmedEvent) {
            self.init(id: e.id, title: EventsNaming.folderTitle(e.name), dateWords: e.dateWords,
                      contentKeys: e.members.map(\.range.contentKey))
        }

        /// The live confirmed events straight from Rick's decisions — no
        /// planner needed (§3: a join, not an analyzer).
        static func events(in decisions: EventsDecisionSnapshot) -> [Event] {
            decisions.liveEvents
                // The stored name may carry a legacy date source: shown without it.
                .map { Event(id: $0.id, title: EventsNaming.folderTitle($0.name),
                             contentKeys: decisions.members(of: $0.id).map(\.contentKey).sorted(), kind: $0.kind) }
                .sorted { $0.title != $1.title ? $0.title < $1.title : $0.id.uuidString < $1.id.uuidString }
        }
    }

    // MARK: - Relations

    /// How a member relates to the recording above it — one glyph and the
    /// muted words after the name (§2).
    enum Relation: Sendable, Hashable {
        /// The family's recording (plain row).
        case recording
        /// ↳ made from it · <kind>
        case madeFrom(String)
        /// = copy · byte for byte, <volume>
        case copy(String)
        /// ⊂ clip of it · <words> (phase 2 — the case is kept, nothing makes one yet)
        case clip(String)
        /// ≈ same event · different footage
        case sameEvent

        var glyph: String? {
            switch self {
            case .recording: return nil
            case .madeFrom: return FootageFolderWords.madeFromGlyph
            case .copy: return FootageFolderWords.copyGlyph
            case .clip: return FootageFolderWords.clipGlyph
            case .sameEvent: return FootageFolderWords.sameEventGlyph
            }
        }

        var words: String? {
            switch self {
            case .recording: return nil
            case .madeFrom(let w), .copy(let w), .clip(let w): return w
            case .sameEvent: return FootageFolderWords.sameEventWords
            }
        }

        var isCopy: Bool {
            if case .copy = self { return true }
            return false
        }

        /// Family order: the recording, then made-from, copies, clips.
        var tier: Int {
            switch self {
            case .recording, .sameEvent: return 0
            case .madeFrom: return 1
            case .copy: return 2
            case .clip: return 3
            }
        }
    }

    struct Member: Sendable, Equatable {
        let id: UUID
        let relation: Relation
    }

    /// One recording and its relatives; the keeper is `members[0]`.
    struct Family: Sendable, Equatable {
        let keeper: UUID
        /// Keeper first, then tier order (the sort orders within a tier).
        let members: [Member]
    }

    struct Summary: Sendable, Equatable {
        var files = 0
        var copies = 0
        var totalSeconds = 0.0
        var totalBytes: Int64 = 0
        var archivedCount = 0
        /// The earliest recording's day.
        var date: Date?
        /// The latest recording's day (the Finder level's date range,
        /// 2026-10-17); nil when no recording is dated.
        var latestDate: Date?
        var dateWords = ""
    }

    struct Folder: Sendable, Equatable {
        let id: UUID
        let title: String
        var kind: FolderKind = .event
        var summary = Summary()
        var keys = SortKeys()
        /// Indices into `Index.families`.
        var families: [Int] = []
    }

    // MARK: - The index (one pass per catalog change)

    struct Index: Sendable, Equatable {
        var families: [Family] = []
        /// The record's first family (a record in two folders is in one
        /// family per folder; they hold the same members).
        var familyOf: [UUID: Int] = [:]
        /// Record → every folder it shows under, primary first.
        var foldersOf: [UUID: [UUID]] = [:]
        var folders: [UUID: Folder] = [:]
        var keysOf: [UUID: SortKeys] = [:]

        static let empty = Index()

        func family(of recordID: UUID) -> Family? { familyOf[recordID].map { families[$0] } }
        /// The folders a record shows under (empty: a loose file).
        func folders(of recordID: UUID) -> [UUID] { foldersOf[recordID] ?? [] }
        /// Its primary folder — "Show in its event", a derivative's reveal.
        func firstFolder(of recordID: UUID) -> UUID? { foldersOf[recordID]?.first }
        func folder(containing recordID: UUID) -> Folder? { firstFolder(of: recordID).flatMap { folders[$0] } }
        func isIn(_ recordID: UUID, folder: UUID) -> Bool { foldersOf[recordID]?.contains(folder) ?? false }
    }

    static func index(rows: [Row], events: [Event]) -> Index {
        var index = Index()
        index.keysOf.reserveCapacity(rows.count)
        for r in rows { index.keysOf[r.id] = r.keys }
        let ownEvent = ownEvents(rows: rows, events: events)
        var folderFamilies: [UUID: [Int]] = [:]
        for component in components(rows) {
            for (eventID, members) in split(component, ownEvent: ownEvent) {
                guard eventID != nil || members.count > 1 else { continue }   // a loose single file needs no family
                let fam = family(members)
                index.families.append(fam)
                let fi = index.families.count - 1
                for m in fam.members {
                    if index.familyOf[m.id] == nil { index.familyOf[m.id] = fi }
                    if let e = eventID { index.foldersOf[m.id, default: []].append(e) }
                }
                if let e = eventID { folderFamilies[e, default: []].append(fi) }
            }
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in events {
            guard let fams = folderFamilies[e.id] else { continue }
            index.folders[e.id] = folder(e, families: fams, in: index, byID: byID)
        }
        return index
    }

    /// Record → every confirmed event its content was accepted into, in
    /// the events' order (one content may be in several folders,
    /// 2026-10-19).
    static func ownEvents(rows: [Row], events: [Event]) -> [UUID: [UUID]] {
        var byKey: [String: [UUID]] = [:]
        for e in events { for k in Set(e.contentKeys) { byKey[k, default: []].append(e.id) } }
        guard !byKey.isEmpty else { return [:] }
        var out: [UUID: [UUID]] = [:]
        for r in rows { if let es = byKey[r.contentKey] { out[r.id] = es } }
        return out
    }

    /// Connected components over copies ∪ lineage (union–find), each in
    /// input order.
    static func components(_ rows: [Row]) -> [[Row]] {
        var parent = Array(0..<rows.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        var position: [UUID: Int] = [:]
        position.reserveCapacity(rows.count)
        for (i, r) in rows.enumerated() { position[r.id] = i }
        var firstByCopyKey: [String: Int] = [:]
        for (i, r) in rows.enumerated() {
            if let k = r.copyKey {
                if let j = firstByCopyKey[k] { union(i, j) } else { firstByCopyKey[k] = i }
            }
            if let p = r.derivedFrom, let j = position[p] { union(i, j) }
        }
        var groups: [Int: [Row]] = [:]
        for (i, r) in rows.enumerated() { groups[find(i), default: []].append(r) }
        return groups.keys.sorted().map { groups[$0] ?? [] }
    }

    /// A component becomes one family per folder its members are in. A
    /// member accepted into folders keeps exactly those (a content may be
    /// in several). A member with no folder of its own follows ITS OWN copy
    /// group's folders first — a copy is the same content (codex 2026-10-16
    /// P2); only a member whose copy group has none follows the family's
    /// leading folders (every folder tied for the most votes — so a version
    /// of a recording that is in two folders shows in both, and a 2 : 1
    /// family still sends it to the majority only).
    static func split(_ component: [Row], ownEvent: [UUID: [UUID]]) -> [(UUID?, [Row])] {
        let group = copyGroups(component)
        var familyVotes: [UUID: Int] = [:]
        var groupVotes: [String: [UUID: Int]] = [:]
        for r in component {
            for e in ownEvent[r.id] ?? [] {
                familyVotes[e, default: 0] += 1
                groupVotes[group[r.id] ?? "", default: [:]][e, default: 0] += 1
            }
        }
        guard let primary = winner(familyVotes) else { return [(nil, component)] }
        let leading = leaders(familyVotes)
        var buckets: [UUID: [Row]] = [:]
        for r in component {
            let own = ownEvent[r.id] ?? []
            let es = !own.isEmpty ? own : (groupVotes[group[r.id] ?? ""].map(leaders) ?? leading)
            for e in es { buckets[e, default: []].append(r) }
        }
        let others = buckets.keys.filter { $0 != primary }.sorted { $0.uuidString < $1.uuidString }
        return [(primary, buckets[primary] ?? [])] + others.map { ($0, buckets[$0] ?? []) }
    }

    /// Every event tied for the most votes, by id.
    static func leaders(_ votes: [UUID: Int]) -> [UUID] {
        guard let top = votes.values.max() else { return [] }
        return votes.filter { $0.value == top }.map(\.key).sorted { $0.uuidString < $1.uuidString }
    }

    /// Most votes; a tie goes to the smaller id (stable, never the luck of
    /// input order).
    static func winner(_ votes: [UUID: Int]) -> UUID? {
        votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.uuidString > $1.key.uuidString })?.key
    }

    // MARK: The family — keeper and relations

    /// Keeper = the best ORIGINAL — a member whose lineage, followed inside
    /// the family (stepping over a byte-copy of its own source, e.g. a
    /// promote), never reaches another copy group: the archived file, else
    /// the better transfer, else the longest. A byte-copy of a DERIVATIVE is
    /// not an original (codex 2026-10-16 P2): it inherits the derivative's
    /// place, so every version reads "↳ made from it" in the right direction
    /// and the copy reads "= copy" of that version.
    static func family(_ members: [Row]) -> Family {
        let group = copyGroups(members)
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roots = members.filter { isOriginal($0, group: group, byID: byID) }
        let pool = roots.isEmpty ? members : roots
        // A full tie: the copy the versions were made from leads, then the
        // catalog's order (the first one scanned) — never the luck of a UUID.
        let sources = Set(members.compactMap(\.derivedFrom))
        guard let keeperIndex = pool.indices.min(by: { i, j in
            if preferredKeeper(pool[i], pool[j]) { return true }
            if preferredKeeper(pool[j], pool[i]) { return false }
            let si = sources.contains(pool[i].id), sj = sources.contains(pool[j].id)
            return si != sj ? si : i < j
        }) else { return Family(keeper: UUID(), members: []) }
        let keeper = pool[keeperIndex]
        let keeperGroup = group[keeper.id] ?? ""
        let leaders = versionLeaders(members, keeperGroup: keeperGroup, group: group, byID: byID)
        var rest: [Member] = []
        for r in members where r.id != keeper.id {
            rest.append(Member(id: r.id, relation: relation(r, keeperGroup: keeperGroup, group: group, leaders: leaders, byID: byID)))
        }
        rest.sort { $0.relation.tier != $1.relation.tier ? $0.relation.tier < $1.relation.tier
            : (byID[$0.id]?.keys.filename ?? "") < (byID[$1.id]?.keys.filename ?? "") }
        return Family(keeper: keeper.id, members: [Member(id: keeper.id, relation: .recording)] + rest)
    }

    /// Record → its copy group within the family (a record with no copy
    /// key is a group of one).
    static func copyGroups(_ members: [Row]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for r in members { out[r.id] = r.copyKey ?? "solo:" + r.id.uuidString }
        return out
    }

    /// An ORIGINAL: following `derivedFrom` inside the family (up to 8
    /// hops) never reaches a member of another copy group. A byte-copy of
    /// its own source (a promote) steps over to the source's lineage; a
    /// source outside the family ends the walk as an original.
    static func isOriginal(_ r: Row, group: [UUID: String], byID: [UUID: Row]) -> Bool {
        let own = group[r.id]
        var cursor = r
        for _ in 0..<8 {
            guard let p = cursor.derivedFrom, let parent = byID[p] else { return true }
            if group[p] != own { return false }
            cursor = parent
        }
        return true
    }

    /// Does `r`'s lineage (up to 8 hops) reach the keeper's copy group?
    static func descendsFromGroup(_ r: Row, _ target: String, group: [UUID: String], byID: [UUID: Row]) -> Bool {
        var cursor = r
        for _ in 0..<8 {
            guard let p = cursor.derivedFrom, let parent = byID[p] else { return false }
            if group[p] == target { return true }
            cursor = parent
        }
        return false
    }

    /// Per copy group that descends from the keeper: the member that IS the
    /// version (its source lies outside its own group). Its byte-copies — a
    /// promote of it, a backup of it — read "= copy" of it. A group where
    /// every source lies inside the group keeps its first member.
    static func versionLeaders(_ members: [Row], keeperGroup: String, group: [UUID: String], byID: [UUID: Row]) -> [String: UUID] {
        var leader: [String: UUID] = [:]
        var settled: Set<String> = []
        for r in members where group[r.id] != keeperGroup && descendsFromGroup(r, keeperGroup, group: group, byID: byID) {
            let g = group[r.id] ?? ""
            let isVersion = r.derivedFrom.map { group[$0] != g } ?? false
            guard leader[g] == nil || (isVersion && !settled.contains(g)) else { continue }
            leader[g] = r.id
            if isVersion { settled.insert(g) }
        }
        return leader
    }

    static func relation(_ r: Row, keeperGroup: String, group: [UUID: String], leaders: [String: UUID], byID: [UUID: Row]) -> Relation {
        let g = group[r.id] ?? ""
        if g == keeperGroup {
            return .copy(FootageFolderWords.copy(byteForByte: r.copyIsByteForByte, volume: r.volume))
        }
        guard let leader = leaders[g] else { return .sameEvent }
        if leader == r.id {
            return .madeFrom(FootageFolderWords.madeFrom(kind: r.derivationKind, codec: r.displayCodec))
        }
        return .copy(FootageFolderWords.copyOf(byID[leader]?.keys.filename ?? "", byteForByte: r.copyIsByteForByte, volume: r.volume))
    }

    /// "a" is the better keeper than "b" (strict weak order; a full tie
    /// is false both ways and the caller keeps the catalog's order).
    static func preferredKeeper(_ a: Row, _ b: Row) -> Bool {
        if a.isArchiveFile != b.isArchiveFile { return a.isArchiveFile }
        if a.isArchived != b.isArchived { return a.isArchived }
        switch betterTransfer(a, b) {
        case .a: return true
        case .b: return false
        case .tie: break
        }
        if a.durationSeconds != b.durationSeconds { return a.durationSeconds > b.durationSeconds }
        return a.keys.filename != b.keys.filename && a.keys.filename < b.keys.filename
    }

    enum BetterTransfer { case a, b, tie }

    /// RelatedLadder.betterTransfer's order (VideoScanCore, rung 5), on
    /// the row's facts: longer by more than 5 %, an original-generation
    /// codec over a delivery re-encode, the larger frame, the higher bit
    /// rate. Kept in step with the ladder by FootageFoldersTests.
    static func betterTransfer(_ a: Row, _ b: Row) -> BetterTransfer {
        let la = a.durationSeconds, lb = b.durationSeconds
        if la > lb * 1.05 { return .a }
        if lb > la * 1.05 { return .b }
        if a.codec == .original, b.codec == .delivery { return .a }
        if b.codec == .original, a.codec == .delivery { return .b }
        if let ha = a.frameHeight, let hb = b.frameHeight, ha != hb { return ha > hb ? .a : .b }
        if let ra = a.bitRate, let rb = b.bitRate, ra != rb { return ra > rb ? .a : .b }
        return .tie
    }

    // MARK: The folder and its summary

    static func folder(_ e: Event, families: [Int], in index: Index, byID: [UUID: Row]) -> Folder {
        var f = Folder(id: e.id, title: e.title, kind: e.kind, families: families)
        var s = Summary()
        var earliest: Date?
        var latest: Date?
        for fi in families {
            let fam = index.families[fi]
            if let keeper = byID[fam.keeper], keeper.isActive {
                s.totalSeconds += keeper.durationSeconds
                if keeper.keys.date > .distantPast {
                    earliest = min(earliest ?? keeper.keys.date, keeper.keys.date)
                    latest = max(latest ?? keeper.keys.date, keeper.keys.date)
                }
            }
            for m in fam.members {
                guard let r = byID[m.id], r.isActive else { continue }
                s.files += 1
                s.totalBytes += r.sizeBytes
                if m.relation.isCopy { s.copies += 1 }
                if r.isArchived || r.isArchiveFile { s.archivedCount += 1 }
            }
        }
        s.date = earliest
        s.latestDate = latest
        s.dateWords = e.dateWords ?? earliest.map { dateFormatter.string(from: $0) } ?? ""
        f.summary = s
        f.keys = SortKeys(filename: e.title, duration: s.totalSeconds, size: s.totalBytes, date: earliest ?? .distantPast)
        return f
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    // MARK: - The display (per filter / sort / open set / scope)

    /// What the list is narrowed to: one event, or one file's family.
    enum Scope: Sendable, Hashable {
        case event(UUID)
        case family(UUID)
    }

    enum RowKind: Sendable, Equatable {
        case folder(eventID: UUID, title: String, summary: Summary)
        case loose(recordID: UUID)
        case member(recordID: UUID, depth: Int, relation: Relation)
    }

    struct DisplayRow: Sendable, Equatable, Identifiable {
        /// The event id for a folder row, the record id otherwise.
        let id: UUID
        let kind: RowKind

        var recordID: UUID? {
            switch kind {
            case .folder: return nil
            case .loose(let id), .member(let id, _, _): return id
            }
        }
        var eventID: UUID? {
            if case .folder(let e, _, _) = kind { return e }
            return nil
        }
        var relation: Relation? {
            if case .member(_, _, let r) = kind { return r }
            return nil
        }
        var isFolder: Bool { eventID != nil }

        static func loose(_ id: UUID) -> DisplayRow { DisplayRow(id: id, kind: .loose(recordID: id)) }
        static func member(_ id: UUID, _ relation: Relation) -> DisplayRow {
            DisplayRow(id: id, kind: .member(recordID: id, depth: 1, relation: relation))
        }
        static func folder(_ f: Folder) -> DisplayRow {
            DisplayRow(id: f.id, kind: .folder(eventID: f.id, title: f.title, summary: f.summary))
        }
    }

    struct Display: Sendable, Equatable {
        var rows: [DisplayRow] = []
        var summaries: [UUID: Summary] = [:]
        /// Composed under Show ▸ Folders Only (top level): the table says
        /// "no folders match" when `rows` is empty, rather than going blank.
        var foldersOnly = false
        static let empty = Display()
    }

    /// The display for the table: `visible` are the filter's survivors in
    /// the table's order; `open` the twisted folders; `scope` narrows to
    /// one event or one family (then every folder is open). `foldersOnly`
    /// (Show ▸ Folders Only) drops the loose rows at the top level; a scope
    /// is an explicit narrowing and is shown as it is.
    static func compose(index: Index, visible: [UUID], sort: Sort, open: Set<UUID>, scope: Scope?,
                        foldersOnly: Bool = false) -> Display {
        let visibleSet = Set(visible)
        switch scope {
        case .family(let id)?:
            return familyDisplay(id, index: index, visibleSet: visibleSet, sort: sort)
        case .event(let id)?:
            guard let f = index.folders[id] else { return .empty }
            return Display(rows: [.folder(f)] + members(of: f, index: index, visibleSet: visibleSet, sort: sort),
                           summaries: [f.id: f.summary])
        case nil:
            var d = folderDisplay(index: index, visible: visible, visibleSet: visibleSet, sort: sort, open: open,
                                  foldersOnly: foldersOnly)
            d.rows = uniqueRowIDs(d.rows)
            return d
        }
    }

    /// A file in two open folders appears twice: its first row keeps the
    /// record id, each later row takes `FootageFolderRowID.alias(folder:
    /// record:)` for the folder above it, so every row id is unique (a
    /// Table's identity). The record id rides in the row's kind either way.
    static func uniqueRowIDs(_ rows: [DisplayRow]) -> [DisplayRow] {
        var seen = Set<UUID>()
        var folder: UUID?
        var out: [DisplayRow] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            if let e = row.eventID { folder = e }
            if row.isFolder || seen.insert(row.id).inserted {
                out.append(row)
            } else {
                out.append(DisplayRow(id: FootageFolderRowID.alias(folder: folder ?? row.id, record: row.id), kind: row.kind))
            }
        }
        return out
    }

    /// One call for tests: index + compose with every row visible and
    /// every folder open unless told otherwise.
    static func build(rows: [Row], events: [Event], sort: Sort = .byName, open: Set<UUID>? = nil,
                      scope: Scope? = nil, visible: [UUID]? = nil, foldersOnly: Bool = false) -> Display {
        let idx = index(rows: rows, events: events)
        return compose(index: idx, visible: visible ?? rows.map(\.id), sort: sort,
                       open: open ?? Set(idx.folders.keys), scope: scope, foldersOnly: foldersOnly)
    }

    /// Loose rows (already in the table's order) merged with the folders
    /// present (sorted by the same key) — one pass, no re-sort of the
    /// loose rows. A loose file with copies or versions carries them under
    /// it, where its first visible member sits ("a family is not a folder,
    /// it is the file"); a lone file is one plain row. `foldersOnly`: no
    /// loose rows at all — a folder still shows when any visible member
    /// matches, so search and filters keep working inside folders.
    static func folderDisplay(index: Index, visible: [UUID], visibleSet: Set<UUID>, sort: Sort, open: Set<UUID>,
                              foldersOnly: Bool = false) -> Display {
        var loose: [[DisplayRow]] = []
        var present: [UUID] = []
        var seenFolders = Set<UUID>()
        var seenFamilies = Set<Int>()
        for id in visible {
            if let es = index.foldersOf[id], !es.isEmpty {
                for e in es where seenFolders.insert(e).inserted { present.append(e) }
            } else if foldersOnly {
                continue   // a file in no folder: hidden under Folders Only
            } else if let fi = index.familyOf[id] {
                if seenFamilies.insert(fi).inserted {
                    loose.append(familyRows(index.families[fi], index: index, visibleSet: visibleSet, sort: sort))
                }
            } else {
                loose.append([.loose(id)])
            }
        }
        let folders = present.compactMap { index.folders[$0] }.sorted { sort.precedes($0.keys, $1.keys) }
        var d = Display()
        d.foldersOnly = foldersOnly
        d.rows.reserveCapacity(visible.count + folders.count)
        var fi = 0, li = 0
        while li < loose.count || fi < folders.count {
            let takeFolder = fi < folders.count
                && (li == loose.count || sort.precedes(folders[fi].keys, index.keysOf[loose[li][0].id] ?? SortKeys()))
            if takeFolder {
                let f = folders[fi]
                d.rows.append(.folder(f))
                d.summaries[f.id] = f.summary
                if open.contains(f.id) { d.rows += members(of: f, index: index, visibleSet: visibleSet, sort: sort) }
                fi += 1
            } else {
                d.rows += loose[li]
                li += 1
            }
        }
        return d
    }

    /// A family outside any event: its first visible member as a plain
    /// row (the keeper, unless the filter hid it), the rest under it.
    static func familyRows(_ fam: Family, index: Index, visibleSet: Set<UUID>, sort: Sort) -> [DisplayRow] {
        let shown = ordered(fam, index: index, sort: sort).filter { visibleSet.contains($0.id) }
        guard let first = shown.first else { return [] }
        return [.loose(first.id)] + shown.dropFirst().map { .member($0.id, $0.relation) }
    }

    /// A folder's member rows: families with a visible member, keepers in
    /// sort order; inside a family the tier order, then the sort. The
    /// first family's keeper is THE recording; later keepers read ≈.
    static func members(of folder: Folder, index: Index, visibleSet: Set<UUID>, sort: Sort) -> [DisplayRow] {
        let families = folder.families.map { index.families[$0] }
            .filter { $0.members.contains { visibleSet.contains($0.id) } }
            .sorted { sort.precedes(index.keysOf[$0.keeper] ?? SortKeys(), index.keysOf[$1.keeper] ?? SortKeys()) }
        var out: [DisplayRow] = []
        for (i, fam) in families.enumerated() {
            for m in ordered(fam, index: index, sort: sort) where visibleSet.contains(m.id) {
                let relation: Relation = (m.id == fam.keeper && i > 0) ? .sameEvent : m.relation
                out.append(.member(m.id, relation))
            }
        }
        return out
    }

    /// Tier order, then the sort within a tier (the keeper stays first).
    static func ordered(_ fam: Family, index: Index, sort: Sort) -> [Member] {
        fam.members.sorted { a, b in
            if a.relation.tier != b.relation.tier { return a.relation.tier < b.relation.tier }
            return sort.precedes(index.keysOf[a.id] ?? SortKeys(), index.keysOf[b.id] ?? SortKeys())
        }
    }

    /// "Show Copies & Related…": the file's family alone — the keeper as
    /// a plain row, its relatives under it. A file with no family is just
    /// itself.
    static func familyDisplay(_ id: UUID, index: Index, visibleSet: Set<UUID>, sort: Sort) -> Display {
        guard let fam = index.family(of: id) else {
            return Display(rows: visibleSet.contains(id) ? [.loose(id)] : [])
        }
        return Display(rows: familyRows(fam, index: index, visibleSet: visibleSet, sort: sort))
    }
}

extension FootageFolderWords {
    /// "copy · byte for byte with Xmas.vs.archive.mov, LaCie" — a copy of a
    /// version, named so it is not mistaken for a copy of the recording.
    static func copyOf(_ name: String, byteForByte: Bool, volume: String) -> String {
        let how = byteForByte ? copyByteForByte : copySameGroup
        let place = volume.isEmpty ? "" : ", \(volume)"
        return "\(copyWords)\(separator)\(how) with \(name)\(place)"
    }
}

/// The id of a file's SECOND (third, …) row in the folder view — the same
/// file shown under another folder. Deterministic, so a selection survives a
/// refresh: the folder's id XOR the record's id, byte by byte. (For Rick:
/// the classic hash-combine of two keys; two random 128-bit ids XOR onto an
/// existing id only by astronomical chance.)
enum FootageFolderRowID {
    static func alias(folder: UUID, record: UUID) -> UUID {
        let f = folder.uuid, r = record.uuid
        return UUID(uuid: (f.0 ^ r.0, f.1 ^ r.1, f.2 ^ r.2, f.3 ^ r.3, f.4 ^ r.4, f.5 ^ r.5, f.6 ^ r.6, f.7 ^ r.7,
                           f.8 ^ r.8, f.9 ^ r.9, f.10 ^ r.10, f.11 ^ r.11, f.12 ^ r.12, f.13 ^ r.13, f.14 ^ r.14, f.15 ^ r.15))
    }
}
