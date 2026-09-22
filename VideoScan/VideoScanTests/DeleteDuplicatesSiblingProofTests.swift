// DeleteDuplicatesSiblingProofTests.swift
// Rick's SanDisk run, 2026-09-21: 2,898 working copies, 1.5 hours, ZERO
// deleted — 1,702 rows "left alone" while the siblings they named sat on
// LaCieWorkspace unproven (a sibling never had a current stamp-bound
// fixity, because nothing ever read one). Three parts, five dimensions:
//
//   1. PROVE SIBLINGS (logic) — keeper + one unproven sibling → read,
//      matches → 2 remain → Trash; + two → permanent; differs → left
//      alone and named; offline → left alone; a hard link of the target
//      is never read nor counted; a stored sibling fixity is reused on the
//      next run without a read; the removal boundary still refuses when
//      the proven sibling changes between counting and mutation; an HDD
//      sibling makes its pair run alone (the slot gate).
//   2. PREVIEW (logic + scale) — buckets on a fixture plan match what the
//      run then does; pure bucket rules; 100k rows under a budget.
//   3. LOGGING — one `[dupjob]` line per decided row for every outcome,
//      a counts-and-sizes summary, a partial summary on pause and cancel.
//   ISOLATION — a poisoned stored fixity on a sibling (right digest,
//      wrong stamp) is never trusted by the run: it re-reads; every line
//      goes to the job's injected sink, never the global log.
//
// Everything lives under the process temp dir; the Trash step is routed
// into a scratch folder (DeleteDuplicatesTierFixtures). No personal
// filenames.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupsibs_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

private func plainSHA256(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let blockSize = FileHasher.segmentSize
private let fileSize = blockSize * 3
private let sizeText = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
private let zero = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
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

/// Rewrite in place (same inode, same size, mtime put back) — only the
/// kernel ctime tells.
private func rewriteInPlace(_ url: URL, bytes: [UInt8]) throws {
    var before = stat()
    try #require(stat(url.path, &before) == 0)
    let fd = open(url.path, O_WRONLY)
    try #require(fd >= 0)
    defer { close(fd) }
    let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }
    try #require(wrote == bytes.count)
    var times = [before.st_atimespec, before.st_mtimespec]
    try #require(futimens(fd, &times) == 0)
}

/// Counts read blocks per label, holds the first open of named files.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    private var opened: [String: Int] = [:]
    var quarantineHold: TimeInterval = 0
    var barrierFor: Set<String> = []
    private var barriers: [String: DispatchSemaphore] = [:]
    private var blockedOnce: Set<String> = []

    func blocks(_ label: String) -> Int { lock.withLock { blocks[label] ?? 0 } }
    func opens(_ name: String) -> Int { lock.withLock { opened[name] ?? 0 } }
    func hasBlocked(_ name: String) -> Bool { lock.withLock { blockedOnce.contains(name) } }
    func release(_ name: String) { lock.withLock { barriers[name] }?.signal() }

    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in lock.withLock { blocks[label, default: 0] += 1 } },
            didOpen: { [self] path in
                let name = (path as NSString).lastPathComponent
                let barrier: DispatchSemaphore? = lock.withLock {
                    opened[name, default: 0] += 1
                    guard barrierFor.contains(name), !blockedOnce.contains(name) else { return nil }
                    blockedOnce.insert(name)
                    let s = DispatchSemaphore(value: 0)
                    barriers[name] = s
                    return s
                }
                barrier?.wait()
            },
            didQuarantine: { [self] _ in
                if quarantineHold > 0 { Thread.sleep(forTimeInterval: quarantineHold) }
            })
    }
}

private func quarantineFolders(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

/// One family: a keeper with a stored fixity, `copies` extras to delete,
/// and `siblings` other members (no fixity unless `siblingFixity`).
@MainActor
private struct Family {
    let keeper: VideoRecord
    let copies: [VideoRecord]
    let siblings: [VideoRecord]
    let bytes: [UInt8]
}

@MainActor
private func addFamily(to model: VideoScanModel, in dir: URL, name: String, copies: Int = 1, siblings: Int = 0,
                       siblingFixity: Bool = false, siblingDir: URL? = nil, seed: UInt8 = 0,
                       keeperFixity: Bool = true) -> Family {
    let bytes = (0..<fileSize).map { UInt8(($0 &+ Int(seed)) % 199) }
    let group = UUID()
    let keeperURL = dir.appendingPathComponent("\(name)-keeper.mov"); write(keeperURL, bytes)
    let keeper = dupRecord(path: keeperURL.path, size: Int64(fileSize), group: group, disposition: .keep)
    if keeperFixity {
        keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL), byteCount: Int64(fileSize))
    }
    var extras: [VideoRecord] = []
    for i in 0..<copies {
        let url = dir.appendingPathComponent("\(name)-copy\(i + 1).mov"); write(url, bytes)
        extras.append(dupRecord(path: url.path, size: Int64(fileSize), group: group, disposition: .extraCopy))
    }
    var sibs: [VideoRecord] = []
    for i in 0..<siblings {
        let url = (siblingDir ?? dir).appendingPathComponent("\(name)-sib\(i + 1).mov"); write(url, bytes)
        let s = dupRecord(path: url.path, size: Int64(fileSize), group: group, disposition: .review)
        if siblingFixity {
            s.contentFixity = ContentFixity.captured(path: url.path, digest: plainSHA256(url), byteCount: Int64(fileSize))
        }
        sibs.append(s)
    }
    model.records.append(contentsOf: [keeper] + extras + sibs)
    return Family(keeper: keeper, copies: extras, siblings: sibs, bytes: bytes)
}

@MainActor
private func makeJob(_ model: VideoScanModel, _ dir: URL, _ probe: Probe, sink: InMemoryLogSink) -> DeleteDuplicatesJob {
    let job = DeleteDuplicatesJob(model: model, volumePath: dir.path,
                                  hooks: probe.hooks.withScratchTrash(in: dir),
                                  planRoot: dir.appendingPathComponent("plans", isDirectory: true))
    job.appLogSink = sink
    return job
}

private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 10) async {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline, !(await condition()) { await Task.yield() }
}

// MARK: - 1. Prove siblings

@Suite("Delete Duplicates — prove siblings", .serialized)
@MainActor
struct DeleteDuplicatesSiblingProofTests {

    @Test func oneUnprovenSiblingIsReadMatchesAndTheCopyGoesToTheTrash() async throws {
        let dir = tempDir("one"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "a", siblings: 1)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.tier == .trash && row.remainingVerifiedCopies == 2,
                "\(row.status): \(row.tierReason ?? row.note)")
        let evidence = try #require(row.countedCopies)
        #expect(evidence.map(\.path) == [fam.siblings[0].fullPath], "the proven sibling rides on the row as evidence")
        #expect(probe.blocks("sibling") == 3, "the sibling was read in full, once")
        #expect(probe.blocks("keeper") == 0, "the keeper is never read")
        let stored = try #require(fam.siblings[0].contentFixity)
        #expect(stored.isUsableForVerification && stored.describesFileNow(FileIdentityStamp.capture(path: fam.siblings[0].fullPath)),
                "the sibling's stamp-bound fixity is persisted where the keeper's is")
        #expect(stored.digest == plainSHA256(URL(fileURLWithPath: fam.siblings[0].fullPath)))
        #expect(FileManager.default.fileExists(atPath: fam.siblings[0].fullPath), "the sibling is never touched")
        #expect(job.runTally.siblingReads == 1 && job.runTally.siblingBytes == Int64(fileSize))
        #expect(sink.joined.contains("[dupjob] read sibling a-sib1.mov on "), Comment(rawValue: sink.joined))
        #expect(sink.joined.contains("for a-copy1.mov — matches"))
    }

    @Test func twoUnprovenSiblingsAreBothReadAndTheCopyIsDeletedOutright() async throws {
        let dir = tempDir("two"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "b", siblings: 2)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .deleted && row.tier == .permanent && row.remainingVerifiedCopies == 3,
                "\(row.status): \(row.tierReason ?? row.note)")
        #expect(probe.blocks("sibling") == 6)
        #expect(!FileManager.default.fileExists(atPath: fam.copies[0].fullPath))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Trash").path), "nothing went to a Trash")
        #expect(fam.siblings.allSatisfy { $0.contentFixity?.isUsableForVerification == true })
    }

    @Test func readsStopAtTheGoal() async throws {
        let dir = tempDir("goal"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        _ = addFamily(to: model, in: dir, name: "g", siblings: 4)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        #expect(job.plan?.entries.first?.status == .deleted)
        #expect(probe.blocks("sibling") == 6, "two siblings reach three copies; the other two are not read")
        #expect(job.runTally.siblingReads == 2)
    }

    @Test func aSiblingThatDiffersIsNotACopyTheRowIsLeftAloneAndNamed() async throws {
        let dir = tempDir("differs"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "c", siblings: 1)
        var other = fam.bytes; other[blockSize + 3] ^= 0x44
        write(URL(fileURLWithPath: fam.siblings[0].fullPath), other)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .skipped && row.tier == nil && row.remainingVerifiedCopies == 1, "\(row.status): \(row.note)")
        #expect(row.note.contains("sibling c-sib1.mov on ") && row.note.hasSuffix("holds different bytes)"), Comment(rawValue: row.note))
        #expect(FileManager.default.fileExists(atPath: fam.copies[0].fullPath), "put back at its path")
        #expect(quarantineFolders(in: dir).isEmpty)
        #expect(fam.copies[0].duplicateDisposition == .extraCopy, "left alone is not a refusal")
        #expect(fam.siblings[0].contentFixity?.digest == plainSHA256(URL(fileURLWithPath: fam.siblings[0].fullPath)),
                "a mismatching sibling's fixity is stored too — no later row reads it again")
        #expect(sink.joined.contains("for c-copy1.mov — differs"))
        #expect(sink.joined.contains("[dupjob] left alone c-copy1.mov (\(sizeText)) — only the keeper on "), Comment(rawValue: sink.joined))
    }

    @Test func anOfflineSiblingIsNotCountedAndNothingIsRead() async throws {
        let dir = tempDir("offline"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "d")
        let away = dupRecord(path: "/Volumes/NotConnected-\(UUID().uuidString.prefix(8))/d-sib.mov", size: Int64(fileSize),
                             group: fam.keeper.duplicateGroupID!, disposition: .review)
        model.records.append(away)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .skipped && row.remainingVerifiedCopies == 1, "\(row.status): \(row.note)")
        #expect(row.note.contains("sibling d-sib.mov on ") && row.note.contains("offline — not counted"), Comment(rawValue: row.note))
        #expect(probe.blocks("sibling") == 0 && probe.blocks("quarantine") == 0, "decided by stat before the hold — nothing moved or read")
        #expect(FileManager.default.fileExists(atPath: fam.copies[0].fullPath))
    }

    @Test func aHardLinkOfTheTargetIsNeverReadAndNeverCounted() async throws {
        let dir = tempDir("hardlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "e")
        let linked = dir.appendingPathComponent("e-linked.mov")
        try #require(link(fam.copies[0].fullPath, linked.path) == 0)
        model.records.append(dupRecord(path: linked.path, size: Int64(fileSize), group: fam.keeper.duplicateGroupID!,
                                       disposition: .review))
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .skipped && row.remainingVerifiedCopies == 1, "\(row.status): \(row.note)")
        #expect(probe.blocks("sibling") == 0, "the same inode as the file about to go is not another copy")
        #expect(FileManager.default.fileExists(atPath: fam.copies[0].fullPath) && FileManager.default.fileExists(atPath: linked.path))
    }

    /// A stored hard-link fixity cannot sneak in either: the gather names it.
    @Test func gatherNeverCountsTheDuplicatesOwnInode() throws {
        let dir = tempDir("gatherlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = [UInt8](repeating: 9, count: 4_096)
        let keeper = dir.appendingPathComponent("k.mov"); write(keeper, bytes)
        let dup = dir.appendingPathComponent("dup.mov"); write(dup, bytes)
        let linked = dir.appendingPathComponent("linked.mov")
        try #require(link(dup.path, linked.path) == 0)
        let digest = plainSHA256(dup)
        var c = DeletionTierCandidates()
        c.keeperLabel = "keeper on X"; c.keeperPath = keeper.path
        c.otherCopies = [.init(path: linked.path, fixity: ContentFixity.captured(path: linked.path, digest: digest, byteCount: 4_096),
                               label: "sibling linked.mov on X")]
        #expect(DeletionTierFacts.gather(c, digest: digest).remainingVerifiedCopies == 2, "without the duplicate's identity (old behaviour)")
        c.duplicateIdentity = FileIdentityStamp.capture(path: dup.path)
        let facts = DeletionTierFacts.gather(c, digest: digest)
        #expect(facts.remainingVerifiedCopies == 1)
        #expect(facts.notCounted == ["sibling linked.mov on X is the same file as the duplicate (hard link) — not another copy"])
    }

    @Test func aStoredSiblingFixityIsReusedOnTheNextRunWithoutAnyRead() async throws {
        let dir = tempDir("reuse"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "f", siblings: 1)
        let first = Probe(); let sink = InMemoryLogSink()
        let job1 = makeJob(model, dir, first, sink: sink)
        job1.start(); await job1.task?.value
        #expect(job1.plan?.entries.first?.status == .trashed)
        #expect(first.blocks("sibling") == 3)

        // A second duplicate turns up; the sibling's stored stamp still holds.
        let copy2 = dir.appendingPathComponent("f-copy2.mov"); write(copy2, fam.bytes)
        model.records.append(dupRecord(path: copy2.path, size: Int64(fileSize), group: fam.keeper.duplicateGroupID!,
                                       disposition: .extraCopy))
        let second = Probe()
        let job2 = makeJob(model, dir, second, sink: sink)
        job2.start(); await job2.task?.value
        let row = try #require(job2.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 2, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(second.blocks("sibling") == 0 && second.opens("f-sib1.mov") == 0, "stat only — the stored fixity stands in for the read")
        #expect(job2.runTally.siblingReads == 0)
    }

    @Test func theRemovalBoundaryStillRefusesWhenAProvenSiblingChanges() async throws {
        let dir = tempDir("boundary"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "h", siblings: 1)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        var tierWhenSaved: DeletionTier?
        job.testHookAfterQuarantineSaved = { [weak job] entry in
            tierWhenSaved = job?.plan?.entries.first { $0.id == entry.id }?.tier
            try? rewriteInPlace(URL(fileURLWithPath: fam.siblings[0].fullPath), bytes: fam.bytes)
        }
        job.start(); await job.task?.value

        #expect(tierWhenSaved == .trash, "the proven sibling made two at the save")
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .skipped && row.tier == nil && row.remainingVerifiedCopies == 1, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(row.note.hasPrefix("evidence changed before removal") && row.note.contains("h-sib1.mov"), Comment(rawValue: row.note))
        #expect(FileManager.default.fileExists(atPath: fam.copies[0].fullPath), "put back untouched")
        #expect(quarantineFolders(in: dir).isEmpty)
    }

    /// The slot gate: a sibling read occupies a slot on the SIBLING's
    /// drive. SSD siblings → two SSD pairs overlap; HDD siblings → each
    /// pair runs alone.
    @Test(arguments: [VolumeMediaTech.ssd, .hdd])
    func aSiblingOnAnHDDMakesItsPairRunAlone(siblingTech: VolumeMediaTech) async throws {
        let dir = tempDir("slots-\(siblingTech)"); defer { try? FileManager.default.removeItem(at: dir) }
        let sibDir = dir.appendingPathComponent("sibdrive", isDirectory: true)
        let model = makeModel(dir)
        _ = addFamily(to: model, in: dir, name: "s1", siblings: 1, siblingDir: sibDir, seed: 1)
        _ = addFamily(to: model, in: dir, name: "s2", siblings: 1, siblingDir: sibDir, seed: 2)
        let probe = Probe(); probe.quarantineHold = 0.3
        let job = makeJob(model, dir, probe, sink: InMemoryLogSink())
        job.mediaTechForPath = { $0.contains("/sibdrive/") ? siblingTech : .ssd }
        job.start(); await job.task?.value

        #expect(job.plan?.entries.map(\.status) == [.trashed, .trashed], "\(job.plan?.entries.map(\.note) ?? [])")
        #expect(job.peakInFlight == (siblingTech == .ssd ? 2 : 1), "peak \(job.peakInFlight) with \(siblingTech) siblings")
    }
}

// MARK: - 2. Preview

@Suite("Delete Duplicates — forecast before Start", .serialized)
@MainActor
struct DeleteDuplicatesForecastTests {

    private static func copy(_ id: UUID = UUID(), digest: String? = nil, online: Bool = true, size: Int64 = 100,
                             archive: String? = nil) -> DeleteDuplicatesForecast.Copy {
        .init(id: id, sizeBytes: size, digest: digest, online: online, isArchive: archive != nil, archiveDigest: archive)
    }

    /// One row, one family — the pure rule table.
    @Test func bucketRules() {
        typealias F = DeleteDuplicatesForecast
        func run(keeper: F.Copy?, row: (size: Int64, digest: String?), siblings: [F.Copy], preferTrash: Bool = false) -> F {
            let g = UUID()
            let rowID = UUID()
            var copies: [UUID: F.Copy] = [:]
            if let keeper { copies[keeper.id] = keeper }
            for s in siblings { copies[s.id] = s }
            copies[rowID] = Self.copy(rowID, digest: row.digest, size: row.size)
            let members = [rowID] + (keeper.map { [$0.id] } ?? []) + siblings.map(\.id)
            return F.compute(.init(rows: [.init(id: rowID, sizeBytes: row.size, digest: row.digest, keeperID: keeper?.id ?? UUID(),
                                                groupID: g)],
                                   copies: copies, members: [g: members], preferTrash: preferTrash))
        }
        let k = Self.copy(digest: "aa")
        // Stored evidence alone.
        #expect(run(keeper: k, row: (100, nil), siblings: [Self.copy(digest: "aa"), Self.copy(digest: "aa")]).rowBuckets == [.permanent])
        #expect(run(keeper: k, row: (100, nil), siblings: [Self.copy(digest: "aa")]).rowBuckets == [.trash])
        #expect(run(keeper: k, row: (100, nil), siblings: [Self.copy(digest: "aa"), Self.copy(digest: "aa")], preferTrash: true).rowBuckets == [.trash])
        // Trash that one read could upgrade.
        let upgrade = run(keeper: k, row: (100, nil), siblings: [Self.copy(digest: "aa"), Self.copy()])
        #expect(upgrade.rowBuckets == [.trash] && upgrade.trashMayBecomePermanent == 1 && upgrade.siblingReads == 1)
        // Reads needed.
        let needs = run(keeper: k, row: (100, nil), siblings: [Self.copy(), Self.copy(), Self.copy()])
        #expect(needs.rowBuckets == [.needsSiblingReads] && needs.siblingReads == 2, "reads stop at the goal (3)")
        #expect(needs.bytesToRead == 100 + 200, "the duplicate once + two siblings")
        // Only the original remains elsewhere.
        let alone = run(keeper: k, row: (100, nil), siblings: [Self.copy(online: false), Self.copy(digest: "bb")])
        #expect(alone.rowBuckets == [.leftAlone] && alone.bytesToRead == 0, "offline and different siblings never count; nothing read")
        // Catalog already says different.
        #expect(run(keeper: k, row: (99, nil), siblings: [Self.copy(digest: "aa")]).rowBuckets == [.likelyNotDuplicate])
        #expect(run(keeper: k, row: (100, "cc"), siblings: [Self.copy(digest: "aa")]).rowBuckets == [.likelyNotDuplicate])
        // Keeper away / missing.
        #expect(run(keeper: Self.copy(digest: "aa", online: false), row: (100, nil), siblings: []).rowBuckets == [.cannotCheck])
        #expect(run(keeper: nil, row: (100, nil), siblings: []).rowBuckets == [.cannotCheck])
        // Archive copy counts only with a stamp-bound digest equal to its record.
        #expect(run(keeper: k, row: (100, nil), siblings: [Self.copy(digest: "aa", archive: "aa")]).rowBuckets == [.trash])
        #expect(run(keeper: k, row: (100, nil), siblings: [Self.copy(archive: "aa")]).rowBuckets == [.leftAlone])
    }

    /// Rows of one run see each other the way the job does: a later row is
    /// still to be decided; an earlier row that goes is gone; one that
    /// stays is a sibling (a read) for the rows after it.
    @Test func rowsOfOneRunSeeEachOtherInPlanOrder() {
        typealias F = DeleteDuplicatesForecast
        let g = UUID()
        let k = Self.copy(digest: "aa")
        let a = UUID(), b = UUID(), c = UUID()
        var copies: [UUID: F.Copy] = [k.id: k]
        for id in [a, b, c] { copies[id] = Self.copy(id) }
        let rows = [a, b, c].map { F.Row(id: $0, sizeBytes: 100, digest: nil, keeperID: k.id, groupID: g) }
        let f = F.compute(.init(rows: rows, copies: copies, members: [g: [k.id, a, b, c]], preferTrash: false))
        // a: b, c still to be decided → only the keeper → left alone.
        // b: a stayed (unproven, readable) → needs a read → goes.
        // c: a was proven by b's read, b is gone → 2 → Trash.
        #expect(f.rowBuckets == [.leftAlone, .needsSiblingReads, .trash], "\(f.rowBuckets)")
        #expect(f.siblingReads == 1, "a is read once, for b; c reuses it")
    }

    /// The forecast on a fixture plan matches what the run then does.
    @Test func forecastMatchesTheRunOnAFixturePlan() async throws {
        let dir = tempDir("forecast"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let permanent = addFamily(to: model, in: dir, name: "p", siblings: 2, siblingFixity: true, seed: 1)
        let trash = addFamily(to: model, in: dir, name: "t", siblings: 1, siblingFixity: true, seed: 2)
        let needs = addFamily(to: model, in: dir, name: "n", siblings: 1, seed: 3)
        let alone = addFamily(to: model, in: dir, name: "l", seed: 4)
        let notDup = addFamily(to: model, in: dir, name: "x", siblings: 2, siblingFixity: true, seed: 5)
        var shorter = notDup.bytes; shorter.removeLast(17)
        write(URL(fileURLWithPath: notDup.copies[0].fullPath), shorter)
        notDup.copies[0].sizeBytes = Int64(shorter.count)

        let started = ContinuousClock.now
        let forecast = model.deleteDuplicatesForecast(onVolume: dir.path)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(forecast.bucket(for: permanent.copies[0].id) == .permanent)
        #expect(forecast.bucket(for: trash.copies[0].id) == .trash)
        #expect(forecast.bucket(for: needs.copies[0].id) == .needsSiblingReads)
        #expect(forecast.bucket(for: alone.copies[0].id) == .leftAlone)
        #expect(forecast.bucket(for: notDup.copies[0].id) == .likelyNotDuplicate)
        #expect(forecast.siblingReads == 1 && forecast.siblingReadBytes == Int64(fileSize))
        let text = forecast.confirmationText
        #expect(text.contains("• will be deleted: 1 (\(sizeText))"), Comment(rawValue: text))
        #expect(text.contains("• will move to the Trash: 1 (\(sizeText))"))
        #expect(text.contains("• need 1 sibling read to decide: 1 (\(sizeText))"))
        #expect(text.contains("• will be left alone — only the original remains elsewhere: 1 (\(sizeText))"))
        #expect(text.contains("• likely not duplicates: 1 ("))

        let sink = InMemoryLogSink()
        let job = makeJob(model, dir, Probe(), sink: sink)
        job.start(); await job.task?.value
        let plan = try #require(job.plan)
        func status(_ r: VideoRecord) -> DeleteDuplicatesPlan.EntryStatus? { plan.entries.first { $0.id == r.id }?.status }
        #expect(status(permanent.copies[0]) == .deleted)
        #expect(status(trash.copies[0]) == .trashed)
        #expect(status(needs.copies[0]) == .trashed, "the one read proved the sibling")
        #expect(status(alone.copies[0]) == .skipped)
        #expect(status(notDup.copies[0]) == .refused)
        #expect(sink.lines.first { $0.hasPrefix("delete duplicates forecast: ") } == forecast.logLine(volume: dir.lastPathComponent),
                "the run logs the same forecast as one line")
    }

    @Test func preferTrashMovesEveryForecastRemovalToTheTrash() {
        let dir = tempDir("forecastpref"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        model.duplicateKeeperSettings.preferTrashForEveryDuplicate = true
        let fam = addFamily(to: model, in: dir, name: "q", siblings: 3, siblingFixity: true)
        #expect(model.deleteDuplicatesForecast(onVolume: dir.path).bucket(for: fam.copies[0].id) == .trash)
    }

    /// SCALE: 100k rows through the pure simulation, and 100k rows through
    /// the live-catalog builder — both under a budget. (Tonight's case is
    /// 2,898 rows.)
    @Test(.timeLimit(.minutes(2)))
    func forecastAt100kRowsStaysUnderBudget() {
        typealias F = DeleteDuplicatesForecast
        let n = 100_000
        var rows: [F.Row] = []; rows.reserveCapacity(n)
        var copies: [UUID: F.Copy] = [:]; copies.reserveCapacity(n * 2)
        var members: [UUID: [UUID]] = [:]; members.reserveCapacity(n / 2)
        for _ in 0..<(n / 2) {
            let g = UUID()
            let k = Self.copy(digest: "aa"), s = Self.copy()
            let r1 = UUID(), r2 = UUID()
            copies[k.id] = k; copies[s.id] = s
            copies[r1] = Self.copy(r1); copies[r2] = Self.copy(r2)
            members[g] = [k.id, r1, r2, s.id]
            rows.append(.init(id: r1, sizeBytes: 100, digest: nil, keeperID: k.id, groupID: g))
            rows.append(.init(id: r2, sizeBytes: 100, digest: nil, keeperID: k.id, groupID: g))
        }
        let t0 = ContinuousClock.now
        let f = F.compute(.init(rows: rows, copies: copies, members: members, preferTrash: false))
        let pure = t0.duration(to: .now)
        #expect(f.rowBuckets.count == n)
        #expect(f.tally(.needsSiblingReads).files == n / 2 && f.tally(.trash).files == n / 2, "\(f.buckets)")
        #expect(pure < .seconds(3), "100k-row forecast took \(pure)")

        // The live-catalog path: 100k rows (50k families of keeper + 2
        // extras + 1 sibling) — built once, timed from the call.
        let dir = URL(fileURLWithPath: "/Volumes/ForecastScale-\(UUID().uuidString.prefix(6))")
        let model = VideoScanModel()
        var recs: [VideoRecord] = []; recs.reserveCapacity(n * 2)
        for i in 0..<(n / 2) {
            let g = UUID()
            let k = dupRecord(path: dir.appendingPathComponent("k\(i).mov").path, size: 100, group: g, disposition: .keep)
            recs.append(k)
            recs.append(dupRecord(path: dir.appendingPathComponent("a\(i).mov").path, size: 100, group: g, disposition: .extraCopy))
            recs.append(dupRecord(path: dir.appendingPathComponent("b\(i).mov").path, size: 100, group: g, disposition: .extraCopy))
            recs.append(dupRecord(path: "/Users/test/sib\(i).mov", size: 100, group: g, disposition: .review))
        }
        model.records = recs
        var keeperOf: [UUID: UUID] = [:]
        for r in recs where r.duplicateDisposition == .keep { keeperOf[r.duplicateGroupID!] = r.id }
        let live = recs.filter { $0.duplicateDisposition == .extraCopy }.map {
            VideoScanModel.DeleteDuplicatesForecastRow(id: $0.id, sizeBytes: $0.sizeBytes, record: $0,
                                                       keeperID: keeperOf[$0.duplicateGroupID!])
        }
        let t1 = ContinuousClock.now
        let lf = model.deleteDuplicatesForecast(rows: live)
        let built = t1.duration(to: .now)
        #expect(lf.rowBuckets.count == n)
        #expect(lf.tally(.cannotCheck).files == n, "the keepers' drive is not mounted — no stat, just the mount table")
        #expect(built < .seconds(6), "100k-row live forecast took \(built)")
    }
}

// MARK: - 3. Logging

@Suite("Delete Duplicates — one line per row, counts and sizes", .serialized)
@MainActor
struct DeleteDuplicatesRowLoggingTests {

    @Test func everyOutcomeGetsOneLineAndTheSummaryHasCountsAndSizes() async throws {
        let dir = tempDir("logging"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        _ = addFamily(to: model, in: dir, name: "p", siblings: 2, siblingFixity: true, seed: 1)
        _ = addFamily(to: model, in: dir, name: "t", siblings: 1, siblingFixity: true, seed: 2)
        _ = addFamily(to: model, in: dir, name: "n", siblings: 1, seed: 3)
        _ = addFamily(to: model, in: dir, name: "l", seed: 4)
        let notDup = addFamily(to: model, in: dir, name: "x", siblings: 2, siblingFixity: true, seed: 5)
        var other = notDup.bytes; other[blockSize * 2 + 1] ^= 0x33
        write(URL(fileURLWithPath: notDup.copies[0].fullPath), other)
        let sink = InMemoryLogSink()
        let job = makeJob(model, dir, Probe(), sink: sink)
        job.start(); await job.task?.value

        let lines = sink.lines
        func one(_ prefix: String) -> String? {
            let hits = lines.filter { $0.hasPrefix(prefix) }
            #expect(hits.count == 1, "\(prefix): \(hits)")
            return hits.first
        }
        let deleted = try #require(one("[dupjob] deleted p-copy1.mov (\(sizeText)) — 3 verified copies remain: keeper on "))
        #expect(deleted.contains("sibling p-sib1.mov on ") && deleted.contains("sibling p-sib2.mov on "), Comment(rawValue: deleted))
        let trashed = try #require(one("[dupjob] trashed t-copy1.mov (\(sizeText)) — 2 verified copies remain: keeper on "))
        #expect(trashed.contains("sibling t-sib1.mov on ") && trashed.contains("in the Trash of "), Comment(rawValue: trashed))
        _ = one("[dupjob] read sibling n-sib1.mov on ")
        _ = one("[dupjob] trashed n-copy1.mov (\(sizeText)) — 2 verified copies remain: keeper on ")
        _ = one("[dupjob] left alone l-copy1.mov (\(sizeText)) — only the keeper on ")
        let refused = try #require(one("[dupjob] refused x-copy1.mov (\(sizeText)) — content differs from keeper x-keeper.mov"))
        #expect(refused.hasSuffix("NOT a duplicate"))
        #expect(notDup.copies[0].duplicateDisposition == .review, "the refused pair is flagged for Review")
        #expect(lines.filter { $0.hasPrefix("[dupjob] ") }.count == 6, "one line per decided row + one per sibling read: \(lines)")

        let two = ByteCountFormatter.string(fromByteCount: Int64(fileSize * 2), countStyle: .file)
        let summary = "delete duplicates done: \(dir.lastPathComponent) — deleted 1 (\(sizeText)) · trashed 2 (\(two)) · "
            + "left alone 1 (\(sizeText)) · refused 1 (\(sizeText)) · freed \(sizeText) · 1 sibling copy read (\(sizeText))"
        #expect(lines.contains(summary), "expected \(summary)\n got \(lines.filter { $0.hasPrefix("delete duplicates") })")
    }

    @Test func pauseAndCancelWritePartialTotals() async throws {
        let dir = tempDir("partial"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        _ = addFamily(to: model, in: dir, name: "a", siblings: 1, siblingFixity: true, seed: 1)
        _ = addFamily(to: model, in: dir, name: "b", siblings: 1, siblingFixity: true, seed: 2)
        _ = addFamily(to: model, in: dir, name: "c", siblings: 1, siblingFixity: true, seed: 3)
        let probe = Probe()
        probe.barrierFor = ["a-copy1.mov", "b-copy1.mov"]
        let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.mediaTechForPath = { _ in .hdd }
        job.start()

        // PAUSE with the first file in flight: it lands, then the partial line.
        await waitUntil({ probe.hasBlocked("a-copy1.mov") })
        job.pause()
        probe.release("a-copy1.mov")
        await waitUntil({ job.isQuiescentForQuit })
        let volume = dir.lastPathComponent
        let paused = "delete duplicates paused: \(volume) — deleted 0 (\(zero)) · trashed 1 (\(sizeText)) · left alone 0 (\(zero)) · "
            + "refused 0 (\(zero)) · freed \(zero) · 0 sibling copies read (\(zero))"
        #expect(sink.lines.contains(paused), "\(sink.lines.filter { $0.hasPrefix("delete duplicates") })")

        // CANCEL (discard) with the second file in flight: partial totals.
        job.resume()
        await waitUntil({ probe.hasBlocked("b-copy1.mov") })
        job.cancel(discardingRemaining: true)
        probe.release("b-copy1.mov")
        await job.task?.value
        let cancelled = try #require(sink.lines.first { $0.hasPrefix("delete duplicates cancelled: ") })
        let two = ByteCountFormatter.string(fromByteCount: Int64(fileSize * 2), countStyle: .file)
        #expect(cancelled == "delete duplicates cancelled: \(volume) — deleted 0 (\(zero)) · trashed 1 (\(sizeText)) · "
                + "left alone 0 (\(zero)) · refused 0 (\(zero)) · not done 2 (\(two)) · freed \(zero) · 0 sibling copies read (\(zero))",
                Comment(rawValue: cancelled))
    }
}

// MARK: - Isolation

@Suite("Delete Duplicates — poisoned sibling evidence", .serialized)
@MainActor
struct DeleteDuplicatesSiblingIsolationTests {

    /// A sibling record carrying a POISONED fixity — the right digest but
    /// a stamp copied from another file — is trusted by the forecast (it
    /// reads only the catalog) and NEVER by the run: the stamp does not
    /// describe the file, so the run reads it before counting it.
    @Test func aPoisonedStoredFixityIsReReadNotTrusted() async throws {
        let dir = tempDir("poison"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "z", siblings: 1)
        let digest = plainSHA256(URL(fileURLWithPath: fam.keeper.fullPath))
        let foreign = try #require(FileIdentityStamp.capture(path: fam.keeper.fullPath))
        fam.siblings[0].contentFixity = ContentFixity(digest: digest, byteCount: Int64(fileSize), stamp: foreign)
        #expect(model.deleteDuplicatesForecast(onVolume: dir.path).bucket(for: fam.copies[0].id) == .trash,
                "the forecast trusts the catalog — and says it is a forecast")
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        #expect(probe.blocks("sibling") == 3, "the poisoned stamp does not describe the sibling — it is read")
        #expect(fam.siblings[0].contentFixity?.stamp != foreign, "replaced by the sibling's own stamp")
        #expect(job.plan?.entries.first?.status == .trashed)
        #expect(sink.joined.contains("for z-copy1.mov — matches"))
    }

    /// A poisoned DIGEST with a stale stamp cannot make a sibling look
    /// different forever: the stamp is stale, so it is read, and the
    /// fresh digest decides.
    @Test func aStaleWrongDigestIsReadAndTheFreshDigestDecides() async throws {
        let dir = tempDir("poison2"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "w", siblings: 1)
        let foreign = try #require(FileIdentityStamp.capture(path: fam.keeper.fullPath))
        fam.siblings[0].contentFixity = ContentFixity(digest: String(repeating: "0", count: 64), byteCount: Int64(fileSize),
                                                      stamp: foreign)
        let probe = Probe()
        let job = makeJob(model, dir, probe, sink: InMemoryLogSink())
        job.start(); await job.task?.value
        #expect(probe.blocks("sibling") == 3)
        #expect(job.plan?.entries.first?.status == .trashed, "\(job.plan?.entries.first?.note ?? "")")
    }
}
