// DeleteDuplicatesCodex258Round2Tests.swift
// Codex re-review of the delete-safety bundle (cycle #35, 2026-10-03): BLOCK,
// 4 findings (docs/reviews/codex/codex-review-delete-safety-bundle-258-r2-2026-10-03.md).
//
//   R2-1  a Read-only refusal found on the DISK THREAD settled as an
//         ordinary refusal (Review) and was then counted as a survivor
//   R2-2  the removal boundary asked today's marks by STRING only; a mark
//         made during phase two that matches by identity was missed
//   R2-3  drive evidence gathered before a mount change survived it
//   R2-4  the forecast took a copy's drive from its FOLDER; a file symlink
//         onto another device diverged from the run
// plus the reviewer's predicted surviving mutants and the cost of reading
// the Angel's buffer at every copy's turn.
//
// Dimensions: Logic (below) · Scale (2,000 turns over a 50-batch × 100-row
// buffer, explicit budget) · Media matrix N/A (synthetic bytes) · Isolation
// (temp catalog, ledger, plan root and buffer; volume, mount and drive
// identity injected) · Sensor (source pins, comments stripped).
//
// Suite: DeleteDuplicatesCodex258Round2Tests

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_codex258r2_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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

private let fileSize = FileHasher.segmentSize * 2
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 193) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

@MainActor
private func record(_ url: URL, at path: String? = nil, group: UUID, _ disposition: DuplicateDisposition, verified: Bool,
                    write: Bool = true) -> VideoRecord {
    if write { FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes)) }
    let r = VideoRecord()
    r.fullPath = path ?? url.path
    r.filename = (r.fullPath as NSString).lastPathComponent
    r.directory = (r.fullPath as NSString).deletingLastPathComponent
    r.sizeBytes = Int64(fileSize)
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    if verified { r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: fileDigest, byteCount: Int64(fileSize)) }
    return r
}

@Suite("Codex #258 round 2 — holds found on the disk thread, late identity marks, stale drive evidence", .serialized)
@MainActor
struct DeleteDuplicatesCodex258Round2Tests {

    // MARK: R2-1

    /// K, H, A on one drive. H's volume is the marked drive — but only its
    /// IDENTITY says so (catalogued through another name: the string gates
    /// miss it; the disk worker's physical check finds it). H must be LEFT
    /// ALONE as a hold — not refused, not marked Review — and so never
    /// counted for A: only the keeper would remain, A is left alone.
    @Test func aReadOnlyRefusalFoundOnTheDiskThreadIsAHoldAndIsNeverCountedForAnotherCopy() async throws {
        let dir = tempDir("r21"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let marked = scanTarget("/Volumes/TestMarked")
        marked.readOnlyMark = VolumeReadOnlyMark(markedAt: .distantPast, volumeUUID: "TEST-U")
        model.scanTargets = [marked, scanTarget(dir.path)]
        let g = UUID()
        let keeper = record(dir.appendingPathComponent("keeper.mov"), group: g, .keep, verified: true)
        let h = record(dir.appendingPathComponent("h.mov"), group: g, .extraCopy, verified: true)
        let a = record(dir.appendingPathComponent("a.mov"), group: g, .extraCopy, verified: false)
        model.records = [keeper, h, a]
        #expect(model.bulkDeleteRefusal(h) == nil, "fixture: the string gate does not see H")

        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: dir),
                                      planRoot: dir.appendingPathComponent("plans", isDirectory: true))
        await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ ($0 as NSString).lastPathComponent == "h.mov" ? "TEST-U" : "TEST-ELSE" }) {
            await ArchiveVolumeProtection.$mountIdentityProbe.withValue({ _ in nil }) {
                job.start()
                await job.task?.value
            }
        }
        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.id) == [h.id, a.id], "fixture: both were planned, H first")
        let rowH = plan.entries[0], rowA = plan.entries[1]
        #expect(rowH.status == .skipped, "a Read-only refusal found by the worker settled as \(rowH.status): \(rowH.note)")
        #expect(rowH.note.hasPrefix("left alone — ") && rowH.note.contains("which you marked Read only"), Comment(rawValue: rowH.note))
        #expect(h.duplicateDisposition == .extraCopy, "the held copy was marked Review")
        #expect(plan.runScope(deciding: a.id).leftAlone[h.id] != nil, "the run reads H's row as decided on its merits")
        // Keep one (2026-10-09): A goes on the keeper alone — H is never counted.
        #expect(rowA.status == .trashed && rowA.remainingVerifiedCopies == 1,
                "A was decided \(rowA.status) on the strength of the held copy: \(rowA.tierReason ?? rowA.note)")
        #expect(FileManager.default.fileExists(atPath: h.fullPath), "the held copy stays")
    }

    /// The same classification wherever the refusal is found, and for a row
    /// an OLDER run settled as an ordinary refusal for a Read-only mark.
    @Test func aReadOnlyRefusalClassifiesAsAHoldWhereverItWasFound() {
        let dir = tempDir("r21b"); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("h.mov").path
        FileManager.default.createFile(atPath: path, contents: Data(fileBytes))
        // The disk worker's own check, before anything is read or moved.
        let readOnly = ReadOnlyVolumeProtection.provisional(marks: [.init(searchPath: dir.path, volumeUUID: nil)])
        let check = ArchiveRemovalCheck(protection: nil, probe: { _ in nil }, identity: { _ in nil }, readOnly: readOnly)
        let item = DeleteDuplicatesWorkItem(path: path, keeperPath: dir.appendingPathComponent("keeper.mov").path, keeperFilename: "keeper.mov",
                                            keeperFixity: nil, quarantineDirectoryName: "test-quarantine",
                                            tierCandidates: DeletionTierCandidates(), archiveCheck: check)
        let outcome = DeleteDuplicatesDiskWorker.verifyAndQuarantine(item, hooks: .live).outcome
        if case .leftAlone(let reason, _) = outcome {
            #expect(reason == "left alone — lives on \(dir.lastPathComponent), which you marked Read only", Comment(rawValue: reason))
        } else {
            Issue.record("the worker's Read-only refusal is \(outcome), not a hold")
        }

        // A plan written by an earlier build: the row was REFUSED for the mark.
        func entry(_ status: DeleteDuplicatesPlan.EntryStatus, _ note: String) -> DeleteDuplicatesPlan.Entry {
            var e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/TestDrive/\(UUID()).mov", filename: "x.mov", sizeBytes: 1,
                                               keeperID: UUID(), keeperPath: "/Volumes/TestDrive/k.mov", keeperFilename: "k.mov")
            e.status = status
            e.note = note
            return e
        }
        let olderWorker = entry(.refused, "lives on TestMarked, which you marked Read only — nothing moved")
        let olderBoundary = entry(.refused, "is under TestMarked, which you marked Read only — a different drive is mounted there now, so it is left alone — put back, nothing removed")
        let ordinary = entry(.refused, "content differs from keeper k.mov — NOT a duplicate")
        let archive = entry(.refused, "lives on TestArchive, the Master Archive volume, which only archive actions may change — nothing moved")
        let plan = DeleteDuplicatesPlan(volumePath: "/Volumes/TestDrive", catalogLocation: "test", crossVolumeMode: false,
                                        skippedBeforePlan: 0, summaryLine: "", entries: [olderWorker, olderBoundary, ordinary, archive])
        let scope = plan.runScope(deciding: nil)
        #expect(Set(scope.leftAlone.keys) == [olderWorker.id, olderBoundary.id], "a resumed plan counts a row refused for a Read-only mark")
        #expect(scope.decided == [ordinary.id, archive.id])
    }

    // MARK: R2-2

    /// The reviewer's test: no marks when the pair began; a mark made during
    /// phase two that matches the file only by its volume's IDENTITY.
    @Test func aLateIdentityMarkStopsTheRemovalBoundary() async {
        let dir = tempDir("r22"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let g = UUID()
        let copy = record(dir.appendingPathComponent("copy.mov"), group: g, .extraCopy, verified: false)
        model.records = [record(dir.appendingPathComponent("keeper.mov"), group: g, .keep, verified: true), copy]
        // Built at the copy's turn (the probes are captured there, as the
        // pair's own removal check captures them).
        let ask = MasterArchiveDesignation.$volumeUUIDProbe.withValue({ _ in "TEST-U" }) {
            ArchiveVolumeProtection.$mountIdentityProbe.withValue({ _ in nil }) {
                DeleteDuplicatesJob.removalBoundaryHold(model: model, recordID: copy.id, path: copy.fullPath)
            }
        }
        #expect(await Task.detached { ask(copy.fullPath) }.value == nil, "fixture: nothing is marked yet")

        let target = scanTarget("/Volumes/TestMarked")
        target.readOnlyMark = VolumeReadOnlyMark(markedAt: .distantPast, volumeUUID: "TEST-U")
        model.scanTargets = [target]
        #expect(model.bulkDeleteRefusal(forPath: copy.fullPath) == nil, "fixture: by its path the copy is not on the marked drive")
        let note = await Task.detached { ask(copy.fullPath) }.value
        #expect(note == "left alone — lives on TestMarked, which you marked Read only",
                "a mark that matches by identity only was missed at the removal boundary: \(String(describing: note))")
    }

    // MARK: R2-3

    /// The reviewer's schedule: volume X (device P) is cached; X is
    /// unmounted and a volume of device Q takes its st_dev and node. A
    /// gather BEFORE the invalidation lands sees "two drives" (the stale P
    /// and Q). The invalidation lands. The final verdict's re-check must not
    /// keep the phantom drive.
    @Test func driveEvidenceGatheredBeforeAMountChangeDoesNotSurviveIt() {
        let dir = tempDir("r23"); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["keeper.mov", "s1.mov", "reused.mov"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(fileBytes))
        }
        var c = DeletionTierCandidates()
        c.keeperPath = dir.appendingPathComponent("keeper.mov").path
        c.keeperLabel = "keeper"
        c.otherCopies = ["s1.mov", "reused.mov"].map {
            let path = dir.appendingPathComponent($0).path
            return .init(path: path, fixity: ContentFixity.captured(path: path, digest: fileDigest, byteCount: Int64(fileSize)), label: $0)
        }
        let q = DuplicateDrives.Identity(device: 1, kind: .physical, physicalDevice: "test-device-Q")
        let p = DuplicateDrives.Identity(device: 1, kind: .physical, physicalDevice: "test-device-P")
        // Everything really sits on Q; "reused.mov" is answered by the cache.
        let others: @Sendable (String) -> DuplicateDrives.Identity? = { $0.hasSuffix("reused.mov") ? nil : q }

        // (This test's own corner of the process-wide cache.)
        let scope = "test-r23-\(UUID().uuidString)|"
        // 1. The cache learns P for the volume (when X was mounted there)…
        let stale = DuplicateDrives.$cacheScope.withValue(scope) {
            DuplicateDrives.$lookupOverride.withValue({ _, _ in p }) {
                DuplicateDrives.$identityOverride.withValue(others) { DeletionTierFacts.gather(c, digest: fileDigest) }
            }
        }
        #expect(stale.remainingVerifiedCopies == 3 && stale.distinctDriveCount == 2, "fixture: the stale entry adds a phantom drive (\(stale.summary))")
        #expect(DeletionTierDecision.decide(facts: stale).tier == .trash)

        // 2. …the mount change is delivered (every lookup now says Q)…
        DuplicateDrives.resetVolumeCache()
        let after = DuplicateDrives.$cacheScope.withValue(scope) {
            DuplicateDrives.$lookupOverride.withValue({ _, _ in q }) {
                DuplicateDrives.$identityOverride.withValue(others) { stale.recheck() }
            }
        }
        // 3. …and the evidence gathered before it is not trusted.
        #expect(after.distinctDriveCount == 1, "drive evidence from before the mount change survived it: \(after.countedDrives)")
        #expect(DeletionTierDecision.decide(facts: after).tier == .trash)
        #expect(!after.droppedAtBoundary.isEmpty, "the final verdict must re-decide, and say why")
    }

    /// The PRODUCTION cache key (not a key a test hands in): the device
    /// node and the volume's UUID are both part of it, and a volume with no
    /// UUID is never cached. And the real cache, through the lookup seam:
    /// one lookup per volume per generation; a reset moves the generation.
    @Test func theProductionCacheKeyNamesTheNodeAndTheVolume() {
        typealias D = DuplicateDrives
        let key = D.cacheKey(device: 7, node: "/dev/disk7s1", volumeUUID: "TEST-U")
        #expect(key != nil)
        #expect(key != D.cacheKey(device: 7, node: "/dev/disk9s1", volumeUUID: "TEST-U"), "the device node left the cache key")
        #expect(key != D.cacheKey(device: 8, node: "/dev/disk7s1", volumeUUID: "TEST-U"), "st_dev left the cache key")
        #expect(key != D.cacheKey(device: 7, node: "/dev/disk7s1", volumeUUID: "TEST-V"),
                "another volume at a reused number and node would hit the cache")
        #expect(D.cacheKey(device: 7, node: "/dev/disk7s1", volumeUUID: nil) == nil && D.cacheKey(device: 7, node: "/dev/disk7s1", volumeUUID: "") == nil,
                "a volume with no UUID must not be cached")

        // The real lookup path, on this machine's temp volume.
        let path = NSTemporaryDirectory()
        var info = stat()
        guard stat(path, &info) == 0, let uuid = VolumeIdentity.uuid(forPath: path) else { return }
        let device = UInt64(info.st_dev)
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let asked = Count()
        let scope = "test-key-\(UUID().uuidString)|"
        func look(_ volumeUUID: String?) -> D.Identity {
            D.$cacheScope.withValue(scope) {
                D.$lookupOverride.withValue({ _, device in
                    asked.lock.withLock { asked.n += 1 }
                    return .init(device: device, kind: .physical, physicalDevice: "test-device")
                }) { D.liveIdentityCached(forPath: path, device: device, volumeUUID: volumeUUID) }
            }
        }
        let before = D.generation
        _ = look(uuid); _ = look(uuid)
        // (Another suite's run start may empty the cache in between: at most
        // one extra lookup per reset — never one per call.)
        let resets = Int(D.generation &- before)
        #expect(asked.lock.withLock { asked.n } <= 1 + resets, "the lookup is not cached")
        let n = asked.lock.withLock { asked.n }
        _ = look("TEST-ANOTHER-VOLUME")
        #expect(asked.lock.withLock { asked.n } == n + 1, "a different volume at the same number and node was answered from the cache")
        _ = look(nil); _ = look(nil)
        #expect(asked.lock.withLock { asked.n } == n + 3, "a volume with no UUID was cached")
        let generation = D.generation
        D.resetVolumeCache()
        #expect(D.generation != generation, "a reset must move the generation")
        _ = look(uuid)
        #expect(asked.lock.withLock { asked.n } == n + 4, "a reset did not empty the cache")
    }

    /// Facts gathered through a test seam (or built by hand) carry no
    /// generation and are never re-derived; production facts carry it.
    @Test func factsRecordTheGenerationTheyWereGatheredUnder() {
        let dir = tempDir("gen"); defer { try? FileManager.default.removeItem(at: dir) }
        let keeper = dir.appendingPathComponent("keeper.mov").path
        FileManager.default.createFile(atPath: keeper, contents: Data(fileBytes))
        var c = DeletionTierCandidates()
        c.keeperPath = keeper
        let before = DuplicateDrives.generation
        let live = DeletionTierFacts.gather(c, digest: fileDigest)
        #expect(live.driveGeneration != nil && live.driveGeneration! >= before && live.keeperPath == keeper)
        let seamed = DeletionTierFacts.gather(c, digest: fileDigest) { _, _ in .init(key: "A", label: "TestA") }
        #expect(seamed.driveGeneration == nil)
        DuplicateDrives.resetVolumeCache()
        #expect(seamed.recheck() == seamed, "seam-given drives are never asked again")
        let again = live.recheck()
        #expect(again.driveGeneration == DuplicateDrives.generation || again.driveGeneration! > live.driveGeneration!)
        #expect(again.droppedAtBoundary.isEmpty && again.countedDrives.map(\.key) == live.countedDrives.map(\.key),
                "the same drives, asked again, are no reason to re-decide")
    }

    // MARK: The Angel's buffer, read at every turn and every removal

    /// 2,000 plan rows over a buffer of 50 batches × 100 rows: the buffer is
    /// asked at each row's turn — a listing and a stat per batch, the plans
    /// decoded once while nothing changes. And a change is always seen.
    @Test("2,000 turns over a 50-batch × 100-row buffer stay within budget", .timeLimit(.minutes(2)))
    func readingTheBufferAtEveryTurnStaysWithinBudget() throws {
        let root = tempDir("buffer"); defer { try? FileManager.default.removeItem(at: root) }
        var held = Set<UUID>()
        var lastPlan: ArchiveAngelPlan?
        for b in 0..<50 {
            let folder = root.appendingPathComponent(String(format: "batch-test-%03d", b), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var plan = ArchiveAngelPlan(batchDir: folder.path, requestedCount: 100, makeLossless: false)
            plan.status = .ready
            plan.entries = (0..<100).map { i in
                var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/Volumes/TestDrive/\(b)-\(i).mov", filename: "\(b)-\(i).mov",
                                               sizeBytes: 1, durationSeconds: 61, score: 0, evidence: [], proposedName: "\(b)-\(i).mov")
                e.status = .ready
                held.insert(e.id)
                return e
            }
            try ArchiveAngelPlanStore.save(plan)
            lastPlan = plan
        }
        #expect(ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root) == held, "fixture: 5,000 rows held")
        let decodesBefore = ArchiveAngelPlanStore.holdReadingDecodes
        let clock = ContinuousClock()
        let start = clock.now
        var answers = 0
        for _ in 0..<2_000 { answers += ArchiveAngelPlanStore.inFlightRecordIDsCached(bufferRoot: root).count }
        let elapsed = start.duration(to: clock.now)
        print("[angel-buffer-scale] 2,000 readings of 50 batches × 100 rows: \(elapsed)")
        #expect(answers == 2_000 * 5_000)
        #expect(ArchiveAngelPlanStore.holdReadingDecodes - decodesBefore == 1, "an unchanged buffer was decoded again")
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(20)), "2,000 turns took \(elapsed)")

        // A batch that changes is seen at the very next reading.
        var changed = try #require(lastPlan)
        let freed = changed.entries[0].id
        changed.entries[0].status = .skipped
        try ArchiveAngelPlanStore.save(changed)
        #expect(!ArchiveAngelPlanStore.inFlightRecordIDsCached(bufferRoot: root).contains(freed), "a changed batch was answered from the cache")
        // …and so is a batch that appears, and one that goes.
        let folder = root.appendingPathComponent("batch-test-new", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = ArchiveAngelPlan(batchDir: folder.path, requestedCount: 1, makeLossless: false)
        added.status = .ready
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/Volumes/TestDrive/new.mov", filename: "new.mov", sizeBytes: 1,
                                       durationSeconds: 61, score: 0, evidence: [], proposedName: "new.mov")
        e.status = .ready
        added.entries = [e]
        try ArchiveAngelPlanStore.save(added)
        #expect(ArchiveAngelPlanStore.inFlightRecordIDsCached(bufferRoot: root).contains(e.id))
        try FileManager.default.removeItem(at: folder)
        #expect(!ArchiveAngelPlanStore.inFlightRecordIDsCached(bufferRoot: root).contains(e.id))
        #expect(ArchiveAngelPlanStore.inFlightRecordIDsCached(bufferRoot: root) == ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root))
    }

    // MARK: Sensors (code only — never a comment)

    @Test func aSensorCannotBeSatisfiedByAComment() {
        let source = """
        // if let held = archiveRemovalCheck()?.bulkRefusal(forPath: rec.fullPath) {
        let url = "http://example.test//path"   // if (try? trash(url)) != nil
            trash(url) // gone
        """
        let code = SourceTree.strippingComments(source)
        #expect(!code.contains("bulkRefusal") && !code.contains("if (try? trash(url))") && !code.contains("gone"))
        #expect(code.contains("let url = \"http://example.test//path\"") && code.contains("trash(url)"))
    }

    @Test func theRoundTwoFixesAreWhereTheyMustBe() throws {
        let job = try SourceTree.appCode(named: "DeleteDuplicatesJob.swift")
        #expect(job.contains("let outcome: DeleteDuplicatesDiskOutcome = refusal.leavesAlone\n                ? .leftAlone(reason: DuplicateDeletionHold.leftAlonePrefix + refusal.note, facts: DeletionTierFacts())"),
                "the worker's own Read-only refusal is an ordinary refusal again")
        #expect(job.contains("if let captured, captured.leavesAlone {\n") && job.contains("heldNote = DuplicateDeletionHold.leftAlonePrefix + captured.note"),
                "phase two's captured check refuses a Read-only file instead of holding it")
        #expect(job.contains("if let note = word?.holdNote {"))
        let gate = try SourceTree.appCode(named: "VideoScanModel+MasterArchive.swift")
        #expect(gate.components(separatedBy: "var leavesAlone: Bool {").count == 2, "ONE classification of a refusal")
        let check = try SourceTree.appCode(named: "ArchiveVolumeProtection.swift")
        #expect(check.contains("found.refusal.leavesAlone)"))
        let plan = try SourceTree.appCode(named: "DeleteDuplicatesPlan.swift")
        #expect(plan.contains("} else if e.status == .skipped || e.status == .refused, let why = DuplicateDeletionHold.leftAloneWhy(note: e.note) {"))
        #expect(plan.contains("let askDrivesAfresh = driveGeneration != nil"))
        #expect(plan.contains("let generation = DuplicateDrives.generation\n        var resolver = DuplicateDrives.Resolver()"),
                "the generation must be read BEFORE the first lookup of a gather")
        // (The mount observer still moves the generation synchronously, but
        // since codex #258 r3-1 safety does not rest on it — the final
        // verdict asks the drives afresh whatever the generation says — so
        // no sensor pins that ordering any more.)
        let drives = try SourceTree.appCode(named: "DeleteDuplicatesDrives.swift")
        #expect(drives.contains("guard stat(path, &info) == 0 else { return nil }") && !drives.contains("deletingLastPathComponent"),
                "the forecast's drive question stats the folder again")
        var repo = try #require(SourceTree.appSourceURL(named: "DeleteDuplicatesPlan.swift"))
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md").path) {
            repo = repo.deletingLastPathComponent()
        }
        let invariants = try String(contentsOf: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md"), encoding: .utf8)
        #expect(invariants.contains("two network shares backed by one server disk count as two") && invariants.contains("Fusion Drive"))
    }

    // MARK: R2-4

    /// A sibling catalogued at a path that is a FILE symlink onto another
    /// device: the forecast must place it where the run does — both ways.
    @Test func aSymlinkedSiblingFileIsPlacedByTheForecastWhereTheRunPlacesIt() throws {
        let dir = tempDir("r24"); defer { try? FileManager.default.removeItem(at: dir) }
        let volA = dir.appendingPathComponent("volA", isDirectory: true), volB = dir.appendingPathComponent("volB", isDirectory: true)
        for d in [volA, volB] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        // The identity of the RESOLVED file decides (volA = device A, volB = device B).
        let identity: @Sendable (String) -> DuplicateDrives.Identity? = { path in
            path.contains("/volB/") ? .init(device: 8, kind: .physical, physicalDevice: "test-B")
                                    : .init(device: 7, kind: .physical, physicalDevice: "test-A")
        }
        for linkOnA in [true, false] {
            let model = makeModel(dir.appendingPathComponent(linkOnA ? "m1" : "m2", isDirectory: true))
            let g = UUID()
            let keeper = record(volA.appendingPathComponent("keeper-\(linkOnA).mov"), group: g, .keep, verified: true)
            let copy = record(volA.appendingPathComponent("copy-\(linkOnA).mov"), group: g, .extraCopy, verified: false)
            let s1 = record(volA.appendingPathComponent("s1-\(linkOnA).mov"), group: g, .review, verified: true)
            // S2: the catalog knows it at `link`; its bytes are at `real`.
            let (linkDir, realDir) = linkOnA ? (volA, volB) : (volB, volA)
            let real = realDir.appendingPathComponent("real-\(linkOnA).mov"), link = linkDir.appendingPathComponent("test_link-\(linkOnA).mov")
            FileManager.default.createFile(atPath: real.path, contents: Data(fileBytes))
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let s2 = record(link, group: g, .review, verified: true, write: false)
            model.records = [keeper, copy, s1, s2]
            let expected: DeletionTier = .trash   // S2's bytes on B → two drives; on A → one — the Trash either way
            DuplicateDrives.$identityOverride.withValue(identity) {
                let facts = DeletionTierFacts.gather(model.deletionTierCandidates(record: copy, keeper: keeper), digest: fileDigest)
                let run = DeletionTierDecision.decide(facts: facts).tier
                let forecast = model.deleteDuplicatesForecast(onVolume: volA.path).bucket(for: copy.id)
                #expect(run == expected, "the run: \(String(describing: run)) (\(facts.summary))")
                #expect(forecast == .trash,
                        "link on \(linkOnA ? "A" : "B"): the forecast says \(String(describing: forecast)), the run \(String(describing: run))")
            }
        }
    }
}
