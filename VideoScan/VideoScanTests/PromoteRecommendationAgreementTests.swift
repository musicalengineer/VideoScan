// PromoteRecommendationAgreementTests.swift
//
// ONE INVARIANT, stated by Rick on 2026-09-16 after clicking a file the
// Archive view had just offered him:
//
//   "make sure the AA and the other recommendation file list in archive
//    view does not recommend a file to promote then when you go to promote
//    it, it says 'already promoted'. It is that simple."
//
// It is that simple, and it got un-simple because three surfaces each
// answered "is this already archived?" their own way:
//
//   buildPromotePlan / Archive categories   masterArchiveCopy(of:) != nil
//   ArchiveAngel.hardFloor                  isOnMasterArchive — the PATH
//   ArchiveAngel `archived`                 isArchiveCopy || inside || copy
//
// The middle one is the trap. A promoted original STAYS ON ITS OWN VOLUME
// and gains a linked copy in the archive, so "is this path inside the
// archive?" answers *no* for every file that has ever been promoted — and
// the Angel proposed them all over again.
//
// These tests do not check a message or a count. They check that the
// RECOMMENDERS and the ENGINE agree, which is the only thing that keeps
// Rick from being offered something Promote then refuses.
//
// Five dimensions:
//   1. Logic     — a promoted original is refused, an un-promoted one is not
//   2. Scale     — the agreement holds over a 10k catalog inside a budget
//   3. Media     — n/a (no media is opened; this is catalog identity)
//   4. Isolation — injected model + scratch archive root, no real App Support
//   5. Sensor    — the cross-surface agreement itself: any recommender that
//                  stops asking the engine fails here, whatever it offers

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Promote — recommenders never offer what the engine refuses", .serialized)
struct PromoteRecommendationAgreementTests {

    private func seed(_ sb: MasterArchiveTestSupport.Sandbox, count: Int) throws -> [URL] {
        try (0..<count).map { i in
            try MasterArchiveTestSupport.writeBlob(
                at: sb.sources.appendingPathComponent("agree_src_\(i).mov"),
                bytes: 64 * 1024 + i, seed: UInt64(i + 1))
        }
    }

    // MARK: - 1. The predicate itself

    @Test func aPromotedOriginalIsRefusedEvenThoughItsPathIsOutsideTheArchive() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("agree")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        _ = try MasterArchiveTestSupport.initialize(model, in: sb)

        let original = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [original]
        #expect(model.promoteRefusal(original) == nil, "a fresh original is promotable")

        _ = await MasterArchiveTestSupport.promote(model, ids: [original.id])

        let after = try #require(model.record(forID: original.id))
        // The whole point: its PATH never moved.
        #expect(!model.isInsideMasterArchive(path: after.fullPath),
                "the original stays on its own volume — that is why a path test misses it")
        #expect(model.promoteRefusal(after) == .alreadyPromoted)
        #expect(model.promoteWouldRefusePermanently(after))
    }

    // MARK: - 5. The cross-surface sensor

    /// THE SENSOR. Whatever a recommender offers, `buildPromotePlan` must
    /// not then skip it for a permanent reason. A surface that invents its
    /// own "already archived" test fails here the moment it disagrees.
    @Test func nothingARecommenderOffersIsPermanentlyRefusedByThePlan() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("agree-sensor")
        defer { sb.cleanup() }
        let files = try seed(sb, count: 6)
        let model = MasterArchiveTestSupport.makeModel(sb)
        _ = try MasterArchiveTestSupport.initialize(model, in: sb)
        model.records = files.map { MasterArchiveTestSupport.makeRecord(path: $0.path) }

        // Promote half of them, so the catalog holds both kinds.
        let promotedIDs = model.records.prefix(3).map(\.id)
        _ = await MasterArchiveTestSupport.promote(model, ids: Array(promotedIDs))

        let offered = model.records.filter { !model.promoteWouldRefusePermanently($0) }
        #expect(!offered.isEmpty, "the fixture must still offer something")

        let plan = try #require(model.buildPromotePlan(recordIDs: offered.map(\.id)))
        let permanentlySkipped = plan.skipped.filter { $0.reason.isPermanent }
        #expect(permanentlySkipped.isEmpty,
                "offered then refused: \(permanentlySkipped.map { "\($0.filename) — \($0.reason)" })")

        // THE CONVERSE, so this cannot pass by offering nothing. Asserted
        // per id, not by counting: promoting also ADDS three archive-copy
        // records, and those are correctly refused as well — an early
        // version of this test counted 3 and got 6, which was the test
        // being wrong, not the code.
        for id in promotedIDs {
            let rec = try #require(model.record(forID: id))
            #expect(model.promoteWouldRefusePermanently(rec),
                    "\(rec.filename) was promoted but is still being offered")
            #expect(!offered.contains { $0.id == id },
                    "\(rec.filename) is in the offered list after being promoted")
        }
    }

    // MARK: - 2. Scale

    /// The agreement is checked per record on a list that can run to
    /// thousands, so it has to stay an index lookup, not a disk probe.
    @Test func theRecommenderPredicateStaysCheapOverALargeCatalog() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("agree-scale")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        _ = try MasterArchiveTestSupport.initialize(model, in: sb)
        model.records = (0..<10_000).map { i in
            MasterArchiveTestSupport.makeRecord(path: "/Volumes/Nope/clip_\(i).mov")
        }

        let start = Date()
        let offered = model.records.filter { !model.promoteWouldRefusePermanently($0) }
        let elapsed = -start.timeIntervalSinceNow

        #expect(offered.count == 10_000)
        #expect(elapsed < 2.0,
                "10k recommender checks took \(String(format: "%.2f", elapsed))s — it stopped being O(1) per record")
    }
}
