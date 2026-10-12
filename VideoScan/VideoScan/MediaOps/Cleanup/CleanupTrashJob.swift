// CleanupTrashJob.swift
// Triage ▸ Cleanup v1 — the MOVE, as one Media File Operation
// (docs/design/cleanup_kiss_2026_10_12.md; FullHashBackfillJob's shape).
//
// Shape:
//   • ONE FROZEN SELECTION (`CleanupSelection`), made when Rick confirms:
//     the plan's extra copies and junk minus what he unticked, plus the
//     FamilyArchive junk only when the per-run tick box was on. One
//     reserved survivor per content group; no keeper is ever in it, under
//     any row or physical file (rule 2; re-filtered here, belt and braces).
//   • ONE ENGINE (rule 5): both lanes go through `deleteConfirmedJunk` — the
//     #143 Trash engine — with a per-file guard:
//       copies  authorize (main): the row and its keeper are still what was
//               planned, the keeper's drive is connected;
//               beforeRemoval (off-main): CleanupProof.verifyCopy — BOTH
//               files read in full, identity held, equal SHA-256 (rule 1);
//       junk    the Delete Junk door's own re-checks (still Confirmed Junk,
//               same catalog path, not an A/V half; still the same file on
//               disk) plus "not a reserved survivor". The tick box's files
//               ride the engine's narrow FamilyArchive waiver.
//     The engine does the gates (viewer, Master Archive tree, Read only
//     drives), the move (`MediaTrash.move`: Finder Trash only, never
//     emptied) and the stamp (`stampRemoval` → "In the Trash"; held,
//     failed, offline and cancelled rows are never stamped).
//   • OUTCOMES: every requested file gets exactly one of moved / held /
//     failed / missing / cancelled, with its reason — the row's detail, the
//     DeletionAudit lines (START / one per file / OUTCOME through the one
//     sink, `cleanupNote`) and the CSV receipt under
//     ~/Library/Logs/VideoScan/deletions/.
//   • Pause takes effect between files: the file being checked finishes,
//     then the run waits (nothing spins on a worker thread). Stop ends the
//     run: the file being checked is interrupted inside its reads and it,
//     with every file after it, is "cancelled" — nothing half-done.
//   • DURABILITY: the engine stamps a batch when the batch ends, so the run
//     goes in short batches (≤20 copies or ≤40 GB of reads; 100 junk) and
//     AWAITS an acknowledged catalog save after each. A save that is not confirmed
//     stops the run, loudly (🔴); the rest are "cancelled".
//
// No volume gate is held: the reads happen inside the engine's synchronous
// disk turn. A Fill In Full Hashes run on the same drive will contend; the
// page says to run Cleanup on its own (follow-up: the engine's RemovalStep).
//
// Memory: the frozen selection (~400 bytes per file) and one Item per file.

import Combine
import Foundation
import SwiftUI
import VideoScanCore
import os

private let cleanupLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "cleanup")

// MARK: - The frozen selection

/// Exactly what one run may move, frozen when Rick confirms.
struct CleanupSelection: Sendable, Equatable {
    let copies: [CleanupPlan.Copy]
    let junk: [CleanupFile]
    /// FamilyArchive junk — non-empty only when the tick box was on.
    let archiveJunk: [CleanupFile]
    let reservedSurvivors: Set<CleanupPhysicalID>

    /// Rule 2, enforced again on the frozen set: no row that is some
    /// group's keeper, and no file that is a reserved survivor, can be in
    /// it — whatever the plan or the ticks say.
    init(plan: CleanupPlan, unticked: Set<UUID>, includeArchiveJunk: Bool,
         includeCopies: Bool = true, includeJunk: Bool = true) {
        let reserved = plan.reservedSurvivors
        let keeperIDs = Set(plan.copies.map(\.keeper.id))
        func mayGo(_ f: CleanupFile) -> Bool {
            !unticked.contains(f.id) && !keeperIDs.contains(f.id) && !reserved.contains(CleanupPhysicalID(f.identity))
        }
        copies = includeCopies ? plan.copies.filter { mayGo($0.target) } : []
        junk = includeJunk ? plan.junk.filter(mayGo) : []
        archiveJunk = includeArchiveJunk ? plan.archiveJunk.filter(mayGo) : []
        reservedSurvivors = reserved
    }

    var allJunk: [CleanupFile] { junk + archiveJunk }
    var count: Int { copies.count + junk.count + archiveJunk.count }
    var isEmpty: Bool { copies.isEmpty && junk.isEmpty && archiveJunk.isEmpty }
    var bytes: Int64 {
        copies.reduce(Int64(0)) { $0 + $1.target.sizeBytes } + allJunk.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
    /// Bytes the proofs read: each extra copy AND its keeper, in full.
    var bytesToRead: Int64 { copies.reduce(Int64(0)) { $0 + 2 * $1.target.sizeBytes } }
}

// MARK: - Per-file outcome

struct CleanupTrashItem: Identifiable, Sendable, Equatable {
    /// The design's five words (an "offline" engine outcome is a hold).
    enum Outcome: String, Sendable, CaseIterable { case moved, held, failed, missing, cancelled }
    enum Lane: String, Sendable { case copy, junk }

    let id: UUID
    let filename: String
    let path: String
    let lane: Lane
    let outcome: Outcome
    let reason: String
    let bytes: Int64

    /// One engine outcome in the design's words. Pure.
    static func outcome(of engine: VideoScanModel.JunkFileOutcome) -> (Outcome, String) {
        switch engine {
        case .moved: return (.moved, "")
        case .held(let why) where why == CleanupProof.stoppedNote: return (.cancelled, why)
        case .held(let why): return (.held, why)
        case .failed(let error): return (.failed, "couldn't move it to the Trash: \(error.localizedDescription) — nothing was deleted")
        case .missing: return (.missing, "already gone from its drive — the catalog now says so")
        case .offline: return (.held, "its drive isn't connected — untouched")
        case .cancelled: return (.cancelled, CleanupProof.stoppedNote)
        }
    }
}

struct CleanupTrashTotals: Sendable, Equatable {
    var planned = 0
    var counts: [CleanupTrashItem.Outcome: Int] = [:]
    var bytesMoved: Int64 = 0
    var done: Int { counts.values.reduce(0, +) }

    subscript(_ o: CleanupTrashItem.Outcome) -> Int { counts[o] ?? 0 }

    mutating func add(_ item: CleanupTrashItem) {
        counts[item.outcome, default: 0] += 1
        if item.outcome == .moved { bytesMoved += item.bytes }
    }

    /// "moved 12 (40 GB selected → Trash) · held 3 · failed 0 · missing 1 · cancelled 0"
    var line: String {
        var parts = ["moved \(self[.moved].formatted()) to the Trash (\(MediaBytes.display(bytesMoved)))"]
        for o in CleanupTrashItem.Outcome.allCases where o != .moved { parts.append("\(o.rawValue) \(self[o].formatted())") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The job

@MainActor
final class CleanupTrashJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    static let itemCap = 50_000

    let id = UUID()
    let kind: MediaFileOperationKind = .cleanupTrash
    let startedAt = Date()
    let selection: CleanupSelection
    private weak var model: VideoScanModel?

    /// TEST SEAM: replaces the acknowledged catalog save. nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    /// TEST SEAM: told, off the main actor, the moment a copy's proof is
    /// about to start reading (its path) — so a test can Pause or Stop at
    /// a known point. nil in production.
    var proofStartedForTesting: (@Sendable (String) -> Void)?

    /// Every file settled, in the order it settled (capped at `itemCap`).
    @Published private(set) var items: [CleanupTrashItem] = []
    /// The same files split as the detail shows them — files that stayed
    /// (held, failed, missing, cancelled) and files that moved — kept here
    /// as each settles, so the view never filters per render (QA P3).
    @Published private(set) var stayed: [CleanupTrashItem] = []
    @Published private(set) var moved: [CleanupTrashItem] = []
    @Published private(set) var totals = CleanupTrashTotals()
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    private(set) var task: Task<Void, Never>?

    private let control = FixityRebind.Control()
    private let ledger = CleanupProofLedger()
    private var audit: DeletionAudit?
    private var current: String?
    /// Bytes the proofs have actually read so far — each read reported once
    /// by the proof, partial reads included, nothing credited for a file
    /// that was never read (codex r1 P2-5).
    var bytesRead: Int64 { ledger.bytesRead }
    private var stopRequested = false

    var title: String { "Cleanup — \(selection.count.formatted()) file(s), \(MediaBytes.display(selection.bytes))" }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }
    var detailView: AnyView { AnyView(CleanupTrashJobDetailView(job: self)) }

    /// Target id → the path of the copy that stays (the receipt's keeper column).
    private let keeperPaths: [UUID: String]

    init(model: VideoScanModel, selection: CleanupSelection) {
        self.model = model
        self.selection = selection
        keeperPaths = Dictionary(selection.copies.map { ($0.target.id, $0.keeper.path) }, uniquingKeysWith: { a, _ in a })
        totals.planned = selection.count
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        subtitleText = reason          // before the state: a state watcher reads it (P2-4)
        state = .failed(message: reason)
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        stopRequested = true
        isPausedValue = false
        control.requestStop()
        subtitleText = "Stopping — the file being checked is left where it is…"
        task?.cancel()
    }

    /// Pause takes effect BETWEEN files: the file being checked finishes
    /// (its reads are never interrupted by Pause, only by Stop), then the
    /// run waits. Nothing spins on a worker thread meanwhile (QA P3).
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        subtitleText = "Paused — \(totals.done.formatted()) of \(totals.planned.formatted()) done; the file being checked finishes, then the run waits"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { stopRequested || !state.isActive }

    private func waitOutPause() async {
        while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
    }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before Cleanup could start — nothing moved."); return }
        guard !model.isReadOnly else {
            wasRefused = true
            model.cleanupNote("refused — this Mac is a read-only viewer of the catalog. Nothing moved.")
            finish(failed: "The catalog is read-only on this Mac — nothing moved.")
            return
        }
        let audit = DeletionAudit(kind: .cleanup, verb: "Cleanup", linePrefix: "[cleanup] ",
                                  sink: { [weak model] line in model?.cleanupNote(line) })
        self.audit = audit
        audit.start(scope: scopeWords, requested: selection.count, bytes: selection.bytes)
        let ticker = startTicker()
        await runCopies(model: model)
        await runJunk(model: model)
        ticker.cancel()
        await conclude(model: model, audit: audit)
    }

    private var scopeWords: String {
        var s = "\(selection.copies.count) extra cop\(selection.copies.count == 1 ? "y" : "ies") (each read in full with the copy that stays), \(selection.junk.count) junk you marked"
        if !selection.archiveJunk.isEmpty { s += ", \(selection.archiveJunk.count) junk on FamilyArchive (ticked for this run)" }
        return s + " — Finder Trash only"
    }

    private func runCopies(model: VideoScanModel) async {
        let recs = resolve(selection.copies.map(\.target), lane: .copy, model: model)
        guard !recs.isEmpty else { return }
        let g = copyGuard(model: model)
        // Each copy costs two full reads: it and the copy that stays.
        let cost = Dictionary(selection.copies.map { ($0.target.id, 2 * $0.target.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        for batch in Self.batches(recs, maxFiles: Self.checkpointFiles, maxBytes: Self.checkpointBytes, bytes: { cost[$0.id] ?? 0 }) {
            await runFiles(batch, lane: .copy, reason: .duplicate, guard: g, model: model)
            await checkpoint(model: model)
        }
    }

    /// One file at a time through the engine, so Pause is honoured between
    /// files and Stop settles every file not reached as cancelled (the file
    /// being checked is interrupted by Stop inside its proof and settles as
    /// cancelled too). The engine's gates, move and stamp are unchanged.
    private func runFiles(_ recs: [VideoRecord], lane: CleanupTrashItem.Lane, reason: RemovalReason,
                          guard g: VideoScanModel.JunkDeletionGuard, model: VideoScanModel) async {
        for rec in recs {
            await waitOutPause()
            if stopped {
                settle(rec, .cancelled, lane: lane)
                continue
            }
            _ = await model.deleteConfirmedJunk([rec], mode: .toTrash, reason: reason, guard: g)
        }
    }

    private func runJunk(model: VideoScanModel) async {
        let files = selection.allJunk
        let recs = resolve(files, lane: .junk, model: model)
        guard !recs.isEmpty else { return }
        let g = junkGuard(files, records: recs, model: model)
        for batch in Self.batches(recs, maxFiles: Self.junkCheckpointFiles, maxBytes: .max, bytes: { _ in 0 }) {
            await runFiles(batch, lane: .junk, reason: .junk, guard: g, model: model)
            await checkpoint(model: model)
        }
    }

    // MARK: Checkpoints

    /// The engine stamps a batch's rows when the batch ends, so the run
    /// hands it short batches and AWAITS an acknowledged catalog save after
    /// each: a crash loses at most one batch's "In the Trash" marks (the
    /// files are in the Trash either way, and the receipt names them). A
    /// batch is bounded by FILES and by BYTES TO READ (QA P2-2: twenty
    /// 50 GB copies would be hours of unstamped moves): at most 20 copies
    /// or 40 GB of reads — a single copy above that is a batch of its own.
    /// Junk needs no reads, so it is bounded by files alone.
    static let checkpointFiles = 20
    static let checkpointBytes: Int64 = 40 << 30
    static let junkCheckpointFiles = 100

    /// `items` cut into batches in order: a batch closes when the next item
    /// would pass either limit; an item too big on its own is a batch of
    /// one, never dropped. Pure.
    static func batches<T>(_ items: [T], maxFiles: Int, maxBytes: Int64, bytes: (T) -> Int64) -> [[T]] {
        var out: [[T]] = []
        var batch: [T] = []
        var batchBytes: Int64 = 0
        for item in items {
            let cost = bytes(item)
            if !batch.isEmpty, batch.count >= maxFiles || batchBytes + cost > maxBytes {
                out.append(batch)
                batch = []
                batchBytes = 0
            }
            batch.append(item)
            batchBytes += cost
        }
        if !batch.isEmpty { out.append(batch) }
        return out
    }

    private var saveFailed = false

    /// One acknowledged save. A save that is not confirmed stops the run:
    /// nothing more is moved while the catalog can't record it.
    private func checkpoint(model: VideoScanModel) async {
        guard !saveFailed else { return }
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        guard !ok else { return }
        saveFailed = true
        model.saveCatalogDebounced()
        model.cleanupNote("🔴 a catalog save was NOT confirmed — stopping so nothing more moves unrecorded. "
            + "The In-the-Trash marks so far are in memory and go out with the next save; the receipt names every file moved.")
        control.requestStop()
        task?.cancel()
    }

    /// The live records for `files`; a row gone from the catalog is held
    /// here (its own outcome, never silently dropped).
    private func resolve(_ files: [CleanupFile], lane: CleanupTrashItem.Lane, model: VideoScanModel) -> [VideoRecord] {
        var recs: [VideoRecord] = []
        for f in files {
            if let rec = model.record(forID: f.id) {
                recs.append(rec)
            } else {
                let item = CleanupTrashItem(id: f.id, filename: f.filename, path: f.path, lane: lane, outcome: .held,
                                          reason: "is no longer in the catalog — nothing moved", bytes: f.sizeBytes)
                add(item, row: DeletionAuditRow(outcome: .held, originalPath: f.path, trashPath: nil, sizeBytes: f.sizeBytes,
                                                keeperPath: nil, keeperProof: nil, reason: item.reason))
            }
        }
        return recs
    }

    // MARK: Guards

    private func copyGuard(model: VideoScanModel) -> VideoScanModel.JunkDeletionGuard {
        let byID = Dictionary(selection.copies.map { ($0.target.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(selection.copies.map { ($0.target.path, $0) }, uniquingKeysWith: { first, _ in first })
        let control = control, ledger = ledger, started = proofStartedForTesting
        var g = VideoScanModel.JunkDeletionGuard(
            authorize: { [weak self, weak model] rec in
                guard let self, let model, let copy = byID[rec.id] else { return "was not in the set you confirmed — nothing moved" }
                self.current = rec.filename
                return model.cleanupCopyCatalogProblem(rec, copy: copy)
            },
            beforeRemoval: { path in
                guard let copy = byPath[path] else { return "was not in the set you confirmed — nothing moved" }
                started?(path)
                switch CleanupProof.verifyCopy(copy, control: control, onRead: { ledger.addBytes($0) }) {
                case .held(let why): return why
                case .proven(let words):
                    ledger.note(words, for: path)
                    return nil
                }
            })
        g.settled = { [weak self] rec, outcome in
            guard let self, byID[rec.id] != nil else { return }
            self.settle(rec, outcome, lane: .copy)
        }
        return g
    }

    private func junkGuard(_ files: [CleanupFile], records: [VideoRecord],
                           model: VideoScanModel) -> VideoScanModel.JunkDeletionGuard {
        let fileByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = records.compactMap { rec in
            fileByID[rec.id].map {
                VideoScanModel.JunkTrashSnapshot.Item(record: rec, path: $0.path, identity: $0.identity,
                                                      bytes: $0.sizeBytes, plan: .toMove)
            }
        }
        let frozen = FrozenJunkFiles(VideoScanModel.JunkTrashSnapshot(items: items))
        let pathByID = fileByID.mapValues(\.path)
        let reserved = selection.reservedSurvivors
        let control = control
        var g = VideoScanModel.JunkDeletionGuard(
            authorize: { [weak self, weak model] rec in
                guard let self, let model else { return "the catalog went away — nothing moved" }
                self.current = rec.filename
                return model.frozenJunkCatalogProblem(rec, frozenPath: pathByID[rec.id])
            },
            beforeRemoval: { path in
                if control.isStopped { return CleanupProof.stoppedNote }
                return CleanupProof.verifyJunk(path: path, frozen: frozen, reserved: reserved)
            })
        g.archiveVolumeJunkWaiver = Set(selection.archiveJunk.map(\.id))
        g.settled = { [weak self] rec, outcome in self?.settle(rec, outcome, lane: .junk) }
        return g
    }

    // MARK: Tally

    private func settle(_ rec: VideoRecord, _ engine: VideoScanModel.JunkFileOutcome, lane: CleanupTrashItem.Lane) {
        let keeperPath = lane == .copy ? keeperPaths[rec.id] : nil
        let (outcome, reason) = CleanupTrashItem.outcome(of: engine)
        var bytes = rec.sizeBytes
        if case .moved(let moved, _) = engine { bytes = moved }
        let item = CleanupTrashItem(id: rec.id, filename: rec.filename, path: rec.fullPath, lane: lane,
                                  outcome: outcome, reason: reason, bytes: bytes)
        var row = VideoScanModel.JunkDeletionResult.auditRow(rec, engine)
        if outcome == .cancelled { row.outcome = .cancelled; row.reason = reason }
        if outcome == .failed { row.outcome = .failed }
        row.keeperPath = keeperPath
        row.keeperProof = keeperPath == nil ? nil : ledger.proof(for: rec.fullPath)
        add(item, row: row)
    }

    private func add(_ item: CleanupTrashItem, row: DeletionAuditRow) {
        totals.add(item)
        if items.count < Self.itemCap {
            items.append(item)
            if item.outcome == .moved { moved.append(item) } else { stayed.append(item) }
        }
        audit?.record(row, id: item.id)
        if item.outcome == .held || item.outcome == .failed {
            cleanupLog.notice("\(item.outcome.rawValue, privacy: .public) \(item.path, privacy: .public) — \(item.reason, privacy: .public)")
        }
    }

    // MARK: Progress

    private func startTicker() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshProgress()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refreshProgress() {
        let inFlight = control.bytesRead
        let toRead = selection.bytesToRead
        let fileShare = Double(totals.done) / Double(max(totals.planned, 1))
        fractionValue = toRead > 0 ? min(1, Double(bytesRead + inFlight) / Double(toRead)) : fileShare
        guard state == .running, !isPausedValue else { return }
        subtitleText = Self.progressLine(done: totals.done, planned: totals.planned, current: current,
                                         read: bytesRead + inFlight, toRead: toRead,
                                         elapsed: Date().timeIntervalSince(startedAt))
    }

    /// "12 of 40 · clip.mov · 41 GB of 160 GB read · ~1 h 5 min left". Pure.
    static func progressLine(done: Int, planned: Int, current: String?, read: Int64, toRead: Int64,
                             elapsed: TimeInterval) -> String {
        var parts = ["\(done.formatted()) of \(planned.formatted())"]
        if let current { parts.append(current) }
        guard toRead > 0 else { return parts.joined(separator: " · ") }
        parts.append("\(MediaBytes.display(read)) of \(MediaBytes.display(toRead)) read")
        if elapsed > 5, read > 0 {
            let rate = Double(read) / elapsed
            parts.append(FullHashBackfillTotals.timeLeft(Double(max(0, toRead - read)) / rate))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Finish

    /// The end of the run (every batch already checkpointed): the receipt,
    /// the one summary, the terminal state. The summary is published BEFORE
    /// the terminal state, here and in every other terminal path: a watcher
    /// of `state` (the page's "Last run") reads the subtitle the moment the
    /// state lands (codex r1 P2-4).
    private func conclude(model: VideoScanModel, audit: DeletionAudit) async {
        audit.finish()
        let line = totals.line
        fractionValue = 1
        isPausedValue = false
        if saveFailed {
            finish(failed: "Stopped — a catalog save was not confirmed. " + line)
        } else if stopRequested || state == .cancelling {
            subtitleText = "Stopped — " + line
            state = .cancelled
        } else {
            subtitleText = line
            state = .finished(summary: line)
        }
    }

    private func finish(failed message: String) {
        subtitleText = message
        isPausedValue = false
        if state.cancelWasRequested {
            state = .cancelled
        } else {
            state = .failed(message: message)
        }
    }
}

// MARK: - Model half

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, unified log.
    func cleanupNote(_ line: String) {
        log("Cleanup: " + line)
        appLog.write("[cleanup] " + line)
        cleanupLog.notice("\(line, privacy: .public)")
    }

    /// The catalog half of one extra copy's re-check, at its turn (main
    /// actor): the row is still in the catalog, live, at the planned path,
    /// not half of an A/V pair; its keeper is still a live row at the
    /// planned path, on a connected drive. nil = go on to the full reads.
    func cleanupCopyCatalogProblem(_ rec: VideoRecord, copy: CleanupPlan.Copy) -> String? {
        guard record(forID: rec.id) === rec, !rec.isPurged else {
            return "is no longer in the catalog (or was already removed) — nothing moved"
        }
        guard rec.fullPath == copy.target.path else { return "was moved in the catalog after you confirmed — nothing moved" }
        if CatalogScopePolicy.isPairProtected(rec) { return Self.pairMemberHeldNote }
        guard let keeper = record(forID: copy.keeper.id), !keeper.isPurged, keeper.fullPath == copy.keeper.path else {
            return "the copy that stays is no longer in the catalog at \(copy.keeper.path) — nothing moved"
        }
        if Self.isExternalVolumePath(keeper.fullPath), !VolumeReachability.isReachable(path: keeper.fullPath) {
            let drive = copy.keeper.volumeName.isEmpty ? VolumeReachability.volumeName(forPath: keeper.fullPath) : copy.keeper.volumeName
            return "the copy that stays is on \(drive), which isn't connected — nothing moved"
        }
        return nil
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start one Cleanup run over a frozen selection. One run at a time —
    /// a second request is refused (nothing moved).
    @discardableResult
    func startCleanup(selection: CleanupSelection, model: VideoScanModel) -> CleanupTrashJob {
        let job = CleanupTrashJob(model: model, selection: selection)
        let busy = jobs.contains { $0.state.isActive && $0 is CleanupTrashJob }
        guard add(job) else {
            // The centre refuses on a viewer Mac: say so on the job, so a
            // page watching its state is released (it never ran).
            job.refuseToStart(reason: "this Mac is a read-only viewer of the catalog — nothing moved.")
            return job
        }
        if busy {
            job.refuseToStart(reason: "Cleanup is already running — wait for it to finish (or stop it). Nothing moved.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "\(selection.count) file(s), \(MediaBytes.display(selection.bytes)) selected — copies read in full with the copy that stays, then the Finder Trash"))
        return job
    }
}
