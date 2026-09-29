// AngelFamilyBirthdays.swift
// Rules v14 event labels: the People tab's birthdays as the Angel's event
// labeler needs them (VideoScanCore.FamilyBirthday). The ONLY place the
// Angel reads profiles, and it reads them the way Hallie does —
// `HallieShellCLI.loadProfilesReadOnly()`: decode the current POI
// folders, never migrate, create or rewrite anything. Reached only through
// `AngelEnvironment.familyBirthdays`; a test host's environment returns []
// and never touches the real App Support folder.
//
// Birthdates are `Date`s. The People sheet's DatePicker stores a LOCAL
// time on the chosen day; a hand-edited profile.json usually says
// "1930-08-31T00:00:00Z". Read in the Mac's calendar, the second would be
// Aug 30 in Massachusetts — so an instant at exactly UTC midnight is read
// in UTC, anything else in the local calendar. (≈ a small free-function
// adapter; no state.)

import Foundation
import VideoScanCore

enum AngelFamilyBirthdays {

    /// Production: every People-tab profile with a birthdate. [] when the
    /// POI store cannot be read (the labels then simply have no birthdays).
    /// Disk I/O — call off the main actor.
    nonisolated static func readPeopleTab() -> [FamilyBirthday] {
        guard case .loaded(let profiles) = HallieShellCLI.loadProfilesReadOnly() else { return [] }
        return from(profiles.map { (name: $0.name, born: $0.birthdate, died: $0.deathdate) })
    }

    /// Pure: (display name, birthdate, deathdate) → birthdays, people with
    /// no birthdate or no name dropped.
    nonisolated static func from(_ people: [(name: String, born: Date?, died: Date?)],
                                 local: Calendar = .current) -> [FamilyBirthday] {
        people.compactMap { p in
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let born = p.born else { return nil }
            return FamilyBirthday(name: name, born: day(of: born, local: local),
                                  diedYear: p.died.map { day(of: $0, local: local).year })
        }
    }

    /// The calendar day a stored birthdate means (see the file header).
    nonisolated static func day(of date: Date, local: Calendar) -> EventDay {
        var calendar = local
        let seconds = date.timeIntervalSince1970
        if seconds.truncatingRemainder(dividingBy: 86_400) == 0 { calendar.timeZone = .gmt }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return EventDay(year: c.year ?? 0, month: c.month ?? 1, day: c.day ?? 1)
    }
}
