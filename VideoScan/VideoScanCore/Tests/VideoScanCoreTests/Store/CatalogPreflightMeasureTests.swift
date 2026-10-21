// CatalogPreflightMeasureTests.swift
// MEASUREMENT, opt-in (QA r1 minor 6): times each launch question against
// the full open checks on a REAL catalog copy. It runs only when
// VIDEOSCAN_PREFLIGHT_DB points at a `.backup` COPY of a catalog (never the
// live file); otherwise it is SKIPPED, visibly — never a silent pass.
//
// Its own suite and file so the gauntlet can mark it blocked ("opt-in
// measurement") without splitting a counted suite; it is not in any stage's
// floor. Run it by hand:
//   python3 -c "import os,subprocess; subprocess.run(['swift','test','--package-path',
//     '<repo>/VideoScan/VideoScanCore','--filter','CatalogPreflightMeasure'],
//     env=dict(os.environ, VIDEOSCAN_PREFLIGHT_DB='<scratch>/pf.sqlite'))"
// after `sqlite3 "<App Support>/catalog.sqlite" ".backup '<scratch>/pf.sqlite'"`.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogPreflightMeasure")
struct CatalogPreflightMeasureTests {

    static let environmentKey = "VIDEOSCAN_PREFLIGHT_DB"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[environmentKey] != nil,
                   "set VIDEOSCAN_PREFLIGHT_DB to a .backup copy of a catalog"))
    func measureOnACatalogCopy() throws {
        let path = try #require(ProcessInfo.processInfo.environment[Self.environmentKey])
        let url = URL(fileURLWithPath: path)
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> String { String(format: "%.1f ms", TimingBudget.seconds(d) * 1_000) }
        var lines: [String] = []
        for round in 1...3 {
            let schema = clock.measure { _ = try? CatalogPreflightReader.schemaVersion(at: url) }
            var outcome: PreflightQuickCheckOutcome?
            let quick = clock.measure { outcome = try? CatalogPreflightReader.quickCheck(at: url, budget: .seconds(10)) }
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            let integrity = try clock.measure { _ = try queue.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } }
            let foreignKeys = try clock.measure { _ = try queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") } }
            try queue.close()
            lines.append("round \(round): schema \(ms(schema)), quick_check \(ms(quick)) [\(outcome.map { "\($0)" } ?? "threw")], "
                         + "integrity_check \(ms(integrity)), foreign_key_check \(ms(foreignKeys))")
        }
        print("[preflight-measure] \(url.lastPathComponent):\n" + lines.joined(separator: "\n"))
    }
}
