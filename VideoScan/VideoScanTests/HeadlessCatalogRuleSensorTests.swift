// HeadlessCatalogRuleSensorTests.swift
// Sensor (2026-11-04, the M4's Hallie lane): no headless path in the app
// target names a catalog.sqlite on its own. The Hallie shell picked
// ~/Library/Application Support/VideoScan/catalog.sqlite itself, so on a
// viewer it read the stale top-level file instead of the master's synced
// copy. Every headless reader goes through `CatalogAuthority.headlessSource`
// (the role rule, `CatalogAuthority.databaseURL(role:…)`).
//
// What it reads: the CODE (comments stripped) of every app source. What it
// refuses outside the allowlist: the reader door by bare URL
// (`SQLiteCatalogReader.load(databaseURL:`), the default-path helpers, and a
// raw `openForReading(at:` — each is a catalog file chosen without the role.
//
// Suite (filter by SUITE): HeadlessCatalogRuleSensorTests

import Foundation
import Testing

@Suite("Sensor: headless catalog readers pick their file through the one role rule")
struct HeadlessCatalogRuleSensorTests {

    /// A catalog file chosen without the role.
    private static let forbidden = [
        "SQLiteCatalogReader.load(databaseURL:",
        "SQLiteCatalogReader.defaultDatabaseURL",
        "PreviewSweepCLIOptions.defaultCatalogURL",
        ".openForReading(at:",
        // The Hallie shell's own path before 11/04: Application Support + this.
        "VideoScan/\\(SQLiteCatalogReader.databaseFileName",
    ]

    /// Relative path → why it may.
    private static let allowed: [String: String] = [
        // The rule itself: the folder the role rule resolves in.
        "Catalog/CatalogAuthorityFlip.swift": "CatalogAuthority.headlessSource — the rule",
        // The preview helper's launcher passes the helper its catalog path. The
        // helper's viewer path is BACKLOG H′ (another worker owns the helper).
        "Media/PreviewService+Sweep.swift": "preview helper launcher — BACKLOG H′",
    ]

    @Test("no app source outside the rule names a catalog.sqlite for a headless read")
    func noHeadlessPathBypassesTheRule() throws {
        #expect(SourceTree.appSources.count > 100, "the sensor read no app sources")
        var offenders: [String] = []
        for (relative, url) in SourceTree.appSources where Self.allowed[relative] == nil {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard Self.forbidden.contains(where: text.contains) else { continue }
            let code = try SourceTree.code(of: text, named: relative)
            for needle in Self.forbidden where code.contains(needle) { offenders.append("\(relative): \(needle)") }
        }
        #expect(offenders.isEmpty, """
            these headless paths choose catalog.sqlite without the role rule — use \
            CatalogAuthority.headlessSource() (on a viewer: the master's synced copy): \(offenders)
            """)
    }

    @Test("the Hallie shell and the find-tag daemon default to the rule")
    func theHeadlessEntriesUseTheRule() throws {
        for name in ["Hallie/Shell/HallieShellCLI.swift", "People/FindTagCLI.swift"] {
            let code = try SourceTree.appCode(named: name)
            #expect(code.contains("var catalog: SQLiteCatalogReader.Source = CatalogAuthority.headlessSource()"), "\(name)")
            #expect(code.contains("CatalogAuthority.explicitSource("), "\(name): --catalog must go through explicitSource")
        }
        let rule = try SourceTree.appCode(named: "Catalog/CatalogAuthorityFlip.swift")
        #expect(rule.contains("let url = databaseURL(role: role, opened: nil, catalogFile:"),
                "headlessSource must resolve through databaseURL(role:opened:catalogFile:)")
    }
}
