// FindMovedCopiesJob.swift — GH #339, Held Back at Import ▸ Find Moved
// Copies: the MFO JOB (CLAUDE.md rule 5; ARCHITECTURE §10.6).
//
// One sentence: for every gone held-back row that has a same-name, same-size
// live file and something to carry, read that live file and prove (or
// disprove) it is the same content — then hand the proven pairs to the store
// as OFFERS. It writes NOTHING: no catalog row, no file, no ledger line; the
// carry is a separate act Rick confirms (HeldBackStore.carry).
//
// Proof (HeldBackProver), bound to the DESTINATION (Codex #385 #1): the
// live file's catalog row must store a whole-file SHA-256 (else not offered
// — "needs a full hash"), and every byte read now must hash to it (else not
// offered — "not the content its row records"). Then: that digest equal to
// the row's stored one → PROVEN; else the `v1:` sampled hash read now equal
// to the row's → LIKELY the same file (sampled check — every word says so);
// a row with neither is never offered. A name + size match whose content
// differs is NOT offered — counted "differs" and named in the log.
//
// Pause / Stop between files and inside a whole-file read (the gate's
// stop cancels the read at the next 1 MiB block). Stop keeps what was
// proven so far. START / per-pair / OUTCOME through `note`.
//
// Memory: one 1 MiB read buffer at a time (the whole-file read, then for a
// sampled row three 1 MiB windows); the plan (≈ 1 KB a task) and the offers
// (≈ 1 KB each) stay with the row. Reads are sequential: one file at a time,
// so a USB drive is never asked for two streams.
//
// (For Rick: the worker loop runs on a detached task per file — a thread the
// UI thread awaits — and the shared pause/stop flags are FindMasterGate's
// mutex + condition variable.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class FindMovedCopiesJob: @MainActor MediaFileOperationJob {

    struct Tally: Equatable, Sendable {
        var rows = 0
        var candidates = 0
        var proven = 0
        var likely = 0
        var differs = 0
        var notRecordedContent = 0
        var needsFullHash = 0
        var noEvidence = 0
        var couldNotRead = 0
        var notStarted = 0
        var stopped = false
    }

    let id = UUID()
    let kind: MediaFileOperationKind = .findMovedCopies
    let startedAt = Date()
    let title = HeldBackWords.jobTitle
    let plan: HeldBackJobPlan
    let canPause = true
    private let prover: HeldBackProver
    private let note: (String) -> Void
    private let deliver: ([HeldBackOffer]) -> Void
    let gate = FindMasterGate()

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Starting…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPaused = false
    private(set) var tally = Tally()
    private(set) var offers: [HeldBackOffer] = []
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    /// `prover` nil = the live reads, cancelled by this job's Stop.
    init(plan: HeldBackJobPlan, prover: HeldBackProver? = nil, note: @escaping (String) -> Void,
         deliver: @escaping ([HeldBackOffer]) -> Void) {
        self.plan = plan
        let gate = self.gate
        self.prover = prover ?? HeldBackProver.live(shouldCancel: { gate.isStopped })
        self.note = note
        self.deliver = deliver
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Stopping…"
        gate.stop()
    }

    func pause() {
        guard state == .running, !isPaused else { return }
        isPaused = true
        gate.pause()
        subtitleText = "Paused — " + subtitleText
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        gate.resume()
        subtitleText = subtitleText.replacingOccurrences(of: "Paused — ", with: "")
    }

    private func run() async {
        tally.rows = plan.tasks.count
        tally.candidates = plan.candidateCount
        note("START find moved copies — \(plan.tasks.count) gone row(s) with a same-name, same-size live file and something to carry "
             + "(\(plan.candidateCount) file(s) to read); left out: \(plan.skippedNothingToCarry) with nothing to carry, "
             + "\(plan.skippedFinding) with an integrity finding, \(plan.skippedUnreadable) whose old record could not be read. Writes nothing.")
        isIndeterminateValue = plan.candidateCount == 0
        var done = 0
        outer: for t in plan.tasks {
            for live in t.candidates {
                if await stoppedWhilePaused() {
                    tally.notStarted = plan.candidateCount - done
                    break outer
                }
                subtitleText = "Checking \(done + 1) of \(plan.candidateCount) — \(live.filename)"
                let prover = self.prover, digest = t.entry.digest, sampled = t.entry.sampledHash, path = live.fullPath
                let destination = live.digest
                let result = await Task.detached(priority: .userInitiated) {
                    prover.prove(rowDigest: digest, rowSampled: sampled, candidatePath: path, destinationDigest: destination)
                }.value
                record(result, task: t, live: live)
                done += 1
                fractionValue = Double(done) / Double(max(1, plan.candidateCount))
            }
        }
        finish()
    }

    private func stoppedWhilePaused() async -> Bool {
        while gate.isPaused && !gate.isStopped {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return gate.isStopped
    }

    private func record(_ result: HeldBackProofResult, task t: HeldBackProofTask, live: HeldBackLive) {
        let pair = "row \(t.entry.qid) \(t.entry.filename) → \(live.fullPath)"
        switch result {
        case .proven(let evidence, let stamp):
            if evidence == .wholeFileSHA256 { tally.proven += 1 } else { tally.likely += 1 }
            let offer = HeldBackOffer.make(entry: t.entry, old: t.old, live: live, evidence: evidence, stamp: stamp)
            offers.append(offer)
            note("  \(evidence == .wholeFileSHA256 ? "PROVEN" : "LIKELY") \(pair) — \(evidence.label)"
                 + (offer.blocked.map { " — not offered: \($0)" } ?? ""))
        case .differs(let evidence):
            tally.differs += 1
            note("  DIFFERS \(pair): same name and size, different content (\(evidence.rawValue)) — not offered")
        case .notTheRecordedContent:
            tally.notRecordedContent += 1
            note("  NOT OFFERED \(pair): every byte read now does not hash to the SHA-256 its own catalog row records — "
                 + "its values cannot be carried onto that row")
        case .noDestinationDigest:
            tally.needsFullHash += 1
            note("  NOT OFFERED \(pair): \(HeldBackWords.needsFullHash)")
        case .noEvidence:
            tally.noEvidence += 1
            note("  NO PROOF \(pair): the old row carries no whole-file or sampled hash — not offered")
        case .couldNotRead(let why):
            tally.couldNotRead += 1
            note("  NOT CHECKED \(pair): \(why) — not offered")
        }
    }

    private func finish() {
        isIndeterminateValue = false
        tally.stopped = gate.isStopped
        deliver(offers)
        let summary = Self.summary(tally)
        note("OUTCOME find moved copies — " + summary + " · nothing was written")
        subtitleText = summary
        if tally.stopped {
            state = .cancelled
        } else {
            fractionValue = 1
            state = .finished(summary: summary)
        }
    }

    nonisolated static func summary(_ t: Tally) -> String {
        var parts = ["\(t.proven) proven (whole-file SHA-256)"]
        if t.likely > 0 { parts.append("\(t.likely) likely the same file (sampled check)") }
        parts.append("\(t.differs) differ")
        if t.notRecordedContent > 0 { parts.append("\(t.notRecordedContent) not the content their catalog row records") }
        if t.needsFullHash > 0 { parts.append("\(t.needsFullHash) need a full hash first") }
        if t.couldNotRead > 0 { parts.append("\(t.couldNotRead) not checked") }
        if t.noEvidence > 0 { parts.append("\(t.noEvidence) no proof possible") }
        if t.notStarted > 0 { parts.append("\(t.notStarted) not started") }
        return (t.stopped ? "Stopped — " : "") + parts.joined(separator: " · ") + " (of \(t.candidates) file(s) for \(t.rows) row(s))"
    }
}

extension MediaFileOperationsCenter {
    /// Start ONE Find Moved Copies run. Refused (nothing started) while another is active.
    @discardableResult
    func startFindMovedCopies(plan: HeldBackJobPlan, note: @escaping (String) -> Void,
                              deliver: @escaping ([HeldBackOffer]) -> Void) -> FindMovedCopiesJob? {
        guard !jobs.contains(where: { $0.state.isActive && $0 is FindMovedCopiesJob }) else {
            note("REFUSED find moved copies — it is already running. Nothing was started.")
            return nil
        }
        let job = FindMovedCopiesJob(plan: plan, note: note, deliver: deliver)
        guard add(job) else { return nil }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "\(plan.candidateCount) live file(s) to read for \(plan.tasks.count) held-back row(s) — checks by content (whole-file SHA-256 proves; a sampled check says only likely); writes nothing"))
        return job
    }
}
