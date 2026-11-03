// CatalogStatusWindow.swift — Catalog ▸ Catalog Status… (Rick 2026-11-01):
// ONE window replacing the status band's old door (Content Analysis) and the
// Catalog Database Info window.
//
//   Catalog Status
//   <what it touches · never · instant>              (CatalogActionBrief)
//   ● Catalog: Synced — the strip's indicator (Rick 2026-11-03), and under
//     it, per colour: green = the database basics (schema, generation, size,
//     last check — CatalogDatabaseInfoModel's own rows, no new source);
//     yellow = the line(s) out of step with their one "Fix: <verb>"; red =
//     what is wrong and its fix, or "no fix yet"; grey = why it is grey and
//     what is happening underneath (Counting… / Checking… / a drive not
//     connected), so the user knows whether to wait.
//   ● Database  Integrity check passed 1 Nov 02:14 (9 h ago)     [Check Now…]
//   ● Files     13,842 present where the catalog says · 3 missing · checked …
//   ● Content   Not yet analyzed: Full Hashes 660 · …   [Content Analysis…]
//   ── Details: the band (reasons, "N to review", doors) — the same view
//      Content Analysis shows, over the same value
//   ── Database: the 11/01 facts (schema, layout, size, generation, counts,
//      last commit, last backup, role, sync, journal, last Validate)
//   ── Restore (only when the app opened an older copy read-only, or saving
//      stopped): Reopen SQLite Catalog · Adopt This SQLite Catalog…
//
// Sources: the three lines are `freshness.state.lines` — built in the
// snapshot's one rejudge from the facts and report the band reads
// (CatalogStatusLines.swift); the facts are CatalogDatabaseInfoModel's own
// read (reused, not duplicated), refreshed on open and whenever the lines
// change (a Validate that just finished). Check Now… opens the same
// ValidateCatalogSheet as the menu; Start is `CatalogMenuActions.startValidate`.
//
// OBSERVATION: the freshness snapshot, the update queue and the cutover
// state (all equality-gated or rarely changing), the facts model; `model`,
// `center` and `orchestrator` are plain references — reads and action calls
// only. NO O(records) work here (CatalogStatusWindowSensorTests pins it).

import SwiftUI
import VideoScanCore

struct CatalogStatusWindow: View {
    static let sceneID = "catalog-status"
    static let windowTitle = "Catalog Status"

    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    let orchestrator: CaptionOrchestrator

    @ObservedObject private var freshness: CatalogFreshnessSnapshot
    @ObservedObject private var queue: CatalogStatusUpdateQueue
    @ObservedObject private var cutover: CatalogCutoverState
    @StateObject private var info: CatalogDatabaseInfoModel
    @State private var showValidate = false
    @Environment(\.openWindow) private var openWindow

    init(model: VideoScanModel, center: MediaFileOperationsCenter, orchestrator: CaptionOrchestrator,
         sources: @escaping @MainActor () -> CatalogDatabaseInfoSources) {
        self.model = model
        self.center = center
        self.orchestrator = orchestrator
        self._freshness = ObservedObject(wrappedValue: model.catalogFreshness)
        self._queue = ObservedObject(wrappedValue: model.catalogStatusUpdateQueue)
        self._cutover = ObservedObject(wrappedValue: model.catalogCutover)
        self._info = StateObject(wrappedValue: CatalogDatabaseInfoModel(sources: sources))
    }

    private var runner: AnalyzeRunner { AnalyzeRunner(model: model, orchestrator: orchestrator, center: center) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text(Self.windowTitle).font(.title.weight(.semibold))
                CatalogActionBriefHeader(brief: .catalogStatus)
                catalogLead
                threeLines
                if cutover.canReopen || cutover.canAdopt { restore }
                GroupBox {
                    CatalogStatusBand(
                        state: freshness.state,
                        queue: queue,
                        runningJob: { cycler in runner.activeIntegrityJob(for: cycler) },
                        onRunNow: { cycler in runner.runNow(cycler, source: "catalog status") },
                        onUpdateAll: { queue.enqueue(freshness.state.staleCyclers, runner: runner, source: "catalog status") },
                        onSeeDetails: { job in
                            center.revealJobID = job.id
                            openWindow(id: MediaFileOperationsWindowOpener.sceneID)
                        })
                        .padding(4)
                } label: {
                    Text("Details").font(.title3.weight(.semibold))
                }
                GroupBox {
                    CatalogDatabaseInfoRows(model: info).padding(4)
                } label: {
                    Text("Database").font(.title3.weight(.semibold))
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, alignment: .topLeading)
        .accessibilityIdentifier("catalogStatus.window")
        .task { await info.refresh() }
        .onChange(of: freshness.state.lines) { _, _ in Task { await info.refresh() } }
        .sheet(isPresented: $showValidate) {
            ValidateCatalogSheet(model: model, center: center)
        }
    }

    // MARK: The Catalog indicator's lead

    /// The strip's Catalog indicator, said in full. O(1): a few strings from
    /// the snapshot, and (green) four of the facts model's ~14 rows.
    private var catalogLead: some View {
        let catalog = CatalogStatusIndicators(freshness.state).catalog
        let lead = catalog.state == .green ? CatalogStatusWindowWords.basics(info.lines) : catalog.why
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(catalog.state.tint).frame(width: 14, height: 14)
                Text(CatalogStatusIndicator.catalogPrefix + catalog.words)
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("catalogStatus.catalogIndicator")
            }
            ForEach(lead, id: \.self) { line in
                Text(line)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(catalog.state.tint.opacity(catalog.state == .green ? 0.06 : 0.12)))
    }

    // MARK: The three lines

    @ViewBuilder
    private var threeLines: some View {
        if let lines = freshness.state.lines, freshness.state.isComputed {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines.all, id: \.kind) { line in
                    lineRow(line)
                }
            }
        } else {
            Text("Checking what the catalog knows…").foregroundStyle(.secondary)
        }
    }

    private func lineRow(_ line: CatalogStatusLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(line.state.tint).frame(width: 12, height: 12)
            Text(line.kind.title)
                .font(.headline)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.words)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("catalogStatus.line.\(line.kind.rawValue)")
                ForEach(line.detail, id: \.self) { d in
                    Text(d).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch line.kind {
            case .database:
                Button("Check Now…") { showValidate = true }
                    .disabled(model.isReadOnly)
                    .help(CatalogActionBrief.validateCatalog.help)
                    .accessibilityIdentifier("catalogStatus.checkNow")
            case .content:
                Button("Content Analysis…") { AnalyzeWindowOpener.open(using: openWindow, source: "catalog-status") }
                    .help(CatalogActionBrief.contentAnalysis.help)
            case .files:
                EmptyView()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(line.state.tint.opacity(line.state == .green ? 0.06 : 0.12)))
    }

    // MARK: Restore (only when it applies)

    private var restore: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(cutover.canAdopt
                 ? "This catalog.sqlite is an older copy (a restore), so it opened read-only."
                 : "Saving to catalog.sqlite stopped\(cutover.blockedReason.map { ": \($0)" } ?? "").")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            CatalogReopenMenuItems(cutover: cutover)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("catalogStatus.restore")
    }
}

/// Pure words for the window's lead.
enum CatalogStatusWindowWords {
    /// The rows a green Catalog shows: the facts model's own (no new source).
    static let basicLabels = ["Schema", "Generation", "Size", "Last Validate Catalog"]

    static func basics(_ lines: [CatalogDatabaseInfoLine]) -> [String] {
        let rows = basicLabels.compactMap { label in lines.first { $0.label == label } }
        guard !rows.isEmpty else { return ["Reading the database facts…"] }
        return rows.map { "\($0.label): \($0.value)" }
    }
}

extension CatalogStatusLineState {
    /// The dot: the band's colours, and blue for "in progress".
    var tint: Color {
        switch self {
        case .grey: return .secondary
        case .green: return .green
        case .inProgress: return .blue
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}
