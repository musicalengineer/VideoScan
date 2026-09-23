// ArchiveAngelRecommendationsTests.swift
// Consolidation S3 — the ONE recommendation classifier and the rule
// language it is driven by (ArchiveAngel/Recommend/ArchiveAngelRecommendations.swift,
// AngelRuleLanguage.swift).
//
//   LOGIC     tables for every operator × field type, `any`, every rule kind
//             the classifier reads, the copy chooser, the date rule;
//   SCALE     the legacy rule set over the S0 100k-record catalog, timed;
//   FROZEN    (S3a parity → S4) the classifier under `.legacyNudge` holds
//             the retired ArchiveNudge.assess's answers — its 100k pins and
//             every ArchiveNudgeTests expectation, unchanged.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The legacy rule set, pinned to frozen answers (S3a parity → S4)

/// S3a proved `.legacyNudge` answers EXACTLY what ArchiveNudge.assess
/// answered (same ids, reasons, years, order) on the 100k S0 catalog and on
/// every ArchiveNudgeTests case. S4 retired ArchiveNudge with the Promote
/// Helper, so the rule set is now held to that function's FROZEN answers:
/// the 100k pins live in ArchiveAngelScaleCharacterizationTests.nudgeCounts,
/// and the ArchiveNudgeTests cases are below with the expectations they
/// asserted on the old function, unchanged.
@Suite("Archive Angel recommendations — the legacy rule set holds the retired ArchiveNudge's frozen answers", .serialized)
@MainActor
struct ArchiveAngelRecommendationsLegacyParityTests {

    @Test("SCALE: the pure classify over 100k projected candidates — under 1 s (Debug)")
    func classifyBudget() {
        let candidates = ArchiveAngelS0Catalog.records(100_000).map { ArchiveAngelCandidate(recommendationFactsOf: $0) }
        let clock = ContinuousClock()
        var result = ArchiveAngelRecommendations.Result.empty
        let elapsed = clock.measure {
            result = ArchiveAngelRecommendations.classify(candidates, rules: .legacyNudge)
        }
        let s = ArchiveAngelS0Catalog.seconds(elapsed)
        print("[angel-s3a] classify 100k \(String(format: "%.3f", s)) s")
        #expect(result.verdicts.count == 100_000)
        #expect(result.counts.values.reduce(0, +) == 100_000)
        #expect(s < 1, "classify 100k in \(s) s")
    }

    // The ArchiveNudgeTests cases (Rick 2026-08-21), frozen expectations.

    private func record(_ name: String, stars: Int = 0, disposition: MediaDisposition = .unreviewed,
                        stage: ArchiveStage = .none, dup: DuplicateDisposition = .none,
                        junk: Int = 0, dated: Bool = true) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/LaCie/\(name)"
        r.starRating = stars
        r.mediaDisposition = disposition
        r.archiveStage = stage
        r.duplicateDisposition = dup
        r.junkScore = junk
        if dated {
            r.embeddedCreationDate = Calendar.current.date(from: DateComponents(year: 1994, month: 7, day: 4))
        }
        return r
    }

    private func legacy(_ records: [VideoRecord]) -> ArchiveAngelRecommendations.Result {
        ArchiveAngelRecommendations.classify(records.map { ArchiveAngelCandidate(recommendationFactsOf: $0) },
                                             rules: .legacyNudge)
    }

    @Test("FROZEN: only vouched, dated keepers are ready — never junk, never an extra copy, 1 star is not a vouch")
    func onlyVouchedDatedKeepersAreReady() {
        let r = legacy([
            record("christmas_1994.mov", stars: 3),
            record("cape.mov", disposition: .important),
            record("ready.mov", stage: .readyForArchive),
            record("unrated.mov"),                              // nobody vouched
            record("one_star.mov", stars: 1),                   // 1 star is not a vouch
            record("copy.mov", stars: 3, dup: .extraCopy),      // never an extra copy
            record("junk.mov", stars: 3, disposition: .suspectedJunk),
            record("scored_junk.mov", stars: 3, junk: 80),
            record("undated.mov", stars: 2, dated: false),
        ])
        #expect(r.ready.map(\.filename) == ["cape.mov", "christmas_1994.mov", "ready.mov"])
        #expect(r.needsDate.map(\.filename) == ["undated.mov"])
        #expect(r.ready.first { $0.filename == "christmas_1994.mov" }?.reasons == ["★★★"])
        #expect(r.ready.first { $0.filename == "christmas_1994.mov" }?.year == 1994)
        #expect(r.ready.first { $0.filename == "cape.mov" }?.reasons == ["marked Important"])
    }

    @Test("FROZEN: stronger vouching sorts first; the Keep mark alone is not a vouch")
    func strongerVouchingSortsFirstAndKeepIsNotAVouchByItself() {
        let r = legacy([
            record("b.mov", stars: 2),
            record("a.mov", stars: 3, disposition: .important, dup: .keep),
            record("keeper_only.mov", dup: .keep),
        ])
        #expect(r.ready.map(\.filename) == ["a.mov", "b.mov"])
        #expect(r.ready.first?.reasons == ["marked Important", "★★★", "the copy to keep"])
    }

    @Test("FROZEN: counts — 15 ready + 1 needing a date; one needing a date alone; nothing at all")
    func counts() {
        let many = legacy((1...15).map { record("f\($0).mov", stars: 2) } + [record("u.mov", stars: 2, dated: false)])
        #expect(many.ready.count == 15 && many.needsDate.count == 1)
        let one = legacy([record("u.mov", stars: 2, dated: false)])
        #expect(one.ready.isEmpty && one.needsDate.map(\.filename) == ["u.mov"])
        let none = legacy([])
        #expect(none.ready.isEmpty && none.needsDate.isEmpty)
    }

    @Test("FROZEN: copies of one recording collapse to the keeper, or to the best-vouched copy")
    func copiesOfOneRecordingCollapseToTheKeeperOrTheBestVouched() {
        let group = UUID()
        func copy(_ name: String, stars: Int, dup: DuplicateDisposition) -> VideoRecord {
            let r = record(name, stars: stars, dup: dup)
            r.duplicateGroupID = group
            r.duplicateGroupCount = 3
            return r
        }
        let withKeeper = legacy([
            copy("lacie/xmas.mov", stars: 3, dup: .review),
            copy("mybook/xmas.mov", stars: 2, dup: .keep),
            copy("x9/xmas.mov", stars: 3, dup: .review),
        ])
        #expect(withKeeper.ready.map(\.filename) == ["mybook/xmas.mov"], "the chosen keeper wins even with fewer stars")
        #expect(withKeeper.ready.first?.reasons.last == "3 copies — this one")
        let noKeeper = legacy([
            copy("lacie/xmas.mov", stars: 2, dup: .review),
            copy("mybook/xmas.mov", stars: 3, dup: .none),
        ])
        #expect(noKeeper.ready.map(\.filename) == ["mybook/xmas.mov"], "no keeper chosen → the best-vouched copy, once")
        #expect(noKeeper.ready.first?.reasons.last == "2 copies — this one")
    }

    @Test("FROZEN: ready rows lead, strongest first; the nearly-ready follow")
    func readyFirstStrongestFirst() {
        var records = (1...20).map { record("r\($0).mov", stars: 2) }
        records.append(record("important.mov", disposition: .important))
        records.append(contentsOf: (1...5).map { record("u\($0).mov", stars: 2, dated: false) })
        let r = legacy(records)
        #expect(r.ready.count == 21 && r.needsDate.count == 5)
        #expect(r.ready.first?.filename == "important.mov", "strongest vouching first")
        let few = legacy([record("a.mov", stars: 2), record("u.mov", stars: 2, dated: false)])
        #expect((few.ready + few.needsDate).map(\.filename) == ["a.mov", "u.mov"])
    }

    @Test("FROZEN: the same camera name and length collapses; older tapes rank first among equals")
    func sameCameraNameAndLengthCollapsesAndOlderTapesRankFirst() {
        func mts(_ path: String) -> VideoRecord {
            let r = record("00000.MTS", disposition: .important)
            r.fullPath = path
            r.durationSeconds = 612.4
            return r
        }
        let fixture2026 = record("2026-07-05_12-55-56.mkv", disposition: .important)
        fixture2026.embeddedCreationDate = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 5))
        let r = legacy([
            fixture2026,
            mts("/Volumes/X9/card1/00000.MTS"), mts("/Volumes/X10/card2/00000.MTS"),
            mts("/Volumes/LaCie/00000.MTS"), mts("/Volumes/MyBook/00000.MTS"),
            record("Cape-1993-archive.mkv", disposition: .important),
        ])
        let names = r.ready.map(\.filename)
        #expect(names.filter { $0 == "00000.MTS" }.count == 1, "four cards, one recording")
        #expect(names.first == "00000.MTS" || names.first == "Cape-1993-archive.mkv")
        #expect(names.last == "2026-07-05_12-55-56.mkv", "older recordings first among equal vouching")
        #expect(r.ready.first { $0.filename == "00000.MTS" }?.reasons.last == "4 copies — this one")
    }

    @Test("the legacy rule set is sound data (validation finds nothing) and survives a JSON round trip unchanged")
    func legacyIsData() throws {
        #expect(AngelRecommendRules.legacyNudge.problems.isEmpty, "\(AngelRecommendRules.legacyNudge.problems)")
        let data = try JSONEncoder().encode(AngelRecommendRules.legacyNudge)
        let back = try JSONDecoder().decode(AngelRecommendRules.self, from: data)
        #expect(back == .legacyNudge)
    }
}

// MARK: - The rule language

@Suite("Archive Angel rule language — fields, operators, any, validation")
struct AngelRuleLanguageTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func matches(_ cond: AngelCondition, _ c: ArchiveAngelCandidate) -> Bool {
        var ctx = AngelEvalContext(now: now)
        return cond.matches(c, &ctx)
    }

    private func decode(_ json: String) throws -> AngelCondition {
        try JSONDecoder().decode(AngelCondition.self, from: Data(json.utf8))
    }

    @Test("numbers: == != < <= > >=; an unknown value (no year) never matches")
    func numbers() throws {
        let c = ArchiveAngelCandidate(durationSeconds: 240)
        let table: [(String, Bool)] = [
            (#"{"field":"durationMinutes","op":"<","value":5}"#, true),
            (#"{"field":"durationMinutes","op":"<=","value":4}"#, true),
            (#"{"field":"durationMinutes","op":">","value":4}"#, false),
            (#"{"field":"durationMinutes","op":">=","value":4}"#, true),
            (#"{"field":"durationSeconds","op":"==","value":240}"#, true),
            (#"{"field":"durationSeconds","op":"!=","value":240}"#, false),
            (#"{"field":"year","op":"<","value":3000}"#, false),
            (#"{"field":"year","op":"!=","value":1990}"#, false),
        ]
        for (json, want) in table {
            let cond = try decode(json)
            #expect(cond.problems(allowClassifierFields: false).isEmpty, "\(json)")
            #expect(matches(cond, c) == want, "\(json)")
        }
    }

    @Test("text: case-insensitive == contains hasPrefix hasSuffix in; lists: contains / in")
    func text() throws {
        let c = ArchiveAngelCandidate(filename: "Cape Cod 1993.MOV", fullPath: "/Volumes/LaCie/Family/Cape Cod 1993.MOV",
                                      confirmedPeople: ["Donna", "Rick"], detectedPeople: ["Tim"], videoCodec: "dvvideo")
        let table: [(String, Bool)] = [
            (#"{"field":"filename","op":"==","value":"cape cod 1993.mov"}"#, true),
            (#"{"field":"filename","op":"contains","value":"COD"}"#, true),
            (#"{"field":"filename","op":"notContains","value":"cod"}"#, false),
            (#"{"field":"path","op":"hasPrefix","value":"/volumes/lacie"}"#, true),
            (#"{"field":"filename","op":"hasSuffix","value":".mp4"}"#, false),
            (#"{"field":"videoCodec","op":"in","value":["h264","DVVIDEO"]}"#, true),
            (#"{"field":"videoCodec","op":"notIn","value":["h264"]}"#, true),
            (#"{"field":"people","op":"contains","value":"donna"}"#, true),
            (#"{"field":"people","op":"contains","value":"Tim"}"#, false),
            (#"{"field":"machinePeople","op":"contains","value":"Tim"}"#, true),
            (#"{"field":"people","op":"in","value":["Ellen","Rick"]}"#, true),
            (#"{"field":"people","op":"notIn","value":["Ellen"]}"#, true),
        ]
        for (json, want) in table {
            let cond = try decode(json)
            #expect(cond.problems(allowClassifierFields: false).isEmpty, "\(json)")
            #expect(matches(cond, c) == want, "\(json)")
        }
    }

    @Test("choices take the case name or the app's label; flags take true/false; any = OR")
    func choicesFlagsAny() throws {
        let c = ArchiveAngelCandidate(mediaDisposition: .suspectedJunk, archiveStage: .readyForArchive,
                                      deviceModel: "iPhone 12", duplicateDisposition: .keep)
        let table: [(String, Bool)] = [
            (#"{"field":"mediaDisposition","op":"==","value":"suspectedJunk"}"#, true),
            (#"{"field":"mediaDisposition","op":"==","value":"Suspected Junk"}"#, true),
            (#"{"field":"mediaDisposition","op":"!=","value":"important"}"#, true),
            (#"{"field":"archiveStage","op":"in","value":["masterAssigned","Ready"]}"#, true),
            (#"{"field":"duplicateDisposition","op":"notIn","value":["extraCopy"]}"#, true),
            (#"{"field":"isPhoneClip","op":"==","value":true}"#, true),
            (#"{"field":"isOnlyCopy","op":"!=","value":false}"#, false),
            (#"{"any":[{"field":"starRating","op":">=","value":2},{"field":"isPhoneClip","op":"==","value":true}]}"#, true),
            (#"{"any":[{"field":"starRating","op":">=","value":2},{"field":"volumeOnline","op":"==","value":false}]}"#, false),
        ]
        for (json, want) in table {
            let cond = try decode(json)
            #expect(cond.problems(allowClassifierFields: false).isEmpty, "\(json)")
            #expect(matches(cond, c) == want, "\(json)")
        }
    }

    @Test("REFUSED: unknown field / op, wrong value type, a choice that is not one, classifier-only fields in a floor — each named")
    func problemsNamed() throws {
        let table: [(String, String)] = [
            (#"{"field":"lenght","op":"<","value":5}"#, "unknown field \"lenght\""),
            (#"{"field":"durationMinutes","op":"~","value":5}"#, "unknown op \"~\""),
            (#"{"field":"durationMinutes","op":"<","value":"5"}"#, "needs a finite number"),
            (#"{"field":"filename","op":"<","value":"a"}"#, "is text"),
            (#"{"field":"isPhoneClip","op":"==","value":1}"#, "needs true or false"),
            (#"{"field":"mediaDisposition","op":"==","value":"Importnt"}"#, "is not a mediaDisposition"),
            (#"{"field":"grade","op":"==","value":"A"}"#, "only known to the class rules"),
            (#"{"any":[]}"#, "at least one condition"),
            (#"{"field":"filename","op":"==","value":"x","any":[{"field":"filename","op":"==","value":"y"}]}"#, "not both"),
        ]
        for (json, fragment) in table {
            let cond = try decode(json)
            let problems = cond.problems(allowClassifierFields: false)
            #expect(problems.contains { $0.contains(fragment) }, "\(json) → \(problems)")
            #expect(!matches(cond, ArchiveAngelCandidate()), "an unresolved condition never matches")
        }
    }

    @Test("values decode as bool / number / string / list — never a number as a bool")
    func valueDecoding() throws {
        let d = JSONDecoder()
        #expect(try d.decode([AngelValue].self, from: Data(#"[true, 3, 2.5, "x", ["a","b"]]"#.utf8))
                == [.bool(true), .number(3), .number(2.5), .string("x"), .strings(["a", "b"])])
        #expect(throws: (any Error).self) { try d.decode(AngelValue.self, from: Data(#"{"a":1}"#.utf8)) }
    }

    @Test("rules: unknown kind and a kind in the wrong section are refused; duplicate ids named; only non-defaults are written")
    func ruleValidation() throws {
        let json = #"""
        [{"id":"a","kind":"match","when":[{"field":"starRating","op":">=","value":2}],"points":5,"line":"starred"},
         {"id":"a","kind":"tooShort"},
         {"id":"c","kind":"frobnicate"}]
        """#
        let rules = try JSONDecoder().decode([AngelRule].self, from: Data(json.utf8))
        let problems = AngelRule.problems(in: rules, section: .vouch, where: "recommend.vouch", pointRange: 0...1_000)
        #expect(problems.contains { $0.contains("duplicate id") })
        #expect(problems.contains { $0.contains("\"tooShort\" does not belong in vouch") })
        #expect(problems.contains { $0.contains("unknown kind \"frobnicate\"") })
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let encoded = String(bytes: try enc.encode(rules[1]), encoding: .utf8)
        #expect(encoded == #"{"id":"a","kind":"tooShort"}"#)
    }

    @Test("the date rule wraps RecordDateResolver; readinessKnown asks ArchiveReadiness.dateState")
    func dateRule() {
        let year = RecordDateResolution(year: 1994, month: nil, day: nil, precision: .year, confidence: 0.5, source: .filename)
        let decade = RecordDateResolution(year: 1990, month: nil, day: nil, precision: .decade, confidence: 0.5, source: .filename)
        let userYear = RecordDateResolution(year: 1994, month: nil, day: nil, precision: .year, confidence: 1, source: .userDate)
        #expect(AngelDateRule(minimum: "year").isDated(year))
        #expect(!AngelDateRule(minimum: "year").isDated(decade))
        #expect(!AngelDateRule(minimum: "month").isDated(year))
        #expect(AngelDateRule(minimum: "decade").isDated(decade))
        #expect(!AngelDateRule(minimum: "readinessKnown").isDated(year), "a filename year is low confidence")
        #expect(AngelDateRule(minimum: "readinessKnown").isDated(userYear), "Rick's own year is known")
        #expect(AngelDateRule(minimum: "yearly").problem != nil)
    }
}

// MARK: - The classifier's own logic

@Suite("Archive Angel recommendations — classes, vouches, copies")
struct ArchiveAngelClassifierLogicTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("legacy: exclusions first, vouches add up, class by vouched + dated, unvouched → Not now")
    func legacyClasses() {
        let dated = Date(timeIntervalSince1970: 773_000_000)
        let cs = [
            ArchiveAngelCandidate(filename: "a.mov", starRating: 3, captureDate: dated),
            ArchiveAngelCandidate(filename: "b.mov", starRating: 2),
            ArchiveAngelCandidate(filename: "c.mov", mediaDisposition: .important, archiveStage: .masterAssigned, captureDate: dated),
            ArchiveAngelCandidate(filename: "d.mov", starRating: 3, junkScore: 50, captureDate: dated),
            ArchiveAngelCandidate(filename: "e.mov", captureDate: dated),
        ]
        let r = ArchiveAngelRecommendations.classify(cs, rules: .legacyNudge, now: now)
        #expect(r.verdicts.map(\.kind) == [.ready, .needsDate, .ready, .excluded, .notNow])
        #expect(r.verdicts[2].points == 4 && r.verdicts[2].reasons == ["marked Important", "stage: Master"])
        #expect(r.verdicts[3].reasons == ["Junk score 50 or more"])
        #expect(r.ready.map(\.filename) == ["c.mov", "a.mov"], "4 points before 3")
        #expect(r.counts == [.ready: 2, .needsDate: 1, .excluded: 1, .notNow: 1])
    }

    @Test("copy chooser: keys in order, the person's Keep first, else the best; the rest become Another copy")
    func copies() {
        let g = UUID()
        let key = { (c: ArchiveAngelCandidate, by: [String]) in ArchiveAngelCopyChooser.key(c, collapseBy: by) }
        let grouped1 = ArchiveAngelCandidate(filename: "x.mov", durationSeconds: 60.4, duplicateGroupID: g, duplicateGroupCount: 1)
        #expect(key(grouped1, ["duplicateGroup"]) == "group:" + g.uuidString)
        #expect(key(grouped1, ["sharedDuplicateGroup", "nameAndDuration"]) == "name:x.mov|60", "a group of one is not shared")
        #expect(key(ArchiveAngelCandidate(filename: "", durationSeconds: 5), ["nameAndDuration"]) == nil)
        #expect(ArchiveAngelCopyChooser.choose([4, 7, 9], prefer: ["userKeeper", "best"], isKeeper: { $0 == 9 },
                                               isBetter: { $0 < $1 }) == 9)
        #expect(ArchiveAngelCopyChooser.choose([4, 7, 2], prefer: ["userKeeper", "best"], isKeeper: { _ in false },
                                               isBetter: { $0 < $1 }) == 2)
        let kept = ArchiveAngelCopyChooser.firstPerKey(["a1", "b1", "a2", "c", "b2"], key: { $0 == "c" ? nil : String($0.prefix(1)) })
        #expect(kept.kept == ["a1", "b1", "c"] && kept.dropped == 2)
    }

    @Test("SENSOR: CopyFamilyAssessor's physical-instance answer is reachable through the one copy seam, unchanged")
    func physicalInstanceSeam() {
        let a = CopyFamilyInput(fullPath: "/Volumes/A/x.mov", isReachable: false)
        let b = CopyFamilyInput(fullPath: "/Volumes/B/x.mov", isReachable: true)
        #expect(ArchiveAngelCopyChooser.physicalInstance(of: [a, b])?.id == CopyFamilyAssessor.recommendedInstance([a, b])?.id)
        #expect(ArchiveAngelCopyChooser.physicalInstance(of: [a, b])?.id == b.id)
    }
}

// MARK: - The unified rules (S3b)

@Suite("Archive Angel recommendations — the unified default rules (S3b)")
struct ArchiveAngelUnifiedRulesTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let dated = Date(timeIntervalSince1970: 773_000_000)   // 1994

    private func ev(_ score: Int, _ rejection: ArchiveAngelRejection? = nil) -> ArchiveAngelEvidenceRecord {
        .init(score: score, lines: [], rejection: rejection, useCount: 0, lastUsed: nil, computedAt: now)
    }

    @Test("LOGIC table: floors, vouch-or-A, the date rule, grade B, C/D, extra copy, not assessed")
    func table() {
        typealias K = ArchiveAngelRecommendationClass
        let rows: [(String, ArchiveAngelCandidate, ArchiveAngelEvidenceRecord?, K)] = [
            ("a floor → Excluded", .init(starRating: 3, captureDate: dated), ev(0, .tooShort), .excluded),
            ("★★ grade C, dated → Ready (vouched)", .init(starRating: 2, captureDate: dated), ev(40), .ready),
            ("grade A unvouched, undated → Needs a date", .init(), ev(120), .needsDate),
            ("grade A unvouched, dated → Ready", .init(captureDate: dated), ev(120), .ready),
            ("grade B unvouched → Worth a look", .init(captureDate: dated), ev(70), .worthALook),
            ("grade B + Important → Ready", .init(mediaDisposition: .important, captureDate: dated), ev(70), .ready),
            ("grade C unvouched → Not now", .init(captureDate: dated), ev(40), .notNow),
            ("grade D, 1 star → Not now (1 star is not a vouch)", .init(starRating: 1, captureDate: dated), ev(10), .notNow),
            ("stage Ready is a VOTE → Ready", .init(archiveStage: .readyForArchive, captureDate: dated), ev(30), .ready),
            ("stage Master is a VOTE → Needs a date", .init(archiveStage: .masterAssigned), ev(30), .needsDate),
            // QA on S3: Extra copy is a scorer FLOOR now — its evidence is X.
            ("an Extra copy → Excluded", .init(starRating: 3, captureDate: dated, duplicateDisposition: .extraCopy), ev(0, .extraCopy), .excluded),
            ("no evidence → Not now", .init(starRating: 3, captureDate: dated), nil, .notNow),
            ("a year in the name dates it", .init(filename: "Cape Cod 1993.mov", starRating: 2), ev(50), .ready),
        ]
        for (label, c, e, want) in rows {
            let v = ArchiveAngelRecommendations.verdict(c, evidence: e, rules: .standard, now: now)
            #expect(v.kind == want, "\(label): got \(v.kind)")
        }
        #expect(AngelRecommendRules.standard.problems.isEmpty, "\(AngelRecommendRules.standard.problems)")
        #expect(ArchiveAngelScorer.hardFloor(.init(starRating: 3, duplicateDisposition: .extraCopy), policy: .builtIn, now: now) == .extraCopy)
    }

    @Test("reasons: vouches first, grade A named when nobody vouched, the floor's own reason when excluded")
    func reasons() {
        let vouched = ArchiveAngelRecommendations.verdict(.init(starRating: 3, mediaDisposition: .important, captureDate: dated),
                                                          evidence: ev(160), rules: .standard, now: now)
        #expect(vouched.reasons == ["marked Important", "★★★"])
        #expect(vouched.year == 1994)
        let byGrade = ArchiveAngelRecommendations.verdict(.init(captureDate: dated), evidence: ev(120), rules: .standard, now: now)
        #expect(byGrade.reasons == ["Archive Angel grade A (120)"])
        let floored = ArchiveAngelRecommendations.verdict(.init(), evidence: ev(0, .volumeOffline), rules: .standard, now: now)
        #expect(floored.reasons == [ArchiveAngelRejection.volumeOffline.rawValue])
    }

    @Test("copies: one per duplicate group — the Keep copy wins over a higher score; the rest are Another copy")
    func copiesCollapse() {
        let g = UUID()
        let a = ArchiveAngelCandidate(filename: "a.mov", starRating: 3, duplicateGroupID: g, captureDate: dated,
                                      duplicateGroupCount: 2)
        let b = ArchiveAngelCandidate(filename: "b.mov", starRating: 2, duplicateGroupID: g, captureDate: dated,
                                      duplicateGroupCount: 2, duplicateDisposition: .keep)
        let r = ArchiveAngelRecommendations.classify([a, b], evidence: [a.id: ev(200), b.id: ev(90)],
                                                     rules: .standard, now: now)
        #expect(r.verdicts.map(\.kind) == [.anotherCopy, .ready])
        #expect(r.verdicts[1].copies == 2 && r.verdicts[1].reasons.last == "2 copies — this one")
        #expect(r.ready.map(\.id) == [b.id])
        let noKeeper = ArchiveAngelRecommendations.classify(
            [a, ArchiveAngelCandidate(filename: "c.mov", duplicateGroupID: g, captureDate: dated, duplicateGroupCount: 2)],
            evidence: [a.id: ev(200)], rules: .standard, now: now)
        #expect(noKeeper.verdicts.first?.kind == .ready, "the other copy is not assessed — nothing collapses")
    }

    @Test("SENSOR (Rick 2026-09-22, decision 3): archiveStage Ready/Master is a vote, not a floor; Relocate's deleted/unsalvageable stages are `fileGone`; v10's rule is one data rule away")
    func stageIsAVote() {
        for stage in [ArchiveStage.masterAssigned, .readyForArchive, .backedUp, .archived] {
            #expect(ArchiveAngelScorer.hardFloor(ArchiveAngelCandidate(archiveStage: stage), policy: .builtIn, now: now) == nil,
                    "\(stage) is not \"already archived\"")
            #expect(ArchiveAngelScorer.hardFloor(ArchiveAngelCandidate(archiveStage: stage), policy: .rulesV10, now: now)
                    == .alreadyArchived, "v10 as data")
        }
        for stage in [ArchiveStage.manuallyDeleted, .salvageFailed] {
            #expect(ArchiveAngelScorer.hardFloor(ArchiveAngelCandidate(archiveStage: stage), policy: .builtIn, now: now) == .fileGone)
        }
        #expect(ArchiveAngelScorer.hardFloor(ArchiveAngelCandidate(isOnMasterArchive: true), policy: .builtIn, now: now) == .alreadyArchived,
                "only a real Master Archive copy means archived")
    }

    @Test("the unified rules survive a JSON round trip unchanged (they are data)")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(AngelRecommendRules.standard)
        #expect(try JSONDecoder().decode(AngelRecommendRules.self, from: data) == .standard)
    }
}

// MARK: - ONE set of numbers (the façade)

@Suite("Archive Angel — one set of numbers: strip headline, badge and filter agree", .serialized)
@MainActor
struct ArchiveAngelOneSetOfNumbersTests {

    private func model() throws -> (VideoScanModel, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-numbers")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (model, sb.root)
    }

    private func rec(_ score: Int, _ kind: ArchiveAngelRecommendationClass?, year: Int? = nil,
                     reasons: [String]? = nil, rejection: ArchiveAngelRejection? = nil) -> ArchiveAngelEvidenceRecord {
        var r = ArchiveAngelEvidenceRecord(score: score, lines: [], rejection: rejection, useCount: 0, lastUsed: nil,
                                           computedAt: Date())
        r.recommendation = kind
        r.year = year
        r.reasons = reasons
        return r
    }

    @Test("the counts, the headline, the candidate set and the badges come from the same classes")
    func agree() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["r1.mov", "r2.mov", "n.mov", "w.mov", "x.mov", "o.mov"]
        let records = names.map { name -> VideoRecord in
            let r = VideoRecord()
            r.filename = name
            r.fullPath = "/Volumes/T/" + name
            return r
        }
        model.records = records
        let ids = records.map(\.id)
        let angel = model.archiveAngel
        angel.store.replace(with: ArchiveAngelEvidenceFile(records: [
            ids[0]: rec(150, .ready, year: 1994, reasons: ["★★★"]),
            ids[1]: rec(40, .ready, year: 1988, reasons: ["marked Important"]),
            ids[2]: rec(120, .needsDate, reasons: ["Archive Angel grade A (120)"]),
            ids[3]: rec(70, .worthALook),
            ids[4]: rec(0, .excluded, rejection: .tooShort),
            ids[5]: rec(80, .anotherCopy),
        ]))
        let s = angel.recommendations
        #expect(s.count(.ready) == 2 && s.count(.needsDate) == 1 && s.count(.worthALook) == 1)
        #expect(s.count(.excluded) == 1 && s.count(.anotherCopy) == 1 && s.count(.prepared) == 0)
        #expect(s.headline == "2 ready · 1 needs a date · 0 prepared")
        // (S4: the Archive tab's nudge list that also read these rows was
        // retired with the Promote Helper; the strip and ranked list remain.)
        #expect(angel.candidateIDs == Set(ids[0...3]), "the catalog filter = Ready + Needs a date + Worth a look")
        #expect(s.ranked == [ids[0], ids[1], ids[2], ids[3]])
        #expect(angel.badge(for: ids[0])?.text == "Promote me")
        #expect(angel.badge(for: ids[2])?.text == "Needs a date")
        #expect(angel.badge(for: ids[3])?.text == "Worth a look")
        #expect(angel.badge(for: ids[4]) == nil && angel.badge(for: ids[5]) == nil)
    }

    @Test("a prepared record leaves its class for Prepared — in the counts, the filter and the badge")
    func preparedOverlay() {
        let a = UUID(), b = UUID(), c = UUID()
        var ready = ArchiveAngelEvidenceRecord(score: 150, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date())
        ready.recommendation = .ready
        let s = ArchiveAngelRecommendationSummary.make(evidence: [a: ready, b: ready], prepared: [a, c], promoted: [],
                                                       revision: 1, live: { _ in "x.mov" })
        #expect(s.count(.ready) == 1 && s.count(.prepared) == 2)
        #expect(s.candidateIDs == [b])
        #expect(s.headline == "1 ready · 0 need a date · 2 prepared")
        #expect(ArchiveAngelCatalogBadge.make(for: ready, prepared: true)?.text == "Prepared")
        let none = ArchiveAngelRecommendationSummary.make(evidence: nil, prepared: [], promoted: [], revision: 1, live: { _ in nil })
        #expect(!none.isAssessed && none.candidateIDs.isEmpty)
    }

    @Test("batch overlay: ready/pending rows are prepared; promoted rows of a buffer batch are promoted; skipped/failed are neither")
    func batchOverlay() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ArchiveAngel")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let promoted = try dec.decode(ArchiveAngelPlan.self, from: Data(contentsOf: fixtures.appendingPathComponent("plan_promoted_with_skips.json")))
        var ready = promoted
        for i in ready.entries.indices { ready.entries[i].status = i == 0 ? .skipped : .ready }
        let o = ArchiveAngelRecommendationSummary.batchOverlay(ready: [ready], buffer: [promoted])
        #expect(o.prepared == Set(ready.entries.dropFirst().map(\.id)))
        let promotedIDs = Set(promoted.entries.filter { $0.status == .promoted }.map(\.id))
        #expect(o.promoted == promotedIDs.subtracting(o.prepared))
        #expect(!o.prepared.contains(ready.entries[0].id))
    }
}

// MARK: - QA on S3 (2026-09-22) — red first

@Suite("Archive Angel S3 QA — safety floors, Extra copy, live guard, regex, schema", .serialized)
@MainActor
struct ArchiveAngelS3QATests {

    private func model() throws -> (VideoScanModel, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-s3qa")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (model, sb.root)
    }

    private func rec(_ score: Int, _ kind: ArchiveAngelRecommendationClass?, year: Int? = nil) -> ArchiveAngelEvidenceRecord {
        var r = ArchiveAngelEvidenceRecord(score: score, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date())
        r.recommendation = kind
        r.year = year
        return r
    }

    private func load(_ json: String) throws -> AngelRecommendationPolicy.Loaded {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("policy.json")
        try Data(json.utf8).write(to: url)
        return AngelRecommendationPolicy.load(overrideURL: url, bundledURL: nil)
    }

    @Test("RED: an override cannot disable or loosen a safety floor")
    func safetyFloorsStay() throws {
        let loaded = try load(#"{"schemaVersion":2,"floors":[{"id":"fileGone","enabled":false},{"id":"onMasterArchive","starExempt":true}]}"#)
        #expect(loaded.source == .builtIn, "the whole file is refused")
        #expect(loaded.notices.first?.contains("safety floor") == true, "\(loaded.notices)")
        let p = loaded.policy
        #expect(ArchiveAngelScorer.hardFloor(.init(archiveStage: .manuallyDeleted), policy: p) == .fileGone)
        #expect(ArchiveAngelScorer.hardFloor(.init(starRating: 3, isOnMasterArchive: true), policy: p) == .alreadyArchived)
        for json in [#"{"schemaVersion":2,"floors":[{"id":"archivedCopy","when":[{"field":"starRating","op":"==","value":0}]}]}"#,
                     #"{"schemaVersion":2,"floors":[{"id":"volumeOffline","explicitPicks":false}]}"#,
                     #"{"schemaVersion":2,"floors":[{"id":"notVideo","kind":"match","when":[{"field":"starRating","op":"<","value":0}]}]}"#] {
            #expect(try load(json).source == .builtIn, "\(json)")
        }
        var rules = AngelRecommendRules.standard
        rules.useAngelFloors = false
        let ev = ArchiveAngelEvidenceRecord(score: 0, lines: [], rejection: .alreadyArchived, useCount: 0, lastUsed: nil, computedAt: Date())
        let v = ArchiveAngelRecommendations.verdict(.init(starRating: 3, captureDate: Date(timeIntervalSince1970: 773_000_000)),
                                                    evidence: ev, rules: rules, now: Date())
        #expect(v.kind == .excluded)
    }

    @Test("RED: the batch never prepares an Extra copy over the Keep copy")
    func prepareHonoursExtraCopy() {
        let g = UUID(), d = Date(timeIntervalSince1970: 773_000_000)
        let keep = ArchiveAngelCandidate(filename: "xmas.mov", fullPath: "/Volumes/RAID/xmas.mov", durationSeconds: 1800, starRating: 3,
                                         volumeRole: .backup, duplicateGroupID: g, captureDate: d, duplicateGroupCount: 2,
                                         duplicateDisposition: .keep)
        let extra = ArchiveAngelCandidate(filename: "xmas.mov", fullPath: "/Volumes/Stray/xmas.mov", durationSeconds: 1800, starRating: 3,
                                          volumeRole: .unassigned, duplicateGroupID: g, captureDate: d, duplicateGroupCount: 2,
                                          duplicateDisposition: .extraCopy)
        let sel = ArchiveAngelScorer.select([keep, extra], count: 1, policy: .builtIn, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(sel.picks.map(\.candidate.id) == [keep.id])
        // A Keep that merely scores lower than a Review copy still wins its group.
        var review = extra
        review.id = UUID()
        review.duplicateDisposition = .review
        let sel2 = ArchiveAngelScorer.select([keep, review], count: 1, policy: .builtIn, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(sel2.picks.map(\.candidate.id) == [keep.id])
    }

    @Test("Prepare follows the classes: a vouched ★★ dated grade-C Ready file goes before an unvouched grade-B Worth a look; Not now / Needs a date are not prepared")
    func prepareByClass() {
        let d = Date(timeIntervalSince1970: 773_000_000), now = Date(timeIntervalSince1970: 1_790_000_000)
        let readyC = ArchiveAngelCandidate(filename: "ready.mov", durationSeconds: 600, starRating: 2, captureDate: d)
        let worthB = ArchiveAngelCandidate(filename: "worth.mov", durationSeconds: 3700, confirmedPeople: ["Donna"],
                                           hasUserNotes: false, userDate: nil, captureDate: nil)
        let notNow = ArchiveAngelCandidate(filename: "weak.mov", durationSeconds: 400, captureDate: d)
        let undatedA = ArchiveAngelCandidate(filename: "undated.mov", durationSeconds: 4000, starRating: 3)
        let all = [worthB, notNow, readyC, undatedA]
        func score(_ c: ArchiveAngelCandidate) -> Int {
            if case .eligible(let s, _) = ArchiveAngelScorer.verdict(c, policy: .builtIn, now: now) { return s }
            return -1
        }
        #expect(score(worthB) >= 60 && score(worthB) < 100, "fixture: B (\(score(worthB)))")
        #expect(score(readyC) < 60, "fixture: C (\(score(readyC)))")
        let sel = ArchiveAngelScorer.select(all, count: 4, policy: .builtIn, now: now, byClass: true)
        #expect(sel.picks.map(\.candidate.filename) == ["ready.mov", "worth.mov"])
        #expect(sel.rejected[.notRecommendedNow] == 2, "Not now + Needs a date")
        var optIn = AngelRecommendationPolicy.builtIn
        optIn.recommend.prepare = ["ready", "needsDate", "worthALook"]
        let sel2 = ArchiveAngelScorer.select(all, count: 4, policy: optIn, now: now, byClass: true)
        #expect(sel2.picks.map(\.candidate.filename) == ["ready.mov", "undated.mov", "worth.mov"])
    }

    @Test("the evidence pick follows the classes too (tier, then score); unclassified evidence comes last")
    func evidencePickByClass() {
        let now = Date()
        let store = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, complete: true, considered: 4, eligible: 4, records: [
            a: rec(40, .ready), b: rec(90, .worthALook), c: rec(160, .needsDate), d: rec(30, nil),
        ]))
        let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 3, now: now) { id in
            ArchiveAngelCandidate(id: id, filename: "\(id).mov", durationSeconds: 600)
        }
        #expect(pick?.selection.picks.map(\.candidate.id) == [a, b, d])
        #expect(pick?.selection.rejected[.notRecommendedNow] == 1)
    }

    @Test("RED: a purged record's stale Ready evidence is not counted or listed")
    func stalePurgedNotRecommended() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let recs = ["a.mov", "b.mov"].map { n -> VideoRecord in let r = VideoRecord(); r.filename = n; r.fullPath = "/Volumes/T/" + n; return r }
        recs[1].purgedAt = Date()
        model.records = recs
        model.archiveAngel.store.replace(with: ArchiveAngelEvidenceFile(records: [recs[0].id: rec(150, .ready, year: 1994),
                                                                                  recs[1].id: rec(150, .ready, year: 1994)]))
        let s = model.archiveAngel.recommendations
        #expect(s.count(.ready) == 1 && !s.candidateIDs.contains(recs[1].id))
        #expect(s.ranked == [recs[0].id], "only the live record is listed")
    }

    @Test("RED: a regex with a repeated group (ReDoS shape) is refused")
    func redosRefused() throws {
        for pattern in [#"^(a+)+$"#, #"^(a|aa)*$"#, #"(x*){2,}"#] {
            let json = #"{"schemaVersion":2,"tables":{"appCacheNamePattern":"# + "\"\(pattern.replacingOccurrences(of: "\\", with: "\\\\"))\"}}"
            let loaded = try load(json)
            #expect(loaded.source == .builtIn, "\(pattern)")
            #expect(loaded.notices.first?.contains("appCacheNamePattern") == true, "\(loaded.notices)")
        }
    }

    @Test("RED: schemaVersion must be an integer (true / 2.0 / \"2\" are refused)")
    func schemaVersionInteger() throws {
        for v in ["true", "2.0", "\"2\""] {
            #expect(try load(#"{"schemaVersion":"# + v + "}").source == .builtIn, "schemaVersion \(v)")
        }
        #expect(try load(#"{"schemaVersion":2}"#).source == .userOverride)
    }
}
