// ArchiveAngelPromoter.swift
// Archive Angel — Stage 2 executor (docs/archive_angel_design.md §6).
//
// The review sheet IS the confirmation, so this goes straight from the
// reviewed plan to the existing Promote job (buildPromotePlan →
// startPromote) — never through `requestPromote`, which would present a
// second confirmation sheet. Before anything is enqueued every selected
// original is re-identified against the catalog and the disk (codex
// #1239 guardrail 1): a file that changed since preparation is refused
// row by row, never silently promoted. Buffer companions are deleted
// only after the Promote job reports the original AND every intended
// companion landed (guardrail 2); anything else keeps its buffer folder
// and its reason.

import Foundation
import Combine

@MainActor
final class ArchiveAngelPromoter: ObservableObject {

    /// The Promote job this promoter launched (nil until `promote` runs).
    @Published private(set) var job: PromoteToArchiveJob?
    private var watchers: [AnyCancellable] = []

    /// Promoters with a promote in flight, kept alive until they settle
    /// (audit #3): the view that made one can go away mid-promote — the
    /// Archive tab's list drops a batch the moment it reads `.promoting` —
    /// and settling must not go with it.
    private static var inFlight: [UUID: ArchiveAngelPromoter] = [:]

    // MARK: Pure rules

    /// "1994-11-24" → .day, "1994-11"/"November 1994" → .month, "1994" → .year,
    /// "1990s" → .decade; nil for empty or unparseable text (an unparseable
    /// string is NOT an override — same rule as the promote sheet).
    nonisolated static func dateHint(from raw: String?) -> ArchiveDateHint? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hint = ArchiveDateEntry.parse(trimmed)?.hint { return hint }
        // "1990-1999" — the decade folder's own spelling.
        let parts = trimmed.split(separator: "-").map(String.init)
        if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]),
           a % 10 == 0, b == a + 9, (1800...2200).contains(a) {
            return .decade(startYear: a)
        }
        return nil
    }

    /// Role label for a companion's naming row in the archive manifest.
    nonisolated static func roleLabel(for kind: ArchiveAngelPlan.StepKind) -> String? {
        switch kind {
        case .accessCopy: return "Access copy"
        case .losslessCopy: return "Lossless copy"
        case .balanceAudio: return "Balanced audio"
        case .verifyAudio: return nil
        }
    }

    /// The stem the archive filename should carry, or nil to keep the
    /// file's own stem. The extension is never part of the title.
    nonisolated static func archiveTitle(from proposedName: String) -> String? {
        let stem = (proposedName as NSString).deletingPathExtension
        return VideoScanModel.normalizedTitle(stem)
    }

    /// Identity re-check for one entry. nil = the original is exactly what
    /// was prepared; otherwise the precise refusal reason.
    static func identityProblem(for entry: ArchiveAngelPlan.Entry, model: VideoScanModel,
                                fileManager fm: FileManager = .default) -> String? {
        guard let rec = model.record(forID: entry.id) else {
            return "The catalog record is gone — was the file purged or the volume removed?"
        }
        if !VideoScanModel.samePath(rec.fullPath, entry.sourcePath) {
            // followRenames() runs first; reaching here means the file at
            // the record's new path is not the one that was prepared.
            return "The record now points at \(rec.fullPath) but that file is not the one prepared "
                + "(size or content hash differ) — discard the row or prepare again"
        }
        guard fm.fileExists(atPath: entry.sourcePath) else {
            return "Source file not found at \(entry.sourcePath)"
        }
        // attributesOfItem is lstat: a symlinked source (~/Movies → the
        // Projects volume after the 8/31 move) measured 62 bytes and was
        // refused as "size changed". Measure the file the link points at.
        let resolved = URL(fileURLWithPath: entry.sourcePath).resolvingSymlinksInPath().path
        let attrs = (try? fm.attributesOfItem(atPath: resolved)) ?? [:]
        let sizeNow = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        if sizeNow != entry.sizeBytes {
            return "Source size changed since preparation (\(entry.sizeBytes) → \(sizeNow) bytes)"
        }
        if rec.sizeBytes != entry.sizeBytes {
            return "Catalog size differs from the prepared size (\(entry.sizeBytes) vs \(rec.sizeBytes) bytes)"
        }
        if !entry.sourceContentHash.isEmpty, !rec.contentHash.isEmpty,
           entry.sourceContentHash != rec.contentHash {
            return "Content hash changed since preparation — the file was rewritten"
        }
        return nil
    }

    /// Companion outcomes that are intended for promotion: done, with a
    /// catalog record and a file still present in the buffer.
    static func promotableCompanions(of entry: ArchiveAngelPlan.Entry, in plan: ArchiveAngelPlan,
                                     fileManager fm: FileManager = .default) -> [ArchiveAngelPlan.StepOutcome] {
        entry.steps.filter { step in
            guard step.state == .done, step.recordID != nil, let rel = step.outputRelPath else { return false }
            let path = URL(fileURLWithPath: plan.batchDir).appendingPathComponent(rel).path
            return fm.fileExists(atPath: path)
        }
    }

    // MARK: Promote

    /// Re-check identities, build the promote plan, start the job. Mutates
    /// `plan` (refused rows → .failed with reason; status → .promoting)
    /// and saves it. Returns the job, or nil when nothing could start
    /// (no master archive, nothing selected) — the plan then says why.
    @discardableResult
    func promote(plan: inout ArchiveAngelPlan, model: VideoScanModel,
                 center: MediaFileOperationsCenter,
                 onFinished: @escaping @MainActor (ArchiveAngelPlan) -> Void) -> PromoteToArchiveJob? {
        guard model.masterArchiveRootPath != nil else {
            Self.note("Archive Angel: Promote refused — no Master Archive designated", plan: &plan, model: model)
            ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")
            return nil
        }
        var ids: [UUID] = []
        var titles: [UUID: String] = [:]
        var dates: [UUID: ArchiveDateHint] = [:]
        var roles: [UUID: String] = [:]
        var intended: [UUID: [UUID]] = [:]   // original → companion record ids

        // A catalog rename since preparation is followed, not refused
        // (Rick 2026-09-10); only a changed file is refused below.
        for line in Self.followRenames(plan: &plan, model: model) { model.log(line); appLog.write(line) }

        for i in plan.entries.indices where plan.entries[i].selected && plan.entries[i].status == .ready {
            let entry = plan.entries[i]
            if let problem = Self.identityProblem(for: entry, model: model) {
                plan.entries[i].status = .failed
                plan.entries[i].failure = problem
                Self.note("Archive Angel: refused \(entry.filename) — \(problem)", plan: &plan, model: model)
                continue
            }
            ids.append(entry.id)
            if let t = Self.archiveTitle(from: entry.proposedName) { titles[entry.id] = t }
            let hint = Self.dateHint(from: entry.proposedDate)
            if let hint { dates[entry.id] = hint }
            var companionIDs: [UUID] = []
            for step in Self.promotableCompanions(of: entry, in: plan) {
                guard let cid = step.recordID else { continue }
                ids.append(cid)
                companionIDs.append(cid)
                if let hint { dates[cid] = hint }
                if let t = titles[entry.id] { titles[cid] = t }
                if let role = Self.roleLabel(for: step.kind) { roles[cid] = role }
            }
            intended[entry.id] = companionIDs
        }

        guard !ids.isEmpty, var promotePlan = model.buildPromotePlan(recordIDs: ids) else {
            Self.note("Archive Angel: Promote — nothing to promote", plan: &plan, model: model)
            ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")
            return nil
        }
        promotePlan.archiveTitles = titles
        promotePlan.archiveDateOverrides = dates
        promotePlan.roleLabels = roles
        for skip in promotePlan.skipped {
            let reason = VideoScanModel.skipReasonLabel(skip.reason)
            if let i = plan.entries.firstIndex(where: { $0.id == skip.id }) {
                plan.entries[i].status = .failed
                plan.entries[i].failure = "Promote skipped it: \(reason)"
                Self.note("Archive Angel: \(skip.filename) — Promote skipped it: \(reason)", plan: &plan, model: model)
            } else {
                Self.note("Archive Angel: companion \(skip.filename) skipped by Promote — \(reason)", plan: &plan, model: model)
            }
        }

        plan.status = .promoting
        let originals = intended.count, companions = intended.values.reduce(0) { $0 + $1.count }
        let startLine = "Archive Angel: Promote started — \(originals) original(s) + \(companions) companion(s), "
            + "\(promotePlan.skipped.count) skipped by Promote, \(ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file)) to copy"
        Self.note(startLine, plan: &plan, model: model)
        ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")

        let job = center.startPromote(plan: promotePlan, model: model)
        job.ledgerActor = .angel   // Media Ledger: "archived … (Archive Angel)"
        self.job = job
        var snapshot = plan
        let planID = plan.id, liveDir = plan.batchDir
        ArchiveAngelLiveBatches.begin(liveDir)
        Self.inFlight[planID] = self
        watch(job) { [weak self] in
            guard let self, let job = self.job, !job.state.isActive else { return }
            self.watchers.removeAll()
            Self.settle(plan: &snapshot, job: job, intended: intended, model: model)
            ArchiveAngelLiveBatches.end(liveDir)
            Self.inFlight[planID] = nil
            onFinished(snapshot)
        }
        return job
    }

    /// Fold the Promote job's per-file outcomes back into the plan.
    static func settle(plan: inout ArchiveAngelPlan, job: PromoteToArchiveJob,
                       intended: [UUID: [UUID]], model: VideoScanModel) {
        // Keyed by RECORD, never filename (audit P0 #2, 2026-09-19): two
        // rows both named 00000.MTS used to take each other's outcome — a
        // failed one marked promoted with the other's path and its buffer
        // deleted — and same-named companions collided the same way.
        var landed: [UUID: String] = [:]      // record → relPath
        var problems: [UUID: String] = [:]    // record → reason
        for o in job.outcomes {
            guard let id = o.recordID else { continue }
            switch o.kind {
            case .promoted, .adopted: landed[id] = o.detail
            case .skipped, .failed: problems[id] = o.detail
            }
        }
        var report = plan.report ?? ArchiveAngelPlan.Report()
        for i in plan.entries.indices where plan.entries[i].status == .ready && plan.entries[i].selected {
            let entry = plan.entries[i]
            guard intended[entry.id] != nil else { continue }   // never enqueued
            guard let rel = landed[entry.id] else {
                let why = problems[entry.id] ?? Self.terminalReason(job)
                plan.entries[i].failure = "Original not promoted: \(why)"
                Self.note("Archive Angel: \(entry.filename) — original not promoted: \(why)", plan: &plan, model: model)
                report.failed.append(entry.filename)
                continue
            }
            var allCompanions = true
            var made = (access: 0, lossless: 0, balanced: 0)
            for step in entry.steps where step.state == .done && step.recordID != nil {
                guard let companionID = step.recordID else { continue }
                if landed[companionID] != nil {
                    switch step.kind {
                    case .accessCopy: made.access += 1
                    case .losslessCopy: made.lossless += 1
                    case .balanceAudio: made.balanced += 1
                    case .verifyAudio: break
                    }
                } else {
                    allCompanions = false
                    plan.entries[i].failure = "\(step.kind.label) not promoted: \(problems[companionID] ?? Self.terminalReason(job))"
                }
            }
            plan.entries[i].promotedRelPath = rel
            let landedLine = "Archive Angel: \(entry.filename) → \(rel)"
                + (allCompanions ? " with \(made.access + made.lossless + made.balanced) companion(s)" : " — " + (plan.entries[i].failure ?? "companion missing"))
            Self.note(landedLine, plan: &plan, model: model)
            if allCompanions {
                plan.entries[i].status = .promoted
                plan.entries[i].failure = nil
                report.promotedOriginals += 1
                report.accessCopies += made.access
                report.losslessCopies += made.lossless
                report.balancedAudio += made.balanced
                if entry.companionsMade.isEmpty { report.originalOnly.append(entry.filename) }
                ArchiveAngelPlanStore.removeEntryFolder(plan, entry: entry)
            } else {
                // Original landed, a companion did not: the row stays
                // reviewable with its buffer intact so a retry can finish.
                report.failed.append(entry.filename)
            }
        }
        // The user's own skips are part of the batch's story, kept apart
        // from `failed` (Rick 2026-09-13): "3 skipped", never "3 failed".
        let skipped = plan.entries.filter { $0.status == .skipped }.map(\.filename)
        report.skippedByUser = skipped.isEmpty ? nil : skipped
        plan.report = report
        plan.status = plan.readyCount == 0 ? .promoted : .ready
        plan.finishedAt = Date()
        Self.note("Archive Angel: " + report.summary, plan: &plan, model: model)
        ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")
    }

    /// Batches left `.promoting` that nothing in this app is promoting — a
    /// quit or crash mid-promote (audit #3). The Promote job writes the
    /// catalog itself, so the catalog is the truth: a row whose record is
    /// now archived is promoted (its buffer folder removed); the rest go
    /// back to ready, saying why, so Promote can be pressed again. Before
    /// this they stayed `.promoting` forever: hidden from the Archive tab,
    /// their rows reserved from every later batch, their gigabytes kept.
    @discardableResult
    static func settleStrandedPromotions(bufferRoot: URL, model: VideoScanModel) -> [String] {
        var lines: [String] = []
        for var plan in ArchiveAngelPlanStore.listBatches(bufferRoot: bufferRoot)
            where plan.status == .promoting && !ArchiveAngelLiveBatches.isLive(plan.batchDir) {
            var promoted = 0, back = 0
            for i in plan.entries.indices where plan.entries[i].status == .ready {
                let entry = plan.entries[i]
                if let rec = model.record(forID: entry.id), model.isArchived(rec) {
                    plan.entries[i].status = .promoted
                    plan.entries[i].failure = nil
                    ArchiveAngelPlanStore.removeEntryFolder(plan, entry: entry)
                    promoted += 1
                } else {
                    plan.entries[i].failure = "Promote was interrupted before this file reached the archive — promote again."
                    back += 1
                }
            }
            plan.status = plan.readyCount == 0 ? .promoted : .ready
            plan.finishedAt = plan.finishedAt ?? Date()
            let line = "Archive Angel: settled an interrupted promote in \((plan.batchDir as NSString).lastPathComponent) — "
                + "\(promoted) archived, \(back) back to ready"
            Self.note(line, plan: &plan, model: model)
            ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")
            lines.append(line)
        }
        return lines
    }

    /// The promoter's ONE log verb (audit P2, Rick 2026-09-19 "tests and
    /// LOGGING … for any actions"): the console, videoscan.log, and the
    /// batch's own plan log — never one without the others.
    static func note(_ line: String, plan: inout ArchiveAngelPlan, model: VideoScanModel) {
        model.log(line)
        appLog.write(line)
        plan.log.append(line)
    }

    private static func terminalReason(_ job: PromoteToArchiveJob) -> String {
        switch job.state {
        case .failed(let message): return message
        case .cancelled: return "promotion cancelled"
        case .cancelling: return "promotion cancelling"
        case .finished: return "no outcome recorded"
        case .running: return "still running"
        }
    }

    private func watch<J: MediaFileOperationJob>(_ job: J, onChange: @escaping @MainActor () -> Void) {
        watchers.removeAll()
        let c = job.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                onChange()
            }
        watchers.append(c)
        DispatchQueue.main.async(execute: onChange)   // may already be terminal (refused)
    }
}
