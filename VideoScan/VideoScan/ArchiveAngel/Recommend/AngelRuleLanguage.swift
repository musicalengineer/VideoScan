// AngelRuleLanguage.swift
// The small, CLOSED language the Archive Angel's recommendation policy is
// written in (Consolidation S3, Rick 2026-09-22: "the AA selection criteria
// should be easily programmable so we can add/delete/change the criteria as
// needed… not hard coded").
//
// A rule is a JSON object — `{ "id", "kind", "when": [conditions], "points",
// "line", "enabled", "note", … }` — interpreted by the Swift below. There is
// no scripting: a `kind` is one of a fixed list of named behaviours, a
// condition is `{ "field", "op", "value" }` over a fixed list of catalog
// facts, and `{ "any": [ … ] }` is the only combinator (the conditions of a
// `when` list are ANDed). Anything this file does not know — a kind, a
// field, an operator, a value of the wrong type, a choice that is not one of
// the field's values — makes the WHOLE policy file refused (logged, the
// defaults run). Evaluation never throws and never traps: an unresolved
// piece evaluates to "no match".
//
// Names are resolved ONCE, when the policy is decoded (a string switch per
// record per rule would cost a second at 100k records); evaluation is enum
// switches and set lookups.
//
// docs/archive_angel_policy.md is the user-facing reference (every field,
// operator and kind, with worked examples).
//
// (For Rick: think of this as a tiny interpreted rule table — the JSON is
// parsed into tagged unions (Swift enums with payloads ≈ std::variant) up
// front, and the per-record loop is a switch over those tags.)

import Foundation
import VideoScanCore

// MARK: - Values

/// A value in a rule: a JSON true/false, number, string, or list of strings.
enum AngelValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case strings([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let l = try? c.decode([String].self) { self = .strings(l); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "a rule value must be true/false, a number, a string or a list of strings")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .strings(let l): try c.encode(l)
        }
    }

    var typeName: String {
        switch self {
        case .bool: return "true/false"
        case .number: return "a number"
        case .string: return "a string"
        case .strings: return "a list of strings"
        }
    }
}

// MARK: - Fields

/// The catalog facts a condition may read. The raw value is the JSON name.
enum AngelField: String, CaseIterable, Sendable {
    // Text (case-insensitive)
    case filename, path, videoCodec, deviceModel, volumeName
    // Numbers
    case durationSeconds, durationMinutes, sizeMB, averageKbps, starRating, junkScore
    case tagCount, useCount, peopleCount, year, captureYear, duplicateGroupCount
    // Lists of names (case-insensitive)
    case people, machinePeople
    // Choices (one of a fixed set of names)
    case mediaDisposition, archiveStage, duplicateDisposition, volumeRole
    // true / false
    case isPhoneClip, isLivePhotoMotion, isHumanMarked, hasUserNotes, formatAtRisk, isOnlyCopy
    case isPairedHalf, volumeOnline, isOnMasterArchive, hasArchivedDuplicate, hasDuplicateGroup
    case hasUserDate, hasCaptions, hasOCRText
    // Classifier-only facts (the `recommend.classes` rules): the Angel's
    // grade, whether the record passed the floors, the vouch tally, the
    // date rule's answer.
    case grade, eligible, vouched, vouchPoints, dated

    enum Kind: Equatable, Sendable {
        case text, number, textList, flag
        case choice([String])
    }

    var kind: Kind {
        switch self {
        case .filename, .path, .videoCodec, .deviceModel, .volumeName: return .text
        case .durationSeconds, .durationMinutes, .sizeMB, .averageKbps, .starRating, .junkScore,
             .tagCount, .useCount, .peopleCount, .year, .captureYear, .duplicateGroupCount, .vouchPoints:
            return .number
        case .people, .machinePeople: return .textList
        case .mediaDisposition: return .choice(MediaDisposition.allCases.map(Self.name))
        case .archiveStage: return .choice(ArchiveStage.allCases.map(Self.name))
        case .duplicateDisposition: return .choice(Self.duplicateDispositions.map(Self.name))
        case .volumeRole: return .choice(VolumeRole.allCases.map(Self.name))
        case .grade: return .choice(ArchiveAngelGrade.allCases.map(\.rawValue))
        case .isPhoneClip, .isLivePhotoMotion, .isHumanMarked, .hasUserNotes, .formatAtRisk, .isOnlyCopy,
             .isPairedHalf, .volumeOnline, .isOnMasterArchive, .hasArchivedDuplicate, .hasDuplicateGroup,
             .hasUserDate, .hasCaptions, .hasOCRText, .eligible, .vouched, .dated:
            return .flag
        }
    }

    /// Only the class rules may read these (a floor runs before any of
    /// them exists).
    var isClassifierOnly: Bool {
        switch self {
        case .grade, .eligible, .vouched, .vouchPoints, .dated: return true
        default: return false
        }
    }

    // MARK: Choice names — the Swift case names, the words the docs use.
    // (Exhaustive switches: a new case in VideoScanCore fails the build
    // here instead of silently never matching.)

    static let duplicateDispositions: [DuplicateDisposition] = [.none, .keep, .review, .extraCopy]

    static func name(_ d: MediaDisposition) -> String {
        switch d {
        case .unreviewed: return "unreviewed"
        case .important: return "important"
        case .recoverable: return "recoverable"
        case .suspectedJunk: return "suspectedJunk"
        case .confirmedJunk: return "confirmedJunk"
        }
    }

    static func name(_ s: ArchiveStage) -> String {
        switch s {
        case .none: return "none"
        case .healthy: return "healthy"
        case .masterAssigned: return "masterAssigned"
        case .backedUp: return "backedUp"
        case .readyForArchive: return "readyForArchive"
        case .archived: return "archived"
        case .manuallyDeleted: return "manuallyDeleted"
        case .salvageFailed: return "salvageFailed"
        }
    }

    static func name(_ d: DuplicateDisposition) -> String {
        switch d {
        case .none: return "none"
        case .keep: return "keep"
        case .review: return "review"
        case .extraCopy: return "extraCopy"
        }
    }

    static func name(_ r: VolumeRole) -> String {
        switch r {
        case .unassigned: return "unassigned"
        case .system: return "system"
        case .workspace: return "workspace"
        case .backup: return "backup"
        case .cloud: return "cloud"
        case .archive: return "archive"
        }
    }

    /// A choice written by Rick: the case name ("suspectedJunk") or the
    /// label the app shows ("Suspected Junk"), any case → the case name.
    func canonicalChoice(_ written: String) -> String? {
        guard case .choice(let names) = kind else { return nil }
        let w = written.trimmingCharacters(in: .whitespaces).lowercased()
        if let hit = names.first(where: { $0.lowercased() == w }) { return hit }
        let labels: [(String, String)]
        switch self {
        case .mediaDisposition: labels = MediaDisposition.allCases.map { ($0.rawValue, Self.name($0)) }
        case .archiveStage: labels = ArchiveStage.allCases.map { ($0.rawValue, Self.name($0)) }
        case .duplicateDisposition: labels = Self.duplicateDispositions.map { ($0.rawValue, Self.name($0)) }
        case .volumeRole: labels = VolumeRole.allCases.map { ($0.rawValue, Self.name($0)) }
        default: labels = []
        }
        return labels.first { !$0.0.isEmpty && $0.0.lowercased() == w }?.1
    }
}

// MARK: - Operators

enum AngelOp: String, CaseIterable, Sendable {
    case eq = "=="
    case ne = "!="
    case lt = "<"
    case le = "<="
    case gt = ">"
    case ge = ">="
    case contains
    case notContains
    case hasPrefix
    case hasSuffix
    case `in`
    case notIn
}

// MARK: - Conditions

/// `{ "field": "durationMinutes", "op": "<", "value": 5 }` or
/// `{ "any": [ condition, … ] }`. Resolved at decode; `problem` names what
/// is wrong with it (validation refuses the file on any problem).
struct AngelCondition: Codable, Sendable, Equatable {
    var field: String?
    var op: String?
    var value: AngelValue?
    var any: [AngelCondition]?

    /// The compiled form. Not encoded.
    enum Compiled: Sendable, Equatable {
        case flag(AngelField, AngelOp, Bool)
        case number(AngelField, AngelOp, Double)
        case text(AngelField, AngelOp, String)            // lowercased operand
        case textSet(AngelField, AngelOp, Set<String>)    // in / notIn (lowercased)
        case choice(AngelField, AngelOp, Set<String>)     // canonical case names
        case any([AngelCondition])
        case invalid(String)
    }
    private(set) var compiled: Compiled = .invalid("not compiled")

    private enum CodingKeys: String, CodingKey { case field, op, value, any }

    init(field: AngelField, op: AngelOp, value: AngelValue) {
        self.field = field.rawValue
        self.op = op.rawValue
        self.value = value
        compiled = Self.compile(field: self.field, op: self.op, value: value, any: nil)
    }

    init(any: [AngelCondition]) {
        self.any = any
        compiled = Self.compile(field: nil, op: nil, value: nil, any: any)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(String.self, forKey: .field)
        op = try c.decodeIfPresent(String.self, forKey: .op)
        value = try c.decodeIfPresent(AngelValue.self, forKey: .value)
        any = try c.decodeIfPresent([AngelCondition].self, forKey: .any)
        compiled = Self.compile(field: field, op: op, value: value, any: any)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(field, forKey: .field)
        try c.encodeIfPresent(op, forKey: .op)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(any, forKey: .any)
    }

    // MARK: Compile (once, at decode)

    static func compile(field: String?, op: String?, value: AngelValue?, any: [AngelCondition]?) -> Compiled {
        if let any {
            guard field == nil, op == nil, value == nil else {
                return .invalid("a condition has either \"any\" or field/op/value, not both")
            }
            guard !any.isEmpty else { return .invalid("\"any\" needs at least one condition") }
            return .any(any)
        }
        guard let fieldName = field else { return .invalid("a condition needs \"field\" (or \"any\")") }
        guard let f = AngelField(rawValue: fieldName) else {
            return .invalid("unknown field \"\(fieldName)\" — known: \(AngelField.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let opName = op else { return .invalid("field \"\(fieldName)\" needs \"op\"") }
        guard let o = AngelOp(rawValue: opName) else {
            return .invalid("unknown op \"\(opName)\" — known: \(AngelOp.allCases.map(\.rawValue).joined(separator: " "))")
        }
        guard let v = value else { return .invalid("field \"\(fieldName)\" needs \"value\"") }
        switch f.kind {
        case .flag: return compileFlag(f, o, v)
        case .number: return compileNumber(f, o, v)
        case .text: return compileText(f, o, v)
        case .textList: return compileTextList(f, o, v)
        case .choice(let names): return compileChoice(f, o, v, names: names)
        }
    }

    private static func wrongValue(_ f: AngelField, _ o: AngelOp, _ v: AngelValue, _ expected: String) -> Compiled {
        .invalid("\"\(f.rawValue)\" \(o.rawValue) needs \(expected), got \(v.typeName)")
    }

    private static func compileFlag(_ f: AngelField, _ o: AngelOp, _ v: AngelValue) -> Compiled {
        guard o == .eq || o == .ne else { return .invalid("\"\(f.rawValue)\" is true/false: use == or !=") }
        guard case .bool(let b) = v else { return wrongValue(f, o, v, "true or false") }
        return .flag(f, o, b)
    }

    private static func compileNumber(_ f: AngelField, _ o: AngelOp, _ v: AngelValue) -> Compiled {
        guard [.eq, .ne, .lt, .le, .gt, .ge].contains(o) else {
            return .invalid("\"\(f.rawValue)\" is a number: use == != < <= > >=")
        }
        guard case .number(let d) = v, d.isFinite else { return wrongValue(f, o, v, "a finite number") }
        return .number(f, o, d)
    }

    private static func compileList(_ f: AngelField, _ o: AngelOp, _ v: AngelValue) -> Compiled {
        guard case .strings(let l) = v else { return wrongValue(f, o, v, "a list of strings") }
        guard l.count <= maxListLength else { return .invalid("\"\(f.rawValue)\" list is longer than \(maxListLength)") }
        return .textSet(f, o, Set(l.map { $0.lowercased() }))
    }

    private static func compileText(_ f: AngelField, _ o: AngelOp, _ v: AngelValue) -> Compiled {
        switch o {
        case .eq, .ne, .contains, .notContains, .hasPrefix, .hasSuffix:
            guard case .string(let s) = v else { return wrongValue(f, o, v, "a string") }
            guard s.count <= maxTextLength else {
                return .invalid("\"\(f.rawValue)\" value is longer than \(maxTextLength) characters")
            }
            return .text(f, o, s.lowercased())
        case .in, .notIn:
            return compileList(f, o, v)
        default:
            return .invalid("\"\(f.rawValue)\" is text: use == != contains notContains hasPrefix hasSuffix in notIn")
        }
    }

    private static func compileTextList(_ f: AngelField, _ o: AngelOp, _ v: AngelValue) -> Compiled {
        switch o {
        case .contains, .notContains:
            guard case .string(let s) = v else { return wrongValue(f, o, v, "a string") }
            return .text(f, o, s.lowercased())
        case .in, .notIn:
            return compileList(f, o, v)
        default:
            return .invalid("\"\(f.rawValue)\" is a list of names: use contains notContains in notIn")
        }
    }

    private static func compileChoice(_ f: AngelField, _ o: AngelOp, _ v: AngelValue, names: [String]) -> Compiled {
        let written: [String]
        switch (o, v) {
        case (.eq, .string(let s)), (.ne, .string(let s)): written = [s]
        case (.in, .strings(let l)), (.notIn, .strings(let l)): written = l
        case (.eq, _), (.ne, _): return wrongValue(f, o, v, "one of: " + names.joined(separator: ", "))
        case (.in, _), (.notIn, _): return wrongValue(f, o, v, "a list drawn from: " + names.joined(separator: ", "))
        default: return .invalid("\"\(f.rawValue)\" is a choice: use == != in notIn")
        }
        var canonical = Set<String>()
        for w in written {
            guard let c = f.canonicalChoice(w) else {
                return .invalid("\"\(w)\" is not a \(f.rawValue) — one of: \(names.joined(separator: ", "))")
            }
            canonical.insert(c)
        }
        return .choice(f, o, canonical)
    }

    static let maxTextLength = 200
    static let maxListLength = 200
    static let maxDepth = 4

    /// Every problem in this condition and its `any` children.
    func problems(allowClassifierFields: Bool, depth: Int = 0) -> [String] {
        switch compiled {
        case .invalid(let why): return [why]
        case .any(let children):
            guard depth < Self.maxDepth else { return ["\"any\" nested deeper than \(Self.maxDepth)"] }
            return children.flatMap { $0.problems(allowClassifierFields: allowClassifierFields, depth: depth + 1) }
        case .flag(let f, _, _), .number(let f, _, _), .text(let f, _, _), .textSet(let f, _, _), .choice(let f, _, _):
            if f.isClassifierOnly && !allowClassifierFields {
                return ["\"\(f.rawValue)\" is only known to the class rules (recommend.classes)"]
            }
            return []
        }
    }

    /// The field names this condition reads (for "does anything read `dated`?").
    var fieldsRead: Set<AngelField> {
        switch compiled {
        case .invalid: return []
        case .any(let children): return children.reduce(into: Set()) { $0.formUnion($1.fieldsRead) }
        case .flag(let f, _, _), .number(let f, _, _), .text(let f, _, _), .textSet(let f, _, _), .choice(let f, _, _):
            return [f]
        }
    }

    // MARK: Evaluate

    func matches(_ ctx: inout AngelEvalContext) -> Bool {
        switch compiled {
        case .invalid:
            return false
        case .any(let children):
            for child in children where child.matches(&ctx) { return true }
            return false
        case .flag(let f, let o, let want):
            let have = ctx.flag(f)
            return o == .eq ? have == want : have != want
        case .number(let f, let o, let want):
            guard let have = ctx.number(f) else { return false }   // unknown (no year…) never matches
            return Self.compare(have, o, want)
        case .text(let f, let o, let want):
            return Self.matchText(ctx, f, o, want)
        case .textSet(let f, let o, let set):
            let hit: Bool
            if case .textList = f.kind {
                hit = ctx.textList(f).contains { set.contains($0.lowercased()) }
            } else {
                hit = set.contains(ctx.text(f).lowercased())
            }
            return o == .in ? hit : !hit
        case .choice(let f, let o, let set):
            guard let have = ctx.choice(f) else { return false }
            let hit = set.contains(have)
            return (o == .eq || o == .in) ? hit : !hit
        }
    }

    private static func compare(_ have: Double, _ o: AngelOp, _ want: Double) -> Bool {
        switch o {
        case .eq: return have == want
        case .ne: return have != want
        case .lt: return have < want
        case .le: return have <= want
        case .gt: return have > want
        case .ge: return have >= want
        default: return false
        }
    }

    private static func matchText(_ ctx: AngelEvalContext, _ f: AngelField, _ o: AngelOp, _ want: String) -> Bool {
        if case .textList = f.kind {
            let has = ctx.textList(f).contains { $0.lowercased() == want }
            return o == .contains ? has : !has
        }
        let have = ctx.text(f).lowercased()
        switch o {
        case .eq: return have == want
        case .ne: return have != want
        case .contains: return have.contains(want)
        case .notContains: return !have.contains(want)
        case .hasPrefix: return have.hasPrefix(want)
        case .hasSuffix: return have.hasSuffix(want)
        default: return false
        }
    }

    /// AND over a `when` list (an empty list always matches).
    static func all(_ conditions: [AngelCondition], _ ctx: inout AngelEvalContext) -> Bool {
        for c in conditions where !c.matches(&ctx) { return false }
        return true
    }
}

// MARK: - Evaluation context

/// What a condition can read: one candidate, plus — for the class rules —
/// the facts the classifier derives. `dated` is computed on first use
/// (RecordDateResolver is the one costly read).
struct AngelEvalContext {
    let candidate: ArchiveAngelCandidate
    var grade: ArchiveAngelGrade?
    var eligible = true
    var vouched = false
    var vouchPoints = 0
    let dateRule: AngelDateRule
    let now: Date
    private var resolution: RecordDateResolution?
    private var datedCache: Bool?

    init(candidate: ArchiveAngelCandidate, dateRule: AngelDateRule = .init(), now: Date) {
        self.candidate = candidate
        self.dateRule = dateRule
        self.now = now
    }

    /// RecordDateResolver over the candidate's date facts — the SAME call
    /// ArchiveNudge and ArchiveReadiness make.
    mutating func dateResolution() -> RecordDateResolution {
        if let r = resolution { return r }
        let c = candidate
        let r = RecordDateResolver.resolve(
            userDate: c.userDate,
            userDateConfidence: c.userDateConfidence,
            embeddedCreationDate: c.captureDate,
            originMake: c.originMake,
            originModel: c.deviceModel.isEmpty ? nil : c.deviceModel,
            originEncoder: c.originEncoder,
            inferredRecordDate: c.inferredRecordDate,
            inferredDateConfidence: c.inferredDateConfidence,
            filename: c.filename.isEmpty ? nil : c.filename,
            now: now)
        resolution = r
        return r
    }

    mutating func isDated() -> Bool {
        if let d = datedCache { return d }
        let d = dateRule.isDated(dateResolution())
        datedCache = d
        return d
    }

    /// The year the date rule found, when it found one.
    mutating func datedYear() -> Int? { isDated() ? dateResolution().year : nil }

    func text(_ f: AngelField) -> String {
        let c = candidate
        switch f {
        case .filename: return c.filename
        case .path: return c.fullPath
        case .videoCodec: return c.videoCodec
        case .deviceModel: return c.deviceModel
        case .volumeName: return c.volumeName
        default: return ""
        }
    }

    func textList(_ f: AngelField) -> [String] {
        switch f {
        case .people: return candidate.confirmedPeople
        case .machinePeople: return candidate.detectedPeople + candidate.suspectedPeople
        default: return []
        }
    }

    mutating func number(_ f: AngelField) -> Double? {
        let c = candidate
        switch f {
        case .durationSeconds: return c.durationSeconds
        case .durationMinutes: return c.durationSeconds / 60
        case .sizeMB: return Double(c.sizeBytes) / 1_000_000
        case .averageKbps:
            guard c.durationSeconds > 0 else { return nil }
            return Double(c.sizeBytes) * 8 / c.durationSeconds / 1000
        case .starRating: return Double(c.starRating)
        case .junkScore: return Double(c.junkScore)
        case .tagCount: return Double(c.tagCount)
        case .useCount: return Double(c.useCount)
        case .peopleCount: return Double(c.confirmedPeople.count)
        case .year: return c.knownYear.map(Double.init)
        case .captureYear:
            return c.captureDate.map { Double(ArchiveAngelCandidate.utcCalendar.component(.year, from: $0)) }
        case .duplicateGroupCount: return Double(c.duplicateGroupCount)
        case .vouchPoints: return Double(vouchPoints)
        default: return nil
        }
    }

    mutating func flag(_ f: AngelField) -> Bool {
        let c = candidate
        switch f {
        case .isPhoneClip: return c.isPhoneClip
        case .isLivePhotoMotion: return c.isLivePhotoMotion
        case .isHumanMarked: return c.isHumanMarked
        case .hasUserNotes: return c.hasUserNotes
        case .formatAtRisk: return c.formatAtRisk
        case .isOnlyCopy: return c.isOnlyCopy
        case .isPairedHalf: return c.isPairedHalf
        case .volumeOnline: return c.volumeOnline
        case .isOnMasterArchive: return c.isOnMasterArchive
        case .hasArchivedDuplicate: return c.hasArchivedDuplicate
        case .hasDuplicateGroup: return c.duplicateGroupID != nil
        case .hasUserDate: return !(c.userDate ?? "").isEmpty
        case .hasCaptions: return c.hasCaptions
        case .hasOCRText: return c.hasOCRText
        case .eligible: return eligible
        case .vouched: return vouched
        case .dated: return isDated()
        default: return false
        }
    }

    func choice(_ f: AngelField) -> String? {
        let c = candidate
        switch f {
        case .mediaDisposition: return AngelField.name(c.mediaDisposition)
        case .archiveStage: return AngelField.name(c.archiveStage)
        case .duplicateDisposition: return AngelField.name(c.duplicateDisposition)
        case .volumeRole: return AngelField.name(c.volumeRole)
        case .grade: return grade?.rawValue
        default: return nil
        }
    }
}

// MARK: - The one date rule

/// "Dated to at least a year" — a thin wrapper over RecordDateResolver
/// (the one ranking of date signals). `readinessKnown` asks
/// ArchiveReadiness.dateState — Promote's own answer — instead of copying it.
struct AngelDateRule: Codable, Sendable, Equatable {
    /// "day" | "month" | "year" (default) | "decade" | "readinessKnown".
    var minimum: String = "year"

    static let choices = ["day", "month", "year", "decade", "readinessKnown"]

    var problem: String? {
        Self.choices.contains(minimum) ? nil
            : "recommend.date.minimum \"\(minimum)\" — one of: \(Self.choices.joined(separator: ", "))"
    }

    func isDated(_ r: RecordDateResolution) -> Bool {
        switch minimum {
        case "day": return r.precision <= .day
        case "month": return r.precision <= .month
        case "decade": return r.precision <= .decade
        case "readinessKnown": return ArchiveReadiness.dateState(r) == .known
        default: return r.precision <= .year
        }
    }

    init(minimum: String = "year") { self.minimum = minimum }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimum = try c.decodeIfPresent(String.self, forKey: .minimum) ?? "year"
    }
}

// MARK: - Rules

/// Every named behaviour a rule may have. Which kinds a section accepts
/// is `AngelRuleSection.allowedKinds`.
enum AngelRuleKind: String, CaseIterable, Sendable {
    /// A rule whose effect applies when its `when` conditions all hold.
    case match
    /// Vouch: `points` × the star rating, with the stars as the reason.
    /// Signal: the ★ / ★★ / ★★★ weights.
    case stars
    // Floors (built-in exclusions; thresholds come from `weights`).
    case notVideo, onMasterArchive, archivedCopy, notPlayable, pairedHalf, livePhotoMotion, recentPhoneClip
    case appCache, derivativeOfOriginal, tooShort, proxyStream, markedJunk, suspectedJunk, junkScore
    case volumeOffline, resting
    // Signals (built-in evidence lines; points come from `weights`).
    case confirmedPeople, machinePeople, playHistory, richness, date, duration, formatAtRisk, onlyCopy
    case unassignedVolume, audioProblem, downloadCap, fatigue
}

enum AngelRuleSection: String, Sendable {
    case floors, signals, vouch, exclude

    var allowedKinds: Set<AngelRuleKind> {
        switch self {
        case .floors:
            return [.match, .notVideo, .onMasterArchive, .archivedCopy, .notPlayable, .pairedHalf, .livePhotoMotion,
                    .recentPhoneClip, .appCache, .derivativeOfOriginal, .tooShort, .proxyStream, .markedJunk,
                    .suspectedJunk, .junkScore, .volumeOffline, .resting]
        case .signals:
            return [.match, .stars, .confirmedPeople, .machinePeople, .playHistory, .richness, .date, .duration,
                    .formatAtRisk, .onlyCopy, .unassignedVolume, .audioProblem, .downloadCap, .fatigue]
        case .vouch:
            return [.match, .stars]
        case .exclude:
            return [.match]
        }
    }
}

/// One rule. Only `id` and `kind` are required in JSON; everything else
/// has a default, and only non-default fields are written back.
struct AngelRule: Codable, Sendable, Equatable {
    var id: String
    var kind: String
    var enabled: Bool = true
    /// Free text for people — why the rule exists. Shown with an exclusion.
    var note: String = ""
    /// All must hold (empty = always, for the built-in kinds).
    var when: [AngelCondition] = []
    /// `match` signals / vouches: the points. `stars` vouches: per star.
    var points: Int = 0
    /// The printed line (signals, vouches) or reason (exclusions).
    var line: String = ""
    /// Floors: a file with a star passes this floor (machine evidence
    /// yields to a person's rating).
    var starExempt: Bool = false
    /// Floors: also applies to "Prepare with Archive Angel" on a catalog
    /// selection (false = only to the Angel's own proposals).
    var explicitPicks: Bool = true
    /// Vouches: counts as a person vouching (false = a note only, like
    /// "the copy to keep").
    var vouches: Bool = true
    /// `match` floors: the built-in reason to report, by name
    /// ("alreadyArchived", "tooShort"…). nil = "Excluded by a rule in your
    /// recommendation policy" plus this rule's line/note.
    var rejection: String?

    /// Resolved at decode/init. Not encoded.
    private(set) var resolvedKind: AngelRuleKind?

    private enum CodingKeys: String, CodingKey {
        case id, kind, enabled, note, when, points, line, starExempt, explicitPicks, vouches, rejection
    }

    init(id: String, kind: AngelRuleKind, enabled: Bool = true, note: String = "", when: [AngelCondition] = [],
         points: Int = 0, line: String = "", starExempt: Bool = false, explicitPicks: Bool = true,
         vouches: Bool = true, rejection: String? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.enabled = enabled
        self.note = note
        self.when = when
        self.points = points
        self.line = line
        self.starExempt = starExempt
        self.explicitPicks = explicitPicks
        self.vouches = vouches
        self.rejection = rejection
        self.resolvedKind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        when = try c.decodeIfPresent([AngelCondition].self, forKey: .when) ?? []
        points = try c.decodeIfPresent(Int.self, forKey: .points) ?? 0
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        starExempt = try c.decodeIfPresent(Bool.self, forKey: .starExempt) ?? false
        explicitPicks = try c.decodeIfPresent(Bool.self, forKey: .explicitPicks) ?? true
        vouches = try c.decodeIfPresent(Bool.self, forKey: .vouches) ?? true
        rejection = try c.decodeIfPresent(String.self, forKey: .rejection)
        resolvedKind = AngelRuleKind(rawValue: kind)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        if !enabled { try c.encode(enabled, forKey: .enabled) }
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if !when.isEmpty { try c.encode(when, forKey: .when) }
        if points != 0 { try c.encode(points, forKey: .points) }
        if !line.isEmpty { try c.encode(line, forKey: .line) }
        if starExempt { try c.encode(starExempt, forKey: .starExempt) }
        if !explicitPicks { try c.encode(explicitPicks, forKey: .explicitPicks) }
        if !vouches { try c.encode(vouches, forKey: .vouches) }
        try c.encodeIfPresent(rejection, forKey: .rejection)
    }

    /// The text a person reads for this rule.
    var displayLine: String { !line.isEmpty ? line : (!note.isEmpty ? note : id) }

    static let maxRulesPerSection = 100
    static let maxConditionsPerRule = 20
    static let maxLineLength = 300

    /// Every problem with one section's rules (unique ids, known kinds for
    /// the section, sound conditions, bounded points and text).
    static func problems(in rules: [AngelRule], section: AngelRuleSection, where path: String,
                         pointRange: ClosedRange<Int>) -> [String] {
        var out: [String] = []
        if rules.count > maxRulesPerSection { out.append("\(path): more than \(maxRulesPerSection) rules") }
        var ids = Set<String>()
        for (i, r) in rules.enumerated() {
            let here = "\(path)[\(i)] \"\(r.id)\""
            if r.id.trimmingCharacters(in: .whitespaces).isEmpty { out.append("\(path)[\(i)]: empty id") }
            if !ids.insert(r.id).inserted { out.append("\(here): duplicate id") }
            guard let k = r.resolvedKind else {
                out.append("\(here): unknown kind \"\(r.kind)\" — known here: "
                           + section.allowedKinds.map(\.rawValue).sorted().joined(separator: ", "))
                continue
            }
            if !section.allowedKinds.contains(k) {
                out.append("\(here): kind \"\(r.kind)\" does not belong in \(section.rawValue) — known here: "
                           + section.allowedKinds.map(\.rawValue).sorted().joined(separator: ", "))
            }
            if r.when.count > maxConditionsPerRule { out.append("\(here): more than \(maxConditionsPerRule) conditions") }
            for cond in r.when {
                out += cond.problems(allowClassifierFields: false).map { "\(here): \($0)" }
            }
            if k == .match && r.when.isEmpty && section != .signals {
                out.append("\(here): a match rule needs at least one condition in \"when\"")
            }
            if !pointRange.contains(r.points) {
                out.append("\(here): points \(r.points) — must be \(pointRange.lowerBound)…\(pointRange.upperBound)")
            }
            if r.line.count > maxLineLength || r.note.count > maxLineLength {
                out.append("\(here): line/note longer than \(maxLineLength) characters")
            }
            if let name = r.rejection {
                if section != .floors || k != .match {
                    out.append("\(here): \"rejection\" only applies to a match floor")
                } else if ArchiveAngelRejection.named(name) == nil {
                    out.append("\(here): unknown rejection \"\(name)\" — known: "
                               + ArchiveAngelRejection.allCases.map(\.name).joined(separator: ", "))
                }
            }
        }
        return out
    }
}

// MARK: - Rejection names (for `match` floors that report a built-in reason)

extension ArchiveAngelRejection {
    /// The Swift case name — the word a policy file uses.
    var name: String {
        switch self {
        case .notVideo: return "notVideo"
        case .alreadyArchived: return "alreadyArchived"
        case .duplicateArchived: return "duplicateArchived"
        case .volumeOffline: return "volumeOffline"
        case .tooShort: return "tooShort"
        case .livePhotoMotion: return "livePhotoMotion"
        case .recentPhoneClip: return "recentPhoneClip"
        case .junk: return "junk"
        case .suspectedJunk: return "suspectedJunk"
        case .notPlayable: return "notPlayable"
        case .pairedHalf: return "pairedHalf"
        case .inAnotherBatch: return "inAnotherBatch"
        case .duplicateOfPick: return "duplicateOfPick"
        case .derivativeOfOriginal: return "derivativeOfOriginal"
        case .appCache: return "appCache"
        case .proxyStream: return "proxyStream"
        case .resting: return "resting"
        case .sameFamilyAsPick: return "sameFamilyAsPick"
        }
    }

    static func named(_ name: String) -> ArchiveAngelRejection? {
        allCases.first { $0.name == name }
    }
}
