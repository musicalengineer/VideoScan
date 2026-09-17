import Foundation
import Testing
@testable import VideoScan

/// 2026-09-17: the morning a narrowing dropped Donna's entire line, the log
/// said nothing was wrong. `[hallie] family graph loaded` printed only
/// `selectedURL`, so a 39,250-person two-pull tree and a 16,383-person
/// one-pull tree looked the same in the log except for the count. The
/// instruments were failing the same way the product was.
@Suite("Family graph load logging", .serialized)
struct FamilyGraphLoadLoggingTests {
    @Test func theLoadLineNamesEverySourceNotJustTheFirst() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GraphLoadLog-\(UUID().uuidString)")
        let assets = sandbox.appendingPathComponent("40_Family_Tree")
        let gedcoms = assets.appendingPathComponent("GEDCOM")
        let storeRoot = sandbox.appendingPathComponent("compiled")
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        func gedcom(_ names: [String]) -> String {
            var lines = ["0 HEAD"]
            for (i, name) in names.enumerated() {
                lines.append("0 @I\(i + 1)@ INDI")
                lines.append("1 NAME \(name)")
            }
            lines.append("0 TRLR")
            return lines.joined(separator: "\n")
        }

        let rickFile = gedcoms.appendingPathComponent("familysearch-rick.ged")
        let donnaFile = gedcoms.appendingPathComponent("familysearch-donna.ged")
        try gedcom(["Rick Breen"]).write(to: rickFile, atomically: true, encoding: .utf8)
        try gedcom(["Donna Breen", "Eileen Latta"]).write(to: donnaFile, atomically: true, encoding: .utf8)

        let store = FamilyGraphCompiledStore(root: storeRoot)
        var builder = FamilyGraphFileLoader(originalsDirectory: gedcoms)
        builder.compiledStore = store
        _ = try #require(builder.recompile(sources: [rickFile, donnaFile]))

        let box = LoadLogBox()
        let cache = FamilyGraphSharedCache(log: { box.add($0) })
        let configuration = FamilyAssetConfiguration(
            roots: .init(assets: assets,
                         thumbnailCache: sandbox.appendingPathComponent("thumbs")),
            access: .readWrite,
            legacyGEDCOMDirectory: nil)
        _ = cache.load(for: configuration, store: store)

        let line = try #require(box.lines.first { $0.contains("family graph loaded") },
                                "no load line was logged: \(box.lines.joined(separator: " | "))")

        // The count, so a narrowing is visible at a glance...
        #expect(line.contains("2 sources"), "the load line did not say how many sources: \(line)")
        // ...and the names, so the log says WHICH pull went missing.
        #expect(line.contains("familysearch-rick.ged"), "first source not named: \(line)")
        #expect(line.contains("familysearch-donna.ged"),
                "the second pull is absent from the log -- the exact blindness that hid the narrowing: \(line)")
    }

    /// codex, P3 on b8c3793f: a plain parse (no compiled store, or a failed
    /// promotion) carries an EMPTY sourceProvenance with its one file recorded
    /// separately, so the raw list printed "0 sources: file.ged" -- a log line
    /// claiming the tree came from nowhere.
    @Test func aPlainParseReportsOneSourceNotZero() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GraphLoadLog-\(UUID().uuidString)")
        let assets = sandbox.appendingPathComponent("40_Family_Tree")
        let gedcoms = assets.appendingPathComponent("GEDCOM")
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var lines = ["0 HEAD"]
        for (i, name) in ["Rick Breen", "Donna Breen"].enumerated() {
            lines.append("0 @I\(i + 1)@ INDI")
            lines.append("1 NAME \(name)")
        }
        lines.append("0 TRLR")
        try lines.joined(separator: "\n").write(
            to: gedcoms.appendingPathComponent("only-one.ged"), atomically: true, encoding: .utf8)

        let box = LoadLogBox()
        let cache = FamilyGraphSharedCache(log: { box.add($0) })
        let configuration = FamilyAssetConfiguration(
            roots: .init(assets: assets,
                         thumbnailCache: sandbox.appendingPathComponent("thumbs")),
            access: .readWrite,
            legacyGEDCOMDirectory: nil)
        // No compiled store: the parse-every-time seam.
        _ = cache.load(for: configuration, store: nil)

        let line = try #require(box.lines.first { $0.contains("family graph loaded") },
                                "no load line was logged: \(box.lines.joined(separator: " | "))")
        #expect(line.contains("1 source:"), "a plain parse should report one source, not zero: \(line)")
        #expect(!line.contains("0 source"), "the load line claimed the tree came from nowhere: \(line)")
        #expect(line.contains("only-one.ged"), "the source file was not named: \(line)")
    }

    /// codex also asked for the one-physical/two-logical case. It is not a
    /// hypothetical shape: a merged tree exported to a single .ged and read
    /// back carries `_VS_MERGED Y` plus a `_VS_SOURCE` per original pull, so
    /// it has ONE physical source (the file) and TWO logical ones (the pulls).
    ///
    /// The count must follow the LOGICAL list -- that is what a narrowing
    /// drops, and the whole point of this line -- but the log must still say
    /// which file was actually read, or a reader cannot find it on disk.
    @Test func aMergedExportNamesBothPullsAndTheFileItWasReadFrom() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GraphLoadLog-\(UUID().uuidString)")
        let assets = sandbox.appendingPathComponent("40_Family_Tree")
        let gedcoms = assets.appendingPathComponent("GEDCOM")
        try FileManager.default.createDirectory(at: gedcoms, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let merged = """
        0 HEAD
        1 _VS_MERGED Y
        1 _VS_SOURCE familysearch-rick.ged
        2 _VS_DROPPED 0
        1 _VS_SOURCE familysearch-donna.ged
        2 _VS_DROPPED 0
        0 @I1@ INDI
        1 NAME Rick Breen
        0 @I2@ INDI
        1 NAME Donna Breen
        0 TRLR
        """
        try merged.write(to: gedcoms.appendingPathComponent("merged-tree.ged"),
                         atomically: true, encoding: .utf8)

        let box = LoadLogBox()
        let cache = FamilyGraphSharedCache(log: { box.add($0) })
        let configuration = FamilyAssetConfiguration(
            roots: .init(assets: assets,
                         thumbnailCache: sandbox.appendingPathComponent("thumbs")),
            access: .readWrite,
            legacyGEDCOMDirectory: nil)
        _ = cache.load(for: configuration, store: nil)

        let line = try #require(box.lines.first { $0.contains("family graph loaded") },
                                "no load line was logged: \(box.lines.joined(separator: " | "))")
        #expect(line.contains("2 sources"),
                "the count must follow the logical pulls, which is what a narrowing drops: \(line)")
        #expect(line.contains("familysearch-rick.ged") && line.contains("familysearch-donna.ged"),
                "both original pulls must be named: \(line)")
        #expect(line.contains("merged-tree.ged"),
                "the file actually read is not named, so nobody can find it on disk: \(line)")
    }
}

/// Collects log lines so an expectation can quote the line it judged.
final class LoadLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    func add(_ line: String) { lock.lock(); collected.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return collected }
}
