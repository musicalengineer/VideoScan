import Testing
import Foundation
@testable import VideoScan

// Codex review F3 (P2): the second catch-up recomputed a shared row's claim
// WITHOUT its (now overwritten) own inference, lost "own evidence said
// 2000" from the reason, failed the equality guard and wrote again.

@MainActor
@Suite("Codex F3 — footage sharing is idempotent and keeps the recorded disagreement")
struct DateReviewF3Tests {
    typealias F = DateReviewFixtures

    @Test("pass two makes ZERO writes and the reason still says 'own evidence said 2000'")
    func secondPassWritesNothing() {
        let model = F.model("f3")
        let (a, b) = F.pair()
        a.userDate = "1992"
        b.inferredRecordDate = pfJanuaryFirst(of: 2000)
        b.inferredDateConfidence = 0.7
        b.inferredDateRange = InferredDateRange(year: 2000)
        b.inferredDateReason = "spoken now-cue 'this is… 2000'"
        b.inferredDateSource = VideoScanModel.InferredDateSource.catchUp
        model.records = [a, b]
        let first = model.catchUpInferredDates(trigger: "test")
        #expect(first.footageShared == 1)
        #expect(b.inferredDateReason?.contains("own evidence said 2000") == true, "\(b.inferredDateReason ?? "nil")")
        let snapA = F.InferredSnapshot(a), snapB = F.InferredSnapshot(b)
        let second = model.catchUpInferredDates(trigger: "test")
        #expect(second.total == 0 && second.cleared == 0 && second.footageShared == 0, "\(second)")
        #expect(F.InferredSnapshot(a) == snapA)
        #expect(F.InferredSnapshot(b) == snapB, "\(b.inferredDateReason ?? "nil")")
        #expect(b.inferredDateReason?.contains("own evidence said 2000") == true)

        // Codex re-review R2: A's confidence alone changes (estimated → known).
        // B re-shares the SAME year at the new confidence and keeps the
        // recorded disagreement; the next unchanged pass writes nothing.
        a.userDateConfidence = "known"
        model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredDateConfidence == RecordDateResolver.userKnownConfidence.clampedToShareCap)
        #expect(b.inferredDateReason?.contains("own evidence said 2000") == true, "\(b.inferredDateReason ?? "nil")")
        let snap3 = F.InferredSnapshot(b)
        let third = model.catchUpInferredDates(trigger: "test")
        #expect(third.total == 0 && third.cleared == 0 && third.footageShared == 0, "\(third)")
        #expect(F.InferredSnapshot(b) == snap3)
    }

    // MARK: - GH #207: the attack pins codex listed after the #201 merge

    /// The F3 fixture: A's estimated user year 1992 overwrites B's own 2000.
    private func sharedWithDisagreement() -> (VideoScanModel, VideoRecord, VideoRecord) {
        let model = F.model("f3-attack")
        let (a, b) = F.pair()
        a.userDate = "1992"
        b.inferredRecordDate = pfJanuaryFirst(of: 2000)
        b.inferredDateConfidence = 0.7
        b.inferredDateRange = InferredDateRange(year: 2000)
        b.inferredDateReason = "spoken now-cue 'this is… 2000'"
        b.inferredDateSource = VideoScanModel.InferredDateSource.catchUp
        model.records = [a, b]
        model.catchUpInferredDates(trigger: "test")
        return (model, a, b)
    }

    @Test("a different-year re-share never restores the old 'own evidence said' note")
    func differentYearReshareDropsTheNote() {
        let (model, a, b) = sharedWithDisagreement()
        #expect(b.inferredDateReason?.contains("own evidence said 2000") == true, "\(b.inferredDateReason ?? "nil")")
        a.userDate = "1993"
        model.catchUpInferredDates(trigger: "test")
        #expect(F.resolve(b).year == 1993)
        #expect(b.inferredDateReason?.contains("own evidence said") == false, "\(b.inferredDateReason ?? "nil")")
        // Back to the original year: the note recorded against 1992 is gone
        // for good — it is never resurrected from anywhere.
        a.userDate = "1992"
        model.catchUpInferredDates(trigger: "test")
        #expect(F.resolve(b).year == 1992)
        #expect(b.inferredDateReason?.contains("own evidence said") == false, "\(b.inferredDateReason ?? "nil")")
        let snap = F.InferredSnapshot(b)
        let again = model.catchUpInferredDates(trigger: "test")
        #expect(again.total == 0 && again.cleared == 0, "\(again)")
        #expect(F.InferredSnapshot(b) == snap)
    }

    @Test("a direct user edit of B after a restore wins and survives the next pass")
    func userEditAfterRestoreWins() {
        let (model, a, b) = sharedWithDisagreement()
        // The R2 restore: A's confidence alone changes, B re-shares 1992 and
        // the recorded disagreement is re-attached.
        a.userDateConfidence = "known"
        model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredDateReason?.contains("own evidence said 2000") == true, "\(b.inferredDateReason ?? "nil")")
        // Rick dates B himself.
        b.userDate = "1985"
        b.userDateConfidence = "known"
        for pass in 1...2 {
            model.catchUpInferredDates(trigger: "test")
            #expect(b.userDate == "1985" && b.userDateConfidence == "known", "pass \(pass)")
            #expect(F.resolve(b).year == 1985, "pass \(pass)")
            #expect(F.resolve(b).source == .userDate, "pass \(pass)")
            #expect(a.userDate == "1992" && F.resolve(a).year == 1992, "B's date never travels onto A's own user date")
        }
        let snapA = F.InferredSnapshot(a), snapB = F.InferredSnapshot(b)
        let idle = model.catchUpInferredDates(trigger: "test")
        #expect(idle.total == 0 && idle.cleared == 0, "\(idle)")
        #expect(F.InferredSnapshot(a) == snapA && F.InferredSnapshot(b) == snapB)
    }
}

private extension Float {
    /// Shares are capped like every triangulated confidence.
    var clampedToShareCap: Float { Swift.min(DateTriangulationWeights.cap, self) }
}
