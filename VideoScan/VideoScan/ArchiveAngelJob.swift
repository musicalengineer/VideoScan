// ArchiveAngelJob.swift
// Archive Angel — Stage 1 as an MFO job (docs/archive_angel_design.md §3–§5).
//
// Consider N candidates → prepare each one's companions in the buffer →
// stop for review. The plan (`plan.json` in the batch folder) is saved
// after every step, so a quit or crash leaves a recoverable batch.
//
// Guardrails (codex #1239 / my #1240):
//   • identity is captured per entry (contentHash / size / mtime) for
//     Promote's re-check;
//   • a companion counts as DONE only when its sub-job finished AND the
//     file exists with size > 0 — partial outputs are never counted;
//   • cancel stops the current sub-job and leaves what was prepared
//     as `.ready`, the rest `.pending`, plan status `.preparing`.
//
// Originals are never copied here. Every media-writing step is an
// existing job (Verify Audio, Balance Audio, Transcode) launched through
// the Center with the buffer as its output — nothing new touches ffmpeg.

import Combine
import Foundation
import OSLog
import VideoScanCore

private let angelLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

@MainActor
final class ArchiveAngelJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .archiveAngel
    let startedAt = Date()

    weak var model: VideoScanModel?
    weak var center: MediaFileOperationsCenter?

    let bufferRoot: URL
    let requestedCount: Int
    let makeLossless: Bool

    /// The batch plan — rewritten (and saved) after every step.
    @Published private(set) var plan: ArchiveAngelPlan

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Walking the catalog…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    private(set) var wasRefused = false

    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// The Verify / Balance / Transcode job currently running for an
    /// entry — cancelled together with this job.
    private var currentSubJob: (any MediaFileOperationJob)?

    var title: String { "Archive Angel — consider \(requestedCount)" }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    init(model: VideoScanModel, center: MediaFileOperationsCenter,
         count: Int, makeLossless: Bool, bufferRoot: URL) {
        self.model = model
        self.center = center
        self.requestedCount = max(1, count)
        self.makeLossless = makeLossless
        self.bufferRoot = bufferRoot
        let dir = ArchiveAngelPlanStore.newBatchDir(bufferRoot: bufferRoot)
        self.plan = ArchiveAngelPlan(batchDir: dir, requestedCount: max(1, count), makeLossless: makeLossless)
    }

    // MARK: Lifecycle

    /// Why this job must not start (nil = go). Mirrors Promote's gates.
    func preflight(model: VideoScanModel) -> String? {
        if model.isReadOnly {
            return "This catalog is open read-only — Archive Angel cannot prepare files here."
        }
        if model.masterArchive == nil {
            return "No Master Archive is designated yet — initialize one first (Archive tab)."
        }
        return nil
    }

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
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
        subtitleText = "Cancelling — prepared candidates stay reviewable…"
        currentSubJob?.cancel()
        task?.cancel()
    }

    private var stopRequested: Bool { state.cancelWasRequested || Task.isCancelled }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "Catalog went away."); return }

        // ── Stage 1a: pick from FRESH evidence (phase 2 sweep) or walk.
        let policy = model.duplicateKeeperPolicy()
        note("Archive Angel: want \(requestedCount), lossless \(makeLossless ? "on" : "off"), buffer \(plan.batchDir)")
        let selection: ArchiveAngelSelection
        let consideredCount: Int
        // Rows already in another batch (preparing / ready / promoting) are
        // not picked again — a second "10" brings the NEXT ten.
        let root = bufferRoot
        let inFlight = await Task.detached(priority: .utility) {
            ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root)
        }.value
        if !inFlight.isEmpty { note("Archive Angel: \(inFlight.count) record(s) already in a prepared batch — skipping them") }
        if let fromEvidence = Self.selectFromEvidence(
            store: model.archiveAngelStore, count: requestedCount, now: Date(), excluding: inFlight,
            project: { id in model.record(forID: id).map { ArchiveAngelCandidate.project($0, model: model, policy: policy) } }) {
            selection = fromEvidence.selection
            consideredCount = model.archiveAngelStore.consideredCount
            let age = max(0, Int(Date().timeIntervalSince(fromEvidence.computedAt) / 60))
            note("Archive Angel: picked from evidence computed \(age) min ago")
        } else {
            // The walk (main actor, in the job's task — never a view body).
            let active = pfActiveRecords(model.records)
            note("Archive Angel: assessing \(active.count) records")
            var candidates: [ArchiveAngelCandidate] = []
            candidates.reserveCapacity(active.count)
            for (i, r) in active.enumerated() {
                candidates.append(ArchiveAngelCandidate.project(r, model: model, policy: policy))
                // O(records) on the main actor: yield every 500 so the UI keeps
                // painting on an 18k-record catalog (no beachball, GH #104 class).
                if i % 500 == 499 {
                    subtitleText = "Considering \(i + 1) of \(active.count) records…"
                    await Task.yield()
                    if stopRequested { finishCancelled(); return }
                }
            }
            if stopRequested { finishCancelled(); return }
            ArchiveAngelScorer.markDerivatives(&candidates)   // T10 H3: same rule as the sweep

            // Spotlight play history for the eligible ones only, off-main.
            let eligiblePaths = candidates.filter { ArchiveAngelScorer.hardFloor($0) == nil }.map(\.fullPath)
            subtitleText = "Reading play history for \(eligiblePaths.count) eligible files…"
            let readings = await Self.readPlayHistoryOffMain(paths: eligiblePaths)
            for i in candidates.indices {
                if let r = readings[candidates[i].fullPath] {
                    candidates[i].useCount = r.useCount
                    candidates[i].lastUsed = r.lastUsed
                }
            }
            if stopRequested { finishCancelled(); return }
            let skipped = candidates.filter { inFlight.contains($0.id) }.count
            var walked = ArchiveAngelScorer.select(candidates.filter { !inFlight.contains($0.id) }, count: requestedCount)
            if skipped > 0 { walked.rejected[.inAnotherBatch, default: 0] += skipped }
            selection = walked
            consideredCount = candidates.count
        }
        plan.consideredCount = consideredCount
        plan.rejected = Dictionary(uniqueKeysWithValues: selection.rejected.map { ($0.key.rawValue, $0.value) })
        plan.overflow = selection.overflow

        // ── Plan entries.
        var entries: [ArchiveAngelPlan.Entry] = []
        for pick in selection.picks {
            guard let rec = model.record(forID: pick.candidate.id) else { continue }
            let facts = ArchivePathResolver.facts(for: rec)
            let people = rec.confirmedByUserPeople.map(\.name) + rec.detectedPeople
            entries.append(.init(
                id: rec.id,
                sourcePath: rec.fullPath,
                filename: rec.filename,
                sizeBytes: rec.sizeBytes,
                sourceContentHash: rec.contentHash,
                sourceModifiedAt: rec.dateModifiedRaw,
                durationSeconds: rec.durationSeconds,
                score: pick.score,
                evidence: pick.evidence,
                proposedName: ArchiveAngelNaming.proposedName(facts: facts, people: people, tags: rec.tags),
                proposedDate: ArchiveAngelNaming.proposedDate(fromFilenamePrefix: facts.dateHint.filenamePrefix)))
        }
        plan.entries = entries
        plan.startedAt = Date()
        for (n, pick) in selection.picks.enumerated() {
            let why = pick.evidence.prefix(3).map(\.line).joined(separator: " · ")
            note("Archive Angel pick \(n + 1)/\(entries.count) [\(pick.score)] \(pick.candidate.filename) — \(why)")
        }
        let walkLine = "Archive Angel: considered \(consideredCount), \(entries.count) picked, "
            + "\(selection.rejectedTotal) rejected, \(selection.overflow) more would qualify"
        model.log(walkLine)
        plan.log.append(walkLine)
        angelLog.info("\(walkLine, privacy: .public)")

        if entries.isEmpty {
            plan.status = .ready
            plan.finishedAt = Date()
            _ = await savePlan()
            finish(success: "Nothing to recommend — " + topRejections(selection.rejected))
            return
        }
        guard await savePlan() else { return }

        // ── Stage 1b: preparation, one entry at a time.
        isIndeterminateValue = false
        let total = plan.entries.count
        for idx in plan.entries.indices {
            if stopRequested { break }
            if plan.entries[idx].status == .ready { continue }   // resumed batch
            let entry = plan.entries[idx]

            // Free-space precheck (design §5): a stopped batch is still reviewable.
            let need = entry.sizeBytes * (makeLossless ? 3 : 2)
            let free = await Self.freeBytesOffMain(at: bufferRoot)
            if free < need {
                let line = "Archive Angel: buffer full after \(idx) of \(total) "
                    + "(\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free, "
                    + "need \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)))"
                model.log(line); plan.log.append(line)
                break
            }

            guard let rec = model.record(forID: entry.id),
                  await Self.fileExistsOffMain(entry.sourcePath) else {
                plan.entries[idx].status = .failed
                plan.entries[idx].failure = "Source file is missing — cannot promote."
                _ = await savePlan()
                continue
            }
            plan.entries[idx].status = .preparing
            _ = await savePlan()
            note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — preparing (\(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)), score \(entry.score))")

            let entryDir = URL(fileURLWithPath: plan.batchDir).appendingPathComponent(entry.id.uuidString, isDirectory: true)
            await Self.ensureDirectoryOffMain(entryDir)

            await prepare(index: idx, record: rec, entryDir: entryDir, position: idx + 1, total: total)
            if stopRequested { break }

            plan.entries[idx].status = .ready
            let made = plan.entries[idx].companionsMade.map { $0.kind.label.lowercased() }
            note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — ready to review"
                 + (made.isEmpty ? " (original only)" : " with " + made.joined(separator: ", ")))
            fractionValue = Double(idx + 1) / Double(total)
            _ = await savePlan()
        }

        if stopRequested { _ = await savePlan(); finishCancelled(); return }

        plan.status = .ready
        plan.finishedAt = Date()
        _ = await savePlan()
        let ready = plan.readyCount
        let summary = "\(ready) ready to review · \(plan.rejectedTotal) rejected · \(plan.overflow) more would qualify"
        model.log("Archive Angel: " + summary)
        finish(success: summary)
    }

    // MARK: Preparation of one entry

    private func prepare(index idx: Int, record rec: VideoRecord, entryDir: URL, position: Int, total: Int) async {
        guard let model, let center else { return }
        let stem = (rec.filename as NSString).deletingPathExtension
        func progress(_ step: String, _ n: Int) {
            subtitleText = "\(position) of \(total) — \(rec.filename): \(step)"
            fractionValue = (Double(position - 1) + Double(n) / 4.0) / Double(total)
        }

        // a. Verify audio
        progress("verifying audio", 0)
        var diagnosis: AudioVerifyDiagnosis?
        if rec.streamType == .videoOnly {
            step(idx, .verifyAudio, .skipped, note: "No audio track")
        } else if !rec.audioVerifyStatus.isEmpty {
            step(idx, .verifyAudio, .skipped, note: "Already verified: \(rec.audioVerifyStatus)")
            diagnosis = center.verifyDiagnosis(forRecordID: rec.id)
        } else if let vj = center.startVerifyAudio(record: rec, model: model) {
            currentSubJob = vj
            await vj.task?.value
            currentSubJob = nil
            if let d = vj.diagnosis {
                diagnosis = d
                step(idx, .verifyAudio, .done, note: HelperAudioOutcome.from(d).headline)
            } else if case .failed(let m) = vj.state {
                step(idx, .verifyAudio, .failed, note: m)
            } else {
                step(idx, .verifyAudio, .skipped, note: "Verify did not finish")
            }
        } else {
            step(idx, .verifyAudio, .skipped, note: "A verify job for this file is already running")
        }
        _ = await savePlan()
        if stopRequested { return }

        // b. Balanced audio — only on a fixable problem.
        progress("balancing audio", 1)
        var balancedRecord: VideoRecord?
        if let d = diagnosis, let analysis = d.balanceAnalysis {
            if let reason = BalanceAudioFix.refusalReason(for: analysis) {
                step(idx, .balanceAudio, .skipped, note: reason)
            } else {
                let ext = BalanceAudioFix.balancedOutputURL(forSourcePath: rec.fullPath,
                                                            containerFormat: analysis.shape.containerFormat,
                                                            fileExists: { _ in false }).pathExtension
                let planned = entryDir.appendingPathComponent("\(stem)_balanced.\(ext)")
                await Self.removeIfPresentOffMain(planned)
                if let bj = center.startBalanceAudio(record: rec, fromDiagnosis: d, model: model, plannedOutput: planned) {
                    currentSubJob = bj
                    await bj.task?.value
                    currentSubJob = nil
                    if case .finished = bj.state, let out = bj.publishedURL,
                       await Self.fileSizeOffMain(out) > 0 {
                        let companion = model.records.first { $0.fullPath == out.path }
                        balancedRecord = companion
                        step(idx, .balanceAudio, .done, note: "Audio balanced (\(analysis.classification.rawValue))",
                                              output: Self.relPath(out, in: plan.batchDir))
                        if let i = plan.entries[idx].steps.firstIndex(where: { $0.kind == .balanceAudio }) {
                            plan.entries[idx].steps[i].recordID = companion?.id
                        }
                    } else if case .failed(let m) = bj.state {
                        step(idx, .balanceAudio, .failed, note: "Balance failed: \(m)")
                    } else {
                        step(idx, .balanceAudio, .failed, note: "Balance did not finish")
                    }
                } else {
                    step(idx, .balanceAudio, .skipped, note: "A balance job for this file is already running")
                }
            }
        } else if rec.streamType == .videoOnly {
            step(idx, .balanceAudio, .skipped, note: "No audio track")
        } else {
            step(idx, .balanceAudio, .skipped, note: "Audio OK — nothing to fix")
        }
        _ = await savePlan()
        if stopRequested { return }

        // c. Access copy — always; from the balanced companion when there is one.
        progress("access copy", 2)
        let accessSource = balancedRecord ?? rec
        let accessOut = entryDir.appendingPathComponent("\(stem).vs.archive.mov")
        await Self.removeIfPresentOffMain(accessOut)
        await runTranscode(index: idx, kind: .accessCopy, record: accessSource, preset: .archival,
                           outputURL: accessOut, model: model, center: center,
                           doneNote: balancedRecord == nil ? "HEVC access copy" : "HEVC access copy (from balanced audio)")
        _ = await savePlan()
        if stopRequested { return }

        // d. Lossless — only when enabled AND the format is at risk.
        progress("lossless copy", 3)
        let readiness = ArchiveReadiness.assess(record: rec)
        if !makeLossless {
            step(idx, .losslessCopy, .skipped, note: "Lossless off (alpha default)")
        } else if case .atRisk = readiness.format {
            let out = entryDir.appendingPathComponent("\(stem).vs.preserve.mkv")
            await Self.removeIfPresentOffMain(out)
            await runTranscode(index: idx, kind: .losslessCopy, record: rec, preset: .preservation,
                               outputURL: out, model: model, center: center, doneNote: "FFV1 preservation copy")
        } else {
            let codec = rec.videoCodec.isEmpty ? "the" : rec.videoCodec
            step(idx, .losslessCopy, .skipped, note: "Lossless copy not needed — \(codec) original is the preservation master")
        }
        _ = await savePlan()
    }

    private func runTranscode(index idx: Int, kind: ArchiveAngelPlan.StepKind, record: VideoRecord,
                              preset: TranscodePreset, outputURL: URL,
                              model: VideoScanModel, center: MediaFileOperationsCenter,
                              doneNote: String) async {
        let startedAt = Date()
        note("Archive Angel [\(idx + 1)/\(plan.entries.count)] \(plan.entries[idx].filename) — "
             + "\(kind.label.lowercased()): starting \(preset.rawValue) → \(outputURL.lastPathComponent)")
        let tj = center.startTranscode(record: record, preset: preset, outputURL: outputURL, model: model)
        currentSubJob = tj
        await tj.task?.value
        currentSubJob = nil
        let outBytes = await Self.fileSizeOffMain(tj.outputURL)
        if case .finished = tj.state, outBytes > 0 {
            let companion = model.records.first { $0.fullPath == tj.outputURL.path }
            step(idx, kind, .done, note: doneNote, output: Self.relPath(tj.outputURL, in: plan.batchDir),
                 startedAt: startedAt, outputBytes: outBytes)
            if let i = plan.entries[idx].steps.firstIndex(where: { $0.kind == kind }) {
                plan.entries[idx].steps[i].recordID = companion?.id
            }
        } else if case .failed(let m) = tj.state {
            step(idx, kind, .failed, note: "\(kind.label) failed: \(m) — original will still be promoted")
        } else if stopRequested {
            step(idx, kind, .failed, note: "\(kind.label) cancelled")
        } else {
            step(idx, kind, .failed, note: "\(kind.label) did not finish — original will still be promoted")
        }
    }

    // MARK: Logging (Rick 2026-09-09: "good logging around archival steps")
    //
    // Every step outcome goes to FOUR places: the app console (model.log),
    // the file log (appLog), OSLog category "archiveAngel", and plan.log so
    // the batch folder tells its own story. Format:
    //   Archive Angel [3/25] 1993_CapeCod.mov — access copy: done — HEVC access copy (41.2 s, 812 MB)

    private func note(_ line: String) {
        model?.log(line)
        appLog.write(line)
        angelLog.info("\(line, privacy: .public)")
        plan.log.append(line)
    }

    private func step(_ idx: Int, _ kind: ArchiveAngelPlan.StepKind, _ state: ArchiveAngelPlan.StepState,
                      note text: String, output: String? = nil, startedAt: Date? = nil, outputBytes: Int64 = 0) {
        plan.entries[idx].set(kind, state, note: text, output: output)   // step-helper
        var extra: [String] = []
        if let startedAt { extra.append(String(format: "%.1f s", Date().timeIntervalSince(startedAt))) }
        if outputBytes > 0 { extra.append(ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)) }
        let tail = extra.isEmpty ? "" : " (" + extra.joined(separator: ", ") + ")"
        note("Archive Angel [\(idx + 1)/\(plan.entries.count)] \(plan.entries[idx].filename) — "
             + "\(kind.label.lowercased()): \(state.rawValue) — \(text)\(tail)")
    }

    // MARK: Plan persistence

    /// Save the plan; on failure the job fails (a batch nobody can review
    /// is not a batch). Returns false when it failed.
    private func savePlan() async -> Bool {
        do {
            try await Self.savePlanOffMain(plan)
            return true
        } catch {
            finish(failed: "Could not write plan.json in \(plan.batchDir): \(error.localizedDescription)")
            return false
        }
    }

    private func topRejections(_ rejected: [ArchiveAngelRejection: Int]) -> String {
        let top = rejected.sorted { $0.value > $1.value }.prefix(3)
        if top.isEmpty { return "no unarchived videos found" }
        return top.map { "\($0.value) \($0.key.rawValue.lowercased())" }.joined(separator: ", ")
    }

    private static func relPath(_ url: URL, in batchDir: String) -> String {
        let base = URL(fileURLWithPath: batchDir, isDirectory: true).standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    // MARK: Finish

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        angelLog.warning("archive angel failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        state = .cancelled
        subtitleText = "Cancelled — \(plan.readyCount) prepared candidates stay reviewable"
        isIndeterminateValue = false
    }

    // MARK: Off-main hops
    //
    // `@concurrent`: a bare `nonisolated async` runs on the CALLER's actor
    // (the trap that has bitten this repo 3×).

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func readPlayHistoryOffMain(paths: [String]) async -> [String: ArchiveAngelPlayHistory.Reading] {
        var out: [String: ArchiveAngelPlayHistory.Reading] = [:]
        out.reserveCapacity(paths.count)
        for p in paths {
            if Task.isCancelled { break }
            let r = ArchiveAngelPlayHistory.reading(forPath: p)
            if r.useCount > 0 || r.lastUsed != nil { out[p] = r }
        }
        return out
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func savePlanOffMain(_ plan: ArchiveAngelPlan) async throws {
        try ArchiveAngelPlanStore.save(plan)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func freeBytesOffMain(at url: URL) async -> Int64 {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ArchiveAngelPlanStore.freeBytes(at: url)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func ensureDirectoryOffMain(_ url: URL) async {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func removeIfPresentOffMain(_ url: URL) async {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fileExistsOffMain(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fileSizeOffMain(_ url: URL) async -> Int64 {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
