// TreeWalkGraph.swift (VideoScanCore)
// The graph algorithms under the tree walk, over integer ordinals only:
//   • Tarjan's strongly-connected components — ITERATIVE (an explicit
//     call stack of (node, next-edge) frames, like hand-lowering the
//     recursion in C), so a 10,000-generation corrupt chain cannot overflow
//     the thread stack.
//   • breadth-first generations from a start person, depth-limited.
//   • bottom-k (KMV) sketches over the condensation for distinct counts.
// Pure functions; no allocation per edge.

import Foundation

enum TreeWalkGraph {

    // MARK: - Tarjan SCC

    struct Components {
        /// ordinal → component number (−1 = excluded).
        let component: [Int32]
        /// Components in Tarjan EMISSION order: a component is emitted only
        /// after every component reachable from it. Over child → parent
        /// edges that is ANCESTORS FIRST (the synthesized order); reversed
        /// it is children first (the inherited order).
        let members: [[Int32]]
        /// A component with > 1 member, or one member who is their own
        /// parent — a cycle.
        let cyclic: [Bool]
    }

    static func stronglyConnected(count n: Int,
                                  include: (Int) -> Bool,
                                  successors: (Int) -> ArraySlice<Int32>) -> Components {
        var index = [Int32](repeating: -1, count: n)
        var low = [Int32](repeating: 0, count: n)
        var onStack = [Bool](repeating: false, count: n)
        var component = [Int32](repeating: -1, count: n)
        var stack: [Int32] = []
        var members: [[Int32]] = []
        var cyclic: [Bool] = []
        // One frame per "recursive call": the node and how far through its
        // successor list we are.
        var frames: [(node: Int32, edge: Int)] = []
        var counter: Int32 = 0

        func push(_ v: Int32) {
            index[Int(v)] = counter
            low[Int(v)] = counter
            counter += 1
            stack.append(v)
            onStack[Int(v)] = true
            frames.append((v, 0))
        }

        for root in 0..<n where include(root) && index[root] == -1 {
            push(Int32(root))
            while let top = frames.last {
                let v = Int(top.node)
                let succ = successors(v)
                var e = top.edge
                var descended = false
                while e < succ.count {
                    let w = Int(succ[succ.startIndex + e])
                    e += 1
                    guard include(w) else { continue }
                    if index[w] == -1 {
                        frames[frames.count - 1].edge = e
                        push(Int32(w))
                        descended = true
                        break
                    } else if onStack[w] {
                        low[v] = min(low[v], index[w])
                    }
                }
                if descended { continue }
                frames.removeLast()
                if let parent = frames.last {
                    low[Int(parent.node)] = min(low[Int(parent.node)], low[v])
                }
                if low[v] == index[v] {
                    var group: [Int32] = []
                    while true {
                        let w = stack.removeLast()
                        onStack[Int(w)] = false
                        component[Int(w)] = Int32(members.count)
                        group.append(w)
                        if Int(w) == v { break }
                    }
                    group.sort()
                    let isCycle = group.count > 1 || successors(v).contains(Int32(v))
                    members.append(group)
                    cyclic.append(isCycle)
                }
            }
        }
        return Components(component: component, members: members, cyclic: cyclic)
    }

    // MARK: - Breadth-first generations

    /// ordinal → generations above `start` along the shortest child→parent
    /// path (0 = start), −1 = not reached within `maxGenerations`.
    static func generations(from start: Int, maxGenerations: Int?,
                            snapshot s: TreeWalkSnapshot) -> [Int32] {
        var gen = [Int32](repeating: -1, count: s.count)
        gen[start] = 0
        var frontier: [Int32] = [Int32(start)]
        var g: Int32 = 0
        while !frontier.isEmpty {
            if let maxGenerations, Int(g) >= maxGenerations { break }
            g += 1
            var next: [Int32] = []
            for v in frontier {
                for p in s.parents(of: Int(v)) where gen[Int(p)] == -1 {
                    gen[Int(p)] = g
                    next.append(p)
                }
            }
            frontier = next
        }
        return gen
    }

    // MARK: - Bottom-k sketches (distinct counts over a DAG)

    /// splitmix64's finaliser: a bijection on UInt64, so distinct ordinals
    /// get distinct, uniformly spread keys. The LOW BIT is replaced by the
    /// person's "dated" flag, so a sketch sample can say what share of the
    /// set has a birth year without a second lookup.
    @inline(__always) static func key(_ o: Int, dated: Bool) -> UInt64 {
        var z = UInt64(truncatingIfNeeded: o) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (z & ~1) | (dated ? 1 : 0)
    }

    struct SetCounts {
        /// Distinct size of each person's set (exact when ≤ k).
        let counts: [TreeWalk.Count]
        /// Share of the set that is dated; nil for an empty set.
        let datedFraction: [Double?]
        let estimated: Int
    }

    /// For every included person, the set of people reachable along
    /// `neighbours` (excluding themself unless in a cycle), processed in
    /// `order` (components whose neighbours are all already done).
    ///
    /// Memory: n × k × 8 bytes for the sketches (39k × 64 → 20 MB; 100k →
    /// 51 MB), released on return. Time: O(edges × k).
    static func reachableSetCounts(snapshot s: TreeWalkSnapshot,
                                   components c: Components,
                                   order: [Int],
                                   k: Int,
                                   dated: [Bool],
                                   neighbours: (Int) -> ArraySlice<Int32>) -> SetCounts {
        let n = s.count
        var counts = [TreeWalk.Count](repeating: TreeWalk.Count(value: 0, isEstimate: false), count: n)
        var fraction = [Double?](repeating: nil, count: n)
        var estimated = 0
        // Raw buffers (C arrays): this is the hot loop of the whole walk,
        // O(edges × k), and Swift's checked Array access costs ~5× in Debug.
        let sketch = UnsafeMutablePointer<UInt64>.allocate(capacity: max(1, n * k))
        let length = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, n))
        length.initialize(repeating: 0, count: max(1, n))
        let acc = UnsafeMutablePointer<UInt64>.allocate(capacity: k)
        let tmp = UnsafeMutablePointer<UInt64>.allocate(capacity: k)
        defer {
            sketch.deallocate(); length.deallocate(); acc.deallocate(); tmp.deallocate()
        }
        let keys = UnsafeMutablePointer<UInt64>.allocate(capacity: max(1, n))
        defer { keys.deallocate() }
        for o in 0..<n { keys[o] = key(o, dated: dated[o]) }

        /// acc ∪ src (sorted ascending, unique), truncated to k — a two-
        /// pointer merge like std::set_union stopped at k outputs.
        func merge(_ accLen: Int, _ src: UnsafePointer<UInt64>, _ srcLen: Int) -> Int {
            if srcLen == 0 { return accLen }
            // Fast path: a full sketch whose largest key is below every
            // incoming key cannot change.
            if accLen == k, src[0] > acc[k - 1] { return accLen }
            var i = 0, j = 0, out = 0
            while out < k, i < accLen || j < srcLen {
                let x: UInt64
                if j >= srcLen || (i < accLen && acc[i] <= src[j]) {
                    x = acc[i]
                    if j < srcLen, src[j] == x { j += 1 }
                    i += 1
                } else {
                    x = src[j]
                    j += 1
                }
                if out == 0 || tmp[out - 1] != x { tmp[out] = x; out += 1 }
            }
            acc.update(from: tmp, count: out)
            return out
        }
        /// Insert one key (binary search + shift); O(k).
        func insert(_ accLen: Int, _ x: UInt64) -> Int {
            if accLen == k, x > acc[k - 1] { return accLen }
            var lo = 0, hi = accLen
            while lo < hi { let mid = (lo + hi) >> 1; if acc[mid] < x { lo = mid + 1 } else { hi = mid } }
            if lo < accLen, acc[lo] == x { return accLen }
            let newLen = min(k, accLen + 1)
            var t = newLen - 1
            while t > lo { acc[t] = acc[t - 1]; t -= 1 }
            if lo < newLen { acc[lo] = x }
            return newLen
        }

        for comp in order {
            let group = c.members[comp]
            var accLen = 0
            for m in group {
                for w in neighbours(Int(m)) {
                    let wi = Int(w)
                    let wc = c.component[wi]
                    guard wc >= 0, wc != Int32(comp) else { continue }
                    accLen = merge(accLen, UnsafePointer(sketch + wi * k), Int(length[wi]))
                    accLen = insert(accLen, keys[wi])
                }
            }
            let isCycle = c.cyclic[comp]
            if isCycle {
                // Every member is every member's ancestor (and descendant).
                for m in group { accLen = insert(accLen, keys[Int(m)]) }
            }
            let exact = accLen < k
            var datedInSample = 0
            for t in 0..<accLen where acc[t] & 1 == 1 { datedInSample += 1 }
            let value: Int
            if exact {
                value = max(0, accLen - (isCycle ? 1 : 0))
            } else {
                let kth = Double(acc[k - 1]) / 18_446_744_073_709_551_616.0
                value = kth > 0 ? Int((Double(k - 1) / kth).rounded()) : accLen
                estimated += group.count
            }
            let share: Double? = accLen == 0 ? nil : Double(datedInSample) / Double(accLen)
            for m in group {
                let mi = Int(m)
                (sketch + mi * k).update(from: acc, count: accLen)
                length[mi] = Int32(accLen)
                counts[mi] = TreeWalk.Count(value: value, isEstimate: !exact)
                fraction[mi] = share
            }
        }
        return SetCounts(counts: counts, datedFraction: fraction, estimated: estimated)
    }
}
