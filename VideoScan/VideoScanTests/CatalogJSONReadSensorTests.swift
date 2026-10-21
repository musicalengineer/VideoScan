// CatalogJSONReadSensorTests.swift
// JSON gone (2026-10-20): catalog.sqlite is the only catalog; catalog.json is
// a frozen history copy. This SENSOR pins every place app code still decodes
// a catalog in the JSON format, with the reason each one may. A NEW reader
// fails here, and so does one that goes away (the list stays true, not a
// museum). The data-path invariant it guards: the app opens catalog.sqlite,
// and no code path reads catalog.json into the live records of a session
// whose authority is catalog.sqlite.
//
// What is still here, and why (see the slice 2 report, 2026-10-20):
//   • CatalogAuthorityFlip — the launch rule. `.json` (no latch: a test host,
//     a viewer's own folder, a Mac never switched), `.refused` (catalog.json
//     READ-ONLY), and adoptSQLiteAuthority's `_ = catalogStore.load()`,
//     whose records are DISCARDED (the SQLite rows are the records) but
//     whose Master Archive designation is kept when catalog_state holds
//     none — a FINDING, reported to the Manager, not changed here.
//   • CatalogStore — the JSON store itself (its own load and decoder).
//   • VerifyCatalogJob — Verify's JSON source, used only when the audited
//     catalog is catalog.json.
//   • BundleImporter — reading a legacy (pre-SQLite) backup bundle; under
//     catalog.sqlite the import is refused before any merge
//     (bundleImportDecision).
//   • VideoScanModel+CatalogImportExport.importCatalog(from:) — the old
//     single-file import; no menu item calls it (tests do).
//
// Dimensions: SENSOR (source). LOGIC/SCALE/MEDIA/ISOLATION: N/A — reads
// source text only.

import Foundation
import Testing
@testable import VideoScan

@Suite("JSON gone — every catalog.json reader in the app is named")
struct CatalogJSONReadSensorTests {

    /// pattern → file (relative to VideoScan/VideoScan) → count.
    static let readers: [String: [String: Int]] = [
        #"catalogStore\.load\(\)"#: ["Catalog/CatalogAuthorityFlip.swift": 4],
        #"decodeCatalogFile\("#: ["Catalog/CatalogStore.swift": 2, "Integrity/VerifyCatalogJob.swift": 1],
        #"CatalogSnapshot(\.self|\s*=\s*try\b)"#: ["Catalog/CatalogStore.swift": 1,
                                                    "App/BundleImporter.swift": 1,
                                                    "Catalog/VideoScanModel+CatalogImportExport.swift": 1],
        // The retired live dossier reload (a 30 s poll merging catalog.json
        // into the records) must not come back.
        #"startLiveDossierReload|pollAndMergeDossierFromDisk|mergeDossierFields"#: [:],
        #"CatalogStore\.shared\.load\(\)"#: [:],
    ]

    private static func count(_ pattern: String, in code: String) throws -> Int {
        code.matches(of: try Regex(pattern)).count
    }

    @Test("SENSOR: the catalog.json readers are exactly the reviewed list")
    func theReadersAreReviewed() throws {
        #expect(SourceTree.appSources.count > 600, "the sensor must see the whole app tree")
        var found: [String: [String: Int]] = [:]
        for source in SourceTree.appSources {
            let raw = try String(contentsOf: source.url, encoding: .utf8)
            let code = SourceTree.scan(raw).code
            for pattern in Self.readers.keys {
                let n = try Self.count(pattern, in: code)
                if n > 0 { found[pattern, default: [:]][source.relative] = n }
            }
        }
        for (pattern, expected) in Self.readers {
            let actual = found[pattern] ?? [:]
            #expect(actual == expected, "\(pattern): found \(actual.sorted { $0.key < $1.key }), reviewed \(expected.sorted { $0.key < $1.key })")
        }
    }

    @Test("SENSOR: under catalog.sqlite the launch takes its records from the database — the JSON load's records are discarded")
    func theSQLiteLaunchDiscardsTheJSONRecords() throws {
        let flip = try SourceTree.appCode(named: "Catalog/CatalogAuthorityFlip.swift")
        #expect(flip.contains("_ = catalogStore.load()"), "the adopt path's JSON load returns nothing to the caller")
        #expect(flip.contains("let result = try SQLiteCatalogLoader.build(launch.snapshot)"))
        #expect(flip.contains("return result.records"))
        #expect(flip.contains("updateReadOnlyFacts { $0.jsonFrozenByLaunch = true }"), "catalog.json is frozen under catalog.sqlite")
    }

    @Test("SENSOR: the retired live dossier reload is gone from the launch")
    func theLiveReloadIsGone() throws {
        let app = try SourceTree.appCode(named: "App/VideoScanApp.swift")
        #expect(!app.contains("LiveDossierReload"))
        #expect(!SourceTree.appSources.contains { $0.relative.hasSuffix("VideoScanModel+LiveReload.swift") })
    }
}
