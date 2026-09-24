// FootageNameWindow.swift
// Find Similar Footage — the NAME rules of FootageGrouping's evidence phase
// (same name + length; same name but a trailing counter) and the date key
// they compare with. Split out of FootageGrouping.swift (file-length lint)
// by codex #1674: the window is bounded by candidates EXAMINED (F5), split
// by concrete year, and polls Task.isCancelled; `DateKey` lets the window
// and the union-find's per-group date sets (F2) compare dates without
// splitting strings in their inner loops.

import Foundation

extension FootageGrouping {

    /// A filename date prefix ("1990-12-25", "1990-xx-xx", "xxxx-12") as
    /// three integer parts, -1 = unknown ("xx", "xxxx", absent). Exactly
    /// `ArchiveItemVersions.datesCompatible`, without splitting strings in
    /// the inner loops (sensor: Footage1674DateKeyTests). A part that
    /// mixes digits and x ("1x") only equals itself, as a string would.
    struct DateKey: Sendable, Hashable {
        /// Year, month, day codes; -1 = unknown.
        var y: Int32, m: Int32, d: Int32

        static let unknown = DateKey(y: -1, m: -1, d: -1)

        init(y: Int32, m: Int32, d: Int32) { self.y = y; self.m = m; self.d = d }

        init(_ prefix: String?) {
            guard let prefix else { self = .unknown; return }
            var out: [Int32] = [-1, -1, -1]
            for (k, comp) in prefix.split(separator: "-").prefix(3).enumerated() {
                if comp.allSatisfy({ $0 == "x" }) { continue }
                // Base 11 (x = 10): unique per fixed-width part.
                var v: Int32 = 0
                for ch in comp.utf8 {
                    let digit: Int32 = ch >= 48 && ch <= 57 ? Int32(ch - 48) : 10
                    v = v &* 11 &+ digit
                }
                out[k] = v
            }
            self.init(y: out[0], m: out[1], d: out[2])
        }

        var year: Int32 { y }
        var isUnknown: Bool { y < 0 && m < 0 && d < 0 }

        func compatible(with o: DateKey) -> Bool {
            (y < 0 || o.y < 0 || y == o.y) && (m < 0 || o.m < 0 || m == o.m) && (d < 0 || o.d < 0 || d == o.d)
        }

        /// Order used to put equal dates next to each other in a window.
        func precedes(_ o: DateKey) -> Bool {
            y != o.y ? y < o.y : m != o.m ? m < o.m : d < o.d
        }
    }
}

extension FootageGrouping.EdgeBuilder {

    /// Same normalized name + length within ±2 frames. Buckets sorted by
    /// length (then date, so equal dates sit together); a sliding
    /// window compares near lengths only. Bounded by what it EXAMINES,
    /// not what it accepts (codex #1674 F5), and split by year first
    /// when a bucket holds several concrete years — "1990-… X" and
    /// "1994-… X" are never compared at all.
    mutating func nameAndDuration() {
        let xs = self.xs
        let dk = p.dateKeys
        for i in idx where xs[i].durationSeconds >= FootageGrouping.minDurationSeconds {
            let k = p.analyses[i].key
            if k.count >= 3 { byKey[k, default: []].append(i) }
        }
        for k in byKey.keys {
            byKey[k]?.sort { a, b in
                xs[a].durationSeconds != xs[b].durationSeconds
                    ? xs[a].durationSeconds < xs[b].durationSeconds : dk[a].precedes(dk[b])
            }
        }
        var sincePoll = 0
        for k in byKey.keys.sorted() {
            guard let m = byKey[k], m.count > 1 else { continue }
            sincePoll += m.count
            if sincePoll >= FootageGrouping.cancelPollStride {
                sincePoll = 0
                if Task.isCancelled { cancelled = true; return }
            }
            for part in yearPartitions(m) {
                for pos in part.list.indices { window(part.list, from: pos, year: part.year) }
            }
        }
    }

    /// One list per concrete year (its members + the year-less ones),
    /// plus the year-less ones alone; or the whole bucket when it has
    /// at most one concrete year, or when re-walking the year-less
    /// members per year would cost more than the split saves.
    func yearPartitions(_ m: [Int]) -> [(list: [Int], year: Int32?)] {
        let dk = p.dateKeys
        var byYear: [Int32: [Int]] = [:]
        var yearless: [Int] = []
        for i in m {
            let y = dk[i].year
            if y < 0 { yearless.append(i) } else { byYear[y, default: []].append(i) }
        }
        guard byYear.count > 1, byYear.count * yearless.count <= 4 * m.count else { return [(m, nil)] }
        var out: [(list: [Int], year: Int32?)] = []
        for y in byYear.keys.sorted() {
            out.append((merged(byYear[y] ?? [], yearless), y))
        }
        if yearless.count > 1 { out.append((yearless, nil)) }
        return out
    }

    /// Merge two lists already in window order.
    func merged(_ a: [Int], _ b: [Int]) -> [Int] {
        let xs = self.xs, dk = p.dateKeys
        var out: [Int] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j >= b.count { out.append(a[i]); i += 1; continue }
            if i >= a.count { out.append(b[j]); j += 1; continue }
            let x = a[i], y = b[j]
            let xFirst = xs[x].durationSeconds != xs[y].durationSeconds
                ? xs[x].durationSeconds < xs[y].durationSeconds : !dk[y].precedes(dk[x])
            if xFirst { out.append(x); i += 1 } else { out.append(y); j += 1 }
        }
        return out
    }

    /// `year` set: this is that year's list — a pair of two year-less
    /// members belongs to the year-less list, not here.
    mutating func window(_ m: [Int], from pos: Int, year: Int32?) {
        let i = m[pos]
        let dk = p.dateKeys
        var partners = 0, examined = 0
        var q = pos + 1
        while q < m.count, partners < FootageGrouping.maxWindowPartners, examined < FootageGrouping.maxWindowExamined {
            let j = m[q]
            q += 1
            let delta = xs[j].durationSeconds - xs[i].durationSeconds
            if delta > FootageStem.maxDurationTolerance { break }
            examined += 1
            if let year, dk[i].year != year, dk[j].year != year { continue }
            if delta <= max(p.tolerance[i], p.tolerance[j]), dk[i].compatible(with: dk[j]) {
                let generic = isGeneric(i) || isGeneric(j)
                add(j, i, generic ? .genericNameAndDuration : .nameAndDuration, FootageGrouping.frameDelta(i, j, p))
                partners += 1
            }
        }
        windowExamined += examined
    }

    /// Same name but one trailing counter + same length → Possible.
    /// Bounded by candidates examined as well as linked (F5's pattern).
    mutating func trailingCounters() {
        let xs = self.xs
        let dk = p.dateKeys
        var sincePoll = 0
        for i in idx where xs[i].durationSeconds >= FootageGrouping.minDurationSeconds {
            guard let base = p.analyses[i].counterBaseKey, let m = byKey[base] else { continue }
            sincePoll += 1
            if sincePoll >= FootageGrouping.cancelPollStride {
                sincePoll = 0
                if Task.isCancelled { cancelled = true; return }
            }
            let d = xs[i].durationSeconds
            var lo = 0, hi = m.count
            while lo < hi {  // first member with duration ≥ d − max tolerance
                let mid = (lo + hi) / 2
                if xs[m[mid]].durationSeconds < d - FootageStem.maxDurationTolerance { lo = mid + 1 } else { hi = mid }
            }
            var partners = 0, examined = 0
            var q = lo
            while q < m.count, partners < FootageGrouping.maxCounterPartners, examined < FootageGrouping.maxCounterExamined,
                  xs[m[q]].durationSeconds <= d + FootageStem.maxDurationTolerance {
                let j = m[q]
                q += 1
                examined += 1
                if j != i, FootageGrouping.lengthsMatch(i, j, p), dk[i].compatible(with: dk[j]) {
                    add(i, j, .counterNameAndDuration, FootageGrouping.frameDelta(i, j, p))
                    partners += 1
                }
            }
        }
    }
}
