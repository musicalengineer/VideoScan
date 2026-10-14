// VideoScanModel+Events.swift
// Triage ▸ Events v1 — the catalog half of the PLAN
// (docs/design/events_v1_plan_2026_10_14.md §4, the Triage-snapshot shape,
// swift_playbook §2).
//
//   1. `eventsInputs()` — ONE O(records) pass on the main actor that
//      copies what the planner reads into Sendable values (`EventsRow`).
//      Never called from a view body: the page's store calls it from a
//      handler. Scope (plan Q1 default): the rows the Archive Angel
//      assesses — `pfActiveRecords`: not purged (the removal marker:
//      Trash / removed / missing), not set aside, not superseded.
//   2. `buildEventsPlan(decisions:birthdays:)` — the projection here, the
//      birthdays read (disk) and the pure planner off the main actor in a
//      detached task.
//   3. `eventsNote(_:)` — the one sink: console + catalog.log,
//      videoscan.log, unified log (the Cleanup shape).
//   4. `eventsStats(…)` — the counts-only object the metrics page reads
//      (`EVENTS_KEYS` in tools/publish_metrics.py): no name, path, caption
//      or speech ever leaves the machine in it.
//
// Memory: ~300 bytes per active record plus SHARED caption / transcript
// storage (Swift strings are copy-on-write; nothing is duplicated).

import Foundation
import os
import VideoScanCore

private let eventsLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "events")

/// Everything the plan reads, captured on the main actor as values.
struct EventsInputs: Sendable {
    let rows: [EventsRow]
    let now: Date
    /// How long the one pass took (the log line; the scale test).
    let projectionNanos: UInt64
}

extension VideoScanModel {

    /// The one O(records) pass (main actor). Pure copies; no disk.
    func eventsInputs() -> EventsInputs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var rows: [EventsRow] = []
        rows.reserveCapacity(records.count)
        for r in records where Self.isInEventsScope(r) {
            rows.append(Self.eventsRow(r))
        }
        return EventsInputs(rows: rows, now: Date(), projectionNanos: DispatchTime.now().uptimeNanoseconds &- t0)
    }

    /// Plan Q1 default: the Archive Angel's active rows.
    nonisolated static func isInEventsScope(_ r: VideoRecord) -> Bool {
        !r.isPurged && !r.isSetAside && !r.isSuperseded && !r.fullPath.isEmpty
    }

    /// One record's observations, with their sources. Pure.
    nonisolated static func eventsRow(_ r: VideoRecord) -> EventsRow {
        EventsRow(
            id: r.id, contentKey: eventsContentKey(r), path: r.fullPath, filename: r.filename, volumeName: r.volumeName,
            durationSeconds: r.durationSeconds, captions: r.sceneCaptions, transcript: r.audioTranscript,
            dateFacts: EventsDateFacts(
                userDate: r.userDate, userDateConfidence: r.userDateConfidence,
                embeddedCreationDate: r.embeddedCreationDate, originMake: r.originMake, originModel: r.originModel,
                originEncoder: r.originEncoder, inferredRecordDate: r.inferredRecordDate,
                inferredDateConfidence: r.inferredDateConfidence, inferredDateRange: r.inferredDateRange,
                inferredDateSource: r.inferredDateSource),
            confirmedPeople: r.confirmedByUserPeople.map(\.name),
            footageGroupID: r.footage?.groupID, footageRole: r.footage?.role.label)
    }

    /// Identity (plan §2): the halves of an A/V pair are one witness; else
    /// the stored full SHA-256; else the record itself. Pure.
    nonisolated static func eventsContentKey(_ r: VideoRecord) -> String {
        if let pair = r.pairGroupID { return "pair:" + pair.uuidString }
        if let digest = storedFullDigest(r) { return digest }
        return "id:" + r.id.uuidString
    }

    /// Build the plan: the projection here, everything else off-main.
    /// `birthdays` is the People-tab reader (disk; none under a test host).
    func buildEventsPlan(decisions: EventsDecisionSnapshot,
                         birthdays: @escaping @Sendable () -> [FamilyBirthday]
                            = AngelEnvironment.familyBirthdaysReader(isTestHost: TestEnvironment.isTestHost))
    async -> EventsPlan {
        let inputs = eventsInputs()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let plan = await Task.detached(priority: .userInitiated) {
            EventsPlanner.plan(rows: inputs.rows, decisions: decisions, birthdays: birthdays(), now: inputs.now)
        }.value
        let planMillis = (DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
        eventsNote("checked \(inputs.rows.count) recordings in \(inputs.projectionNanos / 1_000_000 + planMillis) ms — "
                   + "\(plan.witnessesWithEvidence) with event words, \(plan.suggestions.count) to review, "
                   + "\(plan.questions.count) question\(plan.questions.count == 1 ? "" : "s"), \(plan.confirmed.count) confirmed")
        return plan
    }

    /// The one sink: console + catalog.log, videoscan.log, unified log.
    func eventsNote(_ line: String) {
        log("Events: " + line)
        appLog.write("[events] " + line)
        eventsLog.notice("\(line, privacy: .public)")
    }

    /// The counts-only metrics object. Pure.
    nonisolated static func eventsStats(plan: EventsPlan, decisions: EventsDecisionSnapshot, now: Date) -> EventsStats {
        EventsStats(plan: plan, decisions: decisions, now: now)
    }
}

// MARK: - The metrics object (EVENTS_KEYS, exactly)

/// `events_latest.json`: the keys `tools/publish_metrics.py` allowlists,
/// and nothing else. Marks are Rick's in-app decisions (accepted members =
/// yes; rejected members and rejected categories = no), null until he has
/// made one — the prototype's contract.
struct EventsStats: Codable, Equatable, Sendable {
    struct Marks: Codable, Equatable, Sendable {
        var yes: Int
        var no: Int
    }

    let ts: String
    let activeRecords: Int
    let withCaptions: Int
    let withTranscripts: Int
    let clipsWithEvidence: Int
    let candidateEvents: Int
    let strongEvents: Int
    let byCategory: [String: Int]
    let marksYes: Int?
    let marksNo: Int?
    let precisionByCategory: [String: Marks]?

    enum CodingKeys: String, CodingKey {
        case ts
        case activeRecords = "active_records"
        case withCaptions = "with_captions"
        case withTranscripts = "with_transcripts"
        case clipsWithEvidence = "clips_with_evidence"
        case candidateEvents = "candidate_events"
        case strongEvents = "strong_events"
        case byCategory = "by_category"
        case marksYes = "marks_yes"
        case marksNo = "marks_no"
        case precisionByCategory = "precision_by_category"
    }

    /// The exact key set, for the sensor and the publisher.
    static let keys = ["ts", "active_records", "with_captions", "with_transcripts", "clips_with_evidence",
                       "candidate_events", "strong_events", "by_category", "marks_yes", "marks_no", "precision_by_category"]

    /// Every key is always present: the marks are written as JSON null
    /// until Rick has decided something (JSONEncoder would omit them).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(activeRecords, forKey: .activeRecords)
        try c.encode(withCaptions, forKey: .withCaptions)
        try c.encode(withTranscripts, forKey: .withTranscripts)
        try c.encode(clipsWithEvidence, forKey: .clipsWithEvidence)
        try c.encode(candidateEvents, forKey: .candidateEvents)
        try c.encode(strongEvents, forKey: .strongEvents)
        try c.encode(byCategory, forKey: .byCategory)
        try c.encode(marksYes, forKey: .marksYes)
        try c.encode(marksNo, forKey: .marksNo)
        try c.encode(precisionByCategory, forKey: .precisionByCategory)
    }

    init(plan: EventsPlan, decisions: EventsDecisionSnapshot, now: Date) {
        ts = EventsStats.timestamp.string(from: now)
        activeRecords = plan.rowCount
        withCaptions = plan.withCaptions
        withTranscripts = plan.withTranscripts
        clipsWithEvidence = plan.witnessesWithEvidence
        candidateEvents = plan.candidateCount
        strongEvents = plan.strongCount
        byCategory = plan.byCategory
        let marks = EventsStats.marks(decisions)
        marksYes = marks?.values.reduce(0) { $0 + $1.yes }
        marksNo = marks?.values.reduce(0) { $0 + $1.no }
        precisionByCategory = marks
    }

    /// Per category: accepted members of live events carrying it (yes),
    /// categories said no to (no). nil when Rick has decided nothing.
    static func marks(_ d: EventsDecisionSnapshot) -> [String: Marks]? {
        var out = Dictionary(uniqueKeysWithValues: EventCategory.all.map { ($0.name, Marks(yes: 0, no: 0)) })
        var any = false
        for e in d.liveEvents {
            let count = d.members(of: e.id).count
            guard count > 0, let primary = e.categories.first, out[primary] != nil else { continue }
            out[primary]?.yes += count
            any = true
        }
        for k in d.categoryRejected where out[k.category] != nil {
            out[k.category]?.no += 1
            any = true
        }
        return any ? out : nil
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    /// Write the object beside the decisions file (counts only). Atomic;
    /// `.fast` — it is regenerable. Off the main actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func write(_ stats: EventsStats, to url: URL) async -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? enc.encode(stats) else { return false }
        return (try? AtomicFilePublish.write(data, to: url)) != nil
    }
}
