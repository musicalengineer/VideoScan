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
import os
import VideoScanCore

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
        /// Wall-clock seconds the step took (2026-09-19, the Angel testbed
        /// and journey audit). Additive: plans written before it decode nil.
        var seconds: Double?
        var id: StepKind { kind }
    }

    enum EntryStatus: String, Codable, Sendable {
        case pending
        case preparing
        case ready
        case promoted
        case failed
        /// The user pressed Skip on this row while the batch was preparing
        /// (Rick 2026-09-13: "just skip this file for this batch is fine").
        /// DISTINCT from `.failed` on purpose — "I decided against it" and
        /// "the transcode blew up" must never look alike in the plan, the
        /// icons or the summary. Scope: this batch only; nothing durable is
        /// written to the record, so a later batch may propose it again.
        case skipped

        /// Rows the preparation loop has not settled yet. A skipped row is
        /// settled — it keeps its status through an interruption.
        var isUnsettled: Bool { self == .pending || self == .preparing }

        /// A skip is only meaningful while the row is still on its way into
        /// the batch. Promoted / failed / already-skipped rows refuse it.
        var isSkippable: Bool { self == .pending || self == .preparing || self == .ready }
    }

    /// What the preparation loop does with a row when it reaches it.
    enum LoopAction: Equatable, Sendable {
        case prepare          // pending / preparing
        case passOver         // ready (resumed batch), promoted, failed
        case reclaimBuffer    // skipped — delete its companions, then go on
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
        /// True once the user typed an archive name in the sheet — a
        /// catalog rename then leaves `proposedName` alone. Optional so
        /// batches written before 2026-09-10 still decode (nil = false).
        var userEditedName: Bool?
        var userNotes: String = ""
        var steps: [StepOutcome] = StepKind.allCases.map { StepOutcome(kind: $0) }
        var status: EntryStatus = .pending
        /// Archive relpath of the original after Promote (nil until then).
        var promotedRelPath: String?
        var failure: String?
        /// When the user pressed Skip (nil = never skipped). Optional so
        /// batches written before 2026-09-13 still decode — synthesized
        /// Codable does NOT fall back to a property's default value for a
        /// missing key (≈ a C++ struct with no default-member-init: the
        /// field would simply be garbage, so Swift refuses instead).
        var skippedAt: Date?
        /// Short human line for a skipped row ("Skipped by you at 14:32 —
        /// not in this batch"). Never rendered as a failure.
        var skipNote: String?

        var companionsMade: [StepOutcome] { steps.filter { $0.state == .done && $0.outputRelPath != nil } }
        var isOriginalOnly: Bool { status == .ready && companionsMade.isEmpty }
        /// Left out of this batch for buffer space, not broken (2026-09-19).
        var isBufferShort: Bool {
            status == .failed && (failure ?? "").hasPrefix(ArchiveAngelPlan.bufferShortPrefix)
        }
        /// The ROW's skippability (Rick 2026-09-19: "can't I skip a file
        /// right off the bat?"): every status the state machine allows,
        /// plus a row waiting for buffer space — it is parked, not broken,
        /// and a decision against it needs no buffer at all.
        var isSkippable: Bool { status.isSkippable || isBufferShort }
        func step(_ kind: StepKind) -> StepOutcome { steps.first { $0.kind == kind } ?? StepOutcome(kind: kind) }
        /// The user's skip, recorded on the row. Clears `failure` — a skip
        /// is a decision, not a breakage — and leaves the step outcomes
        /// alone (the preparation loop marks the stopped step `.skipped`).
        mutating func markSkippedByUser(at when: Date = Date(), note: String) {
            status = .skipped
            skippedAt = when
            skipNote = note
            failure = nil
        }

        var loopAction: LoopAction {
            switch status {
            case .pending, .preparing: return .prepare
            case .skipped: return .reclaimBuffer
            case .ready, .promoted, .failed: return .passOver
            }
        }

        /// The original this file was exported from, by NAME ONLY
        /// (`something.vs.edit.mov` → "something"). Rick 2026-09-13 spotted
        /// a batch full of derivative exports: the scorer only rejects one
        /// when the original is IN the catalog, so these are exports whose
        /// original the catalog cannot see. Pure string work on the
        /// filename — no catalog lookup, no new plumbing.
        var derivativeOfStem: String? {
            ArchiveAngelNaming.derivativeBaseStem((filename as NSString).deletingPathExtension)
        }

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
        /// Rows the user skipped for this batch. Optional so reports written
        /// before 2026-09-13 still decode. Reported separately from `failed`
        /// — a skip is never a failure.
        var skippedByUser: [String]?
        var summary: String {
            var s = "\(promotedOriginals) promoted (\(promotedOriginals) originals, \(accessCopies) access "
                + "\(accessCopies == 1 ? "copy" : "copies"), \(losslessCopies) lossless, \(balancedAudio) balanced audio)"
            if !originalOnly.isEmpty { s += "; \(originalOnly.count) original-only: " + originalOnly.joined(separator: ", ") }
            if let skipped = skippedByUser, !skipped.isEmpty {
                s += "; \(skipped.count) skipped: " + skipped.joined(separator: ", ")
            }
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
    /// The ledger's batch id for this batch — the folder name
    /// ("batch-2026-09-19T14-02-11"), stable across saves.
    var batchID: String { (batchDir as NSString).lastPathComponent }

    var selectedEntries: [Entry] { entries.filter { $0.selected && $0.status == .ready } }
    var readyCount: Int { entries.filter { $0.status == .ready }.count }
    /// Rows the user skipped for this batch — counted, kept and shown, so
    /// Rick can "look at them later" (2026-09-13).
    var skippedCount: Int { entries.filter { $0.status == .skipped }.count }
    var skippedEntries: [Entry] { entries.filter { $0.status == .skipped } }
    /// "· 3 skipped" for a status line, or "" when nothing was skipped.
    var skippedClause: String { skippedCount > 0 ? " · \(skippedCount) skipped" : "" }

    // MARK: Buffer space (Rick 2026-09-19: "archive angel does not advance
    // files … it just shows a list"). One 42 GB tape needing 125 GB stopped
    // the whole batch at "buffer full after 0 of 10" — silently, with nine
    // files that would have fit. A file that does not fit is now left for
    // a later batch, with the numbers, and the loop goes on.

    /// Buffer bytes a file needs before preparation starts: the original
    /// plus its companions (design §5 — ×3 with a lossless copy, else ×2).
    static func bufferNeed(sizeBytes: Int64, lossless: Bool) -> Int64 {
        sizeBytes * (lossless ? 3 : 2)
    }

    static let bufferShortPrefix = "Not prepared — needs "

    /// The row's reason when it does not fit, or nil when it does.
    static func bufferShortNote(need: Int64, free: Int64) -> String? {
        guard free < need else { return nil }
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return bufferShortPrefix + "\(fmt(need)) free in the buffer, \(fmt(free)) free. "
            + "Left for a later batch once there is room; nothing was written to the catalog."
    }

    /// Rows left out for buffer space (failed with the buffer-short reason).
    var bufferShortCount: Int {
        entries.filter(\.isBufferShort).count
    }
    /// "· 2 waiting for buffer space", or "".
    var bufferShortClause: String {
        bufferShortCount > 0 ? " · \(bufferShortCount) waiting for buffer space" : ""
    }

    /// GH #177 (Rick 2026-09-10 evening): three cancelled batches stayed
    /// `preparing` forever — invisible in the Archive tab (only `ready`
    /// batches are listed) yet their rows were reserved from later batches
    /// by `inFlightRecordIDs`. Settling a batch that will not continue:
    /// rows never prepared become `failed` with the reason; rows already
    /// prepared keep the batch alive as `ready` (they are reviewable);
    /// nothing prepared → `discarded`. Returns true when the batch stays.
    ///
    /// A `.skipped` row is already settled: the user decided, so a settle
    /// leaves it exactly as it is — never converted to failed or ready
    /// (2026-09-13). Only `pending`/`preparing` rows are unsettled.
    @discardableResult
    mutating func settleAfterInterruption(reason: String) -> Bool {
        for i in entries.indices where entries[i].status.isUnsettled {
            entries[i].status = .failed
            entries[i].failure = reason
        }
        if readyCount > 0 {
            status = .ready
            log.append("Settled after interruption: \(readyCount) ready"
                       + (skippedCount > 0 ? ", \(skippedCount) skipped by you" : "")
                       + ", the rest marked failed — \(reason)")
            return true
        }
        status = .discarded
        log.append("Discarded after interruption: nothing was prepared"
                   + (skippedCount > 0 ? " (\(skippedCount) skipped by you)" : "") + " — \(reason)")
        return false
    }
    /// THE SKIP TRANSITION (Rick 2026-09-13: "just skip this file for this
    /// batch is fine. skip."). Pure and total: marks the row `.skipped`
    /// with its note, or returns nil when the row is unknown or no longer
    /// skippable. The caller (`ArchiveAngelJob.skip`) owns the side effects
    /// — cancelling that row's sub-job, reclaiming its buffer folder,
    /// saving the plan.
    ///
    /// Scope: this batch only. Nothing is written to the catalog record,
    /// so a later batch may propose the same file again.
    mutating func skipEntry(id: UUID, now: Date = Date(),
                            note: (EntryStatus, Date) -> String) -> (index: Int, previous: EntryStatus)? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let previous = entries[i].status
        guard entries[i].isSkippable else { return nil }
        entries[i].markSkippedByUser(at: now, note: note(previous, now))
        return (i, previous)
    }

    var rejectedTotal: Int { rejected.values.reduce(0, +) }
    var bytesToCopy: Int64 {
        selectedEntries.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Batch folder name — sortable, filesystem-safe. Second resolution:
    /// two starts in the same minute used to land in ONE folder.
    static func batchFolderName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "batch-" + f.string(from: date)
    }
}

// MARK: - Store (atomic plan.json; list batches)

enum ArchiveAngelPlanStore {

    /// Default buffer root: the internal SSD (design §5). Rick 9/09: "we'll
    /// try with a fast ssd" — a setting can point this elsewhere.
    static var defaultBufferRoot: URL {
        // Isolation (audit, 2026-09-19): under the test host, never Rick's
        // live buffer — a test that starts a job through the normal entry
        // point would otherwise write batches (and settle his!) there. One
        // folder per test process, like CatalogStore.shared's guard.
        if TestEnvironment.isTestHost { return testHostBufferRoot }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/VideoScan Buffer/ArchiveAngel", isDirectory: true)
    }

    nonisolated static let testHostBufferRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_angel_buffer_pid\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    nonisolated static func save(_ plan: ArchiveAngelPlan) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        // A forced reboot is the operational reality of this app's worst bug;
        // the plan is not regenerable, so pay for the device flush.
        try AtomicFilePublish.write(try enc.encode(plan), to: plan.planURL,
                                    durability: .fullFsync)
    }

    /// `save`, logging a failure instead of swallowing it (audit P2 — Rick
    /// 2026-09-19: "tests and LOGGING … for any actions"). `context` says
    /// what the save was for. Returns whether it was written.
    @discardableResult
    nonisolated static func saveLogged(_ plan: ArchiveAngelPlan, context: String,
                                       log: (String) -> Void = { appLog.write($0) }) -> Bool {
        do {
            try save(plan)
            return true
        } catch {
            log("Archive Angel: could not save plan.json for \((plan.batchDir as NSString).lastPathComponent) "
                + "(\(context)) — \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func load(batchDir: String) throws -> ArchiveAngelPlan {
        let url = URL(fileURLWithPath: batchDir).appendingPathComponent(ArchiveAngelPlan.planFilename)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var plan = try dec.decode(ArchiveAngelPlan.self, from: Data(contentsOf: url))
        plan.batchDir = batchDir   // the folder may have been moved
        return plan
    }

    /// A batch folder path under `bufferRoot` that does not exist yet:
    /// the stamped name, or `-2`, `-3`… when a start lands on a taken name.
    nonisolated static func newBatchDir(bufferRoot: URL, now: Date = Date(),
                                        fileManager fm: FileManager = .default) -> String {
        let base = ArchiveAngelPlan.batchFolderName(for: now)
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: bufferRoot.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"; n += 1
        }
        return bufferRoot.appendingPathComponent(candidate, isDirectory: true).path
    }

    /// A batch that is still `preparing` is a live job only while its
    /// plan.json keeps moving (every step rewrites it); older than
    /// `staleAfter` it is interrupted — the app quit or the job was stopped
    /// before it could settle (GH #177).
    nonisolated static func isInterrupted(_ plan: ArchiveAngelPlan, now: Date = Date(),
                                          staleAfter: TimeInterval = 3600,
                                          fileManager fm: FileManager = .default) -> Bool {
        guard plan.status == .preparing else { return false }
        // Running in this app right now: alive, however long its step.
        guard !ArchiveAngelLiveBatches.isLive(plan.batchDir) else { return false }
        let attrs = (try? fm.attributesOfItem(atPath: plan.planURL.path)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date) ?? plan.startedAt ?? plan.createdAt
        return now.timeIntervalSince(modified) > staleAfter
    }

    /// Settle every interrupted batch under the buffer root (GH #177): rows
    /// never prepared become failed, a batch with prepared rows becomes
    /// `ready` (so the Archive tab lists it), one with none is discarded
    /// and its folder removed. Returns the plans it changed. Safe to call
    /// on every Archive-tab refresh; a live job's batch is never touched.
    nonisolated static func settleInterruptedBatches(bufferRoot: URL, now: Date = Date(),
                                                     staleAfter: TimeInterval = 3600,
                                                     fileManager fm: FileManager = .default) -> [ArchiveAngelPlan] {
        var settled: [ArchiveAngelPlan] = []
        for var plan in listBatches(bufferRoot: bufferRoot) where isInterrupted(plan, now: now, staleAfter: staleAfter, fileManager: fm) {
            let unfinished = plan.entries.filter { $0.status.isUnsettled }
            let kept = plan.settleAfterInterruption(reason: "Interrupted — the app quit or the job was stopped before this row was prepared")
            saveLogged(plan, context: "settling an interrupted batch")
            if kept { reclaimUnfinished(plan, unfinished: unfinished) }
            if !kept {
                do { try removeBatchFolder(plan) } catch {
                    appLog.write("Archive Angel: could not remove the discarded batch \((plan.batchDir as NSString).lastPathComponent) — \(error.localizedDescription)")
                }
            }
            settled.append(plan)
        }
        return settled
    }

    /// Records already spoken for by another batch: every ready row in a
    /// ready or promoting plan, plus the pending/preparing rows of a plan
    /// whose job is still LIVE (plan.json moving). Promoted, failed,
    /// discarded and interrupted rows are free again (GH #177) — and so is
    /// a row the user SKIPPED (2026-09-13): a skip means "not in this
    /// batch", so the record must be free for the next one. The switch
    /// below enumerates the reserving statuses explicitly; `.skipped` is
    /// deliberately absent from every arm.
    nonisolated static func inFlightRecordIDs(bufferRoot: URL, now: Date = Date(),
                                              staleAfter: TimeInterval = 3600,
                                              fileManager fm: FileManager = .default) -> Set<UUID> {
        var ids: Set<UUID> = []
        for plan in listBatches(bufferRoot: bufferRoot) {
            switch plan.status {
            case .ready, .promoting:
                for e in plan.entries where e.status == .ready { ids.insert(e.id) }
            case .preparing:
                guard !isInterrupted(plan, now: now, staleAfter: staleAfter, fileManager: fm) else { continue }
                for e in plan.entries where e.status == .pending || e.status == .preparing || e.status == .ready {
                    ids.insert(e.id)
                }
            case .promoted, .discarded: continue
            }
        }
        return ids
    }

    /// Every readable batch under the buffer root, newest first.
    nonisolated static func listBatches(bufferRoot: URL) -> [ArchiveAngelPlan] {
        scanBatches(bufferRoot: bufferRoot).plans
    }

    /// A `batch-` folder whose plan.json cannot be read — written by a newer
    /// build, damaged, or never written (a crash right after the folder
    /// was made). Audit #7 (Rick 2026-09-19, option a): such a batch used
    /// to vanish from every list SILENTLY, with its gigabytes and its row
    /// reservations. It is now listed as unreadable, with its size, logged
    /// once, and otherwise left alone — never settled, never deleted.
    struct UnreadableBatch: Equatable, Sendable {
        let batchDir: String
        let reason: String
        let sizeBytes: Int64
    }

    /// Readable plans (newest first) and unreadable folders. `log` gets one
    /// line per unreadable folder per session (not on every refresh).
    nonisolated static func scanBatches(bufferRoot: URL,
                                        log: (String) -> Void = { appLog.write($0) })
        -> (plans: [ArchiveAngelPlan], unreadable: [UnreadableBatch]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bufferRoot.path) else { return ([], []) }
        var plans: [ArchiveAngelPlan] = []
        var unreadable: [UnreadableBatch] = []
        for name in names.sorted() where name.hasPrefix("batch-") {
            let dir = bufferRoot.appendingPathComponent(name).path
            do {
                plans.append(try load(batchDir: dir))
            } catch {
                let planPath = URL(fileURLWithPath: dir).appendingPathComponent(ArchiveAngelPlan.planFilename).path
                let reason = fm.fileExists(atPath: planPath)
                    ? "its plan.json can't be read (\(describe(error)))"
                    : "it has no plan.json"
                let batch = UnreadableBatch(batchDir: dir, reason: reason, sizeBytes: folderBytes(dir, fm: fm))
                unreadable.append(batch)
                if reportedUnreadable.withLock({ $0.insert(dir).inserted }) {
                    log("Archive Angel: batch \(name) can't be read — \(reason); "
                        + "\(ByteCountFormatter.string(fromByteCount: batch.sizeBytes, countStyle: .file)) left in place, not settled or deleted")
                }
            }
        }
        return (plans.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }

    private static let reportedUnreadable = OSAllocatedUnfairLock(initialState: Set<String>())

    private nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): return "damaged: \(c.debugDescription)"
        case DecodingError.keyNotFound(let k, _): return "missing field \(k.stringValue)"
        case DecodingError.valueNotFound(_, let c), DecodingError.typeMismatch(_, let c):
            return "unexpected value at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        default: return error.localizedDescription
        }
    }

    private nonisolated static func folderBytes(_ dir: String, fm: FileManager) -> Int64 {
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Delete a batch folder (companions + plan). Used by Discard and by
    /// per-entry cleanup after a successful promote.
    nonisolated static func removeBatchFolder(_ plan: ArchiveAngelPlan) throws {
        try FileManager.default.removeItem(atPath: plan.batchDir)
    }

    nonisolated static func removeEntryFolder(_ plan: ArchiveAngelPlan, entry: ArchiveAngelPlan.Entry,
                                              log: (String) -> Void = { appLog.write($0) }) {
        let dir = URL(fileURLWithPath: plan.batchDir).appendingPathComponent(entry.id.uuidString)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }   // nothing there: fine
        do { try FileManager.default.removeItem(at: dir) } catch {
            log("Archive Angel: could not remove the buffer folder of \(entry.filename) — \(error.localizedDescription)")
        }
    }

    /// Rows a cancel or an interruption left unfinished keep their partial
    /// companions forever once the batch survives (it has ready rows) —
    /// audit P2. They can't be promoted, so their folders go, and the space
    /// that comes back is logged. `unfinished` = the rows that were
    /// unsettled before the settle.
    nonisolated static func reclaimUnfinished(_ plan: ArchiveAngelPlan, unfinished: [ArchiveAngelPlan.Entry],
                                              log: (String) -> Void = { appLog.write($0) }) {
        guard !unfinished.isEmpty else { return }
        var bytes: Int64 = 0
        for entry in unfinished {
            bytes += folderBytes(URL(fileURLWithPath: plan.batchDir).appendingPathComponent(entry.id.uuidString).path,
                                 fm: .default)
            removeEntryFolder(plan, entry: entry, log: log)
        }
        log("Archive Angel: removed the partial files of \(unfinished.count) unfinished row(s) in "
            + "\((plan.batchDir as NSString).lastPathComponent) — \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) back")
    }

    /// Free bytes on the volume holding `url`.
    nonisolated static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}


/// The ONE writer of plan.json for the preparing job (audit P2, 2026-09-19).
/// The job saves from its loop and, on Skip or Cancel, from detached tasks;
/// those could land out of order and an OLDER snapshot overwrite a newer
/// plan. Each save carries a generation taken on the main actor when it is
/// requested; this actor writes in arrival order and drops a save older than
/// the last one written for that batch. Nothing is lost by the drop: the
/// newer save already holds the older one's change, because the plan was
/// mutated before its snapshot was taken.
actor ArchiveAngelPlanWriter {
    static let shared = ArchiveAngelPlanWriter()
    private var written: [String: UInt64] = [:]

    /// Test seam (the Angel testbed's disk-full injection): for a batch
    /// folder whose name contains `batchNameContains`, every write after
    /// the first `afterWrites` throws "out of space". Always compiled —
    /// nil in production, and Release test runs (TestDriver, the testbed)
    /// must be able to set it (codex #1570: a DEBUG-only seam made the
    /// whole-job suite uncompilable in Release).
    nonisolated(unsafe) static var injectedFailure: (batchNameContains: String, afterWrites: Int)?
    private var writesPerBatch: [String: Int] = [:]

    /// Writes unless a newer generation of this batch is already on disk.
    /// Returns false when the save was dropped as stale.
    @discardableResult
    func write(_ plan: ArchiveAngelPlan, generation: UInt64) throws -> Bool {
        let key = URL(fileURLWithPath: plan.batchDir).standardizedFileURL.path
        if let inject = Self.injectedFailure, key.contains(inject.batchNameContains) {
            writesPerBatch[key, default: 0] += 1
            if writesPerBatch[key, default: 0] > inject.afterWrites { throw CocoaError(.fileWriteOutOfSpace) }
        }
        if let last = written[key], last >= generation { return false }
        try ArchiveAngelPlanStore.save(plan)
        written[key] = generation
        return true
    }
}
