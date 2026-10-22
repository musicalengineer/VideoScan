// PruneQARound1Tests.swift
// QA round 1 on the simple PrunePlan (docs/design/pruneplan_simple_2026-10-21.md).
// Two RED findings (Tidy's backlog door) and one GREEN sensor (I2: a path that
// reaches the archive file through a symlinked folder is never moved).
// Sandbox fixture from PruneApplyTests; no real volume, no real Trash.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Prune — QA round 1", .serialized)
@MainActor
struct PruneQARound1Tests {

    private func consoleText(_ model: VideoScanModel) async -> String {
        try? await Task.sleep(nanoseconds: 400_000_000)   // the console flushes every 0.15 s
        return model.dashboard.consoleLines.joined(separator: "\n")
    }

    /// Pins VideoScanModel+PrunePlan.swift:99-104 + VideoScanModel+MediaLedger.swift:173.
    /// Tidy shows "Copies of archived media — N" (partial-MD5 / promote-link
    /// tally) and a "Review…" button; the button closes Tidy and calls
    /// offerArchivedWhatNextForBacklog, which now offers only copies with a
    /// stored full SHA-256. With none, `offerArchivedWhatNext` returns on
    /// `recordIDs.isEmpty` — no sheet, no line: Rick's "if none, say so" is broken.
    @Test("QA r1 RED: Tidy's review of archived copies with nothing byte-identical says so — never a silent no-op")
    func tidyBacklogWithNothingOfferedSaysSo() async throws {
        let f = try await PruneApplyTests.fixture("qa_tidy_none"); defer { f.sb.cleanup() }
        for r in [f.source, f.copy] { r.contentFixity = nil; r.archiveFixity = nil }   // "not hashed yet"
        try #require(CatalogCommit.digest(of: f.source) == nil && CatalogCommit.digest(of: f.copy) == nil)
        try #require(f.model.archivedCopy(of: f.source) != nil, "fixture: Tidy still counts the source as a copy of archived media")
        let plan = await f.model.prunePlan(batch: nil)
        try #require(plan.offeredCount == 0)

        f.model.pendingArchivedWhatNext = nil
        await f.model.offerArchivedWhatNextForBacklog()
        let text = await consoleText(f.model)
        #expect(f.model.pendingArchivedWhatNext != nil
                || text.localizedCaseInsensitiveContains("no obvious choices"),
                "the Review button closed Tidy and nothing was shown or said")
    }

    /// Pins VideoScanModel+PrunePlan.swift:101-103: `ids` = every IDENTICAL row
    /// (offered AND held), `totalBytes` = offered bytes only, and the sheet's
    /// headline (ArchivedWhatNextSheet.swift:110) reads them as one set.
    @Test("QA r1 RED: Tidy's headline count and size describe the same copies")
    func tidyHeadlineCountMatchesItsBytes() async throws {
        let f = try await PruneApplyTests.fixture("qa_tidy_count"); defer { f.sb.cleanup() }
        f.copy.pairGroupID = UUID()   // R5: byte-identical, but held as a pair half
        let plan = await f.model.prunePlan(batch: nil)
        try #require(plan.offeredIDs == [f.source.id], "\(plan)")

        f.model.pendingArchivedWhatNext = nil
        await f.model.offerArchivedWhatNextForBacklog()
        let req = try #require(f.model.pendingArchivedWhatNext)
        #expect(req.fileCount == plan.offeredCount,
                "headline: \(req.fileCount) copies (\(req.totalBytes) bytes) — but the bytes are those of \(plan.offeredCount)")
    }

    /// I2 sensor (GREEN expected): a catalog row whose path reaches the
    /// archive file through a symlinked folder carries the archive's digest
    /// and is not on the archive volume by its spelling. Whether or not the
    /// plan lists it, the move must never take the archive file.
    @Test("QA r1 sensor: a copy spelled through a symlinked folder into the archive is never moved")
    func symlinkedFolderIntoTheArchiveNeverMoves() async throws {
        let f = try await PruneApplyTests.fixture("qa_symlink"); defer { f.sb.cleanup() }
        let archiveURL = URL(fileURLWithPath: f.archive.fullPath)
        let link = f.sb.sources.appendingPathComponent("via_link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archiveURL.deletingLastPathComponent())
        let aliasPath = link.appendingPathComponent(archiveURL.lastPathComponent).path
        let alias = MasterArchiveTestSupport.makeRecord(path: aliasPath, userDate: "1995")
        alias.contentFixity = try #require(ContentFixity.captured(path: aliasPath, digest: f.digest, byteCount: alias.sizeBytes))
        f.model.records.append(alias)

        let shown = await f.model.prunePlan(batch: f.batch).shown()
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        _ = await f.model.applyPrune(shown: shown, selected: shown.offeredIDs.union([alias.id]), batch: f.batch,
                                     batchID: "qa-symlink", hooks: PruneApplyTests.hooks(mover))
        #expect(FileManager.default.fileExists(atPath: f.archive.fullPath), "the archive file left")
        #expect(!mover.paths.contains(aliasPath), "the alias path was handed to the Trash")
        #expect(alias.removal == nil)
    }

    /// Pins PrunePlan.swift:201-206 (only OFFERED rows are asked "missing?")
    /// with PrunePlan+Advice.swift:18-24 (a held identical row counts as
    /// remaining unless its reason is `.missing`). A pair-half copy on a
    /// MOUNTED drive that is gone from disk keeps the reason `.pairHalf`, so
    /// the advice says nothing — yet after the move the archive file is the
    /// only copy left.
    @Test("QA r1 RED: the 'only in the Master Archive' advice is not silenced by a held copy that is gone from disk")
    func adviceCountsAMissingHeldCopyAsGone() async throws {
        let f = try await PruneApplyTests.fixture("qa_advice_missing"); defer { f.sb.cleanup() }
        f.copy.pairGroupID = UUID()   // R5: identical, held
        try FileManager.default.removeItem(atPath: f.copy.fullPath)   // gone from a mounted drive
        let shown = await f.model.prunePlan(batch: f.batch).shown()
        try #require(shown.offeredIDs == [f.source.id], "\(shown)")
        #expect(shown.adviceSentence(after: shown.offeredIDs)?.hasPrefix("1 file will exist only in the Master Archive") == true,
                "advice: \(shown.adviceSentence(after: shown.offeredIDs) ?? "nil") — rows: \(shown.items.flatMap(\.rows).map { "\($0.filename) \($0.reason?.text ?? "offered")" })")
    }
}
