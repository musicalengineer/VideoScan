// DeleteDuplicatesSiblingProofTests.swift
// Rick's SanDisk run, 2026-09-21: 2,898 working copies, 1.5 hours, ZERO
// deleted — rows "left alone" while the siblings they named sat unproven.
// The cure then was to READ siblings until two (or three) verified copies
// would remain.
//
// KEEP ONE (Rick 2026-10-09, design triage_delete_streamline §9 R5): one
// verified keeper is enough for the Trash, so the run never needs a
// sibling read. This file now pins that, and what still stands:
//
//   1. SIBLINGS ARE NAMED, NEVER NEEDED (logic) — an unproven, different,
//      offline or hard-linked sibling is never read; the copy goes to the
//      Trash on the keeper alone; a sibling with current stored evidence
//      is COUNTED for the row's words (stat only); a counted sibling that
//      changes at the removal is dropped from the words, and the copy still
//      goes; the slot gate no longer reserves a sibling's drive.
//   2. PREVIEW (logic + scale) — the forecast's buckets on a fixture plan
//      match what the run then does; the pure bucket rules; the bulk run's
//      pre-selection; 100k rows under a budget.
//   3. LOGGING — one `[dupjob]` line per decided row (rows held before the
//      first read included), a counts-and-sizes summary, a partial summary
//      on pause and cancel.
//   ISOLATION — a poisoned stored fixity on a sibling is never counted and
//      never "repaired" by the run; every line goes to the job's injected
//      sink, never the global log.
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

/// Counts read blocks per label and opens per file; holds the first open
/// of named files.
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

// MARK: - 1. Siblings are named, never needed

@Suite("Delete Duplicates — keep one: siblings are named, never read", .serialized)
@MainActor
struct DeleteDuplicatesSiblingProofTests {

    /// A sibling with no evidence is NOT read: the keeper alone is the one
    /// verified copy, and the copy goes to the Trash. The sibling is named.
    @Test func anUnprovenSiblingIsNotReadTheKeeperAloneSuffices() async throws {
        let dir = tempDir("one"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "a", siblings: 1)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.tier == .trash && row.remainingVerifiedCopies == 1,
                "\(row.status): \(row.tierReason ?? row.note)")
        #expect(row.tierReason?.contains("sibling a-sib1.mov on ") == true && row.tierReason?.contains("not verified yet") == true,
                Comment(rawValue: row.tierReason ?? ""))
        #expect(probe.blocks("sibling") == 0 && probe.opens("a-sib1.mov") == 0, "no sibling is read under keep one")
        #expect(probe.blocks("keeper") == 0, "the keeper is never read (its stored fixity is current)")
        #expect(fam.siblings[0].contentFixity == nil, "nothing was read, nothing stored")
        #expect(FileManager.default.fileExists(atPath: fam.siblings[0].fullPath), "the sibling is never touched")
        #expect(job.runTally.siblingReads == 0)
        #expect(!sink.joined.contains("[dupjob] read sibling"), Comment(rawValue: sink.joined))
    }

    /// A sibling whose stored evidence names OTHER bytes is named and not
    /// counted; the copy still goes on the keeper alone.
    @Test func aSiblingThatDiffersIsNamedNotCountedAndTheCopyStillGoes() async throws {
        let dir = tempDir("differs"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "c", siblings: 1)
        var other = fam.bytes; other[blockSize + 3] ^= 0x44
        let sib = URL(fileURLWithPath: fam.siblings[0].fullPath)
        write(sib, other)
        fam.siblings[0].contentFixity = ContentFixity.captured(path: sib.path, digest: plainSHA256(sib), byteCount: Int64(fileSize))
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 1, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(row.tierReason?.contains("sibling c-sib1.mov on ") == true && row.tierReason?.contains("holds different bytes") == true,
                Comment(rawValue: row.tierReason ?? ""))
        #expect(probe.blocks("sibling") == 0)
        #expect(sink.joined.contains("[dupjob] trashed c-copy1.mov (\(sizeText)) — 1 verified copy remains: keeper on "),
                Comment(rawValue: sink.joined))
    }

    @Test func anOfflineSiblingIsNamedAndNothingIsReadOfIt() async throws {
        let dir = tempDir("offline"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "d", siblings: 1)
        let away = dupRecord(path: "/Volumes/NotConnected-\(UUID().uuidString.prefix(8))/d-sib.mov", size: Int64(fileSize),
                             group: fam.keeper.duplicateGroupID!, disposition: .review)
        model.records.append(away)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 1, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(row.tierReason?.contains("sibling d-sib.mov on ") == true, Comment(rawValue: row.tierReason ?? ""))
        #expect(probe.blocks("sibling") == 0 && probe.opens("d-sib.mov") == 0)
    }

    @Test func aHardLinkOfTheTargetIsNeverReadAndNeverCounted() async throws {
        let dir = tempDir("hardlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "e", siblings: 1)
        let linked = dir.appendingPathComponent("e-linked.mov")
        try #require(link(fam.copies[0].fullPath, linked.path) == 0)
        let linkRecord = dupRecord(path: linked.path, size: Int64(fileSize), group: fam.keeper.duplicateGroupID!, disposition: .review)
        linkRecord.contentFixity = ContentFixity.captured(path: linked.path, digest: plainSHA256(linked), byteCount: Int64(fileSize))
        model.records.append(linkRecord)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 1, "the link is the copy itself, never another copy: \(row.tierReason ?? row.note)")
        #expect(row.tierReason?.contains("e-linked.mov") == true, Comment(rawValue: row.tierReason ?? ""))
        #expect(probe.blocks("sibling") == 0)
        #expect(FileManager.default.fileExists(atPath: linked.path), "the other name keeps its bytes")
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

    /// QA round 3 nit: the OPENED file must be the one stat'ed. A stamp of
    /// another file stands for a symlink retargeted between the stat and
    /// the open — refused, nothing to store; the honest stamp passes.
    @Test func wholeFileFixityRefusesAFileSwappedBetweenStatAndOpen() throws {
        let dir = tempDir("swap"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); write(a, [UInt8](repeating: 1, count: 8_192))
        let b = dir.appendingPathComponent("b.mov"); write(b, [UInt8](repeating: 1, count: 8_192))
        let link = dir.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: b.path)
        let stampOfA = try #require(FileIdentityStamp.capture(path: a.path))
        #expect(SignatureVerification.wholeFileFixity(path: link.path, label: "sibling", hooks: .live, before: stampOfA)
                == .changedDuringRead)
        guard case .fixity(let f) = SignatureVerification.wholeFileFixity(path: link.path, label: "sibling") else {
            Issue.record("the unswapped link should read"); return
        }
        #expect(f.digest == plainSHA256(b))
    }

    /// A sibling with CURRENT stored evidence is counted for the row's words
    /// — stat only, no read.
    @Test func aStoredSiblingFixityIsCountedByStatAlone() async throws {
        let dir = tempDir("reuse"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        _ = addFamily(to: model, in: dir, name: "f", siblings: 1, siblingFixity: true)
        let probe = Probe()
        let job = makeJob(model, dir, probe, sink: InMemoryLogSink())
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 2, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(probe.blocks("sibling") == 0 && probe.opens("f-sib1.mov") == 0, "stat only — the stored fixity stands in for the read")
    }

    /// The removal boundary still re-stats every counted copy: a sibling
    /// rewritten after the save is DROPPED from the words. The keeper still
    /// holds, so the copy still goes to the Trash — and the row says why.
    @Test func aCountedSiblingThatChangesAtTheBoundaryIsDroppedAndTheCopyStillGoes() async throws {
        let dir = tempDir("boundary"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "h", siblings: 1, siblingFixity: true)
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        var tierWhenSaved: DeletionTier?
        job.testHookAfterQuarantineSaved = { [weak job] entry in
            tierWhenSaved = job?.plan?.entries.first { $0.id == entry.id }?.tier
            try? rewriteInPlace(URL(fileURLWithPath: fam.siblings[0].fullPath), bytes: fam.bytes)
        }
        job.start(); await job.task?.value

        #expect(tierWhenSaved == .trash)
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 1, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(row.tierReason?.hasPrefix("re-checked before removal — to the Trash (") == true
                && row.tierReason?.contains("h-sib1.mov") == true, Comment(rawValue: row.tierReason ?? ""))
        #expect(!FileManager.default.fileExists(atPath: fam.copies[0].fullPath))
        #expect(quarantineFolders(in: dir).isEmpty)
    }

    /// Two SSD pairs naming one unproven sibling: nothing waits on a claim
    /// (no sibling is read), both go.
    @Test func twoPairsNamingOneUnprovenSiblingNeitherReadsIt() async throws {
        let dir = tempDir("dedup"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "u", copies: 2, siblings: 1)
        let probe = Probe(); probe.quarantineHold = 0.3
        let job = makeJob(model, dir, probe, sink: InMemoryLogSink())
        job.mediaTechForPath = { _ in .ssd }
        job.start(); await job.task?.value

        #expect(job.plan?.entries.map(\.status) == [.trashed, .trashed], "\(job.plan?.entries.map(\.note) ?? [])")
        #expect(probe.opens("u-sib1.mov") == 0 && job.siblingReadWaits == 0 && job.runTally.siblingReads == 0)
        #expect(job.peakInFlight == 2, "two SSD pairs overlap")
        #expect(FileManager.default.fileExists(atPath: fam.siblings[0].fullPath))
    }

    /// The slot gate no longer reserves a SIBLING's drive: with no read to
    /// make, an HDD sibling does not make its pair run alone.
    @Test(arguments: [VolumeMediaTech.ssd, .hdd])
    func aSiblingsDriveNoLongerChangesTheSlotWeight(siblingTech: VolumeMediaTech) async throws {
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
        #expect(job.peakInFlight == 2, "peak \(job.peakInFlight) with \(siblingTech) siblings")
    }
}

// MARK: - 2. Preview

@Suite("Delete Duplicates — forecast before Start", .serialized)
@MainActor
struct DeleteDuplicatesForecastTests {

    private typealias F = DeleteDuplicatesForecast

    private static func keeper(_ id: UUID = UUID(), digest: String? = "aa", online: Bool = true, size: Int64 = 100) -> F.Keeper {
        .init(id: id, sizeBytes: size, digest: digest, online: online)
    }

    /// One row — the pure rule table.
    @Test func bucketRules() {
        func run(_ k: F.Keeper?, size: Int64 = 100, digest: String? = nil,
                 inCatalog: Bool = true) -> F {
            let row = F.Row(id: UUID(), sizeBytes: size, digest: digest, keeperID: k?.id ?? UUID(),
                            inCatalog: inCatalog)
            return F.compute(.init(rows: [row], keepers: k.map { [$0.id: $0] } ?? [:]))
        }
        let k = Self.keeper()
        #expect(run(k).rowBuckets == [.trash], "a keeper that can be checked: the Trash")
        #expect(run(k).bytesToRead == 100, "the duplicate is read once; the keeper's digest is stored")
        let unknown = run(Self.keeper(digest: nil))
        #expect(unknown.rowBuckets == [.trash] && unknown.bytesToRead == 200, "a keeper without a stored digest is read once too")
        #expect(run(k, digest: "aa").rowBuckets == [.trash])
        #expect(run(k, size: 99).rowBuckets == [.likelyNotDuplicate])
        #expect(run(k, digest: "cc").rowBuckets == [.likelyNotDuplicate])
        #expect(run(Self.keeper(online: false)).rowBuckets == [.cannotCheck])
        #expect(run(nil).rowBuckets == [.cannotCheck])
        #expect(run(k, inCatalog: false).rowBuckets == [.cannotCheck])
        // R5 revised (2026-10-09 evening): no "not pre-selected" bucket — a
        // pair's extra is forecast like any other.
        #expect(F.Bucket.allCases.map(\.rawValue) == ["trash", "likelyNotDuplicate", "cannotCheck"])
        #expect(!F.Bucket.allCases.map(\.rawValue).contains("permanent"), "nothing is forecast for an outright delete")
    }

    /// A keeper shared by many rows is read once.
    @Test func aKeeperWithoutADigestIsReadOncePerRun() {
        let k = Self.keeper(digest: nil)
        let rows = (0..<3).map { _ in F.Row(id: UUID(), sizeBytes: 100, digest: nil, keeperID: k.id) }
        let f = F.compute(.init(rows: rows, keepers: [k.id: k]))
        #expect(f.rowBuckets == [.trash, .trash, .trash] && f.bytesToRead == 300 + 100)
    }

    /// The forecast on a fixture volume matches what the run then does.
    @Test func forecastMatchesTheRunOnAFixturePlan() async throws {
        let dir = tempDir("forecast"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let three = addFamily(to: model, in: dir, name: "t", siblings: 1, siblingFixity: true, seed: 1)
        let unproven = addFamily(to: model, in: dir, name: "n", siblings: 1, seed: 2)
        let two = addFamily(to: model, in: dir, name: "l", seed: 3)                  // keeper + 1: a pair, included
        let notDup = addFamily(to: model, in: dir, name: "x", siblings: 2, siblingFixity: true, seed: 4)
        var shorter = notDup.bytes; shorter.removeLast(17)
        write(URL(fileURLWithPath: notDup.copies[0].fullPath), shorter)
        notDup.copies[0].sizeBytes = Int64(shorter.count)

        let started = ContinuousClock.now
        let forecast = model.deleteDuplicatesForecast(onVolume: dir.path)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(forecast.bucket(for: three.copies[0].id) == .trash)
        #expect(forecast.bucket(for: unproven.copies[0].id) == .trash, "keep one: no sibling read is needed")
        #expect(forecast.bucket(for: two.copies[0].id) == .trash, "pairs included — no tick")
        #expect(forecast.bucket(for: notDup.copies[0].id) == .likelyNotDuplicate)
        let text = forecast.confirmationText(volume: "FixtureDrive")
        #expect(text.hasPrefix("Check 4 copies on FixtureDrive.\n\nForecast (from the catalog — no file read yet): "
                               + "about 3 to the Trash (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize * 3), countStyle: .file))), "
                               + "1 likely not duplicates ("), Comment(rawValue: text))
        #expect(!text.contains("deleted") && !text.contains("Nothing will move"))
        #expect(text.hasSuffix(DeleteDuplicatesForecast.decidesAtTheMoment))
        let sink = InMemoryLogSink()
        let job = makeJob(model, dir, Probe(), sink: sink)
        job.start(); await job.task?.value
        let plan = try #require(job.plan)
        func status(_ r: VideoRecord) -> DeleteDuplicatesPlan.EntryStatus? { plan.entries.first { $0.id == r.id }?.status }
        #expect(status(three.copies[0]) == .trashed)
        #expect(status(unproven.copies[0]) == .trashed)
        #expect(status(two.copies[0]) == .trashed)
        #expect(status(notDup.copies[0]) == .refused)
        #expect(sink.lines.first { $0.hasPrefix("delete duplicates forecast: ") } == job.model?.deleteDuplicatesForecast(for: plan).logLine(volume: dir.lastPathComponent)
                || sink.lines.contains { $0.hasPrefix("delete duplicates forecast: \(dir.lastPathComponent) — trash 3 ") },
                "the run logs its forecast as one line: \(sink.lines.filter { $0.hasPrefix("delete duplicates forecast") })")
    }

    /// Honest when nothing can move — and the button says the one verb.
    @Test func nothingToMoveSaysSoInPlainWords() {
        let k = Self.keeper(online: false)
        let row = F.Row(id: UUID(), sizeBytes: 100, digest: nil, keeperID: k.id)
        let f = F.compute(.init(rows: [row], keepers: [k.id: k]))
        let text = f.confirmationText(volume: "SanDiskWorkspace")
        #expect(text.hasPrefix("Check 1 copy on SanDiskWorkspace.\n\nForecast (from the catalog — no file read yet): about 0 to the Trash"),
                Comment(rawValue: text))
        #expect(text.contains("\n\nNothing will move — no copy here has a keeper that can be checked now."))
        #expect(F.confirmationButtonTitle == "Move Proven Copies to the Trash" && !F.confirmationButtonTitle.lowercased().contains("delete"))
    }

    /// SCALE: 100k rows through the pure forecast, and 100k rows through
    /// the live-catalog builder — both under a budget.
    @Test(.timeLimit(.minutes(2)))
    func forecastAt100kRowsStaysUnderBudget() {
        let n = 100_000
        var rows: [F.Row] = []; rows.reserveCapacity(n)
        var keepers: [UUID: F.Keeper] = [:]; keepers.reserveCapacity(n / 2)
        for _ in 0..<(n / 2) {
            let k = Self.keeper()
            keepers[k.id] = k
            rows.append(.init(id: UUID(), sizeBytes: 100, digest: nil, keeperID: k.id))
            rows.append(.init(id: UUID(), sizeBytes: 99, digest: nil, keeperID: k.id))
        }
        let t0 = ContinuousClock.now
        let f = F.compute(.init(rows: rows, keepers: keepers))
        let pure = t0.duration(to: .now)
        #expect(f.rowBuckets.count == n)
        #expect(f.tally(.trash).files == n / 2 && f.tally(.likelyNotDuplicate).files == n / 2, "\(f.buckets)")
        #expect(pure < PerformanceLane.debugCeiling(.seconds(3)), "100k-row forecast took \(pure)")

        // The live-catalog path: 100k rows (50k families of keeper + 2
        // extras + 1 sibling) — built once, timed from the call.
        let dir = URL(fileURLWithPath: "/Volumes/ForecastScale-\(UUID().uuidString.prefix(6))")
        let model = VideoScanModel()
        var recs: [VideoRecord] = []; recs.reserveCapacity(n * 2)
        for i in 0..<(n / 2) {
            let g = UUID()
            recs.append(dupRecord(path: dir.appendingPathComponent("k\(i).mov").path, size: 100, group: g, disposition: .keep))
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
        #expect(built < PerformanceLane.debugCeiling(.seconds(6)), "100k-row live forecast took \(built)")
    }
}

// MARK: - 3. Logging

@Suite("Delete Duplicates — one line per row, counts and sizes", .serialized)
@MainActor
struct DeleteDuplicatesRowLoggingTests {

    @Test func everyOutcomeGetsOneLineAndTheSummaryHasCountsAndSizes() async throws {
        let dir = tempDir("logging"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let p = addFamily(to: model, in: dir, name: "p", siblings: 1, siblingFixity: true, seed: 1)
        addVerifiedArchiveFamily(to: model, keeper: p.keeper, withSibling: false)
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
        let three = try #require(one("[dupjob] trashed p-copy1.mov (\(sizeText)) — 3 verified copies remain: keeper on "))
        #expect(three.contains("sibling p-sib1.mov on ") && three.contains("archive copy on "), Comment(rawValue: three))
        let trashed = try #require(one("[dupjob] trashed t-copy1.mov (\(sizeText)) — 2 verified copies remain: keeper on "))
        #expect(trashed.contains("sibling t-sib1.mov on ") && trashed.contains("in the Trash of "), Comment(rawValue: trashed))
        _ = one("[dupjob] trashed n-copy1.mov (\(sizeText)) — 1 verified copy remains: keeper on ")
        _ = one("[dupjob] trashed l-copy1.mov (\(sizeText)) — 1 verified copy remains: keeper on ")   // a pair, included
        let refused = try #require(one("[dupjob] refused x-copy1.mov (\(sizeText)) — content differs from keeper x-keeper.mov"))
        #expect(refused.hasSuffix("NOT a duplicate"))
        #expect(notDup.copies[0].duplicateDisposition == .review, "the refused pair is flagged for Review")
        #expect(lines.filter { $0.hasPrefix("[dupjob] ") }.count == 5, "one line per decided row, no sibling reads: \(lines)")

        let fourBytes = ByteCountFormatter.string(fromByteCount: Int64(fileSize * 4), countStyle: .file)
        let summary = "delete duplicates done: \(dir.lastPathComponent) — deleted 0 (\(zero)) · trashed 4 (\(fourBytes)) · "
            + "left alone 0 (\(zero)) · refused 1 (\(sizeText)) · freed \(zero) · 0 sibling copies read (\(zero))"
        #expect(lines.contains(summary), "expected \(summary)\n got \(lines.filter { $0.hasPrefix("delete duplicates") })")
        #expect(lines.filter { $0.hasPrefix("delete duplicates done: ") }.count == 1)
        #expect(job.wroteOwnTerminalLine, "the MFO center's generic outcome line is skipped — one final line per run")
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
        #expect(!job.wroteOwnTerminalLine, "a pause is not the end of the run")

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

    /// A sibling record carrying a POISONED fixity — the right digest but a
    /// stamp copied from another file — is never counted: the stamp does not
    /// describe the file. The run reads nothing, repairs nothing, and the
    /// copy goes on the keeper alone.
    @Test func aPoisonedStoredFixityIsNeverCounted() async throws {
        let dir = tempDir("poison"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let fam = addFamily(to: model, in: dir, name: "z", siblings: 1)
        let digest = plainSHA256(URL(fileURLWithPath: fam.keeper.fullPath))
        let foreign = try #require(FileIdentityStamp.capture(path: fam.keeper.fullPath))
        let poisoned = ContentFixity(digest: digest, byteCount: Int64(fileSize), stamp: foreign)
        fam.siblings[0].contentFixity = poisoned
        let probe = Probe(); let sink = InMemoryLogSink()
        let job = makeJob(model, dir, probe, sink: sink)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 1, "\(row.tierReason ?? row.note)")
        #expect(row.tierReason?.contains("z-sib1.mov on ") == true && row.tierReason?.contains("changed since it was verified") == true,
                Comment(rawValue: row.tierReason ?? ""))
        #expect(probe.blocks("sibling") == 0, "nothing is read")
        #expect(fam.siblings[0].contentFixity == poisoned, "the run does not rewrite evidence it did not produce")
    }
}

// MARK: - Forecast honesty and siblings that must never count (QA round 3)

private let r3Size = FileHasher.segmentSize * 3
private func r3Dir(_ l: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_qa3_\(l)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
}
private func r3Write(_ u: URL, _ b: [UInt8]) { FileManager.default.createFile(atPath: u.path, contents: Data(b)) }
private func r3SHA(_ u: URL) -> String { SHA256.hash(data: (try? Data(contentsOf: u)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
@MainActor private func r3Model(_ d: URL) -> VideoScanModel {
    let m = VideoScanModel()
    m.catalogStore = CatalogStore(directory: d.appendingPathComponent("catalog", isDirectory: true))
    m.mediaLedger = MediaLedger(directory: d.appendingPathComponent("ledger", isDirectory: true))
    return m
}
@MainActor private func r3Rec(_ p: String, _ g: UUID, _ d: DuplicateDisposition, fixity: Bool = false) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = p; r.filename = (p as NSString).lastPathComponent; r.directory = (p as NSString).deletingLastPathComponent
    r.sizeBytes = Int64(r3Size); r.partialMD5 = "same"; r.durationSeconds = 61
    r.duplicateGroupID = g; r.duplicateDisposition = d; r.duplicateConfidence = .high
    if fixity { r.contentFixity = ContentFixity.captured(path: p, digest: r3SHA(URL(fileURLWithPath: p)), byteCount: Int64(r3Size)) }
    return r
}
private final class R3Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    func blocks(_ l: String) -> Int { lock.withLock { blocks[l] ?? 0 } }
    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] l in lock.withLock { blocks[l, default: 0] += 1 } })
    }
}
/// keeper + one extra "copy.mov" (+ `extraSibling` so the group has three
/// copies and the bulk run takes it); returns model, keeper, copy, bytes, group.
@MainActor private func r3Family(_ dir: URL, keeperFixity: Bool = true) -> (VideoScanModel, VideoRecord, VideoRecord, [UInt8], UUID) {
    let bytes = (0..<r3Size).map { UInt8($0 % 197) }
    let g = UUID()
    let k = dir.appendingPathComponent("keeper.mov"); r3Write(k, bytes)
    let c = dir.appendingPathComponent("copy.mov"); r3Write(c, bytes)
    let m = r3Model(dir)
    let keeper = r3Rec(k.path, g, .keep, fixity: keeperFixity)
    let copy = r3Rec(c.path, g, .extraCopy)
    m.records = [keeper, copy]
    return (m, keeper, copy, bytes, g)
}
@MainActor private func r3Job(_ m: VideoScanModel, _ dir: URL, _ p: R3Probe) -> DeleteDuplicatesJob {
    let j = DeleteDuplicatesJob(model: m, volumePath: dir.path, hooks: p.hooks.withScratchTrash(in: dir),
                                planRoot: dir.appendingPathComponent("plans", isDirectory: true))
    j.appLogSink = InMemoryLogSink()
    j.mediaTechForPath = { _ in .ssd }
    return j
}

@Suite("Delete Duplicates — the forecast never promises what the run refuses (QA round 3)", .serialized)
@MainActor
struct DeleteDuplicatesForecastHonestyTests {
    /// Keeper WITHOUT a stored fixity; a sibling with stored evidence of
    /// DIFFERENT bytes. The sibling decides nothing: the run reads the keeper
    /// and the copy, finds them identical, and keeps one → the Trash. The
    /// forecast says the same.
    @Test func aSiblingOfOtherBytesChangesNeitherTheForecastNorTheRun() async throws {
        let dir = r3Dir("fc-digest"); defer { try? FileManager.default.removeItem(at: dir) }
        let (m, _, copy, bytes, g) = r3Family(dir, keeperFixity: false)
        var other = bytes; other[7] ^= 0x44
        let s = dir.appendingPathComponent("sib.mov"); r3Write(s, other)
        m.records.append(r3Rec(s.path, g, .review, fixity: true))
        let forecast = m.deleteDuplicatesForecast(onVolume: dir.path)
        let p = R3Probe(); let job = r3Job(m, dir, p)
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed, "\(row.status) \(row.tierReason ?? row.note)")
        #expect(forecast.bucket(for: copy.id) == .trash, "forecast said \(String(describing: forecast.bucket(for: copy.id)))")
    }

    /// Two catalog records for ONE sibling file: the forecast and the run
    /// agree (the Trash), and the run counts the file once.
    @Test func oneSiblingFileUnderTwoRecordsIsCountedOnce() async throws {
        let dir = r3Dir("fc-twice"); defer { try? FileManager.default.removeItem(at: dir) }
        let (m, _, copy, bytes, g) = r3Family(dir)
        let s = dir.appendingPathComponent("sib.mov"); r3Write(s, bytes)
        m.records.append(r3Rec(s.path, g, .review, fixity: true))
        m.records.append(r3Rec(s.path, g, .review, fixity: true))
        let forecast = m.deleteDuplicatesForecast(onVolume: dir.path)
        let p = R3Probe(); let job = r3Job(m, dir, p)
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 2, "\(row.status) \(row.tierReason ?? row.note)")
        #expect(forecast.bucket(for: copy.id) == .trash, "forecast said \(String(describing: forecast.bucket(for: copy.id)))")
    }
}

@Suite("Delete Duplicates (QA round 3) — siblings that must never count", .serialized)
@MainActor
struct DeleteDuplicatesSiblingNeverCountsTests {

    /// (a) a sibling record naming the DUPLICATE through a case variant,
    /// with "current" stored evidence: never another copy.
    @Test func caseVariantOfTheDuplicateNeverCounts() async throws {
        let dir = r3Dir("case"); defer { try? FileManager.default.removeItem(at: dir) }
        let (m, _, _, _, g) = r3Family(dir)
        let variant = dir.appendingPathComponent("COPY.mov").path
        try #require(FileManager.default.fileExists(atPath: variant), "needs a case-insensitive temp volume")
        m.records.append(r3Rec(variant, g, .review, fixity: true))
        let p = R3Probe(); let job = r3Job(m, dir, p)
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.remainingVerifiedCopies == 1, "the variant is the copy itself: \(row.tierReason ?? row.note)")
    }

    /// (a)/(b) symlinked siblings: one → keeper, one → the duplicate.
    /// Neither is another copy, and neither is read.
    @Test func symlinksToTheKeeperOrTheDuplicateNeverCount() async throws {
        let dir = r3Dir("symlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let (m, keeper, copy, _, g) = r3Family(dir)
        let toKeeper = dir.appendingPathComponent("link-keeper.mov")
        let toCopy = dir.appendingPathComponent("link-copy.mov")
        try FileManager.default.createSymbolicLink(atPath: toKeeper.path, withDestinationPath: keeper.fullPath)
        try FileManager.default.createSymbolicLink(atPath: toCopy.path, withDestinationPath: copy.fullPath)
        m.records.append(r3Rec(toKeeper.path, g, .review, fixity: true))
        m.records.append(r3Rec(toCopy.path, g, .review, fixity: true))
        let p = R3Probe(); let job = r3Job(m, dir, p)
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.remainingVerifiedCopies == 1, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(p.blocks("sibling") == 0, "neither link is read")
        #expect(FileManager.default.fileExists(atPath: keeper.fullPath), "the keeper stays, under every name")
    }

    /// (c) two catalog records for ONE sibling file, and a hard link of it:
    /// each counted once.
    @Test func oneSiblingInodeReachedTwiceCountsOnce() async throws {
        let dir = r3Dir("twice"); defer { try? FileManager.default.removeItem(at: dir) }
        let (m, _, copy, bytes, g) = r3Family(dir)
        let s = dir.appendingPathComponent("sib.mov"); r3Write(s, bytes)
        let h = dir.appendingPathComponent("sib-hardlink.mov")
        try FileManager.default.linkItem(atPath: s.path, toPath: h.path)
        m.records.append(r3Rec(s.path, g, .review, fixity: true))
        m.records.append(r3Rec(s.path, g, .review, fixity: true))     // same path, second record
        m.records.append(r3Rec(h.path, g, .review, fixity: true))     // hard link
        let p = R3Probe(); let job = r3Job(m, dir, p)
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 2, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(!FileManager.default.fileExists(atPath: copy.fullPath))
        #expect(FileManager.default.fileExists(atPath: s.path))
    }

    /// A sibling that cannot be read (permission): never read, never
    /// counted, nothing stored.
    @Test func anUnreadableSiblingIsNeverAMatch() async throws {
        let dir = r3Dir("perm"); defer { try? FileManager.default.removeItem(at: dir) }
        let (m, _, _, bytes, g) = r3Family(dir)
        let s = dir.appendingPathComponent("sib.mov"); r3Write(s, bytes)
        chmod(s.path, 0)
        defer { chmod(s.path, 0o644) }
        let sib = r3Rec(s.path, g, .review); m.records.append(sib)
        let p = R3Probe(); let job = r3Job(m, dir, p)
        job.start(); await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.remainingVerifiedCopies == 1, "\(row.status): \(row.tierReason ?? row.note)")
        #expect(sib.contentFixity == nil, "nothing stored for a file that was not read")
    }
}
