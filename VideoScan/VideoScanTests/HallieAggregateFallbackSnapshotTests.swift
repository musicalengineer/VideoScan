// HallieAggregateFallbackSnapshotTests.swift
//
// Demo probe 2026-10-09 (live shell, real translator): "videos of the
// <X> family" was read as a co-occurrence ranking anchored on "<x>". The
// GH #182 fallback correctly said "<x> is a person, not a co-occurrence
// anchor here, so I searched the catalog" — and then searched NOTHING:
// an aggregate turn captured only aggregate snapshots, so the presence
// search ran over an empty list and answered "I don't have any videos
// tagged with <x> yet" about a family with two tagged videos. The app's
// turn coordinator had the same gap (presenceRecords = [] for aggregate).
//
// This drives the real shell loop with a fixture translator. Synthetic
// names only; no model, no real catalog, no UserDefaults (speakers are
// injected). C++ analogy: `Dependencies` is a struct of std::function
// hooks — the test swaps the I/O ones for in-memory fakes.

import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie shell — the co-occurrence fallback searches real records", .serialized)
struct HallieAggregateFallbackSnapshotTests {

    private static func record(_ path: String, tags: [String]) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        value.confirmedByUserPeople = tags.map {
            ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        return value
    }

    /// Reference box for the closures' shared state (same role as the
    /// Harness class in HallieShellCLITests).
    private final class Box {
        var output: [String] = []
        var translations: [ArchivistQueryAST] = []
    }

    private func run(question: String, anchors: [String]) async throws -> [String] {
        let box = Box()
        box.translations = [.aggregate(.init(operation: .coOccurrence, anchorPeople: anchors))]
        let records = [
            Self.record("/Synthetic/2001/gathering_a.mov", tags: ["Testwood Family"]),
            Self.record("/Synthetic/1999/visit.mov", tags: ["Carol"]),
        ]
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in records },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in
                .init(ast: box.translations.removeFirst(), responderHost: "fixture-translator")
            },
            executeTurn: HallieTurnExecutor.execute,
            executeRequest: { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            },
            performMediaAction: { _ in },
            speakers: { .init(ownerName: "Test Owner", archivistName: "Hallie") })
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--once", question, "--diagnostics", "--no-actions",
        ])
        _ = await HallieShellCLI.run(
            options: options, output: { box.output.append($0) }, dependencies: dependencies)
        return box.output
    }

    /// RED before the fix: "I couldn't resolve the anchor Carol." / "no
    /// videos tagged" — the fallback's presence search saw zero records.
    @Test func aTagOnlyAnchorFindsItsTaggedVideoThroughTheShell() async throws {
        let out = try await run(question: "show me videos with Carol", anchors: ["Carol"])
        let text = out.joined(separator: "\n")
        #expect(text.contains("visit.mov"), Comment(rawValue: text))
        #expect(!text.contains("couldn't resolve"), Comment(rawValue: text))
        #expect(!text.contains("don't have any videos tagged"), Comment(rawValue: text))
    }

    @Test func aFamilyAnchorFindsTheFamilyTagThroughTheShell() async throws {
        let out = try await run(question: "videos of the Testwood family",
                                anchors: ["Testwood family"])
        let text = out.joined(separator: "\n")
        #expect(text.contains("gathering_a.mov"), Comment(rawValue: text))
        #expect(!text.contains("visit.mov"), Comment(rawValue: text))
    }
}
