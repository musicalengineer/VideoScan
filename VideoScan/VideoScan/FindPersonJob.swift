import Combine
import Foundation
import os

// MARK: - FindPersonJob (Find & Tag, 2026-08-02)
//
// Runs a per-person detector recipe over a batch of records and applies
// MACHINE-tier person tags through VideoScanModel.applyRecipeVerdict
// (docs/find-and-tag-design.md). v1 bridges to the python recipe engine
// (tools/donna-recipe/find_person_batch.py) via ProcessRunner — ONE
// python process per job (model prep paid once), streaming a JSONL
// protocol: ready / beat (watchdog ticks) / result (per clip).
//
// Cancellation: Task.cancel → ProcessRunner SIGTERM→SIGKILL escalation.
// Pause: JobPauseCoordinator SIGSTOPs the python child (and its ffmpeg
// grandchildren stall naturally on the stopped parent's pipe).
// Stall: beats arrive every ~50 frames; monitor threshold default 5 min.
//
// For Rick: this is the ProcessRunner-until-proven implementation; the
// Swift-native engine replaces the bridge behind this SAME job later.

private let findLog = Logger(subsystem: "Rick-Breen.VideoScan",
                             category: "fileOps")

@MainActor
final class FindPersonJob: MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .findPerson
    let startedAt = Date()

    /// Person this job hunts (v1: "Donna" — the only tuned recipe).
    let person: String
    let recipeID = "recipe-v1-python"
    let records: [VideoRecord]

    private weak var model: VideoScanModel?

    /// Pause via SIGSTOP/SIGCONT on the python child (GH #150 plumbing).
    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
    }

    func resume() {
        guard pauser.resume() else { return }
        isPausedValue = false
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

    // v1 constants — Rick's machine (see find-and-tag-design.md).
    static let pythonPath = "\(NSHomeDirectory())/dev/VideoScan/venv/bin/python3.12"
    static let scriptPath = "\(NSHomeDirectory())/dev/VideoScan/tools/donna-recipe/find_person_batch.py"
    static let galleryPath = "\(NSHomeDirectory())/dev/VideoScan/tests/fixtures/photos/Donna"

    init(person: String, records: [VideoRecord], model: VideoScanModel) {
        self.person = person
        self.records = records
        self.model = model
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
    }

    // MARK: Run

    private func run() async {
        // Records the recipe may act on — the veto/confirmed skips are
        // also enforced in applyRecipeVerdict; filtering here just saves
        // python the decode time.
        let actionable = records.filter { rec in
            !rec.rejectedPeople.contains {
                $0.compare(person, options: .caseInsensitive) == .orderedSame
            } && !rec.confirmedByUserPeople.contains {
                $0.name.compare(person, options: .caseInsensitive) == .orderedSame
            }
        }
        skipped = records.count - actionable.count
        guard !actionable.isEmpty else {
            finish(summary: "Nothing to do — all \(records.count) file(s) already confirmed or rejected for \(person)")
            return
        }

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

        findLog.info("find person START: \(self.person, privacy: .public) over \(total) file(s)")
        let result = await ProcessRunner.runProcess(
            executable: Self.pythonPath,
            arguments: [Self.scriptPath,
                        "--gallery", Self.galleryPath,
                        "--clips-file", clipsFile.path],
            stdoutLine: { [weak self] line in
                monitor.tick()
                guard let event = FindPersonJob.parseLine(line) else { return }
                Task { @MainActor [weak self] in
                    self?.handle(event: event, byPath: byPath, total: total)
                }
            },
            stderrLine: { _ in monitor.tick() },   // model-load chatter counts as life
            control: pauser.control
        )

        if let stallReason {
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            finish(cancelled: true)
            return
        }
        guard result.exitCode == 0 else {
            let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
            finish(failed: "recipe engine exited \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")")
            return
        }
        finish(summary: "\(person)*: \(tagged) tagged, \(maybes) maybe (\(person)?), \(skipped) skipped, \(errors) error(s)")
    }

    // MARK: Protocol events

    /// One parsed line of the python bridge's JSONL protocol.
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
                findLog.warning("find \(self.person, privacy: .public) error on \((path as NSString).lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return
            }
            guard let score = event.score, let rec = byPath[path],
                  let model else { return }
            let tier = VideoScanModel.recipeTier(forScore: score)
            let changed = model.applyRecipeVerdict(
                person: person, record: rec, score: score, recipeID: recipeID)
            switch tier {
            case .detected: tagged += 1
            case .suspected: maybes += 1
            case .none: if !changed { skipped += 1 }
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
            findLog.info("find person cancelled: \(self.person, privacy: .public) — \(self.completed) of \(self.records.count) scored")
        } else if let failed {
            state = .failed(message: failed)
            findLog.error("find person FAILED: \(self.person, privacy: .public) — \(failed, privacy: .public)")
        } else {
            let text = summary ?? "done"
            state = .finished(summary: text)
            findLog.info("find person done: \(self.person, privacy: .public) — \(text, privacy: .public)")
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
