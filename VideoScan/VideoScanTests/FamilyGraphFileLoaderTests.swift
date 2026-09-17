import Foundation
import Testing
@testable import VideoScan

struct FamilyGraphFileLoaderTests {
    @Test func newestModificationDateWinsAndOutsidePoisonIsIgnored() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FamilyGraphLoader-\(UUID().uuidString)")
        let originals = sandbox.appendingPathComponent("originals")
        let poison = sandbox.appendingPathComponent("poison")
        try FileManager.default.createDirectory(
            at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: poison, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let older = originals.appendingPathComponent("zzz-older.ged")
        let newer = originals.appendingPathComponent("aaa-newer.GED")
        let outside = poison.appendingPathComponent("poison.ged")
        let outsideLink = originals.appendingPathComponent("newest-link.ged")
        try gedcom(names: ["Older Person"]).write(
            to: older, atomically: true, encoding: .utf8)
        try gedcom(names: ["Newer Person", "Second Person"]).write(
            to: newer, atomically: true, encoding: .utf8)
        try gedcom(names: ["Poison One", "Poison Two", "Poison Three"]).write(
            to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: outsideLink, withDestinationURL: outside)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: outside.path)

        let graph = try #require(
            FamilyGraphFileLoader(originalsDirectory: originals).loadNewest())

        #expect(graph.people.count == 2)
        #expect(graph.people(matching: "Newer").count == 1)
        #expect(graph.people(matching: "Poison").isEmpty)
    }

    @Test func missingOrEmptyInjectedDirectoryReturnsNil() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MissingFamilyGraph-\(UUID().uuidString)")
        #expect(FamilyGraphFileLoader(
            originalsDirectory: missing).loadNewest() == nil)

        try FileManager.default.createDirectory(
            at: missing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missing) }
        try "not a GEDCOM".write(
            to: missing.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8)
        #expect(FamilyGraphFileLoader(
            originalsDirectory: missing).loadNewest() == nil)
    }

    @Test func corruptNewestIsReportedAndOlderValidGEDCOMIsUsed() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FamilyGraphFallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let older = sandbox.appendingPathComponent("valid.ged")
        let newer = sandbox.appendingPathComponent("broken.ged")
        try gedcom(names: ["Valid Person"]).write(
            to: older, atomically: true, encoding: .utf8)
        try Data([0xff, 0xfe, 0xfd]).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path)

        let outcome = FamilyGraphFileLoader(
            originalsDirectory: sandbox).loadNewestOutcome()
        #expect(outcome.graph?.people(matching: "Valid").count == 1)
        #expect(outcome.selectedURL?.resolvingSymlinksInPath()
            == older.resolvingSymlinksInPath())
        #expect(outcome.rejectedURLs.map { $0.resolvingSymlinksInPath() }
            == [newer.resolvingSymlinksInPath()])
        #expect(outcome.candidateCount == 2)
    }

    @Test func zeroPersonGEDCOMIsRejectedInsteadOfDisplayedAsLive() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FamilyGraphEmpty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let empty = sandbox.appendingPathComponent("empty.ged")
        try "0 HEAD\n0 TRLR".write(to: empty, atomically: true, encoding: .utf8)

        let outcome = FamilyGraphFileLoader(
            originalsDirectory: sandbox).loadNewestOutcome()
        #expect(outcome.graph == nil)
        #expect(outcome.rejectedURLs.map { $0.resolvingSymlinksInPath() }
            == [empty.resolvingSymlinksInPath()])
    }


    /// 2026-09-17, from the live incident: Rick's tree narrowed 39,250 -> 16,383
    /// and his wife's whole line vanished. The compiled generation recorded TWO
    /// physical pulls; only one of them sits in the scanned directory (the other
    /// lives in a `pulls/` subdirectory on the RAID, which the non-recursive
    /// listing never sees). When the pointer stopped being usable for ANY reason
    /// other than a codec/schema bump, rule 3 did not fire and rule 4 rebuilt the
    /// tree from the single visible file.
    ///
    /// Rule 3's own docstring is the rule being broken here: "never silently
    /// demote N pulls to one" (codex #826).
    @Test func anIntactMultiSourceGenerationOutranksTheOneVisibleFile() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FamilyGraphLoader-\(UUID().uuidString)")
        let originals = sandbox.appendingPathComponent("originals")
        let pulls = originals.appendingPathComponent("pulls")
        let compiled = sandbox.appendingPathComponent("compiled")
        try FileManager.default.createDirectory(at: pulls, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Rick's pull sits where the loader looks; Donna's sits one level down,
        // exactly as on the RAID.
        let rickFile = originals.appendingPathComponent("familysearch-rick.ged")
        let donnaFile = pulls.appendingPathComponent("familysearch-donna.ged")
        try gedcom(names: ["Rick Breen"]).write(to: rickFile, atomically: true, encoding: .utf8)
        try gedcom(names: ["Donna Breen", "Eileen Latta"]).write(to: donnaFile, atomically: true, encoding: .utf8)

        // A real two-source generation, promoted, recording BOTH paths.
        var store = FamilyGraphCompiledStore(root: compiled)
        let logLines = LogBox()
        store.log = { logLines.add($0) }
        // Built through the production path, so the artifact's provenance really
        // does bind to both files (codex #816/#817) -- a hand-made graph is
        // refused by ingest, correctly.
        var builder = FamilyGraphFileLoader(originalsDirectory: originals)
        builder.compiledStore = store
        let both = try #require(builder.recompile(sources: [rickFile, donnaFile]),
                                "recompile refused: \(logLines.joined)")
        #expect(both.people.count == 3)
        let good = try #require(store.readPointer()?.current)

        // Now break the pointer the way the test-fixture pollution did: it names
        // a generation that cannot be loaded. Both real sources are untouched.
        var broken = try #require(store.readPointer())
        broken.current = "gen-00000000T000000-dead"
        broken.previous = nil
        try JSONEncoder().encode(broken).write(to: store.pointerURL)
        #expect(store.loadCurrent() == nil, "precondition: the pointer must be unusable")

        var loader = FamilyGraphFileLoader(originalsDirectory: originals)
        loader.compiledStore = store
        let outcome = loader.loadNewestOutcome()
        let graph = try #require(outcome.graph, "the loader returned no tree at all")

        // The whole point: Donna's line must not disappear because her file is
        // one directory down. Before the fix this returns 1 person -- Rick alone.
        #expect(graph.people.count == 3,
                "narrowed to \(graph.people.count) people; the intact 2-source generation was demoted to the one visible file")
        #expect(!graph.people(matching: "Donna").isEmpty, "Donna's line was dropped")
        #expect(store.readPointer()?.current == good, "the loader should have repointed at the intact generation")
    }


    /// The other half of rule 3b: protecting an N-source generation must not
    /// pin the tree to it forever. A pull genuinely installed AFTER that
    /// generation was compiled still wins, exactly as rule 1 would have let
    /// it. Without this the fix for the narrowing would quietly ignore every
    /// new .ged whenever the pointer was unusable.
    @Test func aPullInstalledAfterTheGenerationStillWins() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FamilyGraphLoader-\(UUID().uuidString)")
        let originals = sandbox.appendingPathComponent("originals")
        let pulls = originals.appendingPathComponent("pulls")
        let compiled = sandbox.appendingPathComponent("compiled")
        try FileManager.default.createDirectory(at: pulls, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let rickFile = originals.appendingPathComponent("familysearch-rick.ged")
        let donnaFile = pulls.appendingPathComponent("familysearch-donna.ged")
        try gedcom(names: ["Rick Breen"]).write(to: rickFile, atomically: true, encoding: .utf8)
        try gedcom(names: ["Donna Breen", "Eileen Latta"]).write(to: donnaFile, atomically: true, encoding: .utf8)

        var store = FamilyGraphCompiledStore(root: compiled)
        let logLines = LogBox()
        store.log = { logLines.add($0) }
        var builder = FamilyGraphFileLoader(originalsDirectory: originals)
        builder.compiledStore = store
        _ = try #require(builder.recompile(sources: [rickFile, donnaFile]),
                         "recompile refused: \(logLines.joined)")

        var broken = try #require(store.readPointer())
        broken.current = "gen-00000000T000000-dead"
        broken.previous = nil
        try JSONEncoder().encode(broken).write(to: store.pointerURL)

        // A fresh pull, installed after the generation was compiled.
        let fresh = originals.appendingPathComponent("familysearch-refreshed.ged")
        try gedcom(names: ["Newly Pulled One", "Newly Pulled Two",
                           "Newly Pulled Three", "Newly Pulled Four"])
            .write(to: fresh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: fresh.path)

        var loader = FamilyGraphFileLoader(originalsDirectory: originals)
        loader.compiledStore = store
        let graph = try #require(loader.loadNewestOutcome().graph)

        #expect(graph.people.count == 4,
                "the newer pull was ignored in favour of the protected generation")
        #expect(!graph.people(matching: "Newly Pulled").isEmpty)
    }

    private func gedcom(names: [String]) -> String {
        var lines: [String] = ["0 HEAD"]
        for (index, name) in names.enumerated() {
            lines.append("0 @I\(index + 1)@ INDI")
            lines.append("1 NAME \(name)")
        }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }
}

/// Collects store log lines so a failed expectation can say why.
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: " | ") }
}
