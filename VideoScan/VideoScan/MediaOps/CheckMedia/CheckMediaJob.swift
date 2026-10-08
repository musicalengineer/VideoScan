import Combine
import Foundation
import os

// MARK: - CheckMediaJob (Rick 2026-10-07)
//
// "Verify…" (the menu verb was "Check Media…" until 2026-10-08; the type,
// the kind case and the Logger category keep the old name) as ONE Media
// File Operations job for the whole selection
// (the CLAUDE.md long-operations rule): verb chip · "N of M" · current file
// · step · time left · progress · Pause / Stop; double-click for every
// file's report card; a one-line summary when finished; START / OUTCOME to
// the console, catalog.log and videoscan.log through the Center's sink.
//
// Per file: quick tier (CheckMediaProbe.quick), then — for a full check —
// the full tier (the Verify Video decode + the Verify Audio levels pass).
// Then:
//   - the report card goes on the record (`mediaReportCard`, additive);
//   - a COMPLETE video / audio diagnosis is written to the verify fields
//     by the Verify jobs' own writers, so every existing reader keeps one
//     meaning; the audio diagnosis also lands in the Center's session
//     cache (the Archive Angel's prepare step reads it as a cache hit);
//   - a file that couldn't be read writes NOTHING ("couldn't check" is
//     not a verdict).
//
// Memory: per file ≈ 1.6 MB of probe text (CheckMediaProbe header); the
// job keeps one report card per file (a few KB each) — 1,000 files ≈ a
// few MB.
//
// Concurrency: the job is @MainActor (≈ "all members on the UI thread");
// the probe's entry points are @concurrent, so the heavy work never runs
// here. Pause = SIGSTOP on the live child + lend the volume slot back.

private let checkMediaJobLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "checkMedia")

/// One file's line in the job's detail.
struct CheckMediaItem: Identifiable, Sendable {
    enum Outcome: Sendable {
        case waiting
        case running(step: String)
        case checked(MediaReportCard)
        case failed(String)
        case cancelled
    }
    let id: UUID
    let filename: String
    var outcome: Outcome
}

@MainActor
final class CheckMediaJob: @MainActor MediaFileOperationJob {

    typealias QuickRunner = @Sendable (String, ProcessControl) async throws -> CheckMediaProbe.QuickOutcome
    typealias FullRunner = @Sendable (String, MediaFacts, ProcessControl,
                                      @escaping CheckMediaProbe.FullProgress) async throws -> CheckMediaFullInputs

    let id = UUID()
    let kind: MediaFileOperationKind = .checkMedia
    let startedAt = Date()
    let records: [VideoRecord]
    let tier: MediaReportCard.Tier

    @Published private(set) var items: [CheckMediaItem]
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to start…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false

    private weak var model: VideoScanModel?
    private weak var center: MediaFileOperationsCenter?
    private let gatesFor: (String) -> [MediaVolumeGate]
    private let quickRunner: QuickRunner
    private let fullRunner: FullRunner
    private let pauser = JobPauseCoordinator()
    private var hold: MediaVolumeGateHold?

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    init(records: [VideoRecord],
         tier: MediaReportCard.Tier,
         model: VideoScanModel?,
         center: MediaFileOperationsCenter?,
         gatesFor: @escaping (String) -> [MediaVolumeGate] = { _ in [] },
         quickRunner: QuickRunner? = nil,
         fullRunner: FullRunner? = nil) {
        self.records = records
        self.tier = tier
        self.model = model
        self.center = center
        self.gatesFor = gatesFor
        self.items = records.map { CheckMediaItem(id: $0.id, filename: $0.filename, outcome: .waiting) }
        self.quickRunner = quickRunner ?? { try await CheckMediaProbe.quick(path: $0, control: $1) }
        self.fullRunner = fullRunner ?? { path, facts, control, progress in
            try await CheckMediaProbe.full(path: path, facts: facts, control: control, progress: progress)
        }
    }

    // MARK: MediaFileOperationJob

    var title: String {
        records.count == 1 ? records[0].filename : "\(records.count) files"
    }
    var subtitle: String {
        if let w = hold?.waiting { return VolumeGateBoard.describeWait(label: w.label, root: w.root) }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    let canPause = true
    var isPaused: Bool { isPausedValue }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
        if task == nil { state = .cancelled }
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
        checkMediaJobLog.info("verify media START: \(self.records.count) file(s), tier=\(self.tier.rawValue, privacy: .public)")
        for index in records.indices {
            guard !Task.isCancelled, state != .cancelling else { break }
            await waitWhilePaused()
            let rec = records[index]
            let hold = MediaVolumeGateHold(jobID: id, holderName: "Verify \(rec.filename)")
            self.hold = hold
            guard await hold.acquire(gatesFor(rec.fullPath), isPaused: { [weak self] in self?.isPausedValue ?? false }) else {
                break
            }
            await checkOne(rec, index: index)
            await hold.close()
            self.hold = nil
        }
        finish()
    }

    private func waitWhilePaused() async {
        while isPausedValue, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func checkOne(_ rec: VideoRecord, index: Int) async {
        let path = rec.fullPath
        setStep("reading the header", index: index, within: 0)
        do {
            switch try await quickRunner(path, pauser.control) {
            case .unopenable(let detail, let size):
                let card = CheckMediaRules.unopenableCard(detail: detail, sizeBytes: size, at: Date())
                persist(card: card, video: VerifyVideoProbe.unopenableDiagnosis(detail: detail, sizeBytes: size),
                        audio: nil, on: rec, index: index)
            case .measured(let quick):
                try await checkMeasured(quick, rec: rec, index: index)
            }
        } catch is CancellationError {
            items[index].outcome = .cancelled
        } catch {
            if Task.isCancelled || state == .cancelling {
                items[index].outcome = .cancelled
                return
            }
            let reason = Self.failureReason(error)
            items[index].outcome = .failed(reason)
            model?.log("Verify: \(rec.filename) — couldn't check: \(reason)")
            checkMediaJobLog.notice("verify media: \(rec.filename, privacy: .public) couldn't check — \(reason, privacy: .public)")
        }
    }

    private func checkMeasured(_ quick: CheckMediaQuickInputs, rec: VideoRecord, index: Int) async throws {
        var checks = CheckMediaRules.quickChecks(quick)
        var video = CheckMediaRules.conclusiveVideoDiagnosis(quick)
        var audio: AudioVerifyDiagnosis?
        if tier == .full {
            setStep("decoding every frame", index: index, within: 0.1)
            // Each phase fills its own slice of this file's bar (FullPhase.span).
            let progress: CheckMediaProbe.FullProgress = { [weak self] phase, f in
                let span = phase.span
                let within = span.lowerBound + (span.upperBound - span.lowerBound) * f
                Task { @MainActor in self?.setStep(phase.step, index: index, within: within) }
            }
            let full = try await fullRunner(rec.fullPath, quick.facts, pauser.control, progress)
            try Task.checkCancellation()
            checks = CheckMediaRules.merging(checks, with: CheckMediaRules.fullChecks(full, facts: quick.facts))
            if case .success(let d)? = full.video { video = d }
            if case .success(let d)? = full.audio { audio = d }
        } else {
            setStep("checking frame windows", index: index, within: 0.9)
            checks += CheckMediaRules.fullRowsNotRun()
        }
        let card = CheckMediaRules.card(tier: tier, checks: checks, quick: quick, at: Date())
        persist(card: card, video: video, audio: audio, on: rec, index: index)
    }

    /// Writes onto the CURRENT catalog object (a rescan may have replaced
    /// the instance mid-run — resolve by UUID, the Verify jobs' rule).
    private func persist(card: MediaReportCard, video: VideoVerifyDiagnosis?, audio: AudioVerifyDiagnosis?,
                         on rec: VideoRecord, index: Int) {
        let current = model?.records.first { $0.id == rec.id } ?? rec
        let now = Date()
        current.mediaReportCard = card
        if let video { VerifyVideoJob.write(video, onto: current, at: now) }
        if let audio {
            VerifyAudioJob.write(audio, onto: current, at: now)
            center?.storeVerifyDiagnosis(audio, forRecordID: rec.id)
        }
        model?.saveCatalogDebounced()
        items[index].outcome = .checked(card)
        model?.log("Verify: \(rec.filename) → \(card.verdictWord) — \(card.headline)")
        checkMediaJobLog.info("verify media: \(rec.filename, privacy: .public) → \(card.verdictWord, privacy: .public): \(card.headline, privacy: .public)")
    }

    private func setStep(_ step: String, index: Int, within: Double) {
        items[index].outcome = .running(step: step)
        let overall = (Double(index) + min(1, max(0, within))) / Double(max(records.count, 1))
        if overall - fractionValue >= 0.005 || overall < fractionValue { fractionValue = overall }
        let left = Self.timeLeftText(elapsed: Date().timeIntervalSince(startedAt), fraction: fractionValue)
        subtitleText = "\(index + 1) of \(records.count) — \(records[index].filename): \(step)…" + (left.map { " · \($0)" } ?? "")
    }

    private func finish() {
        if state == .cancelling || Task.isCancelled {
            for i in items.indices { if case .waiting = items[i].outcome { items[i].outcome = .cancelled } }
            state = .cancelled
            subtitleText = "Cancelled"
            return
        }
        fractionValue = 1
        let summary = Self.summary(items)
        state = .finished(summary: summary)
        subtitleText = summary
        checkMediaJobLog.info("verify media DONE: \(summary, privacy: .public)")
    }

    // MARK: Pure helpers (tested)

    static func failureReason(_ error: Error) -> String {
        switch error {
        case CheckMediaProbe.ProbeError.toolUnavailable(let s): return s
        case CheckMediaProbe.ProbeError.couldNotRead(let s): return s
        default: return error.localizedDescription
        }
    }

    /// "about 3 min left" once there is enough history to say (≥ 5 s and
    /// ≥ 2 %); nil before that.
    static func timeLeftText(elapsed: TimeInterval, fraction: Double) -> String? {
        guard elapsed >= 5, fraction >= 0.02, fraction < 1 else { return nil }
        let left = elapsed / fraction * (1 - fraction)
        if left < 60 { return "under a minute left" }
        return "about \(VerifyVideoRules.durationText(left)) left"
    }

    /// The one-line finished summary: "3 checked — 1 problem, 1 warning, 1 OK".
    /// A quick pass is never "OK": it is "no problems in the quick check".
    static func summary(_ items: [CheckMediaItem]) -> String {
        if items.count == 1, case .checked(let card) = items[0].outcome {
            return card.isQuickPassOnly ? card.displayHeadline : "\(card.verdict.word) — \(card.headline)"
        }
        let tally = CheckMediaTally(items)
        let parts = tally.parts
        return "\(tally.checked) checked — " + (parts.isEmpty ? "nothing to report" : parts.joined(separator: ", "))
    }
}

/// How a finished selection came out, counted once. A quick pass is its
/// own outcome (never folded into "OK").
struct CheckMediaTally: Equatable {
    var problem = 0, warning = 0, ok = 0, quickPass = 0, failed = 0

    init(_ items: [CheckMediaItem]) {
        for item in items { add(item.outcome) }
    }

    private mutating func add(_ outcome: CheckMediaItem.Outcome) {
        switch outcome {
        case .checked(let card) where card.isQuickPassOnly: quickPass += 1
        case .checked(let card) where card.verdict == .problem: problem += 1
        case .checked(let card) where card.verdict == .warning: warning += 1
        case .checked: ok += 1
        case .failed: failed += 1
        default: break
        }
    }

    var checked: Int { problem + warning + ok + quickPass }

    /// "1 problem", "2 warnings", … in reading order; empty counts omitted.
    var parts: [String] {
        [(problem, problem == 1 ? "problem" : "problems"),
         (warning, warning == 1 ? "warning" : "warnings"),
         (ok, "OK"),
         (quickPass, "with no problems in the quick check"),
         (failed, "couldn't be checked")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
    }
}
