// ArchiveLockJob.swift
// "Lock files already in the archive (one-time)…" (Rick 2026-09-27): Promote
// locks every file it lands; this is the ONE-TIME catch-up for files
// promoted before locking existed. Once it has completed cleanly a marker
// in App Support hides the menu item for good. There is no Unlock job — only
// Update… unlocks (to move a file) and relocks it; Rick can use `chflags` in
// Terminal if he ever needs to.
//
// An MFO job of the standard long-operation shape: collapsed row with the
// verb chip, "N of M", the current file, time left, a progress bar, Pause /
// Stop; expanding the row shows the per-file results (locked / already
// locked / failed / busy / skipped + reason) and the totals; the finished
// row keeps a one-line summary.
//
// What it walks: the MANIFEST's rows (archive-relative paths), never a raw
// directory walk — only files the index knows are touched.
//   • The manifest must open through the validated descriptor chain (not a
//     symlink, a known header, readable) — else the job refuses.
//   • A whole row whose path escapes the archive root (a poisoned manifest)
//     refuses the whole job BEFORE any flag changes.
//   • A short / malformed row is SKIPPED AND REPORTED (codex r1 #5, Rick's
//     ruling): its text is never used as a path.
//   • Rows outside the media buckets (00_Index, 40_Family_Tree) are skipped
//     and listed — never locked.
//
// Update… coordination (codex r1 #1): each file's flag is set while holding
// the SAME 00_Index lock Update holds for its whole transaction
// (ArchiveIndexLock, try-lock, never a wait), through a path resolved afresh
// under that lock. A file Update is moving right now is skipped and reported
// "busy — being updated"; lock-all can never freeze a file between Update's
// move and its rollback.
//
// Folders are never locked; the system flag (schg) is never used. Each file
// goes through ArchiveFileLock.set — the one audited primitive — reason
// `.lockAll`. Per-file success lines go to the unified log only (100k lines
// would drown catalog.log); START, every failure / busy file, and the
// OUTCOME counts go to the console + catalog.log + videoscan.log.
//
// Memory (worst case): the manifest's text once (≤ 256 MB cap, ~20 MB at
// 100k rows) and its relpath list (~10 MB at 100k); results keep EVERY
// problem row but only the first `sampleCap` successes.
//
// (For Rick: the chunk hop is `@concurrent` — without it a `nonisolated
// async` would run on the CALLER's actor, i.e. the UI thread.)

import Combine
import Foundation
import os

@MainActor
final class ArchiveLockJob: @MainActor MediaFileOperationJob {

    static let title = "Lock files already in the archive"

    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case changed, already, failed, skipped, busy }
        let id: Int
        let relPath: String
        let kind: Kind
        let detail: String
    }

    struct Totals: Equatable, Sendable {
        var total = 0, done = 0
        var changed = 0, already = 0, failed = 0, skipped = 0
        /// Being changed by Update… at that moment — skipped, run again.
        var busy = 0
    }

    let id = UUID()
    let kind: MediaFileOperationKind = .lockArchive
    let startedAt = Date()
    weak var model: VideoScanModel?

    /// The flag primitives (tests stub them for the 100k scale test).
    var fileLock: ArchiveFileLock.Seams = .live
    /// Files per off-main hop (one main-actor update per chunk).
    var chunkSize = 256
    /// Successes kept for the detail list; problems are ALL kept.
    static let sampleCap = 500

    @Published private(set) var totals = Totals()
    /// Every failed / busy / skipped row, in manifest order.
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

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { state == .running }
    var isPaused: Bool { pauseRequested }

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
        if let refusal = Self.preflightRefusal(model: model) { refuse(refusal, model: model); return }
        guard let root = model.masterArchiveRootPath else { return }
        subtitleText = "Reading the archive manifest…"
        let plan: Plan
        switch await Self.loadPlanOffMain(root: root) {
        case .failure(let r): refuse(r.reason, model: model); return
        case .success(let p): plan = p
        }
        totals.total = plan.relPaths.count
        isIndeterminateValue = false
        model.archiveLockNote("\(title): START — \(plan.relPaths.count) archived file(s) listed in the manifest at \(root) (\(plan.skipped.count) row(s) skipped)")
        var nextID = 0
        for s in plan.skipped {
            problems.append(Item(id: nextID, relPath: s.row, kind: .skipped, detail: s.why))
            totals.skipped += 1
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
            let results = await Self.applyChunkOffMain(root: root, relPaths: chunk, seams: fileLock)
            for (rel, outcome) in zip(chunk, results) {
                record(rel: rel, outcome: outcome, id: nextID, model: model)
                nextID += 1
            }
            index = end
            totals.done = index
            fractionValue = Double(index) / Double(max(1, plan.relPaths.count))
            subtitleText = Self.progressLine(done: index, total: plan.relPaths.count,
                                             current: chunk.last ?? "", elapsed: -begin.timeIntervalSinceNow)
        }
        let summary = Self.summaryLine(totals)
        if Task.isCancelled || state == .cancelling {
            model.archiveLockNote("\(title): OUTCOME stopped at \(totals.done) of \(totals.total) — \(summary)")
            state = .cancelled
            subtitleText = "Stopped — \(summary)"
            isIndeterminateValue = false
            return
        }
        model.archiveLockNote("\(title): OUTCOME — \(summary)")
        if let notComplete = Self.notCompleteReason(totals: totals, plan: plan, summary: summary) {
            if notComplete != summary { model.archiveLockNote("\(title): \(notComplete)") }
            finish(failed: notComplete)   // not complete: the menu item stays
        } else {
            finish(success: summary)
            model.markArchiveLockCatchUpDone(summary: summary)
        }
    }

    private func refuse(_ why: String, model: VideoScanModel) {
        wasRefused = true
        model.archiveLockNote("\(title): refused — \(why). Nothing was changed.")
        finish(failed: "Refused — \(why). Nothing was changed.")
    }

    private func record(rel: String, outcome: LockOutcome, id: Int, model: VideoScanModel) {
        switch outcome {
        case .busy:
            totals.busy += 1
            problems.append(Item(id: id, relPath: rel, kind: .busy,
                                 detail: "busy — being updated right now; skipped (run the job again)"))
            model.archiveLockNote("\(title): SKIPPED \(rel) — busy, being updated right now")
        case .result(.changed):
            totals.changed += 1
            if sample.count < Self.sampleCap { sample.append(Item(id: id, relPath: rel, kind: .changed, detail: "locked")) }
        case .result(.alreadySo):
            totals.already += 1
            if sample.count < Self.sampleCap { sample.append(Item(id: id, relPath: rel, kind: .already, detail: "already locked")) }
        case .result(.absent):
            totals.failed += 1
            problems.append(Item(id: id, relPath: rel, kind: .failed, detail: "listed in the manifest but not found in the archive"))
            model.archiveLockNote("\(title): FAILED \(rel) — listed in the manifest but not found in the archive")
        case .result(.failed(let why)):
            totals.failed += 1
            problems.append(Item(id: id, relPath: rel, kind: .failed, detail: why))
            model.archiveLockNote("\(title): FAILED \(rel) — \(why)")
        }
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

    /// "Locked 812 · already locked 4 · failed 1 · busy 1 · skipped 2".
    nonisolated static func summaryLine(_ t: Totals) -> String {
        var parts = ["Locked \(t.changed)", "already locked \(t.already)", "failed \(t.failed)"]
        if t.busy > 0 { parts.append("busy \(t.busy) (being updated — run again)") }
        if t.skipped > 0 { parts.append("skipped \(t.skipped)") }
        return parts.joined(separator: " · ")
    }

    /// "1,204 of 9,870 · x.mov · ~2 min left".
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

    /// Why a finished run is NOT the one-time completion (the marker is not
    /// written, the menu item stays): a failed or busy file; or a manifest
    /// with data rows of which none could be planned (codex r2 #3 — a
    /// parse that saw nothing must never claim every file is locked). nil =
    /// complete. Pure.
    nonisolated static func notCompleteReason(totals t: Totals, plan: Plan, summary: String) -> String? {
        if t.failed > 0 || t.busy > 0 { return summary }
        if plan.relPaths.isEmpty && plan.dataRows > 0 {
            return "\(summary) — the manifest lists \(plan.dataRows) row(s) but none could be planned; not marked complete (check the manifest by hand)"
        }
        return nil
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
        /// Media-bucket files to lock, manifest order, each once.
        let relPaths: [String]
        /// Rows skipped (malformed, or outside the media buckets) + why.
        let skipped: [(row: String, why: String)]
        /// Non-empty data lines the manifest held (header excluded).
        let dataRows: Int

        static func == (a: Plan, b: Plan) -> Bool {
            a.relPaths == b.relPaths && a.skipped.map(\.row) == b.skipped.map(\.row) && a.dataRows == b.dataRows
        }
    }

    /// Read the manifest through the validated descriptor, then plan.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadPlanOffMain(root: String) async -> Result<Plan, PlanRefusal> {
        do {
            let fd = try ArchivePromoteEngine.openIndexFile(root: root, name: MasterArchiveLayout.manifestFilename,
                                                            mustExist: true,
                                                            expectedHeaders: MasterArchiveLayout.acceptedManifestHeaders)
            defer { Darwin.close(fd) }
            let data = try ArchivePromoteEngine.readAll(fd: fd, limit: ArchiveIndexRename.readLimit + 1)
            guard data.count <= ArchiveIndexRename.readLimit, let text = String(bytes: data, encoding: .utf8) else {
                return .failure(PlanRefusal(reason: "the archive manifest is unreadable or larger than \(ArchiveIndexRename.readLimit >> 20) MB"))
            }
            return plan(manifestText: text, root: root)
        } catch {
            return .failure(PlanRefusal(reason: "the archive manifest could not be read (\(ArchiveAttestationJournal.describe(error)))"))
        }
    }

    /// Pure. Every data row is looked at: a short / malformed row is skipped
    /// and reported (its text is never used as a path); a whole row whose
    /// path escapes the root refuses the whole job; non-media rows are
    /// skipped and listed; duplicates are locked once.
    nonisolated static func plan(manifestText text: String, root: String) -> Result<Plan, PlanRefusal> {
        var seen = Set<String>()
        var media: [String] = []
        var skipped: [(row: String, why: String)] = []
        var dataRows = 0
        // CRLF is ONE Character in Swift (a grapheme cluster), so splitting
        // on "\n" alone never separates CRLF records (codex r2 #3) — split
        // on either terminator. (C++ analogy: iterating Characters is like
        // iterating grapheme clusters, not bytes.)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for (i, line) in lines.enumerated().dropFirst() {
            let raw = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if raw.isEmpty { continue }
            dataRows += 1
            let f = ArchiveManifestCSV.fields(ofLine: raw)
            guard f.count >= ArchiveManifestCSV.columnCountLegacy, !f[ArchiveManifestCSV.relPathColumn].isEmpty else {
                skipped.append(("manifest line \(i + 1)",
                                "not a whole manifest row (\(f.count) field(s)) — skipped, nothing touched; check the manifest by hand"))
                continue
            }
            let rel = f[ArchiveManifestCSV.relPathColumn]
            guard seen.insert(rel).inserted else { continue }
            guard ArchivePromoteEngine.isContainedRelPath(rel, root: root) else {
                return .failure(PlanRefusal(reason: "the archive manifest lists a path that is not a plain path inside the archive (\(rel)) — the manifest looks damaged; check it by hand"))
            }
            let bucket = (rel as NSString).pathComponents.first ?? ""
            if ArchiveRefileAuthorization.movableBuckets.contains(bucket) {
                media.append(rel)
            } else {
                skipped.append((rel, "not in a media bucket (10_Photos / 20_Audio / 30_Video / 50_Documents) — never locked"))
            }
        }
        return .success(Plan(relPaths: media, skipped: skipped, dataRows: dataRows))
    }

    /// One chunk of flag changes, off the main actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func applyChunkOffMain(root: String, relPaths: [String],
                                              seams: ArchiveFileLock.Seams) async -> [LockOutcome] {
        relPaths.map { lockOne(root: root, relPath: $0, seams: seams) }
    }

    enum LockOutcome: Equatable, Sendable {
        case result(ArchiveFileLock.Result)
        /// Update… (or another index writer) holds the index lock right now.
        case busy
    }

    /// ONE file, under the 00_Index lock (try-lock: busy → `.busy`, never a
    /// wait), the flag set through a path resolved NOW — not a descriptor
    /// opened before the lock. Synchronous, disk-bound — off the main actor.
    nonisolated static func lockOne(root: String, relPath: String, seams: ArchiveFileLock.Seams) -> LockOutcome {
        do {
            return try ArchiveIndexLock.withExclusive(root: root, holder: title, wait: .zero) {
                .result(ArchiveFileLock.set(.lock, root: root, relPath: relPath, reason: .lockAll, seams: seams,
                                            audit: { archiveLockLog.debug("\($0, privacy: .public)") }))
            }
        } catch is ArchiveIndexLock.Busy {
            return .busy
        } catch {
            return .result(.failed("the archive index could not be locked (\(ArchiveAttestationJournal.describe(error)))"))
        }
    }
}

// MARK: - Audit sink, the one-time marker, start

extension VideoScanModel {
    /// Console + catalog.log (`log`), videoscan.log, unified log — main actor.
    func archiveLockNote(_ line: String) {
        log(line)
        appLog.write("[archive-lock] " + line)
        archiveLockLog.notice("\(line, privacy: .public)")
    }

    /// The marker that hides the one-time menu item: beside the catalog
    /// (App Support in production; the sandbox's catalog folder in tests).
    var archiveLockCatchUpMarkerURL: URL {
        URL(fileURLWithPath: (catalogStore.fileLocation as NSString).deletingLastPathComponent, isDirectory: true)
            .appendingPathComponent("archive-lock-catchup.done")
    }

    /// True once the catch-up has completed cleanly (no failed, no busy file).
    var archiveLockCatchUpDone: Bool {
        FileManager.default.fileExists(atPath: archiveLockCatchUpMarkerURL.path)
    }

    func markArchiveLockCatchUpDone(summary: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(masterArchiveRootPath ?? "") — \(summary)\n"
        do {
            try Data(text.utf8).write(to: archiveLockCatchUpMarkerURL, options: .atomic)
            objectWillChange.send()
        } catch {
            archiveLockNote("\(ArchiveLockJob.title): completed, but the completion marker could not be written (\(error.localizedDescription)) — the menu item stays")
        }
    }
}

extension MediaFileOperationsCenter {
    /// Start the ONE catch-up pass. Refused (parked, nothing started) while
    /// another is active.
    @discardableResult
    func startArchiveLockCatchUp(model: VideoScanModel) -> ArchiveLockJob {
        let job = ArchiveLockJob(model: model)
        add(job)
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is ArchiveLockJob }) {
            job.refuseToStart(reason: "The lock pass is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "set the user-immutable flag on every archived file the manifest lists (one-time catch-up)"))
        return job
    }
}
