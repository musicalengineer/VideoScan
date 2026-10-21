// CatalogJSONReadSensorTests.swift
// JSON gone (2026-10-20): catalog.sqlite is the only catalog; catalog.json is
// a frozen history copy. This SENSOR pins every place app code still decodes
// a catalog in the JSON format, with the reason each one may. A NEW reader
// fails here, and so does one that goes away (the list stays true, not a
// museum). The data-path invariant it guards: the app opens catalog.sqlite,
// and no code path reads catalog.json into the live records of a session
// whose authority is catalog.sqlite.
//
// What is still here, and why (see the slice 2 report, 2026-10-21):
//   • CatalogAuthorityFlip — the launch rule: only the test host on the
//     shared store (its load reads nothing). A launch with NO latch, or a
//     refused catalog.sqlite, refuses and opens no catalog.json (GH #354,
//     QA r1 F1); the SQLite launch reads none either (GH #353); a viewer
//     never opens its own catalog (QA r1 F2).
//   • CatalogStore — the JSON store itself (its own load and decoder).
//   (Person Finder's catalog prefilter read the frozen catalog.json through
//   CatalogStore.readRecordsWithoutAdopting; it reads the live records since
//   0005b81ee, and that reader was retired 2026-10-21.)
//   • VideoScanModel+VolumeRenameUndo.loadSafetyCopy — a pre-cutover
//     `catalog.pre-volume-rename.*.json` safety copy (never catalog.json).
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
        #"catalogStore\.load\(\)"#: ["Catalog/CatalogAuthorityFlip.swift": 1],
        // Verify's audited-file source (Import to SQLite's phase 2) read
        // catalog.json with no caller left; retired 2026-10-21.
        #"decodeCatalogFile\("#: ["Catalog/CatalogStore.swift": 2],
        #"CatalogSnapshot(\.self|\s*=\s*try\b)"#: ["Catalog/CatalogStore.swift": 1,
                                                    "Catalog/VideoScanModel+CatalogImportExport.swift": 1],
        // The retired live dossier reload (a 30 s poll merging catalog.json
        // into the records) must not come back.
        #"startLiveDossierReload|pollAndMergeDossierFromDisk|mergeDossierFields"#: [:],
        #"CatalogStore\.shared\.load\(\)"#: [:],
        #"readRecordsWithoutAdopting"#: [:],
        #"loadRecords\(fromSnapshotAtPath"#: ["Catalog/CatalogStore.swift": 1, "Volumes/VideoScanModel+VolumeRenameUndo.swift": 1],
        // The live reload's generation adopt (it read catalog.json's header
        // after a merge) left with it; retired 2026-10-21.
        #"adoptOnDiskGenerationAfterReconcile|auditedFileRows|verifyCatalogSnapshot\(auditedGeneration"#: [:],
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

    @Test("SENSOR: under catalog.sqlite the launch takes its records and designation from the database and never loads catalog.json")
    func theSQLiteLaunchNeverLoadsTheJSON() throws {
        let flip = try SourceTree.appCode(named: "Catalog/CatalogAuthorityFlip.swift")
        #expect(!flip.contains("_ = catalogStore.load()"), "GH #353: the adopt path's JSON load is gone")
        let adopt = try #require(flip.range(of: "private func adoptSQLiteAuthority("))
        let next = try #require(flip.range(of: "func catalogCommitInput()"))
        #expect(!flip[adopt.lowerBound..<next.lowerBound].contains("catalogStore.load"), "nothing in the adopt path loads catalog.json")
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
