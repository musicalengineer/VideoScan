// ArchiveAngelCodex1673Tests.swift
// codex #1673 (2026-09-23) — the residuals of #1665, from codex's probe
// (~/Library/Logs/VideoScan/review_backlog_20260923/output.txt, 4 FAILs):
//
//   P1-1  BOTH FRESH ≠ SAME BYTES. A promotion source rewritten and then
//         legitimately re-hashed is fresh again, as is its archive copy — but
//         their current digests differ. The archive link must not lend (via
//         the equivalence edge OR the archivePromotion ancestry hop), and the
//         source must not appear in sameBytes (backup attestations).
//   P1-2  EVERY lending edge needs both ends fresh. A rewritten balanceAudio
//         repair must not lend UP to its unchanged source; a rewritten tape
//         must not lend DOWN to its unchanged trim.
//
// Real files, real SHA-256, real stamps, the production stat pre-pass
// (ArchiveAngelFixityCheck.verify) — no freshness stubs.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — codex #1673: every lending edge needs fresh ends; the archive link needs equal bytes", .serialized)
@MainActor
struct ArchiveAngelCodex1673Tests {

    private func sandboxModel(_ label: String) throws -> (MasterArchiveTestSupport.Sandbox, VideoScanModel) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (sb, model)
    }

    /// A real file with a real captured ContentFixity.
    private func record(_ sb: MasterArchiveTestSupport.Sandbox, _ name: String, seed: UInt64,
                        dir: URL? = nil) throws -> VideoRecord {
        let d = dir ?? sb.sources
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = try MasterArchiveTestSupport.writeBlob(at: d.appendingPathComponent(name), bytes: 2048, seed: seed)
        let r = MasterArchiveTestSupport.makeRecord(path: url.path)
        r.durationSeconds = 600
        try AngelTestFixity.capture(r)
        return r
    }

    /// Same size, different bytes, new ctime — the stored fixity goes stale.
    private func rewriteInPlace(_ r: VideoRecord) throws {
        Thread.sleep(forTimeInterval: 0.01)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: r.fullPath))
        bytes[bytes.count / 2] ^= 0xFF
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: r.fullPath))
        try h.write(contentsOf: bytes)
        try h.close()
        #expect(r.contentFixity?.describesFileNow(FileIdentityStamp.capture(path: r.fullPath)) == false)
    }

    private func relatives(_ model: VideoScanModel, for target: VideoRecord) async
        -> (ArchiveAngelFamilyFacts.Relatives, Set<UUID>) {
        let index = ArchiveAngelCopyFamily.Index(active: model.records)
        let fresh = await ArchiveAngelFixityCheck.verify(targets: [target], index: index, catalog: model)
        return (ArchiveAngelFamilyFacts.relatives(of: target, index: index, catalog: model, fresh: fresh), fresh)
    }

    private let offsite = BackupAttestation(kind: .offsite, answer: .yes, attestedAt: Date(timeIntervalSince1970: 1_757_800_000))

    // MARK: P1-2 repair

    @Test("control: an unchanged balanceAudio repair lends its date to its unchanged source")
    func freshRepairLends() async throws {
        let (sb, model) = try sandboxModel("c1673_repair_ok"); defer { sb.cleanup() }
        let parent = try record(sb, "test_tape.mov", seed: 1)
        let repair = try record(sb, "test_tape_balanced.mov", seed: 2)
        repair.derivedFrom = parent.id; repair.derivationKind = BalanceAudioFix.derivationKind
        repair.userDate = "1987"; repair.userDateConfidence = "known"
        model.records = [parent, repair]
        let (r, fresh) = await relatives(model, for: parent)
        #expect(fresh == [parent.id, repair.id], "the pre-pass stats the repair endpoint")
        #expect(ArchiveAngelFamilyFacts.inherited(for: parent, relatives: r).date?.value == "1987")
        #expect(r.sameBytes.isEmpty, "a repair is different bytes — never an attestation donor")
    }

    @Test("RED P1-2: a balanceAudio repair rewritten since its fixity never lends UP to its source (codex probe)")
    func staleRepairDoesNotLend() async throws {
        let (sb, model) = try sandboxModel("c1673_repair_stale"); defer { sb.cleanup() }
        let parent = try record(sb, "test_tape.mov", seed: 1)
        let repair = try record(sb, "test_tape_balanced.mov", seed: 2)
        repair.derivedFrom = parent.id; repair.derivationKind = BalanceAudioFix.derivationKind
        try rewriteInPlace(repair)
        repair.userDate = "2002-10"; repair.userDateConfidence = "known"
        model.records = [parent, repair]
        let (r, fresh) = await relatives(model, for: parent)
        #expect(!fresh.contains(repair.id))
        let got = ArchiveAngelFamilyFacts.inherited(for: parent, relatives: r)
        #expect(got.date == nil, "a rewritten repair lent \(got.date?.value ?? "") (\(got.date?.confidence ?? ""))")
        #expect(r.similar.contains { $0.id == repair.id }, "…it is shown as similar instead")
    }

    @Test("RED P1-2: a repair with NO fixity cannot lend in either direction")
    func unverifiableRepairDoesNotLend() async throws {
        let (sb, model) = try sandboxModel("c1673_repair_nofix"); defer { sb.cleanup() }
        let parent = try record(sb, "test_tape.mov", seed: 1)
        let repair = try record(sb, "test_tape_balanced.mov", seed: 2)
        repair.derivedFrom = parent.id; repair.derivationKind = BalanceAudioFix.derivationKind
        repair.contentFixity = nil
        repair.userDate = "2002-10"; repair.userDateConfidence = "known"
        model.records = [parent, repair]
        #expect(ArchiveAngelFamilyFacts.inherited(for: parent, relatives: await relatives(model, for: parent).0).date == nil)
        repair.userDate = nil; parent.userDate = "1987"; parent.userDateConfidence = "known"
        #expect(ArchiveAngelFamilyFacts.inherited(for: repair, relatives: await relatives(model, for: repair).0).date == nil)
    }

    // MARK: P1-2 ancestry

    @Test("control: an unchanged tape lends its date DOWN to its unchanged trim")
    func freshAncestorLends() async throws {
        let (sb, model) = try sandboxModel("c1673_anc_ok"); defer { sb.cleanup() }
        let tape = try record(sb, "test_tape.dv", seed: 3)
        let trim = try record(sb, "test_tape_trimmed.dv", seed: 4)
        trim.derivedFrom = tape.id; trim.derivationKind = TrimPlan.derivationKind
        trim.trimInSeconds = 10; trim.trimOutSeconds = 40
        tape.userDate = "1987"; tape.userDateConfidence = "known"
        model.records = [tape, trim]
        #expect(ArchiveAngelFamilyFacts.inherited(for: trim, relatives: await relatives(model, for: trim).0).date?.value == "1987")
    }

    @Test("RED P1-2: a tape rewritten since its fixity never lends DOWN to its trim (codex probe)")
    func staleAncestorDoesNotLend() async throws {
        let (sb, model) = try sandboxModel("c1673_anc_stale"); defer { sb.cleanup() }
        let tape = try record(sb, "test_tape.dv", seed: 3)
        let trim = try record(sb, "test_tape_trimmed.dv", seed: 4)
        trim.derivedFrom = tape.id; trim.derivationKind = TrimPlan.derivationKind
        trim.trimInSeconds = 10; trim.trimOutSeconds = 40
        try rewriteInPlace(tape)
        tape.userDate = "2002-10"; tape.userDateConfidence = "known"
        model.records = [tape, trim]
        let (r, fresh) = await relatives(model, for: trim)
        #expect(!fresh.contains(tape.id))
        let got = ArchiveAngelFamilyFacts.inherited(for: trim, relatives: r)
        #expect(got.date == nil, "a rewritten tape lent \(got.date?.value ?? "") (\(got.date?.confidence ?? ""))")
    }

    @Test("RED P1-2: a stale middle link ends the chain — the grandparent does not lend past it")
    func staleMiddleEndsChain() async throws {
        let (sb, model) = try sandboxModel("c1673_anc_chain"); defer { sb.cleanup() }
        let tape = try record(sb, "test_tape.dv", seed: 3)
        let transcode = try record(sb, "test_tape.mov", seed: 5)
        transcode.derivedFrom = tape.id
        let trim = try record(sb, "test_tape_trimmed.mov", seed: 4)
        trim.derivedFrom = transcode.id; trim.derivationKind = TrimPlan.derivationKind
        trim.trimInSeconds = 10; trim.trimOutSeconds = 40
        tape.userDate = "1987"; tape.userDateConfidence = "known"
        model.records = [tape, transcode, trim]
        #expect(ArchiveAngelFamilyFacts.inherited(for: trim, relatives: await relatives(model, for: trim).0).date?.value == "1987",
                "control: an all-fresh chain lends down two hops")
        try rewriteInPlace(transcode)
        #expect(ArchiveAngelFamilyFacts.inherited(for: trim, relatives: await relatives(model, for: trim).0).date == nil)
    }

    // MARK: P1-1 archive link

    /// A source and its archive copy linked the way Promote links them.
    private func archivePair(_ sb: MasterArchiveTestSupport.Sandbox, _ model: VideoScanModel) throws -> (VideoRecord, VideoRecord) {
        let source = try record(sb, "test_promo.mov", seed: 6)
        let copyURL = sb.archiveVolume.appendingPathComponent("test_1988-xx-xx_promo.mov")
        try FileManager.default.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.fullPath), to: copyURL)
        let copy = MasterArchiveTestSupport.makeRecord(path: copyURL.path)
        copy.durationSeconds = 600
        copy.derivedFrom = source.id; copy.derivationKind = ArchivePromotion.derivationKind
        try AngelTestFixity.capture(copy)
        model.records = [source, copy]
        #expect(model.isArchiveCopy(copy))
        return (source, copy)
    }

    @Test("control: an unchanged source and archive copy — date and backup answers cross the link")
    func equalFreshLinkLends() async throws {
        let (sb, model) = try sandboxModel("c1673_link_ok"); defer { sb.cleanup() }
        let (source, copy) = try archivePair(sb, model)
        source.userDate = "1988"; source.userDateConfidence = "known"
        source.backupAttestations = [offsite]
        let (r, _) = await relatives(model, for: copy)
        let got = ArchiveAngelFamilyFacts.inherited(for: copy, relatives: r)
        #expect(got.date?.value == "1988")
        #expect(r.sameBytes.map(\.id) == [source.id])
        #expect(got.attestationKinds == [BackupAttestation.Kind.offsite.rawValue])
    }

    @Test("RED P1-1: source rewritten and RE-HASHED — both fresh, digests differ: no date, not sameBytes (codex probe)")
    func unequalFreshLinkDoesNotLend() async throws {
        let (sb, model) = try sandboxModel("c1673_link_rehash"); defer { sb.cleanup() }
        let (source, copy) = try archivePair(sb, model)
        try rewriteInPlace(source)
        try AngelTestFixity.capture(source)                   // a legitimate new fixity
        source.userDate = "2002-10"; source.userDateConfidence = "known"
        source.backupAttestations = [offsite]
        let (r, fresh) = await relatives(model, for: copy)
        try #require(fresh.contains(source.id) && fresh.contains(copy.id), "both ends are fresh")
        try #require(source.contentFixity?.digest != copy.contentFixity?.digest, "…with different bytes")
        let got = ArchiveAngelFamilyFacts.inherited(for: copy, relatives: r)
        #expect(got.date == nil, "an unequal archive link lent \(got.date?.value ?? "") (\(got.date?.confidence ?? ""))")
        #expect(!r.sameBytes.contains { $0.id == source.id }, "an unequal archive link claimed sameBytes")
        #expect(got.attestationKinds == nil, "…and carried backup answers")
    }

    @Test("RED P1-1: the reverse — an unequal fresh archive copy never lends to its source")
    func unequalFreshLinkDoesNotLendUp() async throws {
        let (sb, model) = try sandboxModel("c1673_link_rehash_up"); defer { sb.cleanup() }
        let (source, copy) = try archivePair(sb, model)
        try rewriteInPlace(copy)
        try AngelTestFixity.capture(copy)
        copy.userDate = "2002-10"; copy.userDateConfidence = "known"
        copy.backupAttestations = [offsite]
        let (r, fresh) = await relatives(model, for: source)
        try #require(fresh.contains(source.id) && fresh.contains(copy.id))
        let got = ArchiveAngelFamilyFacts.inherited(for: source, relatives: r)
        #expect(got.date == nil)
        #expect(r.sameBytes.isEmpty)
    }

    // MARK: Sensor

    @Test("SENSOR: every lending edge kind is blocked by a non-fresh endpoint (declared fresh set, pure lender logic)")
    func everyEdgeNeedsFreshEnds() {
        let stamp = FileIdentityStamp(device: 1, inode: 1, size: 10, mtimeNs: 0, ctimeNs: 1)
        func rec(_ name: String, digest: String) -> VideoRecord {
            let r = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/\(name)")
            r.sizeBytes = 10; r.durationSeconds = 600
            r.contentFixity = ContentFixity(digest: String(repeating: digest, count: 32), byteCount: 10, stamp: stamp)
            return r
        }
        let model = VideoScanModel()
        let target = rec("t.mov", digest: "aa")
        let twin = rec("twin.mov", digest: "aa")
        let repair = rec("t_balanced.mov", digest: "bb")
        repair.derivedFrom = target.id; repair.derivationKind = "balanceAudio"
        let tape = rec("tape.dv", digest: "cc")
        target.derivedFrom = tape.id
        model.records = [target, twin, repair, tape]
        let index = ArchiveAngelCopyFamily.Index(active: model.records)
        let all: Set<UUID> = [target.id, twin.id, repair.id, tape.id]
        func lenders(_ fresh: Set<UUID>) -> Set<UUID> {
            Set(ArchiveAngelFactLenders.lenders(for: target, index: index, catalog: model, fresh: fresh).facts.map(\.id))
        }
        #expect(lenders(all) == [twin.id, repair.id, tape.id], "control: all fresh → all lend")
        for donor in [twin, repair, tape] {
            #expect(!lenders(all.subtracting([donor.id])).contains(donor.id), "\(donor.filename) lent while not fresh")
        }
        #expect(lenders(all.subtracting([target.id])).isEmpty, "a non-fresh target takes nothing")
        #expect(Set(ArchiveAngelFactLenders.lenders(for: target, index: index, catalog: model, fresh: nil).facts.map(\.id))
                == [twin.id, repair.id, tape.id], "discovery (nil) still reaches every endpoint to stat")
    }
}
