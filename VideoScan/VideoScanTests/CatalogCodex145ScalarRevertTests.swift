// CatalogCodex145ScalarRevertTests.swift
// Codex cycle #145, finding 4 (docs/reviews/codex/
// codex-review-committer-refuse-and-name-2026-10-25.md): after a scoped save
// of copy A, a DIRTY sibling B's shared SCALAR baseline took the committed
// value (the #143 amendment, kept so the store's conflict check never holds
// this session's own sibling) — but B's whole-record fingerprint baseline
// still described the OLD value. B changed back to that old value then
// looked completely clean: never submitted, and a relaunch restored the
// other value.
//
// The promise: when a sibling's commit moves a dirty copy's scalar baseline,
// that copy's fingerprint baseline no longer describes the store, so the
// copy stays CHANGED until its own next commit settles it (the baseline's
// `stale` set) — a reversal is submitted and written.
//
// Red/green (Debug, M4 Max):
//   revertingASiblingAfterAScopedSaveIsSaved  RED on dfd4298ff (store and relaunch kept "shared") → GREEN
//   (the false hold the amendment exists for — CatalogReopenRefuseAndNameTests
//    .rowsOnlyThisSessionWroteAreNeverHeld — stays GREEN)
//
// Dimensions: LOGIC (scoped save, then a reversal; Codex's proposed
// regression verbatim); TRUTH (the store and a relaunch show what memory
// shows); ISOLATION (CutoverScene sandbox). SCALE / MEDIA / SENSOR N/A.
//
// Suites (filter by SUITE): CatalogScopedSaveScalarRevertTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog commit — a dirty sibling's reversal after a scoped save is saved (codex #145 F4)", .serialized)
@MainActor
struct CatalogScopedSaveScalarRevertTests {

    @Test("copies A and B at \"base\"; both → \"shared\"; save A alone; B back to \"base\" is saved and survives a relaunch")
    func revertingASiblingAfterAScopedSaveIsSaved() async throws {
        let (scene, committer) = try await CatalogReopenReconcileTests.launched("codex145_revert")
        defer { scene.cleanup() }
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.userNotes = "base"
        b.userNotes = "base"
        try #require(committer.commitNow(), "both copies normalised to \"base\"")

        a.userNotes = "shared"
        b.userNotes = "shared"
        try #require(committer.commitNow(ids: [a.id]))

        b.userNotes = "base"
        try #require(committer.commitNow())

        #expect(try await scene.reloaded(.curatedConflictB).userNotes == "base")
        #expect(!scene.sandbox.catalogLogText().contains("Catalog store: HELD"), "no false hold")
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictB).userNotes == "base")
        #expect(try scene.record(.curatedConflictA).userNotes == "base", "one content, one note")
    }
}
