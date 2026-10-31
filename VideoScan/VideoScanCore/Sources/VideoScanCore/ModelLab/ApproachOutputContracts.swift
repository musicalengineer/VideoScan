// ApproachOutputContracts.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: one strict `Decodable` per field family — the fixed JSON
// schema a model is told, decoded fail-closed: a response that does not
// decode is `.schemaInvalid(reason)`, never repaired, never coerced, never
// a partial value (docs/design/video_llm_lab_2026_10_30.md §3.3; the Hallie
// translator's fail-closed rule).
//
// For Rick (C++): each contract is a strict parser that THROWS rather than
// coerces — think a `from_json` that rejects unknown members, wrong types,
// and out-of-range values instead of defaulting them. `ContractDecoder`
// is the one entry point; it returns a tagged union (`ContractDecodeResult`)
// so a caller cannot forget the failure arm.
//
// What "strict" means here, for every family:
//   • unknown keys rejected (a model's extra `confidence_score` is a
//     schema violation, not a bonus);
//   • wrong JSON types rejected (a string year, a fractional year);
//   • `family` must equal the family asked for;
//   • `window` is exactly two finite numbers, 0 ≤ start ≤ end;
//   • `selfConfidence` is 0…1 and is stored for the Judge only — it is
//     never the confidence the UI shows (events_design rule 9);
//   • years are 1900…2100 and ranges are not reversed;
//   • list lengths and the whole response are bounded (`maxListItems`,
//     `maxJSONBytes`), so a runaway model cannot grow memory.
//
// Minimal honest shapes for the four families §3.3 did not spell out:
//   ocrDate      — the literal `text` read, `atS` (the frame time), and
//                  OPTIONAL parsed `year`/`month`/`day` (day needs month,
//                  month needs year). Unparsed is honest, not invented.
//   ocrText      — `lines: [{text, atS}]`; an empty list means "nothing
//                  legible", which is a valid answer.
//   scene        — `description`: free text, reported only (§4: search
//                  fodder, never a fact).
//   occasionKind — `kind`: one of the nine EventCategoryRules categories,
//                  or `mixed` / `unknown` (events_design rule 2), with
//                  `rationale` and `cues` like era.
// carrierClues and spokenNamePresence have no contract in this build
// (Phases 1–2); asking for one is `.schemaInvalid` in words.
//
// MEMORY: one response ≤ 64 KB decoded into a few strings; lists ≤ 64
// items. Nothing is retained between calls.

import Foundation

// MARK: - Shared pieces

/// The window the model says it looked at, as declared in the response.
public struct ContractWindow: Sendable, Hashable {
    public let startS: Double
    public let endS: Double
    public init(startS: Double, endS: Double) { self.startS = startS; self.endS = endS }
}

public enum CueKind: String, Sendable, Codable, CaseIterable {
    case technical, cultural, environmental, onScreenText, spoken
}

/// One thing the model points at, with the frame time it saw it.
public struct ContractCue: Sendable, Hashable {
    public let kind: CueKind
    public let text: String
    public let atS: Double
}

public enum RoomSetting: String, Sendable, Codable, CaseIterable {
    case indoor, outdoor, mixed, unknown
}

/// The nine EventCategoryRules categories plus the two honest non-answers.
public enum OccasionKind: String, Sendable, Codable, CaseIterable {
    case birthday, christmas, thanksgiving, easter, halloween, wedding, beachVacation, musicPerformance, graduation
    case mixed, unknown
}

// MARK: - Contracts

public struct EraContract: Sendable, Hashable {
    public let window: ContractWindow
    public let yearRange: ClosedRange<Int>
    public let rationale: String
    public let cues: [ContractCue]
    public let selfConfidence: Double
}

public struct RoomFeaturesContract: Sendable, Hashable {
    public let window: ContractWindow
    public let setting: RoomSetting
    public let locationType: String
    public let features: [String]
    public let selfConfidence: Double
}

public struct OCRDateContract: Sendable, Hashable {
    public let window: ContractWindow
    /// The characters read, verbatim ("JUN 21 1991").
    public let text: String
    /// The frame time it was read at.
    public let atS: Double
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let selfConfidence: Double
}

public struct OCRTextContract: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public let text: String
        public let atS: Double
    }
    public let window: ContractWindow
    public let lines: [Line]
    public let selfConfidence: Double
}

public struct SceneContract: Sendable, Hashable {
    public let window: ContractWindow
    public let description: String
    public let selfConfidence: Double
}

public struct OccasionKindContract: Sendable, Hashable {
    public let window: ContractWindow
    public let kind: OccasionKind
    public let rationale: String
    public let cues: [ContractCue]
    public let selfConfidence: Double
}

/// The decoded value, tagged by family.
public enum ContractValue: Sendable, Hashable {
    case era(EraContract)
    case roomFeatures(RoomFeaturesContract)
    case ocrDate(OCRDateContract)
    case ocrText(OCRTextContract)
    case scene(SceneContract)
    case occasionKind(OccasionKindContract)

    public var family: FieldFamily {
        switch self {
        case .era: return .era
        case .roomFeatures: return .roomFeatures
        case .ocrDate: return .ocrDate
        case .ocrText: return .ocrText
        case .scene: return .scene
        case .occasionKind: return .occasionKind
        }
    }

    public var declaredWindow: ContractWindow {
        switch self {
        case .era(let v): return v.window
        case .roomFeatures(let v): return v.window
        case .ocrDate(let v): return v.window
        case .ocrText(let v): return v.window
        case .scene(let v): return v.window
        case .occasionKind(let v): return v.window
        }
    }

    public var selfConfidence: Double {
        switch self {
        case .era(let v): return v.selfConfidence
        case .roomFeatures(let v): return v.selfConfidence
        case .ocrDate(let v): return v.selfConfidence
        case .ocrText(let v): return v.selfConfidence
        case .scene(let v): return v.selfConfidence
        case .occasionKind(let v): return v.selfConfidence
        }
    }
}

/// One model answer for one window: family + the window the job sent +
/// the decoded value + the raw bytes (the notebook keeps them verbatim).
public struct ApproachOutput: Sendable, Hashable {
    public let family: FieldFamily
    public let window: SampleWindow
    public let value: ContractValue
    public let rawJSON: Data

    public init(family: FieldFamily, window: SampleWindow, value: ContractValue, rawJSON: Data) {
        self.family = family
        self.window = window
        self.value = value
        self.rawJSON = rawJSON
    }
}

public enum ContractDecodeResult: Sendable, Hashable {
    case output(ApproachOutput)
    /// Dropped and logged; never repaired. The reason is for the log line.
    case schemaInvalid(reason: String)
}

// MARK: - Decoder

public enum ContractDecoder {
    /// A response larger than this is refused unread.
    public static let maxJSONBytes = 64 * 1024
    /// Features, cues, lines: more than this is a runaway, not an answer.
    public static let maxListItems = 64
    public static let yearRange = 1900...2100

    public static func decode(family: FieldFamily, json: Data, window: SampleWindow) -> ContractDecodeResult {
        guard json.count <= maxJSONBytes else {
            return .schemaInvalid(reason: "response is \(json.count) bytes, larger than the \(maxJSONBytes)-byte cap")
        }
        guard !json.isEmpty else { return .schemaInvalid(reason: "empty response") }
        let decoder = JSONDecoder()
        decoder.userInfo[.expectedFamily] = family
        do {
            let value: ContractValue
            switch family {
            case .era: value = .era(try decoder.decode(EraContract.self, from: json))
            case .roomFeatures: value = .roomFeatures(try decoder.decode(RoomFeaturesContract.self, from: json))
            case .ocrDate: value = .ocrDate(try decoder.decode(OCRDateContract.self, from: json))
            case .ocrText: value = .ocrText(try decoder.decode(OCRTextContract.self, from: json))
            case .scene: value = .scene(try decoder.decode(SceneContract.self, from: json))
            case .occasionKind: value = .occasionKind(try decoder.decode(OccasionKindContract.self, from: json))
            case .carrierClues, .spokenNamePresence:
                return .schemaInvalid(reason: "no output contract for family '\(family.rawValue)' in this build")
            }
            return .output(ApproachOutput(family: family, window: window, value: value, rawJSON: json))
        } catch let violation as ContractViolation {
            return .schemaInvalid(reason: violation.reason)
        } catch let error as DecodingError {
            return .schemaInvalid(reason: Self.words(for: error))
        } catch {
            return .schemaInvalid(reason: "\(error)")
        }
    }

    /// One line a human can act on, naming the key where possible.
    static func words(for error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "top level" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "missing key '\(parent.isEmpty ? key.stringValue : parent + "." + key.stringValue)'"
        case .typeMismatch(let type, let context):
            return "wrong type at '\(path(context))' (expected \(type)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "null at '\(path(context))' where \(type) was expected"
        case .dataCorrupted(let context):
            // Foundation puts the useful sentence ("Number 1991.5 is not
            // representable in Swift.") in the underlying error's debug
            // description; its localizedDescription is the generic Cocoa one.
            if let underlying = context.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String, !detail.isEmpty {
                return "not valid JSON at '\(path(context))': \(detail)"
            }
            return "not valid at '\(path(context))': \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}

/// A rule of the contract broken by a value that did parse as JSON.
struct ContractViolation: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

extension CodingUserInfoKey {
    // The failable init never fails for a non-empty literal; swiftlint cannot see that.
    // swiftlint:disable:next force_unwrapping
    static let expectedFamily = CodingUserInfoKey(rawValue: "VideoScanCore.ModelLab.expectedFamily")!
}

// MARK: - Strict decoding helpers

/// Any key, for reading the container's full key set.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}

private enum Strict {
    /// Rejects any key the contract did not declare.
    static func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw ContractViolation("unknown key(s) \(unknown.map { "'\($0)'" }.joined(separator: ", ")) — the contract names every field")
        }
    }

    static func family<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K, decoder: Decoder) throws {
        let word = try c.decode(String.self, forKey: key)
        // A bare JSONDecoder is not a door around the contract: without the
        // family the caller asked for, nothing decodes (reviewer R6).
        guard let expected = decoder.userInfo[.expectedFamily] as? FieldFamily else {
            throw ContractViolation("contract decoded outside ContractDecoder (no expected family); use ContractDecoder.decode")
        }
        guard let found = FieldFamily(rawValue: word) else {
            throw ContractViolation("unknown family '\(word)'")
        }
        guard found == expected else {
            throw ContractViolation("family '\(found.rawValue)' where '\(expected.rawValue)' was asked for")
        }
    }

    static func window<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> ContractWindow {
        let pair = try c.decode([Double].self, forKey: key)
        guard pair.count == 2 else { throw ContractViolation("window must be two numbers [start, end], got \(pair.count)") }
        guard pair[0].isFinite, pair[1].isFinite, pair[0] >= 0 else {
            throw ContractViolation("window must be finite and start at or after 0: \(pair)")
        }
        guard pair[1] >= pair[0] else { throw ContractViolation("window end \(pair[1]) is before its start \(pair[0])") }
        return ContractWindow(startS: pair[0], endS: pair[1])
    }

    static func yearRange<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> ClosedRange<Int> {
        let pair = try c.decode([Int].self, forKey: key)
        guard pair.count == 2 else { throw ContractViolation("yearRange must be two years [from, to], got \(pair.count)") }
        for y in pair where !ContractDecoder.yearRange.contains(y) {
            throw ContractViolation("year \(y) is outside \(ContractDecoder.yearRange.lowerBound)…\(ContractDecoder.yearRange.upperBound)")
        }
        guard pair[0] <= pair[1] else { throw ContractViolation("yearRange \(pair) is reversed") }
        return pair[0]...pair[1]
    }

    static func selfConfidence<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> Double {
        let v = try c.decode(Double.self, forKey: key)
        guard v.isFinite, (0...1).contains(v) else { throw ContractViolation("selfConfidence \(v) is outside 0…1") }
        return v
    }

    static func nonEmptyText<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> String {
        let s = try c.decode(String.self, forKey: key)
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContractViolation("'\(key.stringValue)' is empty")
        }
        return s
    }

    static func frameTime<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> Double {
        let t = try c.decode(Double.self, forKey: key)
        guard t.isFinite, t >= 0 else { throw ContractViolation("'\(key.stringValue)' \(t) is not a frame time at or after 0") }
        return t
    }

    static func bounded<T>(_ items: [T], name: String) throws -> [T] {
        guard items.count <= ContractDecoder.maxListItems else {
            throw ContractViolation("'\(name)' has \(items.count) items, more than the \(ContractDecoder.maxListItems) cap")
        }
        return items
    }

    static func word<E: RawRepresentable & CaseIterable, K: CodingKey>(_ type: E.Type, _ c: KeyedDecodingContainer<K>, key: K) throws -> E
    where E.RawValue == String {
        let raw = try c.decode(String.self, forKey: key)
        guard let value = E(rawValue: raw) else {
            throw ContractViolation("'\(key.stringValue)' word '\(raw)' is not one of \(E.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }
}

extension ContractCue: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case kind, text, atS }
    public init(from decoder: Decoder) throws {
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try Strict.word(CueKind.self, c, key: .kind)
        text = try Strict.nonEmptyText(c, key: .text)
        atS = try Strict.frameTime(c, key: .atS)
    }
}

extension EraContract: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case family, window, yearRange, rationale, cues, selfConfidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try Strict.family(c, key: .family, decoder: decoder)
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        window = try Strict.window(c, key: .window)
        yearRange = try Strict.yearRange(c, key: .yearRange)
        rationale = try Strict.nonEmptyText(c, key: .rationale)
        cues = try Strict.bounded(try c.decode([ContractCue].self, forKey: .cues), name: "cues")
        selfConfidence = try Strict.selfConfidence(c, key: .selfConfidence)
    }
}

extension RoomFeaturesContract: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case family, window, setting, locationType, features, selfConfidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try Strict.family(c, key: .family, decoder: decoder)
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        window = try Strict.window(c, key: .window)
        setting = try Strict.word(RoomSetting.self, c, key: .setting)
        locationType = try Strict.nonEmptyText(c, key: .locationType)
        let list = try Strict.bounded(try c.decode([String].self, forKey: .features), name: "features")
        if list.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ContractViolation("'features' holds an empty item")
        }
        features = list
        selfConfidence = try Strict.selfConfidence(c, key: .selfConfidence)
    }
}

extension OCRDateContract: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case family, window, text, atS, year, month, day, selfConfidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try Strict.family(c, key: .family, decoder: decoder)
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        window = try Strict.window(c, key: .window)
        text = try Strict.nonEmptyText(c, key: .text)
        atS = try Strict.frameTime(c, key: .atS)
        let y = try c.decodeIfPresent(Int.self, forKey: .year)
        let m = try c.decodeIfPresent(Int.self, forKey: .month)
        let d = try c.decodeIfPresent(Int.self, forKey: .day)
        if let y, !ContractDecoder.yearRange.contains(y) {
            throw ContractViolation("year \(y) is outside \(ContractDecoder.yearRange.lowerBound)…\(ContractDecoder.yearRange.upperBound)")
        }
        if let m {
            guard y != nil else { throw ContractViolation("'month' without a 'year' is not a date part") }
            guard (1...12).contains(m) else { throw ContractViolation("month \(m) is outside 1…12") }
        }
        if let d {
            guard m != nil else { throw ContractViolation("'day' without a 'month' is not a date part") }
            guard (1...31).contains(d) else { throw ContractViolation("day \(d) is outside 1…31") }
        }
        year = y; month = m; day = d
        selfConfidence = try Strict.selfConfidence(c, key: .selfConfidence)
    }
}

extension OCRTextContract.Line: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case text, atS }
    public init(from decoder: Decoder) throws {
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: Keys.self)
        text = try Strict.nonEmptyText(c, key: .text)
        atS = try Strict.frameTime(c, key: .atS)
    }
}

extension OCRTextContract: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case family, window, lines, selfConfidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try Strict.family(c, key: .family, decoder: decoder)
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        window = try Strict.window(c, key: .window)
        lines = try Strict.bounded(try c.decode([Line].self, forKey: .lines), name: "lines")
        selfConfidence = try Strict.selfConfidence(c, key: .selfConfidence)
    }
}

extension SceneContract: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case family, window, description, selfConfidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try Strict.family(c, key: .family, decoder: decoder)
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        window = try Strict.window(c, key: .window)
        description = try Strict.nonEmptyText(c, key: .description)
        selfConfidence = try Strict.selfConfidence(c, key: .selfConfidence)
    }
}

extension OccasionKindContract: Decodable {
    private enum Keys: String, CodingKey, CaseIterable { case family, window, kind, rationale, cues, selfConfidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try Strict.family(c, key: .family, decoder: decoder)
        try Strict.rejectUnknownKeys(decoder, allowed: Set(Keys.allCases.map(\.rawValue)))
        window = try Strict.window(c, key: .window)
        kind = try Strict.word(OccasionKind.self, c, key: .kind)
        rationale = try Strict.nonEmptyText(c, key: .rationale)
        cues = try Strict.bounded(try c.decode([ContractCue].self, forKey: .cues), name: "cues")
        selfConfidence = try Strict.selfConfidence(c, key: .selfConfidence)
    }
}
