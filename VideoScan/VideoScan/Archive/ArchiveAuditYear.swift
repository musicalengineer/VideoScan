// ArchiveAuditYear.swift
// Archive tab — "Audit <year>…" (Rick 2026-10-07). Right-click a year
// header on the decade page and ask ONE question: does this year hold
// DISTINCT family events, or the same footage repeated?
//
// Pure and SwiftUI-free. The main actor projects one `ArchiveAuditInput`
// per archived CARD (ArchiveView+AuditYear.swift); `ArchiveAuditBuilder`
// runs off-main, once per open, and returns an `ArchiveAuditReport`.
// No media is opened, nothing on disk is read; every rule below is a
// computation over catalog facts that already exist.
//
// ── REPEAT RULES (each group carries its evidence in plain words) ────────
//   Same footage            same content fingerprint (contentHash), the same
//                           source / derivedFrom lineage, or the same Find
//                           Similar Footage group. Union-find within the year.
//   Possibly the same       Whisper transcripts overlap: word 5-gram
//                           containment ≥ 40 % (shared / smaller set). Marked
//                           "possible" — two Christmas mornings both say
//                           "merry christmas".
//   Same event, several     ≥ 3 videos with the same occasion word in the year.
//   Filed from another year the card shares a footage group or lineage with an
//                           archived card filed under a different year.
// A group Rick has marked "These are different, keep both" (ArchiveAuditStore)
// is hidden — and counted, so the sheet can say so.
//
// ── MEMORY (worst case) ──────────────────────────────────────────────────
// Per card: the input (~300 B + its transcript string, shared copy-on-write
// with the catalog). Lineage / group / hash buckets: one dictionary slot per
// key, ~3 per card → ~100 B. At 100k archived cards ≈ 40 MB, freed when the
// build returns. Transcript shingles are capped: at most `maxShinglesPerItem`
// (1 000) hashes per transcript, and at most `maxTranscribedItems` (5 000)
// transcripts per year → ≤ 40 MB of UInt64 plus postings (each posting list
// capped at `maxPosting`). Nothing scales with file size.

import Foundation

// MARK: - Input (one archived card)

struct ArchiveAuditInput: Sendable, Equatable, Identifiable {
    /// The card's id (the asset record — same id the timeline uses).
    let id: UUID
    var title: String
    /// Year the archive filed it under (nil = Undated shelf).
    var year: Int?
    var durationSeconds: Double = 0
    /// The occasion cue AFTER any user override. nil = no cue (photo/audio).
    var occasion: ArchiveOccasionCue? = nil
    /// True when the occasion came from Rick's own tag.
    var occasionIsUserTag: Bool = false
    /// Non-empty content fingerprints of the card's files (FileHasher "v1:…").
    var contentHashes: [String] = []
    /// Find Similar Footage group ids of the card's files.
    var footageGroupIDs: [UUID] = []
    /// Lineage keys: every member's own id, its derivedFrom (promotion links
    /// included — two archive copies of ONE source record share it), and
    /// the archive copy's id. Two cards sharing a key share lineage.
    var lineageKeys: [UUID] = []
    /// Member ids that are the card's OWN files (to word lineage evidence).
    var memberIDs: [UUID] = []
    /// Whisper transcript (nil / empty = none). Only the audited year's
    /// cards need it; the projection leaves it nil elsewhere.
    var transcript: String? = nil
    /// Paths a cached thumbnail might be keyed under (source, then copy).
    var thumbnailPaths: [String] = []

    var friendlyDuration: String { ArchiveTimelinePath.friendlyDuration(seconds: durationSeconds) }
}

// MARK: - Report

enum ArchiveAuditRepeatKind: String, Codable, Sendable, CaseIterable {
    case sameFootage, possiblySame, sameEvent, filedFromAnotherYear

    /// The group's heading — plain words.
    var heading: String { Self.headings[self] ?? rawValue }

    private static let headings: [ArchiveAuditRepeatKind: String] = [
        .sameFootage: "Same footage",
        .possiblySame: "Possibly the same",
        .sameEvent: "Same event, several videos",
        .filedFromAnotherYear: "Filed from another year",
    ]
}

struct ArchiveAuditEvent: Sendable, Equatable, Identifiable {
    let occasion: ArchiveOccasion
    /// "Christmas", "Camping", "Halloween".
    let word: String
    var itemIDs: [UUID]
    var seconds: Double
    var id: String { occasion.rawValue + "|" + word }
}

struct ArchiveAuditRepeatGroup: Sendable, Equatable, Identifiable {
    let kind: ArchiveAuditRepeatKind
    /// Cards in THIS year, title order.
    var itemIDs: [UUID]
    /// Cards in OTHER years (filed-from-another-year only).
    var otherYearIDs: [UUID] = []
    /// The other year most of `otherYearIDs` are filed under.
    var otherYear: Int? = nil
    /// One plain sentence per piece of evidence.
    var evidence: [String]
    /// Stable identity — the kind plus every id involved, sorted.
    var id: String { ArchiveAuditDecision.key(kind: kind, ids: itemIDs + otherYearIDs) }
    /// Every id the "keep both" decision is keyed by.
    var decisionIDs: [UUID] { itemIDs + otherYearIDs }
}

struct ArchiveAuditReport: Sendable, Equatable {
    let year: Int
    var events: [ArchiveAuditEvent] = []
    var repeats: [ArchiveAuditRepeatGroup] = []
    /// Videos with no occasion, title order.
    var unlabeledIDs: [UUID] = []
    /// Groups hidden because Rick said "these are different".
    var dismissedCount = 0
    /// Every card the sheet may name (this year's + the other-year relatives).
    var items: [UUID: ArchiveAuditInput] = [:]

    /// Groups that count as repeats in the verdict (not the other-year ones).
    var repeatCount: Int { repeats.filter { $0.kind != .filedFromAnotherYear }.count }
    var filedFromOtherYears: [ArchiveAuditRepeatGroup] { repeats.filter { $0.kind == .filedFromAnotherYear } }

    /// "1995: 4 events · 1 repeat · 1 filed from 1992".
    var verdict: String {
        var parts = ["\(year): " + Self.plural(events.count, "event")]
        parts.append(repeatCount == 0 ? "no repeats" : Self.plural(repeatCount, "repeat"))
        let filed = filedFromOtherYears
        if !filed.isEmpty {
            let years = Set(filed.compactMap(\.otherYear))
            if years.count == 1, let only = years.first {
                parts.append("\(filed.count) filed from \(only)")
            } else {
                parts.append("\(filed.count) filed from other years")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
}

// MARK: - Decisions ("These are different, keep both")

/// One "keep both" answer. Keyed by the kind + the ids it covers; a group
/// is hidden when a decision of its kind covers ALL of its ids (a new
/// member joining the group later is new information — it asks again).
struct ArchiveAuditDecision: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: ArchiveAuditRepeatKind
    var itemIDs: [UUID]
    var decidedAt: Date
    /// Titles at decision time — for a human reading the JSON, never matched.
    var titles: [String] = []

    var key: String { Self.key(kind: kind, ids: itemIDs) }

    static func key(kind: ArchiveAuditRepeatKind, ids: [UUID]) -> String {
        kind.rawValue + ":" + Set(ids).map(\.uuidString).sorted().joined(separator: ",")
    }
}

/// O(1)-per-id lookup over the decisions, built once per audit.
struct ArchiveAuditDecisionIndex: Sendable {
    private var byFirstID: [UUID: [Set<UUID>]] = [:]
    private var kinds: [UUID: [ArchiveAuditRepeatKind]] = [:]

    init(_ decisions: [ArchiveAuditDecision]) {
        for d in decisions {
            let ids = Set(d.itemIDs)
            for i in ids {
                byFirstID[i, default: []].append(ids)
                kinds[i, default: []].append(d.kind)
            }
        }
    }

    /// True when a decision of `kind` covers every id of the group.
    func covers(kind: ArchiveAuditRepeatKind, ids: [UUID]) -> Bool {
        guard let first = ids.first, let sets = byFirstID[first], let ks = kinds[first] else { return false }
        let want = Set(ids)
        for (s, k) in zip(sets, ks) where k == kind && want.isSubset(of: s) { return true }
        return false
    }
}

// MARK: - Transcript overlap (word 5-gram containment)

enum ArchiveTranscriptOverlap {
    static let shingleWords = 5
    /// "Possibly the same" at or above this containment.
    static let threshold = 0.40
    /// Fewer shingles than this is too little speech to judge ("okay okay").
    static let minShingles = 8
    /// Bottom-k sample cap per transcript (consistent sampling: the same
    /// phrase hashes the same on both sides, so containment is preserved
    /// in expectation).
    static let maxShinglesPerItem = 1_000

    /// Lowercased word tokens (letters and digits only).
    static func words(_ text: String) -> [Substring] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }
    }

    /// FNV-1a 64 over the five words — stable across runs (unlike Hasher).
    static func shingles(_ text: String) -> Set<UInt64> {
        let w = words(text)
        guard w.count >= shingleWords else { return [] }
        var out = Set<UInt64>()
        out.reserveCapacity(min(w.count, maxShinglesPerItem * 2))
        for i in 0...(w.count - shingleWords) {
            out.insert(fnv(w[i..<(i + shingleWords)]))
        }
        guard out.count > maxShinglesPerItem else { return out }
        return Set(out.sorted().prefix(maxShinglesPerItem))
    }

    private static func fnv(_ gram: ArraySlice<Substring>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for word in gram {
            for b in word.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            h = (h ^ 0x20) &* 0x0000_0100_0000_01B3          // word separator
        }
        return h
    }

    /// |A ∩ B| / min(|A|, |B|); 0 when either is too short.
    static func containment(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
        guard a.count >= minShingles, b.count >= minShingles else { return 0 }
        let (small, big) = a.count <= b.count ? (a, b) : (b, a)
        let shared = small.reduce(0) { big.contains($1) ? $0 + 1 : $0 }
        return Double(shared) / Double(small.count)
    }
}

// MARK: - The builder

enum ArchiveAuditBuilder {
    /// A transcript shingle shared by more cards than this is a stock phrase
    /// ("happy birthday to you") — skipped as candidate evidence.
    static let maxPosting = 64
    /// Cap on transcripts compared per year (memory bound in the header).
    static let maxTranscribedItems = 5_000
    /// "Same event" needs at least this many videos with one occasion word.
    static let sameEventMinimum = 3
    /// Evidence sentences shown per group.
    static let maxEvidence = 6

    /// O(archived) bucketing + O(year²) worst case only inside the year's
    /// union-find (bounded by bucket sizes). Runs off-main.
    static func build(year: Int, inputs: [ArchiveAuditInput],
                      decisions: [ArchiveAuditDecision]) -> ArchiveAuditReport {
        let inYear = inputs.filter { $0.year == year }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        var report = ArchiveAuditReport(year: year)
        for i in inYear { report.items[i.id] = i }
        let (events, unlabeled) = eventsAndUnlabeled(inYear)
        report.events = events
        report.unlabeledIDs = unlabeled

        var candidates: [ArchiveAuditRepeatGroup] = []
        let footage = sameFootageGroups(inYear)
        candidates += footage.groups
        candidates += possiblySameGroups(inYear, alreadySame: footage.componentOf)
        candidates += sameEventGroups(events, items: report.items)
        let filed = filedFromAnotherYear(year: year, inYear: inYear, all: inputs)
        candidates += filed.groups
        for (id, input) in filed.relatives { report.items[id] = input }

        let index = ArchiveAuditDecisionIndex(decisions)
        for g in candidates {
            if index.covers(kind: g.kind, ids: g.decisionIDs) { report.dismissedCount += 1 }
            else { report.repeats.append(g) }
        }
        return report
    }

    // MARK: Events

    /// One event per distinct (occasion, word); unlabeled videos apart.
    static func eventsAndUnlabeled(_ inYear: [ArchiveAuditInput]) -> ([ArchiveAuditEvent], [UUID]) {
        var byKey: [String: ArchiveAuditEvent] = [:]
        var order: [String] = []
        var unlabeled: [UUID] = []
        for item in inYear {
            guard let cue = item.occasion else { continue }
            guard cue.occasion != .unlabeled else { unlabeled.append(item.id); continue }
            let key = cue.occasion.rawValue + "|" + cue.word
            if byKey[key] == nil {
                byKey[key] = ArchiveAuditEvent(occasion: cue.occasion, word: cue.word, itemIDs: [], seconds: 0)
                order.append(key)
            }
            byKey[key]?.itemIDs.append(item.id)
            if item.durationSeconds.isFinite, item.durationSeconds > 0 { byKey[key]?.seconds += item.durationSeconds }
        }
        let rank = Dictionary(uniqueKeysWithValues: ArchiveOccasion.allCases.enumerated().map { ($1, $0) })
        let events = order.compactMap { byKey[$0] }.sorted {
            (rank[$0.occasion] ?? 0, $0.word) < (rank[$1.occasion] ?? 0, $1.word)
        }
        return (events, unlabeled)
    }

    // MARK: Same footage

    struct Edge { let a: Int; let b: Int; let line: String }

    /// Union-find over the year's cards on hash / lineage / footage group.
    static func sameFootageGroups(_ xs: [ArchiveAuditInput])
        -> (groups: [ArchiveAuditRepeatGroup], componentOf: [UUID: Int]) {
        var edges: [Edge] = []
        star(buckets(xs) { $0.contentHashes }, xs, into: &edges) { a, b in
            "“\(a.title)” and “\(b.title)” have the same content fingerprint"
        }
        star(buckets(xs) { $0.lineageKeys.map(\.uuidString) }, xs, into: &edges) { a, b in
            lineageLine(a, b)
        }
        star(buckets(xs) { $0.footageGroupIDs.map(\.uuidString) }, xs, into: &edges) { a, b in
            "Find Similar Footage put “\(a.title)” and “\(b.title)” in one group"
        }
        var uf = UnionFind(xs.count)
        for e in edges { uf.union(e.a, e.b) }
        var linesByRoot: [Int: [String]] = [:]
        for e in edges { linesByRoot[uf.find(e.a), default: []].append(e.line) }
        var componentOf: [UUID: Int] = [:]
        var groups: [ArchiveAuditRepeatGroup] = []
        for (root, members) in uf.components() where members.count > 1 {
            for m in members { componentOf[xs[m].id] = root }
            groups.append(ArchiveAuditRepeatGroup(kind: .sameFootage, itemIDs: members.map { xs[$0].id },
                                                  evidence: unique(linesByRoot[root] ?? [])))
        }
        return (groups.sorted { $0.id < $1.id }, componentOf)
    }

    static func lineageLine(_ a: ArchiveAuditInput, _ b: ArchiveAuditInput) -> String {
        let aMadeFromB = !Set(a.lineageKeys).isDisjoint(with: b.memberIDs)
        let bMadeFromA = !Set(b.lineageKeys).isDisjoint(with: a.memberIDs)
        if aMadeFromB || bMadeFromA {
            return "“\(aMadeFromB ? a.title : b.title)” was made from “\(aMadeFromB ? b.title : a.title)”"
        }
        return "“\(a.title)” and “\(b.title)” come from the same source recording"
    }

    /// key → card indices (a card listed once per key).
    static func buckets(_ xs: [ArchiveAuditInput], _ keys: (ArchiveAuditInput) -> [String]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (i, x) in xs.enumerated() {
            for k in Set(keys(x)) where !k.isEmpty { out[k, default: []].append(i) }
        }
        return out
    }

    /// Star edges: every member of a bucket links to its first member.
    static func star(_ b: [String: [Int]], _ xs: [ArchiveAuditInput], into edges: inout [Edge],
                     line: (ArchiveAuditInput, ArchiveAuditInput) -> String) {
        for key in b.keys.sorted() {
            guard let idx = b[key], idx.count > 1 else { continue }
            for j in idx.dropFirst() { edges.append(Edge(a: idx[0], b: j, line: line(xs[idx[0]], xs[j]))) }
        }
    }

    // MARK: Possibly the same (transcripts)

    static func possiblySameGroups(_ xs: [ArchiveAuditInput], alreadySame: [UUID: Int]) -> [ArchiveAuditRepeatGroup] {
        let spoken = xs.filter { !($0.transcript ?? "").isEmpty }.prefix(maxTranscribedItems)
        let sets = spoken.map { ArchiveTranscriptOverlap.shingles($0.transcript ?? "") }
        var postings: [UInt64: [Int]] = [:]
        for (i, s) in sets.enumerated() where s.count >= ArchiveTranscriptOverlap.minShingles {
            for h in s { postings[h, default: []].append(i) }
        }
        var shared: [Int: Int] = [:]                       // pair code → shared shingles
        let n = sets.count
        for list in postings.values where list.count > 1 && list.count <= maxPosting {
            for x in 0..<list.count { for y in (x + 1)..<list.count { shared[list[x] * n + list[y], default: 0] += 1 } }
        }
        var groups: [ArchiveAuditRepeatGroup] = []
        for (code, count) in shared {
            let (i, j) = (code / n, code % n)
            let smaller = min(sets[i].count, sets[j].count)
            guard smaller > 0, Double(count) / Double(smaller) >= ArchiveTranscriptOverlap.threshold else { continue }
            let (a, b) = (spoken[spoken.startIndex + i], spoken[spoken.startIndex + j])
            if let ca = alreadySame[a.id], alreadySame[b.id] == ca { continue }
            let pct = Int((Double(count) / Double(smaller) * 100).rounded())
            groups.append(ArchiveAuditRepeatGroup(
                kind: .possiblySame, itemIDs: [a.id, b.id],
                evidence: ["“\(a.title)” and “\(b.title)” share \(pct)% of their spoken phrases — possibly the same footage"]))
        }
        return groups.sorted { $0.id < $1.id }
    }

    // MARK: Same event, several videos

    static func sameEventGroups(_ events: [ArchiveAuditEvent], items: [UUID: ArchiveAuditInput]) -> [ArchiveAuditRepeatGroup] {
        events.filter { $0.itemIDs.count >= sameEventMinimum }.map { e in
            ArchiveAuditRepeatGroup(
                kind: .sameEvent, itemIDs: e.itemIDs,
                evidence: ["\(e.itemIDs.count) videos are \(e.occasion.emoji) \(e.word) this year — one occasion filmed several times, or several different ones?"])
        }
    }

    // MARK: Filed from another year

    /// O(archived): index other-year cards by lineage key and footage group,
    /// then look each of this year's cards up.
    static func filedFromAnotherYear(year: Int, inYear: [ArchiveAuditInput], all: [ArchiveAuditInput])
        -> (groups: [ArchiveAuditRepeatGroup], relatives: [UUID: ArchiveAuditInput]) {
        var byKey: [UUID: [Int]] = [:]
        for (i, x) in all.enumerated() where x.year != nil && x.year != year {
            for k in Set(x.lineageKeys + x.footageGroupIDs) { byKey[k, default: []].append(i) }
        }
        var groups: [ArchiveAuditRepeatGroup] = []
        var relatives: [UUID: ArchiveAuditInput] = [:]
        for item in inYear {
            var hits = Set<Int>()
            for k in Set(item.lineageKeys + item.footageGroupIDs) { hits.formUnion(byKey[k] ?? []) }
            guard !hits.isEmpty else { continue }
            let others = hits.sorted().map { all[$0] }
            for o in others { relatives[o.id] = o }
            groups.append(filedGroup(item, others: others))
        }
        return (groups, relatives)
    }

    static func filedGroup(_ item: ArchiveAuditInput, others: [ArchiveAuditInput]) -> ArchiveAuditRepeatGroup {
        var tally: [Int: Int] = [:]
        for o in others { if let y = o.year { tally[y, default: 0] += 1 } }
        let top = tally.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        let lines = others.prefix(maxEvidence).map { o -> String in
            let why = Set(o.footageGroupIDs).isDisjoint(with: item.footageGroupIDs)
                ? "the same recording's lineage" : "the same footage group"
            return "“\(item.title)” shares \(why) with “\(o.title)”, filed in \(o.year.map(String.init) ?? "another year")"
        }
        return ArchiveAuditRepeatGroup(kind: .filedFromAnotherYear, itemIDs: [item.id],
                                       otherYearIDs: others.map(\.id), otherYear: top, evidence: lines)
    }

    static func unique(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return Array(lines.filter { seen.insert($0).inserted }.prefix(maxEvidence))
    }

    // MARK: Union-find

    /// Path halving + union by size. (For Rick: the classic disjoint-set
    /// forest — a `struct` with `mutating` methods ≈ a C++ class whose
    /// non-const members take `this` by reference.)
    struct UnionFind {
        var parent: [Int]
        var size: [Int]
        init(_ n: Int) { parent = Array(0..<n); size = Array(repeating: 1, count: n) }

        mutating func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }

        mutating func union(_ a: Int, _ b: Int) {
            var (ra, rb) = (find(a), find(b))
            guard ra != rb else { return }
            if size[ra] < size[rb] { swap(&ra, &rb) }
            parent[rb] = ra
            size[ra] += size[rb]
        }

        /// root → members, members in input order.
        mutating func components() -> [Int: [Int]] {
            var out: [Int: [Int]] = [:]
            for i in 0..<parent.count { out[find(i), default: []].append(i) }
            return out
        }
    }
}
