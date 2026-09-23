import Combine
import Foundation
import os

// MARK: - VerifyVideoJob
//
// "Verify Video" as a Media File Operations job (Rick 2026-09-23: "add a
// Verify Video like we have Verify Audio"). Built the SAME way as
// VerifyAudioJob, deliberately — same gate/pause/cancel machinery, same
// persist-on-success-only rule, same log lines — so the two read as one
// family in the MFO window and in the logs:
//
//   - runs VerifyVideoProbe.diagnose (@concurrent — never the UI thread),
//   - holds the source volume's MediaVolumeGates while it reads (per-disk
//     pacing: a 25-row batch against one HDD reads one file at a time),
//   - Pause = SIGSTOP on the live ffprobe/ffmpeg child AND lends the
//     volume slots back to the queue (the 2026-08-07 compare-starvation
//     fix, copied verbatim from VerifyAudioJob),
//   - honest progress: indeterminate while probing, then the decode's
//     real fraction (ffmpeg -progress out_time ÷ duration),
//   - on completion persists videoVerifyStatus/Note/Date + debounced save
//     and keeps the diagnosis for the row's expandable detail view,
//   - a failed diagnosis persists NOTHING ("couldn't check" is not a
//     verdict — the GH #128 rule).
//
// Memory: the diagnosis is a few small value structs (< 2 KB). The probe
// streams; see VerifyVideoProbe's header for the ≈ 1.2 MB worst case.

private let verifyVideoLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "verifyVideo")

@MainActor
final class VerifyVideoJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .verifyVideo
    let startedAt = Date()

    /// Source record. READ ONLY on disk; verdict fields written on
    /// completion.
    let record: VideoRecord

    /// The computed diagnosis; nil until completion (or on failure).
    @Published private(set) var diagnosis: VideoVerifyDiagnosis?

    /// Test seam — replaces VerifyVideoProbe.diagnose. Production passes nil.
    let diagnoseOverride: (@Sendable (String) async throws -> VideoVerifyDiagnosis)?

    private weak var model: VideoScanModel?
    private let gates: [MediaVolumeGate]

    // MARK: Pause (VerifyAudioJob's machinery, unchanged)

    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()
    private var gateOpsChain: Task<Void, Never>?

    private func enqueueGateOp(_ op: @escaping @MainActor () async -> Void) {
        let previous = gateOpsChain
        gateOpsChain = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
        // SIGSTOP first (above), THEN lend the slots — the disk never has
        // an extra active reader.
        enqueueGateOp { [weak self] in
            guard let self else { return }
            for entry in self.gatePermits {
                await entry.permit.releaseForPause()
                VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: self.id)
            }
        }
    }

    func resume() {
        guard isPausedValue else { return }
        // Re-hold EVERY slot before SIGCONT (codex #289/#292 ordering).
        enqueueGateOp { [weak self] in
            guard let self else { return }
            var allHeld = true
            for entry in self.gatePermits {
                try? await entry.permit.reacquireForResume()
                if await entry.permit.currentPhase == .held {
                    VolumeGateBoard.shared.claim(root: entry.gate.root,
                                                 jobID: self.id,
                                                 name: self.gateHolderName)
                } else {
                    allHeld = false
                }
            }
            guard allHeld, self.pauser.resume() else { return }
            self.isPausedValue = false
        }
    }

    // MARK: Published state

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to check the picture…"
    @Published private(set) var waitingForVolumeLabel: String?
    /// Decode progress 0…1; meaningful only once `decodeStarted`.
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var decodeStarted = false

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    var title: String { record.filename }
    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label,
                                                root: waitingForVolumeRoot ?? "")
        }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    /// Honest: the probe/sample passes have no fraction; the decode does.
    var isIndeterminate: Bool { !decodeStarted }

    // MARK: Init / start

    init(record: VideoRecord,
         model: VideoScanModel,
         gates: [MediaVolumeGate] = [],
         diagnoseOverride: (@Sendable (String) async throws -> VideoVerifyDiagnosis)? = nil) {
        self.record = record
        self.model = model
        self.gates = gates
        self.diagnoseOverride = diagnoseOverride
    }

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates(self.gates[...])
        }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
        if task == nil { state = .cancelled }
    }

    // MARK: Run (gated — PausableGatePermit, VerifyAudioJob's shape)

    private var gatePermits: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []
    private var waitingForVolumeRoot: String?
    private var gateHolderName: String { "Verify Video \(record.filename)" }

    private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>) async {
        for gate in remaining {
            waitingForVolumeLabel = gate.label
            waitingForVolumeRoot = gate.root
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
                gatePermits.append((gate, permit))
                VolumeGateBoard.shared.claim(root: gate.root, jobID: id,
                                             name: gateHolderName)
                // codex #295: a pause that landed while we waited for THIS
                // gate must lend it too, and hold here.
                if isPausedValue {
                    let lentEntry = (gate: gate, permit: permit)
                    enqueueGateOp { [weak self] in
                        guard let self, self.isPausedValue else { return }
                        await lentEntry.permit.releaseForPause()
                        VolumeGateBoard.shared.clear(root: lentEntry.gate.root,
                                                     jobID: self.id)
                    }
                    while isPausedValue, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if Task.isCancelled {
                        await closeGatePermits()
                        finishCancelled()
                        return
                    }
                }
            } catch {
                waitingForVolumeLabel = nil
                waitingForVolumeRoot = nil
                await closeGatePermits()
                finishCancelled()
                return
            }
        }
        waitingForVolumeLabel = nil
        waitingForVolumeRoot = nil
        await runDiagnosis()
        await closeGatePermits()
    }

    private func closeGatePermits() async {
        for entry in gatePermits.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: id)
        }
        gatePermits = []
    }

    /// Progress arrives on a GCD thread; hop to the main actor and only
    /// publish visible steps (≥ 0.5 %) so the row doesn't re-render per
    /// ffmpeg line.
    private func noteProgress(_ f: Double) {
        if !decodeStarted {
            decodeStarted = true
            subtitleText = "Decoding every frame…"
        }
        guard f - fractionValue >= 0.005 || f >= 1 else { return }
        fractionValue = f
        subtitleText = "Decoding every frame… \(Int((f * 100).rounded()))%"
    }

    private func runDiagnosis() async {
        let path = record.fullPath
        subtitleText = "Checking the picture…"
        verifyVideoLog.info("verify video job START: \(self.record.filename, privacy: .public)")
        do {
            let control = pauser.control
            let progress: VerifyVideoProbe.Progress = { [weak self] f in
                Task { @MainActor in self?.noteProgress(f) }
            }
            let diagnose = diagnoseOverride
                ?? { try await VerifyVideoProbe.diagnose(path: $0, control: control, progress: progress) }
            let result = try await diagnose(path)
            if Task.isCancelled || state == .cancelling {
                finishCancelled()
                return
            }
            diagnosis = result
            persistVerdict(result)
            let summary = result.summary
            verifyVideoLog.info("verify video job DONE: \(self.record.filename, privacy: .public) → \(result.verdict.rawValue, privacy: .public): \(summary, privacy: .public)")
            model?.log("Verify Video: \(record.filename) → \(result.verdict.displayName) — \(summary)")
            fractionValue = 1
            finish(success: summary)
        } catch VideoVerifyProbeError.toolUnavailable(let detail) {
            finish(failed: detail)
        } catch VideoVerifyProbeError.probeFailed(let detail) {
            finish(failed: "Could not check the picture — \(detail)")
        } catch VideoVerifyProbeError.noVideoStream {
            finish(failed: "This file has no video stream to check — nothing was recorded.")
        } catch is CancellationError {
            finishCancelled()
        } catch {
            if Task.isCancelled || state == .cancelling {
                finishCancelled()
            } else {
                finish(failed: "Could not check the picture — \(error.localizedDescription)")
            }
        }
    }

    /// Write the verdict onto the CURRENT catalog object (a rescan may have
    /// replaced the instance mid-run — resolve by UUID, the VerifyAudioJob
    /// regression fix) and schedule the debounced save.
    private func persistVerdict(_ diagnosis: VideoVerifyDiagnosis) {
        let currentRecord = model?.records.first(where: { $0.id == record.id })
            ?? record
        currentRecord.videoVerifyStatus = diagnosis.persistedStatus
        currentRecord.videoVerifyNote = diagnosis.persistedNote
        currentRecord.videoVerifyDate = Date()
        model?.saveCatalogDebounced()
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
    }

    private func finish(failed: String) {
        // A job whose cancel was requested NEVER ends .failed (Rick
        // 2026-08-26) — the SIGTERM'd child's exit is the user's Stop.
        if state.cancelWasRequested { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        verifyVideoLog.warning("verify video job failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        guard state != .cancelled else { return }
        state = .cancelled
        subtitleText = "Cancelled"
    }
}
