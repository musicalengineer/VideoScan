// HallieKeywordPresenceTemplateTests.swift
// ITEM 4 (live 2026-08-26): a keyword-only presence hit said "I found 1
// catalog item matching that." — useless. It now says what matched and
// where: "1 video where someone says “oldest photo” — Christmas1997-clip2.mov
// (1997)." Person answers keep their template. Pure.

import Foundation
import Testing
@testable import VideoScan

@Suite("Presence template — keyword-only hits name the match")
struct HallieKeywordPresenceTemplateTests {
    private func citation(_ filename: String, _ bases: [ArchivistEvidenceBasis]) -> ArchivistEvidenceCitation {
        ArchivistEvidenceCitation(recordID: UUID(), fullPath: "/vol/\(filename)", filename: filename,
                                  playbackSeconds: nil, bases: bases)
    }
    private func result(_ query: String, _ citations: [ArchivistEvidenceCitation], total: Int? = nil) -> ArchivistPresenceResult {
        ArchivistPresenceResult(
            conclusion: .present, interpretedQuery: query,
            evidence: ArchivistEvidenceSet(citations: citations, totalMatchCount: total ?? citations.count,
                                           isCitationListTruncated: false))
    }

    @Test func transcriptHitSaysWhoSaysWhatAndWhen() {
        let r = result("shape=presence keyword=oldest photo", [
            citation("Christmas1997-clip2.mov", [.transcriptMention(queryTerm: "oldest photo", model: "whisper")]),
        ])
        #expect(ArchivistPresenceAnswerComposer.compose(r).prose
                == "1 video where someone says “oldest photo” — Christmas1997-clip2.mov (1997).")
        // Token-tier transcript evidence reads the same way; the year comes
        // from a proven basis when there is one.
        let tokens = result("shape=presence keyword=oldest photo", [
            citation("clip2.mov", [.keywordTokens(field: "transcript", queryTerm: "oldest photo", matchedTokens: ["oldest"], alias: nil, matchedValue: "the oldest one", timestamp: 3),
                                   .pathYear(year: 1997, fullPath: "/vol/1997/clip2.mov")]),
            citation("clip3.mov", [.transcriptMention(queryTerm: "oldest photo", model: nil)]),
        ])
        #expect(ArchivistPresenceAnswerComposer.compose(tokens).prose
                == "2 videos where someone says “oldest photo” — clip2.mov (1997), clip3.mov.")
    }

    @Test func captionAndFilenameHitsNameTheField() {
        let caption = result("shape=presence keyword=birthday", [
            citation("party.mov", [.caption(queryTerm: "birthday", timestamp: 4, text: "a birthday cake", model: nil)]),
        ])
        #expect(ArchivistPresenceAnswerComposer.compose(caption).prose == "1 video captioned with “birthday” — party.mov.")
        let file = result("shape=presence keyword=cape", [
            citation("Cape_1993.mov", [.keywordTokens(field: "filename", queryTerm: "down the cape", matchedTokens: ["cape"], alias: nil, matchedValue: "Cape_1993.mov", timestamp: nil)]),
        ], total: 5)
        #expect(ArchivistPresenceAnswerComposer.compose(file).prose
                == "5 videos with “down the cape” in the filename — Cape_1993.mov (1993), and 4 more.")
    }

    // codex #707 item 8 sensor: the FIRST citation's kind used to be
    // attributed to every match ("5 videos where someone says …" when only
    // one was a transcript hit). Mixed evidence is now counted per kind.
    @Test func mixedEvidenceIsCountedPerKindNotByTheFirstCitation() {
        let mixed = result("shape=presence keyword=cape", [
            citation("Beach1993.mov", [.transcriptMention(queryTerm: "cape", model: nil)]),
            citation("Cape_1994.mov", [.keywordTokens(field: "filename", queryTerm: "cape", matchedTokens: ["cape"], alias: nil, matchedValue: "Cape_1994.mov", timestamp: nil)]),
            citation("Cape_1995.mov", [.catalogField(field: "filename", queryTerm: "cape", matchedValue: "Cape_1995.mov")]),
            citation("cottage.mov", [.caption(queryTerm: "cape", timestamp: 1, text: "cape cod cottage", model: nil)]),
            citation("Cape_1996.mov", [.catalogField(field: "filename", queryTerm: "cape", matchedValue: "Cape_1996.mov")]),
        ])
        #expect(ArchivistPresenceAnswerComposer.compose(mixed).prose
                == "5 videos: 1 where someone says “cape” — Beach1993.mov (1993); 3 with “cape” in the filename — Cape_1994.mov (1994); 1 captioned with “cape” — cottage.mov.")
        // A truncated page: per-kind counts cover what was cited, the
        // remainder is said plainly.
        let truncated = result("shape=presence keyword=cape", [
            citation("Beach1993.mov", [.transcriptMention(queryTerm: "cape", model: nil)]),
            citation("Cape_1994.mov", [.catalogField(field: "filename", queryTerm: "cape", matchedValue: "Cape_1994.mov")]),
        ], total: 7)
        #expect(ArchivistPresenceAnswerComposer.compose(truncated).prose
                == "7 videos: 1 where someone says “cape” — Beach1993.mov (1993); 1 with “cape” in the filename — Cape_1994.mov (1994), and 5 more.")
        // A cited item with no keyword basis at all is counted apart, never
        // folded into the first kind.
        let odd = result("shape=presence keyword=cape year=1993", [
            citation("Beach1993.mov", [.transcriptMention(queryTerm: "cape", model: nil)]),
            citation("x.mov", [.pathYear(year: 1993, fullPath: "/1993/x.mov")]),
        ])
        #expect(ArchivistPresenceAnswerComposer.compose(odd).prose
                == "2 videos: 1 where someone says “cape” — Beach1993.mov (1993); 1 matched another way.")
        // An item matching several ways counts once, under its strongest kind.
        #expect(ArchivistPresenceAnswerComposer.keywordMatchKind(of: citation("a.mov", [
            .catalogField(field: "filename", queryTerm: "cape", matchedValue: "a"),
            .transcriptMention(queryTerm: "cape", model: nil)])) == .says("cape"))
    }

    @Test func personAnswersKeepTheirTemplate() {
        let person = result("shape=presence person=Donna keyword=cape", [
            citation("Cape_1993.mov", [.humanPersonTag(queryIdentity: "Donna", taggedName: "Donna", confirmedAt: Date()),
                                       .transcriptMention(queryTerm: "cape", model: nil)]),
        ])
        #expect(ArchivistPresenceAnswerComposer.compose(person).prose == "I found 1 catalog item matching that.")
        // No keyword-ish basis at all (a year-only hit) → the old template.
        let year = result("shape=presence year=1993", [citation("a.mov", [.pathYear(year: 1993, fullPath: "/1993/a.mov")])])
        #expect(ArchivistPresenceAnswerComposer.compose(year).prose == "I found 1 catalog item matching that.")
    }
}
