// SignatureConcurrencyPlan.swift
// How file-signature work is spread across volumes and threads.
//
// Rick's standing motto is "we like to melt silicon", and the signature
// pass is I/O-bound by construction (three seeks and 3 MiB per file, so
// the SHA-256 itself is ~1% of the wall clock). The lever is therefore
// not a faster hash but MORE CONCURRENT SEEKS — with one crucial caveat:
//
//     CONCURRENCY IS NOT UNIFORMLY GOOD.
//
// On an SSD, eight concurrent readers finish roughly eight times sooner.
// On a single spinning platter they finish SLOWER than one, because the
// head thrashes between requests that would otherwise have been serviced
// in order. So parallelism is decided per volume, from the hardware the
// volume actually is. Rick's fleet contains both — Crucial SSDs and the
// LaCie — and tomorrow a SanDisk PRO-G40 three to four times quicker
// than the Crucials, so this has to be a policy, not a constant.
//
// WHY PARTITIONING IS ITS OWN PURE TYPE. The concurrency bugs that
// matter here are not races — no worker shares mutable state — but
// PARTITION bugs: a file hashed twice (wasted I/O), or worse, a file
// silently dropped so its record never gets a signature and quietly
// fails to participate in duplicate detection later. Both are invisible
// at runtime and provable in a unit test, so the split lives here as a
// pure function over value types and the execution layer just runs what
// it is handed.
//
// Lanes are DISJOINT by construction: each lane owns a stride of its
// volume's items and no two lanes ever touch the same file. That is what
// removes the need for a shared cursor, a lock, or an actor in the hot
// path.

import Foundation

/// One file to sign. Value type — this is all that crosses an actor
/// boundary. `VideoRecord` is a main-actor reference type and never
/// leaves it (see [[project_approachable_concurrency_trap]]).
struct SignatureWorkItem: Sendable, Equatable, Hashable {
    let id: UUID
    let path: String
}

enum SignatureConcurrency {

    /// Ceiling on simultaneous readers across the whole fleet.
    ///
    /// Melting silicon is the goal; melting the I/O scheduler is not. A
    /// dozen volumes at eight lanes each would put 96 concurrent reads
    /// in flight, at which point queueing dominates and everything —
    /// including the UI's own disk access — gets slower.
    static let totalLaneCap = 24

    /// Minimum per volume. Rick: "at least 1-2 threads per volume, so if
    /// media is spread over 4 volumes we'd have minimally 4 threads."
    /// Guaranteed even when the cap is biting.
    static let minimumLanesPerVolume = 1

    /// Concurrent readers for one volume, from what the hardware is.
    ///
    /// The HDD case is the load-bearing one and the reason this is not
    /// just "use all the cores": one spindle serves one request at a
    /// time, and interleaving two streams makes the head seek between
    /// them. Serial is genuinely faster there.
    static func lanes(for tech: VolumeMediaTech) -> Int {
        switch tech {
        case .hdd:              return 1   // one head — parallelism thrashes it
        case .ssd:              return 6   // no seek penalty; queue depth is free
        case .raid0, .raid10:   return 8   // striped across spindles — feed them all
        case .raid1, .raid5:    return 4   // redundant, still multi-spindle
        case .network:          return 3   // latency-bound; concurrency hides RTT
        case .cloud:            return 4   // same reasoning, longer RTT
        case .unknown:          return 2   // Rick's floor: never assume serial
        }
    }

    /// Split work into disjoint lanes, at most `lanesFor(volume)` per
    /// volume and `totalLaneCap` overall.
    ///
    /// Deterministic: volumes are processed in sorted order and items
    /// keep their input order within a lane, so the same input always
    /// yields the same plan. That is what makes a failure reproducible.
    static func partition(
        items: [SignatureWorkItem],
        volumeOf: (String) -> String,
        lanesFor: (String) -> Int,
        totalCap: Int = totalLaneCap
    ) -> [[SignatureWorkItem]] {
        guard !items.isEmpty else { return [] }

        var byVolume: [String: [SignatureWorkItem]] = [:]
        for item in items {
            byVolume[volumeOf(item.path), default: []].append(item)
        }
        let volumes = byVolume.keys.sorted()

        // Desired lanes per volume, floored at the minimum and never
        // more lanes than the volume has files (an empty lane is a task
        // that does nothing but cost a context switch).
        var desired: [String: Int] = [:]
        for volume in volumes {
            let count = byVolume[volume]?.count ?? 0
            desired[volume] = max(minimumLanesPerVolume,
                                  min(lanesFor(volume), max(count, 1)))
        }

        // Enforce the fleet cap by trimming the greediest volumes first,
        // never below the per-volume minimum. Trimming the largest
        // allocation each round keeps the distribution even instead of
        // starving whichever volume happens to sort last.
        var total = desired.values.reduce(0, +)
        let floor = volumes.count * minimumLanesPerVolume
        if total > totalCap && totalCap >= floor {
            while total > totalCap {
                guard let greediest = volumes
                    .filter({ (desired[$0] ?? 0) > minimumLanesPerVolume })
                    .max(by: { (desired[$0] ?? 0, $1) < (desired[$1] ?? 0, $0) })
                else { break }
                desired[greediest] = (desired[greediest] ?? 1) - 1
                total -= 1
            }
        }

        // Round-robin each volume's items across its lanes. Stride
        // assignment makes lanes disjoint WITHOUT a shared cursor — the
        // reason no lock or actor is needed while hashing.
        var out: [[SignatureWorkItem]] = []
        for volume in volumes {
            let items = byVolume[volume] ?? []
            let laneCount = max(1, desired[volume] ?? 1)
            var lanes = Array(repeating: [SignatureWorkItem](), count: laneCount)
            for (index, item) in items.enumerated() {
                lanes[index % laneCount].append(item)
            }
            out.append(contentsOf: lanes.filter { !$0.isEmpty })
        }
        return out
    }
}
