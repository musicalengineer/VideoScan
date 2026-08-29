// GedcomFamilyGraph+Index.swift (VideoScanCore)
// Every derived structure a tree search or kinship walk needs, built ONCE
// per graph and persisted with it (GedcomCompiledTree), so lookups on a
// ~40k-person merged tree are microseconds and launch does no name
// tokenizing at all (Rick 2026-08-28: "the user won't see that; melt
// silicon if we have to; use the very best algorithms, data structures
// and caching").
//
// Layout is flat arrays over integer person ORDINALS (position in the
// id-sorted people list), CSR ("compressed sparse row": one offsets array
// + one flat values array, like a C adjacency list) for every one-to-many
// relation, and SORTED string keys with binary search instead of
// dictionaries — so a decoded artifact is a handful of memcpy-shaped
// arrays and nothing hashes 100k strings at launch.
//
// Semantics: the index only NARROWS candidates. Every public lookup on
// GedcomFamilyGraph re-checks survivors with the exact predicate the
// linear scan used, so results are identical by construction (pinned by
// GedcomIndexEquivalenceTests against a frozen copy of the old scans).

import Foundation

extension GedcomFamilyGraph {

    /// One sorted-key → postings table (CSR). `keys` are sorted ascending
    /// (Swift `String` order); `postings[start[k]..<start[k+1]]` are the
    /// ordinals carrying key k, ascending, so intersections are merges.
    public struct PostingTable: Sendable, Equatable {
        public let keys: [String]
        public let start: [Int32]
        public let postings: [Int32]

        public static let empty = PostingTable(keys: [], start: [0], postings: [])

        public init(keys: [String], start: [Int32], postings: [Int32]) {
            self.keys = keys
            self.start = start
            self.postings = postings
        }

        /// Build from an unordered map (build-time only; never at launch).
        init(_ map: [String: [Int32]]) {
            let keys = map.keys.sorted()
            var start: [Int32] = [0]
            start.reserveCapacity(keys.count + 1)
            var postings: [Int32] = []
            for key in keys {
                var list = map[key]!
                list.sort()
                var last: Int32 = -1
                for ordinal in list where ordinal != last {
                    postings.append(ordinal)
                    last = ordinal
                }
                start.append(Int32(postings.count))
            }
            self.init(keys: keys, start: start, postings: postings)
        }

        /// Position of `key` in `keys`, or nil. Binary search: O(log keys).
        @inlinable
        public func position(of key: String) -> Int? {
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if keys[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            return lo < keys.count && keys[lo] == key ? lo : nil
        }

        /// First position whose key is ≥ `key` (lower bound).
        @inlinable
        public func lowerBound(_ key: String) -> Int {
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if keys[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        @inlinable
        public func postings(at position: Int) -> ArraySlice<Int32> {
            postings[Int(start[position])..<Int(start[position + 1])]
        }

        /// Ordinals carrying exactly `key` (empty when absent).
        public func postings(for key: String) -> ArraySlice<Int32> {
            guard let p = position(of: key) else { return [] }
            return postings(at: p)
        }

        /// Ordinals carrying ANY key that starts with `prefix`, ascending,
        /// deduplicated. Keys sharing a prefix are contiguous in the sorted
        /// key array, so this is one binary search plus a scan of the run.
        public func postings(withPrefix prefix: String) -> [Int32] {
            var p = lowerBound(prefix)
            var out: [Int32] = []
            while p < keys.count, keys[p].hasPrefix(prefix) {
                out = Self.union(out, postings(at: p))
                p += 1
            }
            return out
        }

        /// Sorted-merge intersection of two ascending lists.
        public static func intersect<A: Collection, B: Collection>(_ a: A, _ b: B) -> [Int32]
        where A.Element == Int32, B.Element == Int32 {
            var out: [Int32] = []
            out.reserveCapacity(Swift.min(a.count, b.count))
            var i = a.startIndex, j = b.startIndex
            while i < a.endIndex, j < b.endIndex {
                let x = a[i], y = b[j]
                if x == y { out.append(x); i = a.index(after: i); j = b.index(after: j) }
                else if x < y { i = a.index(after: i) }
                else { j = b.index(after: j) }
            }
            return out
        }

        /// Sorted-merge union of two ascending lists.
        public static func union<A: Collection, B: Collection>(_ a: A, _ b: B) -> [Int32]
        where A.Element == Int32, B.Element == Int32 {
            var out: [Int32] = []
            out.reserveCapacity(a.count + b.count)
            var i = a.startIndex, j = b.startIndex
            while i < a.endIndex || j < b.endIndex {
                if j == b.endIndex || (i < a.endIndex && a[i] < b[j]) {
                    if out.last != a[i] { out.append(a[i]) }
                    i = a.index(after: i)
                } else {
                    if out.last != b[j] { out.append(b[j]) }
                    j = b.index(after: j)
                }
            }
            return out
        }

        /// Intersection across several keys, rarest first; nil when any key
        /// is absent (so the caller can stop early).
        public func intersection(of keys: [String]) -> [Int32]? {
            var lists: [ArraySlice<Int32>] = []
            for key in keys {
                guard let p = position(of: key) else { return nil }
                lists.append(postings(at: p))
            }
            guard !lists.isEmpty else { return nil }
            lists.sort { $0.count < $1.count }
            var out = Array(lists[0])
            for list in lists.dropFirst() {
                out = Self.intersect(out, list)
                if out.isEmpty { break }
            }
            return out
        }
    }

    /// The compiled index: people ordinals, CSR topology, name postings and
    /// the sidebar order + search haystack. Immutable once built; shared by
    /// every copy of the graph through `indexBox`.
    public struct TreeIndex: Sendable, Equatable {
        /// Bump when the derived layout changes so a stored artifact
        /// compiled by an older build is recompiled, not misread.
        /// 2 (2026-08-29): launch tables — per-person identity tokens
        /// (given / surname / suffix, what FamilyAssetIdentityDirectory's
        /// tree pass computes) and the sidebar life-years label — so a
        /// 39k-person launch does no tokenizing and no family-unit walk.
        public static let formatVersion: UInt32 = 2

        // MARK: People
        /// ordinal → GEDCOM pointer, ascending (Swift `String` order).
        public let ids: [String]
        /// ordinal → rank in (name, id) order — the order every name
        /// lookup returns, so results sort by one integer compare.
        public let nameRank: [Int32]

        // MARK: Topology (CSR, ordinals)
        /// Parents in `relatives(.father) + relatives(.mother)` order —
        /// the paternal-first order AncestorIndex's BFS depends on.
        public let parentStart: [Int32]
        public let parents: [Int32]
        /// ordinal → index (into `parents`) of that person's first mother;
        /// `parentStart[o]..<motherOffset[o]` are fathers.
        public let motherOffset: [Int32]
        /// Children in `relatives(.children)` order (FAMS order, then CHIL
        /// order), duplicates removed.
        public let childStart: [Int32]
        public let children: [Int32]
        /// Spouses in `relatives(.spouse)` order, duplicates removed.
        public let spouseStart: [Int32]
        public let spouses: [Int32]

        // MARK: Name postings
        /// Raw `FamilyIdentityText.tokens` over every NAME record
        /// (preferred + alternates) — what `people(matching:)` checks.
        public let tokens: PostingTable
        /// Diminutive-expanded tokens plus each woman's married surnames —
        /// what `people(namedLike:)` checks (the old NameIndex).
        public let likeTokens: PostingTable
        /// `FamilyIdentityText.normalized` GEDCOM surname + alternates.
        public let surnames: PostingTable
        /// First token of each NAME record (given name).
        public let givenNames: PostingTable
        /// FamilySearch ID → every person carrying it (a malformed export
        /// can repeat one; `people(matching:)` returns them all).
        public let familySearchIDs: PostingTable

        // MARK: Per-record token ids (so the exact predicates are integer
        // compares — no name is re-tokenized at query time)
        /// ordinal → NAME records (preferred first): `recordStart[o]..<recordStart[o+1]`.
        public let recordStart: [Int32]
        /// record → its tokens, in name order: `recordTokenStart[r]..<recordTokenStart[r+1]`.
        public let recordTokenStart: [Int32]
        /// Positions into `tokens.keys` (raw token).
        public let recordTokenIDs: [Int32]
        /// Parallel to `recordTokenIDs`: positions into `likeTokens.keys`
        /// (diminutive-expanded token).
        public let recordLikeIDs: [Int32]
        /// ordinal → `marriedSurnames(of:)` as positions into `likeTokens.keys`.
        public let marriedStart: [Int32]
        public let marriedIDs: [Int32]
        /// ordinal → GEDCOM surname + alternates as positions into `surnames.keys`.
        public let surnameStart: [Int32]
        public let surnameIDs: [Int32]

        // MARK: Sidebar
        /// Ordinals in Family Tree sidebar order (surname, name, id).
        public let sidebarOrder: [Int32]
        /// One lowercased record per sidebar row — name, alternate names,
        /// surname(s), pointer, FamilySearch ID — each field terminated by
        /// `\n`, concatenated in `sidebarOrder`; `sidebarStart[row]` is the
        /// byte offset of row `row` (count + 1 entries). A substring
        /// filter is one `memmem` sweep over this blob.
        public let sidebarHaystack: [UInt8]
        public let sidebarStart: [Int32]

        // MARK: Launch tables (formatVersion 2)
        /// Sorted unique `FamilyIdentityText.tokens` over every person's
        /// name, surname and their spouses' surnames — the key space of
        /// the three tables below.
        public let identityKeys: [String]
        /// ordinal → given-name tokens (name tokens minus generational
        /// suffixes minus surname tokens), ascending positions into
        /// `identityKeys`: `givenIDs[givenStart[o]..<givenStart[o+1]]`.
        public let givenStart: [Int32]
        public let givenIDs: [Int32]
        /// ordinal → own surname tokens plus every recorded spouse's
        /// surname tokens (the `familyUnits(of:)` spouses), ascending.
        public let surnameTokenStart: [Int32]
        public let surnameTokenIDs: [Int32]
        /// ordinal → the LAST generational suffix token in the name
        /// ("jr", "sr", "ii"…) as a position into `identityKeys`, or −1.
        public let suffixIDs: [Int32]
        /// ordinal → the sidebar life-dates line (`lifeYearsLabel`), "" when
        /// the record carries no dates.
        public let lifeYears: [String]

        public var count: Int { ids.count }

        @inlinable public func givenIDs(of o: Int32) -> ArraySlice<Int32> {
            givenIDs[Int(givenStart[Int(o)])..<Int(givenStart[Int(o) + 1])]
        }
        @inlinable public func surnameTokenIDs(of o: Int32) -> ArraySlice<Int32> {
            surnameTokenIDs[Int(surnameTokenStart[Int(o)])..<Int(surnameTokenStart[Int(o) + 1])]
        }

        /// Ordinal of a GEDCOM pointer: binary search, O(log people).
        public func ordinal(of id: String) -> Int32? {
            var lo = 0, hi = ids.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if ids[mid] < id { lo = mid + 1 } else { hi = mid }
            }
            return lo < ids.count && ids[lo] == id ? Int32(lo) : nil
        }

        @inlinable public func parents(of o: Int32) -> ArraySlice<Int32> {
            parents[Int(parentStart[Int(o)])..<Int(parentStart[Int(o) + 1])]
        }
        @inlinable public func fathers(of o: Int32) -> ArraySlice<Int32> {
            parents[Int(parentStart[Int(o)])..<Int(motherOffset[Int(o)])]
        }
        @inlinable public func mothers(of o: Int32) -> ArraySlice<Int32> {
            parents[Int(motherOffset[Int(o)])..<Int(parentStart[Int(o) + 1])]
        }
        @inlinable public func records(of o: Int32) -> Range<Int> {
            Int(recordStart[Int(o)])..<Int(recordStart[Int(o) + 1])
        }
        @inlinable public func tokenIDs(ofRecord r: Int) -> ArraySlice<Int32> {
            recordTokenIDs[Int(recordTokenStart[r])..<Int(recordTokenStart[r + 1])]
        }
        @inlinable public func likeIDs(ofRecord r: Int) -> ArraySlice<Int32> {
            recordLikeIDs[Int(recordTokenStart[r])..<Int(recordTokenStart[r + 1])]
        }
        @inlinable public func marriedIDs(of o: Int32) -> ArraySlice<Int32> {
            marriedIDs[Int(marriedStart[Int(o)])..<Int(marriedStart[Int(o) + 1])]
        }
        @inlinable public func surnameIDs(of o: Int32) -> ArraySlice<Int32> {
            surnameIDs[Int(surnameStart[Int(o)])..<Int(surnameStart[Int(o) + 1])]
        }
        @inlinable public func children(of o: Int32) -> ArraySlice<Int32> {
            children[Int(childStart[Int(o)])..<Int(childStart[Int(o) + 1])]
        }
        @inlinable public func spouses(of o: Int32) -> ArraySlice<Int32> {
            spouses[Int(spouseStart[Int(o)])..<Int(spouseStart[Int(o) + 1])]
        }

        // MARK: Build (O(people × name tokens); never on the launch path
        // when a compiled artifact exists)

        public init(graph: GedcomFamilyGraph) {
            let ids = graph.people.keys.sorted()
            var ordinalByID: [String: Int32] = [:]
            ordinalByID.reserveCapacity(ids.count)
            for (i, id) in ids.enumerated() { ordinalByID[id] = Int32(i) }
            self.ids = ids

            var parentStart: [Int32] = [0], parents: [Int32] = [], motherOffset: [Int32] = []
            var childStart: [Int32] = [0], children: [Int32] = []
            var spouseStart: [Int32] = [0], spouses: [Int32] = []
            var tokens: [String: [Int32]] = [:]
            var like: [String: [Int32]] = [:]
            var surnames: [String: [Int32]] = [:]
            var givens: [String: [Int32]] = [:]
            var fsids: [String: [Int32]] = [:]
            // Per-record token strings, resolved to key positions once the
            // sorted key arrays exist.
            var recordStart: [Int32] = [0]
            var recordTokenStart: [Int32] = [0]
            var recordTokens: [String] = []
            var marriedStart: [Int32] = [0]
            var marriedTokens: [String] = []
            var surnameStart: [Int32] = [0]
            var surnameTokens: [String] = []
            parentStart.reserveCapacity(ids.count + 1)
            motherOffset.reserveCapacity(ids.count)
            childStart.reserveCapacity(ids.count + 1)
            spouseStart.reserveCapacity(ids.count + 1)
            recordStart.reserveCapacity(ids.count + 1)

            func appendUnique(_ list: inout [Int32], _ from: Int, _ o: Int32) {
                if !list[from...].contains(o) { list.append(o) }
            }
            for (i, id) in ids.enumerated() {
                let o = Int32(i)
                let person = graph.people[id]!
                // Fathers (unique) then mothers (unique) — NOT deduplicated
                // across the two halves, exactly like relatives(.father) +
                // relatives(.mother); walks handle repeats with their seen set.
                let pFrom = parents.count
                for p in graph.relatives(.father, of: person) {
                    if let po = ordinalByID[p.id] { appendUnique(&parents, pFrom, po) }
                }
                motherOffset.append(Int32(parents.count))
                let mFrom = parents.count
                for p in graph.relatives(.mother, of: person) {
                    if let po = ordinalByID[p.id] { appendUnique(&parents, mFrom, po) }
                }
                parentStart.append(Int32(parents.count))
                let cFrom = children.count
                for c in graph.relatives(.children, of: person) {
                    if let co = ordinalByID[c.id] { appendUnique(&children, cFrom, co) }
                }
                childStart.append(Int32(children.count))
                let sFrom = spouses.count
                for s in graph.relatives(.spouse, of: person) {
                    if let so = ordinalByID[s.id] { appendUnique(&spouses, sFrom, so) }
                }
                spouseStart.append(Int32(spouses.count))

                for name in [person.name] + person.alternateNames {
                    let raw = FamilyIdentityText.tokens(name)
                    for (t, token) in raw.enumerated() {
                        tokens[token, default: []].append(o)
                        like[GedcomFamilyGraph.diminutives[token] ?? token, default: []].append(o)
                        if t == 0 { givens[token, default: []].append(o) }
                        recordTokens.append(token)
                    }
                    recordTokenStart.append(Int32(recordTokens.count))
                }
                recordStart.append(Int32(recordTokenStart.count - 1))
                for token in graph.marriedSurnames(of: person) {
                    like[token, default: []].append(o)
                    marriedTokens.append(token)
                }
                marriedStart.append(Int32(marriedTokens.count))
                for surname in [person.surname].compactMap({ $0 }) + person.alternateSurnames {
                    let key = FamilyIdentityText.normalized(surname)
                    surnames[key, default: []].append(o)
                    surnameTokens.append(key)
                }
                surnameStart.append(Int32(surnameTokens.count))
                if let fsid = person.familySearchID { fsids[fsid, default: []].append(o) }
            }
            self.parentStart = parentStart; self.parents = parents; self.motherOffset = motherOffset
            self.childStart = childStart; self.children = children
            self.spouseStart = spouseStart; self.spouses = spouses
            let tokenTable = PostingTable(tokens)
            let likeTable = PostingTable(like)
            let surnameTable = PostingTable(surnames)
            self.tokens = tokenTable
            self.likeTokens = likeTable
            self.surnames = surnameTable
            self.givenNames = PostingTable(givens)
            self.familySearchIDs = PostingTable(fsids)
            self.recordStart = recordStart
            self.recordTokenStart = recordTokenStart
            self.recordTokenIDs = recordTokens.map { Int32(tokenTable.position(of: $0)!) }
            self.recordLikeIDs = recordTokens.map {
                Int32(likeTable.position(of: GedcomFamilyGraph.diminutives[$0] ?? $0)!)
            }
            self.marriedStart = marriedStart
            self.marriedIDs = marriedTokens.map { Int32(likeTable.position(of: $0)!) }
            self.surnameStart = surnameStart
            self.surnameIDs = surnameTokens.map { Int32(surnameTable.position(of: $0)!) }

            // Name order (name, then id) as a rank per ordinal. Names are
            // pulled once; the comparator touches only arrays.
            let names = ids.map { graph.people[$0]!.name }
            let byName = (0..<ids.count).sorted { a, b in
                names[a] == names[b] ? ids[a] < ids[b] : names[a] < names[b]
            }
            var rank = [Int32](repeating: 0, count: ids.count)
            for (r, o) in byName.enumerated() { rank[o] = Int32(r) }
            self.nameRank = rank

            // Sidebar order: the Family Tree comparator (surname, name, id;
            // no surname last), keys computed ONCE per person instead of
            // per comparison.
            struct SortKey { let surname: String; let name: String; let ordinal: Int32 }
            var keys: [SortKey] = []
            keys.reserveCapacity(ids.count)
            for (i, id) in ids.enumerated() {
                let person = graph.people[id]!
                keys.append(SortKey(surname: person.surname?.lowercased() ?? "\u{FFFF}",
                                    name: person.name.lowercased(), ordinal: Int32(i)))
            }
            keys.sort { lhs, rhs in
                if lhs.surname != rhs.surname { return lhs.surname < rhs.surname }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return ids[Int(lhs.ordinal)] < ids[Int(rhs.ordinal)]
            }
            let order = keys.map(\.ordinal)
            self.sidebarOrder = order

            var haystack: [UInt8] = []
            var starts: [Int32] = [0]
            starts.reserveCapacity(order.count + 1)
            haystack.reserveCapacity(order.count * 64)
            for o in order {
                let person = graph.people[ids[Int(o)]]!
                for field in GedcomFamilyGraph.sidebarSearchFields(of: person) {
                    haystack.append(contentsOf: field.lowercased().utf8)
                    haystack.append(0x0A)
                }
                starts.append(Int32(haystack.count))
            }
            self.sidebarHaystack = haystack
            self.sidebarStart = starts

            // Launch tables (formatVersion 2): the tree pass of the
            // group-photo identity directory, per person, and the sidebar
            // life-years line. Spouses are exactly `familyUnits(of:)`'s —
            // a FAMS whose FAM names this person in one partner role.
            let suffixes = GedcomFamilyGraph.nameSuffixes
            var givenTokens: [[String]] = [], surnameTokens2: [[String]] = [], suffixTokens: [String?] = []
            givenTokens.reserveCapacity(ids.count); surnameTokens2.reserveCapacity(ids.count)
            suffixTokens.reserveCapacity(ids.count)
            var identityKeySet: Set<String> = []
            var lifeYears: [String] = []
            lifeYears.reserveCapacity(ids.count)
            for id in ids {
                let person = graph.people[id]!
                var surnameSet = Set(FamilyIdentityText.tokens(person.surname ?? ""))
                for familyID in person.spouseOfFamilies {
                    guard let family = graph.families[familyID] else { continue }
                    let isHusband = family.husband == person.id, isWife = family.wife == person.id
                    guard isHusband != isWife else { continue }
                    if let spouseID = isHusband ? family.wife : family.husband, let spouse = graph.people[spouseID] {
                        surnameSet.formUnion(FamilyIdentityText.tokens(spouse.surname ?? ""))
                    }
                }
                let nameTokens = FamilyIdentityText.tokens(person.name)
                let suffix = nameTokens.last(where: { suffixes.contains($0) })
                let given = Set(nameTokens.filter { !suffixes.contains($0) && !surnameSet.contains($0) })
                identityKeySet.formUnion(given); identityKeySet.formUnion(surnameSet)
                if let suffix { identityKeySet.insert(suffix) }
                givenTokens.append(given.sorted()); surnameTokens2.append(surnameSet.sorted()); suffixTokens.append(suffix)
                lifeYears.append(GedcomFamilyGraph.lifeYearsLabel(birth: person.birthDate, death: person.deathDate) ?? "")
            }
            let identityKeys = identityKeySet.sorted()
            var keyPosition: [String: Int32] = [:]
            keyPosition.reserveCapacity(identityKeys.count)
            for (i, key) in identityKeys.enumerated() { keyPosition[key] = Int32(i) }
            var givenStart: [Int32] = [0], givenIDs: [Int32] = []
            var surnameTokenStart: [Int32] = [0], surnameTokenIDs: [Int32] = []
            var suffixIDs: [Int32] = []
            givenStart.reserveCapacity(ids.count + 1); surnameTokenStart.reserveCapacity(ids.count + 1)
            suffixIDs.reserveCapacity(ids.count)
            for i in 0..<ids.count {
                // Sorted by string above; positions in a sorted key table
                // are ascending in the same order.
                givenIDs.append(contentsOf: givenTokens[i].map { keyPosition[$0]! })
                givenStart.append(Int32(givenIDs.count))
                surnameTokenIDs.append(contentsOf: surnameTokens2[i].map { keyPosition[$0]! })
                surnameTokenStart.append(Int32(surnameTokenIDs.count))
                suffixIDs.append(suffixTokens[i].map { keyPosition[$0]! } ?? -1)
            }
            self.identityKeys = identityKeys
            self.givenStart = givenStart; self.givenIDs = givenIDs
            self.surnameTokenStart = surnameTokenStart; self.surnameTokenIDs = surnameTokenIDs
            self.suffixIDs = suffixIDs
            self.lifeYears = lifeYears
        }

        /// Memberwise, for the compiled-artifact decoder.
        public init(ids: [String], nameRank: [Int32],
                    parentStart: [Int32], parents: [Int32], motherOffset: [Int32],
                    childStart: [Int32], children: [Int32],
                    spouseStart: [Int32], spouses: [Int32],
                    tokens: PostingTable, likeTokens: PostingTable, surnames: PostingTable,
                    givenNames: PostingTable, familySearchIDs: PostingTable,
                    recordStart: [Int32], recordTokenStart: [Int32],
                    recordTokenIDs: [Int32], recordLikeIDs: [Int32],
                    marriedStart: [Int32], marriedIDs: [Int32],
                    surnameStart: [Int32], surnameIDs: [Int32],
                    sidebarOrder: [Int32], sidebarHaystack: [UInt8], sidebarStart: [Int32],
                    identityKeys: [String], givenStart: [Int32], givenIDs: [Int32],
                    surnameTokenStart: [Int32], surnameTokenIDs: [Int32], suffixIDs: [Int32],
                    lifeYears: [String]) {
            self.ids = ids; self.nameRank = nameRank
            self.parentStart = parentStart; self.parents = parents; self.motherOffset = motherOffset
            self.childStart = childStart; self.children = children
            self.spouseStart = spouseStart; self.spouses = spouses
            self.tokens = tokens; self.likeTokens = likeTokens; self.surnames = surnames
            self.givenNames = givenNames; self.familySearchIDs = familySearchIDs
            self.recordStart = recordStart; self.recordTokenStart = recordTokenStart
            self.recordTokenIDs = recordTokenIDs; self.recordLikeIDs = recordLikeIDs
            self.marriedStart = marriedStart; self.marriedIDs = marriedIDs
            self.surnameStart = surnameStart; self.surnameIDs = surnameIDs
            self.sidebarOrder = sidebarOrder
            self.sidebarHaystack = sidebarHaystack; self.sidebarStart = sidebarStart
            self.identityKeys = identityKeys
            self.givenStart = givenStart; self.givenIDs = givenIDs
            self.surnameTokenStart = surnameTokenStart; self.surnameTokenIDs = surnameTokenIDs
            self.suffixIDs = suffixIDs
            self.lifeYears = lifeYears
        }

        // MARK: Integer predicates (the exact rules of the linear scans)

        /// Some single NAME record of `o` carries every id in `wanted`
        /// (`FamilyIdentityText.tokens` containment, record by record).
        @inlinable public func recordContainsAll(_ o: Int32, tokenIDs wanted: [Int32]) -> Bool {
            for r in records(of: o) {
                let have = tokenIDs(ofRecord: r)
                if wanted.allSatisfy({ have.contains($0) }) { return true }
            }
            return false
        }
        /// Some NAME record's token sequence EQUALS `wanted` (order and
        /// multiplicity included).
        @inlinable public func recordEquals(_ o: Int32, tokenIDs wanted: [Int32]) -> Bool {
            for r in records(of: o) where tokenIDs(ofRecord: r).elementsEqual(wanted) { return true }
            return false
        }
        /// Some NAME record where every asked prefix range (half-open
        /// positions into `tokens.keys`) is hit by one of its tokens.
        @inlinable public func recordHasPrefixes(_ o: Int32, ranges: [Range<Int32>]) -> Bool {
            for r in records(of: o) {
                let have = tokenIDs(ofRecord: r)
                if ranges.allSatisfy({ range in have.contains { range.contains($0) } }) { return true }
            }
            return false
        }
        /// Some NAME record whose diminutive-expanded tokens carry every id
        /// in `wanted` (positions into `likeTokens.keys`) — `personMatches`.
        @inlinable public func recordLikeContainsAll(_ o: Int32, likeIDs wanted: [Int32]) -> Bool {
            for r in records(of: o) {
                let have = likeIDs(ofRecord: r)
                if wanted.allSatisfy({ have.contains($0) }) { return true }
            }
            return false
        }
        /// `matches(_:namedLikeTokens:)`: the strict rule, else the
        /// married-surname rule (some typed id is a spouse surname, the
        /// rest are in one NAME record, and there IS a rest).
        public func namedLikeMatches(_ o: Int32, likeIDs typed: [Int32]) -> Bool {
            if recordLikeContainsAll(o, likeIDs: typed) { return true }
            let married = marriedIDs(of: o)
            guard !married.isEmpty else { return false }
            var bySurname = 0
            var byName: [Int32] = []
            for id in typed {
                if married.contains(id) { bySurname += 1 } else { byName.append(id) }
            }
            guard bySurname > 0, !byName.isEmpty else { return false }
            return recordLikeContainsAll(o, likeIDs: byName)
        }

        // MARK: Sidebar filter

        /// Sidebar ROWS (positions in `sidebarOrder`) whose record contains
        /// `needle` (already lowercased), ascending. One `memmem` sweep;
        /// after a hit the sweep resumes at the next row so each row is
        /// reported once. Empty needle → every row.
        public func sidebarRows(containing needle: String) -> [Int32] {
            let rows = sidebarOrder.count
            guard rows > 0 else { return [] }
            let needleBytes = Array(needle.utf8)
            guard !needleBytes.isEmpty else { return Array(0..<Int32(rows)) }
            guard !needleBytes.contains(0x0A) else { return [] }
            var out: [Int32] = []
            sidebarHaystack.withUnsafeBufferPointer { hay in
                needleBytes.withUnsafeBufferPointer { nd in
                    var from = 0
                    let end = hay.count
                    while from < end {
                        guard let hit = memmem(hay.baseAddress! + from, end - from,
                                               nd.baseAddress!, nd.count) else { break }
                        let offset = UnsafeRawPointer(hit) - UnsafeRawPointer(hay.baseAddress!)
                        // Row = last start ≤ offset (upper_bound − 1).
                        var lo = 0, hi = sidebarStart.count - 1
                        while lo < hi {
                            let mid = (lo + hi + 1) >> 1
                            if Int(sidebarStart[mid]) <= offset { lo = mid } else { hi = mid - 1 }
                        }
                        out.append(Int32(lo))
                        from = Int(sidebarStart[lo + 1])
                    }
                }
            }
            return out
        }
    }

    /// The fields the Family Tree sidebar filter searches, in one place so
    /// the index and any linear fallback agree.
    public static func sidebarSearchFields(of person: Person) -> [String] {
        var fields = [person.name]
        fields.append(contentsOf: person.alternateNames)
        if let surname = person.surname { fields.append(surname) }
        fields.append(contentsOf: person.alternateSurnames)
        fields.append(person.id)
        if let fsid = person.familySearchID { fields.append(fsid) }
        return fields
    }

    /// Lazily-built, shared-by-copy holder for the index. A `final class`
    /// behind a lock so a value-type graph handed across actors builds the
    /// index once, and a decoded artifact can hand it in ready-made.
    public final class TreeIndexBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TreeIndex?
        public init(_ index: TreeIndex? = nil) { stored = index }
        /// Non-nil when already built or injected (no build is triggered).
        public var current: TreeIndex? { lock.withLock { stored } }
        public func install(_ index: TreeIndex) { lock.withLock { stored = index } }
        func value(orBuild build: () -> TreeIndex) -> TreeIndex {
            if let stored = lock.withLock({ stored }) { return stored }
            let built = build()
            lock.withLock { if stored == nil { stored = built } }
            return lock.withLock { stored! }
        }
    }

    /// The index, built on first use (~100 ms for 16k people, ~300 ms for
    /// 100k in Release) and reused by every copy of this graph. A graph
    /// decoded from a compiled artifact arrives with it already installed.
    public var index: TreeIndex { indexBox.value(orBuild: { TreeIndex(graph: self) }) }

    /// True when the index is already available (no build on read).
    public var hasBuiltIndex: Bool { indexBox.current != nil }

    // MARK: Indexed lookups (the graph's public API delegates here)

    /// Ordinals → people, in the given order.
    func people(atOrdinals ordinals: [Int32], index: TreeIndex) -> [Person] {
        ordinals.compactMap { people[index.ids[Int($0)]] }
    }

    static func byNameThenID(_ a: Person, _ b: Person) -> Bool {
        a.name == b.name ? a.id < b.id : a.name < b.name
    }

    /// Ordinals → people in (name, id) order.
    func peopleInNameOrder(_ ordinals: [Int32], index: TreeIndex) -> [Person] {
        people(atOrdinals: ordinals.sorted { index.nameRank[Int($0)] < index.nameRank[Int($1)] }, index: index)
    }

    /// `people(matching:)`: postings narrow, integer predicates confirm.
    func indexedPeople(matching typed: String) -> [Person] {
        let index = self.index
        let familySearchKey = typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if Self.isFamilySearchID(familySearchKey) {
            // Postings are ascending ordinals = ascending ids.
            return people(atOrdinals: Array(index.familySearchIDs.postings(for: familySearchKey)), index: index)
        }
        let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed))
        guard !tokens.isEmpty else { return [] }
        let table = index.tokens
        // 1. Token-exact: every typed token in one NAME record; a record
        //    equal to the whole typed name is more specific.
        if let ids = Self.positions(of: tokens, in: table) {
            let candidates = (table.intersection(of: tokens) ?? []).filter { index.recordContainsAll($0, tokenIDs: ids) }
            if !candidates.isEmpty {
                let exact = candidates.filter { index.recordEquals($0, tokenIDs: ids) }
                return peopleInNameOrder(exact.isEmpty ? candidates : exact, index: index)
            }
        }
        // 2. Diminutives (fred → frederick), unique person only.
        let expanded = tokens.map { Self.diminutives[$0] ?? $0 }
        if expanded != tokens, let ids = Self.positions(of: expanded, in: table) {
            let byNickname = (table.intersection(of: expanded) ?? []).filter { index.recordContainsAll($0, tokenIDs: ids) }
            if byNickname.count == 1 { return people(atOrdinals: byNickname, index: index) }
            if byNickname.count > 1 { return [] }
        }
        // 3. Unique ≥3-letter prefix per token.
        guard tokens.allSatisfy({ $0.count >= 3 }) else { return [] }
        var ranges: [Range<Int32>] = []
        var candidates: [Int32]?
        for asked in tokens {
            let lo = table.lowerBound(asked)
            var hi = lo
            while hi < table.keys.count, table.keys[hi].hasPrefix(asked) { hi += 1 }
            ranges.append(Int32(lo)..<Int32(hi))
            var list: [Int32] = []
            for p in lo..<hi { list = PostingTable.union(list, table.postings(at: p)) }
            candidates = candidates.map { PostingTable.intersect($0, list) } ?? list
            if candidates!.isEmpty { return [] }
        }
        let byPrefix = (candidates ?? []).filter { index.recordHasPrefixes($0, ranges: ranges) }
        return byPrefix.count == 1 ? people(atOrdinals: byPrefix, index: index) : []
    }

    /// Key positions for every token, or nil when any token is unknown.
    static func positions(of tokens: [String], in table: PostingTable) -> [Int32]? {
        var out: [Int32] = []
        out.reserveCapacity(tokens.count)
        for token in tokens {
            guard let p = table.position(of: token) else { return nil }
            out.append(Int32(p))
        }
        return out
    }

    /// `people(withSurname:)`: the predicate accepts a surname equal to
    /// the key, or key minus a trailing "s" / "es".
    func indexedPeople(withSurnameKey key: String) -> [Person] {
        let index = self.index
        var keyIDs: [Int32] = []
        var candidates: [Int32] = []
        var variants = [key]
        if key.hasSuffix("s") { variants.append(String(key.dropLast())) }
        if key.hasSuffix("es") { variants.append(String(key.dropLast(2))) }
        for variant in variants {
            guard let p = index.surnames.position(of: variant) else { continue }
            keyIDs.append(Int32(p))
            candidates = PostingTable.union(candidates, index.surnames.postings(at: p))
        }
        let hits = candidates.filter { o in index.surnameIDs(of: o).contains { keyIDs.contains($0) } }
        return peopleInNameOrder(hits, index: index)
    }

    /// `people(namedLike:)` through the expanded-token postings.
    func indexedPeople(namedLikeTokens tokens: [String]) -> [Person] {
        let index = self.index
        guard let ids = Self.positions(of: tokens, in: index.likeTokens),
              let candidates = index.likeTokens.intersection(of: tokens) else { return [] }
        return peopleInNameOrder(candidates.filter { index.namedLikeMatches($0, likeIDs: ids) }, index: index)
    }

    /// Everyone whose GIVEN name (first token of any NAME record) is the
    /// typed one, name order. New surface (2026-08-28), O(log tokens).
    public func people(withGivenName typed: String) -> [Person] {
        let index = self.index
        guard let key = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed)).first else { return [] }
        return peopleInNameOrder(Array(index.givenNames.postings(for: key)), index: index)
    }
}
