import Testing
import Foundation
@testable import VideoScan

// MARK: - Universal search tests (Issue #66, pattern 2)

struct UniversalSearchTokenTests {

    // regression: #66 — Whitespace splits a query into separate tokens
    @Test func multipleTokens() {
        let toks = pfTokenizeSearchQuery("donna holiday 1990")
        #expect(toks == [.substring("donna"), .substring("holiday"), .substring("1990")])
    }

    // regression: #66 — Empty query yields zero tokens (matches everything downstream)
    @Test func emptyQuery() {
        #expect(pfTokenizeSearchQuery("").isEmpty)
        #expect(pfTokenizeSearchQuery("    ").isEmpty)
    }

    // regression: #66 — Decade shorthand "1990s" expands to 1990...1999
    @Test func decadeShorthand1990s() {
        let toks = pfTokenizeSearchQuery("1990s")
        #expect(toks == [.yearRange(1990...1999)])
    }

    // regression: #66 — Decade shorthand "199x" expands to 1990...1999
    @Test func wildcardShorthand199x() {
        let toks = pfTokenizeSearchQuery("199x")
        #expect(toks == [.yearRange(1990...1999)])
    }

    // regression: #66 — "200x" expands to 2000...2009
    @Test func wildcardShorthand200x() {
        let toks = pfTokenizeSearchQuery("200x")
        #expect(toks == [.yearRange(2000...2009)])
    }

    // regression: #66 — "1995s" is NOT a decade (last digit not 0); falls back to substring
    @Test func nonDecadeRejectedAsRange() {
        let toks = pfTokenizeSearchQuery("1995s")
        #expect(toks == [.substring("1995s")])
    }

    // regression: #66 — Mixed substring + range tokens preserved in order
    @Test func mixedTokens() {
        let toks = pfTokenizeSearchQuery("donna 1990s family")
        #expect(toks == [
            .substring("donna"),
            .yearRange(1990...1999),
            .substring("family"),
        ])
    }

    // Rick 2026-06-16 — comma separators (natural-language punctuation)
    @Test func commaAsSeparator() {
        let toks = pfTokenizeSearchQuery("elevator, cape cod, donna")
        #expect(toks == [
            .substring("elevator"),
            .substring("cape"),
            .substring("cod"),
            .substring("donna"),
        ])
    }

    // Rick 2026-06-16 — semicolon separators (symmetric with comma)
    @Test func semicolonAsSeparator() {
        let toks = pfTokenizeSearchQuery("donna; family; 1990s")
        #expect(toks == [
            .substring("donna"),
            .substring("family"),
            .yearRange(1990...1999),
        ])
    }

    // Rick 2026-06-16 — double-quoted phrases stay as one token
    @Test func quotedPhraseStaysWhole() {
        let toks = pfTokenizeSearchQuery(#""cape cod" donna"#)
        #expect(toks == [
            .substring("cape cod"),
            .substring("donna"),
        ])
    }

    // Rick 2026-06-16 — quoted phrase can include comma without splitting
    @Test func quotedPhraseSurvivesComma() {
        let toks = pfTokenizeSearchQuery(#""hello, world""#)
        #expect(toks == [.substring("hello, world")])
    }

    // Rick 2026-06-16 — quoted phrase bypasses field-prefix recognition
    // (escape-hatch for files actually containing "filename:" in their text)
    @Test func quotedPhraseBypassesFieldPrefix() {
        let toks = pfTokenizeSearchQuery(#""filename:cape""#)
        #expect(toks == [.substring("filename:cape")])
    }

    // Rick 2026-06-16 — quoted phrase bypasses year-decade recognition too
    @Test func quotedPhraseBypassesDecadeShorthand() {
        let toks = pfTokenizeSearchQuery(#""1990s""#)
        #expect(toks == [.substring("1990s")])
    }

    // Rick 2026-06-16 — unterminated quote at EOF treats trailing text
    // as a phrase (matches user intent — they started a quote and
    // submitted before closing)
    @Test func unterminatedQuoteAtEnd() {
        let toks = pfTokenizeSearchQuery(#"donna "cape cod"#)
        #expect(toks == [
            .substring("donna"),
            .substring("cape cod"),
        ])
    }

    // Rick 2026-06-16 — mixed: phrase + field-prefix + bare substring
    @Test func mixedPhraseFieldSubstring() {
        let toks = pfTokenizeSearchQuery(#""cape cod" stream:audio elevator"#)
        #expect(toks == [
            .substring("cape cod"),
            .field(name: .streamType, value: "audio"),
            .substring("elevator"),
        ])
    }
}

struct UniversalSearchYearExtractionTests {

    private func record(path: String, dateModified: Date? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.filename = (path as NSString).lastPathComponent
        r.dateModifiedRaw = dateModified
        return r
    }

    // regression: #66 — Year embedded in a path component is extracted
    @Test func yearInPath() {
        let r = record(path: "/Volumes/Drive/holiday_1995/clip.mov")
        #expect(pfYearsFromRecord(r).contains(1995))
    }

    // regression: #66 — Year embedded in a filename is extracted
    @Test func yearInFilename() {
        let r = record(path: "/Volumes/Drive/holiday_1995.mov")
        #expect(pfYearsFromRecord(r).contains(1995))
    }

    // regression: #66 — Embedded run of 5 digits is NOT a year (e.g. "199999")
    @Test func ignoresLongerDigitRuns() {
        let r = record(path: "/Volumes/Drive/something_1999999.mov")
        #expect(!pfYearsFromRecord(r).contains(1999))
    }

    // regression: #66 — dateModifiedRaw year is included
    @Test func dateModifiedYear() {
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: DateComponents(year: 2003, month: 6, day: 1))!
        let r = record(path: "/v/clip.mov", dateModified: date)
        #expect(pfYearsFromRecord(r).contains(2003))
    }

    // regression: #66 — Years out of range (1899, 2100) are ignored
    @Test func rejectsOutOfRangeYears() {
        let r = record(path: "/Volumes/2100abc/old_1899/clip.mov")
        let years = pfYearsFromRecord(r)
        #expect(!years.contains(2100))
        #expect(!years.contains(1899))
    }
}

struct UniversalSearchMatchingTests {

    private func record(
        path: String = "/v/clip.mov",
        detectedPeople: [String] = [],
        avidClipName: String = "",
        videoCodec: String = "",
        notes: String = ""
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.filename = (path as NSString).lastPathComponent
        r.detectedPeople = detectedPeople
        r.avidClipName = avidClipName
        r.videoCodec = videoCodec
        r.notes = notes
        return r
    }

    // regression: #66 — Empty query matches all records
    @Test func emptyQueryMatchesAll() {
        let r = record()
        #expect(pfRecordMatchesQuery(r, query: "") == true)
        #expect(pfRecordMatchesQuery(r, query: "   ") == true)
    }

    // regression: #66 — Single substring matches filename
    @Test func filenameSubstringMatch() {
        let r = record(path: "/v/holiday_1995.mov")
        #expect(pfRecordMatchesQuery(r, query: "holiday") == true)
        #expect(pfRecordMatchesQuery(r, query: "Holiday") == true) // case-insensitive
    }

    // regression: #66 — detectedPeople is searchable
    @Test func detectedPeopleMatch() {
        let r = record(detectedPeople: ["Donna", "Tim"])
        #expect(pfRecordMatchesQuery(r, query: "donna") == true)
        #expect(pfRecordMatchesQuery(r, query: "tim") == true)
        #expect(pfRecordMatchesQuery(r, query: "fred") == false)
    }

    // Step 1b: suspectedPeople is searchable too — typing "donna" in the
    // catalog search bar should find the file regardless of whether
    // Donna was tagged with confirmed or suspected confidence.
    @Test func suspectedPeopleMatch() {
        let r = record()
        r.suspectedPeople = ["Donna", "Tim"]
        #expect(pfRecordMatchesQuery(r, query: "donna") == true)
        #expect(pfRecordMatchesQuery(r, query: "tim") == true)
        #expect(pfRecordMatchesQuery(r, query: "fred") == false)
    }

    // Step S5: caption text is searchable. "playing guitar" hits any
    // caption containing that substring, regardless of timestamp.
    @Test func sceneCaptionTextMatch() {
        let r = record()
        r.sceneCaptions = [
            SceneCaption(timestamp: 0.0, text: "A man playing guitar in a kitchen"),
            SceneCaption(timestamp: 12.5, text: "Two children laughing at a table")
        ]
        #expect(pfRecordMatchesQuery(r, query: "guitar") == true)
        #expect(pfRecordMatchesQuery(r, query: "kitchen") == true)
        #expect(pfRecordMatchesQuery(r, query: "laughing") == true)
        #expect(pfRecordMatchesQuery(r, query: "skydiving") == false)
    }

    // Caption matches compose with people-tag matches under AND
    // semantics. "donna playing guitar" requires both tokens to land
    // somewhere on the record — one via detectedPeople, one via
    // sceneCaptions. This is the headline behavior the captions
    // feature exists to enable.
    @Test func sceneCaptionAndPersonTagComposeAcrossQueries() {
        let r = record(detectedPeople: ["Donna"])
        r.sceneCaptions = [
            SceneCaption(timestamp: 5.0, text: "Man playing guitar in living room")
        ]
        #expect(pfRecordMatchesQuery(r, query: "donna playing guitar") == true)
        #expect(pfRecordMatchesQuery(r, query: "donna kitchen") == false)
    }

    // Caption match is case-insensitive, matching every other text field
    // in pfTokenMatches.
    @Test func sceneCaptionMatchIsCaseInsensitive() {
        let r = record()
        r.sceneCaptions = [SceneCaption(timestamp: 0, text: "A Dog on a Sofa")]
        #expect(pfRecordMatchesQuery(r, query: "DOG") == true)
        #expect(pfRecordMatchesQuery(r, query: "dog") == true)
        #expect(pfRecordMatchesQuery(r, query: "Dog") == true)
    }

    // regression: #66 — avidClipName is searchable
    @Test func avidClipNameMatch() {
        let r = record(avidClipName: "MyClip.V01.A01")
        #expect(pfRecordMatchesQuery(r, query: "v01.a01") == true)
    }

    // regression: #66 — Codec string is searchable
    @Test func codecMatch() {
        let r = record(videoCodec: "h264")
        #expect(pfRecordMatchesQuery(r, query: "h264") == true)
        #expect(pfRecordMatchesQuery(r, query: "prores") == false)
    }

    // regression: #66 — Notes field is searchable
    @Test func notesMatch() {
        let r = record(notes: "wedding reception, mom's side")
        #expect(pfRecordMatchesQuery(r, query: "wedding") == true)
    }

    // regression: #66 — Multi-token AND: both must match (people + year)
    @Test func multiTokenAnd() {
        let r = record(path: "/v/holiday_1995.mov", detectedPeople: ["Donna"])
        #expect(pfRecordMatchesQuery(r, query: "donna 1995") == true)
        // Both match: donna in detectedPeople AND 1995 in path
        #expect(pfRecordMatchesQuery(r, query: "donna fred") == false)
        // donna matches, fred doesn't
    }

    // regression: #66 — Year token matches via path-extracted year
    @Test func yearTokenMatchesPath() {
        let r = record(path: "/v/family_1992/clip.mov")
        #expect(pfRecordMatchesQuery(r, query: "1990s") == true)
        #expect(pfRecordMatchesQuery(r, query: "2000s") == false)
    }

    // regression: #66 — Wildcard year token works the same as decade
    @Test func wildcardYearToken() {
        let r = record(path: "/v/family_2003/clip.mov")
        #expect(pfRecordMatchesQuery(r, query: "200x") == true)
        #expect(pfRecordMatchesQuery(r, query: "199x") == false)
    }

    // regression: #66 — Realistic compound query
    @Test func compoundQueryDonna1990sHoliday() {
        let r = record(path: "/v/holiday_1995/clip.mov", detectedPeople: ["Donna"])
        #expect(pfRecordMatchesQuery(r, query: "donna 1990s holiday") == true)
    }

    // regression: #66 — Bulk filter API returns the right slice
    @Test func bulkFilterReturnsMatchingSlice() {
        let recs = [
            record(path: "/v/donna_1995.mov", detectedPeople: ["Donna"]),
            record(path: "/v/tim_2005.mov", detectedPeople: ["Tim"]),
            record(path: "/v/donna_2005.mov", detectedPeople: ["Donna"]),
        ]
        let donnaIn90s = pfRecordsMatchingQuery(recs, query: "donna 1990s")
        #expect(donnaIn90s.count == 1)
        #expect(donnaIn90s.first?.filename == "donna_1995.mov")
    }
}

// MARK: - Catalog search-bar tests (filename + person tags)

struct CatalogSearchBarTests {

    private func record(
        filename: String = "clip.mov",
        detectedPeople: [String] = [],
        suspectedPeople: [String] = []
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = filename
        r.fullPath = "/v/\(filename)"
        r.detectedPeople = detectedPeople
        r.suspectedPeople = suspectedPeople
        return r
    }

    @Test func emptyQueryMatchesAll() {
        #expect(pfRecordFilenameOrPersonMatch(record(), query: ""))
    }

    @Test func filenameSubstringMatch() {
        let r = record(filename: "Donna_birthday.mov")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "DONNA"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "birthday"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "skydiving"))
    }

    // Typing "donna" finds files tagged Donna even when the filename
    // (IMG_4521.MOV etc) has nothing to do with her — the headline UX
    // benefit of person-aware catalog search.
    @Test func detectedPersonTagMatch() {
        let r = record(filename: "IMG_4521.MOV", detectedPeople: ["Donna"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "DONNA"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "tim"))
    }

    @Test func suspectedPersonTagMatch() {
        let r = record(filename: "IMG_4521.MOV", suspectedPeople: ["Donna"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna"))
    }

    @Test func filenameNoMatchButPersonMatch() {
        let r = record(filename: "IMG_0001.mov", detectedPeople: ["Tim"])
        #expect(!r.filename.lowercased().contains("tim"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "tim"))
    }

    @Test func noMatchReturnsFalse() {
        let r = record(filename: "vacation.mov", detectedPeople: ["Donna"])
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "kayak"))
    }

    // Directory + volumeName ARE now searched per Rick 2026-06-15
    // (commit 6246291: "directory + volumeName join the catalog
    // search haystack"). Folder-based queries like "Cape Cod 1997"
    // need to match files organized by project folder.
    // (Test "pathAndDirectoryAreNotSearched" deleted 2026-06-17 —
    // it asserted the prior design which has been intentionally
    // reversed.)

    // Semantic-content fields (captions, audio transcripts) are
    // also searched — they're "what's in the video" tags. Composes
    // with people-tag matches: typing "donna" should find a clip
    // captioned "donna playing guitar" even if the filename is
    // IMG_4521.MOV. Drives Rick's 2026-06-03 "Search metadata"
    // request.
    @Test func sceneCaptionTextIsSearched() {
        let r = VideoRecord()
        r.filename = "IMG_4521.MOV"
        r.sceneCaptions = [
            SceneCaption(timestamp: 0.0, text: "Donna playing guitar in the living room"),
            SceneCaption(timestamp: 5.0, text: "Close-up of acoustic guitar strings")
        ]
        #expect(pfRecordFilenameOrPersonMatch(r, query: "guitar"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "GUITAR")) // case-insensitive
        #expect(pfRecordFilenameOrPersonMatch(r, query: "living room"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "kayak"))
    }

    @Test func audioTranscriptIsSearched() {
        let r = VideoRecord()
        r.filename = "MVI_6129.MOV"
        r.audioTranscript = "Happy anniversary honey it's been thirty years"
        #expect(pfRecordFilenameOrPersonMatch(r, query: "anniversary"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "ANNIVERSARY")) // case-insensitive
        #expect(pfRecordFilenameOrPersonMatch(r, query: "thirty years"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "graduation"))
    }

    @Test func nilAudioTranscriptDoesNotCrashAndNeverMatches() {
        let r = VideoRecord()
        r.filename = "IMG_0001.mov"
        // audioTranscript stays nil — never-transcribed default
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "anything"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: ""))
    }

    @Test func emptySceneCaptionsArrayDoesNotMatch() {
        let r = VideoRecord()
        r.filename = "IMG_0001.mov"
        r.sceneCaptions = []   // explicit empty (post-caption-run with no detected scenes)
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "anything"))
    }
}

// MARK: - peopleSortKey tests (sortable People column)

struct PeopleSortKeyTests {

    private func makeRecord(detected: [String] = [], suspected: [String] = []) -> VideoRecord {
        let r = VideoRecord()
        r.detectedPeople = detected
        r.suspectedPeople = suspected
        return r
    }

    @Test func confirmedNamesSortAlphabetically() {
        let donna = makeRecord(detected: ["Donna"])
        let tim = makeRecord(detected: ["Tim"])
        #expect(donna.peopleSortKey < tim.peopleSortKey)
    }

    @Test func multipleConfirmedNamesJoinedInSortedOrder() {
        let r = makeRecord(detected: ["Tim", "Donna", "Matt"])
        #expect(r.peopleSortKey == "Donna, Matt, Tim")
    }

    // Untagged records sort AFTER tagged records ascending — U+FFFD
    // sentinel is higher than any normal letter. Avoids the "empty
    // string sorts to the top" surprise users hit with naive joins.
    @Test func untaggedRecordSortsAfterTaggedAscending() {
        let untagged = makeRecord()
        let tagged = makeRecord(detected: ["Donna"])
        #expect(tagged.peopleSortKey < untagged.peopleSortKey)
    }

    // Suspected-only sorts AFTER confirmed (because the suspected
    // bucket is prefixed with "~", which is > letters in ASCII).
    // Cohort order ascending: confirmed → suspected-only → untagged.
    @Test func suspectedOnlySortsAfterConfirmed() {
        let confirmedDonna = makeRecord(detected: ["Donna"])
        let suspectedDonna = makeRecord(suspected: ["Donna"])
        #expect(confirmedDonna.peopleSortKey < suspectedDonna.peopleSortKey)
    }

    @Test func mixedTiersConfirmedComesFirstInKey() {
        let mixed = makeRecord(detected: ["Donna"], suspected: ["Tim"])
        #expect(mixed.peopleSortKey == "Donna ~Tim")
        let suspectedOnly = makeRecord(suspected: ["Tim"])
        #expect(mixed.peopleSortKey < suspectedOnly.peopleSortKey)
    }

    // Tag insertion order shouldn't change the sort position — the key
    // is derived from sorted membership, not raw array order.
    @Test func sortKeyStableAcrossInsertionOrder() {
        let a = makeRecord(detected: ["Donna", "Tim"])
        let b = makeRecord(detected: ["Tim", "Donna"])
        #expect(a.peopleSortKey == b.peopleSortKey)
    }
}

// MARK: - Family tagging predicate tests (Step 5)

struct FamilyTaggingPredicateTests {

    private func record(detected: [String] = [], suspected: [String] = []) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/v/clip.mov"
        r.detectedPeople = detected
        r.suspectedPeople = suspected
        return r
    }

    @Test func hasAnyPersonTrueWhenConfirmed() {
        #expect(pfRecordHasAnyPerson(record(detected: ["Donna"])))
    }

    @Test func hasAnyPersonTrueWhenSuspectedOnly() {
        #expect(pfRecordHasAnyPerson(record(suspected: ["Donna"])))
    }

    @Test func hasAnyPersonTrueWhenBoth() {
        #expect(pfRecordHasAnyPerson(record(detected: ["Donna"], suspected: ["Tim"])))
    }

    @Test func hasAnyPersonFalseWhenEmpty() {
        #expect(!pfRecordHasAnyPerson(record()))
    }

    @Test func isUntaggedTrueWhenBothEmpty() {
        #expect(pfRecordIsUntagged(record()))
    }

    @Test func isUntaggedFalseWhenConfirmed() {
        #expect(!pfRecordIsUntagged(record(detected: ["Donna"])))
    }

    @Test func isUntaggedFalseWhenSuspected() {
        #expect(!pfRecordIsUntagged(record(suspected: ["Donna"])))
    }

    @Test func isUntaggedAndHasAnyPersonAreInverses() {
        // Filter design invariant: every record falls into exactly one
        // of "Has Family" or "Untagged" — these two filters partition
        // the catalog cleanly.
        let cases = [
            record(),
            record(detected: ["Donna"]),
            record(suspected: ["Tim"]),
            record(detected: ["Donna"], suspected: ["Tim"])
        ]
        for r in cases {
            #expect(pfRecordHasAnyPerson(r) != pfRecordIsUntagged(r))
        }
    }
}

// MARK: - Triage disposition tests (Issue #66, pattern 3)


// MARK: - Catalog search: tokenize + AND (Rick 2026-06-08)
//
// Pre-2026-06-08 the catalog search bar did a SINGLE-string substring
// match across the content fields. Typing "mark dan grampa" looked
// for that literal phrase and found nothing — even on records whose
// transcript contained all three names. After this fix, the same
// query is tokenized on whitespace and every token must match
// somewhere on the record (AND semantics), so the catalog can
// answer natural-language queries like the jq demo from the
// previous evening.
//
// These tests pin the new contract on `pfRecordFilenameOrPersonMatch`
// AND verify that the design boundary (no path / directory / codec
// / notes matching from the catalog bar) is preserved.

@Suite("Catalog search: tokenize + AND")
struct CatalogSearchTokenizeAndTests {

    private func record(
        filename: String = "clip.mov",
        path: String = "/Volumes/X/clip.mov",
        directory: String = "/Volumes/X",
        people: [String] = [],
        suspected: [String] = [],
        confirmed: [String] = [],
        captions: [String] = [],
        transcript: String? = nil,
        ocrText: [String] = [],
        ocrDates: [String] = [],
        notes: String = "",
        videoCodec: String = "h264",
        inferredYear: Int? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = filename
        r.fullPath = path
        r.directory = directory
        r.detectedPeople = people
        r.suspectedPeople = suspected
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.sceneCaptions = captions.map { SceneCaption(timestamp: 0, text: $0) }
        r.audioTranscript = transcript
        r.ocrText = ocrText.map { SceneCaption(timestamp: 0, text: $0) }
        r.ocrDateCandidates = ocrDates.map { SceneCaption(timestamp: 0, text: $0) }
        r.notes = notes
        r.videoCodec = videoCodec
        if let y = inferredYear {
            var c = DateComponents()
            c.year = y
            c.month = 6
            c.day = 15
            r.inferredRecordDate = Calendar(identifier: .gregorian).date(from: c)
        }
        return r
    }

    // MARK: - Tokenize + AND semantics

    @Test func multiTokenAND_allMustMatchSomewhereOnRecord() {
        // The original jq demo: "Mark AND Dan AND Grampa" → only the
        // family clip whose transcript has all three should match.
        let family = record(transcript: "Mark and Dan, say hi to Grampa")
        let onlyMark = record(transcript: "Mark is at the beach")
        let onlyDan = record(captions: ["Dan playing in the yard"])
        let onlyGrampa = record(captions: ["Grampa fishing"])

        #expect(pfRecordFilenameOrPersonMatch(family, query: "Mark Dan Grampa") == true)
        #expect(pfRecordFilenameOrPersonMatch(onlyMark, query: "Mark Dan Grampa") == false)
        #expect(pfRecordFilenameOrPersonMatch(onlyDan, query: "Mark Dan Grampa") == false)
        #expect(pfRecordFilenameOrPersonMatch(onlyGrampa, query: "Mark Dan Grampa") == false)
    }

    @Test func tokensCanMatchAcrossDifferentFields() {
        // "donna guitar" → Donna in people tags, "guitar" in captions.
        // Per-token OR across fields, per-query AND across tokens.
        let r = record(
            people: ["Donna"],
            captions: ["A woman playing a guitar by the campfire"]
        )
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna guitar") == true)
    }

    @Test func emptyQueryMatchesEveryRecord() {
        let r = record()
        #expect(pfRecordFilenameOrPersonMatch(r, query: "") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "   ") == true)
    }

    @Test func caseInsensitive() {
        let r = record(people: ["Donna"], captions: ["Beach picnic"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "DONNA BEACH") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "dOnNa BeAcH") == true)
    }

    @Test func partialSubstringMatchesPerToken() {
        // "matt" matches "Matthew" — substring, not whole-word.
        let r = record(people: ["Matthew"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "matt") == true)
    }

    @Test func transcriptIsSearchable() {
        let r = record(transcript: "happy birthday Matt")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "birthday") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "matt happy") == true)
    }

    @Test func ocrTextAndDatesAreSearchable() {
        let r = record(
            ocrText: ["HAPPY BIRTHDAY"],
            ocrDates: ["JUN 21 1991"]
        )
        // OCR'd dates appear as substrings too — typing the year hits
        // them even when the file metadata has no 1991.
        #expect(pfRecordFilenameOrPersonMatch(r, query: "happy") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "1991") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "happy 1991") == true)
    }

    @Test func confirmedByUserPeopleSearchable() {
        let r = record(confirmed: ["Donna"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna") == true)
    }

    @Test func suspectedPeopleSearchable() {
        let r = record(suspected: ["Donna"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna") == true)
    }

    @Test func filenameSearchable() {
        let r = record(filename: "Donna_at_beach.mov")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna beach") == true)
    }

    // MARK: - Design boundary: catalog bar must NOT match codec/notes

    // ("pathIsNOTSearched_preventsMatthewDirectoryFalsePositive"
    // deleted 2026-06-17. Directory IS searched now per commit
    // 6246291 — folder-based queries are first-class. The tradeoff
    // Rick accepted: typing "matt" can surface every file under a
    // /Matthew/ folder, but folder-organized projects become
    // findable, which is the more common workflow.)

    @Test func codecIsNOTSearched() {
        let r = record(videoCodec: "hevc")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "hevc") == false)
    }

    @Test func notesAreNOTSearched_inCatalogBar() {
        // Notes are searchable in universal search but NOT in the
        // catalog bar — keeping the catalog bar focused on "what's
        // in the video" content fields.
        let r = record(notes: "Need to delete this clip eventually")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "delete") == false)
    }

    // MARK: - Year tokens compose with substrings

    @Test func decadeShorthand_matchesFilenameYear() {
        let r = record(filename: "Cape Cod 1991.mov")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "1990s") == true)
    }

    @Test func decadeShorthand_matchesInferredRecordDate() {
        // Even when the filename carries no year and the path has
        // none, an inferred record date from dossier triangulation
        // should make decade queries land. Rick 2026-06-08: this is
        // the payoff of the multi-signal date inference work.
        let r = record(
            filename: "clip.mov",
            path: "/Volumes/X/clip.mov",
            directory: "/Volumes/X",
            inferredYear: 1991
        )
        #expect(pfRecordFilenameOrPersonMatch(r, query: "1990s") == true)
    }

    @Test func decadeShorthand_composesWithSubstring() {
        let r = record(
            people: ["Donna"],
            captions: ["Family beach trip"],
            inferredYear: 1995
        )
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna 1990s beach") == true)
        // Wrong decade should fail even with all substrings present.
        let r2 = record(
            people: ["Donna"],
            captions: ["Family beach trip"],
            inferredYear: 2008
        )
        #expect(pfRecordFilenameOrPersonMatch(r2, query: "donna 1990s beach") == false)
    }

    // MARK: - Failure modes

    @Test func noMatchAcrossAnyField_returnsFalse() {
        let r = record(filename: "vacation.mov", captions: ["mountains"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna beach") == false)
    }

    @Test func tokenWithNoFieldHit_failsTheWholeQuery() {
        // "donna" matches but "xyzzy" doesn't — AND semantics drops it.
        let r = record(people: ["Donna"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna xyzzy") == false)
    }
}

// MARK: - Phase B: field-prefix grammar (Rick 2026-06-08)
//
// "Google-like" search syntax: typing `people:donna` restricts the
// match to people fields, `caption:beach` to scene captions, etc.
// Plus year-range support: `year:1991`, `year:1989..1995`, `decade:1990s`.
// Field-prefix and plain substring tokens compose freely under AND.

@Suite("Search field-prefix grammar")
struct SearchFieldPrefixTokenizerTests {

    @Test func peoplePrefix() {
        #expect(pfTokenizeSearchQuery("people:donna") == [.field(name: .people, value: "donna")])
    }

    @Test func personAliasPrefix() {
        // "person:" and "who:" both alias to .people for ergonomic typing.
        #expect(pfTokenizeSearchQuery("person:donna") == [.field(name: .people, value: "donna")])
        #expect(pfTokenizeSearchQuery("who:donna") == [.field(name: .people, value: "donna")])
    }

    @Test func transcriptPrefixAndAlias() {
        #expect(pfTokenizeSearchQuery("transcript:beach") == [.field(name: .transcript, value: "beach")])
        #expect(pfTokenizeSearchQuery("said:beach") == [.field(name: .transcript, value: "beach")])
    }

    @Test func captionPrefix() {
        #expect(pfTokenizeSearchQuery("caption:guitar") == [.field(name: .caption, value: "guitar")])
        #expect(pfTokenizeSearchQuery("scene:guitar") == [.field(name: .caption, value: "guitar")])
    }

    @Test func ocrPrefix() {
        #expect(pfTokenizeSearchQuery("ocr:1991") == [.field(name: .ocr, value: "1991")])
    }

    @Test func filenamePrefix() {
        #expect(pfTokenizeSearchQuery("filename:cape") == [.field(name: .filename, value: "cape")])
        #expect(pfTokenizeSearchQuery("name:cape") == [.field(name: .filename, value: "cape")])
    }

    @Test func notesPrefix() {
        #expect(pfTokenizeSearchQuery("notes:delete") == [.field(name: .notes, value: "delete")])
    }

    @Test func yearSingleValue() {
        #expect(pfTokenizeSearchQuery("year:1991") == [.yearRange(1991...1991)])
    }

    @Test func yearRangeValue() {
        #expect(pfTokenizeSearchQuery("year:1989..1995") == [.yearRange(1989...1995)])
    }

    @Test func yearDecadeValue() {
        #expect(pfTokenizeSearchQuery("year:1990s") == [.yearRange(1990...1999)])
    }

    @Test func decadePrefix() {
        #expect(pfTokenizeSearchQuery("decade:1990") == [.yearRange(1990...1999)])
        #expect(pfTokenizeSearchQuery("decade:1990s") == [.yearRange(1990...1999)])
        #expect(pfTokenizeSearchQuery("decade:199") == [.yearRange(1990...1999)])
    }

    @Test func unknownPrefixFallsBackToSubstring() {
        // "blah:foo" isn't a known field — preserve the literal so the
        // user can still find a file/text that contains "blah:foo".
        #expect(pfTokenizeSearchQuery("blah:foo") == [.substring("blah:foo")])
    }

    @Test func badYearValueFallsBackToSubstring() {
        // year:gibberish should NOT silently become an empty range.
        // Falls back to substring so the user notices their typo
        // (the count will likely show 0).
        #expect(pfTokenizeSearchQuery("year:nineties") == [.substring("year:nineties")])
    }

    @Test func emptyValueAfterColonFallsBackToSubstring() {
        // "people:" alone has no value — treat as literal so it doesn't
        // silently match everything.
        #expect(pfTokenizeSearchQuery("people:") == [.substring("people:")])
    }

    @Test func mixedTokensComposeCleanly() {
        let toks = pfTokenizeSearchQuery("people:donna year:1990s caption:guitar")
        #expect(toks == [
            .field(name: .people, value: "donna"),
            .yearRange(1990...1999),
            .field(name: .caption, value: "guitar"),
        ])
    }

    @Test func caseInsensitiveFieldNames() {
        #expect(pfTokenizeSearchQuery("PEOPLE:donna") == [.field(name: .people, value: "donna")])
        #expect(pfTokenizeSearchQuery("People:donna") == [.field(name: .people, value: "donna")])
    }
}

@Suite("Search field-prefix matching")
struct SearchFieldPrefixMatchingTests {

    private func record(
        filename: String = "clip.mov",
        path: String = "/Volumes/X/clip.mov",
        directory: String = "/Volumes/X",
        people: [String] = [],
        suspected: [String] = [],
        confirmed: [String] = [],
        captions: [String] = [],
        transcript: String? = nil,
        ocrText: [String] = [],
        ocrDates: [String] = [],
        notes: String = ""
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = filename
        r.fullPath = path
        r.directory = directory
        r.detectedPeople = people
        r.suspectedPeople = suspected
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.sceneCaptions = captions.map { SceneCaption(timestamp: 0, text: $0) }
        r.audioTranscript = transcript
        r.ocrText = ocrText.map { SceneCaption(timestamp: 0, text: $0) }
        r.ocrDateCandidates = ocrDates.map { SceneCaption(timestamp: 0, text: $0) }
        r.notes = notes
        return r
    }

    @Test func peoplePrefixMatchesAllThreePeopleArrays() {
        // detected / suspected / confirmed all count as "people".
        let detected = record(people: ["Donna"])
        let suspected = record(suspected: ["Donna"])
        let confirmed = record(confirmed: ["Donna"])
        for r in [detected, suspected, confirmed] {
            #expect(pfRecordFilenameOrPersonMatch(r, query: "people:donna") == true)
        }
    }

    @Test func peoplePrefixDoesNotLeakToOtherFields() {
        // "donna" in caption but not in any people array → NOT a people: hit.
        let r = record(captions: ["A woman named Donna"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "people:donna") == false)
        // Plain "donna" (no prefix) DOES find it.
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna") == true)
    }

    @Test func transcriptPrefixIsolatesAudioField() {
        let r = record(people: ["Donna"], transcript: "happy birthday Matt")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "transcript:matt") == true)
        // Donna is in people, not in transcript — prefix excludes it.
        #expect(pfRecordFilenameOrPersonMatch(r, query: "transcript:donna") == false)
    }

    @Test func captionPrefixIsolatesSceneCaptions() {
        let r = record(captions: ["beach picnic"], transcript: "no mention of beach in audio")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "caption:picnic") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "caption:audio") == false)
    }

    @Test func ocrPrefixMatchesBothOcrFields() {
        let textOnly = record(ocrText: ["HAPPY BIRTHDAY"])
        let dateOnly = record(ocrDates: ["JUN 1991"])
        #expect(pfRecordFilenameOrPersonMatch(textOnly, query: "ocr:happy") == true)
        #expect(pfRecordFilenameOrPersonMatch(dateOnly, query: "ocr:1991") == true)
    }

    @Test func filenamePrefixDoesNotMatchPath() {
        // "name:matt" should match a file CALLED matt.mov but NOT a file
        // sitting in /Matthew/random.mov — the whole reason the prefix
        // exists.
        let inMatthewDir = record(filename: "random.mov",
                                  path: "/Volumes/X/Matthew/random.mov",
                                  directory: "/Volumes/X/Matthew")
        let namedMatt = record(filename: "matt.mov",
                               path: "/Volumes/X/matt.mov",
                               directory: "/Volumes/X")
        #expect(pfRecordFilenameOrPersonMatch(inMatthewDir, query: "name:matt") == false)
        #expect(pfRecordFilenameOrPersonMatch(namedMatt, query: "name:matt") == true)
    }

    @Test func notesPrefixOptsInToNotesField() {
        // Plain catalog search excludes notes by design. The notes:
        // prefix is the user explicitly opting in.
        let r = record(notes: "Need to delete this clip eventually")
        #expect(pfRecordFilenameOrPersonMatch(r, query: "delete") == false)        // plain → no
        #expect(pfRecordFilenameOrPersonMatch(r, query: "notes:delete") == true)   // prefix → yes
    }

    @Test func yearPrefixSingleValueMatchesInferredDate() {
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents(); c.year = 1991; c.month = 6; c.day = 15
        let r = record()
        r.inferredRecordDate = cal.date(from: c)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "year:1991") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "year:1992") == false)
    }

    @Test func yearPrefixRangeMatchesInferredDate() {
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents(); c.year = 1993; c.month = 6; c.day = 15
        let r = record()
        r.inferredRecordDate = cal.date(from: c)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "year:1989..1995") == true)
        #expect(pfRecordFilenameOrPersonMatch(r, query: "year:2000..2010") == false)
    }

    @Test func fullComposedQuery() {
        // The realistic "Google-like" query Rick had in mind from yesterday:
        // people:donna decade:1990 caption:guitar → must satisfy all three.
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents(); c.year = 1995; c.month = 8; c.day = 4
        let match = record(
            people: ["Donna"],
            captions: ["Donna playing the guitar at the picnic"]
        )
        match.inferredRecordDate = cal.date(from: c)
        #expect(pfRecordFilenameOrPersonMatch(match, query: "people:donna decade:1990 caption:guitar") == true)

        // Missing the guitar caption — composed query should fail.
        let missGuitar = record(
            people: ["Donna"],
            captions: ["Donna and the dog"]
        )
        missGuitar.inferredRecordDate = cal.date(from: c)
        #expect(pfRecordFilenameOrPersonMatch(missGuitar, query: "people:donna decade:1990 caption:guitar") == false)
    }
}
