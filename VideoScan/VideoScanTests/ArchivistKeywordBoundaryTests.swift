import Foundation
import Testing
@testable import VideoScan

/// The "ma breen and the cia" incident, 2026-09-05.
///
/// Rick asked Hallie "tell us about ma breen and the cia". She answered with
/// one cited item and the basis "transcript mentions cia
/// (whisper-medium-mlx-q4)". The transcript — 20,911 characters of a child
/// showing off rocks — contains the letters "cia" exactly once, inside the
/// word "special". A naked substring test had manufactured evidence for a
/// premise the questioner supplied. In a family-facing product that is worse
/// than a refusal.
///
/// Tier 1 of the keyword matcher is now WORD-START ANCHORED: the phrase must
/// begin at a token boundary but may run on into more characters, so "golf"
/// still finds "golfing" and "golfer".
@MainActor
@Suite("Family Archivist keyword word boundaries", .serialized)
struct ArchivistKeywordBoundaryTests {
    private let whisperModel = "whisper-medium-mlx-q4"

    /// The exact sentence from May2000_Misc_People.dv that produced the false
    /// positive (verified against the live catalog 2026-09-05; the transcript
    /// itself is never read by the test).
    private static let rockSentence = """
        Somebody took my big rock. All right. This is my little special \
        rock. This is one that's really nice and smooth, and it goes in \
        my pocket.
        """

    private func matches(_ keyword: String, _ value: String) -> Bool {
        let needle = Array(
            ArchivistKeywordText.normalizedPhrase(keyword).utf8)
        return ArchivistKeywordText.withFoldedBytes(value) {
            ArchivistKeywordText.containsPhrase(needle, in: $0)
        }
    }

    private func snapshot(
        _ path: String,
        people: [String] = [],
        transcript: String? = nil
    ) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            confirmedPeople: people.map {
                ConfirmedTag(name: $0,
                             confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
            },
            transcript: transcript,
            transcriptModel: transcript == nil ? nil : whisperModel)
    }

    private func execute(
        _ payload: ArchivistQueryAST.Presence,
        _ records: [ArchivistPresenceRecordSnapshot]
    ) -> ArchivistPresenceResult {
        ArchivistPresenceExecutor.execute(
            ArchivistPresenceQuery(payload), records: records)
    }

    // MARK: 1 — Logic

    /// The class of bug: a short keyword buried inside a longer word.
    @Test func shortKeywordDoesNotMatchInsideALongerWord() {
        for haystack in ["special", "social", "financial", "appreciate",
                         "Garcia", "officially", "my little special rock",
                         "the Garcia family", "a commercial"] {
            #expect(!matches("cia", haystack),
                    "'cia' must not match inside \"\(haystack)\"")
        }
        #expect(!matches("rick", "a trick of the light"))
        #expect(!matches("ma", "grandma"))
        #expect(!matches("art", "start"))
        #expect(!matches("ion", "vacation"))
    }

    /// The anchor is at the START only — dropping this would silently shrink
    /// "find golf video" from 54 items.
    @Test func keywordStillMatchesLongerWordsThatBeginWithIt() {
        for haystack in ["golf", "golfing", "golfer", "golfers",
                         "Golfing with Dad", "golf-1994.mov",
                         "we went golfing", "GOLFING"] {
            #expect(matches("golf", haystack),
                    "'golf' must match \"\(haystack)\"")
        }
        #expect(matches("cia", "CIA archives"))
        #expect(matches("cia", "cia"))
        #expect(matches("christmas", "Christmas1997-clip2.mov"))
        #expect(matches("cape", "cape-1992-archive.mkv"))
    }

    /// A word start is also a camelCase / letter-digit seam, matching the
    /// tokenizer the token tier already used.
    @Test func wordStartFollowsTheTokenizersBoundaryRules() {
        #expect(matches("cod", "CapeCod"))          // lower -> upper seam
        #expect(!matches("cod", "capecod"))         // no seam: not a word start
        #expect(matches("1992", "cape1992"))        // letter -> digit seam
        #expect(matches("june", "1997June"))        // digit -> letter seam
        #expect(matches("cape", "the_cape_cod"))    // punctuation seam
        #expect(matches("today", "USAToday2001"))   // acronym end
    }

    @Test func matchingIsCaseAndDiacriticInsensitiveAndHandlesEnds() {
        #expect(matches("cape", "CAPE COD"))
        #expect(matches("CAPE", "cape cod"))
        #expect(matches("cafe", "Caf\u{00E9} Z\u{00FC}rich"))
        #expect(matches("cape", "cape"))            // keyword at string start
        #expect(matches("cod", "cape cod"))         // keyword at string end
        #expect(!matches("cape", ""))
        #expect(!matches("", "cape"))
        #expect(!matches("cape cod", "cape"))       // needle longer than value
    }

    /// The matcher is a byte scan, not a regex, so metacharacters are inert
    /// data. A "." must mean a period and "+" must mean a plus.
    @Test func regexMetacharactersAreLiteralNotPatterns() {
        #expect(matches("c.a", "c.a files"))
        #expect(!matches("c.a", "cia files"))
        #expect(!matches("c.a", "cba"))
        #expect(matches("a+b", "a+b testing"))
        #expect(!matches("a+b", "aab"))
        #expect(!matches("a+b", "ab"))
        #expect(matches("(1997)", "(1997) reel"))
        #expect(matches("[take", "[take 2].mov"))
        #expect(matches("100%", "100% done"))
        #expect(!matches(".*", "anything at all"))
    }

    // MARK: 3 — Sensor: the exact escaped case

    /// PIN: keyword "cia" against the rock transcript must find nothing.
    /// If this ever goes green-to-red, Hallie has started corroborating
    /// false premises again.
    @Test func cheeseGraterRockTranscriptIsNotEvidenceForTheCIA() {
        let record = snapshot(
            "/Volumes/LaCieWorkspace/CheesegraterArchive/May2000_Misc_People.dv",
            people: ["Ma"],
            transcript: Self.rockSentence)

        let result = execute(
            ArchivistQueryAST.Presence(people: ["Ma"], keywords: ["cia"]),
            [record])

        // Nothing satisfies person AND keyword. The relax ladder still offers
        // the person-only match, but it is LABELLED as the relaxed answer —
        // that is the honest behaviour and is not what broke here.
        #expect(result.conclusion == .noEvidenceButRelaxed(dropped: .keywords),
                "a child's 'special rock' is not evidence about the CIA")
        #expect(result.conclusion != .present)
        for citation in result.evidence.citations {
            for basis in citation.bases {
                if case .transcriptMention = basis {
                    Issue.record("transcript cited for 'cia': \(basis.summary)")
                }
                #expect(!basis.summary.contains("cia"),
                        "no basis may cite 'cia': \(basis.summary)")
            }
        }

        // And with the person facet removed there is nothing at all.
        let keywordOnly = execute(
            ArchivistQueryAST.Presence(keywords: ["cia"]), [record])
        #expect(keywordOnly.evidence.totalMatchCount == 0)
        #expect(keywordOnly.conclusion == .noEvidence)
    }

    /// The same record, asked about something it really does say, still
    /// answers — and now shows the reader the words it heard.
    @Test func aRealTranscriptHitQuotesTheMatchedSpan() {
        let record = snapshot(
            "/Volumes/LaCieWorkspace/May2000_Misc_People.dv",
            people: ["Ma"],
            transcript: Self.rockSentence)

        let result = execute(
            ArchivistQueryAST.Presence(people: ["Ma"], keywords: ["rock"]),
            [record])

        #expect(result.conclusion == .present)
        guard let basis = result.evidence.citations.first?.bases.first(where: {
            if case .transcriptMention = $0 { return true }
            return false
        }) else {
            Issue.record("expected a transcript basis")
            return
        }
        guard case .transcriptMention(let term, let snippet, let model) = basis
        else { return }
        #expect(term == "rock")
        #expect(model == whisperModel)
        #expect(snippet?.contains("big rock") == true)
        #expect(basis.summary.contains("transcript mentions rock — \""))
        #expect(basis.summary.contains(whisperModel))
        #expect(basis.summary.count < 220,
                "a basis line must stay readable: \(basis.summary)")
    }

    @Test func snippetCollapsesWhitespaceAndElidesBothEnds() {
        let transcript = String(repeating: "filler words here. ", count: 40)
            + "\n\n  and then\tthe   GOLFING  began  \n\n"
            + String(repeating: "more filler here. ", count: 40)
        let record = snapshot("/Volumes/X/clip.mov", transcript: transcript)

        let result = execute(
            ArchivistQueryAST.Presence(keywords: ["golf"]), [record])
        guard case .transcriptMention(_, let snippet, _)
                = result.evidence.citations.first?.bases.first else {
            Issue.record("expected a transcript basis")
            return
        }
        guard let snippet else { Issue.record("no snippet"); return }
        #expect(snippet.hasPrefix("..."))
        #expect(snippet.hasSuffix("..."))
        #expect(snippet.contains("GOLFING"))
        #expect(!snippet.contains("\n"))
        #expect(!snippet.contains("  "))
        #expect(snippet.count < 130, "snippet too long: \(snippet)")
    }

    /// A token-tier hit in a transcript used to print the WHOLE transcript
    /// into the basis line (326 such lines in the September conversation
    /// logs, the largest 60,331 characters).
    @Test func tokenTierTranscriptHitCitesAnExcerptNotTheWholeTranscript() {
        let transcript = String(repeating: "the boys are running around. ",
                                count: 800)
            + "we were playing guitar on the porch. "
            + String(repeating: "then dinner was served. ", count: 800)
        #expect(transcript.count > 20_000)
        let record = snapshot("/Volumes/X/porch.mov", transcript: transcript)

        let result = execute(
            ArchivistQueryAST.Presence(keywords: ["playing guitar"]), [record])
        guard let basis = result.evidence.citations.first?.bases.first else {
            Issue.record("expected a basis")
            return
        }
        #expect(basis.summary.count < 300,
                "basis line was \(basis.summary.count) characters")
        #expect(basis.summary.contains("guitar"))
    }

    // MARK: 2 — Scale

    /// The phrase form is compiled ONCE per query in ArchivistKeywordQuery,
    /// never per record: 100k records with real-sized transcripts must stay
    /// well inside a second. (Debug builds are slower than Release; the
    /// budget is deliberately loose so this is a cliff detector, not a
    /// benchmark.)
    @Test func hundredThousandRecordsScanWithinBudget() {
        let transcript = String(
            repeating: "This is my little special rock and it is very smooth. ",
            count: 380)                                  // ~20 KB, like the real one
        #expect(transcript.utf8.count > 18_000)

        let records = (0..<100_000).map { index in
            snapshot("/Volumes/Test/clip\(index).mov",
                     transcript: index % 100 == 0 ? transcript : "short line")
        }

        let start = Date()
        let result = execute(
            ArchivistQueryAST.Presence(keywords: ["cia"]), records)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.evidence.totalMatchCount == 0,
                "'cia' must not match 'special' at any scale")
        #expect(elapsed < 12.0,
                "100k-record keyword scan took \(elapsed)s")
    }

    /// The query object precomputes its byte forms once; building it must not
    /// depend on the record count.
    @Test func keywordQueryPrecomputesItsByteFormsOnce() {
        let query = ArchivistKeywordQuery("down the cape")
        #expect(query.phraseBytes == Array("down the cape".utf8))
        #expect(query.significantTokens == ["cape"])
        #expect(query.tokenListBytes.first == [Array("cape".utf8)])
        #expect(query == ArchivistKeywordQuery("down the cape"))
    }
}
