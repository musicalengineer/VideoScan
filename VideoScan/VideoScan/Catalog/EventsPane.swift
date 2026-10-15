// EventsPane.swift
// Triage ▸ Events — the page (docs/design/events_design.md §5;
// docs/design/events_v1_plan_2026_10_14.md §5). One question: "Which
// recordings belong to the same family memory?"
//
//   Events                                   Checked 14:05   [Refresh]
//   Which recordings belong to the same family memory?
//   [To review | Confirmed]   All · Birthday 12 · Christmas 9 · …
//   ┌ Same occasion, or different years? ───────────────────────────┐
//   │ Christmas · 1996 (camera)  vs  Christmas · 1999 (your date)    │
//   │ in /Volumes/Tapes/Xmas          [Same occasion] [Different]    │
//   └────────────────────────────────────────────────────────────────┘
//   Birthday · Jun 5, 1998 (your date)         seen and said · 3 recordings
//   Birthday                                   [Confirm] [Dismiss] [Details…]
//   …
//   Left out: 1,204 recordings — no event words …
//
// PERF: the view reads ONLY `EventsStore` — the plan (built off-main by
// `VideoScanModel.buildEventsPlan`), the filtered lists and the cached
// numbers. No O(records) work in any body. (For Rick: `EventsStore` ≈ a
// small observer-pattern holder; SwiftUI redraws the page when one of its
// @Published members is replaced.)

import Combine
import SwiftUI
import VideoScanCore

// MARK: - Store

@MainActor
final class EventsStore: ObservableObject {
    /// The app's one store (one catalog, one Triage tab).
    static let shared = EventsStore()

    enum Lane: String, CaseIterable, Identifiable {
        case toReview = "To review"
        case confirmed = "Confirmed"
        var id: String { rawValue }
    }

    struct Filter: Equatable {
        var category: String?
        var lane: Lane = .toReview
    }

    /// What the page and the sidebar show, cached whenever the plan or
    /// the filter changes (never recomputed in a body).
    struct Numbers: Equatable {
        var toReview = 0
        var questions = 0
        var confirmed = 0
        var byCategory: [String: Int] = [:]
        var leftOut = 0
    }

    let decisions: EventsDecisionStore

    @Published private(set) var plan: EventsPlan?
    @Published private(set) var builtAt: Date?
    @Published private(set) var isBuilding = false
    @Published var filter = Filter() { didSet { refilter() } }
    @Published private(set) var numbers = Numbers()
    @Published private(set) var shownSuggestions: [EventSuggestion] = []
    @Published private(set) var shownConfirmed: [ConfirmedEvent] = []
    /// O(1) lookups for the detail sheet, rebuilt once per plan.
    private(set) var suggestionByKey: [String: EventSuggestion] = [:]
    private(set) var confirmedByID: [UUID: ConfirmedEvent] = [:]
    /// Every confirmed event, newest first — the sheet's Merge with… menu
    /// (precomputed once per plan; the menu only greys out the event itself).
    @Published private(set) var mergeCandidates: [ConfirmedEvent] = []

    /// What the page says at the top: the store's refusal, else its last
    /// failed save (`EventsDecisionStore.problem`).
    var readOnlyReason: String? { decisions.problem }
    /// The cards' Confirm / Dismiss gate.
    var isReadOnly: Bool { decisions.isReadOnly }

    /// A refresh asked for while one was running (a "different occasions"
    /// mark needs the runs rebuilt): run once more when this one lands.
    private var refreshQueued = false
    private var decisionsWatch: AnyCancellable?

    init(decisions: EventsDecisionStore = .shared) {
        self.decisions = decisions
        // A failed save (or a recovery) changes what the page says without
        // a new plan: carry the reason over on the store's one signal.
        decisionsWatch = decisions.$revision.dropFirst().sink { [weak self] _ in self?.carryProblem() }
    }

    /// Rebuild the plan off the main actor; one build at a time. Returns
    /// the build's task (tests await it; the page does not). A call while
    /// a build runs is remembered and honoured when it lands.
    @discardableResult
    func refresh(model: VideoScanModel) -> Task<Void, Never>? {
        guard !isBuilding else {
            refreshQueued = true
            return nil
        }
        isBuilding = true
        decisions.note = { [weak model] line in model?.eventsNote(line) }
        return Task { [weak self] in
            guard let self else { return }
            if !self.decisions.hasLoaded, case .readOnly(let why) = await self.decisions.load() {
                model.eventsNote("decisions file is read-only — \(why)")
            }
            let plan = await model.buildEventsPlan(decisions: self.decisions.snapshot())
            self.install(plan)
            self.builtAt = Date()
            self.isBuilding = false
            let stats = VideoScanModel.eventsStats(plan: plan, decisions: self.decisions.snapshot(), now: Date())
            _ = await EventsStats.write(stats, to: self.decisions.statsURL)
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh(model: model)
            }
        }
    }

    private func install(_ plan: EventsPlan) {
        var p = plan
        p.readOnlyReason = decisions.problem
        self.plan = p
        suggestionByKey = Dictionary(p.suggestions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        confirmedByID = Dictionary(p.confirmed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        mergeCandidates = p.confirmed
        refilter()
    }

    /// The store's problem line changed (a save failed or recovered):
    /// re-publish the plan with the new words, nothing else.
    private func carryProblem() {
        guard var p = plan, p.readOnlyReason != decisions.problem else { return }
        p.readOnlyReason = decisions.problem
        plan = p
    }

    private func refilter() {
        guard let plan else {
            shownSuggestions = []
            shownConfirmed = []
            numbers = Numbers()
            return
        }
        if let category = filter.category {
            shownSuggestions = plan.suggestions.filter { $0.categories.contains(category) }
            shownConfirmed = plan.confirmed.filter { $0.categories.contains(category) }
        } else {
            shownSuggestions = plan.suggestions
            shownConfirmed = plan.confirmed
        }
        var n = Numbers()
        n.toReview = plan.suggestions.count + plan.questions.count
        n.questions = plan.questions.count
        n.confirmed = plan.confirmed.count
        for s in plan.suggestions { for c in s.categories { n.byCategory[c, default: 0] += 1 } }
        n.leftOut = plan.leftOut.values.reduce(0, +)
        numbers = n
    }

    /// Every mutation: one store write (saved off-main by the store) and
    /// the plan re-read against the new decisions — never a rebuild.
    private func reapply() {
        guard let plan else { return }
        install(plan.reapplying(decisions.snapshot()))
    }

    // MARK: Decisions on suggestions

    func confirm(_ s: EventSuggestion, name: String? = nil) {
        let members = s.members.filter { $0.state != .rejected }.map(\.range)
        guard decisions.confirm(name: name ?? s.name, categories: s.categories, members: members) != nil else { return }
        reapply()
    }

    func dismiss(_ s: EventSuggestion) {
        guard decisions.record(.suggestionDismissed(key: s.key, facts: s.facts)) else { return }
        reapply()
    }

    /// "Not this one": the suggestion's categories are said no to for that
    /// recording (Q4 default: one button; the store keeps the distinction).
    func reject(_ m: EventMember, in s: EventSuggestion) {
        guard decisions.record(s.categories.map { .categoryRejected(range: m.range, category: $0) }) else { return }
        reapply()
    }

    /// "These are different occasions" on a suggestion spanning several
    /// folders: each folder's first recording is kept apart from the
    /// others' — one batch, one save. Needs a full rebuild (runs change):
    /// refreshed now, or queued behind the build that is running.
    /// False when there is only one folder (nothing to tell apart).
    @discardableResult
    func markDifferentOccasions(in s: EventSuggestion, model: VideoScanModel) -> Bool {
        let reps = Dictionary(grouping: s.members, by: { ($0.path as NSString).deletingLastPathComponent })
            .values.compactMap { $0.first?.range }.sorted { $0.contentKey < $1.contentKey }
        guard reps.count > 1 else { return false }
        var pairs: [EventDecision] = []
        for (i, a) in reps.enumerated() {
            for b in reps[(i + 1)...] { pairs.append(.differentOccasions(a: a, b: b)) }
        }
        guard decisions.record(pairs) else { return false }
        refresh(model: model)
        return true
    }

    func answer(_ q: EventsQuestion, sameOccasion: Bool) {
        if sameOccasion {
            guard let a = suggestionByKey[q.a], let b = suggestionByKey[q.b] else { return }
            let categories = a.categories + b.categories.filter { !a.categories.contains($0) }
            let members = (a.members + b.members).filter { $0.state != .rejected }.map(\.range)
            guard decisions.confirm(name: a.name, categories: categories, members: members) != nil else { return }
        } else {
            guard decisions.record(.differentOccasions(a: q.aRange, b: q.bRange)) else { return }
        }
        reapply()
    }

    // MARK: Decisions on confirmed events

    func renameEvent(_ e: ConfirmedEvent, to name: String) {
        guard decisions.renameEvent(e.id, to: name) else { return }
        reapply()
    }

    func dismiss(_ e: ConfirmedEvent) {
        guard decisions.setState(e.id, .dismissed) else { return }
        reapply()
    }

    func setMember(_ m: EventMember, of e: ConfirmedEvent, accepted: Bool) {
        guard decisions.setMember(event: e.id, range: m.range, verdict: accepted ? .accepted : .rejected) else { return }
        reapply()
    }

    func split(_ e: ConfirmedEvent, members: [EventMember], name: String) {
        guard decisions.split(e.id, ranges: members.map(\.range), name: name) != nil else { return }
        reapply()
    }

    func merge(_ e: ConfirmedEvent, into target: ConfirmedEvent) {
        guard decisions.merge(e.id, into: target.id) else { return }
        reapply()
    }
}

// MARK: - Words (pure — the tests pin them)

enum EventsWords {
    static let title = "Events"
    static let question = "Which recordings belong to the same family memory?"
    static let sameOccasion = "Same occasion, or different years?"
    static let sameOccasionYes = "Same occasion"
    static let sameOccasionNo = "Different occasions"
    static let confirm = "Confirm"
    static let dismiss = "Dismiss"
    static let details = "Details…"
    static let looking = "Looking for family memories…"
    static let nothingToReview = "Nothing to review — every suggestion has your answer."
    static let nothingConfirmed = "No confirmed events yet. Confirm a suggestion and it stays here."
    static let noWordsYet = "No event words yet. Captions and transcripts arrive from the Dossier and Whisper cyclers; file names, folder names and dates count too."
    static let differentOccasions = "These are different occasions"
    static let mergeWith = "Merge with…"
    static let rename = "Rename"
    static let open = "Open"
    static let notThisOne = "Not this one"
    static let keep = "Keep"
    static let coveredNote = "Grouping never marks a recording covered or safe to remove."

    static func readOnly(_ why: String) -> String {
        "Your decisions can't be saved right now — \(why). You can still look."
    }

    static func recordings(_ n: Int) -> String {
        n == 1 ? "1 recording" : "\(n.formatted()) recordings"
    }

    /// "seen and said · 3 recordings"; "no words of its own · 1 recording".
    static func summary(strength: EventEvidenceStrength?, members: Int) -> String {
        "\(strength?.words ?? "no words of its own") · \(recordings(members))"
    }

    static func copies(_ n: Int) -> String? {
        n > 1 ? "\(n) copies" : nil
    }

    static func leftOut(_ total: Int) -> String {
        "Left out: \(recordings(total))"
    }

    /// The sidebar's count: "N to review", "" until the first plan lands.
    static func sidebarCount(_ n: EventsStore.Numbers?) -> String {
        guard let n else { return "" }
        return "\(n.toReview.formatted()) to review"
    }

    static func checked(_ at: Date) -> String {
        "Checked \(at.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - The page

struct EventsPane: View {
    let model: VideoScanModel
    @ObservedObject var store: EventsStore
    @State private var detail: EventsDetailSubject?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            if let plan = store.plan {
                ScrollView { content(plan).padding(14) }
            } else {
                ProgressView(EventsWords.looking).padding(20)
                Spacer()
            }
        }
        .onAppear { if store.plan == nil { store.refresh(model: model) } }
        .sheet(item: $detail) { subject in
            EventDetailSheet(subject: subject, model: model, store: store)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(EventsWords.title).font(.title3.weight(.semibold))
                Text(EventsWords.question).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let at = store.builtAt {
                Text(EventsWords.checked(at)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Refresh") { store.refresh(model: model) }
                .disabled(store.isBuilding)
                .accessibilityIdentifier("events.refresh")
        }
    }

    @ViewBuilder
    private func content(_ plan: EventsPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let why = plan.readOnlyReason { readOnlyBox(why) }
            filters
            if store.filter.lane == .toReview {
                if !plan.questions.isEmpty { questionsStrip(plan.questions) }
                suggestionsList
            } else {
                confirmedList
            }
            footer(plan)
        }
    }

    private func readOnlyBox(_ why: String) -> some View {
        Text(EventsWords.readOnly(why))
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .accessibilityIdentifier("events.readOnly")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $store.filter.lane) {
                ForEach(EventsStore.Lane.allCases) { lane in
                    Text(lane == .toReview ? "\(lane.rawValue) (\(store.numbers.toReview))" : "\(lane.rawValue) (\(store.numbers.confirmed))")
                        .tag(lane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(nil, title: "All")
                    ForEach(EventCategory.all, id: \.name) { c in
                        chip(c.name, title: "\(c.name) \(store.numbers.byCategory[c.name] ?? 0)")
                    }
                }
            }
        }
    }

    private func chip(_ category: String?, title: String) -> some View {
        let on = store.filter.category == category
        return Button(title) { store.filter.category = category }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: on ? .semibold : .regular))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
    }

    private func questionsStrip(_ questions: [EventsQuestion]) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(EventsWords.sameOccasion).font(.system(size: 13, weight: .semibold))
            ForEach(questions) { q in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(q.aWords)  vs  \(q.bWords)").font(.system(size: 12))
                        Text("in \(q.folder)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(EventsWords.sameOccasionYes) { store.answer(q, sameOccasion: true) }
                    Button(EventsWords.sameOccasionNo) { store.answer(q, sameOccasion: false) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
        .accessibilityIdentifier("events.questions")
    }

    @ViewBuilder
    private var suggestionsList: some View {
        if store.shownSuggestions.isEmpty {
            Text(store.numbers.toReview == 0 && (store.plan?.witnessesWithEvidence ?? 0) == 0
                 ? EventsWords.noWordsYet : EventsWords.nothingToReview)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(store.shownSuggestions) { s in
                    EventCardRow(suggestion: s, isReadOnly: store.isReadOnly,
                                 onConfirm: { store.confirm(s) },
                                 onDismiss: { store.dismiss(s) },
                                 onDetails: { detail = .suggestion(s.key) })
                }
            }
        }
    }

    @ViewBuilder
    private var confirmedList: some View {
        if store.shownConfirmed.isEmpty {
            Text(EventsWords.nothingConfirmed).font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(store.shownConfirmed) { e in
                    ConfirmedCardRow(event: e, onDetails: { detail = .confirmed(e.id) })
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ plan: EventsPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.numbers.leftOut > 0 {
                DisclosureGroup(EventsWords.leftOut(store.numbers.leftOut)) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(plan.leftOut.sorted { $0.value > $1.value }, id: \.key) { line in
                            Text("\(line.value.formatted()) — \(line.key.words)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 12))
            }
            Text(EventsWords.coveredNote).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cards

struct EventCardRow: View {
    let suggestion: EventSuggestion
    /// The store refuses writes (not loaded, a newer file…): the buttons
    /// that would write say so by being disabled; Details… still opens.
    let isReadOnly: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(EventsWords.summary(strength: suggestion.strength, members: suggestion.members.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if suggestion.categories.count > 1 {
                Text(suggestion.categories.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(suggestion.folders.joined(separator: "  ·  ")).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let note = suggestion.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Button(EventsWords.confirm, action: onConfirm).accessibilityIdentifier("events.confirm")
                    .disabled(isReadOnly)
                Button(EventsWords.dismiss, action: onDismiss).accessibilityIdentifier("events.dismiss")
                    .disabled(isReadOnly)
                Button(EventsWords.details, action: onDetails).accessibilityIdentifier("events.details")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}

struct ConfirmedCardRow: View {
    let event: ConfirmedEvent
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(event.dateWords) · \(EventsWords.recordings(event.members.count))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(event.categories.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(EventsWords.details, action: onDetails).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}

// MARK: - Sidebar row

/// Triage's sidebar row for the page. Observes only the store, so a plan
/// landing redraws this row, not TriageView.
struct EventsSidebarRow: View {
    let isSelected: Bool
    let onSelect: () -> Void
    @ObservedObject private var store = EventsStore.shared

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "party.popper").foregroundColor(.purple).frame(width: 18)
                Text(EventsWords.title).lineLimit(1)
                Spacer()
                Text(count).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(isSelected ? 0.16 : 0)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("triage.events")
    }

    /// "N to review", "" until the first plan lands.
    private var count: String {
        EventsWords.sidebarCount(store.plan == nil ? nil : store.numbers)
    }
}
