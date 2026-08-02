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
    // Internal flag — the python bridge stays the DEFAULT until the native
    // engine's calibration + G2 grading prove parity. Flip for a session
    // via `VIDEOSCAN_NATIVE_RECIPE=1` or from test code; each job captures
    // the flag at init so a mid-job flip can't switch engines.
    nonisolated(unsafe) static var useNativeEngine: Bool =
        ProcessInfo.processInfo.environment["VIDEOSCAN_NATIVE_RECIPE"] == "1"

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

    /// Tallies for the completion summary.
    private var tagged = 0          // detected tier
    private var maybes = 0          // suspected tier
    private var skipped = 0         // veto/confirmed/no-change
    private var errors = 0
    private var completed = 0
    private var stallReason: String?

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

    // MARK: Run

    private func run() async {
        // Records the recipe may act on — the veto/confirmed skips are
        // also enforced in applyRecipeVerdict; filtering here just saves
        // the engine the decode time.
        let eligible = records.filter { rec in
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
        skipped = records.count - eligible.count
        appLog.write("Find \(person) started: \(records.count) selected → \(actionable.count) to scan"
                     + (offline > 0 ? ", \(offline) on offline volumes (skipped)" : "")
                     + (skipped > 0 ? ", \(skipped) already confirmed/rejected" : "")
                     + " [\(recipeID), tiers ≥\(VideoScanModel.recipeDetectedMinScore) detected / ≥\(VideoScanModel.recipeSuspectedMinScore) suspected]")
        guard !actionable.isEmpty else {
            let why = offline > 0
                ? "all \(eligible.count) remaining file(s) are on offline volumes — mount them and re-run"
                : "all \(records.count) file(s) already confirmed or rejected for \(person)"
            finish(summary: "Nothing scanned — \(why)")
            return
        }

        let byPath = Dictionary(uniqueKeysWithValues:
            actionable.map { ($0.fullPath, $0) })
        let total = actionable.count

        let monitor = StallMonitor(label: "find \(person)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                guard let self, self.state.isActive, self.stallReason == nil else { return }
                self.stallReason = "no progress for \(Int(silentFor))s — recipe engine stalled"
                self.task?.cancel()
            }
        }
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

        for rec in actionable {
            if Task.isCancelled || !state.isActive { break }
            let clip = URL(fileURLWithPath: rec.fullPath)
            let verdict: RecipeClipScore
            if FileManager.default.fileExists(atPath: rec.fullPath) {
                verdict = await scorer.score(clip: clip)
            } else {
                verdict = RecipeClipScore(error: "missing file")
            }
            if Task.isCancelled { break }
            monitor.tick()
            // Funnel through the same event handler as the python arm so
            // tagging, tallies, and progress stay engine-agnostic.
            handle(event: BridgeEvent(kind: .result, path: rec.fullPath,
                                      score: verdict.score, error: verdict.error),
                   byPath: byPath, total: total)
        }
        finishRun(failure: nil)
    }

    private func handleNativeProgress(_ event: RecipeProgressEvent) {
        guard state.isActive else { return }
        switch event {
        case .preparing(let detail):
            subtitleText = detail
        case .ready:
            isIndeterminateValue = false
            subtitleText = "Scanning for \(person)…"
        case .beat(let clip, _):
            if isIndeterminateValue == false {
                subtitleText = "Scanning \(clip.lastPathComponent)…"
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
                subtitleText = "Scanning \((path as NSString).lastPathComponent)…"
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
                return
            }
            guard let score = event.score, let rec = byPath[path],
                  let model else { return }
            let tier = VideoScanModel.recipeTier(forScore: score)
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
            subtitleText = "\(completed)/\(total) — \(tagged) \(person)*, \(maybes) \(person)?"
        }
    }

    // MARK: Finish

    private func finish(summary: String? = nil, failed: String? = nil,
                        cancelled: Bool = false) {
        guard state.isActive else { return }
        if cancelled {
            state = .cancelled
            subtitleText = "Cancelled — \(completed) of \(records.count) scored"
            findLog.info("find person cancelled: \(self.person, privacy: .public) — \(self.completed) of \(self.records.count) scored")
            appLog.write("Find \(person) cancelled — \(completed) of \(records.count) scored")
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
    /// Start a Find & Tag job over `records`. One active job per person
    /// at a time — a second dispatch while one runs is refused (same
    /// duplicate rule as verify).
    @discardableResult
    func startFindPerson(person: String, records: [VideoRecord],
                         model: VideoScanModel) -> FindPersonJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let f = job as? FindPersonJob else { return false }
            return f.person.compare(person, options: .caseInsensitive) == .orderedSame
        }
        guard !duplicate else {
            findLog.notice("find person REFUSED duplicate dispatch: \(person, privacy: .public) job already active")
            return nil
        }
        let job = FindPersonJob(person: person, records: records, model: model)
        add(job)
        job.start()
        return job
    }
}
