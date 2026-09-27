import Testing
import Foundation
@testable import VideoScan

// MARK: - DateTriangulatorTests (GH #201, 2026-09-26)
//
// Rick's rule: the inferred date is a machine GUESSTIMATE that COMBINES
// criteria and shows a written reason; he confirms. These pin the two
// live cases that drove the work, the criterion table, and the model-
// level catch-up / footage-group sharing.
//
// Five dimensions (docs/testing_retrospective_2026_07_05.md):
//   logic      CapeCod (with / without People-tab birth years), Clip 19,
//              "Christmas 2002" + camera stamp, now vs reference table,
//              age parsing, era floors, ranges, disagreement, priors
//   scale      100k records through the pure triangulator in budget;
//              off the main actor by construction (nonisolated, pure)
//   isolation  no People profiles ⇒ ages neutral; a model under test
//              never reads the real People store
//   sensors    user date always wins · a DV record never infers < 1995 ·
//              an "Apple, no model" stamp with no content still shows the
//              stamp (no regression for the 1,053 conflict-free records) ·
//              unknown ⇒ nil + "no evidence", never a filesystem date
//   media      n/a — no media file is opened; the triangulator reads
//              stored fields (transcript snippets copied from the real
//              catalog into fixtures; the catalog itself is never read)

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC") ?? .current
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h
    return cal.date(from: dc) ?? .distantPast
}

private func year(_ d: Date?) -> Int? {
    guard let d else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC") ?? .current
    return cal.component(.year, from: d)
}

private let testNow = utc(2026, 9, 26)

/// The real transcripts, copied (the catalog is never read here).
enum GH201Fixtures {
    static let capeCodTranscript =
        "Say what year it is. 2004. How old are you? Eight years old. Look at the waves. " +
        "Say what year it is. 2004. Okay. Say what year it is. 2004. Wave to the camera."
    static let clip19Transcript =
        "I think it was 1955 or 6 and it was on the waterfront. Mylon Brando, Lee J Cobb."
    static let timmy = DateTriangulationPerson(name: "Timmy", aliases: ["Tim"], birthYear: 1996)
    static let rick = DateTriangulationPerson(name: "Rick", aliases: ["Dad"], birthYear: 1964)

    static func capeCod(people: [DateTriangulationPerson] = []) -> DateTriangulationInput {
        var i = DateTriangulationInput()
        i.audioTranscript = capeCodTranscript
        i.embeddedCreationDate = utc(2008, 10, 23, 14)
        i.originMake = "Apple"
        i.originEncoder = "H.264"
        i.videoCodec = "h264"
        i.container = "mov,mp4,m4a,3gp,3g2,mj2"
        i.fullPath = "/Volumes/LaCie/Exports/CapeCod_notsure_NTSC.mov"
        i.people = people
        i.now = testNow
        return i
    }

    static func clip19() -> DateTriangulationInput {
        var i = DateTriangulationInput()
        i.audioTranscript = clip19Transcript
        i.videoCodec = "dvvideo"
        i.container = "dv"
        i.fullPath = "/Volumes/LaCie/TimmyBaby-1996/Media/Clip 19.dv"
        i.pathYearHints = pfPathYearHints(in: i.fullPath)
        i.now = testNow
        return i
    }
}

// MARK: - Logic

@Suite("DateTriangulator — the GH #201 live cases and the criterion table")
struct DateTriangulatorLogicTests {

    @Test("CapeCod: three 'what year is it? 2004' now-cues beat the 2008 export stamp; the reason names the cue and the set-aside")
    func capeCodWithoutPeople() {
        let r = pfTriangulateRecordDate(GH201Fixtures.capeCod())
        #expect(year(r.date) == 2004, "\(r.reason)")
        #expect(r.confidence >= 0.7, "got \(r.confidence)")
        #expect(r.precision == .year)
        #expect(r.range == InferredDateRange(year: 2004))
        #expect(r.reason.contains("spoken now-cue"), "\(r.reason)")
        #expect(r.reason.contains("2004"), "\(r.reason)")
        #expect(r.reason.contains("×3"), "\(r.reason)")
        #expect(r.reason.contains("export stamp 2008-10-23 set aside as ingest"), "\(r.reason)")
        // An H.264 EXPORT carries no era floor (the DV capture it came from could be anything).
        #expect(!r.reason.contains("era floor"), "\(r.reason)")
    }

    @Test("CapeCod + Timmy (b. 1996) in the People tab: 'how old are you? eight' corroborates 2004 and the reason says so")
    func capeCodWithPeople() {
        let r = pfTriangulateRecordDate(GH201Fixtures.capeCod(people: [GH201Fixtures.timmy, GH201Fixtures.rick]))
        #expect(year(r.date) == 2004, "\(r.reason)")
        #expect(r.reason.contains("age 8"), "\(r.reason)")
        // Two people with birth years, nobody named nearby → "fits 2 known birth years"
        #expect(r.reason.contains("known birth years"), "\(r.reason)")
        let alone = pfTriangulateRecordDate(GH201Fixtures.capeCod(people: [GH201Fixtures.timmy]))
        #expect(alone.confidence >= 0.8, "corroboration should lift 0.75 → ≥ 0.8, got \(alone.confidence)")
        #expect(alone.reason.contains("age 8 fits Timmy (born 1996) → 2004–2005"), "\(alone.reason)")
        #expect(alone.confidence > pfTriangulateRecordDate(GH201Fixtures.capeCod()).confidence)
    }

    @Test("CapeCod, the subject named: 'Timmy, how old are you? eight' weighs the age as a named person")
    func capeCodNamedSubject() {
        var i = GH201Fixtures.capeCod(people: [GH201Fixtures.timmy, GH201Fixtures.rick])
        i.audioTranscript = "Say what year it is. 2004. Timmy, how old are you? Eight."
        let r = pfTriangulateRecordDate(i)
        #expect(year(r.date) == 2004, "\(r.reason)")
        #expect(r.reason.contains("age 8 fits Timmy (born 1996)"), "\(r.reason)")
        #expect(r.confidence >= 0.85, "0.65 now-cue ⊕ 0.60 named age ≈ 0.86, got \(r.confidence)")
        // The record's one tagged person is the subject when nobody is named nearby.
        var tagged = GH201Fixtures.capeCod(people: [GH201Fixtures.timmy, GH201Fixtures.rick])
        tagged.peopleOnRecord = ["Timmy"]
        #expect(pfTriangulateRecordDate(tagged).reason.contains("fits Timmy (born 1996)"))
    }

    @Test("Clip 19: '1955 or 6… On the Waterfront' is a reference, the folder says 1996, DV floor 1995 respected")
    func clip19() {
        let r = pfTriangulateRecordDate(GH201Fixtures.clip19())
        #expect(year(r.date) == 1996, "\(r.reason)")
        #expect(r.range == InferredDateRange(year: 1996))
        #expect(r.reason.contains("folder 'TimmyBaby-1996' names 1996"), "\(r.reason)")
        #expect(r.reason.contains("1955 mentioned as a reference (past), not the recording year"), "\(r.reason)")
        #expect(r.reason.contains("DV era floor 1995 respected"), "\(r.reason)")
        #expect(r.confidence < RecordDateResolver.inferredConfidenceFloor, "a folder hint alone is shown, not filed")
        // Without the folder hint the record has NO recording-year evidence.
        var bare = GH201Fixtures.clip19()
        bare.pathYearHints = []
        let none = pfTriangulateRecordDate(bare)
        #expect(none.date == nil)
        #expect(none.reason.hasPrefix("no evidence"), "\(none.reason)")
        #expect(none.reason.contains("1955 mentioned as a reference"), "\(none.reason)")
    }

    @Test("'OK Christmas 2002' + a camera stamp 2002-12-25 → 2002-12-25, high confidence, both criteria listed")
    func christmasAgreesWithCameraStamp() {
        var i = DateTriangulationInput()
        i.audioTranscript = "OK Christmas 2002, everybody say hi."
        i.embeddedCreationDate = utc(2002, 12, 25, 15)
        i.originMake = "Sony"; i.originModel = "DCR-TRV27"
        i.videoCodec = "dvvideo"
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(r.date == utc(2002, 12, 25, 15))
        #expect(r.precision == .day && r.range == nil)
        #expect(r.confidence >= 0.9, "got \(r.confidence)")
        #expect(r.reason.contains("camera stamp 2002-12-25 (Sony DCR-TRV27)"), "\(r.reason)")
        #expect(r.reason.contains("spoken now-cue"), "\(r.reason)")
        #expect(r.reason.contains("2002"), "\(r.reason)")
    }

    @Test("now-cue vs reference vs neutral classification table")
    func classification() {
        func role(_ text: String) -> SpokenYearRole? {
            pfClassifyYearMentions(in: text, now: testNow).first?.role
        }
        #expect(role("Say what year it is. 2004.") == .now)
        #expect(role("What year is it? It's 1997!") == .now)
        #expect(role("OK Christmas 2002") == .now)
        #expect(role("Happy New Year 2000!") == .now)
        #expect(role("This is 1994 at the Cape") == .now)
        #expect(role("2004 Cape trip, day one") == .now)
        #expect(role("Thanksgiving 1994 at Ma's") == .now)
        #expect(role("I think it was 1955 or 6 and it was on the waterfront") == .reference)
        #expect(role("back in 1962 we lived in Somerville") == .reference)
        #expect(role("she was born in 1929") == .reference)
        #expect(role("Dad was in Korea in 1951") == .reference)
        #expect(role("that was 1975, the year of the blizzard") == .reference)
        #expect(role("the class of 1982 reunion") == .reference)
        #expect(role("the tape says 1991 on the label") == .neutral)
        #expect(role("no year here at all") == nil)
        // Grammar shared with pfYearMentions: apostrophe years, future ceiling.
        #expect(pfClassifyYearMentions(in: "Christmas '97", now: testNow).first?.year == 1997)
        #expect(pfClassifyYearMentions(in: "in the year 2040", now: testNow).isEmpty)
    }

    @Test("age parsing: digits, number words, compound words, birthdays, 'turned'; the nearest name is the subject")
    func ages() {
        let names = ["Timmy", "Tim", "Rick", "Dad", "Ma"]
        #expect(pfAgeMentions(in: "How old are you? Eight years old.", names: names) == [SpokenAgeMention(age: 8, subject: nil)])
        #expect(pfAgeMentions(in: "Timmy, how old are you? I'm 8.", names: names) == [SpokenAgeMention(age: 8, subject: "Timmy")])
        #expect(pfAgeMentions(in: "Ma is ninety-one years old today", names: names) == [SpokenAgeMention(age: 91, subject: "Ma")])
        #expect(pfAgeMentions(in: "happy 5th birthday Tim!", names: names) == [SpokenAgeMention(age: 5, subject: "Tim")])
        #expect(pfAgeMentions(in: "he just turned six", names: names) == [SpokenAgeMention(age: 6, subject: nil)])
        #expect(pfAgeMentions(in: "that old house on the corner", names: names).isEmpty, "no number, no age")
        #expect(pfAgeMentions(in: "a 100 years old oak", names: names).isEmpty, "ages are 1…99")
        #expect(pfAgeNumber("twenty-one") == 21 && pfAgeNumber("eleven") == 11 && pfAgeNumber("7") == 7)
    }

    @Test("media-era floors: DV ≥ 1995, HDV ≥ 2003, phone/AVCHD H.264 ≥ 2006 only with a camera named; film scans exempt")
    func eraFloors() {
        #expect(pfMediaEraFloor(videoCodec: "dvvideo", container: "dv", originMake: nil, originModel: nil, fullPath: "/V/a.dv")?.year == 1995)
        #expect(pfMediaEraFloor(videoCodec: "mpeg2video", container: "mpegts", originMake: nil, originModel: nil, fullPath: "/V/a.m2t")?.year == 2003)
        #expect(pfMediaEraFloor(videoCodec: "mpeg2video", container: "mpeg", originMake: nil, originModel: nil, fullPath: "/V/dvd.mpg") == nil, "a DVD of an old tape has no floor")
        #expect(pfMediaEraFloor(videoCodec: "h264", container: "mov", originMake: "Apple", originModel: "iPhone 12", fullPath: "/V/a.mov")?.year == 2006)
        #expect(pfMediaEraFloor(videoCodec: "h264", container: "mov", originMake: "Apple", originModel: nil, fullPath: "/V/a.mov") == nil, "an H.264 EXPORT can hold anything")
        #expect(pfMediaEraFloor(videoCodec: "dvvideo", container: "dv", originMake: nil, originModel: nil, fullPath: "/V/Super8 reels/a.dv") == nil, "film scan exempt")
        // A claim below the floor is set aside and said so.
        var i = DateTriangulationInput()
        i.audioTranscript = "This is 1991 at the beach"
        i.videoCodec = "dvvideo"
        i.pathYearHints = [1997]; i.fullPath = "/V/Tapes1997/a.dv"
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(year(r.date) == 1997, "\(r.reason)")
        #expect(r.reason.contains("below the DV era floor (1995) — set aside"), "\(r.reason)")
        #expect(r.reason.contains("DV era floor 1995 applied"), "\(r.reason)")
    }

    @Test("adjacent now-cue years are one tape across a New Year: a range, not a conflict")
    func adjacentYearsMakeARange() {
        var i = DateTriangulationInput()
        i.audioTranscript = "Christmas 2003, everyone. … Happy New Year 2004! … What year is it? 2004."
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(year(r.date) == 2004, "the more-mentioned year is the point estimate: \(r.reason)")
        #expect(r.range == InferredDateRange(startYear: 2003, endYear: 2004))
        #expect(r.range?.displayString == "2003–2004")
        #expect(r.reason.contains("adjacent year, tape may span both"), "\(r.reason)")
        #expect(r.confidence >= 0.65, "no disagreement penalty: \(r.confidence)")
    }

    @Test("two now-cues that disagree: the stronger wins, confidence drops, the range widens to show it")
    func disagreementWidensTheRange() {
        var i = DateTriangulationInput()
        i.audioTranscript = "What year is it? 2004. … What year is it? 2004. … Welcome to 2010!"
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(year(r.date) == 2004, "\(r.reason)")
        #expect(r.range == InferredDateRange(startYear: 2004, endYear: 2010))
        #expect(r.confidence < 0.6, "disagreement keeps it under the filing floor: \(r.confidence)")
        #expect(r.reason.contains("but spoken now-cue"), "\(r.reason)")
        #expect(r.reason.contains("disagrees"), "\(r.reason)")
    }

    @Test("a claim AFTER the export stamp is doubtful; a camera stamp is a claim, an export stamp is only a ceiling")
    func exportCeiling() {
        var i = DateTriangulationInput()
        i.audioTranscript = "It's 2010 now. … What year is it? 2004."
        i.embeddedCreationDate = utc(2008, 10, 23)
        i.originEncoder = "Lavf58"
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(year(r.date) == 2004, "\(r.reason)")
        #expect(r.reason.contains("after the export stamp — doubtful"), "\(r.reason)")
        #expect(r.reason.contains("export stamp 2008-10-23 set aside as ingest (ffmpeg)"), "\(r.reason)")
    }

    @Test("catalog priors: a 1950s date needs two independent criteria at ≥ 0.90; 1960s is shaded; outside 1984–2016 a lone soft claim is halved")
    func priors() {
        var fifties = DateTriangulationInput()
        fifties.audioTranscript = "What year is it? 1955."
        fifties.now = testNow
        let f = pfTriangulateRecordDate(fifties)
        #expect(f.date == nil)
        #expect(f.reason.hasPrefix("no evidence"), "\(f.reason)")
        #expect(f.reason.contains("no 1950s video"), "\(f.reason)")
        // Two independent criteria at 0.90+: an on-screen date agreeing with a now-cue.
        var film = DateTriangulationInput()
        film.ocrDateCandidates = ["JUL 4 1955", "JUL 4 1955", "JUL 4 1955"]
        film.audioTranscript = "This is 1955 on the Fourth"
        film.fullPath = "/V/16mm reels/a.mov"
        film.now = testNow
        let ok = pfTriangulateRecordDate(film)
        #expect(year(ok.date) == 1955, "\(ok.reason)")
        var sixties = DateTriangulationInput()
        sixties.ocrDateCandidates = ["AUG 12 1966", "AUG 12 1966", "AUG 12 1966"]
        sixties.fullPath = "/V/film/a.mov"
        sixties.now = testNow
        let s = pfTriangulateRecordDate(sixties)
        #expect(year(s.date) == 1966)
        #expect(s.reason.contains("sparse decade"), "\(s.reason)")
        #expect(s.confidence < DateTriangulationWeights.ocrConsensus)
        var twenties = DateTriangulationInput()
        twenties.audioTranscript = "the tape says 2020 on the label"
        twenties.now = testNow
        let t = pfTriangulateRecordDate(twenties)
        #expect(year(t.date) == 2020)
        #expect(t.confidence < DateTriangulationWeights.spokenNeutral, "halved outside the window: \(t.confidence)")
    }

    @Test("burn-in tiers unchanged: ≥3 frames 0.95, 2 frames 0.85, 1 frame 0.75; day precision, no range")
    func burnInTiers() {
        func run(_ n: Int) -> DateTriangulationResult {
            var i = DateTriangulationInput()
            i.ocrDateCandidates = Array(repeating: "JUN.21 1991", count: n)
            i.now = testNow
            return pfTriangulateRecordDate(i)
        }
        #expect(run(3).confidence == 0.95 && run(2).confidence == 0.85 && run(1).confidence == 0.75)
        #expect(run(1).date == utc(1991, 6, 21) && run(1).precision == .day && run(1).range == nil)
        #expect(run(1).reason == "on-screen date 1991-06-21 ×1")
    }

    @Test("a range displays as '2004' or '2003–2004' and normalises its order")
    func rangeDisplay() {
        #expect(InferredDateRange(year: 2004).displayString == "2004")
        #expect(InferredDateRange(startYear: 2004, endYear: 2003).displayString == "2003–2004")
        #expect(InferredDateRange(startYear: 2003, endYear: 2004).contains(2004))
        #expect(!InferredDateRange(year: 2004).contains(2005))
    }
}

// MARK: - Sensors

@Suite("DateTriangulator — sensors (GH #201)")
struct DateTriangulatorSensorTests {

    @Test("SENSOR: a DV record never infers a year before 1995, whatever the content says")
    func dvNeverBefore1995() {
        let texts = ["What year is it? 1991.", "Christmas 1988", "This is 1994"]
        for t in texts {
            var i = DateTriangulationInput()
            i.audioTranscript = t
            i.videoCodec = "dvvideo"
            i.now = testNow
            let r = pfTriangulateRecordDate(i)
            if let y = year(r.date) { #expect(y >= 1995, "\(t) → \(y): \(r.reason)") }
            #expect(r.reason.contains("DV era floor"), "\(r.reason)")
        }
        var ocr = DateTriangulationInput()
        ocr.ocrDateCandidates = ["JUN 21 '91", "JUN 21 '91", "JUN 21 '91"]
        ocr.videoCodec = "dvvideo"
        ocr.now = testNow
        let r = pfTriangulateRecordDate(ocr)
        #expect(r.date == nil, "even a burn-in consensus is set aside, and the reason says so: \(r.reason)")
        #expect(r.reason.contains("below the DV era floor (1995) — set aside"), "\(r.reason)")
    }

    @Test("SENSOR: no evidence ⇒ nil with the reason 'no evidence' — a file's dates are never an inferred date")
    func noEvidenceIsNil() {
        var i = DateTriangulationInput()
        i.audioTranscript = "We went to the beach and had a picnic with the kids and grandma."
        i.sceneCaptionTexts = ["a family on a beach"]
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(r.date == nil && r.confidence == 0 && r.range == nil)
        #expect(r.reason == DateTriangulationResult.noEvidenceReason)
        #expect(pfTriangulateRecordDate(DateTriangulationInput()).reason == "no evidence")
    }

    @Test("SENSOR: an 'Apple, no model' export stamp with no content evidence is NOT an inference — the Date column still shows the stamp at 0.80")
    func appleNoModelStampAloneStillShows() {
        var i = DateTriangulationInput()
        i.embeddedCreationDate = utc(2008, 10, 23, 14)
        i.originMake = "Apple"; i.originEncoder = "H.264"; i.videoCodec = "h264"
        i.now = testNow
        let r = pfTriangulateRecordDate(i)
        #expect(r.date == nil && r.reason == "no evidence")
        let rec = VideoRecord()
        rec.filename = "CapeCod_notsure_NTSC.mov"
        rec.embeddedCreationDate = utc(2008, 10, 23, 14)
        rec.originMake = "Apple"; rec.originEncoder = "H.264"
        #expect(rec.resolvedDateDisplay == "2008-10-23")
        #expect(rec.resolvedDateSortKey == utc(2008, 10, 23, 14))
        #expect(RecordDateResolver.embeddedConfidence(originMake: "Apple", originModel: nil, originEncoder: "H.264") == 0.80)
        // A camera stamp alone is the resolver's business too.
        i.originModel = "iPhone 3G"
        #expect(pfTriangulateRecordDate(i).date == nil)
    }

    @Test("SENSOR: a user date always wins — the Date column, the resolver, and the catch-up never touch it")
    @MainActor
    func userDateAlwaysWins() throws {
        let rec = VideoRecord()
        rec.fullPath = "/V/CapeCod_notsure_NTSC.mov"; rec.filename = "CapeCod_notsure_NTSC.mov"
        rec.audioTranscript = GH201Fixtures.capeCodTranscript
        rec.embeddedCreationDate = utc(2008, 10, 23, 14); rec.originMake = "Apple"
        rec.userDate = "2003"; rec.userDateConfidence = "known"
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DateTriangulatorTests-user-\(UUID().uuidString)", isDirectory: true))
        model.dateInferencePeople = []
        model.records = [rec]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.total == 0 && result.examined == 0)
        #expect(rec.userDate == "2003" && rec.inferredRecordDate == nil)
        #expect(rec.resolvedDateDisplay == "2003")
        let r = RecordDateResolver.resolve(userDate: "2003", userDateConfidence: "known",
                                           embeddedCreationDate: rec.embeddedCreationDate, originMake: "Apple",
                                           inferredRecordDate: utc(2004, 1, 1), inferredDateConfidence: 0.95,
                                           inferredDateRange: InferredDateRange(year: 2004), filename: rec.filename)
        #expect(r.isoString == "2003" && r.source == .userDate)
    }

    @Test("the resolver files a ranged inference at YEAR precision (no fabricated Jan 1; no Angel day key)")
    func rangedInferenceIsYearPrecision() {
        let r = RecordDateResolver.resolve(userDate: nil, embeddedCreationDate: utc(2008, 10, 23), originMake: "Apple",
                                           inferredRecordDate: utc(2004, 1, 1), inferredDateConfidence: 0.75,
                                           inferredDateRange: InferredDateRange(year: 2004),
                                           filename: "CapeCod_notsure_NTSC.mov", now: testNow)
        #expect(r.isoString == "2004" && r.precision == .year && r.source == .inferred)
        let c = ArchiveAngelCandidate(filename: "CapeCod_notsure_NTSC.mov", inferredRecordDate: utc(2004, 1, 1),
                                      inferredDateConfidence: 0.75, inferredDateRange: InferredDateRange(year: 2004))
        let e = ArchiveAngelEvent.resolve(c, now: testNow)
        #expect(e.key.isEmpty && e.year == 2004, "a year is not an event")
        let day = ArchiveAngelCandidate(filename: "a.dv", inferredRecordDate: utc(1991, 6, 21), inferredDateConfidence: 0.95)
        #expect(ArchiveAngelEvent.resolve(day, now: testNow).key == "d:1991-06-21")
    }

    @Test("the Date column shows a ranged inference as its span and the tooltip carries the reason")
    func dateColumnShowsRangeAndReason() {
        let rec = VideoRecord()
        rec.fullPath = "/V/a.mov"; rec.filename = "a.mov"
        rec.inferredRecordDate = utc(2003, 1, 1)
        rec.inferredDateConfidence = 0.7
        rec.inferredDateRange = InferredDateRange(startYear: 2003, endYear: 2004)
        rec.inferredDateReason = "spoken now-cue 'christmas… 2003'; spoken now-cue 'new year… 2004' — adjacent year, tape may span both"
        #expect(rec.resolvedDateDisplay == "2003–2004")
        #expect(rec.resolvedDateHelp.contains("Why (70% sure): spoken now-cue"), "\(rec.resolvedDateHelp)")
        // CapeCod: the displaced export stamp shows the inferred year with its reason.
        let cape = VideoRecord()
        cape.filename = "CapeCod_notsure_NTSC.mov"
        cape.embeddedCreationDate = utc(2008, 10, 23, 14); cape.originMake = "Apple"; cape.originEncoder = "H.264"
        cape.inferredRecordDate = utc(2004, 1, 1); cape.inferredDateConfidence = 0.75
        cape.inferredDateRange = InferredDateRange(year: 2004)
        cape.inferredDateReason = "spoken now-cue 'what year it is… 2004' ×3; export stamp 2008-10-23 set aside as ingest (Apple, no model)"
        #expect(cape.resolvedDateDisplay == "2004")
        #expect(cape.resolvedDateHelp.contains("set aside as ingest"), "\(cape.resolvedDateHelp)")
        #expect(cape.resolvedDateSortKey == utc(2004, 1, 1, 0))
    }
}

// MARK: - Isolation

@Suite("DateTriangulator — isolation")
struct DateTriangulatorIsolationTests {

    @Test("no People profiles ⇒ ages are neutral: same date, lower confidence, no age line in the reason")
    func noPeopleAgesNeutral() {
        let none = pfTriangulateRecordDate(GH201Fixtures.capeCod(people: []))
        let some = pfTriangulateRecordDate(GH201Fixtures.capeCod(people: [GH201Fixtures.timmy]))
        #expect(year(none.date) == 2004 && year(some.date) == 2004)
        #expect(!none.reason.contains("age 8"), "\(none.reason)")
        #expect(some.reason.contains("age 8"), "\(some.reason)")
        #expect(none.confidence < some.confidence)
        // A profile whose age window would be in the future never claims.
        let baby = DateTriangulationPerson(name: "Baby", aliases: [], birthYear: 2025)
        #expect(!pfTriangulateRecordDate(GH201Fixtures.capeCod(people: [baby])).reason.contains("age 8"))
    }

    @Test("a model under test never reads the real People store; an injected list is used as-is")
    @MainActor
    func modelUnderTestNeverReadsRealPeople() throws {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DateTriangulatorTests-iso-\(UUID().uuidString)", isDirectory: true))
        #expect(TestEnvironment.isTestHost)
        #expect(model.dateInferencePeopleResolved.isEmpty, "the real POI store must not be read under a test host")
        model.dateInferencePeople = [GH201Fixtures.timmy]
        #expect(model.dateInferencePeopleResolved == [GH201Fixtures.timmy])
    }
}

// MARK: - Scale

@Suite("DateTriangulator — scale")
struct DateTriangulatorScaleTests {

    @Test("100k records through the pure triangulator inside budget (regexes compiled once; pure, off the main actor)",
          .timeLimit(.minutes(2)))
    func hundredThousand() {
        let transcripts = [
            GH201Fixtures.capeCodTranscript,
            GH201Fixtures.clip19Transcript,
            "We went to the beach and had a picnic with the kids and grandma.",
            "OK Christmas 2002, everybody say hi. Ma is ninety-one years old today.",
            "",
        ]
        let codecs = ["dvvideo", "h264", "prores", "mpeg2video"]
        let people = [GH201Fixtures.timmy, GH201Fixtures.rick]
        var inputs: [DateTriangulationInput] = []
        inputs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            var input = DateTriangulationInput()
            input.audioTranscript = transcripts[i % transcripts.count]
            input.videoCodec = codecs[i % codecs.count]
            input.fullPath = i % 3 == 0 ? "/V/Tapes1997/clip\(i).mov" : "/V/clip\(i).mov"
            input.pathYearHints = i % 3 == 0 ? [1997] : []
            if i % 4 == 0 { input.embeddedCreationDate = utc(2008, 10, 23); input.originMake = "Apple" }
            if i % 7 == 0 { input.ocrDateCandidates = ["JUN.21 1991"] }
            input.people = i % 2 == 0 ? people : []
            input.now = testNow
            inputs.append(input)
        }
        let clock = ContinuousClock()
        var dated = 0
        let elapsed = clock.measure {
            for input in inputs where pfTriangulateRecordDate(input).date != nil { dated += 1 }
        }
        print("[date-triangulator] 100k in \(elapsed), \(dated) dated")
        #expect(dated > 40_000)
        // Measured 2026-09-26 (Debug, M4 Max): well under 10 s; 30 s trips
        // only on a complexity regression (a regex compiled per call, a
        // per-year scan over the whole transcript…).
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(30)), "100k triangulations took \(elapsed)")
    }
}

// MARK: - Model level: catch-up + footage-group sharing

@MainActor
@Suite("DateInference — GH #201 catch-up re-triangulation and footage-group sharing")
struct DateInferenceGH201Tests {

    private func scratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DateInferenceGH201Tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(_ dir: URL, people: [DateTriangulationPerson] = []) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        model.dateInferencePeople = people
        return model
    }

    private func membership(_ group: UUID, rank: Int, original: UUID,
                            confidence: FootageConfidence = .likely) -> FootageMembership {
        FootageMembership(groupID: group, groupSize: 2, confidence: confidence,
                          role: rank == 0 ? .original : .export, rank: rank, likelyOriginalID: original,
                          originalInCatalog: true, evidence: ["same name + length"],
                          scannedAt: testNow, algorithmVersion: 1)
    }

    /// CapeCod as the catalog holds it: an export with the transcript, and
    /// its footage-group twin with no transcript and the old 0.30 mtime
    /// "inference".
    private func capeCodPair(confidence: FootageConfidence = .likely) -> (cape: VideoRecord, twin: VideoRecord) {
        let group = UUID()
        let cape = VideoRecord()
        cape.fullPath = "/Volumes/LaCie/Exports/CapeCod_notsure_NTSC.mov"; cape.filename = "CapeCod_notsure_NTSC.mov"
        cape.directory = "/Volumes/LaCie/Exports"
        cape.streamTypeRaw = StreamType.videoAndAudio.rawValue
        cape.audioTranscript = GH201Fixtures.capeCodTranscript
        cape.embeddedCreationDate = utc(2008, 10, 23, 14); cape.originMake = "Apple"; cape.originEncoder = "H.264"
        cape.videoCodec = "h264"; cape.container = "mov,mp4,m4a,3gp,3g2,mj2"
        cape.footage = membership(group, rank: 0, original: cape.id, confidence: confidence)
        let twin = VideoRecord()
        twin.fullPath = "/Volumes/X9/Restored/CapeCod_notsure_NTSC.mov"; twin.filename = "CapeCod_notsure_NTSC.mov"
        twin.directory = "/Volumes/X9/Restored"
        twin.streamTypeRaw = StreamType.videoAndAudio.rawValue
        twin.embeddedCreationDate = utc(2008, 10, 23, 14); twin.originMake = "Apple"; twin.originEncoder = "H.264"
        twin.videoCodec = "h264"
        twin.inferredRecordDate = utc(2008, 10, 23, 14); twin.inferredDateConfidence = 0.30   // the mtime fallback
        twin.footage = membership(group, rank: 1, original: cape.id, confidence: confidence)
        return (cape, twin)
    }

    @Test("SENSOR (CapeCod): the export dates itself 2004 with a reason; its footage-group twin inherits 2004 'shared from … (same footage)'; both Date cells read 2004")
    func capeCodTwinInheritsTheGroupsDate() throws {
        let dir = try scratchDir("capecod")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir, people: [GH201Fixtures.timmy])
        let (cape, twin) = capeCodPair()
        model.records = [cape, twin]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.cleared == 1, "the twin's 2008 @0.30 was the mtime wearing the inferred label")
        #expect(result.inferredFromEvidence == 1 && result.footageShared == 1)
        #expect(year(cape.inferredRecordDate) == 2004)
        #expect((cape.inferredDateConfidence ?? 0) >= 0.7)
        #expect(cape.inferredDateReason?.contains("export stamp 2008-10-23 set aside as ingest") == true, "\(cape.inferredDateReason ?? "nil")")
        #expect(cape.inferredDateReason?.contains("age 8 fits Timmy (born 1996)") == true, "\(cape.inferredDateReason ?? "nil")")
        #expect(year(twin.inferredRecordDate) == 2004)
        #expect(twin.inferredDateRange == InferredDateRange(year: 2004))
        #expect(twin.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: cape))
        #expect(twin.inferredDateReason?.hasPrefix("shared from CapeCod_notsure_NTSC.mov (same footage)") == true, "\(twin.inferredDateReason ?? "nil")")
        #expect(twin.inferredDateReason?.contains("own evidence said 2008") == true, "\(twin.inferredDateReason ?? "nil")")
        // The Date column: the export stamps are set aside on both rows.
        #expect(cape.resolvedDateDisplay == "2004", "\(cape.resolvedDateDisplay)")
        #expect(twin.resolvedDateDisplay == "2004", "\(twin.resolvedDateDisplay)")
        #expect(twin.resolvedDateHelp.contains("shared from"), "\(twin.resolvedDateHelp)")
        // Idempotent.
        let again = model.catchUpInferredDates(trigger: "test")
        #expect(again.total == 0 && again.cleared == 0, "\(again)")
    }

    @Test("a member's user date is the group's strongest claim: the others inherit 'your date'; the user's row is never written")
    func userDateLeadsTheGroup() throws {
        let dir = try scratchDir("user")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let (cape, twin) = capeCodPair()
        twin.userDate = "2003-07"; twin.userDateConfidence = "estimated"
        twin.inferredRecordDate = nil; twin.inferredDateConfidence = nil
        model.records = [cape, twin]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.footageShared == 1)
        #expect(twin.userDate == "2003-07" && twin.inferredRecordDate == nil, "Rick's row is never written")
        #expect(year(cape.inferredRecordDate) == 2003, "\(cape.inferredDateReason ?? "nil")")
        #expect(cape.inferredDateReason?.contains("your date July 2003") == true, "\(cape.inferredDateReason ?? "nil")")
        #expect(cape.inferredDateReason?.contains("own evidence said 2004") == true, "\(cape.inferredDateReason ?? "nil")")
        #expect(cape.resolvedDateDisplay == "2003", "the group's date, shown as a year")
    }

    @Test("a 'possible' footage group does not share; a stale share is cleared when the donor leaves the group")
    func possibleGroupsAndStaleShares() throws {
        let dir = try scratchDir("stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let (cape, twin) = capeCodPair(confidence: .possible)
        model.records = [cape, twin]
        let r1 = model.catchUpInferredDates(trigger: "test")
        #expect(r1.footageShared == 0 && twin.inferredRecordDate == nil, "possible ⇒ no share (twin cleared, then nothing)")
        // Upgrade the group, share, then split it: the twin's date goes away.
        cape.footage?.confidence = .likely; twin.footage?.confidence = .likely
        #expect(model.catchUpInferredDates(trigger: "test").footageShared == 1)
        #expect(year(twin.inferredRecordDate) == 2004)
        twin.footage = nil
        let r3 = model.catchUpInferredDates(trigger: "test")
        #expect(r3.cleared == 1 && twin.inferredRecordDate == nil && twin.inferredDateSource == nil)
    }

    @Test("a footage-shared row never donates to byte twins and re-derives when the group's best changes")
    func sharedRowsAreDerived() throws {
        let dir = try scratchDir("derived")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let (cape, twin) = capeCodPair()
        model.records = [cape, twin]
        model.catchUpInferredDates(trigger: "test")
        #expect(!VideoScanModel.canDonateInferredDate(twin))
        // Rick dates the twin: it becomes the strongest claim; CapeCod follows.
        twin.userDate = "2005"
        model.catchUpInferredDates(trigger: "test")
        #expect(year(cape.inferredRecordDate) == 2005, "\(cape.inferredDateReason ?? "nil")")
        #expect(cape.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: twin))
    }

    @Test("a legacy 1955 (Clip 19) is re-triangulated to 1996 with the reason; a new transcript refreshes a scoped row")
    func clip19AndRefresh() throws {
        let dir = try scratchDir("clip19")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let clip = VideoRecord()
        clip.fullPath = "/Volumes/LaCie/TimmyBaby-1996/Media/Clip 19.dv"; clip.filename = "Clip 19.dv"
        clip.directory = "/Volumes/LaCie/TimmyBaby-1996/Media"
        clip.streamTypeRaw = StreamType.videoAndAudio.rawValue
        clip.videoCodec = "dvvideo"; clip.container = "dv"
        clip.audioTranscript = GH201Fixtures.clip19Transcript
        clip.dateModifiedRaw = utc(2002, 8, 31)
        clip.inferredRecordDate = utc(1955, 1, 1); clip.inferredDateConfidence = 0.55   // the old answer
        model.records = [clip]
        let r = model.catchUpInferredDates(trigger: "test")
        #expect(r.retriangulated == 1)
        #expect(year(clip.inferredRecordDate) == 1996, "\(clip.inferredDateReason ?? "nil")")
        #expect(clip.inferredDateReason?.contains("1955 mentioned as a reference (past), not the recording year") == true)
        #expect(clip.inferredDateReason?.contains("DV era floor 1995 respected") == true)
        #expect(clip.resolvedDateDisplay == "1996")
        // A later transcript with a now-cue lands: the scoped refresh re-derives.
        clip.audioTranscript = GH201Fixtures.clip19Transcript + " What year is it? 1997."
        let r2 = model.catchUpInferredDates(scope: [clip], trigger: "transcript", refreshScope: true)
        #expect(r2.retriangulated == 1)
        #expect(year(clip.inferredRecordDate) == 1997, "\(clip.inferredDateReason ?? "nil")")
    }

    @Test("applyDossier writes the triangulation: reason + range, source nil; no filesystem fallback")
    func applyDossierWritesTheReason() throws {
        let dir = try scratchDir("dossier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/V/Christmas2010/clip.mov"; rec.filename = "clip.mov"; rec.directory = "/Volumes/V/Christmas2010"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.dateModifiedRaw = utc(2026, 1, 1); rec.dateCreatedRaw = utc(2026, 1, 1)
        model.records = [rec]
        let empty = DossierExtraction(scenes: [SceneCaption(timestamp: 0, text: "a tree")], dates: [], texts: [])
        #expect(model.applyDossier(empty, to: rec.fullPath, vlmModel: "vlm", transcript: "Merry Christmas everybody", whisperModel: "w"))
        #expect(year(rec.inferredRecordDate) == 2010, "\(rec.inferredDateReason ?? "nil")")
        #expect(rec.inferredDateReason?.contains("folder 'Christmas2010' names 2010") == true)
        #expect(rec.inferredDateSource == nil && rec.inferredDateRange == InferredDateRange(year: 2010))
        let none = DossierExtraction(scenes: [SceneCaption(timestamp: 0, text: "a tree")], dates: [], texts: [])
        let bare = VideoRecord()
        bare.fullPath = "/Volumes/V/clips/clip2.mov"; bare.filename = "clip2.mov"; bare.directory = "/Volumes/V/clips"
        bare.streamTypeRaw = StreamType.videoAndAudio.rawValue
        bare.dateModifiedRaw = utc(2026, 1, 1)
        model.records = [rec, bare]
        #expect(model.applyDossier(none, to: bare.fullPath, vlmModel: "vlm", transcript: "hello", whisperModel: "w"))
        #expect(bare.inferredRecordDate == nil, "the file's 2026 copy date is never an inferred date")
        #expect(bare.inferredDateReason == "no evidence")
    }
}

// MARK: - Inspector: the inferred line (pure text)

@Suite("Inspector — the machine's guess line (GH #201 #7)")
struct InspectorInferredDateLineTests {

    @Test("the line shows the span, how sure, and the reason; 'No guess' when examined and empty; nothing before any pass")
    func inferredSummary() {
        let cape = VideoRecord()
        cape.inferredRecordDate = utc(2004, 1, 1)
        cape.inferredDateConfidence = 0.83
        cape.inferredDateRange = InferredDateRange(year: 2004)
        cape.inferredDateReason = "spoken now-cue 'what year it is… 2004' ×3; export stamp 2008-10-23 set aside as ingest (Apple, no model)"
        #expect(InspectorDateView.inferredSummary(cape) == "Guess: 2004 (83% sure) — spoken now-cue 'what year it is… 2004' ×3; export stamp 2008-10-23 set aside as ingest (Apple, no model)")

        let span = VideoRecord()
        span.inferredRecordDate = utc(2003, 1, 1); span.inferredDateConfidence = 0.7
        span.inferredDateRange = InferredDateRange(startYear: 2003, endYear: 2004)
        span.inferredDateReason = "r"
        #expect(InspectorDateView.inferredSummary(span)?.hasPrefix("Guess: 2003–2004 (70% sure)") == true)

        let day = VideoRecord()
        day.inferredRecordDate = utc(1991, 6, 21); day.inferredDateConfidence = 0.95
        day.inferredDateReason = "on-screen date 1991-06-21 ×3"
        #expect(InspectorDateView.inferredSummary(day) == "Guess: 1991-06-21 (95% sure) — on-screen date 1991-06-21 ×3")

        let none = VideoRecord()
        none.inferredDateReason = "no evidence"
        #expect(InspectorDateView.inferredSummary(none) == "No guess — no evidence")

        let legacy = VideoRecord()
        legacy.inferredRecordDate = utc(1991, 6, 21); legacy.inferredDateConfidence = 0.75
        #expect(InspectorDateView.inferredSummary(legacy) == "Guess: 1991-06-21 (75% sure) — from an earlier pass, no written reason")

        #expect(InspectorDateView.inferredSummary(VideoRecord()) == nil)
    }
}

// MARK: - In-house QA review of GH #201 (M1–M3 + the unwind minor)

@MainActor
@Suite("QA review — GH #201 date branch (M1–M3, unwind)")
struct DateTriangulatorQAReviewTests {

    private func model(_ label: String) -> VideoScanModel {
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DateQAReview-\(label)-\(UUID().uuidString)", isDirectory: true))
        m.dateInferencePeople = []
        return m
    }

    private func rec(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    /// M1: a folder-year placeholder that gains evidence must SETTLE as a
    /// catch-up — not keep "folder-year" and be re-examined every launch.
    @Test func folderYearPlaceholderGainingEvidenceSettles() {
        let m = model("m1")
        let r = rec("/Volumes/V/1991/NV12.mkv")
        r.inferredRecordDate = pfJanuaryFirst(of: 1991)
        r.inferredDateConfidence = 0.30
        r.inferredDateSource = VideoScanModel.InferredDateSource.folderYear
        r.ocrDateCandidates = [SceneCaption(timestamp: 193, text: "JUN.21 1991 PM11:29")]
        m.records = [r]
        m.catchUpInferredDates(trigger: "test")
        #expect(r.inferredRecordDate == utc(1991, 6, 21))
        #expect(r.inferredDateSource == VideoScanModel.InferredDateSource.catchUp, "\(r.inferredDateSource ?? "nil")")
        #expect(VideoScanModel.hasSettledInferredDate(r))
        let second = m.catchUpInferredDates(trigger: "test")
        #expect(second.total == 0 && second.retriangulated == 0, "\(second)")
    }

    /// M2: a live reload carries the span and the reason with the date.
    @Test func liveReloadCarriesRangeAndReason() {
        let m = model("m2")
        let mem = rec("/Volumes/V/a.mov")
        mem.inferredRecordDate = pfJanuaryFirst(of: 2003)
        mem.inferredDateConfidence = 0.7
        mem.inferredDateRange = InferredDateRange(startYear: 2003, endYear: 2004)
        mem.inferredDateReason = "old"
        mem.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        m.records = [mem]
        let fresh = rec("/Volumes/V/a.mov")   // matched by path
        fresh.inferredRecordDate = utc(1991, 6, 21)
        fresh.inferredDateConfidence = 0.95
        fresh.inferredDateReason = "on-screen date 1991-06-21 ×3"
        fresh.dossierProcessedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(m.mergeDossierFields(from: [fresh]) == 1)
        #expect(mem.inferredDateRange == nil)
        #expect(mem.inferredDateReason == "on-screen date 1991-06-21 ×3")
        #expect(mem.resolvedDateDisplay == "1991-06-21", "got \(mem.resolvedDateDisplay)")
    }
}
