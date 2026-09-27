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
}
