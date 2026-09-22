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
    /// kind "trim") carrying a human note. `extraCopies` adds that many
    /// MORE byte-identical copies (A3, A4…) — duplicates sharing one
    /// archive copy (codex follow-up #6). Their ids follow A2's in `ids`.
    private func fixture(_ label: String, attested: Bool = true, withVersion: Bool = false,
                         extraCopies: Int = 0) async throws -> Fixture {
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
        for n in 0..<extraCopies {
            let an = dupDir.appendingPathComponent("test_prune_a_\(n + 3).mov")
            try FileManager.default.copyItem(at: a, to: an)
            let r = MasterArchiveTestSupport.makeRecord(path: an.path, userDate: "1992")
            r.contentHash = "v1:test-prune-a"
            model.records.append(r)
            ids.append(r.id)
        }
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
        try #require(candidates.count == (withVersion ? 3 : 2) + extraCopies, "fixture: every working copy is checkable — \(family.rows)")
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
            try #require(shown.trashCount == 1 + extraCopies && family.covered
                         && (extraCopies > 0 || family.defaultSelection == [dup.id]),
                         "fixture: keep-one keeps one, the dup is the default check — \(shown)")
        } else {
            try #require(shown.trashCount == 0 && !family.covered && family.defaultSelection.isEmpty,
                         "fixture: the bar is not met, nothing checked by default — \(shown)")
        }
        return Fixture(sb: sb, model: model, ids: ids, shown: shown, dup: dup, keeper: keeper, archive: archive, version: version)
    }

    private func apply(_ f: Fixture, selected: Set<UUID>,
                       hooks: VideoScanModel.PruneVerifyHooks = .live) async -> VideoScanModel.PruneApplyOutcome {
        await f.model.applyPrune(shown: f.shown, selected: selected, recordIDs: f.ids, options: .init(),
                                 batchID: "test-batch", mode: .permanent, hooks: hooks)
    }

    /// Thread-safe tally of the paths the verification opened (the hooks
    /// fire off-main). Counts OPENS, not callback labels.
    final class OpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        func opens(of p: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == p }.count }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    /// Same byte count, different bytes — the stat-size check cannot see it.
    private func rewriteSameSize(_ path: String, seed: UInt64) throws {
        let size = Int((try FileManager.default.attributesOfItem(atPath: path))[.size] as? Int64 ?? 0)
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: size, seed: seed)
    }

    private func approval(_ f: Fixture) async throws -> MediaLedgerEvent {
        await f.model.mediaLedger.waitForPendingWrites()
        return try #require(f.model.mediaLedger.allEvents().first { $0.event == .approval })
    }

    // MARK: The default (the bar met, keep-one)

    @Test func theCheckedDupGoesTheArchiveAndTheKeeperStay() async throws {
        let f = try await fixture("prune_ok"); defer { f.sb.cleanup() }
        // The tie on free space goes to the lower path — `copies/…` — so the
        // default-trashed row is the promotion ORIGINAL: trusted by its stamp
        // (unchanged since the archive copy read back), not re-read.
        try #require(f.family.rows.first { $0.id == f.dup.id }?.kind == .original)
        #expect(f.archive.contentFixity == nil, "fixture: no stored whole-file fixity on the archive copy yet")
        #expect(f.shown.selection(f.shown.defaultSelection).verifySentence == nil, "an original is not counted as a byte check")
        let out = await apply(f, selected: f.shown.defaultSelection)
        #expect(out.trashed == 1 && out.held.isEmpty && out.failed.isEmpty && out.overrideCount == 0, "\(out)")
        #expect(out.verified == 0 && !out.summary.contains("byte-for-byte"), "the original was not read — \(out.summary)")
        // Codex follow-up #2: the ARCHIVE copy must present current evidence
        // before anything goes; with no stamp yet (Promote writes none) it
        // is read in full once, and its stamp is stored for next time.
        #expect(out.archiveReads == 1 && f.archive.contentFixity != nil, "the archive copy read once, stamped — \(out)")
        #expect(!FileManager.default.fileExists(atPath: f.dup.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.keeper.fullPath), "the working copy kept")
        #expect(FileManager.default.fileExists(atPath: f.archivePath), "the archive copy untouched")
        #expect(f.model.record(forID: f.dup.id)?.purgedAt != nil, "the catalog says it is gone")
        let approval = try await approval(f)   // waits for pending ledger writes
        let kinds = f.model.mediaLedger.allEvents().map(\.event)
        #expect(kinds.contains(.approval) && kinds.contains(.copyDeleted), "\(kinds)")
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
        #expect(f.shown.selection([version.id]).verifyCount == 0, "a version goes on provenance — it never claimed identical bytes")
        let out = await apply(f, selected: [version.id])
        #expect(out.trashed == 1 && out.held.isEmpty && out.failed.isEmpty && out.carried == 1 && out.verified == 0, "\(out)")
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

    // MARK: Byte-for-byte before the Trash (QA 2026-09-20 MAJOR 2)

    @Test("DUPLICATE: a checked duplicate is read in full against the archive copy before it goes; the archive copy's fresh fixity is stored")
    func aDuplicateIsReadByteForByteAgainstTheArchiveBeforeItGoes() async throws {
        let f = try await fixture("prune_bytecheck"); defer { f.sb.cleanup() }
        let dup = try #require(f.family.rows.first { $0.kind == .duplicate })
        try #require(dup.id == f.keeper.id, "fixture: the copy is the hinted keeper; the person swaps")
        #expect(f.shown.selection([dup.id]).verifySentence == "1 copy will be checked byte-for-byte against the archive before it goes.")
        #expect(f.archive.contentFixity == nil)
        let out = await apply(f, selected: [dup.id])
        #expect(out.trashed == 1 && out.held.isEmpty && out.verified == 1, "\(out)")
        #expect(out.summary.contains("1 checked byte-for-byte against the archive"), "\(out.summary)")
        #expect(!FileManager.default.fileExists(atPath: dup.copy.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath) && FileManager.default.fileExists(atPath: f.archivePath))
        #expect(f.archive.contentFixity != nil, "the archive copy was read in full once — its fixity stands in next time")
    }

    @Test("ORIGINAL: the promotion source rewritten in place (same size) after the archive copy read back is read in full and held")
    func anOriginalRewrittenSinceTheReadBackIsHeld() async throws {
        let f = try await fixture("prune_origrewrite"); defer { f.sb.cleanup() }
        try #require(f.family.rows.first { $0.id == f.dup.id }?.kind == .original)
        try rewriteSameSize(f.dup.fullPath, seed: 99)
        let out = await apply(f, selected: [f.dup.id])
        #expect(out.trashed == 0 && out.held.count == 1, "\(out)")
        #expect(out.held.first?.hasSuffix("not the same bytes as the archive copy") == true, "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath), "the only copy of the new bytes stays")
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval }, "nothing approved")
    }

    // MARK: Codex follow-up review of 90a54fb0 (2026-09-20) — findings #1, #2, #3, #6

    @Test("PROMOTE binds the source's stat stamp (ctime included) to the promote digest on the SOURCE record; an original without that stamp is read in full")
    func promoteStampsTheSourceAndAnUnstampedOriginalIsRead() async throws {
        let f = try await fixture("prune_promote_stamp"); defer { f.sb.cleanup() }
        let original = try #require(f.model.record(forID: f.dup.id))
        try #require(f.family.rows.first { $0.id == original.id }?.kind == .original)
        let own = try #require(original.contentFixity, "Promote wrote the source's promotion-time fixity")
        #expect(own.digest == f.archive.archiveFixity?.digest && own.byteCount == original.sizeBytes)
        #expect(own.stamp.hasChangeTime && own.isUsableForVerification && own.stampMatches(path: original.fullPath), "\(own)")
        #expect(own.describesFileNow(FileIdentityStamp.capture(path: original.fullPath)), "the stamp reproduces to the ctime")
        // An older catalog (or an adoption) carries no promotion stamp: the
        // original is read in full like any duplicate, not trusted.
        original.contentFixity = nil
        let out = await apply(f, selected: [original.id])
        #expect(out.trashed == 1 && out.verified == 1 && out.held.isEmpty, "read in full, identical, gone — \(out)")
        #expect(!FileManager.default.fileExists(atPath: original.fullPath))
    }

    @Test("CODEX #1: an archive AUDIT after the original was edited must not make the edited original look safe — it is read, found different, and held")
    func anArchiveAuditNeverVouchesForAnEditedOriginal() async throws {
        let f = try await fixture("prune_codex1"); defer { f.sb.cleanup() }
        let original = try #require(f.model.record(forID: f.dup.id))
        try #require(f.family.rows.first { $0.id == original.id }?.kind == .original)
        // 1. Edit the source to different bytes of the same length.
        try rewriteSameSize(original.fullPath, seed: 101)
        // 2. Audit the ARCHIVE copy (Verify Archive Copies' write): the
        //    archive's verifiedAt now postdates the source's edit — the
        //    exact date the old shortcut compared the source against.
        let digest = try #require(f.archive.archiveFixity?.digest)
        let write = f.model.restoreArchiveFixity(path: f.archivePath, observedDigest: digest, digest: digest,
                                                 sizeBytes: f.archive.sizeBytes, verifiedAt: Date(),
                                                 stampBeforeRead: FileIdentityStamp.capture(path: f.archivePath))
        try #require(write == .written && f.archive.contentFixity != nil, "fixture: the audit refreshed the archive's fixity + stamp")
        let edited = try #require(FileIdentityStamp.capture(path: original.fullPath))
        let auditNs = Int64((f.archive.archiveFixity?.verifiedAt.timeIntervalSince1970 ?? 0) * 1_000_000_000)
        try #require(edited.mtimeNs <= auditNs && edited.ctimeNs <= auditNs, "fixture: codex's timeline — the edit precedes the audit")
        let out = await apply(f, selected: [original.id])
        #expect(out.trashed == 0 && out.held.count == 1, "the edited original must never pass unread — \(out)")
        #expect(out.held.first?.hasSuffix("not the same bytes as the archive copy") == true, "\(out.held)")
        #expect(out.archiveReads == 0, "the audited archive copy stood on its stamp — \(out)")
        #expect(FileManager.default.fileExists(atPath: original.fullPath), "the only copy of the edited bytes stays")
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval }, "nothing approved")
    }

    @Test("CODEX #2: the archive copy rewritten to the same size after promotion authorises NOTHING — every copy (a duplicate, the original, a version) is held 'archive copy changed'")
    func aSameSizeArchiveRewriteHoldsEveryCopy() async throws {
        let f = try await fixture("prune_codex2", attested: false, withVersion: true); defer { f.sb.cleanup() }
        let version = try #require(f.version)
        try rewriteSameSize(f.archivePath, seed: 202)
        try #require(f.archive.archiveFixity != nil, "fixture: the catalog still says fixity-verified — only the bytes lie")
        let all: Set<UUID> = [f.dup.id, f.keeper.id, version.id]
        let out = await apply(f, selected: all)
        #expect(out.trashed == 0 && out.held.count == 3, "\(out)")
        #expect(out.held.allSatisfy { $0.contains("archive copy changed") }, "\(out.held)")
        #expect(out.archiveReads == 0 && f.archive.contentFixity == nil, "a mismatching read stores nothing")
        for p in [f.dup.fullPath, f.keeper.fullPath, version.fullPath] {
            #expect(FileManager.default.fileExists(atPath: p), "\(p) stays")
        }
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval }, "nothing approved")
        // A stamp stored by an earlier audit does not survive the rewrite
        // either: the stamp no longer reproduces, the re-read mismatches.
        let f2 = try await fixture("prune_codex2_stamped"); defer { f2.sb.cleanup() }
        let d = try #require(f2.archive.archiveFixity?.digest)
        _ = f2.model.restoreArchiveFixity(path: f2.archivePath, observedDigest: d, digest: d, sizeBytes: f2.archive.sizeBytes,
                                          stampBeforeRead: FileIdentityStamp.capture(path: f2.archivePath))
        try #require(f2.archive.contentFixity?.describesFileNow(FileIdentityStamp.capture(path: f2.archivePath)) == true)
        try rewriteSameSize(f2.archivePath, seed: 203)
        let out2 = await apply(f2, selected: [f2.dup.id])
        #expect(out2.trashed == 0 && out2.held.first?.contains("archive copy changed") == true, "\(out2)")
        #expect(FileManager.default.fileExists(atPath: f2.dup.fullPath))
    }

    @Test("CODEX #3a: target A rewritten between its verdict and the mutation is held by the re-stat immediately before its Trash; B still goes")
    func aTargetRewrittenAfterItsVerdictIsHeldAtTheMutation() async throws {
        let f = try await fixture("prune_codex3a"); defer { f.sb.cleanup() }
        let a = f.dup, b = f.keeper
        let aPath = a.fullPath
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { path in
            guard path == aPath else { return }
            try? MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: aPath), bytes: 40 * 1024, seed: 303)
        }
        let out = await apply(f, selected: [a.id, b.id], hooks: hooks)
        #expect(out.trashed == 1 && out.held.count == 1, "\(out)")
        #expect(out.held.first?.hasPrefix(a.filename) == true && out.held.first?.contains("changed on disk since it was verified") == true, "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: aPath), "the new bytes at A's path survive")
        #expect(!FileManager.default.fileExists(atPath: b.fullPath), "B's proof still held — it went")
        #expect(f.model.record(forID: a.id)?.purgedAt == nil, "A's row stays active")
        #expect(f.model.record(forID: b.id)?.purgedAt != nil)
        await f.model.mediaLedger.waitForPendingWrites()
        let removed = f.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(removed.map(\.recordID) == [b.id], "one removal line, for B only — \(removed.map(\.filename))")
    }

    @Test("CODEX #3b: the pipeline is PER FILE — A is verified and moved before B is touched, so nothing verified earlier waits on B's read; and the archive copy rewritten WHILE B is read holds B, named")
    func thePipelineIsPerFileAndAnArchiveRewriteDuringAReadHoldsIt() async throws {
        let f = try await fixture("prune_codex3b"); defer { f.sb.cleanup() }
        let a = f.dup, b = f.keeper
        try #require(f.family.rows.first { $0.id == a.id }?.kind == .original && f.family.rows.first { $0.id == b.id }?.kind == .duplicate)
        let aPath = a.fullPath, bPath = b.fullPath, archivePath = f.archivePath
        let once = OpenCounter()
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.didOpen = { path in
            // The first time B is opened for its full read: A is already
            // gone (per-file), and the ARCHIVE copy changes under the read.
            guard path == bPath, once.opens(of: bPath) == 0 else { return }
            once.add(bPath)
            once.add(FileManager.default.fileExists(atPath: aPath) ? "a-still-there" : "a-gone")
            let size = Int((try? FileManager.default.attributesOfItem(atPath: archivePath))?[.size] as? Int64 ?? 0)
            try? MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: archivePath), bytes: size, seed: 304)
        }
        let out = await apply(f, selected: [a.id, b.id], hooks: hooks)
        #expect(once.opens(of: bPath) == 1 && once.opens(of: "a-gone") == 1, "fixture: A had already moved when B's read began — \(once.all)")
        #expect(out.trashed == 1 && out.held.count == 1 && out.held.first?.hasPrefix(b.filename) == true, "\(out)")
        #expect(out.held.first?.contains("changed while it was being checked against the archive copy") == true, "\(out.held)")
        #expect(!FileManager.default.fileExists(atPath: aPath) && FileManager.default.fileExists(atPath: bPath))
        #expect(f.model.record(forID: b.id)?.purgedAt == nil)
    }

    @Test("CODEX #3c: the archive copy removed after the batch was verified holds every remaining copy at the mutation")
    func anArchiveRemovedBeforeTheMutationHoldsTheRest() async throws {
        let f = try await fixture("prune_codex3c"); defer { f.sb.cleanup() }
        let archivePath = f.archivePath, aPath = f.dup.fullPath
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { path in
            guard path == aPath else { return }
            try? FileManager.default.removeItem(atPath: archivePath)
        }
        let out = await apply(f, selected: [f.dup.id, f.keeper.id], hooks: hooks)
        #expect(out.trashed == 0 && out.held.count == 2, "\(out)")
        // A: the guard's re-stat of the archive copy the instant before its move. B: no archive copy to read against.
        #expect(out.held[0].hasPrefix(f.dup.filename) && out.held[0].contains("archive copy is no longer on disk"), "\(out.held)")
        #expect(out.held[1].hasPrefix(f.keeper.filename) && out.held[1].contains("could not be read in full"), "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath) && FileManager.default.fileExists(atPath: f.keeper.fullPath))
        #expect(f.model.record(forID: f.dup.id)?.purgedAt == nil && f.model.record(forID: f.keeper.id)?.purgedAt == nil)
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .copyDeleted })
    }

    @Test("CODEX #3d: the live catalog is re-checked on the main actor before the hop — a row moved (or its archive copy unverified) since its verdict is held")
    func aCatalogChangeAfterTheVerdictIsHeld() async throws {
        let f = try await fixture("prune_codex3d"); defer { f.sb.cleanup() }
        let moved = f.sb.sources.appendingPathComponent("elsewhere.mov").path
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { _ in f.model.record(forID: f.dup.id)?.fullPath = moved }
        let out = await apply(f, selected: [f.dup.id], hooks: hooks)
        #expect(out.trashed == 0 && out.held.count == 1 && out.held.first?.contains("moved in the catalog") == true, "\(out)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath), "the file at the verified path is untouched")
        #expect(f.model.record(forID: f.dup.id)?.purgedAt == nil)
        // And the archive side: its fixity withdrawn (an audit's mismatch) between verdict and mutation.
        f.model.record(forID: f.dup.id)?.fullPath = f.dup.fullPath
        var hooks2 = VideoScanModel.PruneVerifyHooks.live
        hooks2.beforeMutation = { _ in f.archive.archiveFixity = nil }
        let out2 = await apply(f, selected: [f.dup.id], hooks: hooks2)
        #expect(out2.trashed == 0 && out2.held.first?.contains("archive copy lost or changed its fixity") == true, "\(out2)")
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath))
    }

    @Test("CODEX #6: three duplicates of one archive copy with no stamp yet — the archive copy is OPENED once, each duplicate once")
    func threeDuplicatesReadTheArchiveCopyOnce() async throws {
        let f = try await fixture("prune_codex6", extraCopies: 2); defer { f.sb.cleanup() }
        let original = try #require(f.family.rows.first { $0.kind == .original }?.id)
        let dups = f.family.rows.filter { $0.kind == .duplicate }
        try #require(dups.count == 3 && f.archive.contentFixity == nil, "fixture: three duplicates, uncached archive copy")
        let opens = OpenCounter()
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.didOpen = { opens.add($0) }
        let out = await apply(f, selected: Set(dups.map(\.id)), hooks: hooks)
        #expect(out.trashed == 3 && out.verified == 3 && out.archiveReads == 1 && out.held.isEmpty, "\(out)")
        #expect(opens.opens(of: f.archivePath) == 1, "the archive copy was opened \(opens.opens(of: f.archivePath))× — \(opens.all)")
        for d in dups {
            #expect(opens.opens(of: d.copy.fullPath) == 1, "\(d.copy.filename) opened \(opens.opens(of: d.copy.fullPath))×")
            #expect(!FileManager.default.fileExists(atPath: d.copy.fullPath))
        }
        #expect(FileManager.default.fileExists(atPath: f.archivePath) && f.model.record(forID: original)?.purgedAt == nil)
        #expect(f.archive.contentFixity != nil, "the fresh evidence was stored")
        // The next batch stats instead of reading: zero archive opens.
        let g = try await fixture("prune_codex6_next", extraCopies: 1); defer { g.sb.cleanup() }
        let gd = g.family.rows.filter { $0.kind == .duplicate }
        let first = await g.model.applyPrune(shown: g.shown, selected: [gd[0].id], recordIDs: g.ids, options: .init(),
                                             batchID: "b1", mode: .permanent)
        try #require(first.archiveReads == 1 && g.archive.contentFixity != nil)
        let again = await g.model.prunePlan(for: g.ids, options: .init(), isOnline: { _ in true })
        let opens2 = OpenCounter()
        var hooks2 = VideoScanModel.PruneVerifyHooks.live
        hooks2.didOpen = { opens2.add($0) }
        let second = await g.model.applyPrune(shown: again, selected: [gd[1].id], recordIDs: g.ids, options: .init(),
                                              batchID: "b2", mode: .permanent, hooks: hooks2)
        #expect(second.trashed == 1 && second.archiveReads == 0, "\(second)")
        #expect(opens2.opens(of: g.archivePath) == 0, "stamped — never re-read: \(opens2.all)")
    }

    // MARK: The job (Rick 2026-09-20: "the app blocks when post-promote delete of big files")

    /// A box so a hook can reach the job it runs inside.
    final class JobBox: @unchecked Sendable { var job: PruneApplyJob? }

    private func runJob(_ f: Fixture, selected: Set<UUID>,
                        hooks: VideoScanModel.PruneVerifyHooks = .live) async -> PruneApplyJob {
        let job = PruneApplyJob(model: f.model, shown: f.shown, selected: selected, recordIDs: f.ids,
                                options: .init(), batchID: "test-job", mode: .permanent, hooks: hooks)
        job.start()
        await job.task?.value
        return job
    }

    /// Poll (bounded) until `condition` holds on the main actor.
    private func eventually(_ what: String, timeoutMs: Int = 4_000, _ condition: () -> Bool) async throws {
        var waited = 0
        while !condition() {
            try #require(waited < timeoutMs, "timed out waiting for: \(what)")
            try await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
    }

    @Test("JOB: runs the same pipeline as applyPrune — every checked copy verified then moved, one row per copy, the approval written ONCE with the actual counts")
    func theJobRunsThePipelineAndWritesTheApprovalOnce() async throws {
        let f = try await fixture("prune_job", extraCopies: 1); defer { f.sb.cleanup() }
        let all = Set(f.family.rows.filter(\.checkable).map(\.id))
        try #require(all.count == 3)
        let job = await runJob(f, selected: all)
        #expect(job.state == .finished(summary: job.outcome.summary) && job.finishedAt != nil, "\(job.state)")
        #expect(job.title == "Move 3 copies to the Trash")
        #expect(job.outcome.trashed == 3 && job.outcome.held.isEmpty && job.outcome.failed.isEmpty, "\(job.outcome)")
        #expect(job.outcome.verified == 2 && job.outcome.archiveReads == 1, "two duplicates read, the original on its stamp, the archive once — \(job.outcome)")
        #expect(job.rows.count == 3 && job.rows.allSatisfy { $0.status == .trashed }, "\(job.rows)")
        #expect(job.progress.settled == 3 && job.progress.trashed == 3 && job.fraction == 1)
        #expect(job.subtitle.hasPrefix("Moved 3 copies to the Trash"), "\(job.subtitle)")
        for id in all { #expect(f.model.record(forID: id)?.purgedAt != nil) }
        #expect(FileManager.default.fileExists(atPath: f.archivePath))
        await f.model.mediaLedger.waitForPendingWrites()
        let approvals = f.model.mediaLedger.allEvents().filter { $0.event == .approval }
        #expect(approvals.count == 1 && approvals.first?.detail[MediaLedgerEvent.Detail.count] == "3", "\(approvals.map(\.detail))")
        #expect(approvals.first?.batchID == "test-job")
        #expect(f.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }.count == 3)
    }

    @Test("JOB: held copies are named in the rows (state + reason) and in the log; no approval when nothing moved")
    func theJobSurfacesHeldReasons() async throws {
        let f = try await fixture("prune_job_held", attested: false, withVersion: true); defer { f.sb.cleanup() }
        let version = try #require(f.version)
        try rewriteSameSize(f.archivePath, seed: 505)
        let job = await runJob(f, selected: [f.dup.id, f.keeper.id, version.id])
        #expect(job.state == .finished(summary: job.outcome.summary), "held is not a failure of the job — \(job.state)")
        #expect(job.outcome.trashed == 0 && job.outcome.held.count == 3, "\(job.outcome)")
        #expect(job.rows.count == 3 && job.rows.allSatisfy { $0.status == .held && $0.note.contains("archive copy changed") }, "\(job.rows)")
        #expect(job.subtitle.contains("3 held back"), "\(job.subtitle)")
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval })
        // And a copy the fresh plan holds before any byte is read is a row too.
        let g = try await fixture("prune_job_held_plan"); defer { g.sb.cleanup() }
        g.model.record(forID: g.dup.id)?.userNotes = "added since"
        let job2 = await runJob(g, selected: [g.dup.id])
        #expect(job2.rows.count == 1 && job2.rows[0].status == .held && job2.rows[0].note.contains("has your note"), "\(job2.rows)")
        #expect(FileManager.default.fileExists(atPath: g.dup.fullPath))
    }

    @Test("JOB: Pause takes effect between files — the file in flight finishes, the next waits; Resume carries on")
    func theJobPausesBetweenFiles() async throws {
        let f = try await fixture("prune_job_pause", extraCopies: 1); defer { f.sb.cleanup() }
        let dups = f.family.rows.filter { $0.kind == .duplicate }.map(\.copy)
        try #require(dups.count == 2)
        let first = dups[0], second = dups[1]
        let box = JobBox()
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { path in if path == first.fullPath { box.job?.pause() } }
        let job = PruneApplyJob(model: f.model, shown: f.shown, selected: [first.id, second.id], recordIDs: f.ids,
                                options: .init(), batchID: "test-pause", mode: .permanent, hooks: hooks)
        box.job = job
        job.start()
        try await eventually("the first file moved and the job paused before the second") {
            job.isPaused && job.rows.first { $0.id == first.id }?.status == .trashed
                && job.rows.first { $0.id == second.id }?.status == .pending
        }
        #expect(job.subtitle.contains("paused") && job.subtitle.hasPrefix("verified 1 of 2"), "\(job.subtitle)")
        #expect(FileManager.default.fileExists(atPath: second.fullPath), "the second file waits")
        job.resume()
        await job.task?.value
        #expect(job.state == .finished(summary: job.outcome.summary) && job.outcome.trashed == 2, "\(job.outcome)")
        #expect(!FileManager.default.fileExists(atPath: second.fullPath))
    }

    @Test("JOB: Stop between a verdict and its move leaves that file and the rest; done stays done; no approval for nothing; Quit is the same Stop")
    func theJobStopsBetweenFiles() async throws {
        let f = try await fixture("prune_job_stop", extraCopies: 1); defer { f.sb.cleanup() }
        let dups = f.family.rows.filter { $0.kind == .duplicate }.map(\.copy)
        let first = dups[0], second = dups[1]
        let box = JobBox()
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { path in if path == first.fullPath { box.job?.stopForQuit() } }
        let job = PruneApplyJob(model: f.model, shown: f.shown, selected: [first.id, second.id], recordIDs: f.ids,
                                options: .init(), batchID: "test-stop", mode: .permanent, hooks: hooks)
        box.job = job
        job.start()
        await job.task?.value
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(job.subtitle.hasPrefix("Stopped — 0 moved to Trash"), "\(job.subtitle)")
        #expect(job.rows.first { $0.id == first.id }?.status == .held && job.rows.first { $0.id == first.id }?.note == "stopped before it was moved", "\(job.rows)")
        #expect(job.rows.first { $0.id == second.id }?.status == .stopped, "\(job.rows)")
        #expect(FileManager.default.fileExists(atPath: first.fullPath) && FileManager.default.fileExists(atPath: second.fullPath))
        #expect(f.model.record(forID: first.id)?.purgedAt == nil && f.model.record(forID: second.id)?.purgedAt == nil)
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval || $0.event == .copyDeleted })
        // Done stays done: a Stop after the first file moved keeps it moved.
        let g = try await fixture("prune_job_stop2", extraCopies: 1); defer { g.sb.cleanup() }
        let gd = g.family.rows.filter { $0.kind == .duplicate }.map(\.copy)
        let box2 = JobBox()
        var hooks2 = VideoScanModel.PruneVerifyHooks.live
        hooks2.beforeMutation = { path in if path == gd[1].fullPath { box2.job?.cancel() } }
        let job2 = PruneApplyJob(model: g.model, shown: g.shown, selected: [gd[0].id, gd[1].id], recordIDs: g.ids,
                                 options: .init(), batchID: "test-stop2", mode: .permanent, hooks: hooks2)
        box2.job = job2
        job2.start()
        await job2.task?.value
        #expect(job2.state == .cancelled && job2.outcome.trashed == 1, "\(job2.outcome)")
        #expect(!FileManager.default.fileExists(atPath: gd[0].fullPath) && FileManager.default.fileExists(atPath: gd[1].fullPath))
        await g.model.mediaLedger.waitForPendingWrites()
        let approvals = g.model.mediaLedger.allEvents().filter { $0.event == .approval }
        #expect(approvals.count == 1 && approvals.first?.detail[MediaLedgerEvent.Detail.count] == "1", "the approval says what actually went")
    }

    // MARK: The queue (Rick 2026-09-22: "blocked UI so you have to wait — goes against best practices for UI")

    /// Main-actor event trail for ordering assertions.
    @MainActor final class Trail { var events: [String] = [] }

    @Test("QUEUE: a second batch while one runs is QUEUED, not refused (the sheet closes); it waits untouched, then runs after the first settles; the chip is TRASH")
    func aSecondBatchQueuesAndRunsAfterTheFirst() async throws {
        let f = try await fixture("prune_q_first"); defer { f.sb.cleanup() }
        let g = try await fixture("prune_q_second"); defer { g.sb.cleanup() }
        let center = MediaFileOperationsCenter()
        let trail = Trail()
        let box = JobBox()
        let fDup = f.dup.fullPath, gDup = g.dup.fullPath
        var h1 = VideoScanModel.PruneVerifyHooks.live
        h1.beforeMutation = { path in
            trail.events.append("first:\(path == fDup)")
            // The first is at its move: the second is still waiting, unread, its file untouched.
            let waiting = box.job.map { $0.isQueued && $0.task == nil && $0.rows.isEmpty } ?? false
            trail.events.append("second-waiting:\(waiting && FileManager.default.fileExists(atPath: gDup))")
        }
        var h2 = VideoScanModel.PruneVerifyHooks.live
        h2.beforeMutation = { path in trail.events.append("second:\(path == gDup)") }
        let first = center.startPruneApply(shown: f.shown, selected: [f.dup.id], recordIDs: f.ids, options: .init(),
                                           batchID: "q1", model: f.model, mode: .permanent, hooks: h1)
        let second = center.startPruneApply(shown: g.shown, selected: [g.dup.id], recordIDs: g.ids, options: .init(),
                                            batchID: "q2", model: g.model, mode: .permanent, hooks: h2)
        box.job = second
        // What the sheet reads: not refused → it dismisses.
        #expect(!second.wasRefused && second.state.isActive && second.isQueued, "\(second.state)")
        #expect(second.task == nil, "a waiting batch has started nothing")
        #expect(second.subtitle == PruneApplyJob.waitingSubtitle(behind: first.title, ahead: 0), "\(second.subtitle)")
        #expect(!second.canPause && !second.isIndeterminate, "a waiting row is not a spinner and has nothing to pause")
        #expect(center.runningPruneApply === first && center.queuedPruneApplies.map(\.id) == [second.id])
        #expect(center.jobs.contains { $0.id == second.id }, "the waiting batch is a visible row")
        await first.task?.value
        try await eventually("the second starts once the first settles") { second.task != nil }
        await second.task?.value
        #expect(first.outcome.trashed == 1 && second.outcome.trashed == 1, "\(first.outcome) / \(second.outcome)")
        #expect(second.state == .finished(summary: second.outcome.summary), "\(second.state)")
        #expect(trail.events == ["first:true", "second-waiting:true", "second:true"], "strictly one after another: \(trail.events)")
        #expect(!FileManager.default.fileExists(atPath: fDup) && !FileManager.default.fileExists(atPath: gDup))
        #expect(!center.hasActivePruneApply && center.queuedPruneApplies.isEmpty)
        #expect(MediaFileOperationKind.pruneCopies.badgeText == "TRASH" && MediaFileOperationKind.pruneCopies.hasDetailView)
    }

    @Test("QUEUE OVERLAP: a copy checked in both batches is moved ONCE — the second skips it (named, never read, not counted); the rest of the second batch still goes")
    func anOverlappingCopyIsMovedOnce() async throws {
        let f = try await fixture("prune_q_overlap", extraCopies: 1); defer { f.sb.cleanup() }
        let others = f.family.rows.filter { $0.checkable && $0.id != f.keeper.id }.map(\.copy)
        try #require(others.count == 2)
        let d0 = others[0], d1 = others[1]
        let center = MediaFileOperationsCenter()
        let opens = OpenCounter()
        var h2 = VideoScanModel.PruneVerifyHooks.live
        h2.didOpen = { opens.add($0) }
        let first = center.startPruneApply(shown: f.shown, selected: [d0.id], recordIDs: f.ids, options: .init(),
                                           batchID: "ov1", model: f.model, mode: .permanent)
        let second = center.startPruneApply(shown: f.shown, selected: [d0.id, d1.id], recordIDs: f.ids, options: .init(),
                                            batchID: "ov2", model: f.model, mode: .permanent, hooks: h2)
        #expect(second.isQueued)
        await first.task?.value
        try await eventually("the second starts") { second.task != nil }
        await second.task?.value
        #expect(first.outcome.trashed == 1, "\(first.outcome)")
        #expect(second.movedEarlier == [d0.id], "handed over at its turn")
        #expect(second.outcome.trashed == 1 && second.outcome.movedByEarlierBatch == 1 && second.outcome.held.isEmpty,
                "\(second.outcome)")
        #expect(second.outcome.summary.contains("1 already moved by the batch before"), "\(second.outcome.summary)")
        let row0 = try #require(second.rows.first { $0.id == d0.id })
        #expect(row0.status == .movedEarlier && row0.note == PruneApplyJob.movedEarlierReason, "\(row0)")
        #expect(PruneApplyDetailView.chip(row0).label == "Already moved by the batch before")
        #expect(opens.opens(of: d0.fullPath) == 0, "never read: \(opens.all)")
        #expect(second.rows.first { $0.id == d1.id }?.status == .trashed)
        #expect(FileManager.default.fileExists(atPath: f.keeper.fullPath) && FileManager.default.fileExists(atPath: f.archivePath))
        await f.model.mediaLedger.waitForPendingWrites()
        let events = f.model.mediaLedger.allEvents()
        #expect(events.filter { $0.event == .copyDeleted }.count == 2, "two files, two deletions — never three")
        let approvals = events.filter { $0.event == .approval }
        #expect(approvals.map { $0.detail[MediaLedgerEvent.Detail.count] } == ["1", "1"], "each batch approves what IT moved: \(approvals.map(\.detail))")
    }

    @Test("QUEUE OVERLAP: a copy the second batch LEFT UNCHECKED (its keeper) was moved by the first → nothing in that family moves; it is never counted as a survivor")
    func aSurvivorMovedByTheBatchBeforeHoldsTheFamily() async throws {
        let f = try await fixture("prune_q_survivor", extraCopies: 1); defer { f.sb.cleanup() }
        let others = f.family.rows.filter { $0.checkable && $0.id != f.keeper.id }.map(\.copy)
        try #require(others.count == 2)
        let center = MediaFileOperationsCenter()
        // Batch 1 takes the keeper; batch 2 was confirmed with that keeper staying.
        let first = center.startPruneApply(shown: f.shown, selected: [f.keeper.id], recordIDs: f.ids, options: .init(),
                                           batchID: "sv1", model: f.model, mode: .permanent)
        let second = center.startPruneApply(shown: f.shown, selected: [others[0].id], recordIDs: f.ids, options: .init(),
                                            batchID: "sv2", model: f.model, mode: .permanent)
        await first.task?.value
        try await eventually("the second starts") { second.task != nil }
        await second.task?.value
        #expect(first.outcome.trashed == 1, "\(first.outcome)")
        #expect(second.outcome.trashed == 0 && second.outcome.held.count == 1, "\(second.outcome)")
        let row = try #require(second.rows.first { $0.id == others[0].id })
        #expect(row.status == .held && row.note.contains("left unchecked") && row.note.contains("batch before"), "\(row)")
        #expect(FileManager.default.fileExists(atPath: others[0].fullPath) && FileManager.default.fileExists(atPath: others[1].fullPath),
                "every copy the second batch was shown as staying — and its own check — is still there")
    }

    @Test("QUEUE RE-VERIFY: a waiting batch checks at ITS turn — its keeper vanished from disk while it waited → the copy is held, not moved")
    func aQueuedBatchReVerifiesAtItsTurn() async throws {
        let f = try await fixture("prune_q_reverify_other"); defer { f.sb.cleanup() }
        let g = try await fixture("prune_q_reverify"); defer { g.sb.cleanup() }
        let center = MediaFileOperationsCenter()
        let gKeeper = g.keeper.fullPath
        let aside = g.sb.root.appendingPathComponent("aside_keeper.mov").path
        var h1 = VideoScanModel.PruneVerifyHooks.live
        // Between g's enqueue and g's turn, g's keeper leaves the disk
        // (moved aside — nothing is deleted).
        h1.beforeMutation = { _ in try? FileManager.default.moveItem(atPath: gKeeper, toPath: aside) }
        let first = center.startPruneApply(shown: f.shown, selected: [f.dup.id], recordIDs: f.ids, options: .init(),
                                           batchID: "rv1", model: f.model, mode: .permanent, hooks: h1)
        let second = center.startPruneApply(shown: g.shown, selected: [g.dup.id], recordIDs: g.ids, options: .init(),
                                            batchID: "rv2", model: g.model, mode: .permanent)
        #expect(second.isQueued && FileManager.default.fileExists(atPath: gKeeper), "at enqueue the keeper was there")
        await first.task?.value
        try await eventually("the second starts") { second.task != nil }
        await second.task?.value
        #expect(!FileManager.default.fileExists(atPath: gKeeper) && FileManager.default.fileExists(atPath: aside))
        #expect(second.outcome.trashed == 0 && second.outcome.held.count == 1, "\(second.outcome)")
        #expect(second.rows.first { $0.id == g.dup.id }?.status == .held, "\(second.rows)")
        #expect(FileManager.default.fileExists(atPath: g.dup.fullPath), "refuse over guess: the copy stays")
        await g.model.mediaLedger.waitForPendingWrites()
        #expect(!g.model.mediaLedger.allEvents().contains { $0.event == .approval || $0.event == .copyDeleted })
    }

    @Test("QUEUE STOP: Stop on a waiting batch takes it out of the line — nothing started, row leaves the list; the next in line still runs after the first; Quit drops waiting batches too")
    func stoppingAWaitingBatchTakesItOutOfTheLine() async throws {
        let f = try await fixture("prune_q_stop_first"); defer { f.sb.cleanup() }
        let g = try await fixture("prune_q_stop_second", extraCopies: 1); defer { g.sb.cleanup() }
        let gd = g.family.rows.filter { $0.checkable && $0.id != g.keeper.id }.map(\.copy)
        try #require(gd.count == 2)
        let center = MediaFileOperationsCenter()
        let first = center.startPruneApply(shown: f.shown, selected: [f.dup.id], recordIDs: f.ids, options: .init(),
                                           batchID: "st1", model: f.model, mode: .permanent)
        let second = center.startPruneApply(shown: g.shown, selected: [gd[0].id], recordIDs: g.ids, options: .init(),
                                            batchID: "st2", model: g.model, mode: .permanent)
        let third = center.startPruneApply(shown: g.shown, selected: [gd[1].id], recordIDs: g.ids, options: .init(),
                                           batchID: "st3", model: g.model, mode: .permanent)
        #expect(center.queuedPruneApplies.map(\.id) == [second.id, third.id], "FIFO")
        #expect(third.subtitle.hasSuffix("and 1 more waiting batch"), "\(third.subtitle)")
        second.cancel()
        #expect(second.state == .cancelled && second.droppedWhileQueued && second.task == nil, "\(second.state)")
        #expect(center.runningPruneApply === first, "the running batch is not disturbed")
        #expect(third.subtitle == PruneApplyJob.waitingSubtitle(behind: first.title, ahead: 0), "the line moved up: \(third.subtitle)")
        try await eventually("the dropped row leaves the list") { !center.jobs.contains { $0.id == second.id } }
        await first.task?.value
        try await eventually("the third starts") { third.task != nil }
        await third.task?.value
        #expect(second.task == nil, "a dropped batch never starts")
        #expect(FileManager.default.fileExists(atPath: gd[0].fullPath), "the dropped batch's copy is untouched")
        #expect(third.outcome.trashed == 1 && !FileManager.default.fileExists(atPath: gd[1].fullPath), "\(third.outcome)")

        // Quit: the waiting batch is dropped at once; the running one stops and settles.
        let h = try await fixture("prune_q_quit", extraCopies: 1); defer { h.sb.cleanup() }
        let hd = h.family.rows.filter { $0.checkable && $0.id != h.keeper.id }.map(\.copy)
        let running = center.startPruneApply(shown: h.shown, selected: [hd[0].id], recordIDs: h.ids, options: .init(),
                                             batchID: "qt1", model: h.model, mode: .permanent)
        let waiting = center.startPruneApply(shown: h.shown, selected: [hd[1].id], recordIDs: h.ids, options: .init(),
                                             batchID: "qt2", model: h.model, mode: .permanent)
        #expect(waiting.isQueued)
        center.stopAllForQuit()
        #expect(waiting.state == .cancelled && waiting.task == nil, "\(waiting.state)")
        let settled = await center.waitForPruneApplyToSettle(deadline: 10)
        #expect(settled && !running.state.isActive && !center.hasActivePruneApply, "\(running.state)")
        #expect(waiting.task == nil && FileManager.default.fileExists(atPath: hd[1].fullPath), "quit never starts a waiting batch")
    }

    @Test("QUEUE LOG LINES: queued / started / taken out of the line each carry the file count and bytes")
    func theQueueLogLinesCarryCountAndBytes() {
        let q = PruneApplyJob.queuedLine(title: "Move 1 copy to the Trash", count: 1, bytes: 6_000_000_000,
                                         behind: "Move 2 copies to the Trash")
        #expect(q.hasPrefix("trash copies queued: Move 1 copy to the Trash — 1 copy, ") && q.contains("waits for Move 2 copies to the Trash"), "\(q)")
        #expect(q.contains(MediaBytes.display(6_000_000_000)), "\(q)")
        let s0 = PruneApplyJob.startPlan(count: 2, bytes: 83_000_000_000, waitedSeconds: nil)
        #expect(s0.hasPrefix("2 copies, \(MediaBytes.display(83_000_000_000)) — verify each copy") && !s0.contains("waited"), "\(s0)")
        let s1 = PruneApplyJob.startPlan(count: 1, bytes: 1_000, waitedSeconds: 125.4)
        #expect(s1.contains("(waited 125 s in line; every copy is checked now, at its turn)"), "\(s1)")
        let d = PruneApplyJob.droppedLine(title: "Move 3 copies to the Trash", count: 3, bytes: 3_000, forQuit: true)
        #expect(d.hasPrefix("trash copies taken out of the line (quit): Move 3 copies to the Trash — 3 copies, ") && d.hasSuffix("nothing was started, nothing to put back"), "\(d)")
        #expect(PruneApplyJob.waitingSubtitle(behind: "Move 2 copies to the Trash", ahead: 2)
                == "Waiting — starts after Move 2 copies to the Trash and 2 more waiting batches")
    }

    @Test("rule 7, table: moved-earlier checks leave go/held; a gone / missing / offline unchecked copy holds its family's checks; unchanged → nothing changes")
    func theOverlapRuleTable() async throws {
        let f = try await fixture("prune_q_rule7", extraCopies: 1); defer { f.sb.cleanup() }
        let others = f.family.rows.filter { $0.checkable && $0.id != f.keeper.id }.map(\.copy)
        try #require(others.count == 2)
        let d0 = others[0], d1 = others[1]
        let keeperPath = f.keeper.fullPath, keeperID = f.keeper.id
        func run(fresh: PrunePlan, selected: Set<UUID>, moved: Set<UUID> = []) -> (go: [UUID], held: [String], already: [UUID]) {
            let t = VideoScanModel.pruneTargets(shown: f.shown, selected: selected, fresh: fresh)
            let r = VideoScanModel.pruneOverlap(shown: f.shown, selected: selected, fresh: fresh,
                                                go: t.go, held: t.held, movedEarlier: moved)
            return (r.go.map(\.id), r.held.map(\.reason), r.movedEarlier.map(\.id))
        }
        // Control: nothing changed → the checks go, nothing held.
        let same = run(fresh: f.shown, selected: [d0.id])
        #expect(same.go == [d0.id] && same.held.isEmpty && same.already.isEmpty, "\(same)")
        // A: a check the batch before moved is skipped, not held, not gone-through.
        let a = run(fresh: f.shown, selected: [d0.id, d1.id], moved: [d0.id])
        #expect(a.go == [d1.id] && a.held.isEmpty && a.already == [d0.id], "\(a)")
        // B: the unchecked keeper went missing / offline since the list → every check in the family held.
        let missing = await f.model.prunePlan(for: f.ids, options: .init(), isOnline: { _ in true },
                                              fileExists: { $0 != keeperPath })
        let m = run(fresh: missing, selected: [d0.id])
        #expect(m.go.isEmpty && m.held.count == 1 && m.held[0].contains("is no longer on disk") && m.held[0].contains("left unchecked"), "\(m)")
        let offline = await f.model.prunePlan(for: f.ids, options: .init(), isOnline: { $0.id != keeperID })
        let o = run(fresh: offline, selected: [d0.id])
        #expect(o.go.isEmpty && o.held.count == 1 && o.held[0].contains("no longer connected"), "\(o)")
        // …and a CHECKED copy going missing is not rule 7's business (the verdict names it).
        let checkedMissing = await f.model.prunePlan(for: f.ids, options: .init(), isOnline: { _ in true },
                                                     fileExists: { $0 != d0.fullPath })
        let c = run(fresh: checkedMissing, selected: [d0.id])
        #expect(!c.held.contains { $0.contains("left unchecked") }, "\(c)")
    }

    @Test("the job's subtitle: bytes-based progress, counts that exist, the time left")
    func theProgressSubtitle() {
        var p = PruneApplyProgress()
        p.total = 12; p.totalBytes = 12_000_000_000
        #expect(p.subtitle() == "verified 0 of 12" && p.fraction == 0)
        p.settle(bytes: 1_000_000_000, seconds: 30, result: .trashed(bytes: 1_000_000_000))
        p.settle(bytes: 1_000_000_000, seconds: 30, result: .trashed(bytes: 1_000_000_000))
        p.settle(bytes: 1_000_000_000, seconds: 20, result: .held("changed"))
        #expect(p.subtitle() == "verified 3 of 12 · 2 moved to Trash · 1 held · about 4 min left", "\(p.subtitle())")
        #expect(p.subtitle(paused: true) == "verified 3 of 12 · 2 moved to Trash · 1 held · paused")
        #expect(p.subtitle(stopping: true).hasSuffix("stopping after this file"))
        #expect(abs(p.fraction - 0.25) < 0.001)
        p.settle(bytes: 9_000_000_000, seconds: 1, result: .failed("locked"))
        #expect(p.subtitle() == "verified 4 of 12 · 2 moved to Trash · 1 held · 1 failed" && p.fraction == 1)
    }

    @Test("the Trash routine's guard: a refusal from either callback leaves the file and the row untouched, and is reported in `refused`")
    func theJunkDeletionGuardRefusesWithoutTouchingAnything() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune_guard"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_guard.mov"), bytes: 1024, seed: 5)
        let rec = MasterArchiveTestSupport.makeRecord(path: file.path)
        model.records = [rec]
        let offDisk = await model.deleteConfirmedJunk([rec], mode: .permanent,
                                                      guard: .init(authorize: { _ in nil }, beforeRemoval: { _ in "the proof no longer holds" }))
        #expect(offDisk.succeeded == 0 && offDisk.alreadyMissing == 0 && offDisk.refused.count == 1 && offDisk.refused[0].reason == "the proof no longer holds")
        #expect(FileManager.default.fileExists(atPath: file.path) && rec.purgedAt == nil && rec.lifecycleStage != .deletedPermanently)
        let inCatalog = await model.deleteConfirmedJunk([rec], mode: .permanent,
                                                        guard: .init(authorize: { _ in "not what was verified" }, beforeRemoval: { _ in nil }))
        #expect(inCatalog.refused.count == 1 && inCatalog.refused[0].reason == "not what was verified" && inCatalog.succeeded == 0)
        #expect(FileManager.default.fileExists(atPath: file.path) && rec.purgedAt == nil)
        // A guarded file that VANISHED is refused, never "already gone".
        try FileManager.default.removeItem(at: file)
        let gone = await model.deleteConfirmedJunk([rec], mode: .permanent,
                                                   guard: .init(authorize: { _ in nil }, beforeRemoval: { _ in "is not on disk" }))
        #expect(gone.refused.count == 1 && gone.alreadyMissing == 0 && rec.purgedAt == nil)
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.allEvents().isEmpty, "nothing left the disk through the routine — no ledger line")
        // No guard → the routine's own semantics are unchanged.
        let plain = await model.deleteConfirmedJunk([rec], mode: .permanent)
        #expect(plain.alreadyMissing == 1 && plain.refused.isEmpty && rec.purgedAt != nil)
    }

    // MARK: QA RED (2026-09-20) — a segmented-hash MATCH is a candidate, not proof

    @Test("QA RED: a 'might be copy' whose bytes differ outside the three sampled windows hashes equal, joins as a duplicate, and Apply trashes it with no full-byte verification (SignatureVerification.swift:19-20: segmented equal ⇒ CANDIDATE only)")
    func aSegmentedHashCollisionIsNeverTrashedAsACopy() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune_hash_collision"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        // > 3 MiB so segmentedHash SAMPLES (head / middle / tail, 1 MiB each) instead of reading in full.
        let size = 4 * FileHasher.segmentSize
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_prune_hc.mov"), bytes: size, seed: 31)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1992")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA))
        try #require(archive.archiveFixity != nil, "fixture: the archive copy is fixity-verified")
        let dir = sb.sources.appendingPathComponent("M4drive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let same = dir.appendingPathComponent("test_prune_hc copy.mov")
        try FileManager.default.copyItem(at: a, to: same)
        // Flip one byte at 1.25 MiB: past the head window, before the middle one (starts at 1.5 MiB).
        let fh = try FileHandle(forUpdating: same)
        let offset = UInt64(FileHasher.segmentSize + FileHasher.segmentSize / 4)
        try fh.seek(toOffset: offset)
        let orig = try #require(fh.read(upToCount: 1)?.first)
        try fh.seek(toOffset: offset)
        try fh.write(contentsOf: Data([orig ^ 0xFF]))
        try fh.close()
        try #require(!FileManager.default.contentsEqual(atPath: a.path, andPath: same.path), "fixture: the bytes DIFFER")
        let recSame = MasterArchiveTestSupport.makeRecord(path: same.path, userDate: "1992")
        for r in [recA, archive, recSame] { r.contentHash = "" }
        model.records += [recSame]
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)

        let before = await model.prunePlan(for: [recA.id], options: .init(bar: bar), isOnline: { _ in true })
        try #require(before.families.count == 1 && before.families[0].related.map(\.id) == [recSame.id])
        _ = await model.hashToConfirm(recordIDs: [recSame.id, recA.id, archive.id])
        try #require(!recA.contentHash.isEmpty && recA.contentHash == recSame.contentHash,
                     "fixture: the segmented hashes COLLIDE — that is exactly why the segmented hash is only a candidate")

        let shown = await model.prunePlan(for: [recA.id], options: .init(bar: bar), isOnline: { _ in true })
        let row = try #require(shown.families[0].rows.first { $0.id == recSame.id })
        // Pins PrunePlan.swift:162-209 (join by contentKey) → the hash match makes it a plain "duplicate".
        try #require(row.checkable && row.kind == .duplicate, "fixture: the collision joined as a normal candidate — \(row)")

        let out = await model.applyPrune(shown: shown, selected: [recSame.id], recordIDs: [recA.id],
                                         options: .init(bar: bar), batchID: "qa-collision", mode: .permanent)
        // Pins VideoScanModel+PruneApply.swift:190-205 (pruneDiskProblem: size only) and :309 (straight to deleteConfirmedJunk).
        #expect(out.trashed == 0, "a file whose bytes are NOT the archive copy's went to the Trash as a 'copy' — \(out)")
        #expect(FileManager.default.fileExists(atPath: same.path), "the only copy of those different bytes is gone")
        #expect(out.held.count == 1, "it should be held, named, with why — \(out.held)")
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
        #expect(!loud.contains("byte-for-byte"), "no duplicate checked → no verify sentence")
        let checked = S.confirmMessage(PrunePlan.Selection(count: 3, bytes: 1, overrideCount: 0, overrideShortfalls: [],
                                                           archiveOnlyFamilies: [], verifyCount: 2))
        #expect(checked.contains("2 copies will be checked byte-for-byte against the archive before they go."), "\(checked)")
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
        #expect(apply.contains("await deleteConfirmedJunk([rec], mode: mode, guard: fileGuard)"),
                "the ONE existing Trash routine, one file at a time — with the file's proof re-checked at the mutation (codex follow-up #3)")
        #expect(!apply.contains("trashItem("), "no file deletion of its own")
        #expect(!apply.contains("removeItem("), "no file deletion of its own")
        #expect(apply.contains("applyHumanMetadataInheritance(from: rec, to: archive)"), "the carry-over reuses the one set of rules")
        let verification = try source("VideoScanModel+PruneVerification.swift")
        #expect(!verification.contains("trashItem(") && !verification.contains("removeItem("), "verification moves nothing")
        #expect(verification.contains("SignatureVerification.verifyAgainstStoredKeeper("), "duplicates go through the one gate")
        #expect(!apply.contains("verifiedAt"), "codex #1: an archive audit's date never vouches for the source")
        let sheet = try source("ArchivedWhatNextSheet.swift")
        // (Since b58449ac the call sits inside `fileOpsCenter.startedByUser { $0.… }`
        // so the MFO window comes forward — same hand-off, new spelling.)
        #expect(sheet.contains("fileOpsCenter.startedByUser {") && sheet.contains(".startPruneApply(shown: shown, selected: selected"),
                "Apply hands the checklist to a Media File Operation (nothing long runs behind a modal)")
        #expect(!sheet.contains("model.applyPrune("), "the sheet never runs the pipeline itself")
        #expect(sheet.contains("dismiss()"), "and closes")
        #expect(!sheet.contains(".permanent"), "the sheet only ever moves to the Trash")
        let job = try source("PruneApplyJob.swift")
        #expect(!job.contains("trashItem(") && !job.contains("removeItem("), "the job moves nothing itself")
        #expect(job.contains("model.pruneOneCopy(item, batch: batch, mode: mode, hooks: jobHooks)"), "the job runs the one pipeline")
        #expect(!job.contains("refuseToStart(reason: \"An \\\"Archived") && !job.contains("is already going"),
                "Rick 2026-09-22: a second batch QUEUES — the center never refuses it (blocked UI)")
        #expect(job.contains("movedEarlier: movedEarlier)"), "the plan and every check happen at the batch's turn, with the hand-off")
        #expect(sheet.contains("minWidth: 960") && sheet.contains("minHeight: 720"), "Rick: a bigger dialog box")
    }

    @Test("QA MINOR: a held copy keeps its note — the carry to the archive copy happens only after the file has gone")
    func aHeldCopyKeepsItsMarks() async throws {
        let f = try await fixture("prune_qa_carry"); defer { f.sb.cleanup() }
        f.model.record(forID: f.dup.id)?.userNotes = "Grandpa's 80th — keep"
        let seen = await f.model.prunePlan(for: f.ids, options: .init(), isOnline: { _ in true })
        let dupPath = f.dup.fullPath
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { path in
            guard path == dupPath else { return }
            try? MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: dupPath), bytes: 40 * 1024, seed: 606)
        }
        let out = await f.model.applyPrune(shown: seen, selected: [f.dup.id], recordIDs: f.ids, options: .init(),
                                           batchID: "qa-carry", mode: .permanent, hooks: hooks)
        #expect(out.trashed == 0 && out.carried == 0 && out.held.count == 1, "\(out)")
        #expect(!f.archive.userNotes.contains("Grandpa"), "nothing carried for a held copy: \(f.archive.userNotes)")
        #expect(f.model.record(forID: f.dup.id)?.userNotes.contains("Grandpa") == true)
    }

    @Test("QA MINOR: the quit path can wait for a stopped batch to settle its file (purgedAt + ledger land before terminate)")
    func theCenterWaitsForAStoppedBatchToSettle() async throws {
        let f = try await fixture("prune_qa_settle", extraCopies: 1); defer { f.sb.cleanup() }
        let center = MediaFileOperationsCenter()
        let dups = f.family.rows.filter { $0.kind == .duplicate }.map(\.copy)
        let job = center.startPruneApply(shown: f.shown, selected: Set(dups.map(\.id)), recordIDs: f.ids,
                                         options: .init(), batchID: "qa-settle", model: f.model, mode: .permanent)
        #expect(center.hasActivePruneApply)
        center.stopAllForQuit()
        let settled = await center.waitForPruneApplyToSettle(deadline: 10)
        #expect(settled && !center.hasActivePruneApply && !job.state.isActive, "\(job.state)")
        await f.model.mediaLedger.waitForPendingWrites()
        let deleted = f.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        // Whatever moved before the Stop is fully recorded; nothing is half-done.
        for id in dups.map(\.id) {
            let gone = !FileManager.default.fileExists(atPath: f.model.record(forID: id)!.fullPath)
            #expect(gone == (f.model.record(forID: id)?.purgedAt != nil), "disk and catalog agree for \(id)")
            #expect(gone == deleted.contains { $0.recordID == id }, "ledger agrees for \(id)")
        }
    }

    // MARK: QA RED (2026-09-20, review of 476f82b9) — the guard re-authorizes the caller's object, not the live row

    @Test("QA RED: pruneProofProblemInCatalog judges the VideoRecord the caller handed in and never asks record(forID:) — a row rebuilt between verdict and mutation (same id, same path, new instance) is trashed and the LIVE row never learns (VideoScanModel+PruneVerification.swift:568-586)")
    func aRebuiltCatalogRowIsNotTheOneThatWasVerified() async throws {
        let f = try await fixture("prune_qa_stale_row"); defer { f.sb.cleanup() }
        let dupID = f.dup.id
        let model = f.model
        var hooks = VideoScanModel.PruneVerifyHooks.live
        hooks.beforeMutation = { path in
            // Between the verdict and the move the catalog rebuilds the row:
            // same id, same path, a NEW instance — what `records[i] = decoded`
            // (VideoScanModel.swift:31) and `records[existing] = newRec`
            // (TrimJob/CleanupJob/TranscodeJob…) do. Nothing on disk changes.
            guard path == f.dup.fullPath,
                  let i = model.records.firstIndex(where: { $0.id == dupID }) else { return }
            model.records[i] = model.records[i].snapshotClone()
        }
        let out = await apply(f, selected: [dupID], hooks: hooks)
        let live = try #require(model.record(forID: dupID), "the live row is the rebuilt one")
        let onDisk = FileManager.default.fileExists(atPath: f.dup.fullPath)
        #expect(!(onDisk == false && live.purgedAt == nil),
                "the file left the disk while the LIVE catalog row still says it is there — the guard authorized on the caller's stale object: \(out)")
        #expect(out.trashed == 0 && out.held.first?.contains("nothing moved") == true, "refused, named: \(out)")
    }
}
