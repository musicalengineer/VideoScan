// AvidIDBackfillJob.swift
// "Fill In Avid IDs…" (A/V pair-matcher fix, Rick 2026-10-22): for every
// live MXF row whose UMID or clip name is missing, ONE tag-only ffprobe and
// a header read fill in `materialPackageUMID`, `materialPackageName` and
// `isAvidRender`; then the stored A/V pairs those IDs prove wrong (a render,
// two different clips) are released and logged. Rick starts it from
// Catalog ▸ Fill In Avid IDs…; nothing runs it automatically.
//
// An MFO job of the standard long-operation shape (CLAUDE.md "Long
// operations"): the collapsed row shows the verb chip, "N of M", the
// current file, time left, a progress bar, Pause / Stop; double-click lists
// every file that could not be read (and why), the first results and the
// released pairs, with the running totals; the finished row keeps a
// one-line summary.
//
// Safety:
//   • READ-ONLY on media — ffprobe reads tags, the header read is read(2)
//     of the first 256 KB; nothing is written beside or into a file.
//   • The ONLY writes are the three catalog fields (compare-and-set on the
//     record the plan named; empty fields only) and, at the end, the pair
//     links the new evidence proves wrong (catalog only).
//   • Offline drives are skipped and counted, never waited for.
//   • Every 200 files (or 60 s), on Stop and at the end the job AWAITS an
//     acknowledged catalog save; a failed save stops the job and says so
//     (the IDs read so far stay in memory and are saved with the next save
//     — they are facts read from the file, so keeping them is harmless).
//   • Refused on a read-only catalog (viewer Mac).
//   • Resumable by construction: a row with both IDs is no longer planned.
//
// Logging (one sink, `AvidIDBackfill.note`): START, a progress line every 250 files,
// every unreadable file, the released pairs, and the OUTCOME go to the
// console, catalog.log, videoscan.log and the unified log.
//
// Memory: the plan (one small struct per MXF row — < 1 MB for 3.7k), every
// problem row, at most `sampleCap` result rows and released-pair lines.
//
// (For Rick: `@MainActor final class` ≈ a class whose methods all run on the
// UI thread; the ffprobe wait itself happens off it in ProcessRunner.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class AvidIDBackfillJob: @MainActor MediaFileOperationJob {

    static let title = "Fill in Avid IDs"

    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case filled, render, noIDs, offline, notFound, failed, recordChanged }
        let id: Int
        let filename: String
        let path: String
        let kind: Kind
        let detail: String
    }

    struct Totals: Equatable, Sendable {
        var total = 0, done = 0
        var filled = 0, renders = 0, noIDs = 0, offline = 0, notFound = 0, failed = 0, recordChanged = 0
        var releasedPairs = 0
    }

    /// One file's read (tests inject a stub; production runs ffprobe).
    typealias Prober = @Sendable (_ path: String) async -> AvidIDProbe?

    let id = UUID()
    let kind: MediaFileOperationKind = .fillAvidIDs
    let startedAt = Date()
    private weak var model: VideoScanModel?

    // Seams (tests replace them; production defaults below).
    var proberForTesting: Prober?
    /// Is the file's DRIVE connected? (Offline drives are skipped, counted.)
    var volumeOnline: @Sendable (String) -> Bool = { VolumeReachability.isReachable(path: $0) }
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var gatesFor: (String) -> [MediaVolumeGate] = { _ in [] }
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    var checkpointEvery = 200
    var progressLineEvery = 250
    static let sampleCap = 500

    @Published private(set) var totals = Totals()
    @Published private(set) var problems: [Item] = []
    @Published private(set) var sample: [Item] = []
    @Published private(set) var released: [CorrelationScorer.ReleasedPair] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var pauseRequested = false
    private(set) var wasRefused = false
    private(set) var task: Task<Void, Never>?
    private(set) var summaryLine = ""

    private var unsaved = 0
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
        subtitleText = "Stopping — saving the IDs read so far…"
        task?.cancel()
    }

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
        guard !model.isReadOnly else { refuse("this Mac is a read-only viewer of the catalog", model: model); return }
        let plan = AvidIDBackfill.plan(records: model.records)
        totals.total = plan.count
        isIndeterminateValue = plan.isEmpty
        AvidIDBackfill.note("\(title): START — \(plan.count) MXF file(s) missing an Avid UMID or clip name; "
                            + "one tag-only ffprobe each, read-only on media — writes only the catalog's three Avid fields",
                            model: model)
        runStart = Date()
        lastSave = Date()
        for (i, item) in plan.enumerated() {
            guard await waitOutPause() else { break }
            guard let outcome = await readOne(item, index: i) else { break }
            record(outcome, for: item, index: i, model: model)
            totals.done = i + 1
            fractionValue = Double(i + 1) / Double(max(1, plan.count))
            if totals.done % max(1, progressLineEvery) == 0 {
                AvidIDBackfill.note("\(title): progress — \(totals.done) of \(totals.total) · \(Self.summaryCounts(totals))", model: model)
            }
            if unsaved >= checkpointEvery || (unsaved > 0 && Date().timeIntervalSince(lastSave) >= 60) {
                guard await persist(model: model) else { failSave(model: model); return }
            }
        }
        // The IDs are in: release what they prove wrong, then save once.
        let freed = AvidIDBackfill.releaseStoredPairs(in: model)
        totals.releasedPairs = freed.count
        released = Array(freed.prefix(Self.sampleCap))
        unsaved += freed.count
        guard await persist(model: model) else { failSave(model: model); return }
        conclude(model: model)
    }

    private func conclude(model: VideoScanModel) {
        summaryLine = Self.summaryCounts(totals)
        if stopped {
            AvidIDBackfill.note("\(title): OUTCOME stopped at \(totals.done) of \(totals.total) — \(summaryLine)", model: model)
            finish(cancelled: ())
            return
        }
        AvidIDBackfill.note("\(title): OUTCOME — \(summaryLine)", model: model)
        finish(success: summaryLine)
    }

    private func waitOutPause() async -> Bool {
        while pauseRequested, !stopped {
            subtitleText = "Paused — \(totals.done) of \(totals.total) done; the next file starts on Resume"
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !stopped
    }

    private enum Outcome: Equatable {
        case read(AvidIDProbe)
        case failed
        case offline
        case notFound
    }

    /// One file: skip an offline drive, hold the file's volume gate(s),
    /// read. nil when stopped.
    private func readOne(_ item: AvidIDBackfillItem, index i: Int) async -> Outcome? {
        guard volumeOnline(item.path) else { return .offline }
        guard fileExists(item.path) else { return .notFound }
        guard let permits = await acquireGates(for: item.path) else { return nil }
        if !pauseRequested {
            subtitleText = PerceptualFingerprintBackfillJob.progressLine(
                done: i, total: totals.total, current: item.filename, elapsed: Date().timeIntervalSince(runStart))
        }
        let probe: AvidIDProbe?
        if let proberForTesting { probe = await proberForTesting(item.path) } else {
            probe = await AvidIDBackfill.probe(path: item.path)
        }
        await releaseGates(permits)
        if stopped { return nil }
        return probe.map(Outcome.read) ?? .failed
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

    private func record(_ outcome: Outcome, for item: AvidIDBackfillItem, index i: Int, model: VideoScanModel) {
        switch outcome {
        case .read(let probe):
            recordRead(probe, item: item, index: i, model: model)
        case .offline:
            totals.offline += 1
            problem(i, item, .offline, "its drive is not connected — skipped (run again with it connected)")
        case .notFound:
            totals.notFound += 1
            problem(i, item, .notFound, "not on its drive at the catalogued path — skipped")
        case .failed:
            totals.failed += 1
            problem(i, item, .failed, "ffprobe and the header read could not open it")
            AvidIDBackfill.note("\(title): could not read \(item.path)", model: model)
        }
    }

    private func recordRead(_ probe: AvidIDProbe, item: AvidIDBackfillItem, index i: Int, model: VideoScanModel) {
        switch AvidIDBackfill.apply(probe, to: item, in: model) {
        case .recordChanged:
            totals.recordChanged += 1
            problem(i, item, .recordChanged, "changed in the catalog during the run (moved, rescanned or removed) — skipped; run again")
        case .written(let changed):
            if changed { unsaved += 1 }
            if probe.isRender { totals.renders += 1 }
            guard probe.hasAnyID || probe.isRender else {
                totals.noIDs += 1
                note(i, item, .noIDs, "no Avid UMID or clip name in this file (an older Avid file ffprobe cannot read)")
                return
            }
            totals.filled += 1
            note(i, item, probe.isRender ? .render : .filled, Self.describe(probe))
        }
    }

    private func problem(_ i: Int, _ item: AvidIDBackfillItem, _ kind: Item.Kind, _ detail: String) {
        problems.append(Item(id: i, filename: item.filename, path: item.path, kind: kind, detail: detail))
    }

    private func note(_ i: Int, _ item: AvidIDBackfillItem, _ kind: Item.Kind, _ detail: String) {
        guard sample.count < Self.sampleCap else { return }
        sample.append(Item(id: i, filename: item.filename, path: item.path, kind: kind, detail: detail))
    }

    // MARK: Saving

    private func persist(model: VideoScanModel) async -> Bool {
        guard unsaved > 0 else { return true }
        subtitleText = "Saving the catalog…"
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        if ok {
            unsaved = 0
            lastSave = Date()
        }
        return ok
    }

    private func failSave(model: VideoScanModel) {
        let message = "The catalog could not be saved — the IDs read so far stay in this session and are saved with the "
            + "next save; no media was changed. Stopped; start Fill In Avid IDs again once the catalog can be saved."
        summaryLine = message
        AvidIDBackfill.note("\(title): OUTCOME — \(message)", model: model)
        finish(failed: message)
    }

    // MARK: Finish

    private func refuse(_ why: String, model: VideoScanModel) {
        wasRefused = true
        AvidIDBackfill.note("\(title): refused — \(why). Nothing was read or changed.", model: model)
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
        subtitleText = "Stopped — the Avid IDs saved so far are kept"
        isIndeterminateValue = false
        pauseRequested = false
    }

    // MARK: Pure pieces

    /// "Filled 3,400 · renders 140 · no IDs 66 · released pairs 605 · not connected 12 · failed 1".
    nonisolated static func summaryCounts(_ t: Totals) -> String {
        var parts = ["Filled \(t.filled)", "renders \(t.renders)", "no IDs \(t.noIDs)", "released pairs \(t.releasedPairs)"]
        if t.offline > 0 { parts.append("not connected \(t.offline)") }
        if t.notFound > 0 { parts.append("not found \(t.notFound)") }
        if t.failed > 0 { parts.append("failed \(t.failed)") }
        if t.recordChanged > 0 { parts.append("changed meanwhile \(t.recordChanged)") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func describe(_ p: AvidIDProbe) -> String {
        var parts: [String] = []
        if !p.name.isEmpty { parts.append("clip \"\(p.name)\"") }
        if !p.umid.isEmpty { parts.append("UMID …\(p.umid.suffix(12))") }
        if p.isRender { parts.append("an Avid render — it will never be paired") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Starting it

extension MediaFileOperationsCenter {
    /// Start "Fill In Avid IDs". One run at a time — a second request is
    /// refused (nothing started).
    @discardableResult
    func startAvidIDBackfill(model: VideoScanModel) -> AvidIDBackfillJob {
        let job = AvidIDBackfillJob(model: model)
        job.gatesFor = { [weak self] path in self?.gatePlan(forPaths: [path]) ?? [] }
        add(job)
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is AvidIDBackfillJob }) {
            job.refuseToStart(reason: "Fill In Avid IDs is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "read the Avid UMID and clip name of every MXF missing one; read-only on media"))
        return job
    }
}
