// AngelRecommendationPolicy.swift
// The Archive Angel's recommendation rules as DATA, not code. Rick
// 2026-09-22: "the AA selection criteria should be easily programmable so we
// can add/delete/change the criteria as needed… not hard coded, a user
// should be able to… guide the app on how it recommends. It is a sort of
// recommendation engine… and it should be easy to change."
//
// S2 (this file) is the SEAM: a versioned, Codable, Sendable value, loaded
// from (1) Rick's optional override at
//     ~/Library/Application Support/VideoScan/archive-angel/policy.json
// (never created by the app), else (2) the bundled default
// ArchiveAngelPolicy.default.json, else (3) the compiled-in `builtIn`.
// A file that cannot be read, decoded or validated is REFUSED — with a
// logged reason — and the next source is used; the Angel never runs on a
// half-understood rule set. The loaded policy is injected through the
// façade (AngelEnvironment names the files).
//
// What it holds TODAY is exactly the scorer's weight table
// (ArchiveAngelWeights: floors, vouch signals and their points, attention
// memory, fresh slots), and the default reproduces today's behaviour
// bit-for-bit (AngelRecommendationPolicyTests pins bundled == built-in ==
// ArchiveAngelWeights.standard). S3 adds the class rules (Ready / Needs a
// date / Worth a look), the one date rule and the grade bands, bumping
// `schemaVersion`.
//
// (For Rick: think of this as a config struct read from a JSON file at
// startup, with the compiled-in defaults as the fallback — the policy is
// passed down by value, so a running job never sees it change mid-batch.)

import Foundation

struct AngelRecommendationPolicy: Codable, Sendable, Equatable {

    /// Bump when a field is added, removed or changes meaning. A file from
    /// another schema is refused (a partial understanding of Rick's rules
    /// is worse than the defaults).
    static let currentSchemaVersion = 1
    static let overrideFilename = "policy.json"
    static let bundledResourceName = "ArchiveAngelPolicy.default"

    var schemaVersion: Int = AngelRecommendationPolicy.currentSchemaVersion
    /// Free text: which rule set this is and why ("default", "Rick 2026-10:
    /// tapes first"). Logged when an override is in use.
    var name: String = "default"
    /// Floors (minimum duration, junk, Live Photo / recent phone clips,
    /// bitrate), vouch signals and weights (stars, people, play history,
    /// richness, dates, duration tiers, format risk, only copy), the
    /// download cap, and the attention memory (fatigue, resting, family
    /// share, fresh slots).
    var weights: ArchiveAngelWeights = .standard

    /// The rules compiled into the app — today's behaviour.
    static let builtIn = AngelRecommendationPolicy()

    // MARK: Validation

    /// Every reason this rule set must not be used; empty = usable. Checks
    /// the schema and that each number is finite and in a range the scorer
    /// can work with — a typo in a hand-edited file must not, say, make
    /// every clip "too short" or divide the fatigue by zero.
    func validationProblems() -> [String] {
        var problems: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            problems.append("schemaVersion \(schemaVersion) — this app reads schema \(Self.currentSchemaVersion)")
        }
        let w = weights
        func nonNegative(_ name: String, _ v: Double) {
            if !v.isFinite || v < 0 { problems.append("\(name) = \(v) — must be a finite number ≥ 0") }
        }
        func fraction(_ name: String, _ v: Double, allowZero: Bool = true) {
            if !v.isFinite || v > 1 || v < 0 || (!allowZero && v == 0) {
                problems.append("\(name) = \(v) — must be between \(allowZero ? "0" : "just above 0") and 1")
            }
        }
        let points: [(String, Int)] = [
            ("threeStars", w.threeStars), ("twoStars", w.twoStars), ("oneStar", w.oneStar),
            ("confirmedPersonEach", w.confirmedPersonEach), ("confirmedPersonCap", w.confirmedPersonCap),
            ("machinePersonEach", w.machinePersonEach), ("machinePersonCap", w.machinePersonCap),
            ("playHistoryCap", w.playHistoryCap), ("playedRecentlyBonus", w.playedRecentlyBonus),
            ("richnessEach", w.richnessEach), ("richnessCap", w.richnessCap),
            ("dateKnown", w.dateKnown), ("dateLowConfidence", w.dateLowConfidence),
            ("formatAtRisk", w.formatAtRisk), ("onlyCopy", w.onlyCopy), ("riskyVolume", w.riskyVolume),
            ("durationWholeTape", w.durationWholeTape), ("durationHalfTape", w.durationHalfTape),
            ("durationLongScene", w.durationLongScene), ("durationScene", w.durationScene),
            ("junkFloor", w.junkFloor), ("downloadCapScore", w.downloadCapScore),
            ("freshMinimumScore", w.freshMinimumScore),
        ]
        for (name, v) in points where v < 0 { problems.append("\(name) = \(v) — points must be ≥ 0") }
        nonNegative("wholeTapeSeconds", w.wholeTapeSeconds)
        nonNegative("halfTapeSeconds", w.halfTapeSeconds)
        nonNegative("longSceneSeconds", w.longSceneSeconds)
        nonNegative("sceneSeconds", w.sceneSeconds)
        if !(w.sceneSeconds <= w.longSceneSeconds && w.longSceneSeconds <= w.halfTapeSeconds
             && w.halfTapeSeconds <= w.wholeTapeSeconds) {
            problems.append("duration tiers must rise: sceneSeconds ≤ longSceneSeconds ≤ halfTapeSeconds ≤ wholeTapeSeconds")
        }
        nonNegative("minimumDurationSeconds", w.minimumDurationSeconds)
        nonNegative("explicitPickMinimumDurationSeconds", w.explicitPickMinimumDurationSeconds)
        if w.minimumDurationSeconds > 24 * 3600 { problems.append("minimumDurationSeconds over a day would exclude everything") }
        if w.recentPhoneClipYears < 0 || w.recentPhoneClipYears > 100 {
            problems.append("recentPhoneClipYears = \(w.recentPhoneClipYears) — must be 0…100")
        }
        fraction("dateConfidenceKnown", Double(w.dateConfidenceKnown))
        nonNegative("minimumAverageKilobitsPerSecond", w.minimumAverageKilobitsPerSecond)
        nonNegative("downloadMaxKilobitsPerSecond", w.downloadMaxKilobitsPerSecond)
        nonNegative("downloadMinimumDurationSeconds", w.downloadMinimumDurationSeconds)
        fraction("fatigueFactor", w.fatigueFactor, allowZero: false)
        if !w.restAfterSkips.isFinite || w.restAfterSkips <= 0 {
            problems.append("restAfterSkips = \(w.restAfterSkips) — must be a finite number > 0")
        }
        nonNegative("restDays", w.restDays)
        nonNegative("oldSkipAfterDays", w.oldSkipAfterDays)
        fraction("oldSkipWeight", w.oldSkipWeight)
        fraction("clearWeight", w.clearWeight)
        fraction("familySkipShare", w.familySkipShare)
        fraction("freshShare", w.freshShare)
        return problems
    }

    // MARK: Loading

    enum Source: String, Sendable, Equatable {
        case userOverride = "your policy.json"
        case bundled = "the bundled default"
        case builtIn = "the built-in rules"
    }

    struct Loaded: Sendable, Equatable {
        var policy: AngelRecommendationPolicy
        var source: Source
        /// User-visible lines: every refusal with its reason, and the
        /// override in use. Empty on the ordinary path (no override).
        var notices: [String]
    }

    /// Pure over the two URLs (tests pass temp files). Never creates a file.
    static func load(overrideURL: URL, bundledURL: URL?,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                     read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> Loaded {
        var notices: [String] = []
        if fileExists(overrideURL.path) {
            switch decodeValidated(from: overrideURL, read: read) {
            case .success(let p):
                notices.append("Archive Angel: using your recommendation rules “\(p.name)” from \(overrideURL.path)")
                return Loaded(policy: p, source: .userOverride, notices: notices)
            case .failure(let why):
                notices.append("Archive Angel: refused \(overrideURL.path) — \(why); using "
                               + (bundledURL == nil ? Source.builtIn.rawValue : Source.bundled.rawValue) + " instead")
            }
        }
        if let bundledURL {
            switch decodeValidated(from: bundledURL, read: read) {
            case .success(let p):
                return Loaded(policy: p, source: .bundled, notices: notices)
            case .failure(let why):
                notices.append("Archive Angel: the bundled default rules are unusable — \(why); using the built-in rules")
            }
        }
        return Loaded(policy: .builtIn, source: .builtIn, notices: notices)
    }

    enum LoadFailure: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case undecodable(String)
        case invalid([String])
        var description: String {
            switch self {
            case .unreadable(let m): return "can't be read (\(m))"
            case .undecodable(let m): return "isn't a rule set this app understands (\(m))"
            case .invalid(let p): return "fails validation: " + p.joined(separator: "; ")
            }
        }
    }

    static func decodeValidated(from url: URL, read: (URL) throws -> Data) -> Result<AngelRecommendationPolicy, LoadFailure> {
        let data: Data
        do { data = try read(url) } catch { return .failure(.unreadable(error.localizedDescription)) }
        let policy: AngelRecommendationPolicy
        do { policy = try JSONDecoder().decode(AngelRecommendationPolicy.self, from: data) } catch {
            return .failure(.undecodable(String(describing: error).prefix(300).description))
        }
        let problems = policy.validationProblems()
        return problems.isEmpty ? .success(policy) : .failure(.invalid(problems))
    }

    /// The JSON an override starts from (sorted keys, pretty) — what the
    /// bundled default file holds.
    func encodedJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}
