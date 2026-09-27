// TreeWalkSnapshot.swift (VideoScanCore)
// The frozen, flat input of the tree walk: one row per person ordinal (the
// compiled index's id order), CSR adjacency, and the LOCAL attributes
// (dates, region, child count) computed once in parallel.
//
// Why a snapshot: every later pass is a loop over integers. No `Person`
// struct is copied and no dictionary is hashed after this is built, and the
// checks can run on many threads over data nothing mutates.
//
// Edges: `parents` is the compiled parent topology (fathers then mothers —
// the primary parent family under Rick's identity rulings). `kids` is its
// exact INVERSE, built here, so walking up and walking down follow the same
// edges (the index's own `children` list comes from every FAMS family and
// can include a child whose primary parents are elsewhere). Hidden records
// (identity rulings) have no edges and are left out of every count.
//
// Memory (39k people): ~60 bytes of columns per person plus the strings the
// graph already holds (shared, copy-on-write) — a few MB. 100k: ~8 MB.

import CryptoKit
import Foundation

struct TreeWalkSnapshot: Sendable {
    let count: Int
    let ids: [String]
    let names: [String]
    /// "M" / "F" / "".
    let sex: [String]
    let visible: [Bool]
    let birth: [TreeWalkDate?]
    let death: [TreeWalkDate?]
    let birthPlaceRecorded: [Bool]
    let region: [BirthplaceClassifier.BirthRegion]
    /// Recorded children (every FAMS family) — the fact on the card.
    let childCount: [Int32]
    // CSR, child → parents (fathers first; motherOffset marks the split).
    let parentStart: [Int32]
    let parents: [Int32]
    let motherOffset: [Int32]
    // CSR, parent → children: the inverse of `parents`.
    let kidStart: [Int32]
    let kids: [Int32]
    // CSR, spouses.
    let spouseStart: [Int32]
    let spouses: [Int32]

    @inline(__always) func parents(of o: Int) -> ArraySlice<Int32> {
        parents[Int(parentStart[o])..<Int(parentStart[o + 1])]
    }
    @inline(__always) func fathers(of o: Int) -> ArraySlice<Int32> {
        parents[Int(parentStart[o])..<Int(motherOffset[o])]
    }
    @inline(__always) func mothers(of o: Int) -> ArraySlice<Int32> {
        parents[Int(motherOffset[o])..<Int(parentStart[o + 1])]
    }
    @inline(__always) func kids(of o: Int) -> ArraySlice<Int32> {
        kids[Int(kidStart[o])..<Int(kidStart[o + 1])]
    }
    @inline(__always) func spouses(of o: Int) -> ArraySlice<Int32> {
        spouses[Int(spouseStart[o])..<Int(spouseStart[o + 1])]
    }

    func ordinal(of id: String) -> Int? {
        var lo = 0, hi = ids.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if ids[mid] < id { lo = mid + 1 } else { hi = mid }
        }
        return lo < ids.count && ids[lo] == id ? lo : nil
    }

    init(graph: GedcomFamilyGraph) {
        let index = graph.index
        let n = index.count
        count = n
        ids = index.ids
        let people = graph.people
        let suppressed = graph.suppressedPersonIDs
        let idList = index.ids
        // Local facts, in parallel: date parsing and place classification
        // are the only per-person string work in the whole walk.
        struct Local {
            var name = ""
            var sex = ""
            var visible = false
            var birth: TreeWalkDate?
            var death: TreeWalkDate?
            var placeRecorded = false
            var region: BirthplaceClassifier.BirthRegion = .unknown
        }
        let locals: [Local] = TreeWalkParallel.map(count: n) { o in
            guard let p = people[idList[o]] else { return Local() }
            var l = Local()
            l.name = p.name
            l.sex = p.sex.uppercased()
            l.visible = !suppressed.contains(p.id)
            l.birth = TreeWalkDate.parse(p.birthDate)
            l.death = TreeWalkDate.parse(p.deathDate)
            l.placeRecorded = !(p.birthPlace?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            l.region = BirthplaceClassifier.region(p.birthPlace)
            return l
        }
        names = locals.map(\.name)
        sex = locals.map(\.sex)
        let vis = locals.map(\.visible)
        visible = vis
        birth = locals.map(\.birth)
        death = locals.map(\.death)
        birthPlaceRecorded = locals.map(\.placeRecorded)
        region = locals.map(\.region)

        // Topology copied from the index, minus edges touching a hidden record.
        var pStart: [Int32] = [0], pList: [Int32] = [], mOff: [Int32] = []
        var sStart: [Int32] = [0], sList: [Int32] = []
        var cCount: [Int32] = []
        pStart.reserveCapacity(n + 1); mOff.reserveCapacity(n); sStart.reserveCapacity(n + 1)
        cCount.reserveCapacity(n)
        pList.reserveCapacity(index.parents.count)
        sList.reserveCapacity(index.spouses.count)
        for o in 0..<n {
            let oo = Int32(o)
            if vis[o] {
                for p in index.fathers(of: oo) where vis[Int(p)] { pList.append(p) }
                mOff.append(Int32(pList.count))
                for p in index.mothers(of: oo) where vis[Int(p)] { pList.append(p) }
                for s in index.spouses(of: oo) where vis[Int(s)] { sList.append(s) }
                cCount.append(Int32(index.children(of: oo).filter { vis[Int($0)] }.count))
            } else {
                mOff.append(Int32(pList.count))
                cCount.append(0)
            }
            pStart.append(Int32(pList.count))
            sStart.append(Int32(sList.count))
        }
        parentStart = pStart; parents = pList; motherOffset = mOff
        spouseStart = sStart; spouses = sList
        childCount = cCount

        // Inverse (counting sort): kids of p in ascending child ordinal.
        var degree = [Int32](repeating: 0, count: n + 1)
        for p in pList { degree[Int(p) + 1] += 1 }
        for i in 0..<n { degree[i + 1] += degree[i] }
        var fill = degree
        var kList = [Int32](repeating: 0, count: pList.count)
        for c in 0..<n {
            // A child listed twice under one parent (father == mother
            // pointer in a corrupt FAM) keeps both edges, like `parents`.
            for p in pList[Int(pStart[c])..<Int(pStart[c + 1])] {
                kList[Int(fill[Int(p)])] = Int32(c)
                fill[Int(p)] += 1
            }
        }
        kidStart = degree; kids = kList
    }

    /// SHA-256 over everything the walker READS: ids, names, sex, raw
    /// dates and places, the edges and who is hidden. A tree whose facts
    /// or rulings change gets a new key, so its stored decorations are
    /// stale. O(people); ~tens of ms on 39k.
    static func sourceKey(graph: GedcomFamilyGraph) -> String {
        let index = graph.index
        var hasher = SHA256()
        func feed(_ s: String?) {
            var bytes = Array((s ?? "\u{1}").utf8)
            bytes.append(0)
            hasher.update(data: bytes)
        }
        func feedList(_ xs: ArraySlice<Int32>) {
            var buf = [Int32](xs)
            buf.append(-1)
            buf.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        feed("walker-source-v1")
        for (o, id) in index.ids.enumerated() {
            let p = graph.people[id]
            feed(id)
            feed(p?.name); feed(p?.sex); feed(p?.birthDate); feed(p?.deathDate); feed(p?.birthPlace)
            feed(graph.suppressedPersonIDs.contains(id) ? "H" : "V")
            let oo = Int32(o)
            feedList(index.fathers(of: oo)); feedList(index.mothers(of: oo)); feedList(index.spouses(of: oo))
            feedList(index.children(of: oo))
        }
        for root in graph.rootPersonIDs { feed(root) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Parallel helpers over ordinals. `DispatchQueue.concurrentPerform` ≈ a
/// C++ parallel-for over a thread pool; every slot is written by exactly one
/// iteration, so no lock is needed.
enum TreeWalkParallel {
    static func map<T>(count n: Int, chunk: Int = 1024, _ body: (Int) -> T) -> [T] {
        guard n > 0 else { return [] }
        // `nonisolated(unsafe)` ≈ "I promise the threads never touch the
        // same slot": each iteration writes only its own range, and `body`
        // only reads the frozen snapshot.
        return withoutActuallyEscaping(body) { escapable in
            nonisolated(unsafe) let work = escapable
            return [T](unsafeUninitializedCapacity: n) { buffer, initialized in
                guard let start = buffer.baseAddress else { initialized = 0; return }
                nonisolated(unsafe) let base = start
                let chunks = (n + chunk - 1) / chunk
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = c * chunk, hi = min(n, lo + chunk)
                    for i in lo..<hi { (base + i).initialize(to: work(i)) }
                }
                initialized = n
            }
        }
    }

    /// Per-chunk results, in chunk order (so the concatenation is
    /// deterministic whatever the thread schedule).
    static func chunks<T>(count n: Int, chunk: Int = 1024, _ body: (Range<Int>) -> T) -> [T] {
        guard n > 0 else { return [] }
        let k = (n + chunk - 1) / chunk
        return map(count: k, chunk: 1) { c in body((c * chunk)..<min(n, c * chunk + chunk)) }
    }
}
