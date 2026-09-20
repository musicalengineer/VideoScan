// PruneApplyTests.swift
// "Archived — what next?" → Apply (2026-09-19), as a CHECKLIST since
// 2026-09-20 (Rick: "I want to see a list of dups and decide which ones to
// delete, maybe leave one behind, maybe not"). A real promote in a sandbox
// makes the fixity-verified archive copy; a second copy of the same
// content on the sources volume is the "extra" the person may check.
// Tests use `.permanent` so fixtures never reach the real Trash; the sheet
// always passes `.toTrash` (the same routine, the other flavour).
//
// ISOLATION: sandbox model + sandbox ledger + sandbox archive root; no
// real volume, no real prefs written.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archived — what next? → Apply", .serialized)
@MainActor
struct PruneApplyTests {

    struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let ids: [UUID]
        let shown: PrunePlan
        /// The copy the bar-respecting plan trashes (attested) or the
        /// non-keeper candidate (not attested).
        let dup: PrunePlan.CopyRef
        /// The plan's elected working copy.
        let keeper: PrunePlan.CopyRef
        let archive: VideoRecord
        var archivePath: String { archive.fullPath }
        var family: PrunePlan.Family { shown.families[0] }
    }

    /// Source A promoted; A2 is a byte-identical copy elsewhere on the
    /// sources volume. `attested` = a cloud copy is attested so the ★★★
    /// family is covered and keep-one puts A2 in the default checks;
    /// otherwise (Rick's Christmas2008 case) the bar is not met, nothing
    /// is checked by default, and both copies are checkable.
    private func fixture(_ label: String, attested: Bool = true) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_prune_a.mov"),
                                                       bytes: 40 * 1024, seed: 7)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1992")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA), "fixture: promote made an archive copy")

        let dupDir = sb.sources.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let a2 = dupDir.appendingPathComponent("test_prune_a.mov")
        try FileManager.default.copyItem(at: a, to: a2)
        let recA2 = MasterArchiveTestSupport.makeRecord(path: a2.path, userDate: "1992")
        // Same bytes → same content key: in the real catalog the scanner
        // sets the hash; here the fixture does, on all three copies.
        for r in [recA, recA2, archive] { r.contentHash = "v1:test-prune-a" }
        model.records.append(recA2)
        let ids = [recA.id, recA2.id]
        if attested {
            await model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: ids).flush?.value
        }

        let shown = await model.prunePlan(for: ids, options: .init(), isOnline: { _ in true })
        try #require(shown.families.count == 1, "fixture: one family — \(shown)")
        let family = shown.families[0]
        let candidates = family.rows.filter(\.checkable)
        try #require(candidates.count == 2, "fixture: both working copies are checkable — \(family.rows)")
        let keeper = try #require(candidates.first { $0.planKeeps == .keeper }?.copy, "fixture: a keeper is hinted")
        let dup = try #require(candidates.first { $0.id != keeper.id }?.copy)
        if attested {
            try #require(shown.trashCount == 1 && family.covered && family.defaultSelection == [dup.id],
                         "fixture: keep-one keeps one, the dup is the default check — \(shown)")
        } else {
            try #require(shown.trashCount == 0 && !family.covered && family.defaultSelection.isEmpty,
                         "fixture: the bar is not met, nothing checked by default — \(shown)")
        }
        return Fixture(sb: sb, model: model, ids: ids, shown: shown, dup: dup, keeper: keeper, archive: archive)
    }

    private func apply(_ f: Fixture, selected: Set<UUID>) async -> VideoScanModel.PruneApplyOutcome {
        await f.model.applyPrune(shown: f.shown, selected: selected, recordIDs: f.ids, options: .init(),
                                 batchID: "test-batch", mode: .permanent)
    }

    private func approval(_ f: Fixture) async throws -> MediaLedgerEvent {
        await f.model.mediaLedger.waitForPendingWrites()
        return try #require(f.model.mediaLedger.allEvents().first { $0.event == .approval })
    }

    // MARK: The default (the bar met, keep-one)

    @Test func theCheckedDupGoesTheArchiveAndTheKeeperStay() async throws {
        let f = try await fixture("prune_ok"); defer { f.sb.cleanup() }
        let out = await apply(f, selected: f.shown.defaultSelection)
        #expect(out.trashed == 1 && out.held.isEmpty && out.failed.isEmpty && out.overrideCount == 0, "\(out)")
        #expect(!FileManager.default.fileExists(atPath: f.dup.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.keeper.fullPath), "the working copy kept")
        #expect(FileManager.default.fileExists(atPath: f.archivePath), "the archive copy untouched")
        #expect(f.model.record(forID: f.dup.id)?.purgedAt != nil, "the catalog says it is gone")
        let kinds = f.model.mediaLedger.allEvents().map(\.event)
        #expect(kinds.contains(.approval) && kinds.contains(.copyDeleted), "\(kinds)")
        let approval = try await approval(f)
        #expect(approval.by == .rick && approval.detail[MediaLedgerEvent.Detail.count] == "1")
        #expect(approval.detail[MediaLedgerEvent.Detail.barOverride] == nil, "respected the bar — no override")
    }

    @Test("SELECTION IS THE TRUTH: an unchecked default-trash copy is not moved; nothing checked moves nothing")
    func uncheckedCopiesAreNeverMoved() async throws {
        let f = try await fixture("prune_unchecked"); defer { f.sb.cleanup() }
        #expect(f.shown.defaultSelection == [f.dup.id], "the plan's default would trash the dup")
        let none = await apply(f, selected: [])
        #expect(none.trashed == 0 && none.held.isEmpty, "\(none)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
        // Only the keeper checked (the person swapped which one stays):
        // the dup — the plan's default — stays put.
        let swapped = await apply(f, selected: [f.keeper.id])
        #expect(swapped.trashed == 1 && swapped.held.isEmpty, "\(swapped)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath), "unchecked → untouched")
        #expect(!FileManager.default.fileExists(atPath: f.keeper.fullPath), "checked → gone")
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(f.model.mediaLedger.allEvents().filter { $0.event == .approval }.count == 1, "an empty selection writes no approval")
    }

    // MARK: Rick's case — the bar not met, the person decides

    @Test("OVERRIDE: a ★★★ family with no attestation offers its copies; a check goes to the Trash and the approval says it went against the bar")
    func overrideOnANotCoveredFamily() async throws {
        let f = try await fixture("prune_override", attested: false); defer { f.sb.cleanup() }
        #expect(f.family.advice == "★★★ / Important — the bar you set wants a cloud or off-site copy; none attested. You can still choose.")
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 1 && out.held.isEmpty && out.overrideCount == 1, "\(out)")
        #expect(out.summary.contains("1 against the bar you set"), "\(out.summary)")
        #expect(!FileManager.default.fileExists(atPath: f.dup.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.keeper.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.archivePath))
        let approval = try await approval(f)
        #expect(approval.detail[MediaLedgerEvent.Detail.count] == "1")
        #expect(approval.detail[MediaLedgerEvent.Detail.barOverride] == "1 copy — ★★★ / Important — no cloud or off-site copy attested",
                "\(approval.detail)")
        #expect(approval.detail[MediaLedgerEvent.Detail.action] == "delete")
    }

    @Test("ARCHIVE ONLY: checking every working copy is allowed; the family then keeps only the archive copy")
    func everyWorkingCopyMayGo() async throws {
        let f = try await fixture("prune_archiveonly", attested: false); defer { f.sb.cleanup() }
        let all: Set<UUID> = [f.dup.id, f.keeper.id]
        let judged = f.shown.selection(all)
        #expect(judged.archiveOnlySentence == "\(f.archive.filename) will exist only in the Master Archive after this.")
        #expect(judged.overrideSentence == "2 copies go against the bar you set: ★★★ / Important — needs 1 more device, no cloud or off-site copy attested.")
        #expect(ArchivedWhatNextSheet.confirmMessage(judged).hasSuffix(judged.archiveOnlySentence ?? "<none>"))
        let out = await apply(f, selected: all)
        #expect(out.trashed == 2 && out.held.isEmpty && out.overrideCount == 2, "\(out)")
        #expect(!FileManager.default.fileExists(atPath: f.dup.fullPath))
        #expect(!FileManager.default.fileExists(atPath: f.keeper.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.archivePath), "the archive copy is never touched")
        let approval = try await approval(f)
        #expect(approval.detail[MediaLedgerEvent.Detail.barOverride]?.hasPrefix("2 copies — ★★★ / Important — needs 1 more device") == true,
                "\(approval.detail)")
        // One removal line per copy that left the disk (copyDeleted here —
        // the tests' `.permanent`; the sheet's `.toTrash` writes copyTrashed).
        let removed = f.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(Set(removed.map(\.recordID)) == all && removed.count == 2, "\(removed.map(\.filename))")
    }

    // MARK: Held back — the fresh plan

    @Test func aNoteAddedSinceTheListWasShownHoldsTheCopy() async throws {
        let f = try await fixture("prune_note"); defer { f.sb.cleanup() }
        f.model.record(forID: f.dup.id)?.userNotes = "Mom's favourite — keep this one"
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 0 && out.held.count == 1, "\(out)")
        #expect(out.held[0] == "\(f.dup.filename) — changed since the list was shown: has your note", "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval }, "nothing approved")
    }

    @Test("a family whose archive copy lost its fixity since the list was shown holds every check")
    func anUnverifiedArchiveCopyHoldsTheCopy() async throws {
        let f = try await fixture("prune_unverified", attested: false); defer { f.sb.cleanup() }
        f.archive.archiveFixity = nil
        let out = await apply(f, selected: [f.dup.id, f.keeper.id])
        #expect(out.trashed == 0 && out.held.count == 2, "\(out)")
        #expect(out.held.allSatisfy { $0.hasSuffix("changed since the list was shown: archive copy unverified") }, "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.keeper.fullPath))
    }

    @Test func aMissingArchiveCopyHoldsEverything() async throws {
        let f = try await fixture("prune_noarchive"); defer { f.sb.cleanup() }
        try FileManager.default.removeItem(atPath: f.archivePath)
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 0 && out.held.count == 1, "\(out)")
        #expect(out.held[0].contains("archive copy is not on disk"), "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath), "never trash the last copy")
    }

    @Test func aKeeperRewrittenOnDiskHoldsTheCopy() async throws {
        let f = try await fixture("prune_keeper"); defer { f.sb.cleanup() }
        try Data(count: 10).write(to: URL(fileURLWithPath: f.keeper.fullPath))
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 0 && out.held.first?.contains("working copy to keep") == true, "\(out)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
    }

    @Test("an id that was never a checkable row is held, not trusted")
    func anUnofferedIDIsHeld() async throws {
        let f = try await fixture("prune_unoffered"); defer { f.sb.cleanup() }
        let fresh = await f.model.prunePlan(for: f.ids, options: .init(), isOnline: { _ in true })
        let (go, held) = VideoScanModel.pruneTargets(shown: f.shown, selected: [f.archive.id, UUID(), f.dup.id], fresh: fresh)
        #expect(go.map(\.id) == [f.dup.id])
        #expect(held.map(\.reason) == ["was never offered: the archive copy"], "\(held)")
        #expect(FileManager.default.fileExists(atPath: f.archivePath))
    }

    @Test func readOnlyViewersNeverDelete() async throws {
        let f = try await fixture("prune_ro"); defer { f.sb.cleanup() }
        f.model.isReadOnly = true
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 0)
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
    }

    // MARK: The sheet's pure parts

    @Test func applyIsOfferedOnlyWithSomethingCheckedOnce() {
        typealias S = ArchivedWhatNextSheet
        #expect(S.canApply(selectedCount: 2, applying: false, applied: false, readOnly: false))
        #expect(!S.canApply(selectedCount: 0, applying: false, applied: false, readOnly: false))
        #expect(!S.canApply(selectedCount: 2, applying: true, applied: false, readOnly: false))
        #expect(!S.canApply(selectedCount: 2, applying: false, applied: true, readOnly: false))
        #expect(!S.canApply(selectedCount: 2, applying: false, applied: false, readOnly: true))
        #expect(!S.canApply(selectedCount: 2, applying: false, applied: false, readOnly: false, reloading: true),
                "never on a plan that is being recomputed")
        // The confirmation says the override and the archive-only sentence in words, when they apply.
        let plain = S.confirmMessage(.empty)
        #expect(!plain.contains("against the bar") && !plain.contains("only in the Master Archive"))
        let loud = S.confirmMessage(PrunePlan.Selection(count: 2, bytes: 1, overrideCount: 2,
                                                        overrideShortfalls: ["★★★ / Important — no cloud or off-site copy attested"],
                                                        archiveOnlyFamilies: ["Christmas2008.mov"]))
        #expect(loud.contains("2 copies go against the bar you set: ★★★ / Important — no cloud or off-site copy attested."))
        #expect(loud.hasSuffix("Christmas2008.mov will exist only in the Master Archive after this."))
    }

    @Test("the checklist lists a header per family and its rows, capped at 200 rows with the rest counted")
    func checklistIsBuiltFromThePlanAndCapped() async throws {
        let f = try await fixture("prune_checklist", attested: false); defer { f.sb.cleanup() }
        let list = PruneChecklist.build(f.shown)
        #expect(list.hiddenRowCount == 0)
        #expect(list.items.count == 1 + f.family.rows.count)
        #expect(list.visibleIDs == Set(f.family.rows.map(\.id)))
        guard case .family(let name, _, let level, let advice) = list.items[0].kind else {
            Issue.record("first item is the family header"); return
        }
        #expect(name == f.family.displayName && level == "★★★ / Important" && advice == f.family.advice)
        #expect(list.items.dropFirst().allSatisfy { if case .copy = $0.kind { return true } else { return false } })
        // The cap: rows past it are counted, families past it are not headed.
        let capped = PruneChecklist.build(f.shown, maxRows: 1)
        #expect(capped.items.count == 2 && capped.hiddenRowCount == f.family.rows.count - 1)
        #expect(PruneChecklist.build(.empty) == .empty)
    }

    // MARK: QA RED tests (2026-09-20 review of 91390deb) — green since the fix commit

    @Test("QA RED: an attestation withdrawn since the list was shown must HOLD the checked copy, not quietly record an override the person never confirmed")
    func attestationWithdrawnSinceTheListWasShownHoldsTheCopy() async throws {
        let f = try await fixture("prune_withdrawn"); defer { f.sb.cleanup() }
        // The sheet the person confirmed: covered, no override sentence.
        #expect(f.shown.selection([f.dup.id]).overrideCount == 0)
        // Another window withdraws the cloud attestation before Apply.
        await f.model.recordAttestation(kind: .cloud, answer: .no, for: f.ids).flush?.value
        let out = await apply(f, selected: [f.dup.id])
        // Pins VideoScanModel+PruneApply.swift:98-113 (pruneTargets) / :208-218 (judged on fresh only).
        #expect(out.trashed == 0 && out.overrideCount == 0, "a bar verdict that got STRICTER since the sheet was shown is a change, not a decision — \(out)")
        #expect(out.held.count == 1 && out.held[0].hasPrefix(f.dup.filename), "the held copy is named — \(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval }, "nothing approved")
    }

    @Test("QA RED: in a not-covered family the hinted keeper (left unchecked) is still checked on disk before the dup goes")
    func theHintedKeeperIsCheckedOnDiskInANotCoveredFamily() async throws {
        let f = try await fixture("prune_override_keeper", attested: false); defer { f.sb.cleanup() }
        try #require(f.family.keeper == nil, "fixture: the not-covered branch elects no keeper (PrunePlan.swift:689)")
        try #require(f.family.rows.contains { $0.planKeeps == .keeper && $0.id == f.keeper.id })
        // The working copy the plan hinted it would keep is rewritten in place.
        try Data(count: 10).write(to: URL(fileURLWithPath: f.keeper.fullPath))
        let out = await apply(f, selected: [f.dup.id])
        // Pins VideoScanModel+PruneApply.swift:173-177 (keeperOf built from family.keeper, nil here).
        #expect(out.trashed == 0 && out.held.first?.contains("working copy to keep") == true,
                "the only other working copy is not what the catalog recorded — \(out)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
    }

    @Test("QA RED: the 200-row cap must never hide a row that is checked by default (Tidy backlog is routinely > 200 rows)")
    func defaultChecksNeverHideBehindTheCap() {
        // Fixture amended by feature-dev with QA's assertions kept intact:
        // the fix lists every default-checked family in full, so for the
        // cap to bite at all the batch needs families WITHOUT a default
        // check — ★★★ with no attestation (not covered: checkable, unchecked).
        // They come FIRST in plan order, so the test also proves the
        // default-checked families are listed wherever they sit.
        var families: [[ArchiveCopySnapshot]] = []
        let n = PruneChecklist.maxRows / 2 + 5
        for i in 0..<n {
            let key = "h:u\(i)"
            let arch = ArchiveCopySnapshot(id: UUID(), filename: "u\(i).mov", fullPath: "/A/u\(i).mov", volumeName: "FamilyArchive",
                                           sizeBytes: 10, contentKey: key, isArchiveCopy: true, fixityVerified: true,
                                           starRating: 3, volumeIsConnectedWorking: false)
            let dup = ArchiveCopySnapshot(id: UUID(), filename: "u\(i).mov", fullPath: "/W/u\(i).mov", volumeName: "LaCie",
                                          sizeBytes: 10, contentKey: key, starRating: 3, volumeFreeBytes: 100)
            families.append([arch, dup])
        }
        for i in 0..<n {
            let key = "h:\(i)"
            let arch = ArchiveCopySnapshot(id: UUID(), filename: "a\(i).mov", fullPath: "/A/a\(i).mov", volumeName: "FamilyArchive",
                                           sizeBytes: 10, contentKey: key, isArchiveCopy: true, fixityVerified: true,
                                           starRating: 1, volumeIsConnectedWorking: false)
            let dup = ArchiveCopySnapshot(id: UUID(), filename: "a\(i).mov", fullPath: "/W/a\(i).mov", volumeName: "LaCie",
                                          sizeBytes: 10, contentKey: key, starRating: 1, volumeFreeBytes: 100)
            families.append([arch, dup])
        }
        let plan = PrunePlan.compute(families: families, options: .init(keepOne: false))
        #expect(plan.defaultSelection.count == n && plan.checkableCount == 2 * n, "fixture: half the dups are default checks")
        let list = PruneChecklist.build(plan)
        try? #require(list.hiddenRowCount > 0, "fixture: the cap bites")
        let visible = Set(list.items.compactMap { if case .copy(let r) = $0.kind { return r.id } else { return nil } })
        let hiddenButChecked = plan.defaultSelection.subtracting(visible)
        // Pins ArchivedWhatNextSheet.swift:242 (selected = p.defaultSelection) vs :395-404 (the cap).
        #expect(hiddenButChecked.isEmpty,
                "\(hiddenButChecked.count) copies would go to the Trash that the person could not see or uncheck")
        #expect(list.visibleIDs == visible, "visibleIDs is what the list shows — the sheet seeds its checks from it")
        #expect(visible.count == 2 * n + PruneChecklist.maxRows && list.hiddenRowCount == 2 * n - PruneChecklist.maxRows,
                "default-checked families in full (\(2 * n) rows), then the cap on the rest")
        // The default-checked families are listed first, whatever their plan order.
        guard case .family(let name, _, _, _) = list.items[0].kind else { Issue.record("a header first"); return }
        #expect(name.hasPrefix("a"), "the ★ family with a default check leads, not the ★★★ one that came first: \(name)")
    }

    /// Sensor: Apply is a plan in front of the ONE Trash routine — it owns
    /// no file deletion, and the sheet never asks for permanent deletion.
    @Test func sensorApplyOwnsNoFileDeletionAndTheSheetOnlyTrashes() throws {
        func source(_ name: String) throws -> String {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: dir.appendingPathComponent("VideoScan").appendingPathComponent(name), encoding: .utf8)
        }
        let apply = try source("VideoScanModel+PruneApply.swift")
        #expect(apply.contains("await deleteConfirmedJunk(targets, mode: mode)"), "the ONE existing Trash routine")
        #expect(!apply.contains("trashItem("), "no file deletion of its own")
        #expect(!apply.contains("removeItem("), "no file deletion of its own")
        let sheet = try source("ArchivedWhatNextSheet.swift")
        #expect(sheet.contains("model.applyPrune(shown: shown, selected: selected"), "Apply is wired to the checklist")
        #expect(!sheet.contains(".permanent"), "the sheet only ever moves to the Trash")
    }
}
