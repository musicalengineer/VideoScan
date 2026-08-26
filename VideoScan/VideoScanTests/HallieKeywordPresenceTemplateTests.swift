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
