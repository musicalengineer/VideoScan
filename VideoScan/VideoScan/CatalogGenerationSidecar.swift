// CatalogGenerationSidecar.swift
// Remembers the HIGHEST OCC generation ever observed for the catalog it
// sits beside (`catalog.generation.max`, a one-line text file next to
// catalog.json). Layer-0 write safety, design doc §4.1; GH #165.
//
// Why it exists: on 2026-08-18 the generation counter silently reset
// 248 → 1. `CatalogSnapshot.headerProbe` only looked at the first 4 KB of
// catalog.json and the encoder had put `generation` AFTER 36 MB of
// records, so the probe returned nil, load() baselined at 0 and the next
// save stamped 1. Nothing on disk remembered 248. This file is that
// memory: a load that sees an on-disk generation LOWER than the sidecar
// is a regression, is logged loudly, and the next write re-seeds above
// the sidecar rather than continuing the reset sequence.
//
// `// For Rick: think of a tiny, append-free "high-water mark" file. One
// `// integer, atomic replace on every advance, never decremented.`

import Foundation
import os

private let sidecarLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogStore")

enum CatalogGenerationSidecar {

    static let fileName = "catalog.generation.max"

    /// Sits beside catalog.json so it travels with (and is backed up with)
    /// the catalog it describes.
    static func url(besideCatalogAt catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The recorded high-water mark, or nil when no sidecar exists yet
    /// (first run after this fix, or a fresh directory).
    static func read(besideCatalogAt catalogURL: URL) -> Int? {
        let u = url(besideCatalogAt: catalogURL)
        guard let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Advance the high-water mark to `generation` if it is higher than
    /// what is recorded. Returns the resulting mark. Never decrements.
    /// Atomic replace (temp + rename) so a crash mid-write leaves the old
    /// value, not a torn one. Failures are logged, not thrown: the sidecar
    /// is a safety net, and a safety net that can block saving is worse
    /// than the regression it guards against.
    @discardableResult
    static func recordMax(_ generation: Int, besideCatalogAt catalogURL: URL) -> Int {
        let existing = read(besideCatalogAt: catalogURL) ?? 0
        guard generation > existing else { return existing }
        write(generation, besideCatalogAt: catalogURL)
        return generation
    }

    private static func write(_ generation: Int, besideCatalogAt catalogURL: URL) {
        do {
            try Data("\(generation)\n".utf8).write(to: url(besideCatalogAt: catalogURL),
                                                   options: .atomic)
        } catch {
            sidecarLog.error("catalog OCC: could not update \(fileName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// First-run bootstrap: when no sidecar exists, reconstruct the
    /// high-water mark from every catalog file in the directory —
    /// catalog.json, catalog.json.prev and the timestamped safety copies
    /// (`catalog.pre-*.json`, `catalog.manual-backup-*.json`, …) — using
    /// the cheap head+tail probe on each (a few KB per file, never a full
    /// decode). Whatever the highest stamp anyone wrote here was, that is
    /// the floor. Writes the result so the scan happens once.
    ///
    /// Generic on purpose: no hard-coded numbers. If the true maximum was
    /// only ever observed (never written to a surviving file) the operator
    /// can seed the sidecar by hand — it is a one-line text file — and the
    /// next load honours it.
    static func bootstrap(besideCatalogAt catalogURL: URL) -> Int {
        let dir = catalogURL.deletingLastPathComponent()
        var best = 0
        var scanned = 0
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasPrefix("catalog")
                && (name.hasSuffix(".json") || name.hasSuffix(".json.prev")) {
                scanned += 1
                if let g = CatalogSnapshot.headerProbe(at: dir.appendingPathComponent(name))?.generation {
                    best = max(best, g)
                }
            }
        }
        sidecarLog.notice("catalog OCC: no \(fileName, privacy: .public) yet — bootstrapped high-water mark \(best) from \(scanned) catalog file(s) in \(dir.path, privacy: .public)")
        write(best, besideCatalogAt: catalogURL)   // even 0: the scan happens once
        return best
    }

    /// Read the mark, bootstrapping it from sibling files on first use.
    static func load(besideCatalogAt catalogURL: URL) -> Int {
        read(besideCatalogAt: catalogURL) ?? bootstrap(besideCatalogAt: catalogURL)
    }
}
