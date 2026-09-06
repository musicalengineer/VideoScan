import Foundation
import Testing
@testable import VideoScan

/// B5, duplicate half. Rick asked, 2026-09-05:
///
///   "do we have any video of my father talking about typewriters"
///
/// and the translator emitted `keyword=typewriters keyword=typewriters`. The
/// duplicate survived all the way to his screen — the decline read
/// `I looked for videos of Richard with "typewriters", "typewriters"` — and
/// it doubled the per-record keyword scan for no additional matches.
///
/// `people` had been deduped since 2026-09-03 for exactly this reason
/// (`PersonNameClaim.dedupe`, one field above in the same initialiser).
/// `keywords` never was.
@MainActor
@Suite("Hallie presence — a keyword is never carried twice", .serialized)
struct HallieDuplicateKeywordTests {

    private func query(_ keywords: [String]) -> ArchivistPresenceQuery {
        ArchivistPresenceQuery(
            ArchivistQueryAST.Presence(people: ["Dad"], keywords: keywords))
    }

    /// THE SENSOR: the exact question and the exact duplication.
    @Test func typewritersIsNotAskedForTwice() {
        let q = query(["typewriters", "typewriters"])
        #expect(q.keywords == ["typewriters"])
        #expect(q.keywordQueries.count == 1)
        #expect(!q.description.contains("keyword=typewriters keyword=typewriters"),
                "the duplicate reached Rick's screen: \(q.description)")
    }

    @Test func duplicatesAreFoldedCaseAndDiacriticInsensitively() {
        #expect(query(["Cape Cod", "cape cod"]).keywords == ["Cape Cod"],
                "first spelling wins, so the answer quotes what was typed")
        #expect(query(["caf\u{00E9}", "cafe"]).keywords.count == 1)
        #expect(query(["CHRISTMAS", "christmas", "Christmas"]).keywords
                == ["CHRISTMAS"])
    }

    @Test func distinctKeywordsAllSurviveInOrder() {
        let q = query(["typewriters", "marines", "christmas"])
        #expect(q.keywords == ["typewriters", "marines", "christmas"])
        #expect(q.keywordQueries.count == 3)
    }

    @Test func emptyAndSingleKeywordListsAreUnchanged() {
        #expect(query([]).keywords.isEmpty)
        #expect(query(["typewriters"]).keywords == ["typewriters"])
    }

    /// Deduping must not disturb the relax ladder: dropping keywords still
    /// drops all of them, and the facet count still sees one keyword facet.
    @Test func dedupeDoesNotDisturbTheRelaxLadder() {
        let q = query(["typewriters", "typewriters"])
        #expect(q.has(.keywords))
        #expect(q.facetCount == 2, "person + keywords, not person + 2 keywords")
        let relaxed = q.dropping(.keywords)
        #expect(relaxed.keywords.isEmpty)
        #expect(relaxed.keywordQueries.isEmpty)
    }
}
