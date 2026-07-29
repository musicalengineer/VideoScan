// PreviewCacheFormat.swift
// The preview disk cache's FORMAT + KEYING contract, lifted into
// VideoScanCore so the app AND a future out-of-process helper (Stage 1)
// derive cache keys and parse/emit payload filenames from ONE source of
// truth — no drift possible between the in-app sweep and the CLI.
//
// COMPATIBILITY CONTRACT (load-bearing — Rick has a warmed on-disk cache):
// every function here was moved VERBATIM from PreviewDiskCache (app
// target). `PreviewDiskCache` now forwards to these, so its on-disk
// behavior is bit-identical. The golden sensor
// (PreviewCacheFormatTests.goldenCacheKey) pins `previewCacheKey`'s exact
// output for a known record; any future edit that changes the digest
// fails loudly, which is exactly the cache-key-drift bug class this
// centralization guards against.
//
// UI-free / Foundation + CryptoKit only — safe for the domain package.

import Foundation
import CryptoKit

// MARK: - Sanity ceilings

/// Upper sanity bound on a plannable media duration (~115 days). Catalog
/// durations beyond this are garbage metadata; the planners must never
/// trust them (`Int((offset * 10).rounded())` TRAPS on non-finite doubles
/// and on finite values past ~1.8e18). Single source of truth for the
/// app's `PreviewBestFramePlan.maxSaneDurationSeconds`.
public let previewMaxSaneDurationSeconds: Double = 10_000_000

/// Ceiling for a strip frame's offset, in milliseconds — aligned with
/// `previewMaxSaneDurationSeconds` so the plan and the cache agree on what
/// a "sane" media timestamp is. A huge FINITE Double passes an isFinite
/// check but `Int(x.rounded())` still traps past ~9.2e18 (codex
/// adversarial finding #40, 2026-07-27) — so the seconds value is bounded
/// BEFORE the millisecond conversion, and the strip-filename parser
/// rejects the same range on read.
public let previewMaxStripOffsetMillis = Int(previewMaxSaneDurationSeconds * 1000)

// MARK: - Tier

/// Payload quality tier. Raw value IS the literal filename suffix
/// ("<key>-fast.jpg" / "<key>-best.jpg"). Declaration order (fast, best)
/// is preserved from the app enum — `allCases` order is relied on by the
/// tier-filename parser.
public enum PreviewCacheTier: String, CaseIterable, Sendable {
    /// Interactive path's single frame at t=0.5s — cheap, may be a blank
    /// VHS lead-in. Upgradeable.
    case fast
    /// Background best-frame pick (content-scored). Terminal — never
    /// overwritten by `fast`.
    case best
}

// MARK: - Keying (pure)

/// Cache key: SHA256 hex of "path|mtimeEpochSeconds|sizeBytes". mtime
/// truncates to whole seconds — sub-second precision differs across
/// filesystems (SMB vs APFS) and a 1 s window can't matter for "did this
/// media file change". Pure and static for tests.
public func previewCacheKey(path: String, mtime: TimeInterval, size: Int64) -> String {
    let material = "\(path)|\(Int64(mtime))|\(size)"
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// (mtime, size) of the file at `path`, or nil when it can't be statted
/// (vanished / dead volume). Callers skip the disk cache entirely on nil
/// rather than keying on garbage. File I/O — call off the main actor.
public func previewFileSignature(atPath path: String) -> (mtime: TimeInterval, size: Int64)? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
          let size = (attrs[.size] as? NSNumber)?.int64Value else {
        return nil
    }
    return (mtime, size)
}

// MARK: - Tier payload filenames (pure)

/// Tier payload filename: "<key>-<tier>.jpg".
public func previewTierFilename(key: String, tier: PreviewCacheTier) -> String {
    "\(key)-\(tier.rawValue).jpg"
}

/// Parse a tier payload filename ("<key>-fast.jpg" / "<key>-best.jpg")
/// back into its fields, or nil for anything else (strip payloads, tmp
/// files, junk). Pure and static — the preview sweep's one-listing cache
/// index is built from THIS parser + `previewParseStripFilename`.
public func previewParseTierFilename(_ filename: String) -> (key: String, tier: PreviewCacheTier)? {
    guard filename.hasSuffix(".jpg") else { return nil }
    let stem = filename.dropLast(4)
    for tier in PreviewCacheTier.allCases {
        let suffix = "-\(tier.rawValue)"
        if stem.hasSuffix(suffix) {
            let key = String(stem.dropLast(suffix.count))
            guard !key.isEmpty else { return nil }
            return (key, tier)
        }
    }
    return nil
}

// MARK: - Strip payload filenames (pure)

/// Strip payload filename:
/// "<key>-strip-<index>-of-<count>-<offsetMillis>.jpg". Pure and static.
public func previewStripFilename(key: String, index: Int, count: Int,
                                 offsetMillis: Int) -> String {
    "\(key)-strip-\(index)-of-\(count)-\(offsetMillis).jpg"
}

/// Parse a strip filename back into its fields. Returns nil for anything
/// else (tier payloads, tmp files, malformed/negative fields, index out
/// of range for its count, or an insane offset past
/// `previewMaxStripOffsetMillis`). Pure and static.
public func previewParseStripFilename(_ filename: String)
    -> (key: String, index: Int, count: Int, offsetMillis: Int)? {
    guard filename.hasSuffix(".jpg") else { return nil }
    let stem = String(filename.dropLast(4))
    guard let marker = stem.range(of: "-strip-") else { return nil }
    let key = String(stem[..<marker.lowerBound])
    guard !key.isEmpty else { return nil }
    // Tail is "<index>-of-<count>-<offsetMillis>". A negative field would
    // add a "-" and break the 4-part shape — rejected.
    let parts = stem[marker.upperBound...].components(separatedBy: "-")
    guard parts.count == 4, parts[1] == "of",
          let index = Int(parts[0]),
          let count = Int(parts[2]),
          let offsetMillis = Int(parts[3]),
          count > 0, index >= 0, index < count,
          // Same sane-offset ceiling as the writer: a hand-crafted
          // filename with a huge-but-parseable offset must be a MISS, not
          // a value that flows downstream into second→millisecond math
          // that traps. Int.init(String) already returns nil on overflow;
          // this closes the in-range-but-insane window.
          offsetMillis >= 0, offsetMillis <= previewMaxStripOffsetMillis else {
        return nil
    }
    return (key, index, count, offsetMillis)
}
