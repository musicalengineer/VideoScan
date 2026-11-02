// TrashWarningsSensorTests.swift
// Codex #205: the Trash routine's settlement warnings (`keptMarkerNotes`,
// `groupNotes`, `groupNeedsAttention`) live only in its returned result. A
// door that reads `result.items` alone turns a kept concurrent marker into a
// clean "moved". So every production caller of `deleteConfirmedJunk` must
// pass its result through THE presenter, `TrashWarnings(…)`, in the same
// function that made the call — and a new caller fails here until it is
// listed (and does so).

import Foundation
import Testing
@testable import VideoScan

@Suite("Trash warnings — every caller of the routine renders them (sensor)")
struct TrashWarningsSensorTests {

    /// Every production door into the one Trash routine.
    static let callers: Set<String> = [
        "VideoScanModel+TrashSelection.swift",      // ⌘⌫ / row menu Move to Trash
        "VideoScanModel+JunkTrashSnapshot.swift",   // Triage Delete Junk
        "VideoScanModel+PruneApply.swift",          // Archived — what next? (Prune)
        "CleanupTrashJob.swift",                    // Triage ▸ Cleanup
        "VideoScanModel+Workbench.swift",           // Under Construction Discard
    ]

    /// The text from `start` to the next function declaration (the rest of
    /// the enclosing function, near enough for a sensor).
    static func restOfFunction(_ code: String, from start: String.Index) -> Substring {
        let tail = code[start...]
        let decl = #/\n[ \t]*(?:@\w+[ \t]+)*(?:(?:private|fileprivate|nonisolated|static|public|internal|override)[ \t]+)*func[ \t]/#
        guard let next = tail.dropFirst().firstMatch(of: decl) else { return tail }
        return code[start..<next.range.lowerBound]
    }

    @Test("sensor: every caller of deleteConfirmedJunk is a known door, and passes its result through TrashWarnings")
    func everyCallerRendersTheWarnings() throws {
        var found: Set<String> = []
        for source in SourceTree.appSources {
            let name = source.url.lastPathComponent
            let text = try String(contentsOf: source.url, encoding: .utf8)
            guard text.contains("deleteConfirmedJunk(") else { continue }
            let code = try SourceTree.code(of: text, named: name)
            var searchFrom = code.startIndex
            while let hit = code[searchFrom...].range(of: "deleteConfirmedJunk(") {
                searchFrom = hit.upperBound
                let lineStart = code[..<hit.lowerBound].lastIndex(of: "\n").map { code.index(after: $0) } ?? code.startIndex
                if code[lineStart..<hit.lowerBound].contains("func ") { continue }   // the definition
                found.insert(name)
                #expect(Self.callers.contains(name), "\(name) calls the Trash routine but is not a listed door — render its result through TrashWarnings and list it")
                #expect(Self.restOfFunction(code, from: hit.lowerBound).contains("TrashWarnings("),
                        "\(name): the routine's result is not passed through TrashWarnings in the calling function (Codex #205)")
            }
        }
        #expect(found == Self.callers, "the door list is stale: found \(found.sorted()), listed \(Self.callers.sorted())")
    }

    @Test("sensor: the shared result sheet renders the routine's warnings through TrashWarnings")
    func reportUsesTheOnePresenter() throws {
        let report = try SourceTree.appCode(named: "JunkDeletionReport.swift")
        #expect(report.contains("TrashWarnings(result)"))
        #expect(report.contains("warnings.lines"))
        #expect(!report.contains("r.keptMarkerNotes") && !report.contains("r.groupNotes"), "the report re-derives the warnings")
        let dup = try SourceTree.appCode(named: "DeleteDuplicatesJob.swift")
        #expect(dup.contains("TrashWarnings(keptMarkerNotes:"), "Delete Duplicates' summary uses the same words")
    }
}
