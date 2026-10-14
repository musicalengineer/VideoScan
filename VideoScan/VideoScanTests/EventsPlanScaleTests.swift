// EventsPlanScaleTests.swift
// Events v1 — SCALE (feature-test checklist item 2; plan §4, §7): the
// planner over 100k synthetic rows within budget (the plan pins ≤ 10 s
// Release; Debug runs through PerformanceLane.debugCeiling, widened on a
// hosted runner or under a sanitizer); the model's projection is ONE
// main-actor pass; reapplying decisions is not a rebuild. Budgets are
// sensors for a complexity-class regression (O(n) → O(n²)), not
// micro-benchmarks. Media matrix: not applicable — no media opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Events — scale", .serialized)
struct EventsPlanScaleTests {

    private typealias F = EventsFixture

    /// `n` rows shaped like a real catalog: 10% captioned, 5% transcribed,
    /// 20% copies (pairs sharing a digest), dates on 60% (user / camera /
    /// inferred), 25 folders per drive, 8 drives, a few footage groups.
    static func syntheticRows(_ n: Int) -> [EventsRow] {
        let captions = ["A birthday cake with lit candles on the table.", "A decorated Christmas tree with wrapped presents.",
                        "Children run across a lawn.", "A roast turkey on the table.", "A woman playing the piano on stage.",
                        "People sit on a beach under an umbrella.", "A man talks to the camera in a kitchen."]
        let speech = ["happy birthday dear Timmy happy birthday to you", "we'll see you at christmas then",
                      "merry christmas everyone open your presents", "what are you thankful for this year", "take it from the top"]
        var rows: [EventsRow] = []
        rows.reserveCapacity(n)
        for i in 0..<n {
            let drive = i % 8
            let folder = (i / 40) % 25
            let year = 1985 + (i / 400) % 30
            let path = "/Volumes/Drive\(drive)/\(year)/folder\(folder)/clip\(i).mov"
            let key = i % 5 == 0 ? "sha-\(i / 2)" : nil
            let caption = i % 10 == 0 ? captions[i % captions.count] : nil
            let transcript = i % 20 == 0 ? speech[i % speech.count] : nil
            var user: String?
            var camera: Date?
            var inferred: Date?
            switch i % 10 {
            case 0...2: user = F.iso(year, 1 + i % 12, 1 + i % 28)
            case 3...4: camera = F.day(year, 1 + i % 12, 1 + i % 28)
            case 5: inferred = F.day(year, 7, 1)
            default: break
            }
            rows.append(F.row(path, key: key, caption: caption, transcript: transcript, userDate: user, camera: camera,
                              inferred: inferred, inferredSource: inferred == nil ? nil : VideoScanModel.InferredDateSource.folderYear,
                              footage: i % 97 == 0 ? UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", i / 97))") : nil))
        }
        return rows
    }

    @Test("SCALE: 100k rows plan within budget (10 s Release, through the Debug/sanitizer ceiling); 10k is timed and printed",
          .timeLimit(.minutes(3)))
    func plansOneHundredThousandRowsWithinBudget() {
        let clock = ContinuousClock()
        let small = Self.syntheticRows(10_000)
        var smallPlan = EventsPlan.empty
        let smallElapsed = clock.measure { smallPlan = F.plan(small, birthdays: F.birthdays) }
        print("EVENTS_PLAN_10K_MS=\(smallElapsed.components.seconds * 1000 + smallElapsed.components.attoseconds / 1_000_000_000_000_000) "
              + "suggestions=\(smallPlan.suggestions.count) witnesses=\(smallPlan.witnessesWithEvidence) \(PerformanceLane.configurationName)")
        #expect(smallPlan.rowCount == 10_000 && smallPlan.suggestions.count > 0)

        let rows = Self.syntheticRows(100_000)
        var plan = EventsPlan.empty
        let elapsed = clock.measure { plan = F.plan(rows, birthdays: F.birthdays) }
        print("EVENTS_PLAN_100K_MS=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) "
              + "suggestions=\(plan.suggestions.count) \(PerformanceLane.configurationName) \(PerformanceLane.loadDescription())")
        #expect(plan.rowCount == 100_000)
        #expect(plan.withCaptions == 10_000 && plan.withTranscripts == 5_000)
        #expect(plan.witnessesWithEvidence > 5_000, "captions, speech and names found \(plan.witnessesWithEvidence)")
        #expect(plan.suggestions.count > 1_000 && plan.suggestions.count < plan.witnessesWithEvidence, "runs group, conservatively")
        #expect(plan.byCategory.count == 9)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(10)), "100k plan took \(elapsed)")
    }

    @Test("the model's projection is ONE main-actor pass over 100k records, within budget, and the build hands it off", .timeLimit(.minutes(2)))
    @MainActor
    func eventsInputsIsOneMainActorPass() async throws {
        let model = VideoScanModel()
        model.records = (0..<100_000).map { i in
            F.record("/Volumes/Scale\(i % 8)/dir\(i % 41)/clip\(i).mov", caption: i % 10 == 0 ? "A birthday cake with candles." : nil,
                     userDate: i % 3 == 0 ? F.iso(1990 + i % 30, 1 + i % 12, 1 + i % 28) : nil)
        }
        let clock = ContinuousClock()
        var inputs: EventsInputs?
        let elapsed = clock.measure { inputs = model.eventsInputs() }
        let rows = try #require(inputs?.rows)
        #expect(rows.count == 100_000)
        #expect(rows.filter { !$0.captions.isEmpty }.count == 10_000)
        #expect(rows.allSatisfy { $0.contentKey.hasPrefix("id:") }, "no hash, no pair: the record is its own content")
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "projection took \(elapsed)")
        // The build: the projection once, then a detached task (source sensor).
        let code = try SourceTree.appCode(named: "VideoScanModel+Events.swift")
        let build = try #require(code.range(of: "func buildEventsPlan("))
        let body = String(code[build.lowerBound...].prefix(1_200))
        #expect(body.components(separatedBy: "eventsInputs()").count - 1 == 1, "exactly one projection per build")
        #expect(body.contains("Task.detached(priority: .userInitiated)"), "the planner runs off the main actor")
        // And it really builds, with birthdays injected (no People tab read).
        let plan = await model.buildEventsPlan(decisions: .empty, birthdays: { F.birthdays })
        #expect(plan.rowCount == 100_000 && plan.suggestions.count > 0)
    }

    @Test("reapplying decisions to a 100k plan is a fraction of the build, never a rebuild", .timeLimit(.minutes(3)))
    func reapplyDecisionsIsNotAFullRebuild() {
        let rows = Self.syntheticRows(100_000)
        let clock = ContinuousClock()
        var plan = EventsPlan.empty
        let build = clock.measure { plan = F.plan(rows) }
        // Confirm the first 200 suggestions, dismiss the next 200, reject
        // one category on 200 members, mark 100 pairs different.
        var events: [EventRecord] = []
        var decisions: [EventDecision] = []
        for s in plan.suggestions.prefix(200) {
            let e = EventRecord(name: s.name, categories: s.categories)
            events.append(e)
            decisions += s.members.map { .member(eventID: e.id, range: $0.range, verdict: .accepted) }
        }
        for s in plan.suggestions.dropFirst(200).prefix(200) { decisions.append(.suggestionDismissed(key: s.key, facts: s.facts)) }
        for s in plan.suggestions.dropFirst(400).prefix(200) {
            decisions.append(.categoryRejected(range: s.members[0].range, category: s.primaryCategory))
        }
        for pair in zip(plan.suggestions.dropFirst(600).prefix(100), plan.suggestions.dropFirst(700).prefix(100)) {
            decisions.append(.differentOccasions(a: pair.0.members[0].range, b: pair.1.members[0].range))
        }
        let snapshot = EventsDecisionSnapshot(events: events, decisions: decisions)
        var after = EventsPlan.empty
        let reapply = clock.measure { after = plan.reapplying(snapshot) }
        #expect(after.confirmed.count == 200)
        #expect(after.suggestions.count <= plan.suggestions.count - 400, "settled and dismissed left the queue")
        #expect((after.leftOut[.settled] ?? 0) > 0 && (after.leftOut[.dismissed] ?? 0) > 0 && (after.leftOut[.categoryRejected] ?? 0) > 0)
        #expect(after.candidateCount == plan.candidateCount, "the metrics count every candidate, decided or not")
        #expect(reapply < build / 4, "reapply \(reapply) vs build \(build)")
        #expect(reapply < PerformanceLane.debugCeiling(.seconds(1)), "reapply took \(reapply)")
    }
}
