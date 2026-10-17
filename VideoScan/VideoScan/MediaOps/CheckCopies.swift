// CheckCopies.swift
// "Check these copies first" — the engine half (Rick 2026-10-11). Given a
// set of record ids, prove which of them really are copies:
//
//   1. PLAN (main actor, one O(records) pass): the seed records plus every
//      candidate twin — same sampled hash + size, same head+tail hash +
//      size, or the same duplicate group. Each needs a full hash unless it
//      already carries a VALID stored one (`isUsableForVerification`: sha256,
//      stamp with ctime and volume UUID). An archive copy that an
//      `archiveFixity` already identifies is never written here — it is
//      left alone and counted. An ARCHIVED-STAGE row without one IS hashed
//      (Verify Catalog bug 1, 2026-10-17: 595 archived rows on
//      SanDiskWorkspace carried no fixity at all and were skipped by the
//      date rule — `isDateReadOnly` guards a record's DATES, Rick's
//      2026-10-11 ruling; a full hash is a probe fact about the bytes, and
//      the archive rule forbids changing name and date, not adding
//      metadata).
//   2. HASH (off the main actor, one file at a time, behind the volume gates):
//      `FixityRebind.rehash` — the existing full read with before/after
//      identity on the opened file — and the digest is stored through the
//      existing writer `storeContentFixity`, compare-and-set: only if the
//      record is still at the planned path with the fixity it had at the
//      plan. A twin whose drive is not connected is skipped and counted.
//   3. REGROUP: the EXISTING duplicate analysis, `analyzeDuplicates
//      (selectedIDs:)`, over the scope widened by the existing
//      `DuplicateDetector.affectedSubset` (whole groups, never a fragment),
//      so dispositions and keepers come from the catalog's own engine and
//      keeper policy (an offline drive is never preferred). Skipped while a
//      Delete Duplicates run or another analysis is live.
//
// NEVER MOVES MEDIA: files are only opened read-only to hash them. The only
// writes are catalog fields (contentFixity; the duplicate fields the
// analysis owns) and log lines. CheckCopiesSensorTests reads this source.
//
// Callable from any future view: `MediaFileOperationsCenter.startCheckCopies
// (recordIDs:model:)` returns the job; `await job.result()` returns the
// `CheckCopiesSummary`.
//
// Memory: the plan is O(seeds + twins) small values; the hash read uses the
// promote engine's fixed buffer (one file at a time), so the worst case does
// not grow with file size.

import Combine
import Foundation
import VideoScanCore
import os

private let checkCopiesLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "checkCopies")

// MARK: - Plan (values)

struct CheckCopiesItem: Sendable, Equatable {
    let id: UUID
    let path: String
    let sizeBytes: Int64
    /// The fixity at the plan — the compare-and-set key for the write.
    let priorFixity: ContentFixity?
}

struct CheckCopiesPlan: Sendable, Equatable {
    var toHash: [CheckCopiesItem] = []
    var seedCount = 0
    var twinCount = 0
    /// Already carry a valid stored full hash.
    var alreadyHashed = 0
    /// Archive copies an `archiveFixity` already identifies — never written.
    var archivedLeftAlone = 0
    /// Seeds + twins: what the duplicate analysis re-derives (widened later).
    var scopeIDs: Set<UUID> = []

    var plannedBytes: Int64 { toHash.reduce(Int64(0)) { $0 + $1.sizeBytes } }
}

/// Builds the plan in one pass over the catalog. Main actor (reads records).
@MainActor
enum CheckCopiesPlanner {

    static func plan(seeds: Set<UUID>, records: [VideoRecord]) -> CheckCopiesPlan {
        let active = records.filter { !$0.isPurged && !$0.isSetAside && !$0.isSuperseded }
        var byKey: [String: [VideoRecord]] = [:]
        for r in active {
            for key in twinKeys(r) { byKey[key, default: []].append(r) }
        }
        var scope: [UUID: VideoRecord] = [:]
        var plan = CheckCopiesPlan()
        for r in active where seeds.contains(r.id) {
            scope[r.id] = r
            plan.seedCount += 1
            for key in twinKeys(r) {
                for twin in byKey[key] ?? [] where scope[twin.id] == nil { scope[twin.id] = twin }
            }
        }
        plan.twinCount = scope.count - plan.seedCount
        plan.scopeIDs = Set(scope.keys)
        for r in scope.values.sorted(by: { $0.fullPath < $1.fullPath }) {
            switch need(r) {
            case .hashed: plan.alreadyHashed += 1
            case .leftAlone: plan.archivedLeftAlone += 1
            case .hash:
                plan.toHash.append(CheckCopiesItem(id: r.id, path: r.fullPath, sizeBytes: r.sizeBytes,
                                                   priorFixity: r.contentFixity))
            }
        }
        return plan
    }

    enum Need: Equatable { case hash, hashed, leftAlone }

    /// Does this record need a full read? The order is the rule: a valid
    /// stored hash → done; an `archiveFixity` (the archive's own digest of
    /// these bytes) → left alone; everything else — an Archived-stage row
    /// included — is read. The lifecycle stage never decides: the archive
    /// rule protects a record's name and date, and a hash is neither.
    static func need(_ r: VideoRecord) -> Need {
        if let f = r.contentFixity, f.isUsableForVerification { return .hashed }
        if r.archiveFixity != nil { return .leftAlone }
        return .hash
    }

    /// Keys that make two records candidate twins (namespaced).
    static func twinKeys(_ r: VideoRecord) -> [String] {
        var keys: [String] = []
        if !r.contentHash.isEmpty, r.sizeBytes > 0 { keys.append("c|\(r.contentHash)|\(r.sizeBytes)") }
        if !r.partialMD5.isEmpty, r.sizeBytes > 0 { keys.append("m|\(r.partialMD5)|\(r.sizeBytes)") }
        if let g = r.duplicateGroupID { keys.append("g|\(g.uuidString)") }
        return keys
    }
}

// MARK: - Summary

struct CheckCopiesSummary: Sendable, Equatable {
    var seeds = 0
    var twins = 0
    var planned = 0
    var hashed = 0
    var hashedBytes: Int64 = 0
    var alreadyHashed = 0
    var archivedLeftAlone = 0
    /// The file's drive is not connected — skipped.
    var driveNotConnected = 0
    /// Drive connected, file not at its path.
    var missing = 0
    var unreadable: [String] = []
    var changedDuringRead = 0
    var noVolumeIdentity = 0
    /// The record changed in the catalog during the run — not written.
    var recordChanged = 0
    /// Records the duplicate analysis re-derived (0 = not run).
    var regrouped = 0
    var regroupSkipped: String?
    var stopped = false
    var saveConfirmed = true

    var line: String {
        var parts = ["\(hashed.formatted()) of \(planned.formatted()) hashed in full (\(MediaBytes.display(hashedBytes)))",
                     "\(alreadyHashed.formatted()) already had a full hash"]
        if archivedLeftAlone > 0 { parts.append("\(archivedLeftAlone.formatted()) archived, left alone") }
        if driveNotConnected > 0 { parts.append("\(driveNotConnected.formatted()) drive not connected") }
        if missing > 0 { parts.append("\(missing.formatted()) missing at their path") }
        if !unreadable.isEmpty { parts.append("\(unreadable.count.formatted()) unreadable") }
        if changedDuringRead > 0 { parts.append("\(changedDuringRead.formatted()) changed while read") }
        if noVolumeIdentity > 0 { parts.append("\(noVolumeIdentity.formatted()) on a drive with no volume id") }
        if recordChanged > 0 { parts.append("\(recordChanged.formatted()) changed in the catalog meanwhile") }
        parts.append(regroupSkipped.map { "duplicates not re-grouped: \($0)" }
                     ?? "duplicates re-grouped over \(regrouped.formatted()) records")
        if !saveConfirmed { parts.append("catalog save NOT confirmed (it will be retried)") }
        return (stopped ? "Stopped — " : "") + parts.joined(separator: " · ")
    }
}

// MARK: - The job

@MainActor
final class CheckCopiesJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .checkCopies
    let startedAt = Date()
    let recordIDs: Set<UUID>
    private weak var model: VideoScanModel?
    private let gatesFor: @MainActor ([String]) -> [MediaVolumeGate]
    private var held: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []
    let control = FixityRebind.Control()
    /// Seam: is the drive holding `path` connected? Tests inject.
    var volumeOnline: @Sendable (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }
    /// Checkpoint: an acknowledged catalog save every this many stored hashes.
    var checkpointEvery = 25

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    private(set) var summary = CheckCopiesSummary()
    private(set) var task: Task<Void, Never>?

    var title: String { "Check copies — \(recordIDs.count.formatted()) file\(recordIDs.count == 1 ? "" : "s") and their twins" }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }

    /// `gatesFor` = the centre's gate plan for the drives the plan reads
    /// (decided once the plan is known: twins may sit on other drives).
    init(recordIDs: Set<UUID>, model: VideoScanModel,
         gatesFor: @escaping @MainActor ([String]) -> [MediaVolumeGate] = { _ in [] }) {
        self.recordIDs = recordIDs
        self.model = model
        self.gatesFor = gatesFor
    }

    /// Wait for the run and return what it found.
    func result() async -> CheckCopiesSummary {
        await task?.value
        return summary
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        state = .failed(message: reason)
        subtitleText = reason
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        control.requestStop()
        subtitleText = "Stopping — hashes already stored are kept…"
        task?.cancel()
    }

    /// Pause interrupts the current file (it restarts from byte 0 on
    /// Resume). The volume slots stay held while paused.
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        control.setPaused(true)
        subtitleText = "Paused — the current file restarts on Resume"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        control.setPaused(false)
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { Task.isCancelled || control.isStopped || !state.isActive || state == .cancelling }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        guard !model.isReadOnly else {
            wasRefused = true
            finish(failed: "The catalog is read-only on this Mac — nothing was read or changed.")
            return
        }
        let plan = CheckCopiesPlanner.plan(seeds: recordIDs, records: model.records)
        summary.seeds = plan.seedCount
        summary.twins = plan.twinCount
        summary.planned = plan.toHash.count
        summary.alreadyHashed = plan.alreadyHashed
        summary.archivedLeftAlone = plan.archivedLeftAlone
        model.checkCopiesNote("START — \(plan.seedCount.formatted()) file(s) and \(plan.twinCount.formatted()) candidate twin(s); \(plan.toHash.count.formatted()) to hash in full (\(MediaBytes.display(plan.plannedBytes))). Read only on media: nothing is moved, renamed or written.")
        if !plan.toHash.isEmpty {
            let roots = Set(plan.toHash.map { model.volumeRoot(for: $0.path) })
            guard await acquireGates(gatesFor(Array(roots).sorted())) else { await releaseGates(); finish(cancelled: model); return }
            await hashAll(plan, model: model)
            await releaseGates()
        }
        summary.saveConfirmed = await model.saveCatalogAcknowledged()
        if !summary.saveConfirmed { model.saveCatalogDebounced() }
        summary.stopped = stopped
        if !summary.stopped { await regroup(plan, model: model) }
        model.checkCopiesNote("OUTCOME — " + summary.line)
        if summary.stopped { finish(cancelled: model) } else { finish(success: summary.line) }
    }

    private func hashAll(_ plan: CheckCopiesPlan, model: VideoScanModel) async {
        let total = max(plan.plannedBytes, 1)
        let begin = Date()
        var doneBytes: Int64 = 0
        var sinceSave = 0
        for (i, item) in plan.toHash.enumerated() {
            guard let outcome = await readOne(item, index: i, count: plan.toHash.count,
                                              doneBytes: doneBytes, total: total, begin: begin) else { return }
            doneBytes += item.sizeBytes
            fractionValue = Double(doneBytes) / Double(total)
            if record(outcome, for: item, model: model) { sinceSave += 1 }
            if sinceSave >= checkpointEvery {
                sinceSave = 0
                if !(await model.saveCatalogAcknowledged()) { model.saveCatalogDebounced() }
            }
        }
    }

    /// One file: skipped when its drive is away; restarted after a pause.
    /// nil when stopped.
    private func readOne(_ item: CheckCopiesItem, index i: Int, count: Int, doneBytes: Int64,
                         total: Int64, begin: Date) async -> FixityRebind.Outcome? {
        while true {
            while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
            guard !stopped else { return nil }
            subtitleText = ArchiveLockJob.progressLine(done: i, total: count, current: (item.path as NSString).lastPathComponent,
                                                       elapsed: -begin.timeIntervalSinceNow)
            let online = volumeOnline
            let path = item.path
            if !(await Self.offMain { online(path) }) { return .offline }
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled, let self {
                    self.fractionValue = Double(doneBytes + self.control.bytesRead) / Double(total)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            let outcome = await BindFixityToVolumeJob.rehashOffMain(path: path, control: control)
            ticker.cancel()
            guard outcome == .interrupted else { return outcome }
            if stopped { return nil }
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func offMain(_ body: @Sendable () -> Bool) async -> Bool { body() }

    /// Tally one outcome; store a hash compare-and-set. True when stored.
    private func record(_ outcome: FixityRebind.Outcome, for item: CheckCopiesItem, model: VideoScanModel) -> Bool {
        switch outcome {
        case .bound(let fixity):
            guard model.storeCheckedCopyFixity(item, fixity: fixity) else {
                summary.recordChanged += 1
                return false
            }
            summary.hashed += 1
            summary.hashedBytes += fixity.byteCount
            return true
        case .offline:
            // `rehash` says offline for ENOENT; the drive was connected a
            // moment ago, so the file is missing — unless the drive just left.
            if volumeOnline(item.path) { summary.missing += 1 } else { summary.driveNotConnected += 1 }
        case .unreadable(let why):
            summary.unreadable.append(item.path)
            model.checkCopiesNote("unreadable: \(item.path) — \(why)")
        case .changedDuringRead(let why):
            summary.changedDuringRead += 1
            checkCopiesLog.notice("check copies: \(item.path, privacy: .public) — \(why, privacy: .public)")
        case .noVolumeIdentity:
            summary.noVolumeIdentity += 1
        case .interrupted:
            break
        }
        return false
    }

    /// The existing duplicate analysis over the scope's whole groups.
    private func regroup(_ plan: CheckCopiesPlan, model: VideoScanModel) async {
        if model.isDeletingDuplicates { summary.regroupSkipped = "a Delete Duplicates run is going"; return }
        if model.isAnalyzingDuplicates { summary.regroupSkipped = "a duplicate analysis is already running"; return }
        let ids = model.checkCopiesRegroupScope(plan.scopeIDs)
        guard !ids.isEmpty else { summary.regroupSkipped = "nothing to group"; return }
        subtitleText = "Grouping \(ids.count.formatted()) records with the catalog's duplicate analysis…"
        await model.analyzeDuplicates(selectedIDs: ids)
        summary.regrouped = ids.count
    }

    // MARK: Gates (one sequential reader per disk)

    private func acquireGates(_ gates: [MediaVolumeGate]) async -> Bool {
        for gate in gates {
            subtitleText = "Waiting for \(gate.label)…"
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do { try await permit.acquire() } catch { return false }
            held.append((gate, permit))
            VolumeGateBoard.shared.claim(root: gate.root, jobID: id, name: "Check copies")
        }
        return true
    }

    private func releaseGates() async {
        for entry in held.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: id)
        }
        held = []
    }

    // MARK: Finish

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isPausedValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { state = .cancelled; subtitleText = "Stopped"; return }
        state = .failed(message: failed)
        subtitleText = failed
        isPausedValue = false
    }

    private func finish(cancelled model: VideoScanModel) {
        summary.stopped = true
        state = .cancelled
        subtitleText = "Stopped — \(summary.hashed.formatted()) hash(es) stored are kept"
        isPausedValue = false
    }
}

// MARK: - Model half

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, unified log.
    func checkCopiesNote(_ line: String) {
        log("Check copies: " + line)
        appLog.write("[check-copies] " + line)
        checkCopiesLog.notice("\(line, privacy: .public)")
    }

    /// Store a fresh full hash through the existing writer — only if the
    /// record is still the one planned (same path, same fixity as at the
    /// plan). Never touches an archive copy that has its own
    /// `archiveFixity`; an Archived-stage row without one takes the hash
    /// (metadata may be added to an archived record — its name and date
    /// may not change, and `storeContentFixity` writes neither).
    func storeCheckedCopyFixity(_ item: CheckCopiesItem, fixity: ContentFixity) -> Bool {
        guard let rec = record(forID: item.id), rec.fullPath == item.path,
              rec.contentFixity == item.priorFixity, rec.archiveFixity == nil else { return false }
        return storeContentFixity(recordID: item.id, path: item.path, fixity: fixity)
    }

    /// The scope widened to whole groups by the analysis' own closure rule.
    func checkCopiesRegroupScope(_ scope: Set<UUID>) -> Set<UUID> {
        let active = pfActiveRecords(records)
        let delta = active.filter { scope.contains($0.id) }
        return Set(DuplicateDetector.affectedSubset(delta: delta, allActive: active).map(\.id))
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {

    /// Start "Check copies" for `recordIDs` as a Media File Operation.
    /// One run at a time.
    @discardableResult
    func startCheckCopies(recordIDs: Set<UUID>, model: VideoScanModel) -> CheckCopiesJob {
        let job = CheckCopiesJob(recordIDs: recordIDs, model: model,
                                 gatesFor: { [weak self] paths in self?.gatePlan(forPaths: paths) ?? [] })
        let busy = jobs.contains { $0.state.isActive && $0 is CheckCopiesJob }
        guard add(job) else { return job }
        if busy {
            job.refuseToStart(reason: "Check copies is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "hash candidate copies in full, then re-group them — read only on media"))
        return job
    }
}
