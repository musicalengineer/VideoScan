import Foundation

// MARK: - pfIdentityCandidates
//
// Given an inferred video date + VLM scene descriptions + the family
// birthdate priors, produces a ranked plausibility for each person in
// the family. The point: eliminate impossible candidates (Matt born
// 1994 cannot be in a 1991 video) and rank by age-fit when the scene
// description mentions an age range ("baby ~1yr").
//
// Sits AFTER pfInferRecordDate in the pipeline:
//   record date  +  scene descriptions  +  family priors
//        ↓
//   [(person, plausibility, reason), ...]
//
// Probabilistic — Rick has explicitly said imperfect-but-useful beats
// no-answer. Output is for ranking display, not autonomous decision.

struct IdentityCandidate: Equatable {
    let name: String
    /// 0.0 = impossible (born after / died before video date)
    /// 0.5 = possible but no age confirmation from description
    /// 1.0 = age estimate perfectly matches description hints
    let plausibility: Float
    /// Approximate age at the video date in years (negative if
    /// born after; nil if birthdate unknown).
    let ageAtVideo: Int?
    /// Human-readable explanation surfaced in the UI tooltip.
    let reason: String
}

/// Rank family-prior candidates for being in a video at `recordDate`.
/// `familyBirthdates` is name → birthdate; `familyDeathdates` is
/// optional death date for filtering memorial-era cutoffs.
/// `sceneDescriptions` are the VLM scene-prompt outputs — searched
/// for age-bucket cues ("baby", "child", "teenager", "adult",
/// "elderly", "boy of about 8").
nonisolated func pfIdentityCandidates(
    recordDate: Date,
    sceneDescriptions: [String],
    familyBirthdates: [String: Date],
    familyDeathdates: [String: Date] = [:]
) -> [IdentityCandidate] {

    let ageBuckets = pfExtractAgeBuckets(from: sceneDescriptions)

    var results: [IdentityCandidate] = []
    for (name, birthdate) in familyBirthdates {
        let cal = Calendar(identifier: .gregorian)
        let age = cal.dateComponents([.year], from: birthdate, to: recordDate).year ?? -1

        // Cutoffs that make the person impossible.
        if age < 0 {
            results.append(IdentityCandidate(
                name: name, plausibility: 0.0, ageAtVideo: age,
                reason: "born \(yearOf(birthdate)) — after video date \(yearOf(recordDate))"
            ))
            continue
        }
        if let death = familyDeathdates[name], death < recordDate {
            results.append(IdentityCandidate(
                name: name, plausibility: 0.0, ageAtVideo: age,
                reason: "deceased \(yearOf(death)) — before video date \(yearOf(recordDate))"
            ))
            continue
        }

        // If we have no age hints from the description, just say
        // "possible at age X."
        guard !ageBuckets.isEmpty else {
            results.append(IdentityCandidate(
                name: name, plausibility: 0.5, ageAtVideo: age,
                reason: "age \(age) at video date — no age cues from description"
            ))
            continue
        }

        // Compute the best-matching bucket.
        var bestMatch: Float = 0.0
        var bestReason = ""
        for bucket in ageBuckets {
            let fit = bucket.fit(age: age)
            if fit > bestMatch {
                bestMatch = fit
                bestReason = "age \(age) matches '\(bucket.label)' (\(bucket.minAge)–\(bucket.maxAge))"
            }
        }
        if bestMatch == 0.0 {
            // No bucket matched well; still possible but low ranking
            results.append(IdentityCandidate(
                name: name, plausibility: 0.25, ageAtVideo: age,
                reason: "age \(age) doesn't match any scene-described age range"
            ))
        } else {
            results.append(IdentityCandidate(
                name: name, plausibility: bestMatch, ageAtVideo: age,
                reason: bestReason
            ))
        }
    }

    // Rank: highest plausibility first; tie-break alphabetically.
    return results.sorted {
        if $0.plausibility != $1.plausibility { return $0.plausibility > $1.plausibility }
        return $0.name < $1.name
    }
}

// MARK: - Age-bucket extraction

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

/// Scan a list of scene descriptions for age-bucket keywords. Returns
/// the union of buckets implied (a clip may have both "a child" and
/// "an adult" if it shows multiple people across frames).
nonisolated func pfExtractAgeBuckets(from descriptions: [String]) -> [AgeBucket] {
    let lowered = descriptions.joined(separator: " ").lowercased()
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
    if lowered.contains("elderly") || lowered.contains("grandparent")
        || lowered.contains("grandmother") || lowered.contains("grandfather")
        || lowered.contains("senior") {
        buckets.append(AgeBucket(label: "elderly", minAge: 60, maxAge: 110))
    }
    return buckets
}

// MARK: - Helpers

private func yearOf(_ d: Date) -> Int {
    Calendar(identifier: .gregorian).component(.year, from: d)
}
