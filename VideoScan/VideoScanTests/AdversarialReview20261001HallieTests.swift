// AdversarialReview20261001HallieTests.swift
// Red tests drafted by the first nightly adversarial review (2026-10-01,
// range 9ed39299..05c2b9a5, brief 3), run red first, then kept as pins.
//   ea7b6739  "W.I." (West Indies) is not Wisconsin in the origin trail
//   cce4ea0e  age at death abstains on "who died in X" / "in X"
//   784f0da7  birthplace counts abstain on "buried in X" / "in X"
//   1a73b432  multi-word, dotted and accented surname scopes abstain
// Synthetic people only (public repo).

import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - ea7b6739

@MainActor
@Suite struct OriginTrailWestIndiesTests {
    @Test func westIndiesBirthplaceIsNotHome() throws {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Child /Quillfeather/
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Parent /Quillfeather/
        1 BIRT
        2 PLAC Kingston, Jamaica, W.I.
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let child = try #require(g.people["@I1@"])
        let stops = g.originTrail(of: child, country: nil)
        try #require(!stops.isEmpty)
        let countries = HallieLineageAnswer.countries(in: stops)
        #expect(countries.allSatisfy { $0.name != "the United States" && !$0.isHome })
        let r = HallieLineageAnswer.originTrail(of: child, country: nil, graph: g)
        #expect(!r.prose.contains("the United States"), Comment(rawValue: r.prose))
        // Named as what it is, not the last letter of "W.I.".
        #expect(countries.map(\.name) == ["the West Indies"], "\(countries.map(\.name))")
    }
}

// MARK: - cce4ea0e / 784f0da7 / 1a73b432

@Suite struct AgeAtDeathConstraintTests {
    @Test func diedClauseOrPlaceFilterAbstains() {
        for q in ["what was the average age at death of our ancestors who died in ireland",
                  "what was the average age at death of our ancestors who died young",
                  "what was the average age at death of our ancestors in ireland",
                  "what was the average age at death of our ancestors buried in ohio"] {
            #expect(HallieAncestorStatisticsQuestion.detect(q) == nil, Comment(rawValue: q))
        }
    }

    /// The unconstrained sentences still answer.
    @Test func plainAgeAtDeathStillRecognized() {
        #expect(HallieAncestorStatisticsQuestion.detect("what was the average age at death of our ancestors") == .ageAtDeath(who: .ours))
        #expect(HallieAncestorStatisticsQuestion.detect("what was the average age at death of our ancestors who died") == .ageAtDeath(who: .ours))
        #expect(HallieAncestorStatisticsQuestion.detect("what was the average age at death of our ancestors in our family tree") == .ageAtDeath(who: .ours))
    }
}

@Suite struct BirthplaceConstraintTests {
    @Test func reducedRelativeOrPlaceFilterAbstains() {
        for q in ["how many of our ancestors buried in ohio were born in ireland",
                  "how many of our ancestors in ohio were born in ireland",
                  "how many of our ancestors from ohio were born in ireland",
                  "how many of our ancestors baptized catholic were born in ireland"] {
            #expect(HallieAncestorStatisticsQuestion.detect(q) == nil, Comment(rawValue: q))
        }
    }

    @Test func plainBirthplaceCountsStillRecognized() {
        #expect(HallieAncestorStatisticsQuestion.detect("how many of our ancestors were born in ireland")?.who == .ours)
        #expect(HallieAncestorStatisticsQuestion.detect("how many ancestors of beth sample were born in ireland")?.who == .person("Beth Sample"))
        #expect(HallieAncestorStatisticsQuestion.detect("how many of our ancestors who were born in ireland")?.who == .ours)
    }
}

@Suite struct UnreadFamilyScopeSurnameShapeTests {
    @Test func multiWordDottedOrAccentedSurnameAbstains() {
        for q in ["how many generations back does the van der quill line go",
                  "who is the earliest ancestor on the van der quill line",
                  "what was the average age at death of our ancestors on the st. quill side",
                  "how many of our ancestors on the müllerby side were born in ireland"] {
            #expect(HallieAncestorStatisticsQuestion.detect(q) == nil, Comment(rawValue: q))
        }
    }

    /// A person's side and the reader's own phrases are not surname scopes.
    @Test func possessiveSidesAndOwnPhrasesStillRecognized() {
        #expect(HallieAncestorStatisticsQuestion.detect("what is the average age at death on donna's side") == .ageAtDeath(who: .person("Donna")))
        #expect(HallieAncestorStatisticsQuestion.detect("what is our deepest line") == .deepestLine(who: .ours))
        #expect(HallieAncestorStatisticsQuestion.detect("who is the earliest ancestor in my family tree") == .earliest(who: .ours))
    }
}
