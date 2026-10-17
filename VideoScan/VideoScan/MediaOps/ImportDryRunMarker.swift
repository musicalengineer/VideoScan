// ImportDryRunMarker.swift
// "Has a dry run of Import to SQLite PASSED on this catalog?" (Rick
// 2026-10-17, docs/design/catalog_sqlite_migration_2026_10_16.md §10c "app
// wiring"): the real import is offered only after a dry run passed on the
// SAME catalog generation. The answer lives in a small marker beside
// catalog.json — `import-dryrun.json` — never in UserDefaults, so it travels
// with the catalog it describes and a test catalog in a scratch folder
// never sees the real one.
//
// The only file this type writes is that marker, through AtomicFilePublish
// (the FullHashBackfillResume shape, MOPS-13). A missing, damaged or stale
// marker disables a menu item; it never starts work and never alters a
// record.
//
// (For Rick: `ObservableObject` + `@Published` ≈ a subject in the observer
// pattern — the menu item holding it re-renders when `lastPassed` changes.)

import Combine
import Foundation
import VideoScanCore

/// What the marker file holds: the last PASSED dry run.
struct ImportDryRunRecord: Codable, Equatable, Sendable {
    var passedAt: Date
    /// The catalog file's generation the dry run read (its header).
    var catalogGeneration: Int
    /// The §f reconciliation line the dry run printed (the confirm sheet shows it).
    var reconciliationLine: String
}

@MainActor
final class ImportDryRunMarker: ObservableObject {

    static let fileName = "import-dryrun.json"

    /// The last passed dry run (nil = none, or unreadable).
    @Published private(set) var lastPassed: ImportDryRunRecord?
    private(set) var fileURL: URL?

    init() {}

    /// Point at the catalog in use (its catalog.json path) and read what
    /// the last dry run left. Returns it, if readable.
    @discardableResult
    func attach(catalogFile: String) -> ImportDryRunRecord? {
        let url = URL(fileURLWithPath: catalogFile).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
        fileURL = url
        lastPassed = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(ImportDryRunRecord.self, from: $0) }
        return lastPassed
    }

    /// A dry run passed: remember the generation it read and its line.
    func notePassed(_ record: ImportDryRunRecord) {
        if let fileURL, let data = try? Self.encoder.encode(record) {
            try? AtomicFilePublish.write(data, to: fileURL, durability: .fast)
        }
        lastPassed = record
    }

    /// The gate for Catalog ▸ Import to SQLite…: a dry run passed on
    /// EXACTLY this generation. A later save (a new generation) disables
    /// the item until a dry run passes again.
    nonisolated static func enablesCommit(_ record: ImportDryRunRecord?, catalogGeneration: Int) -> Bool {
        guard let record else { return false }
        return record.catalogGeneration == catalogGeneration
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension VideoScanModel {
    /// At launch: point the dry-run marker at this catalog and read what the
    /// last dry run left (one small JSON read). Nothing starts.
    func attachImportDryRunMarker() {
        importDryRunMarker.attach(catalogFile: catalogStore.fileLocation)
    }
}

/// What Catalog ▸ Import to SQLite… hands the confirm sheet (`.sheet(item:)`):
/// the passed dry run's line and generation, so the sheet names what will
/// be written. (For Rick: a POD the view is keyed on.)
struct ImportToSQLiteConfirmRequest: Identifiable, Equatable {
    let id = UUID()
    let reconciliationLine: String
    let catalogGeneration: Int
}
