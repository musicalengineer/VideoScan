// EventLabelerTests.swift
// Rules v14 event labels (2026-09-29): the pure labeler — calendar rules
// (Easter across years, Thanksgiving edges, the fixed windows), family
// birthdays (window, leap-day births, New Year boundary, birth and death
// years), and the name lexicon (whole words, camelCase, the weak "party",
// the documented false positives and non-positives).

import Testing
@testable import VideoScanCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> EventDay { EventDay(year: y, month: m, day: d) }

private func events(_ labels: [EventLabel]) -> [String] { labels.map(\.event) }

struct EventLabelerCalendarTests {

    @Test("Easter Sunday by computus across a century of years, incl. the earliest and latest possible dates")
    func easterAcrossYears() {
        let known: [(Int, Int, Int)] = [
            (1818, 3, 22), (1943, 4, 25), (1961, 4, 2), (1994, 4, 3), (2000, 4, 23),
            (2008, 3, 23), (2011, 4, 24), (2018, 4, 1), (2019, 4, 21), (2024, 3, 31), (2025, 4, 20), (2285, 3, 22),
        ]
        for (y, m, d) in known {
            #expect(EventLabeler.easterSunday(year: y) == day(y, m, d), "Easter \(y)")
        }
        #expect(EventLabeler.easterSunday(year: 1500) == nil, "no Gregorian computus before 1583")
    }

    @Test("Easter ±1 day, across the March/April boundary")
    func easterWindow() {
        #expect(EventLabeler.calendarLabels(day(1994, 4, 3)).map(\.reason) == ["Apr 3 — Easter Sunday"])
        #expect(EventLabeler.calendarLabels(day(2024, 3, 30)).map(\.reason) == ["Mar 30 — the day before Easter"])
        #expect(EventLabeler.calendarLabels(day(2024, 4, 1)).map(\.reason) == ["Apr 1 — the day after Easter"])
        #expect(EventLabeler.calendarLabels(day(2018, 3, 31)).map(\.reason) == ["Mar 31 — the day before Easter"])
        #expect(EventLabeler.calendarLabels(day(1994, 4, 5)).isEmpty, "two days after is not Easter")
        #expect(EventLabeler.calendarLabels(day(1994, 4, 1)).isEmpty)
    }

    @Test("Thanksgiving = 4th Thursday of November ±1, at the earliest (22nd) and latest (28th) edges")
    func thanksgivingEdges() {
        let known: [(Int, Int)] = [(1989, 23), (1994, 24), (2012, 22), (2018, 22), (2024, 28), (2026, 26)]
        for (y, d) in known {
            #expect(EventLabeler.nthWeekday(4, weekday: 4, month: 11, year: y) == d, "Thanksgiving \(y)")
            #expect(events(EventLabeler.calendarLabels(day(y, 11, d))) == ["thanksgiving"])
            #expect(events(EventLabeler.calendarLabels(day(y, 11, d - 1))) == ["thanksgiving"], "Wednesday before")
            #expect(events(EventLabeler.calendarLabels(day(y, 11, d + 1))) == ["thanksgiving"], "Friday after")
            #expect(EventLabeler.calendarLabels(day(y, 11, d - 2)).isEmpty)
            #expect(EventLabeler.calendarLabels(day(y, 11, d + 2)).isEmpty)
        }
        // Nov 1 2018 was a Thursday — the 1st Thursday is the 1st, the 4th the 22nd, not the 29th.
        #expect(EventLabeler.calendarLabels(day(2018, 11, 29)).isEmpty)
        #expect(EventLabeler.nthWeekday(5, weekday: 1, month: 2, year: 2021) == nil, "no 5th Monday in Feb 2021")
    }

    @Test("Fixed windows: Christmas Dec 24–26, New Year Dec 31–Jan 1 (Eve keys the NEW year), July 3–5, Halloween only Oct 31")
    func fixedWindows() {
        for d in 24...26 {
            let l = EventLabeler.calendarLabels(day(1994, 12, d))
            #expect(l.map(\.key) == ["e:christmas:1994"], "Dec \(d)")
        }
        #expect(EventLabeler.calendarLabels(day(1994, 12, 25)).first?.reason == "Dec 25 — Christmas")
        #expect(EventLabeler.calendarLabels(day(1994, 12, 23)).isEmpty)
        #expect(EventLabeler.calendarLabels(day(1994, 12, 27)).isEmpty)
        #expect(EventLabeler.calendarLabels(day(1994, 12, 31)).map(\.key) == ["e:newyear:1995"])
        #expect(EventLabeler.calendarLabels(day(1995, 1, 1)).map(\.key) == ["e:newyear:1995"])
        #expect(EventLabeler.calendarLabels(day(1995, 1, 2)).isEmpty)
        for d in 3...5 { #expect(events(EventLabeler.calendarLabels(day(1976, 7, d))) == ["july4"]) }
        #expect(EventLabeler.calendarLabels(day(1976, 7, 6)).isEmpty)
        #expect(events(EventLabeler.calendarLabels(day(1990, 10, 31))) == ["halloween"])
        #expect(EventLabeler.calendarLabels(day(1990, 10, 30)).isEmpty)
        #expect(EventLabeler.calendarLabels(day(1990, 11, 1)).isEmpty)
    }

    @Test("Mother's Day = 2nd Sunday of May, Father's Day = 3rd Sunday of June, the day only")
    func parentsDays() {
        #expect(events(EventLabeler.calendarLabels(day(1994, 5, 8))) == ["mothersday"])
        #expect(events(EventLabeler.calendarLabels(day(2026, 5, 10))) == ["mothersday"])
        #expect(EventLabeler.calendarLabels(day(1994, 5, 9)).isEmpty)
        #expect(events(EventLabeler.calendarLabels(day(1994, 6, 19))) == ["fathersday"])
        #expect(events(EventLabeler.calendarLabels(day(2026, 6, 21))) == ["fathersday"])
        #expect(EventLabeler.calendarLabels(day(1994, 6, 12)).isEmpty)
    }

    @Test("An ordinary day and an impossible date label nothing")
    func nothing() {
        #expect(EventLabeler.calendarLabels(day(1994, 8, 14)).isEmpty)
        #expect(EventLabeler.calendarLabels(day(1994, 2, 30)).isEmpty)
    }
}

struct EventLabelerBirthdayTests {

    private let timmy = FamilyBirthday(name: "Timmy", born: day(1982, 4, 22))

    @Test("±3 days of a birthday, after the birth year; the reason names the day offset and the age")
    func window() {
        let on = EventLabeler.birthdayLabels(day(1994, 4, 22), birthdays: [timmy], windowDays: 3)
        #expect(on.map(\.reason) == ["on Timmy's 12th birthday"])
        #expect(on.first?.key == "e:birthday:timmy:1994")
        #expect(on.first?.title == "Timmy's birthday 1994")
        #expect(EventLabeler.birthdayLabels(day(1994, 4, 25), birthdays: [timmy], windowDays: 3).map(\.reason)
                == ["3 days after Timmy's 12th birthday"])
        #expect(EventLabeler.birthdayLabels(day(1994, 4, 21), birthdays: [timmy], windowDays: 3).map(\.reason)
                == ["1 day before Timmy's 12th birthday"])
        #expect(EventLabeler.birthdayLabels(day(1994, 4, 26), birthdays: [timmy], windowDays: 3).isEmpty)
        #expect(EventLabeler.birthdayLabels(day(1994, 4, 18), birthdays: [timmy], windowDays: 3).isEmpty)
        #expect(EventLabeler.birthdayLabels(day(1994, 4, 26), birthdays: [timmy], windowDays: 4).count == 1, "the window is a policy number")
        #expect(EventLabeler.birthdayLabels(day(1994, 4, 23), birthdays: [timmy], windowDays: 0).isEmpty)
    }

    @Test("Birth year itself is not a birthday; nor is a year after a known death")
    func birthAndDeathYears() {
        let baby = FamilyBirthday(name: "Baby", born: day(1994, 6, 1))
        #expect(EventLabeler.birthdayLabels(day(1994, 6, 2), birthdays: [baby], windowDays: 3).isEmpty)
        #expect(EventLabeler.birthdayLabels(day(1995, 6, 2), birthdays: [baby], windowDays: 3).map(\.reason)
                == ["1 day after Baby's 1st birthday"])
        let dad = FamilyBirthday(name: "Dad", born: day(1929, 2, 21), diedYear: 2008)
        #expect(EventLabeler.birthdayLabels(day(2008, 2, 21), birthdays: [dad], windowDays: 3).count == 1)
        #expect(EventLabeler.birthdayLabels(day(2009, 2, 21), birthdays: [dad], windowDays: 3).isEmpty)
    }

    @Test("Leap-day births: Feb 28 in a common year, Feb 29 in a leap year")
    func leapDay() {
        let leap = FamilyBirthday(name: "Leap", born: day(1984, 2, 29))
        #expect(EventLabeler.birthdayLabels(day(1995, 2, 28), birthdays: [leap], windowDays: 3).map(\.reason)
                == ["on Leap's 11th birthday"])
        #expect(EventLabeler.birthdayLabels(day(1995, 3, 1), birthdays: [leap], windowDays: 3).map(\.reason)
                == ["1 day after Leap's 11th birthday"])
        #expect(EventLabeler.birthdayLabels(day(1996, 2, 29), birthdays: [leap], windowDays: 3).map(\.reason)
                == ["on Leap's 12th birthday"])
        #expect(EventLabeler.birthdayLabels(day(1996, 2, 28), birthdays: [leap], windowDays: 3).map(\.reason)
                == ["1 day before Leap's 12th birthday"])
    }

    @Test("Across New Year: Dec 30 is 2 days before a Jan 1 birthday of the NEXT year; Jan 2 is 2 days after a Dec 31 one of the last")
    func yearBoundary() {
        let jan1 = FamilyBirthday(name: "Jan", born: day(1990, 1, 1))
        let dec30 = EventLabeler.birthdayLabels(day(1994, 12, 30), birthdays: [jan1], windowDays: 3)
        #expect(dec30.map(\.reason) == ["2 days before Jan's 5th birthday"])
        #expect(dec30.first?.key == "e:birthday:jan:1995")
        let dec31 = FamilyBirthday(name: "Eve", born: day(1990, 12, 31))
        let jan2 = EventLabeler.birthdayLabels(day(1995, 1, 2), birthdays: [dec31], windowDays: 3)
        #expect(jan2.map(\.reason) == ["2 days after Eve's 4th birthday"])
        #expect(jan2.first?.key == "e:birthday:eve:1994")
        // Born Dec 31 1990: Jan 2 1991 is inside the window but still the birth year's anniversary — none.
        #expect(EventLabeler.birthdayLabels(day(1991, 1, 2), birthdays: [dec31], windowDays: 3).isEmpty)
    }

    @Test("Several birthdays in the window → all, nearest first, ties by name; blank names ignored")
    func several() {
        let people = [FamilyBirthday(name: "Zed", born: day(1980, 4, 23)), timmy,
                      FamilyBirthday(name: "Amy", born: day(1985, 4, 21)), FamilyBirthday(name: "  ", born: day(1980, 4, 22))]
        let l = EventLabeler.birthdayLabels(day(1994, 4, 22), birthdays: people, windowDays: 3)
        #expect(l.map(\.person) == ["Timmy", "Amy", "Zed"])
        #expect(Set(l.compactMap(\.key)).count == 3)
    }

    @Test("The pass's day-of-year table finds exactly what the full scan finds, every day of a common and a leap year, windows 0…14")
    func tableEqualsScan() {
        let people = [timmy, FamilyBirthday(name: "Leap", born: day(1984, 2, 29)), FamilyBirthday(name: "Jan", born: day(1990, 1, 1)),
                      FamilyBirthday(name: "Eve", born: day(1990, 12, 31)), FamilyBirthday(name: "Dad", born: day(1929, 2, 21), diedYear: 2008)]
        for window in [0, 3, 14] {
            var cache = EventLabeler.FolderWordCache()
            for year in [1995, 1996] {
                for m in 1...12 {
                    for d in 1...31 where EventLabeler.julianDay(year, m, d) != nil {
                        let scan = EventLabeler.birthdayLabels(day(year, m, d), birthdays: people, windowDays: window)
                        let viaTable = EventLabeler.labels(day: day(year, m, d), year: year, filename: "", fullPath: "",
                                                           birthdays: people, birthdayWindowDays: window, cache: &cache)
                            .filter { $0.source == .birthday }
                        #expect(viaTable == scan, "\(year)-\(m)-\(d) window \(window)")
                    }
                }
            }
        }
    }

    @Test("Ordinals")
    func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112].map(EventLabeler.ordinal)
                == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th", "112th"])
    }
}

struct EventLabelerNameTests {

    private func words(_ s: String) -> [String] { EventLabeler.nameWords(in: s[...]).map(\.event) }

    @Test("Digits and punctuation break words: xmas94_tape2 is Christmas; a year makes it Christmas 1994")
    func xmas94() {
        #expect(words("xmas94_tape2") == ["christmas"])
        let l = EventLabeler.labels(day: nil, year: 1994, filename: "xmas94_tape2.mov", fullPath: "/Volumes/X/Tapes/xmas94_tape2.mov")
        #expect(l.map(\.key) == ["e:christmas:1994"])
        #expect(l.first?.title == "Christmas 1994")
        #expect(l.first?.reason == "file name says 'xmas'")
        #expect(l.first?.source == .name)
    }

    @Test("Whole words only: capetown, partyline, gamecube, endgame, campbell are not events; Cape Town IS cape (documented)")
    func falsePositives() {
        #expect(words("capetown_1994").isEmpty)
        #expect(words("partyline").isEmpty)
        #expect(words("gamecube").isEmpty)
        #expect(words("GameCube") == ["game"], "accepted: a camelCase hump is a word break, so GameCube reads Game + Cube")
        #expect(words("endgame").isEmpty)
        #expect(words("campbell reunion").isEmpty)
        #expect(words("Cape Town") == ["cape"], "accepted false positive: a family archive's Cape is the Cape")
        #expect(words("escape").isEmpty)
    }

    @Test("Case-insensitive, camelCase humps and capital runs split")
    func caseAndHumps() {
        #expect(words("XMAS") == ["christmas"])
        #expect(words("ChristmasMorning") == ["christmas"])
        #expect(words("DVDXmas") == ["christmas"])
        #expect(words("BirthdayGame") == ["birthday", "game"])
        #expect(words("Timmy_bday_1994") == ["birthday"])
        #expect(words("Disneyland 1995") == ["disney"])
        #expect(words("summer trip") == ["vacation"])
        #expect(words("dance RECITAL") == ["recital"])
    }

    @Test("'party' is a birthday word only when nothing else in the same name is an event word")
    func weakParty() {
        #expect(words("party") == ["birthday"])
        #expect(words("Office Parties") == ["birthday"])
        #expect(words("xmas party") == ["christmas"])
        #expect(words("party at the beach") == ["beach"])
    }

    @Test("Folders: the two nearest, nearest first, never /Volumes/<drive> or /Users/<me>; each event once, file first")
    func folders() {
        #expect(EventLabeler.parentFolders("/Volumes/LaCie/Family/Christmas 1994/Tape 2/clip.mov") == ["Tape 2", "Christmas 1994"])
        #expect(EventLabeler.parentFolders("/Volumes/Cape/clip.mov").isEmpty, "the drive's name is not a folder word")
        #expect(EventLabeler.parentFolders("/Users/cape/clip.mov").isEmpty)
        #expect(EventLabeler.parentFolders("clip.mov").isEmpty)
        let l = EventLabeler.labels(day: nil, year: 1994, filename: "xmas_tape.mov",
                                    fullPath: "/Volumes/LaCie/Christmas/Beach/xmas_tape.mov")
        #expect(l.map(\.reason) == ["file name says 'xmas'", "folder name says 'beach'"])
        let deep = EventLabeler.labels(day: nil, year: 1994, filename: "clip.mov",
                                       fullPath: "/Volumes/LaCie/Wedding/a/b/clip.mov")
        #expect(deep.isEmpty, "a third-level folder is too far away to name the file")
    }

    @Test("Trip words (2026-10-07): camping, road trip, vacation, beach, lake — trips no longer land in unlabeled")
    func tripWords() {
        #expect(words("Camping 1996") == ["camp"])
        #expect(words("campout_tape1") == ["camp"])
        #expect(words("Campground") == ["camp"])
        #expect(words("Scout Camps") == ["camp"])
        #expect(words("campsite campfire") == ["camp"], "each event once")
        #expect(words("Road Trip 1995") == ["vacation"], "two words: 'trip' already reads it")
        #expect(words("roadtrip_maine") == ["vacation"])
        #expect(words("RoadTrip") == ["vacation"], "a camelCase hump splits Road | Trip")
        #expect(words("Vacation 1995") == ["vacation"])
        #expect(words("beaches") == ["beach"])
        #expect(words("Lake George 1995") == ["lake"])
        #expect(words("lakes_region") == ["lake"])
        #expect(words("LakeHouse") == ["lake"], "Lake | House by the hump")
        #expect(words("lakehouse") == ["lake"])
        #expect(words("lake party") == ["lake"], "the weak 'party' yields to a trip word")
        #expect(words("xmas at the lake") == ["christmas", "lake"], "order of appearance is kept")
    }

    @Test("Trip words stay whole words: blake, flakes, campbell, campus, roadster, beachy are not trips")
    func tripWordFalsePositives() {
        #expect(words("blake_1995").isEmpty)
        #expect(words("snow flakes").isEmpty)
        #expect(words("campbell reunion").isEmpty)
        #expect(words("campus tour").isEmpty)
        #expect(words("roadster").isEmpty)
        #expect(words("beachy").isEmpty)
        #expect(words("tripod test").isEmpty)
    }

    @Test("A trip folder names the file with the year: Camping/clip.mov in 1996 keys e:camp:1996")
    func tripFolder() {
        let l = EventLabeler.labels(day: nil, year: 1996, filename: "clip.mov",
                                    fullPath: "/Volumes/LaCie/Family/Camping Trip/clip.mov")
        #expect(l.map(\.key) == ["e:camp:1996", "e:vacation:1996"])
        #expect(l.first?.reason == "folder name says 'camping'")
        #expect(EventLabeler.displayName("lake") == "Lake")
    }

    @Test("Every lexicon word is at least 4 letters and lower-case (the scanner's length and first-letter gates)")
    func lexiconShape() {
        for (word, event) in EventLabeler.lexicon {
            #expect(word.count >= 4, "\(word)")
            #expect(word == word.lowercased(), "\(word)")
            #expect(!event.isEmpty)
        }
    }

    @Test("A name word without a year explains but keys nothing")
    func noYear() {
        let l = EventLabeler.labels(day: nil, year: nil, filename: "xmas.mov", fullPath: "/Volumes/X/xmas.mov")
        #expect(l.map(\.event) == ["christmas"])
        #expect(l.first?.key == nil)
        #expect(l.first?.title == "Christmas")
    }
}

struct EventLabelerCombinedTests {

    @Test("A trusted day gives calendar, then birthday, then name labels; name words take the day's year")
    func order() {
        let bday = FamilyBirthday(name: "Noel", born: day(1980, 12, 25))
        let l = EventLabeler.labels(day: day(1994, 12, 25), year: 1994, filename: "xmas morning.mov",
                                    fullPath: "/Volumes/X/Family/xmas morning.mov", birthdays: [bday])
        #expect(l.map(\.source) == [.calendar, .birthday, .name])
        #expect(l.compactMap(\.key) == ["e:christmas:1994", "e:birthday:noel:1994", "e:christmas:1994"])
    }

    @Test("Keys never carry a delimiter from a person's name")
    func personKey() {
        #expect(EventLabeler.personKey("Mary Ann|x:y") == "mary-ann-x-y")
    }
}
