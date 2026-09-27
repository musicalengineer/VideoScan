// TreeWalk.swift (VideoScanCore)
// The Family Tree WALK — an attribute-grammar-style pass over the family
// graph (Rick 2026-09-27, a former compiler writer: "design it cleanly").
//
// THE GRAPH. Nodes are people; edges are child → parent from the compiled
// parent topology (the primary parent family, Rick's identity rulings
// applied — the same edges every ancestor walk in the app follows). The
// graph is NOT assumed acyclic: a bad GEDCOM can make someone their own
// ancestor. So the first pass is Tarjan's SCC (iterative — a 40-generation
// line must not blow the stack); every SCC with more than one member, or a
// self-parent, is reported as a cycle and then treated as ONE poisoned node
// of the condensation, which IS a DAG.
//
// THE ATTRIBUTES, in grammar terms:
//   INHERITED (flow from the start people up to their ancestors, children
//   before parents = reverse Tarjan order over the condensation):
//     • line  — which start people this person is an ancestor of
//               (first / second / both / none). A semilattice (bit OR), so
//               pedigree collapse needs no special case: a diamond ORs the
//               same bits twice.
//     • generation from each start — breadth-first shortest distance (the
//               walk itself; BFS is exact on any graph, cycles included).
//     • distinct path count from each start — Σ over children; the
//               collapse indicator (a 20-generation line with no collapse
//               has exactly one path). NaN = poisoned by a cycle.
//   LOCAL (per person, no neighbours): dates with precision, age at death,
//     child count, birth region.
//   SYNTHESIZED (flow from ancestors down, Tarjan order):
//     • ancestor count and the documented (dated) fraction of the ancestor
//       set; descendant count within the tree (the same pass the other way).
//     These are DISTINCT counts over a DAG, where a sum double-counts every
//     shared ancestor. Exact distinct counts for all nodes are a transitive
//     closure (O(n²) bits = 1.2 GB at 100k); instead each node carries a
//     bottom-k (KMV) sketch of its set — merge = union-then-keep-k-smallest,
//     which is associative, commutative and IDEMPOTENT, so shared ancestors
//     are counted once, exactly like the line bits. Sets of ≤ k members are
//     held whole and counted EXACTLY; larger ones are estimated (±~13% at
//     k = 64) and say so (`isEstimate`).
//   CHECKS: per person over the frozen snapshot, in parallel; report,
//     never fix.
//
// EXTENSION SEAM (Rick: "interval inference later"): each pass writes its
// own column (struct-of-arrays over person ordinals) and `Decoration` is
// assembled at the end with every field optional in the codec. A later
// fixpoint pass (birth-year intervals propagated through parent / child /
// sibling / spouse constraints) adds a column and a field, bumps
// `walkerVersion`, and nothing else moves.
//
// C++ readers: `enum TreeWalk` with no cases is a namespace. The structs
// are plain values (copied on assignment, copy-on-write storage).

import Foundation

public enum TreeWalk {

    /// Bump when any decoration or check changes meaning — a stored
    /// decorations.json with an older version is stale and rebuilt.
    public static let walkerVersion = 1

    // MARK: - Attribute values

    /// Which start people a person is an ancestor of. With the default
    /// starts, `first` is Rick's line and `second` Donna's.
    public enum Line: String, Sendable, Codable, CaseIterable, Equatable {
        case first, second, both, none

        init(bits: UInt8) {
            switch bits & 3 {
            case 1: self = .first
            case 2: self = .second
            case 3: self = .both
            default: self = .none
            }
        }
    }

    public enum Severity: String, Sendable, Codable, Comparable, CaseIterable {
        case warn, info
        var rank: Int { self == .warn ? 0 : 1 }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public enum CheckKind: String, Sendable, Codable, CaseIterable, Equatable {
        case childBornBeforeParentAge12
        case childBornAfterMother55
        case childBornAfterFather80
        case deathBeforeBirth
        case ageOver110
        case bornAfterMotherDeath
        case bornAfterFatherDeath
        case spouseAgeGap
        case likelyDuplicate
        case ancestorCycle

        public var label: String {
            switch self {
            case .childBornBeforeParentAge12: return "Child born before parent was 12"
            case .childBornAfterMother55: return "Child born after mother was 55"
            case .childBornAfterFather80: return "Child born after father was 80"
            case .deathBeforeBirth: return "Death before birth"
            case .ageOver110: return "Age at death over 110"
            case .bornAfterMotherDeath: return "Born over a year after mother's death"
            case .bornAfterFatherDeath: return "Born over 9 months after father's death"
            case .spouseAgeGap: return "Spouses born over 40 years apart"
            case .likelyDuplicate: return "Likely the same person twice"
            case .ancestorCycle: return "Own ancestor (cycle)"
            }
        }

        public var severity: Severity {
            switch self {
            case .spouseAgeGap, .likelyDuplicate: return .info
            default: return .warn
            }
        }
    }

    /// One finding. Reported, never acted on.
    public struct Check: Sendable, Codable, Equatable {
        public let kind: CheckKind
        public let severity: Severity
        /// The person the check is ABOUT first (the child, the younger
        /// spouse …), then the others involved.
        public let personIDs: [String]
        public let reason: String

        public init(kind: CheckKind, personIDs: [String], reason: String) {
            self.kind = kind
            self.severity = kind.severity
            self.personIDs = personIDs
            self.reason = reason
        }
    }

    /// A count that is exact or a sketch estimate.
    public struct Count: Sendable, Codable, Equatable {
        public let value: Int
        public let isEstimate: Bool
        public init(value: Int, isEstimate: Bool) {
            self.value = value
            self.isEstimate = isEstimate
        }
        public var spoken: String { (isEstimate ? "≈" : "") + value.formatted() }
    }

    /// Everything the walk knows about one person. Every field decodes as
    /// optional-or-default so a stored file from the same version with a
    /// field missing still loads; a new field comes with a version bump.
    public struct Decoration: Sendable, Codable, Equatable {
        // Inherited
        public var line: Line = .none
        /// Generations above the first start person (0 = that person).
        public var generationFromFirst: Int?
        public var generationFromSecond: Int?
        /// Distinct child→parent paths from the start person; nil when not
        /// an ancestor, or poisoned by a cycle (`inCycle` or above one).
        public var pathsFromFirst: Double?
        public var pathsFromSecond: Double?
        /// Member of a cycle (their own ancestor).
        public var inCycle = false
        // Local
        public var sex = ""
        public var birthYear: Int?
        public var birthPrecision: DatePrecision?
        public var deathYear: Int?
        public var deathPrecision: DatePrecision?
        public var ageAtDeath: AgeAtDeath?
        public var childCount = 0
        public var birthRegion: BirthplaceClassifier.BirthRegion = .unknown
        // Synthesized
        public var ancestorCount = Count(value: 0, isEstimate: false)
        /// Share of the ancestor set with a birth year; nil when no ancestors.
        public var documentedAncestorFraction: Double?
        public var descendantCount = Count(value: 0, isEstimate: false)
        // Checks about this person: indexes into `Result.checks`.
        public var checks: [Int] = []

        public init() {}

        enum CodingKeys: String, CodingKey {
            case line = "l", generationFromFirst = "g1", generationFromSecond = "g2"
            case pathsFromFirst = "p1", pathsFromSecond = "p2", inCycle = "cy"
            case sex = "s", birthYear = "by", birthPrecision = "bp", deathYear = "dy", deathPrecision = "dp"
            case ageAtDeath = "age", childCount = "cc", birthRegion = "r"
            case ancestorCount = "ac", documentedAncestorFraction = "df", descendantCount = "dc", checks = "ck"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            line = try c.decodeIfPresent(Line.self, forKey: .line) ?? .none
            generationFromFirst = try c.decodeIfPresent(Int.self, forKey: .generationFromFirst)
            generationFromSecond = try c.decodeIfPresent(Int.self, forKey: .generationFromSecond)
            pathsFromFirst = try c.decodeIfPresent(Double.self, forKey: .pathsFromFirst)
            pathsFromSecond = try c.decodeIfPresent(Double.self, forKey: .pathsFromSecond)
            inCycle = try c.decodeIfPresent(Bool.self, forKey: .inCycle) ?? false
            sex = try c.decodeIfPresent(String.self, forKey: .sex) ?? ""
            birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
            birthPrecision = try c.decodeIfPresent(DatePrecision.self, forKey: .birthPrecision)
            deathYear = try c.decodeIfPresent(Int.self, forKey: .deathYear)
            deathPrecision = try c.decodeIfPresent(DatePrecision.self, forKey: .deathPrecision)
            ageAtDeath = try c.decodeIfPresent(AgeAtDeath.self, forKey: .ageAtDeath)
            childCount = try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0
            birthRegion = try c.decodeIfPresent(BirthplaceClassifier.BirthRegion.self, forKey: .birthRegion) ?? .unknown
            ancestorCount = try c.decodeIfPresent(Count.self, forKey: .ancestorCount) ?? Count(value: 0, isEstimate: false)
            documentedAncestorFraction = try c.decodeIfPresent(Double.self, forKey: .documentedAncestorFraction)
            descendantCount = try c.decodeIfPresent(Count.self, forKey: .descendantCount) ?? Count(value: 0, isEstimate: false)
            checks = try c.decodeIfPresent([Int].self, forKey: .checks) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if line != .none { try c.encode(line, forKey: .line) }
            try c.encodeIfPresent(generationFromFirst, forKey: .generationFromFirst)
            try c.encodeIfPresent(generationFromSecond, forKey: .generationFromSecond)
            // NaN is not JSON: a poisoned path count is simply absent (and
            // `inCycle` / the cycle check say why).
            try c.encodeIfPresent(pathsFromFirst.flatMap { $0.isNaN ? nil : $0 }, forKey: .pathsFromFirst)
            try c.encodeIfPresent(pathsFromSecond.flatMap { $0.isNaN ? nil : $0 }, forKey: .pathsFromSecond)
            if inCycle { try c.encode(true, forKey: .inCycle) }
            if !sex.isEmpty { try c.encode(sex, forKey: .sex) }
            try c.encodeIfPresent(birthYear, forKey: .birthYear)
            try c.encodeIfPresent(birthPrecision, forKey: .birthPrecision)
            try c.encodeIfPresent(deathYear, forKey: .deathYear)
            try c.encodeIfPresent(deathPrecision, forKey: .deathPrecision)
            try c.encodeIfPresent(ageAtDeath, forKey: .ageAtDeath)
            if childCount != 0 { try c.encode(childCount, forKey: .childCount) }
            if birthRegion != .unknown { try c.encode(birthRegion, forKey: .birthRegion) }
            try c.encode(ancestorCount, forKey: .ancestorCount)
            try c.encodeIfPresent(documentedAncestorFraction, forKey: .documentedAncestorFraction)
            try c.encode(descendantCount, forKey: .descendantCount)
            if !checks.isEmpty { try c.encode(checks, forKey: .checks) }
        }

        /// "your great-grandmother"-style word for generations above a start
        /// person; nil when not an ancestor of that start. Computed on read
        /// (cheap) instead of stored 39k times.
        public func relationLabel(generations: Int?) -> String? {
            guard let g = generations, g > 0 else { return nil }
            return GedcomFamilyGraph.generationLabel(generations: g, sex: sex)
        }
    }

    /// "N of M have <field>".
    public struct CoverageRow: Sendable, Codable, Equatable {
        public let field: String
        public let have: Int
        public let of: Int
        public var fraction: Double { of == 0 ? 0 : Double(have) / Double(of) }
        public var line: String { "\(have.formatted()) of \(of.formatted()) have \(field)" }
        public var percent: String { "\(Int((fraction * 100).rounded()))%" }
    }

    public struct Start: Sendable, Codable, Equatable {
        public let id: String
        public let name: String
        /// First given name ("Richard Harding Breen Jr" → "Richard").
        public var shortName: String {
            name.split(separator: " ").first.map(String.init) ?? name
        }
    }

    public struct Summary: Sendable, Codable, Equatable {
        public var peopleInTree = 0
        public var peopleWalked = 0
        public var byLine: [Line: Int] = [:]
        /// Birth regions of the WALKED people.
        public var byRegion: [BirthplaceClassifier.BirthRegion: Int] = [:]
        public var checksByKind: [CheckKind: Int] = [:]
        public var warnCount = 0
        public var infoCount = 0
        public var cycleCount = 0
        /// Deepest generation reached above each start.
        public var generationsFromFirst = 0
        public var generationsFromSecond = 0
        /// Coverage over the walked people, then over the whole tree.
        public var coverageWalked: [CoverageRow] = []
        public var coverageTree: [CoverageRow] = []
        public var walkMilliseconds = 0.0
        public var checksMilliseconds = 0.0
        public var totalMilliseconds = 0.0
        /// Sets bigger than the sketch size — counted by estimate.
        public var estimatedAncestorCounts = 0
    }

    /// One node as the walk reached it — the animation replays these.
    public struct Visit: Sendable, Equatable {
        public let ordinal: Int32
        public let generation: Int32
        /// The child this person was first reached through (−1 = a start).
        public let from: Int32
        /// Which of that child's parents this is (0 = father first) and
        /// how many parents the child has — the fan layout splits the
        /// child's angle by these.
        public let slot: UInt8
        public let slots: UInt8
        public let line: Line
        public let hasCheck: Bool
    }

    public struct Options: Sendable, Equatable {
        /// One or two start people (GEDCOM pointers). Two = the merged
        /// tree's home people, Rick first.
        public var starts: [String]
        /// nil = the whole ancestry.
        public var maxGenerations: Int?
        /// Bottom-k sketch size for the distinct counts (≤ 255).
        public var sketchSize: Int
        /// Progress event every this many visited people (nil = the
        /// default: 1,000, or 100 for a depth ≤ 5 or a walk under 5,000).
        public var progressEvery: Int?

        public init(starts: [String], maxGenerations: Int? = nil, sketchSize: Int = 64, progressEvery: Int? = nil) {
            self.starts = starts
            self.maxGenerations = maxGenerations
            self.sketchSize = max(2, min(255, sketchSize))
            self.progressEvery = progressEvery
        }
    }

    public enum WalkError: Error, Equatable, CustomStringConvertible {
        case noStartPeople
        case unknownStart(String)
        case tooManyStarts(Int)
        case cancelled

        public var description: String {
            switch self {
            case .noStartPeople:
                return "No start person — this tree names no home people, so pick someone to walk from."
            case .unknownStart(let id): return "The start person \(id) is not in the loaded tree."
            case .tooManyStarts(let n): return "A walk starts from one or two people, not \(n)."
            case .cancelled: return "Stopped before the walk finished."
            }
        }
    }

    /// Enough of one person to write a progress line about them.
    public struct Sample: Sendable, Equatable {
        public let id: String
        public let name: String
        public let birthYear: Int?
        public let line: Line
        public let generationFromFirst: Int?
        public let generationFromSecond: Int?
        public let ageAtDeath: AgeAtDeath?
        public let birthRegion: BirthplaceClassifier.BirthRegion
        public let childCount: Int
    }

    public struct Progress: Sendable, Equatable {
        public let visited: Int
        public let reachable: Int
        public let generation: Int
        public let frontier: Int
        public let sample: Sample?
    }

    public struct StartInfo: Sendable, Equatable {
        public let starts: [Start]
        public let maxGenerations: Int?
        public let peopleInTree: Int
        public let walkerVersion: Int
    }

    /// What the stream says, in order: started, progress…, cycle…,
    /// warnCheck…, then exactly one of finished / failed / cancelled.
    public enum Event: Sendable {
        case started(StartInfo)
        case phase(String)
        case progress(Progress)
        /// One per cyclic SCC, members listed.
        case cycle(Check)
        /// Warn-level checks only (info checks are counted in the summary).
        case warnCheck(Check)
        case finished(Result)
        case failed(String)
        case cancelled
    }
}

/// Swift enums with raw values encode as dictionary KEYS only via
/// CodingKeyRepresentable (macOS 12.3+ / Swift 5.6); declared here so the
/// summary's `[Line: Int]` tables encode as JSON objects, not arrays.
extension TreeWalk.Line: CodingKeyRepresentable {}
extension TreeWalk.CheckKind: CodingKeyRepresentable {}
extension BirthplaceClassifier.BirthRegion: CodingKeyRepresentable {}
