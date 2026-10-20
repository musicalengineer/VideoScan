// AudioFingerprintBackfillJob.swift
// "Fingerprint Sound…" — the Media File Operation (Rick 2026-10-14): decode
// every planned file's sound through ffmpeg (AudioPCMDecoder), compute its
// landmark fingerprint (AudioFingerprint), keep the bytes in the sidecar
// (AudioFingerprintStore) and a small stamp on the catalog record. Built to
// run overnight on the real catalog and survive a crash.
//
// Shape (FullHashBackfillJob's, with PerceptualFingerprintBackfillJob's
// save/undo contract):
//   • One LANE per volume root, all lanes in parallel (a TaskGroup); inside
//     a lane one file at a time, archived first — so a drive sees ONE ffmpeg
//     reader. Each decode also holds the volume's MediaVolumeGate.
//   • MEMORY BUDGET (AudioDecodeBudget, pure): the decoder holds pipe bytes
//     + Int16 samples at once, ≈ 115 MB per hour of audio, 461 MB at the
//     4-hour cap. In-flight estimates sum to ≤ 1.5 GB, never more than 4
//     decodes; a file over the budget on its own runs alone. Worst case in
//     RAM: ~1.5 GB of PCM + the pending batch of fingerprints (≤ 25 × ~2 MB).
//   • SHARED: before decoding, the sidecar (and this run's pending batch) is
//     asked for the record's digest; a copy done earlier → stamp, no decode.
//     A record the catalog knows is video-only → "no sound" stamp, no decode.
//   • DURABILITY: every `checkpointFiles` (25) stamps or `checkpointSeconds`
//     (60 s), on Stop and at the end, the job writes the pending
//     fingerprints to the sidecar in ONE transaction and THEN awaits an
//     acknowledged catalog save (`saveCatalogAcknowledged`). Sidecar first,
//     so a stamp on disk always has its bytes. A failed sidecar write or an
//     unacknowledged save stops the job and UNDOES the unsaved stamps
//     (compare-and-set), so the next run redoes exactly those files; a
//     sidecar row without a stamp is harmless (it is found as "shared").
//   • RESUME: a record with a current stamp is not planned, so the next run
//     continues where this one stopped. No resume file.
//   • STOP finishes the files being decoded, then saves (Rick's brief);
//     no new file starts. A QUIT cuts the decodes (ProcessRunner kills
//     ffmpeg), records them "cut off", then saves what was done.
//   • A decode that fails is recorded on the item with ffmpeg's stderr tail;
//     the lane goes on. Zero samples from a file whose header names a codec
//     is a failed decode too — never "no sound", never "silent".
//   • SILENCE IS MEASURED (stamp rule 4, 2026-10-20): a print with no
//     landmark is stamped only when its audible-seconds bitmap says every
//     second was quiet (`AudioFingerprintStamp.reading(of:)` = `.silence`).
//     A print that heard sound but too little to make one landmark (a 1.5 s
//     AVCHD clip peaking at −0.1 dB) is "heard too little" — listed, not
//     stamped, not kept in the sidecar, retried next run. A drive that goes away: that lane stops, its files
//     count "drive not connected", the other lanes go on. Offline drives are
//     skipped with a count at the start — never an error.
//   • The decoder's deadline is sized by the file (300 s + 1 s per 10 MB), a
//     hang guard, not a pace guard: ffmpeg reads the whole file to reach
//     its audio, and a 50 GB tape on a USB disk takes minutes.
//   • Refused before any read: read-only catalog; the shared catalog from a
//     test host; ffmpeg missing (names the Homebrew path); a sidecar that
//     cannot be opened (folder not writable, poisoned file, newer schema).
//
// READ-ONLY ON MEDIA: ffmpeg opens the file read-only and writes to a pipe.
// The only writes are the sidecar in the catalog's folder, the catalog's
// `audioFingerprint` field, catalog saves and log lines.
// AudioFingerprintBackfillSensorTests reads this source.
//
// Logging (one sink, `audioFingerprintNote`): START, a progress line every
// `progressLogFiles` (25) files or `progressLogSeconds` (60 s), every failed
// file, and the OUTCOME go to the console, catalog.log, videoscan.log and
// the unified log.
//
// (For Rick: `withTaskGroup` ≈ spawning N worker threads and joining them —
// except every lane's bookkeeping runs on the main actor, so the counters
// need no mutex; only the ffmpeg wait and the FFT hop off it.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore
import os

private let audioFingerprintLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fingerprintSound")

@MainActor
final class AudioFingerprintBackfillJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    static let title = "Fingerprint sound (archive first)"
    static let sampleCap = 500
    static let problemCap = 5_000

    /// What one file's pass produced (pure value; `record` interprets it).
    enum Outcome: Equatable, Sendable {
        /// A printable print, or one that MEASURED silence (stamped).
        case fingerprint(AudioFingerprint)
        /// Decoded, heard sound (`audibleSeconds` audible), made no landmark:
        /// not stamped — "too little to print" is never "silent".
        case heardTooLittle(AudioFingerprint, audibleSeconds: Int)
        /// Found under `key` — the stamp names THAT key, never another digest.
        case shared(key: AudioFingerprintStore.Key, AudioFingerprintStore.Summary)
        case noAudio(fromCatalog: Bool)
        case missing
        case failed(String)
        case cancelled
    }

    /// The decode + fingerprint pass for one file (tests inject a stub;
    /// production runs ffmpeg through AudioPCMDecoder).
    typealias Pass = @Sendable (_ item: AudioFingerprintBackfillItem) async throws -> AudioFingerprint

    let id = UUID()
    let kind: MediaFileOperationKind = .fingerprintSound
    let startedAt = Date()
    private weak var model: VideoScanModel?

    // Seams (tests replace them; production defaults).
    var gatesFor: @MainActor (String) -> [MediaVolumeGate] = { _ in [] }
    var volumeOnline: @Sendable (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// TEST SEAM: replaces the ffmpeg pass. nil in production.
    var passForTesting: Pass?
    /// TEST SEAM: replaces the acknowledged catalog save. nil in production.
    var saveCatalogForTesting: (@MainActor () async -> Bool)?
    /// TEST SEAM: replaces the sidecar batch write. nil in production.
    var sidecarPutForTesting: (@MainActor ([AudioFingerprintStore.Entry]) throws -> Void)?
    var ffmpegPath = ToolLocator.ffmpegPath
    /// The fingerprint recipe; validated once at start (a bad recipe is a
    /// named refusal, never a trap inside a lane).
    var parameters = AudioFingerprintParameters.default
    /// Where the sidecar lives (default: the catalog's folder).
    var storeDirectory: URL?
    /// The decoder's cap (the 4-hour default); tests shrink it to prove
    /// the partial stamp.
    var decoderMaxSeconds = AudioPCMDecoder.defaultMaxSeconds
    var checkpointFiles = 25
    var checkpointSeconds: TimeInterval = 60
    var progressLogFiles = 25
    var progressLogSeconds: TimeInterval = 60
    var tickMilliseconds = 1_000

    @Published private(set) var totals = AudioFingerprintBackfillTotals()
    @Published private(set) var lanes: [AudioFingerprintBackfillLaneStatus] = []
    /// Every file (or drive) that could not be done, in the order met.
    @Published private(set) var problems: [AudioFingerprintBackfillItemRow] = []
    /// The first `sampleCap` files stamped.
    @Published private(set) var sample: [AudioFingerprintBackfillItemRow] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// Stamps whose sidecar bytes AND catalog save were acknowledged.
    private(set) var storedCount = 0
    /// Acknowledged checkpoint saves (the final one included).
    private(set) var saveCount = 0
    private(set) var saveFailed = false
    private(set) var store: AudioFingerprintStore?

    /// Stamps written to records since the last acknowledged save (undone
    /// if that save fails) and the fingerprints behind them.
    private var unsavedStamps: [(item: AudioFingerprintBackfillItem, stamp: AudioFingerprintStamp)] = []
    private var pendingEntries: [AudioFingerprintStore.Key: AudioFingerprintStore.Entry] = [:]
    private var saving = false
    private var stopRequested = false
    private var lastSave = Date()
    private var lastProgressLog = Date()
    private var lastProgressLogDone = 0
    private var runStart = Date()
    /// Volume root → the file its lane is decoding now.
    private var reading: [String: String] = [:]
    /// Item id → catalog duration of every decode in flight (the budget).
    private var inFlight: [UUID: Double] = [:]
    private var laneIndex: [String: Int] = [:]
    private var rowID = 0

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }
    var detailView: AnyView { AnyView(AudioFingerprintBackfillDetailView(job: self)) }

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

    /// Stop: no new file starts; the files being decoded finish and are
    /// saved (Rick: "Stop must finish the in-flight item and save").
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        stopRequested = true
        let n = inFlight.count
        subtitleText = n > 0 ? "Stopping — finishing \(n) file\(n == 1 ? "" : "s") being read, then saving…"
            : "Stopping — saving the fingerprints made so far…"
    }

    /// Quit: cut the decodes (ProcessRunner kills ffmpeg), save what is done.
    func stopForQuit() {
        cancel()
        task?.cancel()
    }

    /// Pause takes effect between files (a decode cannot be suspended);
    /// no disk slot is held while paused.
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        subtitleText = "Pausing after the current file — \(totals.done.formatted()) of \(totals.planned.formatted()) done"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { stopRequested || Task.isCancelled || !state.isActive || state == .cancelling }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        if let why = refusal(model: model) {
            wasRefused = true
            model.audioFingerprintNote("refused — \(why). Nothing was read or changed.")
            finish(failed: "Refused — \(why). Nothing was read or changed.")
            return
        }
        let plan = model.audioFingerprintBackfillPlan()
        let split = await splitByConnection(plan.lanes)
        seed(plan, online: split.online, offline: split.offline)
        model.audioFingerprintNote("START — " + startClause(plan, online: split.online, offline: split.offline))
        runStart = Date(); lastSave = Date(); lastProgressLog = Date()
        let ticker = startTicker(model: model)
        await withTaskGroup(of: Void.self) { group in
            for lane in split.online {
                group.addTask { @MainActor in await self.runLane(lane, model: model) }
            }
        }
        ticker.cancel()
        await ticker.value
        await conclude(model: model)
    }

    /// Why the job must not start, in words — nil when it may.
    private func refusal(model: VideoScanModel) -> String? {
        if model.isReadOnly { return "this Mac is a read-only viewer of the catalog" }
        if TestEnvironment.isTestHost && model.catalogStore === CatalogStore.shared {
            return "the catalog in use is the shared one and this process is a test host"
        }
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            return "ffmpeg was not found at \(ffmpegPath) — install it with Homebrew (brew install ffmpeg) or set \(FFmpegLocator.ffmpegEnvVar)"
        }
        do { try parameters.validate() } catch {
            return "the fingerprint recipe is invalid (\(error)) — this build cannot fingerprint anything"
        }
        do {
            store = try AudioFingerprintStore(directory: storeDirectory ?? model.audioFingerprintSidecarDirectory)
        } catch let failure as AudioFingerprintStore.Failure {
            return failure.description
        } catch {
            return "the fingerprint file could not be opened: \(error.localizedDescription)"
        }
        return nil
    }

    /// Which drives are here — asked once per drive, off the main actor.
    private func splitByConnection(_ all: [AudioFingerprintBackfillLane]) async
        -> (online: [AudioFingerprintBackfillLane], offline: [AudioFingerprintBackfillLane]) {
        var online: [AudioFingerprintBackfillLane] = []
        var offline: [AudioFingerprintBackfillLane] = []
        for lane in all {
            if await rootIsOnline(lane.root) { online.append(lane) } else { offline.append(lane) }
        }
        return (online, offline)
    }

    private func rootIsOnline(_ root: String) async -> Bool {
        let probe = volumeOnline
        return await CheckCopiesJob.offMain { probe(root) }
    }

    private func seed(_ plan: AudioFingerprintBackfillPlan, online: [AudioFingerprintBackfillLane],
                      offline: [AudioFingerprintBackfillLane]) {
        totals.planned = online.reduce(0) { $0 + $1.items.count }
        totals.plannedBytes = online.reduce(Int64(0)) { $0 + $1.bytes }
        totals.archivedPlanned = online.reduce(0) { $0 + $1.archivedCount }
        totals.alreadyStamped = plan.alreadyStamped
        totals.noDigest = plan.noDigest
        for lane in offline {
            totals.counts[.driveNotConnected, default: 0] += lane.items.count
            lanes.append(AudioFingerprintBackfillLaneStatus(root: lane.root, label: lane.label, planned: lane.items.count,
                                                            phase: .disconnected))
            addProblem(filename: lane.label, path: lane.root, drive: lane.label, archived: false, .driveNotConnected,
                       "drive not connected — its \(lane.items.count.formatted()) file(s) wait for a run with it connected")
        }
        for lane in online {
            laneIndex[lane.root] = lanes.count
            lanes.append(AudioFingerprintBackfillLaneStatus(root: lane.root, label: lane.label, planned: lane.items.count))
        }
    }

    private func startClause(_ plan: AudioFingerprintBackfillPlan, online: [AudioFingerprintBackfillLane],
                             offline: [AudioFingerprintBackfillLane]) -> String {
        let away = offline.reduce(0) { $0 + $1.items.count }
        var line = "\(totals.planned.formatted()) file(s) to look at (\(MediaBytes.display(totals.plannedBytes)); "
            + "\(totals.archivedPlanned.formatted()) archived first) on \(online.count) drive(s), one reader per drive, "
            + "at most \(AudioDecodeBudget.maxConcurrent) decodes / \(MediaBytes.display(AudioDecodeBudget.totalBytes)) of sound in memory; "
            + "\(plan.alreadyStamped.formatted()) already done"
        if plan.noDigest > 0 { line += "; \(plan.noDigest.formatted()) never hashed (scan them first)" }
        if away > 0 { line += "; \(away.formatted()) on \(offline.count) drive(s) not connected" }
        line += ". Fingerprints go to \(store?.fileURL.path ?? "the sidecar"); the catalog gets a stamp per file."
        return line + " Read only on media: nothing is moved, renamed, deleted or written. Running again continues where this stops."
    }

    // MARK: Lanes

    private func runLane(_ lane: AudioFingerprintBackfillLane, model: VideoScanModel) async {
        setPhase(lane.root, .reading)
        for (i, item) in lane.items.enumerated() {
            guard await waitOutPause(), let outcome = await lookAtOne(item, root: lane.root) else {
                setPhase(lane.root, .stopped)
                return
            }
            if outcome == .missing || outcome.isFailure, !(await rootIsOnline(lane.root)) {
                driveLeft(lane, from: i, model: model)
                return
            }
            record(outcome, for: item, lane: lane, model: model)
            if stopped { setPhase(lane.root, .stopped); return }
            await checkpointIfDue(model: model)
        }
        setPhase(lane.root, .finished)
    }

    /// One file: the catalog's "video-only" answer, then the sidecar, then a
    /// decode under the budget and the drive's gate. nil when stopped
    /// before the file was opened (nothing to record).
    private func lookAtOne(_ item: AudioFingerprintBackfillItem, root: String) async -> Outcome? {
        guard fileExists(item.path) else { return .missing }
        if item.isVideoOnly, !item.headerHasAudio { return .noAudio(fromCatalog: true) }
        if let (key, summary) = sharedFingerprint(for: item) { return .shared(key: key, summary) }
        // The budget slot is RESERVED by waitForBudget before any await
        // (codex QA P2: the gate acquire suspends, and every lane used to
        // pass the budget check with nothing in flight yet).
        guard await waitForBudget(item) else { return nil }
        defer { inFlight[item.id] = nil }
        guard let held = await acquireGates(for: item.path) else { return nil }
        reading[root] = item.filename
        let outcome = await decodeOne(item)
        reading[root] = nil
        await releaseGates(held)
        return outcome
    }

    /// A copy's fingerprint already kept — in this run's pending batch or
    /// in the sidecar — under the record's FULL digest only. A sampled
    /// "v1:" hash is never an identity (QA P1-a: 10 of 836 v1-equal pairs
    /// had different bytes), so a row with only a sampled digest is always
    /// decoded itself. Returns the key the row was found under.
    ///
    /// A sidecar row with NO landmark is never shared: it may have been
    /// written before stamp rule 4, when silence and "too little to print"
    /// were not told apart, and its summary cannot say which — the file is
    /// decoded and decided again. This run's own pending entries are all
    /// rule-4 decisions (printable or measured silence), so they share.
    private func sharedFingerprint(for item: AudioFingerprintBackfillItem)
        -> (AudioFingerprintStore.Key, AudioFingerprintStore.Summary)? {
        for digest in item.digests where AudioFingerprintStamp.isFullDigest(digest) {
            let key = AudioFingerprintStore.Key(contentDigest: digest, sizeBytes: item.sizeBytes)
            if let pending = pendingEntries[key] {
                return (key, AudioFingerprintStore.Summary(engineVersion: Int(pending.fingerprint.version), recipeID: pending.fingerprint.recipeID,
                                                           computedAt: pending.computedAt, sourcePath: pending.sourcePath,
                                                           analyzedSeconds: pending.fingerprint.analyzedSeconds, complete: pending.fingerprint.complete,
                                                           landmarks: pending.fingerprint.landmarkCount, bytes: pending.fingerprint.estimatedBytes))
            }
            if let found = try? store?.summary(for: key), found.landmarks > 0 { return (key, found) }
        }
        return nil
    }

    private func decodeOne(_ item: AudioFingerprintBackfillItem) async -> Outcome {
        do {
            let fingerprint = try await runPass(item)
            return Self.classify(fingerprint)
        } catch AudioPCMDecoder.Failure.noAudioStream {
            // Zero samples (or "does not contain any stream") is a verdict
            // only when the header agrees. 98 real files with pcm/aac/ac3
            // streams were stamped "no sound" this way before 2026-10-17;
            // 9 of 10 decoded fine when retried.
            guard item.headerHasAudio else { return .noAudio(fromCatalog: false) }
            return .failed(Self.decodeGaveNoSamplesWords(codec: item.audioCodec))
        } catch AudioPCMDecoder.Failure.decodeFailed(let code, let tail) {
            return .failed("ffmpeg could not decode it (exit \(code)): \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch AudioPCMDecoder.Failure.timedOut {
            return .failed("no answer from the drive within \(Int(Self.decodeDeadline(sizeBytes: item.sizeBytes))) s — skipped; "
                + "will try again next run; if it keeps failing, the drive may be too slow for a file this size")
        } catch AudioPCMDecoder.Failure.ffmpegMissing(let path) {
            return .failed("ffmpeg disappeared at \(path)")
        } catch is CancellationError {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
    }

    /// The production pass (ffmpeg via AudioPCMDecoder, FFT via
    /// AudioFingerprint), or the test seam.
    private func runPass(_ item: AudioFingerprintBackfillItem) async throws -> AudioFingerprint {
        if let passForTesting { return try await passForTesting(item) }
        return try await Self.fingerprintOffMain(path: item.path, ffmpegPath: ffmpegPath, parameters: parameters,
                                                 maxSeconds: decoderMaxSeconds,
                                                 deadlineSeconds: Self.decodeDeadline(sizeBytes: item.sizeBytes))
    }

    /// A decoded print → what the job does with it: stamp it (printable, or
    /// measured silence) or list it as "heard too little" (pure; tests pin it).
    nonisolated static func classify(_ fingerprint: AudioFingerprint) -> Outcome {
        switch AudioFingerprintStamp.reading(of: fingerprint) {
        case .printable, .silence: return .fingerprint(fingerprint)
        case .heardTooLittle(let audible): return .heardTooLittle(fingerprint, audibleSeconds: audible)
        // Only a pass that skipped `AudioFingerprint.compute` (a test stub)
        // can get here: no loudness measurement, so no verdict either way.
        case .notMeasured: return .failed(notMeasuredWords)
        }
    }

    nonisolated static let notMeasuredWords =
        "the print carries no loudness measurement (0 landmarks) — not judged silent or heard; retried next run"

    /// The detail row for a stamped print: "12 s of sound · 340 landmarks ·
    /// 3 KB", or for measured silence "3 s, measured silent" (QA P3b — a
    /// silent print is never "N s of sound").
    nonisolated static func fingerprintedWords(_ stamp: AudioFingerprintStamp) -> String {
        if stamp.landmarks == 0 { return "\(seconds(stamp.analyzedSeconds)), measured silent" }
        return "\(seconds(stamp.analyzedSeconds)) of sound · \(stamp.landmarks.formatted()) landmarks · \(MediaBytes.display(Int64(stamp.bytes)))"
    }

    /// The words for a print that heard sound but made no landmark.
    nonisolated static func heardTooLittleWords(analyzedSeconds: Double, audibleSeconds: Int) -> String {
        "heard sound (\(audibleSeconds) audible second\(audibleSeconds == 1 ? "" : "s") of \(seconds(analyzedSeconds))) "
            + "but too little to fingerprint (0 landmarks) — not silent; retried next run"
    }

    /// The FAILED words for a decode that produced no samples from a file
    /// whose header names an audio codec — not a stamp, so the plan retries.
    nonisolated static func decodeGaveNoSamplesWords(codec: String) -> String {
        "could not decode the sound (0 samples) — the header says \(codec) sound is there; retried next run"
    }

    /// The "no sound" words, naming the evidence the stamp rests on.
    nonisolated static func noSoundWords(fromCatalog: Bool) -> String {
        fromCatalog ? "no sound track (the catalog's probe found no audio stream) — nothing to fingerprint"
            : "ffmpeg found no sound and the header agrees (no audio codec on the row) — nothing to fingerprint"
    }

    /// 300 s + 1 s per 10 MB: ffmpeg must read the whole file to reach its
    /// audio. A hang guard (dead drive, wedged child), not a pace guard.
    nonisolated static func decodeDeadline(sizeBytes: Int64) -> Double {
        300 + Double(sizeBytes) / 10_000_000
    }

    /// Decode + fingerprint off the main actor. The PCM (≤ 230 MB at the
    /// cap) lives only inside this call.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fingerprintOffMain(path: String, ffmpegPath: String, parameters: AudioFingerprintParameters,
                                               maxSeconds: Double, deadlineSeconds: Double) async throws -> AudioFingerprint {
        let decoder = AudioPCMDecoder(ffmpegPath: ffmpegPath, sampleRate: parameters.sampleRate,
                                      maxSeconds: maxSeconds, deadlineSeconds: deadlineSeconds)
        let pcm = try await decoder.decode(path: path)
        try Task.checkCancellation()
        return AudioFingerprint.compute(pcm, parameters: parameters)
    }

    // MARK: Pause / budget / gates

    private func waitOutPause() async -> Bool {
        while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
        return !stopped
    }

    /// Wait until the memory budget admits this decode, then RESERVE its
    /// slot in `inFlight` with no await in between (main-actor atomic).
    /// False when stopped (nothing reserved).
    private func waitForBudget(_ item: AudioFingerprintBackfillItem) async -> Bool {
        while !AudioDecodeBudget.canStart(durationSeconds: item.durationSeconds, inFlight: Array(inFlight.values)) {
            if stopped { return false }
            if !isPausedValue { subtitleText = "Waiting for memory — \(inFlight.count) file(s) being read…" }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !stopped else { return false }
        inFlight[item.id] = item.durationSeconds
        return true
    }

    private func acquireGates(for path: String) async -> [(MediaVolumeGate, PausableGatePermit)]? {
        var held: [(MediaVolumeGate, PausableGatePermit)] = []
        for gate in gatesFor(path) {
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

    /// The drive went away: this lane stops; the file just tried and every
    /// one after it count as "drive not connected". Other lanes go on.
    private func driveLeft(_ lane: AudioFingerprintBackfillLane, from i: Int, model: VideoScanModel) {
        let rest = lane.items[i...]
        totals.add(.driveNotConnected, files: rest.count, bytes: rest.reduce(Int64(0)) { $0 + $1.sizeBytes })
        bumpLane(lane.root, by: rest.count)
        setPhase(lane.root, .disconnected)
        let why = "the drive went away after \(i.formatted()) file(s) — the \(rest.count.formatted()) left are read on the next run"
        addProblem(filename: lane.label, path: lane.root, drive: lane.label, archived: false, .driveNotConnected, why)
        model.audioFingerprintNote("drive \(lane.label): \(why)")
    }

    // MARK: Tally

    private func record(_ outcome: Outcome, for item: AudioFingerprintBackfillItem,
                        lane: AudioFingerprintBackfillLane, model: VideoScanModel) {
        bumpLane(lane.root, by: 1)
        switch outcome {
        case .fingerprint(let fingerprint):
            let stamp = AudioFingerprintStamp.fingerprinted(fingerprint, contentDigest: item.key.contentDigest, sizeBytes: item.sizeBytes)
            totals.readBytes += item.sizeBytes
            guard stamped(stamp, item, lane: lane, model: model) else { return }
            pendingEntries[item.key] = AudioFingerprintStore.Entry(key: item.key, fingerprint: fingerprint, sourcePath: item.path,
                                                                   computedAt: stamp.computedAt)
            totals.landmarks += stamp.landmarks
            totals.sidecarBytes += Int64(stamp.bytes)
            let detail = Self.fingerprintedWords(stamp)
            if stamp.complete {
                totals.add(.fingerprinted, bytes: item.sizeBytes)
                addSample(item, lane: lane, .fingerprinted, detail)
            } else {
                totals.add(.partial, bytes: item.sizeBytes)
                addProblem(filename: item.filename, path: item.path, drive: lane.label, archived: item.isArchived, .partial,
                           "only the first \(Self.seconds(stamp.analyzedSeconds)) of \(Self.seconds(item.durationSeconds)) were fingerprinted (the decoder's cap) — kept as partial; not retried")
            }
        case .heardTooLittle(let fingerprint, let audible):
            // FOLLOW-UP (pending Rick: additive `sound_prints.audible_s REAL
            // NULL`): stamp here instead — `.fingerprinted`, 0 landmarks,
            // audibleSeconds = `audible` — and teach `hearing`/`describes`
            // that a rule-5 stamp with audible_s > 0 is "heard too little"
            // (stands, not retried). Until then: listed, never stamped.
            totals.readBytes += item.sizeBytes
            totals.add(.heardTooLittle, bytes: item.sizeBytes)
            let why = Self.heardTooLittleWords(analyzedSeconds: fingerprint.analyzedSeconds, audibleSeconds: audible)
            addProblem(filename: item.filename, path: item.path, drive: lane.label, archived: item.isArchived, .heardTooLittle, why)
            model.audioFingerprintNote("HEARD TOO LITTLE \(item.path) — \(why)")
        case .shared(let key, let summary):
            let stamp = AudioFingerprintStamp(computedAt: summary.computedAt, engineVersion: AudioFingerprintStamp.currentEngineVersion,
                                              contentDigest: key.contentDigest, sizeBytes: key.sizeBytes, outcome: .fingerprinted,
                                              analyzedSeconds: summary.analyzedSeconds, complete: summary.complete,
                                              landmarks: summary.landmarks, bytes: summary.bytes)
            guard stamped(stamp, item, lane: lane, model: model) else { return }
            totals.add(.shared, bytes: item.sizeBytes)
            addSample(item, lane: lane, .shared, "same bytes as \((summary.sourcePath as NSString).lastPathComponent) — stamped without reading")
        case .noAudio(let fromCatalog):
            let stamp = AudioFingerprintStamp.noAudio(contentDigest: item.key.contentDigest, sizeBytes: item.sizeBytes)
            if !fromCatalog { totals.readBytes += item.sizeBytes }
            guard stamped(stamp, item, lane: lane, model: model) else { return }
            totals.add(.noAudio, bytes: item.sizeBytes)
            addSample(item, lane: lane, .noAudio, Self.noSoundWords(fromCatalog: fromCatalog))
        case .missing:
            totals.add(.missing, bytes: item.sizeBytes)
            addProblem(filename: item.filename, path: item.path, drive: lane.label, archived: item.isArchived, .missing,
                       "not at its path (the drive is connected) — skipped")
        case .failed(let why):
            totals.add(.failed, bytes: item.sizeBytes)
            addProblem(filename: item.filename, path: item.path, drive: lane.label, archived: item.isArchived, .failed, why)
            model.audioFingerprintNote("FAILED \(item.path) — \(why)")
        case .cancelled:
            totals.add(.cancelled, bytes: item.sizeBytes)
            addProblem(filename: item.filename, path: item.path, drive: lane.label, archived: item.isArchived, .cancelled,
                       "cut off while being read — the next run reads it again")
        }
    }

    /// Compare-and-set the stamp on the planned record. False (and a
    /// "changed meanwhile" row) when the record moved or changed.
    private func stamped(_ stamp: AudioFingerprintStamp, _ item: AudioFingerprintBackfillItem,
                         lane: AudioFingerprintBackfillLane, model: VideoScanModel) -> Bool {
        guard model.applyAudioFingerprintStamp(stamp, to: item) == .written else {
            totals.add(.recordChanged, bytes: item.sizeBytes)
            addProblem(filename: item.filename, path: item.path, drive: lane.label, archived: item.isArchived, .recordChanged,
                       "moved, rescanned or changed in the catalog during the run — not written; the next run looks again")
            return false
        }
        unsavedStamps.append((item, stamp))
        return true
    }

    private func addProblem(filename: String, path: String, drive: String, archived: Bool,
                            _ result: AudioFingerprintBackfillResult, _ detail: String) {
        rowID += 1
        guard problems.count < Self.problemCap else { return }
        problems.append(AudioFingerprintBackfillItemRow(id: rowID, filename: filename, path: path, drive: drive,
                                                        archived: archived, result: result, detail: detail))
    }

    private func addSample(_ item: AudioFingerprintBackfillItem, lane: AudioFingerprintBackfillLane,
                           _ result: AudioFingerprintBackfillResult, _ detail: String) {
        rowID += 1
        guard sample.count < Self.sampleCap else { return }
        sample.append(AudioFingerprintBackfillItemRow(id: rowID, filename: item.filename, path: item.path, drive: lane.label,
                                                      archived: item.isArchived, result: result, detail: detail))
    }

    private func setPhase(_ root: String, _ phase: AudioFingerprintBackfillLaneStatus.Phase) {
        guard let i = laneIndex[root] else { return }
        lanes[i].phase = phase
    }

    private func bumpLane(_ root: String, by n: Int) {
        guard let i = laneIndex[root] else { return }
        lanes[i].done += n
    }

    // MARK: Progress ticker

    /// Once a second: the bar, the subtitle, the 60 s save checkpoint (so a
    /// lane deep inside one long file still has its earlier stamps saved),
    /// and a progress line to the logs on the clock.
    private func startTicker(model: VideoScanModel) -> Task<Void, Never> {
        let interval = tickMilliseconds
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshProgress()
                await self.checkpointIfDue(model: model)
                self.logProgressIfDue(model: model)
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    private func refreshProgress() {
        fractionValue = min(1, Double(totals.doneBytes) / Double(max(totals.plannedBytes, 1)))
        guard state == .running, !isPausedValue else { return }
        subtitleText = totals.progressLine(reading: reading.values.sorted(), lanesActive: reading.count,
                                           elapsed: Date().timeIntervalSince(runStart))
    }

    /// Every `progressLogFiles` files or `progressLogSeconds`, whichever
    /// comes first. The clock line goes out even while one long file is
    /// being read, so an overnight log never falls silent.
    private func logProgressIfDue(model: VideoScanModel) {
        let byCount = totals.done - lastProgressLogDone >= max(1, progressLogFiles)
        let byClock = Date().timeIntervalSince(lastProgressLog) >= progressLogSeconds
        guard byCount || byClock else { return }
        lastProgressLog = Date()
        lastProgressLogDone = totals.done
        model.audioFingerprintNote("progress — \(subtitleText) · \(storedCount.formatted()) saved")
    }

    // MARK: Saving

    private func checkpointIfDue(model: VideoScanModel) async {
        guard !unsavedStamps.isEmpty, !saving, !saveFailed else { return }
        guard unsavedStamps.count >= checkpointFiles || Date().timeIntervalSince(lastSave) >= checkpointSeconds else { return }
        await persist(model: model)
    }

    /// Sidecar batch in one transaction, THEN an acknowledged catalog
    /// save. True when there was nothing to save or both are on disk. A
    /// failure stops the job and undoes the stamps of THIS batch.
    ///
    /// The batch is taken and the queues cleared BEFORE the first await
    /// (QA P1-c): lanes keep stamping while the catalog save is in flight,
    /// and those newer stamps must stay queued for the next checkpoint —
    /// never dropped with this one's `removeAll`.
    @discardableResult
    private func persist(model: VideoScanModel) async -> Bool {
        guard !unsavedStamps.isEmpty, !saving, !saveFailed else { return !saveFailed }
        saving = true
        defer { saving = false }
        let batch = Array(pendingEntries.values)
        let stamps = unsavedStamps
        pendingEntries.removeAll()
        unsavedStamps.removeAll()
        let n = stamps.count
        subtitleText = "Saving \(n) fingerprint\(n == 1 ? "" : "s")…"
        do {
            if let sidecarPutForTesting { try sidecarPutForTesting(batch) } else { try store?.put(batch) }
        } catch {
            failSave(model: model, why: "the fingerprint file could not be written (\(error))", undo: stamps)
            return false
        }
        let ok: Bool
        if let saveCatalogForTesting { ok = await saveCatalogForTesting() } else { ok = await model.saveCatalogAcknowledged() }
        guard ok else {
            model.saveCatalogDebounced()
            failSave(model: model, why: "the catalog save was NOT confirmed", undo: stamps)
            return false
        }
        storedCount += n
        saveCount += 1
        lastSave = Date()
        return true
    }

    /// Undo the stamps the failed save would have carried (compare-and-set)
    /// and stop: nothing more is put at risk. Media was never touched.
    private func failSave(model: VideoScanModel, why: String,
                          undo: [(item: AudioFingerprintBackfillItem, stamp: AudioFingerprintStamp)]) {
        var undone = 0
        for p in undo where model.revertAudioFingerprintStamp(p.item, written: p.stamp) { undone += 1 }
        saveFailed = true
        stopRequested = true
        model.audioFingerprintNote("\(why) — stopping so no more work is at risk; \(undone.formatted()) stamp(s) undone, "
            + "those files are looked at again next run")
    }

    // MARK: Finish

    private func conclude(model: VideoScanModel) async {
        await persist(model: model)
        if saveFailed, !unsavedStamps.isEmpty {
            // Files finished after the failed save: their bytes never reached
            // the sidecar, so their stamps come off too (the next run redoes them).
            for p in unsavedStamps { _ = model.revertAudioFingerprintStamp(p.item, written: p.stamp) }
            unsavedStamps.removeAll()
            pendingEntries.removeAll()
        }
        let line = totals.line
        if saveFailed {
            let message = "Stopped — the fingerprints could not be saved. \(storedCount.formatted()) saved earlier are kept; no media was changed. " + line
            model.audioFingerprintNote("OUTCOME — " + message)
            finish(failed: message)
        } else if stopped {
            model.audioFingerprintNote("OUTCOME stopped at \(totals.done.formatted()) of \(totals.planned.formatted()) — " + line)
            finish(cancelled: ())
        } else {
            model.audioFingerprintNote("OUTCOME — " + line)
            finish(success: line)
        }
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isPausedValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        isPausedValue = false
        audioFingerprintLog.warning("fingerprint sound failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped — \(storedCount.formatted()) fingerprint(s) saved are kept; run again to continue"
        isPausedValue = false
    }

    // MARK: Words

    nonisolated static func seconds(_ s: Double) -> String {
        s >= 3_600 ? String(format: "%.1f h", s / 3_600) : s >= 60 ? "\(Int((s / 60).rounded())) min" : "\(Int(s.rounded())) s"
    }
}

private extension AudioFingerprintBackfillJob.Outcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start "Fingerprint Sound" over the whole catalog. One run at a time —
    /// a second request is refused (nothing started).
    @discardableResult
    func startAudioFingerprintBackfill(model: VideoScanModel) -> AudioFingerprintBackfillJob {
        let job = AudioFingerprintBackfillJob(model: model)
        job.gatesFor = { [weak self] path in self?.gatePlan(forPaths: [path]) ?? [] }
        let busy = jobs.contains { $0.state.isActive && $0 is AudioFingerprintBackfillJob }
        guard add(job) else { return job }
        if busy {
            job.refuseToStart(reason: "Fingerprint Sound is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "fingerprint the sound of every catalog file without a current stamp, archived first, one reader per drive — read only on media"))
        return job
    }
}
