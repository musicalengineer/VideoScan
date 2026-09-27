// ArchiveLockJob.swift
// "Lock archive files…" / "Unlock archive files…" (Rick 2026-09-27): the
// one-time pass that locks every file the archive already holds (Promote
// locks new ones itself), and its reverse for Rick's own use. An MFO job of
// the standard long-operation shape: collapsed row with the verb chip,
// "N of M", the current file, time left, a progress bar, Pause / Stop;
// expanding the row shows the per-file results (locked / already locked /
// failed + reason) and the totals; the finished row keeps a one-line summary.
//
// What it walks: the MANIFEST's rows (archive-relative paths), never a raw
// directory walk — only files the index knows are touched. Before ANY flag
// is changed every row is checked (refuse before mutating):
//   • the manifest must open through the validated descriptor chain (not a
//     symlink, a known header, readable) — else the job refuses;
//   • every row's path must be a plain path inside the archive root — ONE
//     escaping row (a poisoned manifest) refuses the whole job, nothing
//     flagged.
// Rows outside the media buckets (10_Photos / 20_Audio / 30_Video /
// 50_Documents) are skipped and listed: 00_Index and the family tree are
// written by other features and are never locked.
//
// Folders are never locked; the system flag (schg) is never used. Each file
// goes through ArchiveFileLock.set — the one audited primitive — with reason
// `.lockAll` / `.unlockAll`. Per-file success lines go to the unified log
// only (100k lines would drown catalog.log); START, every failure, and the
// OUTCOME counts go to the console + catalog.log + videoscan.log.
//
// Memory (worst case): the manifest's text once (≤ 256 MB cap, ~20 MB at
// 100k rows) and its relpath list (~10 MB at 100k); results keep EVERY
// problem row but only the first `sampleCap` successes — bounded no matter
// how big the archive grows.
//
// (For Rick: the chunk hop is `@concurrent` — without it a `nonisolated
// async` would run on the CALLER's actor, i.e. the UI thread.)

import Combine
import Foundation
import os

@MainActor
final class ArchiveLockJob: @MainActor MediaFileOperationJob {

    enum Mode: Sendable, Equatable {
        case lock, unlock
        var change: ArchiveFileLock.Change { self == .lock ? .lock : .unlock }
        var reason: ArchiveFileLock.Reason { self == .lock ? .lockAll : .unlockAll }
        var title: String { self == .lock ? "Lock archive files" : "Unlock archive files" }
        var doneWord: String { self == .lock ? "Locked" : "Unlocked" }
        var alreadyWord: String { self == .lock ? "already locked" : "already unlocked" }
    }

    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case changed, already, failed, skipped }
        let id: Int
        let relPath: String
        let kind: Kind
        let detail: String
    }

    struct Totals: Equatable, Sendable {
        var total = 0, done = 0
        var changed = 0, already = 0, failed = 0, skipped = 0
    }

    let id = UUID()
    let kind: MediaFileOperationKind = .lockArchive
    let startedAt = Date()
    let mode: Mode
    weak var model: VideoScanModel?

    /// The flag primitives (tests stub them for the 100k scale test).
    var fileLock: ArchiveFileLock.Seams = .live
    /// Files per off-main hop (one main-actor update per chunk).
    var chunkSize = 256
    /// Successes kept for the detail list; problems are ALL kept.
    static let sampleCap = 500

    @Published private(set) var totals = Totals()
    /// Every failed / skipped row, in manifest order.
    @Published private(set) var problems: [Item] = []
    /// The first `sampleCap` locked / already-locked rows.
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

    var title: String { mode.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { state == .running }
    var isPaused: Bool { pauseRequested }

    init(mode: Mode, model: VideoScanModel) {
        self.mode = mode
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
        subtitleText = "Stopping after the current files…"
        pauseRequested = false
        task?.cancel()
    }

    func pause() { if state == .running { pauseRequested = true } }
    func resume() { pauseRequested = false }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        if let refusal = Self.preflightRefusal(model: model) {
            wasRefused = true
            model.archiveLockNote("\(mode.title): refused — \(refusal). Nothing was changed.")
            finish(failed: "Refused — \(refusal). Nothing was changed.")
            return
        }
        guard let root = model.masterArchiveRootPath else { return }
        subtitleText = "Reading the archive manifest…"
        let loaded = await Self.loadPlanOffMain(root: root)
        let plan: Plan
        switch loaded {
        case .failure(let refusal):
            let why = refusal.reason
            wasRefused = true
            model.archiveLockNote("\(mode.title): refused — \(why). Nothing was changed.")
            finish(failed: "Refused — \(why). Nothing was changed.")
            return
        case .success(let p): plan = p
        }
        totals.total = plan.relPaths.count
        isIndeterminateValue = false
        model.archiveLockNote("\(mode.title): START — \(plan.relPaths.count) archived file(s) listed in the manifest at \(root) (\(plan.skipped.count) outside the media buckets, skipped)")
        var nextID = 0
        for rel in plan.skipped {
            appendProblem(Item(id: nextID, relPath: rel, kind: .skipped,
                               detail: "not in a media bucket (10_Photos / 20_Audio / 30_Video / 50_Documents) — never locked"))
            nextID += 1
        }
        let begin = Date()
        var index = 0
        while index < plan.relPaths.count {
            while pauseRequested, !Task.isCancelled, state == .running {
                subtitleText = "Paused — \(totals.done) of \(totals.total)"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if Task.isCancelled || state == .cancelling { break }
            let end = min(index + max(1, chunkSize), plan.relPaths.count)
            let chunk = Array(plan.relPaths[index..<end])
            let results = await Self.applyChunkOffMain(root: root, relPaths: chunk, mode: mode, seams: fileLock)
            for (rel, result) in zip(chunk, results) {
                record(rel: rel, result: result, id: nextID, model: model)
                nextID += 1
            }
            index = end
            totals.done = index
            fractionValue = Double(index) / Double(max(1, plan.relPaths.count))
            subtitleText = Self.progressLine(done: index, total: plan.relPaths.count,
                                             current: chunk.last ?? "", elapsed: -begin.timeIntervalSinceNow)
        }
        let summary = Self.summaryLine(totals, mode: mode)
        if Task.isCancelled || state == .cancelling {
            model.archiveLockNote("\(mode.title): OUTCOME stopped at \(totals.done) of \(totals.total) — \(summary)")
            state = .cancelled
            subtitleText = "Stopped — \(summary)"
            isIndeterminateValue = false
            return
        }
        model.archiveLockNote("\(mode.title): OUTCOME — \(summary)")
        if totals.failed > 0 { finish(failed: summary) } else { finish(success: summary) }
    }

    private func record(rel: String, result: ArchiveFileLock.Result, id: Int, model: VideoScanModel) {
        switch result {
        case .changed:
            totals.changed += 1
            if sample.count < Self.sampleCap { sample.append(Item(id: id, relPath: rel, kind: .changed, detail: mode.doneWord.lowercased())) }
        case .alreadySo:
            totals.already += 1
            if sample.count < Self.sampleCap { sample.append(Item(id: id, relPath: rel, kind: .already, detail: mode.alreadyWord)) }
        case .absent:
            totals.failed += 1
            appendProblem(Item(id: id, relPath: rel, kind: .failed, detail: "listed in the manifest but not found in the archive"))
            model.archiveLockNote("\(mode.title): FAILED \(rel) — listed in the manifest but not found in the archive")
        case .failed(let why):
            totals.failed += 1
            appendProblem(Item(id: id, relPath: rel, kind: .failed, detail: why))
            model.archiveLockNote("\(mode.title): FAILED \(rel) — \(why)")
        }
    }

    private func appendProblem(_ item: Item) {
        problems.append(item)
        if item.kind == .skipped { totals.skipped += 1 }
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested {
            state = .cancelled
            subtitleText = "Stopped"
            isIndeterminateValue = false
            return
        }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
    }

    // MARK: Pure pieces

    /// "Locked 812 · already locked 4 · failed 1 · skipped 2".
    nonisolated static func summaryLine(_ t: Totals, mode: Mode) -> String {
        var parts = ["\(mode.doneWord) \(t.changed)", "\(mode.alreadyWord) \(t.already)", "failed \(t.failed)"]
        if t.skipped > 0 { parts.append("skipped \(t.skipped)") }
        return parts.joined(separator: " · ")
    }

    /// "1,204 of 9,870 · 30_Video/…/x.mov · ~2 min left".
    nonisolated static func progressLine(done: Int, total: Int, current: String, elapsed: TimeInterval) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        let d = f.string(from: NSNumber(value: done)) ?? "\(done)"
        let t = f.string(from: NSNumber(value: total)) ?? "\(total)"
        var left = ""
        if done > 0, total > done, elapsed > 1 {
            let secs = elapsed / Double(done) * Double(total - done)
            left = secs < 60 ? " · ~\(max(1, Int(secs.rounded()))) s left" : " · ~\(Int((secs / 60).rounded())) min left"
        }
        return "\(d) of \(t) · \((current as NSString).lastPathComponent)\(left)"
    }

    /// Main-actor refusals, before anything is read.
    static func preflightRefusal(model: VideoScanModel) -> String? {
        if model.isReadOnly { return "this Mac is a read-only viewer of the catalog" }
        guard let root = model.masterArchiveRootPath else { return "no Master Archive is designated" }
        if let refusal = model.masterArchiveIdentityRefusal() { return refusal }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return "the Master Archive is not reachable (\(root))"
        }
        return nil
    }

    struct PlanRefusal: Error, Equatable, Sendable { let reason: String }

    struct Plan: Sendable, Equatable {
        /// Media-bucket files to flag, manifest order, each once.
        let relPaths: [String]
        /// Contained rows outside the media buckets (listed, never flagged).
        let skipped: [String]
    }

    /// Read + validate the WHOLE manifest before anything is flagged.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadPlanOffMain(root: String) async -> Result<Plan, PlanRefusal> {
        switch ArchiveRefile.manifestRows(rootPath: root) {
        case .failure(let f): return .failure(PlanRefusal(reason: f.reason))
        case .success(let rows): return plan(fromRelPaths: rows.map(\.relPath), root: root)
        }
    }

    /// Pure: dedupe, validate containment (ANY escaping row refuses the
    /// whole job), split media buckets from the rest.
    nonisolated static func plan(fromRelPaths all: [String], root: String) -> Result<Plan, PlanRefusal> {
        var seen = Set<String>()
        var media: [String] = [], other: [String] = []
        for rel in all where seen.insert(rel).inserted {
            guard ArchivePromoteEngine.isContainedRelPath(rel, root: root) else {
                return .failure(PlanRefusal(reason: "the archive manifest lists a path that is not a plain path inside the archive (\(rel)) — the manifest looks damaged; check it by hand"))
            }
            let bucket = (rel as NSString).pathComponents.first ?? ""
            if ArchiveRefileAuthorization.movableBuckets.contains(bucket) { media.append(rel) } else { other.append(rel) }
        }
        return .success(Plan(relPaths: media, skipped: other))
    }

    /// One chunk of flag changes, off the main actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func applyChunkOffMain(root: String, relPaths: [String], mode: Mode,
                                              seams: ArchiveFileLock.Seams) async -> [ArchiveFileLock.Result] {
        relPaths.map { rel in
            ArchiveFileLock.set(mode.change, root: root, relPath: rel, reason: mode.reason, seams: seams,
                                audit: { archiveLockLog.debug("\($0, privacy: .public)") })
        }
    }
}

// MARK: - Audit sink + start

extension VideoScanModel {
    /// Console + catalog.log (`log`), videoscan.log, unified log — main actor.
    func archiveLockNote(_ line: String) {
        log(line)
        appLog.write("[archive-lock] " + line)
        archiveLockLog.notice("\(line, privacy: .public)")
    }
}

extension MediaFileOperationsCenter {
    /// Start ONE lock / unlock pass. Refused (parked, nothing started) while
    /// another lock / unlock pass is active.
    @discardableResult
    func startArchiveLock(mode: ArchiveLockJob.Mode, model: VideoScanModel) -> ArchiveLockJob {
        let job = ArchiveLockJob(mode: mode, model: model)
        add(job)
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is ArchiveLockJob }) {
            job.refuseToStart(reason: "A lock / unlock pass is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: mode == .lock
                                               ? "set the user-immutable flag on every archived file the manifest lists"
                                               : "clear the user-immutable flag on every archived file the manifest lists"))
        return job
    }
}
