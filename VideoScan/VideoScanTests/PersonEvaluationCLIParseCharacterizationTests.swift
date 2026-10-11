// PersonEvaluationCLIParseCharacterizationTests.swift
// Pins for PersonEvaluationCLI.parse written BEFORE the 2026-10-10 refactor
// (CCN 37 → a Flag vocabulary + per-flag assignment + separate validation).
// EvalPresenceRuleTests and AdaFaceMigrationTests already pin the aggregation
// truth table and the legacy-dlib arm; this file pins what they leave open:
// the exact error TEXT (it is emitted in the JSON `error` field), which error
// wins when several apply, the defaults, the numeric validators, and
// last-wins on repeated scalar flags.

import XCTest
@testable import VideoScan

final class PersonEvaluationCLIParseCharacterizationTests: XCTestCase {

    private let required = ["--person", "Donna", "--references", "/tmp/refs", "--video", "/tmp/v.mov"]

    private func parse(_ args: [String]) throws -> PersonEvaluationCLI.Options {
        try PersonEvaluationCLI.parse(args)
    }

    /// The message the CLI would put in the JSON `error` field.
    private func failure(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> String {
        var message = ""
        XCTAssertThrowsError(try parse(args), "expected a parse error for \(args)", file: file, line: line) {
            message = $0.localizedDescription
        }
        return message
    }

    // MARK: Defaults and simple assignments

    func test_requiredOnly_givesTheDocumentedDefaults() throws {
        let o = try parse(["--person-eval"] + required)
        XCTAssertEqual(o.person, "Donna")
        XCTAssertEqual(o.references, "/tmp/refs")
        XCTAssertEqual(o.video, "/tmp/v.mov")
        XCTAssertEqual(o.engine, .vision)
        XCTAssertFalse(o.legacyDlib)
        XCTAssertNil(o.threshold)
        XCTAssertNil(o.frameStep)
        XCTAssertNil(o.minFaceConfidence)
        XCTAssertFalse(o.largestFaceOnly)
        XCTAssertFalse(o.facePresenceOnly)
        XCTAssertNil(o.pythonPath)
        XCTAssertNil(o.recognitionScript)
        XCTAssertNil(o.aggregationMode)
        XCTAssertNil(o.minHits)
        XCTAssertEqual(o.presenceRule, .legacy)
    }

    func test_engineTokens_matchDisplayNameOrTitle_caseInsensitively() throws {
        XCTAssertEqual(try parse(required + ["--engine", "Vision"]).engine, .vision)
        XCTAssertEqual(try parse(required + ["--engine", "ARCFACE"]).engine, .arcface)
        XCTAssertEqual(try parse(required + ["--engine", "adaface"]).engine, .adaface)
        XCTAssertEqual(try parse(required + ["--engine", "Hybrid"]).engine, .hybrid)
        XCTAssertEqual(failure(required + ["--engine", "Vision (fast)"]), "unknown engine: vision (fast)",
                       "the raw value spelling is not a token")
        XCTAssertEqual(failure(required + ["--engine", ""]), "unknown engine: ")
    }

    func test_numericValues_parseAndRejectWithTheirOwnMessages() throws {
        XCTAssertEqual(try parse(required + ["--threshold", "0.5"]).threshold, 0.5)
        XCTAssertEqual(try parse(required + ["--threshold", "-1"]).threshold, -1, "no range check on threshold")
        XCTAssertEqual(failure(required + ["--threshold", "abc"]), "invalid threshold")
        XCTAssertEqual(try parse(required + ["--frame-step", "5"]).frameStep, 5)
        XCTAssertEqual(failure(required + ["--frame-step", "0"]), "invalid frame step")
        XCTAssertEqual(failure(required + ["--frame-step", "-3"]), "invalid frame step")
        XCTAssertEqual(failure(required + ["--frame-step", "2.5"]), "invalid frame step")
        XCTAssertEqual(try parse(required + ["--min-face-confidence", "0.7"]).minFaceConfidence, 0.7)
        XCTAssertEqual(failure(required + ["--min-face-confidence", "x"]), "invalid face confidence")
        XCTAssertEqual(failure(required + ["--min-hits", "0", "--aggregation", "minimum-hits"]),
                       "invalid --min-hits: 0 (must be a positive integer)")
    }

    func test_booleanFlags_setAndNeedNoValue() throws {
        let o = try parse(required + ["--largest-face-only", "--face-presence-only"])
        XCTAssertTrue(o.largestFaceOnly)
        XCTAssertTrue(o.facePresenceOnly)
        // A value after a boolean flag is just the next argument — and unknown.
        XCTAssertEqual(failure(required + ["--largest-face-only", "yes"]), "unknown argument: yes")
    }

    func test_toolingPathsAndAggregationSpellings() throws {
        let o = try parse(required + ["--python-path", "/py", "--recognition-script", "/s.py",
                                      "--aggregation", "MINIMUM-HITS", "--min-hits", "7"])
        XCTAssertEqual(o.pythonPath, "/py")
        XCTAssertEqual(o.recognitionScript, "/s.py")
        XCTAssertEqual(o.aggregationMode, .minimumHits)
        XCTAssertEqual(o.minHits, 7)
        XCTAssertEqual(o.presenceRule, .minimumHits(floor: 7))
        XCTAssertEqual(try parse(required + ["--aggregation", "minimumhits", "--min-hits", "2"]).aggregationMode, .minimumHits)
        XCTAssertEqual(try parse(required + ["--aggregation", "legacy-any-hit"]).aggregationMode, .legacyAnyHit)
        XCTAssertEqual(try parse(required + ["--aggregation", "legacyanyhit"]).aggregationMode, .legacyAnyHit)
        XCTAssertEqual(try parse(required + ["--aggregation", "legacy"]).presenceRule, .legacy)
    }

    func test_repeatedScalarFlags_lastWins_butDlibTokenStaysSet() throws {
        XCTAssertEqual(try parse(required + ["--person", "Mark"]).person, "Mark")
        XCTAssertEqual(try parse(required + ["--engine", "vision", "--engine", "arcface"]).engine, .arcface)
        // Quirk pinned, not endorsed: `dlib` then `vision` leaves BOTH the
        // legacy arm on and the registry engine set.
        let both = try parse(required + ["--engine", "dlib", "--engine", "arcface"])
        XCTAssertTrue(both.legacyDlib)
        XCTAssertEqual(both.engine, .arcface)
        XCTAssertEqual(try parse(required + ["--threshold", "0.1", "--threshold", "0.9"]).threshold, 0.9)
    }

    // MARK: Error text and precedence

    func test_requiredArgumentMessages_inOrder_personReferencesVideo() {
        XCTAssertEqual(failure([]), "--person is required")
        XCTAssertEqual(failure(["--person", "D"]), "--references is required")
        XCTAssertEqual(failure(["--person", "D", "--references", "/r"]), "--video is required")
        XCTAssertEqual(failure(["--face-presence-only"]), "--video is required",
                       "presence-only needs neither person nor references")
        XCTAssertNoThrow(try parse(["--face-presence-only", "--video", "/v"]))
        XCTAssertEqual(failure(["--person", "", "--references", "/r", "--video", "/v"]), "--person is required",
                       "an empty value counts as missing")
    }

    func test_unknownAndMissingValueMessages() {
        XCTAssertEqual(failure(required + ["--bogus"]), "unknown argument: --bogus")
        XCTAssertEqual(failure(required + ["stray"]), "unknown argument: stray")
        XCTAssertEqual(failure(required + ["--video"]), "missing value after --video")
        XCTAssertEqual(failure(required + ["--engine"]), "missing value after --engine")
        XCTAssertEqual(failure(["--person"]), "missing value after --person")
    }

    func test_firstErrorInArgumentOrderWins_andScanErrorsBeatValidation() {
        XCTAssertEqual(failure(["--engine", "skynet", "--bogus"]), "unknown engine: skynet")
        XCTAssertEqual(failure(["--bogus", "--engine", "skynet"]), "unknown argument: --bogus")
        XCTAssertEqual(failure(["--frame-step", "0", "--threshold", "x"]), "invalid frame step")
        // A scan error is reported even though required args are also missing.
        XCTAssertEqual(failure(["--threshold", "x"]), "invalid threshold")
        // Required-argument checks come before flag-coherence checks.
        XCTAssertEqual(failure(["--aggregation", "minimum-hits"]), "--person is required")
        XCTAssertEqual(failure(["--face-presence-only", "--aggregation", "minimum-hits", "--min-hits", "3"]),
                       "--video is required")
    }

    func test_coherenceMessages_areExact() {
        XCTAssertEqual(failure(required + ["--aggregation", "minimum-hits"]),
                       "--aggregation minimum-hits requires --min-hits (no silent default)")
        XCTAssertEqual(failure(required + ["--face-presence-only", "--aggregation", "minimum-hits", "--min-hits", "3"]),
                       "--aggregation minimum-hits conflicts with --face-presence-only (a presence-only run has no reference hits to count)")
        XCTAssertEqual(failure(required + ["--min-hits", "3"]), "--min-hits requires --aggregation minimum-hits")
        XCTAssertEqual(failure(required + ["--aggregation", "legacy", "--min-hits", "3"]),
                       "--min-hits requires --aggregation minimum-hits")
        XCTAssertEqual(failure(required + ["--aggregation", "legacy", "--aggregation", "legacy"]), "duplicate --aggregation")
        XCTAssertEqual(failure(required + ["--min-hits", "3", "--min-hits", "3", "--aggregation", "minimum-hits"]),
                       "duplicate --min-hits")
        XCTAssertEqual(failure(required + ["--aggregation", "score"]), "unknown aggregation mode: score")
        XCTAssertEqual(failure(required + ["--aggregation", "Legacy-Any-Hit", "--aggregation", "x"]), "duplicate --aggregation",
                       "the duplicate check runs before the mode is read")
        // …even when the second flag has no value at all.
        XCTAssertEqual(failure(required + ["--aggregation", "legacy", "--aggregation"]), "duplicate --aggregation")
        XCTAssertEqual(failure(required + ["--min-hits", "3", "--min-hits"]), "duplicate --min-hits")
        // Whereas a value-taking flag with no duplicate guard reports the missing value.
        XCTAssertEqual(failure(required + ["--threshold", "0.5", "--threshold"]), "missing value after --threshold")
    }
}
