import Foundation
import Testing
@testable import VideoScan

/// Sensors for the three-tier keyword semantics that fixed Rick's
/// "show videos of donna down the cape in the 90s" → "no evidence" turn
/// (Hallie log 2026-08-17). The catalog spells the place as
/// "Cape-1992-archive.mkv" / "CapeCod_June_1997.mp4"; the translator kept
/// the family idiom "down the cape" as the keyword.
@MainActor
@Suite("Family Archivist keyword matching", .serialized)
struct ArchivistKeywordMatchingTests {
    private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        _ path: String,
        people: [String] = [],
        tags: [String] = [],
        userNotes: String = "",
        volumeName: String = "",
        transcript: String? = nil,
        captions: [(Double, String)] = [],
        inferredYear: Int? = nil
    ) -> ArchivistPresenceRecordSnapshot {
        var inferred: Date?
        if let inferredYear {
            inferred = pfGregorianCalendar.date(
                from: DateComponents(year: inferredYear, month: 6, day: 15))
        }
        return ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: volumeName,
            inferredDate: inferred,
            confirmedPeople: people.map {
                ConfirmedTag(name: $0, confirmedAt: confirmedAt)
            },
            tags: tags,
            userNotes: userNotes,
            captions: captions.map { SceneCaption(timestamp: $0.0, text: $0.1) },
            transcript: transcript)
    }

    private func execute(
        _ payload: ArchivistQueryAST.Presence,
        _ records: [ArchivistPresenceRecordSnapshot]
    ) -> ArchivistPresenceResult {
        ArchivistPresenceExecutor.execute(
            ArchivistPresenceQuery(payload), records: records)
    }

    // MARK: Tokenizer

    @Test func tokenizerSplitsCamelCaseDigitsAndPunctuation() {
        #expect(ArchivistKeywordText.tokens("CapeCod_June_1997")
                == ["cape", "cod", "june", "1997"])
        #expect(ArchivistKeywordText.tokens("Cape-1992-archive.mkv")
                == ["cape", "1992", "archive", "mkv"])
        #expect(ArchivistKeywordText.tokens("Donna-CapeCod-1990s_prob4_1.mov")
                == ["donna", "cape", "cod", "1990", "s", "prob", "4", "1", "mov"])
        #expect(ArchivistKeywordText.tokens("USAToday2001")
                == ["usa", "today", "2001"])
        #expect(ArchivistKeywordText.tokens("xmas1990Morning")
                == ["xmas", "1990", "morning"])
        #expect(ArchivistKeywordText.tokens("") == [])
        #expect(ArchivistKeywordText.tokens("---") == [])
    }

    @Test func tokenizerFoldsCaseAndDiacritics() {
        #expect(ArchivistKeywordText.tokens("Caf\u{00E9} Z\u{00FC}rich")
                == ["cafe", "zurich"])
        #expect(ArchivistKeywordText.tokens("MARTHA'S Vineyard")
                == ["martha", "s", "vineyard"])
        #expect(ArchivistKeywordText.normalizedPhrase("Caf\u{00E9} DOWN")
                == "cafe down")
    }

    @Test func significantTokensDropStopwordsAndDuplicates() {
        #expect(ArchivistKeywordText.significantTokens("down the cape") == ["cape"])
        #expect(ArchivistKeywordText.significantTokens("our trip up to the lake")
                == ["lake"])
        #expect(ArchivistKeywordText.significantTokens("videos of the cape cape")
                == ["cape"])
        #expect(ArchivistKeywordText.significantTokens("the video") == [])
        #expect(ArchivistKeywordText.significantTokens("Christmas morning")
                == ["christmas", "morning"])
    }

    /// The byte-level record scanner must agree with the reference scalar
    /// tokenizer: every token it produces is found, and non-token substrings
    /// ("cape" inside "scape" or "CaPe") are not.
    @Test func byteMatcherAgreesWithReferenceTokenizer() {
        let values = [
            "CapeCod_June_1997", "Cape-1992-archive.mkv", "USAToday2001",
            "xmas1990Morning", "Donna-CapeCod-1990s_prob4_1.mov",
            "Caf\u{00E9} Z\u{00FC}rich", "the_cape_cod_fudge", "scape cape",
            "MARTHA'S Vineyard", "capecod", "Cape1992", "1997June",
        ]
        for value in values {
            for token in ArchivistKeywordText.tokens(value) {
                #expect(ArchivistKeywordText.containsAllTokens(value, [token]),
                        "\(value): token \(token) not found by byte matcher")
            }
            #expect(ArchivistKeywordText.containsAllTokens(
                value, ArchivistKeywordText.tokens(value)))
        }
        #expect(!ArchivistKeywordText.containsAllTokens("scape", ["cape"]))
        #expect(!ArchivistKeywordText.containsAllTokens("CaPe", ["cape"]))
        #expect(!ArchivistKeywordText.containsAllTokens("cape", ["cape", "cod"]))
        #expect(!ArchivistKeywordText.containsAllTokens("Capecod", ["cape"]))
        #expect(ArchivistKeywordText.containsAllTokens("Capecod", ["capecod"]))
        #expect(ArchivistKeywordText.containsAllTokens("CAPE COD", ["cape", "cod"]))
        #expect(ArchivistKeywordText.containsAllTokens("caf\u{00E9}", ["cafe"]))
        #expect(!ArchivistKeywordText.containsAllTokens("", ["cape"]))
    }

    // MARK: Alias table

    @Test func aliasTableBridgesFamilyIdioms() {
        let cape = ArchivistKeywordAliases.aliases(for: "down the cape")
        #expect(cape.contains(["cape", "cod"]))
        #expect(cape.contains(["capecod"]))
        #expect(!cape.contains(["cape"]), "own token list is not an alias")
        #expect(ArchivistKeywordAliases.aliases(for: "xmas").contains(["christmas"]))
        #expect(ArchivistKeywordAliases.aliases(for: "b-day").contains(["birthday"]))
        #expect(ArchivistKeywordAliases.aliases(for: "the vineyard")
                .contains(["martha", "s", "vineyard"]))
        #expect(ArchivistKeywordAliases.aliases(for: "montana").isEmpty)
        #expect(ArchivistKeywordAliases.aliases(for: "the").isEmpty)
    }

    @Test func aliasTableIsInternallyConsistent() {
        for group in ArchivistKeywordAliases.groups {
            #expect(group.count >= 2, "\(group): a group needs two members")
            for member in group {
                #expect(!ArchivistKeywordText.significantTokens(member).isEmpty,
                        "\(member): alias member is all stopwords")
            }
        }
    }

    // MARK: Executor tiers (the reported turn)

    @Test func downTheCapeMatchesCapeFilenamesForDonnaInTheNineties() throws {
        let donna = ["Donna"]
        let records = [
            snapshot("/Volumes/LaCie/Cape-1992-archive.mkv", people: donna),
            snapshot("/Volumes/LaCie/CapeCod_June_1997.mp4", people: donna),
            snapshot("/Volumes/LaCie/Donna-CapeCod-1990s_prob4_1.mov",
                     people: donna, inferredYear: 1994),
            snapshot("/Volumes/LaCie/Cape-1993/reel.mov", people: donna),
            snapshot("/Volumes/LaCie/cape-1992-edit.mov", people: donna),
            // Negatives
            snapshot("/Volumes/LaCie/Down the Road 1995.mov", people: donna),
            snapshot("/Volumes/LaCie/Cape-2004-archive.mkv", people: donna),
            snapshot("/Volumes/LaCie/Cape-1994-rick.mov", people: ["Rick"]),
        ]
        let result = execute(.init(
            people: donna, yearStart: 1990, yearEnd: 1999,
            mediaKind: .video, keywords: ["down the cape"]), records)

        #expect(result.conclusion == .present)
        #expect(result.evidence.totalMatchCount == 5)
        let filenames = result.evidence.citations.map(\.filename)
        #expect(!filenames.contains("Down the Road 1995.mov"))
        #expect(!filenames.contains("Cape-2004-archive.mkv"))
        #expect(!filenames.contains("Cape-1994-rick.mov"))

        let first = try #require(result.evidence.citations.first)
        let keywordBasis = try #require(first.bases.first {
            if case .keywordTokens = $0 { return true }
            return false
        })
        #expect(keywordBasis.summary
                == "filename token 'cape' for 'down the cape' (Cape-1992-archive.mkv)")
    }

    @Test func phraseTierStillWinsAndIsCitedAsContains() throws {
        let records = [snapshot("/Archive/down the cape 1991.mov")]
        let result = execute(.init(keywords: ["down the cape"]), records)
        let basis = try #require(result.evidence.citations.first?.bases.first)
        guard case .catalogField(let field, let term, _) = basis else {
            Issue.record("phrase hit must be cited as a catalog field, got \(basis)")
            return
        }
        #expect(field == "filename")
        #expect(term == "down the cape")
    }

    @Test func aliasTierIsCitedDistinctly() throws {
        let records = [snapshot("/Archive/xmas_1990.mov")]
        let result = execute(.init(keywords: ["christmas"]), records)
        #expect(result.evidence.totalMatchCount == 1)
        let basis = try #require(result.evidence.citations.first?.bases.first)
        #expect(basis.summary
                == "filename token 'xmas' via alias 'xmas' of 'christmas' (xmas_1990.mov)")

        let oneWord = [snapshot("/Archive/capecod_summer.mov")]
        let capeCod = execute(.init(keywords: ["cape cod"]), oneWord)
        #expect(capeCod.evidence.totalMatchCount == 1)
    }

    @Test func tokenTierRequiresAllSignificantTokensNeverAny() {
        let records = [
            snapshot("/Archive/Christmas_1990.mov"),
            snapshot("/Archive/Morning_walk.mov"),
            snapshot("/Archive/Christmas_Morning_1990.mov"),
        ]
        let result = execute(.init(keywords: ["christmas morning"]), records)
        #expect(result.evidence.totalMatchCount == 1)
        #expect(result.evidence.citations.first?.filename
                == "Christmas_Morning_1990.mov")
    }

    @Test func precisionNegativesSharingOnlyStopwordsDoNotMatch() {
        let records = [
            snapshot("/Archive/Down the Road.mov"),
            snapshot("/Archive/the_video_of_us.mov"),
            snapshot("/Archive/Up on the Roof.mov"),
            snapshot("/Archive/scape_1992.mov"),   // "cape" is a substring, not a token
        ]
        let result = execute(.init(keywords: ["down the cape"]), records)
        #expect(result.conclusion == .noEvidence)
        #expect(result.evidence.totalMatchCount == 0)
    }

    @Test func allStopwordKeywordOnlyUsesPhraseTier() {
        let records = [
            snapshot("/Archive/the video.mov"),
            snapshot("/Archive/Cape-1992.mov"),
        ]
        let result = execute(.init(keywords: ["the video"]), records)
        #expect(result.evidence.totalMatchCount == 1)
        #expect(result.evidence.citations.first?.filename == "the video.mov")
    }

    @Test func tokenTierCoversEveryCitedFieldInPriorityOrder() throws {
        let cases: [(ArchivistPresenceRecordSnapshot, String)] = [
            (snapshot("/a/x.mov", tags: ["Cape trip"]), "tag"),
            (snapshot("/a/x.mov", userNotes: "Down at the Cape, 1992"), "userNotes"),
            (snapshot("/a/Cape-1992.mov"), "filename"),
            (snapshot("/a/CapeCod/x.mov"), "directory"),
            (snapshot("/a/x.mov", volumeName: "CapeArchive"), "volumeName"),
            (snapshot("/a/x.mov", people: ["Cape Cousins"]), "person tag"),
            (snapshot("/a/x.mov", transcript: "we drove down to the cape"),
             "transcript"),
            (snapshot("/a/x.mov", captions: [(7.5, "beach on the cape")]), "caption"),
        ]
        for (record, expectedField) in cases {
            let result = execute(.init(keywords: ["down the cape"]), [record])
            let basis = try #require(result.evidence.citations.first?.bases.first,
                                     "\(expectedField): no match")
            guard case .keywordTokens(let field, _, _, _, _, let timestamp) = basis
            else {
                Issue.record("\(expectedField): unexpected basis \(basis)")
                continue
            }
            #expect(field == expectedField)
            if expectedField == "caption" {
                #expect(timestamp == 7.5)
                #expect(result.evidence.citations.first?.playbackSeconds == 7.5)
            }
        }
    }

    // MARK: Scale

    @Test func oneHundredThousandRecordKeywordScanIsBudgeted() async {
        var snapshots: [ArchivistPresenceRecordSnapshot] = []
        snapshots.reserveCapacity(100_000)
        for index in 0..<100_000 {
            let name = index.isMultiple(of: 100)
                ? "CapeCod_June_\(1990 + index % 10).mp4"
                : "Home_movie_\(index)_reel.mov"
            snapshots.append(ArchivistPresenceRecordSnapshot(
                fullPath: "/Archive/scale/\(name)",
                directory: "/Archive/scale",
                volumeName: "LaCie",
                userNotes: "family footage",
                transcript: "and then we all went to the beach for the day"))
        }
        let query = ArchivistPresenceQuery(.init(keywords: ["down the cape"]))

        let started = ContinuousClock.now
        let result = await Task.detached {
            ArchivistPresenceExecutor.execute(query, records: snapshots)
        }.value
        let elapsed = ContinuousClock.now - started

        #expect(result.evidence.totalMatchCount == 1_000)
        #expect(elapsed < .seconds(2),
                "keyword token scan took \(elapsed) over 100k snapshots")
    }
}
