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
}

private extension Float {
    /// Shares are capped like every triangulated confidence.
    var clampedToShareCap: Float { Swift.min(DateTriangulationWeights.cap, self) }
}
