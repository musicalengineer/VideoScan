// CatalogAuditJob.swift
// "Audit Catalog…" — the Media File Operation (Rick 2026-10-15/16, tier 0;
// docs/design/catalog_status_freshness_2026_10_16.md §6): stat every live
// catalog row on a mounted drive; mark the ones whose file is gone as
// Missing; make a Missing row live again when its file is back. ~10k stats
// take seconds; it runs nightly (`--audit-catalog`) and on demand.
//
// Shape (FullHashBackfillJob's lanes, AudioFingerprintBackfillJob's
// save/undo contract):
//   • One LANE per volume root, all lanes in parallel (a TaskGroup). A lane
//     first ANCHORS its rows (off the main actor): the identity of the
//     filesystem each file is expected on (CatalogAuditMountIdentity — the
//     real mount, not the lexical root). Then it stats its rows in CHUNKS
//     (`chunkSize`) off the main actor, and applies the chunk's answers on
//     the main actor — each to the row it asked about only (same id, same
//     snapshot of the fields that matter: invariant 4).
//   • MOUNT RULE (invariant 1): a root that is not mounted at the start is
//     "not asked" — its rows are counted, never stat'ed. A chunk that found
//     anything gone re-asks the KERNEL MOUNT TABLE (no disk I/O, no cache)
//     before applying: a drive that left mid-run makes every path look gone,
//     so that lane stops and its remaining rows are "not asked".
//   • PROVE AT THE MARK (codex 2026-10-16 F1/F2): the chunk's ENOENT is the
//     cheap first pass and decides nothing. The apply step re-stats every
//     gone row SYNCHRONOUSLY just before the mark and accepts ENOENT only
//     on the SAME filesystem the lane anchored — a drive that left, a link
//     whose target moved, a file that is back, an errno: never a mark.
//   • ERRNO RULE (invariant 2): only ENOENT / ENOTDIR mean gone. Permission,
//     I/O, timeout — anything else — is "could not check", never a mark.
//   • ONE WRITER (invariant 3): marks go through `applyCatalogAudit`
//     (VideoScanModel+CatalogAudit.swift) → `stampRemoval` / `clearRemoval`.
//   • DURABILITY (invariants 3, 6): every `checkpointRows` (25) marks or
//     `checkpointSeconds` (60 s), on Stop and at the end, the job AWAITS an
//     acknowledged catalog save. A save that is not acknowledged UNDOES the
//     marks of that batch (compare-and-set by value, on the current row
//     instance), stops the job, and the run is "failed" — even if Stop was
//     pressed meanwhile (codex F5: failed > stopped > completed). A crash
//     between a mark and its save loses only in-memory marks: the catalog
//     on disk never holds a half-applied batch.
//   • STOP finishes the chunk in flight (its stats are honest), saves, and
//     the OUTCOME says "partial". Pause takes effect between chunks.
//   • Refused before any stat: read-only catalog; the shared catalog from a
//     test host.
//
// NOTHING ON MEDIA: the syscalls against a media path are `stat(2)` and,
// for the anchor, `realpath` / `lstat` / `statfs` on its FOLDER. The only
// writes are the catalog's removal markers (through the engine), catalog
// saves, log lines and `catalog-audit.json` (CatalogAuditRun.swift) in the
// catalog's folder. CatalogAuditSensorTests reads these sources.
//
// Memory: the plan (~250 bytes per live row), at most `problemCap` detail
// rows and `sampleCap` present rows, the pending batch of marks (≤ 25 + one
// chunk) and the per-folder gone tally. Nothing grows with file size.
//
// (For Rick: `withTaskGroup` ≈ spawning N worker threads and joining them —
// except every lane's bookkeeping runs on the main actor, so the counters
// and the marks need no mutex; only the anchor and stat batches hop off it.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore
import os

private let catalogAuditJobLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "auditCatalogJob")

@MainActor
final class CatalogAuditJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    static let title = "Audit catalog"
    static let sampleCap = 500
    static let problemCap = 5_000

    let id = UUID()
    let kind: MediaFileOperationKind = .auditCatalog
    let startedAt = Date()
    private weak var model: VideoScanModel?
    private let marker: CatalogAuditRunMarker?

    // Seams (tests replace them; production defaults).
    /// Is this volume root mounted right now? The default reads the kernel
    /// mount table — microseconds, no disk I/O, no cache — because a stale
    /// "still mounted" is exactly what would let an unmounted drive's rows
    /// be marked gone.
    var volumeOnline: @Sendable (String) -> Bool = { CatalogAuditJob.isMounted($0) }
    /// One stat per path, in order — the FIRST PASS only. The default is
    /// the real `stat(2)`. The second look at the mark is never a seam.
    var statPaths: @Sendable ([String]) -> [CatalogAuditStat] = { $0.map(CatalogAuditStat.of) }
    /// TEST SEAM: replaces the acknowledged catalog save. nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    var chunkSize = 256
    var checkpointRows = 25
    var checkpointSeconds: TimeInterval = 60
    var progressLogRows = 2_000
    var progressLogSeconds: TimeInterval = 60
    var tickMilliseconds = 1_000

    @Published private(set) var totals = CatalogAuditTotals()
    @Published private(set) var lanes: [CatalogAuditLaneStatus] = []
    /// Every row that was not simply present, in the order met.
    @Published private(set) var problems: [CatalogAuditRow] = []
    /// The first `sampleCap` present rows.
    @Published private(set) var sample: [CatalogAuditRow] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// Marks whose catalog save was ACKNOWLEDGED durable.
    private(set) var storedCount = 0
    /// Acknowledged checkpoint saves (the final one included).
    private(set) var saveCount = 0
    private(set) var saveFailed = false

    /// Marks written since the last acknowledged save (undone if it fails).
    private var unsavedMarks: [CatalogAuditMark] = []
    private var saving = false
    private var stopRequested = false
    private var lastSave = Date()
    private var lastProgressLog = Date()
    private var lastProgressLogDone = 0
    private var runStart = Date()
    /// Volume root → the lane is inside an anchor or stat batch now.
    private var checking: Set<String> = []
    private var laneIndex: [String: Int] = [:]
    private var rowID = 0

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }
    var detailView: AnyView { AnyView(CatalogAuditDetailView(job: self)) }

    init(model: VideoScanModel, marker: CatalogAuditRunMarker? = nil) {
        self.model = model
        self.marker = marker
    }

    /// The kernel's answer, fresh: "/" is always mounted; anything else
    /// must be in the mount table right now.
    nonisolated static func isMounted(_ root: String) -> Bool {
        root == "/" || VolumeReachability.currentMountedRoots().contains(root)
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    /// Stop: the chunk being stat'ed finishes and its answers are applied
    /// (they are honest); no new chunk starts; the marks so far are saved.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        stopRequested = true
        subtitleText = "Stopping — saving the marks made so far…"
    }

    /// Pause takes effect between chunks.
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        subtitleText = "Paused — \(totals.done.formatted()) of \(totals.planned.formatted()) checked"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { stopRequested || Task.isCancelled || !state.isActive || state == .cancelling }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        if let why = refusal(model: model) {
            wasRefused = true
            model.catalogAuditNote("refused — \(why). Nothing was checked or changed.")
            marker?.attach(catalogFile: model.catalogStore.fileLocation)
            finish(failed: "Refused — \(why). Nothing was checked or changed.")
            return
        }
        let plan = model.catalogAuditPlan()
        let split = splitByConnection(plan.lanes)
        seed(plan, online: split.online, offline: split.offline)
        marker?.attach(catalogFile: model.catalogStore.fileLocation)
        marker?.noteStarted()
        model.catalogAuditNote("START — " + startClause(plan, online: split.online, offline: split.offline))
        runStart = Date(); lastSave = Date(); lastProgressLog = Date()
        let ticker = startTicker(model: model)
        await withTaskGroup(of: Void.self) { group in
            for lane in split.online {
                group.addTask { @MainActor in await self.runLane(lane, model: model) }
            }
        }
        ticker.cancel()
        await ticker.value
        await conclude(model: model)
    }

    /// Why the job must not start, in words — nil when it may.
    private func refusal(model: VideoScanModel) -> String? {
        if model.isReadOnly { return "this Mac is a read-only viewer of the catalog" }
        if TestEnvironment.isTestHost && model.catalogStore === CatalogStore.shared {
            return "the catalog in use is the shared one and this process is a test host"
        }
        return nil
    }

    /// Which drives are here — the mount table, once per root.
    private func splitByConnection(_ all: [CatalogAuditLane]) -> (online: [CatalogAuditLane], offline: [CatalogAuditLane]) {
        var online: [CatalogAuditLane] = []
        var offline: [CatalogAuditLane] = []
        for lane in all {
            if volumeOnline(lane.root) { online.append(lane) } else { offline.append(lane) }
        }
        return (online, offline)
    }

    private func seed(_ plan: CatalogAuditPlan, online: [CatalogAuditLane], offline: [CatalogAuditLane]) {
        totals.planned = plan.rowCount
        totals.skipped = plan.skipped
        totals.missingRecheck = plan.missingRecheck
        for lane in offline {
            totals.add(.notAsked, rows: lane.items.count)
            lanes.append(CatalogAuditLaneStatus(root: lane.root, label: lane.label, planned: lane.items.count,
                                                done: lane.items.count, phase: .disconnected))
            addProblem(filename: lane.label, path: lane.root, drive: lane.label, .notAsked,
                       "drive not connected — its \(lane.items.count.formatted()) row(s) are not asked; nothing is marked")
        }
        for lane in online {
            laneIndex[lane.root] = lanes.count
            lanes.append(CatalogAuditLaneStatus(root: lane.root, label: lane.label, planned: lane.items.count))
        }
    }

    private func startClause(_ plan: CatalogAuditPlan, online: [CatalogAuditLane], offline: [CatalogAuditLane]) -> String {
        let asked = online.reduce(0) { $0 + $1.items.count }
        let away = offline.reduce(0) { $0 + $1.items.count }
        var line = "\(asked.formatted()) row(s) to check on \(online.count) drive(s)"
        if plan.missingRecheck > 0 { line += " (\(plan.missingRecheck.formatted()) marked Missing, re-checked for a return)" }
        if away > 0 { line += "; \(away.formatted()) on \(offline.count) drive(s) not connected — not asked" }
        if plan.skippedCount > 0 { line += "; \(plan.skippedCount.formatted()) skipped (\(totals.skippedWords))" }
        return line + ". One stat per row; nothing on media is opened, moved, renamed, deleted or written. "
            + "A file that is gone is marked Missing; a Missing file that is back goes live again."
    }

    // MARK: Lanes

    private func runLane(_ planned: CatalogAuditLane, model: VideoScanModel) async {
        setPhase(planned.root, .checking)
        let lane = await anchor(planned)
        var i = 0
        while i < lane.items.count {
            guard await waitOutPause() else { setPhase(lane.root, .stopped); return }
            let chunk = Array(lane.items[i..<min(i + chunkSize, lane.items.count)])
            let stats = await statChunk(chunk, root: lane.root)
            // The mount table, FRESH, before any answer lands (invariant 1):
            // an unmounted drive makes every path read ENOENT.
            if stats.contains(.gone), !volumeOnline(lane.root) {
                driveLeft(lane, from: i, model: model)
                return
            }
            for (item, stat) in zip(chunk, stats) { record(stat, for: item, lane: lane, model: model) }
            i += chunk.count
            if stopped { setPhase(lane.root, .stopped); return }
            await checkpointIfDue(model: model)
        }
        setPhase(lane.root, .finished)
    }

    /// Before the lane's first stat: which filesystem each row's file is
    /// expected on, read while the drive is (by the mount table) here. Off
    /// the main actor — a sleeping drive answers its first `realpath` slowly.
    private func anchor(_ lane: CatalogAuditLane) async -> CatalogAuditLane {
        checking.insert(lane.root)
        defer { checking.remove(lane.root) }
        var anchored = lane
        anchored.items = await Self.anchorOffMain(lane.items)
        return anchored
    }

    /// One `realpath` + `statfs` per distinct FOLDER (rows share folders;
    /// the cache is one entry per folder in the lane).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func anchorOffMain(_ items: [CatalogAuditItem]) async -> [CatalogAuditItem] {
        var byFolder: [String: CatalogAuditMountIdentity?] = [:]
        return items.map { item in
            var anchored = item
            let folder = item.directory
            if let known = byFolder[folder] {
                anchored.expectedMount = known
            } else {
                let identity = CatalogAuditMountIdentity.expected(forDirectory: folder, root: item.root)
                byFolder.updateValue(identity, forKey: folder)
                anchored.expectedMount = identity
            }
            return anchored
        }
    }

    private func statChunk(_ chunk: [CatalogAuditItem], root: String) async -> [CatalogAuditStat] {
        checking.insert(root)
        defer { checking.remove(root) }
        let paths = chunk.map(\.path)
        let probe = statPaths
        return await Self.statOffMain(paths, probe)
    }

    /// The stats, off the main actor (a sleeping drive can take a while
    /// to answer the first one).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func statOffMain(_ paths: [String],
                                        _ probe: @Sendable ([String]) -> [CatalogAuditStat]) async -> [CatalogAuditStat] {
        probe(paths)
    }

    private func waitOutPause() async -> Bool {
        while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
        return !stopped
    }

    /// The drive went away: this lane stops; the chunk just stat'ed and
    /// every row after it are "not asked" — nothing in the chunk is
    /// applied. Other lanes go on.
    private func driveLeft(_ lane: CatalogAuditLane, from i: Int, model: VideoScanModel) {
        let rest = lane.items.count - i
        totals.add(.notAsked, rows: rest)
        bumpLane(lane.root, by: rest)
        setPhase(lane.root, .disconnected)
        let why = "the drive went away after \(i.formatted()) row(s) — the \(rest.formatted()) left are not asked; nothing is marked"
        addProblem(filename: lane.label, path: lane.root, drive: lane.label, .notAsked, why)
        model.catalogAuditNote("drive \(lane.label): \(why)")
    }

    // MARK: Tally

    private func record(_ stat: CatalogAuditStat, for item: CatalogAuditItem,
                        lane: CatalogAuditLane, model: VideoScanModel) {
        bumpLane(lane.root, by: 1)
        let (apply, mark) = model.applyCatalogAudit(stat, to: item)
        totals.add(apply.result)
        if let mark { unsavedMarks.append(mark) }
        switch apply.result {
        case .present:
            addSample(item, lane: lane, apply)
        case .gone, .goneArchived:
            totals.noteGone(path: item.path)
            addProblem(filename: item.filename, path: item.path, drive: lane.label, apply.result, apply.detail)
            model.catalogAuditNote("\(apply.result.words): \(item.path)")
        case .cameBack, .changed, .couldNotCheck:
            addProblem(filename: item.filename, path: item.path, drive: lane.label, apply.result, apply.detail)
            model.catalogAuditNote("\(apply.result.words): \(item.path) — \(apply.detail)")
        case .stillMissing, .notAsked, .recordChanged:
            addProblem(filename: item.filename, path: item.path, drive: lane.label, apply.result, apply.detail)
        }
    }

    private func addProblem(filename: String, path: String, drive: String,
                            _ result: CatalogAuditResult, _ detail: String) {
        rowID += 1
        guard problems.count < Self.problemCap else { return }
        problems.append(CatalogAuditRow(id: rowID, filename: filename, path: path, drive: drive, result: result, detail: detail))
    }

    private func addSample(_ item: CatalogAuditItem, lane: CatalogAuditLane, _ apply: CatalogAuditApply) {
        rowID += 1
        guard sample.count < Self.sampleCap else { return }
        sample.append(CatalogAuditRow(id: rowID, filename: item.filename, path: item.path, drive: lane.label,
                                      result: apply.result, detail: apply.detail))
    }

    private func setPhase(_ root: String, _ phase: CatalogAuditLaneStatus.Phase) {
        guard let i = laneIndex[root] else { return }
        lanes[i].phase = phase
    }

    private func bumpLane(_ root: String, by n: Int) {
        guard let i = laneIndex[root] else { return }
        lanes[i].done += n
    }

    // MARK: Progress ticker

    /// Once a second: the bar, the subtitle, the 60 s save checkpoint and
    /// a progress line to the logs on the clock.
    private func startTicker(model: VideoScanModel) -> Task<Void, Never> {
        let interval = tickMilliseconds
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshProgress()
                await self.checkpointIfDue(model: model)
                self.logProgressIfDue(model: model)
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    private func refreshProgress() {
        fractionValue = min(1, Double(totals.done) / Double(max(totals.planned, 1)))
        guard state == .running, !isPausedValue else { return }
        let labels = checking.map { FullHashBackfillPlanner.label(forRoot: $0) }.sorted()
        subtitleText = totals.progressLine(checking: labels, elapsed: Date().timeIntervalSince(runStart))
    }

    private func logProgressIfDue(model: VideoScanModel) {
        let byCount = totals.done - lastProgressLogDone >= max(1, progressLogRows)
        let byClock = Date().timeIntervalSince(lastProgressLog) >= progressLogSeconds
        guard byCount || byClock, totals.done > lastProgressLogDone else { return }
        lastProgressLog = Date()
        lastProgressLogDone = totals.done
        model.catalogAuditNote("progress — \(subtitleText) · \(storedCount.formatted()) mark(s) saved")
    }

    // MARK: Saving

    private func checkpointIfDue(model: VideoScanModel) async {
        guard !unsavedMarks.isEmpty, !saving, !saveFailed else { return }
        guard unsavedMarks.count >= checkpointRows || Date().timeIntervalSince(lastSave) >= checkpointSeconds else { return }
        await persist(model: model)
    }

    /// Await an ACKNOWLEDGED durable save of the marks made since the last
    /// one. True when there was nothing to save or it is on disk. A failure
    /// undoes THIS batch's marks and stops the job.
    ///
    /// The batch is taken and the queue cleared BEFORE the await: lanes
    /// keep marking while the save is in flight, and those newer marks
    /// stay queued for the next checkpoint.
    @discardableResult
    private func persist(model: VideoScanModel) async -> Bool {
        guard !unsavedMarks.isEmpty, !saving, !saveFailed else { return !saveFailed }
        saving = true
        defer { saving = false }
        let batch = unsavedMarks
        unsavedMarks.removeAll()
        subtitleText = "Saving \(batch.count) mark\(batch.count == 1 ? "" : "s")…"
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        guard ok else {
            failSave(model: model, undo: batch)
            return false
        }
        storedCount += batch.count
        saveCount += 1
        lastSave = Date()
        marker?.noteSaved(totals: totals, marked: storedCount)
        model.noteCatalogRecordsMutated()
        return true
    }

    /// Undo the marks the failed save would have carried (compare-and-set,
    /// by value, on the current row instances) and stop: nothing more is
    /// put at risk. Media was never touched.
    private func failSave(model: VideoScanModel, undo: [CatalogAuditMark]) {
        var undone = 0
        for mark in undo where model.revertCatalogAuditMark(mark) { undone += 1 }
        saveFailed = true
        stopRequested = true
        model.catalogAuditNote("the catalog save was NOT confirmed — stopping so no more work is at risk; "
            + "\(undone.formatted()) of \(undo.count.formatted()) mark(s) undone (the rows are as they were); the next run asks again")
    }

    // MARK: Finish

    /// Outcome precedence: failed > stopped > completed (codex F5). A save
    /// that was not acknowledged is reported as failed even when Stop was
    /// pressed meanwhile — marks were undone and the person must know.
    private func conclude(model: VideoScanModel) async {
        await persist(model: model)
        if saveFailed, !unsavedMarks.isEmpty {
            // Chunks applied after the failed save: their marks come off too.
            for mark in unsavedMarks { _ = model.revertCatalogAuditMark(mark) }
            unsavedMarks.removeAll()
        }
        let partial = totals.done < totals.planned
        var line = totals.line
        let folders = totals.goneFoldersClause
        if !folders.isEmpty { line += " — " + folders }
        if saveFailed {
            let message = "Failed — marks undone: the catalog could not be saved, so the marks made since the last confirmed save were taken back. "
                + "\(storedCount.formatted()) mark(s) saved earlier are kept; nothing on media was changed. " + line
            model.catalogAuditNote("OUTCOME failed (partial) — " + message)
            marker?.noteFinished(.failed, totals: totals, marked: storedCount, partial: true)
            finish(failedSave: message)
        } else if stopped {
            model.catalogAuditNote("OUTCOME stopped (partial) at \(totals.done.formatted()) of \(totals.planned.formatted()) — " + line)
            marker?.noteFinished(.stopped, totals: totals, marked: storedCount, partial: true)
            finish(cancelled: ())
        } else {
            model.catalogAuditNote("OUTCOME — " + line)
            marker?.noteFinished(.completed, totals: totals, marked: storedCount, partial: partial)
            finish(success: line)
        }
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isPausedValue = false
    }

    /// A refusal or a lost model: Stop, if requested, still wins here
    /// (Rick 2026-08-26 — a requested Stop is never repainted as Failed).
    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        isPausedValue = false
        catalogAuditJobLog.warning("audit catalog failed: \(failed, privacy: .public)")
    }

    /// The one failure Stop does not soften: a save that was not
    /// acknowledged. The row, the run marker and the CLI exit all say
    /// failed, because marks were undone.
    private func finish(failedSave message: String) {
        state = .failed(message: message)
        subtitleText = message
        isPausedValue = false
        catalogAuditJobLog.warning("audit catalog failed: \(message, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped (partial) — \(storedCount.formatted()) mark(s) saved to the catalog are kept; run again for the rest"
        isPausedValue = false
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start "Audit Catalog" over the whole catalog. One run at a time —
    /// a second request is refused (nothing started).
    @discardableResult
    func startCatalogAudit(model: VideoScanModel, marker: CatalogAuditRunMarker?) -> CatalogAuditJob {
        let job = CatalogAuditJob(model: model, marker: marker)
        let busy = jobs.contains { $0.state.isActive && $0 is CatalogAuditJob }
        guard add(job) else { return job }
        if busy {
            job.refuseToStart(reason: "Audit Catalog is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "stat every live catalog row on a connected drive; mark the gone ones Missing — nothing on media is opened"))
        return job
    }
}
