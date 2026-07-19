import Testing
import Foundation
@testable import VideoScan

// MARK: - Match Confidence Floor Tests (POI cycle-03 PROMOTION to production)
//
// EvalPresenceRuleTests pins the rule itself (boundary, canonical bytes,
// CLI flags). THIS file pins the production wiring promoted 2026-07-19:
//
//   • PersonFinderModel.matchFloorDecision — the video-level decision the
//     scan pipeline, cache restore, and session rehydration all share,
//     including the short-clip any-hit safeguard the eval CLI doesn't have.
//   • PersonFinderModel.filterResults — the combined floor + min-presence
//     gate (successor of the private filterByPresence; this is the seam
//     PersonFinderPresenceArithmeticTests asked for).
//   • The honest console line + per-job provenance line formats.
//   • PersonFinderSettings.matchConfidenceFloor persistence — through an
//     INJECTED UserDefaults suite only (settings-pollution rule: tests
//     never write the real prefs plist), with a poisoned-state test.
//
// The graded operating point is floor = 7 (balanced accuracy 0.615 vs
// 0.500 legacy, zero Donna misses in both grading rounds).

// MARK: Helpers

/// Synthetic per-video result. Defaults describe a comfortably long video
/// (600 s × 30 fps ÷ step 5 = 3600 estimated sampled frames) so the
/// short-clip safeguard stays OUT of the way unless a test asks for it.
private func makeResult(
    hits: Int,
    filename: String = "clip.mov",
    duration: Double = 600,
    fps: Double = 30,
    presence: Double = 10,
    segmentCount: Int = 1
) -> pfVideoResult {
    let segs: [pfSegment] = (0..<segmentCount).map { i in
        pfSegment(
            startSecs: Double(i) * 30,
            endSecs: Double(i) * 30 + presence / Double(max(1, segmentCount)),
            bestDistance: 0.30, avgDistance: 0.35
        )
    }
    return pfVideoResult(
        filename: filename, filePath: "/tmp/\(filename)",
        durationSeconds: duration, fps: fps,
        totalHits: hits, segments: segs
    )
}

private func makeSettings(
    floor: Int, minPresence: Double = 0, frameStep: Int = 5
) -> PersonFinderSettings {
    var s = PersonFinderSettings()
    s.matchConfidenceFloor = floor
    s.minPresenceSecs = minPresence
    s.frameStep = frameStep
    return s
}

// MARK: - Shared-rule contract

@Suite("Match floor — shared EvalPresenceRule contract")
struct MatchFloorSharedRuleTests {

    @Test func productionMapsToTheGradedRuleNotACopy() {
        // The promotion REUSES the graded rule value — floor 7 is byte-for-
        // byte the configuration the external grader attributed the PASS to.
        #expect(PersonFinderModel.presenceRule(floor: 7) == EvalPresenceRule.minimumHits(floor: 7))
        #expect(PersonFinderModel.presenceRule(floor: 7).canonicalJSON()
            == #"{"minHits":7,"mode":"minimumHits"}"#)
    }

    @Test func floorOneMapsToLegacyArm() {
        #expect(PersonFinderModel.presenceRule(floor: 1) == EvalPresenceRule.legacy)
        // Defensive: nonsense floors also collapse to legacy, never crash.
        #expect(PersonFinderModel.presenceRule(floor: 0) == EvalPresenceRule.legacy)
        #expect(PersonFinderModel.presenceRule(floor: -5) == EvalPresenceRule.legacy)
    }
}

// MARK: - Video-level decision

@Suite("Match floor — video-level decision")
struct MatchFloorDecisionTests {

    /// Decision for a long video (safeguard inert).
    private func decide(hits: Int, floor: Int) -> (confirmed: Bool, usedShortClipFallback: Bool) {
        PersonFinderModel.matchFloorDecision(
            totalHits: hits, durationSeconds: 600, fps: 30, floor: floor, frameStep: 5
        )
    }

    @Test func boundaryAtSeven() {
        #expect(!decide(hits: 6, floor: 7).confirmed)
        #expect(decide(hits: 7, floor: 7).confirmed)
        #expect(decide(hits: 8, floor: 7).confirmed)
        #expect(!decide(hits: 0, floor: 7).confirmed)
        // The boundary cases never report a fallback on a long video.
        #expect(!decide(hits: 6, floor: 7).usedShortClipFallback)
        #expect(!decide(hits: 7, floor: 7).usedShortClipFallback)
    }

    @Test func legacyParityAtFloorOne() {
        for hits in 0...10 {
            let d = decide(hits: hits, floor: 1)
            #expect(d.confirmed == (hits > 0))
            #expect(!d.usedShortClipFallback)
        }
    }

    @Test func poisonedFloorClampsToAnyHit() {
        // A floor of 0 / negative (poisoned prefs reached the pipeline
        // anyway) behaves as any-hit — matching never silently disables.
        #expect(decide(hits: 1, floor: 0).confirmed)
        #expect(decide(hits: 1, floor: -3).confirmed)
        #expect(!decide(hits: 0, floor: 0).confirmed)
    }

    // MARK: Short-clip safeguard (the FN guard the grade disclosed)

    @Test func shortClipFallsBackToAnyHit() {
        // 1 s × 10 fps ÷ step 5 = 2 estimated sampled frames < floor 7:
        // a single real match must still count.
        let d = PersonFinderModel.matchFloorDecision(
            totalHits: 1, durationSeconds: 1.0, fps: 10, floor: 7, frameStep: 5
        )
        #expect(d.confirmed)
        #expect(d.usedShortClipFallback)
    }

    @Test func shortClipWithZeroHitsStaysNone() {
        // The safeguard rescues real matches only — it never invents one.
        let d = PersonFinderModel.matchFloorDecision(
            totalHits: 0, durationSeconds: 1.0, fps: 10, floor: 7, frameStep: 5
        )
        #expect(!d.confirmed)
        #expect(!d.usedShortClipFallback)
    }

    @Test func estimateExactlyAtFloorGetsNoFallback() {
        // 3.5 s × 10 fps ÷ step 5 = 7 sampled = floor: the floor is
        // reachable, so it applies (6 hits refused, 7 confirmed).
        let refused = PersonFinderModel.matchFloorDecision(
            totalHits: 6, durationSeconds: 3.5, fps: 10, floor: 7, frameStep: 5
        )
        #expect(!refused.confirmed)
        #expect(!refused.usedShortClipFallback)
        let confirmed = PersonFinderModel.matchFloorDecision(
            totalHits: 7, durationSeconds: 3.5, fps: 10, floor: 7, frameStep: 5
        )
        #expect(confirmed.confirmed)
    }

    @Test func unknownDurationOrFPSFailsOpenTowardLegacy() {
        // fps 0 / duration 0 (dlib error rows, odd containers) → estimate
        // unknown → any-hit. Fails OPEN: never a new silent miss.
        let d1 = PersonFinderModel.matchFloorDecision(
            totalHits: 2, durationSeconds: 0, fps: 0, floor: 7, frameStep: 5
        )
        #expect(d1.confirmed)
        #expect(d1.usedShortClipFallback)
        let d2 = PersonFinderModel.matchFloorDecision(
            totalHits: 2, durationSeconds: 600, fps: 0, floor: 7, frameStep: 5
        )
        #expect(d2.confirmed)
    }

    @Test func fallbackReportedOnlyWhenItChangedTheOutcome() {
        // Short clip whose hits ALSO clear the floor: confirmed by the
        // floor itself, so no fallback is reported.
        let d = PersonFinderModel.matchFloorDecision(
            totalHits: 9, durationSeconds: 1.0, fps: 10, floor: 7, frameStep: 5
        )
        #expect(d.confirmed)
        #expect(!d.usedShortClipFallback)
    }
}

// MARK: - Combined filter gate

@Suite("Match floor — filterResults gate")
struct MatchFloorFilterResultsTests {

    @Test func boundarySixVsSevenAtTheVideoLevel() {
        let outcome = PersonFinderModel.filterResults(
            [makeResult(hits: 6, filename: "six.mov"),
             makeResult(hits: 7, filename: "seven.mov"),
             nil],
            settings: makeSettings(floor: 7)
        )
        #expect(outcome.valid.map(\.filename) == ["seven.mov"])
        #expect(outcome.belowFloorCount == 1)
        #expect(outcome.shortClipFallbackCount == 0)
        #expect(outcome.belowPresenceCount == 0)
    }

    @Test func legacyParityAtFloorOne() {
        // Floor 1 must reproduce the old filterByPresence results exactly:
        // any video with segments is kept (minPresence 0 here).
        let outcome = PersonFinderModel.filterResults(
            [makeResult(hits: 1, filename: "one.mov"),
             makeResult(hits: 12, filename: "many.mov")],
            settings: makeSettings(floor: 1)
        )
        #expect(outcome.valid.map(\.filename) == ["one.mov", "many.mov"])
        #expect(outcome.belowFloorCount == 0)
        #expect(outcome.shortClipFallbackCount == 0)
    }

    @Test func shortClipFallbackIsCountedAndKept() {
        let short = makeResult(hits: 2, filename: "short.mov",
                               duration: 1.0, fps: 10, presence: 0.5)
        let outcome = PersonFinderModel.filterResults(
            [short], settings: makeSettings(floor: 7)
        )
        #expect(outcome.valid.map(\.filename) == ["short.mov"])
        #expect(outcome.shortClipFallbackCount == 1)
        #expect(outcome.belowFloorCount == 0)
    }

    @Test func presenceGateSemanticsUnchanged() {
        // The pre-existing min-presence filter still applies after the
        // floor: presence 3 s < 5 s is refused and counted separately.
        let outcome = PersonFinderModel.filterResults(
            [makeResult(hits: 9, filename: "brief.mov", presence: 3),
             makeResult(hits: 9, filename: "long.mov", presence: 6)],
            settings: makeSettings(floor: 7, minPresence: 5)
        )
        #expect(outcome.valid.map(\.filename) == ["long.mov"])
        #expect(outcome.belowPresenceCount == 1)
        #expect(outcome.belowFloorCount == 0)
    }

    @Test func belowFloorIsCountedBeforePresence() {
        // A video failing BOTH gates is attributed to the floor (the gate
        // that runs first), not double-counted.
        let outcome = PersonFinderModel.filterResults(
            [makeResult(hits: 2, filename: "both.mov", presence: 1)],
            settings: makeSettings(floor: 7, minPresence: 5)
        )
        #expect(outcome.valid.isEmpty)
        #expect(outcome.belowFloorCount == 1)
        #expect(outcome.belowPresenceCount == 0)
    }

    @Test func emptySegmentQuirkPreserved() {
        // Characterization of the old filterByPresence behavior, preserved
        // byte-for-byte: empty-segment results (cache "unreadable" skips)
        // pass through when minPresence ≤ 0 (downstream ClipResult builders
        // still exclude them) and are silently dropped when minPresence > 0
        // — in neither case do they hit the floor counters.
        let empty = makeResult(hits: 0, filename: "empty.mov",
                               presence: 0, segmentCount: 0)
        let kept = PersonFinderModel.filterResults(
            [empty], settings: makeSettings(floor: 7, minPresence: 0)
        )
        #expect(kept.valid.map(\.filename) == ["empty.mov"])
        #expect(kept.belowFloorCount == 0)
        let dropped = PersonFinderModel.filterResults(
            [empty], settings: makeSettings(floor: 7, minPresence: 5)
        )
        #expect(dropped.valid.isEmpty)
        #expect(dropped.belowFloorCount == 0)
        #expect(dropped.belowPresenceCount == 0)
    }

    @Test func orderIsPreserved() {
        let outcome = PersonFinderModel.filterResults(
            [makeResult(hits: 8, filename: "a.mov"),
             makeResult(hits: 2, filename: "refused.mov"),
             makeResult(hits: 9, filename: "b.mov"),
             makeResult(hits: 10, filename: "c.mov")],
            settings: makeSettings(floor: 7)
        )
        #expect(outcome.valid.map(\.filename) == ["a.mov", "b.mov", "c.mov"])
        #expect(outcome.belowFloorCount == 1)
    }
}

// MARK: - Honest console + provenance lines

@Suite("Match floor — console and provenance line formats")
struct MatchFloorLineFormatTests {

    @Test func belowFloorSummaryLinePlural() {
        #expect(PersonFinderModel.belowFloorSummaryLine(count: 3, floor: 7)
            == "3 videos had brief possible matches below the confidence floor (7) — not counted as found. Set the floor to 1 in search settings to count any single match.")
    }

    @Test func belowFloorSummaryLineSingular() {
        #expect(PersonFinderModel.belowFloorSummaryLine(count: 1, floor: 7)
            == "1 video had brief possible matches below the confidence floor (7) — not counted as found. Set the floor to 1 in search settings to count any single match.")
    }

    @Test func provenanceLineForGradedFloor() {
        #expect(PersonFinderModel.floorProvenanceLine(personName: "Donna", floor: 7)
            == "Match confidence floor for Donna: 7 (rule=minimumHits, short clips fall back to any match)")
    }

    @Test func provenanceLineForLegacyOptOut() {
        #expect(PersonFinderModel.floorProvenanceLine(personName: "Donna", floor: 1)
            == "Match confidence floor for Donna: 1 (rule=legacyAnyHit, any single match counts)")
        // Poisoned floors report the clamped value, not the poison.
        #expect(PersonFinderModel.floorProvenanceLine(personName: "Donna", floor: -4)
            == "Match confidence floor for Donna: 1 (rule=legacyAnyHit, any single match counts)")
    }
}

// MARK: - Settings persistence + isolation

@Suite("Match floor — settings persistence (injected suite only)")
struct MatchFloorSettingsPersistenceTests {

    /// Fresh throwaway suite per test; removed on exit. Tests NEVER touch
    /// UserDefaults.standard (settings-pollution rule).
    private func withSuite<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suiteName = "vs-test-matchfloor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try body(defaults)
    }

    @Test func defaultIsTheGradedSeven() throws {
        #expect(PersonFinderSettings().matchConfidenceFloor == 7)
        // Missing key on restore → struct default 7 (existing users get the
        // graded config on upgrade, per Rick's approval).
        try withSuite { defaults in
            #expect(PersonFinderSettings.restored(from: defaults).matchConfidenceFloor == 7)
        }
    }

    @Test func roundTripsThroughInjectedSuite() throws {
        try withSuite { defaults in
            var s = PersonFinderSettings()
            s.matchConfidenceFloor = 12
            s.save(to: defaults)
            #expect(PersonFinderSettings.restored(from: defaults).matchConfidenceFloor == 12)
            s.matchConfidenceFloor = 1   // legacy opt-out persists too
            s.save(to: defaults)
            #expect(PersonFinderSettings.restored(from: defaults).matchConfidenceFloor == 1)
        }
    }

    @Test(arguments: [0, -1, -99])
    func poisonedIntegerClampsToAnyHit(poison: Int) throws {
        try withSuite { defaults in
            defaults.set(poison, forKey: "pf_matchConfidenceFloor")
            #expect(PersonFinderSettings.restored(from: defaults).matchConfidenceFloor == 1)
        }
    }

    @Test func poisonedNonNumericClampsToAnyHit() throws {
        // A corrupted plist value ("seven") reads back as integer 0 via
        // UserDefaults; the clamp must turn that into 1, never 0.
        try withSuite { defaults in
            defaults.set("seven", forKey: "pf_matchConfidenceFloor")
            #expect(PersonFinderSettings.restored(from: defaults).matchConfidenceFloor == 1)
        }
    }

    @Test func saveToInjectedSuiteNeverTouchesStandardPrefs() throws {
        // Isolation sensor for the whole suite: writing through the
        // injected suite must leave the real prefs key untouched.
        let before = UserDefaults.standard.object(forKey: "pf_matchConfidenceFloor")
        try withSuite { defaults in
            var s = PersonFinderSettings()
            s.matchConfidenceFloor = 42
            s.save(to: defaults)
        }
        let after = UserDefaults.standard.object(forKey: "pf_matchConfidenceFloor")
        #expect((before as? Int) == (after as? Int))
        #expect((after as? Int) != 42 || (before as? Int) == 42)
    }
}
