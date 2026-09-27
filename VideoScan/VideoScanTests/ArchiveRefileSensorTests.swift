// ArchiveRefileSensorTests.swift
// SENSOR (feature-test checklist item 5) for Refile: the Master Archive
// stays near read-only. Refile is the ONLY new FamilyArchive write path,
// and it goes through the explicit, audited exception
// (ArchiveRefileAuthorization) — pinned here against the SOURCE, so a
// second mover, a second grant site, a copy + delete, or a placement rule
// that forks from Promote's fails the suite. (The whole-app inventory of
// no-clobber renames lives in ArchiveVolumeProtectionSourceSensor.)

import Foundation
import Testing

@Suite("Archive Refile — source sensor")
struct ArchiveRefileSensorTests {

    private static var appDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Non-comment lines only.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Per app source file (recursive), occurrences of `needle` in code lines.
    private static func sites(of needle: String) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let names = try FileManager.default.subpathsOfDirectory(atPath: appDir.path).filter { $0.hasSuffix(".swift") }
        for name in names {
            let text = code(try String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8))
            let n = text.components(separatedBy: needle).count - 1
            if n > 0 { out[name] = n }
        }
        return out
    }

    @Test("the archive write exception is granted in exactly ONE place: the model's refile")
    func oneGrantSite() throws {
        #expect(try Self.sites(of: "ArchiveRefileAuthorization.grant(") == ["VideoScanModel+ArchiveRefile.swift": 1])
    }

    @Test("the refile engine runs from exactly ONE place, and only with a grant it re-checks")
    func oneEngineCallSite() throws {
        #expect(try Self.sites(of: "ArchiveRefileEngine.execute(") == ["VideoScanModel+ArchiveRefile.swift": 1])
        let engine = Self.code(try Self.source("ArchiveRefile.swift"))
        #expect(engine.contains("authorization: ArchiveRefileAuthorization,"), "execute requires the grant")
        #expect(engine.contains("guard authorization.covers(rootPath: root, fromRelPath: from, toRelPath: to) else {"))
        // The grant's constructor is private — only `grant` makes one.
        let guardFile = try Self.source("ArchiveVolumeProtection.swift")
        #expect(guardFile.contains("    private init(rootPath: String, fromRelPath: String, toRelPath: String, reason: String, grantedAt: Date) {"))
    }

    @Test("Refile renames, never copies + deletes, never clobbers")
    func renameNotCopy() throws {
        for file in ["ArchiveRefile.swift", "VideoScanModel+ArchiveRefile.swift", "ArchiveRefileSheet.swift"] {
            let text = Self.code(try Self.source(file))
            for banned in ["moveItem(", "copyItem(", "removeItem(", "unlink(", "unlinkat(", "trashItem(", "copyfile(", "clonefile("] {
                #expect(!text.contains(banned), "\(file) must not call \(banned)")
            }
        }
        let engine = Self.code(try Self.source("ArchiveRefile.swift"))
        let renames = engine.split(separator: "\n").filter { $0.contains("renameatx_np(") }
        #expect(renames.count == 2, "the move and the move back")
        #expect(renames.allSatisfy { $0.contains("UInt32(RENAME_EXCL)") }, "no-clobber, same volume (EXDEV refuses)")
    }

    @Test("the refile target comes from Promote's placement function, not a copy of it")
    func onePlacementFunction() throws {
        let engine = Self.code(try Self.source("ArchiveRefile.swift"))
        let body = try #require(engine.range(of: "static func targetRelPath(")).upperBound
        let next = engine[body...].range(of: "static func ")?.lowerBound ?? engine.endIndex
        #expect(engine[body..<next].contains("ArchivePathResolver.baseRelativePath(facts: facts, title: title)"))
        let promote = Self.code(try Self.source("PromoteToArchiveJob+Steps.swift"))
        #expect(promote.contains("ArchivePathResolver.baseRelativePath(facts: facts, title: title)"),
                "Promote's destination chooser starts from the same function")
        // The filing-year guard is ONE function, asked by both.
        #expect(promote.contains("ArchivePathResolver.filingYearRefusal(facts: facts)"))
        let preview = Self.code(try Self.source("VideoScanModel+ArchiveRefile.swift"))
        #expect(preview.contains("ArchivePathResolver.filingYearRefusal("))
    }

    @Test("every refile outcome writes an audit line through the one sink")
    func auditLines() throws {
        let model = Self.code(try Self.source("VideoScanModel+ArchiveRefile.swift"))
        #expect(model.contains("appLog.write(\"[refile] \" + line)"), "videoscan.log")
        #expect(model.contains("        log(line)\n"), "console + catalog.log")
        for needle in ["— BEGIN ", "— refused: ", "— ROLLED BACK: ", "— FAILED AND COULD NOT BE FULLY UNDONE: ",
                       "fixity verified; index updated"] {
            #expect(model.contains(needle), "missing audit line: \(needle)")
        }
        #expect(model.contains("ledgerEvent(.refiled,") && model.contains("ledgerEvent(.refileRolledBack,"))
    }
}
