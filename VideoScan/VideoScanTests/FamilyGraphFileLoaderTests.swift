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
