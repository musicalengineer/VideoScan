// CatalogChangeDetector.swift
// Which records changed since the last commit (cutover B2, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §10 "B2-lite": the funnels keep
// their signatures and the DIFF is the dirty tracking until field-level
// writes exist).
//
// How. A fingerprint per record = one 64-bit SipHash of everything the
// app's ONE encoder (`VideoRecordDTO.encode(to:)`, the byte-identity source
// of catalog.json) emits for it, fed through `HashingEncoder` (no text is
// built). Two records with the same persisted state emit the same keys and
// values, so the same fingerprint; any persisted field that changes changes
// the stream. The baseline is a dictionary id → fingerprint of what the
// store holds (filled at load, updated per landed row).
//
// Chosen by measurement (Debug, M4 Max, 14k "rich" records — every one of
// the 129 keys set, captions and a report card each, so heavier than a
// real catalog row), per record, serial:
//   CatalogRecordDTO(record:)        ≈ 1 100–1 700 µs  (B1's "too slow")
//   CatalogJSONValueEncoder tree      ≈ 160–250 µs
//   JSONEncoder bytes + hash          ≈ 80–100 µs
//   HashingEncoder (this)             ≈ 26 µs
// The `VideoRecordDTO` snapshot is taken on the main actor (≈ 2 µs a
// record); the hashing runs OFF it, split across the cores.
// CatalogChangeDetectorScaleTests prints the current numbers; the budget is
// 150 ms for 14k records, Debug, load-aware.
//
// Memory: one `Int` per record in the baseline (14k → 112 KB; 100k →
// 800 KB) plus one result `Int` per record while a detection runs.
// The `[VideoRecordDTO]` snapshot shares its strings and arrays with the
// live records (copy-on-write), so it costs about one pointer per field.
//
// A collision (two different states, one hash) would hide one change until
// the record changes again: 2⁻⁶⁴ per changed record. `Hasher` is seeded per
// process, so fingerprints are never persisted or compared across launches.
//
// (For Rick: a per-row checksum compared against the last-saved checksum —
// the dirty bit is computed, not remembered, so no writer can forget to set
// it. `DispatchQueue.concurrentPerform` ≈ an OpenMP `parallel for`.)

import Foundation

public enum CatalogChangeDetector {

    public typealias Fingerprint = Int

    /// The fingerprint of each snapshot, in order. Runs on the calling
    /// thread plus the cores `concurrentPerform` lends; call it off the
    /// main actor.
    public static func fingerprints(of snapshots: [VideoRecordDTO]) -> [Fingerprint] {
        let count = snapshots.count
        guard count > 0 else { return [] }
        let chunkSize = max(64, count / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let chunks = (count + chunkSize - 1) / chunkSize
        var out = [Fingerprint](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            // Each chunk writes only its own index range — no two threads
            // touch one slot. (For Rick: a raw array pointer handed to the
            // workers, like passing `int*` into a parallel loop.)
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let lower = chunk * chunkSize
                let upper = min(count, lower + chunkSize)
                for index in lower..<upper {
                    slots[index] = fingerprint(snapshots[index])
                }
            }
        }
        return out
    }

    /// One record's fingerprint. A record the encoder refuses gets a value
    /// no baseline can hold (a fresh random number), so it always reads as
    /// changed and the commit names the refusal.
    public static func fingerprint(_ snapshot: VideoRecordDTO) -> Fingerprint {
        (try? HashingEncoder.hash(snapshot)) ?? Int.random(in: Int.min...Int.max)
    }

    /// The ids whose fingerprint differs from `baseline` (or that have
    /// none), in snapshot order.
    public static func changed(_ ids: [UUID], fingerprints: [Fingerprint],
                               baseline: [UUID: Fingerprint]) -> [Int] {
        var dirty: [Int] = []
        for index in ids.indices where baseline[ids[index]] != fingerprints[index] {
            dirty.append(index)
        }
        return dirty
    }
}
