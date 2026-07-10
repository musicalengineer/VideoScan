import Foundation

// MARK: - pfIdentityCandidates
//
// Given an inferred video date + VLM scene descriptions + per-person
// identity priors (birthdate, deathdate, sex, hair color, eye color),
// produces a ranked plausibility for each person in the family. The
// point: eliminate impossible candidates (Matt born 1994 cannot be in
// a 1991 video) and rank the rest by how well the scene description's
// cues fit each person.
//
// Sits AFTER pfInferRecordDate in the pipeline:
//   record date  +  scene descriptions  +  identity priors
//        ↓
//   [(person, plausibility, reason), ...]
//
// Signals, in doctrine order (Rick's rule: imperfect-but-useful beats
// no-answer; output is for ranking display, not autonomous decision):
//
//   1. Birth/death impossibility — the ONLY thing that produces 0.0.
//      Born after the video date, or deceased before it ⇒ impossible.
//   2. Age-bucket fit — "baby", "teenager", "a boy of about 8" cues
//      vs the person's age at the video date. Sets the base score.
//   3. Sex cues — "woman/man/boy/girl/she/he/grandmother…". A clear
//      mismatch (scene mentions ONLY the other sex) demotes strongly
//      (× 0.3) but never to 0.0 — VLMs are wrong sometimes. Note that
//      "boy"/"girl" feed BOTH this signal and the age buckets.
//   4. Hair/eye color cues — "a blonde woman", "red-haired child".
//      BOOST on match only. A mismatch must NEVER penalize: hair color
//      changes across decades (gold in 1979, gray in 2010) and
//      B&W/faded footage lies about color entirely.
//
// Marquee scenario: a ~1994 video whose scene description says "a boy"
// must rank Rick's son (b.1983, age 11 — child bucket fit + male) above
// Donna (b.1959, age 35 — no bucket fit, sex mismatch), even when their
// face embeddings are similar.

struct IdentityCandidate: Equatable {
    let name: String
    /// 0.0 = impossible (born after / died before video date) — nothing
    ///       else can zero a candidate out.
    /// 0.5 = possible but no confirmation from the description
    /// 1.0 = description cues match this person very well
    let plausibility: Float
    /// Approximate age at the video date in years (negative if
    /// born after; nil if birthdate unknown).
    let ageAtVideo: Int?
    /// Human-readable explanation surfaced in the UI tooltip.
    let reason: String
}

/// Per-person identity prior fed to `pfIdentityCandidates`. One small
/// struct per person instead of parallel name-keyed dictionaries.
/// Everything optional — nil fields simply contribute no signal.
struct IdentityPrior: Equatable {
    var name: String
    var birthdate: Date?
    var deathdate: Date?
    var sex: PersonSex?
    var hairColor: HairColor?
    var eyeColor: EyeColor?

    /// True when at least one field can influence a score — callers can
    /// skip the whole narrowing pass for profiles with nothing set.
    var hasAnySignal: Bool {
        birthdate != nil || deathdate != nil || sex != nil
            || hairColor != nil || eyeColor != nil
    }
}

extension IdentityPrior {
    /// Lift the priors off a saved POI profile.
    init(profile: POIProfile) {
        self.init(
            name: profile.name,
            birthdate: profile.birthdate,
            deathdate: profile.deathdate,
            sex: profile.sex,
            hairColor: profile.hairColor,
            eyeColor: profile.eyeColor
        )
    }
}

// Demote factor for a clear sex mismatch. Strong, but deliberately not
// 0 — only birth/death impossibility may eliminate.
private let sexMismatchFactor: Float = 0.3
// Boost-on-match increments (additive, capped at 1.0).
private let hairMatchBoost: Float = 0.15
private let eyeMatchBoost: Float = 0.10

/// Rank candidates for being in a video at `recordDate` given their
/// identity priors and the VLM scene descriptions.
nonisolated func pfIdentityCandidates(
    recordDate: Date,
    sceneDescriptions: [String],
    priors: [IdentityPrior]
) -> [IdentityCandidate] {

    let cues = pfExtractSceneCues(from: sceneDescriptions)

    var results: [IdentityCandidate] = []
    for prior in priors {
        results.append(pfScoreCandidate(
            prior: prior, recordDate: recordDate, cues: cues
        ))
    }

    // Rank: highest plausibility first; tie-break alphabetically.
    return results.sorted {
        if $0.plausibility != $1.plausibility { return $0.plausibility > $1.plausibility }
        return $0.name < $1.name
    }
}

/// Back-compat convenience: the original dictionary-shaped signature,
/// still used by tests and any callers that only have birthdates.
/// Delegates to the prior-struct core.
nonisolated func pfIdentityCandidates(
    recordDate: Date,
    sceneDescriptions: [String],
    familyBirthdates: [String: Date],
    familyDeathdates: [String: Date] = [:]
) -> [IdentityCandidate] {
    let priors = familyBirthdates.map { name, birth in
        IdentityPrior(name: name, birthdate: birth, deathdate: familyDeathdates[name])
    }
    return pfIdentityCandidates(
        recordDate: recordDate,
        sceneDescriptions: sceneDescriptions,
        priors: priors
    )
}

/// Score one person against the extracted scene cues. Pure.
private nonisolated func pfScoreCandidate(
    prior: IdentityPrior,
    recordDate: Date,
    cues: SceneIdentityCues
) -> IdentityCandidate {
    let cal = Calendar(identifier: .gregorian)
    let age: Int? = prior.birthdate.map {
        cal.dateComponents([.year], from: $0, to: recordDate).year ?? -1
    }

    // 1. Hard cutoffs — the ONLY producers of 0.0.
    if let age, age < 0, let birth = prior.birthdate {
        return IdentityCandidate(
            name: prior.name, plausibility: 0.0, ageAtVideo: age,
            reason: "born \(yearOf(birth)) — after video date \(yearOf(recordDate))"
        )
    }
    if let death = prior.deathdate, death < recordDate {
        return IdentityCandidate(
            name: prior.name, plausibility: 0.0, ageAtVideo: age,
            reason: "deceased \(yearOf(death)) — before video date \(yearOf(recordDate))"
        )
    }

    // 2. Base score from age-bucket fit.
    var score: Float
    var reasons: [String] = []
    if let age, !cues.ageBuckets.isEmpty {
        var bestMatch: Float = 0.0
        var bestReason = ""
        for bucket in cues.ageBuckets {
            let fit = bucket.fit(age: age)
            if fit > bestMatch {
                bestMatch = fit
                bestReason = "age \(age) matches '\(bucket.label)' (\(bucket.minAge)–\(bucket.maxAge))"
            }
        }
        if bestMatch == 0.0 {
            score = 0.25
            reasons.append("age \(age) doesn't match any scene-described age range")
        } else {
            score = bestMatch
            reasons.append(bestReason)
        }
    } else if let age {
        score = 0.5
        reasons.append("age \(age) at video date — no age cues from description")
    } else {
        score = 0.5
        reasons.append("birthdate not set — no age check")
    }

    // 3. Sex cue — demote on a CLEAR mismatch (scene mentions only the
    //    other sex), never on ambiguity ("a man and a woman" penalizes
    //    no one). Never zeroes out — VLMs misread sex sometimes.
    if let sex = prior.sex, !cues.sexes.isEmpty {
        if cues.sexes.contains(sex) {
            reasons.append("scene mentions \(sex == .female ? "a female" : "a male")")
        } else {
            score *= sexMismatchFactor
            let other = sex == .female ? "male" : "female"
            reasons.append("scene mentions only \(other) people — demoted (\(prior.name) is \(sex.rawValue))")
        }
    }

    // 4. Hair/eye color — boost on match ONLY. No mismatch penalty, ever.
    //
    // DOCTRINE — ordering is deliberate: color boosts apply AFTER the sex
    // demote (step 3) and are ADDITIVE, so a hair+eye match can lift a
    // sex-mismatched candidate from 0.15 back up to 0.40. That's intended,
    // not a bug: evidence is evidence — a demote records doubt, it doesn't
    // veto, and corroborating physical cues should be able to buy back
    // standing (VLMs misread sex more often than they misread hair color).
    // If the boosts moved BEFORE the demote they'd be multiplied by 0.3
    // and could never meaningfully rehabilitate a candidate.
    if let hair = prior.hairColor, cues.hairColors.contains(hair) {
        score = min(1.0, score + hairMatchBoost)
        reasons.append("scene mentions \(hair.rawValue) hair — matches")
    }
    if let eye = prior.eyeColor, cues.eyeColors.contains(eye) {
        score = min(1.0, score + eyeMatchBoost)
        reasons.append("scene mentions \(eye.rawValue) eyes — matches")
    }

    return IdentityCandidate(
        name: prior.name,
        plausibility: score,
        ageAtVideo: age,
        reason: reasons.joined(separator: "; ")
    )
}

// MARK: - Scene cue extraction

/// Everything the narrowing pass can read out of a set of VLM scene
/// descriptions: age buckets, mentioned sexes, hair colors, eye colors.
struct SceneIdentityCues: Equatable {
    var ageBuckets: [AgeBucket] = []
    var sexes: Set<PersonSex> = []
    var hairColors: Set<HairColor> = []
    var eyeColors: Set<EyeColor> = []
}

/// A coarse age bucket extracted from a VLM scene description.
struct AgeBucket: Equatable {
    let label: String
    let minAge: Int
    let maxAge: Int

    /// Smooth fit score 0.0–1.0. 1.0 = age is well inside the range,
    /// 0.0 = age is far outside. Linear falloff with a 2-year edge.
    func fit(age: Int) -> Float {
        if age >= minAge && age <= maxAge { return 1.0 }
        let dist = max(minAge - age, age - maxAge)
        if dist <= 2 { return 0.6 }
        if dist <= 4 { return 0.3 }
        return 0.0
    }
}

/// One-stop extraction of all identity cues. Word tokens (not raw
/// substrings) are used for the sex vocabulary — a naive
/// `contains("man")` would match "woman", and `contains("he")` would
/// match half the dictionary.
nonisolated func pfExtractSceneCues(from descriptions: [String]) -> SceneIdentityCues {
    var cues = SceneIdentityCues()
    cues.ageBuckets = pfExtractAgeBuckets(from: descriptions)

    let lowered = descriptions.joined(separator: " ").lowercased()
    let tokens = pfWordTokens(lowered)

    // Sex vocabulary. Relationship words carry sex too ("grandmother"
    // already feeds the elderly age bucket via pfExtractAgeBuckets —
    // here it additionally counts as a female mention).
    let femaleTokens: Set<String> = [
        "woman", "women", "lady", "ladies", "girl", "girls",
        "she", "her", "hers", "herself",
        "mother", "mom", "mommy", "grandmother", "grandma",
        "wife", "daughter", "sister", "aunt", "bride"
    ]
    let maleTokens: Set<String> = [
        "man", "men", "gentleman", "gentlemen", "boy", "boys",
        "he", "him", "his", "himself",
        "father", "dad", "daddy", "grandfather", "grandpa",
        "husband", "son", "brother", "uncle", "groom"
    ]
    if !tokens.isDisjoint(with: femaleTokens) { cues.sexes.insert(.female) }
    if !tokens.isDisjoint(with: maleTokens) { cues.sexes.insert(.male) }

    // Hair color. Unambiguous single words first, then "<color> hair" /
    // "<color>-haired" phrases so a brown dog or a white wall can't
    // masquerade as a hair color.
    if tokens.contains("blonde") || tokens.contains("blond") { cues.hairColors.insert(.blonde) }
    if tokens.contains("brunette") { cues.hairColors.insert(.brown) }
    if tokens.contains("redhead") || tokens.contains("redheaded") || tokens.contains("ginger") {
        cues.hairColors.insert(.red)
    }
    if tokens.contains("bald") || tokens.contains("balding") { cues.hairColors.insert(.bald) }
    let hairPhrases: [(String, HairColor)] = [
        ("brown", .brown), ("black", .black), ("red", .red),
        ("gray", .gray), ("grey", .gray), ("silver", .gray),
        ("white", .white), ("blonde", .blonde), ("blond", .blonde)
    ]
    for (word, color) in hairPhrases {
        if lowered.contains("\(word) hair") || lowered.contains("\(word)-haired")
            || lowered.contains("\(word) haired") {
            cues.hairColors.insert(color)
        }
    }

    // Eye color — phrase-gated for the same reason as hair.
    let eyePhrases: [(String, EyeColor)] = [
        ("blue", .blue), ("brown", .brown), ("green", .green),
        ("hazel", .hazel), ("gray", .gray), ("grey", .gray)
    ]
    for (word, color) in eyePhrases {
        if lowered.contains("\(word) eyes") || lowered.contains("\(word)-eyed")
            || lowered.contains("\(word) eyed") {
            cues.eyeColors.insert(color)
        }
    }

    return cues
}

/// Scan a list of scene descriptions for age-bucket keywords. Returns
/// the union of buckets implied (a clip may have both "a child" and
/// "an adult" if it shows multiple people across frames).
nonisolated func pfExtractAgeBuckets(from descriptions: [String]) -> [AgeBucket] {
    let lowered = descriptions.joined(separator: " ").lowercased()
    let tokens = pfWordTokens(lowered)
    var buckets: [AgeBucket] = []
    // Order roughly youngest → oldest. Multiple matches accumulate
    // because a clip can legitimately span ages (a parent holding a
    // baby).
    if lowered.contains("baby") || lowered.contains("infant") {
        buckets.append(AgeBucket(label: "baby", minAge: 0, maxAge: 2))
    }
    if lowered.contains("toddler") {
        buckets.append(AgeBucket(label: "toddler", minAge: 1, maxAge: 3))
    }
    if lowered.contains("young child") || lowered.contains("small child") {
        buckets.append(AgeBucket(label: "young child", minAge: 3, maxAge: 7))
    }
    if lowered.contains("child") && !lowered.contains("young child")
        && !lowered.contains("small child") {
        buckets.append(AgeBucket(label: "child", minAge: 3, maxAge: 12))
    }
    // "boy"/"girl" imply BOTH a sex (handled in pfExtractSceneCues) and
    // a child-age bucket. Token match, not substring — "cowboy" is not
    // a child. Range is wider than "child": VLMs call a 14-year-old
    // "a boy" without blinking.
    if !tokens.isDisjoint(with: ["boy", "boys", "girl", "girls"]) {
        buckets.append(AgeBucket(label: "boy/girl", minAge: 2, maxAge: 14))
    }
    if lowered.contains("teen") || lowered.contains("teenager")
        || lowered.contains("adolescent") {
        buckets.append(AgeBucket(label: "teenager", minAge: 13, maxAge: 19))
    }
    if lowered.contains("young adult") || lowered.contains("young man")
        || lowered.contains("young woman") {
        buckets.append(AgeBucket(label: "young adult", minAge: 18, maxAge: 30))
    }
    if lowered.contains("adult") && !lowered.contains("young adult") {
        buckets.append(AgeBucket(label: "adult", minAge: 20, maxAge: 65))
    }
    // Bare "man"/"woman" ⇒ grown-up. Deliberately wide (a "man" can be
    // 16 or 96) — its job is to keep babies from ranking high when the
    // scene only shows adults, not to pin an age. Token match: the
    // substring "man" lives inside "woman".
    if !tokens.isDisjoint(with: ["man", "men", "woman", "women", "lady", "ladies",
                                 "gentleman", "gentlemen"]) {
        buckets.append(AgeBucket(label: "grown-up", minAge: 16, maxAge: 110))
    }
    if lowered.contains("elderly") || lowered.contains("grandparent")
        || lowered.contains("grandmother") || lowered.contains("grandfather")
        || lowered.contains("senior") {
        buckets.append(AgeBucket(label: "elderly", minAge: 60, maxAge: 110))
    }
    return buckets
}

// MARK: - Helpers

/// Split lowercased text into a set of word tokens (letters only).
/// ≈ C++: tokenize on ispunct/isspace into an unordered_set<string>.
private nonisolated func pfWordTokens(_ lowered: String) -> Set<String> {
    Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
}

private func yearOf(_ d: Date) -> Int {
    Calendar(identifier: .gregorian).component(.year, from: d)
}
