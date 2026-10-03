// AnalyzeRunner.swift
// "Run now" / Pause / Resume / Stop for every cycler, wired to the entry
// points that EXIST today (Phase A trial, 2026-10-02 — no engine changes):
//
//   Detect Duplicates     VideoScanModel.analyzeDuplicates(selectedIDs:)
//   Find Similar Footage  MediaFileOperationsCenter.startFindSimilarFootage
//                         (still an MFO job in Phase A — see the Phase C note
//                         in the design doc)
//   Scene Captions / OCR / Transcribe
//                         CaptionOrchestrator.enqueueAnalyze(volumePrefix:)
//                         / enqueueAnalyzeAll — the ONE dossier pipeline;
//                         pause() / resume() / cancel()
//   Correlate A/V         VideoScanModel.correlate() / correlateAcrossVolumes()
//                         / clearAndRecorrelateAll()
//   File Signatures       VideoScanModel.runContentHashBackfill(pathPrefix:)
//   Embedded Dates        VideoScanModel.runEmbeddedDateBackfill(pathPrefix:)
//   Date Inference        VideoScanModel.catchUpInferredDates(trigger:)
//
// LOGGING. Every Run now writes ONE START line through the existing sinks
// (model.log → console + catalog.log; appLog → videoscan.log) and, where
// the engine reports only through a status string (duplicates, correlate,
// date inference), ONE OUTCOME line echoing that string when the pass
// returns. The backfills and the MFO/dossier engines already write their
// own outcome lines; nothing is duplicated for them. No new log files.
//
// Used by the Analyze panel (all controls) and by the Catalog toolbar's
// Analyze menu (Update now rows) through ContentView.
//
// (For Rick: a `struct` of three references + methods ≈ a small C++ helper
// object holding pointers; `Task { await … }` ≈ fire-and-forget on the
// main actor's run loop, no thread of its own.)

import Foundation

@MainActor
struct AnalyzeRunner {
    let model: VideoScanModel
    /// nil in windows that have no orchestrator (tests); the dossier rows
    /// then refuse out loud.
    let orchestrator: CaptionOrchestrator?
    /// nil when Media File Operations is not available (tests, previews).
    let center: MediaFileOperationsCenter?

    // MARK: Run now

    /// `volume`: a scan-target root to scope the pass, or nil for "all
    /// reachable". `source`: who clicked ("panel", "menu", "storage card").
    func runNow(_ cycler: AnalyzeCycler, volume: String? = nil, source: String) {
        let scopeText = volume.map { VolumeReachability.displayLabel(forPath: $0) } ?? "all reachable"
        start(cycler, "START — \(scopeText) (\(source))")

        switch cycler {
        case .duplicates:
            // No volume scope in the engine today: a volume Run now passes
            // that volume's record ids — the existing "redo these" path,
            // which CLEARS and REDOES those records rather than the
            // incremental catalog-wide pass (noted in the Phase A report).
            let ids: Set<UUID>? = volume.map { root in
                Set(model.records.lazy.filter { VolumeDashboardCalculator.isUnder($0.fullPath, root: root) }.map(\.id))
            }
            Task { [model] in
                await model.analyzeDuplicates(selectedIDs: ids)
                outcome(cycler, model.duplicateStatus.isEmpty ? "finished" : model.duplicateStatus)
            }

        case .footage:
            guard let center else { return refuse(cycler, "Media File Operations is not available in this window") }
            let scope: FootageScope = volume.map {
                .volume(prefix: $0, label: VolumeReachability.displayLabel(forPath: $0))
            } ?? .catalog
            _ = center.startedByUser { $0.startFindSimilarFootage(scope: scope, model: model) }

        case .sceneCaptions, .ocr, .transcribe:
            guard let orchestrator else { return refuse(cycler, "the analysis pipeline is not available in this window") }
            if let volume {
                orchestrator.enqueueAnalyze(volumePrefix: volume, model: model)
            } else {
                // Every reachable volume with dossier work left — the same
                // choice the legacy dashboard's Analyze All makes.
                let report = model.analyzeCoverageSnapshot.report
                let remaining = report.byVolume[.sceneCaptions] ?? [:]
                let prefixes = CatalogScanTarget.analyzeCandidates(model.scanTargets)
                    .map(\.searchPath)
                    .filter { (remaining[VolumeDashboardCalculator.normalizedRoot($0)]?.remaining ?? 0) > 0 }
                if prefixes.isEmpty {
                    outcome(cycler, "nothing to do — every reachable volume is current")
                } else {
                    orchestrator.enqueueAnalyzeAll(volumePrefixes: prefixes, model: model)
                }
            }

        case .correlate:
            Task { [model] in
                await model.correlate()
                outcome(cycler, model.correlateStatus.isEmpty ? "finished" : model.correlateStatus)
            }

        case .fileSignatures:
            Task { [model] in
                let r = await model.runContentHashBackfill(pathPrefix: volume)
                outcome(cycler, "\(r.hashed) signed, \(r.failed) could not be read\(r.cancelled ? ", stopped early" : "")")
            }

        case .embeddedDates:
            Task { [model] in
                let r = await model.runEmbeddedDateBackfill(pathPrefix: volume)
                outcome(cycler, "\(r.dated) dated, \(r.noTag) with no tag, \(r.failed) could not be read")
            }

        case .dateInference:
            // Runs on the main actor today (bounded to 50k rows per pass);
            // moving it off-main is a Phase C item.
            let r = model.catchUpInferredDates(trigger: "analyze panel")
            outcome(cycler, "\(r.total) dated (\(r.examined) examined, \(r.cleared) cleared\(r.truncated ? ", more next pass" : ""))")
        }
    }

    // MARK: Correlate extras (the row's disclosure)

    func findPairsAcrossVolumes(source: String) {
        start(.correlate, "START — find A/V pairs across all volumes (\(source))")
        Task { [model] in
            await model.correlateAcrossVolumes()
            outcome(.correlate, model.correlateStatus.isEmpty ? "finished" : model.correlateStatus)
        }
    }

    /// The ONLY from-scratch redo; the caller confirms first.
    func clearAndRecorrelateAll(source: String) {
        start(.correlate, "START — clear ALL pairs and re-correlate from scratch (\(source))")
        Task { [model] in
            await model.clearAndRecorrelateAll()
            outcome(.correlate, model.correlateStatus.isEmpty ? "finished" : model.correlateStatus)
        }
    }

    // MARK: Pause / Resume / Stop (only where the engine has them)

    func pause(_ cycler: AnalyzeCycler) {
        switch cycler {
        case .sceneCaptions, .ocr, .transcribe:
            orchestrator?.pause()
        case .footage:
            activeFootageJob()?.pause()
        default:
            break   // not pausable today — the control is disabled
        }
        if cycler.isPausable { model.log("Analyze: \(cycler.title) — paused") }
    }

    func resume(_ cycler: AnalyzeCycler) {
        switch cycler {
        case .sceneCaptions, .ocr, .transcribe:
            guard let orchestrator else { return }
            if orchestrator.queuePaused { orchestrator.resumeQueue(model: model) }
            orchestrator.resume()
        case .footage:
            activeFootageJob()?.resume()
        default:
            break
        }
        if cycler.isPausable { model.log("Analyze: \(cycler.title) — resumed") }
    }

    func stop(_ cycler: AnalyzeCycler) {
        switch cycler {
        case .sceneCaptions, .ocr, .transcribe:
            orchestrator?.cancel()
        case .footage:
            activeFootageJob()?.cancel()
        default:
            break
        }
        if cycler.isPausable { model.log("Analyze: \(cycler.title) — stop requested") }
    }

    /// The newest active Find Similar Footage run, if any.
    func activeFootageJob() -> FindSimilarFootageJob? {
        center?.jobs.first { $0.state.isActive && $0 is FindSimilarFootageJob } as? FindSimilarFootageJob
    }

    // MARK: Log lines

    private func start(_ cycler: AnalyzeCycler, _ text: String) {
        let line = "Analyze: \(cycler.title) — \(text)"
        model.log(line)
        appLog.write(line)
    }

    private func outcome(_ cycler: AnalyzeCycler, _ text: String) {
        let line = "Analyze: \(cycler.title) — OUTCOME: \(text)"
        model.log(line)
        appLog.write(line)
    }

    private func refuse(_ cycler: AnalyzeCycler, _ why: String) {
        let line = "Analyze: \(cycler.title) — not started: \(why)"
        model.log(line)
        appLog.write(line)
    }
}
