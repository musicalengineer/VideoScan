// ArchiveAngelPlan.swift
// Archive Angel — the batch plan (docs/archive_angel_design.md §5–§6).
//
// `plan.json` in the batch folder is the SOURCE OF TRUTH for Stage 2: the
// candidates, their scores and why-lines, every preparation step's outcome
// and output path, and the user's edits (name, date, selected, notes). It is
// rewritten atomically after every step so a crash or quit mid-batch
// resumes where it stopped and a ready batch survives until reviewed.
//
// Originals are NEVER copied into the buffer — only companions are. The
// Promote job copies originals source → archive at approval time.

import Foundation

struct ArchiveAngelPlan: Codable, Sendable, Identifiable, Equatable {

    enum Status: String, Codable, Sendable {
        case preparing      // Stage 1 running (or interrupted — resumable)
        case ready          // Stage 1 done; waiting for review
        case promoting      // user pressed Promote; Promote job in flight
        case promoted       // done; report in `report`
        case discarded      // user discarded the batch
    }

    enum StepKind: String, Codable, Sendable, CaseIterable {
        case verifyAudio
        case balanceAudio
        case accessCopy
        case losslessCopy
        var label: String {
            switch self {
            case .verifyAudio: return "Verify audio"
            case .balanceAudio: return "Balanced audio"
            case .accessCopy: return "Access copy"
            case .losslessCopy: return "Lossless copy"
            }
        }
    }

    enum StepState: String, Codable, Sendable {
        case pending
        case done
        case skipped        // deliberately not needed — `note` says why
        case failed         // degrade, never block — `note` says why
    }

    struct StepOutcome: Codable, Sendable, Equatable, Identifiable {
        var kind: StepKind
        var state: StepState = .pending
        var note: String = ""
        /// Companion file in the buffer (relative to the batch folder).
        var outputRelPath: String?
        /// Catalog record of the companion (Transcode/Balance jobs catalog
        /// their outputs; Promote only accepts catalog record IDs).
        var recordID: UUID?
        var id: StepKind { kind }
    }

    enum EntryStatus: String, Codable, Sendable {
        case pending
        case preparing
        case ready
        case promoted
        case failed
    }

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        /// Catalog record id of the ORIGINAL.
        var id: UUID
        var sourcePath: String
        var filename: String
        var sizeBytes: Int64
        /// Identity captured at preparation; Promote re-checks all three and
        /// refuses the row if the source changed underneath (codex #1239 g1).
        var sourceContentHash: String = ""
        var sourceModifiedAt: Date?
        var durationSeconds: Double
        var score: Int
        var evidence: [ArchiveAngelEvidence]
        /// Archive filename proposed by the naming rule; user-editable.
        var proposedName: String
        /// "YYYY", "YYYY-MM" or "YYYY-MM-DD"; nil = undated. User-editable;
        /// drives the decade/year folder at Promote time.
        var proposedDate: String?
        var selected: Bool = true
        var userNotes: String = ""
        var steps: [StepOutcome] = StepKind.allCases.map { StepOutcome(kind: $0) }
        var status: EntryStatus = .pending
        /// Archive relpath of the original after Promote (nil until then).
        var promotedRelPath: String?
        var failure: String?

        var companionsMade: [StepOutcome] { steps.filter { $0.state == .done && $0.outputRelPath != nil } }
        var isOriginalOnly: Bool { status == .ready && companionsMade.isEmpty }
        func step(_ kind: StepKind) -> StepOutcome { steps.first { $0.kind == kind } ?? StepOutcome(kind: kind) }
        mutating func set(_ kind: StepKind, _ state: StepState, note: String = "", output: String? = nil) {
            if let i = steps.firstIndex(where: { $0.kind == kind }) {
                steps[i].state = state; steps[i].note = note; steps[i].outputRelPath = output
            } else {
                steps.append(StepOutcome(kind: kind, state: state, note: note, outputRelPath: output))
            }
        }
    }

    struct Report: Codable, Sendable, Equatable {
        var promotedOriginals = 0
        var accessCopies = 0
        var losslessCopies = 0
        var balancedAudio = 0
        var originalOnly: [String] = []
        var failed: [String] = []
        var summary: String {
            var s = "\(promotedOriginals) promoted (\(promotedOriginals) originals, \(accessCopies) access "
                + "\(accessCopies == 1 ? "copy" : "copies"), \(losslessCopies) lossless, \(balancedAudio) balanced audio)"
            if !originalOnly.isEmpty { s += "; \(originalOnly.count) original-only: " + originalOnly.joined(separator: ", ") }
            if !failed.isEmpty { s += "; \(failed.count) failed: " + failed.joined(separator: ", ") }
            return s
        }
    }

    var id: UUID
    var createdAt: Date
    /// Absolute path of the batch folder (buffer root / batch-<stamp>).
    var batchDir: String
    var requestedCount: Int
    var makeLossless: Bool
    var status: Status
    var entries: [Entry]
    /// Rejection reason (ArchiveAngelRejection.rawValue) → count.
    var rejected: [String: Int]
    var overflow: Int
    var consideredCount: Int
    var startedAt: Date?
    var finishedAt: Date?
    var report: Report?
    var log: [String] = []

    init(id: UUID = UUID(), createdAt: Date = Date(), batchDir: String, requestedCount: Int,
         makeLossless: Bool, entries: [Entry] = [], rejected: [String: Int] = [:],
         overflow: Int = 0, consideredCount: Int = 0) {
        self.id = id; self.createdAt = createdAt; self.batchDir = batchDir
        self.requestedCount = requestedCount; self.makeLossless = makeLossless
        self.status = .preparing; self.entries = entries; self.rejected = rejected
        self.overflow = overflow; self.consideredCount = consideredCount
    }

    static let planFilename = "plan.json"
    var planURL: URL { URL(fileURLWithPath: batchDir).appendingPathComponent(Self.planFilename) }

    var selectedEntries: [Entry] { entries.filter { $0.selected && $0.status == .ready } }
    var readyCount: Int { entries.filter { $0.status == .ready }.count }
    var rejectedTotal: Int { rejected.values.reduce(0, +) }
    var bytesToCopy: Int64 {
        selectedEntries.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Batch folder name — sortable, filesystem-safe.
    static func batchFolderName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm"
        return "batch-" + f.string(from: date)
    }
}

// MARK: - Store (atomic plan.json; list batches)

enum ArchiveAngelPlanStore {

    /// Default buffer root: the internal SSD (design §5). Rick 9/09: "we'll
    /// try with a fast ssd" — a setting can point this elsewhere.
    static var defaultBufferRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/VideoScan Buffer/ArchiveAngel", isDirectory: true)
    }

    nonisolated static func save(_ plan: ArchiveAngelPlan) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(plan)
        let dir = URL(fileURLWithPath: plan.batchDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".plan.json.tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(plan.planURL, withItemAt: tmp)
    }

    nonisolated static func load(batchDir: String) throws -> ArchiveAngelPlan {
        let url = URL(fileURLWithPath: batchDir).appendingPathComponent(ArchiveAngelPlan.planFilename)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var plan = try dec.decode(ArchiveAngelPlan.self, from: Data(contentsOf: url))
        plan.batchDir = batchDir   // the folder may have been moved
        return plan
    }

    /// Every batch under the buffer root, newest first. Unreadable plans
    /// are skipped (a half-written folder is not a batch).
    nonisolated static func listBatches(bufferRoot: URL) -> [ArchiveAngelPlan] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bufferRoot.path) else { return [] }
        return names.filter { $0.hasPrefix("batch-") }
            .compactMap { try? load(batchDir: bufferRoot.appendingPathComponent($0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Delete a batch folder (companions + plan). Used by Discard and by
    /// per-entry cleanup after a successful promote.
    nonisolated static func removeBatchFolder(_ plan: ArchiveAngelPlan) throws {
        try FileManager.default.removeItem(atPath: plan.batchDir)
    }

    nonisolated static func removeEntryFolder(_ plan: ArchiveAngelPlan, entry: ArchiveAngelPlan.Entry) {
        let dir = URL(fileURLWithPath: plan.batchDir).appendingPathComponent(entry.id.uuidString)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Free bytes on the volume holding `url`.
    nonisolated static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
