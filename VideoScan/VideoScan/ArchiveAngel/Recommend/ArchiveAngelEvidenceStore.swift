// ArchiveAngelEvidenceStore.swift
// Archive Angel phase 2 (docs/archive_angel_phase2_design.md): the SIDECAR
// that holds the background sweep's machine-tier evidence — one record per
// catalog id: the score and its printed why-lines, or the hard-floor
// rejection. Fully re-derivable, so a stale or missing file is harmless and
// a file from a different store version is simply ignored.
//
// Not the catalog schema: no VideoRecord field, no migration. If Rick wants
// the score on the record later it is one additive field and a copy.

import Foundation
import Combine
import VideoScanCore

/// Grade band (Rick 2026-09-09): a letter the eye reads faster than a score.
/// A ready · B nearly ready · C candidate · D weak · X excluded (floor).
enum ArchiveAngelGrade: String, Codable, Sendable, CaseIterable, Comparable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case x = "X"

    var label: String {
        switch self {
        case .a: return "ready"
        case .b: return "nearly ready"
        case .c: return "candidate"
        case .d: return "weak"
        case .x: return "excluded"
        }
    }

    /// Pure band from a score under the built-in bands (A ≥ 100, B ≥ 60,
    /// C ≥ 25, D ≥ 1). Rejections are graded X by the record's init.
    static func from(score: Int) -> ArchiveAngelGrade {
        AngelGradeBands.standard.grade(for: score)
    }

    /// The same under the policy's bands (`grades` in policy.json, S3b).
    static func from(score: Int, bands: AngelGradeBands) -> ArchiveAngelGrade {
        bands.grade(for: score)
    }

    /// A + B — the "Archive candidates" set for a record the classifier
    /// has not classified (an evidence file from before S3b, a test-built
    /// record). A classified record answers with its class instead.
    static let candidateGrades: Set<ArchiveAngelGrade> = [.a, .b]

    static func < (lhs: ArchiveAngelGrade, rhs: ArchiveAngelGrade) -> Bool {
        let order = ArchiveAngelGrade.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// The assessment's verdict for one record.
struct ArchiveAngelEvidenceRecord: Codable, Sendable, Equatable {
    var score: Int
    var lines: [ArchiveAngelEvidence]
    var rejection: ArchiveAngelRejection?
    var useCount: Int
    var lastUsed: Date?
    var computedAt: Date
    var grade: ArchiveAngelGrade
    /// Phase 1 attention: how often the Angel has proposed this file (0 =
    /// new to the person). Lets the evidence pick find "fresh eyes"
    /// candidates past the score band without projecting them.
    var timesProposed: Int
    /// The OTHER members' effective skips in this file's event family, as
    /// the sweep's `applyFamilyAttention` pass computed them (codex
    /// 2026-09-20 #6): the pick's projection is per record and never runs
    /// that pass, so without this a never-proposed variant of skipped
    /// footage came back "New to you" from the cache. Rules v9.
    var familySkips: Double
    /// Consolidation S3b — the recommendation classifier's answer, written
    /// by the sweep (nil in a file from before S3b or a checkpoint):
    /// the class, why (vouches, "grade A", "3 copies — this one"), the year
    /// the date rule found, and how many copies collapsed onto this one.
    var recommendation: ArchiveAngelRecommendationClass?
    var reasons: [String]?
    var year: Int?
    var copies: Int?
    /// A policy floor's own words when `rejection == .policyRule`.
    var excludedBy: String?

    init(score: Int, lines: [ArchiveAngelEvidence], rejection: ArchiveAngelRejection?,
         useCount: Int, lastUsed: Date?, computedAt: Date, timesProposed: Int = 0,
         familySkips: Double = 0, bands: AngelGradeBands = .standard, excludedBy: String? = nil) {
        self.score = score
        self.lines = lines
        self.rejection = rejection
        self.useCount = useCount
        self.lastUsed = lastUsed
        self.computedAt = computedAt
        self.grade = rejection == nil ? bands.grade(for: score) : .x
        self.timesProposed = timesProposed
        self.familySkips = familySkips
        self.excludedBy = excludedBy
    }

    /// Scored (cleared the floor) — any of A–D.
    var isEligible: Bool { rejection == nil }

    /// The class this record is in: the classifier's, or — for a record it
    /// never saw — the grade's nearest (A → Ready, B → Worth a look,
    /// C/D → Not now, X → Excluded).
    var recommendationClass: ArchiveAngelRecommendationClass {
        if let recommendation { return recommendation }
        switch grade {
        case .a: return .ready
        case .b: return .worthALook
        case .c, .d: return .notNow
        case .x: return .excluded
        }
    }

    /// In the "Archive candidates" set: Ready, Needs a date or Worth a look.
    var isCandidate: Bool { recommendationClass.isRecommended }

    /// "AAA grade B (72) — ★★ · Donna (confirmed) · played 14 times";
    /// a classified record adds its class: "AAA grade A (112) · Ready — …".
    func summary(maxLines: Int = 3) -> String {
        if let r = rejection { return "AAA excluded — " + (excludedBy.map { r.rawValue + ": " + $0 } ?? r.rawValue) }
        let why = lines.prefix(maxLines).map(\.line).joined(separator: " · ")
        var head = "AAA grade \(grade.rawValue) (\(score))"
        if let recommendation { head += " · " + recommendation.label }
        if recommendation == .anotherCopy || recommendation == .excluded, let first = reasons?.first {
            return head + " — " + first
        }
        return why.isEmpty ? head : head + " — " + why
    }
}

/// On-disk shape. `complete == false` marks a checkpoint written mid-sweep;
/// freshness requires a complete file.
struct ArchiveAngelEvidenceFile: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var storeVersion: Int = ArchiveAngelEvidenceFile.currentVersion
    /// Scorer rules the records were computed under. A file from older
    /// rules (or one without the stamp) is ignored on load — the sweep
    /// re-derives it in seconds — so a refined floor or weight table
    /// never shows stale grades.
    var rulesVersion: Int = ArchiveAngelScorer.rulesVersion
    var computedAt: Date
    var complete: Bool
    var considered: Int
    var eligible: Int
    var records: [UUID: ArchiveAngelEvidenceRecord]
    /// The attention state the sweep ACTUALLY scored with (codex
    /// 2026-09-20 #5): `ArchiveAngelAttentionStore.revision` and
    /// `lastEventAt`, captured at the snapshot — not when scoring finished.
    /// A skip noted while scoring ran is older than `computedAt` but newer
    /// than these, so the pick can tell. nil = written by something that
    /// did not capture it (a test-built file); the pick then falls back to
    /// `computedAt`.
    var attentionRevision: Int?
    var attentionLastEventAt: Date?
    /// The recommendation policy the records were scored under
    /// (`AngelRecommendationPolicy.fingerprint`, S2 2026-09-22). nil = a
    /// file written before the stamp existed: accepted only while the
    /// DEFAULT policy is active (no forced re-score on upgrade).
    var policyFingerprint: String?

    init(computedAt: Date = Date(), complete: Bool = true, considered: Int = 0,
         eligible: Int = 0, records: [UUID: ArchiveAngelEvidenceRecord] = [:],
         attentionRevision: Int? = nil, attentionLastEventAt: Date? = nil,
         policyFingerprint: String? = nil) {
        self.computedAt = computedAt
        self.complete = complete
        self.considered = considered
        self.eligible = eligible
        self.records = records
        self.attentionRevision = attentionRevision
        self.attentionLastEventAt = attentionLastEventAt
        self.policyFingerprint = policyFingerprint
    }
}

/// Main-actor façade over the sidecar file. Reads are O(1) per record so a
/// catalog filter or an inspector line can ask freely; the file itself is
/// loaded and saved off-main.
@MainActor
final class ArchiveAngelEvidenceStore: ObservableObject {

    static let filename = "evidence.json"

    /// App Support/VideoScan/archive-angel/ — the production home; under a
    /// test host a per-process scratch folder. The formula and the reason
    /// (the 2026-09-19 evidence.json overwrite from inside the unit suite)
    /// live in AngelEnvironment (S2); the façade injects the directory.
    nonisolated static var defaultDirectory: URL { AngelEnvironment.currentEvidenceDirectory }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    @Published private(set) var file: ArchiveAngelEvidenceFile?
    /// Grade A + B ids — the "Archive candidates" filter set. Rebuilt on
    /// every replace so the catalog filter is a Set lookup.
    @Published private(set) var candidateIDs: Set<UUID> = []
    /// Bumped on EVERY replace/clear, membership change or not (codex
    /// #1345): a sweep that keeps a record in A/B but flips A↔B or
    /// rewrites its summary leaves `candidateIDs` untouched, so the
    /// catalog rows drawing the badge/tooltip had nothing to observe.
    /// Rows re-render on this; the filter recomputes on `candidateIDs`.
    @Published private(set) var revision: Int = 0

    /// The fingerprint of the policy this store's sweep scores with; a
    /// loaded file stamped with another is treated like old rules.
    let policyFingerprint: String
    /// Where "policy changed" / load refusals are said (console + file log
    /// via the façade). Default: the unified log only.
    var log: (String) -> Void = { _ in }
    /// Called after every replace / clear, AFTER the new file is in place
    /// (a `$revision` sink runs in willSet and would read the old file).
    /// The façade rebuilds its class counts here.
    var didChange: () -> Void = {}
    /// Set by `load()` when evidence.json on disk was scored under an OLDER
    /// rules version (ignored, as always): the version and its grade
    /// histogram, so the first sweep under the new rules can log old → new
    /// once. Cleared by the sweep that logs it.
    var olderRules: (rulesVersion: Int, grades: [ArchiveAngelGrade: Int])?

    init(directory: URL = ArchiveAngelEvidenceStore.defaultDirectory,
         policyFingerprint: String = AngelRecommendationPolicy.defaultFingerprint) {
        self.directory = directory
        self.policyFingerprint = policyFingerprint
    }

    // MARK: Reads (O(1))

    var computedAt: Date? { file?.computedAt }
    /// The attention state the file was scored with (nil = not stamped).
    var attentionRevision: Int? { file?.attentionRevision }
    var attentionLastEventAt: Date? { file?.attentionLastEventAt }
    var isLoaded: Bool { file != nil }
    /// Grades A + B (the default filter).
    var candidateCount: Int { candidateIDs.count }
    /// Everything that cleared the floor (A–D) — what the Angel ranks over.
    var eligibleCount: Int { file?.eligible ?? 0 }
    var consideredCount: Int { file?.considered ?? 0 }

    /// Class histogram — one O(records) pass.
    func classCounts() -> [ArchiveAngelRecommendationClass: Int] {
        guard let f = file else { return [:] }
        var out: [ArchiveAngelRecommendationClass: Int] = [:]
        for r in f.records.values { out[r.recommendationClass, default: 0] += 1 }
        return out
    }

    /// Grade histogram — one O(records) pass, for the finish line.
    func gradeCounts() -> [ArchiveAngelGrade: Int] {
        guard let f = file else { return [:] }
        var out: [ArchiveAngelGrade: Int] = [:]
        for r in f.records.values { out[r.grade, default: 0] += 1 }
        return out
    }

    func record(for id: UUID) -> ArchiveAngelEvidenceRecord? { file?.records[id] }

    /// Fresh = a COMPLETE sweep finished within `interval` of `now`.
    func isFresh(within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let f = file, f.complete else { return false }
        return now.timeIntervalSince(f.computedAt) <= interval
    }

    /// Every ELIGIBLE record (A–D) ranked the way the scorer ranks picks
    /// (score desc, then the caller's tie-break). Pure over the loaded file.
    func rankedEligibleIDs(tieBreak: (UUID, UUID) -> Bool = { $0.uuidString < $1.uuidString }) -> [UUID] {
        guard let f = file else { return [] }
        return f.records.filter { $0.value.isEligible }
            .sorted { a, b in
                if a.value.score != b.value.score { return a.value.score > b.value.score }
                return tieBreak(a.key, b.key)
            }
            .map(\.key)
    }

    /// The Prepare order (QA on S3): records whose class Prepare takes,
    /// by (tier = index in `prepare`, score desc, id); an UNCLASSIFIED
    /// eligible record (a pre-S3b or test-built file) takes the last tier,
    /// so old evidence still prepares by score. `skipped` = eligible
    /// records in classes Prepare does not take. One O(records) pass + sort.
    func rankedPrepareIDs(_ prepare: [ArchiveAngelRecommendationClass]) -> (ids: [(UUID, Int)], skipped: Int) {
        guard let f = file else { return ([], 0) }
        var rows: [(UUID, Int, Int)] = []
        var skipped = 0
        for (id, r) in f.records where r.isEligible {
            if prepare.isEmpty {
                rows.append((id, 0, r.score))   // no class filter: score order
            } else if let k = r.recommendation {
                guard let tier = prepare.firstIndex(of: k) else { skipped += 1; continue }
                rows.append((id, tier, r.score))
            } else {
                rows.append((id, prepare.count, r.score))
            }
        }
        rows.sort { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0.uuidString < b.0.uuidString
        }
        return (rows.map { ($0.0, $0.1) }, skipped)
    }

    /// Floor rejections by reason — one O(records) pass, for the Angel
    /// plan's "rejected" summary when picks come from evidence.
    func rejectionCounts() -> [ArchiveAngelRejection: Int] {
        guard let f = file else { return [:] }
        var out: [ArchiveAngelRejection: Int] = [:]
        for r in f.records.values { if let rej = r.rejection { out[rej, default: 0] += 1 } }
        return out
    }

    // MARK: Writes

    /// Replace the in-memory file (does not touch disk — see `save`).
    func replace(with newFile: ArchiveAngelEvidenceFile) {
        file = newFile
        candidateIDs = Set(newFile.records.filter { $0.value.isCandidate }.map(\.key))
        revision &+= 1
        didChange()
    }

    /// Forget everything (tests, "Rescore now" reset).
    func clear() {
        file = nil
        candidateIDs = []
        revision &+= 1
        didChange()
    }

    /// Load from disk off-main and publish. A missing, malformed,
    /// wrong-version or old-rules file leaves the store empty
    /// (poisoned-state rule). Returns whether anything was loaded so the
    /// caller can re-score straight away instead of waiting.
    @discardableResult
    func load() async -> Bool {
        let url = fileURL
        guard let loaded = await Self.loadOffMain(url) else {
            olderRules = await Self.olderRulesOffMain(url)
            if let old = olderRules {
                log("Archive Angel Assessment: evidence.json was scored under rules v\(old.rulesVersion) — re-scoring under v\(ArchiveAngelScorer.rulesVersion)")
            }
            return false
        }
        if let why = Self.policyMismatch(stamped: loaded.policyFingerprint, current: policyFingerprint) {
            log("Archive Angel Assessment: evidence.json ignored — " + why + "; re-scoring")
            return false
        }
        replace(with: loaded)
        return true
    }

    /// nil = the file's grades were computed under the current policy.
    /// An unstamped (pre-S2) file counts as the DEFAULT policy's.
    nonisolated static func policyMismatch(stamped: String?, current: String) -> String? {
        let old = stamped ?? AngelRecommendationPolicy.defaultFingerprint
        return old == current ? nil : "policy changed: \(stamped ?? "unstamped (default)") → \(current)"
    }

    /// Save the current file off-main (atomic replace). No-op when empty.
    @discardableResult
    func save() async -> Bool {
        guard let f = file else { return false }
        return await Self.saveOffMain(f, to: fileURL)
    }

    // MARK: Off-main hops

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOffMain(_ url: URL) async -> ArchiveAngelEvidenceFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(ArchiveAngelEvidenceFile.self, from: data),
              f.storeVersion == ArchiveAngelEvidenceFile.currentVersion,
              f.rulesVersion == ArchiveAngelScorer.rulesVersion else { return nil }
        return f
    }

    /// The rules version and grade histogram of an evidence.json scored
    /// under OLDER rules; nil when there is none (or it is current, or
    /// unreadable). One decode, off-main.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func olderRulesOffMain(_ url: URL) async -> (rulesVersion: Int, grades: [ArchiveAngelGrade: Int])? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(ArchiveAngelEvidenceFile.self, from: data),
              f.storeVersion == ArchiveAngelEvidenceFile.currentVersion,
              f.rulesVersion < ArchiveAngelScorer.rulesVersion, f.complete else { return nil }
        var grades: [ArchiveAngelGrade: Int] = [:]
        for r in f.records.values { grades[r.grade, default: 0] += 1 }
        return (f.rulesVersion, grades)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func saveOffMain(_ file: ArchiveAngelEvidenceFile, to url: URL) async -> Bool {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try AtomicFilePublish.write(try enc.encode(file), to: url, durability: .fullFsync)
            return true
        } catch {
            return false
        }
    }
}
