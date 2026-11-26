// PersonLogName.swift
// ONE rule for how a person is named in the local log
// (~/Library/Logs/VideoScan, local, never uploaded).
//
// DECISIONS 2026-11-25 (Rick, on GH #466): "full names for everyone from my
// parents and back. for living people … first names are fine since I know
// who they are." So:
//   • deceased (a recorded death, or born ≥ 100 years ago)  → the full name
//   • living (everyone else, including unknown dates)       → the People-tab
//     nickname, else the first name — never a living person's surname
// Living is decided by LifeStatus's conservative privacy rule (DECISIONS
// 2026-10-10: no death date, or born after 1926 without one); the family
// around the person is never consulted here, so an undated record is living.
//
// Every log line that names a person goes through this type
// (PersonLogNameSensorTests pins the sites). Media paths, filenames,
// transcripts and captions stay out of logs as before (2026-10-02).
//
// The surname guard: a living rendering is a nickname or the first token of
// the name, and it is refused when any of its tokens is a surname token (the
// recorded surname / maiden name, or any token of the full name after the
// first). A nickname like "Grampa Smythe" or a record whose name starts with
// the surname falls through to `livingFallback`. Deterministic, no I/O.
//
// C++ readers: a caseless `enum` is a namespace of static functions (no
// instances), like a `struct` with only `static` members and a deleted ctor.

import Foundation
import VideoScanCore

enum PersonLogName {

    /// What a living person is called when neither the nickname nor the
    /// first name can be shown without a surname.
    static let livingFallback = "a living relative"

    // MARK: - The rule

    /// The rendering itself. `surnames` are the recorded family names (nil
    /// and blank entries are ignored); tokens of `fullName` after the first
    /// are treated as surname tokens too.
    static func render(fullName: String, nickname: String? = nil,
                       surnames: [String?] = [], status: LifeStatus) -> String {
        let full = collapsed(fullName)
        guard status == .living else { return full.isEmpty ? livingFallback : full }
        let fullTokens = tokens(full)
        var banned = Set(fullTokens.dropFirst().flatMap(foldedParts))
        for surname in surnames.compactMap({ $0 }) { banned.formUnion(tokens(surname).flatMap(foldedParts)) }
        func shown(_ candidate: String?) -> String? {
            guard let candidate else { return nil }
            let text = collapsed(candidate)
            guard text.contains(where: \.isLetter) else { return nil }
            return tokens(text).flatMap(foldedParts).contains(where: banned.contains) ? nil : text
        }
        return shown(nickname) ?? shown(fullTokens.first) ?? livingFallback
    }

    // MARK: - Sources of a person

    /// A family-tree record. `nickname` is the People-tab nickname when the
    /// caller has the bridged profile.
    static func of(_ person: GedcomFamilyGraph.Person, nickname: String? = nil,
                   now: Date = Date(), calendar: Calendar = .current) -> String {
        let status = LifeStatus.privacyVerdict(person, in: nil, now: now, calendar: calendar)
        return render(fullName: person.name, nickname: nickname,
                      surnames: [person.surname] + person.alternateSurnames, status: status)
    }

    /// A People-tab profile: the first alias is the family nickname (Rick
    /// 2026-09-12); the full name is the profile's full display form.
    static func of(profile: POIProfile, now: Date = Date(), calendar: Calendar = .current) -> String {
        of(name: profile.name, fullName: profile.displayFullName, aliases: profile.aliases,
           surname: profile.surname, maidenName: profile.maidenName,
           deathdate: profile.deathdate, birthdate: profile.birthdate, now: now, calendar: calendar)
    }

    /// The same rule over a profile's bare fields (Hallie's ProfileSnapshot,
    /// an undo snapshot).
    static func of(name: String, fullName: String? = nil, aliases: [String] = [],
                   surname: String? = nil, maidenName: String? = nil,
                   deathdate: Date?, birthdate: Date?,
                   now: Date = Date(), calendar: Calendar = .current) -> String {
        let status = LifeStatus.privacyVerdict(deathdate: deathdate, birthdate: birthdate,
                                               now: now, calendar: calendar)
        let nickname = aliases.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return render(fullName: status == .living ? name : (fullName ?? name), nickname: nickname,
                      surnames: [surname, maidenName], status: status)
    }

    /// A bare name string. When exactly one tree record carries it, that
    /// record decides; otherwise nothing is known about the person's dates,
    /// so they are treated as living (first name only).
    static func named(_ name: String, matches: [GedcomFamilyGraph.Person] = [],
                      now: Date = Date(), calendar: Calendar = .current) -> String {
        if matches.count == 1, let only = matches.first { return of(only, now: now, calendar: calendar) }
        return render(fullName: name, status: .living)
    }

    /// A bare name with a known birth year and no death record (a
    /// `FamilyAssetPerson` built without its tree record).
    static func named(_ name: String, birthYear: Int?, now: Date = Date(),
                      calendar: Calendar = .current) -> String {
        let status = LifeStatus.privacyVerdict(deathRecorded: false, birthYear: birthYear,
                                               now: now, calendar: calendar)
        return render(fullName: name, status: status)
    }

    // MARK: - A single name word

    /// May the log show `word` (one name word — a pronunciation being taught)
    /// beside the person rendered as `rendering`? Only when the rendering
    /// already shows it: a living person's surname never passes, a deceased
    /// person's full name shows every word of it.
    static func mayShow(word: String, rendering: String) -> Bool {
        let parts = tokens(word).flatMap(foldedParts)
        guard !parts.isEmpty else { return false }
        let shown = Set(tokens(rendering).flatMap(foldedParts))
        return parts.allSatisfy(shown.contains)
    }

    // MARK: - Text helpers

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// "Smythe-Jones," → ["smythe-jones", "smythe", "jones"]: case and
    /// diacritics folded, edge punctuation trimmed, hyphen parts included so
    /// half of a double-barrelled surname is caught too.
    private static func foldedParts(_ token: String) -> [String] {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !folded.isEmpty else { return [] }
        let parts = folded.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        return parts.count > 1 ? [folded] + parts : [folded]
    }
}
