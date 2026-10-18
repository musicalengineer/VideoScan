// FullHashBackfillJob.swift
// "Fill In Full Hashes…" — the Media File Operation (Rick 2026-10-11): read
// every planned file in full (FullHashBackfill.swift's plan) and store its
// SHA-256 on the catalog record. Built to run overnight and survive a crash.
//
// Shape:
//   • One LANE per volume root, all lanes in parallel (a TaskGroup); inside
//     a lane, one file at a time in path order — so a spinning drive gets
//     one sequential reader, never two seeking against each other. Each read
//     also holds that volume's MediaVolumeGate, so other heavy jobs on the
//     same drive queue behind it rather than thrash it.
//   • The hash stage is CheckCopies': `BindFixityToVolumeJob.rehashOffMain`
//     (the FixityRebind full read, identity held on the opened file) and
//     `storeCheckedCopyFixity` → `storeContentFixity`, compare-and-set (the
//     record must still be at the planned path with the planned fixity, and
//     never an archive copy with its own `archiveFixity`; an Archived-stage
//     row without one takes the hash — 2026-10-17). The duplicate RE-GROUP
//     stage is not run: over
//     the whole catalog it is the full duplicate analysis, not a cheap tail
//     — Rick runs that on purpose.
//   • DURABILITY: `storeContentFixity` only sets a field — it does NOT
//     schedule a catalog save. So this job AWAITS an acknowledged save
//     (`saveCatalogAcknowledged`) every `checkpointFiles` (50) stored hashes
//     or `checkpointSeconds` (60 s) — the ticker checks the clock even while
//     every lane is inside one long file — and at the end. A crash loses at
//     most ~1 minute of hashes; those files are simply read again next run.
//     A save that is not acknowledged stops the job (nothing more is put at
//     risk) and schedules the debounced save as a retry.
//   • RESUME: a record with a valid hash is not planned, so the next run
//     continues where this one stopped. FullHashBackfillResumeMarker records
//     "started, not finished" for the launch offer.
//   • A drive that goes away mid-run: that lane stops, its remaining files
//     are counted "drive not connected", the other lanes go on. Unreadable
//     files are named (console + logs + detail), counted, skipped.
//   • Pause interrupts the current files (each restarts from byte 0 on
//     Resume; no gate is held while paused). Stop keeps every hash stored.
//
// READ-ONLY ON MEDIA: files are only opened O_RDONLY by FixityRebind. The
// only writes are the catalog's contentFixity field, catalog saves, log
// lines and the resume marker (FullHashBackfillResume.swift, in the
// catalog's folder). FullHashBackfillSensorTests reads this source.
//
// Memory: the plan (~100 bytes per file to read), every problem row (capped
// at `problemCap`), at most `sampleCap` success rows, and one fixed read
// buffer per lane inside FixityRebind — nothing grows with file size.
//
// (For Rick: `withTaskGroup` ≈ spawning N worker threads and joining them
// all before going on — except every lane's bookkeeping runs on the main
// actor, so the counters need no mutex; only the blocking reads hop off it.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore
import os

private let fullHashLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fullHashBackfill")

@MainActor
final class FullHashBackfillJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    static let title = "Fill in full hashes"
    static let sampleCap = 500
    static let problemCap = 5_000

    let id = UUID()
    let kind: MediaFileOperationKind = .fillFullHashes
    let startedAt = Date()
    private weak var model: VideoScanModel?
    private let marker: FullHashBackfillResumeMarker?

    // Seams (tests replace them; production defaults).
    /// The volume gates one file's read must hold (the Center supplies them).
    var gatesFor: @MainActor (String) -> [MediaVolumeGate] = { _ in [] }
    /// Is the drive holding this path / root connected?
    var volumeOnline: @Sendable (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }
    /// TEST SEAM: replaces the acknowledged catalog save. nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    /// The records this run may read (nil = the whole catalog). Set by the
    /// scoped start (FullHashBackfillScoped.swift — cutover B2.1: the new
    /// rows catalog.sqlite holds back until they have a whole-file hash).
    var scope: Set<UUID>?
    var checkpointFiles = 50
    var checkpointSeconds: TimeInterval = 60
    var progressLogSeconds: TimeInterval = 300
    var tickMilliseconds = 1_000

    @Published private(set) var totals = FullHashBackfillTotals()
    @Published private(set) var lanes: [FullHashBackfillLaneStatus] = []
    /// Every file (or drive) that could not be done, in the order met.
    @Published private(set) var problems: [FullHashBackfillItem] = []
    /// The first `sampleCap` files hashed.
    @Published private(set) var sample: [FullHashBackfillItem] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    private(set) var task: Task<Void, Never>?
    /// Hashes whose catalog save was ACKNOWLEDGED durable.
    private(set) var storedCount = 0
    /// Acknowledged checkpoint saves (the final one included).
    private(set) var saveCount = 0
    private(set) var saveFailed = false

    private var unsaved = 0
    private var saving = false
    private var stopRequested = false
    private var lastSave = Date()
    private var lastProgressLog = Date()
    private var runStart = Date()
    private var controls: [String: FixityRebind.Control] = [:]
    /// Volume root → the file its lane is reading now.
    private var reading: [String: String] = [:]
    private var laneIndex: [String: Int] = [:]
    private var rowID = 0

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }
    var detailView: AnyView { AnyView(FullHashBackfillDetailView(job: self)) }

    init(model: VideoScanModel, marker: FullHashBackfillResumeMarker? = nil) {
        self.model = model
        self.marker = marker
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

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        stopRequested = true
        for c in controls.values { c.requestStop() }
        subtitleText = "Stopping — saving the hashes made so far…"
        task?.cancel()
    }

    /// Pause interrupts every lane's current file (it restarts from byte 0
    /// on Resume); no disk slot is held while paused.
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        for c in controls.values { c.setPaused(true) }
        subtitleText = "Paused — \(totals.done.formatted()) of \(totals.planned.formatted()) done; the current files restart on Resume"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        for c in controls.values { c.setPaused(false) }
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { stopRequested || !state.isActive || state == .cancelling }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        guard !model.isReadOnly else {
            wasRefused = true
            model.fullHashBackfillNote("refused — this Mac is a read-only viewer of the catalog. Nothing was read or changed.")
            finish(failed: "The catalog is read-only on this Mac — nothing was read or changed.")
            return
        }
        let plan = FullHashBackfillPlanner.plan(records: scope.map { ids in model.records.filter { ids.contains($0.id) } } ?? model.records)
        let split = await splitByConnection(plan.lanes)
        seed(plan, online: split.online, offline: split.offline)
        marker?.attach(catalogFile: model.catalogStore.fileLocation)
        marker?.noteStarted()
        model.fullHashBackfillNote("START — " + startClause(plan, online: split.online, offline: split.offline))
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

    /// Which drives are here — asked once per drive, off the main actor
    /// (a sleeping drive can make even a mount-table probe slow).
    private func splitByConnection(_ all: [FullHashBackfillLane]) async
        -> (online: [FullHashBackfillLane], offline: [FullHashBackfillLane]) {
        var online: [FullHashBackfillLane] = []
        var offline: [FullHashBackfillLane] = []
        for lane in all {
            if await rootIsOnline(lane.root) { online.append(lane) } else { offline.append(lane) }
        }
        return (online, offline)
    }

    private func rootIsOnline(_ root: String) async -> Bool {
        let probe = volumeOnline
        return await CheckCopiesJob.offMain { probe(root) }
    }

    private func seed(_ plan: FullHashBackfillPlan, online: [FullHashBackfillLane], offline: [FullHashBackfillLane]) {
        totals.planned = online.reduce(0) { $0 + $1.items.count }
        totals.plannedBytes = online.reduce(Int64(0)) { $0 + $1.bytes }
        totals.alreadyHashed = plan.alreadyHashed
        totals.archivedLeftAlone = plan.archivedLeftAlone
        for lane in offline {
            totals.counts[.driveNotConnected, default: 0] += lane.items.count
            lanes.append(FullHashBackfillLaneStatus(root: lane.root, label: lane.label, planned: lane.items.count,
                                                    phase: .disconnected))
            addProblem(filename: lane.label, path: lane.root, drive: lane.label, .driveNotConnected,
                       "drive not connected — its \(lane.items.count.formatted()) file(s) wait for a run with it connected")
        }
        for lane in online {
            controls[lane.root] = FixityRebind.Control()
            laneIndex[lane.root] = lanes.count
            lanes.append(FullHashBackfillLaneStatus(root: lane.root, label: lane.label, planned: lane.items.count))
        }
    }

    private func startClause(_ plan: FullHashBackfillPlan, online: [FullHashBackfillLane],
                             offline: [FullHashBackfillLane]) -> String {
        let away = offline.reduce(0) { $0 + $1.items.count }
        var line = "\(totals.planned.formatted()) file(s) to hash in full (\(MediaBytes.display(totals.plannedBytes))) "
            + "on \(online.count) drive(s), one reader per drive; \(plan.alreadyHashed.formatted()) already have a full hash"
        if plan.archivedLeftAlone > 0 { line += "; \(plan.archivedLeftAlone.formatted()) archived, left alone" }
        if away > 0 { line += "; \(away.formatted()) on \(offline.count) drive(s) not connected" }
        return line + ". Read only on media: nothing is moved, renamed, deleted or written."
    }

    // MARK: Lanes

    private func runLane(_ lane: FullHashBackfillLane, model: VideoScanModel) async {
        guard let control = controls[lane.root] else { return }
        setPhase(lane.root, .reading)
        for (i, item) in lane.items.enumerated() {
            guard let outcome = await readOne(item, root: lane.root, control: control) else {
                setPhase(lane.root, .stopped)
                return
            }
            if FullHashBackfillResult(failure: outcome) != nil, !(await rootIsOnline(lane.root)) {
                driveLeft(lane, from: i, model: model)
                return
            }
            record(outcome, for: item, lane: lane, model: model)
            await checkpointIfDue(model: model)
        }
        setPhase(lane.root, .finished)
    }

    /// One file: wait out a pause, hold the drive's gate, read it in full.
    /// A paused read restarts the file. nil when stopped.
    private func readOne(_ item: CheckCopiesItem, root: String,
                         control: FixityRebind.Control) async -> FixityRebind.Outcome? {
        while true {
            guard await waitOutPause(), let held = await acquireGates(for: item.path) else { return nil }
            reading[root] = (item.path as NSString).lastPathComponent
            let outcome = await BindFixityToVolumeJob.rehashOffMain(path: item.path, control: control)
            reading[root] = nil
            await releaseGates(held)
            guard outcome == .interrupted else { return outcome }
            if stopped { return nil }
        }
    }

    private func waitOutPause() async -> Bool {
        while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
        return !stopped
    }

    /// The drive went away: this lane stops; the file just tried and every
    /// one after it count as "drive not connected". Other lanes go on.
    private func driveLeft(_ lane: FullHashBackfillLane, from i: Int, model: VideoScanModel) {
        let rest = lane.items[i...]
        totals.add(.driveNotConnected, files: rest.count, bytes: rest.reduce(Int64(0)) { $0 + $1.sizeBytes })
        bumpLane(lane.root, by: rest.count)
        setPhase(lane.root, .disconnected)
        let why = "the drive went away after \(i.formatted()) file(s) — the \(rest.count.formatted()) left are read on the next run"
        addProblem(filename: lane.label, path: lane.root, drive: lane.label, .driveNotConnected, why)
        model.fullHashBackfillNote("drive \(lane.label): \(why)")
    }

    // MARK: Tally

    private func record(_ outcome: FixityRebind.Outcome, for item: CheckCopiesItem,
                        lane: FullHashBackfillLane, model: VideoScanModel) {
        bumpLane(lane.root, by: 1)
        let name = (item.path as NSString).lastPathComponent
        if case .bound(let fixity) = outcome {
            totals.readBytes += fixity.byteCount
            guard model.storeCheckedCopyFixity(item, fixity: fixity) else {
                totals.add(.recordChanged, bytes: item.sizeBytes)
                addProblem(filename: name, path: item.path, drive: lane.label, .recordChanged,
                           "moved, rescanned or changed in the catalog during the run — not written; the next run reads it again")
                return
            }
            totals.add(.hashed, bytes: item.sizeBytes)
            totals.hashedBytes += fixity.byteCount
            unsaved += 1
            addSample(filename: name, path: item.path, drive: lane.label,
                      "SHA-256 \(fixity.digest.prefix(12))… · \(MediaBytes.display(fixity.byteCount))")
            return
        }
        guard let result = FullHashBackfillResult(failure: outcome) else { return }
        totals.add(result, bytes: item.sizeBytes)
        let why = FullHashBackfillResult.detail(for: outcome)
        addProblem(filename: name, path: item.path, drive: lane.label, result, why)
        if result == .unreadable || result == .changedDuringRead {
            model.fullHashBackfillNote("\(result.words): \(item.path) — \(why)")
        }
    }

    private func addProblem(filename: String, path: String, drive: String,
                            _ result: FullHashBackfillResult, _ detail: String) {
        rowID += 1
        guard problems.count < Self.problemCap else { return }
        problems.append(FullHashBackfillItem(id: rowID, filename: filename, path: path, drive: drive,
                                             result: result, detail: detail))
    }

    private func addSample(filename: String, path: String, drive: String, _ detail: String) {
        rowID += 1
        guard sample.count < Self.sampleCap else { return }
        sample.append(FullHashBackfillItem(id: rowID, filename: filename, path: path, drive: drive,
                                           result: .hashed, detail: detail))
    }

    private func setPhase(_ root: String, _ phase: FullHashBackfillLaneStatus.Phase) {
        guard let i = laneIndex[root] else { return }
        lanes[i].phase = phase
    }

    private func bumpLane(_ root: String, by n: Int) {
        guard let i = laneIndex[root] else { return }
        lanes[i].done += n
    }

    // MARK: Progress ticker

    /// Once a second: the bar, the subtitle, the 60 s save checkpoint (so a
    /// lane deep inside one huge file still has its earlier hashes saved),
    /// and a progress line to the logs every `progressLogSeconds`.
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
        let inFlight = reading.keys.reduce(Int64(0)) { $0 + (controls[$1]?.bytesRead ?? 0) }
        fractionValue = min(1, Double(totals.doneBytes + inFlight) / Double(max(totals.plannedBytes, 1)))
        guard state == .running, !isPausedValue else { return }
        subtitleText = totals.progressLine(reading: reading.values.sorted(), lanesActive: reading.count,
                                           inFlight: inFlight, elapsed: Date().timeIntervalSince(runStart))
    }

    private func logProgressIfDue(model: VideoScanModel) {
        guard Date().timeIntervalSince(lastProgressLog) >= progressLogSeconds else { return }
        lastProgressLog = Date()
        model.fullHashBackfillNote("progress — \(subtitleText) · \(storedCount.formatted()) saved")
    }

    // MARK: Saving

    private func checkpointIfDue(model: VideoScanModel) async {
        guard unsaved > 0, !saving, !saveFailed else { return }
        guard unsaved >= checkpointFiles || Date().timeIntervalSince(lastSave) >= checkpointSeconds else { return }
        await persist(model: model)
    }

    /// Await an ACKNOWLEDGED durable save of the hashes stored since the
    /// last one. True when there was nothing to save or it is on disk.
    /// A failure stops the job: nothing more is read while saves fail.
    @discardableResult
    private func persist(model: VideoScanModel) async -> Bool {
        guard unsaved > 0, !saving, !saveFailed else { return !saveFailed }
        saving = true
        defer { saving = false }
        let n = unsaved
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        guard ok else {
            saveFailed = true
            model.saveCatalogDebounced()
            model.fullHashBackfillNote("the catalog save was NOT confirmed — stopping so no more work is at risk; "
                + "\(unsaved.formatted()) hash(es) stay in memory and go out with the next successful save")
            stopRequested = true
            for c in controls.values { c.requestStop() }
            return false
        }
        unsaved -= n
        storedCount += n
        saveCount += 1
        lastSave = Date()
        marker?.noteSaved(hashedSoFar: storedCount)
        return true
    }

    // MARK: Finish

    private func conclude(model: VideoScanModel) async {
        await persist(model: model)
        let line = totals.line
        if saveFailed {
            let message = "Stopped — the catalog could not be saved. \(storedCount.formatted()) hash(es) saved earlier are kept; no media was changed. " + line
            model.fullHashBackfillNote("OUTCOME — " + message)
            marker?.noteUnfinished()
            finish(failed: message)
        } else if stopped {
            model.fullHashBackfillNote("OUTCOME stopped at \(totals.done.formatted()) of \(totals.planned.formatted()) — " + line)
            marker?.noteUnfinished()
            finish(cancelled: ())
        } else {
            model.fullHashBackfillNote("OUTCOME — " + line)
            marker?.noteFinished(hashed: storedCount)
            finish(success: line)
        }
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isPausedValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        isPausedValue = false
        fullHashLog.warning("fill in full hashes failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped — \(storedCount.formatted()) hash(es) saved to the catalog are kept; run again to continue"
        isPausedValue = false
    }

    // MARK: Gates

    private func acquireGates(for path: String) async -> [(MediaVolumeGate, PausableGatePermit)]? {
        var held: [(MediaVolumeGate, PausableGatePermit)] = []
        for gate in gatesFor(path) {
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do { try await permit.acquire() } catch {
                await releaseGates(held)
                return nil
            }
            held.append((gate, permit))
            VolumeGateBoard.shared.claim(root: gate.root, jobID: id, name: Self.title)
        }
        if stopped {
            await releaseGates(held)
            return nil
        }
        return held
    }

    private func releaseGates(_ held: [(MediaVolumeGate, PausableGatePermit)]) async {
        for (gate, permit) in held.reversed() {
            await permit.close()
            VolumeGateBoard.shared.clear(root: gate.root, jobID: id)
        }
    }
}

// MARK: - Model half

extension VideoScanModel {
    /// The one sink: console + catalog.log, videoscan.log, unified log.
    func fullHashBackfillNote(_ line: String) {
        log("Fill in full hashes: " + line)
        appLog.write("[full-hashes] " + line)
        fullHashLog.notice("\(line, privacy: .public)")
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start "Fill In Full Hashes" over the whole catalog. One run at a
    /// time — a second request is refused (nothing started).
    @discardableResult
    func startFullHashBackfill(model: VideoScanModel, marker: FullHashBackfillResumeMarker?) -> FullHashBackfillJob {
        let job = FullHashBackfillJob(model: model, marker: marker)
        job.gatesFor = { [weak self] path in self?.gatePlan(forPaths: [path]) ?? [] }
        let busy = jobs.contains { $0.state.isActive && $0 is FullHashBackfillJob }
        guard add(job) else { return job }
        if busy {
            job.refuseToStart(reason: "Fill In Full Hashes is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "hash in full every catalog file without a valid full hash, one reader per drive — read only on media"))
        return job
    }
}
