// DeleteDuplicatesCodex258Round3Tests.swift
// Codex round 3 on the delete-safety bundle (cycle #36, 2026-10-03): BLOCK,
// 3 findings — one disease: a CACHE feeding a safety decision.
//
// THE PRINCIPLE (MOPS-2): at the final verdict immediately before a
// removal, nothing comes from a cache. Drive topology, the Archive Angel's
// holds and the Read-only marks are each read FRESH there. Caches serve
// forecasts, displays and the per-turn pre-checks only.
//
//   R3-1  drive topology came from the cache until a mount notification
//   R3-2  the buffer-reading cache could conceal a changed plan
//   R3-3  the code-only sensors kept `/* … */` comments
//
// Dimensions: Logic (below) · Scale (the uncached boundary reads: budget
// tests for the buffer and for the topology lookup) · Media matrix N/A ·
// Isolation (temp catalog, ledger, plan root, buffer; identities injected)
// · Sensor (the principle itself, code only).
//
// Suite: DeleteDuplicatesCodex258Round3Tests

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_codex258r3_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 191) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

@MainActor
private func record(_ url: URL, group: UUID, _ disposition: DuplicateDisposition, verified: Bool) -> VideoRecord {
    FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes))
    let r = VideoRecord()
    r.fullPath = url.path
    r.filename = url.lastPathComponent
    r.directory = url.deletingLastPathComponent().path
    r.sizeBytes = Int64(fileSize)
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    if verified { r.contentFixity = ContentFixity.captured(path: url.path, digest: fileDigest, byteCount: Int64(fileSize)) }
    return r
}

private func readyBatch(in root: URL, name: String, ids: [UUID]) throws -> ArchiveAngelPlan {
    let folder = root.appendingPathComponent("batch-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var plan = ArchiveAngelPlan(batchDir: folder.path, requestedCount: ids.count, makeLossless: false)
    plan.status = .ready
    plan.entries = ids.enumerated().map { i, id in
        var e = ArchiveAngelPlan.Entry(id: id, sourcePath: "/Volumes/TestDrive/\(name)-\(i).mov", filename: "\(name)-\(i).mov",
                                       sizeBytes: 1, durationSeconds: 61, score: 0, evidence: [], proposedName: "\(name)-\(i).mov")
        e.status = .ready
        return e
    }
    try ArchiveAngelPlanStore.save(plan)
    return plan
}

@Suite("Codex #258 round 3 — at the final verdict nothing comes from a cache", .serialized)
@MainActor
struct DeleteDuplicatesCodex258Round3Tests {

    // MARK: R3-1

    /// The disk was re-enumerated; the notification has NOT arrived (no
    /// reset, same generation). The cache still says device P for one
    /// volume; its neighbours are looked up now and say Q. The final
    /// verdict's re-check asks afresh and finds ONE drive.
    @Test func theFinalVerdictAsksTheDrivesAfreshBeforeAnyNotification() {
        let dir = tempDir("r31"); defer { try? FileManager.default.removeItem(at: dir) }
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
        let others: @Sendable (String) -> DuplicateDrives.Identity? = { $0.hasSuffix("reused.mov") ? nil : q }
        let scope = "test-r31-\(UUID().uuidString)|"
        // The cache learns P…
        let warm = DuplicateDrives.$cacheScope.withValue(scope) {
            DuplicateDrives.$lookupOverride.withValue({ _, _ in p }) {
                DuplicateDrives.$identityOverride.withValue(others) { DeletionTierFacts.gather(c, digest: fileDigest) }
            }
        }
        #expect(warm.distinctDriveCount == 2, "fixture: P (cached) and Q")
        // …the device now answers Q; nothing was reset.
        let (gathered, checked) = DuplicateDrives.$cacheScope.withValue(scope) {
            DuplicateDrives.$lookupOverride.withValue({ _, _ in q }) {
                DuplicateDrives.$identityOverride.withValue(others) {
                    let facts = DeletionTierFacts.gather(c, digest: fileDigest)
                    return (facts, facts.recheck())
                }
            }
        }
        #expect(gathered.distinctDriveCount == 2 || gathered.distinctDriveCount == 1,
                "the per-turn gather may be served from the cache — it is advisory")
        #expect(checked.distinctDriveCount == 1, "the final verdict trusted a cached device path: \(checked.countedDrives)")
        #expect(DeletionTierDecision.decide(facts: checked, preferTrash: false).tier == .trash)
    }

    // MARK: R3-2

    /// A plan.json rewritten IN PLACE (same inode, same size) with its
    /// modification time put back: the old fingerprint could not see it.
    /// The boundary's reading of the buffer is uncached and sees the record
    /// the batch now holds; and the cache's fingerprint includes ctime.
    @Test func aPlanRewrittenInPlaceIsSeenAtTheRemovalBoundary() async throws {
        let dir = tempDir("r32"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        var env = AngelEnvironment.app
        env.bufferRoot = dir.appendingPathComponent("Buffer", isDirectory: true)
        env.evidenceDirectory = dir.appendingPathComponent("evidence", isDirectory: true)
        env.policyOverrideURL = dir.appendingPathComponent("no-policy.json")
        env.isTestHost = true
        model.archiveAngel = ArchiveAngel(model: model, environment: env)
        let root = env.bufferRoot
        let outgoing = UUID(), incoming = UUID()
        let plan = try readyBatch(in: root, name: "rewrite", ids: [outgoing])
        // Warm every cache there is.
        await model.archiveAngel.refreshRecordIDsInBatchesOnDisk()
        #expect(model.archiveAngel.recordIDsInBatchesOnDisk == [outgoing])
        let fingerprint = ArchiveAngelPlanStore.bufferFingerprint(bufferRoot: root)

        // The in-place rewrite (UUID strings have one length), mtime restored.
        let url = plan.planURL
        var before = stat()
        try #require(stat(url.path, &before) == 0)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: outgoing.uuidString, with: incoming.uuidString)
        let bytes = Data(text.utf8)
        try #require(bytes.count == Int(before.st_size))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: bytes)
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        try #require(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        var after = stat()
        try #require(stat(url.path, &after) == 0)
        #expect(after.st_ino == before.st_ino && after.st_size == before.st_size
                && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                "fixture: same inode, size and modification time")

        // The boundary's question (asked on a disk thread).
        let inBatch = model.archiveAngel.recordInBatchOnDiskFreshProbe()
        #expect(await Task.detached { inBatch(incoming) }.value == .held, "the removal boundary did not see the record the batch now holds")
        #expect(await Task.detached { inBatch(outgoing) }.value == .free)
        // The pre-check's cache notices too: ctime is part of the fingerprint.
        #expect(ArchiveAngelPlanStore.bufferFingerprint(bufferRoot: root) != fingerprint, "the fingerprint cannot see an in-place rewrite")
        #expect(ArchiveAngelPlanStore.inFlightRecordIDsCached(bufferRoot: root) == [incoming])
    }

    // MARK: The boundary's costs (it runs once per removal, off the main actor)

    @Test("The uncached boundary reads stay within budget", .timeLimit(.minutes(2)))
    func theUncachedBoundaryReadsStayWithinBudget() throws {
        // The buffer: 50 batches × 100 rows, every plan.json read and decoded.
        let root = tempDir("cost"); defer { try? FileManager.default.removeItem(at: root) }
        var held = Set<UUID>()
        for b in 0..<50 {
            let ids = (0..<100).map { _ in UUID() }
            held.formUnion(ids)
            _ = try readyBatch(in: root, name: String(format: "cost-%03d", b), ids: ids)
        }
        let clock = ContinuousClock()
        var start = clock.now
        let read = ArchiveAngelPlanStore.inFlightRecordIDsFresh(bufferRoot: root)
        let bufferTime = start.duration(to: clock.now)
        #expect(read == .ids(held))
        // The topology: one statfs + one DiskArbitration description per volume.
        var info = stat()
        try #require(stat(root.path, &info) == 0)
        start = clock.now
        var kinds = Set<String>()
        for _ in 0..<100 { kinds.insert(DuplicateDrives.liveIdentityFresh(forPath: root.path, device: UInt64(info.st_dev)).kind.rawValue) }
        let topologyTime = start.duration(to: clock.now)
        print("[boundary-cost] buffer 50 batches × 100 rows, uncached: \(bufferTime) · 100 uncached volume lookups: \(topologyTime)")
        #expect(kinds.count == 1, "the same volume answered differently: \(kinds)")
        #expect(bufferTime < PerformanceLane.debugCeiling(.seconds(2)), "one uncached buffer reading took \(bufferTime)")
        #expect(topologyTime < PerformanceLane.debugCeiling(.seconds(5)), "100 uncached volume lookups took \(topologyTime)")
    }

    // MARK: Behaviour where round 2 had only a sensor

    /// Phase two's CAPTURED removal check finds the Read-only drive (only
    /// in quarantine does the file's volume read as the marked one): the
    /// file is put back as a hold — skipped, not refused, not Review.
    @Test func phaseTwosCapturedCheckHoldsAReadOnlyFileInsteadOfRefusingIt() async throws {
        let dir = tempDir("phase2"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let marked = scanTarget("/Volumes/TestMarked")
        marked.readOnlyMark = VolumeReadOnlyMark(markedAt: .distantPast, volumeUUID: "TEST-U")
        model.scanTargets = [marked, scanTarget(dir.path)]
        let g = UUID()
        let keeper = record(dir.appendingPathComponent("keeper.mov"), group: g, .keep, verified: true)
        let copy = record(dir.appendingPathComponent("copy.mov"), group: g, .extraCopy, verified: false)
        model.records = [keeper, copy, record(dir.appendingPathComponent("sibling.mov"), group: g, .review, verified: true)]
        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: dir),
                                      planRoot: dir.appendingPathComponent("plans", isDirectory: true))
        var sawQuarantine = false
        job.testHookAfterQuarantineSaved = { _ in sawQuarantine = true }
        let inQuarantine = SignatureVerification.quarantineDirectoryPrefix
        await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ $0.contains(inQuarantine) ? "TEST-U" : "TEST-ELSE" }) {
            await ArchiveVolumeProtection.$mountIdentityProbe.withValue({ _ in nil }) {
                job.start()
                await job.task?.value
            }
        }
        #expect(sawQuarantine, "fixture: phase one passed; the file reached quarantine")
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .skipped && row.note == "left alone — lives on TestMarked, which you marked Read only", "\(row.status): \(row.note)")
        #expect(copy.duplicateDisposition == .extraCopy, "a held copy was marked Review")
        #expect(FileManager.default.fileExists(atPath: copy.fullPath) && row.quarantineDirectory == nil, "put back at its path")
        #expect(job.runTally.refused == 0)
    }

    /// The forecast's drive question stats the FILE: a symlink whose target
    /// is on another volume is placed on that volume. (devfs is a second volume on every Mac;
    /// the lookup seam gives
    /// each its own device so the keys can be told apart.)
    @Test func theForecastsResolverFollowsAFileSymlinkOntoAnotherVolume() throws {
        let dir = tempDir("statfile"); defer { try? FileManager.default.removeItem(at: dir) }
        let target = "/dev/null"   // devfs: a second volume on every Mac (the boot and data volumes share one st_dev)
        var there = stat(), here = stat()
        guard stat(target, &there) == 0, stat(dir.path, &here) == 0, there.st_dev != here.st_dev else { return }
        let local = dir.appendingPathComponent("local.mov"), link = dir.appendingPathComponent("test_link")
        FileManager.default.createFile(atPath: local.path, contents: Data([1]))
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        let keys: [String?] = DuplicateDrives.$cacheScope.withValue("test-statfile-\(UUID().uuidString)|") {
            DuplicateDrives.$lookupOverride.withValue({ _, device in .init(device: device, kind: .physical, physicalDevice: "test-volume-\(device)") }) {
                var resolver = DuplicateDrives.Resolver()
                return [resolver.drive(forPath: link.path)?.key, resolver.drive(forPath: target)?.key, resolver.drive(forPath: local.path)?.key]
            }
        }
        #expect(keys[0] != nil && keys[0] == keys[1], "the symlinked file was not placed on its target's volume")
        #expect(keys[0] != keys[2], "the symlinked file was placed on its FOLDER's volume")
    }

    // MARK: The principle, pinned

    /// At the final verdict nothing comes from a cache: the functions it
    /// runs call the Fresh entry points and none of the Cached ones.
    @Test func theFinalVerdictCallsOnlyTheFreshEntryPoints() throws {
        func body(_ code: String, from start: String, to end: String) throws -> String {
            let a = try #require(code.range(of: start), "\(start) is gone")
            let b = try #require(code.range(of: end, range: a.upperBound..<code.endIndex), "\(end) is gone")
            return String(code[a.upperBound..<b.lowerBound])
        }
        let job = try SourceTree.appCode(named: "DeleteDuplicatesJob.swift")
        // The verdict closure itself: the holds, then the copies and their drives.
        let verdict = try body(job, from: "let result = SignatureVerification.deleteQuarantined(ticket, disposal: recorded, hooks: hooks) {",
                               to: "var outcome = map(result, proof: ticket.proof, keeper: keeperFilename)")
        #expect(verdict.contains("let word = ask?(ticket.quarantinedPath)") && verdict.contains("let now = facts.recheck()"))
        #expect(verdict.components(separatedBy: "ask?(").count == 2, "the final verdict asks the boundary more than once")
        #expect(verdict.contains("if let refusal = word?.archive {"), "the final verdict no longer asks the Master Archive rule afresh")
        #expect(verdict.contains("let trashEveryDuplicate = preferTrash || word?.preferTrash == true"),
                "the final verdict no longer reads \"Prefer the Trash\" afresh")
        #expect(job.contains("boundary: Self.removalBoundary(model: model, recordID: entry.id, path: entry.path))")
                && job.contains("archiveCheck: archiveCheck, boundary: boundary)"))
        // The boundary: the buffer, ONE hop, the protections built there.
        let boundary = try body(job, from: "static func removalBoundary(", to: "static func removalBoundaryHold(")
        #expect(boundary.components(separatedBy: "onMainActor").count == 2, "the boundary hops to the main actor more than once")
        #expect(boundary.contains("return model.duplicateRemovalBoundaryNow(recordID: recordID)"))
        #expect(boundary.contains("model.archiveAngel.recordInBatchOnDiskFreshProbe()"))
        #expect(boundary.contains("ReadOnlyVolumeProtection.make(marks: now.readOnlyMarks, probe: uuidProbe, identity: identityProbe)"))
        #expect(boundary.contains("ArchiveVolumeProtection.make(designation: designation, aliasCandidates: now.aliasCandidates,"))
        #expect(!boundary.contains("Cached") && !boundary.contains("readOnlyVolumeProtection()") && !boundary.contains("recordIDsInBatchesOnDisk")
                && !boundary.contains("archiveVolumeProtection()") && !boundary.contains("archiveRemovalCheck()"),
                "the removal boundary reads a cache")
        #expect(job.components(separatedBy: "onMainActor {").count == 2, "a second synchronous hop at the removal")
        let model = try SourceTree.appCode(named: "VideoScanModel+Duplicates.swift")
        let word = try body(model, from: "func duplicateRemovalBoundaryWord(", to: "func duplicateSurvivorStandingRule(")
        #expect(word.contains("return (hold?.note, readOnlyVolumeMarks)") && !word.contains("readOnlyVolumeProtection()"))
        #expect(word.contains("(masterArchive, archiveAliasCandidates,") && word.contains("preferTrash: duplicateKeeperSettings.preferTrashForEveryDuplicate)"))
        let facade = try SourceTree.appCode(named: "ArchiveAngel.swift")
        let probe = try body(facade, from: "func recordInBatchOnDiskFreshProbe()", to: "static func readRecordIDsInBatches(")
        #expect(probe.contains("ArchiveAngelPlanStore.inFlightRecordIDsFresh(bufferRoot: root)") && !probe.contains("Cached"))
        let store = try SourceTree.appCode(named: "ArchiveAngelPlan.swift")
        let fresh = try body(store, from: "static func inFlightRecordIDsFresh(", to: "static func inFlightRecordIDsCached(")
        #expect(fresh.contains("plan = try load(batchDir: dir)") && !fresh.contains("holdReadings") && !fresh.contains("Cached("),
                "the fresh buffer reading touches the cache")
        // …and it FAILS CLOSED (r4-2): it never goes through the readers that skip what they cannot read.
        #expect(!fresh.contains("listBatches(") && !fresh.contains("scanBatches(") && !fresh.contains("try? load"),
                "the fresh buffer reading skips a batch it cannot read")
        #expect(fresh.components(separatedBy: "return .uncertain(").count == 5,
                "a failed listing, a symlinked batch (r5-5), an unreadable plan and an unexaminable one are each uncertain")
        #expect(boundary.contains("case .uncertain(let why):") && !boundary.contains("default:"), "the boundary no longer holds on unreadable evidence")
        // The drives.
        let plan = try SourceTree.appCode(named: "DeleteDuplicatesPlan.swift")
        let recheck = try body(plan, from: "nonisolated func recheck() -> DeletionTierFacts {", to: "struct DeletionTierDecision")
        #expect(recheck.contains("var resolver = DuplicateDrives.Resolver(fresh: true)") && !recheck.contains("DuplicateDrives.Resolver()"),
                "the final verdict's drive question may be answered from the cache")
        #expect(recheck.contains("let askDrivesAfresh = driveGeneration != nil"), "the fresh lookup depends on the generation again")
        let drives = try SourceTree.appCode(named: "DeleteDuplicatesDrives.swift")
        let lookup = try body(drives, from: "static func liveIdentityFresh(", to: "static func liveIdentityCached(")
        #expect(!lookup.contains("shared") && !lookup.contains("cache"), "the fresh lookup reads or writes the cache")
        #expect(drives.contains("? DuplicateDrives.liveIdentityFresh(forPath: path, device: device)\n                : DuplicateDrives.liveIdentityCached("))
        var repo = try #require(SourceTree.appSourceURL(named: "DeleteDuplicatesPlan.swift"))
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md").path) {
            repo = repo.deletingLastPathComponent()
        }
        let invariants = try String(contentsOf: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md"), encoding: .utf8)
        #expect(invariants.contains("AT THE FINAL VERDICT IMMEDIATELY BEFORE A REMOVAL, NOTHING COMES FROM A CACHE"))
        #expect(invariants.contains("the Master Archive rule (the current designation, turned into a protection there and then")
                && invariants.contains("that makes six, all fresh"))
    }

    // MARK: R3-3

    @Test func theCommentStripperRemovesBlockCommentsToo() {
        #expect(!SourceTree.strippingComments("/* DuplicateDrives.resetVolumeCache() */").contains("resetVolumeCache"))
        let source = """
        let a = 1 /* gone */ + 2
        /* outer /* nested */ still a comment: hidden() */
        let url = "http://example.test/*not-a-comment*/path"   // trailing
        /*
         multi()
         line()
        */
        keep()
        """
        let code = SourceTree.strippingComments(source)
        #expect(code.contains("let a = 1  + 2") && code.contains("keep()"))
        #expect(!code.contains("gone") && !code.contains("hidden()") && !code.contains("multi()") && !code.contains("line()") && !code.contains("trailing"))
        #expect(code.contains("\"http://example.test/*not-a-comment*/path\""), "a string literal is not a comment")
        // Lines that were only a comment vanish, so code on either side stays adjacent.
        #expect(SourceTree.strippingComments("first()\n    // why\n    /* and why */\nsecond()") == "first()\nsecond()")
    }
}
