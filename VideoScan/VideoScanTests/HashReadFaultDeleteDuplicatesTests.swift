// HashReadFaultDeleteDuplicatesTests.swift
// NEGATIVE MATRIX — Delete Duplicates (the verb that sends duplicate files to
// the Trash) under a faulted full read (dedupe hash read seam, 2026-11-21).
// END TO END: `MediaFileOperationsCenter.startDeleteDuplicates` → the job →
// its detached disk workers → `SignatureVerification` → the test-host Trash
// (`MediaTrash.move`), with the production hooks (`.live`). The fault is bound
// on the test's task and reaches the workers by value
// (`Hooks.carryingReadHook()`).
//
// THE RULE: a file goes to the Trash only when BOTH files were proven by
// complete reads with equal digests; under a fault the outcome is named
// (refused / could not be read / mismatch), never success; no fixity is
// recorded from a faulted read; the row line, the audit line, the receipt and
// the plan journal all say what happened.
//
// Reads, by path of the gate:
//   UNCACHED keeper (no stored fixity) — "two-file path": the KEEPER in full,
//     the DUPLICATE in full at its path, then, in quarantine, the RE-HASH.
//   CACHED keeper (stamp-valid stored fixity) — "single-read path": the
//     duplicate is moved into quarantine and read ONCE there. The keeper is
//     never read.
//   SIBLING proof: unreachable from the job since KEEP ONE (2026-10-09) — the
//     keeper alone reaches the goal, so no sibling is read. Pinned
//     (`theJobReadsNoSibling`), and the matrix is run on `SiblingProver.prove`.
//
// MATRIX, files byte-identical (read × fault → outcome; nothing reaches the
// Trash in any cell but the benign partial read):
//
//   read                 EIO mid-file            premature EOF           bit flip                     partial read
//   KEEPER               refused "could not      refused "could not      refused "content differs —   trashed
//                        read <keeper>"          read <keeper>"          NOT a duplicate"             (proven)
//                                                                        + P1: the FLIPPED digest is
//                                                                        STORED as the keeper's fixity
//   DUPLICATE at path    refused "could not      refused "could not      refused "content differs —   trashed
//                        read <dup>"             read <dup>"             NOT a duplicate"
//   quarantine RE-HASH   put back; P3: named     put back; P3: named     put back "<dup> changed      trashed
//                        "<dup> changed during   "<dup> changed during   during verification"
//                        verification"           verification"
//   quarantine SINGLE    put back "could not     put back "could not     put back "content differs —  trashed
//   READ (cached keeper) read <dup>"             read <dup>"             NOT a duplicate"
//   SIBLING (prover)     "could not be read —    "could not be read —    "differs" + P1: the FLIPPED  matches
//                        not counted"            not counted"            digest is the sibling's
//                                                                        fixity (stored by the job)
//
// CODEX'S SHAPES (GH #504):
//   A  the duplicate is the keeper's bytes + a tail, its read ends at the
//      keeper's length — CLOSED: the size gate refuses before any read, and
//      the hasher compares bytes consumed with the size (seam suite).
//   B  two files ONE BIT apart, the flip lands on that bit:
//        in the KEEPER's read (uncached)       → 🔴 P0: THE DUPLICATE IS TRASHED
//        in the duplicate's read at its path   → held: the quarantine re-read disagrees
//        in the SINGLE quarantine read (cached)→ 🔴 P0: THE DUPLICATE IS TRASHED
//   C  a stale/false but stamp-valid CACHED keeper fixity → 🔴 P0 (Codex r1:
//      "persistent removal authority, not merely bad metadata"): the keeper is
//      NOT re-read; a file holding the cached digest's bytes is trashed with
//      every read clean. The poisoned cache is SUPPLIED by the P1 in the
//      matrix's keeper/bit-flip cell: a refused pair still publishes the
//      flipped keeper fixity (DeleteDuplicatesJob.swift ~:1556).
//
// Every misbehaviour is parked under `withKnownIssue` with severity, what
// happens, where the media ends up and a proposed fix. NOTHING IS FIXED HERE
// (data-risk code: Rick and Codex, rule 10). The Trash is recoverable: in
// every P0 below the file is in the Trash, intact, and the keeper is intact.
//
// Parallel-safe: a temp folder per test; unique file names (the test-host
// Trash is one shared folder); task-local hook and log.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixture

private let block = FileHasher.segmentSize
/// Past the 4 MiB head compare (which is not a full-file hash and is not
/// seamed), so a difference at `faultByte` is only visible to the full reads.
private let fileBytes = SignatureVerification.headCompareBytes + 2 * block
private let faultByte = Int64(SignatureVerification.headCompareBytes + block + 777)

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

enum DedupeReadSite: String, Sendable, CaseIterable, CustomStringConvertible {
    case keeper, duplicateAtPath, quarantineRehash, quarantineSingleRead
    var description: String { rawValue }
    /// The single-read path needs the keeper's stored fixity.
    var cachedKeeper: Bool { self == .quarantineSingleRead }
}

struct DedupeFaultCell: Sendable, CustomStringConvertible {
    let site: DedupeReadSite
    let kind: DedupeFaultKind
    var description: String { "\(kind) in the \(site) read" }
    static let all: [DedupeFaultCell] = DedupeReadSite.allCases.flatMap { site in
        DedupeFaultKind.allCases.map { DedupeFaultCell(site: site, kind: $0) }
    }
}

@MainActor
private struct Rig {
    let dir: URL
    let plans: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let dup: VideoRecord
    let keeperData: Data
    let dupData: Data
    var keeperName: String { keeper.filename }
    var dupName: String { dup.filename }
    var trashURL: URL { MediaTrash.testHostTrash.appendingPathComponent(dupName) }
    var inTrash: Bool { FileManager.default.fileExists(atPath: trashURL.path) }
    var atPath: Bool { FileManager.default.fileExists(atPath: dup.fullPath) }
    var quarantineFolders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: trashURL)
    }

    /// The fault's target, by the REAL path of the descriptor being read.
    func fault(_ kind: DedupeFaultKind, _ site: DedupeReadSite, atByte: Int64 = faultByte) -> DedupeReadFault {
        let keeperName = keeperName, dupName = dupName
        let quarantine = SignatureVerification.quarantineDirectoryPrefix
        switch site {
        case .keeper:
            return DedupeReadFault(kind, where: { $0.hasSuffix("/" + keeperName) }, atByte: atByte)
        case .duplicateAtPath:
            return DedupeReadFault(kind, where: { $0.hasSuffix("/" + dupName) && !$0.contains(quarantine) }, atByte: atByte)
        case .quarantineRehash, .quarantineSingleRead:
            return DedupeReadFault(kind, where: { $0.hasSuffix("/" + dupName) && $0.contains(quarantine) }, atByte: atByte)
        }
    }
}

@MainActor
private func record(_ url: URL, size: Int, group: UUID, _ disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = url.path
    r.filename = url.lastPathComponent
    r.directory = url.deletingLastPathComponent().path
    r.sizeBytes = Int64(size)
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

/// A keeper and ONE extra copy. `duplicate` = the extra's bytes (default: the
/// keeper's). `cachedKeeper` stores the keeper's TRUE stamp-bound fixity.
@MainActor
private func makeRig(_ label: String, cachedKeeper: Bool, duplicate: ((Data) -> Data)? = nil) throws -> Rig {
    let dir = dedupeSeamTempDir(label)
    let tag = UUID().uuidString.prefix(8)
    let keeperData = hashSeamBlob(bytes: fileBytes, seed: 4_242)
    let dupData = duplicate?(keeperData) ?? keeperData
    let keeperURL = dir.appendingPathComponent("test_keeper_\(tag).mov")
    let dupURL = dir.appendingPathComponent("test_dup_\(tag).mov")
    try keeperData.write(to: keeperURL)
    try dupData.write(to: dupURL)
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    let group = UUID()
    let keeper = record(keeperURL, size: keeperData.count, group: group, .keep)
    let dup = record(dupURL, size: dupData.count, group: group, .extraCopy)
    if cachedKeeper {
        keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: sha(keeperData),
                                                      byteCount: Int64(keeperData.count))
    }
    model.records = [keeper, dup]
    return Rig(dir: dir, plans: dir.appendingPathComponent("plans", isDirectory: true), model: model,
               keeper: keeper, dup: dup, keeperData: keeperData, dupData: dupData)
}

/// What one run left behind — everything the assertions read.
@MainActor
private struct Ran {
    let job: DeleteDuplicatesJob
    let log: String
    let row: DeleteDuplicatesPlan.Entry
    let receipt: String
    let journal: String
    /// "[dupjob] refused …" / "[dupjob] trashed …" for the duplicate.
    var rowLine: String { log.components(separatedBy: "\n").first { $0.hasPrefix("[dupjob] ") && !$0.contains("audit:") && $0.contains("test_dup_") } ?? "" }
    var auditLine: String { log.components(separatedBy: "\n").first { $0.hasPrefix("[dupjob] audit: ") && $0.contains("test_dup_") } ?? "" }
    var outcomeLine: String { log.components(separatedBy: "\n").first { $0.hasPrefix("[dupjob] audit: OUTCOME") } ?? "" }
    var summaryLine: String { log.components(separatedBy: "\n").first { $0.hasPrefix("delete duplicates done:") } ?? "" }
}

/// Run Delete Duplicates through the Center, with `hook` (a fault, a counter,
/// or nothing) bound around it and the app log captured.
@MainActor
private func runThroughTheCenter(_ rig: Rig, hook: ArchivePromoteEngine.ReadHook?) async throws -> Ran {
    let sink = InMemoryLogSink()
    let center = MediaFileOperationsCenter()
    var started: DeleteDuplicatesJob?
    await withAppLog(sink) {
        await ArchivePromoteEngine.$readHook.withValue(hook) {
            let job = center.startDeleteDuplicates(onVolume: rig.dir.path, model: rig.model, planRoot: rig.plans)
            started = job
            await job.task?.value
        }
        _ = await sink.waitForLine(containing: "[dupjob] audit: OUTCOME")
    }
    let job = try #require(started)
    #expect(!job.wasRefused, "the Center refused the run: \(job.state)")
    let plan = try #require(job.plan)
    let row = try #require(plan.entries.first { $0.path == rig.dup.fullPath }, "the duplicate is a row of the plan")
    let receipt = job.receiptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    let filed = DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.plans).appendingPathComponent("plan.json")
    let journal = (try? String(contentsOf: filed, encoding: .utf8)) ?? ""
    if let url = job.receiptURL { try? FileManager.default.removeItem(at: url) }
    return Ran(job: job, log: sink.joined, row: row, receipt: receipt, journal: journal)
}

// MARK: - The matrix

@Suite("Hash read fault × Delete Duplicates — nothing reaches the Trash unless both files were proven by complete reads")
@MainActor
struct HashReadFaultDeleteDuplicatesTests {

    // MARK: 🔴 P0 — first, and unmistakable

    /// 🔴 P0 (parked). Codex shape B, flip in the KEEPER's read.
    /// The keeper has no stored fixity, so the gate reads both files. The
    /// duplicate differs from the keeper in ONE BIT; the keeper's one full
    /// read returns that bit flipped. The keeper's digest then equals the
    /// duplicate's, the duplicate's two reads (at its path, in quarantine)
    /// agree with each other, and the file GOES TO THE TRASH as "verified
    /// identical" — though no clean read of the keeper ever matched it. The
    /// flipped digest is also stored as the keeper's fixity (stamp-bound, so
    /// every later stamp-trusting reader believes it without a read).
    /// WHERE THE MEDIA IS: the duplicate is in the Trash, intact and
    /// recoverable; the keeper is untouched. Lost if the Trash is emptied:
    /// the only copy of the one-bit-different file.
    /// HOW REAL: it needs a wrong read whose error lands exactly on the
    /// difference between two otherwise identical files — far rarer than the
    /// read fault itself. It is here because the gate's claim is "every byte
    /// is compared", and for the keeper that rests on ONE read.
    /// PROPOSED FIX: the keeper is read a second time before the removal (it
    /// is the file that stays; the duplicate already gets its second read in
    /// quarantine) — or the first pair's keeper digest is confirmed by a
    /// second read before it is used or stored.
    @Test("🔴 P0 (parked): two files ONE BIT apart, the flip lands on that bit in the KEEPER's only read → the duplicate is sent to the Trash as 'verified identical', and the flipped digest is stored as the keeper's fixity")
    func p0_aFlippedKeeperReadTrashesAFileOneBitApart() async throws {
        let rig = try makeRig("p0keeper", cachedKeeper: false) { var d = $0; d[Int(faultByte)] ^= 0x01; return d }
        defer { rig.cleanup() }
        try #require(rig.keeperData != rig.dupData && sha(rig.keeperData) != sha(rig.dupData))
        let fault = rig.fault(.bitFlip, .keeper)
        let ran = try await runThroughTheCenter(rig, hook: fault.hook)
        #expect(fault.firedCount == 1, "the flip never reached the keeper's read")
        print("[hash-matrix] delete duplicates | shape B: flip on the differing bit, KEEPER read | \(ran.row.status) | \(ran.rowLine)")

        withKnownIssue("🔴 P0 PARKED 2026-11-21 (Delete Duplicates, two-file path): one flipped bit in the keeper's ONLY full read makes a file one bit apart 'verified identical' → it is moved to the Trash (recoverable; keeper untouched), and the flipped digest is stored as the keeper's stamp-bound fixity. SignatureVerification.verify reads the keeper once; nothing re-reads it before deleteQuarantined. Proposed: a second, fresh read of the keeper must agree before the removal (and before didComputeKeeperFixity stores anything).") {
            #expect(!rig.inTrash, "THE DUPLICATE IS IN THE TRASH on a keeper digest that came from a faulted read: \(rig.trashURL.path)")
            #expect(rig.atPath, "the duplicate is no longer at its path")
            #expect(ran.row.status == .refused, "the row says \(ran.row.status)")
            #expect(rig.keeper.contentFixity?.digest != sha(rig.dupData), "the keeper's stored fixity is the DUPLICATE's digest")
        }
        // Where the media is, whatever the verdict: both files exist, intact.
        let where_ = rig.inTrash ? rig.trashURL : URL(fileURLWithPath: rig.dup.fullPath)
        #expect(try Data(contentsOf: where_) == rig.dupData, "the duplicate's bytes are intact (Trash or path)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.keeper.fullPath)) == rig.keeperData)
        #expect(rig.quarantineFolders.isEmpty)
    }

    /// 🔴 P0 (parked). Codex shape B, flip in the SINGLE quarantine read.
    /// The keeper's stored fixity is true and current, so the duplicate is
    /// moved into quarantine and read ONCE. The duplicate differs from the
    /// keeper in one bit; that one read returns the bit flipped; the digest
    /// equals the keeper's stored one; the file goes to the Trash.
    /// WHERE THE MEDIA IS: in the Trash, intact, recoverable; keeper untouched.
    /// HOW REAL: as above — the wrong bit must be exactly the differing one.
    /// PROPOSED FIX: none cheap — a single read against a stored digest is the
    /// design of the single-read path (Rick 2026-09-20). A second read of the
    /// held file would double the I/O that path exists to save. Rick's call;
    /// the same question as GH #504's "is the cost of a second read
    /// acceptable?".
    @Test("🔴 P0 (parked): two files ONE BIT apart, the flip lands on that bit in the duplicate's SINGLE quarantine read (cached keeper) → the duplicate is sent to the Trash on one faulted read")
    func p0_aFlippedSingleReadTrashesAFileOneBitApart() async throws {
        let rig = try makeRig("p0single", cachedKeeper: true) { var d = $0; d[Int(faultByte)] ^= 0x01; return d }
        defer { rig.cleanup() }
        let fault = rig.fault(.bitFlip, .quarantineSingleRead)
        let keeperReads = DedupeReadCounter(where: { [name = rig.keeperName] in $0.hasSuffix("/" + name) })
        let both: ArchivePromoteEngine.ReadHook = { fd, offset, count in
            _ = keeperReads.hook(fd, offset, count)
            return fault.hook(fd, offset, count)
        }
        let ran = try await runThroughTheCenter(rig, hook: both)
        #expect(fault.firedCount == 1, "the flip never reached the quarantine read")
        #expect(fault.passCount == 1, "the held file was read exactly once")
        #expect(keeperReads.passCount == 0, "the keeper is never read on the single-read path")
        print("[hash-matrix] delete duplicates | shape B: flip on the differing bit, SINGLE quarantine read | \(ran.row.status) | \(ran.rowLine)")

        withKnownIssue("🔴 P0 PARKED 2026-11-21 (Delete Duplicates, single-read path): one flipped bit in the duplicate's ONLY read makes a file one bit apart from the keeper match the keeper's stored digest → it is moved to the Trash (recoverable; keeper untouched). verifyHeld hashes once; the ticket is `hashedInQuarantine`, so deleteQuarantined does not re-read. Proposed (Rick's call — it costs the read this path saves): a second read of the held file must agree before the Trash move.") {
            #expect(!rig.inTrash, "THE DUPLICATE IS IN THE TRASH on one faulted read: \(rig.trashURL.path)")
            #expect(rig.atPath)
            #expect(ran.row.status == .refused, "the row says \(ran.row.status)")
        }
        let where_ = rig.inTrash ? rig.trashURL : URL(fileURLWithPath: rig.dup.fullPath)
        #expect(try Data(contentsOf: where_) == rig.dupData)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.keeper.fullPath)) == rig.keeperData)
        #expect(rig.quarantineFolders.isEmpty)
    }

    // MARK: The matrix (byte-identical files)

    @Test("MATRIX: {EIO, premature EOF, partial read, bit flip} × {keeper, duplicate at its path, quarantine re-hash, quarantine single read} — only the benign partial read reaches the Trash; every other cell is refused, named, journalled, and the duplicate is back at its path, byte for byte",
          .timeLimit(.minutes(3)), arguments: DedupeFaultCell.all)
    func aFaultedReadNeverReachesTheTrash(_ c: DedupeFaultCell) async throws {
        let rig = try makeRig("m_\(c.site)_\(c.kind)", cachedKeeper: c.site.cachedKeeper)
        defer { rig.cleanup() }
        let trueDigest = sha(rig.keeperData)
        let keeperFixityBefore = rig.keeper.contentFixity
        let fault = rig.fault(c.kind, c.site)
        let ran = try await runThroughTheCenter(rig, hook: fault.hook)
        #expect(fault.firedCount == 1, "\(c): the fault never reached its read (passes \(fault.passCount))")
        print("[hash-matrix] delete duplicates | \(c) | \(ran.row.status) | \(ran.rowLine) | keeper fixity \(rig.keeper.contentFixity.map { $0.digest == trueDigest ? "TRUE" : "FALSE" } ?? "none")")

        // --- No digest is ever recorded for the duplicate; no quarantine folder is left.
        #expect(rig.dup.contentFixity == nil, "\(c): a fixity was stored on the duplicate")
        #expect(rig.quarantineFolders.isEmpty, "\(c): \(rig.quarantineFolders)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.keeper.fullPath)) == rig.keeperData)

        if c.kind == .partialRead {
            // A partial read is a COMPLETE read: both files proven, equal digests.
            #expect(ran.row.status == .trashed && rig.inTrash && !rig.atPath, "\(c): \(ran.row.status) — \(ran.row.note)")
            #expect(try Data(contentsOf: rig.trashURL) == rig.dupData)
            #expect(rig.dup.removal?.state == .inTrash)
            #expect(ran.rowLine.hasPrefix("[dupjob] trashed \(rig.dupName)"), "\(ran.rowLine)")
            #expect(ran.auditLine.contains("audit: moved "), "\(ran.auditLine)")
            if !c.site.cachedKeeper {
                #expect(rig.keeper.contentFixity?.digest == trueDigest, "the keeper's clean read is stored")
            }
            return
        }

        // --- THE RULE: an unproven read sends nothing to the Trash.
        #expect(!rig.inTrash, "\(c): THE DUPLICATE IS IN THE TRASH: \(rig.trashURL.path)")
        #expect(rig.atPath, "\(c): the duplicate is not at its path")
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.dup.fullPath)) == rig.dupData, "\(c): put back byte for byte")
        #expect(rig.dup.removal == nil && !rig.dup.isPurged, "\(c): the row carries a removal marker")

        // --- Never success: the row, the job, the tally.
        #expect(ran.row.status == .refused, "\(c): \(ran.row.status) — \(ran.row.note)")
        #expect(ran.job.result.deleted == 0 && ran.job.runTally.trashed == 0 && ran.job.runTally.refused == 1, "\(c): \(ran.job.runTally)")
        if case .finished(let summary) = ran.job.state {
            #expect(summary.hasPrefix("Moved 0 (") && summary.contains("1 held ("), "\(c): \(summary)")
        } else { Issue.record("\(c): \(ran.job.state)") }

        // --- The words. `expected` is the truthful name of what happened.
        let note = ran.row.note
        switch (c.site, c.kind) {
        case (.keeper, .eio), (.keeper, .prematureEOF):
            #expect(note == "could not read \(rig.keeperName) to verify", "\(c): \(note)")
        case (.duplicateAtPath, .eio), (.duplicateAtPath, .prematureEOF),
             (.quarantineSingleRead, .eio), (.quarantineSingleRead, .prematureEOF):
            #expect(note == "could not read \(rig.dupName) to verify", "\(c): \(note)")
        case (.quarantineRehash, .eio), (.quarantineRehash, .prematureEOF):
            #expect(!note.isEmpty)
            withKnownIssue("PARKED 2026-11-21 (P3, wording): the quarantine RE-READ that fails or ends early is reported as \"<file> changed during verification\" — the file did not change, it could not be read. deleteQuarantined passes restoreOrRetain the true reason (\"quarantined file could not be re-read before removal\") but the refusal it returns is .changedSinceVerification, and that is what the row, the log and the receipt say. Nothing moves: the file is put back. Proposed: return .unreadable(original) for an empty re-hash.") {
                #expect(note.contains("could not") && note.contains("read"), "\(c): \(note)")
            }
        case (.quarantineRehash, .bitFlip):
            // Two reads of one file disagree: "changed during verification" is
            // the honest inference from inside the gate.
            #expect(note == "\(rig.dupName) changed during verification", "\(c): \(note)")
        case (_, .bitFlip):
            // A mismatch, named as one. (The files ARE identical — one read
            // said otherwise; the row is re-marked Review. Refusing is the
            // safe direction.)
            #expect(note == "content differs from keeper \(rig.keeperName) — NOT a duplicate", "\(c): \(note)")
        case (_, .partialRead): break
        }

        // --- Said everywhere: the row line, the audit line, the OUTCOME line, the receipt, the plan journal.
        #expect(ran.rowLine.hasPrefix("[dupjob] refused \(rig.dupName)") && ran.rowLine.contains(note), "\(c): \(ran.rowLine)")
        #expect(ran.auditLine.contains("audit: held \(rig.dup.fullPath)") && ran.auditLine.contains(note), "\(c): \(ran.auditLine)")
        #expect(ran.outcomeLine.contains("held 1") && !ran.outcomeLine.contains("moved 1"), "\(c): \(ran.outcomeLine)")
        #expect(ran.summaryLine.contains("trashed 0 ") && ran.summaryLine.contains("refused 1 "), "\(c): \(ran.summaryLine)")
        #expect(ran.receipt.contains(rig.dup.fullPath) && ran.receipt.contains("held"), "\(c): receipt \(ran.receipt)")
        #expect(ran.journal.contains("\"refused\"") && ran.journal.contains(rig.dupName), "\(c): the plan journal does not record the refusal")

        // --- No fixity from a faulted read.
        switch c.site {
        case .keeper:
            if c.kind == .bitFlip {
                withKnownIssue("PARKED 2026-11-21 (P1, GH #504 root cause B — and the SUPPLIER of shape C's P0 poisoned cache): a bit flipped in the keeper's one full read is STORED as the keeper's whole-file fixity — `verify` calls didComputeKeeperFixity before the pair's verdict and the job stores it (`learnedKeeperFixity`), stamp-bound, although the pair it came from was refused as a mismatch. Every later stamp-trusting reader believes it without a read: Delete Duplicates' single-read path then refuses the keeper's TRUE duplicates as 'NOT a duplicate' and would trash a file that holds the flipped bytes (shape C); ContentCopyProof vouches by it. No media moves in this cell. Proposed: store a keeper fixity only from a pair that verified (two files' reads agreed), or after a second read of the keeper agrees.") {
                    #expect(rig.keeper.contentFixity == nil || rig.keeper.contentFixity?.digest == trueDigest,
                            "\(c): the keeper's stored fixity is a digest no clean read ever produced")
                }
            } else {
                #expect(rig.keeper.contentFixity == nil, "\(c): a fixity was stored from a keeper read that failed")
            }
        case .duplicateAtPath, .quarantineRehash:
            // The keeper's own read was clean: its true digest may be kept.
            #expect(rig.keeper.contentFixity == nil || rig.keeper.contentFixity?.digest == trueDigest, "\(c)")
        case .quarantineSingleRead:
            #expect(rig.keeper.contentFixity == keeperFixityBefore, "\(c): the cached keeper fixity changed")
        }

        // --- The refusal was the fault's: the same run, clean, trashes the copy.
        #expect(rig.dup.duplicateDisposition == .review, "\(c): a refused pair is re-marked Review")
        rig.dup.duplicateDisposition = .extraCopy
        if c.site == .keeper && c.kind == .bitFlip { rig.keeper.contentFixity = nil }   // drop the parked false digest
        let clean = try await runThroughTheCenter(rig, hook: nil)
        #expect(clean.row.status == .trashed && rig.inTrash, "\(c): the clean re-run: \(clean.row.status) — \(clean.row.note)")
    }

    // MARK: Codex's shapes

    @Test("Codex shape A (CLOSED): the duplicate is the keeper's bytes + a unique tail and its read would end at the keeper's length — both gate paths refuse on SIZE before any full read; nothing is trashed",
          arguments: [false, true])
    func shapeA_aLongerFileIsRefusedBeforeAnyRead(_ cachedKeeper: Bool) async throws {
        let rig = try makeRig("shapeA_\(cachedKeeper)", cachedKeeper: cachedKeeper) { $0 + hashSeamBlob(bytes: 65_536, seed: 9) }
        defer { rig.cleanup() }
        // Aimed at ANY read of the duplicate, at its path or in quarantine.
        let fault = DedupeReadFault(.prematureEOF, where: { [name = rig.dupName] in $0.hasSuffix("/" + name) },
                                    atByte: Int64(rig.keeperData.count), onPass: 0)
        let ran = try await runThroughTheCenter(rig, hook: fault.hook)
        print("[hash-matrix] delete duplicates | shape A, cached keeper \(cachedKeeper) | \(ran.row.status) | \(ran.rowLine) | full reads of the duplicate \(fault.passCount)")
        #expect(fault.passCount == 0 && fault.firedCount == 0, "the size gate refuses before the duplicate is read at all")
        #expect(ran.row.status == .refused && !rig.inTrash && rig.atPath)
        #expect(ran.row.note == "content differs from keeper \(rig.keeperName) — NOT a duplicate", "\(ran.row.note)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.dup.fullPath)) == rig.dupData)
        #expect(rig.quarantineFolders.isEmpty && rig.dup.contentFixity == nil)
    }

    @Test("Codex shape B, flip in the duplicate's read AT ITS PATH (uncached keeper): the pair 'verifies', but the quarantine RE-READ sees the real bytes and the file is put back — the second read is what saves it")
    func shapeB_theQuarantineRereadCatchesAFlippedDuplicateRead() async throws {
        let rig = try makeRig("shapeBdup", cachedKeeper: false) { var d = $0; d[Int(faultByte)] ^= 0x01; return d }
        defer { rig.cleanup() }
        let fault = rig.fault(.bitFlip, .duplicateAtPath)
        let rereads = DedupeReadCounter(where: { [name = rig.dupName] in
            $0.hasSuffix("/" + name) && $0.contains(SignatureVerification.quarantineDirectoryPrefix)
        })
        let both: ArchivePromoteEngine.ReadHook = { fd, offset, count in
            _ = rereads.hook(fd, offset, count)
            return fault.hook(fd, offset, count)
        }
        let ran = try await runThroughTheCenter(rig, hook: both)
        #expect(fault.firedCount == 1)
        #expect(rereads.passCount == 1, "the file was moved to quarantine and re-read there")
        print("[hash-matrix] delete duplicates | shape B: flip on the differing bit, DUPLICATE read at its path | \(ran.row.status) | \(ran.rowLine)")
        #expect(ran.row.status == .refused && !rig.inTrash && rig.atPath, "\(ran.row.status) — \(ran.row.note)")
        #expect(ran.row.note == "\(rig.dupName) changed during verification", "\(ran.row.note)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.dup.fullPath)) == rig.dupData)
        #expect(rig.keeper.contentFixity?.digest == sha(rig.keeperData), "the keeper's clean read is what is stored")
        #expect(rig.dup.contentFixity == nil && rig.quarantineFolders.isEmpty)
    }

    /// Codex shape C. The keeper carries a whole-file fixity that is FALSE
    /// (it names other bytes) but whose stamp reproduces — what Bind Fixity's
    /// overwrite (GH #504 item 1) or the keeper flip above leaves behind. The
    /// "duplicate" holds the bytes the false digest names. Delete Duplicates
    /// does NOT re-read the keeper: `holdForSingleRead` accepts a fixity whose
    /// stamp describes the file now (the cached-keeper contract, the same one
    /// VerifyArchiveCopiesJob's stamp-bound fixity relies on), reads the
    /// duplicate once, and trashes it.
    /// 🔴 P0 (re-ranked from P1, Codex r1): this is persistent REMOVAL
    /// AUTHORITY, not merely bad metadata — a keeper holding bytes A with a
    /// current stamp saying digest B lets ANY file holding B be trashed, on
    /// every later run, with all reads clean and A never read. What supplies
    /// the poisoned cache: the P1 "a refused pair still publishes the
    /// corrupted keeper fixity" (the matrix's keeper/bit-flip cell;
    /// `learnedKeeperFixity` stored at DeleteDuplicatesJob.swift ~:1556), and
    /// GH #504's Bind Fixity overwrite.
    /// WHERE THE MEDIA IS: in the Trash, intact, recoverable; keeper untouched.
    @Test("🔴 P0 (parked) Codex shape C: a FALSE but stamp-valid cached keeper fixity is trusted — the keeper is not re-read, and a file that matches the false digest (not the keeper) is sent to the Trash")
    func shapeC_aFalseCachedKeeperFixityIsTrusted() async throws {
        let rig = try makeRig("shapeC", cachedKeeper: false) { var d = $0; d[Int(faultByte)] ^= 0x01; return d }
        defer { rig.cleanup() }
        // Stamp of the KEEPER, digest of the OTHER file.
        rig.keeper.contentFixity = ContentFixity.captured(path: rig.keeper.fullPath, digest: sha(rig.dupData),
                                                          byteCount: Int64(rig.keeperData.count))
        let keeperReads = DedupeReadCounter(where: { [name = rig.keeperName] in $0.hasSuffix("/" + name) })
        let ran = try await runThroughTheCenter(rig, hook: keeperReads.hook)
        print("[hash-matrix] delete duplicates | shape C: false cached keeper fixity, no fault | \(ran.row.status) | \(ran.rowLine) | full reads of the keeper \(keeperReads.passCount)")
        // PINNED: what it does today.
        #expect(keeperReads.passCount == 0, "the keeper was re-read — the contract changed; promote the parked assertion below")
        #expect(ran.row.keeperMatchedByStoredFixity == true)
        withKnownIssue("🔴 P0 PARKED 2026-11-21 (re-ranked from P1 by Codex r1: persistent removal authority, not merely bad metadata; design — Rick + Codex): Delete Duplicates trusts a stamp-valid stored keeper fixity and never re-reads the keeper (holdForSingleRead / verifyHeld; Rick 2026-09-20 'single read'). With a FALSE stored digest — which GH #504's Bind Fixity overwrite and this suite's keeper-flip P1 (a refused pair still publishes the flipped keeper fixity, DeleteDuplicatesJob.swift ~:1556) can both write — a file that is NOT the keeper's bytes is moved to the Trash (recoverable; keeper untouched) and logged 'verified identical … keeper matched by stored fixity'. The trust is only as good as every writer of contentFixity. Proposed: fix the writers first (never store a digest from one unconfirmed read); then decide whether the first use of a cached keeper digest in a run earns one keeper re-read.") {
            #expect(!rig.inTrash, "a file that is not the keeper's bytes is in the Trash: \(rig.trashURL.path)")
            #expect(ran.row.status == .refused, "\(ran.row.status)")
        }
        let where_ = rig.inTrash ? rig.trashURL : URL(fileURLWithPath: rig.dup.fullPath)
        #expect(try Data(contentsOf: where_) == rig.dupData)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.keeper.fullPath)) == rig.keeperData)
    }

    // MARK: The sibling proof

    @Test("REACH: the job reads no sibling (KEEP ONE) — a fault aimed at an unproven sibling never fires, the copy goes on the keeper alone, and nothing is stored on the sibling")
    func theJobReadsNoSibling() async throws {
        let rig = try makeRig("nosib", cachedKeeper: true); defer { rig.cleanup() }
        let sibURL = rig.dir.appendingPathComponent("test_sib_\(UUID().uuidString.prefix(8)).mov")
        try rig.keeperData.write(to: sibURL)
        let sib = record(sibURL, size: rig.keeperData.count, group: try #require(rig.keeper.duplicateGroupID), .review)
        rig.model.records.append(sib)
        let fault = DedupeReadFault(.eio, pathSuffix: sibURL.lastPathComponent, atByte: 5_000, onPass: 0)
        let ran = try await runThroughTheCenter(rig, hook: fault.hook)
        #expect(fault.passCount == 0 && fault.firedCount == 0, "a sibling was read: the sibling matrix now belongs on the job")
        #expect(ran.row.status == .trashed && rig.inTrash && ran.job.runTally.siblingReads == 0)
        #expect(sib.contentFixity == nil)
        #expect(ran.row.remainingVerifiedCopies == 1)
    }

    @Test("SIBLING × fault, at the prover (goal 2): a sibling whose read fails or ends early is 'could not be read — not counted' and gets no fixity; a partial read proves it; a flipped read makes it 'differs' and hands back the FLIPPED digest as its fixity (P1, parked)",
          arguments: DedupeFaultKind.allCases)
    func theSiblingProofUnderEachFault(_ kind: DedupeFaultKind) async throws {
        let rig = try makeRig("sib_\(kind)", cachedKeeper: true); defer { rig.cleanup() }
        let sibURL = rig.dir.appendingPathComponent("test_sib_\(UUID().uuidString.prefix(8)).mov")
        try rig.keeperData.write(to: sibURL)
        let sib = record(sibURL, size: rig.keeperData.count, group: try #require(rig.keeper.duplicateGroupID), .review)
        rig.model.records.append(sib)
        let digest = sha(rig.keeperData)
        var candidates = rig.model.deletionTierCandidates(record: rig.dup, keeper: rig.keeper)
        try #require(candidates.otherCopies.map(\.path) == [sibURL.path])
        let allowance = SiblingProver.Allowance(goal: 2, readablePaths: [sibURL.path])

        let fault = DedupeReadFault(kind, pathSuffix: sibURL.lastPathComponent, atByte: faultByte)
        let reads = fault.runSync { SiblingProver.prove(&candidates, digest: digest, allowance: allowance, hooks: .live) }
        #expect(fault.firedCount == 1, "\(kind): the fault never reached the sibling's read")
        let read = try #require(reads.first)
        let facts = DeletionTierFacts.gather(candidates, digest: digest)
        print("[hash-matrix] delete duplicates | \(kind) in the SIBLING read (prover) | \(read.result.word) | counted \(facts.remainingVerifiedCopies): \(facts.counted) | not counted: \(facts.notCounted)")
        #expect(reads.count == 1)
        switch kind {
        case .eio, .prematureEOF:
            #expect(read.result == .unreadable && read.fixity == nil, "\(kind): \(read)")
            #expect(candidates.otherCopies[0].fixity == nil)
            #expect(candidates.otherCopies[0].unverifiedNote == "could not be read — not counted")
            #expect(facts.remainingVerifiedCopies == 1, "only the keeper counts: \(facts.counted)")
        case .partialRead:
            #expect(read.result == .matches && read.fixity?.digest == digest)
            #expect(facts.remainingVerifiedCopies == 2)
        case .bitFlip:
            // Not counted — the safe direction…
            #expect(read.result == .differs && facts.remainingVerifiedCopies == 1, "\(kind): \(read.result)")
            // …but the flipped digest is handed back as the sibling's fixity, and
            // the job stores every `read.fixity` on the sibling's record
            // (noteSiblingReads), whatever the result.
            withKnownIssue("PARKED 2026-11-21 (P1, GH #504 root cause B; unreachable from the job while KEEP ONE reads no sibling): one flipped bit in a sibling's proving read is returned as that sibling's stamp-bound fixity (SiblingRead.fixity) and named 'holds different bytes'; DeleteDuplicatesJob.noteSiblingReads stores it on the sibling's record whether it matched or not. No media moves. Proposed: store a sibling's fixity only when it matched the duplicate's digest (two reads of two files agreed); a lone disagreeing read is reported, not recorded.") {
                #expect(read.fixity == nil, "a digest no clean read produced is on its way to the sibling's record: \(read.fixity?.digest ?? "")")
            }
        }
        #expect(try Data(contentsOf: sibURL) == rig.keeperData)
    }

    /// Codex shape B at the sibling: the sibling is one bit apart from the
    /// duplicate and its one read flips that bit → it is COUNTED as a verified
    /// copy ("2 verified copies remain") and its fixity names the duplicate's
    /// bytes. Under KEEP ONE this changes only the row's words, and the job
    /// cannot reach it at all.
    @Test("SIBLING shape B (P1, parked; prover only): a sibling ONE BIT apart whose read flips that bit is counted as a verified copy and given the duplicate's digest as its fixity")
    func shapeB_aFlippedSiblingReadCountsAFalseCopy() async throws {
        let rig = try makeRig("sibB", cachedKeeper: true); defer { rig.cleanup() }
        let sibURL = rig.dir.appendingPathComponent("test_sib_\(UUID().uuidString.prefix(8)).mov")
        var other = rig.keeperData; other[Int(faultByte)] ^= 0x01
        try other.write(to: sibURL)
        let sib = record(sibURL, size: other.count, group: try #require(rig.keeper.duplicateGroupID), .review)
        rig.model.records.append(sib)
        let digest = sha(rig.keeperData)
        var candidates = rig.model.deletionTierCandidates(record: rig.dup, keeper: rig.keeper)
        let fault = DedupeReadFault(.bitFlip, pathSuffix: sibURL.lastPathComponent, atByte: faultByte)
        let reads = fault.runSync {
            SiblingProver.prove(&candidates, digest: digest, allowance: .init(goal: 2, readablePaths: [sibURL.path]), hooks: .live)
        }
        #expect(fault.firedCount == 1)
        let facts = DeletionTierFacts.gather(candidates, digest: digest)
        print("[hash-matrix] delete duplicates | shape B: flip on the differing bit, SIBLING read (prover) | \(reads.first?.result.word ?? "-") | counted \(facts.remainingVerifiedCopies)")
        withKnownIssue("PARKED 2026-11-21 (P1 truth, prover only — the job reads no sibling under KEEP ONE): a sibling one bit apart is counted as a verified copy on ONE flipped read, and the duplicate's digest becomes its stamp-bound fixity. It would make the row say '2 verified copies remain' when one remains. No media moves on it (the keeper alone already authorises the Trash). Proposed: as GH #504 root cause B — a second fresh read must agree before a digest is stored or counted.") {
            #expect(reads.first?.result != .matches)
            #expect(facts.remainingVerifiedCopies == 1)
        }
        #expect(try Data(contentsOf: sibURL) == other)
    }
}
