import Testing
import Foundation
@testable import VideoScan

// Roll Call, 2026-10-04 (Rick): click pauses / resumes with a 4-minute
// auto-resume, every 3rd play is a shuffled mix, and a "Drifting names"
// style. The counter runs on an injected UserDefaults suite (isolation),
// the drift timing is pure, and a sensor keeps clicks pausing, not skipping.

@Suite("Roll Call — pause, mix, drift")
struct RollCallPauseMixDriftTests {

    @Test func everyThirdPlayIsAMix() throws {
        let suite = "RollCallMixTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plays = (0..<9).map { _ in RollCallMix.advance(defaults) }
        #expect(plays == [false, false, true, false, false, true, false, false, true])
    }

    @Test func aPoisonedCounterStillCountsInThrees() throws {
        let suite = "RollCallMixTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not a number", forKey: RollCallMix.storageKey)
        #expect(RollCallMix.advance(defaults) == false)   // garbage reads as 0 → play 1
        #expect(RollCallMix.advance(defaults) == false)
        #expect(RollCallMix.advance(defaults) == true)
    }

    @Test func driftFadesInAndOutAndIsInvisibleOutsideItsLife() {
        #expect(RollCallDrift.opacity(age: -1) == 0)
        #expect(RollCallDrift.opacity(age: 0) == 0)
        #expect(RollCallDrift.opacity(age: RollCallDrift.life / 2) == 1)
        #expect(RollCallDrift.opacity(age: RollCallDrift.life) == 0)
        #expect(RollCallDrift.opacity(age: 1) > 0 && RollCallDrift.opacity(age: 1) < 1)
    }

    @Test func driftRunLengthStaysReasonable() {
        #expect(RollCallDrift.duration(entries: 0) == 0)
        for n in [1, 8, 36] {
            let d = RollCallDrift.duration(entries: n)
            #expect(d >= RollCallDrift.life && d <= 100, "\(n) names → \(d) s")
        }
    }

    @Test func driftAnchorsStayOnTheCanvasAndSpreadOut() {
        let points = (0..<36).map(RollCallDrift.anchor)
        #expect(points.allSatisfy { (0.15...0.85).contains($0.x) && (0.15...0.85).contains($0.y) })
        for i in 0..<35 {
            let a = points[i], b = points[i + 1]
            #expect(hypot(a.x - b.x, a.y - b.y) > 0.15, "neighbours in time land apart (\(i))")
        }
    }

    @Test func clickPausesAndFourMinutesResumes() throws {
        #expect(RollCallOverlay.autoResumeAfter == 240)
        let source = try SourceTree.appSource(named: "FamilyTreeRollCall.swift")
        #expect(source.contains(".onTapGesture { togglePause() }"), "a click pauses, it does not skip")
        #expect(source.contains("Button(\"Skip\") { finish() }"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"), "Esc still ends it")
    }

    @Test func mixPlaysNeverTouchTheCache() throws {
        let sheet = try SourceTree.appSource(named: "FamilyTreeWalkSheet.swift")
        #expect(sheet.contains("if mixSeed == nil, let cached = rollCallCache[order]"))
        #expect(sheet.contains("if mixSeed == nil { rollCallCache[order] = playback }"))
    }
}
