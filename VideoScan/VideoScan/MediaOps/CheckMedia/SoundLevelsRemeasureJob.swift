// SoundLevelsRemeasureJob.swift — "Re-measure sound levels", the MFO job
// (GH #516; DECISIONS 2026-11-25). Rules and the card stamp: SoundLevelsRemeasure.swift.
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
//   * The ONLY write is the card's Sound row, `soundMeasuredSilent`, its
//     `soundLevels` stamp and (when the row's verdict changed) the headline.
//   * Cards are stored per DIGEST (`media_checks`), so one content is ONE
//     plan item. Its write is ONE synchronous main-actor step with no await
//     inside (Codex closing pass, P0-1/P0-2): (a) find the content's copies
//     BY DIGEST in the live records at that moment; (b) every copy must hold
//     the card the plan read, and so must the card catalog.sqlite held (read
//     just before, async); (c) write every copy; (d) commit exactly those
//     rows now (`CatalogCommitter.commitNow(ids:)`, the committer's scoped
//     synchronous door; `saveCatalogNow` on the JSON store). Nothing the job
//     made dirty is left lying around while another await runs; a commit
//     that is refused (a write hold, a read-only flip) puts that content
//     back exactly as it was and stops the run. Anything that fails (a or b)
//     is left as it is ("left alone"); it stays a candidate.
//   * Resume needs no cursor: a rewritten card carries the stamp, so Stop,
//     quit or a crash leaves exactly the cards not yet rewritten as
//     candidates (a withdrawn one is tried again — a stat, if its drive is away).
//   * Refused on a read-only catalog (viewer Mac) and when ffmpeg is missing
//     (a missing tool is never "could not measure the file").
//   * One file at a time, holding its volume gate while it reads. Pause
//     takes effect between files; Stop terminates the running ffmpeg.
//   * Rows are never added or removed: OUTCOME says rows before = after.
//
// Cost of (a): one pass over the records per content written (~ms at 100k)
// — beside seconds of decoding per file.
// Memory: the plan (~400 B per content, ~40 MB at 100k), one content's
// (copy, old card) pairs during its write, every problem row, and at most
// `sampleCap` other rows. Nothing scales with media size.
//
// (For Rick: `@MainActor final class` ≈ an object whose methods all run on
// the UI thread; the ffmpeg wait happens off it inside `measure`, which is
// `@concurrent` ≈ "always runs on the worker pool".)

import Combine
import Foundation
import os
import VideoScanCore

private let remeasureLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "remeasureSoundLevels")

/// One CONTENT the job will measure again (its card is stored per digest).
/// A small value: no card copy.
struct SoundLevelsRemeasureItem: Sendable, Equatable {
    /// The record the plan read the card from.
    let id: UUID
    /// The content's whole-file digest (the store's key); nil = held row.
    let digest: String?
    let filename: String
    /// Every planned copy's path; the first on a connected drive is read.
    let paths: [String]
    let need: SoundLevelsRemeasureRules.Need
    /// The card the plan read: compared again before the write.
    let checkedAt: Date
    let soundRow: MediaCheck
    let fileSizeBytes: Int64

    var path: String { paths.first ?? "" }

    /// The row's key: its digest, else the row itself.
    @MainActor
    static func key(_ r: VideoRecord) -> String { CatalogCommit.digest(of: r) ?? "row:" + r.id.uuidString }

    /// Every candidate content, one item per digest, in key order.
    /// O(records), main actor (the records live there).
    @MainActor
    static func plan(_ records: [VideoRecord]) -> [SoundLevelsRemeasureItem] {
        var byKey: [String: SoundLevelsRemeasureItem] = [:]
        for r in records {
            guard let card = r.mediaReportCard,
                  let need = SoundLevelsRemeasureRules.need(card, live: r.removal == nil),
                  let row = card.check(.sound) else { continue }
            let k = key(r)
            if let first = byKey[k] {
                byKey[k] = SoundLevelsRemeasureItem(id: first.id, digest: first.digest, filename: first.filename,
                                                    paths: first.paths + [r.fullPath], need: first.need,
                                                    checkedAt: first.checkedAt, soundRow: first.soundRow,
                                                    fileSizeBytes: first.fileSizeBytes)
                continue
            }
            byKey[k] = SoundLevelsRemeasureItem(id: r.id, digest: CatalogCommit.digest(of: r), filename: r.filename,
                                                paths: [r.fullPath], need: need, checkedAt: card.checkedAt,
                                                soundRow: row, fileSizeBytes: card.fileSizeBytes)
        }
        return byKey.keys.sorted().compactMap { byKey[$0] }
    }

    /// The live records holding `key` now (by digest; a held row is itself).
    /// O(records), main actor.
    @MainActor
    static func copiesNow(_ records: [VideoRecord], key k: String) -> [VideoRecord] {
        if k.hasPrefix("row:") { return records.filter { "row:" + $0.id.uuidString == k } }
        return records.filter { CatalogCommit.digest(of: $0) == k }
    }

    /// Contents withdrawn because their drive was not connected: on drives
    /// still away (`cards`, `drives`) and ready now — ANY copy's drive is
    /// connected (`ready`, Codex closing P2-5). One per content. O(records),
    /// main actor; `isOnline` is the app's volume signal.
    @MainActor
    static func waiting(_ records: [VideoRecord], isOnline: (String) -> Bool) -> SoundLevelsRemeasureWaiting {
        var byKey: [String: [String]] = [:]
        for r in records where r.removal == nil {
            guard let card = r.mediaReportCard, card.tier == .full,
                  SoundLevelsRemeasureRules.isWaitingForDrive(card) else { continue }
            byKey[key(r), default: []].append(r.fullPath)
        }
        var w = SoundLevelsRemeasureWaiting()
        for paths in byKey.values {
            if paths.contains(where: isOnline) {
                w.ready += 1
            } else {
                w.cards += 1
                for p in paths { w.drives.insert(SoundLevelsRemeasureRules.driveKey(p)) }
            }
        }
        return w
    }

    /// Whether the scheduler should start the job, from the cards alone: a
    /// content with levels from an unstamped pass that is NOT in the
    /// left-alone set with the same fingerprint (P1-3), or a content waiting
    /// for a drive that is connected now. O(records).
    @MainActor
    static func autoRunDue(_ records: [VideoRecord], isOnline: (String) -> Bool,
                           leftAlone: [String: String] = [:]) -> Bool {
        var prefixKeys: Set<String> = []
        for r in records where SoundLevelsRemeasureRules.need(r.mediaReportCard, live: r.removal == nil) == .prefix {
            prefixKeys.insert(key(r))
        }
        for k in prefixKeys {
            guard let fp = leftAlone[k] else { return true }
            if SoundLevelsRemeasureRules.fingerprint(copiesNow(records, key: k)) != fp { return true }
        }
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

/// The card catalog.sqlite holds for a digest, read just before a write.
enum SoundLevelsStoredCard: Sendable {
    /// No SQLite store (or no card stored for it yet).
    case none
    case card(MediaReportCard)
    /// Could not be read or decoded: refuse rather than guess.
    case unreadable(String)
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
        /// Cards written (every copy of a content counts).
        var cardsWritten = 0
        /// Of `changedMeanwhile`: contents whose copies' cards differ.
        var copiesDiffer = 0
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
    /// TEST SEAM: replaces the scoped synchronous commit of one content's
    /// rows. nil in production (`commitRows`).
    var commitForTesting: (@MainActor ([UUID]) -> Bool)?
    /// The card catalog.sqlite holds for a digest (P0-1). Production reads
    /// the committer's repository; with no SQLite store there is none.
    var storedCard: @MainActor (String) async -> SoundLevelsStoredCard = { _ in .none }
    var now: () -> Date = { Date() }
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
    /// Cards whose commit landed.
    private(set) var savedCount = 0
    private(set) var saveFailed = false
    private(set) var summaryLine = ""

    /// Contents left alone because their copies' cards differ: key →
    /// fingerprint of those cards (the scheduler's "not due again" set, P1-3).
    private(set) var leftAloneKeys: [String: String] = [:]
    /// Catalog rows at START (OUTCOME's "before", Codex P2-7).
    private(set) var rowsAtStart = 0
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
        self.storedCard = { [weak model] digest in
            await Self.readStoredCard(model?.catalogCutover.committer?.repository, digest: digest)
        }
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
        rowsAtStart = model.records.count
        let plan = SoundLevelsRemeasureItem.plan(model.records)
        totals.total = plan.count
        isIndeterminateValue = plan.isEmpty
        note("START — \(Self.startClause(plan)); catalog rows \(rowsAtStart)", model: model)
        runStart = Date()
        for (i, item) in plan.enumerated() {
            guard await waitOutPause() else { break }
            guard await turn(item, index: i, model: model) else { break }
            totals.done = i + 1
            fractionValue = Double(i + 1) / Double(max(1, plan.count))
            if totals.done % max(1, progressLineEvery) == 0 {
                note("progress — \(totals.done) of \(totals.total) · \(Self.summaryCounts(totals))", model: model)
            }
        }
        rememberLeftAlone(plan)
        if saveFailed { return }
        if let why = toolLost {
            summaryLine = Self.summaryCounts(totals)
            let message = "ffmpeg went away mid-run (\(why)) — stopped after \(totals.done) of \(totals.total); \(savedCount) card(s) saved are kept; it continues from here once ffmpeg is back"
            note("OUTCOME — \(message)", model: model)
            finish(failed: message)
            return
        }
        conclude(model: model)
    }

    private func conclude(model: VideoScanModel) {
        summaryLine = Self.summaryCounts(totals)
        let rows = Self.rowsClause(before: rowsAtStart, after: model.records.count, written: totals.cardsWritten)
        if stopped {
            note("OUTCOME stopped at \(totals.done) of \(totals.total) — \(summaryLine); \(rows)", model: model)
            finish(cancelled: ())
            return
        }
        // Work still owed is said, never "done" (coordinator, #516 review):
        // cards withdrawn for an absent drive wait for it.
        let waiting = SoundLevelsRemeasureItem.waiting(model.records, isOnline: isOnline)
        if let words = waiting.words { summaryLine += " · " + words }
        note("OUTCOME — \(summaryLine); \(rows)", model: model)
        finish(success: totals.total == 0 && waiting.cards == 0
               ? "Nothing to do — every saved card's sound levels come from today's measurement" : summaryLine)
    }

    /// One content's turn: measure, read the stored card, write. False when
    /// the run must stop (Stop, or ffmpeg went away).
    private func turn(_ item: SoundLevelsRemeasureItem, index i: Int, model: VideoScanModel) async -> Bool {
        guard let outcome = await measureOne(item, index: i) else { return false }
        let stored: SoundLevelsStoredCard = if let d = item.digest { await storedCard(d) } else { .none }
        guard !stopped else { return false }
        record(outcome, for: item, stored: stored, index: i, model: model)
        return !saveFailed
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
        let path = item.paths.first(where: isOnline) ?? item.path
        guard let permits = await acquireGates(for: path) else { return nil }
        if !pauseRequested {
            subtitleText = PerceptualFingerprintBackfillJob.progressLine(done: i, total: totals.total, current: item.filename,
                                                                         elapsed: Date().timeIntervalSince(runStart))
        }
        let measure: Measure = self.measure ?? { [isOnline] path, size in
            try await Self.measureFile(path: path, expectedSize: size, isOnline: isOnline)
        }
        let pass = Task { try await measure(path, item.fileSizeBytes) }
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

    /// ONE synchronous step per content — no await from here to the commit
    /// (P0-1/P0-2): find its copies by digest NOW, check each card and the
    /// stored snapshot against the card the plan read, write every copy,
    /// commit exactly those rows. Refused commit → put back, stop.
    private func record(_ r: SoundLevelsRemeasureRules.Remeasured, for item: SoundLevelsRemeasureItem,
                        stored: SoundLevelsStoredCard, index i: Int, model: VideoScanModel) {
        guard let rec = model.record(forID: item.id), let card = rec.mediaReportCard,
              card.checkedAt == item.checkedAt, card.check(.sound) == item.soundRow else {
            return leftAlone(i, item, "its card changed in the catalog during the run (checked again, or removed)")
        }
        let key = SoundLevelsRemeasureItem.key(rec)
        let copies = SoundLevelsRemeasureItem.copiesNow(model.records, key: key)
        guard copies.allSatisfy({ $0.mediaReportCard.map { SoundLevelsRemeasureRules.sameCard($0, card) } ?? false }) else {
            leftAloneKeys[key] = SoundLevelsRemeasureRules.fingerprint(copies)
            totals.copiesDiffer += 1
            return leftAlone(i, item, "its copies' cards differ (a copy was checked again)")
        }
        switch stored {
        case .none: break
        case .card(let c) where SoundLevelsRemeasureRules.sameCard(c, card): break
        case .card:
            return leftAlone(i, item, "the card stored for this content differs from the one read (a copy was checked again)")
        case .unreadable(let why):
            return leftAlone(i, item, "the stored card for this content could not be read (\(why))")
        }
        var before: [(VideoRecord, MediaReportCard)] = []
        for copy in copies {
            guard let old = copy.mediaReportCard else { continue }
            let new = SoundLevelsRemeasureRules.rewrite(old, with: r, context: copy.soundPresenceContext)
            guard new != old else { continue }
            copy.mediaReportCard = new
            before.append((copy, old))
        }
        leftAloneKeys[key] = nil
        if !before.isEmpty {
            guard commitRows(before.map(\.0.id), model: model) else {
                for (copy, old) in before { copy.mediaReportCard = old }
                return failCommit(item, model: model)
            }
            savedCount += before.count
            totals.cardsWritten += before.count
        }
        tally(SoundLevelsRemeasureRules.result(of: r), i, item, model: model)
    }

    /// Commit exactly these rows now, synchronously: the committer's scoped
    /// door under catalog.sqlite, else the JSON store's synchronous save.
    private func commitRows(_ ids: [UUID], model: VideoScanModel) -> Bool {
        if let commitForTesting { return commitForTesting(ids) }
        if let committer = model.catalogCutover.committer {
            model.noteCatalogMutated()
            return committer.commitNow(ids: Set(ids))
        }
        return model.saveCatalogNow()
    }

    /// A refused commit: that content is back exactly as it was; stop.
    private func failCommit(_ item: SoundLevelsRemeasureItem, model: VideoScanModel) {
        saveFailed = true
        let message = "The catalog could not be saved — \(item.filename)'s card was put back as it was; "
            + "\(savedCount) card(s) saved earlier are kept; no media was changed. Stopped; it continues from here once the catalog can be saved."
        summaryLine = message
        note("OUTCOME — \(message)", model: model)
        finish(failed: message)
    }

    /// Keep the left-alone set beside the catalog (the scheduler reads it):
    /// this run's skips replace earlier entries for the contents it planned.
    private func rememberLeftAlone(_ plan: [SoundLevelsRemeasureItem]) {
        var schedule = SoundLevelsRemeasureSchedule.load(catalogFile: catalogFile)
        guard let model else { return }
        for item in plan {
            guard let rec = model.record(forID: item.id) else { continue }
            schedule.leftAlone[SoundLevelsRemeasureItem.key(rec)] = nil
        }
        schedule.leftAlone.merge(leftAloneKeys) { $1 }
        try? schedule.save(catalogFile: catalogFile)
    }

    private func leftAlone(_ i: Int, _ item: SoundLevelsRemeasureItem, _ why: String) {
        totals.changedMeanwhile += 1
        problems.append(Item(id: i, filename: item.filename, path: item.path, result: nil,
                             detail: "\(why) — left as it is; it stays a candidate"))
    }

    private func tally(_ result: SoundLevelsRemeasureRules.Result, _ i: Int, _ item: SoundLevelsRemeasureItem,
                       model: VideoScanModel) {
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

    /// "12 content(s): 10 with sound levels from an earlier measurement, 2 withdrawn earlier …"
    nonisolated static func startClause(_ plan: [SoundLevelsRemeasureItem]) -> String {
        let withdrawn = plan.filter { $0.need == .withdrawn }.count
        return "\(plan.count) content(s): \(plan.count - withdrawn) with sound levels from an earlier measurement, "
            + "\(withdrawn) withdrawn earlier and waiting to be measured; "
            + "read-only on media — rewrites only each card's Sound row"
    }

    /// "catalog rows before 100 · after 101 · difference +1 from other work during the run (…)" — `before` is
    /// counted at START (Codex P2-7). Pure.
    nonisolated static func rowsClause(before: Int, after: Int, written: Int) -> String {
        let diff = after - before
        return "catalog rows before \(before) · after \(after) · "
            + (diff == 0 ? "difference none" : "difference \(diff > 0 ? "+" : "")\(diff) from other work during the run")
            + " (this job adds and removes none; \(written) card(s) rewritten in place)"
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
        if t.copiesDiffer > 0 { parts.append("\(t.copiesDiffer) file\(t.copiesDiffer == 1 ? "" : "s") left alone: their copies' cards differ") }
        let meanwhile = t.changedMeanwhile - t.copiesDiffer
        if meanwhile > 0 { parts.append("changed meanwhile \(meanwhile)") }
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
            // The drive went away mid-read: it waits for the drive (P2-5).
            return .notMeasured(isOnline(path) ? .failed(why) : .offline)
        } catch {
            return .notMeasured(isOnline(path) ? .failed(error.localizedDescription) : .offline)
        }
    }

    /// The card catalog.sqlite holds for `digest` (no repository → none).
    static func readStoredCard(_ repository: (any CatalogRepository)?, digest: String) async -> SoundLevelsStoredCard {
        guard let repository else { return .none }
        do {
            let json = try await repository.read { try $0.storedReportCardJSON(digest: digest) }
            guard let json else { return .none }
            guard let value = CatalogJSONValue.parse(json),
                  let card = try? CatalogJSONValueDecoder().decode(MediaReportCard.self, from: value) else {
                return .unreadable("its JSON does not decode")
            }
            return .card(card)
        } catch {
            return .unreadable(error.localizedDescription)
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
