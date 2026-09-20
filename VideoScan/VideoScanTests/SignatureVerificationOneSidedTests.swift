// SignatureVerificationOneSidedTests.swift
// The stored-keeper verification path (Rick 2026-09-20: "if we must
// compare byte-for-byte, only do one file, the one being deleted").
//
// Contract under test:
//   • keeper has a fixity whose stamp reproduces → ONLY the duplicate is
//     read; equal digest + size → VerifiedDuplicate (keeperReadInFull false)
//   • no fixity / stamp changed → both files read ONCE, the proof carries
//     the keeper's fresh fixity (keeperReadInFull true)
//   • digest mismatch → refused, keeper still not read
//   • keeper unreadable → refused
//   • the digest is the plain sha256 the archive carries
// Plus ContentFixity itself: Codable additive on VideoRecord, stampMatches.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

/// Counts which side was read, by the "keeper"/"duplicate" labels.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func note(_ label: String) { lock.withLock { counts[label, default: 0] += 1 } }
    func blocks(_ label: String) -> Int { lock.withLock { counts[label] ?? 0 } }
    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(shouldCancel: { false }, didReadBlock: { [self] in note($0) })
    }
}

private func plainSHA256(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("SignatureVerification — one-sided keeper path")
struct SignatureVerificationOneSidedTests {

    private let size = FileHasher.segmentSize * 2 + 777   // three blocks

    @Test func equalDigestReadsOnlyTheDuplicate() throws {
        let dir = tempDir("onesided_equal"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 251) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                          byteCount: Int64(size)))
        let counter = ReadCounter()

        let result = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path, hooks: counter.hooks)

        let proof = try result.get()
        #expect(proof.keeperReadInFull == false)
        #expect(counter.blocks("keeper") == 0, "the keeper must not be read when its fixity stands")
        #expect(counter.blocks("duplicate") == 3, "the duplicate is read end to end")
        #expect(proof.fullHash == fixity.digest)
        #expect(proof.keeperFixity == fixity)
        #expect(proof.duplicateSize == Int64(size))
        // The proof authorises the same quarantine-and-delete as the two-file one.
        #expect(SignatureVerification.quarantineAndDelete(proof, hooks: counter.hooks) == .deleted(bytes: Int64(size)))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: keeper.path))
        #expect(counter.blocks("keeper") == 0, "deletion stats the keeper; it never reads it")
    }

    @Test func noFixityFallsBackToTwoFileReadAndReturnsFreshKeeperFixity() throws {
        let dir = tempDir("onesided_nofix"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 13) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let counter = ReadCounter()

        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: nil, duplicatePath: copy.path, hooks: counter.hooks).get()

        #expect(proof.keeperReadInFull == true)
        #expect(counter.blocks("keeper") == 3 && counter.blocks("duplicate") == 3)
        #expect(proof.keeperFixity.digest == plainSHA256(keeper), "the fixity is the plain sha256 — same as the archive's")
        #expect(proof.keeperFixity.stampMatches(path: keeper.path))
        #expect(proof.keeperFixity.byteCount == Int64(size))

        // Second pair with the stored fixity: keeper not read again.
        let copy2 = dir.appendingPathComponent("copy2.mov"); write(copy2, bytes)
        let counter2 = ReadCounter()
        let proof2 = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: proof.keeperFixity, duplicatePath: copy2.path, hooks: counter2.hooks).get()
        #expect(proof2.keeperReadInFull == false)
        #expect(counter2.blocks("keeper") == 0 && counter2.blocks("duplicate") == 3)
    }

    @Test func keeperStampChangedFallsBackAndStoresFreshFixity() throws {
        let dir = tempDir("onesided_stamp"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 17) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let stale = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                         byteCount: Int64(size)))
        // Rewrite the keeper in place with the SAME bytes but a new mtime:
        // the stamp no longer reproduces, so the stored digest may not stand.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                                              ofItemAtPath: keeper.path)
        #expect(!stale.stampMatches(path: keeper.path), "precondition: the stamp must be stale")
        let counter = ReadCounter()

        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: stale, duplicatePath: copy.path, hooks: counter.hooks).get()

        #expect(proof.keeperReadInFull == true, "a changed stamp costs one full read of the keeper")
        #expect(counter.blocks("keeper") == 3)
        #expect(proof.keeperFixity != stale)
        #expect(proof.keeperFixity.stampMatches(path: keeper.path), "the fresh fixity carries the NEW stamp")
    }

    @Test func keeperRewrittenWithDifferentContentIsRefused() throws {
        let dir = tempDir("onesided_rewrite"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 19) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let stale = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                         byteCount: Int64(size)))
        var other = bytes; other[size / 2] ^= 0xFF
        write(keeper, other)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_100_000_000)],
                                              ofItemAtPath: keeper.path)

        let result = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: stale, duplicatePath: copy.path)
        #expect(result == .failure(.contentDiffers), "a stale fixity must never vouch for new bytes")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func digestMismatchIsRefusedWithoutReadingTheKeeper() throws {
        let dir = tempDir("onesided_mismatch"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 23) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        var middle = bytes; middle[FileHasher.segmentSize + 100] ^= 0x01   // past any head gate
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, middle)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                          byteCount: Int64(size)))
        let counter = ReadCounter()

        let result = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path, hooks: counter.hooks)

        #expect(result == .failure(.contentDiffers))
        #expect(counter.blocks("keeper") == 0)
        #expect(counter.blocks("duplicate") == 3)
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func sizeMismatchIsRefusedBeforeAnyRead() throws {
        let dir = tempDir("onesided_size"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 29) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes + [1])
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                          byteCount: Int64(size)))
        let counter = ReadCounter()
        let result = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path, hooks: counter.hooks)
        #expect(result == .failure(.contentDiffers))
        #expect(counter.blocks("keeper") == 0 && counter.blocks("duplicate") == 0)
    }

    @Test func unreadableKeeperIsRefused() throws {
        let dir = tempDir("onesided_gone"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 31) }
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let ghost = dir.appendingPathComponent("gone.mov").path
        let fixity = ContentFixity(digest: plainSHA256(copy), byteCount: Int64(size),
                                   stamp: FileIdentityStamp(device: 1, inode: 2, size: Int64(size), mtimeNs: 3))
        let result = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: ghost, keeperFixity: fixity, duplicatePath: copy.path)
        #expect(result == .failure(.unreadable(ghost)), "a stored digest is no substitute for a keeper that is not there")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func samePathIsRefused() {
        let dir = tempDir("onesided_same"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("only.mov"); write(f, [1, 2, 3])
        #expect(SignatureVerification.verifyAgainstStoredKeeper(keeperPath: f.path, keeperFixity: nil,
                                                                duplicatePath: f.path) == .failure(.samePath))
    }

    /// A pre-ctime fixity (stamp without ctime) costs one keeper re-read
    /// and is replaced by a proper one.
    @Test func preCtimeFixityFallsBackToTwoFileRead() throws {
        let dir = tempDir("onesided_prectime"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 59) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let live = try #require(FileIdentityStamp.capture(path: keeper.path))
        let old = ContentFixity(digest: plainSHA256(keeper), byteCount: Int64(size),
                                stamp: FileIdentityStamp(device: live.device, inode: live.inode,
                                                         size: live.size, mtimeNs: live.mtimeNs))
        #expect(old.stampMatches(path: keeper.path) && !old.isUsableForVerification)
        let counter = ReadCounter()
        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: old, duplicatePath: copy.path, hooks: counter.hooks).get()
        #expect(proof.keeperReadInFull == true && counter.blocks("keeper") == 3)
        #expect(proof.keeperFixity.stamp.hasChangeTime && proof.keeperFixity.isUsableForVerification)
    }

    @Test func nonSha256FixityFallsBack() throws {
        let dir = tempDir("onesided_algo"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 37) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let stamp = try #require(FileIdentityStamp.capture(path: keeper.path))
        let foreign = ContentFixity(algorithm: "blake3", digest: "00", byteCount: Int64(size), stamp: stamp)
        let counter = ReadCounter()
        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: foreign, duplicatePath: copy.path, hooks: counter.hooks).get()
        #expect(proof.keeperReadInFull == true && counter.blocks("keeper") == 3)
    }

    /// The two-file path's digest is the plain sha256 the archive manifest
    /// and CatalogStore.sha256HexStreaming produce — one fixity vocabulary.
    @Test func twoFileDigestMatchesTheArchiveSha256() throws {
        let dir = tempDir("onesided_sha"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 41) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let proof = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: copy.path).get()
        #expect(proof.fullHash == (try CatalogStore.sha256HexStreaming(fileURL: keeper)))
        #expect(proof.keeperFixity.digest == proof.fullHash)
    }
}

// MARK: - ContentFixity

@Suite("ContentFixity — Codable additive + stamp")
@MainActor
struct ContentFixityTests {

    @Test func oldRecordJSONDecodesWithNilFixity() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","filename":"old.mov","fullPath":"/v/old.mov"}"#
        let rec = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(rec.contentFixity == nil)
        #expect(rec.filename == "old.mov")
    }

    @Test func fixityRoundTripsThroughTheDTOAndIsOmittedWhenNil() throws {
        let rec = VideoRecord()
        rec.filename = "a.mov"; rec.fullPath = "/v/a.mov"
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let withoutKey = String(decoding: try enc.encode(VideoRecordDTO(rec)), as: UTF8.self)
        #expect(!withoutKey.contains("contentFixity"), "nil fixity must not appear on disk — legacy files round-trip byte-identical")

        let stamp = FileIdentityStamp(device: 7, inode: 99, size: 1234, mtimeNs: 1_700_000_000_123_456_789)
        rec.contentFixity = ContentFixity(digest: "AB" + String(repeating: "cd", count: 31), byteCount: 1234,
                                          stamp: stamp, computedAt: Date(timeIntervalSince1970: 1_000))
        let data = try enc.encode(VideoRecordDTO(rec))
        let back = try JSONDecoder().decode(VideoRecord.self, from: data)
        let fx = try #require(back.contentFixity)
        #expect(fx.digest.hasPrefix("ab"), "digest is normalised to lowercase")
        #expect(fx.stamp == stamp && fx.byteCount == 1234 && fx.algorithm == "sha256")
        #expect(back.snapshotClone().contentFixity == fx, "the clone carries it too")
    }

    @Test func stampMatchesRequiresEveryField() {
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 3, mtimeNs: 4)
        let fx = ContentFixity(digest: "00", byteCount: 3, stamp: stamp)
        #expect(fx.stampMatches(stamp))
        #expect(!fx.stampMatches(nil), "a failed stat never matches")
        #expect(!fx.stampMatches(FileIdentityStamp(device: 1, inode: 2, size: 3, mtimeNs: 5)))
        #expect(!fx.stampMatches(FileIdentityStamp(device: 1, inode: 9, size: 3, mtimeNs: 4)))
        #expect(!fx.stampMatches(FileIdentityStamp(device: 1, inode: 2, size: 4, mtimeNs: 4)))
        let inconsistent = ContentFixity(digest: "00", byteCount: 99, stamp: stamp)
        #expect(!inconsistent.stampMatches(stamp), "byteCount must agree with the stamp's size")
    }

    /// QA MAJOR 1 schema: a fixity saved before the ctime field existed
    /// decodes, but is "absent" to the gate — one re-read replaces it.
    @Test func preCtimeFixityDecodesAsUnusableForVerification() throws {
        let json = #"{"algorithm":"sha256","digest":"ab","byteCount":3,"computedAt":0,"stamp":{"device":1,"inode":2,"size":3,"mtimeNs":4}}"#
        let fx = try JSONDecoder().decode(ContentFixity.self, from: Data(json.utf8))
        #expect(fx.stamp.ctimeNs == FileIdentityStamp.unknownCtime)
        #expect(!fx.stamp.hasChangeTime)
        #expect(!fx.isUsableForVerification)
        let live = FileIdentityStamp(device: 1, inode: 2, size: 3, mtimeNs: 4, ctimeNs: 99)
        #expect(fx.stampMatches(live), "the user-visible stamp still matches")
        #expect(!fx.describesFileNow(live), "but it may never stand in for a read")
        // A fixity WITH ctime: the strict check needs it to reproduce.
        let strict = ContentFixity(digest: "ab", byteCount: 3, stamp: live)
        #expect(strict.isUsableForVerification && strict.describesFileNow(live))
        #expect(!strict.describesFileNow(FileIdentityStamp(device: 1, inode: 2, size: 3, mtimeNs: 4, ctimeNs: 100)))
        #expect(strict.stampMatches(FileIdentityStamp(device: 1, inode: 2, size: 3, mtimeNs: 4, ctimeNs: 100)))
    }

    @Test func capturedRequiresTheBeforeStampToReproduce() throws {
        let dir = tempDir("fixity_before"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.bin"); write(f, [1, 2, 3, 4])
        let before = try #require(FileIdentityStamp.capture(path: f.path))
        #expect(ContentFixity.captured(path: f.path, digest: "aa", byteCount: 4, before: before) != nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: f.path)
        #expect(ContentFixity.captured(path: f.path, digest: "aa", byteCount: 4, before: before) == nil,
                "changed under the read — no fixity")
    }

    @Test func capturedRefusesWhenTheFileChangedUnderTheRead() throws {
        let dir = tempDir("fixity_captured"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.bin"); write(f, [1, 2, 3, 4])
        #expect(ContentFixity.captured(path: f.path, digest: "aa", byteCount: 4) != nil)
        #expect(ContentFixity.captured(path: f.path, digest: "aa", byteCount: 5) == nil, "size on disk ≠ bytes hashed")
        #expect(ContentFixity.captured(path: f.path, digest: "", byteCount: 4) == nil, "an empty digest is no fixity")
        #expect(ContentFixity.captured(path: dir.appendingPathComponent("no").path, digest: "aa", byteCount: 4) == nil)
    }
}


// MARK: - QA red tests (2026-09-20 review of feature/delete-duplicates-job)
//
// Each test below FAILS on 462b034b and pins one finding. Uncommitted;
// the fix agent lands them red → green.

/// A thread-safe flag for the cancel-after-quarantine test.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@Suite("SignatureVerification — QA red tests (delete-duplicates-job)")
struct SignatureVerificationDeleteDuplicatesQATests {

    private let size = FileHasher.segmentSize * 2 + 777   // three blocks

    /// FINDING: a duplicate that is a HARD LINK of its keeper (same device +
    /// inode) passes both gates — the string-only `keeperPath != duplicatePath`
    /// check (SignatureVerification.swift:135 and :219) is the only identity
    /// test. The unlink frees nothing, "bytes freed" is overstated, and the
    /// same-file-two-paths case (case-insensitive APFS: /Family vs /family)
    /// is caught only AFTER the keeper has been moved into quarantine.
    /// Rick's rule: a hard link of the keeper is refused or handled
    /// explicitly. Fix: refuse when device+inode agree, before any read.
    @Test func hardLinkOfTheKeeperIsRefusedNotUnlinked() throws {
        let dir = tempDir("qa_hardlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 43) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let link = dir.appendingPathComponent("copy.mov")
        try FileManager.default.linkItem(at: keeper, to: link)
        let k = try #require(FileIdentityStamp.capture(path: keeper.path))
        let d = try #require(FileIdentityStamp.capture(path: link.path))
        #expect(k.device == d.device && k.inode == d.inode, "precondition: one inode, two names")
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                          byteCount: Int64(size)))

        let stored = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: link.path)
        #expect(stored == .failure(.samePath),
                "same device+inode as the keeper must be refused (nothing to free) — got \(stored)")

        let twoFile = SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: link.path)
        #expect(twoFile == .failure(.samePath),
                "the two-file path must refuse the same inode too — got \(twoFile)")
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    /// FINDING: the stamp (device/inode/size/mtimeNs) is reproducible by
    /// ordinary tools — `cp -p`, `rsync -t --inplace`, `touch -r` — after an
    /// in-place rewrite of the SAME size (DV tapes of equal length have
    /// identical byte counts). The stored digest then describes bytes the
    /// keeper no longer holds, and a duplicate equal to the OLD bytes — the
    /// last copy of them — matches the stale digest and is deleted
    /// (SignatureVerification.swift:223–228 trusts `stampMatches` alone).
    /// Fix: add `ctimeNs` (st_ctimespec, kernel-set, not user-settable) to
    /// FileIdentityStamp; an in-place rewrite then costs one keeper re-read.
    @Test func inPlaceRewriteWithPreservedMtimeMustNotLetTheStaleDigestStand() throws {
        let dir = tempDir("qa_ctime"); defer { try? FileManager.default.removeItem(at: dir) }
        let old = (0..<size).map { UInt8($0 % 47) }
        var new = old; new[size / 2] ^= 0xFF                       // same size, different bytes
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, old)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, old)   // the LAST copy of the old bytes
        let whole = Date(timeIntervalSince1970: 1_600_000_000)     // whole second: reproducible to the ns
        try FileManager.default.setAttributes([.modificationDate: whole], ofItemAtPath: keeper.path)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                          byteCount: Int64(size)))

        // Rewrite in place (same inode, same size) and put the mtime back.
        let fd = open(keeper.path, O_WRONLY)
        #expect(fd >= 0)
        let wrote = new.withUnsafeBytes { pwrite(fd, $0.baseAddress, size, 0) }
        close(fd)
        #expect(wrote == size)
        try FileManager.default.setAttributes([.modificationDate: whole], ofItemAtPath: keeper.path)
        #expect(fixity.stampMatches(path: keeper.path), "precondition: the stamp reproduces — this IS the spoof")
        #expect(plainSHA256(keeper) != fixity.digest, "precondition: the keeper's bytes are new")

        let result = SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path)
        if case .success(let proof) = result {
            Issue.record("a stale digest vouched for a keeper whose bytes changed (keeperReadInFull=\(proof.keeperReadInFull)); copy.mov is the last copy of the old bytes and would be deleted")
        }
        #expect(result == .failure(.contentDiffers), "\(result)")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    /// FINDING (pre-existing, now user-visible through the plan): a Stop
    /// that lands between the quarantine move and the final identity check
    /// restores the file but reports `.changedSinceVerification(path)`
    /// (SignatureVerification.swift:381 discards the "cancelled after
    /// quarantine" reason). DeleteDuplicatesJob.swift:313–326 then treats it
    /// as a refusal: the row is re-marked Review with "copy.mov changed
    /// during verification" — for a cancel. Fix: restoreOrRetain returns
    /// `.refused(.cancelled)` when the reason is the cancel.
    @Test func cancelAfterQuarantineIsReportedAsCancelledNotAsChanged() throws {
        let dir = tempDir("qa_cancelq"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 53) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let proof = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: copy.path).get()
        let cancelled = Flag()
        let hooks = SignatureVerification.Hooks(shouldCancel: { cancelled.value },
                                                didQuarantine: { _ in cancelled.value = true })

        let outcome = SignatureVerification.quarantineAndDelete(proof, hooks: hooks)

        #expect(FileManager.default.fileExists(atPath: copy.path), "the file is put back")
        #expect(outcome == .refused(.cancelled),
                "a Stop is a cancel, not a changed file — got \(outcome)")
    }
}
