// HallieTypoPossessiveRealWordTests.swift
// Strict-009 regression (clean replay 2026-09-25 23:19, green on 09-18/21):
// "find the birthplaces of my materanl lines back to europe" reached the
// catalog ("I looked for videos with “birthplaces”, “maternal”, …").
//
// Cause: the typo front door's possessive repair turned "lines" into
// "line's" — "Line" is a name in the 39k-person tree, so the tree oracle
// protected the stem, and "lines" is not in the normalizer's own small word
// table. HallieBirthplaceTrail's one-edit "materanl" repair requires a line
// NOUN after it, and "line's" is not one, so the trail never engaged.
//
// Pinned: a real English word is never re-read as a possessive of a
// TREE-derived name; the curated inner-circle names ("donnas", "tims")
// still are.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie typo front door — a real word is not a tree name's possessive")
struct HallieTypoPossessiveRealWordTests {
    /// The live tree has people named Line and Back; the oracle says so.
    private let treeNames: (String) -> Bool = {
        ["line", "back", "tim", "donna"].contains($0.lowercased())
    }

    @Test func linesStaysLinesAndTheTrailEngages() {
        let question = "find the birthplaces of my materanl lines back to europe"
        let door = HallieFrontDoor.prepare(question, isProtectedName: treeNames)
        #expect(door.routingText == question, Comment(rawValue: door.routingText))
        guard case .birthplaceTrail(_, let line, _, _)? = HallieLineageQuestion.detect(door.routingText) else {
            Issue.record("the birthplace trail did not engage: \(door.routingText)")
            return
        }
        #expect(line == .maternal)
    }

    @Test func otherRealWordsAreLeftAlone() {
        #expect(HallieTypoNormalizer.normalize("draw lines between the cousins", isProtectedName: treeNames).text
                == "draw lines between the cousins")
        #expect(HallieTypoNormalizer.normalize("any backs turned in the photo", isProtectedName: treeNames).text
                == "any backs turned in the photo")
    }

    /// The repair still works where it was built for.
    @Test func innerCircleAndTreeOnlyNamesStillTakeThePossessive() {
        #expect(HallieTypoNormalizer.normalize("whos donnas mom", isProtectedName: treeNames).text
                == "who's donna's mom")
        #expect(HallieTypoNormalizer.normalize("who is Tims brother", isProtectedName: treeNames).text
                == "who is Tim's brother")
        let thankful: (String) -> Bool = { $0.lowercased() == "pratt" }
        #expect(HallieTypoNormalizer.normalize("show pratts family tree", isProtectedName: thankful).text
                == "show pratt's family tree")
    }
}
