// ArchivistTemporalGroupSnapshotTests.swift
// GH #281 R3 (2026-10-06): characterization snapshots for
// ArchivistTemporalExecutor.executeGroup, recorded from the pre-refactor
// code (main@ebcd2f09) before the function was split. executeGroup is pure,
// so the snapshot is a full grid: 7 subject groups × 4 asks × 12 group
// references (every reference kind and every selection precision), each
// rendered field by field. Synthetic people only.

import Foundation
import Testing
@testable import VideoScan

@Suite("Temporal executeGroup: characterization snapshots")
struct ArchivistTemporalGroupSnapshotTests {

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour))!
    }

    static func person(_ name: String, born: Date?, died: Date? = nil,
                       tree: Bool = false, sex: PersonSex? = .male) -> ArchivistTemporalSubjectSnapshot {
        .init(stableID: name.lowercased(), canonicalName: name, birthdate: born,
              birthdateProvenance: tree ? .gedcomTree(personID: "@\(name)@") : nil,
              deathdate: died,
              deathdateProvenance: tree ? .gedcomTree(personID: "@\(name)@") : nil,
              sex: sex)
    }

    static let groups: [(String, [ArchivistTemporalSubjectSnapshot])] = [
        ("boys", [person("Dan", born: date(1984, 6, 1)), person("Mark", born: date(1986, 11, 15)),
                  person("Matt", born: date(1996, 5, 10)), person("Timmy", born: date(1999, 4, 22))]),
        ("mixed-stores-and-deaths", [
            person("Dad", born: date(1936, 5, 10), died: date(1977, 6, 25)),
            person("Grandma", born: date(1910, 2, 3), died: date(2001, 9, 9), tree: true, sex: .female),
            person("Nana", born: nil, sex: .female),
            person("Dan", born: date(1984, 6, 1)),
        ]),
        ("no-birthdates", [person("Nana", born: nil, sex: .female), person("Pop", born: nil)]),
        ("empty", []),
        ("reference-month-and-day", [
            person("Holly", born: date(1994, 12, 25), sex: .female),
            person("Noel", born: date(1994, 12, 3)),
            person("Ivy", born: date(1994, 3, 1), sex: .female),
            person("Eve", born: date(1994, 12, 26), sex: .female),
        ]),
        ("died-around-reference", [
            person("Uncle", born: date(1930, 1, 1), died: date(1994, 12, 24)),
            person("Aunt", born: date(1932, 7, 7), died: date(1994, 12, 26), sex: .female),
            person("Cousin", born: date(1960, 8, 8), died: date(1990, 1, 1), tree: true),
        ]),
        ("all-tree", [person("Al", born: date(1931, 4, 4), tree: true),
                      person("Bea", born: date(1933, 5, 5), died: date(2020, 2, 2), tree: true, sex: .female)]),
    ]

    static let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000001994")!

    static func selection(_ precision: RecordDateResolution.Precision, _ date: Date) -> ArchivistTemporalExecutor.GroupReference {
        .selection(.resolved(recordID: recordID, fullPath: "/Archive/Christmas_1994.mkv", date: date,
                             source: .userDate, precision: precision, confidence: 0.9))
    }

    static let references: [(String, ArchivistTemporalExecutor.GroupReference)] = [
        ("year 1994", .explicitYear(1994)),
        ("year 1850 (invalid)", .explicitYear(1850)),
        ("selection year", selection(.year, date(1994, 1, 1))),
        ("selection month", selection(.month, date(1994, 12, 1))),
        ("selection day", selection(.day, date(1994, 12, 25))),
        ("selection decade", selection(.decade, date(1990, 1, 1))),
        ("selection unknown", selection(.unknown, date(1994, 6, 1))),
        ("dossier inferred", .selection(.dossierInferred(recordID: recordID, fullPath: "/Archive/x.mov",
                                                         date: date(1994, 12, 25, hour: 9), confidence: 0.7))),
        ("catalog creation", .selection(.catalogCreation(recordID: recordID, fullPath: "/Archive/x.mov",
                                                         date: date(1994, 12, 25)))),
        ("file modification", .selection(.fileModification(recordID: recordID, fullPath: "/Archive/x.mov",
                                                           date: date(1994, 12, 25)))),
        ("today", .today(date(2026, 10, 6))),
        ("death", .death),
    ]

    static let asks: [(String, ArchivistTemporalExecutor.Ask)] = [
        ("age", .age), ("bornYet", .bornYet), ("wouldHaveBeen", .wouldHaveBeen), ("ageAtDeath", .ageAtDeath),
    ]

    static func render(_ result: ArchivistTemporalResult) -> String {
        HallieGoldenSnapshot.masked([
            "value=\(String(reflecting: result.value))",
            "decline=\(String(reflecting: result.decline))",
            "prose=\(result.prose)",
            "basis=\(result.basisLine)",
            "evidence=\(String(reflecting: result.evidence))",
        ].joined(separator: "\n"))
    }

    @Test func everyGroupAskAndReferenceMatchesItsRecordedSnapshot() throws {
        var out: [String: String] = [:]
        for (groupName, subjects) in Self.groups {
            for (askName, ask) in Self.asks {
                for (referenceName, reference) in Self.references {
                    let result = ArchivistTemporalExecutor.executeGroup(
                        subjects: subjects, phrase: "'the \(groupName)'", ask: ask,
                        reference: reference, now: Self.date(2026, 10, 6))
                    out["\(groupName) | \(askName) | \(referenceName)"] = Self.render(result)
                }
            }
        }
        #expect(out.count == Self.groups.count * Self.asks.count * Self.references.count)
        try HallieGoldenSnapshot.verify("temporal_group", out)
    }
}
