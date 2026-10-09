// DeleteDuplicatesBatchRun.swift
// R2 (design triage_delete_streamline_2026_10_09 §9 R2): a reviewed plan
// that spans several volumes runs as SEQUENTIAL per-volume Delete
// Duplicates jobs — one at a time is the job's own rule (one run, one
// re-entry flag), and each volume's job is its own row in Media File
// Operations with its own progress and result.
//
// One fixed keeper per group across the whole batch is settled when the
// batch is frozen (`DeleteDuplicatesReview.holds`) and asked again by each
// job before it reads a byte; each row is still asked at its own turn
// whether it stands. A Stop ends the batch: the volumes whose turn never
// came are reported, row by row, as cancelled — never silently dropped.
//
// (For Rick: `@MainActor final class` ≈ a class touched only on the UI
// thread; `Task { … }` ≈ a coroutine on that thread that awaits each job.)

import Foundation

@MainActor
final class DeleteDuplicatesBatchRun {

    let batch: DeleteDuplicatesBatch
    /// The jobs started so far, in order.
    private(set) var jobs: [DeleteDuplicatesJob] = []
    /// Plans whose turn never came (the batch was stopped first).
    private(set) var notStarted: [DeleteDuplicatesPlan] = []
    /// Internal so tests (and callers) can `await run.task?.value`.
    private(set) var task: Task<Void, Never>?

    static let notStartedNote = "not started — the run was stopped before this drive's turn"

    init(batch: DeleteDuplicatesBatch) {
        self.batch = batch
    }

    /// Start the plans one after the other. `make` builds a volume's job;
    /// `launch` registers and starts it (the MFO center, or `start()` in a
    /// test). Idempotent — a second call is a no-op.
    func start(make: @escaping (DeleteDuplicatesPlan) -> DeleteDuplicatesJob,
               launch: @escaping (DeleteDuplicatesJob) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            for (i, plan) in self.batch.plans.enumerated() {
                let job = make(plan)
                self.jobs.append(job)
                launch(job)
                await job.task?.value
                if job.state == .cancelled {
                    // Stopped by Rick (or a quit): the rest waits for a new review.
                    self.notStarted = Array(self.batch.plans[(i + 1)...])
                    break
                }
            }
        }
    }

    /// Stop the batch: the running job stops (its own Stop — the file in
    /// flight is put back), and no further volume starts.
    func cancel() {
        jobs.last?.cancel()
    }
}
