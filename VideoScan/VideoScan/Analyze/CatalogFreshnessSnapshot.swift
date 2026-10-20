// CatalogFreshnessSnapshot.swift
// ONE equality-gated snapshot behind every Catalog Status surface (Rick
// 2026-10-16, docs/design/catalog_status_freshness_2026_10_16.md §4): the
// chip on the totals strip, the dot on the Content Analysis button, the
// Analyze menu's first row, the Catalog ▸ Catalog Status… title, the band
// at the top of the Analyze panel and the freshness column on every row.
//
// Pattern = AnalyzeCoverageSnapshot: the model's debounced catalog-change
// pass projects once, computes off-main, and publishes here; the views
// observe THIS object and nothing else. NO O(records) work anywhere in
// this file — the rows are built from the cached AnalyzeCoverageReport
// (already O(1) per cycler) plus two small facts (CatalogFreshnessFacts).
//
// Three things move the snapshot:
//   1. the coverage pass (catalog mutation; the audit / hash / sound jobs
//      save the catalog, so their stamps land here) — report + facts;
//   2. what is RUNNING, from the same three sources AnalyzeRunner.isRunning
//      reads (codex cycle #80: a running OCR pass must read "running" here
//      too, not only on the panel's tick): the MFO center's job list (the
//      three integrity jobs + Similar Footage; a 4 Hz-throttled signal),
//      the model's four engine flags (Duplicates, Correlate, Signatures,
//      Embedded Dates) and the dossier snapshot (Captions / OCR /
//      Transcribe share one engine). Re-judged only when the union SET
//      changes. A kind that just STOPPED also re-reads the two facts off
//      the main actor — an audit that found every file present marks
//      nothing, so no catalog save (and no coverage pass) would follow,
//      yet its marker just changed;
//   3. a 60 s clock: "12 minutes ago" ages; re-judging 12 rows is µs.
// Each lands as one `state` write, and only when the value differs.
//
// Memory: a dozen FreshnessRows and their verdicts — bytes.
//
// (For Rick: `@Published private(set) var state` ≈ a struct member with a
// change signal the views subscribe to; `AnyCancellable` ≈ an RAII
// subscription handle.)

import Combine
import Foundation
import VideoScanCore

// MARK: - Rows (pure)

enum CatalogFreshnessRows {

    /// One FreshnessRow per registry kind, in registry order.
    /// `running` = kinds with a pass in flight (sampled by the caller).
    static func rows(report: AnalyzeCoverageReport,
                     facts: CatalogFreshnessFacts,
                     running: Set<AnalyzeCycler>) -> [FreshnessRow] {
        AnalyzeCycler.allCases.map { row($0, report: report, facts: facts, running: running) }
    }

    static func row(_ cycler: AnalyzeCycler, report: AnalyzeCoverageReport,
                    facts: CatalogFreshnessFacts, running: Set<AnalyzeCycler>) -> FreshnessRow {
        let k = report.counts(cycler)
        var row = FreshnessRow(kind: cycler.rawValue, title: cycler.title,
                               eligible: k.eligible, covered: k.covered, offline: k.offline,
                               lastCompleted: k.newestStamp, lastOutcome: .ok,
                               isRunning: running.contains(cycler), phrases: phrases(cycler))
        switch cycler {
        case .filePresence:
            let audit = CatalogAuditPresenceFacts.from(facts.audit, switchedAt: facts.switchedAt)
            row.covered = min(row.eligible, audit.checked)
            row.lastCompleted = audit.lastCompleted
            row.lastOutcome = audit.outcome
            row.needsDecision = audit.needsDecision
            row.cadence = .seconds(24 * 3_600)
            if audit.predatesSwitch { row.phrases.uncovered = Self.notSinceTheSwitch("checked") }
        case .soundPrints:
            row.storeUnavailable = facts.soundStoreProblem
        case .integrity:
            // No stamp per row: the last Verify Catalog report stands in
            // (its BUILT tiers' results, dates and words — IntegrityReportFacts).
            // uncovered = the rows some built tier could not verify (a tier
            // not run, "could not check", the catalog changed during the
            // run): yellow, naming the tier; lastCompleted = the OLDEST
            // built tier's date, so the day's cadence judges the stalest
            // one; the note names the tiers not built, whatever the colour.
            let integrity = facts.integrity
            row.covered = row.eligible - integrity.unverified
            row.lastCompleted = integrity.lastCompleted
            row.lastOutcome = integrity.outcome
            row.needsDecision = integrity.needsDecision
            row.storeUnavailable = integrity.problem
            row.cadence = .seconds(24 * 3_600)
            row.note = integrity.note
            if let words = integrity.decisionWords { row.phrases.decision = "— \(words)" }
            if integrity.needsDecision == 0, let words = integrity.unverifiedWords {
                // The yellow words count rows; red keeps "findings".
                row.phrases.unit = "row"
                row.phrases.uncovered = "not verified — \(words)"
            }
            if integrity.predatesSwitch {
                // The report is catalog.json's: every row of this catalog
                // is unverified, and Run now is the answer.
                row.covered = 0
                row.phrases.unit = "row"
                row.phrases.uncovered = Self.notSinceTheSwitch("verified")
            }
        case .correlate:
            // Pairs are counted differently: the unpaired candidates are
            // the uncovered rows, the pairs the covered ones.
            let c = report.correlate
            row.eligible = c.pairs * 2 + c.unpaired
            row.covered = c.pairs * 2
            row.offline = c.offlineCandidates
        case .footage:
            // No per-record stamp (a singleton carries nothing): the row
            // can only say when it last ran, never a count. Treat it as
            // covered so the band does not shout about a number it does
            // not have (AnalyzeCoverageReport.coverageUnknown).
            row.covered = row.eligible
        default:
            break
        }
        return row
    }

    /// "not checked since the switch to SQLite" — the uncovered words of a
    /// row whose last pass read catalog.json, before the switch.
    static func notSinceTheSwitch(_ participle: String) -> String {
        "not \(participle) since the switch to SQLite"
    }

    /// Each kind's own words for its counts (FreshnessRow.Phrases).
    static func phrases(_ cycler: AnalyzeCycler) -> FreshnessRow.Phrases {
        switch cycler {
        case .filePresence:
            return .init(unit: "file", uncovered: "not yet checked",
                         decision: "pointing at nothing or changed on disk — look at Fix Links")
        case .fullHashes:
            return .init(unit: "file", uncovered: "without a full hash")
        case .soundPrints:
            return .init(unit: "file", uncovered: "without a sound print")
        case .integrity:
            return .init(unit: "finding", uncovered: "not yet verified",
                         decision: "needing a decision — Validate Catalog's row lists them")
        case .correlate:
            return .init(unit: "file", uncovered: "unpaired")
        case .dateInference:
            return .init(unit: "file", uncovered: "without an inferred date")
        case .duplicates, .footage, .sceneCaptions, .ocr, .transcribe, .fileSignatures, .embeddedDates:
            return .init(unit: "file", uncovered: "not yet \(verb(cycler))")
        }
    }

    private static func verb(_ cycler: AnalyzeCycler) -> String {
        switch cycler {
        case .duplicates: return "checked for duplicates"
        case .footage: return "grouped"
        case .sceneCaptions: return "captioned"
        case .ocr: return "read for on-screen text"
        case .transcribe: return "transcribed"
        case .fileSignatures: return "signed"
        case .embeddedDates: return "probed for an embedded date"
        default: return "checked"
        }
    }
}

// MARK: - State (one value; Equatable)

/// Everything the surfaces read. Built in one place (`CatalogFreshnessSnapshot`),
/// compared as a whole before it is published.
struct CatalogFreshnessState: Equatable {
    var rows: [FreshnessRow] = []
    var verdicts: [AnalyzeCycler: FreshnessVerdict] = [:]
    /// The band. Its COLOUR and HEADLINE are the reality verdict's (Rick
    /// 2026-10-20: does the catalog reflect reality? — CatalogRealityPolicy);
    /// its items and stale kinds are still the per-row ones (what is stale,
    /// what "Update everything stale" queues).
    var summary = FreshnessSummary(colour: .grey, headline: "Nothing to check", items: [], staleKinds: [])
    /// The band's verdict: colour, headline, reasons, the review items
    /// ("N to review") and the information lines.
    var reality = CatalogRealityVerdict(colour: .grey, headline: "Nothing to check", reasons: [], review: [], information: [])
    /// False until the first coverage pass has landed (the chip stays
    /// quiet rather than claiming "nothing to check" at launch).
    var isComputed = false

    func verdict(_ cycler: AnalyzeCycler) -> FreshnessVerdict? { verdicts[cycler] }
    func row(_ cycler: AnalyzeCycler) -> FreshnessRow? { rows.first { $0.kind == cycler.rawValue } }
    func isRunning(_ cycler: AnalyzeCycler) -> Bool { row(cycler)?.isRunning ?? false }

    /// The kinds "Update everything stale" queues, in registry order.
    var staleCyclers: [AnalyzeCycler] { summary.staleKinds.compactMap(AnalyzeCycler.init(rawValue:)) }

    /// Judge every row, summarize, and take the band's colour and headline
    /// from the reality verdict — the one place the policies are applied.
    /// `reality` defaults to "nothing known" (never validated: yellow).
    static func judged(rows: [FreshnessRow], reality: CatalogRealityInputs = CatalogRealityInputs(),
                       now: Date, wording: FreshnessWording = .current) -> CatalogFreshnessState {
        var s = CatalogFreshnessState()
        s.rows = rows
        for row in rows {
            guard let cycler = AnalyzeCycler(rawValue: row.kind) else { continue }
            s.verdicts[cycler] = FreshnessPolicy.judge(row, now: now, wording: wording)
        }
        s.summary = FreshnessPolicy.summarize(rows, now: now, wording: wording)
        s.reality = CatalogRealityPolicy.judge(reality.facts, review: reality.review, information: reality.information, now: now)
        s.summary.colour = s.reality.colour
        s.summary.headline = s.reality.headline
        s.isComputed = true
        return s
    }
}

// MARK: - Words for the chip and the menu (pure)

enum CatalogStatusWords {

    static let chipPrefix = "Catalog Status: "

    /// What follows "Catalog Status: " on the totals strip: the colour in
    /// two or three words, so the chip ends under the Files column (Rick
    /// 2026-10-18). The headline and the items live in the tooltip and in
    /// Content Analysis, one click away.
    static func chipWords(_ state: CatalogFreshnessState) -> String {
        guard state.isComputed else { return "checking…" }
        // Rick 2026-10-20: the colour answers "does the catalog reflect reality?"
        switch state.summary.colour {
        case .green: return "Reconciled"
        case .yellow: return state.reality.reasons.first?.shortWords ?? "Needs validation"
        case .red: return "Needs attention…"
        case .grey: return "nothing to check"
        }
    }

    /// Catalog ▸ "Catalog Status…" carries the colour word when not green.
    static func menuTitle(_ colour: FreshnessColour) -> String {
        switch colour {
        case .red: return "Catalog Status — Needs attention…"
        case .yellow, .green, .grey: return "Catalog Status…"
        }
    }

    /// The one console/log line at launch when the band is red: the
    /// headline, then every red reason past the first (the headline names
    /// the first once).
    static func launchLine(_ reality: CatalogRealityVerdict) -> String {
        let more = reality.reasons.dropFirst().filter { $0.colour == .red }.map(reality.words)
        let tail = more.isEmpty ? "" : " — " + more.joined(separator: "; ")
        return "\(reality.headline)\(tail). Catalog ▸ Catalog Status… lists the doors."
    }
}

// MARK: - The snapshot (model-owned; views observe this and nothing else)

@MainActor
final class CatalogFreshnessSnapshot: ObservableObject {

    @Published private(set) var state = CatalogFreshnessState()
    /// Test hook: how many state writes actually landed.
    private(set) var publishCount = 0

    private var report = AnalyzeCoverageReport()
    private var facts = CatalogFreshnessFacts()
    /// What the rows read: the union of the three sources below.
    private var running: Set<AnalyzeCycler> = []
    /// Kept apart so one source's signal never erases another's answer
    /// (≈ three bitfields OR-ed together on every change).
    private var jobRunning: Set<AnalyzeCycler> = []
    private var engineRunning: Set<AnalyzeCycler> = []
    private var dossierRunning: Set<AnalyzeCycler> = []
    /// The catalog.json path the facts were read beside (for the re-read).
    private var catalogFile: String?
    private var factsTask: Task<Void, Never>?
    private var centerSubscription: AnyCancellable?
    private var engineSubscription: AnyCancellable?
    private var dossierSubscription: AnyCancellable?
    private var clock: AnyCancellable?
    private var announced = false

    init() {}

    /// From the coverage pass: the report and the two file facts.
    func publish(report: AnalyzeCoverageReport, facts: CatalogFreshnessFacts, catalogFile: String? = nil) {
        self.report = report
        self.facts = facts
        if let catalogFile { self.catalogFile = catalogFile }
        rejudge()
    }

    /// Which kinds have a pass in flight. Re-judges only when the set
    /// changed; a kind that just stopped re-reads the facts (see header).
    func setRunning(_ kinds: Set<AnalyzeCycler>) {
        guard kinds != running else { return }
        let stopped = !running.subtracting(kinds).isEmpty
        running = kinds
        rejudge()
        if stopped { rereadFacts() }
    }

    /// One small JSON + one SQLite open, off the main actor; the result
    /// lands through `publish` (equality-gated like everything else).
    func rereadFacts() {
        guard let catalogFile else { return }
        factsTask?.cancel()
        factsTask = Task { [weak self] in
            let facts = await Task.detached(priority: .utility) {
                CatalogFreshnessFactsReader.read(catalogFile: catalogFile)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.publish(report: self.report, facts: facts)
        }
    }

    /// Follow the MFO center: the three integrity jobs and Similar Footage
    /// are MFO jobs, so "running" is whether one of them is active in the
    /// list. The center already throttles its change signal to 4 Hz; the
    /// set comparison above makes a progress beat a no-op.
    func observeRunning(in center: MediaFileOperationsCenter) {
        centerSubscription = center.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak center] _ in
                guard let self, let center else { return }
                self.jobRunning = Self.jobRunning(in: center)
                self.mergeRunning()
            }
        jobRunning = Self.jobRunning(in: center)
        mergeRunning()
    }

    /// Follow the model's own engine flags — the ones AnalyzeRunner.isRunning
    /// reads for Duplicates, Correlate, Signatures and Embedded Dates. Each
    /// is `@Published`, so a flip is one event, not a tick. (For Rick:
    /// CombineLatest4 ≈ a 4-input latch that re-emits the tuple whenever
    /// any input changes.)
    func observeEngines(of model: VideoScanModel) {
        engineSubscription = Publishers.CombineLatest4(model.$isAnalyzingDuplicates, model.$isCorrelating,
                                                       model.$isComputingSignatures, model.$isRefreshingEmbeddedDates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duplicates, correlate, signatures, embeddedDates in
                guard let self else { return }
                var s: Set<AnalyzeCycler> = []
                if duplicates { s.insert(.duplicates) }
                if correlate { s.insert(.correlate) }
                if signatures { s.insert(.fileSignatures) }
                if embeddedDates { s.insert(.embeddedDates) }
                self.engineRunning = s
                self.mergeRunning()
            }
    }

    /// Follow the dossier engine: Captions, OCR and Transcribe share one
    /// orchestrator and one queue, so all three read "running" together
    /// (the same answer AnalyzeRunner.isRunning gives). The snapshot is
    /// already equality-gated at ≤2 Hz.
    func observeDossier(_ dossier: DossierDashboardSnapshot) {
        dossierSubscription = dossier.$state
            .map(\.statusIsActive)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                self.dossierRunning = active ? [.sceneCaptions, .ocr, .transcribe] : []
                self.mergeRunning()
            }
    }

    private func mergeRunning() {
        setRunning(jobRunning.union(engineRunning).union(dossierRunning))
    }

    /// The kinds with an active MFO job in the center. O(jobs).
    static func jobRunning(in center: MediaFileOperationsCenter) -> Set<AnalyzeCycler> {
        var s: Set<AnalyzeCycler> = []
        for job in center.jobs where job.state.isActive {
            if job is ValidateCatalogJob { s.formUnion([.filePresence, .integrity]) }   // both steps, one job
            if job is CatalogAuditJob { s.insert(.filePresence) }
            else if job is FullHashBackfillJob { s.insert(.fullHashes) }
            else if job is AudioFingerprintBackfillJob { s.insert(.soundPrints) }
            else if job is VerifyCatalogJob { s.insert(.integrity) }
            else if job is FindSimilarFootageJob { s.insert(.footage) }
        }
        return s
    }

    /// The integrity kinds with an active job in the center.
    static func integrityRunning(in center: MediaFileOperationsCenter) -> Set<AnalyzeCycler> {
        jobRunning(in: center).intersection(AnalyzeCycler.integrityJobs)
    }

    /// Keep the relative words honest ("12 minutes ago" → "13 …") — one
    /// re-judge a minute, equality-gated so an unchanged minute is free.
    func startClock(every seconds: TimeInterval = 60) {
        clock = Timer.publish(every: seconds, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.rejudge() }
    }

    /// §4.3: at launch, a red summary is ONE line through the catalog sink.
    /// Called after each publish; fires once per process, on the first
    /// computed state that saw a loaded catalog (an empty pre-load pass
    /// has nothing to say and must not spend the one line).
    func announceAtLaunch(to model: VideoScanModel) {
        guard !announced, state.isComputed, report.activeRecords > 0 else { return }
        announced = true
        guard state.summary.needsAttention else { return }
        model.catalogStatusNote(CatalogStatusWords.launchLine(state.reality))
    }

    private func rejudge(now: Date = Date()) {
        guard report.computedAt.timeIntervalSince1970 > 0 else { return }
        let rows = CatalogFreshnessRows.rows(report: report, facts: facts, running: running)
        let reality = CatalogRealityFactsBuilder.inputs(facts: facts, missing: report.missingCopies)
        let new = CatalogFreshnessState.judged(rows: rows, reality: reality, now: now)
        guard new != state else { return }
        publishCount += 1
        state = new
    }
}

// MARK: - Model half

extension VideoScanModel {
    /// The one sink: console + catalog.log, videoscan.log (the full-hash
    /// launch line's pattern).
    func catalogStatusNote(_ line: String) {
        log("Catalog status: " + line)
        appLog.write("[catalog-status] " + line)
    }
}
