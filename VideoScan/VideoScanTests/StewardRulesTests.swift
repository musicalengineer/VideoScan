// StewardRulesTests.swift
// The two rules of the content steward that are "the first tests" (design
// §5.6 of docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md):
//
//   RULE 1 — a delete card shows the PROOF, not the score. The "N verified
//            copies would remain" on a Reclaim set card is the Delete
//            planner's own number for the same files: same candidates
//            (`deletionTierCandidates`), same disk question
//            (`DeletionTierFacts.gather`), same tier rule
//            (`DeletionTierDecision.decide`). Pinned here against real
//            files with real stored evidence, not against a re-statement.
//
//   RULE 2 — one steward's cases are never another's loss. No case
//            proposes letting go of an archive copy, a file on the archive
//            drive, a file filed as Archived, or a file Archive Angel has
//            chosen or is preparing; a set whose only other copies are
//            protected produces no Reclaim card. Decided by the canonical
//            predicates, exercised here through the model.
//
// Isolation: every model has its own temp catalog directory; the fixtures
// are small files in a temp folder (`test_` prefix), removed afterwards.
// Media matrix: N/A — the planner's stat-only question; no media is opened.
//
// Suites: StewardProofRuleTests · StewardExclusionRuleTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
private func isolatedModel() -> VideoScanModel {
    let model = VideoScanModel()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_steward_\(UUID().uuidString.prefix(8))", isDirectory: true)
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

@MainActor
private func record(_ path: String, size: Int64 = 1, group: UUID? = nil,
                    disposition: DuplicateDisposition = .none) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "m"
    r.durationSeconds = 61
    if let group {
        r.duplicateGroupID = group
        r.duplicateDisposition = disposition
        r.duplicateConfidence = .high
    }
    return r
}

@MainActor
private func queue(_ model: VideoScanModel, crossMode: Bool = false) -> StewardQueue {
    let inputs = StewardCaseBuilder.project(model.records, protection: model.stewardProtectionRule())
    return StewardCaseBuilder.build(inputs: inputs, volumes: [], mountedRoots: ["/"], alsoCleanUpWorkingCopies: crossMode)
}

// MARK: - Rule 1

@Suite("Steward rule 1 — the card's proof IS the Delete planner's", .serialized)
@MainActor
struct StewardProofRuleTests {

    /// A lowercase 64-hex digest, as a stored whole-file fixity carries.
    private let digest = String(repeating: "ab", count: 32)
    private let otherDigest = String(repeating: "cd", count: 32)

    private struct Rig {
        let dir: URL
        let model: VideoScanModel
        let group = UUID()
    }

    private func rig() throws -> Rig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_steward_proof_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("here"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        return Rig(dir: dir, model: isolatedModel())
    }

    /// A real file with its catalog record; `evidence` = the stored digest
    /// bound to the file as it is on disk now (what a full read leaves).
    private func file(_ rig: Rig, _ relative: String, _ disposition: DuplicateDisposition,
                      evidence: String?) throws -> VideoRecord {
        let url = rig.dir.appendingPathComponent(relative)
        let bytes = Data(repeating: 7, count: 4_096)
        try bytes.write(to: url)
        let r = record(url.path, size: Int64(bytes.count), group: rig.group, disposition: disposition)
        if let evidence {
            r.contentFixity = try #require(ContentFixity.captured(path: url.path, digest: evidence, byteCount: Int64(bytes.count)))
        }
        return r
    }

    /// The card's proof for `copy`, through the steward's own two steps.
    private func stewardProof(_ rig: Rig, copy: VideoRecord) throws -> StewardCopyProof {
        let set = try #require(queue(rig.model).cases.first { $0.kind == .reclaimGroup })
        let prepared = try #require(StewardEvidenceBuilder.prepare(model: rig.model, for: set))
        let proofs = StewardEvidenceBuilder.prove(prepared.questions, preferTrash: prepared.preferTrash)
        return try #require(proofs[copy.id])
    }

    /// The planner's answer for the same copy, asked directly.
    private func plannerAnswer(_ rig: Rig, copy: VideoRecord, keeper: VideoRecord, excluding: Set<UUID>,
                               digest: String) -> (facts: DeletionTierFacts, decision: DeletionTierDecision) {
        let candidates = rig.model.deletionTierCandidates(record: copy, keeper: keeper, excluding: excluding)
        let facts = DeletionTierFacts.gather(candidates, digest: digest)
        return (facts, DeletionTierDecision.decide(facts: facts,
                                                   preferTrash: rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate))
    }

    @Test func aCountedSiblingMakesTwoAndTheNumberEqualsThePlanners() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        // On another "drive" (another folder: no scan targets here), so it
        // is not a row of the same run — and its evidence still describes it.
        let sibling = try file(rig, "elsewhere/sibling.mov", .extraCopy, evidence: digest)
        rig.model.records = [keeper, copy, sibling]

        let proof = try stewardProof(rig, copy: copy)
        let planner = plannerAnswer(rig, copy: copy, keeper: keeper, excluding: [], digest: digest)
        #expect(planner.facts.remainingVerifiedCopies == 2, "fixture: keeper + the sibling whose evidence reproduces")
        #expect(proof.remaining == planner.decision.remainingVerifiedCopies)
        #expect(proof.counted == planner.facts.counted)
        #expect(proof.notCounted == planner.facts.unverifiedCopies)
        #expect(proof.tier == planner.decision.tier)
        #expect(proof.tier == .trash, "exactly \(DeletionTierDecision.minimumForTrash) remain → the Trash")
        #expect(proof.hadStoredDigest)
        #expect(proof.remainLine.hasPrefix("2 verified copies would remain: keeper on "))
    }

    @Test func aThirdVerifiedCopyMakesItPermanentExactlyAsThePlannerDecides() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        try FileManager.default.createDirectory(at: rig.dir.appendingPathComponent("third"), withIntermediateDirectories: true)
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        let a = try file(rig, "elsewhere/a.mov", .extraCopy, evidence: digest)
        let b = try file(rig, "third/b.mov", .extraCopy, evidence: digest)
        rig.model.records = [keeper, copy, a, b]

        let proof = try stewardProof(rig, copy: copy)
        let planner = plannerAnswer(rig, copy: copy, keeper: keeper, excluding: [], digest: digest)
        #expect(planner.facts.remainingVerifiedCopies == DeletionTierDecision.minimumForPermanent)
        #expect(proof.remaining == planner.facts.remainingVerifiedCopies && proof.tier == planner.decision.tier)
        #expect(proof.tier == .permanent)
    }

    /// The other copies on the SAME drive are rows of the same run, still
    /// to be decided: the planner never counts them, and neither does the
    /// card — it shows the conservative number the run would act on.
    @Test func copiesTheSameRunWouldAlsoDecideAreNotCounted() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        let sameRun = try file(rig, "here/copy2.mov", .extraCopy, evidence: digest)
        rig.model.records = [keeper, copy, sameRun]

        let proof = try stewardProof(rig, copy: copy)
        let asTheRunAsks = plannerAnswer(rig, copy: copy, keeper: keeper, excluding: [sameRun.id], digest: digest)
        let optimistic = plannerAnswer(rig, copy: copy, keeper: keeper, excluding: [], digest: digest)
        #expect(optimistic.facts.remainingVerifiedCopies == 2, "fixture: counting the same-run row would say two")
        #expect(asTheRunAsks.facts.remainingVerifiedCopies == 1)
        #expect(proof.remaining == asTheRunAsks.facts.remainingVerifiedCopies)
        #expect(proof.tier == nil && proof.outcomeLine == "As things stand, it would be left alone.")
        #expect(proof.notCounted == asTheRunAsks.facts.unverifiedCopies)
        #expect(proof.caveatLine == "1 other copy was not counted — not connected, different, or part of the same cleanup.")
    }

    /// QA F2 (2026-10-03): a sibling with no stored evidence is one the run
    /// READS — and then this copy goes. The card must not say "left alone".
    @Test func aCopyTheRunWouldRemoveAfterReadingASiblingIsNotPromisedAsLeftAlone() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        let unread = try file(rig, "elsewhere/unread.mov", .extraCopy, evidence: nil)
        rig.model.records = [keeper, copy, unread]
        let proof = try stewardProof(rig, copy: copy)
        #expect(proof.remaining == 1, "fixture: as things stand only the keeper is verified")
        #expect(!proof.outcomeLine.contains("left alone"), "said: \(proof.outcomeLine)")
        #expect(proof.outcomeLine.contains("reads 1 more copy first"))
        #expect(proof.outcomeLine.contains("Trash"), "keeper + the sibling once read = two → the Trash")
    }

    /// GH #258 (was QA F1, 2026-10-03): the Delete planner now leaves the
    /// Archive Angel's picks and filed-as-Archived copies alone, so they
    /// are NOT rows of the run. The card says "never offered" again, and
    /// counts them exactly as the run does — as ordinary siblings, which
    /// count when their stored evidence reproduces.
    @Test func copiesTheAngelChoseOrYouFiledAreCountedAsTheRunCountsThem() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let free = try file(rig, "here/free.mov", .extraCopy, evidence: digest)
        let angel = try file(rig, "here/angel.mov", .extraCopy, evidence: digest)
        let filed = try file(rig, "here/filed.mov", .extraCopy, evidence: digest)
        filed.lifecycleStage = .archived
        rig.model.records = [keeper, free, angel, filed]
        var summary = rig.model.archiveAngel.recommendations
        summary.candidateIDs = [angel.id]
        summary.revision += 1
        rig.model.archiveAngel.publishRecommendations(summary)

        // What the run would select on this drive: the free copy only.
        let selection = rig.model.duplicateDeletionSelection(onVolume: rig.dir.appendingPathComponent("here").path)
        #expect(selection.targets.map(\.id) == [free.id], "the run behind the card took a copy the card calls never offered")
        #expect(Set(selection.held.map(\.record.id)) == [angel.id, filed.id])

        // The run's other rows still to decide: none — so the Angel's and
        // the filed copy are asked about as siblings, and both reproduce.
        let sameRun = Set(selection.targets.map(\.id)).subtracting([free.id])
        let proof = try stewardProof(rig, copy: free)
        let run = plannerAnswer(rig, copy: free, keeper: keeper, excluding: sameRun, digest: digest)
        #expect(run.facts.remainingVerifiedCopies == 3, "keeper + the two copies left alone, each with current evidence")
        #expect(proof.remaining == run.facts.remainingVerifiedCopies, "the card and the run count differently")
        #expect(proof.tier == run.decision.tier && proof.notCounted == run.facts.unverifiedCopies)

        // (1) The words on the Angel's and the filed rows.
        let set = try #require(queue(rig.model).cases.first { $0.kind == .reclaimGroup })
        let rows = Dictionary(uniqueKeysWithValues: set.copies.map { ($0.id, $0) })
        let angelRow = try #require(rows[angel.id]), filedRow = try #require(rows[filed.id])
        #expect(angelRow.standing == .protected(.angel) && filedRow.standing == .protected(.filedArchived))
        #expect(StewardStandingWords.words(for: angelRow, proof: nil) == "Archive Angel has chosen this copy — never offered.")
        #expect(StewardStandingWords.words(for: filedRow, proof: nil) == "You filed this copy as Archived — never offered.")
        // …they are not reclaimable, not proposed, not rows of the run, and not asked about.
        #expect(set.payoffBytes == free.sizeBytes && set.protectedCopies == 2)
        #expect(set.runRows.map(\.id) == [free.id])
        let prepared = try #require(StewardEvidenceBuilder.prepare(model: rig.model, for: set))
        #expect(prepared.questions.map(\.copyID) == [free.id])

        // (2) The drive card counts the one copy the run would take.
        let drive = try #require(queue(rig.model).cases.first { $0.kind == .reclaimDrive })
        #expect(drive.estimate?.copies == 1 && drive.recordIDs == [free.id])
        #expect(rig.model.volumesWithDeletableDuplicates().map(\.count) == [1], "the Delete flow's own count agrees")
    }

    /// QA F6: a hard link of the copy itself is the same bytes on the same
    /// platter — never "another copy that remains".
    @Test func aHardLinkOfTheCopyItselfIsNotCounted() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        let linkURL = rig.dir.appendingPathComponent("elsewhere/link.mov")
        try FileManager.default.linkItem(at: URL(fileURLWithPath: copy.fullPath), to: linkURL)
        // The link changed the inode's ctime: re-bind both records' evidence.
        copy.contentFixity = try #require(ContentFixity.captured(path: copy.fullPath, digest: digest, byteCount: copy.sizeBytes))
        let link = VideoRecord()
        link.fullPath = linkURL.path
        link.filename = "link.mov"
        link.directory = linkURL.deletingLastPathComponent().path
        link.sizeBytes = copy.sizeBytes
        link.duplicateGroupID = rig.group
        link.duplicateDisposition = .extraCopy
        link.contentFixity = try #require(ContentFixity.captured(path: linkURL.path, digest: digest, byteCount: copy.sizeBytes))
        rig.model.records = [keeper, copy, link]
        let proof = try stewardProof(rig, copy: copy)
        #expect(proof.remaining == 1, "the hard link was counted as a second copy")
        #expect(proof.notCounted == 1)
    }

    @Test func aSiblingWithDifferentBytesOrChangedSinceIsNotCounted() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        let different = try file(rig, "elsewhere/different.mov", .extraCopy, evidence: otherDigest)
        rig.model.records = [keeper, copy, different]
        let proof = try stewardProof(rig, copy: copy)
        let planner = plannerAnswer(rig, copy: copy, keeper: keeper, excluding: [], digest: digest)
        #expect(planner.facts.remainingVerifiedCopies == 1)
        #expect(proof.remaining == 1 && proof.notCounted == planner.facts.unverifiedCopies && proof.notCounted == 1)
        #expect(proof.caveatLine == "1 other copy was not counted — not connected, different, or part of the same cleanup.")
        #expect(proof.readsFirst == 0 && proof.outcomeLine == "As things stand, it would be left alone.",
                "its evidence is current and says different bytes: no read would change that")
    }

    @Test func withNoStoredDigestOnlyTheKeeperIsCountedAndTheCardSaysTheRunReadsFirst() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: nil)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: nil)
        let sibling = try file(rig, "elsewhere/sibling.mov", .extraCopy, evidence: digest)
        rig.model.records = [keeper, copy, sibling]
        let proof = try stewardProof(rig, copy: copy)
        #expect(proof.remaining == 1 && proof.tier == nil && !proof.hadStoredDigest)
        #expect(proof.notCounted == 1)
        // QA F2: not "left alone" — the run reads the copy, and the sibling may then count.
        #expect(proof.readsFirst == 1 && proof.tierIfTheyMatch == .trash)
        #expect(proof.outcomeLine == "The run reads this copy first; if the other copy matches, it would go to the Trash, not be deleted.")
        #expect(proof.caveatLine == nil)
        #expect(proof.counted.count == 1 && proof.counted[0].hasPrefix("keeper on "))
    }

    @Test func theKeepersDigestStandsInWhenTheCopyHasNone() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: nil)
        let sibling = try file(rig, "elsewhere/sibling.mov", .extraCopy, evidence: digest)
        rig.model.records = [keeper, copy, sibling]
        let proof = try stewardProof(rig, copy: copy)
        let planner = plannerAnswer(rig, copy: copy, keeper: keeper, excluding: [], digest: digest)
        #expect(proof.hadStoredDigest && proof.remaining == planner.facts.remainingVerifiedCopies && proof.remaining == 2)
    }

    @Test func theCardSaysWhyTheKeeperWasChosen() throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let keeper = try file(rig, "here/keeper.mov", .keep, evidence: digest)
        keeper.starRating = 4                                  // the person's own mark
        let copy = try file(rig, "here/copy.mov", .extraCopy, evidence: digest)
        rig.model.records = [keeper, copy]
        let set = try #require(queue(rig.model).cases.first { $0.kind == .reclaimGroup })
        let prepared = try #require(StewardEvidenceBuilder.prepare(model: rig.model, for: set))
        #expect(prepared.evidence.keeperReason == "It carries more of your own marks — ratings, names, notes, dates.")
        #expect(prepared.evidence.proofs == nil, "the count arrives once the disk has answered")
        #expect(prepared.questions.map(\.copyID) == [copy.id])
    }

    /// The rule printed on the card is the planner's constants, quoted.
    @Test func theSurvivalRuleOnTheCardQuotesThePlannersConstants() {
        #expect(ReclaimableEstimate.survivalRule.contains("at least \(DeletionTierDecision.minimumForPermanent) verified copies"))
        #expect(ReclaimableEstimate.survivalRule.contains("exactly \(DeletionTierDecision.minimumForTrash)"))
    }
}

// MARK: - Rule 2

@Suite("Steward rule 2 — never another steward's loss", .serialized)
@MainActor
struct StewardExclusionRuleTests {

    private func designateFamilyArchive(_ model: VideoScanModel) {
        model.masterArchive = MasterArchiveDesignation(
            targetPath: "/Volumes/FamilyArchive", rootPath: "/Volumes/FamilyArchive/Test_Family_Archive", volumeUUID: nil)
    }

    @Test func thePredicateProtectsArchiveCopiesTheArchiveDriveAndFiledRecords() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let rule = model.stewardProtectionRule()
        #expect(rule(record("/Volumes/FamilyArchive/Test_Family_Archive/1990s/a.mov")) == .archived, "inside the archive")
        #expect(rule(record("/Volumes/FamilyArchive/loose/a.mov")) == .archiveDrive, "elsewhere on the archive's drive")
        #expect(rule(record("/Volumes/SanDisk/a.mov")) == .none)
        #expect(rule(record("/Volumes/FamilyArchiveOld/a.mov")) == .none, "a different drive whose name merely starts the same")

        let promoted = record("/Volumes/SanDisk/promoted.mov")
        promoted.derivationKind = ArchivePromotion.derivationKind
        #expect(rule(promoted) == .archived, "a promoted copy, wherever it sits")

        let filed = record("/Volumes/SanDisk/filed.mov")
        filed.lifecycleStage = .archived
        #expect(rule(filed) == .filedArchived, "filed as Archived in Triage")

        // With NO Master Archive designated the archive rule says nothing;
        // the planner's hold rule still leaves a promoted copy alone.
        let bare = isolatedModel()
        #expect(bare.stewardProtectionRule()(promoted) == .filedArchived)
        #expect(bare.duplicateDeletionHoldRule()(promoted) == .promotedArchiveCopy)
    }

    /// GH #258: "protected" on a card and "left alone" by the Delete
    /// planner are ONE answer, for every class — asked of the planner's two
    /// rules directly, and of its selection.
    @Test func thePredicateAgreesWithTheDeletePlannersOwnRules() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let g = UUID()
        func extra(_ path: String) -> VideoRecord { record(path, group: g, disposition: .extraCopy) }
        let filed = extra("/Volumes/SanDisk/filed.mov")
        filed.lifecycleStage = .archived
        let chosen = extra("/Volumes/SanDisk/chosen.mov")
        let promoted = extra("/Volumes/SanDisk/promoted.mov")
        promoted.derivationKind = ArchivePromotion.derivationKind
        let free = extra("/Volumes/SanDisk/z.mov")
        let all = [extra("/Volumes/FamilyArchive/Test_Family_Archive/x.mov"), extra("/Volumes/FamilyArchive/y.mov"),
                   free, extra("/Users/someone/Movies/w.mov"), filed, chosen, promoted]
        model.records = [record("/Volumes/SanDisk/keeper.mov", group: g, disposition: .keep)] + all
        var summary = model.archiveAngel.recommendations
        summary.candidateIDs = [chosen.id]
        summary.revision += 1
        model.archiveAngel.publishRecommendations(summary)

        let rule = model.stewardProtectionRule()
        let hold = model.duplicateDeletionHoldRule()
        let snapshot = model.archiveVolumeProtection()
        for r in all {
            let plannerLeavesAlone = model.bulkDeleteRefusal(r, volume: snapshot) != nil || hold(r) != nil
            #expect(plannerLeavesAlone == rule(r).isProtected, "\(r.fullPath): the steward and the Delete planner disagree")
        }
        #expect(rule(filed) == .filedArchived && rule(chosen) == .angel && rule(promoted) == .archived && rule(free) == .none)
        // …and the selection on the drive takes exactly what no rule protects.
        #expect(model.duplicateDeletionSelection(onVolume: "/Volumes/SanDisk").targets.map(\.id) == [free.id])
    }

    @Test func archiveAngelsPicksAndPreparedBatchesAreProtected() {
        let model = isolatedModel()
        let chosen = record("/Volumes/SanDisk/chosen.mov")
        let preparing = record("/Volumes/SanDisk/preparing.mov")
        let promoted = record("/Volumes/SanDisk/just promoted.mov")
        let plain = record("/Volumes/SanDisk/plain.mov")
        var summary = model.archiveAngel.recommendations
        summary.candidateIDs = [chosen.id]
        summary.preparedIDs = [preparing.id]
        summary.promotedIDs = [promoted.id]
        summary.revision += 1
        model.archiveAngel.publishRecommendations(summary)
        let rule = model.stewardProtectionRule()
        #expect(rule(chosen) == .angel && rule(preparing) == .angel && rule(promoted) == .angel)
        #expect(rule(plain) == .none)
    }

    @Test func aSetWhoseOnlyOtherCopyIsOnTheArchiveDriveProducesNoReclaimCard() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let g = UUID()
        model.records = [record("/Volumes/LaCie/keep.mov", group: g, disposition: .keep),
                         record("/Volumes/FamilyArchive/loose/copy.mov", group: g, disposition: .extraCopy)]
        for crossMode in [false, true] {
            let q = queue(model, crossMode: crossMode)
            #expect(q.cases.isEmpty, "nothing on the archive drive is ever proposed (working copies \(crossMode ? "on" : "off"))")
        }
    }

    @Test func protectedCopiesAreShownButNeverCountedAsReclaimable() throws {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let g = UUID()
        let keeper = record("/Volumes/SanDisk/keep.mov", size: 100, group: g, disposition: .keep)
        let free = record("/Volumes/SanDisk/free.mov", size: 100, group: g, disposition: .extraCopy)
        let angel = record("/Volumes/SanDisk/angel.mov", size: 100, group: g, disposition: .extraCopy)
        let archived = record("/Volumes/SanDisk/promoted.mov", size: 100, group: g, disposition: .extraCopy)
        archived.derivationKind = ArchivePromotion.derivationKind
        let onArchiveDrive = record("/Volumes/FamilyArchive/loose/copy.mov", size: 100, group: g, disposition: .extraCopy)
        model.records = [keeper, free, angel, archived, onArchiveDrive]
        var summary = model.archiveAngel.recommendations
        summary.candidateIDs = [angel.id]
        summary.revision += 1
        model.archiveAngel.publishRecommendations(summary)

        let q = queue(model, crossMode: true)
        let set = try #require(q.cases.first { $0.kind == .reclaimGroup })
        #expect(set.payoffBytes == 100 && set.actionableBytes == 100, "only the free copy could come back")
        #expect(set.protectedCopies == 3, "the archive copy, the one on the archive drive, and the Angel's pick")
        let standing = Dictionary(uniqueKeysWithValues: set.copies.map { ($0.id, $0.standing) })
        #expect(standing[free.id] == .wouldBeChecked)
        #expect(standing[angel.id] == .protected(.angel))
        #expect(standing[archived.id] == .protected(.archived))
        #expect(standing[onArchiveDrive.id] == .protected(.archiveDrive))

        let drives = q.cases.filter { $0.kind == .reclaimDrive }
        #expect(drives.map(\.driveLabel) == ["SanDisk"], "the archive drive never gets a Reclaim card")
        #expect(drives.first?.estimate?.copies == 1 && drives.first?.recordIDs == [free.id])

        // The proof never asks about a protected copy either.
        let prepared = try #require(StewardEvidenceBuilder.prepare(model: model, for: set))
        #expect(prepared.questions.map(\.copyID) == [free.id])
    }

    @Test func aSetWhoseOnlyOtherCopiesAreAngelsOrArchivedProducesNoCard() {
        let model = isolatedModel()
        let g = UUID()
        let keeper = record("/Volumes/SanDisk/keep.mov", group: g, disposition: .keep)
        let angel = record("/Volumes/SanDisk/angel.mov", group: g, disposition: .extraCopy)
        let filed = record("/Volumes/SanDisk/filed.mov", group: g, disposition: .extraCopy)
        filed.lifecycleStage = .archived
        model.records = [keeper, angel, filed]
        var summary = model.archiveAngel.recommendations
        summary.preparedIDs = [angel.id]
        summary.revision += 1
        model.archiveAngel.publishRecommendations(summary)
        #expect(queue(model).cases.isEmpty)
    }

    @Test func junkClustersLeaveProtectedAndArchivedFilesOut() throws {
        let model = isolatedModel()
        designateFamilyArchive(model)
        func short(_ path: String) -> VideoRecord {
            let r = record(path)
            r.junkScore = 7
            r.junkReasons = ["Very short (1.0s)"]
            return r
        }
        let a = short("/Volumes/SanDisk/a.mov"), b = short("/Volumes/SanDisk/b.mov")
        let filed = short("/Volumes/SanDisk/filed.mov")
        filed.lifecycleStage = .archived
        let decided = short("/Volumes/SanDisk/kept.mov")
        decided.mediaDisposition = .important
        let suggested = short("/Volumes/SanDisk/suggested.mov")
        suggested.mediaDisposition = .suspectedJunk            // the machine's suggestion: nobody has decided yet
        model.records = [a, b, filed, decided, suggested,
                         short("/Volumes/FamilyArchive/loose/x.mov"), short("/Volumes/FamilyArchive/loose/y.mov")]
        let cards = queue(model).cases.filter { $0.kind == .junk }
        let card = try #require(cards.first)
        #expect(cards.count == 1 && card.title == "3 very short clips on SanDisk")
        #expect(Set(card.recordIDs) == [a.id, b.id, suggested.id])
    }

    @Test func hiddenRecordsNeverReachTheBuilder() {
        let model = isolatedModel()
        let g = UUID()
        let purged = record("/Volumes/SanDisk/purged.mov", group: g, disposition: .extraCopy)
        purged.purgedAt = Date()
        model.records = [record("/Volumes/SanDisk/keep.mov", group: g, disposition: .keep), purged]
        let inputs = StewardCaseBuilder.project(model.records, protection: model.stewardProtectionRule())
        #expect(inputs.count == 1)
        #expect(queue(model).cases.isEmpty)
    }

    /// The model-owned cache: nothing is built until the pane has asked,
    /// and an unchanged catalog publishes nothing more.
    @Test func theQueueIsBuiltOnlyOnceThePaneIsShownAndIsEqualityGated() async throws {
        let model = isolatedModel()
        let g = UUID()
        model.records = [record("/Volumes/SanDisk/keep.mov", size: 10, group: g, disposition: .keep),
                         record("/Volumes/SanDisk/copy.mov", size: 10, group: g, disposition: .extraCopy)]
        // The Skip memory the refresh reads: a suite of its own, never Rick's.
        let suite = "steward-tests-\(UUID().uuidString)"
        model.stewardDefaults = try #require(UserDefaults(suiteName: suite))
        defer { model.stewardDefaults.removePersistentDomain(forName: suite) }
        model.scheduleStewardRefresh()
        #expect(model.stewardTask == nil && !model.stewardSnapshot.queue.isBuilt, "no work before the pane appears")

        model.stewardPaneAppeared()
        // The catalog-change debounce may replace the first build with an
        // equal one; wait for whichever lands.
        for _ in 0..<100 where !model.stewardSnapshot.queue.isBuilt {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await model.stewardTask?.value
        #expect(model.stewardSnapshot.queue.isBuilt)
        #expect(model.stewardSnapshot.queue.count(of: .reclaimGroup) == 1)
        #expect(model.stewardSnapshot.publishCount == 1)

        model.scheduleStewardRefresh()
        await model.stewardTask?.value
        #expect(model.stewardSnapshot.publishCount == 1, "an unchanged queue is not re-published")
    }
}
