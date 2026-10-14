// EventsPlan.swift
// Triage ▸ Events v1 — the PLAN: "which recordings belong to the same
// family memory?" (docs/design/events_design.md v2;
// docs/design/events_v1_plan_2026_10_14.md, sections 2 and 4).
//
// Values plus ONE pure pipeline (`EventsPlanner.plan`). It never touches
// the catalog (main actor), never opens a media file, and never reads the
// disk: the rows arrive as Sendable `EventsRow` values (one per catalog
// record, copied on the main actor by `VideoScanModel.eventsInputs()`),
// the birthdays as values, Rick's decisions as a snapshot.
//
// Stages, in order:
//   A  identity   rows fold into one WITNESS per content key: the stored
//                 full SHA-256; "pair:<pairGroupID>" for the halves of an
//                 A/V pair; "id:<record>" when neither. Every copy's file
//                 and folder name contributes a label; `footage` lineage is
//                 shown as evidence ("same footage as X, likely"), never
//                 collapsed. Dates keep their source (you › camera ›
//                 inferred › file name › folder year).
//   C  category   `EventCategoryRules.evidence` (VideoScanCore) per witness.
//   B  runs       conservative adjacency: a witness joins a run when it
//                 shares a folder OR is dated (day-precise, not a folder
//                 year) within 4 days of the run's last date, the run's
//                 whole span staying within 14 days; categories must be
//                 compatible; a reliable date conflict (years apart)
//                 blocks; two reliable dates more than 14 days apart never
//                 join on a folder alone (that pair becomes the question).
//                 A witness with no evidence of its own joins only on
//                 folder AND date together (candles indoors, children
//                 outside: one party). A folder's label and a folder's
//                 year are ONE source: neither counts twice.
//   D  instances  each run is one suggestion; the one question — "Same
//                 occasion, or different years?" — for two suggestions in
//                 one category and one folder dated > 14 days apart or
//                 undated.
//   F  decisions  `reapplying(_:)` folds Rick's decisions in without
//                 rebuilding: settled members leave the queue, dismissed
//                 suggestions stay hidden while their facts hold,
//                 confirmed events are listed from his word alone.
//
// Grouping never marks a clip covered (design §1.3): nothing here is read
// by any delete or archive path.
//
// Memory: one `EventsRow` per active record (captions and transcript are
// shared `String` storage with the catalog, not copied: ~300 B + text),
// one witness per content, members only for witnesses with evidence or a
// decision. ~60 MB worst case at 100k rows with every row captioned.
//
// (For Rick: everything here is a `struct` — value semantics, copied like
// a C++ POD — and `Sendable`, so the planner runs on a worker thread.)

import Foundation
import VideoScanCore

// MARK: - Input: one catalog row, as Events reads it

/// The record's date facts, as values, for `RecordDateResolver` off-main.
struct EventsDateFacts: Sendable, Equatable {
    var userDate: String?
    var userDateConfidence: String?
    var embeddedCreationDate: Date?
    var originMake: String?
    var originModel: String?
    var originEncoder: String?
    var inferredRecordDate: Date?
    var inferredDateConfidence: Float?
    var inferredDateRange: InferredDateRange?
    /// `VideoScanModel.InferredDateSource` ("folder-year" is a folder year).
    var inferredDateSource: String?

    static let none = EventsDateFacts()
}

/// One active catalog row, copied on the main actor.
struct EventsRow: Sendable, Equatable, Identifiable {
    let id: UUID
    let contentKey: String
    let path: String
    let filename: String
    let volumeName: String
    let durationSeconds: Double
    let captions: [SceneCaption]
    let transcript: String?
    let dateFacts: EventsDateFacts
    let confirmedPeople: [String]
    let footageGroupID: UUID?
    let footageRole: String?

    var folder: String { (path as NSString).deletingLastPathComponent }
}

// MARK: - A date with its source

/// A recording's date and where it came from (design principle 4: never
/// blended silently). Only a trusted, day-precise date keys a calendar
/// day; a folder year never chains two recordings together.
struct EventsDate: Sendable, Hashable {
    enum Source: Int, Sendable, Comparable {
        case none = 0, folderYear, fileName, inferred, camera, you
        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }

        var words: String {
            switch self {
            case .you: return "your date"
            case .camera: return "camera"
            case .inferred: return "inferred"
            case .fileName: return "file name"
            case .folderYear: return "folder name (year only)"
            case .none: return "no date"
            }
        }
    }

    let year: Int?
    let month: Int?
    let day: Int?
    let source: Source
    /// A camera stamp with no camera behind it dates the COPY: it keys no
    /// day and settles no conflict (the Archive Angel's rule, v14).
    let trusted: Bool

    static let none = EventsDate(year: nil, month: nil, day: nil, source: .none, trusted: false)

    /// The calendar day for EventLabeler — trusted and day-precise only.
    var eventDay: EventDay? {
        guard trusted, let year, let month, let day else { return nil }
        return EventDay(year: year, month: month, day: day)
    }

    /// Noon UTC of the day, for "within 4 days" arithmetic. Day-precise,
    /// never a folder year (the only source that has no day anyway).
    var dayInstant: Date? {
        guard source != .folderYear, let year, let month, let day else { return nil }
        return Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// The year that can BLOCK a merge: Rick's or a trusted camera's.
    var reliableYear: Int? {
        switch source {
        case .you: return year
        case .camera: return trusted ? year : nil
        case .inferred, .fileName, .folderYear, .none: return nil
        }
    }

    /// "Jun 5, 1998 (your date)", "Jun 1998 (camera)", "1998 (folder name (year only))", "no date".
    var words: String {
        guard let year else { return source.words }
        let base: String
        if let month, let day { base = "\(Self.monthNames[month - 1]) \(day), \(year)" }
        else if let month { base = "\(Self.monthNames[month - 1]) \(year)" }
        else { base = String(year) }
        return "\(base) (\(source.words))"
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The record's date with its source: the app's one resolver first
    /// (you › camera › inferred › file name), then a year in the path as
    /// the last resort. Pure.
    static func resolve(_ f: EventsDateFacts, filename: String, path: String, now: Date) -> EventsDate {
        let r = RecordDateResolver.resolve(
            userDate: f.userDate, userDateConfidence: f.userDateConfidence, embeddedCreationDate: f.embeddedCreationDate,
            originMake: f.originMake, originModel: f.originModel, originEncoder: f.originEncoder,
            inferredRecordDate: f.inferredRecordDate, inferredDateConfidence: f.inferredDateConfidence,
            inferredDateRange: f.inferredDateRange, filename: filename.isEmpty ? nil : filename, now: now)
        guard let year = r.year else {
            guard let folderYear = EventsPathYear.year(in: path, now: now) else { return .none }
            return EventsDate(year: folderYear, month: nil, day: nil, source: .folderYear, trusted: false)
        }
        let source: Source
        switch r.source {
        case .userDate: source = .you
        case .embedded: source = .camera
        case .inferred: source = f.inferredDateSource == VideoScanModel.InferredDateSource.folderYear ? .folderYear : .inferred
        case .filename: source = .fileName
        case .none: source = .none
        }
        let trusted = r.source != .embedded || r.confidence >= RecordDateResolver.embeddedConfidenceUnknownOrigin
        let month = r.precision <= .month ? r.month : nil
        let day = r.precision == .day ? r.day : nil
        return EventsDate(year: year, month: month, day: day, source: source, trusted: trusted)
    }
}

/// A four-digit year in a path (1950 … now) — the prototype's last resort.
enum EventsPathYear {
    static func year(in path: String, now: Date) -> Int? {
        let thisYear = Calendar.current.component(.year, from: now)
        var digits = 0
        var value = 0
        var found: Int?
        for ch in path.utf8 {
            if ch >= 0x30 && ch <= 0x39 {
                digits += 1
                value = digits <= 4 ? value * 10 + Int(ch - 0x30) : value
            } else {
                if digits == 4, value >= 1950, value <= thisYear { found = value }
                digits = 0
                value = 0
            }
        }
        if digits == 4, value >= 1950, value <= thisYear { found = value }
        return found
    }
}

// MARK: - Output: the plan

/// One line of evidence on a member, with the category it supports.
struct EvidenceLine: Sendable, Hashable {
    let category: String
    let source: EventEvidenceSource
    let words: String
    let timestamp: Double?

    init(category: String, _ line: EventEvidenceLine) {
        self.category = category
        self.source = line.source
        self.words = line.words
        self.timestamp = line.timestamp
    }
}

/// One recording in a suggestion or a confirmed event.
struct EventMember: Sendable, Equatable, Identifiable {
    enum State: String, Sendable { case suggested, accepted, rejected }

    /// The representative record (the first copy by path).
    let id: UUID
    let range: ContentRange
    let filename: String
    let path: String
    let volumeName: String
    let copies: Int
    let durationSeconds: Double
    let date: EventsDate
    let evidence: [EvidenceLine]
    /// nil for a member attached by folder and date alone.
    let strength: EventEvidenceStrength?
    /// "same footage as X, likely" — shown, never used to group.
    let lineage: String?
    let people: [String]
    /// Why an evidence-less member is here ("same folder and day as …").
    let link: String?
    var state: State = .suggested

    /// A member Rick accepted whose content is not in the catalog now
    /// (a drive away, a rescan): the decision stands, the details wait.
    static func placeholder(_ range: ContentRange) -> EventMember {
        EventMember(id: UUID(), range: range, filename: "(not in the catalog now)", path: "", volumeName: "",
                    copies: 0, durationSeconds: 0, date: .none, evidence: [], strength: nil, lineage: nil,
                    people: [], link: nil, state: .accepted)
    }
}

/// What a dismissed suggestion looked like; it returns only when these move.
struct SuggestionFacts: Codable, Hashable, Sendable {
    var members: Int
    var evidence: Int
}

/// A proposed event instance: one capture run.
struct EventSuggestion: Sendable, Equatable, Identifiable {
    /// Stable across rebuilds while the run's first content stays: the
    /// primary category + the smallest member content key.
    let key: String
    let name: String
    /// Most evidence first.
    let categories: [String]
    var members: [EventMember]
    let dateWords: String
    let start: Date?
    let end: Date?
    let folders: [String]
    let strength: EventEvidenceStrength?
    /// The prototype's rule, kept for the metrics stream: a seen-and-said
    /// member, or three members.
    let isStrong: Bool
    /// A caveat the card says out loud (an untimed transcript on a long tape).
    let note: String?

    var id: String { key }
    var primaryCategory: String { categories.first ?? "" }
    var facts: SuggestionFacts { SuggestionFacts(members: members.count, evidence: members.reduce(0) { $0 + $1.evidence.count }) }
}

/// An event Rick confirmed, listed from his decisions alone.
struct ConfirmedEvent: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let categories: [String]
    let members: [EventMember]
    let dateWords: String
    let updatedAt: Date
}

/// The one high-value question (design §5).
struct EventsQuestion: Sendable, Equatable, Identifiable {
    let a: String
    let b: String
    let category: String
    let folder: String
    let aRange: ContentRange
    let bRange: ContentRange
    let aWords: String
    let bWords: String
    var id: String { a + "?" + b }
    var pair: EventsPair { EventsPair(aRange.contentKey, bRange.contentKey) }
}

/// Two content keys, unordered.
struct EventsPair: Hashable, Sendable, Codable {
    let a: String
    let b: String
    init(_ x: String, _ y: String) {
        a = min(x, y)
        b = max(x, y)
    }
}

/// Why a recording is not in the queue: a stable key plus its words
/// (the CleanupExclusion shape — a value carrying its own words).
struct EventsExclusion: Sendable, Hashable {
    let key: String
    let words: String
    private init(_ key: String, _ words: String) {
        self.key = key
        self.words = words
    }
    static let noEvidence = Self("noEvidence", "no event words in its captions, transcript, names or dates")
    static let settled = Self("settled", "already in an event you confirmed")
    static let dismissed = Self("dismissed", "a suggestion you dismissed — it returns if the facts change")
    static let categoryRejected = Self("categoryRejected", "a category you said no to for this recording")
}

struct EventsPlan: Sendable, Equatable {
    /// The review queue, after decisions.
    var suggestions: [EventSuggestion] = []
    var confirmed: [ConfirmedEvent] = []
    var questions: [EventsQuestion] = []
    var leftOut: [EventsExclusion: Int] = [:]
    /// Set when the decisions file could not be written to (the page says so).
    var readOnlyReason: String?

    // The counts-only facts (`EventsStats`), summed ONCE when built (the
    // planner, in this file, sets the first four).
    fileprivate(set) var rowCount = 0
    fileprivate(set) var withCaptions = 0
    fileprivate(set) var withTranscripts = 0
    fileprivate(set) var witnessesWithEvidence = 0
    private(set) var candidateCount = 0
    private(set) var strongCount = 0
    private(set) var byCategory: [String: Int] = [:]
    private(set) var toReview = 0

    static let empty = EventsPlan()

    /// Every suggestion BEFORE decisions, and the members decisions may
    /// name, so `reapplying` never re-runs the rules.
    fileprivate var allSuggestions: [EventSuggestion] = []
    fileprivate var allQuestions: [EventsQuestion] = []
    fileprivate var membersByContent: [String: EventMember] = [:]
    fileprivate var noEvidenceCount = 0

    /// Sum the page's numbers. The planner calls it last.
    mutating func finishTotals() {
        candidateCount = allSuggestions.count
        strongCount = allSuggestions.filter(\.isStrong).count
        var counts = Dictionary(uniqueKeysWithValues: EventCategory.all.map { ($0.name, 0) })
        for s in allSuggestions { counts[s.primaryCategory, default: 0] += 1 }
        byCategory = counts
        toReview = suggestions.count + questions.count
    }

    /// Fold Rick's decisions into THIS plan — O(suggestions + decisions),
    /// no rules, no runs (the store calls it after every mutation).
    func reapplying(_ d: EventsDecisionSnapshot) -> EventsPlan {
        var plan = self
        plan.leftOut = [:]
        if noEvidenceCount > 0 { plan.leftOut[.noEvidence] = noEvidenceCount }
        var kept: [EventSuggestion] = []
        var keptKeys = Set<String>()
        for s in allSuggestions {
            if d.dismissed[s.key] == s.facts {
                plan.leftOut[.dismissed, default: 0] += s.members.count
                continue
            }
            var members: [EventMember] = []
            for m in s.members {
                if d.isSettled(m.range.contentKey) {
                    plan.leftOut[.settled, default: 0] += 1
                } else if s.categories.contains(where: { d.categoryRejected.contains(EventsCategoryKey(m.range.contentKey, $0)) }) {
                    plan.leftOut[.categoryRejected, default: 0] += 1
                } else {
                    members.append(m)
                }
            }
            guard !members.isEmpty else { continue }
            var s = s
            s.members = members
            kept.append(s)
            keptKeys.insert(s.key)
        }
        plan.suggestions = kept
        plan.questions = allQuestions.filter {
            keptKeys.contains($0.a) && keptKeys.contains($0.b) && !d.differentOccasions.contains($0.pair)
        }
        plan.confirmed = EventsPlanner.confirmedEvents(d, members: membersByContent)
        plan.finishTotals()
        return plan
    }
}

// MARK: - Witnesses (stage A + C)

/// One content, every copy of it, and what it says.
struct EventWitness: Sendable, Identifiable {
    let contentKey: String
    /// Every copy, by path; the first is the representative.
    let rows: [EventsRow]
    let date: EventsDate
    var evidence: [EventCategoryEvidence]
    let lineage: String?

    var id: UUID { rows[0].id }
    var representative: EventsRow { rows[0] }
    var folders: Set<String> { Set(rows.map(\.folder)) }
    var categories: [String] { evidence.map(\.category) }
    var people: [String] { Array(Set(rows.flatMap(\.confirmedPeople))).sorted() }
    var bestStrength: EventEvidenceStrength? { evidence.map(\.strength).max() }
    var dayInstant: Date? { date.dayInstant }
}

// MARK: - The planner (pure)

enum EventsPlanner {

    /// The conservative rules (plan §2), as data.
    enum Rules {
        static let adjacencyDays = 4.0
        static let spanDays = 14.0
        static let longTapeSeconds = 20.0 * 60
        static let strongMemberCount = 3
        static var adjacency: TimeInterval { adjacencyDays * 86_400 }
        static var span: TimeInterval { spanDays * 86_400 }
    }

    /// Build the plan: witnesses → evidence → runs → suggestions → the
    /// question → decisions. `birthdays` are the People tab's (values).
    static func plan(rows: [EventsRow], decisions: EventsDecisionSnapshot, birthdays: [FamilyBirthday],
                     now: Date = Date()) -> EventsPlan {
        var plan = EventsPlan()
        plan.rowCount = rows.count
        plan.withCaptions = rows.filter { !$0.captions.isEmpty }.count
        plan.withTranscripts = rows.filter { !($0.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let witnesses = self.witnesses(rows, birthdays: birthdays, now: now)
        plan.witnessesWithEvidence = witnesses.filter { !$0.evidence.isEmpty }.count
        plan.noEvidenceCount = witnesses.count - plan.witnessesWithEvidence
        let runs = self.runs(witnesses, blocked: decisions.differentOccasions)
        plan.allSuggestions = runs.map { suggestion($0) }
        plan.allQuestions = questions(plan.allSuggestions)
        plan.membersByContent = memberIndex(witnesses, suggestions: plan.allSuggestions, decisions: decisions)
        return plan.reapplying(decisions)
    }

    // MARK: Stage A + C — witnesses

    /// Rows folded by content key; labels from EVERY copy's names; the
    /// best date across copies; the category evidence per witness.
    static func witnesses(_ rows: [EventsRow], birthdays: [FamilyBirthday], now: Date) -> [EventWitness] {
        var byKey: [String: [EventsRow]] = [:]
        for r in rows { byKey[r.contentKey, default: []].append(r) }
        let lineage = lineageWords(rows)
        var cache = EventLabeler.FolderWordCache()
        var out: [EventWitness] = []
        out.reserveCapacity(byKey.count)
        for (key, group) in byKey {
            let copies = group.sorted { $0.path < $1.path }
            let date = copies.map { EventsDate.resolve($0.dateFacts, filename: $0.filename, path: $0.path, now: now) }
                .max { $0.source < $1.source } ?? .none
            var labels: [EventLabel] = []
            for c in copies {
                for l in EventLabeler.labels(day: date.eventDay, year: date.trusted ? date.year : nil, filename: c.filename,
                                             fullPath: c.path, birthdays: birthdays,
                                             birthdayWindowDays: EventLabeler.defaultBirthdayWindowDays, cache: &cache)
                where !labels.contains(l) { labels.append(l) }
            }
            let spoken = copies.first { !($0.transcript ?? "").isEmpty }
            let captioned = copies.first { !$0.captions.isEmpty }
            let evidence = EventCategoryRules.evidence(captions: captioned?.captions ?? [], transcript: spoken?.transcript,
                                                       labels: labels)
            out.append(EventWitness(contentKey: key, rows: copies, date: date, evidence: evidence,
                                    lineage: copies.lazy.compactMap { lineage[$0.id] }.first))
        }
        return out.sorted { $0.representative.path < $1.representative.path }
    }

    /// "same footage as X, likely" for every row in a footage group with
    /// another row of DIFFERENT content (a copy is the same witness).
    static func lineageWords(_ rows: [EventsRow]) -> [UUID: String] {
        var groups: [UUID: [EventsRow]] = [:]
        for r in rows { if let g = r.footageGroupID { groups[g, default: []].append(r) } }
        var out: [UUID: String] = [:]
        for members in groups.values where members.count > 1 {
            for r in members {
                guard let other = members.first(where: { $0.contentKey != r.contentKey }) else { continue }
                let role = r.footageRole.map { " (\($0))" } ?? ""
                out[r.id] = "same footage as \(other.filename), likely\(role)"
            }
        }
        return out
    }

    // MARK: Stage B — capture runs

    /// A run under construction.
    struct Run {
        var members: [EventWitness] = []
        var categories: [String: Int] = [:]
        var folders: Set<String> = []
        var first: Date?
        var last: Date?
        var reliableYear: Int?

        var hasEvidence: Bool { !categories.isEmpty }

        mutating func add(_ w: EventWitness) {
            members.append(w)
            for c in w.categories { categories[c, default: 0] += 1 }
            folders.formUnion(w.folders)
            if let d = w.dayInstant {
                first = min(first ?? d, d)
                last = max(last ?? d, d)
            }
            if reliableYear == nil { reliableYear = w.date.reliableYear }
        }
    }

    /// Pass 1 opens runs from witnesses WITH evidence (dated first, in
    /// date order, so the span bound reads forward); pass 2 attaches
    /// evidence-less witnesses on folder AND date together. Folder lookups
    /// go through an index; date lookups through the window of runs still
    /// within reach — the walk stays O(n · small).
    static func runs(_ witnesses: [EventWitness], blocked: Set<EventsPair>) -> [Run] {
        var runs: [Run] = []
        var byFolder: [String: [Int]] = [:]
        var recent: [Int] = []           // runs whose last date may still be within reach
        let evidenced = witnesses.filter { !$0.evidence.isEmpty }.sorted(by: dateOrder)
        for w in evidenced {
            var i = home(for: w, runs: runs, byFolder: byFolder, recent: &recent, blocked: blocked, needsBoth: false)
            if i == nil {
                runs.append(Run())
                i = runs.count - 1
            }
            join(w, run: i!, runs: &runs, byFolder: &byFolder, recent: &recent)
        }
        // Pass 2 needs the folder AND the date, so the folder index alone
        // names its candidates: no date window to copy per witness.
        var noWindow: [Int] = []
        for w in witnesses where w.evidence.isEmpty {
            if let i = home(for: w, runs: runs, byFolder: byFolder, recent: &noWindow, blocked: blocked, needsBoth: true) {
                join(w, run: i, runs: &runs, byFolder: &byFolder, recent: &noWindow)
            }
        }
        return runs
    }

    private static func dateOrder(_ a: EventWitness, _ b: EventWitness) -> Bool {
        switch (a.dayInstant, b.dayInstant) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.representative.path < b.representative.path
        }
    }

    /// Add `w` to run `i`; index its folders; a dated join puts the run
    /// (back) in the date window — its last date just moved forward.
    private static func join(_ w: EventWitness, run i: Int, runs: inout [Run], byFolder: inout [String: [Int]],
                             recent: inout [Int]) {
        runs[i].add(w)
        for f in w.folders where !(byFolder[f] ?? []).contains(i) { byFolder[f, default: []].append(i) }
        if w.dayInstant != nil, !recent.contains(i) { recent.append(i) }
    }

    /// The first run `w` may join: by folder (index), then by date
    /// (recent runs; those out of reach are dropped from the window).
    private static func home(for w: EventWitness, runs: [Run], byFolder: [String: [Int]], recent: inout [Int],
                             blocked: Set<EventsPair>, needsBoth: Bool) -> Int? {
        var candidates: [Int] = []
        for f in w.folders { candidates += byFolder[f] ?? [] }
        if let d = w.dayInstant, !needsBoth {
            recent.removeAll { runs[$0].last.map { d.timeIntervalSince($0) > Rules.adjacency } ?? false }
            candidates += recent
        }
        var seen = Set<Int>()
        for i in candidates where seen.insert(i).inserted {
            let link = EventsLink(w, runs[i])
            guard link.joins(needsBoth: needsBoth), !link.yearConflict, link.compatible,
                  !link.isBlocked(blocked) else { continue }
            return i
        }
        return nil
    }

    // MARK: Stage D — suggestions and the question

    static func suggestion(_ run: Run) -> EventSuggestion {
        let categories = run.categories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let members = run.members.map { member($0, categories: categories) }
        let strength = run.members.compactMap(\.bestStrength).max()
        let dated = run.members.filter { $0.dayInstant != nil }.map(\.date)
        let folderOnly = run.members.allSatisfy { $0.date.source == .folderYear || $0.date.source == .none }
        let dateWords = EventsNaming.dateWords(dated: dated, fallback: folderOnly ? run.members.first?.date : nil)
        let primary = categories.first ?? ""
        let longTape = run.members.contains {
            $0.representative.durationSeconds >= Rules.longTapeSeconds && $0.evidence.contains { $0.lines.contains { $0.source == .transcript } }
        }
        return EventSuggestion(
            key: primary + "|" + (run.members.map(\.contentKey).min() ?? ""),
            name: EventsNaming.suggestionName(category: primary, dateWords: dateWords),
            categories: categories, members: members, dateWords: dateWords, start: run.first, end: run.last,
            folders: run.folders.sorted(), strength: strength,
            isStrong: strength == .seenAndSaid || run.members.count >= Rules.strongMemberCount,
            note: longTape ? EventsNaming.untimedTranscriptNote : nil)
    }

    static func member(_ w: EventWitness, categories: [String]) -> EventMember {
        let lines = w.evidence.filter { categories.contains($0.category) }
            .flatMap { e in e.lines.map { EvidenceLine(category: e.category, $0) } }
        let link: String? = w.evidence.isEmpty
            ? "no words of its own — same folder and day as the others" : nil
        let r = w.representative
        return EventMember(id: r.id, range: ContentRange(contentKey: w.contentKey), filename: r.filename, path: r.path,
                           volumeName: r.volumeName, copies: w.rows.count, durationSeconds: r.durationSeconds,
                           date: w.date, evidence: lines, strength: w.bestStrength, lineage: w.lineage,
                           people: w.people, link: link)
    }

    /// Consecutive suggestions (by date) in one category sharing a folder,
    /// dated more than the span apart or undated.
    static func questions(_ suggestions: [EventSuggestion]) -> [EventsQuestion] {
        var byCategoryFolder: [String: [EventSuggestion]] = [:]
        for s in suggestions {
            for f in s.folders { byCategoryFolder[s.primaryCategory + "\u{1F}" + f, default: []].append(s) }
        }
        var out: [EventsQuestion] = []
        for (key, group) in byCategoryFolder where group.count > 1 {
            let sorted = group.sorted { ($0.start ?? .distantFuture, $0.key) < ($1.start ?? .distantFuture, $1.key) }
            let folder = String(key.split(separator: "\u{1F}", maxSplits: 1)[1])
            for (a, b) in zip(sorted, sorted.dropFirst()) where asksSameOccasion(a, b) {
                out.append(EventsQuestion(a: a.key, b: b.key, category: a.primaryCategory, folder: folder,
                                          aRange: a.members[0].range, bRange: b.members[0].range,
                                          aWords: a.name, bWords: b.name))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    static func asksSameOccasion(_ a: EventSuggestion, _ b: EventSuggestion) -> Bool {
        guard let x = a.end ?? a.start, let y = b.start ?? b.end else { return true }
        return abs(y.timeIntervalSince(x)) > Rules.span
    }

    // MARK: Stage F — decisions

    /// Members decisions may name: every suggestion member, plus witnesses
    /// whose content a decision mentions (a confirmed member that lost its
    /// evidence still shows its file).
    static func memberIndex(_ witnesses: [EventWitness], suggestions: [EventSuggestion],
                            decisions: EventsDecisionSnapshot) -> [String: EventMember] {
        var index: [String: EventMember] = [:]
        for s in suggestions {
            for m in s.members where index[m.range.contentKey] == nil { index[m.range.contentKey] = m }
        }
        let named = decisions.namedContentKeys
        guard !named.isEmpty else { return index }
        for w in witnesses where index[w.contentKey] == nil && named.contains(w.contentKey) {
            index[w.contentKey] = member(w, categories: w.categories)
        }
        return index
    }

    /// The confirmed list, from Rick's word: each live event with its
    /// accepted members (details from the index, else a placeholder).
    static func confirmedEvents(_ d: EventsDecisionSnapshot, members: [String: EventMember]) -> [ConfirmedEvent] {
        d.liveEvents.map { e in
            let ranges = d.members(of: e.id).sorted { $0.contentKey < $1.contentKey }
            let list = ranges.map { r -> EventMember in
                var m = members[r.contentKey] ?? .placeholder(r)
                m.state = .accepted
                return m
            }
            let dated = list.map(\.date).filter { $0.dayInstant != nil }
            return ConfirmedEvent(id: e.id, name: e.name, categories: e.categories, members: list,
                                  dateWords: EventsNaming.dateWords(dated: dated, fallback: list.first?.date),
                                  updatedAt: e.updatedAt)
        }
        .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.name < $1.name }
    }
}

/// How one witness relates to one run — the join rules as a value.
struct EventsLink {
    let sharesFolder: Bool
    let datedWithin: Bool
    let datedApart: Bool
    let yearConflict: Bool
    let compatible: Bool
    let runHasEvidence: Bool
    let contentKey: String
    let runKeys: [String]

    init(_ w: EventWitness, _ run: EventsPlanner.Run) {
        sharesFolder = !w.folders.isDisjoint(with: run.folders)
        if let d = w.dayInstant, let last = run.last, let first = run.first {
            let gap = abs(d.timeIntervalSince(last))
            datedWithin = gap <= EventsPlanner.Rules.adjacency
                && max(d, last).timeIntervalSince(min(d, first)) <= EventsPlanner.Rules.span
            datedApart = gap > EventsPlanner.Rules.span
        } else {
            datedWithin = false
            datedApart = false
        }
        yearConflict = w.date.reliableYear != nil && run.reliableYear != nil && w.date.reliableYear != run.reliableYear
        compatible = w.categories.allSatisfy { c in run.categories.keys.allSatisfy { EventCategory.compatible(c, $0) } }
        runHasEvidence = run.hasEvidence
        contentKey = w.contentKey
        runKeys = run.members.map(\.contentKey)
    }

    /// Folder OR date (with evidence); folder AND date (without). A folder
    /// alone never bridges two reliable dates more than the span apart.
    func joins(needsBoth: Bool) -> Bool {
        if needsBoth { return runHasEvidence && sharesFolder && datedWithin }
        return datedWithin || (sharesFolder && !datedApart)
    }

    func isBlocked(_ pairs: Set<EventsPair>) -> Bool {
        !pairs.isEmpty && runKeys.contains { pairs.contains(EventsPair(contentKey, $0)) }
    }
}

// MARK: - Names and date words (pure, pinned by EventsSensorTests)

enum EventsNaming {
    static let untimedTranscriptNote = "A long tape: its transcript isn't timed, so these words may belong to one of several occasions on it."

    /// "Birthday · Jun 5, 1998 (your date)"; "Christmas · date unknown".
    static func suggestionName(category: String, dateWords: String) -> String {
        "\(category) · \(dateWords)"
    }

    /// One day, a range, a folder year, or "date unknown" — the source
    /// kept with it.
    static func dateWords(dated: [EventsDate], fallback: EventsDate?) -> String {
        let sorted = dated.compactMap { d in d.dayInstant.map { ($0, d) } }.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else {
            guard let fallback, fallback.year != nil else { return "date unknown" }
            return fallback.words
        }
        if first.0 == last.0 { return first.1.words }
        return "\(first.1.words) – \(last.1.words)"
    }
}
