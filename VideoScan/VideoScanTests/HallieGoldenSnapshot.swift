// HallieGoldenSnapshot.swift
// GH #281 R3 (2026-10-06): golden characterization snapshots for the Hallie
// executor refactors (executeRelationship, HallieShellCLI.answer,
// HallieLineageAnswer.superlative, ArchivistTemporalExecutor.executeGroup).
//
// Each suite renders a fixed scenario list to text and compares it with
// tests/fixtures/hallie_snapshots/<name>.json, which was RECORDED FROM THE
// PRE-REFACTOR CODE and committed before any move. A missing golden is
// written and the test fails ("recorded — re-run"), so a golden can only be
// created deliberately; a mismatch writes <name>.actual.json beside it (not
// committed) and fails with the differing scenario names.
//
// Rendering is plain text, field by field, so the diff reads like the
// answer; UUIDs are masked because continuation tokens are random.

import Foundation
import Testing
@testable import VideoScan

enum HallieGoldenSnapshot {

    static func directory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // VideoScanTests
            .deletingLastPathComponent()      // VideoScan
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("tests/fixtures/hallie_snapshots")
    }

    /// Compare `actual` (scenario name → rendering) with the golden file.
    static func verify(_ name: String, _ actual: [String: String],
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let dir = directory()
        let golden = dir.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(actual)
        guard FileManager.default.fileExists(atPath: golden.path) else {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: golden)
            Issue.record("recorded \(golden.path) (\(actual.count) scenarios) — re-run", sourceLocation: sourceLocation)
            return
        }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: golden))
        let names = Set(expected.keys).union(actual.keys).sorted()
        let differing = names.filter { expected[$0] != actual[$0] }
        if differing.isEmpty {
            #expect(actual.count == expected.count, sourceLocation: sourceLocation)
            return
        }
        try data.write(to: dir.appendingPathComponent("\(name).actual.json"))
        let detail = differing.prefix(8).map { key in
            "── \(key)\n  golden: \(expected[key] ?? "<missing>")\n  actual: \(actual[key] ?? "<missing>")"
        }.joined(separator: "\n")
        Issue.record("\(differing.count) of \(names.count) snapshots differ in \(name):\n\(detail)",
                     sourceLocation: sourceLocation)
    }

    /// UUIDs (continuation tokens, generated ids) differ every run.
    static func masked(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<uuid>", options: .regularExpression)
    }

    /// Every field of a turn result a reader can see or a client can act on.
    static func render(_ result: HallieTurnExecutor.Result) -> String {
        var lines = [
            "route=\(result.route) outcome=\(result.outcome) composedBy=\(result.composedBy)",
            "prose=\(result.prose)",
            "basis=\(result.basisLine)",
            "query=\(result.queryDescription ?? "nil") person=\(result.catalogPersonName ?? "nil") matchCount=\(result.matchCount.map(String.init) ?? "nil")",
            "citations=\(result.citations.count) knowledge=\(result.knowledgeCitations.count) attachments=\(result.attachments.count)",
            "offers=\(String(reflecting: result.offeredActions)) performsFirst=\(result.performsFirstOfferedAction)",
            "plan=\(result.answerPlan.map { String(reflecting: $0) } ?? "nil")",
            "transcript=\(result.transcriptText ?? "nil")",
        ]
        if let clarification = result.clarification {
            lines.append("clarify.stage=\(clarification.stage)")
            lines.append("clarify.candidates=\(String(reflecting: clarification.candidates))")
            // A dictionary: sorted, because Swift's hash order changes per process.
            let pins = clarification.intent.pinnedGraphSubjects.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String(reflecting: $0.value))" }
            lines.append("clarify.pinned=\(pins)")
        } else {
            lines.append("clarify=nil")
        }
        return masked(lines.joined(separator: "\n"))
    }
}
