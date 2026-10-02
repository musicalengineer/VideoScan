// PromoteAdoptionProofTests.swift
// Codex review 2026-10-02, finding 1 (P1): adoption trusted a STORED digest.
//
// `chooseDestinationOffMain` compared a file already sitting at the planned
// destination against the source's cached `ContentFixity` digest. A stored
// digest that lies (fresh stamp, wrong bytes) therefore made Promote ADOPT a
// different file — B was registered as A's archive copy and the copy path
// (which re-proves the source bytes) never ran.
//
// The rule now: before ANY journal entry or registration, Promote proves
// the CURRENT source bytes — a digest read from the source in this run —
// and adoption compares the existing destination's bytes against THAT
// proof. A cached fixity is only ever a fast path for the duplicate
// lookup, never evidence for adoption.
//
// Sandbox only (`test_*` names, temp dir) — never /Volumes, never App Support.
// (For Rick: `#require` ≈ ASSERT_*, `#expect` ≈ EXPECT_*.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Codex 2026-10-02 #1 — adoption proves the CURRENT source bytes, never a stored digest", .serialized)
@MainActor
struct PromoteAdoptionProofTests {

    typealias H = PromoteIntegrityHarness

    /// The planned base destination for `rec` (where a collision is checked).
    private func plannedBase(_ rec: VideoRecord) -> String {
        ArchivePathResolver.baseRelativePath(facts: ArchivePathResolver.facts(for: rec), title: nil)
    }

    /// A different, SAME-SIZE file B placed at A's planned destination,
    /// with no manifest row and no catalog record (invisible to #190).
    private func plantImpostor(at rel: String, in sb: MasterArchiveTestSupport.Sandbox,
                               bytes: Int, seed: UInt64) throws -> String {
        let url = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: url, bytes: bytes, seed: seed)
        return try #require(MasterArchiveTestSupport.sha256(ofFile: url.path))
    }

    @Test("a lying stored digest equal to an existing file's bytes cannot make Promote adopt that file")
    func lyingDigestCannotAdoptDifferentBytes() async throws {
        let (sb, model) = try H.setup("adopt_lie")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_clip_a.mov", seed: 41, bytes: 30_000)
        let rel = plannedBase(a)
        let shaB = try plantImpostor(at: rel, in: sb, bytes: 30_000, seed: 42)
        let shaA = try #require(MasterArchiveTestSupport.sha256(ofFile: a.fullPath))
        try #require(shaA != shaB)

        // A's stored fixity claims B's bytes, bound to A's CURRENT stamp.
        let stamp = try #require(FileIdentityStamp.capture(path: a.fullPath))
        let lying = ContentFixity(digest: shaB, byteCount: a.sizeBytes, stamp: stamp)
        try #require(lying.isUsableForVerification, "the sandbox volume must yield a UUID-bound stamp")
        a.contentFixity = lying
        let journalBefore = try? Data(contentsOf: sb.journalURL)

        let job = try await H.run(model, ids: [a.id])
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind != .adopted, "B must never be adopted as A's copy: \(o.kind) — \(o.detail)")
        #expect(model.masterArchiveCopy(of: a)?.archiveFixity?.digest != shaB, "B registered as A's archive copy")
        #expect(model.masterArchiveCopy(of: a) == nil, "nothing registered for A")
        #expect(o.kind == .failed, "refused: \(o.kind) — \(o.detail)")
        // Refused BEFORE any journal entry; B itself untouched.
        #expect((try? Data(contentsOf: sb.journalURL)) == journalBefore, "no journal entry for a refused file")
        #expect(MasterArchiveTestSupport.sha256(ofFile: sb.archiveRoot.appendingPathComponent(rel).path) == shaB)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        #expect(model.promoteDigestClaim(shaB, root: sb.archiveRoot.path) == nil, "the lying claim is released")
    }

    @Test("an HONEST stored digest + a byte-identical file already at the destination is still adopted (proof read, not a cache hit)")
    func honestDigestStillAdopts() async throws {
        let (sb, model) = try H.setup("adopt_honest")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_clip_a.mov", seed: 43, bytes: 30_000)
        let rel = plannedBase(a)
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: a.fullPath, toPath: dest.path)
        let shaA = try #require(MasterArchiveTestSupport.sha256(ofFile: a.fullPath))
        let stamp = try #require(FileIdentityStamp.capture(path: a.fullPath))
        a.contentFixity = ContentFixity(digest: shaA, byteCount: a.sizeBytes, stamp: stamp)

        let job = try await H.run(model, ids: [a.id])
        #expect(H.outcome(job, a.id)?.kind == .adopted, "\(job.outcomes)")
        #expect(model.masterArchiveCopy(of: a)?.archiveFixity?.digest == shaA)
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [rel], "adopted in place, no second copy")
    }

    @Test("NO stored digest + a same-size DIFFERENT file at the destination → copied beside it, never adopted")
    func noDigestDifferentBytesCopiedBeside() async throws {
        let (sb, model) = try H.setup("adopt_none")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_clip_a.mov", seed: 44, bytes: 30_000)
        let rel = plannedBase(a)
        let shaB = try plantImpostor(at: rel, in: sb, bytes: 30_000, seed: 45)
        let job = try await H.run(model, ids: [a.id])
        #expect(H.outcome(job, a.id)?.kind == .promoted, "\(job.outcomes)")
        let copy = try #require(model.masterArchiveCopy(of: a))
        #expect(copy.archiveFixity?.digest != shaB)
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 2, "B stays, A lands as _02")
    }
}
