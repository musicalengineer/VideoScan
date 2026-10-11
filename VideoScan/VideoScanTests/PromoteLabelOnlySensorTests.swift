// PromoteLabelOnlySensorTests.swift
// SENSOR for tab-charter audit T2 (2026-10-11): "Promote" had two
// label-only implementations — Triage's Archive button
// (TriageView.promoteSelectedToArchive) and Under Construction's Promote
// (VideoScanModel.promoteWorkbenchToArchive) set `lifecycleStage = .archived`
// and copied nothing. The file left Triage, its dates froze, and the
// Archive tab never saw it. Both now go through the one Promote engine
// (`requestPromote` → PromoteToArchiveJob).
//
// This pins it at the source: in the app and VideoScanCore sources, a
// literal assignment of `.archived` to `lifecycleStage` may appear ONLY in
// the allowlisted writers below, at exactly the counts listed. A new
// writer anywhere — or a second one in an allowlisted file — fails here
// and has to explain itself.
//
// (For Rick: this is a grep with teeth — the test reads the .swift files
// themselves, the way a lint rule would, rather than running the code.)

import Foundation
import Testing

@Suite("Promote — no label-only promote (audit T2 sensor)")
struct PromoteLabelOnlySensorTests {

    /// path (relative to its source root) → literal `.archived` writers.
    static let allowlist: [String: Int] = [
        // The Promote engine's job completion: the verified archive copy's
        // record (registerPromotedCopy, registerOrphanPromotedCopy).
        "Archive/VideoScanModel+MasterArchive.swift": 2,
        // Load-time legacy migration (audit P4): a record whose
        // archiveStage is already >= .masterAssigned gets the stage field it
        // predates. Goes once the legacy stamps are migrated.
        "Model/VideoScanModel.swift": 1,
    ]

    /// `lifecycleStage = .archived`, `= LifecycleStage.archived`, or the
    /// labelled-argument form `lifecycleStage: .archived`. Never `==`/`!=`.
    static let writerPattern = #"\blifecycleStage\s*(=|:)\s*(LifecycleStage)?\.archived\b"#

    static var coreSourceRoot: URL {
        SourceTree.appSourceRoot.deletingLastPathComponent()
            .appendingPathComponent("VideoScanCore/Sources", isDirectory: true)
    }

    /// Code with comments removed; a file the stripper can't read is
    /// scanned with only whole-line `//` comments dropped (more text, never
    /// less — so it can only over-report, never hide a writer).
    static func code(_ text: String) -> String {
        let scanned = SourceTree.scan(text)
        if scanned.unsupported.isEmpty { return scanned.code }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func writerCount(in text: String) throws -> Int {
        let c = code(text)
        let writer = try NSRegularExpression(pattern: writerPattern)
        return writer.numberOfMatches(in: c, range: NSRange(c.startIndex..., in: c))
    }

    static func swiftFiles(under root: URL) -> [(relative: String, url: URL)] {
        let base = SourceTree.canonicalPath(root) + "/"
        var out: [(String, URL)] = []
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let full = SourceTree.canonicalPath(url)
            if full.hasPrefix(base) { out.append((String(full.dropFirst(base.count)), url)) }
        }
        return out
    }

    @Test("the pattern sees every writer shape and no comparison")
    func patternSelfTest() throws {
        #expect(try Self.writerCount(in: "rec.lifecycleStage = .archived") == 1)
        #expect(try Self.writerCount(in: "r.lifecycleStage=LifecycleStage.archived") == 1)
        #expect(try Self.writerCount(in: "VideoRecord(lifecycleStage: .archived)") == 1)
        #expect(try Self.writerCount(in: "if r.lifecycleStage == .archived { }") == 0)
        #expect(try Self.writerCount(in: "if r.lifecycleStage != .archived { }") == 0)
        #expect(try Self.writerCount(in: "// rec.lifecycleStage = .archived") == 0)
        #expect(try Self.writerCount(in: "rec.lifecycleStage = .archivedSomething") == 0)
    }

    @Test("outside the allowlisted writers, nothing stamps lifecycleStage = .archived")
    func onlyTheEngineAndTheMigrationStampArchived() throws {
        var found: [String: Int] = [:]
        var scanned = 0
        for root in [SourceTree.appSourceRoot, Self.coreSourceRoot] {
            for file in Self.swiftFiles(under: root) {
                scanned += 1
                let n = try Self.writerCount(in: try String(contentsOf: file.url, encoding: .utf8))
                if n > 0 { found[file.relative, default: 0] += n }
            }
        }
        #expect(scanned > 500, "the sensor must read the real source trees (read \(scanned) files)")
        #expect(found == Self.allowlist, """
            lifecycleStage = .archived writers changed: \(found.sorted { $0.key < $1.key }). \
            A file is archived only through the Promote engine (requestPromote → PromoteToArchiveJob); \
            never stamp the stage from a button.
            """)
    }

    @Test("Triage's Archive and Under Construction's Promote call the one Promote door")
    func bothDoorsCallTheEngine() throws {
        let triage = try SourceTree.appCode(named: "TriageView.swift")
        let start = try #require(triage.range(of: "private func promoteSelectedToArchive()"))
        let body = triage[start.upperBound...].prefix(400)
        #expect(body.contains("model.requestPromote(records:"))
        let workbench = try SourceTree.appCode(named: "VideoScanModel+Workbench.swift")
        let wStart = try #require(workbench.range(of: "func promoteWorkbenchToArchive("))
        #expect(workbench[wStart.upperBound...].prefix(200).contains("requestPromote(records:"))
        let catalog = try SourceTree.appCode(named: "CatalogContent+Promote.swift")
        #expect(catalog.contains("model.requestPromote(records: activeRecs)"))
    }
}
