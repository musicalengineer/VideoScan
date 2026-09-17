// TreeLifecycleChainTests.swift
//
// THE GAP THAT LET THE 2026-09-16 P1 THROUGH.
//
// There were 1,069 GEDCOM/family-tree tests when a Refresh silently took
// Rick's tree from 39,250 people and two sources to 16,383 and one. Not one
// of them caught it, and the reason matters more than the count: every test
// asked "is this component correct?" — parse, merge, compile, verify — and
// each component WAS correct. The defect lived in the WIRING between them,
// where a loader was constructed without the store that lets it see a
// multi-source generation. No unit test of either side can see that.
//
// So these tests walk the whole chain on real files and assert about the
// SHAPE OF THE RESULT rather than the correctness of any step:
//
//     two pulls → ingest → promoted generation → load it back
//                        → merge a third pull in → load again
//
// and at every hop ask the only question that would have caught it: did the
// tree just get smaller, and does anything say so?
//
// Five dimensions:
//   1. Logic     — the chain end to end, and a narrowing detected mid-chain
//   2. Scale     — a 2,000-person pair, enough to be real without being slow
//   3. Media     — n/a
//   4. Isolation — a temp store and temp .ged files; nothing near the archive
//   5. Sensor    — the incident's SHAPE (multi-source → single-source) rather
//                  than its exact numbers, so it survives fixture changes

import Foundation
import XCTest
@testable import VideoScanCore

final class TreeLifecycleChainTests: XCTestCase {

    private var root: URL!
    private var storeRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-chain-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("compiled", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() -> FamilyGraphCompiledStore {
        var s = FamilyGraphCompiledStore(root: storeRoot)
        s.log = { _ in }
        return s
    }

    private func pull(_ name: String, people: Int, generations: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try GedcomSyntheticPedigree.gedcom(people: people, generations: generations)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 1 & 5. The whole chain, and the narrowing

    /// THE SENSOR. Build a two-source tree the way Rick's is built, then do
    /// what the broken Refresh did — promote a single-source tree over it —
    /// and assert that the chain NOTICES. Shape, not numbers: any tree that
    /// drops a source its predecessor had must alarm.
    func testPromotingASingleSourceTreeOverATwoSourceOneIsDetected() throws {
        let mine = try pull("mine.ged", people: 400, generations: 6)
        let hers = try pull("hers.ged", people: 600, generations: 6)
        var s = store()

        let a = try XCTUnwrap(GedcomFamilyGraph(fileURL: mine))
        let b = try XCTUnwrap(GedcomFamilyGraph(fileURL: hers))
        XCTAssertNotNil(s.ingest(graph: a.merge(with: b).graph, sources: [mine, hers]),
                        "the two-source generation must compile")
        let both = try XCTUnwrap(s.loadCurrent())
        XCTAssertEqual(both.manifest.sources.count, 2)
        let twoSourcePeople = both.manifest.peopleCount

        // Now the incident: a tree built from ONE of them, promoted on top.
        XCTAssertNotNil(s.ingest(graph: a, sources: [mine]))
        let after = try XCTUnwrap(s.loadCurrent())
        XCTAssertEqual(after.manifest.sources.count, 1, "fixture did not reproduce the narrowing")
        XCTAssertLessThan(after.manifest.peopleCount, twoSourcePeople)

        // The only question that mattered on the night.
        // SPECIFIC, not just `hasAlarm`. An earlier version of this test
        // asserted only that SOMETHING alarmed and that SOME message named
        // hers.ged — and it passed with the source-drop rule downgraded to
        // a note, because the people-loss rule alarmed instead and the note
        // still carried the filename. It was testing the wrong rule.
        let findings = s.auditCurrentGeneration()
        let sourceAlarms = findings.filter {
            $0.severity == .alarm && $0.message.contains("hers.ged") && $0.message.contains("DROPS")
        }
        XCTAssertFalse(sourceAlarms.isEmpty,
                       "losing a source must alarm AS a source loss, naming the file: \(findings.map { "\($0.severity): \($0.message)" })")
    }

    /// The ordinary path must stay quiet, or the alarm is worthless: two
    /// pulls in, a third merged on top, tree grows, nothing alarms.
    func testTheOrdinaryGrowingChainNeverAlarms() throws {
        let mine = try pull("mine.ged", people: 400, generations: 6)
        let hers = try pull("hers.ged", people: 600, generations: 6)
        let cousin = try pull("cousin.ged", people: 300, generations: 5)
        var s = store()

        let a = try XCTUnwrap(GedcomFamilyGraph(fileURL: mine))
        let b = try XCTUnwrap(GedcomFamilyGraph(fileURL: hers))
        XCTAssertNotNil(s.ingest(graph: a.merge(with: b).graph, sources: [mine, hers]))
        let before = try XCTUnwrap(s.loadCurrent()).manifest.peopleCount

        let c = try XCTUnwrap(GedcomFamilyGraph(fileURL: cousin))
        let three = a.merge(with: b).graph.merge(with: c).graph
        XCTAssertNotNil(s.ingest(graph: three, sources: [mine, hers, cousin]))

        let after = try XCTUnwrap(s.loadCurrent())
        XCTAssertEqual(after.manifest.sources.count, 3)
        XCTAssertGreaterThan(after.manifest.peopleCount, before)
        XCTAssertFalse(TreeIntegrityCheck.hasAlarm(s.auditCurrentGeneration()),
                       "a growing tree alarmed: \(s.auditCurrentGeneration().map(\.message))")
    }

    /// A tree that survives the round trip is a tree you can still use:
    /// what went in comes back out, by FamilySearch ID, after a real
    /// compile and decode — not just a manifest count.
    func testEveryPersonSurvivesIngestAndReload() throws {
        let mine = try pull("mine.ged", people: 400, generations: 6)
        let hers = try pull("hers.ged", people: 600, generations: 6)
        var s = store()
        let a = try XCTUnwrap(GedcomFamilyGraph(fileURL: mine))
        let b = try XCTUnwrap(GedcomFamilyGraph(fileURL: hers))
        let merged = a.merge(with: b).graph
        let expected = Set(merged.people.values.compactMap(\.familySearchID))

        XCTAssertNotNil(s.ingest(graph: merged, sources: [mine, hers]))
        let reloaded = try XCTUnwrap(s.loadCurrent()).graph
        let got = Set(reloaded.people.values.compactMap(\.familySearchID))

        XCTAssertEqual(got.count, expected.count)
        XCTAssertTrue(expected.subtracting(got).isEmpty,
                      "\(expected.subtracting(got).count) people did not survive the round trip")
    }

    // MARK: - 2. Scale

    /// Real enough to matter, fast enough to run every time.
    func testATwoThousandPersonChainStaysInsideABudget() throws {
        let mine = try pull("mine.ged", people: 1_000, generations: 8)
        let hers = try pull("hers.ged", people: 1_000, generations: 8)
        var s = store()
        let a = try XCTUnwrap(GedcomFamilyGraph(fileURL: mine))
        let b = try XCTUnwrap(GedcomFamilyGraph(fileURL: hers))

        let start = Date()
        XCTAssertNotNil(s.ingest(graph: a.merge(with: b).graph, sources: [mine, hers]))
        _ = s.loadCurrent()
        _ = s.auditCurrentGeneration()
        let elapsed = -start.timeIntervalSinceNow

        XCTAssertLessThan(elapsed, 20.0,
                          "the full chain took \(String(format: "%.1f", elapsed))s")
    }
}
