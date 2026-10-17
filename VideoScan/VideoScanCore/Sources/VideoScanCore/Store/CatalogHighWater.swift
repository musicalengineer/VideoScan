// CatalogHighWater.swift (VideoScanCore/Store)
// The external generation high-water mark: `catalog.highwater`, one integer
// in a file BESIDE the database. Contract F8 / F8r3
// (docs/design/catalog_contract_freeze_2026_10_17.md §e.9).
//
// Why it is outside the database: a restore of the database from an older
// copy would rewind anything stored inside it. The file remembers the
// highest generation this Mac ever intended to write, so a restored copy
// is caught at open (`generation < highwater`) and opens read-only until a
// person adopts it.
//
// Two-phase rule (F8r3): the file is raised to g+1 BEFORE the transaction
// that advances g → g+1 commits. So at open `highwater ≥ generation` always
// holds; `highwater > generation` is a restore or a crash between the two
// phases, and either way writing waits for a person.
//
// Lineage: the JSON store's `catalog.generation.max` sidecar (GH #165) is
// the same idea written AFTER each save; this one is written BEFORE, which
// is what closes codex's restore-then-crash-then-restore case.
//
// For Rick: this is a tiny struct of static functions over one file —
// no instances, no state; think of a C namespace of three functions.

import Foundation

public enum CatalogHighWater {

    public static let fileName = "catalog.highwater"

    /// What the file says. The three shapes are distinct on purpose:
    /// `missing` is recreated from the database (DDL §11), `unreadable` is
    /// a poisoned file that only a person can resolve.
    public enum Reading: Sendable, Equatable {
        case value(Int)
        case missing
        case unreadable(String)
    }

    /// Sits beside the database so it travels with the catalog it describes.
    public static func url(besideDatabaseAt databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    public static func read(besideDatabaseAt databaseURL: URL) -> Reading {
        let fileURL = url(besideDatabaseAt: databaseURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .unreadable("\(fileName) could not be read as UTF-8 text")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else {
            return .unreadable("\(fileName) holds '\(trimmed.prefix(40))', not a generation number")
        }
        return .value(value)
    }

    /// Publish `generation` as the mark: temp file + rename, and with
    /// `.fullFsync` an F_FULLFSYNC before the rename plus a directory fsync
    /// after — the mark must survive a forced reboot or it cannot witness
    /// the commit it precedes. Callers decide `durability` once, at
    /// repository construction, and say why.
    public static func write(_ generation: Int,
                             besideDatabaseAt databaseURL: URL,
                             durability: AtomicFilePublish.Durability) throws {
        try AtomicFilePublish.write(Data("\(generation)\n".utf8),
                                    to: url(besideDatabaseAt: databaseURL),
                                    durability: durability,
                                    createIntermediates: false)
    }
}
