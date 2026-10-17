// ImportDryRunMarker.swift
// "Has a dry run of Import to SQLite PASSED on this build?" (Rick
// 2026-10-17, docs/design/catalog_sqlite_migration_2026_10_16.md §10c "app
// wiring"; rule changed the same evening with "one action verb"): the real
// import is offered once a dry run passed ON THIS BUILD. It used to demand
// the same catalog generation, which a live app could never keep — the
// background savers move the generation every minute or so. The real run
// re-proves everything anyway: it runs Audit Catalog, Verify Catalog, the
// gate and the comparator inside its own write hold. The marker records
// the build (`ImportBuildIdentity.current`) and still records the
// generation and the line, which the confirm sheet shows.
//
// The answer lives in a small marker beside catalog.json —
// `import-dryrun.json` — never in UserDefaults, so it travels with the
// catalog it describes and a test catalog in a scratch folder never sees
// the real one. A marker written before the build was recorded has none
// and enables nothing.
//
// The only file this type writes is that marker, through AtomicFilePublish
// (the FullHashBackfillResume shape, MOPS-13). A missing, damaged or other-
// build marker disables a menu item; it never starts work and never alters
// a record.
//
// (For Rick: `ObservableObject` + `@Published` ≈ a subject in the observer
// pattern — the menu item holding it re-renders when `lastPassed` changes.)

import Combine
import Foundation
import VideoScanCore

/// What the marker file holds: the last PASSED dry run.
struct ImportDryRunRecord: Codable, Equatable, Sendable {
    var passedAt: Date
    /// The catalog generation the dry run imported (its own audit's save).
    var catalogGeneration: Int
    /// The §f reconciliation line the dry run printed (the confirm sheet shows it).
    var reconciliationLine: String
    /// The build that ran it (`ImportBuildIdentity.current`); nil = a marker
    /// from before the build was recorded — it enables nothing.
    var build: String?
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

    /// A dry run passed: remember the build, the generation and the line.
    func notePassed(_ record: ImportDryRunRecord) {
        if let fileURL, let data = try? Self.encoder.encode(record) {
            try? AtomicFilePublish.write(data, to: fileURL, durability: .fast)
        }
        lastPassed = record
    }

    /// The gate for Catalog ▸ Import to SQLite…: a dry run passed on THIS
    /// build. The generation does not matter — the real run audits and
    /// verifies again inside its own hold before it imports.
    nonisolated static func enablesCommit(_ record: ImportDryRunRecord?, build: String) -> Bool {
        guard let recorded = record?.build else { return false }
        return !build.isEmpty && recorded == build
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
/// the passed dry run's line, generation and time, so the sheet names what
/// was proved. (For Rick: a POD the view is keyed on.)
struct ImportToSQLiteConfirmRequest: Identifiable, Equatable {
    let id = UUID()
    let reconciliationLine: String
    let catalogGeneration: Int
    let passedAt: Date
}
