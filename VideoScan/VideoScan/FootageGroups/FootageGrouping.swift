// FootageGrouping.swift
// Find Similar Footage, Phase 1 — the pure core (Rick 2026-09-23,
// docs/find_original_design.md top section). Catalog METADATA in, footage
// groups out. No media bytes, no disk, no actors: every function here is a
// plain computation over Sendable values, so it runs on the cooperative
// pool (@concurrent) and is table-testable.
//
// ── EVIDENCE (each edge keeps its reason) ─────────────────────────────────
//   Identical  same full content hash (`contentHash`, the h: key)
//              same whole-file SHA-256 (`contentFixity`)
//   Confirmed  the person said "same footage" (FootageDecision.same)
//   Likely     recorded lineage (derivedFrom + derivationKind)
//              combinedFromPairID → the pair it was combined from
//              an A/V pair correlated High (pairGroupID)
//              same Avid material package UMID, same stream type
//              same FCP `com.apple.proapps.mediaIdentifier`
//              FCP `<event>/Transcoded Media/**/X.*` ↔ `<event>/Original Media/X.*`
//              a promote collision "<name>_02" beside "<name>" in the same
//                folder (ArchiveItemVersions' rule) AND the same length
//              same normalized name (FootageStem) AND length within ±2
//                frames at the record's own frame rate
//              same sampled signature (partialMD5 + size) — a NOMINATION:
//                refused when the two full hashes are known and differ,
//                never "Identical" (codex, #1633 review)
//   Possible   a camera-counter name (Clip 03, MVI_1234 — generic stems
//                are reused by every camera) + the same length
//              the same name except one trailing counter ("-3", "_7")
//                + the same length (DickyTheBoysDadBreen-1985 / -1985-3)
//              an A/V pair correlated Medium (Low correlations are guesses
//                by length and are NOT evidence — calibration 2026-09-23
//                found Low pairs 0.7 s apart)
//   DURATION ALONE NEVER MAKES AN EDGE. (Sensor: FootageGroupingSensorTests.)
//
// ── GROUPS ────────────────────────────────────────────────────────────────
// Connected components by union-find, taking edges strongest first
// (Confirmed, Identical, Likely, Possible) — so each group's links form a
// maximum spanning forest and the group's confidence (its WEAKEST accepted
// link) is the bottleneck of the strongest path, as the spec asks.
// Guards against runaway components (documented rules):
//   1. "Not the same" is a cannot-link: no edge — not even byte identity —
//      may put two records the person separated into one group.
//   2. Cap: a non-Identical merge that would make a group larger than
//      `cap` (64) is refused and counted. Identical merges are exempt
//      (byte copies ARE the same footage, however many).
//   3. Possible never chains: a Possible edge may only attach a SINGLETON
//      (a record in no group yet) as a leaf, and a leaf never hosts another
//      Possible edge. So Possible links form stars of depth one around a
//      member; two multi-member groups are never merged by a Possible edge.
//
// ── MEMORY (worst case) ───────────────────────────────────────────────────
// Per record: one FootageStem.Analysis (~200 B) + union-find arrays (~40 B)
// + dictionary buckets (~150 B). Edges: star-shaped per bucket, so at most
// a few per record; the name/duration window is capped at
// `maxWindowPartners` per record. 100k records ≈ 50 MB peak, freed when the
// run returns. Nothing scales with file size; no media is opened.
//
// (For Rick: union-find ≈ the classic disjoint-set forest with path
// halving + union by size; `inout Stats` ≈ passing a stats struct by
// non-const reference.)

import Foundation
import VideoScanCore

// MARK: - Input (one record, by value)

struct FootageInput: Sendable, Equatable {
    var id: UUID
    var filename: String
    var fullPath: String
    var durationSeconds: Double
    var frameRate: String
    var sizeBytes: Int64
    var contentHash: String
    var partialMD5: String
    var fixityDigest: String?
    var derivedFrom: UUID?
    var derivationKind: String?
    var cleanupRecipeID: String?
    var pairGroupID: UUID?
    var pairConfidence: PairConfidence?
    var combinedFromPairID: UUID?
    var materialPackageUMID: String
    var streamTypeRaw: String
    var mediaIdentifier: String?
    var originMake: String?
    var originModel: String?
    var originEncoder: String?
    var videoCodec: String
    var embeddedCreationDate: Date?
    var decisions: [FootageDecision]
    /// Purged / set aside / superseded — hidden from the catalog, so not
    /// grouped unless `Options.includeHidden`.
    var isHidden: Bool
    /// The machine answer already on the record (for the incremental apply).
    var existing: FootageMembership?

    init(id: UUID = UUID(), filename: String, fullPath: String = "", durationSeconds: Double = 0,
         frameRate: String = "29.97", sizeBytes: Int64 = 0, contentHash: String = "", partialMD5: String = "",
         fixityDigest: String? = nil, derivedFrom: UUID? = nil, derivationKind: String? = nil,
         cleanupRecipeID: String? = nil, pairGroupID: UUID? = nil, pairConfidence: PairConfidence? = nil,
         combinedFromPairID: UUID? = nil, materialPackageUMID: String = "",
         streamTypeRaw: String = StreamType.videoAndAudio.rawValue, mediaIdentifier: String? = nil,
         originMake: String? = nil, originModel: String? = nil, originEncoder: String? = nil,
         videoCodec: String = "", embeddedCreationDate: Date? = nil, decisions: [FootageDecision] = [],
         isHidden: Bool = false, existing: FootageMembership? = nil) {
        self.id = id; self.filename = filename
        self.fullPath = fullPath.isEmpty ? "/Volumes/T/" + filename : fullPath
        self.durationSeconds = durationSeconds; self.frameRate = frameRate; self.sizeBytes = sizeBytes
        self.contentHash = contentHash; self.partialMD5 = partialMD5; self.fixityDigest = fixityDigest
        self.derivedFrom = derivedFrom; self.derivationKind = derivationKind; self.cleanupRecipeID = cleanupRecipeID
        self.pairGroupID = pairGroupID; self.pairConfidence = pairConfidence
        self.combinedFromPairID = combinedFromPairID; self.materialPackageUMID = materialPackageUMID
        self.streamTypeRaw = streamTypeRaw; self.mediaIdentifier = mediaIdentifier
        self.originMake = originMake; self.originModel = originModel; self.originEncoder = originEncoder
        self.videoCodec = videoCodec; self.embeddedCreationDate = embeddedCreationDate
        self.decisions = decisions; self.isHidden = isHidden; self.existing = existing
    }

    /// "h:<hash>" / "f:<sha256>" / "p:<md5>:<size>" — the key two byte
    /// copies share (the full keys first; "p:" is only a nomination).
    var identityKey: String {
        if !contentHash.isEmpty { return "h:" + contentHash }
        if let f = fixityDigest, !f.isEmpty { return "f:" + f }
        if !partialMD5.isEmpty, sizeBytes > 0 { return "p:\(partialMD5):\(sizeBytes)" }
        return ""
    }

    /// Byte-identical as far as the catalog can tell: the same full content
    /// hash or whole-file digest, or the same sampled signature + size when
    /// at least one side has no full hash (a nomination, never a conflict).
    func sameBytes(as o: FootageInput) -> Bool {
        if !contentHash.isEmpty, contentHash == o.contentHash { return true }
        if let f = fixityDigest, !f.isEmpty, f == o.fixityDigest { return true }
        if !contentHash.isEmpty, !o.contentHash.isEmpty { return false }
        return !partialMD5.isEmpty && partialMD5 == o.partialMD5 && sizeBytes > 0 && sizeBytes == o.sizeBytes
    }
}

// MARK: - The core

enum FootageGrouping {

    /// Bump when a rule changes: every record's answer is then rewritten.
    static let algorithmVersion = 1
    static let defaultCap = 64
    /// Reasons kept per member (the sheet shows them as chips).
    static let maxReasons = 6
    /// Shorter than this, a length match means nothing.
    static let minDurationSeconds = 1.0
    /// Name/duration window: partners compared per record (a bucket of
    /// thousands of equal-length "IMG_0001"s can't go quadratic).
    static let maxWindowPartners = 32

    struct Options: Sendable, Equatable {
        var cap: Int = FootageGrouping.defaultCap
        /// Group purged / set-aside / superseded records too (calibration).
        var includeHidden: Bool = false
    }

    enum Reason: String, Sendable, CaseIterable, Comparable {
        case personSaidSame
        case sameContentHash
        case sameFixity
        case lineage
        case combinedFromPair
        case avPairHigh
        case materialPackage
        case fcpMediaIdentifier
        case fcpOriginalTranscoded
        case promoteCollision
        case nameAndDuration
        case sampledSignature
        case genericNameAndDuration
        case counterNameAndDuration
        case avPairWeak

        var confidence: FootageConfidence {
            switch self {
            case .personSaidSame: return .confirmed
            case .sameContentHash, .sameFixity: return .identical
            case .lineage, .combinedFromPair, .avPairHigh, .materialPackage, .fcpMediaIdentifier,
                 .fcpOriginalTranscoded, .promoteCollision, .nameAndDuration, .sampledSignature:
                return .likely
            case .genericNameAndDuration, .counterNameAndDuration, .avPairWeak: return .possible
            }
        }

        static func < (a: Reason, b: Reason) -> Bool {
            (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
        }
    }

    /// One piece of evidence between inputs[a] and inputs[b]. For
    /// directional reasons, `a` is the derived side (child / transcode /
    /// collision copy / the record carrying the counter).
    struct Edge: Sendable, Equatable {
        var a: Int
        var b: Int
        var reason: Reason
        /// "balanceAudio", "Δ1 frame", "High"… (shown in the reason text).
        var detail: String = ""
        var confidence: FootageConfidence { reason.confidence }
    }

    struct Stats: Sendable, Equatable {
        var inputs = 0
        var considered = 0
        var edgesByReason: [Reason: Int] = [:]
        var acceptedByReason: [Reason: Int] = [:]
        /// Sampled-signature buckets whose full hashes disagreed.
        var sampledConflicts = 0
        var refusedByCap = 0
        var refusedPossibleChain = 0
        var refusedByPerson = 0
        var groups = 0
        var members = 0
        var groupsByConfidence: [FootageConfidence: Int] = [:]
        var largestGroup = 0
        var originalNotInCatalog = 0
    }

    struct Group: Sendable, Equatable {
        var id: UUID
        /// Rank order: [0] is the likely original.
        var memberIDs: [UUID]
        var confidence: FootageConfidence
        var originalInCatalog: Bool
        /// Accepted-link reasons in this group.
        var reasons: [Reason: Int]
    }

    struct Result: Sendable {
        var memberships: [UUID: FootageMembership]
        var groups: [Group]
        var stats: Stats
    }

    /// Everything phase 1 derives per input.
    struct Prepared: Sendable {
        var inputs: [FootageInput]
        var considered: [Bool]
        var analyses: [FootageStem.Analysis]
        var tolerance: [Double]
        var indexByID: [UUID: Int]
    }

    struct Components: Sendable {
        /// Root index per input (self for singletons / unconsidered).
        var root: [Int]
        var size: [Int]
        /// Weakest accepted link per root.
        var confidence: [Int: FootageConfidence]
        var acceptedByRoot: [Int: [Reason: Int]]
    }

    // MARK: Whole run

    static func run(_ inputs: [FootageInput], options: Options = Options(), now: Date = Date()) -> Result {
        var stats = Stats()
        let p = prepare(inputs, options: options, stats: &stats)
        let e = edges(p, stats: &stats)
        let c = components(p, edges: e, options: options, stats: &stats)
        return assemble(p, edges: e, components: c, now: now, stats: stats)
    }

    // MARK: Phase 1 — per-record analysis

    static func prepare(_ inputs: [FootageInput], options: Options, stats: inout Stats) -> Prepared {
        var considered = [Bool](repeating: false, count: inputs.count)
        var analyses: [FootageStem.Analysis] = []
        analyses.reserveCapacity(inputs.count)
        var tolerance = [Double](repeating: 0.1, count: inputs.count)
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(inputs.count)
        for (i, x) in inputs.enumerated() {
            indexByID[x.id] = i
            considered[i] = options.includeHidden || !x.isHidden
            analyses.append(FootageStem.analyze(x.filename))
            tolerance[i] = FootageStem.durationTolerance(frameRate: x.frameRate)
        }
        stats.inputs = inputs.count
        stats.considered = considered.lazy.filter { $0 }.count
        return Prepared(inputs: inputs, considered: considered, analyses: analyses,
                        tolerance: tolerance, indexByID: indexByID)
    }

    // MARK: Phase 2 — evidence

    static func edges(_ p: Prepared, stats: inout Stats) -> [Edge] {
        var b = EdgeBuilder(p: p)
        b.identical()
        b.sampledSignatures()
        b.lineage()
        b.avPairs()
        b.structure()
        b.promoteCollisions()
        b.nameAndDuration()
        b.trailingCounters()
        b.personSaidSame()
        for (r, n) in b.counts { stats.edgesByReason[r, default: 0] += n }
        stats.sampledConflicts += b.sampledConflicts
        return b.out
    }

    /// Phase 2's working state: one method per evidence rule. (For Rick: a
    /// small builder object ≈ a C++ functor class whose members are the
    /// shared indexes, so each rule is its own short, testable function.)
    struct EdgeBuilder {
        let p: Prepared
        var xs: [FootageInput] { p.inputs }
        let idx: [Int]
        var out: [Edge] = []
        var counts: [Reason: Int] = [:]
        var sampledConflicts = 0
        /// Normalized-name buckets sorted by length (built by nameAndDuration).
        var byKey: [String: [Int]] = [:]
        var genericCache: [Int: Bool] = [:]

        init(p: Prepared) {
            self.p = p
            idx = p.inputs.indices.filter { p.considered[$0] }
        }

        mutating func add(_ a: Int, _ b: Int, _ r: Reason, _ detail: String = "") {
            guard a != b else { return }
            out.append(Edge(a: a, b: b, reason: r, detail: detail))
            counts[r, default: 0] += 1
        }

        func buckets(_ key: (Int) -> String?) -> [String: [Int]] {
            var d: [String: [Int]] = [:]
            for i in idx { if let k = key(i), !k.isEmpty { d[k, default: []].append(i) } }
            return d
        }

        /// Buckets → stars (connectivity is all a component needs; the first
        /// member is the hub). Keys sorted so the edge order is stable.
        mutating func star(_ d: [String: [Int]], _ r: Reason) {
            for key in d.keys.sorted() {
                guard let m = d[key], let hub = m.first, m.count > 1 else { continue }
                for i in m.dropFirst() { add(i, hub, r) }
            }
        }

        mutating func identical() {
            let xs = self.xs
            star(buckets { xs[$0].contentHash }, .sameContentHash)
            star(buckets { xs[$0].fixityDigest }, .sameFixity)
        }

        /// A nomination, refused on a full-hash conflict; an unhashed member
        /// joins the bucket's (single) hashed identity.
        mutating func sampledSignatures() {
            let xs = self.xs
            let sampled = buckets { i in
                xs[i].partialMD5.isEmpty || xs[i].sizeBytes <= 0 ? nil : "\(xs[i].partialMD5):\(xs[i].sizeBytes)"
            }
            for key in sampled.keys.sorted() {
                guard let m = sampled[key], let first = m.first, m.count > 1 else { continue }
                let known = Set(m.map { xs[$0].contentHash }.filter { !$0.isEmpty })
                if known.count > 1 { sampledConflicts += 1; continue }
                let hub = m.first { !xs[$0].contentHash.isEmpty } ?? first
                for i in m where i != hub && xs[i].contentHash.isEmpty { add(i, hub, .sampledSignature) }
            }
        }

        mutating func lineage() {
            for i in idx {
                guard let parent = xs[i].derivedFrom, let j = p.indexByID[parent], p.considered[j] else { continue }
                add(i, j, .lineage, xs[i].derivationKind ?? (xs[i].cleanupRecipeID != nil ? "cleanup" : "derived"))
            }
        }

        /// A/V pairs (High → Likely, Medium → Possible, Low → nothing) and
        /// the file combined from a pair.
        mutating func avPairs() {
            let xs = self.xs
            let pairs = buckets { xs[$0].pairGroupID?.uuidString }
            for key in pairs.keys.sorted() {
                guard let m = pairs[key], let first = m.first, m.count > 1 else { continue }
                let hub = m.first { xs[$0].streamTypeRaw != StreamType.audioOnly.rawValue } ?? first
                for i in m where i != hub {
                    let conf = min(xs[i].pairConfidence ?? .low, xs[hub].pairConfidence ?? .low)
                    switch conf {
                    case .high: add(i, hub, .avPairHigh, conf.rawValue)
                    case .medium: add(i, hub, .avPairWeak, conf.rawValue)
                    case .low: continue
                    }
                }
            }
            for i in idx {
                guard let pid = xs[i].combinedFromPairID, let hub = pairs[pid.uuidString]?.first else { continue }
                add(i, hub, .combinedFromPair)
            }
        }

        /// Avid material package, FCP media identifier, FCP Original ↔
        /// Transcoded Media (same event, same stem).
        mutating func structure() {
            let xs = self.xs
            star(buckets { i in
                xs[i].materialPackageUMID.isEmpty ? nil : xs[i].materialPackageUMID + "|" + xs[i].streamTypeRaw
            }, .materialPackage)
            star(buckets { xs[$0].mediaIdentifier }, .fcpMediaIdentifier)
            var originals: [String: Int] = [:]
            for i in idx {
                if let k = fcpKey(xs[i].fullPath, folder: "/original media/"), originals[k] == nil { originals[k] = i }
            }
            for i in idx {
                guard let k = fcpKey(xs[i].fullPath, folder: "/transcoded media/"), let j = originals[k] else { continue }
                add(i, j, .fcpOriginalTranscoded)
            }
        }

        /// "<name>_NN" beside "<name>" in the same folder, same length.
        mutating func promoteCollisions() {
            var byFolderName: [String: Int] = [:]
            for i in idx { byFolderName[folderKey(xs[i].fullPath) + "/" + xs[i].filename.lowercased()] = i }
            for i in idx {
                guard let base = p.analyses[i].collisionBaseFilename,
                      let j = byFolderName[folderKey(xs[i].fullPath) + "/" + base],
                      lengthsMatch(i, j, p) else { continue }
                add(i, j, .promoteCollision)
            }
        }

        mutating func isGeneric(_ i: Int) -> Bool {
            if let g = genericCache[i] { return g }
            let g = ArchiveNameAdvisor.isGenericStem(p.analyses[i].strippedStem) || p.analyses[i].key.count < 6
            genericCache[i] = g
            return g
        }

        /// Same normalized name + length within ±2 frames. Buckets sorted by
        /// length; a sliding window compares near lengths only.
        mutating func nameAndDuration() {
            let xs = self.xs
            for i in idx where xs[i].durationSeconds >= minDurationSeconds {
                let k = p.analyses[i].key
                if k.count >= 3 { byKey[k, default: []].append(i) }
            }
            for k in byKey.keys { byKey[k]?.sort { xs[$0].durationSeconds < xs[$1].durationSeconds } }
            for k in byKey.keys.sorted() {
                guard let m = byKey[k], m.count > 1 else { continue }
                for (pos, i) in m.enumerated() { window(m, from: pos, anchor: i) }
            }
        }

        private mutating func window(_ m: [Int], from pos: Int, anchor i: Int) {
            var partners = 0
            var q = pos + 1
            while q < m.count, partners < maxWindowPartners {
                let j = m[q]
                let delta = xs[j].durationSeconds - xs[i].durationSeconds
                if delta > FootageStem.maxDurationTolerance { break }
                if delta <= max(p.tolerance[i], p.tolerance[j]) {
                    let generic = isGeneric(i) || isGeneric(j)
                    add(j, i, generic ? .genericNameAndDuration : .nameAndDuration, frameDelta(i, j, p))
                    partners += 1
                }
                q += 1
            }
        }

        /// Same name but one trailing counter + same length → Possible.
        mutating func trailingCounters() {
            let xs = self.xs
            for i in idx where xs[i].durationSeconds >= minDurationSeconds {
                guard let base = p.analyses[i].counterBaseKey, let m = byKey[base] else { continue }
                let d = xs[i].durationSeconds
                var lo = 0, hi = m.count
                while lo < hi {  // first member with duration ≥ d − max tolerance
                    let mid = (lo + hi) / 2
                    if xs[m[mid]].durationSeconds < d - FootageStem.maxDurationTolerance { lo = mid + 1 } else { hi = mid }
                }
                var partners = 0
                var q = lo
                while q < m.count, partners < 8, xs[m[q]].durationSeconds <= d + FootageStem.maxDurationTolerance {
                    let j = m[q]
                    if j != i, lengthsMatch(i, j, p) {
                        add(i, j, .counterNameAndDuration, frameDelta(i, j, p))
                        partners += 1
                    }
                    q += 1
                }
            }
        }

        /// The person's "same footage" (read from both sides; deduped).
        mutating func personSaidSame() {
            var seen = Set<[Int]>()
            for i in idx {
                for d in xs[i].decisions where d.verdict == .same {
                    guard let j = p.indexByID[d.otherID], p.considered[j] else { continue }
                    if seen.insert([min(i, j), max(i, j)]).inserted { add(i, j, .personSaidSame) }
                }
            }
        }
    }

    // MARK: Phase 3 — components

    static func components(_ p: Prepared, edges: [Edge], options: Options, stats: inout Stats) -> Components {
        var uf = UnionFind(count: p.inputs.count, cap: options.cap)
        // Cannot-link lists (the person's "not the same"), both directions.
        for (i, x) in p.inputs.enumerated() where p.considered[i] {
            for d in x.decisions where d.verdict == .notSame {
                guard let j = p.indexByID[d.otherID], j != i else { continue }
                uf.forbidden[i, default: []].append(j)
                uf.forbidden[j, default: []].append(i)
            }
        }
        // Strongest first; stable within a tier.
        let order = edges.indices.sorted { l, r in
            let a = edges[l], b = edges[r]
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.reason != b.reason { return a.reason < b.reason }
            return a.a != b.a ? a.a < b.a : a.b < b.b
        }
        for k in order { uf.offer(edges[k], stats: &stats) }
        let root = (0..<p.inputs.count).map { uf.find($0) }
        return Components(root: root, size: uf.size, confidence: uf.confidence, acceptedByRoot: uf.accepted)
    }

    /// Disjoint-set forest with the three documented merge rules.
    struct UnionFind {
        var parent: [Int]
        var size: [Int]
        var possibleLeaf: [Bool]
        var confidence: [Int: FootageConfidence] = [:]
        var accepted: [Int: [Reason: Int]] = [:]
        var forbidden: [Int: [Int]] = [:]
        let cap: Int

        init(count: Int, cap: Int) {
            parent = Array(0..<count)
            size = [Int](repeating: 1, count: count)
            possibleLeaf = [Bool](repeating: false, count: count)
            self.cap = cap
        }

        mutating func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }

        /// Take the edge if the rules allow it.
        mutating func offer(_ e: Edge, stats: inout Stats) {
            var ra = find(e.a), rb = find(e.b)
            guard ra != rb else { return }
            // Rule 1 — the person's cannot-link wins over everything.
            if (forbidden[ra] ?? []).contains(where: { find($0) == rb }) {
                stats.refusedByPerson += 1
                return
            }
            // Rule 3 — Possible attaches a singleton leaf, never chains.
            var leaf: Int?
            if e.confidence == .possible {
                guard let l = possibleLeafEndpoint(e, ra: ra, rb: rb) else {
                    stats.refusedPossibleChain += 1
                    return
                }
                leaf = l
            }
            // Rule 2 — the cap (Identical exempt).
            if e.confidence != .identical, size[ra] + size[rb] > cap {
                stats.refusedByCap += 1
                return
            }
            if size[ra] < size[rb] { swap(&ra, &rb) }
            parent[rb] = ra
            size[ra] += size[rb]
            if let leaf { possibleLeaf[leaf] = true }
            confidence[ra] = [confidence[ra], confidence[rb], e.confidence].compactMap { $0 }.min() ?? e.confidence
            confidence[rb] = nil
            var acc = accepted[ra] ?? [:]
            for (r, c) in accepted[rb] ?? [:] { acc[r, default: 0] += c }
            acc[e.reason, default: 0] += 1
            accepted[ra] = acc
            accepted[rb] = nil
            stats.acceptedByReason[e.reason, default: 0] += 1
            if let fb = forbidden[rb] { forbidden[ra, default: []].append(contentsOf: fb); forbidden[rb] = nil }
        }

        /// The endpoint a Possible edge would attach as a leaf, or nil when
        /// the edge would chain (a leaf already hosts it, or neither side
        /// is a singleton).
        func possibleLeafEndpoint(_ e: Edge, ra: Int, rb: Int) -> Int? {
            if possibleLeaf[e.a] || possibleLeaf[e.b] { return nil }
            if size[rb] == 1 { return e.b }
            if size[ra] == 1 { return e.a }
            return nil
        }
    }

    // MARK: Phase 4 — ranking, roles, memberships

    static func assemble(_ p: Prepared, edges: [Edge], components c: Components,
                         now: Date, stats: Stats) -> Result {
        var stats = stats
        let xs = p.inputs
        var members: [Int: [Int]] = [:]
        for i in xs.indices where p.considered[i] { members[c.root[i], default: []].append(i) }

        // Reasons per member, from every edge inside its final group.
        var reasonLines: [Int: [String]] = [:]
        for e in edges where c.root[e.a] == c.root[e.b] && (members[c.root[e.a]]?.count ?? 0) > 1 {
            append(&reasonLines[e.a], text(e, side: .derived, other: xs[e.b].filename))
            append(&reasonLines[e.b], text(e, side: .source, other: xs[e.a].filename))
        }

        var memberships: [UUID: FootageMembership] = [:]
        var groups: [Group] = []
        for r in members.keys.sorted() {
            guard let m = members[r], m.count > 1 else { continue }
            let g = assembleGroup(m, p: p, confidence: c.confidence[r] ?? .likely,
                                  reasons: c.acceptedByRoot[r] ?? [:], reasonLines: reasonLines, now: now)
            for (id, mem) in g.memberships { memberships[id] = mem }
            groups.append(g.group)
            stats.groups += 1
            stats.members += m.count
            stats.groupsByConfidence[g.group.confidence, default: 0] += 1
            stats.largestGroup = max(stats.largestGroup, m.count)
            if !g.group.originalInCatalog { stats.originalNotInCatalog += 1 }
        }
        groups.sort { $0.memberIDs.count != $1.memberIDs.count ? $0.memberIDs.count > $1.memberIDs.count
                                                               : $0.id.uuidString < $1.id.uuidString }
        return Result(memberships: memberships, groups: groups, stats: stats)
    }

    /// One group: rank by originality, assign roles, write memberships.
    static func assembleGroup(_ m: [Int], p: Prepared, confidence conf: FootageConfidence,
                              reasons: [Reason: Int], reasonLines: [Int: [String]],
                              now: Date) -> (group: Group, memberships: [UUID: FootageMembership]) {
        let xs = p.inputs
        var verdicts: [Int: FootageOriginality.Verdict] = [:]
        for i in m { verdicts[i] = FootageOriginality.assess(xs[i], analysis: p.analyses[i]) }
        let none = FootageOriginality.Verdict(score: .min, reasons: [], cameraEvidence: false)
        let ranked = m.sorted {
            FootageOriginality.ranksBefore((verdicts[$0] ?? none, xs[$0]), (verdicts[$1] ?? none, xs[$1]))
        }
        let o = ranked[0]
        let oVerdict = verdicts[o] ?? none
        let groupID = m.map { xs[$0].id }.min { $0.uuidString < $1.uuidString } ?? xs[o].id

        // Roles; byte-identical members share the most specific one.
        var roles: [Int: FootageRole] = [:]
        for i in m {
            roles[i] = i == o ? .original : FootageOriginality.role(
                of: xs[i], analysis: p.analyses[i], verdict: verdicts[i] ?? none,
                original: xs[o], originalVerdict: oVerdict, identicalToOriginal: xs[i].sameBytes(as: xs[o]))
        }
        var byIdentity: [String: [Int]] = [:]
        for i in m where i != o && roles[i] != .copy && !xs[i].identityKey.isEmpty {
            byIdentity[xs[i].identityKey, default: []].append(i)
        }
        for (_, same) in byIdentity where same.count > 1 {
            let best = same.compactMap { roles[$0] }.min { rolePriority($0) < rolePriority($1) } ?? .related
            for i in same { roles[i] = best }
        }

        // "Original not in catalog" is claimed only when the best member
        // looks like an EXPORT (no camera tags, and a delivery codec, a
        // transcoder's tag or an editor's folder) — the guitar case. A
        // group of untagged byte copies makes no claim either way.
        let originalInCatalog = !FootageOriginality.looksLikeExport(xs[o], verdict: oVerdict)
        var memberships: [UUID: FootageMembership] = [:]
        for (rank, i) in ranked.enumerated() {
            var ev: [String] = []
            if i == o {
                ev.append(originalInCatalog
                          ? "likely original" + (oVerdict.reasons.isEmpty ? "" : " — " + oVerdict.reasons.prefix(2).joined(separator: ", "))
                          : "best available — an export with no camera tags; the camera original is probably not in the catalog")
            }
            for line in reasonLines[i] ?? [] where ev.count < maxReasons && !ev.contains(line) { ev.append(line) }
            memberships[xs[i].id] = FootageMembership(
                groupID: groupID, groupSize: m.count, confidence: conf, role: roles[i] ?? .related,
                rank: rank, likelyOriginalID: xs[o].id, originalInCatalog: originalInCatalog,
                evidence: ev, scannedAt: now, algorithmVersion: algorithmVersion)
        }
        let group = Group(id: groupID, memberIDs: ranked.map { xs[$0].id }, confidence: conf,
                          originalInCatalog: originalInCatalog, reasons: reasons)
        return (group, memberships)
    }

    // MARK: Helpers

    /// "<event dir>|<stem>" for a file inside `folder` of an FCP library.
    static func fcpKey(_ path: String, folder: String) -> String? {
        let lower = path.lowercased()
        guard lower.contains(".fcpbundle/"), let r = lower.range(of: folder) else { return nil }
        let event = String(lower[..<r.lowerBound])
        let stem = ((lower as NSString).lastPathComponent as NSString).deletingPathExtension
        return stem.isEmpty ? nil : event + "|" + stem
    }

    static func folderKey(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent.lowercased()
    }

    static func lengthsMatch(_ i: Int, _ j: Int, _ p: Prepared) -> Bool {
        let a = p.inputs[i].durationSeconds, b = p.inputs[j].durationSeconds
        guard a >= minDurationSeconds, b >= minDurationSeconds else { return false }
        return abs(a - b) <= max(p.tolerance[i], p.tolerance[j])
    }

    /// "Δ0 frames" / "Δ1 frame" at the first record's rate (29.97 fallback).
    static func frameDelta(_ i: Int, _ j: Int, _ p: Prepared) -> String {
        let fps = FootageStem.framesPerSecond(p.inputs[i].frameRate).flatMap { $0 >= 10 && $0 <= 121 ? $0 : nil } ?? 29.97
        let frames = Int((abs(p.inputs[i].durationSeconds - p.inputs[j].durationSeconds) * fps).rounded())
        return "Δ\(frames) frame\(frames == 1 ? "" : "s")"
    }

    /// Lower = more specific (wins when byte copies disagree).
    static func rolePriority(_ r: FootageRole) -> Int {
        switch r {
        case .transcode: return 0
        case .restored: return 1
        case .trim: return 2
        case .reEncode: return 3
        case .export: return 4
        case .avHalf: return 5
        case .copy: return 6
        case .related: return 7
        case .original: return 8
        }
    }

    enum Side { case derived, source }

    /// The reason line as `side`'s record would read it.
    static func text(_ e: Edge, side: Side, other: String) -> String {
        let detail = e.detail.isEmpty ? "" : " (\(e.detail))"
        switch e.reason {
        case .personSaidSame: return "you said: same footage as \(other)"
        case .sameContentHash: return "same bytes as \(other)"
        case .sameFixity: return "same bytes (whole-file SHA-256) as \(other)"
        case .sampledSignature: return "same sampled signature + size as \(other) (not yet verified)"
        case .lineage:
            return side == .derived ? "made from \(other)\(detail)" : "\(other) was made from it\(detail)"
        case .combinedFromPair:
            return side == .derived ? "combined from the A/V pair with \(other)" : "\(other) was combined from it"
        case .avPairHigh, .avPairWeak: return "A/V pair with \(other)\(detail)"
        case .materialPackage: return "same Avid material package as \(other)"
        case .fcpMediaIdentifier: return "same Final Cut media identifier as \(other)"
        case .fcpOriginalTranscoded:
            return side == .derived ? "Final Cut transcode of \(other)" : "\(other) is its Final Cut transcode"
        case .promoteCollision:
            return side == .derived ? "second copy of \(other) in the same folder" : "\(other) is a second copy of it"
        case .nameAndDuration: return "same name + length as \(other)\(detail)"
        case .genericNameAndDuration: return "same camera-counter name + length as \(other)\(detail)"
        case .counterNameAndDuration: return "same name but a trailing number, same length as \(other)\(detail)"
        }
    }

    private static func append(_ lines: inout [String]?, _ line: String) {
        var l = lines ?? []
        if l.count < maxReasons * 2, !l.contains(line) { l.append(line) }
        lines = l
    }
}
