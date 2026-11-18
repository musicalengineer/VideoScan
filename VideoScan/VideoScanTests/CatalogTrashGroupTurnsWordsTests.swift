// CatalogTrashGroupTurnsWordsTests.swift
// GH #481 item 2: the pair-move report named "Show Removed ▸ Restore", a
// route that left the Show menu on 2026-11-17 (DECISIONS: "Put Back on a
// set-aside or removed row has no menu route until one is asked for"). The
// words now say the record's state and the one route that exists for the
// FILE — Finder's Put Back — and never a menu that is gone, nor a row
// marker it does not know (Codex #481 F1).

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog Move to Trash — pair report words name routes that exist (GH #481)")
@MainActor
struct CatalogTrashGroupTurnsWordsTests {

    private func group() -> CatalogPairGroups.Group {
        CatalogPairGroups.Group(key: UUID(), members: [UUID(), UUID()],
                                filenames: ["tape9.V.mxf", "tape9.A.mxf"],
                                paths: ["/nonexistent-481/tape9.V.mxf", "/nonexistent-481/tape9.A.mxf"],
                                pairGroupIDs: [nil, nil], identities: [], departed: [])
    }

    @Test("SPLIT line: no removed menu route; says where the moved half is, never a row marker")
    func splitLineWords() {
        let unit = CatalogTrashGroupTurns.UnitOutcome(group(), outcomes: [
            .moved(bytes: 10, trashPath: "/Users/x/.Trash/tape9.V.mxf"), .held("is the only copy")])
        let line = unit.splitLine(currentPath: { _ in nil }, late: [])
        #expect(!line.contains("Show Removed"), "names a route removed 2026-11-17: \(line)")
        #expect(line.contains("tape9.V.mxf is in the Trash (/Users/x/.Trash/tape9.V.mxf)"), "\(line)")
        #expect(line.contains(CatalogTrashGroupTurns.splitAdvice), "\(line)")
        #expect(CatalogTrashGroupTurns.splitAdvice.contains("Finder"))
        // Codex #481 F1: the file's place is evidence; the row's marker is not
        // known to this sentence (another action may have kept its own).
        #expect(!CatalogTrashGroupTurns.splitAdvice.contains("marked"), "\(CatalogTrashGroupTurns.splitAdvice)")
    }

    @Test("late-linked advice: no removed menu route; where the files are and Finder's Put Back")
    func lateLinkedAdviceWords() {
        let words = CatalogTrashGroupTurns.lateLinkedAdvice
        #expect(!words.contains("Show Removed"), "\(words)")
        #expect(words.contains("pair protection") && words.contains("in the Trash") && words.contains("Finder"), "\(words)")
        #expect(!words.contains("marked"), "never claims a row marker it was not given: \(words)")
    }
}
