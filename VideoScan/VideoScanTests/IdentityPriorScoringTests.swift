// IdentityPriorScoringTests.swift
// LOGIC + SENSOR dimensions for the POI identity-metadata feature
// (feature-test checklist items 1 & 5).
//
// Covers the new IdentityPrior-struct signature of pfIdentityCandidates
// (IdentityNarrowing.swift). Scoring doctrine under test:
//   • ONLY birth/death impossibility produces 0.0
//   • age-bucket fit sets the base (0.25 floor on no-fit, 0.5 neutral)
//   • clear sex mismatch demotes ×0.3 — strong, never eliminating
//   • sex cues are WORD tokens ("woman" must not read as "man";
//     "boy"/"girl" feed both a sex and a child age bucket)
//   • hair (+0.15) / eye (+0.10) BOOST on match only, capped at 1.0;
//     a color mismatch must never penalize
//
// The old dictionary-signature tests live in IdentityNarrowingTests.swift
// and still exercise the back-compat wrapper.
//
// C++ readers: `#expect(...)` ≈ gtest's EXPECT_* — non-fatal, the test
// keeps running and reports every failed expectation.

import Testing
import Foundation
@testable import VideoScan

struct IdentityPriorScoringTests {

    // Same helper shape as IdentityNarrowingTests — noon UTC avoids
    // day-boundary flake in year arithmetic.
    private func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private func score(
        _ scene: String, prior: IdentityPrior, at recordDate: Date
    ) -> IdentityCandidate? {
        pfIdentityCandidates(
            recordDate: recordDate,
            sceneDescriptions: [scene],
            priors: [prior]
        ).first
    }

    // Float tolerance — the boost sums (0.5 + 0.15) land on a
    // representability tie, so exact == is fragile there.
    private func near(_ a: Float?, _ b: Float) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.0001
    }

    // MARK: - Sex demote doctrine

    @Test func sexClearMismatchDemotesByFactorNeverToZero() {
        // Scene mentions ONLY a woman; the candidate is male, age fits
        // the grown-up bucket (base 1.0) → 1.0 × 0.3 = 0.3, not 0.0.
        let c = score(
            "a woman in the garden",
            prior: IdentityPrior(name: "Rick", birthdate: date(1959), sex: .male),
            at: date(1994)
        )
        #expect(near(c?.plausibility, 0.3),
                "clear sex mismatch must demote ×0.3, got \(c?.plausibility ?? -1)")
        #expect((c?.plausibility ?? 0) > 0.0,
                "only birth/death impossibility may produce 0.0")
        #expect(c?.reason.contains("demoted") == true)
    }

    @Test func ambiguousSceneWithBothSexesPenalizesNoOne() {
        // "a man and a woman" — both sexes present ⇒ neither candidate
        // is a *clear* mismatch, so nobody gets the ×0.3.
        let recordDate = date(1994)
        let results = pfIdentityCandidates(
            recordDate: recordDate,
            sceneDescriptions: ["a man and a woman at the kitchen table"],
            priors: [
                IdentityPrior(name: "Donna", birthdate: date(1959), sex: .female),
                IdentityPrior(name: "Rick", birthdate: date(1958), sex: .male)
            ]
        )
        for c in results {
            #expect(c.plausibility == 1.0,
                    "\(c.name) should not be demoted by an ambiguous scene, got \(c.plausibility)")
        }
    }

    // MARK: - Word-token boundaries

    @Test func womanTokenDoesNotReadAsMan() {
        // A naive substring scan finds "man" inside "woman". Cue
        // extraction must be word-token based.
        let cues = pfExtractSceneCues(from: ["a woman waves at the camera"])
        #expect(cues.sexes == [.female],
                "'woman' must register female ONLY, got \(cues.sexes)")
    }

    @Test func grandmotherImpliesFemaleAndElderly() {
        let cues = pfExtractSceneCues(from: ["the grandmother smiled from her chair"])
        #expect(cues.sexes.contains(.female))
        #expect(cues.ageBuckets.contains { $0.label == "elderly" })

        // And it scores accordingly: elderly female = 1.0, an
        // age-matched male gets the sex demote (0.3), never 0.
        let recordDate = date(1994)
        let results = pfIdentityCandidates(
            recordDate: recordDate,
            sceneDescriptions: ["the grandmother smiled from her chair"],
            priors: [
                IdentityPrior(name: "Eileen", birthdate: date(1930), sex: .female),
                IdentityPrior(name: "Frank", birthdate: date(1930), sex: .male)
            ]
        )
        let eileen = results.first { $0.name == "Eileen" }
        let frank = results.first { $0.name == "Frank" }
        #expect(eileen?.plausibility == 1.0)
        #expect(near(frank?.plausibility, 0.3))
    }

    @Test func boyFeedsBothMaleSexAndChildBucket() {
        let cues = pfExtractSceneCues(from: ["a boy on a bicycle"])
        #expect(cues.sexes == [.male])
        #expect(cues.ageBuckets.contains { $0.label == "boy/girl" })
    }

    @Test func girlFeedsBothFemaleSexAndChildBucket() {
        let cues = pfExtractSceneCues(from: ["a girl blowing out candles"])
        #expect(cues.sexes == [.female])
        #expect(cues.ageBuckets.contains { $0.label == "boy/girl" })
    }

    @Test func cowboyIsNeitherABoyNorAMale() {
        // Token boundary again: the substring "boy" lives inside
        // "cowboy", but a cowboy hat is not a child.
        let cues = pfExtractSceneCues(from: ["a cowboy hat rests on the shelf"])
        #expect(cues.sexes.isEmpty)
        #expect(!cues.ageBuckets.contains { $0.label == "boy/girl" })
    }

    // MARK: - Hair/eye boosts (match-only, capped, never penalizing)

    @Test func hairColorMatchBoostsNeutralBase() {
        // Scene has a hair cue but no age/sex words → base 0.5, +0.15.
        let c = score(
            "blonde hair shining in the sunlight",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .blonde),
            at: date(1994)
        )
        #expect(near(c?.plausibility, 0.65),
                "hair match should boost 0.5 → 0.65, got \(c?.plausibility ?? -1)")
        #expect(c?.reason.contains("hair") == true)
    }

    @Test func eyeColorMatchBoostsNeutralBase() {
        let c = score(
            "blue eyes catching the light",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), eyeColor: .blue),
            at: date(1994)
        )
        #expect(near(c?.plausibility, 0.6),
                "eye match should boost 0.5 → 0.6, got \(c?.plausibility ?? -1)")
        #expect(c?.reason.contains("eyes") == true)
    }

    @Test func boostsAreCappedAtOne() {
        // Perfect age fit (grown-up, base 1.0) + hair AND eye matches
        // must clamp at 1.0, never 1.25.
        let c = score(
            "a blonde woman with blue eyes",
            prior: IdentityPrior(
                name: "Donna", birthdate: date(1959),
                sex: .female, hairColor: .blonde, eyeColor: .blue
            ),
            at: date(1994)
        )
        #expect(c?.plausibility == 1.0,
                "score must cap at 1.0, got \(c?.plausibility ?? -1)")
    }

    @Test func hairColorMismatchNeverPenalizes() {
        // Doctrine: hair changes across decades and B&W footage lies.
        // A candidate whose stored hair color contradicts the scene must
        // score EXACTLY the same as one with no hair prior at all.
        let recordDate = date(1994)
        let scene = ["a blonde woman near the window"]
        let without = pfIdentityCandidates(
            recordDate: recordDate, sceneDescriptions: scene,
            priors: [IdentityPrior(name: "Donna", birthdate: date(1959))]
        ).first
        let withWrongHair = pfIdentityCandidates(
            recordDate: recordDate, sceneDescriptions: scene,
            priors: [IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .black)]
        ).first
        #expect(without?.plausibility == withWrongHair?.plausibility,
                "hair mismatch penalized: \(without?.plausibility ?? -1) vs \(withWrongHair?.plausibility ?? -1)")
    }

    @Test func eyeColorMismatchNeverPenalizes() {
        let recordDate = date(1994)
        let scene = ["a woman with blue eyes"]
        let without = pfIdentityCandidates(
            recordDate: recordDate, sceneDescriptions: scene,
            priors: [IdentityPrior(name: "Donna", birthdate: date(1959))]
        ).first
        let withWrongEyes = pfIdentityCandidates(
            recordDate: recordDate, sceneDescriptions: scene,
            priors: [IdentityPrior(name: "Donna", birthdate: date(1959), eyeColor: .brown)]
        ).first
        #expect(without?.plausibility == withWrongEyes?.plausibility,
                "eye mismatch penalized: \(without?.plausibility ?? -1) vs \(withWrongEyes?.plausibility ?? -1)")
    }

    // MARK: - Phrase adjacency (pins pfScanWords word-pair semantics)
    //
    // Doctrine: a color word and "hair"/"haired"/"eyes"/"eyed" pair up
    // ONLY when joined by spaces and/or hyphens. Any other punctuation
    // between them breaks adjacency, and the second word must be exact —
    // longer words sharing the prefix ("hairstyle", "eyeshadow") never
    // count. All boost-only assertions on the neutral 0.5 base, same
    // shape as the color tests above.
    //
    // Record-keeping: commit c0dab76's message claimed "brown, hair" now
    // matches — it does not, and never did; the comma-breaks test below
    // pins the code's actual (correct) behavior.

    @Test func hyphenatedHairFormBoosts() {
        // "brown-haired" — hyphen bridges the pair exactly like a space.
        let c = score(
            "a brown-haired figure waving from the porch",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .brown),
            at: date(1994)
        )
        #expect(near(c?.plausibility, 0.65),
                "'brown-haired' must boost 0.5 → 0.65, got \(c?.plausibility ?? -1)")
        #expect(c?.reason.contains("hair") == true)
    }

    @Test func hyphenatedEyeFormBoosts() {
        let c = score(
            "blue-eyed and smiling at the camera",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), eyeColor: .blue),
            at: date(1994)
        )
        #expect(near(c?.plausibility, 0.6),
                "'blue-eyed' must boost 0.5 → 0.6, got \(c?.plausibility ?? -1)")
        #expect(c?.reason.contains("eyes") == true)
    }

    @Test func doubleSpaceStillBridgesColorAdjacency() {
        // Two spaces between "brown" and "hair" (VLM output is not
        // whitespace-tidy) — a separator RUN of spaces/hyphens bridges.
        let c = score(
            "brown  hair blowing in the wind",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .brown),
            at: date(1994)
        )
        #expect(near(c?.plausibility, 0.65),
                "double-spaced 'brown  hair' must still boost, got \(c?.plausibility ?? -1)")
    }

    @Test func commaBreaksColorAdjacency() {
        // "brown, hair" — a brown *something* and then hair as a new
        // clause, NOT brown hair. Neutral base, no boost.
        let c = score(
            "the dog was brown, hair covered the couch",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .brown),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.5,
                "'brown, hair' must NOT boost — comma breaks adjacency, got \(c?.plausibility ?? -1)")
    }

    @Test func periodBreaksColorAdjacency() {
        // Sentence boundary between the color and "hair" — same rule as
        // the comma; mirrors the original substring-scan semantics.
        let c = score(
            "the fence was painted brown. hair clips lay on the bench",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .brown),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.5,
                "'brown. hair' must NOT boost — period breaks adjacency, got \(c?.plausibility ?? -1)")
    }

    @Test func hairstyleSuffixDoesNotCountAsHair() {
        // Suffix exactness: "hairstyle" is not "hair". The pre-c0dab76
        // substring scan wrongly matched this ("brown hair" lives inside
        // "brown hairstyle"); the word-pair scan must not.
        let c = score(
            "a stylish brown hairstyle from the salon",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), hairColor: .brown),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.5,
                "'brown hairstyle' must NOT boost — suffix must be exact, got \(c?.plausibility ?? -1)")
    }

    @Test func eyeshadowSuffixDoesNotCountAsEyes() {
        // Same correction on the eye side: "blue eyeshadow" is makeup on
        // a counter, not an eye color.
        let c = score(
            "shimmering blue eyeshadow on the counter",
            prior: IdentityPrior(name: "Donna", birthdate: date(1959), eyeColor: .blue),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.5,
                "'blue eyeshadow' must NOT boost — suffix must be exact, got \(c?.plausibility ?? -1)")
    }

    // MARK: - Neutral / impossible paths via the prior signature

    @Test func noBirthdateScoresNeutral() {
        // Sex prior set but no birthdate, scene has no cues at all →
        // neutral 0.5 with an explanatory reason.
        let c = score(
            "a dark hallway",
            prior: IdentityPrior(name: "Mystery", sex: .female),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.5)
        #expect(c?.ageAtVideo == nil)
    }

    @Test func deathdateBeforeVideoIsImpossibleViaPriors() {
        let c = score(
            "a woman holding flowers",
            prior: IdentityPrior(
                name: "Eileen", birthdate: date(1935),
                deathdate: date(1990), sex: .female
            ),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.0)
        #expect(c?.reason.contains("deceased") == true)
    }

    @Test func bornAfterVideoIsImpossibleViaPriors() {
        let c = score(
            "a baby in a crib",
            prior: IdentityPrior(name: "Matt", birthdate: date(1996), sex: .male),
            at: date(1994)
        )
        #expect(c?.plausibility == 0.0)
        #expect(c?.reason.contains("after") == true)
    }

    // MARK: - Reason strings

    @Test func reasonStringIsNonEmptyOnEveryScoringPath() {
        let recordDate = date(1994)
        // One scenario per distinct code path in pfScoreCandidate.
        let scenarios: [(label: String, prior: IdentityPrior, scene: String)] = [
            ("born after video", IdentityPrior(name: "P", birthdate: date(2000)), "a boy"),
            ("deceased before video", IdentityPrior(name: "P", birthdate: date(1900), deathdate: date(1980)), "a man"),
            ("age-bucket match", IdentityPrior(name: "P", birthdate: date(1983)), "a boy"),
            ("age-bucket no-fit", IdentityPrior(name: "P", birthdate: date(1959)), "a boy"),
            ("no age cues", IdentityPrior(name: "P", birthdate: date(1959)), "a dark room"),
            ("no birthdate", IdentityPrior(name: "P", sex: .female), "a dark room"),
            ("sex match", IdentityPrior(name: "P", birthdate: date(1959), sex: .female), "a woman"),
            ("sex mismatch", IdentityPrior(name: "P", birthdate: date(1959), sex: .male), "a woman"),
            ("hair boost", IdentityPrior(name: "P", birthdate: date(1959), hairColor: .blonde), "blonde hair"),
            ("eye boost", IdentityPrior(name: "P", birthdate: date(1959), eyeColor: .blue), "blue eyes")
        ]
        for s in scenarios {
            let c = score(s.scene, prior: s.prior, at: recordDate)
            #expect(c?.reason.isEmpty == false,
                    "empty reason string on path: \(s.label)")
        }
    }

    // MARK: - IdentityPrior plumbing

    @Test func hasAnySignalReflectsSetFields() {
        #expect(!IdentityPrior(name: "Empty").hasAnySignal)
        #expect(IdentityPrior(name: "B", birthdate: date(1959)).hasAnySignal)
        #expect(IdentityPrior(name: "S", sex: .male).hasAnySignal)
        #expect(IdentityPrior(name: "H", hairColor: .gray).hasAnySignal)
        #expect(IdentityPrior(name: "E", eyeColor: .hazel).hasAnySignal)
        #expect(IdentityPrior(name: "D", deathdate: date(2000)).hasAnySignal)
    }

    @Test func priorLiftsAllIdentityFieldsOffProfile() {
        let profile = POIProfile(
            name: "Donna", referencePath: "/tmp/ref",
            birthdate: date(1959), deathdate: nil,
            sex: .female, hairColor: .blonde, eyeColor: .blue,
            identityNotes: "always wore glasses"
        )
        let prior = IdentityPrior(profile: profile)
        #expect(prior.name == "Donna")
        #expect(prior.birthdate == profile.birthdate)
        #expect(prior.sex == .female)
        #expect(prior.hairColor == .blonde)
        #expect(prior.eyeColor == .blue)
    }
}

// MARK: - Regression sensor (feature-test checklist item 5)

struct IdentityNarrowingRegressionSensors {

    private func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    /// THE marquee scenario this feature exists for, pinned end to end:
    /// a 1994 video whose VLM caption says "a boy" must rank Rick's son
    /// (b.1983 — child-bucket fit + male) strictly above Donna (b.1959 —
    /// no bucket fit AND sex mismatch), even when face embeddings tie.
    /// If any future scoring tweak breaks this ordering or lets Donna
    /// climb above 0.1 here, the feature has regressed — do NOT loosen
    /// these bounds to make the test pass.
    @Test func donnaVsSonMarqueeScenario_regressionSensor() {
        let results = pfIdentityCandidates(
            recordDate: date(1994),
            sceneDescriptions: ["a boy"],
            priors: [
                IdentityPrior(name: "Donna", birthdate: date(1959), sex: .female),
                IdentityPrior(name: "Son", birthdate: date(1983), sex: .male)
            ]
        )
        #expect(results.count == 2)
        let son = results.first { $0.name == "Son" }
        let donna = results.first { $0.name == "Donna" }

        // Son: age 11 → boy/girl bucket (2–14) fit 1.0, sex match.
        #expect(results.first?.name == "Son", "son must rank first")
        #expect(son?.plausibility == 1.0)

        // Donna: age 35 → 0.25 no-fit floor × 0.3 sex demote = 0.075.
        #expect((donna?.plausibility ?? 1) <= 0.1,
                "Donna must be strongly demoted, got \(donna?.plausibility ?? -1)")
        #expect((donna?.plausibility ?? 0) > 0.0,
                "Donna is demoted, NOT eliminated — only birth/death may zero")
        #expect((son?.plausibility ?? 0) > (donna?.plausibility ?? 1),
                "ordering must be strict, not a tie")

        // The reason must explain BOTH demotions to the user.
        #expect(donna?.reason.contains("doesn't match any scene-described age range") == true,
                "reason must mention the age demotion, got: \(donna?.reason ?? "nil")")
        #expect(donna?.reason.contains("demoted") == true,
                "reason must mention the sex demotion, got: \(donna?.reason ?? "nil")")
    }
}
