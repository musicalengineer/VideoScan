import Testing
import Foundation
import CryptoKit
@testable import VideoScan

// MARK: - Eval Presence Rule Tests (POI improvement cycle 3)
//
// Pins the minimum-hit confirmation floor — the ONE cycle-03 change:
//
//     legacyAnyHit (default): presence = "confirmed" ⇔ hits > 0
//     minimumHits(N):         presence = "confirmed" ⇔ hits ≥ N
//     otherwise:              presence = "none"
//
// The candidate operating point is N = 7 (see
// docs/poi-cycles/cycle-03-minimum-hits.md). These tests pin the exact
// decision boundary, the canonical config bytes + hash the external grader
// attributes runs to, legacy-arm parity, and the CLI flag truth table.
// They do NOT touch the benchmark corpus (graded externally).

struct EvalPresenceRuleTests {

    private let floor7 = EvalPresenceRule.minimumHits(floor: 7)
    private let legacy = EvalPresenceRule.legacy

    // MARK: Decision boundary — exact, positive AND negative

    @Test func minimumHitsBoundaryAtSeven() {
        #expect(floor7.presence(hits: 0) == "none")
        #expect(floor7.presence(hits: 6) == "none")
        #expect(floor7.presence(hits: 7) == "confirmed")
        #expect(floor7.presence(hits: 8) == "confirmed")
    }

    @Test func minimumHitsFullNeighborhood() {
        // Every count below the floor is none; at/above is confirmed.
        for hits in 0..<7 { #expect(floor7.presence(hits: hits) == "none") }
        for hits in 7...20 { #expect(floor7.presence(hits: hits) == "confirmed") }
    }

    @Test func floorOfOneEqualsAnyHit() {
        let floor1 = EvalPresenceRule.minimumHits(floor: 1)
        for hits in 0...10 {
            #expect(floor1.presence(hits: hits) == legacy.presence(hits: hits))
        }
    }

    @Test func zeroFacesZeroHitsIsNoneInBothModes() {
        // A video with no detected faces reaches the rule as hits == 0.
        #expect(legacy.presence(hits: 0) == "none")
        #expect(floor7.presence(hits: 0) == "none")
    }

    @Test func largeHitCounts() {
        #expect(floor7.presence(hits: 1_000_000) == "confirmed")
        #expect(floor7.presence(hits: Int.max) == "confirmed")
        #expect(legacy.presence(hits: Int.max) == "confirmed")
        #expect(EvalPresenceRule.minimumHits(floor: Int.max).presence(hits: Int.max) == "confirmed")
        #expect(EvalPresenceRule.minimumHits(floor: Int.max).presence(hits: Int.max - 1) == "none")
    }

    @Test func halfSpecifiedRuleFailsClosed() {
        // Unreachable via the CLI (parse rejects the combination), but the
        // type itself must never silently confirm without a floor.
        let broken = EvalPresenceRule(mode: .minimumHits, minHits: nil)
        #expect(broken.presence(hits: 100) == "none")
    }

    // MARK: Legacy parity sensor — the A/B control arm is untouched any-hit

    @Test func legacyParityMatchesAnyHitExactly() {
        for hits in 0...50 {
            let expected = hits > 0 ? "confirmed" : "none"
            #expect(legacy.presence(hits: hits) == expected)
        }
    }

    // MARK: Canonical config bytes + hash (the grader's attribution surface)

    @Test func canonicalBytesMinimumHits7() {
        #expect(floor7.canonicalJSON() == #"{"minHits":7,"mode":"minimumHits"}"#)
    }

    @Test func canonicalBytesLegacyOmitsInertFields() {
        // Exactly the meaningful fields: legacy has no floor to report.
        #expect(legacy.canonicalJSON() == #"{"mode":"legacyAnyHit"}"#)
    }

    @Test func canonicalHashStability() {
        // Pinned sha256 constants — if these move, the grader's config
        // attribution breaks and the cycle doc must be re-issued.
        #expect(sha256Hex(floor7.canonicalJSON())
            == "e981faa37be39891b21a1f650858e24cfef989e2816bf71fe043c2cd15dbe7ea")
        #expect(sha256Hex(legacy.canonicalJSON())
            == "4f475fab1db48dba996da6415cdac83c9fd38837c0a036704c395e7ff953af16")
    }

    @Test func canonicalBytesAreByteStableAcrossRepeatedEncodes() {
        let reference = floor7.canonicalJSON()
        for _ in 0..<100 { #expect(floor7.canonicalJSON() == reference) }
    }

    @Test func configRoundTripsThroughCodable() throws {
        let decoder = JSONDecoder()
        let decoded7 = try decoder.decode(
            EvalPresenceRule.self, from: Data(floor7.canonicalJSON().utf8))
        #expect(decoded7 == floor7)
        let decodedLegacy = try decoder.decode(
            EvalPresenceRule.self, from: Data(legacy.canonicalJSON().utf8))
        #expect(decodedLegacy == legacy)
    }

    // MARK: Output schema — the emitted object embeds the effective config

    @Test func outputEmbedsEffectiveConfigAndPresence() throws {
        let json = try encodeOutput(rule: floor7, hits: 9)
        #expect(json.contains(#""aggregation":{"minHits":7,"mode":"minimumHits"}"#))
        #expect(json.contains(#""presence":"confirmed""#))
        #expect(json.contains(#""schemaVersion":2"#))
        #expect(json.contains(#""hits":9"#))  // raw hits unchanged
    }

    @Test func outputLegacyArmKeepsAnyHitPresence() throws {
        // One hit: legacy confirms (unchanged pre-cycle behavior)…
        let legacyJSON = try encodeOutput(rule: legacy, hits: 1)
        #expect(legacyJSON.contains(#""aggregation":{"mode":"legacyAnyHit"}"#))
        #expect(legacyJSON.contains(#""presence":"confirmed""#))
        // …while the cycle-03 arm classifies the same raw count as none.
        let floorJSON = try encodeOutput(rule: floor7, hits: 1)
        #expect(floorJSON.contains(#""presence":"none""#))
        #expect(floorJSON.contains(#""hits":1"#))  // raw hits identical
    }

    // MARK: CLI flag truth table

    private let requiredArgs = ["--person", "Donna", "--references", "/tmp/refs", "--video", "/tmp/v.mov"]

    private func parse(_ extra: [String]) throws -> PersonEvaluationCLI.Options {
        try PersonEvaluationCLI.parse(requiredArgs + extra)
    }

    @Test func defaultRunIsLegacy() throws {
        let options = try parse([])
        #expect(options.presenceRule == .legacy)
        #expect(options.presenceRule.canonicalJSON() == #"{"mode":"legacyAnyHit"}"#)
    }

    @Test func explicitLegacyFlagIsAccepted() throws {
        let options = try parse(["--aggregation", "legacy"])
        #expect(options.presenceRule == .legacy)
    }

    @Test func minimumHitsFlagChangesModeAndPresence() throws {
        let options = try parse(["--aggregation", "minimum-hits", "--min-hits", "7"])
        #expect(options.presenceRule == .minimumHits(floor: 7))
        // The flag demonstrably changes the presence decision for the same
        // raw observation:
        let defaults = try parse([])
        #expect(defaults.presenceRule.presence(hits: 1) == "confirmed")
        #expect(options.presenceRule.presence(hits: 1) == "none")
        #expect(options.presenceRule.presence(hits: 7) == "confirmed")
    }

    @Test func flagOrderIsIrrelevant() throws {
        let options = try parse(["--min-hits", "7", "--aggregation", "minimum-hits"])
        #expect(options.presenceRule == .minimumHits(floor: 7))
    }

    @Test func minHitsWithoutModeIsRejected() {
        // Inert flag — would not influence the run, so it must be an error.
        #expect(throws: (any Error).self) { try self.parse(["--min-hits", "7"]) }
    }

    @Test func minHitsWithLegacyModeIsRejected() {
        #expect(throws: (any Error).self) {
            try self.parse(["--aggregation", "legacy", "--min-hits", "7"])
        }
    }

    @Test func minimumHitsModeWithoutFloorIsRejected() {
        // No silent default: the floor must be explicit.
        #expect(throws: (any Error).self) { try self.parse(["--aggregation", "minimum-hits"]) }
    }

    @Test func minimumHitsConflictsWithFacePresenceOnly() {
        #expect(throws: (any Error).self) {
            try PersonEvaluationCLI.parse(
                ["--face-presence-only", "--video", "/tmp/v.mov",
                 "--aggregation", "minimum-hits", "--min-hits", "7"])
        }
    }

    @Test(arguments: ["0", "-3", "7.5", "nan", "NaN", "", "seven", "0x7",
                      "99999999999999999999999", "+", "7,0", " 7"])
    func malformedMinHitsIsRejected(raw: String) {
        #expect(throws: (any Error).self) {
            try self.parse(["--aggregation", "minimum-hits", "--min-hits", raw])
        }
    }

    @Test func unknownAggregationModeIsRejected() {
        #expect(throws: (any Error).self) { try self.parse(["--aggregation", "score"]) }
        #expect(throws: (any Error).self) { try self.parse(["--aggregation", ""]) }
    }

    @Test func duplicateFlagsAreRejected() {
        #expect(throws: (any Error).self) {
            try self.parse(["--aggregation", "minimum-hits", "--aggregation", "minimum-hits",
                            "--min-hits", "7"])
        }
        #expect(throws: (any Error).self) {
            try self.parse(["--aggregation", "minimum-hits", "--min-hits", "7", "--min-hits", "7"])
        }
    }

    @Test func missingValueAfterFlagIsRejected() {
        #expect(throws: (any Error).self) {
            try PersonEvaluationCLI.parse(self.requiredArgs + ["--min-hits"])
        }
        #expect(throws: (any Error).self) {
            try PersonEvaluationCLI.parse(self.requiredArgs + ["--aggregation"])
        }
    }

    @Test func preexistingFlagsStillParse() throws {
        // Regression guard: the cycle-03 additions must not disturb the
        // established surface.
        let options = try parse(["--engine", "arcface", "--frame-step", "10",
                                 "--largest-face-only"])
        #expect(options.engine == .arcface)
        #expect(options.frameStep == 10)
        #expect(options.largestFaceOnly)
        #expect(options.presenceRule == .legacy)
    }

    // MARK: Helpers

    /// Encode an Output exactly the way the CLI does (sortedKeys), with the
    /// presence computed through the same single rule value that is emitted —
    /// the provenance invariant under test.
    private func encodeOutput(rule: EvalPresenceRule, hits: Int) throws -> String {
        let output = PersonEvaluationCLI.Output(
            schemaVersion: 2, person: "Donna", engine: "ArcFace", video: "/tmp/v.mov",
            facesDetected: max(hits, 10), hits: hits, bestDistance: 0.31,
            segments: [], elapsedSeconds: 1.0, peakRSSMB: 100, error: nil,
            aggregation: rule, presence: rule.presence(hits: hits)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    private func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
