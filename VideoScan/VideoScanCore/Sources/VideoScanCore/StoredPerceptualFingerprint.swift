// StoredPerceptualFingerprint.swift
// GH #293 item 1 (2026-10-07): the 32-frame perceptual fingerprint of a
// video, KEPT on its catalog record. Before this the fingerprinter wrote
// its frames to a temp file and the hashes died with the compare that made
// them — 0% of the catalog carried one, so Find Similar, delete-excess
// Tier 2 and the archive Year check could never reuse them.
//
// What is stored: the 64-bit dHashes (one per sampled frame, up to 32) in
// the form PerceptualHash.swift designed for persistence ("Fingerprint
// encoding (future catalog persistence)"): the hashes packed BIG-ENDIAN,
// 8 bytes each, as base64 — 344 characters for 32 frames, endian-pinned so
// a value written on one Mac reads identically on any other. The app's
// `PerceptualHash.base64(from:)` produces the identical string (pinned by a
// test). Plus the facts that make it trustworthy later:
//   • `algorithmVersion` — the sampling recipe (32 frames, 5% trimmed off
//     each end, 9×8 gray, dHash). A future recipe bumps it; older values
//     are then simply "absent" and recomputed.
//   • `sizeBytes` / `durationSeconds` — the file it was taken from. A
//     different size means different bytes: the value is ignored.
//   • `computedAt` — when.
//
// Decoding NEVER fails on the base64's content — a damaged string decodes,
// and `hashes` reads nil (so one bad record can never stop the catalog from
// loading). Readers treat nil as "absent".
//
// ADDITIVE optional on VideoRecord (`perceptualFingerprint`): legacy
// catalogs decode nil; the DTO writes the key only when present, so every
// record without one round-trips byte-identical. No catalog version bump
// (same rule as `inferredDateRange`, `footage`, `contentFixity`).
//
// (For Rick: a POD struct, compiler-written serializer; `hashes` is a const
// accessor that unpacks the bytes on demand — ≈ 32 ntohll calls.)

import Foundation

public struct StoredPerceptualFingerprint: Codable, Equatable, Hashable, Sendable {

    /// The sampling recipe this build writes and trusts.
    public static let currentAlgorithmVersion = 1

    public var algorithmVersion: Int
    /// Base64 of the hashes packed big-endian, 8 bytes per frame.
    public var hashesBase64: String
    /// Size of the file the hashes were taken from.
    public var sizeBytes: Int64
    /// The catalog duration used to place the samples.
    public var durationSeconds: Double
    public var computedAt: Date

    public init(hashes: [UInt64], sizeBytes: Int64, durationSeconds: Double,
                computedAt: Date = Date(), algorithmVersion: Int = Self.currentAlgorithmVersion) {
        self.algorithmVersion = algorithmVersion
        self.hashesBase64 = Self.base64(hashes)
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.computedAt = computedAt
    }

    /// The frame hashes, or nil when the stored text is damaged (not
    /// base64, or not a whole number of 8-byte hashes) or empty.
    public var hashes: [UInt64]? {
        guard let data = Data(base64Encoded: hashesBase64), !data.isEmpty, data.count % 8 == 0 else { return nil }
        var out: [UInt64] = []
        out.reserveCapacity(data.count / 8)
        var value: UInt64 = 0
        for (i, byte) in data.enumerated() {
            value = (value &<< 8) | UInt64(byte)
            if i % 8 == 7 {
                out.append(value)
                value = 0
            }
        }
        return out
    }

    /// May this value stand in for a fresh fingerprint of a file of
    /// `sizeBytes`? Same recipe, same size, enough frames, undamaged.
    public func isCurrent(forSizeBytes sizeBytes: Int64, minimumFrames: Int) -> Bool {
        guard algorithmVersion == Self.currentAlgorithmVersion, self.sizeBytes == sizeBytes, sizeBytes > 0,
              let h = hashes else { return false }
        return h.count >= minimumFrames
    }

    /// Big-endian packed bytes, base64 — the persisted form.
    static func base64(_ hashes: [UInt64]) -> String {
        var d = Data(capacity: hashes.count * 8)
        for value in hashes {
            withUnsafeBytes(of: value.bigEndian) { d.append(contentsOf: $0) }
        }
        return d.base64EncodedString()
    }
}
