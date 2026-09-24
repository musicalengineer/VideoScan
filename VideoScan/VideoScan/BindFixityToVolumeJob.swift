// BindFixityToVolumeJob.swift
// "Bind Fixity to Volume" — a Media File Operation Rick starts per volume
// (2026-09-23; codex #1707). Every whole-file digest on that volume whose
// stamp predates volume UUIDs is re-read ONCE, in full, with before/after
// identity checks on the same opened file (FixityRebind), and re-stored
// with a stamp that carries the volume's persistent UUID. From then on the
// digest survives remounts: Delete Duplicates can skip a proven keeper or
// sibling, Archive Angel can lend, Find Similar Footage can say
// "Identical".
//
// Why it exists: a pre-UUID stamp names its volume by st_dev, which macOS
// reassigns on every mount and reuses across disks, so it cannot prove
// which disk produced its digest — the app now treats such a digest as
// absent (ContentFixity.swift header). Delete Duplicates and Verify
// Archive Copies re-bind the files they happen to read; this job does a
// whole volume on purpose. Nothing runs automatically at launch or mount:
// terabytes of reads are Rick's decision (it can be an overnight job).
//
// Behaviour:
//   • per-disk pacing — holds the volume's MediaVolumeGate (one sequential
//     reader on a spinning disk; other heavy jobs on it queue), one file at
//     a time; jobs on different volumes run in parallel;
//   • Pause gives the disk slot back at once (the current file is dropped
//     and restarts from byte 0 on Resume); Stop keeps every binding
//     already stored;
//   • resumable by construction — a bound record is no longer a
//     candidate, so re-running continues where the last run stopped;
//   • honest progress by bytes, with a ticker during long files;
//   • catalog writes are compare-and-set on the main actor; every 25
//     bindings (or 60 s), on Stop, on disconnect and at the end the job
//     AWAITS an acknowledged durable save (codex #1721 P2-2 — the
//     debounced save can be starved and never reports failure). Only
//     acknowledged bindings are reported "stored"; a failed save stops the
//     job, says so on the row and in the log, and leaves it resumable;
//     refused on a read-only catalog;
//   • a digest that CHANGES on the re-read is stored (it is what the file
//     holds now — the old one was unprovable) and named in the log;
//   • one START line (the Center), one summary line (console, videoscan.log,
//     os_log), and one os_log line per refused file.

import Combine
import Foundation
import VideoScanCore
import os

private let bindFixityLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "bindFixity")

@MainActor
final class BindFixityToVolumeJob: @MainActor MediaFileOperationJob {

    struct Tally: Equatable, Sendable {
        var planned = 0
        var plannedBytes: Int64 = 0
        var bound = 0
        var boundBytes: Int64 = 0
        /// Bound, but the re-read digest differs from the stored one.
        var digestChanged = 0
        var offline = 0
        var unreadable = 0
        var noVolumeIdentity = 0
        var changedDuringRead = 0
        /// The record changed under the run (rescan, other job) — skipped.
        var recordChanged = 0
        var refused: Int { offline + unreadable + noVolumeIdentity + changedDuringRead + recordChanged }
    }

    let id = UUID()
    let kind: MediaFileOperationKind = .bindFixity
    let startedAt = Date()
    let scopePath: String
    let scopeLabel: String
    private weak var model: VideoScanModel?
    private let gates: [MediaVolumeGate]
    private var heldGates: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []
    let control = FixityRebind.Control()

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to start…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    private(set) var tally = Tally()
    private(set) var summaryLine = ""
    /// The run Task — internal so tests can await it.
    private(set) var task: Task<Void, Never>?
    /// TEST SEAM: replaces the acknowledged catalog save (inject a failure,
    /// count checkpoints). nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    /// Bindings between acknowledged saves.
    var checkpointEvery = 25
    /// Bindings whose catalog save was ACKNOWLEDGED durable.
    private(set) var storedCount = 0
    /// True when an acknowledged save failed — the row and log say so.
    private(set) var saveFailed = false
    /// Bindings made in memory since the last acknowledged save.
    private var unsaved = 0
    private var lastSave = Date()

    var title: String { "Bind Fixity to Volume — \(scopeLabel)" }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }

    init(scopePath: String, scopeLabel: String, model: VideoScanModel, gates: [MediaVolumeGate] = []) {
        self.scopePath = scopePath
        self.scopeLabel = scopeLabel
        self.model = model
        self.gates = gates
    }

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
        control.requestStop()
        subtitleText = "Stopping — saving the bindings made so far…"
        task?.cancel()
    }

    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        control.setPaused(true)
        subtitleText = "Paused — the disk is free; the current file restarts on Resume"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        control.setPaused(false)
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { Task.isCancelled || control.isStopped || !state.isActive }

    // MARK: Gates

    private func acquireGates() async -> Bool {
        for gate in gates {
            subtitleText = "Waiting for \(gate.label)…"
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do { try await permit.acquire() } catch { return false }
            heldGates.append((gate, permit))
            VolumeGateBoard.shared.claim(root: gate.root, jobID: id, name: "Bind Fixity to Volume")
        }
        return true
    }

    private func releaseGates() async {
        for entry in heldGates.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: id)
        }
        heldGates = []
    }

    /// Paused: hand the disk back, wait, then re-join the queue. False when
    /// stopped meanwhile (or the slot could not be re-held).
    private func waitOutPause() async -> Bool {
        guard isPausedValue else { return !stopped }
        for entry in heldGates { await entry.permit.releaseForPause() }
        while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
        guard !stopped else { return false }
        for entry in heldGates {
            subtitleText = "Waiting for \(entry.gate.label)…"
            do { try await entry.permit.reacquireForResume() } catch { return false }
            guard await entry.permit.currentPhase == .held else { return false }
        }
        return !stopped
    }

    // MARK: Run

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func rehashOffMain(path: String, control: FixityRebind.Control) async -> FixityRebind.Outcome {
        FixityRebind.rehash(path: path, control: control)
    }

    private func run() async {
        guard let model else { finish(failed: "Lost the catalog"); return }
        guard !model.isReadOnly else {
            wasRefused = true
            finish(failed: "The catalog is read-only on this Mac — nothing was read or changed.")
            return
        }
        guard FileManager.default.fileExists(atPath: scopePath) else {
            wasRefused = true
            finish(failed: "\(scopeLabel) is not connected — reconnect it and start Bind Fixity to Volume again.")
            return
        }
        let items = model.fixityRebindCandidates(prefix: scopePath)
        tally.planned = items.count
        tally.plannedBytes = items.reduce(0) { $0 + $1.bytes }
        guard !items.isEmpty else {
            summaryLine = "Bind Fixity to Volume — \(scopeLabel): nothing to do — every stored digest here already carries its volume identity"
            model.log(summaryLine)
            finish(success: "Nothing to do — every stored digest here already carries its volume identity")
            return
        }
        let total = max(tally.plannedBytes, 1)
        bindFixityLog.notice("bind fixity \(self.scopeLabel, privacy: .public): \(items.count) file(s), \(self.tally.plannedBytes) bytes to read")
        guard await acquireGates() else { await releaseGates(); finish(cancelled: ()); return }

        var doneBytes: Int64 = 0
        for (i, item) in items.enumerated() {
            guard let outcome = await readOne(item, index: i, count: items.count, doneBytes: doneBytes, total: total)
            else { break }
            doneBytes += item.bytes
            fractionValue = Double(doneBytes) / Double(total)
            record(outcome, for: item, model: model)
            if unsaved >= checkpointEvery || (unsaved > 0 && Date().timeIntervalSince(lastSave) >= 60) {
                guard await persist(model: model) else { await failSave(model: model); return }
            }
            // The whole volume went away — not a verdict on its files.
            if outcome == .offline, !FileManager.default.fileExists(atPath: scopePath) {
                await releaseGates()
                guard await persist(model: model) else { await failSave(model: model); return }
                finishSummary(model: model, ending: "stopped — \(scopeLabel) disconnected")
                finish(failed: "\(scopeLabel) was disconnected — \(storedCount) binding(s) saved; start again when it is back")
                return
            }
        }
        await releaseGates()
        guard await persist(model: model) else { await failSave(model: model); return }
        if stopped {
            finishSummary(model: model, ending: "stopped")
            finish(cancelled: ())
            return
        }
        finishSummary(model: model, ending: "done")
        finish(success: summaryLine)
    }

    /// Await an ACKNOWLEDGED durable catalog save of the bindings made
    /// since the last one. True when there was nothing to save or the
    /// save is on disk.
    private func persist(model: VideoScanModel) async -> Bool {
        guard unsaved > 0 else { return true }
        subtitleText = "Saving the catalog (\(unsaved) new binding\(unsaved == 1 ? "" : "s"))…"
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        if ok {
            storedCount += unsaved
            unsaved = 0
            lastSave = Date()
        } else {
            saveFailed = true
        }
        return ok
    }

    /// A save was not acknowledged: stop reading, say so, stay resumable.
    private func failSave(model: VideoScanModel) async {
        await releaseGates()
        let pending = unsaved
        finishSummary(model: model, ending: "stopped — catalog save FAILED")
        let message = "The catalog could not be saved — \(pending) binding(s) are only in memory (\(storedCount) saved); "
            + "no media was changed. Stopped; start Bind Fixity to Volume again once the catalog can be saved — it resumes where it stopped."
        model.log("  ⚠️ " + message)
        bindFixityLog.error("\(message, privacy: .public)")
        finish(failed: message)
    }

    /// Read one file, restarting it after a pause (the disk slot is given
    /// back meanwhile). nil when stopped.
    private func readOne(_ item: FixityRebindItem, index i: Int, count: Int,
                         doneBytes: Int64, total: Int64) async -> FixityRebind.Outcome? {
        while true {
            guard await waitOutPause() else { return nil }
            subtitleText = "Reading \(i + 1) of \(count) — \((item.path as NSString).lastPathComponent) · "
                + "\(ByteCountFormatter.string(fromByteCount: doneBytes, countStyle: .file)) of "
                + "\(ByteCountFormatter.string(fromByteCount: tally.plannedBytes, countStyle: .file))"
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled, let self {
                    self.fractionValue = Double(doneBytes + self.control.bytesRead) / Double(total)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            let outcome = await Self.rehashOffMain(path: item.path, control: control)
            ticker.cancel()
            guard outcome == .interrupted else { return outcome }
            if stopped { return nil }               // else paused: restart this file
        }
    }

    private func record(_ outcome: FixityRebind.Outcome, for item: FixityRebindItem, model: VideoScanModel) {
        let name = (item.path as NSString).lastPathComponent
        switch outcome {
        case .bound(let fixity):
            switch model.applyFixityRebind(item, fixity: fixity) {
            case .written:
                tally.bound += 1; tally.boundBytes += fixity.byteCount; unsaved += 1
            case .digestChanged:
                tally.bound += 1; tally.boundBytes += fixity.byteCount; tally.digestChanged += 1; unsaved += 1
                bindFixityLog.warning("bind fixity: \(item.path, privacy: .public) — the re-read digest differs from the stored one (stored the new one)")
                model.log("  ⚠️ \(name): its bytes are not what was hashed before — stored the digest it holds now")
            case .recordChanged:
                tally.recordChanged += 1
                bindFixityLog.notice("bind fixity: \(item.path, privacy: .public) — record changed during the run; skipped")
            }
        case .interrupted:
            break
        case .offline:
            tally.offline += 1
            bindFixityLog.notice("bind fixity: \(item.path, privacy: .public) — not found")
        case .unreadable(let why):
            tally.unreadable += 1
            bindFixityLog.warning("bind fixity: \(item.path, privacy: .public) — unreadable: \(why, privacy: .public)")
        case .noVolumeIdentity:
            tally.noVolumeIdentity += 1
            bindFixityLog.notice("bind fixity: \(item.path, privacy: .public) — volume reports no UUID")
        case .changedDuringRead(let why):
            tally.changedDuringRead += 1
            bindFixityLog.warning("bind fixity: \(item.path, privacy: .public) — refused: \(why, privacy: .public)")
        }
    }

    private func finishSummary(model: VideoScanModel, ending: String) {
        let t = tally
        let read = ByteCountFormatter.string(fromByteCount: t.boundBytes, countStyle: .file)
        var line = saveFailed
            ? "Bind Fixity to Volume — \(scopeLabel) (\(ending)): \(t.bound.formatted()) of \(t.planned.formatted()) re-read (\(read)), "
                + "only \(storedCount.formatted()) saved to the catalog"
            : "Bind Fixity to Volume — \(scopeLabel) (\(ending)): \(storedCount.formatted()) of \(t.planned.formatted()) stored (\(read) read)"
        var notes: [String] = []
        if t.digestChanged > 0 { notes.append("\(t.digestChanged) held different bytes than before") }
        if t.changedDuringRead > 0 { notes.append("\(t.changedDuringRead) changed during the read") }
        if t.offline > 0 { notes.append("\(t.offline) not found") }
        if t.unreadable > 0 { notes.append("\(t.unreadable) unreadable") }
        if t.noVolumeIdentity > 0 { notes.append("\(t.noVolumeIdentity) on a volume with no UUID") }
        if t.recordChanged > 0 { notes.append("\(t.recordChanged) changed in the catalog meanwhile") }
        if !notes.isEmpty { line += "; " + notes.joined(separator: ", ") }
        summaryLine = line
        model.log(line)
        bindFixityLog.notice("\(line, privacy: .public)")
    }

    // MARK: Finish

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
        bindFixityLog.warning("bind fixity failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped — \(storedCount) binding(s) saved to the catalog are kept"
        isPausedValue = false
    }
}

// MARK: - Starting it

extension MediaFileOperationsCenter {
    /// Start "Bind Fixity to Volume" for one scan target / volume. One run
    /// per volume at a time (a second request for the same volume is
    /// refused — nothing started); runs on different volumes proceed in
    /// parallel, each paced by its own volume gate.
    @discardableResult
    func startBindFixityToVolume(scopePath: String, model: VideoScanModel) -> BindFixityToVolumeJob {
        let label = VolumeReachability.displayLabel(forPath: scopePath)
        let job = BindFixityToVolumeJob(scopePath: scopePath, scopeLabel: label, model: model,
                                        gates: gatePlan(forPaths: [scopePath]))
        let duplicate = jobs.contains { other in
            other.state.isActive && (other as? BindFixityToVolumeJob)?.scopePath == scopePath
        }
        guard add(job) else { return job }
        if duplicate {
            job.refuseToStart(reason: "Bind Fixity to Volume is already running for \(label) — nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "re-read every file on \(label) whose stored digest predates volume identity, in full, and re-bind it"))
        return job
    }
}
