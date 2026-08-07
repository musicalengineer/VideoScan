import Combine
import Foundation
import os

// MARK: - VerifyAudioJob
//
// "Verify Audio" as a Media File Operations job (GH #135, Rick
// 2026-07-24). The shipped sheet ran VerifyAudioProbe.diagnose inside a
// window-modal presentation — but the levels pass decodes the ENTIRE
// audio track, which is minutes on long tapes, so the catalog sat
// blocked. This job runs the same @concurrent diagnosis with the MFO
// window's progress/cancel affordances instead; single- and multi-
// select dispatch identically.
//
// On completion the job:
//   - persists the verdict (audioVerifyStatus/Note/Date + debounced
//     save — the exact body VerifyAudioSheet.persistVerdict used),
//   - hands the full computed AudioVerifyDiagnosis to the Center's
//     cache via `onDiagnosis` so "Verification Results…" presents it
//     instantly with NO re-probe and NO levels re-decode,
//   - when `autoRepair` is set (the batch "Repair Damaged Audio" path),
//     the Center's onDiagnosis closure chains into startRebuildAudio
//     for an unsupported-codec finding.
//
// A failed diagnosis persists NOTHING — "couldn't check" is not a
// verdict (the GH #128 transient-I/O rule lives inside diagnose()).
//
// Per-disk pacing: acquires the same MediaVolumeGates compare/extract
// use (PairCompareJob's recursive withPermit idiom) — a 25-row batch
// verify against one HDD reads it one file at a time instead of
// thrashing.
//
// Memory: the diagnosis is a few small value structs (<1 KB); the probe
// subprocess streams. Worst-case in-process footprint per job ≈ the
// 1 MB ffprobe stdout cap.

private let verifyLog = Logger(subsystem: "Rick-Breen.VideoScan",
                               category: "verifyAudio")

@MainActor
final class VerifyAudioJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .verifyAudio
    let startedAt = Date()

    /// Source record. READ ONLY on disk; verdict fields written on
    /// completion.
    let record: VideoRecord

    /// Batch "Repair Damaged Audio": when true, the Center's
    /// onDiagnosis closure chains a rebuild for codec-damage findings.
    let autoRepair: Bool

    /// Set by the Center at dispatch — receives the computed diagnosis
    /// exactly once, before the terminal transition.
    var onDiagnosis: ((VerifyAudioJob, AudioVerifyDiagnosis) -> Void)?

    /// The computed diagnosis; nil until completion (or on failure).
    private(set) var diagnosis: AudioVerifyDiagnosis?

    /// Test seam — replaces VerifyAudioProbe.diagnose (real ffprobe +
    /// astats) with a canned result. Production passes nil.
    let diagnoseOverride: (@Sendable (String) async throws -> AudioVerifyDiagnosis)?

    private weak var model: VideoScanModel?
    private let gates: [MediaVolumeGate]

    /// Pause via SIGSTOP/SIGCONT on the live ffprobe/ffmpeg child
    /// (GH #150 pattern, wired 2026-08-03 — Rick: "pause doesn't work
    /// for verify audio"). No StallMonitor here — these passes are
    /// deadline-guarded, and ProcessRunner restarts a deadline that
    /// fires while the child is suspended.
    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
        // Step aside (2026-08-07 compare-starvation incident): the
        // SIGSTOPped child does no IO, so lending the volume slots to
        // the queue costs nothing — and holding them starved a queued
        // compare for hours. SIGSTOP lands first (above), THEN the
        // slots return, so the disk never has an extra active reader.
        let permits = gatePermits
        let holder = gateHolderName
        Task { @MainActor in
            for entry in permits {
                await entry.permit.releaseForPause()
                VolumeGateBoard.clear(root: entry.gate.root, holder: holder)
            }
        }
    }

    func resume() {
        guard isPausedValue else { return }
        // Re-join the queue BEFORE SIGCONT — the child may not touch
        // the disk until a slot is held again. The row stays "paused"
        // while queued; a second Resume click is phase-guarded to a
        // no-op inside the permit.
        let permits = gatePermits
        let holder = gateHolderName
        Task { @MainActor [weak self] in
            for entry in permits {
                try? await entry.permit.reacquireForResume()
                VolumeGateBoard.claim(root: entry.gate.root, holder: holder)
            }
            guard let self, self.pauser.resume() else { return }
            self.isPausedValue = false
        }
    }

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to check the audio track…"
    /// Non-nil while queued behind another job on a gated volume.
    @Published private(set) var waitingForVolumeLabel: String?

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
    /// The diagnosis has no meaningful fraction — ffprobe is sub-second
    /// and the astats pass reports no progress stream worth wiring yet.
    var fraction: Double { 0 }
    var isIndeterminate: Bool { true }

    // MARK: Init / start

    init(record: VideoRecord,
         model: VideoScanModel,
         autoRepair: Bool = false,
         gates: [MediaVolumeGate] = [],
         diagnoseOverride: (@Sendable (String) async throws -> AudioVerifyDiagnosis)? = nil) {
        self.record = record
        self.model = model
        self.autoRepair = autoRepair
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
        // Cancelled while queued for a gate: withPermit throws
        // CancellationError and the runner finishes the state below —
        // but a cancel-before-start has no task-side transition, so
        // settle it here when nothing is running yet.
        if task == nil { state = .cancelled }
    }

    // MARK: Run (gated — PausableGatePermit, 2026-08-07)
    //
    // Replaced the recursive withPermit idiom: pause/resume must be
    // able to lend the held slots to the queue and take them back,
    // which withPermit's structured hold cannot express. The permit
    // actor owns the exactly-one-signal-per-wait discipline
    // (PausableGatePermitTests + codex's adversarial matrix).

    /// Permits currently owned by this job, acquisition order (gate
    /// kept alongside for holder-board bookkeeping).
    private var gatePermits: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []
    /// Root of the gate currently queued on — the subtitle names its
    /// holder live via VolumeGateBoard.
    private var waitingForVolumeRoot: String?

    /// This job's name on the holder board.
    private var gateHolderName: String { "Verify \(record.filename)" }

    private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>) async {
        for gate in remaining {
            waitingForVolumeLabel = gate.label
            waitingForVolumeRoot = gate.root
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
                gatePermits.append((gate, permit))
                VolumeGateBoard.claim(root: gate.root, holder: gateHolderName)
            } catch {
                // Only CancellationError escapes wait() — the user
                // cancelled while queued.
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

    /// Release every held slot, reverse order. Permits that lent their
    /// slot away (paused) or never acquired owe the semaphore nothing —
    /// the permit's phase machine guarantees the balance.
    private func closeGatePermits() async {
        for entry in gatePermits.reversed() {
            await entry.permit.close()
            VolumeGateBoard.clear(root: entry.gate.root, holder: gateHolderName)
        }
        gatePermits = []
    }

    private func runDiagnosis() async {
        let path = record.fullPath
        subtitleText = "Checking the audio track…"
        verifyLog.info("verify job START: \(self.record.filename, privacy: .public) (autoRepair=\(self.autoRepair))")
        do {
            let control = pauser.control
            let diagnose = diagnoseOverride
                ?? { try await VerifyAudioProbe.diagnose(path: $0, control: control) }
            let result = try await diagnose(path)
            if Task.isCancelled || state == .cancelling {
                finishCancelled()
                return
            }
            diagnosis = result
            persistVerdict(result)
            onDiagnosis?(self, result)
            let summary = result.isHealthy
                ? "All is well — the audio track checked out."
                : result.persistedNote
            verifyLog.info("verify job DONE: \(self.record.filename, privacy: .public) → \(result.isHealthy ? "healthy" : result.persistedNote, privacy: .public)")
            finish(success: summary)
        } catch AudioVerifyProbeError.toolUnavailable(let detail) {
            finish(failed: detail)
        } catch AudioVerifyProbeError.probeFailed(let detail) {
            finish(failed: "Could not check the audio — \(detail)")
        } catch is CancellationError {
            finishCancelled()
        } catch {
            if Task.isCancelled || state == .cancelling {
                finishCancelled()
            } else {
                finish(failed: "Could not check the audio — \(error.localizedDescription)")
            }
        }
    }

    /// Write the verdict onto the record (the persistent damaged marking
    /// the red rows key off) and schedule the debounced save — verbatim
    /// from the retired sheet flow. A failed probe never reaches here:
    /// "couldn't check" is not a verdict.
    private func persistVerdict(_ diagnosis: AudioVerifyDiagnosis) {
        // regression: a rescan may replace the class instance while the
        // diagnosis runs. Commit onto the current catalog object by UUID.
        let currentRecord = model?.records.first(where: { $0.id == record.id })
            ?? record
        currentRecord.audioVerifyStatus = diagnosis.persistedStatus
        currentRecord.audioVerifyNote = diagnosis.persistedNote
        currentRecord.audioVerifyDate = Date()
        model?.saveCatalogDebounced()
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
    }

    private func finish(failed: String) {
        state = .failed(message: failed)
        subtitleText = failed
        verifyLog.warning("verify job failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        guard state != .cancelled else { return }
        state = .cancelled
        subtitleText = "Cancelled"
    }
}
