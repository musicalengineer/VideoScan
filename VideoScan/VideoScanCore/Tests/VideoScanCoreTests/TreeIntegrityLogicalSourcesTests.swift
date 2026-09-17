// TreeIntegrityLogicalSourcesTests.swift
// Regression sensor: app Add/Refresh writes one new merged GEDCOM while
// retaining the original pulls in its logical provenance. Changing that
// physical artifact filename is not evidence that a source was dropped.
//
// Pure manifest fixtures, matching TreeIntegrityCheckTests: no GEDCOM I/O,
// app launch, preferences, or real store. Production-sized counts are scalar
// metadata; this test allocates only a handful of source entries.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Tree integrity — merged artifacts preserve logical provenance")
struct TreeIntegrityLogicalSourcesTests {
    private typealias Manifest = FamilyGraphCompiledStore.Manifest
    private typealias LogicalSource = FamilyGraphCompiledStore.LogicalSource

    private func manifest(people: Int, families: Int, physicalNames: [String],
                          logicalSources: [LogicalSource], generation: String) -> Manifest {
        let timestamp = Date(timeIntervalSince1970: 0)
        return Manifest(
            schema: 3, codec: 6, index: 2, generation: generation, createdAt: timestamp,
            sources: physicalNames.map {
                .init(fileName: $0, path: "/private/tmp/tree-integrity-fixture/\($0)",
                      size: 1, modifiedAt: timestamp, key: $0, sha256: $0,
                      droppedLineCount: 0)
            },
            logicalSources: logicalSources, peopleCount: people, familyCount: families,
            verification: [], mergeReport: nil,
            localDroppedLineCount: 0, totalDroppedLineCount: 0)
    }

    /// Both real transitions: a compiled multi-pull tree becomes one app
    /// merge artifact, then a later refresh replaces that artifact with a
    /// newly named one. The raw pulls remain present by name AND hash.
    @Test(arguments: [
        ["familysearch-tree-20generations.ged", "familysearch-donna-20generations.ged"],
        ["familysearch-merged-20260916-180000.ged"]
    ])
    func growingMergedArtifactDoesNotDropPreservedLogicalSources(previousPhysicalNames: [String]) {
        let originalPulls: [LogicalSource] = [
            .init(fileName: "familysearch-tree-20generations.ged",
                  sha256: String(repeating: "a", count: 64), droppedLineCount: 0),
            .init(fileName: "familysearch-donna-20generations.ged",
                  sha256: String(repeating: "b", count: 64), droppedLineCount: 0)
        ]
        let previous = manifest(
            people: 39_250, families: 24_935, physicalNames: previousPhysicalNames,
            logicalSources: originalPulls, generation: "before-refresh")
        let incoming = manifest(
            people: 39_400, families: 25_000,
            physicalNames: ["familysearch-refreshed-20260917-001509.ged"],
            logicalSources: originalPulls + [
                .init(fileName: "familysearch-new-pull.ged",
                      sha256: String(repeating: "c", count: 64), droppedLineCount: 0)
            ], generation: "after-refresh")

        // Pin the fixture's distinction: physical inputs were repackaged,
        // while every existing logical identity and its hash survived.
        #expect(incoming.sources.map(\.fileName) != previous.sources.map(\.fileName))
        #expect(Array(incoming.logicalSources.prefix(originalPulls.count)) == previous.logicalSources)
        #expect(incoming.peopleCount > previous.peopleCount)
        #expect(incoming.familyCount > previous.familyCount)

        let findings = TreeIntegrityCheck.compare(incoming: incoming, against: previous)
        let messages = findings.map(\.message).joined(separator: " | ")
        #expect(!TreeIntegrityCheck.hasAlarm(findings),
                "A growing merged tree preserved all logical sources; replacing its physical artifact must not alarm: \(messages)")
        #expect(!findings.contains { $0.message.contains("DROPS") },
                "No original pull disappeared from the logical provenance: \(messages)")
    }
}
