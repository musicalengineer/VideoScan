import Combine
import Foundation
import os

// MARK: - MediaRepairJob — Repair Now as ONE Media File Operations job
//
// "Make a fixed copy of this damaged file next to it, and show me what
// changed." (Rick 2026-10-08)
//
// The row: chip "Repair" · step · "N of M" · the file · time left · bar ·
// Pause / Stop. Double-click: the plan (each fix, copied vs re-encoded),
// how it ended and why, and — after a repair — the before → after card.
// START / OUTCOME lines go through the Center's one sink.
//
// Ownership (one writer each):
//   • MediaRepairEngine writes the ONE new file (or nothing) and says how
//     it ended. This job never touches a media file itself.
//   • This job owns the row's state and, only after `.repaired`, the
//     bookkeeping: the new catalog record (derivedFrom = the original,
//     derivationKind "repair" — NOT a repair-lifecycle kind, so nothing is
//     superseded or hidden), a quick Verify of the copy, the before → after
//     comparison, and the link on the ORIGINAL's report card (additive
//     `repairedCopy`; the original's file is never written).
//
// Outcomes, each reported as what it is (never as success unless it is):
//   repaired → .finished   refused → .failed + wasRefused
//   failed   → .failed     cancelled → .cancelled (a stall → .failed)
//
// Memory: the engine's bound (< 2 MB) plus one report card (a few KB).
// Concurrency: @MainActor (≈ "every member on the UI thread"); the engine
// and the quick Verify are @concurrent, so no media work runs here.
// Volume pacing: the same per-volume gates as Verify (one slot per HDD).

private let repairJobLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "repair")

@MainActor
final class MediaRepairJob: @MainActor MediaFileOperationJob {

    /// The provenance tag on the repaired copy's record. Not in
    /// `VideoRecord.repairDerivationKinds`: a Repair Now copy is a new
    /// file beside the original, not a confirm-or-restore replacement.
    static let derivationKind = "repair"

    typealias Runner = @Sendable (MediaRepairRequest, ProcessControl, @escaping MediaRepairEngine.Progress) async -> MediaRepairOutcome
    typealias QuickVerifier = @Sendable (String, ProcessControl) async throws -> MediaReportCard

    let id = UUID()
    let kind: MediaFileOperationKind = .repair
    let startedAt = Date()
    let record: VideoRecord
    let request: MediaRepairRequest
    /// The original's card when Repair was started — the "before".
    let beforeCard: MediaReportCard?
    let besideOriginal: Bool

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to start…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPausedValue = false
    @Published private(set) var phase: MediaRepairPhase?
    @Published private(set) var outcome: MediaRepairOutcome?
    @Published private(set) var afterCard: MediaReportCard?
    @Published private(set) var comparison: MediaRepairComparison?
    private(set) var wasRefused = false

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    private weak var model: VideoScanModel?
    private let gates: [MediaVolumeGate]
    private let runner: Runner
    private let quickVerifier: QuickVerifier
    private let pauser = JobPauseCoordinator()
    private var hold: MediaVolumeGateHold?
    private var terminalCause = MFOTerminalCause()

    init(record: VideoRecord, request: MediaRepairRequest, beforeCard: MediaReportCard?,
         besideOriginal: Bool, model: VideoScanModel?, gates: [MediaVolumeGate] = [],
         runner: Runner? = nil, quickVerifier: QuickVerifier? = nil) {
        self.record = record
        self.request = request
        self.beforeCard = beforeCard
        self.besideOriginal = besideOriginal
        self.model = model
        self.gates = gates
        self.runner = runner ?? { req, control, progress in
            await MediaRepairEngine.run(req, control: control, progress: progress)
        }
        self.quickVerifier = quickVerifier ?? { path, control in
            try await MediaRepairJob.quickCard(path: path, control: control)
        }
    }

    // MARK: MediaFileOperationJob

    var title: String { record.filename }
    var subtitle: String {
        if let w = hold?.waiting { return VolumeGateBoard.describeWait(label: w.label, root: w.root) }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    let canPause = true
    var isPaused: Bool { isPausedValue }

    /// The steps this run walks, for "N of M": the plan read (repeated
    /// frames only), write, check, save, then the quick Verify of the copy.
    var steps: [String] {
        var phases = MediaRepairPhase.allCases
        if request.recipe.picture != .removeRepeatedFrames { phases.removeAll { $0 == .plan } }
        return phases.map(\.step) + [Self.verifyStep]
    }
    static let verifyStep = "verifying the repaired copy"

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Refused at the Center (e.g. a repair of this file is already running).
    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        finishRefused(reason)
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        if terminalCause.record(.cancel) {
            state = .cancelling
            subtitleText = "Stopping…"
        }
        task?.cancel()
    }

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
        hold?.lend()   // SIGSTOP first (above), THEN lend the slot
    }

    func resume() {
        guard isPausedValue else { return }
        guard let hold else {
            if pauser.resume() { isPausedValue = false }
            return
        }
        hold.reacquire { [weak self] allHeld in
            guard let self, allHeld, self.pauser.resume() else { return }
            self.isPausedValue = false
        }
    }

    // MARK: Run

    private func run() async {
        repairJobLog.info("repair START: \(self.record.filename, privacy: .public) → \(self.request.output.path, privacy: .public) [\(self.request.recipe.applied.map(\.rawValue).joined(separator: "+"), privacy: .public)]")
        let hold = MediaVolumeGateHold(jobID: id, holderName: "Repair \(record.filename)")
        self.hold = hold
        guard await hold.acquire(gates, isPaused: { [weak self] in self?.isPausedValue ?? false }) else {
            self.hold = nil
            finishCancelled()
            return
        }
        let monitor = StallMonitor(label: "repair \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in self?.handleStall(silentFor: silentFor) }
        }
        let progress: MediaRepairEngine.Progress = { [weak self] phase, fraction in
            monitor.tick()
            Task { @MainActor [weak self] in self?.apply(phase: phase, fraction: fraction) }
        }
        monitor.start()
        pauser.register(monitor)
        let result = await runner(request, pauser.control, progress)
        monitor.stop()
        await hold.close()
        self.hold = nil
        await conclude(result)
    }

    private func conclude(_ result: MediaRepairOutcome) async {
        outcome = result
        switch result {
        case .repaired(let url, let proof):
            await afterRepair(url: url, proof: proof)
        case .refused(let why):
            finishRefused(why)
        case .failed(let why, let kept):
            finish(failed: Self.failureSentence(why, keptAt: kept))
        case .cancelled:
            finishCancelled()
        }
    }

    /// Only after `.repaired`: catalogue the copy, Verify it (quick), link
    /// it on the original's card, compare. A Verify that can't run doesn't
    /// undo the repair — the copy is published and proved — it says so.
    private func afterRepair(url: URL, proof: String) async {
        setStep(steps.count - 1, fraction: 0.97)
        let copyRecord = await catalogCopy(at: url)
        var card: MediaReportCard?
        do {
            card = try await quickVerifier(url.path, pauser.control)
        } catch {
            repairJobLog.notice("repair: quick Verify of \(url.lastPathComponent, privacy: .public) couldn't run — \(error.localizedDescription, privacy: .public)")
        }
        if let card, let copyRecord {
            copyRecord.mediaReportCard = card
            afterCard = card
        }
        if let card, let beforeCard {
            comparison = MediaRepairComparison(before: beforeCard, after: card, applied: request.recipe.applied,
                                               outputName: url.lastPathComponent, besideOriginal: besideOriginal)
        }
        linkOnOriginal(copy: copyRecord, url: url)
        model?.saveCatalogDebounced()
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        let summary = Self.successSummary(comparison: comparison, outputName: url.lastPathComponent,
                                          verified: card != nil, proof: proof)
        model?.log("Repair: \(record.filename) → \(url.lastPathComponent) — \(summary). The original is untouched.")
        finish(success: summary + " The original is untouched.")
    }

    /// The new record: probed from the published file, provenance pointing
    /// at the original, the person's date / place carried over (same
    /// footage — the GH #117 convention the audio repairs follow).
    private func catalogCopy(at url: URL) async -> VideoRecord? {
        guard let model else { return nil }
        let copy = await model.probeFile(url: url)
        copy.derivedFrom = record.id
        copy.derivationKind = Self.derivationKind
        copy.userDate = record.userDate
        copy.userDateConfidence = record.userDateConfidence
        copy.userPlace = record.userPlace
        copy.userPlaceConfidence = record.userPlaceConfidence
        if let existing = model.records.firstIndex(where: { $0.fullPath == url.path }) {
            model.records[existing] = copy
        } else {
            model.records.append(copy)
        }
        model.searchIndex.update(copy)
        return copy
    }

    /// The additive link on the ORIGINAL's card (resolved by id — a rescan
    /// may have replaced the object). Writes the catalog, never the file.
    private func linkOnOriginal(copy: VideoRecord?, url: URL) {
        let original = model?.records.first { $0.id == record.id } ?? record
        guard var card = original.mediaReportCard ?? beforeCard else { return }
        card.repairedCopy = MediaRepairLink(recordID: copy?.id ?? UUID(), path: url.path, repairedAt: Date(),
                                            fixes: request.recipe.applied.map(\.rawValue))
        original.mediaReportCard = card
    }

    // MARK: Progress

    private func apply(phase: MediaRepairPhase, fraction: Double?) {
        guard state.isActive else { return }
        self.phase = phase
        let index = steps.firstIndex(of: phase.step) ?? 0
        setStep(index, fraction: phase == .write ? fraction : nil)
    }

    /// Bar: the write is most of the time (85 %); the other steps share
    /// the rest equally. `within` is the write's own fraction.
    private func setStep(_ index: Int, fraction within: Double?) {
        let overall = Self.overallFraction(steps: steps, index: index, within: within)
        if within != nil { isIndeterminateValue = false }
        if overall > fractionValue { fractionValue = min(overall, 0.99) }
        let left = CheckMediaJob.timeLeftText(elapsed: Date().timeIntervalSince(startedAt), fraction: fractionValue)
        subtitleText = "Step \(index + 1) of \(steps.count) — \(steps[index])…" + (left.map { " · \($0)" } ?? "")
    }

    static func overallFraction(steps: [String], index: Int, within: Double?) -> Double {
        let writeWeight = 0.85
        let other = (1 - writeWeight) / Double(max(steps.count - 1, 1))
        let weights = steps.map { $0 == MediaRepairPhase.write.step ? writeWeight : other }
        let done = weights.prefix(index).reduce(0, +)
        return done + weights[index] * min(1, max(0, within ?? 0))
    }

    private func handleStall(silentFor: Double) {
        guard state.isActive, terminalCause.first == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, request.output.path])
        let reason = "Stalled — no progress for \(Int(silentFor)) s while repairing. \(attribution)"
        terminalCause.record(.stall(reason: reason))
        subtitleText = "Stalled — stopping…"
        appLog.write("repair watchdog: \(record.filename) stalled \(Int(silentFor)) s — \(attribution); stopping the job")
        task?.cancel()
    }

    // MARK: Finish

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        if terminalCause.isCancel { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        repairJobLog.warning("repair failed: \(self.record.filename, privacy: .public) — \(failed, privacy: .public)")
    }

    private func finishRefused(_ why: String) {
        wasRefused = true
        let line = "Not started — \(why)"
        state = .failed(message: line)
        subtitleText = line
        isIndeterminateValue = false
        repairJobLog.notice("repair refused: \(self.record.filename, privacy: .public) — \(why, privacy: .public)")
    }

    private func finishCancelled() {
        if let reason = terminalCause.stallReason { state = .failed(message: reason); subtitleText = reason; return }
        state = .cancelled
        subtitleText = "Stopped — nothing was saved; the original is untouched."
        isIndeterminateValue = false
    }

    // MARK: Pure helpers (tested)

    /// The finished line: what the comparison says (or that the copy was
    /// saved and checked), always with the verification level.
    static func successSummary(comparison: MediaRepairComparison?, outputName: String,
                               verified: Bool, proof: String) -> String {
        let level = MediaRepairEngine.verificationLevel
        if let comparison { return "\(comparison.headline) (\(level))" }
        return "Repaired copy saved as \(outputName) (\(level))"
            + (verified ? "" : " — Verify the copy to see its report card")
    }

    static func failureSentence(_ why: String, keptAt: URL?) -> String {
        var s = "Couldn't repair: \(why) The original is untouched."
        if let keptAt { s += " The unfinished copy was kept, unpublished, at \(keptAt.path)." }
        return s
    }

    /// The quick Verify of the copy — the same rows CheckMediaJob writes.
    @concurrent
    nonisolated static func quickCard(path: String, control: ProcessControl) async throws -> MediaReportCard {
        switch try await CheckMediaProbe.quick(path: path, control: control) {
        case .measured(let quick): return CheckMediaRules.quickCard(quick, at: Date())
        case .unopenable(let detail, let size): return CheckMediaRules.unopenableCard(detail: detail, sizeBytes: size, at: Date())
        }
    }
}
