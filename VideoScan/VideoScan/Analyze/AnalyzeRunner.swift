// AnalyzeRunner.swift
// "Run now" / Pause / Resume / Stop for every cycler, wired to the entry
// points that EXIST today (Phase A trial, 2026-10-02 — no engine changes;
// the three integrity rows added 2026-10-16, Catalog Status §2):
//
//   File Presence         MediaFileOperationsCenter.startCatalogAudit
//   Integrity             MediaFileOperationsCenter.startValidateCatalog
//                         (files on disk, then the catalog — one job)
//   Full Hashes           MediaFileOperationsCenter.startFullHashBackfill
//   Sound Prints          MediaFileOperationsCenter.startAudioFingerprintBackfill
//                         — the three MFO jobs; pause / resume / cancel act
//                         on the job the center holds (the band mirrors it)
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
// Used by the Analyze panel (all controls), the Catalog toolbar's Analyze
// menu (Update now rows) through ContentView, and the Catalog Status
// band / update queue.
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
        guard engineIsFree(for: cycler) else { return }
        let scopeText = volume.map { VolumeReachability.displayLabel(forPath: $0) } ?? "all reachable"
        start(cycler, "START — \(scopeText) (\(source))")

        switch cycler {
        case .filePresence, .fullHashes, .soundPrints, .integrity:
            startIntegrityJob(cycler)

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
            startFootageJob(volume: volume)

        case .sceneCaptions, .ocr, .transcribe:
            guard let orchestrator else { return refuse(cycler, "the analysis pipeline is not available in this window") }
            if let volume {
                orchestrator.enqueueAnalyze(volumePrefix: volume, model: model)
            } else {
                // Every reachable volume, as the legacy dashboard's Analyze
                // All did; enqueueAnalyze's own guards skip a volume already
                // queued or running, and a volume with nothing left settles
                // as "nothing to do" (QA 2026-10-02: no coverage pre-filter
                // here — the three dossier rows share one queue).
                let prefixes = CatalogScanTarget.analyzeCandidates(model.scanTargets).map(\.searchPath)
                if prefixes.isEmpty {
                    outcome(cycler, "nothing to do — no reachable volume")
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

    /// Find Similar Footage — still an MFO job in Phase A; a volume scopes it.
    private func startFootageJob(volume: String?) {
        guard let center else { return refuse(.footage, "Media File Operations is not available in this window") }
        let scope: FootageScope = volume.map {
            .volume(prefix: $0, label: VolumeReachability.displayLabel(forPath: $0))
        } ?? .catalog
        _ = center.startedByUser { $0.startFindSimilarFootage(scope: scope, model: model) }
    }

    /// The three integrity jobs — the SAME starts the Catalog menu items
    /// use, with the model-owned run markers, through `startedByUser` so
    /// the MFO window comes forward. The center refuses a second run of
    /// the same kind on its own (nothing is started twice).
    private func startIntegrityJob(_ cycler: AnalyzeCycler) {
        guard let center else { return refuse(cycler, "Media File Operations is not available in this window") }
        center.startedByUser { c in
            switch cycler {
            case .filePresence:
                _ = c.startCatalogAudit(model: model, marker: model.catalogAuditRunMarker)
            case .fullHashes:
                _ = c.startFullHashBackfill(model: model, marker: model.fullHashResumeMarker)
            case .soundPrints:
                _ = c.startAudioFingerprintBackfill(model: model)
            case .integrity:
                // Validate Catalog (Rick 2026-10-20, one verb): the files on
                // disk first, then the catalog — never Verify on its own,
                // which would grade the catalog against an old disk picture.
                _ = c.startValidateCatalog(model: model, marker: model.catalogAuditRunMarker)
            default:
                break
            }
        }
    }

    // MARK: Correlate extras (the row's disclosure)

    func findPairsAcrossVolumes(source: String) {
        guard engineIsFree(for: .correlate) else { return }
        start(.correlate, "START — find A/V pairs across all volumes (\(source))")
        Task { [model] in
            await model.correlateAcrossVolumes()
            outcome(.correlate, model.correlateStatus.isEmpty ? "finished" : model.correlateStatus)
        }
    }

    /// The ONLY from-scratch redo; the caller confirms first.
    func clearAndRecorrelateAll(source: String) {
        guard engineIsFree(for: .correlate) else { return }
        start(.correlate, "START — clear ALL pairs and re-correlate from scratch (\(source))")
        Task { [model] in
            await model.clearAndRecorrelateAll()
            outcome(.correlate, model.correlateStatus.isEmpty ? "finished" : model.correlateStatus)
        }
    }

    // MARK: Engine gates (QA on the Phase A branch, 2026-10-02)

    /// analyzeDuplicates() and correlate() have NO reentrancy guard of their
    /// own (the two backfills do): a second pass started from another
    /// surface would run concurrently and its `defer` would clear the first
    /// pass's flag. Refuse — out loud — while the engine is busy, and while
    /// a scan runs (both old toolbar menus were disabled during a scan).
    /// The other engines guard themselves (backfills, the integrity jobs
    /// through the center) or queue (dossier, footage). False = refused
    /// and logged.
    func engineIsFree(for cycler: AnalyzeCycler) -> Bool {
        switch cycler {
        case .duplicates:
            if model.isAnalyzingDuplicates { refuse(cycler, "already running"); return false }
            if model.isScanning { refuse(cycler, "a scan is running — try again when it finishes"); return false }
        case .correlate:
            if model.isCorrelating { refuse(cycler, "already running"); return false }
            if model.isScanning { refuse(cycler, "a scan is running — try again when it finishes"); return false }
        case .filePresence, .fullHashes, .soundPrints, .integrity:
            if activeIntegrityJob(for: cycler) != nil { refuse(cycler, "already running"); return false }
        default:
            break
        }
        return true
    }

    // MARK: Is it running? (the queue's and the band's question)

    /// Whether a pass of this kind is in flight right now — the same
    /// engine flags the panel samples on its tick, in one place.
    func isRunning(_ cycler: AnalyzeCycler) -> Bool {
        switch cycler {
        case .filePresence, .fullHashes, .soundPrints, .integrity:
            return activeIntegrityJob(for: cycler) != nil
        case .duplicates:
            return model.isAnalyzingDuplicates
        case .footage:
            return activeFootageJob() != nil
        case .sceneCaptions, .ocr, .transcribe:
            return orchestrator?.dashboardSnapshot.state.statusIsActive ?? false
        case .correlate:
            return model.isCorrelating
        case .fileSignatures:
            return model.isComputingSignatures
        case .embeddedDates:
            return model.isRefreshingEmbeddedDates
        case .dateInference:
            return false   // synchronous on the main actor; never "running" between frames
        }
    }

    // MARK: Pause / Resume / Stop (only where the engine has them)

    func pause(_ cycler: AnalyzeCycler) {
        switch cycler {
        case .filePresence, .fullHashes, .soundPrints, .integrity:
            activeIntegrityJob(for: cycler)?.pause()
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
        case .filePresence, .fullHashes, .soundPrints, .integrity:
            activeIntegrityJob(for: cycler)?.resume()
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
        case .filePresence, .fullHashes, .soundPrints, .integrity:
            activeIntegrityJob(for: cycler)?.cancel()
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

    /// The active MFO job behind an integrity row, if any — the object the
    /// MFO row observes, so the band can observe the same one. O(jobs).
    func activeIntegrityJob(for cycler: AnalyzeCycler) -> (any MediaFileOperationJob)? {
        guard let center else { return nil }
        return center.jobs.first { job in
            guard job.state.isActive else { return false }
            switch cycler {
            // Validate Catalog runs the file check AND the catalog check, so
            // it is the job behind both rows while it runs.
            case .filePresence: return job is CatalogAuditJob || job is ValidateCatalogJob
            case .fullHashes: return job is FullHashBackfillJob
            case .soundPrints: return job is AudioFingerprintBackfillJob
            case .integrity: return job is VerifyCatalogJob || job is ValidateCatalogJob
            default: return false
            }
        }
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
