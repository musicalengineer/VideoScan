// FamilyGraphCompiledStoreBindingTests.swift
// codex #822/#823 (post-merge blockers on the one-time ingest):
//   1. LOGICAL provenance (what a tree was merged from) is not the same
//      thing as the PHYSICAL files the store hashes. A merge artifact
//      written by the app's "Add to current tree" is ONE .ged whose HEAD
//      lists A and B; the store binds it to ITSELF (one physical source),
//      keeps [A, B] as logical provenance and records both in the manifest.
//   2. A source rewritten AFTER the first hash but before the pointer is
//      written is refused: the store rehashes right before the manifest.
//   3. Duplicate basenames are distinct positions; identity = (position, sha).

import XCTest
@testable import VideoScanCore

final class FamilyGraphCompiledStoreBindingTests: XCTestCase {

    typealias StoreBox = GedcomCompiledTreeTests.StoreBox

    /// A.ged + B.ged on disk, merged in memory, written as ONE artifact
    /// file `ab.ged` (the app's Add path), then parsed back.
    private func artifact(in box: StoreBox) throws -> (a: URL, b: URL, ab: URL, parsed: GedcomFamilyGraph) {
        let a = try box.write(GedcomCompiledTreeTests.lossyOneSource(people: 40), as: "a.ged")
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID B"), as: "b.ged")
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: a)).merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: b)))
        XCTAssertTrue(merged.isMergedArtifact)
        XCTAssertNil(merged.sourceFingerprint, "an in-memory merge has no file of its own")
        XCTAssertFalse(merged.bindsToOwnFile)
        XCTAssertEqual(merged.physicalSources, merged.sourceProvenance, "CLI shape: physical == logical")
        let ab = try box.write(merged.gedcomText(provenance: "test artifact"), as: "ab.ged")
        let parsed = try XCTUnwrap(GedcomFamilyGraph(fileURL: ab))
        return (a, b, ab, parsed)
    }

    func testMergedArtifactFileBindsToItselfAndKeepsLogicalProvenance() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let (a, b, ab, parsed) = try artifact(in: box)
        let shaA = try GedcomCompiledTree.fullSHA256(of: a), shaB = try GedcomCompiledTree.fullSHA256(of: b)
        let shaAB = try GedcomCompiledTree.fullSHA256(of: ab)

        // The parsed artifact: logical [A, B] from HEAD, physical = itself.
        XCTAssertTrue(parsed.isMergedArtifact)
        XCTAssertTrue(parsed.bindsToOwnFile)
        XCTAssertEqual(parsed.sourceProvenance.map(\.name), ["a.ged", "b.ged"])
        XCTAssertEqual(parsed.sourceProvenance.map(\.sha256), [shaA, shaB])
        XCTAssertEqual(parsed.physicalSources.map(\.name), ["ab.ged"])
        XCTAssertEqual(parsed.physicalSources.map(\.sha256), [shaAB])
        XCTAssertEqual(parsed.physicalSources[0].droppedLineCount, parsed.droppedLineCount, "artifact re-parse loss is its physical entry's loss")

        let store = box.store()
        // Fail-closed is NOT weakened: binding the artifact to the pulls it
        // lists (count 2 vs physical 1), or to the wrong single file, is refused.
        XCTAssertNil(store.ingest(graph: parsed, sources: [a, b]))
        XCTAssertTrue(box.lines.contains("lists 1 source but 2 were given"), "\(box.lines.all)")
        XCTAssertNil(store.ingest(graph: parsed, sources: [a]))
        XCTAssertTrue(box.lines.contains("is a.ged"), "\(box.lines.all)")
        XCTAssertNil(store.readPointer())
        XCTAssertEqual(store.generations(), [])

        // The right binding: the artifact file itself.
        let promoted = try XCTUnwrap(store.ingest(graph: parsed, sources: [ab]))
        let pointer = try XCTUnwrap(store.readPointer())
        let manifest = try XCTUnwrap(store.readManifest(pointer.current))
        XCTAssertTrue(manifest.verification.isEmpty, "\(manifest.verification)")
        XCTAssertEqual(manifest.sources.map(\.fileName), ["ab.ged"])
        XCTAssertEqual(manifest.sources.map(\.sha256), [shaAB])
        XCTAssertEqual(pointer.sourceKeys, [shaAB])
        XCTAssertEqual(manifest.logicalSources.map(\.fileName), ["a.ged", "b.ged"])
        XCTAssertEqual(manifest.logicalSources.map(\.sha256), [shaA, shaB])
        XCTAssertEqual(manifest.logicalSources.map(\.droppedLineCount), parsed.sourceProvenance.map(\.droppedLineCount))
        XCTAssertEqual(manifest.localDroppedLineCount, parsed.droppedLineCount)
        XCTAssertEqual(manifest.totalDroppedLineCount, parsed.totalDroppedLineCount)
        // The decoded artifact still tells the whole story.
        XCTAssertTrue(promoted.isMergedArtifact)
        XCTAssertEqual(promoted.sourceProvenance, parsed.sourceProvenance)
        XCTAssertEqual(promoted.sourceFingerprint, shaAB)
        XCTAssertEqual(promoted.physicalSources.map(\.name), ["ab.ged"])
        XCTAssertEqual(promoted.sourceFileNames, ["a.ged", "b.ged"])
        XCTAssertEqual(promoted.rootPersonIDs.count, 2)
        XCTAssertEqual(promoted.people.count, parsed.people.count)

        // loadCurrent() is a hit; load(sources: [ab]) too.
        XCTAssertEqual(store.loadCurrent()?.graph.people.count, parsed.people.count)
        XCTAssertNotNil(store.load(sources: [ab]))
        // Deleting a LOGICAL source does not invalidate: the store bound the artifact, not the pulls.
        try FileManager.default.removeItem(at: a)
        XCTAssertNotNil(store.loadCurrent())
        // Changing the artifact does.
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 5, generations: 2), as: "ab.ged")
        XCTAssertNil(store.loadCurrent())
        XCTAssertTrue(box.lines.contains("ab.ged missing or changed"), "\(box.lines.all)")
    }

    /// A schema-3 manifest written before `logicalSources` existed reads
    /// back with logical == physical (what those generations were), so
    /// Rick's compiled two-pull tree stays current without a recompile.
    func testManifestWithoutLogicalSourcesDecodesAsLogicalEqualsPhysical() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 20, generations: 3), as: "a.ged")
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 15, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID B"), as: "b.ged")
        let store = box.store()
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: a)).merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: b)))
        XCTAssertNotNil(store.ingest(graph: merged, sources: [a, b]))
        let pointer = try XCTUnwrap(store.readPointer())
        let written = try XCTUnwrap(store.readManifest(pointer.current))
        XCTAssertEqual(written.logicalSources.map(\.sha256), written.sources.map(\.sha256))
        // Strip the field the way an older writer would have left it.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.manifestURL(pointer.current))) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "logicalSources"))
        try JSONSerialization.data(withJSONObject: json).write(to: store.manifestURL(pointer.current))
        let reread = try XCTUnwrap(store.readManifest(pointer.current))
        XCTAssertEqual(reread.logicalSources, written.logicalSources)
        XCTAssertEqual(reread.sources, written.sources)
        XCTAssertNotNil(store.loadCurrent())
    }

    /// codex #822 item 2 — the late-rewrite window. The store hashed and
    /// bound the file, then compile + verify ran; the file is replaced
    /// from inside the `progress` callback at "Verifying", i.e. AFTER the
    /// first hash and BEFORE the manifest/pointer. Refused: log REFUSED,
    /// pointer untouched, generation directory gone, nil returned. The
    /// positive control (no rewrite) promotes.
    func testRewriteDuringVerifyIsRefusedAndLeavesNoGeneration() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let url = try box.write(GedcomCompiledTreeTests.lossyOneSource(people: 40), as: "pull.ged")
        let store = box.store()
        let first = try XCTUnwrap(store.ingest(graph: try XCTUnwrap(GedcomFamilyGraph(fileURL: url)), sources: [url]))
        let before = try XCTUnwrap(store.readPointer())

        // Same bytes back on disk so the bind succeeds, then rewrite mid-ingest.
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: url))
        var rewrote = false
        let result = store.ingest(graph: graph, sources: [url], progress: { phase in
            if phase.hasPrefix("Verifying") {
                _ = try? box.write(GedcomSyntheticPedigree.gedcom(people: 41, generations: 4), as: "pull.ged")
                rewrote = true
            }
        })
        XCTAssertTrue(rewrote, "the sensor must have fired")
        XCTAssertNil(result)
        XCTAssertTrue(box.lines.contains("REFUSED") && box.lines.contains("changed during compile/verify"), "\(box.lines.all)")
        XCTAssertEqual(store.readPointer(), before, "pointer untouched")
        XCTAssertEqual(store.generations(), [before.current], "failed generation directory removed")
        XCTAssertEqual(try GedcomCompiledTree.decode(try Data(contentsOf: store.artifactURL(before.current))).people.count, first.people.count)
        // And the store now reports a miss for that path (the bytes changed).
        XCTAssertNil(store.load(sources: [url]))

        // Positive control: same flow, no rewrite → promoted, previous kept.
        let again = try XCTUnwrap(GedcomFamilyGraph(fileURL: url))
        var phases: [String] = []
        let promoted = store.ingest(graph: again, sources: [url], progress: { phases.append($0) })
        XCTAssertNotNil(promoted)
        XCTAssertTrue(phases.contains { $0.hasPrefix("Verifying") })
        XCTAssertEqual(promoted?.people.count, 41)
        let after = try XCTUnwrap(store.readPointer())
        XCTAssertNotEqual(after.current, before.current)
        XCTAssertEqual(after.previous, before.current)
        // Two "hashed 1 source" lines per ingest: bind + pre-manifest rehash.
        XCTAssertGreaterThanOrEqual(box.lines.all.filter { $0.contains("hashed 1 source") }.count, 4)
    }

    /// Two-source variant of the late rewrite: only the SECOND file moves,
    /// after the bind. Refused by position, named in the log.
    func testLateRewriteOfSecondSourceIsRefused() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 20, generations: 3), as: "a.ged")
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 15, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID B"), as: "b.ged")
        let store = box.store()
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: a)).merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: b)))
        XCTAssertNil(store.ingest(graph: merged, sources: [a, b], progress: { phase in
            if phase.hasPrefix("Verifying") {
                _ = try? box.write(GedcomSyntheticPedigree.gedcom(people: 16, generations: 3), as: "b.ged")
            }
        }))
        XCTAssertTrue(box.lines.contains("REFUSED") && box.lines.contains("b.ged changed during compile/verify"), "\(box.lines.all)")
        XCTAssertNil(store.readPointer())
        XCTAssertEqual(store.generations(), [])
    }

    /// codex #823: duplicate basenames are two POSITIONS. `sourceFileNames`
    /// lists both; identity is (position, sha); the manifest's physical
    /// and logical lists both carry the repeated name in order.
    func testDuplicateBasenamesAreDistinctPositions() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let dirX = box.root.appendingPathComponent("x"), dirY = box.root.appendingPathComponent("y")
        try FileManager.default.createDirectory(at: dirX, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirY, withIntermediateDirectories: true)
        let x = dirX.appendingPathComponent("pull.ged"), y = dirY.appendingPathComponent("pull.ged")
        try GedcomSyntheticPedigree.gedcom(people: 20, generations: 3).write(to: x, atomically: true, encoding: .utf8)
        try GedcomSyntheticPedigree.gedcom(people: 15, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID Y").write(to: y, atomically: true, encoding: .utf8)
        let gx = try XCTUnwrap(GedcomFamilyGraph(fileURL: x)), gy = try XCTUnwrap(GedcomFamilyGraph(fileURL: y))
        let merged = gx.merged(with: gy)
        XCTAssertEqual(merged.sourceProvenance.map(\.name), ["pull.ged", "pull.ged"])
        XCTAssertNotEqual(merged.sourceProvenance[0].sha256, merged.sourceProvenance[1].sha256)
        XCTAssertEqual(merged.sourceProvenance.map(\.identity).count, Set(merged.sourceProvenance.map(\.identity)).count, "distinct identities")

        let store = box.store()
        let promoted = try XCTUnwrap(store.ingest(graph: merged, sources: [x, y]))
        let manifest = try XCTUnwrap(store.readManifest(try XCTUnwrap(store.readPointer()).current))
        XCTAssertEqual(manifest.sources.map(\.fileName), ["pull.ged", "pull.ged"])
        XCTAssertEqual(manifest.sources.map(\.path), [x.path, y.path])
        XCTAssertEqual(manifest.logicalSources.map(\.fileName), ["pull.ged", "pull.ged"])
        XCTAssertEqual(manifest.logicalSources.map(\.sha256), manifest.sources.map(\.sha256))
        XCTAssertEqual(promoted.sourceProvenance.map(\.name), ["pull.ged", "pull.ged"])

        // The written artifact lists the name twice, each with its own sha,
        // and parses back to two logical positions bound to ONE physical file.
        let xy = try box.write(merged.gedcomText(provenance: "dup names"), as: "xy.ged")
        let parsed = try XCTUnwrap(GedcomFamilyGraph(fileURL: xy))
        XCTAssertEqual(parsed.sourceProvenance.map(\.name), ["pull.ged", "pull.ged"])
        XCTAssertEqual(parsed.sourceProvenance.map(\.sha256), merged.sourceProvenance.map(\.sha256))
        XCTAssertEqual(parsed.physicalSources.map(\.name), ["xy.ged"])
    }
}
