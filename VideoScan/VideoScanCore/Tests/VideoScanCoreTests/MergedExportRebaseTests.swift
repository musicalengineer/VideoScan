// MergedExportRebaseTests.swift
// The sequence that rebuilt Rick's live family tree on 2026-09-17, which
// until now had no test at all.
//
// Merging a MERGED EXPORT with a fresh pull is the shape that gets you both
// halves of the family AND a correction that only exists in the export. It
// is also the shape that the positional provenance bind (codex #816/#817)
// correctly refuses when it is done naively: the export drags its own
// logical sources along, so TWO input files produce THREE provenance
// entries and the bind reports "graph lists 3 sources but 2 were given".
//
// The way through is what the app's Refresh has always done and what
// `videoscan-tree-ingest --write-merged` now does: publish the merged tree
// as ONE artifact and ingest THAT, so it binds to its own file and the
// inputs survive as logical provenance. These cases pin both halves —
// the refusal, and the way through — because Rick's real tree depends on it
// and because the next person to hit this will be told the tree is broken
// when it is not.

import Foundation
import XCTest
@testable import VideoScanCore

final class MergedExportRebaseTests: XCTestCase {

    typealias StoreBox = GedcomCompiledTreeTests.StoreBox

    /// Rick's shape in miniature: his pull, a refreshed export of it, and
    /// Donna's separate pull.
    private func sources(in box: StoreBox) throws
        -> (rick: URL, refreshedExport: URL, donna: URL) {
        let rick = try box.write(GedcomCompiledTreeTests.lossyOneSource(people: 30), as: "rick.ged")
        let threeGen = try box.write(
            GedcomSyntheticPedigree.gedcom(people: 8, generations: 3)
                .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID R"), as: "rick-3gen.ged")
        // The export: rick + a refresh of rick, merged and written as ONE file.
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: rick))
            .merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: threeGen)))
        let export = try box.write(merged.gedcomText(provenance: "rick.ged + rick-3gen.ged"),
                                   as: "refreshed.ged")
        let donna = try box.write(
            GedcomSyntheticPedigree.gedcom(people: 25, generations: 4)
                .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "donna.ged")
        return (rick, export, donna)
    }

    /// The export really does carry more logical sources than it is files.
    func testAMergedExportCarriesItsInputsAsLogicalProvenance() throws {
        let box = try StoreBox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let s = try sources(in: box)
        let export = try XCTUnwrap(GedcomFamilyGraph(fileURL: s.refreshedExport))

        XCTAssertTrue(export.isMergedArtifact)
        XCTAssertTrue(export.bindsToOwnFile, "parsed from its own file, so it binds to that file")
        XCTAssertEqual(export.physicalSources.count, 1, "one file")
        XCTAssertEqual(export.sourceProvenance.count, 2, "two pulls behind it")
    }

    /// THE REFUSAL. Naively ingesting export + donna as two files is
    /// refused, and must be — the provenance and the files disagree.
    func testMergingAnExportWithAPullIsRefusedWhenIngestedAsTwoFiles() throws {
        let box = try StoreBox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let s = try sources(in: box)
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: s.refreshedExport))
            .merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: s.donna)))
        XCTAssertEqual(merged.sourceProvenance.count, 3, "three pulls, two files")

        var store = box.store()
        var log: [String] = []
        store.log = { log.append($0) }
        XCTAssertNil(store.ingest(graph: merged, sources: [s.refreshedExport, s.donna]),
                     "the bind must refuse a graph whose provenance does not match the files")
        XCTAssertNil(store.readPointer(), "a refused ingest must promote nothing")
        XCTAssertTrue(log.contains { $0.contains("REFUSED") },
                      "the refusal must say so: \(log)")
    }

    /// THE WAY THROUGH, and the thing Rick's tree is actually built on:
    /// publish the merge as one artifact, re-parse it, ingest THAT.
    func testPublishingTheMergeAsOneArtifactPromotesAndKeepsEveryInput() throws {
        let box = try StoreBox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let s = try sources(in: box)
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: s.refreshedExport))
            .merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: s.donna)))
        let peopleBefore = merged.people.count

        let published = try box.write(merged.gedcomText(provenance: "refreshed.ged + donna.ged"),
                                      as: "final.ged")
        let reparsed = try XCTUnwrap(GedcomFamilyGraph(fileURL: published))
        XCTAssertEqual(reparsed.people.count, peopleBefore,
                       "the round trip through GEDCOM lost people")

        let store = box.store()
        let promoted = try XCTUnwrap(store.ingest(graph: reparsed, sources: [published]),
                                     "the single-artifact path must promote")
        XCTAssertEqual(promoted.people.count, peopleBefore)

        let pointer = try XCTUnwrap(store.readPointer())
        let manifest = try XCTUnwrap(store.readManifest(pointer.current))
        XCTAssertEqual(manifest.sources.count, 1, "one file on disk")
        XCTAssertEqual(manifest.logicalSources.count, 3,
                       "all three pulls must survive as provenance, or nobody can tell "
                       + "later what this tree was built from")
        XCTAssertEqual(manifest.peopleCount, peopleBefore)
        XCTAssertTrue(manifest.verification.isEmpty, "promoted artifact failed its own verify")
    }

    /// And it loads back as what was promoted — the check that would have
    /// caught a tree that promoted clean and then read short.
    func testTheRepublishedTreeLoadsBackWithEveryPerson() throws {
        let box = try StoreBox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let s = try sources(in: box)
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: s.refreshedExport))
            .merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: s.donna)))
        let published = try box.write(merged.gedcomText(provenance: "final"), as: "final.ged")
        let reparsed = try XCTUnwrap(GedcomFamilyGraph(fileURL: published))

        let store = box.store()
        XCTAssertNotNil(store.ingest(graph: reparsed, sources: [published]))

        let loaded = try XCTUnwrap(store.loadCurrent(), "the promoted tree would not load back")
        XCTAssertEqual(loaded.graph.people.count, merged.people.count)
        XCTAssertEqual(loaded.manifest.logicalSources.count, 3)
    }
}
