// ArchiveAngelExtraCopyGuardTests.swift
// Today's fact, made a rule (Rick's ruling on GH #258, 2026-10-03): the
// Archive Angel never recommends a record marked "Extra copy" — it defers to
// the duplicate check's keeper. Delete Duplicates relies on that: it no
// longer holds a copy the Angel merely lists, because the Angel does not
// list extra copies.
//
// Where the exclusion lives: the `extraCopy` rule in the recommendation
// policy's floors (AngelPolicyDefaults.swift, and the bundled
// ArchiveAngelPolicy.default.json). It is EXPLICIT, but it is a policy rule
// — "a default (switchable), not a safety floor": a policy.json override
// could drop it. These tests pin the built-in rules and the bundled file.
//
// Suite: ArchiveAngelExtraCopyGuardTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Archive Angel — an Extra copy is never recommended (the keeper is)")
struct ArchiveAngelExtraCopyGuardTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let dated = Date(timeIntervalSince1970: 775_000_000)   // 1994

    /// keeper + two extras in one group, and an ungrouped file — each one
    /// starred and dated, so nothing else would hold an extra back.
    private func fixture() -> (keeper: ArchiveAngelCandidate, extras: [ArchiveAngelCandidate], lone: ArchiveAngelCandidate) {
        let group = UUID()
        func candidate(_ name: String, _ disposition: DuplicateDisposition, grouped: Bool = true) -> ArchiveAngelCandidate {
            var c = ArchiveAngelCandidate(filename: name, starRating: 3, captureDate: dated, duplicateDisposition: disposition)
            c.duplicateGroupID = grouped ? group : nil
            c.duplicateGroupCount = grouped ? 3 : 0
            return c
        }
        return (candidate("keeper.mov", .keep), [candidate("copy 1.mov", .extraCopy), candidate("copy 2.mov", .extraCopy)],
                candidate("lone.mov", .none, grouped: false))
    }

    @Test func theScorerRejectsEveryExtraCopyAndNeverTheKeeperForThatReason() {
        let f = fixture()
        for extra in f.extras {
            #expect(ArchiveAngelScorer.hardFloor(extra, policy: .builtIn, now: now) == .extraCopy, "\(extra.filename)")
            if case .rejected(let why) = ArchiveAngelScorer.verdict(extra, policy: .builtIn, now: now) {
                #expect(why == .extraCopy)
            } else {
                Issue.record("\(extra.filename): an Extra copy was eligible")
            }
        }
        for other in [f.keeper, f.lone] {
            #expect(ArchiveAngelScorer.hardFloor(other, policy: .builtIn, now: now) != .extraCopy, "\(other.filename)")
        }
    }

    @Test func theRecommendationSetNeverContainsAnExtraCopy() {
        let f = fixture()
        let all = [f.keeper] + f.extras + [f.lone]
        let extraIDs = Set(f.extras.map(\.id))
        // Prepare's pick…
        for byClass in [false, true] {
            let selection = ArchiveAngelScorer.select(all, count: 10, policy: .builtIn, now: now, byClass: byClass)
            #expect(extraIDs.isDisjoint(with: selection.picks.map(\.candidate.id)), "byClass \(byClass): an Extra copy was picked")
            #expect(selection.rejected[.extraCopy] == 2)
        }
        // …and the classes every surface counts (ready / needs a date /
        // worth a look), under the standard rules with the scorer's floor
        // as each record's evidence.
        var evidence: [UUID: ArchiveAngelEvidenceRecord] = [:]
        for c in all {
            // What the sweep stores: the scorer's own verdict (an eligible
            // record is given a grade-A score so nothing else holds it back).
            switch ArchiveAngelScorer.verdict(c, policy: .builtIn, now: now) {
            case .eligible:
                evidence[c.id] = .init(score: 120, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)
            case .rejected(let why):
                evidence[c.id] = .init(score: 0, lines: [], rejection: why, useCount: 0, lastUsed: nil, computedAt: now)
            }
        }
        let result = ArchiveAngelRecommendations.classify(all, evidence: evidence, rules: .standard, now: now)
        let recommended = Set((result.ready + result.needsDate + result.worthALook).map(\.id))
        #expect(!recommended.isEmpty, "fixture: the keeper or the lone file is recommended")
        #expect(extraIDs.isDisjoint(with: recommended), "an Extra copy is in the recommendation set")
        for (c, v) in zip(all, result.verdicts) where extraIDs.contains(c.id) {
            #expect(!v.kind.isRecommended, "\(c.filename): \(v.kind)")
        }
    }

    /// Source sensor: the rule is in the built-in policy AND in the bundled
    /// default file, spelled as the scorer reads it.
    @Test func theExtraCopyRuleIsInTheBuiltInPolicyAndTheBundledFile() throws {
        let defaults = try SourceTree.appSource(named: "AngelPolicyDefaults.swift")
        #expect(defaults.contains("AngelRule(id: \"extraCopy\", kind: .match,"))
        #expect(defaults.contains("when: [.init(field: .duplicateDisposition, op: .eq, value: .string(\"extraCopy\"))],"))
        #expect(defaults.contains("rejection: \"extraCopy\"),"))
        #expect(AngelRecommendationPolicy.builtIn.floors.contains { $0.id == "extraCopy" && $0.rejection == "extraCopy" },
                "the built-in rules no longer carry the Extra-copy floor")
        let folder = try #require(SourceTree.appSourceURL(named: "AngelPolicyDefaults.swift")).deletingLastPathComponent()
        let json = try String(contentsOf: folder.appendingPathComponent("ArchiveAngelPolicy.default.json"), encoding: .utf8)
        #expect(json.contains("\"id\" : \"extraCopy\"") && json.contains("\"rejection\" : \"extraCopy\""))
    }
}
