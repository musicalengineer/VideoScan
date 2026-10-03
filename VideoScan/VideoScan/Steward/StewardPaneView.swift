// StewardPaneView.swift
// The content steward's pane at the top of the Triage tab (trial UI,
// 2026-10-03; design §5.6 of
// docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md):
//
//   ┌ Here is what would tidy the catalog most ── Show skipped (3) · What the catalog knows… ┐
//   │ ┌ ONE focused case ───────────────────────────┐ ┌ Next up ─────────────┐ │
//   │ │ [Reclaim space]                              │ │ [Same footage] 27 …  │ │
//   │ │ SanDisk: 412 GB in 1,208 duplicate copies    │ │ [Not worth keeping]… │ │
//   │ │ evidence … rule …                            │ │ [Reclaim space] 4 …  │ │
//   │ │ [Show these in the Catalog] [Delete…] [Skip] │ │ …                    │ │
//   │ └──────────────────────────────────────────────┘ └──────────────────────┘ │
//   └────────────────────────────────────────────────────────────────────────────┘
//   (the Triage table, unchanged, below)
//
// ONE QUEUE WITH A KIND CHIP, not three tabs: the librarian model is one
// thing at a time, and three tabs would ask the person to choose a kind
// before seeing a case. Bytes (Reclaim) and clarity (Same footage) are not
// the same currency, so the kinds are not ranked against each other — they
// take turns, each in its own payoff order (StewardCaseBuilder.interleave).
//
// It REWIRES what exists; it starts nothing of its own:
//   Show these in the Catalog ...... model.showInCatalog(focus:label:)
//   Delete duplicates on <drive>… .. the shared deleteDuplicatesFlow
//                                    (picker → forecast → the existing job)
//   Open the footage group ......... FootageGroupSheet
//   Show one per footage ........... the Catalog's persisted Show filter
//   Review these below ............. the Triage table (via `onReviewBelow`)
//   What the catalog knows… ........ AnalyzeWindowOpener
//
// NO O(records) work here: the pane reads the model's cached
// `stewardSnapshot.queue` (≤ 100 cases) and the Analyze coverage snapshot.
// The focused Reclaim set's proof is worked out in `.task(id:)`, never in a
// body (StewardEvidence.swift).
//
// Logging: one line per user action (shown / skipped / brought back /
// acted) through the existing sinks, never per render, never a filename, a
// title or a path (StewardLog).
//
// (For Rick: `@ObservedObject` ≈ subscribing to that object's change
// signal; `@State` ≈ a member variable SwiftUI keeps alive across redraws;
// `.task(id:)` ≈ "run this coroutine whenever `id` changes, cancelling the
// previous run".)

import SwiftUI

struct StewardPaneView: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var snapshot: StewardSnapshot
    @ObservedObject var coverage: AnalyzeCoverageSnapshot
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenterReference
    @Environment(\.openWindow) private var openWindow
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @AppStorage("steward.pane.expanded") private var expanded = true

    /// "Review these below": the Triage table shows just these, selected.
    let onReviewBelow: (_ ids: Set<UUID>, _ label: String) -> Void

    @State private var active: [StewardCase] = []
    @State private var skipped: [StewardCase] = []
    @State private var showSkipped = false
    @State private var focusedID: String?
    @State private var lastShownID: String?
    @State private var evidence: StewardGroupEvidence?
    @State private var picker: DeleteDuplicatesVolumePickerRequest?
    @State private var pickerPreselect: String?
    @State private var deleteCase: StewardCase?
    @State private var footageSheet: FootageSheetRequest?

    /// Rows in the "next up" list.
    static let nextUpRows = 7
    static let expandedHeight: CGFloat = 330

    private var skipStore: StewardSkipStore { StewardSkipStore(defaults: model.stewardDefaults) }

    /// The list on screen: the queue, or the skipped cases.
    private var visible: [StewardCase] { showSkipped ? skipped : active }

    private var focused: StewardCase? {
        visible.first { $0.id == focusedID } ?? visible.first
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if expanded {
                Divider()
                content
                    .frame(height: Self.expandedHeight)
            }
            Divider()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .accessibilityIdentifier("steward.pane")
        .onAppear {
            model.stewardPaneAppeared()
            repartition()
        }
        .onChange(of: snapshot.queue) { _, _ in repartition() }
        // The focused Reclaim set's proof — keyed on the case AND its
        // facts, so a rebuilt queue re-asks.
        .task(id: evidenceKey) { await loadEvidence() }
        .deleteDuplicatesFlow(picker: $picker, preselectedPath: pickerPreselect, source: "Triage tab",
                              onStarted: { volume in
            guard let c = deleteCase else { return }
            note(.acted, c, action: "Delete duplicates started on \(StewardCaseBuilder.driveLabel(volume))")
        })
        .sheet(item: $footageSheet) { request in
            FootageGroupSheet(request: request, model: model, startRun: { [fileOpsCenterReference, model] scope in
                fileOpsCenterReference?.startFindSimilarFootage(scope: scope, model: model)
            })
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Here is what would tidy the catalog most")
                        .font(.system(size: 16, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the suggestions" : "Show the suggestions")
            .accessibilityIdentifier("steward.pane.toggle")

            Text(countLine)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("steward.pane.count")

            Spacer(minLength: 8)

            if !skipped.isEmpty || showSkipped {
                Button(showSkipped ? "Back to the suggestions" : "Show skipped (\(skipped.count))") {
                    showSkipped.toggle()
                    focusedID = nil
                    noteShownIfChanged()
                }
                .buttonStyle(.link)
                .font(.system(size: 14))
                .help(showSkipped ? "Back to what has not been skipped"
                                  : "The suggestions you skipped — bring any of them back")
                .accessibilityIdentifier("steward.pane.showSkipped")
            }
            Button("What the catalog knows…") {
                AnalyzeWindowOpener.open(using: openWindow, source: "triage-suggestions")
            }
            .buttonStyle(.link)
            .font(.system(size: 14))
            .help("How current the catalog's knowledge is — duplicates, same footage, dates and the rest — and the controls to bring it up to date")
            .accessibilityIdentifier("steward.pane.knowledge")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var countLine: String {
        guard snapshot.queue.isBuilt else { return "looking through the catalog…" }
        if showSkipped { return "\(skipped.count) skipped" }
        if active.isEmpty { return "nothing to tidy right now" }
        return "\(active.count) suggestion\(active.count == 1 ? "" : "s")"
    }

    // MARK: The focused case + next up

    @ViewBuilder
    private var content: some View {
        if let c = focused {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    StewardCardView(item: c,
                                    evidence: evidence?.caseID == c.id ? evidence : nil,
                                    freshness: freshness(for: c),
                                    deleteGate: deleteGate(for: c),
                                    isReadOnly: model.isReadOnly,
                                    isSkipped: showSkipped,
                                    actions: actions(for: c))
                }
                .frame(maxWidth: .infinity)
                Divider()
                nextUp(after: c)
                    .frame(width: 340)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.queue.isBuilt
                     ? (showSkipped ? "Nothing is skipped." : "Nothing to tidy right now.")
                     : "Looking through the catalog…")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                if snapshot.queue.isBuilt {
                    Text(StewardFreshness.line(for: .reclaimGroup, duplicatesLastChecked: snapshot.queue.duplicatesLastChecked,
                                               report: coverage.report, now: Date()))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text(StewardFreshness.line(for: .sameFootage, duplicatesLastChecked: nil,
                                               report: coverage.report, now: Date()))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func nextUp(after focused: StewardCase) -> some View {
        let rows = visible.filter { $0.id != focused.id }
        return VStack(alignment: .leading, spacing: 0) {
            Text(showSkipped ? "Skipped" : "Next up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.prefix(Self.nextUpRows)) { c in
                        Button {
                            focusedID = c.id
                            noteShownIfChanged()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                StewardKindChip(kind: c.kind)
                                Text(c.title)
                                    .font(.system(size: 14))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Look at this one")
                        .accessibilityIdentifier("steward.nextUp.row")
                        Divider()
                    }
                    if rows.count > Self.nextUpRows {
                        Text("and \((rows.count - Self.nextUpRows).formatted()) more after these")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }
                    if rows.isEmpty {
                        Text("Nothing else is waiting.")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }
                }
            }
        }
        .accessibilityIdentifier("steward.nextUp")
    }

    // MARK: Words and button states (O(volumes) at most)

    private func freshness(for c: StewardCase) -> String {
        StewardFreshness.line(for: c.kind, duplicatesLastChecked: snapshot.queue.duplicatesLastChecked,
                              report: coverage.report, now: Date())
    }

    /// The drive as the Delete flow itself lists it (the model's cached
    /// menu payload), or nil when the flow does not offer it.
    private func offeredPath(for c: StewardCase) -> String? {
        guard let root = c.driveRoot else { return nil }
        return model.deletableDupVolumes
            .first { VolumeDashboardCalculator.normalizedRoot($0.path) == root }?.path
    }

    private func deleteGate(for c: StewardCase) -> StewardActionGate {
        StewardActionGate.deleteDuplicates(isReadOnly: model.isReadOnly,
                                           isDeleteRunning: model.isDeletingDuplicates,
                                           driveLabel: c.driveLabel,
                                           driveConnected: c.driveConnected,
                                           offeredByDeleteFlow: offeredPath(for: c) != nil,
                                           needsWorkingCopyMode: c.copiesNeedingWorkingCopyMode > 0)
    }

    // MARK: Actions

    private func actions(for c: StewardCase) -> StewardCardActions {
        StewardCardActions(
            showInCatalog: {
                note(.acted, c, action: "Show these in the Catalog")
                model.showInCatalog(focus: Set(c.recordIDs), label: c.kind.chip)
            },
            deleteDuplicates: {
                guard let path = offeredPath(for: c) else { return }
                note(.acted, c, action: "opened Delete duplicates for \(c.driveLabel)")
                deleteCase = c
                pickerPreselect = path
                picker = DeleteDuplicatesVolumePickerRequest()
            },
            openFootageGroup: {
                guard let id = c.likelyOriginalID ?? c.recordIDs.first else { return }
                note(.acted, c, action: "Open the footage group")
                footageSheet = FootageSheetRequest(recordID: id)
            },
            showOnePerFootage: {
                note(.acted, c, action: "Show one per footage in the Catalog")
                StewardCatalogDoor.turnOnOnePerFootage(in: .standard)
                // The Catalog restores the last focus when it appears; an
                // old one would hide the very rows this is meant to show.
                model.focusedMediaIDs = []
                model.pendingCatalogSelection = nil
                selectedTab = 1
            },
            reviewBelow: {
                note(.acted, c, action: "Review these below")
                onReviewBelow(Set(c.recordIDs), c.title)
            },
            skip: {
                note(.skipped, c)
                skipStore.skip(c)
                focusedID = nil
                repartition()
                // Rebuild so the next one behind the per-kind limit comes
                // forward (QA F4).
                model.scheduleStewardRefresh()
            },
            bringBack: {
                note(.broughtBack, c)
                skipStore.bringBack(caseID: c.id)
                focusedID = nil
                repartition()
                model.scheduleStewardRefresh()
            })
    }

    // MARK: State upkeep (event handlers — never from `body`)

    /// Split the cached queue by the skip memory (≤ 100 defaults reads).
    private func repartition() {
        let parts = skipStore.partition(snapshot.queue.cases)
        active = parts.active
        skipped = parts.skipped
        if skipped.isEmpty { showSkipped = false }
        // Focus is sticky: it moves only when its case is gone.
        if focusedID == nil || !visible.contains(where: { $0.id == focusedID }) {
            focusedID = visible.first?.id
        }
        noteShownIfChanged()
    }

    /// One "shown" line each time a DIFFERENT case takes the card.
    private func noteShownIfChanged() {
        guard expanded, let c = focused, c.id != lastShownID else { return }
        lastShownID = c.id
        note(.shown, c)
    }

    private func note(_ verb: StewardLog.Verb, _ c: StewardCase, action: String? = nil) {
        let line = StewardLog.line(verb, c, action: action)
        model.log(line)
        appLog.write(line)
    }

    private var evidenceKey: String {
        guard expanded, let c = focused, c.kind == .reclaimGroup else { return "" }
        return "\(c.id)|\(c.facts.bytes)|\(c.facts.count)"
    }

    /// The focused Reclaim set's proof: the keeper's reason at once, then
    /// the planner's count once the drives have answered (stat only).
    private func loadEvidence() async {
        guard expanded, let c = focused, c.kind == .reclaimGroup,
              let prepared = StewardEvidenceBuilder.prepare(model: model, for: c) else {
            evidence = nil
            return
        }
        evidence = prepared.evidence
        let questions = prepared.questions
        let preferTrash = prepared.preferTrash
        let proofs = await Task.detached(priority: .utility) {
            StewardEvidenceBuilder.prove(questions, preferTrash: preferTrash)
        }.value
        guard !Task.isCancelled else { return }
        var done = prepared.evidence
        done.proofs = proofs
        evidence = done
    }
}

/// The steward's way into the Catalog's "One Per Footage" view. The Catalog
/// tab is not alive while Triage is on screen, so there is no binding to
/// flip; the Show filters are persisted under one key and read back when
/// the Catalog appears — this adds the filter there, through the Catalog's
/// own encoder.
enum StewardCatalogDoor {
    /// CatalogView's `@AppStorage("catalog.viewFilters")` (sensor:
    /// StewardSourceSensorTests pins that the Catalog still uses this key).
    static let viewFiltersKey = "catalog.viewFilters"

    static func turnOnOnePerFootage(in defaults: UserDefaults) {
        var filters = CatalogShowingSummary.decode(defaults.string(forKey: viewFiltersKey) ?? "")
        filters.insert(.onePerFootage)
        defaults.set(CatalogShowingSummary.encode(filters), forKey: viewFiltersKey)
    }
}
