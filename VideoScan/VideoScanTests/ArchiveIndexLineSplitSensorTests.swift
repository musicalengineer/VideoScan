// ArchiveIndexLineSplitSensorTests.swift
// Sensor for the CRLF bug class in archive-index readers.
//
// In Swift "\r\n" is ONE Character, so a Character-"\n" split
// (`split(separator: "\n")`, `whereSeparator: { $0 == "\n" }`) never
// separates CRLF records: a CRLF manifest or journal reads as one giant
// line and rows are silently dropped (codex r2 #3). Every reader of
// `00_Index/` text goes through ArchiveIndexText.lines instead.
//
// Pure source scan (no build products, no model): a file that reads the
// archive index — it calls `openIndexFile(`, `readAll(fd:` or
// `ArchiveManifestCSV.fields(ofLine` — must not split on "\n" itself.
// The reverse check pins the known readers to the helper so the list
// cannot rot silently. Also a few direct contract checks on the helper.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive index line-split sensor (CRLF)")
struct ArchiveIndexLineSplitSensorTests {

    /// Every file known to split archive-index text, and the reader in it.
    static let knownReaders: [String: String] = [
        "ArchiveLockJob.swift":                    "ArchiveLockJob.plan (manifest)",
        "MasterArchive.swift":                     "ArchiveManifestCSV.fieldRowsBySource (manifest)",
        "VerifyArchiveCopiesJob.swift":            "VerifyArchiveManifestIndex.parse (manifest)",
        "VideoScanModel+ArchivedAtBackfill.swift": "ArchivedAtBackfill.manifestDates (manifest)",
        "ArchiveRefile.swift":                     "ArchiveRefile.parseRows (manifest)",
        "ArchivePromoteEngine.swift":              "ArchivePromoteJournal.latestBySource (promote journal)",
        "VideoScanModel+BackupAttestations.swift": "ArchiveAttestationJournal.entries (attestation journal)",
    ]

    /// `<repo>/VideoScan` — app target, Core package and this test target.
    static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func sourceFiles() throws -> [URL] {
        let roots = [projectRoot.appendingPathComponent("VideoScan", isDirectory: true),
                     projectRoot.appendingPathComponent("VideoScanCore/Sources", isDirectory: true)]
        var out: [URL] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" { out.append(url) }
        }
        try #require(out.count > 100, "source scan found only \(out.count) files under \(projectRoot.path)")
        return out
    }

    /// Code with line comments removed (comments talk about the bug freely).
    static func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }
    }

    static var indexReadMarker: NSRegularExpression {
        try! NSRegularExpression(pattern: #"openIndexFile\(|readAll\(fd:|ArchiveManifestCSV\.fields\(ofLine"#)
    }
    /// A Character-"\n" split: `split(separator: "\n"`, a `whereSeparator`
    /// closure comparing to "\n", or `components(separatedBy: "\n")`.
    static var newlineSplit: NSRegularExpression {
        try! NSRegularExpression(pattern: #"split\(separator:\s*"\\n"|\$0\s*==\s*"\\n"|components\(separatedBy:\s*"\\n"\)"#)
    }

    static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    @Test("no archive-index reader splits on Character \"\\n\" outside ArchiveIndexText")
    func noRawNewlineSplitInIndexReaders() throws {
        var readers: Set<String> = []
        var hits: [String] = []
        let marker = Self.indexReadMarker, split = Self.newlineSplit
        for url in try Self.sourceFiles() where url.lastPathComponent != "ArchiveIndexText.swift" {
            let lines = Self.codeLines(try String(contentsOf: url, encoding: .utf8))
            guard lines.contains(where: { Self.matches(marker, $0) }) else { continue }
            readers.insert(url.lastPathComponent)
            for (i, code) in lines.enumerated() where Self.matches(split, code) {
                hits.append("\(url.lastPathComponent):\(i + 1): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(readers.count >= 8, "the index-reader scan found only \(readers.sorted()) — the marker regex has rotted")
        #expect(hits.isEmpty, """
            Character-"\\n" split in a file that reads 00_Index text. "\\r\\n" is ONE Character in \
            Swift, so this never splits CRLF records — use ArchiveIndexText.lines(_:) instead:
            \(hits.joined(separator: "\n"))
            """)
    }

    @Test("every known index reader still routes through ArchiveIndexText.lines")
    func knownReadersUseTheHelper() throws {
        let files = Dictionary(try Self.sourceFiles().map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, reader) in Self.knownReaders.sorted(by: { $0.key < $1.key }) {
            guard let url = files[name] else { Issue.record("\(name) (\(reader)) is gone — update knownReaders"); continue }
            let code = Self.codeLines(try String(contentsOf: url, encoding: .utf8)).joined(separator: "\n")
            #expect(code.contains("ArchiveIndexText.lines("), "\(name): \(reader) no longer uses ArchiveIndexText.lines")
        }
    }

    // MARK: Helper contract

    @Test("ArchiveIndexText.lines: LF, CRLF and mixed give the same lines; trailing CR dropped; mid-line CR kept")
    func helperContract() {
        let lf = "h\na\n\nb\n"
        let crlf = "h\r\na\r\n\r\nb\r\n"
        let mixed = "h\na\r\n\nb\r\n"
        for text in [lf, crlf, mixed] {
            #expect(ArchiveIndexText.lines(text) == ["h", "a", "b"], "\(text.debugDescription)")
            #expect(ArchiveIndexText.lines(text, omittingEmpty: false) == ["h", "a", "", "b", ""], "\(text.debugDescription)")
        }
        #expect(ArchiveIndexText.lines("a\r") == ["a"], "a lone trailing CR (file ends mid-CRLF) is dropped")
        #expect(ArchiveIndexText.lines("a\rb\nc") == ["a\rb", "c"], "a mid-line CR is not a terminator")
        #expect(ArchiveIndexText.lines("").isEmpty)
        #expect(ArchiveIndexText.lines("", omittingEmpty: false) == [""], "matches split(omittingEmptySubsequences: false)")
        // For LF-only text the helper is exactly the old split.
        let old = lf.split(separator: "\n").map(String.init)
        #expect(ArchiveIndexText.lines(lf).map(String.init) == old)
    }

    @Test("scale: 100k CRLF manifest rows split within a load-aware budget")
    func helperScale() {
        let row = "2026-09-27T00:00:00Z,30_Video/x.mov,ab,1,/x,t,\(UUID()),\(UUID()),,,,3"
        let text = String(repeating: row + "\r\n", count: 100_000)
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = ArchiveIndexText.lines(text).count }
        #expect(count == 100_000)
        #expect(elapsed < .seconds(10), "100k-row split took \(elapsed)")
    }
}
