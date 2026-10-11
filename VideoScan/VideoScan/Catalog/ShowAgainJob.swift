// ShowAgainJob.swift
// "Show these files again" as a Media File Operations row (CLAUDE.md "Long
// operations"): verb chip "Show Again", what it is doing, "N of M", the
// current file, time left, a progress bar, Stop; double-click for every file
// that stayed labelled (with why) and the first files shown again; the
// finished row keeps the one-line summary. START / progress / OUTCOME lines
// go to the console, catalog.log and videoscan.log through
// `showAgainNote`; one per-file line goes to catalog.log.
//
// No Pause: the long part is ~one stat per file (seconds on Rick's ~1,000);
// the label change itself is one synchronous step. Stop is honoured until
// the safety snapshot is written — after that the change is instant and
// all-or-nothing. A Stop that lands then is reported as what it was.
//
// The job runs EXACTLY the reviewed plan (the sheet's dry run): a file the
// review did not offer is never changed, and each offered file is checked
// again at the job's turn (ShowAgain+Apply).

import Combine
import Foundation
import SwiftUI

@MainActor
final class ShowAgainJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    static let title = "Show files hidden by a “deleted” label"

    let id = UUID()
    let kind: MediaFileOperationKind = .showAgain
    let startedAt = Date()
    weak var model: VideoScanModel?
    let reviewed: ShowAgainPlan
    /// Tests inject a fake disk; production uses the real one.
    var disk: ShowAgainDisk = .live

    /// Files shown again kept for the detail list; stays are ALL kept.
    static let sampleCap = 500

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var result: VideoScanModel.ShowAgainRunResult?
    @Published private(set) var reverse: VideoScanModel.ShowAgainReverseResult?
    @Published private(set) var isReversing = false
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var detailView: AnyView { AnyView(ShowAgainDetailView(job: self)) }

    init(model: VideoScanModel, reviewed: ShowAgainPlan) {
        self.model = model
        self.reviewed = reviewed
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        state = .failed(message: reason)
        subtitleText = reason
        isIndeterminateValue = false
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Stopping — nothing changes unless the labels were already being set…"
        task?.cancel()
    }

    // MARK: Run

    private func run() async {
        guard let model else {
            state = .failed(message: "The catalog went away before the job could start")
            return
        }
        let total = reviewed.showCount
        subtitleText = "Checking \(total.formatted()) files on disk and in the ledger…"
        isIndeterminateValue = false
        let begin = Date()
        let names = reviewed.toShow.map(\.candidate.filename)
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, all in
            Task { @MainActor [weak self] in
                self?.tick(done: done, total: all, names: names, begin: begin)
            }
        }
        let outcome = await model.applyShowAgain(reviewed: reviewed, disk: disk, progress: progress)
        finish(outcome)
    }

    private func tick(done: Int, total: Int, names: [String], begin: Date) {
        guard state == .running, total > 0 else { return }
        fractionValue = Double(done) / Double(total)
        let current = done < names.count ? names[done] : ""
        subtitleText = ArchiveLockJob.progressLine(done: done, total: total, current: current,
                                                   elapsed: -begin.timeIntervalSinceNow)
    }

    private func finish(_ r: VideoScanModel.ShowAgainRunResult) {
        result = r
        fractionValue = 1
        isIndeterminateValue = false
        switch r.outcome {
        case .shown, .nothingToDo:
            state = .finished(summary: r.summary)
            subtitleText = r.summary
        case .saveUnconfirmed:
            state = .failed(message: r.summary + " — catalog save not confirmed; it will be retried")
            subtitleText = r.summary + " — save not confirmed"
        case .refused(let why):
            wasRefused = true
            state = .failed(message: "Refused — \(why). Nothing was changed.")
            subtitleText = "Refused — \(why). Nothing was changed."
        case .stopped:
            state = .cancelled
            subtitleText = "Stopped — nothing was changed"
        }
    }

    // MARK: Reverse (the detail view's "Put the labels back")

    var canReverse: Bool {
        guard !state.isActive, !isReversing, reverse == nil, let r = result else { return false }
        return r.receiptURL != nil && !r.shown.isEmpty
    }

    func putLabelsBack() {
        guard canReverse, let url = result?.receiptURL, let model else { return }
        isReversing = true
        Task { [weak self] in
            let out = await model.reverseShowAgain(receiptURL: url)
            self?.reverse = out
            self?.isReversing = false
        }
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start the run for a reviewed plan. Refused (parked, nothing started)
    /// while another Show Again run is active.
    @discardableResult
    func startShowAgain(model: VideoScanModel, reviewed: ShowAgainPlan) -> ShowAgainJob {
        let job = ShowAgainJob(model: model, reviewed: reviewed)
        guard add(job) else { return job }
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is ShowAgainJob }) {
            job.refuseToStart(reason: "Show Again is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "\(reviewed.headline) — label only; files are not touched"))
        return job
    }
}

// MARK: - Detail

struct ShowAgainDetailView: View {
    @ObservedObject var job: ShowAgainJob
    @State private var confirmReverse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 12, weight: .medium))
            if let r = job.result {
                list(r)
                reverseRow(r)
            } else {
                Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
    }

    private var headline: String {
        job.result?.summary ?? "\(job.reviewed.headline) (reviewed)"
    }

    @ViewBuilder private func list(_ r: VideoScanModel.ShowAgainRunResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(r.stayed, id: \.candidate.id) { s in
                    row(icon: "eye.slash", tint: .orange, path: s.candidate.fullPath, detail: "left labelled — " + s.reason.words)
                }
                ForEach(r.shown.prefix(ShowAgainJob.sampleCap)) { c in
                    row(icon: "eye", tint: .green, path: c.fullPath, detail: "shown again — on disk at \(MediaBytes.display(c.sizeBytes))")
                }
                if r.shown.count > ShowAgainJob.sampleCap {
                    Text("…and \((r.shown.count - ShowAgainJob.sampleCap).formatted()) more shown again (every file is listed in catalog.log)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    @ViewBuilder private func reverseRow(_ r: VideoScanModel.ShowAgainRunResult) -> some View {
        if let rev = job.reverse {
            Text(rev.refusal.map { "Put back refused — \($0)" }
                 ?? "Labels put back on \(rev.restored.formatted()) file(s); \(rev.skipped.count.formatted()) had changed and were left as they are.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if job.canReverse {
            Button("Put the labels back…") { confirmReverse = true }
                .controlSize(.small)
                .accessibilityIdentifier("mfo.showAgain.putLabelsBack")
                .confirmationDialog("Hide these \(r.shown.count.formatted()) files again behind the “deleted” label?",
                                    isPresented: $confirmReverse) {
                    Button("Put the labels back") { job.putLabelsBack() }
                } message: {
                    Text("Only the label changes back. Files are not touched.")
                }
        }
    }

    private func row(icon: String, tint: Color, path: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 12)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
