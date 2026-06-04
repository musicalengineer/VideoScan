import Testing
import Foundation
@testable import VideoScan

// MARK: - pfIdentityCandidates
//
// Family-prior identity ranking. Eliminates impossible candidates
// (born after / died before video date) and ranks the rest by how
// well their age at the video date matches VLM scene-description age
// cues. PROVEN motivating case: Clip 03_converted.mov, video date
// 1991-06-21, scene "checking you up baby" → must rank Matt (born
// 1994) as IMPOSSIBLE and Tim (born 1990) as HIGH PLAUSIBILITY.

struct IdentityNarrowingTests {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    // MARK: motivating case — the Clip 03 reality

    @Test func mattBornAfterVideoIsImpossible() {
        let result = pfIdentityCandidates(
            recordDate: date(1991, 6, 21),
            sceneDescriptions: ["a man and a baby in a bedroom"],
            familyBirthdates: [
                "Matt":  date(1994, 1, 1),
                "Tim":   date(1990, 5, 1),
                "Rick":  date(1965, 1, 1)
            ]
        )
        let matt = result.first { $0.name == "Matt" }
        #expect(matt?.plausibility == 0.0)
        #expect(matt?.reason.contains("after") == true)
    }

    @Test func tim13MonthsOldMatchesBabyDescription() {
        // The Clip 03 motivating case: video 1991-06-21, Tim born
        // 1990-05-01 = 13 months old → "baby" bucket matches.
        let result = pfIdentityCandidates(
            recordDate: date(1991, 6, 21),
            sceneDescriptions: ["a man checking up on a baby in bed"],
            familyBirthdates: [
                "Tim":   date(1990, 5, 1),
                "Matt":  date(1994, 1, 1),
                "Rick":  date(1965, 1, 1)
            ]
        )
        let tim = result.first { $0.name == "Tim" }
        #expect(tim?.plausibility == 1.0,
                "Tim at 1yr should be a perfect 'baby' match, got \(tim?.plausibility ?? -1)")
        #expect(tim?.ageAtVideo == 1)
    }

    @Test func adultRickRanksHighForAdultDescription() {
        let result = pfIdentityCandidates(
            recordDate: date(1991, 6, 21),
            sceneDescriptions: ["an adult man standing in a dimly lit bedroom"],
            familyBirthdates: [
                "Rick":  date(1965, 1, 1),
                "Tim":   date(1990, 5, 1)
            ]
        )
        let rick = result.first { $0.name == "Rick" }
        #expect(rick?.plausibility == 1.0)
        #expect(rick?.ageAtVideo == 26)
    }

    // MARK: ranking + ordering

    @Test func resultsAreSortedByPlausibilityDescending() {
        let result = pfIdentityCandidates(
            recordDate: date(2010, 12, 25),
            sceneDescriptions: ["a teenager opening Christmas presents"],
            familyBirthdates: [
                "Matt":   date(1994, 1, 1),    // age 16 → teen match (1.0)
                "Tim":    date(1990, 5, 1),    // age 20 → not a teen (lower)
                "Rick":   date(1965, 1, 1),    // age 45 → adult, no teen
                "Donna":  date(1965, 1, 1)
            ]
        )
        // Highest plausibility first.
        for i in 0..<(result.count - 1) {
            #expect(result[i].plausibility >= result[i + 1].plausibility)
        }
        #expect(result.first?.name == "Matt")
    }

    // MARK: deathdate

    @Test func deathBeforeVideoIsImpossible() {
        let result = pfIdentityCandidates(
            recordDate: date(2024, 1, 1),
            sceneDescriptions: ["a woman holding flowers"],
            familyBirthdates: ["Eileen": date(1935, 1, 1)],
            familyDeathdates: ["Eileen": date(2023, 6, 1)]
        )
        #expect(result.first?.plausibility == 0.0)
        #expect(result.first?.reason.contains("deceased") == true)
    }

    // MARK: missing scene cues

    @Test func missingAgeCuesGivesNeutralPlausibility() {
        // No age cues → can't rank, just say "possible".
        let result = pfIdentityCandidates(
            recordDate: date(2010, 1, 1),
            sceneDescriptions: ["a dark room"],
            familyBirthdates: ["Rick": date(1965, 1, 1)]
        )
        #expect(result.first?.plausibility == 0.5)
    }

    @Test func emptyFamilyReturnsEmpty() {
        let result = pfIdentityCandidates(
            recordDate: date(2010, 1, 1),
            sceneDescriptions: [],
            familyBirthdates: [:]
        )
        #expect(result.isEmpty)
    }
}

struct AgeBucketTests {

    @Test func babyKeywordExtracted() {
        let buckets = pfExtractAgeBuckets(from: ["a small baby on a bed"])
        #expect(buckets.contains { $0.label == "baby" })
    }

    @Test func teenagerKeywordExtracted() {
        let buckets = pfExtractAgeBuckets(from: ["a teenager at the kitchen table"])
        #expect(buckets.contains { $0.label == "teenager" })
    }

    @Test func multipleBucketsAccumulate() {
        let buckets = pfExtractAgeBuckets(from: [
            "a man holding a baby on his lap",
            "another frame shows an elderly woman in a chair"
        ])
        let labels = buckets.map(\.label)
        #expect(labels.contains("baby"))
        #expect(labels.contains("elderly"))
    }

    @Test func fitScoreInsideRangeIsOne() {
        let baby = AgeBucket(label: "baby", minAge: 0, maxAge: 2)
        #expect(baby.fit(age: 1) == 1.0)
        #expect(baby.fit(age: 0) == 1.0)
        #expect(baby.fit(age: 2) == 1.0)
    }

    @Test func fitScoreFallsOffOutsideRange() {
        let baby = AgeBucket(label: "baby", minAge: 0, maxAge: 2)
        #expect(baby.fit(age: 4) == 0.6)    // 2 years past
        #expect(baby.fit(age: 6) == 0.3)    // 4 years past
        #expect(baby.fit(age: 12) == 0.0)   // way past
    }
}
