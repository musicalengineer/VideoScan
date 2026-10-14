// EventsTestSupport.swift
// Shared fixtures for the Events v1 suites: rows built as values (no
// catalog, no disk), UTC days, a few family birthdays, and a store in a
// per-test temp folder. No tests here.

import Foundation
@testable import VideoScan
import VideoScanCore

enum EventsFixture {

    /// Noon UTC on a day — the planner's own day arithmetic.
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        EventsDate.utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// "1998-06-05" — the shape `VideoRecord.userDate` keeps.
    static func iso(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d-%02d-%02d", y, m, d)
    }

    static let birthdays = [
        FamilyBirthday(name: "Timmy", born: EventDay(year: 1986, month: 4, day: 22)),
        FamilyBirthday(name: "Matt", born: EventDay(year: 1990, month: 6, day: 5)),
    ]

    /// One row. `key` nil → "id:<uuid>" (unique content); `caption` is one
    /// caption at 95 s; a user date is Rick's (reliable); `camera` is a
    /// trusted camera stamp; `inferred` an inferred date (not reliable).
    static func row(_ path: String, key: String? = nil, caption: String? = nil, captions: [SceneCaption] = [],
                    transcript: String? = nil, userDate: String? = nil, camera: Date? = nil, inferred: Date? = nil,
                    inferredSource: String? = nil, footage: UUID? = nil, role: String? = nil,
                    people: [String] = [], duration: Double = 60, id: UUID = UUID()) -> EventsRow {
        var caps = captions
        if let caption { caps.append(SceneCaption(timestamp: 95, text: caption)) }
        return EventsRow(
            id: id, contentKey: key ?? "id:" + id.uuidString, path: path, filename: (path as NSString).lastPathComponent,
            volumeName: path.split(separator: "/").dropFirst().first.map(String.init) ?? "", durationSeconds: duration,
            captions: caps, transcript: transcript,
            dateFacts: EventsDateFacts(userDate: userDate, embeddedCreationDate: camera, originMake: camera == nil ? nil : "Sony",
                                       inferredRecordDate: inferred, inferredDateConfidence: inferred == nil ? nil : 0.9,
                                       inferredDateSource: inferredSource),
            confirmedPeople: people, footageGroupID: footage, footageRole: role)
    }

    static func plan(_ rows: [EventsRow], decisions: EventsDecisionSnapshot = .empty,
                     birthdays: [FamilyBirthday] = []) -> EventsPlan {
        EventsPlanner.plan(rows: rows, decisions: decisions, birthdays: birthdays, now: day(2026, 10, 14))
    }

    /// A fresh per-test folder under the system temp dir.
    static func scratchDirectory(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VideoScan-tests/events-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A catalog record shaped like a captioned clip (for the model half).
    @MainActor
    static func record(_ path: String, caption: String? = nil, userDate: String? = nil, digest: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 60
        r.sizeBytes = 1_000_000
        if let caption { r.sceneCaptions = [SceneCaption(timestamp: 95, text: caption)] }
        r.userDate = userDate
        if let digest {
            r.contentFixity = ContentFixity(digest: digest, byteCount: r.sizeBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: 1, size: r.sizeBytes, mtimeNs: 0),
                                            computedAt: Date())
        }
        return r
    }
}
