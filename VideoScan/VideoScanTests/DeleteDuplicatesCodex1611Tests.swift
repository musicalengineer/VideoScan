// DeleteDuplicatesCodex1611Tests.swift
// Regression for codex #1611 (review 1606 #4, the last open item on the
// Delete Duplicates job): the copy-count TIER was decided from a stat of
// the family's other copies, then the ticket save was awaited, and phase
// two re-checked only the target and the keeper — never the OTHER copies
// the count rested on. Rewrite or remove a counted sibling during that
// await and the stale tier stood: a permanent unlink with only two intact
// copies left, or a Trash move with only the keeper left.
//
// Now every counted copy's evidence (record id, path, the full stamp it
// reproduced — ctime included — and the digest it was counted under)
// rides on the plan row, and phase two re-stats each one immediately
// before the unlink / Trash move: a copy whose stamp no longer reproduces
// (or is gone) is dropped and the tier re-decided from what still holds.
//   permanent → Trash          when the count falls to two;
//   anything → put back        when it falls below two (the row names the
//                              copy that changed — left alone, its
//                              disposition kept);
//   unchanged                  otherwise — the row is not rewritten and
//                              the keeper is not read (stat only).
//
// All deterministic through `testHookAfterQuarantineSaved`, the seam that
// runs between the ticket save and phase two. Files live under the process
// temp dir; the Trash step is routed into a scratch folder.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dup1611_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

private func plainSHA256(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let blockSize = FileHasher.segmentSize
private let fileSize = blockSize * 3

/// Rewrite the file IN PLACE through a descriptor (same inode, same
/// size) and put the mtime back to the nanosecond — device / inode /
/// size / mtime all reproduce afterwards; only the kernel ctime (and the
/// bytes) differ. The codex harness's corruption.
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
    var after = stat()
    try #require(stat(url.path, &after) == 0)
    try #require(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                 && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
                 && after.st_ino == before.st_ino && after.st_size == before.st_size)
}

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

/// Block counter + open counter per basename (thread-safe): the keeper
/// must never be OPENED by the boundary re-check, not merely not hashed.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    private var opens: [String: Int] = [:]

    func blocks(_ label: String) -> Int { lock.withLock { blocks[label] ?? 0 } }
    func opens(_ basename: String) -> Int { lock.withLock { opens[basename] ?? 0 } }

    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in lock.withLock { blocks[label, default: 0] += 1 } },
            didOpen: { [self] path in
                let name = (path as NSString).lastPathComponent
                lock.withLock { opens[name, default: 0] += 1 }
            })
    }
}

/// The console flushes on the main actor a beat after the log call.
@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 300_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

private func quarantineFolders(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

/// keeper (stored fixity) + one identical extra + the verified archive
/// family (archive + sibling, both with stamp-bound fixity) → three
/// verified copies remain after the extra goes → PERMANENT, until the
/// hook meddles with a counted copy.
@MainActor
private struct Rig {
    let dir: URL
    let root: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let copy: VideoRecord
    let archive: VideoRecord?
    let sibling: VideoRecord?
    let bytes: [UInt8]

    init(_ label: String, withSibling: Bool = true) {
        dir = tempDir(label)
        root = dir.appendingPathComponent("plans", isDirectory: true)
        bytes = (0..<fileSize).map { UInt8($0 % 197) }
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let group = UUID()
        model = makeModel(dir)
        keeper = dupRecord(path: keeperURL.path, size: Int64(fileSize), group: group, disposition: .keep)
        keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL), byteCount: Int64(fileSize))
        let c = dir.appendingPathComponent("copy1.mov"); write(c, bytes)
        copy = dupRecord(path: c.path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        model.records = [keeper, copy]
        let family = addVerifiedArchiveFamily(to: model, keeper: keeper, withSibling: withSibling)
        archive = family.archive
        sibling = family.sibling
    }

    var copyURL: URL { URL(fileURLWithPath: copy.fullPath) }
    var trashedCopyURL: URL { dir.appendingPathComponent("Trash/copy1.mov") }

    func job(_ probe: Probe) -> DeleteDuplicatesJob {
        DeleteDuplicatesJob(model: model, volumePath: dir.path,
                            hooks: probe.hooks.withScratchTrash(in: dir), planRoot: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Codex 1611 — counted copies are re-checked at the removal boundary", .serialized)
@MainActor
struct DeleteDuplicatesCountedEvidenceCodex1611Tests {

    /// The pure re-check: every counted copy must reproduce the exact
    /// stamp it was counted on. One rewritten in place (mtime put back)
    /// is dropped and named; one removed is dropped and named; nothing is
    /// ever added; unchanged evidence returns the facts untouched.
    @Test func recheckDropsOnlyTheCopiesWhoseStampNoLongerReproduces() throws {
        let dir = tempDir("recheck"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<4_096).map { UInt8($0 % 13) }
        let a = dir.appendingPathComponent("a.mov"); write(a, bytes)
        let b = dir.appendingPathComponent("b.mov"); write(b, bytes)
        let c = dir.appendingPathComponent("c.mov"); write(c, bytes)
        let digest = plainSHA256(a)
        var cand = DeletionTierCandidates()
        cand.keeperLabel = "keeper on LaCieWorkspace"
        cand.archiveCopies = [.init(path: a.path, digest: digest, sizeBytes: 4_096,
                                    fixity: ContentFixity.captured(path: a.path, digest: digest, byteCount: 4_096),
                                    label: "archive copy on FamilyArchive", recordID: UUID())]
        cand.otherCopies = [
            .init(path: b.path, fixity: ContentFixity.captured(path: b.path, digest: digest, byteCount: 4_096), label: "sibling b.mov on SanDisk", recordID: UUID()),
            .init(path: c.path, fixity: ContentFixity.captured(path: c.path, digest: digest, byteCount: 4_096), label: "sibling c.mov on SanDisk", recordID: UUID()),
        ]
        let facts = DeletionTierFacts.gather(cand, digest: digest)
        #expect(facts.remainingVerifiedCopies == 4 && facts.countedCopies.count == 3)
        #expect(facts.keeperCounted == "keeper on LaCieWorkspace" && facts.counted.first == facts.keeperCounted)
        #expect(facts.countedCopies.map(\.label) == ["archive copy on FamilyArchive", "sibling b.mov on SanDisk", "sibling c.mov on SanDisk"])
        #expect(facts.countedCopies.allSatisfy { $0.digest == digest && $0.stamp.hasChangeTime && $0.recordID != nil })

        // Unchanged: the very same facts come back.
        #expect(facts.recheck() == facts && facts.recheck().droppedAtBoundary.isEmpty)

        // b rewritten in place (mtime put back), c removed; a untouched.
        var corrupt = bytes; corrupt[100] ^= 0x01
        try rewriteInPlace(b, bytes: corrupt)
        try FileManager.default.removeItem(at: c)
        let now = facts.recheck()
        #expect(now.remainingVerifiedCopies == 2, Comment(rawValue: now.summary))
        #expect(now.counted == ["keeper on LaCieWorkspace", "archive copy on FamilyArchive"])
        #expect(now.countedCopies.map(\.label) == ["archive copy on FamilyArchive"])
        #expect(now.droppedAtBoundary == ["sibling b.mov on SanDisk changed since it was counted",
                                          "sibling c.mov on SanDisk gone since it was counted (removed or offline)"])
        #expect(now.notCounted.prefix(2).elementsEqual(now.droppedAtBoundary), "the dropped copies are named first in the reason")
        #expect(now.unverifiedCopies == facts.unverifiedCopies + 2)
        #expect(DeletionTierDecision.decide(facts: now, preferTrash: false).tier == .trash)
        #expect(DeletionTierDecision.decide(facts: facts, preferTrash: false).tier == .permanent)

        // A copy that came back is never ADDED at the boundary: c exists
        // again with the right bytes, but under a new inode / ctime.
        write(c, bytes)
        let again = facts.recheck()
        #expect(again.remainingVerifiedCopies == 2 && again.droppedAtBoundary.count == 2,
                "c is back but its stamp is new: still dropped (\(again.summary))")
    }

    /// (a) A counted SIBLING is rewritten in place the same size with the
    /// mtime put back while the ticket is being saved: only its kernel
    /// ctime tells. The tier falls from permanent to the Trash; the row
    /// and the ledger say which copy changed.
    @Test func rewrittenSiblingDowngradesPermanentToTrash() async throws {
        let rig = Rig("sibling-rewritten"); defer { rig.cleanup() }
        let sibling = try #require(rig.sibling)
        let probe = Probe()
        let job = rig.job(probe)
        var tierWhenSaved: DeletionTier?
        job.testHookAfterQuarantineSaved = { [weak job] entry in
            tierWhenSaved = job?.plan?.entries.first { $0.id == entry.id }?.tier
            var corrupt = rig.bytes; corrupt[blockSize + 5] ^= 0x7E
            try? rewriteInPlace(URL(fileURLWithPath: sibling.fullPath), bytes: corrupt)
        }
        job.start(); await job.task?.value

        #expect(tierWhenSaved == .permanent, "three verified copies at the save: the tier was permanent")
        #expect(sibling.contentFixity?.stampMatches(path: sibling.fullPath) == true, "the user-visible stamp still reproduces — only ctime tells")
        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .trashed && row.tier == .trash, "\(row.status): \(row.tierReason ?? "")")
        #expect(row.remainingVerifiedCopies == 2)
        let reason = try #require(row.tierReason)
        #expect(reason.contains("sibling verified-sibling-of-keeper.mov on ") && reason.contains("changed since it was counted"),
                Comment(rawValue: reason))
        #expect(!FileManager.default.fileExists(atPath: rig.copy.fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.trashedCopyURL.path), "to the Trash, not gone")
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        #expect(job.result.bytesFreed == 0 && job.result.deleted == 1)
        #expect(probe.opens("keeper.mov") == 0, "the keeper is stat'ed, never read")
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed || $0.event == .copyDeleted }
        #expect(events.count == 1 && events.first?.event == .copyTrashed)
        #expect(events.first?.detail[MediaLedgerEvent.Detail.tier] == "trash")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.remainingVerifiedCopies] == "2")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.reason]?.contains("changed since it was counted") == true)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root)
            .appendingPathComponent(DeleteDuplicatesPlan.planFilename))
        #expect(onDisk.entries[0].tier == .trash && onDisk.entries[0].tierReason == reason, "the final tier is what the plan on disk says")
        let console = await consoleText(rig.model)
        #expect(console.contains("re-checked before removal") && console.contains("Trash"), Comment(rawValue: console))
    }

    /// (b) A counted sibling is REMOVED during the save: keeper + archive
    /// still make two → the Trash. With the archive gone as well (keeper
    /// only), the file is put back at its original path, untouched, and
    /// the row names both copies; the record keeps its disposition.
    @Test func removedSiblingDowngradesOrPutsBack() async throws {
        for variant in ["siblingOnly", "siblingAndArchive"] {
            let rig = Rig("sibling-removed-\(variant)"); defer { rig.cleanup() }
            let sibling = try #require(rig.sibling)
            let archive = try #require(rig.archive)
            let probe = Probe()
            let job = rig.job(probe)
            job.testHookAfterQuarantineSaved = { _ in
                try? FileManager.default.removeItem(atPath: sibling.fullPath)
                if variant == "siblingAndArchive" { try? FileManager.default.removeItem(atPath: archive.fullPath) }
            }
            job.start(); await job.task?.value

            let plan = try #require(job.plan)
            let row = plan.entries[0]
            #expect(quarantineFolders(in: rig.dir).isEmpty, Comment(rawValue: variant))
            #expect(probe.opens("keeper.mov") == 0, "\(variant): the keeper is never read")
            if variant == "siblingOnly" {
                #expect(row.status == .trashed && row.tier == .trash && row.remainingVerifiedCopies == 2,
                        "\(variant): \(row.status): \(row.tierReason ?? "")")
                #expect(row.tierReason?.contains("sibling verified-sibling-of-keeper.mov on ") == true
                        && row.tierReason?.contains("gone since it was counted") == true, Comment(rawValue: row.tierReason ?? ""))
                #expect(FileManager.default.fileExists(atPath: rig.trashedCopyURL.path), "\(variant): to the Trash")
                #expect(!FileManager.default.fileExists(atPath: rig.copy.fullPath))
                #expect(job.result.deleted == 1 && job.result.bytesFreed == 0)
            } else {
                #expect(row.status == .skipped && row.tier == nil && row.remainingVerifiedCopies == 1,
                        "\(variant): \(row.status): \(row.note)")
                #expect(row.note.contains("sibling verified-sibling-of-keeper.mov on ") && row.note.contains("archive copy on ")
                        && row.note.contains("gone since it was counted"), Comment(rawValue: row.note))
                #expect(row.note.contains("left alone"), Comment(rawValue: row.note))
                #expect(FileManager.default.fileExists(atPath: rig.copy.fullPath), "\(variant): put back at its original path")
                #expect((try? Data(contentsOf: rig.copyURL)) == Data(rig.bytes), "\(variant): untouched")
                #expect(!FileManager.default.fileExists(atPath: rig.trashedCopyURL.path))
                #expect(job.result.deleted == 0 && job.result.bytesFreed == 0)
                #expect(rig.copy.duplicateDisposition == .extraCopy, "left alone keeps the disposition — not a refusal of the pair")
                await rig.model.mediaLedger.waitForPendingWrites()
                let removals = rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed || $0.event == .copyDeleted }
                #expect(removals.isEmpty, "\(variant): nothing left the disk")
                let console = await consoleText(rig.model)
                #expect(console.contains("put back") && console.contains("gone since it was counted"), Comment(rawValue: console))
            }
        }
    }

    /// (c) A counted ARCHIVE copy is rewritten in place during the save
    /// (size and mtime intact): it is dropped like any sibling → the
    /// Trash, and the reason names the archive copy.
    @Test func rewrittenArchiveCopyDowngradesPermanentToTrash() async throws {
        let rig = Rig("archive-rewritten"); defer { rig.cleanup() }
        let archive = try #require(rig.archive)
        let probe = Probe()
        let job = rig.job(probe)
        job.testHookAfterQuarantineSaved = { _ in
            var corrupt = rig.bytes; corrupt[blockSize * 2 + 9] ^= 0x11
            try? rewriteInPlace(URL(fileURLWithPath: archive.fullPath), bytes: corrupt)
        }
        job.start(); await job.task?.value

        #expect(archive.contentFixity?.stampMatches(path: archive.fullPath) == true, "user-visible stamp unchanged")
        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .trashed && row.tier == .trash && row.remainingVerifiedCopies == 2, "\(row.status): \(row.tierReason ?? "")")
        #expect(row.tierReason?.contains("archive copy on ") == true && row.tierReason?.contains("changed since it was counted") == true,
                Comment(rawValue: row.tierReason ?? ""))
        #expect(row.hasVerifiedArchive == true, "on record the family is archived — informational only")
        #expect(FileManager.default.fileExists(atPath: rig.trashedCopyURL.path), "to the Trash, not gone")
        #expect(FileManager.default.fileExists(atPath: archive.fullPath), "the archive itself is never touched")
        #expect(job.result.bytesFreed == 0 && job.result.deleted == 1)
        #expect(probe.opens("keeper.mov") == 0)
    }

    /// (d) Nothing changed during the save: the tier stands as decided,
    /// the row is not rewritten, the file is unlinked, and the keeper was
    /// neither opened nor hashed — the re-check is stat only.
    @Test func unchangedEvidenceKeepsTheTierAndNeverReadsTheKeeper() async throws {
        let rig = Rig("unchanged"); defer { rig.cleanup() }
        let probe = Probe()
        let job = rig.job(probe)
        var reasonWhenSaved: String?
        var evidenceOnDisk: [DeletionTierFacts.CountedCopy]?
        var hookRan = false
        job.testHookAfterQuarantineSaved = { [weak job] entry in
            hookRan = true
            guard let plan = job?.plan else { return }
            reasonWhenSaved = plan.entries.first { $0.id == entry.id }?.tierReason
            // The evidence is ON DISK before phase two — the saved ticket
            // carries what the count rests on.
            let saved = try? DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
            evidenceOnDisk = saved?.entries.first { $0.id == entry.id }?.countedCopies
        }
        job.start(); await job.task?.value

        #expect(hookRan)
        let evidence = try #require(evidenceOnDisk)
        #expect(evidence.count == 2, "archive + sibling — the keeper is not listed (its identity is on the ticket)")
        #expect(Set(evidence.compactMap(\.recordID)) == Set([rig.archive?.id, rig.sibling?.id].compactMap { $0 }))
        #expect(evidence.allSatisfy { $0.stamp.hasChangeTime && $0.digest == rig.keeper.contentFixity?.digest })
        #expect(Set(evidence.map(\.path)) == Set([rig.archive?.fullPath, rig.sibling?.fullPath].compactMap { $0 }))
        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .deleted && row.tier == .permanent && row.remainingVerifiedCopies == 3, "\(row.status): \(row.tierReason ?? "")")
        #expect(row.tierReason == reasonWhenSaved, "unchanged evidence: the row keeps the reason it was saved with")
        #expect(row.tierReason?.hasPrefix("space back now") == true, Comment(rawValue: row.tierReason ?? ""))
        #expect(!FileManager.default.fileExists(atPath: rig.copy.fullPath) && !FileManager.default.fileExists(atPath: rig.trashedCopyURL.path))
        #expect(job.result.deleted == 1 && job.result.bytesFreed == Int64(fileSize))
        #expect(probe.opens("keeper.mov") == 0 && probe.blocks("keeper") == 0, "keeper stat'ed, never read")
        #expect(probe.blocks("quarantine") == 3, "the one read of the duplicate; nothing else")
        let console = await consoleText(rig.model)
        #expect(!console.contains("re-checked before removal"), "nothing to say when nothing changed")
    }
}
