import Testing
import Foundation
@testable import VideoScan

// Codex review F2 (P1): a footage-shared date stayed after the donor's claim
// was retracted (user date cleared) or the group was downgraded to
// `possible` — Promote kept filing the sibling under a year nobody claims.

@MainActor
@Suite("Codex F2 — a share is stale unless the donor still holds the shared claim in a ≥ likely, not-refused group")
struct DateReviewF2Tests {
    typealias F = DateReviewFixtures

    private func shared() -> (VideoScanModel, VideoRecord, VideoRecord) {
        let model = F.model("f2")
        let (a, b) = F.pair()
        a.userDate = "1992"
        model.records = [a, b]
        model.catchUpInferredDates(trigger: "test")
        return (model, a, b)
    }

    @Test("clearing the donor's user date removes the share; dateHint becomes unknown")
    func retractedUserDate() {
        let (model, a, b) = shared()
        #expect(F.resolve(b).year == 1992)
        a.userDate = nil
        model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredRecordDate == nil && b.inferredDateSource == nil, "\(b.inferredDateReason ?? "nil")")
        #expect(ArchivePathResolver.facts(for: b).dateHint == .unknown)
    }

    @Test("the donor's claim changing year re-shares the new year (never keeps the old one)")
    func changedUserDate() {
        let (model, a, b) = shared()
        a.userDate = "1993"
        model.catchUpInferredDates(trigger: "test")
        #expect(F.resolve(b).year == 1993)
    }

    @Test("downgrading the group to `possible` removes the share")
    func downgradedGroup() {
        let (model, a, b) = shared()
        a.footage?.confidence = .possible
        b.footage?.confidence = .possible
        model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredRecordDate == nil && b.inferredDateSource == nil)
        #expect(ArchivePathResolver.facts(for: b).dateHint == .unknown)
    }

    @Test("Rick's 'not the same' removes the share")
    func notSameDecision() {
        let (model, a, b) = shared()
        b.setFootageDecision(FootageDecision(otherID: a.id, verdict: .notSame))
        a.setFootageDecision(FootageDecision(otherID: b.id, verdict: .notSame))
        model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredRecordDate == nil && b.inferredDateSource == nil)
    }

    /// Codex re-review R1: a DONOR-scoped pass must reach the donor's former
    /// dependents — A moved to another group, B still says "shared from A".
    @Test("donor-scoped pass after A is regrouped clears B's share")
    func donorScopedPassAfterRegroupClearsDependents() {
        let (model, a, b) = shared()
        #expect(F.resolve(b).year == 1992)
        a.footage?.groupID = UUID()
        model.catchUpInferredDates(scope: [a], trigger: "test")
        #expect(F.InferredSnapshot(b) == F.InferredSnapshot(VideoRecord()), "\(b.inferredDateReason ?? "nil")")
        #expect(ArchivePathResolver.facts(for: b).dateHint == .unknown)
    }

    @Test("donor-scoped pass after the donor's membership is downgraded clears B's share")
    func donorScopedPassAfterDowngradeClearsDependents() {
        let (model, a, b) = shared()
        a.footage?.confidence = .possible
        model.catchUpInferredDates(scope: [a], trigger: "test")
        #expect(b.inferredRecordDate == nil && b.inferredDateSource == nil && b.inferredDateRange == nil
                && b.inferredDateConfidence == nil, "\(b.inferredDateReason ?? "nil")")
    }

    // MARK: - GH #207: the attack pins codex listed after the #201 merge

    /// A donor that left the catalog (removed from `records`) or was purged,
    /// but is still named in a scoped pass: its dependents lose the share.
    @Test("a removed donor supplied in scope clears its dependents", arguments: ["removed", "purged"])
    func removedDonorInScopeClearsDependents(_ how: String) {
        let (model, a, b) = shared()
        #expect(F.resolve(b).year == 1992)
        if how == "removed" { model.records = [b] } else { a.purgedAt = F.now }
        model.catchUpInferredDates(scope: [a], trigger: "test")
        #expect(F.InferredSnapshot(b) == F.InferredSnapshot(VideoRecord()), "\(b.inferredDateReason ?? "nil")")
        #expect(ArchivePathResolver.facts(for: b).dateHint == .unknown)
        #expect(a.userDate == "1992", "the pass never writes a user date")
    }

    /// Three members of one footage group, or of two groups (`splitGroups`:
    /// C alone in a second group). Names carry no year.
    private func trio(splitGroups: Bool) -> (VideoRecord, VideoRecord, VideoRecord) {
        let g1 = UUID(), g2 = splitGroups ? UUID() : g1
        func make(_ dir: String, group: UUID, rank: Int) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = "/Volumes/\(dir)/clip.mov"; r.filename = "clip.mov"; r.directory = "/Volumes/\(dir)"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.footage = FootageMembership(groupID: group, groupSize: splitGroups ? 2 : 3, confidence: .likely,
                                          role: rank == 0 ? .original : .copy, rank: rank,
                                          likelyOriginalID: r.id, originalInCatalog: true,
                                          evidence: ["same name + length"], scannedAt: F.now, algorithmVersion: 1)
            return r
        }
        return (make("A", group: g1, rank: 0), make("B", group: g1, rank: 1), make("C", group: g2, rank: 1))
    }

    /// The invalid chain A→B→C: C still says "footage-shared from B" while
    /// B's own date is a share from A — B cannot donate (a derived date
    /// never donates). Reached realistically: B held a user date that C
    /// took; B's user date is cleared, A gains one, and a pass scoped to A
    /// runs. With C in another group (B regrouped), the R1 one-hop
    /// expansion (A's dependents) never reached C — red before GH #207; the
    /// scoped pass now also re-checks shares naming A's groupmates.
    @Test("chain A→B→C where B cannot donate: an A-scoped pass leaves C no stale share",
          arguments: [false, true])
    func invalidChainLeavesNoStaleShare(splitGroups: Bool) {
        let model = F.model("f2-chain")
        let (a, b, c) = trio(splitGroups: splitGroups)
        if splitGroups {
            // C took B's date while B and C were one group …
            b.footage?.groupID = c.footage?.groupID ?? UUID()
        }
        b.userDate = "1990"
        model.records = [a, b, c]
        model.catchUpInferredDates(trigger: "test")
        #expect(c.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: b))
        #expect(F.resolve(c).year == 1990)
        if splitGroups {
            // … then B was regrouped with A.
            b.footage?.groupID = a.footage?.groupID ?? UUID()
        }
        // B's claim goes; A gains one; B now takes A's date (so B cannot donate).
        b.userDate = nil
        a.userDate = "1992"
        model.catchUpInferredDates(scope: [a], trigger: "test")
        #expect(b.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: a),
                "\(b.inferredDateReason ?? "nil")")
        #expect(!VideoScanModel.canDonateInferredDate(b))
        #expect(c.inferredDateSource != VideoScanModel.InferredDateSource.footageShared(from: b),
                "C kept a share from B, whose date is itself a share: \(c.inferredDateReason ?? "nil")")
        let byID = Dictionary(uniqueKeysWithValues: model.records.map { ($0.id, $0) })
        #expect(!VideoScanModel.isStaleFootageShare(c, byID: byID, now: F.now))
        if splitGroups {
            // C is alone in its group now: no share at all.
            #expect(F.InferredSnapshot(c) == F.InferredSnapshot(VideoRecord()), "\(c.inferredDateReason ?? "nil")")
        } else {
            #expect(c.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: a))
            #expect(F.resolve(c).year == 1992)
        }
    }

    /// The scoped pass runs on the MainActor and is O(catalog) (the R1
    /// dependents scan + the bucketing walk). A donor-scoped pass over a
    /// 100k catalog must stay interactive.
    @Test("a donor-scoped pass over a 100k catalog stays inside a load-aware budget", .timeLimit(.minutes(3)))
    func donorScopedPassAt100k() {
        let model = F.model("f2-100k")
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        var donors: [VideoRecord] = []
        // 25k footage pairs (50k rows), each donor user-dated, plus 50k solos
        // (every 5th in a verified content pair, so the content bucket runs too).
        for i in 0..<25_000 {
            let (a, b) = F.pair()
            a.userDate = String(1960 + i % 60)
            records.append(a); records.append(b)
            donors.append(a)
        }
        for i in 0..<50_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/S/\(i).mov"; r.filename = "\(i).mov"; r.directory = "/Volumes/S"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            if i % 5 == 0 { r.partialMD5 = String(format: "%032x", i / 10 + 1); r.sizeBytes = 1_000 + Int64(i / 10) }
            records.append(r)
        }
        model.records = records
        let setup = model.catchUpInferredDates(trigger: "test")
        #expect(setup.footageShared == 25_000)

        // 20 donor-scoped passes, each after its donor's year changed.
        let probes = Array(donors.prefix(20))
        let clock = ContinuousClock()
        var shared = 0
        let elapsed = clock.measure {
            for donor in probes {
                donor.userDate = "2001"
                shared += model.catchUpInferredDates(scope: [donor], trigger: "test").footageShared
            }
        }
        #expect(shared == probes.count, "each scoped pass re-shares its one recipient")
        let perPass = elapsed / probes.count
        print("[date-sharing] donor-scoped pass over 100k: \(perPass) per pass (\(elapsed) for \(probes.count))")
        // Measured 2026-09-26 (Debug, M5, load avg ~10): 90 ms per pass
        // (78 ms before GH #207 added the groupmate scan). 135 ms is 1.5×,
        // load-aware; it trips on a per-scope or per-group O(records) walk.
        #expect(perPass < PerformanceLane.loadAwareDebugCeiling(.milliseconds(135)),
                "a donor-scoped pass over 100k took \(perPass)")
    }
}
