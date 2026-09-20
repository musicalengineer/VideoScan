// PruneApplyTests.swift
// "Archived — what next?" → Apply (2026-09-19), as a CHECKLIST since
// 2026-09-20 (Rick: "I want to see a list of dups and decide which ones to
// delete, maybe leave one behind, maybe not"), v3 the same evening ("allow
// me to delete any copy or all copies on any drive EXCEPT FamilyArchive …
// many are subsets or improvements or trimmed"). A real promote in a
// sandbox makes the fixity-verified archive copy; a second copy of the
// same content on the sources volume is the "extra" the person may
// check; a trimmed VERSION with a note is checkable too and its note is
// carried to the archive copy. Tests use `.permanent` so fixtures never
// reach the real Trash; the sheet always passes `.toTrash` (the same
// routine, the other flavour).
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
        /// The trimmed version with a note (when the fixture made one).
        let version: PrunePlan.CopyRef?
        var archivePath: String { archive.fullPath }
        var family: PrunePlan.Family { shown.families[0] }
    }

    static let versionNote = "Trimmed for Tim's wedding video — keep the note"

    /// Source A promoted; A2 is a byte-identical copy elsewhere on the
    /// sources volume. `attested` = a cloud copy is attested so the ★★★
    /// family is covered and keep-one puts A2 in the default checks;
    /// otherwise (Rick's Christmas2008 case) the bar is not met, nothing
    /// is checked by default, and both copies are checkable. `withVersion`
    /// adds a trimmed version of A (different bytes, derivedFrom = A,
    /// kind "trim") carrying a human note.
    private func fixture(_ label: String, attested: Bool = true, withVersion: Bool = false) async throws -> Fixture {
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
        var ids = [recA.id, recA2.id]
        var recV: VideoRecord?
        if withVersion {
            let v = try MasterArchiveTestSupport.writeBlob(at: dupDir.appendingPathComponent("test_prune_a_trimmed.mov"),
                                                           bytes: 20 * 1024, seed: 8)
            let r = MasterArchiveTestSupport.makeRecord(path: v.path, userDate: "1992")
            r.contentHash = "v1:test-prune-a-trimmed"
            r.derivedFrom = recA.id; r.derivationKind = "trim"
            r.userNotes = Self.versionNote
            model.records.append(r)
            recV = r
            ids.append(r.id)
        }
        if attested {
            await model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: ids).flush?.value
        }

        let shown = await model.prunePlan(for: ids, options: .init(), isOnline: { _ in true })
        try #require(shown.families.count == 1, "fixture: one family — \(shown)")
        let family = shown.families[0]
        try #require(family.archive.map(\.id) == [archive.id] && family.archiveVerified, "fixture: the archive copy is the header")
        try #require(!family.rows.contains { $0.id == archive.id }, "fixture: the archive copy is never a row")
        let candidates = family.rows.filter(\.checkable)
        try #require(candidates.count == (withVersion ? 3 : 2), "fixture: every working copy is checkable — \(family.rows)")
        let keeper = try #require(candidates.first { $0.planKeeps == .keeper }?.copy, "fixture: a keeper is hinted")
        let dup = try #require(candidates.first { $0.id != keeper.id && !$0.kind.isVersion }?.copy)
        var version: PrunePlan.CopyRef?
        if let recV {
            let row = try #require(family.rows.first { $0.id == recV.id })
            try #require(row.checkable && !row.defaultChecked && row.kind == .trimmed && row.hasNote && row.planKeeps == .version,
                         "fixture: the version is checkable, unchecked, trimmed, noted — \(row)")
            version = row.copy
        }
        if attested {
            try #require(shown.trashCount == 1 && family.covered && family.defaultSelection == [dup.id],
                         "fixture: keep-one keeps one, the dup is the default check — \(shown)")
        } else {
            try #require(shown.trashCount == 0 && !family.covered && family.defaultSelection.isEmpty,
                         "fixture: the bar is not met, nothing checked by default — \(shown)")
        }
        return Fixture(sb: sb, model: model, ids: ids, shown: shown, dup: dup, keeper: keeper, archive: archive, version: version)
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

    // MARK: v3 — versions and notes (Rick's ruling 2026-09-20)

    @Test("VERSION: a checked trimmed version goes, writes its removal line, and its note is carried to the archive copy first")
    func aCheckedVersionGoesAndItsNoteReachesTheArchiveCopy() async throws {
        let f = try await fixture("prune_version", withVersion: true); defer { f.sb.cleanup() }
        let version = try #require(f.version)
        #expect(f.family.rows.first { $0.id == version.id }?.reasonText == "a trimmed version — the original is in the archive")
        #expect(f.archive.userNotes.isEmpty, "fixture: the archive copy has no note yet")
        let out = await apply(f, selected: [version.id])
        #expect(out.trashed == 1 && out.held.isEmpty && out.failed.isEmpty && out.carried == 1, "\(out)")
        #expect(out.summary.contains("notes and marks from 1 carried to the archive copy"), "\(out.summary)")
        #expect(!FileManager.default.fileExists(atPath: version.fullPath), "the version left the disk")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath) && FileManager.default.fileExists(atPath: f.keeper.fullPath),
                "unchecked copies untouched")
        #expect(FileManager.default.fileExists(atPath: f.archivePath))
        #expect(f.archive.userNotes.contains(Self.versionNote), "the note is on the archive copy now: \(f.archive.userNotes)")
        #expect(f.model.record(forID: version.id)?.purgedAt != nil)
        await f.model.mediaLedger.waitForPendingWrites()
        let removed = f.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(removed.map(\.recordID) == [version.id], "\(removed.map(\.filename))")
        let approval = try await approval(f)
        #expect(approval.detail[MediaLedgerEvent.Detail.files] == version.filename)
        #expect(approval.detail[MediaLedgerEvent.Detail.barOverride] == nil, "the bar is met — the original and the dup stay")
    }

    @Test("a version's archive copy is its FAMILY's — the disk check finds it even though the version has no promote link")
    func aVersionIsHeldWhenTheFamilysArchiveCopyIsGone() async throws {
        let f = try await fixture("prune_version_noarchive", withVersion: true); defer { f.sb.cleanup() }
        let version = try #require(f.version)
        try FileManager.default.removeItem(atPath: f.archivePath)
        let out = await apply(f, selected: [version.id])
        #expect(out.trashed == 0 && out.held.count == 1 && out.held[0].contains("archive copy is not on disk"), "\(out)")
        #expect(FileManager.default.fileExists(atPath: version.fullPath), "never trash a version whose original is not safely archived")
    }

    @Test("HASH TO CONFIRM: a name-related unhashed copy is a might-be row; hashing it (and the unhashed family members) joins it as a normal candidate; different bytes stay out as different footage")
    func hashToConfirmJoinsAMatchingCopyAndNamesADifferentOne() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune_hash"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_prune_h.mov"), bytes: 40 * 1024, seed: 21)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1992")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA))
        let dir = sb.sources.appendingPathComponent("M4drive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let same = dir.appendingPathComponent("test_prune_h copy.mov")
        try FileManager.default.copyItem(at: a, to: same)
        let other = try MasterArchiveTestSupport.writeBlob(at: dir.appendingPathComponent("test_prune_h_trimmed.mov"), bytes: 30 * 1024, seed: 22)
        let recSame = MasterArchiveTestSupport.makeRecord(path: same.path, userDate: "1992")
        let recOther = MasterArchiveTestSupport.makeRecord(path: other.path, userDate: "1992")
        for r in [recA, archive, recSame, recOther] { r.contentHash = "" }   // nothing hashed yet
        model.records += [recSame, recOther]
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)

        let before = await model.prunePlan(for: [recA.id], options: .init(bar: bar), isOnline: { _ in true })
        try #require(before.families.count == 1)
        let f0 = before.families[0]
        #expect(f0.rows.map(\.id) == [recA.id], "only the promote link joins — the unhashed copies are not in the family")
        #expect(Set(f0.related.map(\.id)) == [recSame.id, recOther.id] && f0.related.allSatisfy { $0.status == .needsHash })
        #expect(Set(f0.unhashedMemberIDs) == [recA.id, archive.id], "the family members need a hash too, so the keys can compare")
        #expect(!before.checkableIDs.contains(recSame.id), "never checkable without a hash match")
        let list = PruneChecklist.build(before)
        let hashAll: [UUID] = list.items.compactMap { item -> [UUID]? in
            if case .family(let h) = item.kind { return h.hashAllIDs } else { return nil }
        }.first ?? []
        #expect(Set(hashAll) == [recSame.id, recOther.id, recA.id, archive.id], "Hash all = the unhashed related rows + the unhashed members")

        let hashed = await model.hashToConfirm(recordIDs: hashAll + [recA.id])
        #expect(Set(hashed) == Set(hashAll), "each record hashed once")
        #expect(!recA.contentHash.isEmpty && recA.contentHash == recSame.contentHash && recA.contentHash == archive.contentHash)
        #expect(recOther.contentHash != recA.contentHash && !recOther.contentHash.isEmpty)
        #expect(recA.contentHashAt != nil)
        #expect(await model.hashToConfirm(recordIDs: [recA.id]).isEmpty, "already hashed — left alone")

        let after = await model.prunePlan(for: [recA.id], options: .init(bar: bar), isOnline: { _ in true })
        let f1 = after.families[0]
        let joined = try #require(f1.rows.first { $0.id == recSame.id })
        #expect(joined.checkable && joined.kind == .duplicate, "a matching hash makes it a normal candidate")
        #expect(f1.related.map(\.id) == [recOther.id] && f1.related[0].status == .differentFootage,
                "different bytes stay out, and say so")
        #expect(f1.unhashedMemberIDs.isEmpty)
        #expect(f1.logLine.contains("1 name-related (1 different)"), "\(f1.logLine)")
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
        // A note the person SAW on the list is not a change: the copy goes, the note is carried.
        let seen = await f.model.prunePlan(for: f.ids, options: .init(), isOnline: { _ in true })
        #expect(seen.families[0].rows.first { $0.id == f.dup.id }?.hasNote == true)
        let again = await f.model.applyPrune(shown: seen, selected: [f.dup.id], recordIDs: f.ids, options: .init(),
                                             batchID: "test-batch-2", mode: .permanent)
        #expect(again.trashed == 1 && again.carried == 1, "\(again)")
        #expect(f.archive.userNotes.contains("Mom's favourite"), "\(f.archive.userNotes)")
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

    @Test("an id that was never a checkable row is held, not trusted — the archive copy is named, an unknown id is ignored")
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
        // The confirmation says the counts, that the originals in the
        // archive are untouched, then the override and the archive-only
        // sentence in words, when they apply.
        let plain = S.confirmMessage(.empty)
        #expect(plain.hasPrefix("0 copies (0 B) go to the Trash. The originals in the Master Archive are untouched"), "\(plain)")
        #expect(!plain.contains("against the bar") && !plain.contains("only in the Master Archive"))
        let loud = S.confirmMessage(PrunePlan.Selection(count: 2, bytes: 1, overrideCount: 2,
                                                        overrideShortfalls: ["★★★ / Important — no cloud or off-site copy attested"],
                                                        archiveOnlyFamilies: ["Christmas2008.mov"]),
                                    archiveLabel: "FamilyArchive")
        #expect(loud.hasPrefix("2 copies (1 B) go to the Trash. The originals in FamilyArchive are untouched"), "\(loud)")
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
        guard case .family(let h) = list.items[0].kind else {
            Issue.record("first item is the family header"); return
        }
        #expect(h.name == f.family.displayName && h.level == "★★★ / Important" && h.advice == f.family.advice)
        #expect(h.archiveCount == 1 && h.archiveVerified && h.hashAllIDs.isEmpty)
        #expect(h.checkableIDs == f.family.checkableIDs && h.checkableBytes == f.family.checkableBytes)
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
        // Pins VideoScanModel+PruneApply.swift (pruneTargets: the shown verdict vs the fresh one).
        #expect(out.trashed == 0 && out.overrideCount == 0, "a bar verdict that got STRICTER since the sheet was shown is a change, not a decision — \(out)")
        #expect(out.held.count == 1 && out.held[0].hasPrefix(f.dup.filename), "the held copy is named — \(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval }, "nothing approved")
    }

    @Test("QA RED: in a not-covered family the hinted keeper (left unchecked) is still checked on disk before the dup goes")
    func theHintedKeeperIsCheckedOnDiskInANotCoveredFamily() async throws {
        let f = try await fixture("prune_override_keeper", attested: false); defer { f.sb.cleanup() }
        try #require(f.family.keeper == nil, "fixture: the not-covered branch elects no keeper")
        try #require(f.family.rows.contains { $0.planKeeps == .keeper && $0.id == f.keeper.id })
        // The working copy the plan hinted it would keep is rewritten in place.
        try Data(count: 10).write(to: URL(fileURLWithPath: f.keeper.fullPath))
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 0 && out.held.first?.contains("working copy to keep") == true,
                "the only other working copy is not what the catalog recorded — \(out)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
    }

    @Test("QA RED: the 200-row cap must never hide a row that is checked by default (Tidy backlog is routinely > 200 rows)")
    func defaultChecksNeverHideBehindTheCap() {
        // The fix lists every default-checked family in full, so for the
        // cap to bite at all the batch needs families WITHOUT a default
        // check — ★★★ with no attestation (not covered: checkable,
        // unchecked). They come FIRST in plan order, so the test also
        // proves the default-checked families are listed wherever they
        // sit. v3: the archive copy is no longer a row, so each family is
        // ONE row and the ★★★ families must outnumber the cap.
        var families: [[ArchiveCopySnapshot]] = []
        let n = PruneChecklist.maxRows + 5
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
        #expect(hiddenButChecked.isEmpty,
                "\(hiddenButChecked.count) copies would go to the Trash that the person could not see or uncheck")
        #expect(list.visibleIDs == visible, "visibleIDs is what the list shows — the sheet seeds its checks from it")
        #expect(visible.count == n + PruneChecklist.maxRows && list.hiddenRowCount == n - PruneChecklist.maxRows,
                "default-checked families in full (\(n) rows), then the cap on the rest")
        // The default-checked families are listed first, whatever their plan order.
        guard case .family(let h) = list.items[0].kind else { Issue.record("a header first"); return }
        #expect(h.name.hasPrefix("a"), "the ★ family with a default check leads, not the ★★★ one that came first: \(h.name)")
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
        #expect(apply.contains("applyHumanMetadataInheritance(from: rec, to: archive)"), "the carry-over reuses the one set of rules")
        let sheet = try source("ArchivedWhatNextSheet.swift")
        #expect(sheet.contains("model.applyPrune(shown: shown, selected: selected"), "Apply is wired to the checklist")
        #expect(!sheet.contains(".permanent"), "the sheet only ever moves to the Trash")
        #expect(sheet.contains("minWidth: 960") && sheet.contains("minHeight: 720"), "Rick: a bigger dialog box")
    }
}
