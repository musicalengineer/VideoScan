// ArchiveAngel.swift
// The Archive Angel's ONE front door (docs/archive_angel_consolidation_plan.md,
// "Target architecture"). The rest of the app talks to `model.archiveAngel`
// and to the few public views (ArchiveAngelStrip, ArchiveAngelMenuItems,
// ArchiveAngelCatalogBadgeView, ArchiveAngelJobDetailView); everything else
// under ArchiveAngel/ is the module's inside. ArchiveAngelBoundarySensorTests
// fails when app code reaches past this surface.
//
// S2 (2026-09-22): the façade OWNS the Angel's state — the evidence store,
// the background sweep, the attention memory, the settings, the prepared
// batches the Archive tab shows (moved here from ArchiveView), and the
// recommendation policy — and reaches the app only through the seams in
// Seams/AngelSeams.swift. Behaviour is unchanged (S0's characterization
// tests pin it).
//
// LOGGING: every action entry point writes a START line and a result line
// to the unified log (subsystem Rick-Breen.VideoScan, category
// "archiveAngel"); the ones a person triggers (Prepare, Assess Now, Assess
// Continuously) also go to the console + videoscan.log. O(1) reads and the
// debounced signals (catalogChanged, noteAttention) are deliberately NOT
// logged — they run on every records change / ledger append.
//
// (For Rick: think of this as the module's public header plus its owning
// object — one instance per catalog model, created lazily by the model.)

import Combine
import Foundation
import OSLog

private let facadeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

@MainActor
final class ArchiveAngel: ObservableObject {

    /// What the catalog shows for a record (grade, score, why-lines, floor).
    typealias Evidence = ArchiveAngelEvidenceRecord
    /// The catalog row's "Promote me" / "Worth a look" chip.
    typealias Badge = ArchiveAngelCatalogBadge

    /// The prepared batches the Archive tab shows. Read from the buffer
    /// OUTSIDE any view body (disk I/O), by `refreshBatches`.
    struct Batches: Equatable {
        /// `.ready` batches with at least one ready row, newest first.
        var ready: [ArchiveAngelPlan] = []
        /// Batch folders whose plan can't be read (audit #7) — listed, never touched.
        var unreadable: [ArchiveAngelPlanStore.UnreadableBatch] = []
        /// Buffer hygiene (curation Phase 2, 2026-09-19): what is waiting in
        /// the buffer and what finished batches still hold.
        var hygiene: ArchiveAngelBufferHygiene.Report = .empty
    }

    // MARK: State (owned)

    let environment: AngelEnvironment
    /// Archive Angel phase 2 (2026-09-09): the evidence sidecar.
    let store: ArchiveAngelEvidenceStore
    /// The background scoring sweep over the evidence store.
    let sweep: ArchiveAngelSweep
    /// Phase 1 attention memory — derived from the Media Ledger's
    /// angelProposed / angelSkipped / angelCleared lines.
    let attention: ArchiveAngelAttentionStore
    /// The recommendation rules (built-in, bundled default, or Rick's
    /// policy.json). Read once when the façade is made.
    let policy: AngelRecommendationPolicy
    let policySource: AngelRecommendationPolicy.Source
    /// Lines the policy load wants a person to see (a refused override…),
    /// written at `launch()` once the console exists.
    private var policyNotices: [String]

    /// "Assess Continuously" — ON by default (scoring reads catalog fields
    /// + Spotlight, never media). A test host starts from the pristine ON
    /// default and never reads Rick's preference.
    @Published private(set) var sweepEnabled: Bool
    @Published private(set) var batches = Batches()
    /// Refreshes are stamped when requested; a scan publishes only if it
    /// is newer than what is on screen (codex review 2026-09-20 #9).
    private var refreshGeneration = 0

    // MARK: Seams (non-owning)

    /// The composition root. VideoScanModel conforms to AngelCatalog,
    /// AngelNavigator, AngelArchive and AngelLedger (AppConformances.swift);
    /// the concrete type is kept only because the core job still takes it
    /// (S6). `weak` ≈ a non-owning pointer that nils itself — the model
    /// owns this façade, never the other way round.
    private weak var model: VideoScanModel?
    /// The MFO center, attached by VideoScanApp once it exists. nil = no
    /// job can be running (the pre-S2 default closure answered "not busy").
    private weak var jobRunner: (any AngelJobRunner)?

    var catalog: (any AngelCatalog)? { model }
    var navigator: (any AngelNavigator)? { model }
    var archive: (any AngelArchive)? { model }
    var ledger: (any AngelLedger)? { model }

    init(model: VideoScanModel, environment: AngelEnvironment = .app) {
        self.model = model
        self.environment = environment
        let store = ArchiveAngelEvidenceStore(directory: environment.evidenceDirectory)
        self.store = store
        self.sweep = ArchiveAngelSweep(store: store)
        self.attention = ArchiveAngelAttentionStore()
        self.sweepEnabled = environment.isTestHost
            ? ArchiveAngelSettings().sweepEnabled
            : ArchiveAngelSettings.restored(from: environment.defaults).sweepEnabled
        let loaded = AngelRecommendationPolicy.load(overrideURL: environment.policyOverrideURL,
                                                    bundledURL: environment.bundledPolicyURL)
        self.policy = loaded.policy
        self.policySource = loaded.source
        self.policyNotices = loaded.notices
        facadeLog.info("recommendation policy: \(loaded.source.rawValue, privacy: .public) “\(loaded.policy.name, privacy: .public)” schema \(loaded.policy.schemaVersion)")
    }

    // MARK: Lifecycle

    /// Called once from the model's init (was configureArchiveAngelSweep).
    /// Loads the sidecar (off-main) so the catalog filter works at once,
    /// then schedules the first scoring run. A test host never starts the
    /// launch task: the setting is the pristine default and the sweep only
    /// runs when a test drives it.
    func launch() {
        facadeLog.info("launch START — assessment \(self.sweepEnabled ? "on" : "off", privacy: .public), test host \(self.environment.isTestHost)")
        for line in policyNotices { catalog?.angelLog(line) }
        policyNotices = []
        sweep.configure(ArchiveAngelSweep.Configuration(
            candidates: { [weak self] in self?.catalog?.archiveAngelSweepCandidates() ?? [] },
            isExternallyBusy: { [weak self] in
                guard let self, let catalog = self.catalog else { return true }
                if catalog.isCatalogBusyForAngel { return true }
                return self.jobRunner?.isBusy ?? false
            },
            attentionState: { [weak self] in
                guard let self else { return (0, nil) }
                return (self.attention.revision, self.attention.lastEventAt)
            },
            weights: policy.weights,
            log: { [weak self] line in self?.catalog?.angelLog(line) }
        ), enabled: sweepEnabled)

        guard !environment.isTestHost else {
            facadeLog.info("launch done — test host: no launch pass")
            return
        }
        let root = environment.bufferRoot
        Task { [weak self] in
            guard let self, let catalog = self.catalog, let ledger = self.ledger else { return }
            // Buffer companions whose batch folder is already gone (batches
            // cleared before the companion-retirement fix) are retired
            // once per launch — stats off-main, the catalog on main
            // (2026-09-21; VideoScanModel+ArchiveAngelCompanions).
            await catalog.reconcileArchiveAngelBufferAtLaunch(bufferRoot: root, fileExists: VideoScanModel.fileIsOnDisk)
            // Attention memory first (the scorer reads it), then the grades.
            await self.attention.load(from: ledger.mediaLedger)
            let loaded = await self.store.load()
            // No sidecar, or one assessed under older rules: the grades
            // are needed now, not in 90 s — a pass is under 2 s.
            self.sweep.scheduleLaunchRun(delay: loaded ? nil : 15)
            facadeLog.info("launch done — evidence \(loaded ? "loaded" : "missing or old rules", privacy: .public)")
        }
    }

    /// The MFO center, once VideoScanApp has it: the sweep parks behind an
    /// active Angel or Promote job (`AngelJobRunner.isBusy`).
    func attach(jobRunner: any AngelJobRunner) {
        self.jobRunner = jobRunner
        facadeLog.info("job runner attached")
    }

    /// Rescore once the catalog settles (the sweep debounces). Called on
    /// every records change — O(1), never logged.
    func catalogChanged() {
        sweep.noteCatalogChanged()
    }

    /// Attention events were just ledgered: fold them into the memory and
    /// let the grades catch up (debounced). O(events), never logged here —
    /// the ledger line is the record.
    func noteAttention(_ events: [MediaLedgerEvent]) {
        attention.note(events)
        sweep.noteCatalogChanged()
    }

    // MARK: Recommend (O(1) reads — safe in a row or an inspector)

    /// Grade A + B ids — the catalog's "Archive candidates" filter set.
    var candidateIDs: Set<UUID> { store.candidateIDs }

    func evidence(for id: UUID) -> Evidence? { store.record(for: id) }

    func badge(for id: UUID) -> Badge? { ArchiveAngelCatalogBadge.make(for: store.record(for: id)) }

    /// Bumps on EVERY sweep result (rows re-render their badge on it).
    var evidenceRevisionPublisher: AnyPublisher<Int, Never> {
        store.$revision.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    /// Changes only when the A + B set does (the filter recomputes on it).
    var candidateIDsPublisher: AnyPublisher<Set<UUID>, Never> {
        store.$candidateIDs.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    /// "Assess Now": re-score every record (a few seconds).
    func assessNow() {
        note("Archive Angel: Assess Now — START (\(sweep.status.line))")
        sweep.rescoreNow()
        note("Archive Angel: Assess Now — \(sweepEnabled ? sweep.status.line : "not run: Assess Continuously is off")")
    }

    /// "Assess Continuously": persist, then start/stop the sweep.
    func setContinuous(_ on: Bool) {
        note("Archive Angel: Assess Continuously → \(on ? "on" : "off") — START")
        sweepEnabled = on
        ArchiveAngelSettings.saveSweepEnabled(on, to: environment.defaults)
        sweep.setEnabled(on)
        if on { sweep.rescoreNow() }
        note("Archive Angel: Assess Continuously is \(on ? "on" : "off") — \(sweep.status.line)")
    }

    // MARK: Settings the sheets bind to (live reads — the @AppStorage semantics)

    var batchCount: Int { ArchiveAngelSettings.restored(from: environment.defaults).batchCount }
    var makeLossless: Bool { ArchiveAngelSettings.restored(from: environment.defaults).makeLossless }

    func setBatchCount(_ n: Int) {
        objectWillChange.send()
        ArchiveAngelSettings.saveBatchCount(n, to: environment.defaults)
    }

    func setMakeLossless(_ on: Bool) {
        objectWillChange.send()
        ArchiveAngelSettings.saveMakeLossless(on, to: environment.defaults)
    }

    // MARK: Prepare

    /// The start sheet's Start: the Angel picks `count` and prepares them.
    @discardableResult
    func prepare(count: Int, lossless: Bool, using runner: any AngelJobRunner) -> ArchiveAngelJob? {
        startPrepare(count: count, recordIDs: nil, lossless: lossless, runner: runner,
                     what: "\(count) candidates")
    }

    /// The catalog's "Prepare with Archive Angel": exactly these records.
    /// Lossless follows the start sheet's remembered choice.
    @discardableResult
    func prepare(recordIDs: [UUID], using runner: any AngelJobRunner) -> ArchiveAngelJob? {
        startPrepare(count: recordIDs.count, recordIDs: recordIDs, lossless: makeLossless, runner: runner,
                     what: "\(recordIDs.count) selected record(s)")
    }

    private func startPrepare(count: Int, recordIDs: [UUID]?, lossless: Bool,
                              runner: any AngelJobRunner, what: String) -> ArchiveAngelJob? {
        note("Archive Angel: Prepare \(what), lossless \(lossless ? "on" : "off") — START")
        guard let model else {
            note("Archive Angel: Prepare \(what) — not started: the catalog went away")
            return nil
        }
        let job = runner.startArchiveAngelByUser(count: count, recordIDs: recordIDs, makeLossless: lossless,
                                                 model: model, bufferRoot: environment.bufferRoot,
                                                 weights: policy.weights)
        switch job.state {
        case .failed(let message): note("Archive Angel: Prepare \(what) — refused: \(message)")
        default: note("Archive Angel: Prepare \(what) — started “\(job.title)” (\(job.state.isActive ? "running" : "finished"))")
        }
        return job
    }

    // MARK: Review — the prepared batches (moved from ArchiveView, S2)

    /// Re-read the buffer: settle a promote a quit left `.promoting`, settle
    /// batches a quit or stop left `preparing`, list ready + unreadable
    /// batches and the hygiene report (folder sizes are disk walks — off
    /// the main actor), retire the companions the settle reclaimed, follow
    /// catalog renames, publish. An older scan that finishes late never
    /// overwrites a newer one.
    func refreshBatches(reason: String) {
        guard let model else { return }
        let root = environment.bufferRoot
        facadeLog.info("refreshBatches START (\(reason, privacy: .public))")
        // A promote a quit left `.promoting` is settled against the catalog
        // first (audit #3), so its batch is listed again or finished.
        ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: root, model: model)
        refreshGeneration += 1
        let generation = refreshGeneration
        Task { [weak self] in
            let (readyPlans, unreadable, settled, hygiene) = await Task.detached(priority: .utility) {
                // GH #177: a batch left `preparing` by a quit or a stop is
                // settled here (ready rows kept → listed; none → removed).
                let settled = ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root)
                let scan = ArchiveAngelPlanStore.scanBatches(bufferRoot: root)
                // Folder sizes are disk walks — here, never in body.
                var hygiene = ArchiveAngelBufferHygiene.report(
                    plans: scan.plans,
                    bytesOf: { ArchiveAngelPlanStore.folderBytes($0.batchDir, fm: .default) },
                    modifiedAt: ArchiveAngelBufferHygiene.planModifiedAt,
                    diskFree: ArchiveAngelBufferHygiene.diskFree(bufferRoot: root))
                hygiene.generation = generation
                // A "ready" batch with no ready rows has nothing to review
                // (Rick 2026-09-22: "Archive Angel has 0 videos ready" in
                // orange) — it is not offered.
                return (scan.plans.filter { $0.status == .ready && $0.readyCount > 0 },
                        scan.unreadable, settled, hygiene)
            }.value
            var ready = readyPlans
            await MainActor.run {
                guard let self, let model = self.model else { return }
                // The settle reclaimed the unfinished rows' files; their
                // catalogued companions are retired here (codex #1572) —
                // after the settle's removals, reconciled against the disk.
                model.forgetArchiveAngelCompanions(settled: settled)
                // An older scan that finished late must not overwrite a
                // newer one (#9): its side effects above are idempotent,
                // its picture of the buffer is stale.
                guard hygiene.isNewer(than: self.batches.hygiene) else {
                    facadeLog.info("refreshBatches — generation \(generation) superseded, not published")
                    return
                }
                // Rows follow catalog renames (Rick 2026-09-10) — the row
                // and the sheet show the record's current name.
                for i in ready.indices {
                    let lines = ArchiveAngelPromoter.followRenames(plan: &ready[i], model: model)
                    if !lines.isEmpty {
                        lines.forEach { model.log($0) }
                        ArchiveAngelPlanStore.saveLogged(ready[i], context: "following a catalog rename")
                    }
                }
                self.batches = Batches(ready: ready, unreadable: unreadable, hygiene: hygiene)
                facadeLog.info("refreshBatches done — \(ready.count) ready batch(es), \(unreadable.count) unreadable, \(hygiene.batches.count) in the buffer (generation \(generation))")
            }
        }
    }

    /// The start sheet's banner: un-hide anything put off with Later so
    /// the whole buffer picture is on screen again.
    func revealHygiene() {
        facadeLog.info("revealHygiene START — \(ArchiveAngelHygieneSession.shared.laterBatchIDs.count) batch(es) put off")
        ArchiveAngelHygieneSession.shared.laterBatchIDs.removeAll()
        facadeLog.info("revealHygiene done")
    }

    /// Finished Angel jobs among `jobs` — a change means a batch just
    /// became ready (the Archive tab refreshes on it).
    static func finishedJobCount(_ jobs: [any MediaFileOperationJob]) -> Int {
        jobs.filter { $0.kind == .archiveAngel && !$0.state.isActive }.count
    }

    // MARK: Shared pure helpers other app code uses (the three funcs are nonisolated — callable anywhere)

    /// The ledger kinds that are attention events.
    static var attentionKinds: Set<MediaLedgerEvent.Kind> { ArchiveAngelAttentionStore.attentionKinds }

    /// Lines of `notes` a PERSON could have written (machine text filtered).
    nonisolated static func hasHumanNote(_ notes: String) -> Bool { ArchiveAngelCandidate.hasHumanNote(notes) }

    /// An event family's stem: derivative and share-out tokens stripped, case-folded.
    nonisolated static func familyBaseStem(_ stem: String) -> String { ArchiveAngelFamily.baseStem(stem) }

    /// The stem an export was made from ("x_balanced" → "x"), or nil for an original.
    nonisolated static func derivativeBaseStem(_ stem: String) -> String? { ArchiveAngelNaming.derivativeBaseStem(stem) }

    // MARK: Logging

    /// A user-visible line: unified log + console + videoscan.log.
    private func note(_ line: String) {
        facadeLog.info("\(line, privacy: .public)")
        catalog?.angelLog(line)
    }
}
