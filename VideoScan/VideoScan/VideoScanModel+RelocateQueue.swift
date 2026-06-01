import Foundation
import UserNotifications

// MARK: - VideoScanModel+RelocateQueue
//
// Queue management for the Relocate Volume feature. Rick wants to fire
// off four Mac Pro volumes in sequence (HighSierra → osx10.8 →
// InternalRaid → ExternalRAID) and walk away. The UI illusion is
// "kicked off four runs in parallel"; the implementation is a strictly
// serial queue. Why serial:
//
//   - Concurrent writes to one destination volume thrash the FS.
//   - Concurrent reads from a single networked Mac Pro share one NIC.
//   - Concurrent catalog mutations would race on the in-memory model.
//
// See docs/relocate_volume_plan.md §3 (Relocate Job Queue).
//
// Memory footprint: O(jobs) entries in `relocateQueue`. Each job is a
// few hundred bytes of metadata + an optional ~few-KB `RelocateSummary`.
// Even a Rick-scale night with 4 jobs is sub-KB total. The big payloads
// (catalogs, file lists) live on `VideoScanModel`, not on the job.

extension VideoScanModel {

    // MARK: - Public queue API

    /// Append a Relocate request to the queue. If nothing is currently
    /// running, immediately spawns the runner for the new job. Returns
    /// the new job's id so callers can store it (the panel's row
    /// context-menu uses it).
    ///
    /// Refuses to enqueue when `isReadOnly` (viewer mode — same gate as
    /// the legacy entry point) or when no records are in scope (no
    /// point queuing a no-op). Logs the refusal so the user sees why
    /// nothing happened.
    @discardableResult
    func enqueueRelocate(sourceRootPath: String,
                         destinationRoot: URL,
                         options: RelocateOptions) -> UUID? {
        guard !isReadOnly else {
            log("Migrate refused: read-only viewer mode.")
            return nil
        }
        let scope = Self.recordsScoped(to: sourceRootPath, in: records)
        guard !scope.isEmpty else {
            log("Migrate: no catalogued files under \(sourceRootPath).")
            return nil
        }

        let sourceName = (sourceRootPath as NSString).lastPathComponent
        let job = RelocateQueuedJob(
            sourceVolumeRootPath: sourceRootPath,
            sourceVolumeName: sourceName.isEmpty ? sourceRootPath : sourceName,
            destinationRoot: destinationRoot,
            options: options
        )
        relocateQueue.append(job)
        log("Migrate queued: \(job.sourceVolumeName) → \(destinationRoot.path) (queue depth: \(queuedCount))")
        // Kick the runner if idle. If something's already in flight,
        // this is a no-op — the runner's completion path picks the
        // next queued job.
        startNextQueuedJobIfIdle()
        return job.id
    }

    /// Cancel a `.queued` job. Running/terminal jobs are left alone —
    /// returns `false` so callers can show a "couldn't cancel" hint if
    /// they care. v1 has no mid-copy abort (intentional: a partial copy
    /// has unclear semantics, and the per-file engine already verifies
    /// before committing). Documented in §3 of the plan.
    @discardableResult
    func cancelRelocateJob(id: UUID) -> Bool {
        guard let idx = relocateQueue.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard relocateQueue[idx].status == .queued else {
            log("Migrate cancel ignored: job \(id) is \(relocateQueue[idx].statusLabel).")
            return false
        }
        var job = relocateQueue[idx]
        job.status = .canceled
        job.completedAt = Date()
        relocateQueue[idx] = job
        log("Migrate canceled (queued): \(job.sourceVolumeName)")
        return true
    }

    /// Drop all `.complete` / `.failed` / `.canceled` entries from the
    /// queue. Running and queued jobs stay. Invoked from the Jobs
    /// panel's "Clear completed" toolbar button.
    func clearCompletedJobs() {
        let before = relocateQueue.count
        relocateQueue.removeAll { $0.isTerminal }
        let after = relocateQueue.count
        if before != after {
            log("Migrate queue: cleared \(before - after) completed job(s).")
        }
    }

    // MARK: - Queue counts (panel headline)

    var queuedCount:      Int { relocateQueue.filter { $0.status == .queued }.count }
    var runningCount:     Int { relocateQueue.filter { $0.isInFlight }.count }
    var completedCount:   Int { relocateQueue.filter { $0.status == .complete }.count }
    var failedCount: Int {
        relocateQueue.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
    }
    var canceledCount:    Int { relocateQueue.filter { $0.status == .canceled }.count }

    // MARK: - Runner orchestration

    /// Pick the oldest `.queued` job and spawn its runner. If a job is
    /// already in flight (.reconciling / .copying / .awaitingDone),
    /// this is a no-op — the runner's completion path will call us
    /// again once the current job is dismissed.
    func startNextQueuedJobIfIdle() {
        // Anything running (including awaiting summary acknowledgement) → wait.
        if relocateQueue.contains(where: { $0.isInFlight }) { return }
        guard let nextIdx = relocateQueue.firstIndex(where: { $0.status == .queued }) else {
            return
        }

        // Flip to .reconciling NOW (on the same actor turn) so a
        // second call doesn't double-spawn. The runner then does the
        // real work in its Task.
        let jobID = relocateQueue[nextIdx].id
        var job = relocateQueue[nextIdx]
        job.status = .reconciling
        job.startedAt = Date()
        relocateQueue[nextIdx] = job

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Migrate Volume — \(job.sourceVolumeRootPath)
          → \(job.destinationRoot.path)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRelocate(jobID: jobID)
            // Note: we do NOT advance the queue here. The job flips to
            // .awaitingDone at the end of runRelocate and the user's
            // Done click on the summary sheet drives the advance via
            // acknowledgeRelocateSummary(). That's the user-visible
            // contract: every run gets its summary acknowledged before
            // the next starts.
        }
    }

    // MARK: - Job-list mutators (internal — runner calls these)

    /// Update the status of the job with `id`. Idempotent on jobs that
    /// already match. Used by the runner to advance the lifecycle and
    /// by the failure path. Keeps the published-array writes atomic so
    /// SwiftUI sees one diff per transition, not a partially-updated
    /// struct.
    func updateJobStatus(id: UUID, status: RelocateJobStatus) {
        guard let idx = relocateQueue.firstIndex(where: { $0.id == id }) else { return }
        if relocateQueue[idx].status == status { return }
        var job = relocateQueue[idx]
        job.status = status
        if case .complete = status        { job.completedAt = Date() }
        if case .failed   = status        { job.completedAt = Date() }
        if case .canceled = status        { job.completedAt = Date() }
        relocateQueue[idx] = job
    }

    /// Attach the post-flight summary to a job. Called once at the end
    /// of runRelocate (real run AND dry run) so the panel's Show
    /// summary action has data to render later on.
    func attachJobSummary(id: UUID, summary: RelocateSummary) {
        guard let idx = relocateQueue.firstIndex(where: { $0.id == id }) else { return }
        var job = relocateQueue[idx]
        job.summary = summary
        relocateQueue[idx] = job
    }

    /// Push a copy-phase tick. Called per file from runRelocate's copy
    /// loop. Cheap struct assignment; SwiftUI's diff bails fast when
    /// nothing actually moved (Equatable conformance on CopyProgress).
    func updateJobCopyProgress(id: UUID,
                                done: Int,
                                total: Int,
                                currentFile: String,
                                bytesCopied: Int64) {
        guard let idx = relocateQueue.firstIndex(where: { $0.id == id }) else { return }
        let prog = RelocateQueuedJob.CopyProgress(
            done: done,
            total: total,
            currentFile: currentFile,
            bytesCopied: bytesCopied
        )
        if relocateQueue[idx].copyProgress == prog { return }
        var job = relocateQueue[idx]
        job.copyProgress = prog
        relocateQueue[idx] = job
    }

    // MARK: - Summary acknowledgement → queue advance

    /// Find the job currently in `.awaitingDone` (there can be at most
    /// one — the queue is serial) and flip it to `.complete`. Then
    /// fire `startNextQueuedJobIfIdle()` to kick the next run.
    ///
    /// Called from `acknowledgeRelocateSummary()` in
    /// VideoScanModel+Relocate.swift, which is in turn invoked from
    /// the summary sheet's Done button. Also called as the failure
    /// path's queue-advance hook so a job that crashed during
    /// reconcile doesn't strand the queue.
    func advanceQueueAfterCurrent() {
        if let awaitingIdx = relocateQueue.firstIndex(where: { $0.status == .awaitingDone }) {
            var job = relocateQueue[awaitingIdx]
            job.status = .complete
            job.completedAt = Date()
            relocateQueue[awaitingIdx] = job
            postCompletionNotification(for: job)
        }
        startNextQueuedJobIfIdle()
    }

    // MARK: - User notifications

    /// Post a macOS notification on completion/failure. Best-effort —
    /// if the user hasn't granted notification permission elsewhere we
    /// gracefully no-op (we don't request permission ourselves; that
    /// belongs to a top-level UX moment, not a side-effect of a long
    /// relocate run).
    ///
    /// Notification body mirrors the relocate.log summary line so the
    /// user gets the same numbers in both places.
    nonisolated func postCompletionNotification(for job: RelocateQueuedJob) {
        let center = UNUserNotificationCenter.current()
        // Check existing authorization — DON'T request it. Per spec.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = Self.notificationTitle(for: job)
            content.body  = Self.notificationBody(for: job)
            content.sound = nil  // long unattended runs — don't ding at 2 AM
            let req = UNNotificationRequest(
                identifier: "relocate.\(job.id.uuidString)",
                content: content,
                trigger: nil
            )
            center.add(req, withCompletionHandler: nil)
        }
    }

    /// Pure formatter — exposed as a static so a test can verify the
    /// rendering without spinning up UserNotifications. Renders the
    /// user-visible language: "Migrate done: <volumeName>" /
    /// "Migrate failed:".
    nonisolated static func notificationTitle(for job: RelocateQueuedJob) -> String {
        switch job.status {
        case .failed: return "Migrate failed: \(job.sourceVolumeName)"
        default:      return "Migrate done: \(job.sourceVolumeName)"
        }
    }

    /// Body line — "<succeeded> copied · <safelyBacked> safely backed up
    /// · <gb> GB written in <duration>". Falls back to a short summary
    /// for failed/canceled jobs that don't have full counts.
    nonisolated static func notificationBody(for job: RelocateQueuedJob) -> String {
        if case .failed(let reason) = job.status {
            return reason
        }
        guard let s = job.summary else {
            return job.statusLabel
        }
        let gb = Double(s.bytesCopied) / 1_073_741_824.0
        let duration: String = {
            guard let e = job.elapsedSeconds else { return "" }
            if e < 60 { return "\(Int(e))s" }
            return "\(Int(e / 60))m"
        }()
        var parts: [String] = []
        parts.append("\(s.succeededCount) copied")
        if s.safelyBackedUpCount > 0 {
            parts.append("\(s.safelyBackedUpCount) safely backed up")
        }
        parts.append(String(format: "%.1f GB written", gb))
        let summaryLine = parts.joined(separator: " · ")
        return duration.isEmpty ? summaryLine : "\(summaryLine) in \(duration)"
    }
}
