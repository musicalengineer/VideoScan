// ArchiveHelperRetiredSensorTests.swift
// Archive Angel consolidation S4 (Rick 2026-09-22): the old Promote Helper
// is gone — one module, the Archive Angel, recommends, prepares and
// promotes. This sensor fails if any USER-FACING string in the app names
// the Helper again (a label, help text, log line a person reads, or its
// retired accessibility ids). Comments are stripped first: history notes
// that say "the Archive Helper did X" are allowed and encouraged.

import Foundation
import Testing

@Suite("Archive Helper retired — no user-facing string names it")
struct ArchiveHelperRetiredSensorTests {

    /// What a person could see (or a UI test could click) if the Helper
    /// came back. Case-sensitive: these are the exact spellings it used.
    static let forbidden = ["Archive Helper", "Promote Helper", "Helper…", "archiveHelper.",
                            "catalog.row.assessCopies", "assessCopies.detail"]

    static func hits(in code: String) -> [String] {
        forbidden.filter { code.contains($0) }
    }

    @Test("no app source outside comments contains a Helper name or id")
    func noUserFacingHelperStrings() {
        let app = ArchiveAngelBoundarySensorTests.appDir()
        let files = ArchiveAngelBoundarySensorTests.swiftFiles(under: app)
        #expect(files.count > 300, "the scan must see the app (\(files.count) files)")
        var found: [String] = []
        for url in files {
            let code = ArchiveAngelBoundarySensorTests.code(of: url)
            for h in Self.hits(in: code) {
                found.append("\(ArchiveAngelBoundarySensorTests.relative(url, to: app)): \(h)")
            }
        }
        #expect(found.isEmpty, "the retired Helper is named again: \(found)")
    }

    @Test("the sensor catches a planted label, and ignores the same words in a comment")
    func catchesPlanted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-sensor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Planted.swift")
        try """
        // The Archive Helper used to live here (history — allowed).
        Button("Archive Helper…") { }
        """.write(to: f, atomically: true, encoding: .utf8)
        let code = ArchiveAngelBoundarySensorTests.code(of: f)
        #expect(Self.hits(in: code) == ["Archive Helper", "Helper…"])
    }
}
