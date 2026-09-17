import Foundation
import XCTest
@testable import VideoScanCore

/// Deterministic schedule of two independent store clients: recovery selects A,
/// ingest promotes B, then recovery resumes adoption. No scheduler timing needed.
final class AdoptionSafetyRegressionTests: XCTestCase {
    func testAdoptionMustNotOverwriteAnIngestAfterCandidateSelection() throws {
        let fixture = URL(fileURLWithPath: "/private/tmp/videoscan-loader-review-c67297a3-20260917")
            .appendingPathComponent("adoption-race-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        func source(_ label: String, count: Int) throws -> (URL, GedcomFamilyGraph) {
            let url = fixture.appendingPathComponent(label + ".ged")
            var lines = ["0 HEAD"]
            for n in 1...count {
                lines += ["0 @I\(n)@ INDI", "1 NAME \(label)\(n) /\(label)/", "1 _FSFTID \(label)-\(n)"]
            }
            lines += ["0 TRLR"]
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return (url, try XCTUnwrap(GedcomFamilyGraph(fileURL: url)))
        }
        let (aURL, a) = try source("Alpha", count: 2)
        let (bURL, b) = try source("Beta", count: 3)
        let (cURL, c) = try source("Gamma", count: 4)
        let ab = a.merged(with: b)
        let abc = ab.merged(with: c)
        XCTAssertGreaterThan(abc.people.count, ab.people.count)
        var recovering = FamilyGraphCompiledStore(root: fixture.appendingPathComponent("compiled"))
        recovering.log = { print("ADOPTION_RACE_LOG " + $0) }
        XCTAssertNotNil(recovering.ingest(graph: ab, sources: [aURL, bURL]))
        let old = try XCTUnwrap(recovering.readPointer())
        var broken = old
        broken.current = "gen-missing"
        broken.previous = nil
        try JSONEncoder().encode(broken).write(to: recovering.pointerURL, options: .atomic)

        // Reader selects the older intact generation while the pointer is broken.
        let selected = try XCTUnwrap(recovering.intactMultiSourceGeneration())
        XCTAssertEqual(selected.generation, old.current)
        // A different process/client completes a successful ingest before adoption.
        let writer = FamilyGraphCompiledStore(root: recovering.root)
        XCTAssertNotNil(writer.ingest(graph: abc, sources: [aURL, bURL, cURL]))
        let promoted = try XCTUnwrap(writer.readPointer())
        XCTAssertNotEqual(promoted.current, selected.generation)
        XCTAssertEqual(writer.loadCurrent()?.graph.people.count, abc.people.count)

        _ = recovering.adopt(selected)
        let after = try XCTUnwrap(writer.readPointer())
        let loaded = try XCTUnwrap(writer.loadCurrent())
        print("ADOPTION_RACE_EVIDENCE before=\(abc.people.count)p/3s after=\(loaded.graph.people.count)p/\(loaded.manifest.sources.count)s overwritten=\(after.current != promoted.current) previous=\(after.previous ?? "nil") fixture=\(fixture.path)")
        XCTAssertEqual(after, promoted, "Recovery must preserve an ingest completed after candidate selection")
        XCTAssertEqual(loaded.graph.people.count, abc.people.count, "Stale recovery dropped the third source")
    }
    /// codex, re-review P2: if the OUTER lock never opens, we never read the
    /// pointer under it, so classifying that as "no competing writer" is an
    /// assumption rather than an observation. With a promotion landing in the
    /// same window, adopt would report .couldNotPersist and the caller would
    /// serve the stale candidate while the pointer named the winner.
    ///
    /// The lock is forced to fail by making root/.lock a DIRECTORY, so
    /// open(2) with O_RDWR returns EISDIR.
    func testLockFailureAfterAPromotionIsSupersessionNotAPersistenceFailure() throws {
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adoption-lockfail-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func source(_ label: String, count: Int) throws -> (URL, GedcomFamilyGraph) {
            let url = fixture.appendingPathComponent(label + ".ged")
            var lines = ["0 HEAD"]
            for n in 1...count {
                lines += ["0 @I\(n)@ INDI", "1 NAME \(label)\(n) /\(label)/", "1 _FSFTID \(label)-\(n)"]
            }
            lines += ["0 TRLR"]
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return (url, try XCTUnwrap(GedcomFamilyGraph(fileURL: url)))
        }
        let (aURL, a) = try source("Alpha", count: 2)
        let (bURL, b) = try source("Beta", count: 3)
        let (cURL, c) = try source("Gamma", count: 4)
        let ab = a.merged(with: b)
        let abc = ab.merged(with: c)

        var recovering = FamilyGraphCompiledStore(root: fixture.appendingPathComponent("compiled"))
        recovering.log = { print("LOCKFAIL_LOG " + $0) }
        XCTAssertNotNil(recovering.ingest(graph: ab, sources: [aURL, bURL]))
        let old = try XCTUnwrap(recovering.readPointer())
        var broken = old
        broken.current = "gen-missing"
        broken.previous = nil
        try JSONEncoder().encode(broken).write(to: recovering.pointerURL, options: .atomic)

        let selected = try XCTUnwrap(recovering.intactMultiSourceGeneration())

        // A competing client wins, THEN the lock becomes unopenable.
        let writer = FamilyGraphCompiledStore(root: recovering.root)
        XCTAssertNotNil(writer.ingest(graph: abc, sources: [aURL, bURL, cURL]))
        let promoted = try XCTUnwrap(writer.readPointer())
        try? FileManager.default.removeItem(at: recovering.lockURL)
        try FileManager.default.createDirectory(at: recovering.lockURL, withIntermediateDirectories: true)

        switch recovering.adopt(selected) {
        case .superseded:
            break   // correct: we could not check under the lock, and it HAD moved
        case .adopted(let graph):
            XCTFail("adopted a stale candidate (\(graph.people.count) people) after losing the race")
        case .couldNotPersist(let graph):
            XCTFail("reported a persistence failure while the pointer had already moved; "
                    + "serving \(graph.people.count) people instead of \(abc.people.count)")
        }
        XCTAssertEqual(try XCTUnwrap(writer.readPointer()), promoted,
                       "the winning promotion must survive a failed adoption")
    }
}
