import Combine
import Foundation
import os

// MARK: - PromoteToArchiveJob
//
// "Promote to Archive" (docs/archive_promotion_workflow.md §5, Rick
// 2026-08-15; hardened per codex QA rounds 1–2). ONE job per confirmation
// — N files, disk-paced through the MediaVolumeGate like every other MFO
// verb. Per file (see PromoteToArchiveJob+Steps.swift):
//
//   0. Reconcile the intent journal from any earlier interrupted run
//      (crash after rename / after manifest / mid-copy) so the archive
//      CONVERGES to exactly one copy + one manifest row + one catalog link
//      per source before new work starts.
//   1. Idempotency by SOURCE IDENTITY (source record id): a catalog copy
//      or a manifest row already naming this source ⇒ never copy again
//      (a manifest-only row is adopted into the catalog instead).
//   2. Resolve the destination name; on collision, compare the existing
//      file's bytes with the source and ADOPT it if identical — `_NN` is
//      minted only for a genuinely different file.
//   3. Journal INTENT → copy source→`.partial` via open descriptors with
//      the TOCTOU contract (ArchivePromoteEngine) → verify → RENAME_EXCL →
//      fsync dir → journal RENAMED.
//   4. Probe the copy, append the manifest row (single O_APPEND write) →
//      journal MANIFEST.
//   5. Main actor: linked record + source stamp + noteCatalogRecordsMutated
//      + debounced save → journal DONE.
//
// Free space for the WHOLE batch is checked once, up front (§5.2).
// Cancel-safe: the in-flight partial is removed; completed files stay
// (they are verified, journaled, indexed and recorded). Source files are
// NEVER modified — the pipeline only reads them.
//
// Memory: constant per file (ArchivePromoteEngine's chunk buffers); the
// plan/result/journal maps are O(selection + journal entries) — a few
// hundred bytes each. Worst case for a 500-file batch < 4 MB in-process.

let promoteLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "promote")

/// (For Rick: `@MainActor` before the protocol name (SE-0470) says the
/// conformance itself may only be used from the UI thread — statically
/// checked, like the other new-style jobs.)
@MainActor
final class PromoteToArchiveJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .promote
    let startedAt = Date()

    /// The confirmed plan (root, entries, byte totals). Immutable.
    let plan: ArchivePromotePlan

    weak var model: VideoScanModel?

    /// Per-disk pacing: the source volumes AND the archive volume. Held
    /// for the whole run (a batch is one long sequential read+write).
    private let gates: [MediaVolumeGate]

    /// One-file result rows for the end-of-run summary.
    struct FileOutcome: Identifiable, Equatable {
        enum Kind: Equatable { case promoted, adopted, skipped, failed }
        let id = UUID()
        let filename: String
        let kind: Kind
        /// relpath for promoted/adopted; reason for skipped / failed.
        let detail: String
    }
    @Published private(set) var outcomes: [FileOutcome] = []

    /// Destination paths claimed by THIS batch — resolved but possibly not
    /// on disk yet when the next file resolves. Folded into the collision
    /// check so two files in one batch can never pick the same name.
    var claimedNames = Set<String>()

    /// Journal entries this run brought to `published` (file + manifest
    /// durable, catalog link in memory). Advanced to `done` ONLY after
    /// the batch-end `saveCatalogNow()` returns true (codex R3 blocker 5).
    var publishedThisBatch: [ArchivePromoteJournal.Entry] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true
    private(set) var wasRefused = false

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    var title: String {
        plan.entries.count == 1
            ? (plan.entries.first?.filename ?? "1 file")
            : "\(plan.entries.count) files → Master Archive"
    }
    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label,
                                                root: waitingForVolumeRoot ?? "")
        }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    @Published private(set) var waitingForVolumeLabel: String?
    private var waitingForVolumeRoot: String?
    private var heldGates: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []

    // MARK: Init / start

    init(plan: ArchivePromotePlan,
         model: VideoScanModel,
         gates: [MediaVolumeGate] = []) {
        self.plan = plan
        self.model = model
        self.gates = gates
        self.subtitleText = plan.entries.isEmpty
            ? "Nothing to promote"
            : "Preparing to promote \(plan.entries.count) file(s)…"
    }

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates()
        }
    }

    /// Park the row as refused before any work (Center-level guard).
    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Gates

    private func runHoldingGates() async {
        for gate in gates {
            waitingForVolumeLabel = gate.label
            waitingForVolumeRoot = gate.root
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
                heldGates.append((gate, permit))
                VolumeGateBoard.shared.claim(root: gate.root, jobID: id,
                                             name: "Promote \(title)")
            } catch {
                waitingForVolumeLabel = nil
                waitingForVolumeRoot = nil
                await releaseGates()
                finishCancelled()
                return
            }
        }
        waitingForVolumeLabel = nil
        waitingForVolumeRoot = nil
        await run()
        await releaseGates()
    }

    private func releaseGates() async {
        for entry in heldGates.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: id)
        }
        heldGates = []
    }

    // MARK: Run

    struct Tally {
        var promoted = 0, adopted = 0, skipped = 0, failed = 0
        var bytesDone: Int64 = 0
    }

    private func run() async {
        guard state != .cancelling else { finishCancelled(); return }
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        guard let ctx = preflight(model: model) else { return }

        var tally = Tally()
        let total = plan.entries.count
        promoteLog.info("promote START: \(total) file(s) → \(ctx.root, privacy: .public)")
        isIndeterminateValue = false

        // Step 0 — converge anything an earlier run left half-done.
        subtitleText = "Checking the archive journal…"
        let reconciled = await reconcileJournal(model: model, ctx: ctx)
        if reconciled > 0 {
            model.log("Promote: finished \(reconciled) promotion(s) an earlier run left incomplete.")
        }

        for (index, entry) in plan.entries.enumerated() {
            if Task.isCancelled || state == .cancelling { break }
            subtitleText = "\(index + 1)/\(total) · \(entry.filename)"
            let outcome = await promoteOne(entry: entry, model: model, ctx: ctx,
                                           bytesDone: tally.bytesDone)
            switch outcome {
            case .promoted(let relPath):
                tally.promoted += 1
                tally.bytesDone += entry.sizeBytes
                record(.promoted, entry.filename, relPath)
            case .adopted(let relPath):
                tally.adopted += 1
                tally.bytesDone += entry.sizeBytes
                record(.adopted, entry.filename, relPath)
                model.log("Promote: \(entry.filename) — an identical copy already sat at \(relPath); adopted it (no second copy).")
            case .skipped(let why):
                tally.skipped += 1
                record(.skipped, entry.filename, why)
                model.log("Promote: skipped \(entry.filename) — \(why).")
            case .failed(let why):
                tally.failed += 1
                tally.bytesDone += entry.sizeBytes
                record(.failed, entry.filename, why)
                model.log("Promote: FAILED \(entry.filename) — \(why)")
                promoteLog.error("promote FAILED \(entry.filename, privacy: .public): \(why, privacy: .public)")
            case .cancelled:
                break
            }
            if case .cancelled = outcome { break }
        }

        // Batch end: ONE durable catalog save; only then are the batch's
        // journal entries marked done. Runs on cancel too — whatever was
        // published stays published and must be persisted.
        let saved = finalizeBatch(model: model, ctx: ctx)
        finishRun(tally: tally, saved: saved, model: model)
    }

    private func finishRun(tally: Tally, saved: Bool, model: VideoScanModel) {
        if Task.isCancelled || state == .cancelling {
            let kept = tally.promoted + tally.adopted
            let done = kept > 0 ? " (\(kept) already promoted stay in the archive)" : ""
            model.log("Promote: cancelled\(done).")
            finishCancelled()
            return
        }
        var parts = ["Promoted \(tally.promoted)"]
        if tally.adopted > 0 { parts.append("adopted \(tally.adopted)") }
        parts.append("skipped \(tally.skipped)")
        parts.append("failed \(tally.failed)")
        if !saved && (tally.promoted + tally.adopted) > 0 {
            parts.append("catalog save deferred (links re-established next run)")
        }
        let summary = parts.joined(separator: " · ")
        model.log("Promote: \(summary).")
        if tally.promoted + tally.adopted == 0 && tally.failed > 0 {
            finish(failed: summary)
        } else {
            finish(success: summary)
        }
    }

    func record(_ kind: FileOutcome.Kind, _ filename: String, _ detail: String) {
        outcomes.append(FileOutcome(filename: filename, kind: kind, detail: detail))
    }

    func applyProgress(_ fraction: Double) {
        guard state.isActive else { return }
        fractionValue = min(1, max(fractionValue, fraction))
    }

    /// Phase text from the copy/verify loop ("Copying X · 47 of 69 GB ·
    /// 187 MB/s · ~2 min"). Only while active — a finished/cancelled row
    /// keeps its summary.
    func applyPhaseSubtitle(_ text: String) {
        guard state.isActive else { return }
        subtitleText = text
    }

    // MARK: Finish helpers

    func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    func finish(failed: String) {
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        promoteLog.warning("promote failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    static func humanBytes(_ bytes: Int64) -> String {
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }
}

/// Typed per-file failure so the summary row carries the exact reason.
struct PromoteError: Error, Sendable {
    let message: String
}
