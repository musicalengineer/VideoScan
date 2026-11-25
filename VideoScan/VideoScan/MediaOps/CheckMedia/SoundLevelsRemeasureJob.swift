// SoundLevelsRemeasureJob.swift — "Re-measure sound levels", the MFO job
// (GH #516; DECISIONS 2026-11-25). Rules and the marker: SoundLevelsRemeasure.swift.
//
// One sentence: for every Check Media card whose Sound row may hold levels
// measured by pre-2441ceb42 code (or was withdrawn by an earlier run), run
// today's sound pass (`VerifyAudioProbe.diagnose`, the one Check Media
// runs — rule 4) and rewrite that row: today's levels; none when the sound
// changes partway (a rebuilt filter graph); WITHDRAWN when the file is not
// connected, is not the size it was checked at, or cannot be measured.
//
// The standard long-operation shape (CLAUDE.md rule 5): the row shows the
// verb chip, N of M, the current file, time left, Pause / Stop; START, a
// progress line every 50 files, one line per card whose levels were
// withdrawn, and the OUTCOME go through the one sink (`note`: console +
// catalog.log, videoscan.log, the unified log).
//
// Safety (data-risk: a catalog writer; follow-up Codex pass before merge):
//   * READ-ONLY on media: ffprobe + an audio-only ffmpeg decode.
//   * The ONLY write is the card's Sound row, `soundMeasuredSilent` and (when
//     the row's verdict changed) the headline — compare-and-set on the card
//     the plan read (same `checkedAt`, same Sound row): a card Check Media
//     rewrote meanwhile is left alone ("changed meanwhile").
//   * Every 25 cards (or 60 s), on Stop and at the end the job AWAITS an
//     acknowledged durable catalog save (the commit door via
//     `saveCatalogAcknowledged`); a failed save stops the job and UNDOES the
//     unsaved rewrites (compare-and-set), and the cursor does not move.
//   * The marker's cursor moves only after an acknowledged save, so Stop,
//     quit or a crash resumes at the first card not yet durably rewritten.
//   * Refused on a read-only catalog (viewer Mac) and when ffmpeg is missing
//     (a missing tool is never "could not measure the file").
//   * One file at a time, holding its volume gate while it reads. Pause
//     takes effect between files; Stop terminates the running ffmpeg.
//   * Rows are never added or removed: OUTCOME says rows before = after.
//
// Memory: the plan (~300 B per card, ~30 MB at 100k), up to `checkpointEvery`
// pending (old, new) card pairs (a few KB each), every problem row, and at
// most `sampleCap` other rows. Nothing scales with media size.
//
// (For Rick: `@MainActor final class` ≈ an object whose methods all run on
// the UI thread; the ffmpeg wait happens off it inside `measure`, which is
// `@concurrent` ≈ "always runs on the worker pool".)

import Combine
import Foundation
import os
import VideoScanCore

private let remeasureLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "remeasureSoundLevels")

/// One card the job will measure again. A small value: no card copy.
struct SoundLevelsRemeasureItem: Sendable, Equatable {
    let id: UUID
    let filename: String
    let path: String
    let need: SoundLevelsRemeasureRules.Need
    /// The card the plan read: compared again before the write.
    let checkedAt: Date
    let soundRow: MediaCheck
    let fileSizeBytes: Int64

    /// Every candidate, in record-id order (the cursor's order). O(records),
    /// main actor (the records live there).
    @MainActor
    static func plan(_ records: [VideoRecord], marker: SoundLevelsRemeasureMarker,
                     now: Date = Date()) -> [SoundLevelsRemeasureItem] {
        var out: [SoundLevelsRemeasureItem] = []
        for r in records {
            guard let card = r.mediaReportCard,
                  let need = SoundLevelsRemeasureRules.need(card, recordID: r.id, live: r.removal == nil,
                                                                 marker: marker, now: now),
                  let row = card.check(.sound) else { continue }
            out.append(SoundLevelsRemeasureItem(id: r.id, filename: r.filename, path: r.fullPath, need: need,
                                                checkedAt: card.checkedAt, soundRow: row,
                                                fileSizeBytes: card.fileSizeBytes))
        }
        return out.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Cards withdrawn because their drive was not connected: on drives
    /// still away (`cards`, `drives`) and on drives connected now (`ready`).
    /// O(records), main actor; `isOnline` is the app's volume signal.
    @MainActor
    static func waiting(_ records: [VideoRecord], isOnline: (String) -> Bool) -> SoundLevelsRemeasureWaiting {
        var w = SoundLevelsRemeasureWaiting()
        for r in records where r.removal == nil {
            guard let card = r.mediaReportCard, card.tier == .full, let row = card.check(.sound),
                  SoundLevelsRemeasureRules.isWaitingForDrive(row) else { continue }
            if isOnline(r.fullPath) {
                w.ready += 1
            } else {
                w.cards += 1
                w.drives.insert(SoundLevelsRemeasureRules.driveKey(r.fullPath))
            }
        }
        return w
    }

    /// Whether the scheduler should start the job: the pre-fix walk is not
    /// finished, or a card waiting for its drive can be measured now.
    @MainActor
    static func autoRunDue(_ records: [VideoRecord], marker: SoundLevelsRemeasureMarker?,
                           isOnline: (String) -> Bool) -> Bool {
        guard let marker else { return true }
        if !marker.isWalked { return true }
        return waiting(records, isOnline: isOnline).ready > 0
    }
}

/// Cards whose levels wait for their drive to be connected.
struct SoundLevelsRemeasureWaiting: Sendable, Equatable {
    var cards = 0
    var drives: Set<String> = []
    /// Waiting cards whose drive is connected now: the next run measures them.
    var ready = 0

    /// "waiting for 2 drives (14 cards)"; nil when none waits.
    var words: String? {
        guard cards > 0 else { return nil }
        return "waiting for \(drives.count) drive\(drives.count == 1 ? "" : "s") (\(cards) card\(cards == 1 ? "" : "s"))"
    }
}

@MainActor
final class SoundLevelsRemeasureJob: @MainActor MediaFileOperationJob {

    static let title = "Re-measure sound levels"

    struct Item: Identifiable, Equatable, Sendable {
        let id: Int
        let filename: String
        let path: String
        let result: SoundLevelsRemeasureRules.Result?
        let detail: String
    }

    struct Totals: Equatable, Sendable {
        var total = 0, done = 0
        var refreshed = 0, reconfigured = 0, offline = 0, notFound = 0, changed = 0, failed = 0, changedMeanwhile = 0
        var withdrawn: Int { offline + notFound + changed + failed }
    }

    /// Today's sound pass on one file (tests inject a stub).
    typealias Measure = @Sendable (_ path: String, _ expectedSize: Int64) async throws -> SoundLevelsRemeasureRules.Remeasured

    let id = UUID()
    let kind: MediaFileOperationKind = .remeasureSoundLevels
    let startedAt = Date()
    private weak var model: VideoScanModel?
    private let catalogFile: String

    // Seams (tests replace them; production defaults below).
    /// TEST SEAM: replaces today's sound pass. nil in production (`measureFile`).
    var measure: Measure?
    /// Is this path's DRIVE connected (the app's volume signal; never "does
    /// the file exist"). Tests replace it.
    var isOnline: @Sendable (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }
    var toolsAvailable: @Sendable () -> Bool = { FileManager.default.isExecutableFile(atPath: ToolLocator.ffmpegPath) }
    var gatesFor: (String) -> [MediaVolumeGate] = { _ in [] }
    /// TEST SEAM: replaces the acknowledged catalog save. nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    var now: () -> Date = { Date() }
    var checkpointEvery = 25
    var progressLineEvery = 50
    static let sampleCap = 500

    @Published private(set) var totals = Totals()
    /// Every card whose levels were withdrawn or that changed meanwhile.
    @Published private(set) var problems: [Item] = []
    /// The first `sampleCap` refreshed / reconfigured cards.
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
    /// Rewrites whose catalog save was ACKNOWLEDGED durable.
    private(set) var savedCount = 0
    private(set) var saveFailed = false
    private(set) var summaryLine = ""
    private(set) var marker: SoundLevelsRemeasureMarker?

    private struct Pending { let item: SoundLevelsRemeasureItem; let old: MediaReportCard; let new: MediaReportCard }
    private var pending: [Pending] = []
    /// The last pre-fix item handled since the last save (moves the cursor).
    private var pendingCursor: String?
    private var lastSave = Date()
    private var runStart = Date()
    /// Set when ffmpeg disappeared mid-run: the run stops, nothing is guessed.
    private var toolLost: String?

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { state == .running }
    var isPaused: Bool { pauseRequested }

    init(model: VideoScanModel, catalogFile: String? = nil) {
        self.model = model
        self.catalogFile = catalogFile ?? model.catalogStore.fileLocation
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
        subtitleText = "Stopping — saving the cards rewritten so far…"
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
        guard toolsAvailable() else {
            refuse("ffmpeg was not found (install it with Homebrew, or set VS_FFMPEG_PATH)", model: model); return
        }
        var marker = openMarker(model: model)
        let plan = SoundLevelsRemeasureItem.plan(model.records, marker: marker, now: now())
        totals.total = plan.count
        isIndeterminateValue = plan.isEmpty
        note("START — \(Self.startClause(plan, marker: marker))", model: model)
        runStart = Date()
        lastSave = Date()
        for (i, item) in plan.enumerated() {
            guard await waitOutPause() else { break }
            guard let outcome = await measureOne(item, index: i) else { break }
            record(outcome, for: item, index: i, model: model)
            totals.done = i + 1
            fractionValue = Double(i + 1) / Double(max(1, plan.count))
            if totals.done % max(1, progressLineEvery) == 0 {
                note("progress — \(totals.done) of \(totals.total) · \(Self.summaryCounts(totals))", model: model)
            }
            if pending.count >= checkpointEvery || (!pending.isEmpty && Date().timeIntervalSince(lastSave) >= 60) {
                guard await persist(model: model, marker: &marker) else { await failSave(model: model); return }
            }
        }
        guard await persist(model: model, marker: &marker) else { await failSave(model: model); return }
        if let why = toolLost {
            summaryLine = Self.summaryCounts(totals)
            let message = "ffmpeg went away mid-run (\(why)) — stopped after \(totals.done) of \(totals.total); \(savedCount) card(s) saved are kept; it continues from here once ffmpeg is back"
            note("OUTCOME — \(message)", model: model)
            finish(failed: message)
            return
        }
        conclude(model: model, marker: &marker)
    }

    /// The marker beside the catalog: read, or made now (its cutoff), or —
    /// unreadable — replaced with today's cutoff, said in the log.
    private func openMarker(model: VideoScanModel) -> SoundLevelsRemeasureMarker {
        let loaded = SoundLevelsRemeasureMarker.loadOrCreate(catalogFile: catalogFile, now: now())
        if loaded.replaced {
            note("the marker \(SoundLevelsRemeasureMarker.fileName) could not be read — started a new one with today as the cutoff (every card with levels is measured again)", model: model)
        }
        if loaded.created { writeMarker(loaded.marker, model: model) }
        self.marker = loaded.marker
        return loaded.marker
    }

    private func conclude(model: VideoScanModel, marker: inout SoundLevelsRemeasureMarker) {
        summaryLine = Self.summaryCounts(totals)
        let rows = "catalog rows before \(model.records.count) · after \(model.records.count) · difference none (Sound rows rewritten in place)"
        if stopped {
            note("OUTCOME stopped at \(totals.done) of \(totals.total) — \(summaryLine); \(rows)", model: model)
            finish(cancelled: ())
            return
        }
        // Done only when no card waits for a drive (coordinator, #516 review):
        // a card withdrawn for an absent drive is work still owed.
        let waiting = SoundLevelsRemeasureItem.waiting(model.records, isOnline: isOnline)
        if let words = waiting.words { summaryLine += " · " + words }
        marker.walkedAt = marker.walkedAt ?? now()
        marker.completedAt = waiting.cards == 0 && waiting.ready == 0 ? now() : nil
        marker.cursor = nil
        marker.lastSummary = summaryLine
        writeMarker(marker, model: model)
        self.marker = marker
        note("OUTCOME — \(summaryLine); \(rows)", model: model)
        finish(success: totals.total == 0 && waiting.cards == 0
               ? "Nothing to do — no saved card holds sound levels from before the fix" : summaryLine)
    }

    private func waitOutPause() async -> Bool {
        while pauseRequested, !stopped {
            subtitleText = "Paused — \(totals.done) of \(totals.total) done; the next file starts on Resume"
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !stopped
    }

    /// One file: hold its volume gate(s), measure. nil when stopped, or when
    /// ffmpeg went away (`toolLost`; the job then fails without writing it).
    private func measureOne(_ item: SoundLevelsRemeasureItem, index i: Int) async -> SoundLevelsRemeasureRules.Remeasured? {
        guard let permits = await acquireGates(for: item.path) else { return nil }
        if !pauseRequested {
            subtitleText = PerceptualFingerprintBackfillJob.progressLine(done: i, total: totals.total, current: item.filename,
                                                                         elapsed: Date().timeIntervalSince(runStart))
        }
        let measure: Measure = self.measure ?? { [isOnline] path, size in
            try await Self.measureFile(path: path, expectedSize: size, isOnline: isOnline)
        }
        let pass = Task { try await measure(item.path, item.fileSizeBytes) }
        var outcome: SoundLevelsRemeasureRules.Remeasured?
        do {
            outcome = try await withTaskCancellationHandler { try await pass.value } onCancel: { pass.cancel() }
        } catch AudioVerifyProbeError.toolUnavailable(let why) {
            toolLost = why
        } catch {
            outcome = nil   // Stop
        }
        await releaseGates(permits)
        return stopped ? nil : outcome
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

    /// Compare-and-set the rewrite onto the card the plan read.
    private func record(_ r: SoundLevelsRemeasureRules.Remeasured, for item: SoundLevelsRemeasureItem,
                        index i: Int, model: VideoScanModel) {
        if item.need == .prefix { pendingCursor = item.id.uuidString }
        guard let rec = model.record(forID: item.id), let card = rec.mediaReportCard,
              card.checkedAt == item.checkedAt, card.check(.sound) == item.soundRow else {
            totals.changedMeanwhile += 1
            problems.append(Item(id: i, filename: item.filename, path: item.path, result: nil,
                                 detail: "its card changed in the catalog during the run (checked again, or removed) — left as it is"))
            return
        }
        let result = SoundLevelsRemeasureRules.result(of: r)
        let new = SoundLevelsRemeasureRules.rewrite(card, with: r, context: rec.soundPresenceContext)
        if new != card {
            rec.mediaReportCard = new
            pending.append(Pending(item: item, old: card, new: new))
        }
        switch result {
        case .refreshed:
            totals.refreshed += 1
            keepSample(i, item, result, "measured again — today's levels kept")
        case .reconfigured:
            totals.reconfigured += 1
            keepSample(i, item, result, "the sound changes partway through — no levels kept")
            note("\(item.path) — levels withdrawn: the sound's sample rate, format or layout changes partway, so no single measurement covers it", model: model)
        case .withdrawn(let why):
            switch why {
            case .offline: totals.offline += 1
            case .notFound: totals.notFound += 1
            case .changed: totals.changed += 1
            case .failed: totals.failed += 1
            }
            problems.append(Item(id: i, filename: item.filename, path: item.path, result: result,
                                 detail: "levels withdrawn until it can be measured: \(why.words)"))
            note("\(item.path) — levels withdrawn until it can be measured again: \(why.words)", model: model)
        }
    }

    private func keepSample(_ i: Int, _ item: SoundLevelsRemeasureItem, _ r: SoundLevelsRemeasureRules.Result, _ detail: String) {
        guard sample.count < Self.sampleCap else { return }
        sample.append(Item(id: i, filename: item.filename, path: item.path, result: r, detail: detail))
    }

    // MARK: Saving

    /// Await an ACKNOWLEDGED durable save of the rewrites since the last one,
    /// then move the cursor. True when there was nothing to save or it is on disk.
    private func persist(model: VideoScanModel, marker: inout SoundLevelsRemeasureMarker) async -> Bool {
        if !pending.isEmpty {
            let n = pending.count
            subtitleText = "Saving the catalog (\(n) card\(n == 1 ? "" : "s") rewritten)…"
            let ok: Bool
            if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
            guard ok else { saveFailed = true; return false }
            savedCount += n
            pending.removeAll()
        }
        lastSave = Date()
        if let cursor = pendingCursor {
            marker.cursor = cursor
            pendingCursor = nil
            writeMarker(marker, model: model)
            self.marker = marker
        }
        return true
    }

    /// A save was not acknowledged: stop, UNDO the unsaved rewrites
    /// (compare-and-set), keep the cursor where the last save left it.
    private func failSave(model: VideoScanModel) async {
        var undone = 0
        for p in pending {
            guard let rec = model.record(forID: p.item.id), rec.mediaReportCard == p.new else { continue }
            rec.mediaReportCard = p.old
            undone += 1
        }
        pending.removeAll()
        let message = "The catalog could not be saved — \(undone) card(s) rewritten since the last save were put back as they were; "
            + "\(savedCount) saved earlier are kept; no media was changed. Stopped; it continues from here once the catalog can be saved."
        summaryLine = message
        note("OUTCOME — \(message)", model: model)
        finish(failed: message)
    }

    private func writeMarker(_ m: SoundLevelsRemeasureMarker, model: VideoScanModel) {
        do { try m.save(catalogFile: catalogFile) } catch {
            note("the marker \(SoundLevelsRemeasureMarker.fileName) could not be written (\(error.localizedDescription)) — a later run measures some cards again; nothing is lost", model: model)
        }
    }

    // MARK: The sink

    /// The one sink: console + catalog.log (`log`), videoscan.log, unified log.
    func note(_ line: String, model: VideoScanModel) {
        let text = "\(Self.title): \(line)"
        model.log(text)
        appLog.write("[remeasure-sound] " + text)
        remeasureLog.notice("\(text, privacy: .public)")
    }

    // MARK: Finish

    private func refuse(_ why: String, model: VideoScanModel) {
        wasRefused = true
        note("refused — \(why). Nothing was read or changed.", model: model)
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
        subtitleText = "Stopped — \(savedCount) card(s) saved; running it again continues where it stopped"
        isIndeterminateValue = false
        pauseRequested = false
    }

    // MARK: Pure pieces

    /// "12 card(s): 10 measured before 25 Nov 2026 at 09:00, 2 withdrawn earlier …"
    nonisolated static func startClause(_ plan: [SoundLevelsRemeasureItem], marker: SoundLevelsRemeasureMarker) -> String {
        let withdrawn = plan.filter { $0.need == .withdrawn }.count
        return "\(plan.count) card(s): \(plan.count - withdrawn) checked before \(marker.cutoff.formatted(date: .abbreviated, time: .shortened)) "
            + "with sound levels on the Sound row, \(withdrawn) withdrawn earlier and waiting to be measured; "
            + "read-only on media — rewrites only each card's Sound row"
    }

    /// "Measured again 10 · sound changes partway 1 · withdrawn 2 (not connected 2)".
    nonisolated static func summaryCounts(_ t: Totals) -> String {
        var parts = ["Measured again \(t.refreshed)", "sound changes partway \(t.reconfigured)"]
        var why: [String] = []
        if t.offline > 0 { why.append("not connected \(t.offline)") }
        if t.notFound > 0 { why.append("not at its path \(t.notFound)") }
        if t.changed > 0 { why.append("changed on disk \(t.changed)") }
        if t.failed > 0 { why.append("could not measure \(t.failed)") }
        parts.append("withdrawn \(t.withdrawn)" + (why.isEmpty ? "" : " (\(why.joined(separator: ", ")))"))
        if t.changedMeanwhile > 0 { parts.append("changed meanwhile \(t.changedMeanwhile)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Today's sound pass (I/O)

    /// Stat the file (present, same size as the card), then Check Media's own
    /// sound pass. A missing ffmpeg THROWS (the job stops; never "could not
    /// measure the file"); Stop throws CancellationError.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func measureFile(path: String, expectedSize: Int64,
                                        isOnline: @Sendable (String) -> Bool) async throws -> SoundLevelsRemeasureRules.Remeasured {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .notMeasured(isOnline(path) ? .notFound : .offline)
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else { return .notMeasured(.changed) }
        do {
            return .measured(try await VerifyAudioProbe.diagnose(path: path))
        } catch is CancellationError {
            throw CancellationError()
        } catch AudioVerifyProbeError.toolUnavailable(let why) {
            throw AudioVerifyProbeError.toolUnavailable(why)
        } catch let AudioVerifyProbeError.probeFailed(why) {
            return .notMeasured(.failed(why))
        } catch {
            return .notMeasured(.failed(error.localizedDescription))
        }
    }
}

// MARK: - Starting it

extension MediaFileOperationsCenter {
    /// Start "Re-measure sound levels". One run at a time — a second request
    /// is refused (parked, nothing started).
    @discardableResult
    func startSoundLevelsRemeasure(model: VideoScanModel) -> SoundLevelsRemeasureJob {
        let job = SoundLevelsRemeasureJob(model: model)
        job.gatesFor = { [weak self] path in self?.gatePlan(forPaths: [path]) ?? [] }
        add(job)
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is SoundLevelsRemeasureJob }) {
            job.refuseToStart(reason: "Re-measure sound levels is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "measure the sound again on Verify report cards saved before the fix (#516); read-only on media"))
        return job
    }
}
