// PerceptualFingerprintBackfillJob.swift
// "Fingerprint Pictures…" (GH #293 item 1, 2026-10-07): computes the
// 32-frame perceptual fingerprint for every video that has none and KEEPS
// it on the catalog record, ARCHIVED FILES FIRST, then everything else.
// Rick starts it (it can be an overnight job: ~one ffmpeg decode pass per
// file at thumbnail scale); nothing runs it automatically.
//
// An MFO job of the standard long-operation shape (CLAUDE.md "Long
// operations"): the collapsed row shows the verb chip, "N of M", the
// current file, time left, a progress bar, Pause / Stop; expanding it lists
// every file that could not be done (and why) and the first results, with
// the running totals; the finished row keeps a one-line summary.
//
// Safety:
//   • READ-ONLY on media — ffmpeg decodes 32 thumbnails into a temp file
//     (PerceptualFingerprinter); nothing is written beside the media.
//   • The ONLY write is `VideoRecord.perceptualFingerprint`, compare-and-
//     set on the record the plan named (same id, path and size).
//   • Every 25 fingerprints (or 60 s), on Stop and at the end the job
//     AWAITS an acknowledged durable catalog save; a failed save stops the
//     job and UNDOES the unsaved fingerprints (compare-and-set), so the
//     next run recomputes them — the BindFixityToVolumeJob contract.
//   • Refused on a read-only catalog (viewer Mac).
//   • One file at a time, holding that file's volume gate while it reads
//     (a spinning disk gets one sequential reader; other heavy jobs on it
//     queue). Pause takes effect between files; Stop terminates the
//     running ffmpeg (ProcessRunner's cancellation) and keeps every
//     fingerprint already saved.
//   • A StallMonitor fed by ffmpeg's progress watches every pass: a drive
//     that sleeps or wedges mid-read fails that file cleanly after 5 min of
//     silence (with the volume attribution) and the run moves on — never
//     the 14-hour hang.
//   • Resumable by construction: a fingerprinted record is no longer a
//     candidate.
//
// Logging (one sink, `perceptualFingerprintNote`): START, a progress line
// every 50 files, every failed file, and the OUTCOME go to the console,
// catalog.log, videoscan.log and the unified log.
//
// Memory: the plan (one small struct per candidate — ~20 MB at 100k), every
// problem row, and at most `sampleCap` success rows. Nothing scales with
// media size (each fingerprint is 32 × 8 bytes).
//
// (For Rick: `@MainActor final class` ≈ a class whose methods all run on the
// UI thread; the ffmpeg wait itself happens off it inside
// PerceptualFingerprinter's `@concurrent` function.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class PerceptualFingerprintBackfillJob: @MainActor MediaFileOperationJob {

    static let title = "Fingerprint pictures (archive first)"

    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case stored, failed, offline, recordChanged }
        let id: Int
        let filename: String
        let path: String
        let archived: Bool
        let kind: Kind
        let detail: String
    }

    struct Totals: Equatable, Sendable {
        var total = 0, archivedTotal = 0, done = 0
        var stored = 0, failed = 0, offline = 0, recordChanged = 0
    }

    /// What one file's pass produced (pure value; `record` interprets it).
    enum Outcome: Equatable, Sendable {
        case fingerprint([UInt64])
        case failed(String)
        case offline
    }

    /// The fingerprint pass for one file (tests inject a stub; production
    /// runs ffmpeg through PerceptualFingerprinter).
    typealias Fingerprinter = @Sendable (_ path: String, _ durationSeconds: Double,
                                         _ onFraction: @escaping @Sendable (Double) -> Void) async throws -> [UInt64]

    let id = UUID()
    let kind: MediaFileOperationKind = .fingerprintBackfill
    let startedAt = Date()
    private weak var model: VideoScanModel?

    // Seams (tests replace them; production defaults below).
    /// TEST SEAM: replaces the ffmpeg pass. nil in production.
    var fingerprinterForTesting: Fingerprinter?
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// The volume gates a file's read must hold (the Center supplies them).
    var gatesFor: (String) -> [MediaVolumeGate] = { _ in [] }
    /// TEST SEAM: replaces the acknowledged catalog save. nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    var checkpointEvery = 25
    var progressLineEvery = 50
    /// No-progress window before one file's pass is declared stalled.
    var stallThresholdSeconds = StallMonitor.defaultStallThresholdSeconds
    var stallPollSeconds = StallMonitor.defaultPollIntervalSeconds
    static let sampleCap = 500

    @Published private(set) var totals = Totals()
    /// Every file that could not be fingerprinted, in plan order.
    @Published private(set) var problems: [Item] = []
    /// The first `sampleCap` stored files.
    @Published private(set) var sample: [Item] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var pauseRequested = false
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// Fingerprints whose catalog save was ACKNOWLEDGED durable.
    private(set) var storedCount = 0
    private(set) var saveFailed = false
    private(set) var summaryLine = ""

    private var pending: [(item: PerceptualFingerprintBackfillItem, written: StoredPerceptualFingerprint)] = []
    private var lastSave = Date()
    private var runStart = Date()

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { state == .running }
    var isPaused: Bool { pauseRequested }

    init(model: VideoScanModel) {
        self.model = model
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
        pauseRequested = false
        subtitleText = "Stopping — saving the fingerprints made so far…"
        task?.cancel()
    }

    /// Pause takes effect between files (a pass cannot be suspended
    /// half-way); the row says so at once.
    func pause() {
        guard state == .running else { return }
        pauseRequested = true
        subtitleText = "Pausing after the current file — \(totals.done) of \(totals.total) done"
    }

    func resume() {
        guard pauseRequested else { return }
        pauseRequested = false
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { Task.isCancelled || state == .cancelling || !state.isActive }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        guard !model.isReadOnly else {
            refuse("this Mac is a read-only viewer of the catalog", model: model)
            return
        }
        let plan = model.perceptualFingerprintBackfillPlan()
        totals.total = plan.count
        totals.archivedTotal = plan.filter(\.isArchived).count
        isIndeterminateValue = plan.isEmpty
        model.perceptualFingerprintNote("\(title): START — \(Self.startClause(totals))")
        guard !plan.isEmpty else {
            summaryLine = "Nothing to do — every video already has a current fingerprint"
            model.perceptualFingerprintNote("\(title): OUTCOME — \(summaryLine)")
            finish(success: summaryLine)
            return
        }
        runStart = Date()
        lastSave = Date()
        for (i, item) in plan.enumerated() {
            guard await waitOutPause() else { break }
            guard let outcome = await fingerprintOne(item, index: i) else { break }
            record(outcome, for: item, index: i, model: model)
            totals.done = i + 1
            fractionValue = Double(i + 1) / Double(plan.count)
            if totals.done % max(1, progressLineEvery) == 0 {
                model.perceptualFingerprintNote("\(title): progress — \(totals.done) of \(totals.total) · \(Self.summaryCounts(totals))")
            }
            if pending.count >= checkpointEvery || (!pending.isEmpty && Date().timeIntervalSince(lastSave) >= 60) {
                guard await persist(model: model) else { await failSave(model: model); return }
            }
        }
        guard await persist(model: model) else { await failSave(model: model); return }
        conclude(model: model)
    }

    private func conclude(model: VideoScanModel) {
        summaryLine = Self.summaryCounts(totals)
        if stopped {
            model.perceptualFingerprintNote("\(title): OUTCOME stopped at \(totals.done) of \(totals.total) — \(summaryLine)")
            finish(cancelled: ())
            return
        }
        model.perceptualFingerprintNote("\(title): OUTCOME — \(summaryLine)")
        finish(success: summaryLine)
    }

    /// Paused: wait between files (no disk slot is held here). False when
    /// stopped meanwhile.
    private func waitOutPause() async -> Bool {
        while pauseRequested, !stopped {
            subtitleText = "Paused — \(totals.done) of \(totals.total) done; the next file starts on Resume"
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !stopped
    }

    /// One file: hold its volume gate(s), run the watched pass. nil when
    /// stopped.
    private func fingerprintOne(_ item: PerceptualFingerprintBackfillItem, index i: Int) async -> Outcome? {
        guard fileExists(item.path) else { return .offline }
        let permits = await acquireGates(for: item.path)
        guard let permits else { return nil }
        if !pauseRequested {
            subtitleText = Self.progressLine(done: i, total: totals.total, current: item.filename,
                                             elapsed: Date().timeIntervalSince(runStart))
        }
        let outcome = await watchedPass(item, index: i)
        await releaseGates(permits)
        return stopped ? nil : outcome
    }

    /// The pass in its own task under a StallMonitor fed by ffmpeg's
    /// progress lines. A drive that sleeps or wedges mid-read fails THIS
    /// file cleanly after `stallThresholdSeconds` of silence (the 14-hour
    /// hang class, StallMonitor.swift) and the run moves on; Stop cancels
    /// the pass, and its ffmpeg, at once. nil when stopped.
    private func watchedPass(_ item: PerceptualFingerprintBackfillItem, index i: Int) async -> Outcome? {
        let total = Double(max(1, totals.total))
        let handle = PassHandle()
        let monitor = StallMonitor(label: "fingerprint \(item.filename)", thresholdSeconds: stallThresholdSeconds,
                                   pollIntervalSeconds: stallPollSeconds) { _ in handle.stall() }
        let sink: @Sendable (Double) -> Void = { [weak self] f in
            monitor.tick()
            Task { @MainActor in self?.fractionValue = min(1, (Double(i) + min(1, max(0, f))) / total) }
        }
        let pass = Task { try await self.runPass(item, onFraction: sink) }
        handle.attach(pass)
        monitor.start()
        defer { monitor.stop() }
        do {
            let hashes = try await withTaskCancellationHandler {
                try await pass.value
            } onCancel: {
                pass.cancel()
            }
            return .fingerprint(hashes)
        } catch {
            if handle.stalled {
                return .failed("stalled — no progress for \(Int(stallThresholdSeconds)) s, so it was stopped and skipped; "
                    + StallMonitor.attribution(forPaths: [item.path]))
            }
            if error is CancellationError || stopped { return nil }
            return .failed(error.localizedDescription)
        }
    }

    /// The production pass (ffmpeg via PerceptualFingerprinter), or the
    /// test seam.
    private func runPass(_ item: PerceptualFingerprintBackfillItem,
                         onFraction: @escaping @Sendable (Double) -> Void) async throws -> [UInt64] {
        if let fingerprinterForTesting {
            return try await fingerprinterForTesting(item.path, item.durationSeconds, onFraction)
        }
        return try await PerceptualFingerprinter.fingerprint(ffmpegPath: ToolLocator.ffmpegPath, path: item.path,
                                                             durationSeconds: item.durationSeconds,
                                                             onFraction: onFraction)
    }

    private func acquireGates(for path: String) async -> [(MediaVolumeGate, PausableGatePermit)]? {
        var held: [(MediaVolumeGate, PausableGatePermit)] = []
        for gate in gatesFor(path) {
            subtitleText = "Waiting for \(gate.label)…"
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

    private func record(_ outcome: Outcome, for item: PerceptualFingerprintBackfillItem, index i: Int,
                        model: VideoScanModel) {
        switch outcome {
        case .fingerprint(let hashes):
            let fp = StoredPerceptualFingerprint(hashes: hashes, sizeBytes: item.sizeBytes,
                                                 durationSeconds: item.durationSeconds)
            switch model.applyPerceptualFingerprint(fp, to: item) {
            case .written:
                totals.stored += 1
                pending.append((item, fp))
                if sample.count < Self.sampleCap {
                    sample.append(Item(id: i, filename: item.filename, path: item.path, archived: item.isArchived,
                                       kind: .stored, detail: "\(hashes.count) frames kept"))
                }
            case .recordChanged:
                totals.recordChanged += 1
                problem(i, item, .recordChanged, "changed in the catalog during the run (moved, rescanned or removed) — skipped; run again")
            }
        case .offline:
            totals.offline += 1
            problem(i, item, .offline, "not found — its drive is not connected; skipped (run again with it connected)")
        case .failed(let why):
            totals.failed += 1
            problem(i, item, .failed, why)
            model.perceptualFingerprintNote("\(title): FAILED \(item.path) — \(why)")
        }
    }

    private func problem(_ i: Int, _ item: PerceptualFingerprintBackfillItem, _ kind: Item.Kind, _ detail: String) {
        problems.append(Item(id: i, filename: item.filename, path: item.path, archived: item.isArchived,
                             kind: kind, detail: detail))
    }

    // MARK: Saving

    /// Await an ACKNOWLEDGED durable save of the fingerprints made since
    /// the last one. True when there was nothing to save or it is on disk.
    private func persist(model: VideoScanModel) async -> Bool {
        guard !pending.isEmpty else { return true }
        let n = pending.count
        subtitleText = "Saving the catalog (\(n) new fingerprint\(n == 1 ? "" : "s"))…"
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        if ok {
            storedCount += n
            pending.removeAll()
            lastSave = Date()
        } else {
            saveFailed = true
        }
        return ok
    }

    /// A save was not acknowledged: stop, UNDO the unsaved fingerprints
    /// (compare-and-set), say so. Media was never touched.
    private func failSave(model: VideoScanModel) async {
        var undone = 0
        for p in pending where model.revertPerceptualFingerprint(p.item, written: p.written) { undone += 1 }
        pending.removeAll()
        let message = "The catalog could not be saved — \(undone) fingerprint(s) were not saved and were undone; "
            + "\(storedCount) saved earlier are kept; no media was changed. Stopped; start Fingerprint Pictures "
            + "again once the catalog can be saved."
        summaryLine = message
        model.perceptualFingerprintNote("\(title): OUTCOME — \(message)")
        finish(failed: message)
    }

    // MARK: Finish

    private func refuse(_ why: String, model: VideoScanModel) {
        wasRefused = true
        model.perceptualFingerprintNote("\(title): refused — \(why). Nothing was read or changed.")
        finish(failed: "Refused — \(why). Nothing was read or changed.")
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isIndeterminateValue = false
        pauseRequested = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        pauseRequested = false
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped — \(storedCount) fingerprint(s) saved to the catalog are kept"
        isIndeterminateValue = false
        pauseRequested = false
    }

    // MARK: Pure pieces

    /// "164 videos without a fingerprint (164 archived first, then 0 others); read-only on media …"
    nonisolated static func startClause(_ t: Totals) -> String {
        "\(t.total) video(s) without a fingerprint (\(t.archivedTotal) archived first, then "
            + "\(t.total - t.archivedTotal) others); read-only on media — writes only the catalog's fingerprint field"
    }

    /// "Stored 160 · failed 2 · not connected 1 · changed meanwhile 1".
    nonisolated static func summaryCounts(_ t: Totals) -> String {
        var parts = ["Stored \(t.stored)", "failed \(t.failed)"]
        if t.offline > 0 { parts.append("not connected \(t.offline)") }
        if t.recordChanged > 0 { parts.append("changed meanwhile \(t.recordChanged)") }
        return parts.joined(separator: " · ")
    }

    /// "12 of 164 · Cape-1992-archive.mkv · ~40 min left".
    nonisolated static func progressLine(done: Int, total: Int, current: String, elapsed: TimeInterval) -> String {
        var left = ""
        if done > 0, total > done, elapsed > 1 {
            let secs = elapsed / Double(done) * Double(total - done)
            left = secs < 60 ? " · ~\(max(1, Int(secs.rounded()))) s left"
                : secs < 3600 ? " · ~\(Int((secs / 60).rounded())) min left"
                : " · ~\(Int(secs / 3600)) h \(Int(secs.truncatingRemainder(dividingBy: 3600) / 60)) min left"
        }
        return "\(done.formatted()) of \(total.formatted()) · \(current)\(left)"
    }
}

// MARK: - One pass's stall latch

/// Lets the StallMonitor (which fires off the main actor) cancel the pass
/// it watches and leaves a record that it did. (≈ C++: a mutex-guarded
/// struct holding a cancel handle and a flag.)
private final class PassHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[UInt64], Error>?
    private var didStall = false

    func attach(_ task: Task<[UInt64], Error>) {
        lock.lock()
        self.task = task
        let fired = didStall
        lock.unlock()
        if fired { task.cancel() }
    }

    func stall() {
        lock.lock()
        didStall = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    var stalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStall
    }
}

// MARK: - Starting it

extension MediaFileOperationsCenter {
    /// Start "Fingerprint Pictures". One run at a time — a second request is
    /// refused (parked, nothing started).
    @discardableResult
    func startPerceptualFingerprintBackfill(model: VideoScanModel) -> PerceptualFingerprintBackfillJob {
        let job = PerceptualFingerprintBackfillJob(model: model)
        job.gatesFor = { [weak self] path in self?.gatePlan(forPaths: [path]) ?? [] }
        add(job)
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is PerceptualFingerprintBackfillJob }) {
            job.refuseToStart(reason: "Fingerprint Pictures is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "fingerprint every video without one, archived files first; read-only on media"))
        return job
    }
}
