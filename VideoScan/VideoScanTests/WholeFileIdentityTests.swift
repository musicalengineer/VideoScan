import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #523: "same content" is the whole-file SHA-256, never a sample
//
// DateInference rule 2 (a machine date travels between copies), Dossier
// carry-over ("same bytes" text reuse, which delivers OCR DATE candidates)
// and Relocate's Bucket E (a witness on a third volume lets Migrate skip the
// copy) decided "same content" by partialMD5 + size — a head+tail SAMPLE —
// or the segmented contentHash. On Rick's catalog 12 partialMD5 groups held
// several whole-file digests (same size, head and tail, different interior
// bytes). An inferred date feeds Promote's decade folder, and a Bucket E
// skip leaves a file's only copy on a drive being retired, so rule 6
// applies: identity is the whole-file SHA-256 under the commit's digest rule
// (`VideoScanModel.contentKey(of:)` / `CatalogCommit.digest(of:)`); no
// whole-file digest ⇒ no sharing.
//
// Each test here uses only APIs that existed before the fix and was run RED
// against it (red/green table in the commit message).
//
// Dimensions:
//   logic      rule 2, carry-over, Bucket E and the #1413 unwind on the
//              incident's shape (same partialMD5 + size, different digests)
//              and on unhashed sample twins; a same-digest control that
//              still shares in each
//   scale      InferredDatePropagationTests' 100k / 5k-group budget, now on
//              digest-keyed buckets
//   isolation  a poisoned pair: a fixity that does not cover the file, two
//              fixities that disagree — no identity, nothing shared
//   sensor     the production-shape guard (ProductionShapeWholeFileIdentity
//              Tests) counts, on a .backup copy, every share the sample rule
//              would make that the digest rule refuses
//   media      Bucket E on real files of the same size and partialMD5 with
//              different interior bytes (FileHasher reads them)

@MainActor
@Suite("GH #523 — a date, dossier text or a Relocate witness travels only by whole-file SHA-256", .serialized)
struct WholeFileIdentityTests {

    typealias F = DossierAdmissionFixtures
    typealias W = ArchivedTwinDateWritersTests

    static let sampleMD5 = "33f3a67a70d4f531bc0ea0313d9ddd65"
    static let digestX = String(repeating: "7a", count: 32)
    static let digestY = String(repeating: "7b", count: 32)

    /// Same partialMD5 + size; `digest` nil = never fully hashed.
    static func sample(_ r: VideoRecord, digest: String?, size: Int64 = 31_142_257) {
        r.partialMD5 = sampleMD5
        r.sizeBytes = size
        r.contentFixity = digest.map { W.fixity($0, size) }
    }

    // MARK: Rule 2

    @Test("RED before #523: the incident's shape — same partialMD5 + size, different digests — never shares a date; same digest still does")
    func ruleTwoNeedsTheSameDigest() throws {
        let sb = try F.Sandbox("t523_rule2"); defer { sb.cleanup() }
        let dated = sb.record("test_nv12_a.mkv", stage: .cataloged, onDisk: false)
        dated.ocrDateCandidates = [F.ocr1991]          // dated by OCR (rule 1) this pass
        let other = sb.record("test_nv12_b.mkv", stage: .cataloged, onDisk: false)
        let same = sb.record("test_nv12_c.mkv", stage: .cataloged, onDisk: false)
        Self.sample(dated, digest: Self.digestX); Self.sample(other, digest: Self.digestY); Self.sample(same, digest: Self.digestX)
        sb.model.records = [dated, other, same]
        let r = sb.model.catchUpInferredDates(trigger: "test")
        #expect(dated.inferredRecordDate != nil, "the donor dates itself from its own OCR")
        #expect(other.inferredRecordDate == nil, "different interior bytes: never inherits the date")
        #expect(same.inferredRecordDate == dated.inferredRecordDate, "control: the same whole-file digest shares")
        #expect(r.propagated == 1)
        #expect(!VideoScanModel.propagateInferredDate(from: dated, to: other), "the single-write guard agrees")
    }

    @Test("RED before #523: unhashed sample twins share nothing — no whole-file digest, no sharing")
    func ruleTwoNeedsADigest() throws {
        let sb = try F.Sandbox("t523_nodigest"); defer { sb.cleanup() }
        let dated = sb.record("test_u_a.mkv", stage: .cataloged, onDisk: false)
        dated.inferredRecordDate = F.utc(1991); dated.inferredDateConfidence = 0.95
        dated.inferredDateReason = "on-screen date 1991-01-01 ×3"
        let twin = sb.record("test_u_b.mkv", stage: .cataloged, onDisk: false)
        Self.sample(dated, digest: nil); Self.sample(twin, digest: nil)
        sb.model.records = [dated, twin]
        #expect(sb.model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(twin.inferredRecordDate == nil)
    }

    @Test("ISOLATION: a fixity that does not cover the file, or two that disagree, is no identity")
    func poisonedFixities() throws {
        let sb = try F.Sandbox("t523_poison"); defer { sb.cleanup() }
        let dated = sb.record("test_p_a.mkv", stage: .cataloged, onDisk: false)
        dated.inferredRecordDate = F.utc(1991); dated.inferredDateConfidence = 0.95
        dated.inferredDateReason = "on-screen date 1991-01-01 ×3"
        Self.sample(dated, digest: Self.digestX)
        let short = sb.record("test_p_short.mkv", stage: .cataloged, onDisk: false)
        Self.sample(short, digest: nil)
        short.contentFixity = W.fixity(Self.digestX, 1_000)            // covers 1 000 bytes of 31 MB
        let split = sb.record("test_p_split.mkv", stage: .cataloged, onDisk: false)
        Self.sample(split, digest: Self.digestX)
        split.archiveFixity = ArchiveFixity(digest: Self.digestY, verifiedAt: Date(), sizeBytes: split.sizeBytes)
        sb.model.records = [dated, short, split]
        #expect(sb.model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(short.inferredRecordDate == nil && split.inferredRecordDate == nil)
    }

    // MARK: The #1413 unwind

    @Test("RED before #523: the unwind clears a date propagated under the sample rule from a row whose digest is KNOWN to differ; an unhashed one is kept")
    func unwindClearsAProvenMismatch() throws {
        let sb = try F.Sandbox("t523_unwind"); defer { sb.cleanup() }
        let origin = sb.record("test_w_origin.mkv", stage: .cataloged, onDisk: false)
        origin.inferredRecordDate = F.utc(1991); origin.inferredDateConfidence = 0.95
        Self.sample(origin, digest: Self.digestX)
        let mismatched = sb.record("test_w_mismatch.mkv", stage: .cataloged, onDisk: false)
        Self.sample(mismatched, digest: Self.digestY)
        let unhashed = sb.record("test_w_unhashed.mkv", stage: .cataloged, onDisk: false)
        Self.sample(unhashed, digest: nil)
        for r in [mismatched, unhashed] {
            r.inferredRecordDate = F.utc(1991); r.inferredDateConfidence = 0.95
            r.inferredDateSource = VideoScanModel.InferredDateSource.propagated(from: origin)
        }
        sb.model.records = [origin, mismatched, unhashed]
        let r = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                        trigger: "test")
        #expect(r.unwound == 1 && r.conflictingHashes == 1, "\(r)")
        #expect(mismatched.inferredRecordDate == nil, "proven different content: the date is unwound (sidecar kept)")
        #expect(unhashed.inferredRecordDate == F.utc(1991), "unproven, not disproven: left as it was")
    }

    // MARK: Dossier carry-over

    @Test("RED before #523: Dossier carry-over never calls a different digest — or an unhashed sample twin — 'same bytes'; the same digest still carries")
    func carryOverNeedsTheSameDigest() async throws {
        let sb = try F.Sandbox("t523_carry"); defer { sb.cleanup() }
        let donor = sb.record("test_c_donor.mov", stage: .cataloged)
        donor.sceneCaptions = [SceneCaption(timestamp: 1, text: "Thanksgiving dinner")]
        donor.audioTranscript = "next to him we have Mr. Glenn Hudson"
        donor.ocrDateCandidates = [F.ocr1991]
        donor.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        donor.dossierProcessedBy = "vlm-x+whisper-x"
        let other = sb.record("test_c_other.mov", stage: .cataloged)
        let unhashed = sb.record("test_c_unhashed.mov", stage: .cataloged)
        let same = sb.record("test_c_same.mov", stage: .cataloged)
        Self.sample(donor, digest: Self.digestX); Self.sample(other, digest: Self.digestY)
        Self.sample(unhashed, digest: nil); Self.sample(same, digest: Self.digestX)
        let index = DossierCarryOverIndex(records: [donor, other, unhashed, same], candidates: [other, unhashed, same])
        #expect(index.donor(for: other) == nil, "different interior bytes: analyze, never carry")
        #expect(index.donor(for: unhashed) == nil, "no whole-file digest: analyze, never carry")
        let carried = index.donor(for: same)
        #expect(carried?.record === donor && carried?.relation == .sameBytes, "control: the same digest carries")
    }

    // MARK: Relocate Bucket E

    private static func plan(_ source: VideoRecord, witnesses: [VideoRecord], sourceRoot: String) -> ReconcilePlan {
        RelocateReconcile.reconcilePlan(
            records: [source.asReconcileInput], witnesses: ([source] + witnesses).map(\.asReconcileInput),
            sourceVolumeRootPath: sourceRoot, destinationRoot: URL(fileURLWithPath: "/Volumes/TestDest523/dest"),
            sourceFiles: [ReconcileFileEntry(path: source.fullPath, size: source.sizeBytes)], destFiles: [],
            skipDupsOnOtherVolumes: true,
            witnessOnDisk: { _, _ in true }, witnessIndependent: { _, _, _ in true },
            hash: { _ in sampleMD5 })
    }

    private static func row(_ path: String, digest: String?) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        sample(r, digest: digest)
        return r
    }

    @Test("RED before #523: Bucket E never skips a copy on the strength of a sample — a different digest or none is no witness; the same digest is")
    func bucketENeedsTheSameDigest() {
        let root = "/Volumes/TestSrc523"
        let source = Self.row(root + "/kids.mov", digest: Self.digestX)
        let differs = Self.row("/Volumes/TestThird523/kids.mov", digest: Self.digestY)
        let unhashed = Self.row("/Volumes/TestFourth523/kids.mov", digest: nil)
        #expect(Self.plan(source, witnesses: [differs, unhashed], sourceRoot: root).safelyRedundant.isEmpty,
                "same size + partialMD5 is not the same file: the record must be copied")
        let unhashedSource = Self.row(root + "/kids2.mov", digest: nil)
        let twinOfUnhashed = Self.row("/Volumes/TestThird523/kids2.mov", digest: nil)
        #expect(Self.plan(unhashedSource, witnesses: [twinOfUnhashed], sourceRoot: root).safelyRedundant.isEmpty,
                "an unhashed source is never skipped")
        let same = Self.row("/Volumes/TestThird523/kids_copy.mov", digest: Self.digestX)
        #expect(Self.plan(source, witnesses: [differs, same], sourceRoot: root).safelyRedundant.map(\.witnesses)
                == [[same.fullPath]], "control: a same-digest witness vouches, and only it")
    }

    /// MEDIA: two real files of one size whose head and tail windows are
    /// identical (so FileHasher.partialMD5 agrees) and whose middle differs.
    @Test("RED before #523 (MEDIA): real files with equal partialMD5 and different interior bytes are not Bucket E witnesses")
    func bucketEOnRealFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t523_media_\(UUID().uuidString.prefix(8))")
        let srcDir = dir.appendingPathComponent("src"), third = dir.appendingPathComponent("third")
        for d in [srcDir, third] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = 8 * 1024 * 1024
        var a = Data(count: size)
        for i in 0..<size { a[i] = UInt8((i &* 31) % 251) }
        var b = a
        b[size / 2] ^= 0xFF                                         // one interior byte
        let pa = srcDir.appendingPathComponent("tape.mov"), pb = third.appendingPathComponent("tape.mov")
        try a.write(to: pa); try b.write(to: pb)
        let md5a = FileHasher.partialMD5(path: pa.path), md5b = FileHasher.partialMD5(path: pb.path)
        try #require(!md5a.isEmpty && md5a == md5b, "the fixture must collide on the sample")
        func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let source = Self.row(pa.path, digest: nil), witness = Self.row(pb.path, digest: nil)
        for (r, bytes) in [(source, a), (witness, b)] {
            r.sizeBytes = Int64(size); r.partialMD5 = md5a
            r.contentFixity = W.fixity(sha256(bytes), Int64(size))
        }
        try #require(CatalogCommit.digest(of: source) != nil && CatalogCommit.digest(of: source) != CatalogCommit.digest(of: witness))
        let plan = RelocateReconcile.reconcilePlan(
            records: [source.asReconcileInput], witnesses: [source, witness].map(\.asReconcileInput),
            sourceVolumeRootPath: srcDir.path, destinationRoot: dir.appendingPathComponent("dest"),
            sourceFiles: [ReconcileFileEntry(path: pa.path, size: Int64(size))], destFiles: [],
            skipDupsOnOtherVolumes: true, witnessIndependent: RelocateReconcile.witnessIsNotTheSourceFile,
            hash: { FileHasher.partialMD5(path: $0) })
        #expect(plan.safelyRedundant.isEmpty, "the third-volume file differs inside: Migrate must copy")
        #expect(plan.readyIDs == [source.id])
    }
}

// MARK: - Fixture helper (GH #523)

/// Older fixtures name a row's CONTENT by its partialMD5 (+ size, + the
/// segmented contentHash when they set one). Since GH #523 "same content" is
/// the whole-file SHA-256, so such a fixture row must carry one: this gives it
/// a deterministic digest derived from exactly those fields — two rows the
/// fixture means as byte twins get the same digest, two rows whose
/// contentHash differs get different ones. A row with no partialMD5 or no
/// size is left unhashed (no whole-file digest ⇒ no identity).
/// (For Rick: a test-only stand-in for "this file was fully hashed".)
enum FixtureDigest {
    static func digest(md5: String, size: Int64, contentHash: String = "") -> String {
        SHA256.hash(data: Data("\(md5)|\(size)|\(contentHash)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stamp `r` as fully hashed from its partialMD5 / size / contentHash.
    @MainActor
    static func stamp(_ r: VideoRecord) {
        guard !r.partialMD5.isEmpty, r.sizeBytes > 0 else { return }
        r.contentFixity = ArchivedTwinDateWritersTests.fixity(
            digest(md5: r.partialMD5, size: r.sizeBytes, contentHash: r.contentHash), r.sizeBytes)
    }

    /// `rows`, each stamped (as `stamp`) unless it already carries a fixity.
    @MainActor
    static func stamped(_ rows: [VideoRecord]) -> [VideoRecord] {
        for r in rows where r.contentFixity == nil { stamp(r) }
        return rows
    }

    /// The real whole-file SHA-256 of a file on disk (streamed, 1 MiB chunks).
    static func sha256(ofFileAt path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stamp `r` with the real digest of its file when it exists, else as `stamp`.
    @MainActor
    static func stampFromDisk(_ r: VideoRecord) {
        if r.sizeBytes > 0, let d = sha256(ofFileAt: r.fullPath) {
            r.contentFixity = ArchivedTwinDateWritersTests.fixity(d, r.sizeBytes)
        } else {
            stamp(r)
        }
    }
}
