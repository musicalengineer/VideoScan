// CatalogFileHash.swift
// "DBCC CHECKDB for a JSON file" (docs/design/integrity_first_2026_10_16.md
// §3a): the catalog file's own SHA-256, recorded in the integrity report
// together with the generation it belongs to, so the next run can say
// "changed (generation N → M, expected)" — or "changed with the SAME
// generation — look", which is a finding (every save writes generation+1;
// same generation + other bytes means something other than the app wrote
// the file).
//
// STREAMED, never slurped: catalog.json is tens of MB; the hasher reads 1 MiB
// at a time through a FileHandle (worst-case memory: one 1 MiB buffer plus
// the first 4 KB kept for the header probe). The generation is read from
// that header — CatalogStore writes it by hand BEFORE `records`, in the
// first few hundred bytes (CatalogGenerationSidecar relies on the same).
//
// Read-only on the catalog: the file is opened for reading and closed. Pure
// apart from that one read; safe off the main actor.
//
// (For Rick: `SHA256()` from CryptoKit is an incremental hasher ≈ OpenSSL's
// EVP_DigestUpdate loop; `Comparison` is a tagged union the words switch on.)

import CryptoKit
import Foundation

struct CatalogFileHash: Sendable, Equatable {
    /// Lowercase hex SHA-256 of every byte of the file.
    let sha256: String
    let byteCount: Int64
    /// The `generation` in the file's header; nil when the header does
    /// not carry one (an old catalog, or a file that is not a catalog).
    let generation: Int?

    static let chunkBytes = 1 << 20
    static let headerBytes = 4_096

    /// Hash the file at `url`, streaming. Throws when it cannot be opened
    /// or read.
    static func of(fileAt url: URL) throws -> CatalogFileHash {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var head = Data()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            if head.count < headerBytes { head.append(chunk.prefix(headerBytes - head.count)) }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return CatalogFileHash(sha256: hex, byteCount: total, generation: generation(inHeader: head))
    }

    /// `"generation": 1234` in the first bytes of a catalog. Decoded as
    /// Latin-1 on purpose: it never fails (a 4 KB cut can split a multibyte
    /// UTF-8 character) and the key and digits the regex needs are ASCII.
    static func generation(inHeader head: Data) -> Int? {
        let text = String(bytes: head, encoding: .isoLatin1) ?? ""
        guard let match = text.range(of: #""generation"\s*:\s*(\d+)"#, options: .regularExpression) else { return nil }
        let digits = text[match].drop { !$0.isNumber }
        return Int(digits)
    }

    // MARK: - Run to run

    /// What the previous report's hash says about the catalog now.
    enum Comparison: Equatable, Sendable {
        /// No earlier report to compare with.
        case firstRun
        case unchanged
        /// The bytes changed and the generation moved on — a save did it.
        case changedExpected(from: Int, to: Int)
        /// The bytes changed and the generation did NOT move: a finding.
        case changedSameGeneration(Int)
        /// The bytes changed and one side's generation is unknown.
        case changedGenerationUnknown
        case notOnDisk

        /// True only for the one case a person has to look at.
        var needsDecision: Bool {
            if case .changedSameGeneration = self { return true }
            return false
        }

        var words: String {
            switch self {
            case .firstRun: return "first run — the catalog file's SHA-256 is recorded for the next one"
            case .unchanged: return "catalog.json unchanged since the last run"
            case .changedExpected(let from, let to): return "catalog.json changed (generation \(from) → \(to), expected)"
            case .changedSameGeneration(let g): return "catalog.json changed with the SAME generation (\(g)) — look: something other than a save rewrote it"
            case .changedGenerationUnknown: return "catalog.json changed (generation unknown on one side)"
            case .notOnDisk: return "catalog.json is not on disk — nothing to hash"
            }
        }
    }

    static func compare(previousSHA: String?, previousGeneration: Int?, current: CatalogFileHash?) -> Comparison {
        guard let current else { return .notOnDisk }
        guard let previousSHA else { return .firstRun }
        if previousSHA == current.sha256 { return .unchanged }
        guard let from = previousGeneration, let to = current.generation else { return .changedGenerationUnknown }
        return to > from ? .changedExpected(from: from, to: to) : .changedSameGeneration(to)
    }
}
