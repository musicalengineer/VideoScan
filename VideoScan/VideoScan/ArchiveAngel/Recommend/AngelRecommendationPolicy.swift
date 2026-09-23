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

import CryptoKit
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
    /// The built-in rules' fingerprint — what an unstamped evidence.json
    /// is assumed to have been scored under.
    static let defaultFingerprint = builtIn.fingerprint

    // MARK: Validation

    /// Every reason this rule set must not be used; empty = usable. EVERY
    /// number has a bounded range (QA 2026-09-22: a "threeStars" near
    /// Int.max passed a ≥ 0 check and would have trapped the scorer's sum
    /// at every launch), and the duration tiers must rise. The ranges are
    /// generous — far beyond any sane rule set — and exist to keep a typo
    /// or a hostile file from reaching the arithmetic.
    func validationProblems() -> [String] {
        var problems: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            problems.append("schemaVersion \(schemaVersion) — this app reads schema \(Self.currentSchemaVersion)")
        }
        let w = weights
        func check(_ name: String, _ v: Int, _ range: ClosedRange<Int>) {
            if !range.contains(v) { problems.append("\(name) = \(v) — must be \(range.lowerBound)…\(range.upperBound)") }
        }
        func check(_ name: String, _ v: Double, _ range: ClosedRange<Double>, excludingLower: Bool = false) {
            if !v.isFinite || !range.contains(v) || (excludingLower && v == range.lowerBound) {
                let lo = excludingLower ? "above \(range.lowerBound)" : "\(range.lowerBound)"
                problems.append("\(name) = \(v) — must be a finite number \(lo)…\(range.upperBound)")
            }
        }
        let points = Self.pointRange
        let pointFields: [(String, Int)] = [
            ("threeStars", w.threeStars), ("twoStars", w.twoStars), ("oneStar", w.oneStar),
            ("confirmedPersonEach", w.confirmedPersonEach), ("confirmedPersonCap", w.confirmedPersonCap),
            ("machinePersonEach", w.machinePersonEach), ("machinePersonCap", w.machinePersonCap),
            ("playHistoryCap", w.playHistoryCap), ("playedRecentlyBonus", w.playedRecentlyBonus),
            ("richnessEach", w.richnessEach), ("richnessCap", w.richnessCap),
            ("dateKnown", w.dateKnown), ("dateLowConfidence", w.dateLowConfidence),
            ("formatAtRisk", w.formatAtRisk), ("onlyCopy", w.onlyCopy), ("riskyVolume", w.riskyVolume),
            ("durationWholeTape", w.durationWholeTape), ("durationHalfTape", w.durationHalfTape),
            ("durationLongScene", w.durationLongScene), ("durationScene", w.durationScene),
            ("downloadCapScore", w.downloadCapScore), ("freshMinimumScore", w.freshMinimumScore),
        ]
        for (name, v) in pointFields { check(name, v, points) }
        check("junkFloor", w.junkFloor, 0...1_000)
        let day = Self.maxSeconds
        check("wholeTapeSeconds", w.wholeTapeSeconds, 0...day)
        check("halfTapeSeconds", w.halfTapeSeconds, 0...day)
        check("longSceneSeconds", w.longSceneSeconds, 0...day)
        check("sceneSeconds", w.sceneSeconds, 0...day)
        if !(w.sceneSeconds <= w.longSceneSeconds && w.longSceneSeconds <= w.halfTapeSeconds
             && w.halfTapeSeconds <= w.wholeTapeSeconds) {
            problems.append("duration tiers must rise: sceneSeconds ≤ longSceneSeconds ≤ halfTapeSeconds ≤ wholeTapeSeconds")
        }
        check("minimumDurationSeconds", w.minimumDurationSeconds, 0...day)
        check("explicitPickMinimumDurationSeconds", w.explicitPickMinimumDurationSeconds, 0...day)
        check("downloadMinimumDurationSeconds", w.downloadMinimumDurationSeconds, 0...day)
        check("recentPhoneClipYears", w.recentPhoneClipYears, 0...100)
        check("dateConfidenceKnown", Double(w.dateConfidenceKnown), 0...1)
        check("minimumAverageKilobitsPerSecond", w.minimumAverageKilobitsPerSecond, 0...Self.maxKilobitsPerSecond)
        check("downloadMaxKilobitsPerSecond", w.downloadMaxKilobitsPerSecond, 0...Self.maxKilobitsPerSecond)
        check("fatigueFactor", w.fatigueFactor, 0...1, excludingLower: true)
        check("restAfterSkips", w.restAfterSkips, 0...1_000, excludingLower: true)
        check("restDays", w.restDays, 0...3_650)
        check("oldSkipAfterDays", w.oldSkipAfterDays, 0...3_650)
        check("oldSkipWeight", w.oldSkipWeight, 0...1)
        check("clearWeight", w.clearWeight, 0...1)
        check("familySkipShare", w.familySkipShare, 0...1)
        check("freshShare", w.freshShare, 0...1)
        return problems
    }

    /// Points any single rule may be worth. Today's largest is 100 (★★★).
    static let pointRange = 0...10_000
    /// Any duration / threshold in seconds: at most a day.
    static let maxSeconds: Double = 86_400
    /// Any bitrate threshold: at most 1 Gbit/s.
    static let maxKilobitsPerSecond: Double = 1_000_000

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
            var unknown: [String] = []
            switch decodeValidated(from: overrideURL, read: read, unknownKeys: { unknown = $0 }) {
            case .success(let p):
                notices.append("Archive Angel: using your recommendation rules “\(p.name)” from \(overrideURL.path)")
                if !unknown.isEmpty {
                    notices.append("Archive Angel: \(overrideURL.lastPathComponent) has key(s) this app does not read — "
                                   + unknown.joined(separator: ", ") + " (ignored; a typo? the default applies for the intended field)")
                }
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
        decodeValidated(from: url, read: read, unknownKeys: { _ in })
    }

    /// Same, reporting keys the file has that this app does not read
    /// ("weights.threeStar" — a typo that would otherwise be silently
    /// ignored while the default applies).
    static func decodeValidated(from url: URL, read: (URL) throws -> Data,
                                unknownKeys: ([String]) -> Void) -> Result<AngelRecommendationPolicy, LoadFailure> {
        let data: Data
        do { data = try read(url) } catch { return .failure(.unreadable(error.localizedDescription)) }
        let policy: AngelRecommendationPolicy
        do { policy = try JSONDecoder().decode(AngelRecommendationPolicy.self, from: data) } catch {
            return .failure(.undecodable(String(describing: error).prefix(300).description))
        }
        let problems = policy.validationProblems()
        guard problems.isEmpty else { return .failure(.invalid(problems)) }
        let unknown = Self.unknownKeys(in: data)
        if !unknown.isEmpty { unknownKeys(unknown) }
        return .success(policy)
    }

    /// Top-level and `weights.` keys in `data` that the built-in policy
    /// does not encode. Sorted. Empty when the JSON can't be read as an object.
    static func unknownKeys(in data: Data) -> [String] {
        guard let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let known = (try? builtIn.encodedJSON()).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        else { return [] }
        var out = given.keys.filter { known[$0] == nil }
        if let gw = given["weights"] as? [String: Any], let kw = known["weights"] as? [String: Any] {
            out += gw.keys.filter { kw[$0] == nil }.map { "weights." + $0 }
        }
        return out.sorted()
    }

    /// A stable fingerprint of the rule set: SHA-256 (first 16 hex digits)
    /// of the canonical encoding (sorted keys, no whitespace). Stamped into
    /// evidence.json so grades computed under other rules are re-scored.
    var fingerprint: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return "unencodable" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The JSON an override starts from (sorted keys, pretty) — what the
    /// bundled default file holds.
    func encodedJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}
