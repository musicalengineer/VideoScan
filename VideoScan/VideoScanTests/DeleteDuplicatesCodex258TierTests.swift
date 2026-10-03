// DeleteDuplicatesCodex258TierTests.swift
// Codex review of the delete-safety bundle (GH #258 + Read-only volumes +
// the two-drives rule), cycle #34, 2026-10-03: BLOCK, 11 findings
// (docs/reviews/codex/codex-review-delete-safety-bundle-258-2026-10-03.md).
// One pinning test (or a few) per finding, each red before its fix.
//
//   F1  a copy the run LEAVES ALONE (in use by the Angel, on a Read-only
//       folder of the cleaned drive) was counted as a survivor for another
//       copy — which main never did while it was a pending row
//   F2  a Read-only mark made through an alias / a custom mount point
//       protected only the spelling
//   F3  an import replaced an existing mark's drive identity
//   F4  a FOLDER mark was not found by UUID at removal after a remount
//   F5  Junk Delete / Move to Trash judged every file by the snapshot taken
//       before the first one
//   F6  a hold acquired during phase two's re-read was not asked at the
//       removal boundary
//   F7  a finished Prepare released its hold before the prepared set said
//       so; a batch saved by another route was not seen at a copy's turn;
//       an older disk read could overwrite a newer one
//   F8  one volume keyed two ways (UUID / device) counted as two drives
//   F9  a disk image counted as a drive
//   F10 the forecast took the drive from the path's spelling
//   F11 a sibling on a second drive was not read once three were counted
//
// Dimensions: Logic (below) · Scale N/A (every change is O(family) per row
// or O(1) per file; the 100k selection budgets are pinned in
// DeleteDuplicatesAngelHoldTests / ReadOnlyVolumeTests and re-run) · Media
// matrix N/A (synthetic bytes; no media opened beyond the planner's whole-
// file reads) · Isolation (temp catalog, ledger, plan root and Angel buffer
// per test; volume identity, mount identity and drive identity are injected
// — nothing reads the machine's drives) · Sensor (source pins at the end).
//
// Suites: DeleteDuplicatesCodex258SurvivorTests · DeleteDuplicatesCodex258DrivesTests
//
// This file: F1 and F8–F11 (the tier: who counts as a survivor, and what counts as a drive).

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_codex258_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func scanTarget(_ path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    return t
}

@MainActor
private func dupRecord(path: String, size: Int64, group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

@MainActor
private func setAngel(_ model: VideoScanModel, prepared: Set<UUID> = [], promoted: Set<UUID> = []) {
    var summary = model.archiveAngel.recommendations
    summary.preparedIDs = prepared
    summary.promotedIDs = promoted
    summary.revision += 1
    model.archiveAngel.publishRecommendations(summary)
}

private let fileSize = FileHasher.segmentSize * 2
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 199) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

/// A lock-protected value a hook on a disk thread and the test can share.
private final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline, !condition() { await Task.yield() }
    #expect(condition(), "timed out waiting for: \(what)")
}

/// Two drives cannot be had in one temp folder: R "is on" drive B.
private let secondDrive: @Sendable (String, FileIdentityStamp) -> DeletionTierFacts.Drive = { path, _ in
    path.hasSuffix("/r.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
}

// MARK: - F1 — a copy the run leaves alone is never a new survivor

@Suite("Codex #258 F1 — a held copy of the same run is never counted as a survivor", .serialized)
@MainActor
struct DeleteDuplicatesCodex258SurvivorTests {

    enum Hold: String, CaseIterable { case prepared, promoted, readOnlyFolder }
    enum Fixture: String, CaseIterable { case kah, kahr, kahWithArchive, kha }

    struct Rig {
        let dir: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let a: VideoRecord
        let h: VideoRecord
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// One "drive" (a folder): keeper K (verified), the free copy A, the
    /// copy H that may be held (verified — its stored evidence reproduces),
    /// in the subfolder `Clips` (its own scan target, so it can be marked
    /// Read only). `.kahr` adds a verified ordinary sibling R (a Review
    /// row); `.kahWithArchive` the verified archive copy + sibling.
    private func makeRig(_ fixture: Fixture) -> Rig {
        let dir = tempDir(fixture.rawValue)
        let clips = dir.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let group = UUID()
        func record(_ url: URL, _ disposition: DuplicateDisposition, verified: Bool) -> VideoRecord {
            FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes))
            let r = dupRecord(path: url.path, size: Int64(fileSize), group: group, disposition: disposition)
            if verified { r.contentFixity = ContentFixity.captured(path: url.path, digest: fileDigest, byteCount: Int64(fileSize)) }
            return r
        }
        let model = makeModel(dir)
        model.scanTargets = [scanTarget(dir.path), scanTarget(clips.path)]
        let keeper = record(dir.appendingPathComponent("keeper.mov"), .keep, verified: true)
        let a = record(dir.appendingPathComponent("a.mov"), .extraCopy, verified: false)
        let h = record(clips.appendingPathComponent("h.mov"), .extraCopy, verified: true)
        model.records = fixture == .kha ? [keeper, h, a] : [keeper, a, h]
        if fixture == .kahr { model.records.append(record(dir.appendingPathComponent("r.mov"), .review, verified: true)) }
        if fixture == .kahWithArchive { addVerifiedArchiveFamily(to: model, keeper: keeper) }
        return Rig(dir: dir, model: model, keeper: keeper, a: a, h: h)
    }

    private func apply(_ hold: Hold, to rig: Rig) {
        switch hold {
        case .prepared: setAngel(rig.model, prepared: [rig.h.id])
        case .promoted: setAngel(rig.model, promoted: [rig.h.id])
        case .readOnlyFolder: rig.model.setVolumeReadOnly(true, for: rig.model.scanTargets[1])
        }
    }

    /// 0 = left alone · 1 = the Trash · 2 = deleted outright.
    private func rank(_ status: DeleteDuplicatesPlan.EntryStatus?) -> Int {
        switch status {
        case .skipped?: return 0
        case .trashed?: return 1
        case .deleted?: return 2
        default: return -1
        }
    }

    private func run(_ rig: Rig) async -> DeleteDuplicatesPlan? {
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir),
                                      planRoot: rig.dir.appendingPathComponent("plans", isDirectory: true))
        job.start()
        await job.task?.value
        return job.plan
    }

    /// The finding's second half, end to end: K + A + H on one drive, H in a
    /// prepared batch and verified. Main (H a pending row of the run) counts
    /// K alone and leaves A alone; the branch counted K + H and trashed A.
    @Test func aCopyTheRunLeavesAloneIsNotASurvivorForAnotherCopy() async throws {
        let rig = makeRig(.kah); defer { rig.cleanup() }
        apply(.prepared, to: rig)
        // The forecast says what the run will do — it asks the same rule.
        let forecast = rig.model.deleteDuplicatesForecast(onVolume: rig.dir.path)
        #expect(forecast.bucket(for: rig.a.id) == .leftAlone && forecast.total.files == 1,
                "the forecast promised \(String(describing: forecast.bucket(for: rig.a.id))) on the strength of the held copy")
        let plan = try #require(await run(rig))
        #expect(plan.entries.map(\.id) == [rig.a.id], "the Angel's copy is not a row of the run")
        let row = try #require(plan.entries.first)
        #expect(row.status == .skipped && row.remainingVerifiedCopies == 1,
                "the held copy was counted as a survivor: \(row.status), \(row.tierReason ?? row.note)")
        #expect(row.note.contains("h.mov") && row.note.contains("not counted") && row.note.contains("in use by the Archive Angel"),
                Comment(rawValue: row.note))
        #expect(FileManager.default.fileExists(atPath: rig.a.fullPath) && FileManager.default.fileExists(atPath: rig.h.fullPath))
        #expect(!FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash").path), "nothing went to the Trash")
    }

    /// NO WEAKENING, as a property over identical inputs: the same records,
    /// hold OFF (H is an ordinary row of the run, as on main) and hold ON —
    /// the fate of the OTHER copy is never more permissive with the hold on.
    @Test(arguments: Fixture.allCases, Hold.allCases)
    func holdingACopyNeverMakesAnotherCopysFateMorePermissive(fixture: Fixture, hold: Hold) async throws {
        let off = makeRig(fixture); defer { off.cleanup() }
        let on = makeRig(fixture); defer { on.cleanup() }
        apply(hold, to: on)

        let planOff = try #require(await run(off))
        let planOn = try #require(await run(on))
        let fateOff = rank(planOff.entries.first { $0.id == off.a.id }?.status)
        let fateOn = rank(planOn.entries.first { $0.id == on.a.id }?.status)
        #expect(fateOff >= 0 && fateOn >= 0, "fixture: the free copy was decided in both runs (\(fateOff), \(fateOn))")
        #expect(planOff.entries.contains { $0.id == off.h.id }, "fixture: with the hold off, H is a row of the run — as on main")
        #expect(!planOn.entries.contains { $0.id == on.h.id }, "with the hold on, H is never a row")
        #expect(fateOn <= fateOff,
                "\(fixture.rawValue)/\(hold.rawValue): the hold made the other copy's fate MORE permissive (\(fateOff) → \(fateOn))")
        #expect(FileManager.default.fileExists(atPath: on.h.fullPath), "the held copy itself was removed")
    }

    /// Codex's own fixture: K, A, H on drive A; R, a verified ordinary
    /// sibling, on drive B; H in a prepared batch. Main counts K + R for A
    /// (H is a pending row) → the Trash. The branch counted K + H + R on two
    /// drives → an outright delete. (Two drives cannot be had in one temp
    /// folder: R "is on" B through gather's seam; the candidates are the
    /// job's own — the plan's run scope through THE survivor rule.)
    @Test func withASiblingOnASecondDriveTheHeldCopyNeverEarnsTheOutrightDelete() async throws {
        var tiers: [Bool: DeletionTier?] = [:]
        for held in [false, true] {
            let rig = makeRig(.kahr); defer { rig.cleanup() }
            if held { apply(.prepared, to: rig) }
            let plan = try #require(await rig.model.prepareDuplicateDeletion(onVolume: rig.dir.path))
            #expect(plan.entries.contains { $0.id == rig.h.id } == !held)
            let candidates = rig.model.deletionTierCandidates(record: rig.a, keeper: rig.keeper,
                                                              run: plan.runScope(deciding: rig.a.id))
            #expect(candidates.otherCopies.map(\.label).allSatisfy { $0.contains("r.mov") }, "only R is asked about: \(candidates.otherCopies.map(\.label))")
            #expect(held ? candidates.leftAloneByRun.count == 1 && candidates.alsoInThisRun.isEmpty
                         : candidates.alsoInThisRun.count == 1 && candidates.leftAloneByRun.isEmpty)
            let facts = DeletionTierFacts.gather(candidates, digest: fileDigest, driveOf: secondDrive)
            #expect(facts.remainingVerifiedCopies == 2 && facts.distinctDriveCount == 2, "K + R, on two drives: \(facts.summary)")
            tiers[held] = DeletionTierDecision.decide(facts: facts, preferTrash: false).tier
        }
        #expect(tiers[false] == .some(.trash), "fixture: main's answer is the Trash")
        #expect(tiers[true] == .some(.trash), "with H held, A was decided \(String(describing: tiers[true])) — main says the Trash")
    }

    /// The run's rows, as the rule reads them from the plan: a row skipped
    /// FOR A HOLD (or a Read-only mark) is "left alone" — never a survivor;
    /// a row the tier left alone, or one refused, was decided on its merits.
    @Test func thePlanTellsARowLeftAloneForAHoldFromOneDecidedOnItsMerits() {
        func entry(_ status: DeleteDuplicatesPlan.EntryStatus, _ note: String) -> DeleteDuplicatesPlan.Entry {
            var e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/TestDrive/\(UUID()).mov", filename: "x.mov", sizeBytes: 1,
                                               keeperID: UUID(), keeperPath: "/Volumes/TestDrive/k.mov", keeperFilename: "k.mov")
            e.status = status
            e.note = note
            return e
        }
        let deciding = entry(.verifying, "")
        let pending = entry(.pending, "")
        let heldByAngel = entry(.skipped, DuplicateDeletionHold.inUseByAngel.note)
        let promoted = entry(.skipped, DuplicateDeletionHold.promotedArchiveCopy.note)
        let readOnly = entry(.skipped, "left alone — lives on TestDrive, which you marked Read only")
        let byTier = entry(.skipped, "only 1 verified copy would remain — left alone (1 verified remain: keeper on TestDrive)")
        let refused = entry(.refused, "content differs from keeper k.mov — NOT a duplicate")
        let plan = DeleteDuplicatesPlan(volumePath: "/Volumes/TestDrive", catalogLocation: "test", crossVolumeMode: false,
                                        skippedBeforePlan: 0, summaryLine: "",
                                        entries: [deciding, pending, heldByAngel, promoted, readOnly, byTier, refused])
        let scope = plan.runScope(deciding: deciding.id)
        #expect(scope.volumePath == "/Volumes/TestDrive")
        #expect(scope.pending == [pending.id], "the row being decided is never listed")
        #expect(scope.leftAlone == [heldByAngel.id: "in use by the Archive Angel", promoted.id: "it is a promoted archive copy",
                                    readOnly.id: "lives on TestDrive, which you marked Read only"])
        #expect(scope.decided == [byTier.id, refused.id])
        #expect(plan.runScope(deciding: nil).pending == [deciding.id, pending.id])
    }

    /// THE rule, member by member (the table in its doc comment).
    @Test func theSurvivorRuleMemberByMember() {
        let model = makeModel(tempDir("rule"))
        let drive = "/Volumes/TestCleaned", other = "/Volumes/TestOther", clips = "/Volumes/TestCleaned/Clips"
        model.scanTargets = [scanTarget(drive), scanTarget(clips), scanTarget(other)]
        let g = UUID()
        func member(_ path: String, _ disposition: DuplicateDisposition) -> VideoRecord {
            dupRecord(path: path, size: 1, group: g, disposition: disposition)
        }
        let pending = member("\(drive)/pending.mov", .extraCopy)
        let skippedForHold = member("\(drive)/held-row.mov", .extraCopy)
        let decided = member("\(drive)/decided.mov", .extraCopy)
        let heldNow = member("\(drive)/held-now.mov", .extraCopy)
        let onReadOnlyFolder = member("\(clips)/readonly.mov", .extraCopy)
        let neverPlanned = member("\(drive)/never-planned.mov", .extraCopy)
        let review = member("\(drive)/review.mov", .review)
        let elsewhere = member("\(other)/elsewhere.mov", .extraCopy)
        let heldElsewhere = member("\(other)/held-elsewhere.mov", .extraCopy)
        model.records = [pending, skippedForHold, decided, heldNow, onReadOnlyFolder, neverPlanned, review, elsewhere, heldElsewhere]
        setAngel(model, prepared: [heldNow.id, heldElsewhere.id])
        model.scanTargets[1].readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)

        var run = DuplicateRunScope(volumePath: drive)
        run.pending = [pending.id]
        run.leftAlone = [skippedForHold.id: "in use by the Archive Angel"]
        run.decided = [decided.id]
        let rule = model.duplicateSurvivorStandingRule(in: run)
        #expect(rule(pending) == .pendingRow)
        #expect(rule(skippedForHold) == .leftAlone("in use by the Archive Angel"))
        #expect(rule(decided) == .bySiblingRules, "a row the run decided on its merits counts by its evidence — as on main")
        #expect(rule(heldNow) == .leftAlone("in use by the Archive Angel"))
        #expect(rule(onReadOnlyFolder) == .leftAlone("on a drive marked Read only"))
        #expect(rule(neverPlanned) == .leftAlone("not a row of this run"),
                "an extra copy on the cleaned drive that the run never planned may be the next run's row")
        #expect(rule(review) == .bySiblingRules, "a Review row was never a row of the run on main either")
        #expect(rule(elsewhere) == .bySiblingRules && rule(heldElsewhere) == .bySiblingRules,
                "another drive's copies — held or not, Read only or not — count by their evidence when THIS drive is cleaned")

        // Main never planned a Master-Archive-protected extra either — and counted it.
        model.masterArchive = MasterArchiveDesignation(targetPath: drive, rootPath: "\(drive)/Test_Family_Archive", volumeUUID: nil)
        let protected = member("\(drive)/loose.mov", .extraCopy)
        model.records.append(protected)
        #expect(model.duplicateSurvivorStandingRule(in: run)(protected) == .bySiblingRules)
    }

    /// The steward's proof for the same fixture is the run's answer — the
    /// card asks the planner's own rule, with the run's own drive counting.
    @Test func theStewardsProofEqualsTheRunForTheHeldCopyAndTwoDriveFixtures() async throws {
        for (fixture, twoDrives) in [(Fixture.kah, false), (.kahr, false), (.kahr, true)] {
            let rig = makeRig(fixture); defer { rig.cleanup() }
            apply(.prepared, to: rig)
            var driveOf: ((String, FileIdentityStamp) -> DeletionTierFacts.Drive)?
            if twoDrives { driveOf = { secondDrive($0, $1) } }
            // The run.
            let plan = try #require(await rig.model.prepareDuplicateDeletion(onVolume: rig.dir.path))
            let candidates = rig.model.deletionTierCandidates(record: rig.a, keeper: rig.keeper, run: plan.runScope(deciding: rig.a.id))
            let facts = DeletionTierFacts.gather(candidates, digest: fileDigest, driveOf: driveOf)
            let run = DeletionTierDecision.decide(facts: facts, preferTrash: false)
            // The card.
            let inputs = StewardCaseBuilder.project(rig.model.records, protection: rig.model.stewardProtectionRule())
            let queue = StewardCaseBuilder.build(inputs: inputs, volumes: AnalyzeCoverageCalculator.volumeFacts(rig.model.scanTargets),
                                                 mountedRoots: ["/"], alsoCleanUpWorkingCopies: false)
            let card = try #require(queue.cases.first { $0.kind == .reclaimGroup }, "no Reclaim set card for \(fixture.rawValue)")
            let prepared = try #require(StewardEvidenceBuilder.prepare(model: rig.model, for: card))
            let question = try #require(prepared.questions.first { $0.copyID == rig.a.id })
            #expect(!prepared.questions.contains { $0.copyID == rig.h.id }, "the held copy is never proposed")
            let proof = StewardEvidenceBuilder.proof(question, preferTrash: false, driveOf: driveOf)
            #expect(proof.tier == run.tier && proof.remaining == run.remainingVerifiedCopies,
                    "\(fixture.rawValue)\(twoDrives ? " on two drives" : ""): the card says \(String(describing: proof.tier)) with \(proof.remaining) remaining, the run \(String(describing: run.tier)) with \(run.remainingVerifiedCopies)")
            #expect(proof.readsFirst == 0 && proof.tierIfTheyMatch == run.tier, "no read stands between the card and the decision here")
            #expect(run.tier == (fixture == .kah ? nil : .trash), "fixture: \(String(describing: run.tier))")
        }
    }

    /// Sensor: the job, the forecast and the steward all hand the run to
    /// the ONE rule; nobody builds a pending set of their own.
    @Test func everyCounterOfSurvivorsAsksTheOneRule() throws {
        let job = try SourceTree.appSource(named: "DeleteDuplicatesJob.swift")
        #expect(job.contains("run: current.runScope(deciding: entry.id))"), "the job no longer hands its run to the survivor rule")
        #expect(!job.contains("excluding: alsoPending"), "the job counts survivors by a pending set of its own again")
        let model = try SourceTree.appSource(named: "VideoScanModel+Duplicates.swift")
        #expect(model.components(separatedBy: "func duplicateSurvivorStandingRule(").count == 2, "exactly one definition")
        #expect(model.contains("let standing = run.map { duplicateSurvivorStandingRule(in: $0) }"))
        #expect(model.contains("if let held = hold(m) { return .leftAlone(held.why) }")
                && model.contains("case .readOnlyVolume?, .readOnlyVolumeDifferentDrive?: return .leftAlone("))
        let forecast = try SourceTree.appSource(named: "DeleteDuplicatesForecast.swift")
        #expect(forecast.contains("duplicateSurvivorStandingRule(in: $0)") && forecast.contains("if copy.leftAloneByRun { continue }"))
        #expect(forecast.contains("run: plan.runScope(deciding: nil)"))
        let steward = try SourceTree.appSource(named: "StewardEvidence.swift")
        #expect(steward.contains("run: DuplicateRunScope(volumePath: row.driveRoot, pending: sameRun)"))
    }
}

// MARK: - F8, F11 — drives

@Suite("Codex #258 F8–F11 — what counts as a second drive", .serialized)
@MainActor
struct DeleteDuplicatesCodex258DrivesTests {

    private func candidates(in dir: URL, verified: [String], unverified: [String] = [],
                            stamp: (String) -> ContentFixity?) -> DeletionTierCandidates {
        var c = DeletionTierCandidates()
        c.keeperPath = dir.appendingPathComponent("keeper.mov").path
        c.keeperLabel = "keeper"
        c.otherCopies = verified.map { .init(path: dir.appendingPathComponent($0).path, fixity: stamp($0), label: $0) }
            + unverified.map { .init(path: dir.appendingPathComponent($0).path, fixity: nil, label: $0) }
        return c
    }

    private func write(_ names: [String], in dir: URL) {
        for name in names { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(fileBytes)) }
    }

    /// F8: three survivors on ONE volume; the keeper's capture returns no
    /// volume UUID, the siblings' does. One drive — the Trash.
    @Test func oneVolumeKeyedTwoWaysIsOneDrive() {
        let dir = tempDir("f8"); defer { try? FileManager.default.removeItem(at: dir) }
        write(["keeper.mov", "s1.mov", "s2.mov"], in: dir)
        let facts = VolumeIdentity.$resolverOverride.withValue({ $0.hasSuffix("keeper.mov") ? nil : "TEST-U" }) {
            let c = candidates(in: dir, verified: ["s1.mov", "s2.mov"]) { name in
                ContentFixity.captured(path: dir.appendingPathComponent(name).path, digest: fileDigest, byteCount: Int64(fileSize))
            }
            return DeletionTierFacts.gather(c, digest: fileDigest)
        }
        #expect(facts.remainingVerifiedCopies == 3, "fixture: keeper + two verified siblings (\(facts.summary))")
        #expect(facts.distinctDriveCount == 1, "one volume counted as \(facts.distinctDriveCount) drives: \(facts.countedDrives)")
        #expect(DeletionTierDecision.decide(facts: facts, preferTrash: false).tier == .trash)
    }

    /// F9: keeper + sibling on drive A; the third verified sibling sits in a
    /// mounted DISK IMAGE (another volume identity — whose backing file may
    /// be on A). It counts as a copy, never as a second drive. So does a
    /// volume whose kind cannot be established. A network volume is a drive.
    @Test func aDiskImageOrAnUnidentifiedVolumeNeverAddsADrive() {
        let dir = tempDir("f9"); defer { try? FileManager.default.removeItem(at: dir) }
        write(["keeper.mov", "s1.mov", "third.mov"], in: dir)
        let c = candidates(in: dir, verified: ["s1.mov", "third.mov"]) { name in
            ContentFixity.captured(path: dir.appendingPathComponent(name).path, digest: fileDigest, byteCount: Int64(fileSize))
        }
        func facts(third: DuplicateDrives.VolumeKind, keeper: DuplicateDrives.VolumeKind = .physical) -> DeletionTierFacts {
            DuplicateDrives.$identityOverride.withValue({ path in
                if path.hasSuffix("third.mov") { return .init(device: 9_001, kind: third) }
                return .init(device: 7, kind: path.hasSuffix("keeper.mov") ? keeper : .physical)
            }) { DeletionTierFacts.gather(c, digest: fileDigest) }
        }
        func tier(_ f: DeletionTierFacts) -> DeletionTier? { DeletionTierDecision.decide(facts: f, preferTrash: false).tier }

        let image = facts(third: .diskImage)
        #expect(image.remainingVerifiedCopies == 3, "a copy in a disk image still counts as a COPY (\(image.summary))")
        #expect(image.distinctDriveCount == 1, "a disk image counted as a second drive: \(image.countedDrives)")
        #expect(tier(image) == .trash)
        let unidentified = facts(third: .unknown)
        #expect(unidentified.remainingVerifiedCopies == 3 && unidentified.distinctDriveCount == 1 && tier(unidentified) == .trash,
                "a volume whose kind cannot be established added a drive")
        // What DOES count: another physical volume, and a network volume.
        #expect(facts(third: .physical).distinctDriveCount == 2 && tier(facts(third: .physical)) == .permanent)
        #expect(facts(third: .network).distinctDriveCount == 2 && tier(facts(third: .network)) == .permanent)
        // The KEEPER in a disk image, both siblings on one physical drive: one drive.
        let keeperInImage = DuplicateDrives.$identityOverride.withValue({ path in
            path.hasSuffix("keeper.mov") ? .init(device: 9_001, kind: .diskImage) : .init(device: 7, kind: .physical)
        }) { DeletionTierFacts.gather(c, digest: fileDigest) }
        #expect(keeperInImage.remainingVerifiedCopies == 3 && keeperInImage.distinctDriveCount == 1 && tier(keeperInImage) == .trash)
        // The row says why three copies did not earn the outright delete.
        let reason = DeletionTierDecision.decide(facts: image, preferTrash: false).reason
        #expect(reason.contains("a disk image is not a second drive"), Comment(rawValue: reason))
        // At the removal boundary nothing is ever added: the copy on the
        // second drive changes → its drive goes with it.
        let two = facts(third: .physical)
        try? Data([1, 2, 3]).write(to: dir.appendingPathComponent("third.mov"))
        let after = two.recheck()
        #expect(after.remainingVerifiedCopies == 2 && after.distinctDriveCount == 1 && !after.droppedAtBoundary.isEmpty)
    }

    /// F9: how a disk image is recognised — what DiskArbitration says about
    /// the volume's device (measured 2026-10-03: .dmg/APFS, .dmg/HFS+,
    /// .sparsebundle and a RAM disk all read model "Disk Image", protocol
    /// "Virtual Interface"). Refuse over guess: nothing said = unknown.
    @Test func whatTheSystemSaysAboutTheDeviceDecidesTheKind() {
        typealias D = DuplicateDrives
        #expect(D.kind(model: "Disk Image", deviceProtocol: "Virtual Interface") == .diskImage)
        #expect(D.kind(model: "Disk Image", deviceProtocol: nil) == .diskImage)
        #expect(D.kind(model: nil, deviceProtocol: "Virtual Interface") == .diskImage)
        #expect(D.kind(model: "APPLE SSD AP1024Z", deviceProtocol: "Apple Fabric") == .physical)
        #expect(D.kind(model: "d2 Professional", deviceProtocol: "USB") == .physical)
        #expect(D.kind(model: nil, deviceProtocol: nil) == .unknown && D.kind(model: " ", deviceProtocol: "") == .unknown)
        #expect(D.VolumeKind.physical.addsADrive && D.VolumeKind.network.addsADrive)
        #expect(!D.VolumeKind.diskImage.addsADrive && !D.VolumeKind.unknown.addsADrive)
        #expect(D.key(device: 42) == "dev:42")
        // The live probe, on this machine's own temp folder and on a path
        // that is not there: it answers, and never guesses "a drive".
        #expect(D.liveKind(forPath: NSTemporaryDirectory()) != .network)
        #expect(D.liveKind(forPath: "/test_codex258_no_such_folder_\(UUID().uuidString)") == .unknown)
        var resolver = D.Resolver()
        #expect(resolver.drive(forPath: "/test_codex258_no_such_folder/a.mov") == nil, "a folder that cannot be stat'ed has no drive")
        let here = resolver.drive(forPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("a.mov"))
        #expect(here != nil && here?.key.isEmpty == false)
    }

    /// Sensors: ONE question about drives, asked by the run, the prover,
    /// the steward and the forecast; no path-spelled drive anywhere.
    @Test func everyoneAsksTheOneResolverWhereACopySits() throws {
        let plan = try SourceTree.appSource(named: "DeleteDuplicatesPlan.swift")
        #expect(plan.contains("seam?(path, stamp) ?? resolver.drive(path: path, stamp: stamp)"))
        #expect(!plan.contains("\"uuid:\""), "a drive is keyed by the volume UUID again — one volume could be keyed two ways")
        #expect(plan.contains("guard drive.kind.addsADrive else {"), "every counted copy's volume adds a drive again")
        for file in ["DeleteDuplicatesSiblingProof.swift", "StewardEvidence.swift"] {
            #expect(try SourceTree.appSource(named: file).contains("seam?(path, stamp) ?? resolver.drive(path: path, stamp: stamp)"), "\(file)")
        }
        let forecast = try SourceTree.appSource(named: "DeleteDuplicatesForecast.swift")
        #expect(forecast.contains("drives.drive(forPath: r.fullPath), d.kind.addsADrive"), "the forecast no longer asks the run's resolver")
        #expect(!forecast.contains("\"boot\"") && !forecast.contains("static func drive(ofPath"), "the forecast reads a drive off the path's spelling again")
        let drives = try SourceTree.appSource(named: "DeleteDuplicatesDrives.swift")
        #expect(drives.contains("var addsADrive: Bool { self == .physical || self == .network }"))
        var repo = try #require(SourceTree.appSourceURL(named: "DeleteDuplicatesPlan.swift"))
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md").path) {
            repo = repo.deletingLastPathComponent()
        }
        let invariants = try String(contentsOf: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md"), encoding: .utf8)
        #expect(invariants.contains("a mounted disk image") && invariants.contains("a network volume (one drive per server + share)")
                && invariants.contains("APFS volumes in one container"))
    }

    /// F10: the forecast asks the SAME question the run asks about where a
    /// copy sits — never the path's spelling. Two volumes mounted outside
    /// /Volumes are two drives; one volume reached through a symlink is one.
    @Test func theForecastCountsDrivesAsTheRunDoes() throws {
        let dir = tempDir("f10"); defer { try? FileManager.default.removeItem(at: dir) }
        let mnt = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir)
        let model = makeModel(dir)
        let group = UUID()
        func record(_ url: URL, _ disposition: DuplicateDisposition, verified: Bool, at path: String? = nil) -> VideoRecord {
            FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes))
            let r = dupRecord(path: path ?? url.path, size: Int64(fileSize), group: group, disposition: disposition)
            if verified { r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: fileDigest, byteCount: Int64(fileSize)) }
            return r
        }
        let keeper = record(dir.appendingPathComponent("keeper.mov"), .keep, verified: true)
        let copy = record(dir.appendingPathComponent("copy.mov"), .extraCopy, verified: false)
        let near = record(dir.appendingPathComponent("near.mov"), .review, verified: true)
        // Cataloged THROUGH the symlink — the same volume.
        let aliased = record(dir.appendingPathComponent("aliased.mov"), .review, verified: true,
                             at: dir.appendingPathComponent("link/aliased.mov").path)
        model.records = [keeper, copy, near, aliased]

        func both(_ override: @escaping @Sendable (String) -> DuplicateDrives.Identity?)
            -> (forecast: DeleteDuplicatesForecast.Bucket?, run: DeletionTier?) {
            DuplicateDrives.$identityOverride.withValue(override) {
                let forecast = model.deleteDuplicatesForecast(onVolume: dir.path).bucket(for: copy.id)
                let candidates = model.deletionTierCandidates(record: copy, keeper: keeper)
                let facts = DeletionTierFacts.gather(candidates, digest: fileDigest)
                return (forecast, DeletionTierDecision.decide(facts: facts, preferTrash: false).tier)
            }
        }
        // One volume, one of its files reached through a symlink: one drive.
        let oneVolume = both { _ in .init(device: 7, kind: .physical) }
        #expect(oneVolume.run == .trash && oneVolume.forecast == .trash, "\(oneVolume)")

        // A second volume mounted OUTSIDE /Volumes (here: under mnt/).
        let far = record(mnt.appendingPathComponent("far.mov"), .review, verified: true)
        model.records.append(far)
        let twoVolumes = both { path in .init(device: path.contains("/mnt/") ? 8 : 7, kind: .physical) }
        #expect(twoVolumes.run == .permanent, "fixture: the run sees two drives (\(twoVolumes))")
        #expect(twoVolumes.forecast == .permanent,
                "the forecast (\(String(describing: twoVolumes.forecast))) disagrees with the run about where the copies sit")
        // …and a disk image there is not a drive, for the forecast either.
        let image = both { path in .init(device: path.contains("/mnt/") ? 8 : 7, kind: path.contains("/mnt/") ? .diskImage : .physical) }
        #expect(image.run == .trash && image.forecast == .trash, "\(image)")
    }

    /// F11: three are counted on ONE drive; an unverified sibling sits on a
    /// SECOND drive. Reading it is what would earn the outright delete.
    @Test func aSiblingOnASecondDriveIsWorthReadingEvenWithThreeCounted() {
        #expect(SiblingProver.worthReading(count: 3, drives: ["A"], countsArchiveCopy: false, candidateDrive: "B", goal: 3))
        #expect(SiblingProver.worthReading(count: 5, drives: ["A"], countsArchiveCopy: false, candidateDrive: "B", goal: 3))
        #expect(!SiblingProver.worthReading(count: 3, drives: ["A"], countsArchiveCopy: false, candidateDrive: "A", goal: 3),
                "a fourth copy on the same drive changes nothing")
        #expect(!SiblingProver.worthReading(count: 3, drives: ["A", "B"], countsArchiveCopy: false, candidateDrive: "C", goal: 3),
                "already permanent: no read")
        #expect(!SiblingProver.worthReading(count: 3, drives: ["A"], countsArchiveCopy: true, candidateDrive: "B", goal: 3),
                "the archive copy is counted: already permanent")
        #expect(!SiblingProver.worthReading(count: 3, drives: ["A"], countsArchiveCopy: false, candidateDrive: "B", goal: 2),
                "Prefer the Trash: nothing can lift the tier")
    }

    @Test func theRunReadsTheSecondDriveSiblingAndTheForecastSaysItWill() throws {
        let dir = tempDir("f11"); defer { try? FileManager.default.removeItem(at: dir) }
        write(["keeper.mov", "s1.mov", "s2.mov", "far.mov"], in: dir)
        var c = candidates(in: dir, verified: ["s1.mov", "s2.mov"], unverified: ["far.mov"]) { name in
            ContentFixity.captured(path: dir.appendingPathComponent(name).path, digest: fileDigest, byteCount: Int64(fileSize))
        }
        let driveOf: (String, FileIdentityStamp) -> DeletionTierFacts.Drive = { path, _ in
            path.hasSuffix("far.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        let before = DeletionTierFacts.gather(c, digest: fileDigest, driveOf: driveOf)
        #expect(before.remainingVerifiedCopies == 3 && DeletionTierDecision.decide(facts: before, preferTrash: false).tier == .trash)
        let reads = SiblingProver.prove(&c, digest: fileDigest,
                                        allowance: .init(goal: 3, readablePaths: Set(c.otherCopies.map(\.path))),
                                        hooks: .live, driveOf: driveOf)
        #expect(reads.map(\.result) == [.matches], "the sibling on the second drive was not read: \(reads)")
        let after = DeletionTierFacts.gather(c, digest: fileDigest, driveOf: driveOf)
        #expect(after.remainingVerifiedCopies == 4 && after.distinctDriveCount == 2)
        #expect(DeletionTierDecision.decide(facts: after, preferTrash: false).tier == .permanent)

        // The job reserves the sibling's drive for that read…
        c.otherCopies[2].fixity = nil
        let keeperFixity = ContentFixity.captured(path: c.keeperPath, digest: fileDigest, byteCount: Int64(fileSize))
        #expect(DeleteDuplicatesJob.siblingsThatMayNeedReading(c, keeperDigest: keeperFixity, goal: 3) == [c.otherCopies[2].path],
                "no drive is reserved for the read that could earn the outright delete")
        #expect(DeleteDuplicatesJob.siblingsThatMayNeedReading(c, keeperDigest: keeperFixity, goal: 2).isEmpty, "Prefer the Trash")

        // …and the forecast says so: the Trash as things stand, one read,
        // and it may become an outright delete.
        typealias F = DeleteDuplicatesForecast
        let g = UUID(), keeper = UUID(), row = UUID(), s1 = UUID(), s2 = UUID(), far = UUID()
        func copy(_ id: UUID, _ digest: String?, _ drive: String) -> F.Copy {
            .init(id: id, sizeBytes: 10, digest: digest, online: true, isArchive: false, archiveDigest: nil, drive: drive)
        }
        let forecast = F.compute(.init(rows: [.init(id: row, sizeBytes: 10, digest: "d", keeperID: keeper, groupID: g)],
                                       copies: [keeper: copy(keeper, "d", "a"), row: copy(row, "d", "a"), s1: copy(s1, "d", "a"),
                                                s2: copy(s2, "d", "a"), far: copy(far, nil, "b")],
                                       members: [g: [keeper, row, s1, s2, far]], preferTrash: false))
        #expect(forecast.bucket(for: row) == .trash && forecast.siblingReads == 1 && forecast.trashMayBecomePermanent == 1,
                "forecast: \(String(describing: forecast.bucket(for: row))), \(forecast.siblingReads) reads, \(forecast.trashMayBecomePermanent) may become permanent")
    }
}
