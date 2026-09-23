// AngelRecommendationPolicy.swift
// The Archive Angel's recommendation rules as DATA, not code. Rick
// 2026-09-22: "the AA selection criteria should be easily programmable so we
// can add/delete/change the criteria as needed… not hard coded, a user
// should be able to… guide the app on how it recommends. It is a sort of
// recommendation engine… and it should be easy to change."
//
// A versioned, Codable, Sendable value, loaded from (1) Rick's optional
// override at
//     ~/Library/Application Support/VideoScan/archive-angel/policy.json
// (never created by the app), else (2) the bundled default
// ArchiveAngelPolicy.default.json, else (3) the compiled-in `builtIn`.
// A file that cannot be read, decoded or validated is REFUSED — with a
// logged reason naming every problem — and the next source is used; the
// Angel never runs on a half-understood rule set. The loaded policy is
// injected through the façade (AngelEnvironment names the files).
//
// Schema 2 (Consolidation S3b, 2026-09-22) — every recommendation criterion:
//   weights    the numbers the built-in rules use (schema 1's whole content)
//   floors     ordered exclusion rules          ┐ arrays of named rule
//   signals    the evidence lines → the score   │ objects in the closed rule
//   recommend  classes, vouches, date, copies   ┘ language (AngelRuleLanguage)
//   grades     the A/B/C/D bands
//   tables     originality, delivery codecs, app-cache names, family folders
// See docs/archive_angel_policy.md for the reference and worked examples.
//
// An override is MERGED over the built-in rules, so a file may hold only
// what it changes — `{"schemaVersion": 2, "weights": {"minimumDurationSeconds":
// 300}}` is a complete policy. Objects merge key by key; the rule lists
// (floors, signals, recommend.exclude, recommend.vouch) merge BY ID: an
// entry whose id is a built-in rule's edits that rule in place (`"enabled":
// false` removes it), a new id adds a rule (a new signal goes just before
// the download cap / fatigue adjusters, anything else at the end). Other
// arrays and values replace. A schema-1 file (weights only) is still read:
// its weights, today's rules for everything else, and a notice saying so.
//
// (For Rick: think of this as a config struct read from a JSON file at
// startup, with the compiled-in defaults as the fallback — the policy is
// passed down by value, so a running job never sees it change mid-batch.)

import CryptoKit
import Foundation

struct AngelRecommendationPolicy: Codable, Sendable, Equatable {

    /// Bump when a field is added, removed or changes meaning. 1 = weights
    /// only (S2); 2 = floors, signals, recommend, grades, tables (S3b).
    static let currentSchemaVersion = 2
    /// Schemas this app reads (1 is migrated on load).
    static let readableSchemaVersions: ClosedRange<Int> = 1...2
    static let overrideFilename = "policy.json"
    static let bundledResourceName = "ArchiveAngelPolicy.default"

    var schemaVersion: Int = AngelRecommendationPolicy.currentSchemaVersion
    /// Free text: which rule set this is and why ("default", "Rick 2026-10:
    /// tapes first"). Logged when an override is in use.
    var name: String = "default"
    /// The numbers the built-in floors and signals read (minimum duration,
    /// junk floor, ★ points, people, play history, richness, dates,
    /// duration tiers, the download cap, the attention memory).
    var weights: ArchiveAngelWeights = .standard
    /// Hard floors, first hit excludes.
    var floors: [AngelRule] = AngelPolicyDefaults.floors
    /// Evidence lines; the score is their sum.
    var signals: [AngelRule] = AngelPolicyDefaults.signals
    var grades: AngelGradeBands = .standard
    var tables: AngelPolicyTables = .standard
    /// Ready / Needs a date / Worth a look.
    var recommend: AngelRecommendRules = .standard

    /// The rules compiled into the app — today's behaviour.
    static let builtIn = AngelRecommendationPolicy()
    /// The built-in rules' fingerprint — what an unstamped evidence.json
    /// is assumed to have been scored under.
    static let defaultFingerprint = builtIn.fingerprint

    /// The same rules with other weights (the scorer's `weights:` overloads).
    func with(weights w: ArchiveAngelWeights) -> AngelRecommendationPolicy {
        var p = self
        p.weights = w
        return p
    }

    /// The rules for "Prepare with Archive Angel" on a catalog selection:
    /// the explicit-pick minimum duration, and every floor marked
    /// `explicitPicks: false` (Live Photo motion, recent phone clips) off —
    /// the person chose these rows (Rick 2026-09-21).
    func forExplicitPicks() -> AngelRecommendationPolicy {
        var p = self
        p.weights.minimumDurationSeconds = p.weights.explicitPickMinimumDurationSeconds
        for i in p.floors.indices where !p.floors[i].explicitPicks { p.floors[i].enabled = false }
        return p
    }

    // MARK: Validation

    /// Every reason this rule set must not be used; empty = usable. EVERY
    /// number has a bounded range (QA 2026-09-22: a "threeStars" near
    /// Int.max passed a ≥ 0 check and would have trapped the scorer's sum
    /// at every launch), every rule's kind, field, operator and value is
    /// known, and the duration tiers and grade bands must rise. The ranges
    /// are generous — far beyond any sane rule set — and exist to keep a
    /// typo or a hostile file from reaching the arithmetic.
    func validationProblems() -> [String] {
        var problems: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            problems.append("schemaVersion \(schemaVersion) — this app reads schema \(Self.currentSchemaVersion)"
                            + " (and migrates 1)")
        }
        problems += weightProblems()
        problems += AngelRule.problems(in: floors, section: .floors, where: "floors", pointRange: 0...0)
        problems += AngelRule.problems(in: signals, section: .signals, where: "signals",
                                       pointRange: -Self.pointRange.upperBound...Self.pointRange.upperBound)
        problems += grades.problems
        problems += tables.problems
        problems += recommend.problems
        return problems
    }

    private func weightProblems() -> [String] {
        var problems: [String] = []
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
        check("playHistoryPerDoubling", w.playHistoryPerDoubling, 0...1_000)
        check("playedRecentlyDays", w.playedRecentlyDays, 0...36_500)
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
    /// A policy file larger than this is refused unread (a runaway file
    /// must not be parsed into memory).
    static let maxFileBytes = 1_000_000

    // MARK: Loading

    enum Source: String, Sendable, Equatable {
        case userOverride = "your policy.json"
        case bundled = "the bundled default"
        case builtIn = "the built-in rules"
    }

    struct Loaded: Sendable, Equatable {
        var policy: AngelRecommendationPolicy
        var source: Source
        /// User-visible lines: every refusal with its reason, the override
        /// in use, a schema-1 migration, unread keys. Empty on the ordinary
        /// path (no override).
        var notices: [String]
    }

    /// Pure over the two URLs (tests pass temp files). Never creates a file.
    static func load(overrideURL: URL, bundledURL: URL?,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                     read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> Loaded {
        var notices: [String] = []
        if fileExists(overrideURL.path) {
            var extra: [String] = []
            switch decodeValidated(from: overrideURL, read: read, notes: { extra = $0 }) {
            case .success(let p):
                notices.append("Archive Angel: using your recommendation rules “\(p.name)” from \(overrideURL.path)")
                notices += extra.map { "Archive Angel: \(overrideURL.lastPathComponent) — \($0)" }
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
        decodeValidated(from: url, read: read, notes: { _ in })
    }

    /// Read, merge over the built-in rules, decode, migrate schema 1,
    /// validate. `notes` receives what a person should know about a file
    /// that IS used: a schema-1 migration, keys this app does not read
    /// ("weights.threeStar" — a typo that would otherwise pass silently).
    static func decodeValidated(from url: URL, read: (URL) throws -> Data,
                                notes: ([String]) -> Void) -> Result<AngelRecommendationPolicy, LoadFailure> {
        let data: Data
        do { data = try read(url) } catch { return .failure(.unreadable(error.localizedDescription)) }
        guard data.count <= maxFileBytes else {
            return .failure(.unreadable("\(data.count) bytes — larger than \(maxFileBytes)"))
        }
        let given: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.undecodable("the top level must be a JSON object"))
            }
            given = obj
        } catch {
            return .failure(.undecodable(String(describing: error).prefix(300).description))
        }
        guard let version = given["schemaVersion"] as? Int else {
            return .failure(.undecodable("no \"schemaVersion\" (this app reads \(readableSchemaVersions.lowerBound)…\(readableSchemaVersions.upperBound))"))
        }
        guard readableSchemaVersions.contains(version) else {
            return .failure(.invalid(["schemaVersion \(version) — this app reads schema \(currentSchemaVersion) (and migrates 1)"]))
        }
        var policy: AngelRecommendationPolicy
        do {
            policy = try decodeMerged(given)
        } catch {
            return .failure(.undecodable(String(describing: error).prefix(300).description))
        }
        var fileNotes: [String] = []
        if version == 1 {
            policy.schemaVersion = currentSchemaVersion
            fileNotes.append("schema 1 (weights only) read: your weights, the current default floors, signals and classes for everything else")
        }
        let problems = policy.validationProblems()
        guard problems.isEmpty else { return .failure(.invalid(problems)) }
        let unknown = unknownKeys(in: data)
        if !unknown.isEmpty {
            fileNotes.append("has key(s) this app does not read — " + unknown.joined(separator: ", ")
                             + " (ignored; a typo? the default applies for the intended field)")
        }
        if !fileNotes.isEmpty { notes(fileNotes) }
        return .success(policy)
    }

    /// `given` merged over the built-in rules' JSON (objects merge key by
    /// key; arrays and values replace), then decoded.
    static func decodeMerged(_ given: [String: Any]) throws -> AngelRecommendationPolicy {
        let baseData = try builtIn.encodedJSON()
        guard let base = try JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            throw LoadFailure.undecodable("the built-in rules did not encode as an object")
        }
        let merged = mergeJSON(given, over: base)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(AngelRecommendationPolicy.self, from: mergedData)
    }

    /// Objects merge recursively; the rule lists merge by id
    /// (`mergeRules`); anything else in `top` replaces `base`.
    /// `tables.originality` is a data map (codec → rank): replaced whole,
    /// so a policy can REMOVE a codec from the table.
    static func mergeJSON(_ top: [String: Any], over base: [String: Any], path: String = "") -> [String: Any] {
        var out = base
        for (k, v) in top {
            let here = path.isEmpty ? k : path + "." + k
            if ruleListPaths.contains(here), let tv = v as? [[String: Any]], let bv = base[k] as? [[String: Any]] {
                out[k] = mergeRules(tv, over: bv, insertBeforeKinds: here == "signals" ? ["downloadCap", "fatigue"] : [])
            } else if here != "tables.originality", let tv = v as? [String: Any], let bv = base[k] as? [String: Any] {
                out[k] = mergeJSON(tv, over: bv, path: here)
            } else {
                out[k] = v
            }
        }
        return out
    }

    static let ruleListPaths: Set<String> = ["floors", "signals", "recommend.exclude", "recommend.vouch"]

    /// Rule lists merge by `id`: a matching entry's keys replace the
    /// built-in rule's (in place — order kept); a new id is inserted before
    /// the first rule of `insertBeforeKinds`, else appended. An entry with
    /// no string id is appended as written (validation names it).
    static func mergeRules(_ top: [[String: Any]], over base: [[String: Any]],
                           insertBeforeKinds: Set<String>) -> [[String: Any]] {
        var out = base
        for rule in top {
            if let id = rule["id"] as? String, let i = out.firstIndex(where: { ($0["id"] as? String) == id }) {
                out[i].merge(rule) { _, new in new }
            } else if let at = out.firstIndex(where: { insertBeforeKinds.contains(($0["kind"] as? String) ?? "") }) {
                out.insert(rule, at: at)
            } else {
                out.append(rule)
            }
        }
        return out
    }

    /// Keys in `data` this app does not read: top level, every section's
    /// own keys, and inside every rule / condition / class rule object.
    /// Sorted. Empty when the JSON can't be read as an object.
    static func unknownKeys(in data: Data) -> [String] {
        guard let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let known = (try? builtIn.encodedJSON()).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        else { return [] }
        var out = given.keys.filter { known[$0] == nil }
        func objectKeys(_ section: String, in object: [String: Any]?, against reference: [String: Any]?) {
            guard let object, let reference else { return }
            out += object.keys.filter { reference[$0] == nil }.map { section + "." + $0 }
        }
        for section in ["weights", "grades", "tables"] {
            objectKeys(section, in: given[section] as? [String: Any], against: known[section] as? [String: Any])
        }
        let recommend = given["recommend"] as? [String: Any]
        let knownRecommend = known["recommend"] as? [String: Any]
        objectKeys("recommend", in: recommend, against: knownRecommend)
        for sub in ["date", "copies"] {
            objectKeys("recommend." + sub, in: recommend?[sub] as? [String: Any],
                       against: knownRecommend?[sub] as? [String: Any])
        }
        func conditionKeys(_ list: Any?, at path: String) {
            for (i, c) in ((list as? [[String: Any]]) ?? []).enumerated() {
                out += c.keys.filter { !conditionKeySet.contains($0) }.map { "\(path)[\(i)].\($0)" }
                conditionKeys(c["any"], at: "\(path)[\(i)].any")
            }
        }
        func ruleKeys(_ list: Any?, at path: String, allowed: Set<String>) {
            for (i, r) in ((list as? [[String: Any]]) ?? []).enumerated() {
                out += r.keys.filter { !allowed.contains($0) }.map { "\(path)[\(i)].\($0)" }
                conditionKeys(r["when"], at: "\(path)[\(i)].when")
            }
        }
        ruleKeys(given["floors"], at: "floors", allowed: ruleKeySet)
        ruleKeys(given["signals"], at: "signals", allowed: ruleKeySet)
        ruleKeys(recommend?["exclude"], at: "recommend.exclude", allowed: ruleKeySet)
        ruleKeys(recommend?["vouch"], at: "recommend.vouch", allowed: ruleKeySet)
        ruleKeys(recommend?["classes"], at: "recommend.classes", allowed: ["class", "when", "note"])
        return out.sorted()
    }

    static let ruleKeySet: Set<String> = ["id", "kind", "enabled", "note", "when", "points", "line", "starExempt",
                                          "explicitPicks", "vouches", "rejection"]
    static let conditionKeySet: Set<String> = ["field", "op", "value", "any"]

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
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}
