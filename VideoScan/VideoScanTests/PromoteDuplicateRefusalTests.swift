// PromoteDuplicateRefusalTests.swift
//
// Rick, 2026-10-07: "Promote just allowed me to promote <a 73 GB tape
// capture> again while it is already in there."
//
// What happened (read-only forensics, 10/7): the archive copy was promoted on
// 8/22 from a STAGING sibling on another volume. That staging file was later
// trashed and its record pruned, so the archive copy's promote link
// (`derivedFrom`) points at a record that no longer exists. The surviving
// sibling on the other volume:
//   • has no promote link          → masterArchiveCopy(of:) == nil
//   • has an EMPTY contentHash     → the segmented-hash leg misses
//   • sits alone in its dup group  → the dup-group leg misses
//   • DOES carry a full-file sha256 (contentFixity) equal to the archive
//     copy's verified digest — but its stamp predates the volume-UUID
//     binding and the ctime has moved, so the job (correctly) will not let
//     it stand in for a read.
// So the plan gate (`promoteRefusal`) accepted it, the sheet offered it, and
// only the job's full 73 GB read refused it, six and a half minutes later.
// Nothing landed in the archive. The gap is the PLAN gate: it never asked
// the one piece of evidence the catalog already had — the full digest.
//
// The fix (one sentence): Promote refuses, before any work, a file the
// catalog already knows by its full sha256 to be in the archive, and names
// the archived file.
//
// Five dimensions:
//   1. Logic     — the exact shape above is refused at plan time, with the
//                  archived path; a changed file / different digest / size
//                  mismatch is NOT refused at plan time (the job decides)
//   2. Scale     — the recommender form stays an index lookup over 10k
//   3. Media     — n/a (identity only; no decoder involved)
//   4. Isolation — sandbox archive root, isolated catalog store
//   5. Sensor    — every promote entry point builds its plan through
//                  buildPromotePlan → promoteRefusal (source scan)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Promote — refuse a file the archive already holds (by full digest)", .serialized)
struct PromoteDuplicateRefusalTests {

    /// The reported shape: promote a staging copy, prune its record,
    /// leave an identical sibling whose fingerprint has a stale stamp.
    private struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let copy: VideoRecord
        let sibling: VideoRecord
        let siblingURL: URL
        let digest: String
    }

    private func makeFixture(_ label: String,
                             tweakFixity: ((FileIdentityStamp) -> FileIdentityStamp)? = nil,
                             digestOverride: String? = nil) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let fm = FileManager.default
        let staging = sb.sources.appendingPathComponent("staging", isDirectory: true)
        let expansion = sb.sources.appendingPathComponent("expansion", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: expansion, withIntermediateDirectories: true)
        let stagingURL = try MasterArchiveTestSupport.writeBlob(
            at: staging.appendingPathComponent("test_tape_capture.mkv"), bytes: 96 * 1024, seed: 1995)
        let siblingURL = expansion.appendingPathComponent("test_tape_capture.mkv")
        try fm.copyItem(at: stagingURL, to: siblingURL)

        let model = MasterArchiveTestSupport.makeModel(sb)
        _ = try MasterArchiveTestSupport.initialize(model, in: sb)
        let staged = MasterArchiveTestSupport.makeRecord(path: stagingURL.path, userDate: "1995")
        model.records = [staged]
        _ = await MasterArchiveTestSupport.promote(model, ids: [staged.id])
        let copy = try #require(model.masterArchiveCopy(of: staged), "fixture: the staging copy was promoted")

        // The staging file was trashed and its record pruned: the copy's
        // promote link now dangles.
        model.records.removeAll { $0.id == staged.id }

        let digest = try #require(MasterArchiveTestSupport.sha256(ofFile: siblingURL.path))
        let sibling = MasterArchiveTestSupport.makeRecord(path: siblingURL.path)
        sibling.contentHash = ""
        let real = try #require(FileIdentityStamp.capture(path: siblingURL.path))
        // Stale stamp: another st_dev (remount), an older ctime, and no
        // volume UUID (pre-9/23 binding) — exactly what the job distrusts.
        let stale = FileIdentityStamp(device: real.device &+ 26, inode: real.inode, size: real.size,
                                      mtimeNs: real.mtimeNs, ctimeNs: real.ctimeNs - 5_000_000_000,
                                      volumeUUID: nil)
        let stamp = tweakFixity?(stale) ?? stale
        sibling.contentFixity = ContentFixity(digest: digestOverride ?? digest,
                                              byteCount: real.size, stamp: stamp)
        model.records.append(sibling)
        return Fixture(sb: sb, model: model, copy: copy, sibling: sibling,
                       siblingURL: siblingURL, digest: digest)
    }

    // MARK: - 1. Logic — the reported case

    @Test func anUnlinkedSiblingWithTheArchivedDigestIsRefusedAtPlanTime() async throws {
        let f = try await makeFixture("dup-sibling")
        defer { f.sb.cleanup() }

        // Premise — the three legs that existed all miss, as on Rick's Mac.
        #expect(f.model.masterArchiveCopy(of: f.sibling) == nil, "no promote link")
        #expect(f.sibling.contentHash.isEmpty, "no segmented hash")
        #expect(f.model.record(forID: try #require(f.copy.derivedFrom)) == nil, "the copy's source was pruned")
        #expect(f.copy.archiveFixity?.digest.lowercased() == f.digest, "the archive holds these bytes")

        // THE BUG: the plan gate must refuse, naming the archived file.
        #expect(f.model.identicalArchivedCopy(of: f.sibling)?.id == f.copy.id)
        #expect(f.model.promoteRefusal(f.sibling) == .alreadyPromoted)
        #expect(f.model.promoteWouldRefusePermanently(f.sibling),
                "recommenders must not offer what the plan refuses")

        let plan = try #require(f.model.buildPromotePlan(recordIDs: [f.sibling.id]))
        #expect(plan.entries.isEmpty, "offered for promotion: \(plan.entries.map(\.filename))")
        #expect(plan.skipped.map(\.reason) == [.alreadyPromoted])
        let detail = try #require(f.model.promoteSkipDetail(recordID: f.sibling.id, reason: .alreadyPromoted))
        #expect(detail.contains(f.copy.fullPath), "the skip names the archived file: \(detail)")
    }

    @Test func requestPromoteThenTheJobWritesNothingAndKeepsOneCopy() async throws {
        let f = try await makeFixture("dup-e2e")
        defer { f.sb.cleanup() }
        let filesBefore = MasterArchiveTestSupport.archivedFiles(f.sb)
        let rowsBefore = MasterArchiveTestSupport.manifestRows(f.sb).count
        let journalBefore = try? Data(contentsOf: f.sb.journalURL)

        f.model.requestPromote(recordIDs: [f.sibling.id])
        let request = try #require(f.model.pendingPromoteRequest)
        #expect(request.plan.entries.isEmpty, "the sheet would offer a duplicate")

        _ = await MasterArchiveTestSupport.promote(f.model, ids: [f.sibling.id])
        #expect(MasterArchiveTestSupport.archivedFiles(f.sb) == filesBefore, "a second copy landed")
        #expect(MasterArchiveTestSupport.manifestRows(f.sb).count == rowsBefore)
        #expect((try? Data(contentsOf: f.sb.journalURL)) == journalBefore, "the journal was written")
    }

    // MARK: - 1b. What the plan gate must NOT refuse (the job decides)

    @Test func aFingerprintWhoseFileHasSinceChangedIsNotRefusedAtPlanTime() async throws {
        let f = try await makeFixture("dup-mtime") { s in
            FileIdentityStamp(device: s.device, inode: s.inode, size: s.size,
                              mtimeNs: s.mtimeNs - 60_000_000_000, ctimeNs: s.ctimeNs, volumeUUID: nil)
        }
        defer { f.sb.cleanup() }
        #expect(f.model.promoteRefusal(f.sibling) == nil,
                "mtime moved — the stored digest may no longer describe these bytes; the job's full read decides")
    }

    @Test func aDifferentDigestIsNotRefused() async throws {
        let other = String(repeating: "ab", count: 32)
        let f = try await makeFixture("dup-other", digestOverride: other)
        defer { f.sb.cleanup() }
        #expect(f.model.identicalArchivedCopy(of: f.sibling) == nil)
        #expect(f.model.promoteRefusal(f.sibling) == nil)
        #expect(!f.model.promoteWouldRefusePermanently(f.sibling))
    }

    @Test func aDigestWhoseByteCountDisagreesWithTheCopyIsNotTrusted() async throws {
        let f = try await makeFixture("dup-size")
        defer { f.sb.cleanup() }
        f.sibling.sizeBytes += 1
        #expect(f.model.identicalArchivedCopy(of: f.sibling) == nil,
                "a catalog size that disagrees with the fingerprint is not a match")
    }

    @Test func theArchiveCopyItselfIsStillRefusedAsACopyNotAsItsOwnDuplicate() async throws {
        let f = try await makeFixture("dup-self")
        defer { f.sb.cleanup() }
        #expect(f.model.identicalArchivedCopy(of: f.copy) == nil)
        #expect(f.model.promoteRefusal(f.copy) == .isArchiveCopy)
    }

    // MARK: - 2. Scale

    /// The recommender form is asked per record over lists that run to
    /// thousands: it must stay an index lookup (no disk).
    @Test func theDigestLegStaysAnIndexLookupOverALargeCatalog() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("dup-scale")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        _ = try MasterArchiveTestSupport.initialize(model, in: sb)
        let stamp = FileIdentityStamp(device: 1, inode: 1, size: 10, mtimeNs: 1, ctimeNs: 1)
        model.records = (0..<10_000).map { i in
            let r = MasterArchiveTestSupport.makeRecord(path: "/Volumes/Nope/clip_\(i).mov")
            r.sizeBytes = 10
            let hex = String(format: "%064x", i)
            r.contentFixity = ContentFixity(digest: hex, byteCount: 10, stamp: stamp)
            return r
        }
        let start = Date()
        let offered = model.records.filter { !model.promoteWouldRefusePermanently($0) }
        let elapsed = -start.timeIntervalSinceNow
        #expect(offered.count == 10_000)
        #expect(elapsed < 2.0, "10k checks took \(String(format: "%.2f", elapsed))s — no longer O(1) per record")
    }

    // MARK: - 5. Sensor — one preflight for every entry point

    /// Every promote entry point must reach the job through
    /// `buildPromotePlan`, whose loop asks `promoteRefusal` for each record,
    /// and `promoteRefusal` must ask the full-digest leg. A new surface that
    /// builds a plan by hand, or a gate that drops the digest leg, fails here.
    @Test func everyPromoteEntryPointGoesThroughTheDuplicatePreflight() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
        let base = app.resolvingSymlinksInPath().standardizedFileURL
        var planBuilders: Set<String> = []
        var jobBuilders: Set<String> = []
        let it = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = it?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let rel = String(path.dropFirst(base.path.count + 1))
            let code = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("ArchivePromotePlan(") }) { planBuilders.insert(rel) }
            if code.contains(where: { $0.contains("PromoteToArchiveJob(plan:") }) { jobBuilders.insert(rel) }
        }
        #expect(planBuilders == ["Archive/VideoScanModel+MasterArchive.swift"],
                "a plan built outside buildPromotePlan skips the duplicate preflight: \(planBuilders.sorted())")
        #expect(jobBuilders == ["MediaOps/MediaFileOperations+Promote.swift"],
                "a new place starts a Promote job — route it through requestPromote/buildPromotePlan: \(jobBuilders.sorted())")

        let gate = try String(contentsOf: base.appendingPathComponent("Archive/VideoScanModel+MasterArchive.swift"),
                              encoding: .utf8)
        func body(of sig: String) throws -> Substring {
            let s = try #require(gate.range(of: sig), "missing \(sig)")
            let end = gate.range(of: "\n    }\n", range: s.upperBound..<gate.endIndex)?.lowerBound ?? gate.endIndex
            return gate[s.upperBound..<end]
        }
        #expect(try body(of: "func buildPromotePlan(recordIDs").contains("promoteRefusal(rec)"),
                "buildPromotePlan must ask promoteRefusal for every record")
        #expect(try body(of: "func promoteRefusal(_ rec").contains("identicalArchivedCopy(of: rec)"),
                "promoteRefusal must consult the full-digest leg")
        #expect(try body(of: "func promoteWouldRefusePermanently(").contains("identicalArchivedCopy(of: rec)"),
                "the recommender form must agree with the plan gate")
    }
}
