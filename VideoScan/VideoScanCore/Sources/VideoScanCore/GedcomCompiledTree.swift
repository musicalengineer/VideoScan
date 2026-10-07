// GedcomCompiledTree.swift (VideoScanCore)
// The compiled, preprocessed native form of a family tree: the parsed
// graph PLUS every derived structure (TreeIndex — name postings, CSR
// topology, sidebar order and haystack), in one flat little-endian blob
// that decodes as a string table and a handful of Int32 arrays.
//
// Rick (2026-08-28): huge GEDCOM pulls are rare — one per side, ever —
// so import is a ONE-TIME COMPILE step and launch reads the compiled
// artifact; the .ged stays the source of truth and is never rewritten.
// The app-side store (FamilyGraphCompiledStore) owns directories,
// generations, verification and promotion; these files are the codec and
// the verification checklist, both pure.
//
// Layout (all integers little-endian):
//   "VSFT" | u32 codec version | u32 TreeIndex.formatVersion
//   u64 payload length | payload | SHA-256(payload)
// Payload: string table (one UTF-8 blob + offsets), then people, families,
// roots, FamilySearch index, source provenance, then the index arrays.
// Strings are interned: every name/date/place/pointer is an Int32 into the
// table (−1 = nil). A corrupt or truncated file throws — never traps.

import CryptoKit
import Foundation

public enum GedcomCompiledTree {

    /// Bump when the encoding changes so older artifacts are recompiled.
    /// 4 (2026-08-28, codex #812/#814): provenance is written in the
    /// CANONICAL shape — the positional source list plus the graph-local
    /// remainder — so a one-source graph's loss is carried once (codec 3
    /// wrote it both in the list and as the local count: 2× after decode).
    /// 5 (2026-08-29): the people and family sections carry a chunk
    /// offset table so they decode in parallel (one chunk per core), and
    /// TreeIndex formatVersion 2 adds the launch tables. Older blobs are
    /// refused with `versionMismatch` and the store recompiles.
    /// 6 (2026-09-02, Rick's one-primary-parent-family ruling): the family
    /// section carries the FAM `_FSFTID`, and the persisted parent table
    /// now lists ONE father and ONE mother per person (the primary
    /// family's) — a codec-5 blob would keep serving both mothers.
    /// 7 (2026-09-23, Hallie's military-service stories): each person
    /// carries its military facts (`Person.militaryFacts`) as a flat list,
    /// six strings per fact (tag, value, type, date, place, note; "" = nil).
    /// A codec-6 blob has none and would hide every one of them.
    public static let codecVersion: UInt32 = 7
    /// Strings per military fact in the codec-7 people section.
    static let militaryFactWidth = 6
    static let magic: [UInt8] = Array("VSFT".utf8)
    /// Records per parallel decode chunk (written into the section header;
    /// the reader honours whatever the file says). 39k people → 39
    /// chunks; 100k → 98: enough to balance 16 cores, large enough that
    /// the per-chunk dispatch is noise.
    static let chunkSize = 1024

    public enum CodecError: Error, Equatable {
        case badMagic
        case versionMismatch(codec: UInt32, index: UInt32)
        case truncated
        case checksumMismatch
        case corrupt(String)
    }

    // MARK: Decode

    /// The graph, with its index installed. Throws on any malformed input.
    ///
    /// Uses every core (2026-08-29): the payload checksum runs on one
    /// thread while the sections parse on the others; the string table
    /// and the chunked people/family sections parse with
    /// `DispatchQueue.concurrentPerform`. Every reader is bounds-checked,
    /// so parsing ahead of the checksum can only throw, never trap — and
    /// a checksum failure is still reported as `checksumMismatch`
    /// whatever the parse made of the bytes. The result is identical to
    /// a sequential decode by construction (each chunk reads a disjoint
    /// byte range into a disjoint slot; assembly is in ordinal order).
    public static func decode(_ data: Data) throws -> GedcomFamilyGraph {
        guard data.count >= 4 + 4 + 4 + 8 + 32 else { throw CodecError.truncated }
        guard Array(data.prefix(4)) == magic else { throw CodecError.badMagic }
        let codec: UInt32 = data.readLE(at: 4), indexVersion: UInt32 = data.readLE(at: 8)
        guard codec == codecVersion, indexVersion == GedcomFamilyGraph.TreeIndex.formatVersion else {
            throw CodecError.versionMismatch(codec: codec, index: indexVersion)
        }
        let length: UInt64 = data.readLE(at: 12)
        let payloadStart = 20
        // The file is exactly header | payload | checksum (codex #797-5):
        // shorter = truncated, longer = something appended after the
        // checksum that the hash would never have covered. Both refuse.
        let available = UInt64(data.count - payloadStart - 32)
        guard length <= available else { throw CodecError.truncated }
        guard length == available else { throw CodecError.corrupt("trailing bytes after checksum") }
        let payloadEnd = payloadStart + Int(length)
        return try data.withUnsafeBytes { whole -> GedcomFamilyGraph in
            // Strict concurrency: `payload` and `checksumOK` are shared with
            // the hash worker below. `nonisolated(unsafe)` ≈ telling the
            // compiler "I own the synchronization" (like a raw pointer handed
            // to a pthread in C). Race-free because:
            //  - `payload` is only READ, by both threads, and the bytes stay
            //    alive until `hashGroup.wait()` (the `defer` below runs before
            //    `withUnsafeBytes` returns);
            //  - `checksumOK` is written once by the worker and read here only
            //    after `hashGroup.wait()`, which is a happens-before edge
            //    (every read site below is preceded by a wait).
            nonisolated(unsafe) let payload = UnsafeRawBufferPointer(rebasing: whole[payloadStart..<payloadEnd])
            let stored = Array(whole[payloadEnd..<payloadEnd + 32])
            // Checksum on a worker while this thread parses.
            let hashGroup = DispatchGroup()
            nonisolated(unsafe) var checksumOK = false
            DispatchQueue.global(qos: .userInitiated).async(group: hashGroup) {
                checksumOK = Array(SHA256.hash(data: payload)) == stored
            }
            defer { hashGroup.wait() }
            let parsed: GedcomFamilyGraph
            do {
                parsed = try parsePayload(payload)
            } catch {
                hashGroup.wait()
                if !checksumOK { throw CodecError.checksumMismatch }
                throw error
            }
            let waited = PhaseClock()
            hashGroup.wait()
            var c = waited; c.lap("checksum wait")
            guard checksumOK else { throw CodecError.checksumMismatch }
            return parsed
        }
    }

    static func chunkCount(_ records: Int) -> Int { (records + chunkSize - 1) / chunkSize }

    /// `VS_DECODE_TIMING=1` prints one line per decode phase (perf work).
    static let phaseTiming = ProcessInfo.processInfo.environment["VS_DECODE_TIMING"] != nil
    struct PhaseClock {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var last: UInt64
        init() { last = t0 }
        mutating func lap(_ label: String) {
            guard GedcomCompiledTree.phaseTiming else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            print("DECODE-PHASE \(label): +\(Double(now - last) / 1e6) ms (\(Double(now - t0) / 1e6) ms)")
            last = now
        }
    }

    // MARK: Source identity

    /// Identity of a source file for invalidation = its FULL SHA-256, hex
    /// (codex #792/#797, requirement #771). Size and mtime are deliberately
    /// NOT part of the key: a same-size, mtime-preserving edit in the
    /// middle of the file must be a miss, and a `touch` with identical
    /// bytes may stay a hit. Costs one streaming read of the file
    /// (~0.2 s per 100 MB on the M4); the store logs the measured time.
    public static func sourceKey(for url: URL) throws -> String {
        try fullSHA256(of: url)
    }

    /// (size, mtime) straight from the filesystem.
    public static func sourceStat(_ url: URL) throws -> (size: Int, mtime: TimeInterval) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// Full-file SHA-256 (the sidecar / provenance hash). Streams in 4 MiB.
    public static func fullSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
