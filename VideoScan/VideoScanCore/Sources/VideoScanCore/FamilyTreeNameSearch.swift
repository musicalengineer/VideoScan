// FamilyTreeNameSearch.swift (VideoScanCore)
// The Family Tree TAB's name search (2026-09-26, Rick: "a kinda page-rank
// search for family trees"). Replaces the verbatim substring filter the
// sidebar used: "Mary O'Connor" found nothing because the record reads
// "Mary Christina O'Connor", and nobody types "Gruffudd ap Einion"
// letter-perfect.
//
// Three stages, each cheap enough for a keystroke on 100k people:
//   1. Token AND-match, any order, prefix per token. Every typed token
//      must be an exact or prefix match of SOME token of the person's
//      name / alternate names / surname(s) / pointer / FamilySearch ID
//      (the same fields `TreeIndex.sidebarHaystack` carries), or of a
//      People-tab alias supplied through `Overlay`.
//   2. Fuzzy fallback when stage 1 finds fewer than `fuzzyThreshold`
//      rows: bounded Damerau-Levenshtein (adjacent transpositions count
//      one) per token — ≤ 1 edit for tokens of 3–5 letters, ≤ 2 for
//      longer, none for 1–2 letters or for anything with a digit —
//      measured against the closest PREFIX of an indexed NAME token, so
//      "grufud" reaches "gruffudd". Pointers and FamilySearch IDs are
//      never fuzzy candidates: "I14" must not drift to I13/I15, and a
//      100k tree has 100k pointer keys that all start with "i".
//   3. Ranking: exact > prefix > fuzzy per token (the primary key), then
//      three SMALL tie-breakers whose combined spread stays under the
//      smallest tier gap so they only ever order rows that matched
//      equally well: covering the whole name, a People-tab profile, and
//      a birth year in the last ~200 years (a slope, not a cliff;
//      unknown = neutral).
//
// This is the tab's search ONLY. Hallie's resolver (`people(matching:)`)
// is untouched; its semantics are pinned by GedcomIndexEquivalenceTests.
//
// Memory (worst case, 100k people): ~25k unique tokens ≈ 0.5 MB of key
// bytes, plus five Int32 CSR tables of ~600k entries ≈ 2.5 MB. Built once
// per install with the launch bundle (tokenization in parallel chunks),
// never per keystroke. Per query: one `[UInt8]` of `keys.count` per typed
// token and one `[Bool]` of `rowCount` — freed on return.
//
// C++ analogy: a struct of const arrays (CSR adjacency + a sorted string
// table); `search` is a const member that allocates only scratch.

import Foundation

public struct FamilyTreeNameSearch: Sendable, Equatable {

    // MARK: Tunables

    /// Stage 2 runs when stage 1 returns fewer rows than this.
    public static let fuzzyThreshold = 5
    /// Longest list stage 2 may return (stage 1 is never capped — "breen"
    /// should list every Breen).
    public static let fuzzyCap = 50

    /// Score weights. The tie-breakers' total spread (−0.60…+0.55 = 1.15)
    /// is deliberately under the smallest gap between tiers (1.5), so a
    /// fuzzy row can never outrank a prefix row and a prefix row never an
    /// exact one, whatever the tie-breakers say.
    ///
    /// Among the tie-breakers: covering the WHOLE name (no unmatched
    /// token) outweighs the recency slope, so typing someone's full name
    /// puts that person above a longer-named, younger namesake; the
    /// People-tab profile outweighs one unmatched token, so "Mary
    /// O'Connor" still leads with the profile's Mary Christina O'Connor.
    public enum Weight {
        public static let exact = 4.0
        public static let prefix = 2.5
        public static let fuzzy = 1.0
        /// (a) has a People-tab profile.
        public static let profile = 0.4
        /// (b) born within `recencyWindow` years: linear from −recency/2
        /// at the window's far edge to +recency/2 today; unknown = 0.
        public static let recency = 0.3
        public static let recencyWindow = 200
        /// (c) name tokens the query did not cover: the first costs
        /// `unmatchedFirst`, each further one `unmatchedToken`, capped.
        public static let unmatchedFirst = 0.35
        public static let unmatchedToken = 0.05
        public static let unmatchedCap = 0.45
    }

    // MARK: Tables

    /// Sorted unique normalized tokens (`indexTokens` over every field).
    public let keys: [String]
    /// `keys` as UTF-8, flat: `keyBytes[keyStart[k]..<keyStart[k+1]]`.
    public let keyBytes: [UInt8]
    public let keyStart: [Int32]
    /// key → may be a fuzzy candidate: letters only, and carried by at
    /// least one NAME field (not only a pointer / FamilySearch ID).
    public let fuzzable: [Bool]
    /// row → key ids: `rowTokenIDs[rowTokenStart[r]..<rowTokenStart[r+1]]`.
    /// Rows are positions in `TreeIndex.sidebarOrder`.
    public let rowTokenStart: [Int32]
    public let rowTokenIDs: [Int32]
    /// key → rows (ascending): `postingRows[postingStart[k]..<postingStart[k+1]]`.
    public let postingStart: [Int32]
    public let postingRows: [Int32]
    /// row → birth year, or −1 when the record carries none.
    public let birthYear: [Int32]
    /// row → number of tokens in the PREFERRED name (the unmatched penalty).
    public let nameTokenCount: [Int16]
    /// ordinal → row, the inverse of `sidebarOrder` (People-tab bridge).
    public let rowByOrdinal: [Int32]
    /// Fuzzy candidate buckets over `fuzzable` keys: keys whose first /
    /// second byte is `b`, as CSR over 256 buckets (`…Start` has 257).
    public let firstByteStart: [Int32]
    public let firstByteKeys: [Int32]
    public let secondByteStart: [Int32]
    public let secondByteKeys: [Int32]

    public var rowCount: Int { rowTokenStart.count - 1 }

    // MARK: Build

    /// One row's raw tokens, produced in parallel; ids are assigned in a
    /// single sequential pass afterwards.
    private struct RowTokens {
        var name: [String] = []     // from NAME / surname fields
        var id: [String] = []       // from the pointer / FamilySearch ID
        var year: Int32 = -1
        var nameCount: Int16 = 0
    }

    /// O(people) tokenization over the compiled index's sidebar order.
    /// Pure; safe on any thread (the launch bundle builds it in parallel
    /// with the sidebar rows).
    public init(graph: GedcomFamilyGraph) {
        let index = graph.index
        let rows = index.sidebarOrder.count

        // Pass 1 (parallel chunks): tokens per row. Same fields as
        // `GedcomFamilyGraph.sidebarSearchFields(of:)`, split by origin so
        // the fuzzy stage can keep to names.
        var perRow = [RowTokens](repeating: RowTokens(), count: rows)
        let chunk = 4096
        let chunks = (rows + chunk - 1) / chunk
        perRow.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunk, hi = min(rows, lo + chunk)
                for row in lo..<hi {
                    let person = graph.people[index.ids[Int(index.sidebarOrder[row])]]!
                    var tokens = RowTokens()
                    var nameFields = [person.name]
                    nameFields.append(contentsOf: person.alternateNames)
                    if let surname = person.surname { nameFields.append(surname) }
                    nameFields.append(contentsOf: person.alternateSurnames)
                    for field in nameFields {
                        for token in Self.indexTokens(field) where !tokens.name.contains(token) {
                            tokens.name.append(token)
                        }
                    }
                    var idFields = [person.id]
                    if let fsid = person.familySearchID { idFields.append(fsid) }
                    for field in idFields {
                        for token in Self.indexTokens(field) where !tokens.id.contains(token) && !tokens.name.contains(token) {
                            tokens.id.append(token)
                        }
                    }
                    if let year = GedcomFamilyGraph.year(in: person.birthDate) { tokens.year = Int32(year) }
                    tokens.nameCount = Int16(clamping: Self.queryTokens(person.name).count)
                    out[row] = tokens
                }
            }
        }

        // Pass 2 (sequential): provisional key ids in first-seen order.
        var keyID: [String: Int32] = [:]
        var firstSeen: [String] = []
        var fromName: [Bool] = []
        var rowStart: [Int32] = [0]
        rowStart.reserveCapacity(rows + 1)
        var rowIDs: [Int32] = []
        rowIDs.reserveCapacity(rows * 6)
        var years = [Int32](repeating: -1, count: rows)
        var nameCounts = [Int16](repeating: 0, count: rows)
        var byOrdinal = [Int32](repeating: 0, count: index.count)
        func assign(_ token: String, name: Bool) -> Int32 {
            if let known = keyID[token] {
                if name { fromName[Int(known)] = true }
                return known
            }
            let id = Int32(firstSeen.count)
            keyID[token] = id
            firstSeen.append(token)
            fromName.append(name)
            return id
        }
        for row in 0..<rows {
            byOrdinal[Int(index.sidebarOrder[row])] = Int32(row)
            let tokens = perRow[row]
            for token in tokens.name { rowIDs.append(assign(token, name: true)) }
            for token in tokens.id { rowIDs.append(assign(token, name: false)) }
            rowStart.append(Int32(rowIDs.count))
            years[row] = tokens.year
            nameCounts[row] = tokens.nameCount
        }

        // Sorted key table + remap.
        let order = firstSeen.indices.sorted { firstSeen[$0] < firstSeen[$1] }
        var remap = [Int32](repeating: 0, count: firstSeen.count)
        for (sorted, original) in order.enumerated() { remap[original] = Int32(sorted) }
        let sortedKeys = order.map { firstSeen[$0] }
        for i in rowIDs.indices { rowIDs[i] = remap[Int(rowIDs[i])] }

        var bytes: [UInt8] = []
        var starts: [Int32] = [0]
        starts.reserveCapacity(sortedKeys.count + 1)
        var fuzzable = [Bool](repeating: false, count: sortedKeys.count)
        for (k, original) in order.enumerated() {
            let key = sortedKeys[k]
            bytes.append(contentsOf: key.utf8)
            starts.append(Int32(bytes.count))
            fuzzable[k] = fromName[original] && key.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A }
        }

        // Postings by counting sort (rows ascend because rows are visited
        // in order).
        var counts = [Int32](repeating: 0, count: sortedKeys.count + 1)
        for id in rowIDs { counts[Int(id) + 1] += 1 }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        var fill = counts
        var postings = [Int32](repeating: 0, count: rowIDs.count)
        for row in 0..<rows {
            for i in Int(rowStart[row])..<Int(rowStart[row + 1]) {
                let k = Int(rowIDs[i])
                postings[Int(fill[k])] = Int32(row)
                fill[k] += 1
            }
        }

        // Byte buckets for the fuzzy stage — fuzzable keys only.
        func buckets(_ byteAt: (Int) -> UInt8?) -> (start: [Int32], keys: [Int32]) {
            var c = [Int32](repeating: 0, count: 257)
            for k in 0..<sortedKeys.count where fuzzable[k] { if let b = byteAt(k) { c[Int(b) + 1] += 1 } }
            for b in 1..<c.count { c[b] += c[b - 1] }
            var f = c
            var out = [Int32](repeating: 0, count: Int(c[256]))
            for k in 0..<sortedKeys.count where fuzzable[k] {
                if let b = byteAt(k) { out[Int(f[Int(b)])] = Int32(k); f[Int(b)] += 1 }
            }
            return (c, out)
        }
        let first = buckets { k in
            let lo = Int(starts[k]), hi = Int(starts[k + 1])
            return hi > lo ? bytes[lo] : nil
        }
        let second = buckets { k in
            let lo = Int(starts[k]), hi = Int(starts[k + 1])
            return hi > lo + 1 ? bytes[lo + 1] : nil
        }

        self.keys = sortedKeys
        self.keyBytes = bytes
        self.keyStart = starts
        self.fuzzable = fuzzable
        self.rowTokenStart = rowStart
        self.rowTokenIDs = rowIDs
        self.postingStart = counts
        self.postingRows = postings
        self.birthYear = years
        self.nameTokenCount = nameCounts
        self.rowByOrdinal = byOrdinal
        self.firstByteStart = first.start
        self.firstByteKeys = first.keys
        self.secondByteStart = second.start
        self.secondByteKeys = second.keys
    }

    // MARK: Normalization

    /// What a typed query becomes: lowercased, diacritics folded,
    /// apostrophes and hyphens JOIN ("O'Connor" → "oconnor",
    /// "GVQV-NW3" → "gvqvnw3"), everything else separates, and a bare
    /// "Mc"/"Mac" word fuses with the next ("Mc Gill" → "mcgill" — never
    /// "Mc Gill", per Rick).
    public static func queryTokens(_ text: String) -> [String] {
        tokenize(text, includeParts: false)
    }

    /// What a record's field becomes: `queryTokens` PLUS the pieces of any
    /// joined word ("oconnor" also indexes "o" and "connor"; "mcgill" —
    /// whether written "Mc Gill" or solid — also indexes "gill"), so a
    /// search for the piece still lands. Query side never emits pieces,
    /// so "o'connor" == "oconnor".
    public static func indexTokens(_ text: String) -> [String] {
        tokenize(text, includeParts: true)
    }

    /// "mcgill" → "gill", "macdonald" → "donald"; nil when the remainder
    /// is too short to be a name ("macy", "mcx").
    private static func particleRemainder(_ token: String) -> String? {
        for particle in ["mac", "mc"] where token.hasPrefix(particle) {
            let rest = String(token.dropFirst(particle.count))
            return rest.count >= 3 ? rest : nil
        }
        return nil
    }

    private static func isJoiner(_ c: Character) -> Bool {
        switch c {
        case "'", "\u{2019}", "\u{2018}", "`", "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}":
            return true
        default:
            return false
        }
    }

    private static func tokenize(_ text: String, includeParts: Bool) -> [String] {
        let normalized = FamilyIdentityText.normalized(text)
        // words[i] = the pieces of word i (split at joiners).
        var words: [[String]] = []
        var pieces: [String] = []
        var piece = ""
        func closePiece() {
            if !piece.isEmpty { pieces.append(piece); piece = "" }
        }
        func closeWord() {
            closePiece()
            if !pieces.isEmpty { words.append(pieces); pieces = [] }
        }
        for c in normalized {
            if c.isLetter || c.isNumber {
                piece.append(c)
            } else if isJoiner(c) {
                closePiece()
            } else {
                closeWord()
            }
        }
        closeWord()

        var out: [String] = []
        var i = 0
        while i < words.count {
            var parts = words[i]
            var joined = parts.joined()
            // "Mc Gill" / "Mac Donald": fuse the particle into the next word.
            if (joined == "mc" || joined == "mac"), i + 1 < words.count {
                let next = words[i + 1]
                let nextJoined = next.joined()
                joined += nextJoined
                parts = [nextJoined] + next.filter { $0 != nextJoined }
                i += 1
            } else if parts.count == 1 {
                parts = []
            }
            if !out.contains(joined) { out.append(joined) }
            if includeParts {
                for part in parts where part != joined && !out.contains(part) { out.append(part) }
                if let rest = particleRemainder(joined), !out.contains(rest) { out.append(rest) }
            }
            i += 1
        }
        return out
    }

    /// Edits allowed for a token of `length` bytes in the fuzzy stage.
    public static func maxDistance(forLength length: Int) -> Int {
        switch length {
        case ..<3: return 0
        case 3...5: return 1
        default: return 2
        }
    }

    /// Edits allowed for a typed token: by length, and none at all when
    /// it carries a digit (a pointer or FamilySearch ID is typed exactly).
    public static func maxDistance(for token: String) -> Int {
        guard token.utf8.allSatisfy({ $0 < 0x30 || $0 > 0x39 }) else { return 0 }
        return maxDistance(forLength: token.utf8.count)
    }

    // MARK: Query

    /// People-tab knowledge the index cannot carry (profiles change
    /// without a recompile): rows that have a profile, and per row the
    /// profile's `queryTokens`-normalized name + aliases.
    public struct Overlay: Sendable, Equatable {
        public var profileRows: Set<Int32> = []
        public var aliasTokens: [Int32: [String]] = [:]
        public init(profileRows: Set<Int32> = [], aliasTokens: [Int32: [String]] = [:]) {
            self.profileRows = profileRows
            self.aliasTokens = aliasTokens
        }
    }

    public struct Hit: Sendable, Equatable {
        public let row: Int32
        public let score: Double
    }

    public struct Result: Sendable, Equatable {
        /// Ranked: score descending, then sidebar order.
        public let hits: [Hit]
        /// How many rows stage 1 (exact/prefix) found. `hits.count >
        /// exactCount` means the fuzzy stage contributed the rest.
        public let exactCount: Int
        public var includesCloseMatches: Bool { hits.count > exactCount }
        public var isApproximate: Bool { exactCount == 0 && !hits.isEmpty }
        public static let empty = Result(hits: [], exactCount: 0)
    }

    public static var thisYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    /// Per typed token: tier per key (0 none / 1 fuzzy / 2 prefix / 3
    /// exact), the matched key ids, and their total posting length (to
    /// pick the cheapest driver).
    private struct TokenMatch {
        var tier: [UInt8]
        var matchedKeys: [Int32] = []
        var postingTotal = 0
    }

    public func search(_ query: String, overlay: Overlay = Overlay(),
                       currentYear: Int = FamilyTreeNameSearch.thisYear) -> Result {
        let q = Self.queryTokens(query)
        guard !q.isEmpty, rowCount > 0 else { return .empty }
        var matches = q.map { prefixMatches($0) }
        let stage1 = evaluate(q, matches, overlay: overlay, allowFuzzy: false, currentYear: currentYear)
        guard stage1.count < Self.fuzzyThreshold,
              q.contains(where: { Self.maxDistance(for: $0) > 0 }) else {
            return Result(hits: stage1, exactCount: stage1.count)
        }
        for i in q.indices { addFuzzyMatches(q[i], into: &matches[i]) }
        let stage2 = evaluate(q, matches, overlay: overlay, allowFuzzy: true, currentYear: currentYear)
        guard stage2.count > stage1.count else { return Result(hits: stage1, exactCount: stage1.count) }
        return Result(hits: Array(stage2.prefix(Self.fuzzyCap)), exactCount: stage1.count)
    }

    // MARK: Stage 1 — exact / prefix over the sorted key table

    private func prefixMatches(_ token: String) -> TokenMatch {
        var match = TokenMatch(tier: [UInt8](repeating: 0, count: keys.count))
        // lower_bound, then walk while the prefix holds (keys are sorted).
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if keys[mid] < token { lo = mid + 1 } else { hi = mid }
        }
        var k = lo
        while k < keys.count, keys[k].hasPrefix(token) {
            match.tier[k] = keys[k] == token ? 3 : 2
            match.matchedKeys.append(Int32(k))
            match.postingTotal += Int(postingStart[k + 1] - postingStart[k])
            k += 1
        }
        return match
    }

    // MARK: Stage 2 — bounded edit distance against name-key prefixes

    private func addFuzzyMatches(_ token: String, into match: inout TokenMatch) {
        let q = Array(token.utf8)
        let maxD = Self.maxDistance(for: token)
        guard maxD > 0, q.count >= 2 else { return }
        // Candidates: any single edit at the front leaves one of these
        // four alignments intact (two edits at the very front can slip
        // through — accepted; the buckets cut the scan ~6×).
        let cols = q.count + maxD
        var scratch = [Int32](repeating: 0, count: 3 * (cols + 1))
        var seen = [Bool](repeating: false, count: keys.count)
        func consider(_ k: Int) {
            guard !seen[k] else { return }
            seen[k] = true
            guard match.tier[k] == 0 else { return }
            let lo = Int(keyStart[k]), hi = Int(keyStart[k + 1])
            guard hi - lo >= q.count - maxD else { return }
            let within = keyBytes.withUnsafeBufferPointer { kb in
                scratch.withUnsafeMutableBufferPointer { s in
                    Self.prefixDistance(q, UnsafeBufferPointer(rebasing: kb[lo..<hi]), maxD: maxD, scratch: s)
                }
            }
            guard within else { return }
            match.tier[k] = 1
            match.matchedKeys.append(Int32(k))
            match.postingTotal += Int(postingStart[k + 1] - postingStart[k])
        }
        func scan(_ start: [Int32], _ list: [Int32], byte: UInt8) {
            for i in Int(start[Int(byte)])..<Int(start[Int(byte) + 1]) { consider(Int(list[i])) }
        }
        scan(firstByteStart, firstByteKeys, byte: q[0])
        scan(firstByteStart, firstByteKeys, byte: q[1])
        scan(secondByteStart, secondByteKeys, byte: q[1])
        scan(secondByteStart, secondByteKeys, byte: q[0])
    }

    /// True when some PREFIX of `t` is within `maxD` optimal-string-
    /// alignment edits of `q` (insert / delete / substitute / adjacent
    /// transposition). Three rolling rows; `scratch` holds 3 × (|q|+maxD+1).
    static func prefixDistance(_ q: [UInt8], _ t: UnsafeBufferPointer<UInt8>, maxD: Int,
                               scratch: UnsafeMutableBufferPointer<Int32>) -> Bool {
        let m = q.count
        let n = min(t.count, m + maxD)
        guard n >= m - maxD else { return false }
        let width = n + 1
        var prev2 = 0, prev = width, cur = 2 * width
        for j in 0...n { scratch[prev + j] = Int32(j) }
        for i in 1...m {
            scratch[cur] = Int32(i)
            var rowMin = Int32(i)
            if n >= 1 {
                for j in 1...n {
                    let cost: Int32 = q[i - 1] == t[j - 1] ? 0 : 1
                    var v = min(scratch[prev + j] + 1, scratch[cur + j - 1] + 1, scratch[prev + j - 1] + cost)
                    if i > 1, j > 1, q[i - 1] == t[j - 2], q[i - 2] == t[j - 1] {
                        v = min(v, scratch[prev2 + j - 2] + 1)
                    }
                    scratch[cur + j] = v
                    if v < rowMin { rowMin = v }
                }
            }
            if rowMin > Int32(maxD) { return false }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        // Last computed row is now `prev`: min over prefixes of t that
        // could be within range (shorter prefixes cost at least m − j).
        var best = Int32.max
        for j in max(0, m - maxD)...n where scratch[prev + j] < best { best = scratch[prev + j] }
        return best <= Int32(maxD)
    }

    // MARK: Scoring

    private func evaluate(_ q: [String], _ matches: [TokenMatch], overlay: Overlay,
                          allowFuzzy: Bool, currentYear: Int) -> [Hit] {
        // Driver: the typed token reaching the fewest rows; every row it
        // reaches is then verified against all tokens.
        var driver = 0
        for i in matches.indices where matches[i].postingTotal < matches[driver].postingTotal { driver = i }
        var visited = [Bool](repeating: false, count: rowCount)
        var out: [Hit] = []
        for k in matches[driver].matchedKeys {
            for p in Int(postingStart[Int(k)])..<Int(postingStart[Int(k) + 1]) {
                let row = Int(postingRows[p])
                guard !visited[row] else { continue }
                visited[row] = true
                if let score = score(row: row, q, matches, overlay: overlay, allowFuzzy: allowFuzzy, currentYear: currentYear) {
                    out.append(Hit(row: Int32(row), score: score))
                }
            }
        }
        // Rows the driver reaches only through a People-tab alias.
        for (row32, _) in overlay.aliasTokens {
            let row = Int(row32)
            guard row >= 0, row < rowCount, !visited[row] else { continue }
            visited[row] = true
            if let score = score(row: row, q, matches, overlay: overlay, allowFuzzy: allowFuzzy, currentYear: currentYear) {
                out.append(Hit(row: row32, score: score))
            }
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.row < $1.row }
        return out
    }

    /// nil when some typed token matches nothing on this row.
    private func score(row: Int, _ q: [String], _ matches: [TokenMatch], overlay: Overlay,
                       allowFuzzy: Bool, currentYear: Int) -> Double? {
        let aliases = overlay.aliasTokens[Int32(row)]
        var total = 0.0
        for i in q.indices {
            var best: UInt8 = 0
            for t in Int(rowTokenStart[row])..<Int(rowTokenStart[row + 1]) {
                let tier = matches[i].tier[Int(rowTokenIDs[t])]
                if tier > best { best = tier; if best == 3 { break } }
            }
            if best < 3, let aliases {
                for alias in aliases {
                    let tier = Self.tier(q[i], against: alias, allowFuzzy: allowFuzzy)
                    if tier > best { best = tier; if best == 3 { break } }
                }
            }
            guard best > 0 else { return nil }
            switch best {
            case 3: total += Weight.exact
            case 2: total += Weight.prefix
            default: total += Weight.fuzzy
            }
        }
        if overlay.profileRows.contains(Int32(row)) { total += Weight.profile }
        let year = Int(birthYear[row])
        if year >= 0 {
            let t = min(1, max(0, Double(year - (currentYear - Weight.recencyWindow)) / Double(Weight.recencyWindow)))
            total += Weight.recency * (t - 0.5)
        }
        let unmatched = max(0, Int(nameTokenCount[row]) - q.count)
        if unmatched > 0 {
            total -= min(Weight.unmatchedCap, Weight.unmatchedFirst + Double(unmatched - 1) * Weight.unmatchedToken)
        }
        return total
    }

    /// Tier of a typed token against one alias token (not in the key
    /// table, so compared directly).
    private static func tier(_ token: String, against alias: String, allowFuzzy: Bool) -> UInt8 {
        if alias == token { return 3 }
        if alias.hasPrefix(token) { return 2 }
        guard allowFuzzy else { return 0 }
        let q = Array(token.utf8)
        let maxD = maxDistance(for: token)
        guard maxD > 0 else { return 0 }
        let a = Array(alias.utf8)
        var scratch = [Int32](repeating: 0, count: 3 * (q.count + maxD + 1))
        let within = a.withUnsafeBufferPointer { ab in
            scratch.withUnsafeMutableBufferPointer { s in prefixDistance(q, ab, maxD: maxD, scratch: s) }
        }
        return within ? 1 : 0
    }
}
