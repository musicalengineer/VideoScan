// ArchiveUpdateSensorTests.swift
// SENSOR (feature-test checklist item 5) for Update… (the Refile engine): the Master Archive
// stays near read-only. Refile is the ONLY new FamilyArchive write path,
// and it goes through the explicit, audited exception
// (ArchiveRefileAuthorization) — pinned here against the SOURCE, so a
// second mover, a second grant site, a copy + delete, or a placement rule
// that forks from Promote's fails the suite. (The whole-app inventory of
// no-clobber renames lives in ArchiveVolumeProtectionSourceSensor.)

import Foundation
import Testing

@Suite("Archive Update — source sensor")
struct ArchiveUpdateSensorTests {

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

    @Test("the archive write exception is granted in exactly ONE place: the model's Update")
    func oneGrantSite() throws {
        #expect(try Self.sites(of: "ArchiveRefileAuthorization.grant(") == ["VideoScanModel+ArchiveUpdate.swift": 1])
    }

    @Test("the refile engine runs from exactly ONE place, and only with a grant it re-checks")
    func oneEngineCallSite() throws {
        #expect(try Self.sites(of: "ArchiveRefileEngine.execute(") == ["VideoScanModel+ArchiveUpdate.swift": 1])
        let engine = Self.code(try Self.source("ArchiveRefile.swift"))
        #expect(engine.contains("authorization: ArchiveRefileAuthorization,"), "execute requires the grant")
        #expect(engine.contains("guard authorization.covers(rootPath: root, fromRelPath: from, toRelPath: to) else {"))
        // The grant's constructor is private — only `grant` makes one.
        let guardFile = try Self.source("ArchiveVolumeProtection.swift")
        #expect(guardFile.contains("    private init(rootPath: String, fromRelPath: String, toRelPath: String, reason: String, grantedAt: Date) {"))
    }

    @Test("Refile renames, never copies + deletes, never clobbers")
    func renameNotCopy() throws {
        for file in ["ArchiveRefile.swift", "VideoScanModel+ArchiveUpdate.swift", "ArchiveUpdateSheet.swift"] {
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

    @Test("the Update target comes from Promote's placement pieces, not a copy of them")
    func onePlacementFunction() throws {
        let engine = Self.code(try Self.source("ArchiveRefile.swift"))
        // A new place is built from Promote's own pieces — its folder rule,
        // its filename prefix and its slug — never a copy of them.
        let body = try #require(engine.range(of: "static func updatedRelPath(")).upperBound
        let next = engine[body...].range(of: "static func ")?.lowerBound ?? engine.endIndex
        for piece in ["ArchivePathResolver.folder(for:", "hint.filenamePrefix", "ArchivePathResolver.slug(from:"] {
            #expect(engine[body..<next].contains(piece), "updatedRelPath must use \(piece)")
        }
        let promote = Self.code(try Self.source("PromoteToArchiveJob+Steps.swift"))
        #expect(promote.contains("ArchivePathResolver.baseRelativePath(facts: facts, title: title)"),
                "Promote's destination chooser starts from the same function")
        // The filing-year guard is ONE function, asked by both.
        #expect(promote.contains("ArchivePathResolver.filingYearRefusal(facts: facts)"))
        let preview = Self.code(try Self.source("VideoScanModel+ArchiveUpdate.swift"))
        #expect(preview.contains("ArchivePathResolver.filingYearRefusal("))
    }

    @Test("ONE index-write lock: every 00_Index appender and the whole-file rewrite hold it (codex review #1)")
    func everyIndexWriterHoldsTheLock() throws {
        let lockSites = try Self.sites(of: "ArchiveIndexLock.withExclusive(")
        #expect(lockSites == ["MasterArchive.swift": 1, "ArchivePromoteEngine.swift": 1,
                              "ArchivePromoteDecisions.swift": 1, "VideoScanModel+BackupAttestations.swift": 1,
                              "ArchiveIndexRename.swift": 1,
                              // Not a writer: the one-time lock catch-up holds it per file so it
                              // can never flag a file mid-Update (codex r1 #1 on promote-dates-and-lock).
                              "ArchiveLockJob.swift": 1], "\(lockSites)")
        // An index append is `appendDurable(fd:` — exactly the four above.
        let appends = try Self.sites(of: "ArchivePromoteEngine.appendDurable(fd:")
        #expect(appends == ["MasterArchive.swift": 1, "ArchivePromoteEngine.swift": 1,
                            "ArchivePromoteDecisions.swift": 1, "VideoScanModel+BackupAttestations.swift": 1],
                "a new 00_Index appender must take ArchiveIndexLock: \(appends)")
    }

    @Test("every Update outcome writes an audit line through the one sink")
    func auditLines() throws {
        let model = Self.code(try Self.source("VideoScanModel+ArchiveUpdate.swift"))
        #expect(model.contains("appLog.write(\"[archive-update] \" + line)"), "videoscan.log")
        #expect(model.contains("        log(line)\n"), "console + catalog.log")
        for needle in ["— BEGIN ", "— refused: ", "— ROLLED BACK: ", "— FAILED AND COULD NOT BE FULLY UNDONE: ",
                       "fixity verified; index updated"] {
            #expect(model.contains(needle), "missing audit line: \(needle)")
        }
        #expect(model.contains("ledgerEvent(.archiveUpdated,") && model.contains("ledgerEvent(.archiveUpdateRolledBack,"))
        // Rick 2026-09-27: no retry journal, no replay; THIS record only.
        for gone in ["pending-refiles", "replayPending", "promotionSource(of: copy)"] {
            #expect(!model.contains(gone), "Update must not bring back \(gone)")
        }
    }
}
