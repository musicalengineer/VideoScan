// ArchiveAngelRecommendations.swift
// THE recommendation classifier (docs/archive_angel_consolidation_plan.md,
// "Folding the Helper in"; Consolidation S3). One pure pass over the
// catalog's candidates that puts every record in ONE class — Ready, Needs a
// date, Worth a look, Not now, Excluded (with its reason), or Another copy —
// and lists the recommended ones in order. Every decision is read from a
// rule set (`AngelRecommendRules`, part of the recommendation policy); the
// Swift below only interprets it:
//
//   1. Floors — when `useAngelFloors`, a record the Angel's scorer rejected
//      (evidence grade X) is Excluded with the scorer's reason.
//   2. Exclusions — the rule set's own `exclude` rules (first match wins).
//   3. Vouches — every enabled `vouch` rule that matches adds its points
//      and its reason; a rule with `vouches: true` makes the record vouched.
//   4. Classes — the first `classes` rule whose conditions hold assigns the
//      class; none → Not now. Conditions may read the Angel's `grade`,
//      `eligible`, `vouched`, `vouchPoints` and `dated` (the date rule).
//   5. Copies — records in `copies.classes` that are the same recording
//      (ArchiveAngelCopyChooser) collapse to ONE: the person's Keep, else
//      the best by `order`; the rest become Another copy.
//   6. Lists — Ready / Needs a date / Worth a look, ordered by `order`.
//
// Two rule sets ship: `.legacyNudge` reproduces the retired ArchiveNudge.assess
// exactly (S3a proved it by parity; since S4 removed the nudge, frozen
// expected numbers pin it), and the unified default (S3b) is Rick's
// 2026-09-22 ruling: Ready = passes the Angel's floors AND (vouched OR
// grade A) AND dated to at least a year.
//
// Pure, Sendable, O(n) plus the sort of the recommended lists. No catalog,
// no main actor — table-testable and safe to run off-main.
//
// (For Rick: a function from a const vector of structs and a rule table to
// a result struct — no globals, no I/O; the rule table plays the part of a
// strategy object.)

import Foundation
import VideoScanCore

// MARK: - Classes

/// The one answer the Angel gives about a record (public surface — the
/// badge, the catalog filter and the Archive tab all speak in these).
enum ArchiveAngelRecommendationClass: String, Codable, Sendable, CaseIterable {
    /// Passes the floors, someone vouched (or grade A), dated.
    case ready
    /// Same, but not dated to the rule's precision.
    case needsDate
    /// Grade B, nobody vouched.
    case worthALook
    /// Grade C / D, or nothing recommends it.
    case notNow
    /// A floor or an exclusion rule — see the evidence's reason.
    case excluded
    /// The same recording as a recommended copy; that copy is the one.
    case anotherCopy
    /// In a prepared batch, waiting for review (from the plan store).
    case prepared
    /// Promoted by a batch still in the buffer (from the plan store).
    case promoted

    /// The classes a class rule may assign (the rest are assigned by the
    /// machinery: floors, copies, batches).
    static let assignable: [ArchiveAngelRecommendationClass] = [.ready, .needsDate, .worthALook, .notNow, .excluded]

    /// The "Archive candidates" set: what the Angel recommends doing
    /// something about now.
    var isRecommended: Bool { self == .ready || self == .needsDate || self == .worthALook }

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .needsDate: return "Needs a date"
        case .worthALook: return "Worth a look"
        case .notNow: return "Not now"
        case .excluded: return "Excluded"
        case .anotherCopy: return "Another copy"
        case .prepared: return "Prepared — waiting for review"
        case .promoted: return "Promoted"
        }
    }
}

// MARK: - Rule set

/// One class rule: `{ "class": "ready", "when": [ … ] }`.
struct AngelClassRule: Codable, Sendable, Equatable {
    var assign: String
    var when: [AngelCondition] = []
    var note: String = ""
    private(set) var resolvedClass: ArchiveAngelRecommendationClass?

    private enum CodingKeys: String, CodingKey { case assign = "class", when, note }

    init(_ assign: ArchiveAngelRecommendationClass, when: [AngelCondition] = [], note: String = "") {
        self.assign = assign.rawValue
        self.when = when
        self.note = note
        self.resolvedClass = assign
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assign = try c.decode(String.self, forKey: .assign)
        when = try c.decodeIfPresent([AngelCondition].self, forKey: .when) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        resolvedClass = ArchiveAngelRecommendationClass(rawValue: assign)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assign, forKey: .assign)
        if !when.isEmpty { try c.encode(when, forKey: .when) }
        if !note.isEmpty { try c.encode(note, forKey: .note) }
    }
}

/// How copies of one recording collapse to one recommendation.
struct AngelCopyRules: Codable, Sendable, Equatable {
    /// Keys tried in order; the first a record has is its recording key:
    /// "duplicateGroup" (any catalog duplicate group), "sharedDuplicateGroup"
    /// (a group of two or more — the nudge's rule), "nameAndDuration" (same
    /// filename and length rounded to the second — "00000.MTS" ×4).
    var collapseBy: [String] = ["duplicateGroup", "nameAndDuration"]
    /// Which copy stays, criteria in order: "userKeeper" (the copy the
    /// person marked Keep — first one wins), "best" (first by `order`).
    var prefer: [String] = ["userKeeper", "best"]
    /// The classes that collapse (a Not now copy never hides a Ready one).
    var classes: [String] = ["ready", "needsDate", "worthALook"]
    /// Add "N copies — this one" to the kept copy's reasons.
    var noteCopies: Bool = true

    static let collapseKinds = ["duplicateGroup", "sharedDuplicateGroup", "nameAndDuration"]
    static let preferKinds = ["userKeeper", "best"]

    init(collapseBy: [String] = ["duplicateGroup", "nameAndDuration"], prefer: [String] = ["userKeeper", "best"],
         classes: [String] = ["ready", "needsDate", "worthALook"], noteCopies: Bool = true) {
        self.collapseBy = collapseBy
        self.prefer = prefer
        self.classes = classes
        self.noteCopies = noteCopies
    }

    init(from decoder: Decoder) throws {
        let d = AngelCopyRules()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapseBy = try c.decodeIfPresent([String].self, forKey: .collapseBy) ?? d.collapseBy
        prefer = try c.decodeIfPresent([String].self, forKey: .prefer) ?? d.prefer
        classes = try c.decodeIfPresent([String].self, forKey: .classes) ?? d.classes
        noteCopies = try c.decodeIfPresent(Bool.self, forKey: .noteCopies) ?? d.noteCopies
    }

    var problems: [String] {
        var out: [String] = []
        for k in collapseBy where !Self.collapseKinds.contains(k) {
            out.append("recommend.copies.collapseBy \"\(k)\" — one of: \(Self.collapseKinds.joined(separator: ", "))")
        }
        for k in prefer where !Self.preferKinds.contains(k) {
            out.append("recommend.copies.prefer \"\(k)\" — one of: \(Self.preferKinds.joined(separator: ", "))")
        }
        for k in classes where ArchiveAngelRecommendationClass(rawValue: k).map({ !$0.isRecommended }) ?? true {
            out.append("recommend.copies.classes \"\(k)\" — one of: ready, needsDate, worthALook")
        }
        return out
    }
}

/// The recommendation rule set — the policy's `recommend` section.
struct AngelRecommendRules: Codable, Sendable, Equatable {
    /// Grade X (a scorer floor) → Excluded, with the scorer's reason.
    var useAngelFloors: Bool
    /// Classifier-only exclusions (`match` rules), first match wins.
    var exclude: [AngelRule]
    /// Who vouched, and how strongly (`match` / `stars` rules).
    var vouch: [AngelRule]
    /// What "dated" means.
    var date: AngelDateRule
    /// First match wins; none → Not now.
    var classes: [AngelClassRule]
    var copies: AngelCopyRules
    /// The recommended lists' order and the copy chooser's "best":
    /// "angelRank" (the Angel's score, then its most-original tie-breaks)
    /// or "vouchPoints" (vouch points, then the older year, then the name).
    var order: String
    /// The classes Prepare Batch takes, in this order (QA on S3: Prepare
    /// agrees with the numbers). Needs a date is left out by default — add
    /// it to opt in. Unclassified evidence (a pre-S3b file) comes last.
    /// EMPTY = no class filter: every eligible file by score (the pre-S3
    /// batch order).
    var prepare: [String]

    static let orders = ["angelRank", "vouchPoints"]
    static let defaultPrepare = ["ready", "worthALook"]

    var prepareClasses: [ArchiveAngelRecommendationClass] {
        prepare.compactMap(ArchiveAngelRecommendationClass.init(rawValue:))
    }

    init(useAngelFloors: Bool, exclude: [AngelRule], vouch: [AngelRule], date: AngelDateRule,
         classes: [AngelClassRule], copies: AngelCopyRules, order: String,
         prepare: [String] = AngelRecommendRules.defaultPrepare) {
        self.useAngelFloors = useAngelFloors
        self.exclude = exclude
        self.vouch = vouch
        self.date = date
        self.classes = classes
        self.copies = copies
        self.order = order
        self.prepare = prepare
    }

    private enum CodingKeys: String, CodingKey {
        case useAngelFloors, exclude, vouch, date, classes, copies, order, prepare
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useAngelFloors = try c.decode(Bool.self, forKey: .useAngelFloors)
        exclude = try c.decode([AngelRule].self, forKey: .exclude)
        vouch = try c.decode([AngelRule].self, forKey: .vouch)
        date = try c.decode(AngelDateRule.self, forKey: .date)
        classes = try c.decode([AngelClassRule].self, forKey: .classes)
        copies = try c.decode(AngelCopyRules.self, forKey: .copies)
        order = try c.decode(String.self, forKey: .order)
        prepare = try c.decodeIfPresent([String].self, forKey: .prepare) ?? Self.defaultPrepare
    }

    /// Every problem in the rule set; empty = usable.
    var problems: [String] {
        var out = AngelRule.problems(in: exclude, section: .exclude, where: "recommend.exclude",
                                     pointRange: 0...0)
        out += AngelRule.problems(in: vouch, section: .vouch, where: "recommend.vouch", pointRange: 0...1_000)
        if let p = date.problem { out.append(p) }
        if classes.count > AngelRule.maxRulesPerSection { out.append("recommend.classes: more than \(AngelRule.maxRulesPerSection) rules") }
        for (i, rule) in classes.enumerated() {
            let here = "recommend.classes[\(i)] \"\(rule.assign)\""
            if let k = rule.resolvedClass {
                if !ArchiveAngelRecommendationClass.assignable.contains(k) {
                    out.append("\(here): a class rule may assign only "
                               + ArchiveAngelRecommendationClass.assignable.map(\.rawValue).joined(separator: ", "))
                }
            } else {
                out.append("\(here): unknown class — one of: "
                           + ArchiveAngelRecommendationClass.assignable.map(\.rawValue).joined(separator: ", "))
            }
            if rule.when.count > AngelRule.maxConditionsPerRule { out.append("\(here): more than \(AngelRule.maxConditionsPerRule) conditions") }
            for cond in rule.when { out += cond.problems(allowClassifierFields: true).map { "\(here): \($0)" } }
        }
        out += copies.problems
        for k in prepare where ArchiveAngelRecommendationClass(rawValue: k).map({ !$0.isRecommended }) ?? true {
            out.append("recommend.prepare \"\(k)\" — one of: ready, needsDate, worthALook")
        }
        if !Self.orders.contains(order) {
            out.append("recommend.order \"\(order)\" — one of: \(Self.orders.joined(separator: ", "))")
        }
        return out
    }
}

extension AngelRecommendRules {

    /// ArchiveNudge.assess (the Archive tab's "It looks like N files are
    /// ready…", Rick 2026-08-21; retired with the Promote Helper in S4) as
    /// DATA — S3a. Still read by the sweep's once-per-rules-change
    /// "old → new counts" log line. Reproduces it exactly:
    ///   • excluded: an Extra copy, a junk disposition, junkScore ≥ 50;
    ///   • vouched: Important (3), ★★ / ★★★ (1 per star), stage Ready (2)
    ///     or Master (1); "the copy to keep" is a reason, not a vouch;
    ///   • ready = vouched + a date to the year; needs a date = vouched;
    ///   • one per recording: a duplicate group of 2+, else filename +
    ///     length to the second; the Keep copy, else the best-vouched;
    ///   • ordered by vouch points, then the older year, then the name.
    /// The Angel's floors and grades are NOT consulted — that was the nudge.
    static let legacyNudge = AngelRecommendRules(
        useAngelFloors: false,
        exclude: [
            AngelRule(id: "extraCopy", kind: .match,
                      when: [.init(field: .duplicateDisposition, op: .eq, value: .string("extraCopy"))],
                      line: "An extra copy"),
            AngelRule(id: "junkDisposition", kind: .match,
                      when: [.init(field: .mediaDisposition, op: .in, value: .strings(["suspectedJunk", "confirmedJunk"]))],
                      line: "Marked junk"),
            AngelRule(id: "junkScore", kind: .match,
                      when: [.init(field: .junkScore, op: .ge, value: .number(50))],
                      line: "Junk score 50 or more"),
        ],
        vouch: [
            AngelRule(id: "important", kind: .match,
                      when: [.init(field: .mediaDisposition, op: .eq, value: .string("important"))],
                      points: 3, line: "marked Important"),
            AngelRule(id: "stars", kind: .stars,
                      when: [.init(field: .starRating, op: .ge, value: .number(2))],
                      points: 1),
            AngelRule(id: "stageReady", kind: .match,
                      when: [.init(field: .archiveStage, op: .eq, value: .string("readyForArchive"))],
                      points: 2, line: "stage: Ready"),
            AngelRule(id: "stageMaster", kind: .match,
                      when: [.init(field: .archiveStage, op: .eq, value: .string("masterAssigned"))],
                      points: 1, line: "stage: Master"),
            AngelRule(id: "keeper", kind: .match,
                      when: [.init(field: .duplicateDisposition, op: .eq, value: .string("keep"))],
                      line: "the copy to keep", vouches: false),
        ],
        date: AngelDateRule(minimum: "year"),
        classes: [
            AngelClassRule(.ready, when: [.init(field: .vouched, op: .eq, value: .bool(true)),
                                          .init(field: .dated, op: .eq, value: .bool(true))]),
            AngelClassRule(.needsDate, when: [.init(field: .vouched, op: .eq, value: .bool(true))]),
        ],
        copies: AngelCopyRules(collapseBy: ["sharedDuplicateGroup", "nameAndDuration"],
                               prefer: ["userKeeper", "best"],
                               classes: ["ready", "needsDate"],
                               noteCopies: true),
        order: "vouchPoints")
}

// MARK: - The copy chooser (the ONE seam for "which copy of this recording")

/// Which records are the same recording, and which of them is the one to
/// recommend. The classifier uses it; the scorer's one-per-duplicate-group
/// batch filter is the `duplicateGroup` key with "best" = rank order.
/// CopyFamilyAssessor.recommendedInstance answers a finer question (which
/// physical instance of one representation, from content hashes, volume
/// reliability and verified audio the Angel's projection does not carry)
/// and stays behind Show Copies…; see `physicalInstance(of:anchors:)`.
enum ArchiveAngelCopyChooser {

    /// The recording key for `c` under `collapseBy`, or nil (never collapses).
    static func key(_ c: ArchiveAngelCandidate, collapseBy: [String]) -> String? {
        for kind in collapseBy {
            switch kind {
            case "duplicateGroup":
                if let g = c.duplicateGroupID { return "group:" + g.uuidString }
            case "sharedDuplicateGroup":
                if let g = c.duplicateGroupID, c.duplicateGroupCount > 1 { return "group:" + g.uuidString }
            case "nameAndDuration":
                if !c.filename.isEmpty, c.durationSeconds > 0 {
                    return "name:\(c.filename.lowercased())|\(Int(c.durationSeconds.rounded()))"
                }
            default:
                continue
            }
        }
        return nil
    }

    /// The member to keep, by `prefer`: indices into `members` (input
    /// order); `isBetter(a, b)` = a ranks before b. The person's Keep is
    /// the FIRST such member; "best" keeps the first of equals.
    static func choose(_ members: [Int], prefer: [String], isKeeper: (Int) -> Bool,
                       isBetter: (Int, Int) -> Bool) -> Int? {
        guard let first = members.first else { return nil }
        for criterion in prefer {
            switch criterion {
            case "userKeeper":
                if let k = members.first(where: isKeeper) { return k }
            case "best":
                var best = first
                for m in members.dropFirst() where isBetter(m, best) { best = m }
                return best
            default:
                continue
            }
        }
        return first
    }

    /// One per `key` in an already-ranked list: the first seen stays, the
    /// rest are returned as dropped. Pure; the scorer's batch filter.
    static func firstPerKey<T>(_ ranked: [T], key: (T) -> String?) -> (kept: [T], dropped: Int) {
        var seen = Set<String>()
        var kept: [T] = []
        kept.reserveCapacity(ranked.count)
        var dropped = 0
        for item in ranked {
            guard let k = key(item) else { kept.append(item); continue }
            if seen.insert(k).inserted { kept.append(item) } else { dropped += 1 }
        }
        return (kept, dropped)
    }

    /// Show Copies…'s answer (which physical instance of one
    /// representation), reached through this seam so every "which copy"
    /// question has one front door.
    static func physicalInstance(of members: [CopyFamilyInput], anchors: Set<UUID> = []) -> CopyFamilyInput? {
        CopyFamilyAssessor.recommendedInstance(members, anchors: anchors)
    }
}

// MARK: - The classifier

enum ArchiveAngelRecommendations {

    /// One record's answer.
    struct Verdict: Sendable, Equatable {
        var kind: ArchiveAngelRecommendationClass
        /// Why, in the order a person would say it (vouch reasons, "grade
        /// A", "3 copies — this one"; the exclusion's reason when excluded
        /// by a classifier rule).
        var reasons: [String] = []
        /// Vouch points.
        var points: Int = 0
        /// The year the date rule found (nil = not dated, or not asked).
        var year: Int?
        /// Copies that collapsed onto this one (1 = none).
        var copies: Int = 1
        /// The Angel's score when floors are used (orders the lists).
        var score: Int = 0
    }

    /// A row of a recommended list.
    struct Entry: Sendable, Equatable, Identifiable {
        var id: UUID
        var filename: String
        var kind: ArchiveAngelRecommendationClass
        var year: Int?
        var reasons: [String]
        var points: Int
        var score: Int
        var copies: Int
    }

    struct Result: Sendable, Equatable {
        /// Parallel to the input candidates.
        var verdicts: [Verdict]
        var ready: [Entry]
        var needsDate: [Entry]
        var worthALook: [Entry]
        var counts: [ArchiveAngelRecommendationClass: Int]

        static let empty = Result(verdicts: [], ready: [], needsDate: [], worthALook: [], counts: [:])
    }

    /// Classify every candidate. `evidence` is the Angel's verdict per
    /// record (grade, score, floor) — required when `useAngelFloors`; a
    /// record with no evidence then counts as Not now ("not assessed").
    /// Pure. Worst case O(n) + O(r log r) for the r recommended rows; memory
    /// one Verdict per record plus the collapse keys (~200 B/record).
    static func classify(_ candidates: [ArchiveAngelCandidate],
                         evidence: [UUID: ArchiveAngelEvidenceRecord] = [:],
                         rules: AngelRecommendRules,
                         now: Date = Date()) -> Result {
        var verdicts: [Verdict] = []
        verdicts.reserveCapacity(candidates.count)
        for c in candidates {
            verdicts.append(verdict(c, evidence: evidence[c.id], rules: rules, now: now))
        }

        // Copies → one per recording.
        let byOrder = comparator(rules.order, candidates: candidates, verdicts: verdicts)
        let collapsing = Set(rules.copies.classes.compactMap(ArchiveAngelRecommendationClass.init(rawValue:)))
        var groups: [String: [Int]] = [:]
        var groupOrder: [String] = []
        for (i, v) in verdicts.enumerated() where collapsing.contains(v.kind) {
            guard let k = ArchiveAngelCopyChooser.key(candidates[i], collapseBy: rules.copies.collapseBy) else { continue }
            if groups[k] == nil { groupOrder.append(k) }
            groups[k, default: []].append(i)
        }
        for k in groupOrder {
            guard let members = groups[k], members.count > 1,
                  let kept = ArchiveAngelCopyChooser.choose(
                    members, prefer: rules.copies.prefer,
                    isKeeper: { candidates[$0].duplicateDisposition == .keep },
                    isBetter: byOrder) else { continue }
            for m in members where m != kept {
                verdicts[m].kind = .anotherCopy
                verdicts[m].reasons = ["Another copy of \(candidates[kept].filename) is the one recommended"]
            }
            verdicts[kept].copies = members.count
            if rules.copies.noteCopies { verdicts[kept].reasons.append("\(members.count) copies — this one") }
        }

        // Lists + counts.
        var counts: [ArchiveAngelRecommendationClass: Int] = [:]
        var ready: [Int] = [], needsDate: [Int] = [], worth: [Int] = []
        for (i, v) in verdicts.enumerated() {
            counts[v.kind, default: 0] += 1
            switch v.kind {
            case .ready: ready.append(i)
            case .needsDate: needsDate.append(i)
            case .worthALook: worth.append(i)
            default: break
            }
        }
        func entries(_ idx: [Int]) -> [Entry] {
            idx.sorted(by: byOrder).map { i in
                let c = candidates[i], v = verdicts[i]
                return Entry(id: c.id, filename: c.filename, kind: v.kind, year: v.year, reasons: v.reasons,
                             points: v.points, score: v.score, copies: v.copies)
            }
        }
        return Result(verdicts: verdicts, ready: entries(ready), needsDate: entries(needsDate),
                      worthALook: entries(worth), counts: counts)
    }

    /// Steps 1–4 for one record (no copies — that needs the whole set).
    static func verdict(_ c: ArchiveAngelCandidate, evidence ev: ArchiveAngelEvidenceRecord?,
                        rules: AngelRecommendRules, now: Date) -> Verdict {
        var ctx = AngelEvalContext(dateRule: rules.date, now: now)
        var v = Verdict(kind: .notNow)
        if let ev {
            ctx.grade = ev.grade
            v.score = ev.score
        }
        // 0. Safety floors are never overridden (QA on S3): a gone,
        // archived, offline or non-video file is Excluded even when the
        // rules ignore the Angel's floors.
        if let rejection = ev?.rejection, ArchiveAngelRejection.safetyReasons.contains(rejection) {
            v.kind = .excluded
            v.reasons = [rejection.rawValue]
            return v
        }
        // 1. The Angel's floors.
        if rules.useAngelFloors {
            guard let ev else {
                v.reasons = ["Not assessed yet"]
                return v
            }
            if let rejection = ev.rejection {
                ctx.eligible = false
                v.kind = .excluded
                v.reasons = [rejection.rawValue]
                return v
            }
        }
        // 2. Exclusions.
        for rule in rules.exclude where rule.enabled && AngelCondition.all(rule.when, c, &ctx) {
            v.kind = .excluded
            v.reasons = [rule.displayLine]
            return v
        }
        // 3. Vouches.
        for rule in rules.vouch where rule.enabled && AngelCondition.all(rule.when, c, &ctx) {
            switch rule.resolvedKind {
            case .stars?:
                let stars = max(0, c.starRating)
                ctx.vouchPoints = ArchiveAngelScorer.sum(ctx.vouchPoints, ArchiveAngelScorer.product(rule.points, stars))
                v.reasons.append(rule.line.isEmpty ? String(repeating: "★", count: min(stars, 10)) : rule.line)
            case .match?:
                ctx.vouchPoints = ArchiveAngelScorer.sum(ctx.vouchPoints, rule.points)
                v.reasons.append(rule.displayLine)
            default:
                continue
            }
            if rule.vouches { ctx.vouched = true }
        }
        v.points = ctx.vouchPoints
        // 4. Classes.
        for rule in rules.classes {
            guard let assigned = rule.resolvedClass, AngelCondition.all(rule.when, c, &ctx) else { continue }
            v.kind = assigned
            break
        }
        if v.kind == .ready || v.kind == .needsDate || v.kind == .worthALook {
            v.year = ctx.datedYear(c)
            if !ctx.vouched, ctx.grade == .a, v.kind != .worthALook {
                v.reasons.append("Archive Angel grade A (\(v.score))")
            } else if v.kind == .worthALook, let g = ctx.grade {
                v.reasons.append("Archive Angel grade \(g.rawValue) (\(v.score))")
            }
        }
        if v.kind == .notNow, v.reasons.isEmpty, let g = ctx.grade {
            v.reasons = ["Archive Angel grade \(g.rawValue) (\(v.score))"]
        }
        return v
    }

    /// The list order — also the copy chooser's "best".
    static func comparator(_ order: String, candidates: [ArchiveAngelCandidate],
                           verdicts: [Verdict]) -> (Int, Int) -> Bool {
        switch order {
        case "vouchPoints":
            // ArchiveNudge's order: strongest vouching, the older recording
            // (the heritage tapes are the point), then the name.
            return { a, b in
                let va = verdicts[a], vb = verdicts[b]
                if va.points != vb.points { return va.points > vb.points }
                if va.year != vb.year { return (va.year ?? .max) < (vb.year ?? .max) }
                return candidates[a].filename.localizedStandardCompare(candidates[b].filename) == .orderedAscending
            }
        default:
            // The Angel's ONE comparator (score, then most original…).
            return { a, b in
                ArchiveAngelScorer.rank(candidates[a], score: verdicts[a].score,
                                        before: candidates[b], score: verdicts[b].score)
            }
        }
    }
}
