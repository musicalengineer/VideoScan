// CatalogBackupSeal.swift
// The catalog half of File ▸ Back Up Catalog… once catalog.sqlite is the
// authority (2026-10-19, "JSON gone by Friday"). One sentence: the bundle
// gets a sealed copy of catalog.sqlite — every row, removed rows and
// quarantine included — made and checked the same way the viewer snapshot
// is, plus the latch and the high-water this Mac had written.
//
// In the bundle:
//   catalog.sqlite     a sealed `VACUUM INTO` copy: one rollback-journal
//                      file, no -wal, consistent at one generation
//   catalog.cutover    a byte copy of this Mac's latch
//   catalog.highwater  the high-water this Mac had written when the copy
//                      was sealed (the higher of catalog.highwater and the
//                      last line of catalog.highwater.log) — a record of
//                      where this Mac's catalog stood, NOT something a
//                      restore copies back (a restore keeps this Mac's own
//                      witnesses, so an older copy opens read-only below
//                      them and has to be adopted on purpose)
//
// Steps (each refuses before anything is published in the bundle):
//   1. the caller commits what is in memory FIRST (main actor,
//      `CatalogCommitter.commitBeforeSafetyCopy`) — so the copy holds what
//      the person sees; a held, blocked or read-only catalog refuses there;
//   2. seal: `repository.sealedCopyBlocking` into a hidden temp in the
//      bundle (the same call the viewer publisher and the scan-merge safety
//      copy use) — OFF the main actor, because VACUUM INTO blocks its thread;
//   3. check: open the temp the way a viewer does (sealed, read-only:
//      integrity_check, foreign_key_check, schema), read the generation and
//      the row counts (`CatalogViewerSnapshot.inspect`);
//   4. publish the temp as catalog.sqlite (rename(2) via AtomicFilePublish),
//      then the latch and the high-water; hash the published file.
// Nothing is written beside the live catalog: the temp lives in the bundle.
//
// Memory: VACUUM INTO streams page by page inside SQLite; the SHA-256 is
// streamed in 1 MB chunks (CatalogStore.sha256HexStreaming). Worst case is
// the latch bytes (< 1 KB) plus one 1 MB hash buffer. Disk: one copy the
// size of catalog.sqlite, inside the bundle.
//
// (For Rick: an `enum` with no cases ≈ a C++ namespace of static
// functions; `@concurrent` ≈ "always run on a worker thread, never on the
// caller's actor".)

import Foundation
import VideoScanCore

enum CatalogBackupSeal {

    static let databaseFileName = CatalogAuthority.databaseFileName     // "catalog.sqlite"
    static let latchFileName = CatalogAuthority.latchFileName           // "catalog.cutover"
    static let highWaterFileName = CatalogHighWater.fileName            // "catalog.highwater"

    /// What the session lends the seal: its open store and where its
    /// database and latch live. Built on the main actor by the model.
    struct Source: Sendable {
        let repository: any CatalogRepository
        /// The live catalog.sqlite (its folder holds the high-water witnesses).
        let databaseURL: URL
        /// The live `catalog.cutover`, beside the database.
        let latchURL: URL
    }

    /// What the bundle's manifest records about the sealed copy.
    struct Sealed: Codable, Equatable, Sendable {
        var fileName: String
        /// The generation the sealed copy is at.
        var generation: Int
        /// The high-water this Mac had written when the copy was sealed
        /// (nil when neither witness could be read).
        var highWater: Int?
        /// `files` rows — live and removed (tombstoned) alike.
        var files: Int
        var quarantine: Int
        var content: Int
        var bytes: Int64
        /// Lowercase hex SHA-256 of the bundled catalog.sqlite.
        var sha256: String
    }

    /// Seal `source` into `bundleURL/catalog.sqlite` with its latch and
    /// high-water beside it. Throws `CatalogViewerSnapshot.PublishError`
    /// (the same words the viewer publisher uses); on a throw nothing named
    /// catalog.sqlite is left in the bundle.
    @concurrent
    nonisolated static func seal(_ source: Source, into bundleURL: URL) async throws -> Sealed {
        typealias Failure = CatalogViewerSnapshot.PublishError
        let fm = FileManager.default
        let latchBytes: Data
        do { latchBytes = try Data(contentsOf: source.latchURL) } catch { throw Failure.noLatch(source.latchURL.path) }

        let target = bundleURL.appendingPathComponent(databaseFileName)
        // Hidden + the publish suffix, like the viewer snapshot's temp.
        let temp = bundleURL.appendingPathComponent(".\(databaseFileName).\(UUID().uuidString)\(AtomicFilePublish.temporarySuffix)")
        defer { try? fm.removeItem(at: temp) }   // consumed by the rename on success

        if let why = source.repository.sealedCopyBlocking(to: temp) { throw Failure.sealRefused(why) }
        let facts = try await CatalogViewerSnapshot.inspect(temp)
        let highWater = CatalogAdopt.highWater(besideDatabaseAt: source.databaseURL)
        do {
            try AtomicFilePublish.publish(temp, as: target)
            try AtomicFilePublish.write(latchBytes, to: bundleURL.appendingPathComponent(latchFileName),
                                        durability: .fast, createIntermediates: false)
            if let highWater {
                try CatalogHighWater.write(highWater, besideDatabaseAt: target, durability: .fast)
            }
        } catch {
            throw Failure.publishFailed(error.localizedDescription)
        }
        let sha: String
        do { sha = try CatalogStore.sha256HexStreaming(fileURL: target) } catch {
            throw Failure.publishFailed("the sealed copy could not be hashed: \(error.localizedDescription)")
        }
        let bytes = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Sealed(fileName: databaseFileName, generation: facts.generation, highWater: highWater,
                      files: facts.counts.files, quarantine: facts.counts.quarantine, content: facts.counts.content,
                      bytes: bytes, sha256: sha)
    }
}
