import XCTest
@testable import VideoScan

/// Scale sensor: a real 20-generation FamilySearch export (16,383 people,
/// 1.4M lines, 70 MB) must parse and install within budget. Skips when the
/// archive volume is not mounted so it never fails a laptop run.
final class GedcomScaleSensorTests: XCTestCase {
    static let bigTree = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged")

    func testSeventyMegabyteGedcomParsesWithinBudget() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path), "archive not mounted")
        let t0 = Date()
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        let parse = Date().timeIntervalSince(t0)
        print("SCALE parse: \(String(format: "%.2f", parse))s people=\(graph.people.count)")
        XCTAssertEqual(graph.people.count, 16383)
        XCTAssertLessThan(parse, 10, "parse budget (measured 2.4 s Release, 2026-08-26)")
    }

    @MainActor
    func testSeventyMegabyteGedcomInstallsWithinBudget() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path), "archive not mounted")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        let model = FamilyTreeLiveModel()
        let t0 = Date()
        model.install(graph: graph)
        let install = Date().timeIntervalSince(t0)
        print("SCALE install: \(String(format: "%.2f", install))s filtered=\(model.filteredPeople.count) cards=\(model.scene.cards.count)")
        XCTAssertLessThan(install, 2, "install/sort/refilter/layout budget (measured 0.08 s)")
        let t1 = Date()
        model.searchText = "Breen"
        print("SCALE search: \(String(format: "%.3f", Date().timeIntervalSince(t1)))s → \(model.filteredPeople.count)")
    }
}
