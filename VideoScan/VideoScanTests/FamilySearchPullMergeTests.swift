// FamilySearchPullMergeTests.swift
// "Add to current tree" on the Get Family Tree sheet (2026-08-27): the
// coordinator merges the verified export with the tree the loader reads,
// writes ONE new .ged next to the current one, and leaves both sources
// byte-for-byte untouched. ISOLATION: a temp GEDCOM folder; nothing near
// the archive. Same harness shape as FamilySearchPullLifecycleTests.

import Foundation
import XCTest
@testable import VideoScan
import VideoScanCore

@MainActor
final class FamilySearchPullMergeTests: XCTestCase {
    private struct SilentLauncher: FamilySearchPullLauncher { func open(_ url: URL) {} }

    private var root: URL!
    private var gedcomDirectory: URL!
    private var staging: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("fs-merge-\(UUID().uuidString)", isDirectory: true)
        gedcomDirectory = root.appendingPathComponent("GEDCOM", isDirectory: true)
        staging = root.appendingPathComponent("Downloads", isDirectory: true)
        for dir in [gedcomDirectory!, staging!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let rickPull = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 FAMS @F1@
    1 _FSFTID GVQV-NW3
    0 @I2@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 FAMS @F1@
    1 _FSFTID G2CL-86B
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    0 TRLR
    """
    private static let donnaPull = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 FAMC @F1@
    1 _FSFTID G2CL-86B
    0 @I2@ INDI
    1 NAME Walter /Hudson/
    1 SEX M
    1 FAMS @F1@
    1 _FSFTID DON1-DAD
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 TRLR
    """

    private func makeCoordinator() -> FamilySearchPullCoordinator {
        FamilySearchPullCoordinator(
            gedcomDirectory: gedcomDirectory,
            defaultUsername: "rick@example.com",
            scriptURL: staging.appendingPathComponent("get-family-tree.command"),
            locator: FamilySearchToolLocator(overridePath: "/nonexistent/getmyancestors"),
            launcher: SilentLauncher(),
            pollInterval: .milliseconds(30))
    }

    private func waitForReady(_ coordinator: FamilySearchPullCoordinator) async {
        for _ in 0..<200 {
            if case .ready = coordinator.phase { return }
            if case .failed = coordinator.phase { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAddToCurrentTreeWritesANewMergedFileAndLeavesSourcesUntouched() async throws {
        let fm = FileManager.default
        let current = gedcomDirectory.appendingPathComponent("familysearch-tree-20generations.ged")
        try Self.rickPull.write(to: current, atomically: true, encoding: .utf8)
        let download = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.donnaPull.write(to: download, atomically: true, encoding: .utf8)
        let currentBytes = try Data(contentsOf: current)
        let downloadBytes = try Data(contentsOf: download)

        let coordinator = makeCoordinator()
        coordinator.installFromFile(download)
        await waitForReady(coordinator)
        guard case .ready(_, _, let existing, _) = coordinator.phase else {
            return XCTFail("expected .ready, got \(coordinator.phase)")
        }
        XCTAssertEqual(existing?.people, 2)

        await coordinator.installMerged()
        guard case .installed(let merged, let people) = coordinator.phase else {
            return XCTFail("expected .installed, got \(coordinator.phase)")
        }
        XCTAssertEqual(people, 3, "Rick + Donna (once) + Walter")
        XCTAssertTrue(merged.lastPathComponent.hasPrefix("familysearch-merged-"))
        XCTAssertEqual(merged.deletingLastPathComponent().path, gedcomDirectory.path)
        // Sources untouched, byte for byte.
        XCTAssertEqual(try Data(contentsOf: current), currentBytes)
        XCTAssertEqual(try Data(contentsOf: download), downloadBytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: gedcomDirectory.path).count, 2)

        // The loader now reads the merged tree: Donna has her father, both roots named.
        let loaded = try XCTUnwrap(FamilyGraphFileLoader(originalsDirectory: gedcomDirectory).loadNewestOutcome())
        // /var vs /private/var: compare the resolved paths.
        XCTAssertEqual(loaded.selectedURL?.resolvingSymlinksInPath().path, merged.resolvingSymlinksInPath().path)
        let graph = try XCTUnwrap(loaded.graph)
        XCTAssertEqual(graph.roots.map(\.name), ["Richard Harding Breen Jr", "Donna Hudson"])
        XCTAssertEqual(graph.sourceFileNames, ["familysearch-tree-20generations.ged", "familysearch-donna-20generations.ged"])
        let donna = try XCTUnwrap(graph.person(familySearchID: "G2CL-86B"))
        XCTAssertEqual(graph.relatives(.father, of: donna).map(\.name), ["Walter Hudson"])
        XCTAssertEqual(graph.relatives(.husband, of: donna).map(\.name), ["Richard Harding Breen Jr"])
        let text = try String(contentsOf: merged, encoding: .utf8)
        XCTAssertTrue(text.contains("1 NOTE Merged by VideoScan on "))
        XCTAssertTrue(text.contains("1 _VS_ROOT @I1@\n1 _VS_ROOT @I2@"))
        XCTAssertTrue(text.contains("1 _FSFTID DON1-DAD"))
    }

    func testAddToCurrentTreeWithNoCurrentTreeFailsHonestly() async throws {
        let download = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.donnaPull.write(to: download, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator()
        coordinator.installFromFile(download)
        await waitForReady(coordinator)
        await coordinator.installMerged()
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("expected .failed, got \(coordinator.phase)")
        }
        XCTAssertTrue(message.contains("no current tree"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: gedcomDirectory.path).count, 0)
    }
}
