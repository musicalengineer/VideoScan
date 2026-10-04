// StewardPaneView.swift
// The content steward's pane at the top of the Triage tab (trial UI,
// 2026-10-03; design §5.6 of
// docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md):
//
//   ┌ Here is what is in the catalog, by occasion — and what would tidy it ── Show skipped (3) · What the catalog knows… ┐
//   │ (All | Events | Same footage | Space | Not worth keeping)  [ ] By year   1,204 of 9,310 clips have a date…        │
//   │ ┌ ONE focused card ───────────────────────────┐ ┌ Next up ─────────────┐ │
//   │ │ [Event]                                      │ │ [Event] Alex's 3rd … │ │
//   │ │ Christmas 1994                               │ │ [Event] Cape 1996    │ │
//   │ │ 14 clips · 3 drives · 2 h 10 m · Dec 24–26…  │ │ [A day to name] …    │ │
//   │ │ how placed … inside … why each clip is here  │ │ [Same footage] 27 …  │ │
//   │ │ [Show these in the Catalog] [Review…] [Skip] │ │ [Reclaim space] …    │ │
//   │ └──────────────────────────────────────────────┘ └──────────────────────┘ │
//   └────────────────────────────────────────────────────────────────────────────┘
//   (the Triage table, unchanged, below)
//
// EVENTS LEAD (Rick 2026-10-03: "it should help find events … the deletion
// of dups is just to keep the database down"). ONE LIST WITH A KIND CHIP:
// the librarian model is one thing at a time. The list runs lane after
// lane — events (most clips first), days to name, same footage, reclaim
// space, not worth keeping — and the filter above it narrows it to one
// kind. "By year" puts the events in year order instead. Both are pure
// view state (StewardCaseBuilder.arrange); the focus is sticky.
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
// acted / the filter changed) through the existing sinks, never per
// render, never a filename, a title or a path — an event is logged by its
// kind and its counts only (StewardLog).
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
    /// The filter above the list and the Events order — pure view state.
    @AppStorage("steward.pane.filter") private var filterRaw = StewardCaseBuilder.Filter.all.rawValue
    @AppStorage("steward.pane.eventsByYear") private var eventsByYear = false

    /// "Review these below": the Triage table shows just these, selected.
    let onReviewBelow: (_ ids: Set<UUID>, _ label: String) -> Void

    @State private var active: [StewardCase] = []
    @State private var skipped: [StewardCase] = []
    /// The list on screen: the suggestions (or the skipped ones), narrowed
    /// and ordered. Set by `rearrange()` in event handlers, never in body.
    @State private var visible: [StewardCase] = []
    @State private var showSkipped = false
    @State private var counts = StewardPaneWords.Counts()
    @State private var focusedID: String?
    @State private var lastShownID: String?
    @State private var evidence: StewardGroupEvidence?
    @State private var picker: DeleteDuplicatesVolumePickerRequest?
    @State private var pickerPreselect: String?
    @State private var deleteCase: StewardCase?
    @State private var footageSheet: FootageSheetRequest?

    /// Rows in the "next up" list (it scrolls; events are browsed here).
    static let nextUpRows = 30
    static let expandedHeight: CGFloat = 330

    private var skipStore: StewardSkipStore { StewardSkipStore(defaults: model.stewardDefaults) }

    private var filter: StewardCaseBuilder.Filter { StewardCaseBuilder.Filter(rawValue: filterRaw) ?? .all }

    private var focused: StewardCase? {
        visible.first { $0.id == focusedID } ?? visible.first
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if expanded {
                Divider()
                filterBar
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
        .onDisappear { model.stewardPaneDisappeared() }
        .onChange(of: snapshot.queue) { _, _ in repartition() }
        .onChange(of: filterRaw) { _, _ in viewChanged() }
        .onChange(of: eventsByYear) { _, _ in viewChanged() }
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
                    Text("Here is what is in the catalog, by occasion — and what would tidy it")
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
                    rearrange()
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
        if active.isEmpty { return "nothing to show right now" }
        return StewardPaneWords.countLine(events: counts.events, days: counts.days, tidy: counts.tidy)
    }

    // MARK: Filter + order

    private var filterBar: some View {
        HStack(spacing: 14) {
            Picker("Show", selection: $filterRaw) {
                ForEach(StewardCaseBuilder.Filter.allCases, id: \.rawValue) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show everything, or just one kind")
            .accessibilityIdentifier("steward.pane.filter")

            Toggle("By year", isOn: $eventsByYear)
                .toggleStyle(.checkbox)
                .font(.system(size: 14))
                .disabled(!(filter == .all || filter == .events))
                .help("List the events from the earliest year to the latest, instead of the biggest first")
                .accessibilityIdentifier("steward.event.byYear")

            Spacer(minLength: 8)

            if snapshot.queue.isBuilt {
                Text(StewardFreshness.events(placed: snapshot.queue.placedClips, of: snapshot.queue.placeableClips))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .help("An event is found from a clip's date, a family birthday near it, or a word in its file or folder name. Clips with no trustworthy date can still be placed by name.")
                    .accessibilityIdentifier("steward.event.coverage")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
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
                        // A new card starts with its per-clip reasons closed.
                        .id(c.id)
                }
                .frame(maxWidth: .infinity)
                Divider()
                nextUp(after: c)
                    .frame(width: 340)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.queue.isBuilt
                     ? StewardPaneWords.emptyLine(showSkipped: showSkipped, filter: filter, anythingAtAll: !active.isEmpty)
                     : "Looking through the catalog…")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                if snapshot.queue.isBuilt {
                    Text(StewardFreshness.events(placed: snapshot.queue.placedClips, of: snapshot.queue.placeableClips))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
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
                                if c.kind == .event || c.kind == .unlabelledDay, !c.detail.isEmpty {
                                    Text(c.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
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
                              report: coverage.report, now: Date(),
                              placedClips: snapshot.queue.placedClips, placeableClips: snapshot.queue.placeableClips)
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
                // The Catalog's banner names the event; the log line above does not.
                model.showInCatalog(focus: Set(c.recordIDs),
                                    label: c.kind == .event || c.kind == .unlabelledDay ? c.title : c.kind.chip)
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
            reviewCopies: {
                guard !c.copyReviewIDs.isEmpty else { return }
                note(.acted, c, action: "Review the copies (\(c.copyReviewIDs.count.formatted()))")
                model.showInCatalog(focus: Set(c.copyReviewIDs), label: "Copies in \(c.title)")
            },
            compareFootage: {
                guard let center = fileOpsCenterReference else { return }
                note(.acted, c, action: "Compare these")
                // The run's title names the kind and the count — never an
                // event's title (log lines carry kinds and counts only).
                guard model.startFootageSpectrum(ids: c.recordIDs, title: "\(c.kind.chip) — \(c.recordIDs.count) clips",
                                                 preferredFirst: c.likelyOriginalID, center: center,
                                                 source: "Triage suggestions") != nil else { return }
                FootageSpectrumWindowOpener.open(using: openWindow, source: "triage-suggestions")
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
        counts = StewardPaneWords.counts(parts.active)
        rearrange()
    }

    /// Narrow and order what is on screen (≤ a few hundred rows).
    private func rearrange() {
        visible = StewardCaseBuilder.arrange(showSkipped ? skipped : active, filter: filter, eventsByYear: eventsByYear)
        // Focus is sticky: it moves only when its card is gone.
        if focusedID == nil || !visible.contains(where: { $0.id == focusedID }) {
            focusedID = visible.first?.id
        }
        noteShownIfChanged()
    }

    /// The person changed the filter or the order: one line, then re-list.
    private func viewChanged() {
        rearrange()
        let line = StewardLog.viewLine(filter: filter, eventsByYear: eventsByYear, listed: visible.count)
        model.log(line)
        appLog.write(line)
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

/// The pane's own sentences that depend on what is listed (pure; tested).
enum StewardPaneWords {
    struct Counts: Sendable, Equatable {
        var events = 0
        var days = 0
        var tidy = 0
    }

    nonisolated static func counts(_ cases: [StewardCase]) -> Counts {
        var c = Counts()
        for item in cases {
            switch item.kind {
            case .event: c.events += 1
            case .unlabelledDay: c.days += 1
            default: c.tidy += 1
            }
        }
        return c
    }

    /// "42 events · 6 days to name · 31 tidy suggestions" — content first.
    nonisolated static func countLine(events: Int, days: Int, tidy: Int) -> String {
        var parts: [String] = []
        if events > 0 { parts.append("\(events.formatted()) event\(events == 1 ? "" : "s")") }
        if days > 0 { parts.append("\(days.formatted()) day\(days == 1 ? "" : "s") to name") }
        if tidy > 0 { parts.append("\(tidy.formatted()) tidy suggestion\(tidy == 1 ? "" : "s")") }
        return parts.isEmpty ? "nothing to show right now" : parts.joined(separator: " · ")
    }

    nonisolated static func emptyLine(showSkipped: Bool, filter: StewardCaseBuilder.Filter, anythingAtAll: Bool) -> String {
        if showSkipped { return filter == .all ? "Nothing is skipped." : "Nothing of this kind is skipped." }
        if anythingAtAll, filter != .all { return "Nothing of this kind right now — choose All to see the rest." }
        return "No events found yet, and nothing to tidy right now."
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
