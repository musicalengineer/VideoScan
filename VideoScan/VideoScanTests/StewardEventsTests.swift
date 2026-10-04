// StewardEventsTests.swift
// The EVENTS lane of the Triage tab's suggestions (trial UI, 2026-10-03;
// Rick: "it should help find events, groups of similar events in time").
//
// What is pinned:
//   * An event = the labeller's own (occasion, person, year): a holiday
//     from a trusted day, a People-tab birthday, a word in a file or folder
//     name with the year. The labels and the trusted day are the Angel's
//     (ArchiveAngelEvent.derive over VideoScanCore.EventLabeler), asked
//     through the Angel's front door (ArchiveAngel.OccasionReader) — a
//     parity test holds the steward to the Angel's answer.
//   * A clip with several labels is in each event; a footage sibling with
//     no conflicting date is pulled in "by matching footage".
//   * Days nobody has named: ≥ 4 clips on one trusted day (or up to three
//     days running) with no label.
//   * Order: events, days to name, same footage, reclaim space, junk; the
//     filter and "By year".
//   * Skip keys are stable across rebuilds.
//   * The Same-footage title guess is the labeller's majority among dated
//     members; a tie, a reset-clock 1 January, a copy-era stamp, a year
//     range and a file-system date give no guess.
//
// Five dimensions: Logic (here) · Scale (StewardEventsScaleTests below +
// StewardScaleTests) · Media matrix N/A (catalog metadata only) · Isolation
// (the skip memory runs against its own UserDefaults suite) · Sensor
// (StewardSensorTests).
//
// PUBLIC REPO: every name and date below is synthetic ("Alex", "Sam", "Jo").
//
// Suites: StewardEventsLogicTests · StewardEventsOrderTests ·
//         StewardFootageGuessTests · StewardEventsScaleTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let mounted: Set<String> = ["/", "/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9"]
private let volumes = [
    AnalyzeVolumeFact(root: "/Volumes/SanDisk", isReachable: true, isRetired: false),
    AnalyzeVolumeFact(root: "/Volumes/LaCie", isReachable: true, isRetired: false),
    AnalyzeVolumeFact(root: "/Volumes/X9", isReachable: true, isRetired: false),
]

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date(timeIntervalSince1970: 0)
}

/// A fixed "now" (2026): it only bounds the resolver's search for a year in a name.
private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

private let family = [
    FamilyBirthday(name: "Alex", born: EventDay(year: 1982, month: 6, day: 10)),
    FamilyBirthday(name: "Sam", born: EventDay(year: 1985, month: 9, day: 2)),
    FamilyBirthday(name: "Jo", born: EventDay(year: 1955, month: 3, day: 20)),
]

/// The steward's side: the Angel's front door, built-in rules.
private func reader(_ birthdays: [FamilyBirthday] = family) -> ArchiveAngel.OccasionReader {
    ArchiveAngel.OccasionReader(birthdays: birthdays)
}

/// The Angel's side of the parity test: its own context, labels on. (The
/// test target may name the Angel's inside; Steward/ may not —
/// ArchiveAngelBoundarySensorTests.)
private func angelContext(_ birthdays: [FamilyBirthday] = family) -> ArchiveAngelEventContext {
    var rules = AngelCoverageRules.standard
    rules.eventLabels = true
    return ArchiveAngelEventContext(coverage: rules, birthdays: birthdays)
}

/// The day SPELLED in the Angel's event key ("e:christmas:1994|d:1994-12-25"
/// → 25 Dec 1994; nil when the key carries no day). The steward read its
/// day this way until 2026-10-03; it is kept here as the independent side
/// of the parity test for the reader's typed day.
private func dayInAngelKey(_ key: String) -> EventDay? {
    guard !key.isEmpty, let part = key.split(separator: ArchiveAngelEvent.keySeparator).last,
          part.hasPrefix("d:") else { return nil }
    let numbers = part.dropFirst(2).split(separator: "-").compactMap { Int($0) }
    guard numbers.count == 3 else { return nil }
    return EventDay(year: numbers[0], month: numbers[1], day: numbers[2])
}

private func build(_ inputs: [StewardInput], birthdays: [FamilyBirthday] = family,
                   skipped: [String: StewardFacts] = [:]) -> StewardQueue {
    StewardCaseBuilder.build(inputs: inputs, volumes: volumes, mountedRoots: mounted, alsoCleanUpWorkingCopies: false,
                             events: reader(birthdays), skipped: skipped, calendar: utc, now: fixedNow)
}

/// A clip whose date a person typed ("1994-12-25", "1994", or none).
private func clip(_ path: String, on userDate: String? = nil, seconds: Double = 60) -> StewardInput {
    StewardInput(fullPath: path, durationSeconds: seconds, userDate: userDate)
}

private func events(_ q: StewardQueue) -> [StewardCase] { q.cases.filter { $0.kind == .event } }
private func days(_ q: StewardQueue) -> [StewardCase] { q.cases.filter { $0.kind == .unlabelledDay } }

// MARK: - Logic

@Suite("Steward events — occasions the catalog can already name")
struct StewardEventsLogicTests {

    // Each label kind

    @Test func aHolidayGathersItsDaysAndTheFolderThatNamesIt() throws {
        let a = clip("/Volumes/LaCie/tapes/a.mov", on: "1994-12-24")
        let b = clip("/Volumes/SanDisk/tapes/b.mov", on: "1994-12-25")
        let c = clip("/Volumes/SanDisk/xmas94/tape2.mov", on: "1994")
        let q = build([c, b, a])
        let e = try #require(events(q).first)
        #expect(events(q).count == 1 && days(q).isEmpty)
        #expect(e.id == "event:christmas:-:1994" && e.title == "Christmas 1994")
        #expect(e.eventKind == "christmas" && e.eventYear == 1994)
        #expect(e.detail == "3 clips · 2 drives · 3 m · Dec 24–25, 1994")
        #expect(e.whyLine == "2 by date · 1 by folder name 'xmas'")
        #expect(e.recordIDs == [a.id, b.id, c.id], "by day, then the ones with no day")
        #expect(e.copies.map(\.reason) == ["Dec 24 — Christmas Eve", "Dec 25 — Christmas", "folder name says 'xmas'"],
                "the labeller's own reason lines")
        #expect(e.memberCount == 3 && e.facts == StewardFacts(bytes: 3, count: 3) && e.durationSeconds == 180)
        #expect(e.driveRoot == nil && e.estimate == nil && e.keeperID == nil, "nothing on an event card points at a cleanup")
    }

    @Test func aBirthdayNamesThePersonAndTheNumber() throws {
        let q = build([clip("/Volumes/LaCie/tapes/a.mov", on: "1994-06-12"),
                       clip("/Volumes/LaCie/tapes/b.mov", on: "1994-06-10")])
        let e = try #require(events(q).first)
        #expect(e.id == "event:birthday:alex:1994")
        #expect(e.title == "Alex's 12th birthday")
        #expect(e.eventKind == "birthday", "the log's word is the kind — never the person")
        #expect(e.copies.map(\.reason) == ["on Alex's 12th birthday", "2 days after Alex's 12th birthday"])
        #expect(e.whyLine == "2 by date")
        #expect(e.detail == "2 clips · 1 drive · 2 m · Jun 10–12, 1994")
        // Without the People tab's birthdays the same clips are just a day.
        #expect(events(build([clip("/Volumes/LaCie/tapes/a.mov", on: "1994-06-12")], birthdays: [])).isEmpty)
    }

    @Test func aWordInAFolderNameNeedsOnlyAYear() throws {
        let q = build([clip("/Volumes/LaCie/Cape/a.mov", on: "1996-07-14"),
                       clip("/Volumes/LaCie/Cape/b.mov", on: "1996"),
                       clip("/Volumes/LaCie/Cape/undated.mov"),
                       clip("/Volumes/SanDisk/bday party/c.mov", on: "1996"),
                       clip("/Volumes/SanDisk/bday party/d.mov", on: "1996")])
        let cape = try #require(events(q).first { $0.eventKind == "cape" })
        #expect(cape.id == "event:cape:-:1996" && cape.title == "Cape 1996", "the labeller's own display wording")
        #expect(cape.memberCount == 2, "a word with no year is not an event")
        #expect(cape.whyLine == "2 by folder name 'cape'")
        #expect(cape.detail == "2 clips · 1 drive · 2 m · Jul 14, 1996")
        let party = try #require(events(q).first { $0.eventKind == "birthday" })
        #expect(party.id == "event:birthday:-:1996" && party.title == "Birthday 1996", "a name knows no person")
        #expect(party.detail == "2 clips · 1 drive · 2 m · 1996", "no trusted day: the year alone")
    }

    @Test func newYearsEveBelongsToTheNewYear() throws {
        let q = build([clip("/Volumes/LaCie/t/eve.mov", on: "1994-12-31"), clip("/Volumes/LaCie/t/day.mov", on: "1995-01-01")])
        let e = try #require(events(q).first)
        #expect(events(q).count == 1)
        #expect(e.id == "event:newyear:-:1995" && e.title == "New Year 1995")
        #expect(e.detail == "2 clips · 1 drive · 2 m · Dec 31, 1994 – Jan 1, 1995")
    }

    /// F12: a Feb 29 birthday — kept on Feb 28 in a common year, on the
    /// 29th in a leap year (the labeller's rule, seen through the steward).
    @Test func aLeapDayBirthdayIsAnEventInCommonAndLeapYears() throws {
        let leap = [FamilyBirthday(name: "Jo", born: EventDay(year: 1984, month: 2, day: 29))]
        let common = try #require(events(build([clip("/Volumes/LaCie/t/a.mov", on: "1995-02-28"),
                                                clip("/Volumes/LaCie/t/b.mov", on: "1995-03-01")], birthdays: leap)).first)
        #expect(common.id == "event:birthday:jo:1995" && common.title == "Jo's 11th birthday")
        #expect(common.copies.map(\.reason) == ["on Jo's 11th birthday", "1 day after Jo's 11th birthday"])
        let leapYear = try #require(events(build([clip("/Volumes/LaCie/t/c.mov", on: "1996-02-29"),
                                                  clip("/Volumes/LaCie/t/d.mov", on: "1996-02-28")], birthdays: leap)).first)
        #expect(leapYear.id == "event:birthday:jo:1996" && leapYear.title == "Jo's 12th birthday")
        #expect(leapYear.copies.map(\.reason) == ["1 day before Jo's 12th birthday", "on Jo's 12th birthday"])
    }

    // The Angel's trusted day, and the one filter on it

    /// QA F3: the expected side is the Angel's OWN projection of a real
    /// VideoRecord (ArchiveAngelCandidate+Record.swift, the one its Occasion
    /// line uses) — not a hand copy of what `place` builds — so a date fact
    /// the steward's projection drops, renames or the Angel starts reading
    /// shows up here as a difference.
    @MainActor
    @Test func theLabelsAndTheDayAreTheAngelsOwn() {
        func record(_ path: String, _ setUp: (VideoRecord) -> Void) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = path
            r.filename = (path as NSString).lastPathComponent
            r.directory = (path as NSString).deletingLastPathComponent
            setUp(r)
            return r
        }
        // (record, labelled?) — every date fact RecordDateResolver reads is exercised.
        let fixtures: [(VideoRecord, Bool)] = [
            (record("/Volumes/LaCie/xmas94/tape2.mov") { $0.userDate = "1994-12-25" }, true),
            (record("/Volumes/LaCie/Cape/a.mov") { $0.userDate = "1996-07-04"; $0.userDateConfidence = UserDateConfidence.known.rawValue }, true),
            (record("/Volumes/LaCie/tapes/b.mov") { $0.userDate = "1994-06-12" }, true),
            (record("/Volumes/LaCie/tapes/cam.mov") { $0.embeddedCreationDate = day(2006, 11, 23); $0.originModel = "Camcorder" }, true),
            (record("/Volumes/LaCie/tapes/gopro.mov") { $0.embeddedCreationDate = day(2006, 10, 31); $0.originMake = "GoPro" }, true),
            (record("/Volumes/LaCie/tapes/unknown.mov") { $0.embeddedCreationDate = day(2006, 12, 24) }, true),
            (record("/Volumes/LaCie/tapes/inferred.mov") { $0.inferredRecordDate = day(2006, 10, 31); $0.inferredDateConfidence = 0.9 }, true),
            (record("/Volumes/LaCie/tapes/2003-12-25 morning.mov") { _ in }, true),
            (record("/Volumes/LaCie/xmas/year.mov") { $0.userDate = "1994"; $0.embeddedCreationDate = day(1994, 12, 26)
                                                      $0.originModel = "Camcorder" }, true),
            // Not good enough to place — the two must agree on that too.
            (record("/Volumes/LaCie/tapes/export.mov") { $0.embeddedCreationDate = day(2006, 12, 25); $0.originEncoder = "Lavf58.29.100" }, false),
            (record("/Volumes/LaCie/tapes/apple.mov") { $0.embeddedCreationDate = day(2006, 12, 25); $0.originMake = "Apple" }, false),
            (record("/Volumes/LaCie/tapes/range.mov") { $0.inferredRecordDate = day(2006, 12, 25); $0.inferredDateConfidence = 0.9
                                                        $0.inferredDateRange = InferredDateRange(startYear: 2005, endYear: 2007) }, false),
            (record("/Volumes/LaCie/tapes/weak.mov") { $0.inferredRecordDate = day(2006, 12, 25); $0.inferredDateConfidence = 0.3 }, false),
        ]
        var folders = EventLabeler.FolderWordCache()
        for (r, labelled) in fixtures {
            // The Angel's side: its own projection of the record.
            let candidate = ArchiveAngelCandidate(recommendationFactsOf: r)
            let angels = ArchiveAngelEvent.labels(candidate, now: fixedNow, context: angelContext())
            let key = ArchiveAngelEvent.resolve(candidate, now: fixedNow, context: angelContext()).key
            // The steward's side: its own projection of the same record.
            let input = StewardInput(record: r, protection: .none, calendar: utc)
            let mine = StewardEvents.place(input, now: fixedNow, reader: reader(), folders: &folders)
            #expect(mine.labels == angels, "\(r.filename): the labels differ from the Angel's")
            #expect(angels.contains { $0.key != nil } == labelled, "\(r.filename): fixture labelled = \(labelled)")
            #expect(mine.day == dayInAngelKey(key), "\(r.filename): the day is the one in the Angel's key")
            #expect((mine.day != nil) == key.contains("d:"), "\(r.filename): a day exactly when the Angel's key has one")
        }
    }

    /// The reader's day is TYPED (QA F4 — nobody outside the Angel parses
    /// its key), and it is the day the key spells.
    @Test func theDayComesOutOfTheAngelsKey() {
        #expect(dayInAngelKey("e:christmas:1994|d:1994-12-25") == EventDay(year: 1994, month: 12, day: 25))
        #expect(dayInAngelKey("d:1994-11-24") == EventDay(year: 1994, month: 11, day: 24))
        #expect(dayInAngelKey("e:christmas:1994") == nil, "a name word with a year has no day")
        #expect(dayInAngelKey("") == nil)
        var folders = EventLabeler.FolderWordCache()
        func read(_ r: StewardInput, with door: ArchiveAngel.OccasionReader = reader()) -> ArchiveAngel.Occasions {
            door.occasions(for: StewardEvents.facts(r), now: fixedNow, folders: &folders)
        }
        let christmas = read(clip("/Volumes/LaCie/t/a.mov", on: "1994-12-25"))
        #expect(christmas.day == EventDay(year: 1994, month: 12, day: 25))
        #expect(christmas.year == 1994 && christmas.isPersonDated)
        #expect(christmas.labels.map(\.key) == ["e:christmas:1994"])
        let plainDay = read(clip("/Volumes/LaCie/t/b.mov", on: "1994-11-02"))
        #expect(plainDay.day == EventDay(year: 1994, month: 11, day: 2) && plainDay.labels.isEmpty)
        let yearOnly = read(clip("/Volumes/LaCie/xmas/c.mov", on: "1994"))
        #expect(yearOnly.day == nil && yearOnly.year == 1994, "a name word with a year has no day")
        #expect(yearOnly.labels.map(\.key) == ["e:christmas:1994"])
        #expect(read(clip("/Volumes/LaCie/t/d.mov")) == ArchiveAngel.Occasions(), "nothing dates it, nothing names it")
        let half = read(clip("/Volumes/LaCie/t/jpegvideocomplement_1.mov", on: "1994-12-25"))
        #expect(half == ArchiveAngel.Occasions(isLivePhotoMotion: true), "a Live Photo half carries nothing else")
        // A policy with the Angel's event labels OFF still names the
        // occasion for a reader (labels are forced on in a copy).
        let off = read(clip("/Volumes/LaCie/t/a.mov", on: "1994-12-25"),
                       with: ArchiveAngel.OccasionReader(coverage: .off, birthdays: []))
        #expect(off.labels.map(\.key) == ["e:christmas:1994"])
    }

    /// Events QA F2 (2026-10-03): the date resolver reads a phone's stamp
    /// as UTC, so New Year's Eve evening in the US resolves to 1 January.
    /// A PHONE's 1 January stamp between 00:00 and 07:59 UTC is that real
    /// evening, not a reset clock. Exactly 00:00:00 still is a reset, and so
    /// is any camcorder's 1 January, and any hour after 07:59.
    @Test func newYearsEvePhoneFootageIsNotAResetClock() throws {
        func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            utc.date(from: DateComponents(year: 2015, month: 1, day: 1, hour: hour, minute: minute, second: second))
                ?? Date(timeIntervalSince1970: 0)
        }
        func phone(_ name: String, _ when: Date, make: String = "Apple", model: String = "iPhone 6") -> StewardInput {
            StewardInput(fullPath: "/Volumes/LaCie/phone/\(name).mov", embeddedDate: when, originMake: make, originModel: model)
        }
        var folders = EventLabeler.FolderWordCache()
        func placed(_ r: StewardInput) -> StewardPlacement {
            StewardEvents.place(r, now: fixedNow, reader: reader(), folders: &folders)
        }
        let newYear = EventDay(year: 2015, month: 1, day: 1)
        // 22:12 and 23:40 on Dec 31 in New York.
        let eve = phone("IMG_0001", at(3, 12)), later = phone("IMG_0002", at(4, 40))
        #expect(placed(eve).day == newYear && placed(eve).year == 2015, "a phone at 03:12 UTC on 1 January is New Year's Eve")
        #expect(events(build([eve, later])).map(\.id) == ["event:newyear:-:2015"])
        #expect(placed(phone("android", at(7, 59, 59), make: "samsung", model: "SM-G960U")).day == newYear,
                "another phone maker, the last second of the window")
        // Still reset clocks.
        #expect(placed(phone("midnight", at(0, 0))).day == nil, "exactly midnight is what a reset clock stamps")
        #expect(placed(phone("morning", at(8, 0))).day == nil, "outside the window")
        let camcorder = StewardInput(fullPath: "/Volumes/LaCie/t/cam.mov", embeddedDate: at(3, 12), originModel: "Camcorder")
        #expect(placed(camcorder).day == nil, "a camcorder's 1 January is a reset clock at any hour")
    }

    /// QA F7 of the first trial, kept: no reset-clock 1 January, no
    /// copy-era stamp, no year range, no file-system date.
    @Test func datesThatAreNotGoodEnoughPlaceNothing() {
        let resetClock = StewardInput(fullPath: "/Volumes/LaCie/t/reset.mov", embeddedDate: day(2000, 1, 1), originModel: "Camcorder")
        let copyStamp = StewardInput(fullPath: "/Volumes/LaCie/xmas/export.mov", embeddedDate: day(2006, 12, 25),
                                     originEncoder: "Lavf58.29.100")
        let range = StewardInput(fullPath: "/Volumes/LaCie/t/range.mov", inferredDate: day(2006, 12, 25), inferredConfidence: 0.9,
                                 inferredRange: InferredDateRange(startYear: 2005, endYear: 2007))
        let weak = StewardInput(fullPath: "/Volumes/LaCie/t/weak.mov", inferredDate: day(2006, 12, 25), inferredConfidence: 0.3)
        let copied = StewardInput(fullPath: "/Volumes/LaCie/t/copied.mov", bestDate: day(2006, 12, 25))
        let q = build([resetClock, copyStamp, range, weak, copied])
        #expect(events(q).isEmpty && days(q).isEmpty)
        #expect(q.placedClips == 0 && q.placeableClips == 5)
        var folders = EventLabeler.FolderWordCache()
        let reset = StewardEvents.place(resetClock, now: fixedNow, reader: reader(), folders: &folders)
        #expect(reset.day == nil && reset.labels.isEmpty, "1 January that nobody typed is a reset clock, not New Year's Day")
        let stamp = StewardEvents.place(copyStamp, now: fixedNow, reader: reader(), folders: &folders)
        #expect(stamp.day == nil && stamp.year == nil, "a stamp with no camera behind it dates the copy")
        #expect(stamp.labels.map(\.key) == [nil], "the folder word explains, and keys nothing")
        // …but 1 January a PERSON typed is New Year's Day.
        #expect(events(build([clip("/Volumes/LaCie/t/typed.mov", on: "2000-01-01"),
                              clip("/Volumes/LaCie/t/typed2.mov", on: "2000-01-01")])).first?.id == "event:newyear:-:2000")
    }

    /// QA F1 (2026-10-03): a reset clock's YEAR is as wrong as its day. A
    /// camcorder clip stamped 2000-01-01 in a folder "xmas" must not become
    /// "Christmas 2000", and the stale year must not keep it out of its
    /// footage twin's real event.
    @Test func aResetClocksYearNamesNoEventEither() throws {
        let reset = StewardInput(fullPath: "/Volumes/LaCie/xmas/reset.mov", embeddedDate: day(2000, 1, 1), originModel: "Camcorder")
        var folders = EventLabeler.FolderWordCache()
        let placed = StewardEvents.place(reset, now: fixedNow, reader: reader(), folders: &folders)
        #expect(placed.day == nil)
        #expect(placed.year == nil, "the reset clock's year is kept: \(String(describing: placed.year))")
        #expect(placed.labels.map(\.key) == [nil], "the folder word explains, and keys nothing")
        #expect(events(build([reset])).isEmpty, "said: \(events(build([reset])).map(\.title))")

        // With a twin that a person dated, it joins the twin's real event.
        let g = UUID()
        var twin = clip("/Volumes/SanDisk/t/tape.mov", on: "1994-12-25")
        var copy = reset
        twin.footageGroupID = g
        twin.footageStrength = 1
        copy.footageGroupID = g
        copy.footageStrength = 1
        let found = events(build([twin, copy]))
        #expect(found.map(\.id) == ["event:christmas:-:1994"])
        #expect(found.first?.memberCount == 2, "the reset-clock copy belongs where its twin belongs")
    }

    @Test func livePhotoHalvesAreLeftOutAndTheCoverageCountsTheRest() {
        let q = build([clip("/Volumes/LaCie/t/a.mov", on: "1994-12-25"),
                       clip("/Volumes/LaCie/t/a2.mov", on: "1994-12-25"),
                       clip("/Volumes/LaCie/t/b.mov", on: "1996-07-14"),
                       clip("/Volumes/LaCie/t/undated.mov"),
                       clip("/Volumes/LaCie/t/jpegvideocomplement_1.mov", on: "1994-12-25")])
        #expect(q.placeableClips == 4 && q.placedClips == 3)
        #expect(events(q).first?.memberCount == 2, "the motion half of a photo is not a clip of the event")
    }

    // Several labels

    @Test func aClipWithSeveralLabelsIsInEachEventAndSaysSo() throws {
        let both = clip("/Volumes/LaCie/Cape/fireworks.mov", on: "1996-07-04")
        let capeOnly = clip("/Volumes/LaCie/Cape/dunes.mov", on: "1996-07-14")
        let parade = clip("/Volumes/LaCie/t/parade.mov", on: "1996-07-04")
        let q = build([both, capeOnly, parade])
        let fourth = try #require(events(q).first { $0.eventKind == "july4" })
        let cape = try #require(events(q).first { $0.eventKind == "cape" })
        #expect(fourth.title == "Fourth of July 1996" && fourth.recordIDs == [both.id, parade.id])
        #expect(Set(cape.recordIDs) == [both.id, capeOnly.id])
        #expect(fourth.copies.first?.alsoIn == "Cape 1996")
        #expect(fourth.alsoInLine == "1 of these is also in: Cape 1996")
        #expect(cape.alsoInLine == "1 of these is also in: Fourth of July 1996")
        #expect(cape.copies.first { $0.id == capeOnly.id }?.alsoIn.isEmpty == true)
        // A date AND a name for the same occasion is one membership, both reasons.
        let twice = clip("/Volumes/LaCie/xmas/morning.mov", on: "1994-12-25")
        let e = try #require(events(build([twice, clip("/Volumes/LaCie/xmas/noon.mov", on: "1994-12-25")])).first)
        #expect(e.memberCount == 2 && e.whyLine == "2 by date")
        #expect(e.copies.first { $0.id == twice.id }?.reason == "Dec 25 — Christmas; folder name says 'xmas'")
        #expect(e.alsoInLine.isEmpty)
    }

    /// Events F8: one short clip is not an event — a card needs two clips,
    /// unless the one clip is a whole tape (20 minutes or more).
    @Test func aSingleClipIsAnEventOnlyWhenItIsAWholeTape() {
        #expect(events(build([clip("/Volumes/LaCie/t/a.mov", on: "1994-12-25")])).isEmpty, "one short clip")
        #expect(events(build([clip("/Volumes/LaCie/t/a.mov", on: "1994-12-25", seconds: 1_199)])).isEmpty, "19:59")
        #expect(events(build([clip("/Volumes/LaCie/t/tape.mov", on: "1994-12-25", seconds: 1_200)])).map(\.id)
                == ["event:christmas:-:1994"], "a whole tape")
        #expect(events(build([clip("/Volumes/LaCie/t/a.mov", on: "1994-12-25"),
                              clip("/Volumes/LaCie/t/b.mov", on: "1994-12-24")])).map(\.memberCount) == [2])
        // A clip pulled in by matching footage counts towards the two.
        let g = UUID()
        var dated = clip("/Volumes/LaCie/t/tape.mov", on: "1994-12-25"), twin = clip("/Volumes/SanDisk/t/tape copy.mov")
        dated.footageGroupID = g; dated.footageStrength = 1
        twin.footageGroupID = g; twin.footageStrength = 1
        #expect(events(build([dated, twin])).map(\.memberCount) == [2])
    }

    // Footage siblings

    @Test func aFootageSiblingWithNoConflictingDateBelongsToItsTwinsEvent() throws {
        let g = UUID()
        func member(_ path: String, on date: String?, strength: Int = 1) -> StewardInput {
            var r = clip(path, on: date)
            r.footageGroupID = g
            r.footageStrength = strength
            return r
        }
        let dated = member("/Volumes/LaCie/t/tape.mov", on: "1994-12-25")
        let undated = member("/Volumes/SanDisk/t/tape copy.mov", on: nil)
        let sameYear = member("/Volumes/X9/t/tape small.mov", on: "1994")
        let otherDay = member("/Volumes/X9/t/other day.mov", on: "1990-05-05")
        let otherYear = member("/Volumes/X9/t/other year.mov", on: "1993")
        let e = try #require(events(build([dated, undated, sameYear, otherDay, otherYear])).first)
        #expect(e.id == "event:christmas:-:1994")
        #expect(e.recordIDs == [dated.id, undated.id, sameYear.id], "the clip placed by date, then the two by footage (by path)")
        #expect(e.whyLine == "1 by date · 2 by matching footage")
        #expect(e.copies.map(\.reason) == ["Dec 25 — Christmas", "by matching footage", "by matching footage"])
        #expect(e.insideLines == ["3 are the same footage (1 group)"])
        #expect(e.footageGroupID == g, "exactly one group: Open the footage group is offered")

        // A group that is only Possible shares nothing.
        let weak = [dated, undated].map { r -> StewardInput in var w = r; w.footageStrength = 0; return w }
        #expect(events(build(weak)).isEmpty, "the dated clip alone is one short clip — no event (F8)")
    }

    @Test func theConflictRuleIsAboutTheSiblingsOwnDate() {
        func placed(day: EventDay? = nil, year: Int? = nil) -> StewardPlacement { StewardPlacement(day: day, year: year) }
        let conflicts = StewardEvents.conflicts
        #expect(!conflicts(placed(), "christmas", 1994, true), "no date at all conflicts with nothing")
        #expect(!conflicts(placed(year: 1994), "christmas", 1994, true))
        #expect(conflicts(placed(year: 1993), "christmas", 1994, true))
        #expect(!conflicts(placed(year: 1994), "newyear", 1995, true), "New Year's Eve belongs to the new year")
        #expect(conflicts(placed(year: 1993), "newyear", 1995, true))
        let july = EventDay(year: 1996, month: 7, day: 14)
        #expect(conflicts(placed(day: july, year: 1996), "july4", 1996, true),
                "a clip with its own trusted day would have been placed by it")
        #expect(!conflicts(placed(day: july, year: 1996), "cape", 1996, false), "an event placed by name only: the year decides")
        #expect(conflicts(placed(day: july, year: 1996), "cape", 1997, false))
    }

    // What is inside

    @Test func theInsideLinesComeFromWhatTheCatalogAlreadyKnows() throws {
        let s1 = UUID(), s2 = UUID(), s3 = UUID(), f = UUID()
        func xmas(_ name: String) -> StewardInput { clip("/Volumes/LaCie/t/\(name).mov", on: "1994-12-25") }
        var k1 = xmas("k1"), c1 = xmas("c1"), k2 = xmas("k2"), c2 = xmas("c2"), lone = xmas("lone")
        k1.duplicateGroupID = s1; k1.isKeeper = true
        c1.duplicateGroupID = s1; c1.isExtraCopy = true
        k2.duplicateGroupID = s2; k2.isKeeper = true
        c2.duplicateGroupID = s2; c2.isExtraCopy = true
        lone.duplicateGroupID = s3                      // its partner is not in the event
        var original = xmas("original"), reencode = xmas("reencode")
        original.footageGroupID = f
        original.footageStrength = 1
        original.footageLikelyOriginalID = original.id
        reencode.footageGroupID = f
        reencode.footageStrength = 1
        reencode.footageRank = 1
        reencode.footageLikelyOriginalID = original.id
        var archived = xmas("archived"), filed = xmas("filed"), onArchiveDrive = xmas("drive"), chosen = xmas("chosen")
        archived.protection = .archived
        filed.protection = .filedArchived
        onArchiveDrive.protection = .archiveDrive
        chosen.protection = .angel
        let all = [k1, c1, k2, c2, lone, original, reencode, archived, filed, onArchiveDrive, chosen]
        let e = try #require(events(build(all)).first)
        #expect(e.memberCount == 11, "an event LISTS archived clips and the Angel's picks — it proposes nothing about them")
        #expect(e.insideLines == ["4 of these are copies of each other (2 sets)",
                                  "2 are the same footage (1 group)",
                                  "2 are in the archive",
                                  "Best copy: original.mov"])
        #expect(Set(e.copyReviewIDs) == [k1.id, c1.id, k2.id, c2.id], "Review the copies: the sets with two or more here")
        #expect(e.footageGroupID == f && e.likelyOriginalID == original.id)

        // No likely original in the catalog → no "Best copy" line; two groups → no single group to open.
        var gone = [original, reencode]
        for i in gone.indices { gone[i].footageOriginalInCatalog = false }
        #expect(try #require(events(build(gone)).first).insideLines == ["2 are the same footage (1 group)"])
        let f2 = UUID()
        var second = [xmas("second a"), xmas("second b")]
        for i in second.indices {
            second[i].footageGroupID = f2
            second[i].footageStrength = 2
            second[i].footageRank = i
            second[i].footageLikelyOriginalID = second[0].id
        }
        let two = try #require(events(build([original, reencode] + second)).first)
        #expect(two.insideLines == ["4 are the same footage (2 groups)", "Best copy of each: original.mov, second a.mov"])
        #expect(two.footageGroupID == nil)
        // Nothing known → nothing said, and nothing to review.
        let plain = try #require(events(build([xmas("plain"), xmas("plain too")])).first)
        #expect(plain.insideLines.isEmpty && plain.copyReviewIDs.isEmpty)
    }

    // Days nobody has named

    @Test func fourClipsOnOneDayWithNoLabelGetACardAndThreeDoNot() throws {
        var inputs = (0..<4).map { clip("/Volumes/LaCie/t/july\($0).mov", on: "1996-07-14", seconds: 600) }
        inputs += (0..<3).map { clip("/Volumes/LaCie/t/may\($0).mov", on: "1996-05-18") }
        let q = build(inputs)
        #expect(events(q).isEmpty)
        let d = try #require(days(q).first)
        #expect(days(q).count == 1)
        #expect(d.id == "day:1996-07-14" && d.title == "A day in July 1996")
        #expect(d.detail == "4 clips · 1 drive · 40 m · Jul 14, 1996")
        #expect(d.whyLine == "4 clips are dated Jul 14, 1996, and nothing on them says what the occasion was")
        #expect(d.copies.allSatisfy { $0.reason == "dated Jul 14, 1996" })
        #expect(d.memberCount == StewardEvents.minDayCluster && d.eventKind.isEmpty)
    }

    @Test func daysRunningAreOneOccasionUpToThreeDays() {
        func pair(_ date: String) -> [StewardInput] { (0..<2).map { clip("/Volumes/LaCie/t/\(date)-\($0).mov", on: date) } }
        let weekend = days(build(pair("1996-07-20") + pair("1996-07-21")))
        #expect(weekend.map(\.title) == ["2 days in July 1996"])
        #expect(weekend.first?.id == "day:1996-07-20" && weekend.first?.detail == "4 clips · 1 drive · 4 m · Jul 20–21, 1996")
        // Not running: two days apart are two days, each too small.
        #expect(days(build(pair("1996-07-20") + pair("1996-07-22"))).isEmpty)
        // Four days running: the first three are one occasion; the fourth is its own (and too small).
        let run = days(build(pair("1996-08-01") + pair("1996-08-02") + pair("1996-08-03") + pair("1996-08-04")))
        #expect(run.map(\.id) == ["day:1996-08-01"])
        #expect(run.first?.title == "3 days in August 1996" && run.first?.memberCount == 6)
        // Across a month end and a leap day the days still run.
        #expect(StewardEvents.dayNumber(EventDay(year: 1996, month: 3, day: 1))
                - StewardEvents.dayNumber(EventDay(year: 1996, month: 2, day: 28)) == 2)
        #expect(StewardEvents.dayNumber(EventDay(year: 1970, month: 1, day: 1)) == 0)
        let monthEnd = days(build(pair("1997-07-31") + pair("1997-08-01")))
        #expect(monthEnd.first?.detail == "4 clips · 1 drive · 4 m · Jul 31 – Aug 1, 1997")
    }

    /// Events QA F7: a day card is keyed by its busiest day (the earliest of
    /// a tie), not its first — so a clip arriving on the day before does not
    /// change the id (and lose a Skip) of a run it merely extends.
    @Test func aDayCardKeepsItsIdWhenAClipArrivesOnAnAdjacentDay() {
        let base = (0..<4).map { clip("/Volumes/LaCie/t/july\($0).mov", on: "1996-07-14") }
        #expect(days(build(base)).map(\.id) == ["day:1996-07-14"])
        let before = base + [clip("/Volumes/LaCie/t/early.mov", on: "1996-07-13")]
        #expect(days(build(before)).map(\.id) == ["day:1996-07-14"], "a clip the day before keeps the id")
        #expect(days(build(before)).first?.memberCount == 5, "…and joins the run")
        let after = base + [clip("/Volumes/LaCie/t/late.mov", on: "1996-07-15")]
        #expect(days(build(after)).map(\.id) == ["day:1996-07-14"], "a clip the day after keeps the id")
        // A tie between two days: the earlier one.
        func pair(_ date: String) -> [StewardInput] { (0..<2).map { clip("/Volumes/LaCie/t/\(date)-\($0).mov", on: date) } }
        #expect(days(build(pair("1996-08-10") + pair("1996-08-11"))).map(\.id) == ["day:1996-08-10"])
    }

    @Test func aLabelledClipIsNeverCountedTowardsAnUnnamedDay() {
        // Four clips on Christmas Day are an event, not "a day to name".
        let q = build((0..<4).map { clip("/Volumes/LaCie/t/c\($0).mov", on: "1994-12-25") })
        #expect(days(q).isEmpty && events(q).count == 1)
    }

    // Words

    @Test func lengthsAndDateRangesReadPlainly() {
        #expect(StewardEvents.lengthText(7_800) == "2 h 10 m")
        #expect(StewardEvents.lengthText(7_200) == "2 h")
        #expect(StewardEvents.lengthText(2_880) == "48 m")
        #expect(StewardEvents.lengthText(30) == "30 s")
        let a = EventDay(year: 1994, month: 12, day: 24), b = EventDay(year: 1994, month: 12, day: 26)
        #expect(StewardEvents.dayRangeText(a, a) == "Dec 24, 1994")
        #expect(StewardEvents.dayRangeText(a, b) == "Dec 24–26, 1994")
        #expect(StewardEvents.subtitle(clips: 14, drives: 3, seconds: 7_800, when: "Dec 24–26, 1994")
                == "14 clips · 3 drives · 2 h 10 m · Dec 24–26, 1994")
        #expect(StewardEvents.subtitle(clips: 1, drives: 1, seconds: 0, when: "") == "1 clip · 1 drive")
    }
}

// MARK: - Order, filter, skip

@Suite("Steward events — the order of the pane, the filter, and Skip", .serialized)
struct StewardEventsOrderTests {

    private func mixed() -> [StewardInput] {
        let dup = UUID(), footage = UUID()
        var inputs: [StewardInput] = []
        // Events: Christmas 1994 (3 clips), Cape 1990 (2 long clips), Halloween 1998 (2 short clips).
        inputs += (0..<3).map { clip("/Volumes/LaCie/t/x\($0).mov", on: "1994-12-25") }
        inputs += (0..<2).map { clip("/Volumes/LaCie/Cape/c\($0).mov", on: "1990-08-0\($0 + 1)", seconds: 3_600) }
        inputs += (0..<2).map { clip("/Volumes/LaCie/t/h\($0).mov", on: "1998-10-31") }
        // A day to name.
        inputs += (0..<5).map { clip("/Volumes/LaCie/t/d\($0).mov", on: "1996-07-14") }
        // Same footage, a duplicate set, junk — none of them dated.
        inputs += (0..<2).map { StewardInput(fullPath: "/Volumes/X9/f\($0).mov", footageGroupID: footage, footageStrength: 1, footageRank: $0) }
        inputs.append(StewardInput(fullPath: "/Volumes/SanDisk/k.mov", isKeeper: true, duplicateGroupID: dup))
        inputs.append(StewardInput(fullPath: "/Volumes/SanDisk/c.mov", isExtraCopy: true, duplicateGroupID: dup))
        inputs += (0..<2).map { StewardInput(fullPath: "/Volumes/X9/j\($0).mov", junkScore: 6, junkReasonKey: "Very short") }
        return inputs
    }

    @Test func eventsLeadThenDaysThenFootageThenSpaceThenJunk() {
        let q = build(mixed())
        #expect(q.cases.map(\.kind.lane) == [0, 0, 0, 1, 2, 3, 3, 4])
        #expect(q.cases.prefix(5).map(\.kind) == [.event, .event, .event, .unlabelledDay, .sameFootage])
        #expect(q.cases.last?.kind == .junk)
        #expect(q.cases.prefix(3).map(\.title) == ["Christmas 1994", "Cape 1990", "Halloween 1998"],
                "most clips first; then, between two of a size, the longer")
        #expect(Set(q.cases.map(\.id)).count == q.cases.count)
    }

    @Test func theFilterNarrowsAndByYearReordersOnlyTheEvents() {
        let q = build(mixed())
        typealias Filter = StewardCaseBuilder.Filter
        let arrange = StewardCaseBuilder.arrange
        #expect(arrange(q.cases, .all, false) == q.cases, "All, biggest first, is the built order")
        #expect(arrange(q.cases, .events, false).map(\.kind) == [.event, .event, .event, .unlabelledDay])
        #expect(arrange(q.cases, .footage, false).map(\.kind) == [.sameFootage])
        #expect(Set(arrange(q.cases, .space, false).map(\.kind)) == [.reclaimDrive, .reclaimGroup])
        #expect(arrange(q.cases, .junk, false).map(\.kind) == [.junk])
        let byYear = arrange(q.cases, .all, true)
        #expect(byYear.prefix(3).map(\.title) == ["Cape 1990", "Christmas 1994", "Halloween 1998"], "earliest year first")
        #expect(Array(byYear.dropFirst(3)) == Array(q.cases.dropFirst(3)), "everything after the events keeps its place")
        #expect(arrange(q.cases, .events, true).map(\.kind) == [.event, .event, .event, .unlabelledDay])
        #expect(arrange(q.cases, .space, true) == arrange(q.cases, .space, false))
        #expect(Filter.allCases.map(\.label) == ["All", "Events", "Same footage", "Space", "Not worth keeping"])
        #expect(Filter(rawValue: "nonsense") == nil, "a stored value from another build falls back to All in the pane")
    }

    @Test func eventKeysAreTheSameAcrossRebuilds() {
        let first = build(mixed())
        // Other record ids, other group ids, another order: the same events.
        let again = build(Array(mixed().reversed()))
        #expect(events(again).map(\.id) == events(first).map(\.id))
        #expect(events(first).map(\.id) == ["event:christmas:-:1994", "event:cape:-:1990", "event:halloween:-:1998"])
        #expect(days(again).map(\.id) == ["day:1996-07-14"] && days(first).map(\.id) == ["day:1996-07-14"])
        let alex = StewardEvents.caseID(EventLabel(event: "birthday", person: "Alex", year: 1994, source: .birthday,
                                                   why: .birthday(offset: 0, age: 12)))
        #expect(alex == "event:birthday:alex:1994")
        #expect(StewardEvents.caseID(EventLabel(event: "cape", year: nil, source: .name, why: .word(place: "folder", word: "cape"))) == nil,
                "a word with no year is no event")
    }

    @Test func aSkippedEventStaysAwayUntilItGrowsAndIsNotCountedAgainstTheLimit() throws {
        let name = "steward-events-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StewardSkipStore(defaults: defaults)

        let christmas = try #require(events(build(mixed())).first)
        store.skip(christmas)
        #expect(defaults.string(forKey: "steward.skipped.event:christmas:-:1994") != nil, "key = steward.skipped.event:<kind>:<subject>:<year>")
        let rebuilt = try #require(events(build(mixed(), skipped: store.snapshot())).first { $0.id == christmas.id })
        #expect(store.isSkipped(rebuilt), "the same event after a rebuild is still skipped")
        let grown = mixed() + [clip("/Volumes/LaCie/t/x-new.mov", on: "1994-12-26")]
        let bigger = try #require(events(build(grown, skipped: store.snapshot())).first { $0.id == christmas.id })
        #expect(!store.isSkipped(bigger), "a fourth clip is a material change: it comes back")

        // The lane keeps `maxEventCases` that are NOT skipped.
        var many: [StewardInput] = []
        for year in 1950..<2020 {
            for n in 0..<2 {     // two clips: one short clip is no event (Events F8)
                many.append(clip("/Volumes/LaCie/t/x\(year)-\(n).mov", on: "\(year)-12-25"))
                many.append(clip("/Volumes/LaCie/t/j\(year)-\(n).mov", on: "\(year)-07-04"))
                many.append(clip("/Volumes/LaCie/t/h\(year)-\(n).mov", on: "\(year)-10-31"))
            }
        }
        let all = events(build(many))
        #expect(all.count == StewardEvents.maxEventCases, "210 events, 200 kept")
        all.forEach(store.skip)
        let after = store.partition(events(build(many, skipped: store.snapshot())))
        #expect(after.active.count == 10, "the ten behind the limit come forward")
        #expect(after.skipped.count == StewardEvents.maxSkippedEvents, "…and skipped ones can still be brought back")
    }
}

// MARK: - The Same-footage title guess

@Suite("Steward events — the Same-footage title is the labeller's guess")
struct StewardFootageGuessTests {

    private func group(_ members: [StewardInput]) -> [StewardInput] {
        let g = UUID()
        return members.enumerated().map { i, r in
            var m = r
            m.footageGroupID = g
            m.footageStrength = 1
            m.footageRank = i
            return m
        }
    }

    private func footage(_ inputs: [StewardInput], birthdays: [FamilyBirthday] = family) throws -> StewardCase {
        try #require(build(inputs, birthdays: birthdays).cases.first { $0.kind == .sameFootage })
    }

    @Test func aHolidayOrABirthdayOnTheMembersDaysIsTheGuess() throws {
        let xmas = try footage(group([clip("/Volumes/LaCie/t/a.mov", on: "2006-12-25"), clip("/Volumes/SanDisk/t/b.mov", on: "2006-12-24")]))
        #expect(xmas.title == "Around Christmas 2006?")
        #expect(xmas.detail.hasPrefix("a guess from the date · 2 clips on 2 drives — likely the same footage"))
        #expect(xmas.occasionGuess == StewardOccasionGuess(text: "Christmas 2006", caption: "a guess from the date"))

        let birthday = try footage(group([clip("/Volumes/LaCie/t/a.mov", on: "1994-06-11"), clip("/Volumes/LaCie/t/b.mov")]))
        #expect(birthday.title == "Around Alex's 12th birthday?")
        #expect(birthday.plainDescription.hasPrefix("2 clips on 1 drive"))
    }

    @Test func aFolderWordOnADatedMemberIsAGuessFromTheFolderName() throws {
        let c = try footage(group([clip("/Volumes/LaCie/Cape/a.mov", on: "1996-07-14"), clip("/Volumes/LaCie/Cape/b.mov", on: "1996-07-15")]))
        #expect(c.title == "Around Cape 1996?")
        #expect(c.detail.hasPrefix("a guess from the folder name · "))
    }

    @Test func theMajorityWinsAndATieIsNoGuess() throws {
        let majority = try footage(group([clip("/Volumes/LaCie/t/a.mov", on: "2006-12-25"), clip("/Volumes/LaCie/t/b.mov", on: "2006-12-26"),
                                          clip("/Volumes/LaCie/t/c.mov", on: "2006-07-04")]))
        #expect(majority.title == "Around Christmas 2006?")
        let tie = try footage(group([clip("/Volumes/LaCie/t/a.mov", on: "2006-12-25"), clip("/Volumes/LaCie/t/c.mov", on: "2006-07-04")]))
        #expect(tie.occasionGuess == nil && tie.title == tie.plainDescription && tie.detail.isEmpty)
    }

    @Test func membersWithoutATrustedDayDoNotVote() throws {
        // A reset clock, a copy-era stamp, a year range, a file-system date, a year alone in an "xmas" folder.
        let none = try footage(group([
            StewardInput(fullPath: "/Volumes/LaCie/t/reset.mov", embeddedDate: day(2000, 1, 1), originModel: "Camcorder"),
            StewardInput(fullPath: "/Volumes/LaCie/t/export.mov", embeddedDate: day(2006, 12, 25), originEncoder: "Lavf58.29.100"),
            StewardInput(fullPath: "/Volumes/LaCie/t/range.mov", inferredDate: day(2006, 12, 25), inferredConfidence: 0.9,
                         inferredRange: InferredDateRange(year: 2006)),
            StewardInput(fullPath: "/Volumes/LaCie/t/copied.mov", bestDate: day(2006, 12, 25)),
            clip("/Volumes/LaCie/xmas/year only.mov", on: "2006"),
        ]))
        #expect(none.occasionGuess == nil, "said: \(none.title)")
        #expect(none.title == none.plainDescription)
        // One member a camera dated settles it.
        let one = try footage(group([
            StewardInput(fullPath: "/Volumes/LaCie/t/copied.mov", bestDate: day(2006, 12, 25)),
            StewardInput(fullPath: "/Volumes/LaCie/t/camera.mov", embeddedDate: day(2006, 12, 25), originModel: "Camcorder"),
        ]))
        #expect(one.title == "Around Christmas 2006?")
    }

    @Test func aNameWinsOverAGuessAndTheGuessOverTheDescription() {
        let guess = StewardOccasionGuess(text: "Christmas 2006", caption: "a guess from the date")
        let named = StewardFootageTitle.lines(name: "  Grandma's tape  ", guess: guess, description: "2 clips")
        #expect(named == .init(title: "Grandma's tape", caption: "2 clips", isGuess: false))
        let guessed = StewardFootageTitle.lines(name: nil, guess: guess, description: "2 clips")
        #expect(guessed == .init(title: "Around Christmas 2006?", caption: "a guess from the date · 2 clips", isGuess: true))
        #expect(StewardFootageTitle.lines(name: " ", guess: nil, description: "2 clips") == .init(title: "2 clips", caption: nil, isGuess: false))
    }
}

// MARK: - Scale

@Suite("Steward events — scale")
struct StewardEventsScaleTests {

    /// 100k clips, EVERY one dated to the day by a camera and labelled
    /// against 40 birthdays; one folder in ten carries an event word; 5,000
    /// footage groups of 4 (three dated, one undated twin). Grouping is
    /// O(records): one build under 4 s in Debug.
    @Test func hundredThousandDatedClipsGroupIntoEventsUnderBudget() {
        let drives = ["/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9"]
        let words = ["xmas", "Cape", "vacation", "bday", "camp"]
        let groups = (0..<5_000).map { _ in UUID() }
        var inputs: [StewardInput] = []
        inputs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let folder = i % 10 == 0 ? "\(words[(i / 10) % words.count]) \(i % 300)" : "folder\(i % 300)"
            var r = StewardInput(fullPath: "\(drives[i % 3])/\(folder)/clip\(i).mov", sizeBytes: 1_000_000, durationSeconds: 90)
            // In each footage group of four the last twin is undated; elsewhere one clip in five is.
            let undated = i < 20_000 ? i >= 15_000 : i % 5 == 4
            if !undated {
                // Never the 1st: a camera's 1 January is a reset clock and places nothing.
                r.embeddedDate = day(1985 + (i / 7) % 35, 1 + (i / 3) % 12, 2 + i % 27)
                r.originModel = "Camcorder"
            }
            if i < 20_000 {
                r.footageGroupID = groups[i % 5_000]
                r.footageStrength = 1
                r.footageRank = i / 5_000
            }
            inputs.append(r)
        }
        let birthdays = (0..<40).map {
            FamilyBirthday(name: "Person \($0)", born: EventDay(year: 1950 + $0, month: 1 + $0 % 12, day: 1 + $0 % 28))
        }
        let start = ContinuousClock.now
        let q = StewardCaseBuilder.build(inputs: inputs, volumes: volumes, mountedRoots: mounted, alsoCleanUpWorkingCopies: false,
                                         events: ArchiveAngel.OccasionReader(birthdays: birthdays),
                                         calendar: utc, now: fixedNow)
        let elapsed = ContinuousClock.now - start
        #expect(q.count(of: .event) == StewardEvents.maxEventCases)
        #expect(q.count(of: .unlabelledDay) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.placeableClips == 100_000 && q.placedClips == 79_000)
        #expect(q.cases.allSatisfy { $0.copies.count <= StewardCaseBuilder.maxCopiesPerCase && $0.recordIDs.count <= StewardCaseBuilder.maxIDsPerCase })
        let eventSizes = events(q).map(\.memberCount)
        #expect(eventSizes == eventSizes.sorted(by: >), "biggest first")
        #expect(events(q).contains { $0.whyLine.contains("by matching footage") }, "undated twins are pulled in at this size too")
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(4_000)),
                "the events build took \(elapsed) for 100k dated clips — over the 4 s budget")
        // Arranging what the pane shows is nothing beside it.
        let arrangeStart = ContinuousClock.now
        for _ in 0..<100 { _ = StewardCaseBuilder.arrange(q.cases, filter: .all, eventsByYear: true) }
        #expect(ContinuousClock.now - arrangeStart < PerformanceLane.debugCeiling(.milliseconds(1_000)))
    }

    /// QA F6: ONE event of 50,000 clips (a decade of phone clips in a folder
    /// called "vacation", all typed as one year), half of them pulled in by
    /// matching footage. Inserting into a bucket must not copy its member
    /// array each time — the build stays inside the same budget.
    @Test func oneEventOfFiftyThousandClipsBuildsUnderTheSameBudget() throws {
        let groups = (0..<25_000).map { _ in UUID() }
        var inputs: [StewardInput] = []
        inputs.reserveCapacity(50_000)
        for i in 0..<50_000 {
            let direct = i < 25_000
            // The twin of each clip sits in a plain folder with no date: only its footage places it.
            var r = StewardInput(fullPath: direct ? "/Volumes/LaCie/vacation/clip\(i).mov" : "/Volumes/SanDisk/plain/clip\(i).mov",
                                 sizeBytes: 1_000_000, durationSeconds: 30, userDate: direct ? "1999" : nil)
            r.footageGroupID = groups[i % 25_000]
            r.footageStrength = 1
            r.footageRank = direct ? 0 : 1
            inputs.append(r)
        }
        let start = ContinuousClock.now
        let q = StewardCaseBuilder.build(inputs: inputs, volumes: volumes, mountedRoots: mounted, alsoCleanUpWorkingCopies: false,
                                         events: ArchiveAngel.OccasionReader(),
                                         calendar: utc, now: fixedNow)
        let elapsed = ContinuousClock.now - start
        let event = try #require(events(q).first)
        #expect(events(q).count == 1 && event.id == "event:vacation:-:1999")
        #expect(event.memberCount == 50_000 && event.facts.count == 50_000)
        #expect(event.whyLine == "25,000 by folder name 'vacation' · 25,000 by matching footage")
        #expect(event.recordIDs.count == StewardCaseBuilder.maxIDsPerCase && event.copies.count == StewardCaseBuilder.maxCopiesPerCase)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(4_000)),
                "one event of 50k clips took \(elapsed) — over the 4 s budget")
    }
}
