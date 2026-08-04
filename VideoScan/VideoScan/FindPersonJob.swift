import Combine
import Foundation
import os

// MARK: - FindPersonJob (Find & Tag, 2026-08-02)
//
// Runs a per-person detector recipe over a batch of records and applies
// MACHINE-tier person tags through VideoScanModel.applyRecipeVerdict
// (docs/find-and-tag-design.md). Two engines behind one job, selected by
// the internal `useNativeEngine` flag:
//
//  - python bridge (DEFAULT until parity is proven): shells out ONCE per
//    job to tools/donna-recipe/find_person_batch.py via ProcessRunner —
//    model prep paid once, streaming a JSONL protocol: ready / beat
//    (watchdog ticks) / result (per clip).
//  - native (NativeRecipeScorer): in-process Vision + AdaFace CoreML via
//    the RecipeScoring seam. Same recipe rules; DIFFERENT embedding
//    space, so scores are NOT tier-comparable to python's until the
//    recipe tier constants are recalibrated (see runNative note).
//
// Cancellation: Task.cancel → ProcessRunner SIGTERM→SIGKILL escalation
// (python) / cooperative between-frame checks (native).
// Pause: JobPauseCoordinator SIGSTOPs the python child; the native
// engine parks on a PauseGate at frame checkpoints. Both arms stop the
// stall watchdog while paused (a suspended engine is silent by design).
// Stall: beats arrive every ~50 frames; monitor threshold default 5 min.

private let findLog = Logger(subsystem: "Rick-Breen.VideoScan",
                             category: "fileOps")

@MainActor
final class FindPersonJob: MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .findPerson
    let startedAt = Date()

    /// Person this job hunts (v1: "Donna" — the only tuned recipe).
    let person: String
    let recipeID: String
    let records: [VideoRecord]

    private weak var model: VideoScanModel?

    // MARK: Engine selection
    //
    // NATIVE is the default as of 2026-08-02 (Rick: overnight archive
    // run at 3.4x, per-engine thresholds now wired — native scores are
    // tiered in native space, 0.46/0.30 from the calibration sweep).
    // `VIDEOSCAN_NATIVE_RECIPE=0` forces the python bridge (reference
    // engine — keeps the A/B honest until the sex gate closes the AUC
    // gap). Each job captures the flag at init so a mid-job flip can't
    // switch engines.
    nonisolated(unsafe) static var useNativeEngine: Bool =
        ProcessInfo.processInfo.environment["VIDEOSCAN_NATIVE_RECIPE"] != "0"

    let usesNativeEngine: Bool

    /// Pause via SIGSTOP/SIGCONT on the python child (GH #150 plumbing);
    /// the native arm additionally parks the scorer on `nativeGate`.
    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()
    /// Auto-pause (memory pressure) is off: this gate answers ONLY to the
    /// user's Pause button. An unattended auto-pause would look like a
    /// stall to nobody (watchdog is stopped while paused) and hang the job
    /// silently — the recipe's memory use is bounded per clip instead.
    private let nativeGate: PauseGate = {
        let gate = PauseGate()
        Task { await gate.setAutoPause(false) }
        return gate
    }()

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
        if usesNativeEngine {
            let gate = nativeGate
            Task { await gate.pause() }
        }
    }

    func resume() {
        guard pauser.resume() else { return }
        isPausedValue = false
        if usesNativeEngine {
            let gate = nativeGate
            Task { await gate.resume() }
        }
    }

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    var title: String { "Find \(person) — \(records.count) file(s)" }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    /// Tallies for the completion summary (private(set): the expanded
    /// row's detail view reads them).
    private(set) var tagged = 0     // detected tier
    private(set) var maybes = 0     // suspected tier
    private(set) var skipped = 0    // veto/confirmed/no-change
    private(set) var errors = 0
    private(set) var completed = 0
    private var stallReason: String?

    // MARK: Expanded-row context (Rick 2026-08-04: like the compare row)

    /// Previous / current / next clip for the detail view, with the
    /// previous clip's outcome ("Donna* 0.84", "no match", "error").
    struct ClipProgressContext: Equatable {
        var previous: String?
        var previousOutcome: String?
        var current: String?
        var next: String?
    }
    @Published private(set) var clipContext = ClipProgressContext()
    /// Within-file fraction of the clip being scanned (native arm).
    @Published private(set) var currentClipFraction: Double?
    /// Bytes of completed clips — drives the MB/s summary figure.
    private var scannedBytes: Int64 = 0

    /// "Found and tagged Donna 12 times · 2 maybe · 1 error · 41.2
    /// files/h · 87 MB/s" — the detail view's bottom line.
    var detailSummary: String {
        let elapsed = Date().timeIntervalSince(scanBeganAt ?? startedAt)
        var parts = ["Found and tagged \(person) \(tagged) time\(tagged == 1 ? "" : "s")"]
        if maybes > 0 { parts.append("\(maybes) maybe") }
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if elapsed > 0, completed > 0 {
            parts.append(String(format: "%.1f files/h",
                                Double(completed) / elapsed * 3_600))
            let mbps = Double(scannedBytes) / elapsed / 1_048_576
            if mbps >= 0.1 { parts.append(String(format: "%.0f MB/s", mbps)) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Wedged-clip skip (GH #156 — Rick 2026-08-04: "skip it and log it")

    /// Resolves the current clip's score-race when the stall watchdog
    /// abandons it. nil while not scoring (python arm never sets it, so
    /// that arm keeps the old whole-batch stall behavior).
    private var clipAbandonContinuation: CheckedContinuation<RecipeClipScore?, Never>?
    private var consecutiveAbandons = 0
    /// This many CONSECUTIVE wedged clips means the volume, not the
    /// file, is sick — fail the batch (the old behavior) instead of
    /// grinding 5 minutes per file forever.
    static let consecutiveAbandonCap = 3
    private weak var stallMonitor: StallMonitor?

    // Progress-telemetry state (Rick 2026-08-04: the 2026-08-03 stalled
    // run was a post-mortem with no per-file evidence; design distilled
    // with codex, channel #91).
    /// Actionable count ≠ records.count after the eligibility, human-
    /// verdict, and offline-volume filters. Terminal logs must never
    /// repeat the misleading selected count (7,894 when the batch was
    /// 2,988).
    private var actionableTotal = 0
    private var scanBeganAt: Date?
    private var currentClipName: String?
    /// Per-clip stats ("native, 823f, 41 faces, 92s") set by the native
    /// loop after scoring; folded into the next durable progress line.
    /// The python arm leaves it nil.
    private var currentClipDetail: String?
    private var clipStartedAt: Date?
    /// Highest quartile (1…3) already logged for the current clip —
    /// long clips log 25/50/75%, everything else stays quiet.
    private var clipQuartileLogged = 0
    /// Last wall-clock "still scanning" line for the current clip.
    /// Declared duration is NOT a cost proxy (codex #102: a 40 GB mp4
    /// claiming 36.65 s suppressed every quartile line while grinding
    /// for minutes) — long WALL time earns durable lines too.
    private var lastLongRunLogAt: Date?

    /// Same-person batch queueing (Rick 2026-08-04: a second batch used
    /// to be a SILENT refusal — a dead click). Set by the Center at
    /// dispatch; this job waits (visibly) until the predecessor leaves
    /// its active state, then runs. Parallel same-person scans stay
    /// disallowed — they'd fight over the serialized embedder and
    /// interleave catalog writes.
    weak var precededBy: FindPersonJob?

    /// Center's volume-tech lookup, for the read-ahead warmer's
    /// second-reader rule. nil ⇒ unknown tech (treated as HDD-cautious).
    var mediaTechForPath: ((String) -> VolumeMediaTech)?

    /// Read-ahead: warms the NEXT clip into the page cache while the
    /// current one scores (GH #157 stage 2 — hides open+I/O latency).
    private var warmTask: Task<Void, Never>?

    private(set) var task: Task<Void, Never>?

    /// Events whose main-actor Task has run (ordering seam — see
    /// runPythonBridge). Incremented FIRST thing in each event Task so
    /// even guarded-out events count as delivered.
    private var handledEvents = 0

    /// Lock-guarded emitted-event counter, incremented on the
    /// ProcessRunner callback thread. Paired with `handledEvents` to
    /// let finish wait for in-flight event Tasks.
    final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // v1 constants — Rick's machine (see find-and-tag-design.md).
    static let pythonPath = "\(NSHomeDirectory())/dev/VideoScan/venv/bin/python3.12"
    static let scriptPath = "\(NSHomeDirectory())/dev/VideoScan/tools/donna-recipe/find_person_batch.py"
    static let galleryPath = "\(NSHomeDirectory())/dev/VideoScan/tests/fixtures/photos/Donna"

    init(person: String, records: [VideoRecord], model: VideoScanModel) {
        self.person = person
        self.records = records
        self.model = model
        let native = FindPersonJob.useNativeEngine
        self.usesNativeEngine = native
        self.recipeID = native ? "recipe-v1-native" : "recipe-v1-python"
        self.subtitleText = "Warming up the \(person) recipe…"
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
        if usesNativeEngine {
            // A paused native scorer is parked INSIDE waitIfPaused —
            // release it so the cancellation check after the gate runs.
            let gate = nativeGate
            Task { await gate.resume() }
        }
    }

    // MARK: Eligibility prefilter (Rick 2026-08-03: "only video files
    // > 10 seconds — no audio-only, junk, cover art, bundle internals")
    //
    // Pure + nonisolated so codex pins the spec without a job. Every
    // exclusion returns a REASON; the job logs the breakdown so a
    // filtered run explains itself instead of silently shrinking.
    enum SkipReason: String, CaseIterable {
        case notVideo = "not video (audio-only / no streams / probe-failed)"
        case junk = "marked junk"
        case tooShort = "shorter than 10s"
        case bundleInternal = "app-bundle internals (FCP/iMovie/Photos)"
        case purgedOrRetired = "purged / set-aside / superseded"
    }

    /// Minimum duration a clip must have to be worth the recipe's time —
    /// FCP/iMovie transitions and stingers live below this.
    nonisolated static let minimumClipSeconds: Double = 10

    /// nil = eligible; otherwise why the recipe skips it.
    nonisolated static func skipReason(for rec: VideoRecord) -> SkipReason? {
        // Structural: only real video streams reach the detector. This
        // also drops iTunes audio + attached-pic cover art (classified
        // audio-only since the 2026-07 fix).
        switch rec.streamType {
        case .videoAndAudio, .videoOnly: break
        default: return .notVideo
        }
        if rec.mediaDisposition == .suspectedJunk || rec.mediaDisposition == .confirmedJunk {
            return .junk
        }
        if rec.isPurged || rec.setAsideReason != nil || rec.supersededByID != nil {
            return .purgedOrRetired
        }
        // Editors' bundles hold render files, transitions, and proxies —
        // derivatives of footage that exists elsewhere in the catalog.
        let path = rec.fullPath.lowercased()
        for marker in [".fcpbundle/", ".imovielibrary/", ".photoslibrary/", ".fcpcache/"]
        where path.contains(marker) {
            return .bundleInternal
        }
        // Duration 0 usually means "never probed" — treat unknown as too
        // short rather than feeding mystery files to an overnight run.
        if rec.durationSeconds < Self.minimumClipSeconds {
            return .tooShort
        }
        return nil
    }

    // MARK: Run

    private func run() async {
        // Queued behind an earlier same-person batch? Wait visibly.
        // Eligibility is computed AFTER the wait — verdicts the
        // predecessor writes (confirmed/rejected/auto-tags) must count
        // when this batch finally filters.
        if let predecessor = precededBy, predecessor.state.isActive {
            appLog.write("Find \(person) queued: \(records.count) file(s) — waiting for the running Find \(predecessor.person) scan")
            subtitleText = "Waiting for the current Find \(person) scan…"
            while let p = precededBy, p.state.isActive {
                if Task.isCancelled || state == .cancelling {
                    finish(cancelled: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard state.isActive else { return }
        }

        // Recipe eligibility first (with logged breakdown)…
        var skipCounts: [SkipReason: Int] = [:]
        let recipeEligible = records.filter { rec in
            if let reason = Self.skipReason(for: rec) {
                skipCounts[reason, default: 0] += 1
                return false
            }
            return true
        }
        // …then the veto/confirmed skips (also enforced in
        // applyRecipeVerdict; here they save the engine the decode time).
        let eligible = recipeEligible.filter { rec in
            !rec.rejectedPeople.contains {
                $0.compare(person, options: .caseInsensitive) == .orderedSame
            } && !rec.confirmedByUserPeople.contains {
                $0.name.compare(person, options: .caseInsensitive) == .orderedSame
            }
        }
        // Offline volumes produce instant per-file errors that LOOK like
        // a completed scan (Rick 2026-08-02: 6802 files "done" in 33 s —
        // every one was an unreachable path). Partition them out loudly.
        let actionable = eligible.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        let offline = eligible.count - actionable.count
        let humanSkipped = recipeEligible.count - eligible.count
        skipped = records.count - eligible.count
        let tiers = VideoScanModel.recipeThresholds[recipeID]
            ?? (detected: VideoScanModel.recipeDetectedMinScore,
                suspected: VideoScanModel.recipeSuspectedMinScore)
        // Self-explaining start line: every excluded file is accounted
        // for by category, so a filtered run never looks mysteriously
        // small (the 6802→33s lesson, generalized).
        let breakdown = SkipReason.allCases.compactMap { reason -> String? in
            guard let n = skipCounts[reason], n > 0 else { return nil }
            return "\(n) \(reason.rawValue)"
        }
        appLog.write("Find \(person) started: \(records.count) selected → \(actionable.count) to scan"
                     + (breakdown.isEmpty ? "" : " | filtered: " + breakdown.joined(separator: ", "))
                     + (humanSkipped > 0 ? " | \(humanSkipped) already confirmed/rejected" : "")
                     + (offline > 0 ? " | \(offline) on offline volumes" : "")
                     + " [\(recipeID), tiers ≥\(tiers.detected) detected / ≥\(tiers.suspected) suspected, ≥\(Int(Self.minimumClipSeconds))s video only]")
        guard !actionable.isEmpty else {
            let why: String
            if recipeEligible.isEmpty {
                why = "no eligible video files in the selection (see filter breakdown in the log)"
            } else if offline > 0 {
                why = "all \(eligible.count) remaining file(s) are on offline volumes — mount them and re-run"
            } else {
                why = "all remaining file(s) already confirmed or rejected for \(person)"
            }
            finish(summary: "Nothing scanned — \(why)")
            return
        }

        let byPath = Dictionary(uniqueKeysWithValues:
            actionable.map { ($0.fullPath, $0) })
        let total = actionable.count
        actionableTotal = total
        scanBeganAt = Date()

        let monitor = StallMonitor(label: "find \(person)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                guard let self, self.state.isActive, self.stallReason == nil else { return }
                // Wedged CLIP first (GH #156): abandon it, log it, keep
                // the batch moving. Falls through to the batch-fail path
                // when abandonment isn't possible (python arm) or the
                // wedges are a pattern (consecutive cap — sick volume).
                if self.abandonCurrentClip(silentFor: silentFor) { return }
                self.stallReason = Self.stallDescription(
                    silentSeconds: silentFor,
                    completed: self.completed,
                    total: self.actionableTotal,
                    currentFilename: self.currentClipName)
                appLog.write("Find \(self.person) STALL: \(self.stallReason ?? "recipe engine stalled")")
                self.task?.cancel()
            }
        }
        stallMonitor = monitor
        monitor.start()
        pauser.register(monitor)
        defer { monitor.stop() }

        findLog.info("find person START: \(self.person, privacy: .public) over \(total) file(s) [\(self.recipeID, privacy: .public)]")
        if usesNativeEngine {
            await runNative(actionable: actionable, byPath: byPath,
                            total: total, monitor: monitor)
        } else {
            await runPythonBridge(actionable: actionable, byPath: byPath,
                                  total: total, monitor: monitor)
        }
    }

    /// Shared run epilogue — the stall/cancel/success ladder both engine
    /// arms end with. `failure` is an engine-specific setup failure (nil
    /// on success).
    private func finishRun(failure: String?) {
        if let stallReason {
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            finish(cancelled: true)
            return
        }
        if let failure {
            finish(failed: failure)
            return
        }
        finish(summary: "\(person)*: \(tagged) tagged, \(maybes) maybe (\(person)?), \(skipped) skipped, \(errors) error(s)")
    }

    // MARK: Python bridge arm

    private func runPythonBridge(actionable: [VideoRecord],
                                 byPath: [String: VideoRecord],
                                 total: Int, monitor: StallMonitor) async {
        let clipsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("findperson-\(id.uuidString).txt")
        defer { try? FileManager.default.removeItem(at: clipsFile) }
        do {
            try actionable.map(\.fullPath).joined(separator: "\n")
                .write(to: clipsFile, atomically: true, encoding: .utf8)
        } catch {
            finish(failed: "couldn't write clip list: \(error.localizedDescription)")
            return
        }

        // Event-ordering seam (codex finding, channel #76 / QA-confirmed):
        // stdout events hop to the main actor via unstructured Tasks, and
        // the resumed job task can OUTRANK them on the priority-ordered
        // main-actor executor — finish() would then flip state to
        // terminal and the last clip's verdict(s) die on handle()'s
        // isActive guard: scored by python, never tagged, silently. The
        // emitted/handled counters make finish WAIT until every spawned
        // event ran (bounded — a lost Task must not hang the job).
        let emitted = FindPersonJob.EventCounter()

        let result = await ProcessRunner.runProcess(
            executable: Self.pythonPath,
            arguments: [Self.scriptPath,
                        "--gallery", Self.galleryPath,
                        "--clips-file", clipsFile.path,
                        // GUI PATH has no Homebrew — pass the app's
                        // known-good ffmpeg explicitly (2026-08-02: every
                        // clip errored FileNotFoundError in ms without it).
                        "--ffmpeg", ToolLocator.ffmpegPath],
            stdoutLine: { [weak self] line in
                monitor.tick()
                guard let event = FindPersonJob.parseLine(line) else { return }
                emitted.increment()
                Task { @MainActor [weak self] in
                    self?.handledEvents += 1
                    self?.handle(event: event, byPath: byPath, total: total)
                }
            },
            stderrLine: { _ in monitor.tick() },   // model-load chatter counts as life
            control: pauser.control
        )

        // Drain: every emitted event's main-actor Task must have run
        // before we judge tallies or finish. 5 s bound = pure paranoia;
        // the Tasks were all spawned before runProcess resumed.
        let deadline = ContinuousClock.now + .seconds(5)
        while handledEvents < emitted.value, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if handledEvents < emitted.value {
            findLog.error("find \(self.person, privacy: .public): \(emitted.value - self.handledEvents) event(s) unhandled after drain deadline")
        }

        var failure: String?
        if result.exitCode != 0 {
            let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
            failure = "recipe engine exited \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")"
        }
        finishRun(failure: failure)
    }

    // MARK: Native engine arm (RecipeScoring seam)

    private func runNative(actionable: [VideoRecord],
                           byPath: [String: VideoRecord],
                           total: Int, monitor: StallMonitor) async {
        // NOTE: native scores land in the app-ArcFace embedding space
        // (backend chosen by measurement — see RecipeEmbeddingBackend);
        // the recipe tier cutoffs in VideoScanModel+PeopleTags (0.55/0.38)
        // are python-space numbers. Until those constants are recalibrated
        // (--recipe-calibrate output + Rick's sign-off), native runs are
        // for parity evaluation — which is why this arm is flag-gated and
        // the flag defaults OFF.
        let scorer = NativeRecipeScorer(
            backend: .arcface,
            params: RecipeParameters(),
            pauseGate: nativeGate,
            onProgress: { [weak self] event in
                monitor.tick()
                Task { @MainActor [weak self] in
                    self?.handleNativeProgress(event)
                }
            })

        do {
            _ = try await scorer.prepare(
                galleryRoot: URL(fileURLWithPath: Self.galleryPath))
        } catch {
            finishRun(failure: "native recipe setup failed: \(error.localizedDescription)")
            return
        }

        for (index, rec) in actionable.enumerated() {
            if Task.isCancelled || !state.isActive { break }
            let clip = URL(fileURLWithPath: rec.fullPath)
            currentClipName = clip.lastPathComponent
            clipQuartileLogged = 0
            lastLongRunLogAt = nil
            currentClipFraction = nil
            clipContext.current = clip.lastPathComponent
            clipContext.next = index + 1 < actionable.count
                ? (actionable[index + 1].fullPath as NSString).lastPathComponent
                : nil
            startWarmingNextClip(after: index, in: actionable)
            let verdict: RecipeClipScore
            if FileManager.default.fileExists(atPath: rec.fullPath) {
                // Logged BEFORE the score (durably, not just unified) so
                // a wedged clip is named — the 2026-08-03 overnight stall
                // died on an unidentifiable file because only completions
                // logged.
                findLog.info("find \(self.person, privacy: .public) scanning: \(clip.lastPathComponent, privacy: .public)")
                appLog.write("Find \(person) scanning \(completed + 1)/\(total): \(clip.lastPathComponent)")
                clipStartedAt = Date()
                // Score races the stall watchdog: a wedged decode is
                // ABANDONED (the task leaks — bounded by the consecutive
                // cap — and its late verdict, if any, is discarded) so
                // the batch continues. The scorer actor is reentrant at
                // its awaits, so the next clip's score() proceeds while
                // the wedged one stays suspended.
                let scoreTask = Task { await scorer.score(clip: clip) }
                let raced: RecipeClipScore? = await withCheckedContinuation { cont in
                    clipAbandonContinuation = cont
                    Task { @MainActor [weak self] in
                        let v = await scoreTask.value
                        guard let self, let pending = self.clipAbandonContinuation else { return }
                        self.clipAbandonContinuation = nil
                        pending.resume(returning: v)
                    }
                }
                if let raced {
                    consecutiveAbandons = 0
                    verdict = raced
                } else {
                    scoreTask.cancel()
                    verdict = RecipeClipScore(
                        error: "decode wedged — no progress past the watchdog; clip skipped (GH #156)")
                }
            } else {
                verdict = RecipeClipScore(error: "missing file")
            }
            if Task.isCancelled { break }
            let clipWall = clipStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            // Error verdicts keep their stats too when the decode got far
            // enough to know the transport — "ffmpeg, 210f, …" next to an
            // error is diagnosis, not noise (codex #97). Missing-file and
            // open-failure verdicts (no transport) stay bare.
            currentClipDetail = verdict.decodeTransport != nil
                ? Self.clipDetail(verdict: verdict, wallSeconds: clipWall)
                : nil
            monitor.tick()
            // Funnel through the same event handler as the python arm so
            // tagging, tallies, and progress stay engine-agnostic.
            handle(event: BridgeEvent(kind: .result, path: rec.fullPath,
                                      score: verdict.score, error: verdict.error),
                   byPath: byPath, total: total)
        }
        finishRun(failure: nil)
    }

    /// Media length above which a clip earns quartile progress lines in
    /// the durable log. Short clips stay silent — a 3,000-file run must
    /// not flood videoscan.log with per-clip percentages.
    private static let quartileLogMinimumMediaSeconds: Double = 300

    private func handleNativeProgress(_ event: RecipeProgressEvent) {
        guard state.isActive else { return }
        switch event {
        case .preparing(let detail):
            subtitleText = detail
        case .ready:
            isIndeterminateValue = false
            subtitleText = "Scanning for \(person)…"
        case .beat(let clip, let frameIndex, let fraction, let mediaSeconds):
            guard isIndeterminateValue == false else { return }
            let name = clip.lastPathComponent
            logLongRunningClipIfDue(name: name, frameIndex: frameIndex,
                                    mediaSeconds: mediaSeconds)
            guard let fraction else {
                subtitleText = "Scanning \(name)…"
                return
            }
            let clamped = min(max(fraction, 0), 1)
            // Within-file % in the window (Rick 2026-08-04), and a
            // smooth overall bar: completed files + the live clip's
            // fraction over the actionable total.
            currentClipFraction = clamped
            subtitleText = "Scanning \(name)… \(Int(clamped * 100))%"
            fractionValue = (Double(completed) + clamped)
                / Double(max(actionableTotal, 1))
            if mediaSeconds >= Self.quartileLogMinimumMediaSeconds,
               let quartile = Self.quartileToLog(fraction: clamped,
                                                 alreadyLogged: clipQuartileLogged) {
                clipQuartileLogged = quartile
                appLog.write("Find \(person) scanning \(completed + 1)/\(actionableTotal): \(name) — \(quartile * 25)% of \(Self.durationText(mediaSeconds))")
            }
        }
    }

    // MARK: Protocol events

    /// One parsed line of the python bridge's JSONL protocol (the native
    /// arm synthesizes the same events so downstream handling is shared).
    /// Nonisolated + pure so codex can test the parser without a job.
    struct BridgeEvent: Equatable {
        enum Kind: Equatable { case ready(clips: Int), beat, result }
        var kind: Kind
        var path: String?
        var score: Double?
        var error: String?
    }

    nonisolated static func parseLine(_ line: String) -> BridgeEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return nil }
        switch event {
        case "ready":
            return BridgeEvent(kind: .ready(clips: obj["clips"] as? Int ?? 0))
        case "beat":
            return BridgeEvent(kind: .beat, path: obj["path"] as? String)
        case "result":
            return BridgeEvent(kind: .result,
                               path: obj["path"] as? String,
                               score: obj["score"] as? Double,
                               error: obj["error"] as? String)
        default:
            return nil
        }
    }

    private func handle(event: BridgeEvent, byPath: [String: VideoRecord], total: Int) {
        guard state.isActive else { return }
        switch event.kind {
        case .ready:
            isIndeterminateValue = false
            subtitleText = "Scanning for \(person)…"
        case .beat:
            if let path = event.path, isIndeterminateValue == false {
                let filename = (path as NSString).lastPathComponent
                subtitleText = "Scanning \(filename)…"
                // The python bridge emits beats rather than entering the
                // native loop, so persist its first beat per new clip —
                // both engines leave the same pre-stall evidence.
                if currentClipName != filename {
                    currentClipName = filename
                    appLog.write("Find \(person) scanning \(completed + 1)/\(total): \(filename)")
                }
            }
        case .result:
            completed += 1
            fractionValue = Double(completed) / Double(max(total, 1))
            guard let path = event.path else { return }
            if let error = event.error {
                errors += 1
                // Errors must move the visible status too — a frozen
                // "Scanning…" over a stream of failures reads as
                // progress (Rick 2026-08-02).
                subtitleText = "\(completed)/\(total) — \(tagged) \(person)*, \(maybes) \(person)?, \(errors) error(s)"
                findLog.warning("find \(self.person, privacy: .public) error on \((path as NSString).lastPathComponent, privacy: .public): \(error, privacy: .public)")
                recordClipOutcome(path: path, outcome: "error", record: byPath[path])
                writeDurableProgress(total: total, lastPath: path)
                return
            }
            guard let score = event.score, let rec = byPath[path],
                  let model else {
                // A valid no-face result can carry no numeric score —
                // keep the no-mutation behavior but never lose the
                // progress telemetry.
                skipped += 1
                subtitleText = "\(completed)/\(total) — \(tagged) \(person)*, \(maybes) \(person)?"
                recordClipOutcome(path: path, outcome: "no match", record: byPath[path])
                writeDurableProgress(total: total, lastPath: path)
                return
            }
            let tier = VideoScanModel.recipeTier(forScore: score, recipeID: recipeID)
            let changed = model.applyRecipeVerdict(
                person: person, record: rec, score: score, recipeID: recipeID)
            switch tier {
            case .detected:
                tagged += 1
                findLog.info("find \(self.person, privacy: .public) HIT \((path as NSString).lastPathComponent, privacy: .public): score \(String(format: "%.3f", score), privacy: .public) → \(self.person, privacy: .public)*")
            case .suspected:
                maybes += 1
                findLog.info("find \(self.person, privacy: .public) maybe \((path as NSString).lastPathComponent, privacy: .public): score \(String(format: "%.3f", score), privacy: .public) → \(self.person, privacy: .public)?")
            case .none:
                if !changed { skipped += 1 }
            }
            let outcome: String
            switch tier {
            case .detected: outcome = String(format: "%@* %.2f", person, score)
            case .suspected: outcome = String(format: "%@? %.2f", person, score)
            case .none: outcome = "no match"
            }
            recordClipOutcome(path: path, outcome: outcome, record: rec)
            subtitleText = "\(completed)/\(total) — \(tagged) \(person)*, \(maybes) \(person)?"
            writeDurableProgress(total: total, lastPath: path)
        }
    }

    /// Detail-view context + MB/s accounting for one finished clip.
    private func recordClipOutcome(path: String, outcome: String,
                                   record: VideoRecord?) {
        clipContext.previous = (path as NSString).lastPathComponent
        clipContext.previousOutcome = outcome
        if clipContext.current == clipContext.previous {
            clipContext.current = nil
            currentClipFraction = nil
        }
        scannedBytes += record?.sizeBytes ?? 0
    }

    // MARK: Progress telemetry (design distilled with codex, channel #91)

    /// One durable line per completed clip. At archive scale this is a
    /// few thousand short lines, and it makes a post-mortem independent
    /// of the UI and the volatile unified log.
    private func writeDurableProgress(total: Int, lastPath: String) {
        let elapsed = Date().timeIntervalSince(scanBeganAt ?? startedAt)
        let detail = currentClipDetail
        currentClipDetail = nil
        appLog.write(Self.progressLine(
            person: person,
            completed: completed,
            total: total,
            tagged: tagged,
            maybes: maybes,
            errors: errors,
            elapsedSeconds: elapsed,
            lastFilename: (lastPath as NSString).lastPathComponent,
            lastDetail: detail))
    }

    /// Pure formatting seam — logging is an operational contract, so
    /// tests pin the completed/total, throughput, ETA, tally, and
    /// last-file fields that were missing from the 2026-08-03 failed
    /// run's log.
    nonisolated static func progressLine(person: String,
                                         completed: Int,
                                         total: Int,
                                         tagged: Int,
                                         maybes: Int,
                                         errors: Int,
                                         elapsedSeconds: Double,
                                         lastFilename: String,
                                         lastDetail: String? = nil) -> String {
        let safeTotal = max(total, 0)
        let safeCompleted = min(max(completed, 0), safeTotal)
        let elapsed = max(elapsedSeconds, 0)
        let percent = safeTotal > 0 ? Double(safeCompleted) / Double(safeTotal) * 100 : 100
        let perHour = elapsed > 0 ? Double(safeCompleted) / elapsed * 3_600 : 0
        // "—" until a rate is measurable — an "ETA 0s" on the first
        // completion reads as nearly-done (codex review, #97).
        let eta = perHour > 0
            ? durationText(Double(max(safeTotal - safeCompleted, 0)) / perHour * 3_600)
            : "—"
        let last = lastDetail.map { "\(lastFilename) (\($0))" } ?? lastFilename
        return String(format:
            "Find %@ progress: %d/%d (%.1f%%) | %.1f files/h | ETA %@ | %d %@*, %d %@?, %d error(s) | last: %@",
            person, safeCompleted, safeTotal, percent, perHour,
            eta, tagged, person, maybes, person,
            errors, last)
    }

    /// Stall line with enough context to identify the wedge: progress
    /// position AND the file being scanned when beats stopped.
    nonisolated static func stallDescription(silentSeconds: Double,
                                             completed: Int,
                                             total: Int,
                                             currentFilename: String?) -> String {
        let clip = currentFilename.map { " while scanning \($0)" } ?? ""
        return "no progress for \(Int(max(silentSeconds, 0)))s — recipe engine stalled at \(max(completed, 0))/\(max(total, 0))\(clip)"
    }

    /// Abandon the clip currently being scored (stall-watchdog path).
    /// Returns false when there is nothing to abandon (python arm, not
    /// scoring) or the consecutive cap says the volume is sick — the
    /// caller then fails the batch as before.
    private func abandonCurrentClip(silentFor: Double) -> Bool {
        guard let pending = clipAbandonContinuation else { return false }
        consecutiveAbandons += 1
        guard consecutiveAbandons < Self.consecutiveAbandonCap else { return false }
        clipAbandonContinuation = nil
        let name = currentClipName ?? "?"
        appLog.write("Find \(person) WEDGED: skipping \(completed + 1)/\(actionableTotal): \(name) — no progress for \(Int(silentFor))s, decode abandoned (GH #156)")
        findLog.error("find \(self.person, privacy: .public) wedged clip skipped: \(name, privacy: .public) after \(Int(silentFor), privacy: .public)s")
        pending.resume(returning: nil)
        // Fresh liveness clock for the next clip (the fired monitor's
        // poll loop has exited; stop-then-start relaunches it).
        stallMonitor?.stop()
        stallMonitor?.start()
        return true
    }

    /// Wall-clock cadence for "still scanning" lines on clips that
    /// grind past this regardless of declared duration (codex #102).
    private static let longRunLogIntervalSeconds: Double = 120

    /// Durable evidence for expensive clips whose DECLARED duration
    /// suppressed quartile lines — pathological metadata (the 40 GB
    /// "36-second" mp4) must not scan in operational silence.
    private func logLongRunningClipIfDue(name: String, frameIndex: Int,
                                         mediaSeconds: Double) {
        guard let started = clipStartedAt else { return }
        let wall = Date().timeIntervalSince(started)
        guard wall > Self.longRunLogIntervalSeconds else { return }
        if let last = lastLongRunLogAt,
           Date().timeIntervalSince(last) < Self.longRunLogIntervalSeconds { return }
        lastLongRunLogAt = Date()
        let suspect = mediaSeconds < Self.longRunLogIntervalSeconds
            ? " (declared \(Int(mediaSeconds))s — suspect metadata)" : ""
        appLog.write("Find \(person) still scanning \(completed + 1)/\(actionableTotal): \(name) — \(Int(wall / 60))m elapsed, frame \(frameIndex)\(suspect)")
    }

    // MARK: Read-ahead warming (GH #157 stage 2)

    /// Cap on bytes warmed per file — page-cache warming must help the
    /// decoder, not evict the rest of the working set (repo RAM rule:
    /// spend freely, but bounded).
    private static let warmByteCap: Int64 = 6 << 30

    /// Warm the NEXT clip's bytes into the page cache while the current
    /// clip scores. Second-reader rule: never put a warming read on the
    /// SAME volume the decoder is reading unless that volume is SSD or
    /// the internal disk — two sequential readers thrash a spinning
    /// disk into a crawl (the MediaVolumeGate HDD=1 rationale). Unknown
    /// tech gets HDD caution.
    private func startWarmingNextClip(after index: Int,
                                      in actionable: [VideoRecord]) {
        warmTask?.cancel()
        warmTask = nil
        guard index + 1 < actionable.count else { return }
        let currentPath = actionable[index].fullPath
        let nextPath = actionable[index + 1].fullPath
        let currentRoot = MediaVolumeGatePolicy.volumeRoot(forPath: currentPath)
        let nextRoot = MediaVolumeGatePolicy.volumeRoot(forPath: nextPath)
        if nextRoot == currentRoot, nextRoot != "/" {
            let tech = mediaTechForPath?(nextPath) ?? .unknown
            guard tech == .ssd else { return }
        }
        let cap = Self.warmByteCap
        warmTask = Task.detached(priority: .utility) {
            guard let handle = FileHandle(forReadingAtPath: nextPath) else { return }
            defer { try? handle.close() }
            var warmed: Int64 = 0
            while warmed < cap, !Task.isCancelled {
                guard let data = try? handle.read(upToCount: 8 << 20),
                      !data.isEmpty else { break }
                warmed += Int64(data.count)
            }
        }
    }

    /// Which quartile line (1…3 = 25/50/75%) is due for a beat at
    /// `fraction`, given the highest already logged; nil when nothing
    /// new. JUMP POLICY (deliberate, codex #97): a beat that crosses
    /// several quartiles at once logs ONLY the highest one reached —
    /// these lines are for humans tailing the log, not a complete
    /// series.
    nonisolated static func quartileToLog(fraction: Double,
                                          alreadyLogged: Int) -> Int? {
        let clamped = min(max(fraction, 0), 1)
        let quartile = min(Int(clamped * 4), 3)
        return quartile > alreadyLogged ? quartile : nil
    }

    /// Per-clip stats folded into the progress line's "last:" segment.
    nonisolated static func clipDetail(verdict: RecipeClipScore,
                                       wallSeconds: Double) -> String {
        let transport = verdict.decodeTransport ?? "native"
        return "\(transport), \(verdict.frameCount)f, \(verdict.gatedFaceCount) faces, \(Self.durationText(wallSeconds))"
    }

    nonisolated private static func durationText(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    // MARK: Finish

    private func finish(summary: String? = nil, failed: String? = nil,
                        cancelled: Bool = false) {
        guard state.isActive else { return }
        warmTask?.cancel()
        warmTask = nil
        if cancelled {
            state = .cancelled
            // Actionable total, never the selected count — "19 of 7,894"
            // reads as a barely-started run when the batch was 2,988.
            let denom = actionableTotal > 0 ? actionableTotal : records.count
            subtitleText = "Cancelled — \(completed) of \(denom) scored"
            findLog.info("find person cancelled: \(self.person, privacy: .public) — \(self.completed) of \(denom) scored")
            appLog.write("Find \(person) cancelled — \(completed) of \(denom) scored")
        } else if let failed {
            state = .failed(message: failed)
            subtitleText = failed
            findLog.error("find person FAILED: \(self.person, privacy: .public) — \(failed, privacy: .public)")
            appLog.write("Find \(person) FAILED: \(failed)")
        } else if completed > 0, errors == completed {
            // Every scanned file errored — a green check here reads as
            // "all done, nothing found", which is a lie (Rick 2026-08-02).
            let text = "no file could be scanned (\(errors) error(s) — see log)"
            state = .failed(message: text)
            subtitleText = text
            findLog.error("find person FAILED: \(self.person, privacy: .public) — \(text, privacy: .public)")
            appLog.write("Find \(person) FAILED: \(text)")
        } else {
            let text = summary ?? "done"
            state = .finished(summary: text)
            subtitleText = text
            findLog.info("find person done: \(self.person, privacy: .public) — \(text, privacy: .public)")
            appLog.write("Find \(person) done: \(text)")
        }
    }
}

// MARK: - Center dispatch

extension MediaFileOperationsCenter {
    /// Start a Find & Tag job over `records`. One RUNNING job per person
    /// at a time, but a second batch no longer refuses silently (the
    /// 2026-08-04 dead click) — it QUEUES behind the newest active job
    /// for that person as a visible "Waiting…" row and starts when the
    /// predecessor finishes. Chains: a third batch waits on the second.
    @discardableResult
    func startFindPerson(person: String, records: [VideoRecord],
                         model: VideoScanModel) -> FindPersonJob? {
        let predecessor = jobs.first { job in
            guard job.state.isActive, let f = job as? FindPersonJob else { return false }
            return f.person.compare(person, options: .caseInsensitive) == .orderedSame
        } as? FindPersonJob
        let job = FindPersonJob(person: person, records: records, model: model)
        job.precededBy = predecessor
        job.mediaTechForPath = mediaTechForPath
        if predecessor != nil {
            findLog.notice("find person QUEUED: \(person, privacy: .public) — \(records.count) file(s) behind the active job")
        }
        add(job)
        job.start()
        return job
    }
}
