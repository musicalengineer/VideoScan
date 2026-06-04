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

    // Intentional non-match: path / directory are NOT searched here, so
    // typing "Volumes" or a directory name doesn't match every file
    // under that mount. Keeps the catalog search bar predictable per
    // the Finder-like heuristic in the helper's doc comment.
    @Test func pathAndDirectoryAreNotSearched() {
        let r = VideoRecord()
        r.filename = "thing.mov"
        r.fullPath = "/Volumes/MyBook/family/Donna_compilation/thing.mov"
        r.directory = "/Volumes/MyBook/family/Donna_compilation"
        // "donna" appears in path/directory only — no filename / tag match.
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "donna"))
        // "Volumes" should not match either.
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "volumes"))
    }

    // Semantic-content fields (captions, audio transcripts) ARE
    // searched — they're "what's in the video" tags, not location
    // metadata. This is the deliberate distinction from path/directory
    // above: typing "donna" should find a clip captioned "donna
    // playing guitar" even if the filename is IMG_4521.MOV, the same
    // way it finds a clip tagged Donna in detectedPeople. Drives
    // Rick's 2026-06-03 "Search metadata" request — captions are
    // currently 0/13,570 populated, so this is greenfield, but lights
    // up the moment any VLM-captioning run completes.
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

struct TriageDispositionTests {

    private func record(
        junkScore: Int = 50,
        backupCount: Int = 0,
        archiveStage: ArchiveStage = .none
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/v/clip.mov"
        r.junkScore = junkScore
        r.archiveStage = archiveStage
        r.backupDestinations = (0..<backupCount).map {
            BackupEntry(name: "Backup\($0)", kind: .local, date: .now)
        }
        return r
    }

    // regression: #66 — junkScore <= autoKeepBelow → autoKeep
    @Test func lowScoreYieldsAutoKeep() {
        let r = record(junkScore: 10)
        #expect(pfTriageDisposition(r) == .autoKeep)
    }

    // regression: #66 — junkScore at boundary (= 30) is autoKeep (inclusive)
    @Test func autoKeepBoundaryIsInclusive() {
        let r = record(junkScore: 30)
        #expect(pfTriageDisposition(r) == .autoKeep)
    }

    // regression: #66 — Middle band → queue (human review)
    @Test func middleBandYieldsQueue() {
        let r = record(junkScore: 50)
        #expect(pfTriageDisposition(r) == .queue)
    }

    // regression: #66 — junkScore >= autoJunkAbove + verified backup → autoJunk
    @Test func highScoreWithBackupYieldsAutoJunk() {
        let r = record(junkScore: 80, backupCount: 2)
        #expect(pfTriageDisposition(r) == .autoJunk)
    }

    // regression: #66 — Backup gate: high score WITHOUT backup → junkButNotBackedUp (safety)
    @Test func highScoreWithoutBackupNotAutoJunked() {
        let r = record(junkScore: 80, backupCount: 0)
        #expect(pfTriageDisposition(r) == .junkButNotBackedUp)
    }

    // regression: #66 — One backup is not enough; need 2-locations rule
    @Test func singleBackupNotEnough() {
        let r = record(junkScore: 80, backupCount: 1)
        #expect(pfTriageDisposition(r) == .junkButNotBackedUp)
    }

    // regression: #66 — archiveStage = .healthy satisfies the backup gate
    @Test func healthyArchiveStageSatisfiesGate() {
        let r = record(junkScore: 80, backupCount: 0, archiveStage: .healthy)
        #expect(pfTriageDisposition(r) == .autoJunk)
    }

    // regression: #66 — `requireBackupForJunk: false` skips the safety gate
    @Test func disablingGateAllowsRiskyAutoJunk() {
        let r = record(junkScore: 90, backupCount: 0)
        #expect(pfTriageDisposition(r, requireBackupForJunk: false) == .autoJunk)
    }
}

struct TriageQueueTests {

    private func record(_ path: String, junkScore: Int, backupCount: Int = 0) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.junkScore = junkScore
        r.backupDestinations = (0..<backupCount).map {
            BackupEntry(name: "B\($0)", kind: .local, date: .now)
        }
        return r
    }

    // regression: #66 — Triage queue surfaces only borderline records
    @Test func queueSurfacesOnlyBorderline() {
        let recs = [
            record("/v/keeper.mov", junkScore: 5),     // autoKeep (filtered out)
            record("/v/borderline.mov", junkScore: 50),// queue (kept)
            record("/v/junk.mov", junkScore: 90, backupCount: 2), // autoJunk (filtered)
        ]
        let queue = pfTriageQueueRecords(from: recs)
        #expect(queue.count == 1)
        #expect(queue.first?.filename == "borderline.mov")
    }

    // regression: #66 — junkButNotBackedUp included by default (visibility for safety)
    @Test func includesUnbackedJunkByDefault() {
        let recs = [
            record("/v/risky.mov", junkScore: 90, backupCount: 0)
        ]
        let queue = pfTriageQueueRecords(from: recs)
        #expect(queue.count == 1)
    }

    // regression: #66 — Setting includeUnbackedJunk: false hides them
    @Test func canHideUnbackedJunk() {
        let recs = [
            record("/v/risky.mov", junkScore: 90, backupCount: 0)
        ]
        let queue = pfTriageQueueRecords(from: recs, includeUnbackedJunk: false)
        #expect(queue.isEmpty)
    }

    // regression: #66 — Band counts split a mixed catalog correctly
    @Test func bandCountsAggregate() {
        let recs = [
            record("/v/keep1.mov", junkScore: 5),
            record("/v/keep2.mov", junkScore: 25),
            record("/v/maybe.mov", junkScore: 50),
            record("/v/junk.mov", junkScore: 85, backupCount: 2),
            record("/v/risky.mov", junkScore: 90, backupCount: 0),
        ]
        let counts = pfTriageBandCounts(from: recs)
        #expect(counts.autoKeep == 2)
        #expect(counts.queue == 1)
        #expect(counts.autoJunk == 1)
        #expect(counts.junkButNotBackedUp == 1)
        #expect(counts.total == 5)
    }
}
