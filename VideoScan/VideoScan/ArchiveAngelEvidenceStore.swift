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

    /// Pure band from a score. Rejections are graded X by `from(record:)`.
    static func from(score: Int) -> ArchiveAngelGrade {
        switch score {
        case 100...: return .a
        case 60...99: return .b
        case 25...59: return .c
        case 1...24: return .d
        default: return .x
        }
    }

    /// The default "Archive candidates" filter = A + B.
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

    init(score: Int, lines: [ArchiveAngelEvidence], rejection: ArchiveAngelRejection?,
         useCount: Int, lastUsed: Date?, computedAt: Date) {
        self.score = score
        self.lines = lines
        self.rejection = rejection
        self.useCount = useCount
        self.lastUsed = lastUsed
        self.computedAt = computedAt
        self.grade = rejection == nil ? ArchiveAngelGrade.from(score: score) : .x
    }

    /// Scored (cleared the floor) — any of A–D.
    var isEligible: Bool { rejection == nil }
    /// In the default candidates filter (A + B).
    var isCandidate: Bool { ArchiveAngelGrade.candidateGrades.contains(grade) }

    /// "AAA grade B (72) — ★★ · Donna (confirmed) · played 14 times"
    func summary(maxLines: Int = 3) -> String {
        if let r = rejection { return "AAA excluded — " + r.rawValue }
        let why = lines.prefix(maxLines).map(\.line).joined(separator: " · ")
        let head = "AAA grade \(grade.rawValue) (\(score))"
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

    init(computedAt: Date = Date(), complete: Bool = true, considered: Int = 0,
         eligible: Int = 0, records: [UUID: ArchiveAngelEvidenceRecord] = [:]) {
        self.computedAt = computedAt
        self.complete = complete
        self.considered = considered
        self.eligible = eligible
        self.records = records
    }
}

/// Main-actor façade over the sidecar file. Reads are O(1) per record so a
/// catalog filter or an inspector line can ask freely; the file itself is
/// loaded and saved off-main.
@MainActor
final class ArchiveAngelEvidenceStore: ObservableObject {

    static let filename = "evidence.json"

    /// App Support/VideoScan/archive-angel/ — the production home.
    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan/archive-angel", isDirectory: true)
    }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    @Published private(set) var file: ArchiveAngelEvidenceFile?
    /// Grade A + B ids — the "Archive candidates" filter set. Rebuilt on
    /// every replace so the catalog filter is a Set lookup.
    @Published private(set) var candidateIDs: Set<UUID> = []

    init(directory: URL = ArchiveAngelEvidenceStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Reads (O(1))

    var computedAt: Date? { file?.computedAt }
    var isLoaded: Bool { file != nil }
    /// Grades A + B (the default filter).
    var candidateCount: Int { candidateIDs.count }
    /// Everything that cleared the floor (A–D) — what the Angel ranks over.
    var eligibleCount: Int { file?.eligible ?? 0 }
    var consideredCount: Int { file?.considered ?? 0 }

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
    }

    /// Forget everything (tests, "Rescore now" reset).
    func clear() {
        file = nil
        candidateIDs = []
    }

    /// Load from disk off-main and publish. A missing, malformed,
    /// wrong-version or old-rules file leaves the store empty
    /// (poisoned-state rule). Returns whether anything was loaded so the
    /// caller can re-score straight away instead of waiting.
    @discardableResult
    func load() async -> Bool {
        let url = fileURL
        guard let loaded = await Self.loadOffMain(url) else { return false }
        replace(with: loaded)
        return true
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

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func saveOffMain(_ file: ArchiveAngelEvidenceFile, to url: URL) async -> Bool {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(file)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".evidence.json.tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            return false
        }
    }
}
