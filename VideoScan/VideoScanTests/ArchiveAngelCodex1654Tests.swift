// ArchiveAngelCodex1654Tests.swift
// codex #1654 (2026-09-23) — post-merge review of Archive Angel S4, four P1s.
// Written RED first against main 6c57b2c0 (existing API only for the core
// assertions); the probes in ~/Library/Logs/VideoScan/review_s4_20260923/
// turned into tests:
//
//   P1-1  a SAMPLED content signature (FileHasher.segmentedHash: head /
//         middle / tail windows) is not identity — two 6 MiB files with the
//         same sampled hash and different bytes must not exchange a known date.
//   P1-2  trims are ancestry, not equivalence — two event trims of one tape
//         must not date each other, and a trim must not date its tape.
//   P1-3  an unlinked `<stem>_balanced` of equal length is a nomination,
//         never used automatically.
//   P1-4  rollback durability — the promote never starts without a durably
//         saved journal; a cancelled promote keeps its rollback entries
//         until the restored catalog is durably saved, and a relaunch
//         re-applies pending restores.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — codex #1654: identity, trims, balanced provenance, rollback durability", .serialized)
@MainActor
struct ArchiveAngelCodex1654Tests {

    // MARK: Fixtures

    private func sandboxModel(_ label: String) throws -> (MasterArchiveTestSupport.Sandbox, VideoScanModel) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (sb, model)
    }

    /// Two 6 MiB files that differ only at 1.25 MiB — outside the production
    /// 1 MiB head / middle / tail windows (codex's ProbeDefault fixture).
    private func sampledTwins(in dir: URL) throws -> (URL, URL) {
        var bytes = [UInt8](repeating: 0, count: 6 * 1024 * 1024)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let a = dir.appendingPathComponent("test_signature_a.bin")
        let b = dir.appendingPathComponent("test_signature_b.bin")
        try Data(bytes).write(to: a)
        bytes[1_310_720] ^= 0xFF
        try Data(bytes).write(to: b)
        return (a, b)
    }

    private func relatives(_ model: VideoScanModel, _ rec: VideoRecord,
                           fresh: Set<UUID> = []) -> ArchiveAngelFamilyFacts.Relatives {
        ArchiveAngelFamilyFacts.relatives(of: rec, index: ArchiveAngelCopyFamily.Index(active: model.records),
                                          catalog: model, fresh: fresh)
    }

    // MARK: P1-1

    @Test("RED P1-1: equal SAMPLED signatures with different bytes never lend a known date (codex probe)")
    func sampledSignatureIsNotIdentity() throws {
        let (sb, model) = try sandboxModel("c1654_sampled"); defer { sb.cleanup() }
        let (a, b) = try sampledTwins(in: sb.sources)
        let hashA = FileHasher.segmentedHash(path: a.path), hashB = FileHasher.segmentedHash(path: b.path)
        try #require(!hashA.isEmpty && hashA == hashB, "the fixture must reproduce equal sampled hashes")
        let fullA = try #require(try ArchivePromoteEngine.sha256(path: a.path))
        let fullB = try #require(try ArchivePromoteEngine.sha256(path: b.path))
        try #require(fullA != fullB, "…and unequal full SHA-256")
        let recipient = MasterArchiveTestSupport.makeRecord(path: a.path); recipient.contentHash = hashA
        let donor = MasterArchiveTestSupport.makeRecord(path: b.path); donor.contentHash = hashB
        donor.userDate = "1987-06"; donor.userDateConfidence = "known"; donor.userPlace = "Cape Cod"
        model.records = [recipient, donor]
        let got = ArchiveAngelFamilyFacts.inherited(for: recipient, relatives: relatives(model, recipient))
        #expect(got.date == nil, "a sampled-hash twin lent \(got.date?.value ?? "") (\(got.date?.confidence ?? ""))")
        #expect(got.place == nil)
    }

    // MARK: P1-2

    @Test("RED P1-2: two event trims of one tape never date each other, and a trim never dates its tape (codex probe)")
    func trimsAreNotEquivalent() throws {
        let (sb, model) = try sandboxModel("c1654_trims"); defer { sb.cleanup() }
        let tape = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/tape.dv"); tape.durationSeconds = 3600
        let birthday = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/tape_trimmed.dv")
        birthday.derivedFrom = tape.id; birthday.derivationKind = TrimPlan.derivationKind
        birthday.trimInSeconds = 0; birthday.trimOutSeconds = 600; birthday.durationSeconds = 600
        birthday.userDate = "1987-06-12"; birthday.userDateConfidence = "known"
        let wedding = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/tape_trimmed 2.dv")
        wedding.derivedFrom = tape.id; wedding.derivationKind = TrimPlan.derivationKind
        wedding.trimInSeconds = 1800; wedding.trimOutSeconds = 2400; wedding.durationSeconds = 600
        model.records = [tape, birthday, wedding]
        let second = ArchiveAngelFamilyFacts.inherited(for: wedding, relatives: relatives(model, wedding))
        #expect(second.date == nil, "the second trim took the first trim's \(second.date?.value ?? "")")
        let parent = ArchiveAngelFamilyFacts.inherited(for: tape, relatives: relatives(model, tape))
        #expect(parent.date == nil, "the tape took a segment's \(parent.date?.value ?? "")")
    }

    @Test("P1-2 positive: facts flow DOWN to a trim and between whole-file equivalents; attestations only between same bytes")
    func directionAndEquivalence() throws {
        let (sb, model) = try sandboxModel("c1654_direction"); defer { sb.cleanup() }
        let tape = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/tape.dv"); tape.durationSeconds = 3600
        tape.userDate = "1987"; tape.userDateConfidence = "known"
        tape.backupAttestations = [BackupAttestation(kind: .offsite, answer: .yes, attestedAt: Date(timeIntervalSince1970: 1_757_800_000))]
        let trim = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/tape_trimmed.dv")
        trim.derivedFrom = tape.id; trim.derivationKind = TrimPlan.derivationKind
        trim.trimInSeconds = 0; trim.trimOutSeconds = 600; trim.durationSeconds = 600
        let balanced = MasterArchiveTestSupport.makeRecord(path: "/Volumes/T/tape_balanced.mov")
        balanced.derivedFrom = tape.id; balanced.derivationKind = BalanceAudioFix.derivationKind
        balanced.durationSeconds = 3600.4
        model.records = [tape, trim, balanced]
        let down = ArchiveAngelFamilyFacts.inherited(for: trim, relatives: relatives(model, trim))
        #expect(down.date?.value == "1987", "a trim takes its tape's date")
        #expect(down.attestationKinds == nil, "…but not its backup answers: different bytes")
        let equiv = ArchiveAngelFamilyFacts.inherited(for: balanced, relatives: relatives(model, balanced))
        #expect(equiv.date?.value == "1987", "a whole-file repair takes its source's date")
        // And the tape takes a whole-file repair's date (equivalent), never a trim's.
        tape.userDate = nil; balanced.userDate = "1988"; balanced.userDateConfidence = "estimated"
        let up = ArchiveAngelFamilyFacts.inherited(for: tape, relatives: relatives(model, tape))
        #expect(up.date?.value == "1988")
        // A "balanced" copy that is a different length is NOT an equivalent.
        balanced.durationSeconds = 600
        let cut = ArchiveAngelFamilyFacts.inherited(for: tape, relatives: relatives(model, tape))
        #expect(cut.date == nil)
    }

    @Test("P1-1 positive: a stale whole-file digest (size changed since it was read) is not identity")
    func staleDigestIsNotIdentity() async throws {
        let (sb, model) = try sandboxModel("c1654_stale"); defer { sb.cleanup() }
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_x.mov"), bytes: 100, seed: 3)
        let a = MasterArchiveTestSupport.makeRecord(path: file.path)
        let b = try AngelTestFixity.verifiedTwin(of: a, named: "test_x_copy.mov", in: sb.sources)
        b.userDate = "1990"
        model.records = [a, b]
        let index = ArchiveAngelCopyFamily.Index(active: model.records)
        let fresh = await ArchiveAngelFixityCheck.verify(targets: [a], index: index, catalog: model)
        #expect(fresh == [a.id, b.id], "both stamps describe their files now")
        #expect(ArchiveAngelFamilyFacts.inherited(for: a, relatives: relatives(model, a, fresh: fresh)).date?.value == "1990")
        #expect(ArchiveAngelFamilyFacts.inherited(for: a, relatives: relatives(model, a)).date == nil,
                "no stat, no lending")
        a.sizeBytes = 200                                  // the catalogue says it changed since the digest
        #expect(ArchiveAngelFamilyFacts.inherited(for: a, relatives: relatives(model, a, fresh: fresh)).date == nil)
    }

    // MARK: P1-3

    @Test("RED P1-3: an UNLINKED <stem>_balanced of equal length is not used",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable, "ffmpeg/ffprobe not available"))
    func unlinkedBalancedIsNotUsed() async throws {
        let (sb, model) = try sandboxModel("c1654_balanced"); defer { sb.cleanup() }
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        let path = try BalanceAudioTestMedia.generate(into: sb.sources, channelCase: .leftOnly, wrapper: .movH264Pcm)
        let rec = MasterArchiveTestSupport.makeRecord(path: path, userDate: "1995", starRating: 2)
        rec.durationSeconds = 600; rec.videoCodec = "h264"; rec.audioCodec = "pcm_s16le"; rec.isPlayable = "Yes"
        let lookalikeURL = sb.sources.appendingPathComponent("test_balance_leftOnly_balanced.mov")
        try FileManager.default.copyItem(atPath: path, toPath: lookalikeURL.path)
        let lookalike = MasterArchiveTestSupport.makeRecord(path: lookalikeURL.path, userDate: "1995")
        lookalike.durationSeconds = 600; lookalike.videoCodec = "h264"; lookalike.audioCodec = "pcm_s16le"
        lookalike.isPlayable = "Yes"                   // derivedFrom nil: no provenance
        model.records = [rec, lookalike]
        let center = MediaFileOperationsCenter()            // held: the job keeps it weakly
        let job = ArchiveAngelJob(model: model, center: center, count: 1, makeLossless: false,
                                  bufferRoot: buffer, explicitRecordIDs: [rec.id])
        job.start()
        await job.task?.value
        _ = center
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let step = try #require(job.plan.entries.first?.steps.first { $0.kind == .balanceAudio })
        #expect(step.recordID != lookalike.id, "an unlinked look-alike was used as the balanced companion")
        #expect(!job.plan.log.contains { $0.contains("using existing balanced copy") }, "\(job.plan.log.suffix(6))")
        // …but it is NOMINATED for Review.
        let entry = try #require(job.plan.entries.first)
        #expect(entry.balancedNomination == lookalike.fullPath)
        #expect(ArchiveAngelFamilyFacts.reviewLine(entry).contains("an existing balanced copy may exist: test_balance_leftOnly_balanced.mov — not used"))
    }

    // MARK: P1-4

    /// A promote row whose sibling lends a known date through a VERIFIED
    /// full-content match (both carry the same whole-file SHA-256).
    private func promoteFixture(_ label: String, batchDir: URL? = nil) throws
        -> (MasterArchiveTestSupport.Sandbox, VideoScanModel, VideoRecord, ArchiveAngelPlan) {
        let (sb, model) = try sandboxModel(label)
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("tape.mov"), bytes: 4096, seed: 11)
        let rec = MasterArchiveTestSupport.makeRecord(path: file.path, starRating: 3)
        rec.contentHash = "v1:tape"
        // A REAL byte-identical copy with real fixity (codex #1659).
        let sibling = try AngelTestFixity.verifiedTwin(of: rec, named: "Christmas copy.mov", in: sb.sources)
        sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"
        model.records = [rec, sibling]
        let entry = ArchiveAngelPlan.Entry(
            id: rec.id, sourcePath: file.path, filename: "tape.mov", sizeBytes: 4096,
            sourceContentHash: "v1:tape", sourceModifiedAt: nil,
            durationSeconds: 600, score: 105, evidence: [], proposedName: "tape.mov",
            proposedDate: "1987-06", status: .ready)
        var plan = ArchiveAngelPlan(batchDir: (batchDir ?? sb.root.appendingPathComponent("batch-c1654")).path,
                                    requestedCount: 1, makeLossless: false, entries: [entry])
        plan.status = .ready
        return (sb, model, rec, plan)
    }

    @Test("P1-4 control: a verified full-content twin DOES lend its known date at promote")
    func verifiedTwinLends() async throws {
        let (sb, model, rec, fixturePlan) = try promoteFixture("c1654_control"); defer { sb.cleanup() }
        var plan = fixturePlan
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: plan, catalog: model)
        let job = ArchiveAngelPromoter().promote(plan: &plan, model: model, center: MediaFileOperationsCenter(),
                                                 freshFixity: fresh) { _ in }
        #expect(job != nil)
        #expect(rec.userDate == "1987-06" && rec.userDateConfidence == "known")
        job?.cancel()
    }

    @Test("RED P1-4a: the promote never starts when its journal (plan.json) cannot be saved — and nothing is stamped")
    func noJournalNoPromote() async throws {
        let sbLabel = "c1654_nojournal"
        let blockerParent = FileManager.default.temporaryDirectory.appendingPathComponent("test_c1654_blocker_\(UUID().uuidString)")
        try Data([0]).write(to: blockerParent)                 // a FILE where the batch's parent folder should be
        defer { try? FileManager.default.removeItem(at: blockerParent) }
        let (sb, model, rec, fixturePlan) = try promoteFixture(sbLabel, batchDir: blockerParent.appendingPathComponent("batch-x"))
        defer { sb.cleanup() }
        var plan = fixturePlan
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let center = MediaFileOperationsCenter()
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: plan, catalog: model)
        #expect(!fresh.isEmpty, "the donor is verified — the stamp would happen")
        let job = ArchiveAngelPromoter().promote(plan: &plan, model: model, center: center, freshFixity: fresh) { _ in }
        #expect(job == nil, "a promote started without a durable journal")
        #expect(center.jobs.isEmpty)
        #expect(rec.userDate == nil, "an inherited fact was left on the record with no journal to undo it")
    }

    @Test("RED P1-4b: after a cancel, the rollback journal stays on disk until the restored catalog is durably saved; a relaunch re-applies it")
    func rollbackSurvivesACrash() async throws {
        let (sb, model, rec, fixturePlan) = try promoteFixture("c1654_crash"); defer { sb.cleanup() }
        var plan = fixturePlan
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var settled: ArchiveAngelPlan?
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: plan, catalog: model)
        let job = try #require(ArchiveAngelPromoter().promote(plan: &plan, model: model,
                                                              center: MediaFileOperationsCenter(),
                                                              freshFixity: fresh) { settled = $0 })
        #expect(rec.userDate == "1987-06", "stamped from the verified twin")
        // The catalog cannot be saved (a full or read-only volume) while
        // the cancel settles — the restore is NOT durable yet.
        model.catalogStore.isReadOnly = true
        job.cancel()
        await job.task?.value
        for _ in 0..<500 where settled == nil {
            await Task.yield(); try? await Task.sleep(for: .milliseconds(2))
        }
        // Let the (refused — read-only) acknowledged save run its course.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rec.userDate == nil, "restored in memory")
        let onDisk = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)
        #expect(onDisk.entries.first?.stampedFacts?.isEmpty == false,
                "the journal must survive until the restored catalog is on disk")

        // CRASH: the catalog on disk still holds the inherited value.
        rec.userDate = "1987-06"; rec.userDateConfidence = "known"
        model.catalogStore.isReadOnly = false
        // RELAUNCH: the settle pass re-applies the pending restore.
        _ = ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: sb.root, model: model)
        #expect(rec.userDate == nil, "the relaunch re-applied the pending restore")
        // The acknowledged save runs OFF the main actor (codex #1659): the
        // journal is cleared only once it confirms — poll for it.
        var after = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)
        for _ in 0..<300 where after.entries.first?.stampedFacts != nil {
            try? await Task.sleep(for: .milliseconds(10))
            after = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)
        }
        #expect(after.entries.first?.stampedFacts == nil, "cleared once the catalog save was confirmed")
    }
}
