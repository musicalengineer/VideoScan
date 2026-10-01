// ResearchPersonSheet.swift
// The Research pane (Rick 2026-08-29): right-click a Family Tree card →
// "Research Person…" → this sheet, keyed by the person's FamilySearch ID.
// Header with name + vitals from the tree, the query plan the sources will
// run (so nothing leaves the machine unseen), Run/Cancel, then the findings
// list with a verdict per row and a lore field, and "Tell Hallie" which
// writes the CONFIRMED findings into the CyberBrain with their citations.
//
// Findings render in a `List` (lazy rows): 500 findings cost the same to
// show as 5. Every network call runs off the main actor in a cancellable
// Task; verdict/lore edits save the small dossier JSON at once (verdict)
// or on commit (lore). Log lines are counts only.
//
// C++ readers: `@MainActor` ≈ "this must run on the UI thread";
// `ObservableObject` + `@Published` ≈ a model whose setters notify the
// view; `Task { … }` ≈ spawning a coroutine that we keep a handle to so
// Cancel can stop it.

import Combine
import SwiftUI
import VideoScanCore

/// What the tree view presents; `Identifiable` for `.sheet(item:)`.
struct ResearchTarget: Identifiable, Equatable {
    let subject: ResearchSubject
    var id: String { subject.key }
}

@MainActor
final class ResearchPersonModel: ObservableObject {
    let subject: ResearchSubject
    @Published private(set) var plan: ResearchQueryPlan
    @Published private(set) var dossier: ResearchDossier
    @Published private(set) var isRunning = false
    @Published private(set) var statusLine = ""
    @Published var errorMessage: String?
    /// Lore drafts by finding id, committed on submit/blur. Changed only
    /// through `editLore` (the user typing) or by following the disk.
    @Published private(set) var loreDrafts: [String: String] = [:]
    /// Findings whose draft the user has typed into since it last matched
    /// the disk (codex review #18 F2). Only these are ever committed; every
    /// other draft follows the file, so an untouched field can never write
    /// a stale copy over lore another pane saved meanwhile.
    /// (C++: a dirty-bit set beside a cache.)
    private var editedLore: Set<String> = []

    private let store: ResearchStore
    private let fetcher: any ResearchFetcher
    private let speakerName: String
    private let record: (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt
    private let makeSources: (any ResearchFetcher) -> [any ResearchSource]
    private let log: @Sendable (String) -> Void
    private let now: () -> Date
    private var runTask: Task<Void, Never>?

    init(subject: ResearchSubject,
         store: ResearchStore,
         fetcher: any ResearchFetcher,
         speakerName: String,
         record: @escaping (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt,
         sources: ((any ResearchFetcher) -> [any ResearchSource])? = nil,
         log: @escaping @Sendable (String) -> Void = { appLog.write($0) },
         now: @escaping () -> Date = { Date() }) {
        self.subject = subject
        self.store = store
        self.fetcher = fetcher
        self.speakerName = speakerName
        self.record = record
        // Default: every source, including the record adapters that read
        // this subject's places and years (GH #230 Phase B).
        // Wikipedia's vetting writes one counts-only line to the same log.
        self.makeSources = sources ?? { ResearchRunner.sources(fetcher: $0, subject: subject, log: log) }
        self.log = log
        self.now = now
        self.plan = ResearchQueryPlan.build(subject: subject, now: now())
        self.dossier = ResearchDossier(subject: subject)
        self.dossier.plan = plan
    }

    var findings: [ResearchFinding] { dossier.findings }
    /// The two groups the list shows (≤ 500 findings: a cheap filter).
    var mainFindings: [ResearchFinding] { dossier.mainFindings }
    var nearMissFindings: [ResearchFinding] { dossier.nearMissFindings }
    var confirmedUntoldCount: Int { dossier.untoldConfirmed.count }
    var toldCount: Int { dossier.findings.filter { $0.toldItemID != nil }.count }

    /// Load a saved dossier (verdicts, lore, last findings) for this key.
    func load() {
        do {
            if let saved = try store.loadDossier(key: subject.key) {
                dossier = saved
                if let savedPlan = saved.plan { plan = savedPlan }
                loreDrafts = Dictionary(uniqueKeysWithValues: saved.findings.map { ($0.id, $0.lore) })
                editedLore.removeAll()
                statusLine = saved.lastRunAt.map { "Last run \(Self.shortDate($0)) · \(saved.findings.count) findings" }
                    ?? "Not run yet"
            } else {
                statusLine = "Not run yet"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Run every source. `refresh` bypasses the page cache.
    func run(refresh: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        statusLine = refresh ? "Searching (fresh)…" : "Searching…"
        let plan = self.plan
        let caching = CachingResearchFetcher(inner: fetcher, store: store,
                                             subjectKey: subject.key, bypassCache: refresh)
        let sources = makeSources(caching)
        let log = self.log
        let countsSummary = plan.countsSummary
        log("Research: run started (\(countsSummary), \(sources.count) sources)")
        runTask = Task { [weak self] in
            // Off-main: the sources do their own network work; only the
            // merge below touches the model.
            let outcomes = await ResearchRunner.run(plan: plan, sources: sources, log: log)
            guard let self, !Task.isCancelled else {
                self?.finishCancelled()
                return
            }
            self.apply(outcomes)
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    private func finishCancelled() {
        isRunning = false
        statusLine = "Cancelled"
        log("Research: run cancelled")
    }

    private func apply(_ outcomes: [ResearchRunner.SourceOutcome]) {
        let plan = self.plan
        let fresh = outcomes.flatMap(\.findings)
        let at = now()
        mutate { dossier in
            dossier.plan = plan
            dossier.merge(fresh: fresh, at: at)
            for outcome in outcomes { dossier.sourceStatus[outcome.kind.rawValue] = outcome.status }
        }
        isRunning = false
        runTask = nil
        let failed = outcomes.filter { $0.failure != nil }.count
        let nearMisses = dossier.nearMissFindings.count
        statusLine = "\(dossier.findings.count - nearMisses) findings"
            + (nearMisses == 0 ? "" : " (+\(nearMisses) also turned up)")
            + " from \(outcomes.count - failed) of \(outcomes.count) sources"
        log("Research: run finished (\(dossier.findings.count) findings, \(failed) sources failed)")
    }

    func setVerdict(_ verdict: ResearchVerdict, for id: String) {
        mutate { $0.setVerdict(verdict, for: id) }
    }

    /// The user typed in a lore field: the draft is now theirs until it is
    /// committed, and a refresh from disk leaves it alone.
    func editLore(_ text: String, for id: String) {
        loreDrafts[id] = text
        editedLore.insert(id)
    }

    /// Commit the draft for one finding (Return in the field / focus lost).
    /// A draft the user never edited is not committed: it is the disk's own
    /// value, possibly older than what is on disk now.
    func commitLore(for id: String) {
        guard editedLore.contains(id) else { return }
        let draft = loreDrafts[id] ?? ""
        if dossier.findings.first(where: { $0.id == id })?.lore != draft {
            // A failed save keeps the draft marked edited, so the next
            // commit (or Tell Hallie) tries again instead of dropping it.
            guard mutate({ $0.setLore(draft, for: id) }) else { return }
        }
        editedLore.remove(id)
    }

    /// Confirmed, not-yet-told findings → CyberBrain attestations. Each is
    /// written on its own so one failure does not lose the others. The list
    /// is read from DISK, so a finding another window already told is not
    /// told again (and the CyberBrain writer itself refuses to duplicate
    /// the same passage — QA 2026-10-01 P3-5).
    @discardableResult
    func tellHallie() -> Int {
        for id in editedLore.sorted() { commitLore(for: id) }   // only what the user typed
        mutate { _ in }                                   // pick up other writers' changes
        var told = 0
        var failures: [String] = []
        for finding in dossier.untoldConfirmed {
            do {
                let testimony = try ResearchAttestation.testimony(
                    for: finding, subject: subject, speakerName: speakerName, date: now())
                let receipt = try record(testimony)
                mutate { $0.markTold(id: finding.id, itemID: receipt.itemID) }
                told += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        log("Research: told Hallie \(told) findings (\(failures.count) failed)")
        if failures.isEmpty {
            statusLine = told == 0 ? "Nothing confirmed to tell yet"
                : "Told Hallie \(told) confirmed \(told == 1 ? "finding" : "findings")"
        } else {
            errorMessage = "Told \(told); couldn't save \(failures.count): " + failures.joined(separator: "; ")
        }
        return told
    }

    /// Apply one change to the dossier ON DISK (under the store's per-key
    /// lock: read now → change → write), then show the result. Never saves
    /// this pane's in-memory copy over someone else's newer file — the
    /// "I found a record" filer or a second window (QA 2026-10-01 P2-1).
    /// On a store error the change is still shown here, with the error.
    /// Returns whether the change reached the disk.
    @discardableResult
    private func mutate(_ change: (inout ResearchDossier) -> Void) -> Bool {
        let subject = self.subject
        var saved = true
        do {
            let updated = try store.update(key: subject.key) { onDisk in
                var working = onDisk ?? ResearchDossier(subject: subject)
                change(&working)
                // A pane that has changed nothing never creates a file.
                if onDisk != nil || working != ResearchDossier(subject: subject) { onDisk = working }
            }
            if let updated { dossier = updated }
        } catch {
            change(&dossier)
            errorMessage = error.localizedDescription
            saved = false
        }
        // Untouched drafts follow the dossier as it is NOW; the user's own
        // unsaved typing is left alone (codex review #18 F2).
        for finding in dossier.findings where !editedLore.contains(finding.id) {
            loreDrafts[finding.id] = finding.lore
        }
        return saved
    }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }
}

// MARK: - View

struct ResearchPersonSheet: View {
    @StateObject private var model: ResearchPersonModel
    let onClose: () -> Void
    /// "Also turned up — probably not this person" starts collapsed.
    @State private var showNearMisses = false

    init(model: ResearchPersonModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            planSection
            Divider()
            findingsList
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .onAppear { model.load() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Research: \(model.subject.name)")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    if !model.subject.vitals.isEmpty {
                        Text(model.subject.vitals)
                    }
                    if let place = model.subject.birthPlace, !place.isEmpty {
                        Text("b. \(place)")
                    }
                    Text(model.subject.isFamilySearchKey ? "FSID \(model.subject.key)" : "key \(model.subject.key)")
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Query plan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Run") { model.run() }
                        .masterOnly()
                        .keyboardShortcut(.defaultAction)
                    Button("Run (fresh)") { model.run(refresh: true) }
                        .masterOnly()
                        .help("Ignore cached pages and fetch again")
                }
            }
            planLine("Names", model.plan.nameVariants.joined(separator: " · "))
            planLine("Years", "\(model.plan.yearFrom)–\(model.plan.yearTo)"
                     + (model.plan.stateHint.map { "  (state: \($0))" } ?? ""))
            planLine("Places", model.plan.placeTokens.isEmpty ? "none in the tree" : model.plan.placeTokens.joined(separator: " · "))
            planLine("Sources", ResearchRunner.runKinds
                .map { kind in
                    let status = model.dossier.sourceStatus[kind.rawValue]
                    return status.map { "\(kind.label): \($0)" } ?? kind.label
                }
                .joined(separator: " · "))
            HStack {
                Text(model.statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                if let error = model.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
        .padding(14)
    }

    private func planLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private var findingsList: some View {
        Group {
            if model.findings.isEmpty {
                VStack {
                    Spacer()
                    Text(model.isRunning ? "Searching…" : "No findings yet. Press Run.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                let nearMisses = model.nearMissFindings
                List {
                    ForEach(model.mainFindings) { finding in row(finding) }
                    if !nearMisses.isEmpty {
                        // Rick 2026-10-01: keep near-misses for serendipity,
                        // but apart from the findings and folded away.
                        Section {
                            if showNearMisses {
                                ForEach(nearMisses) { finding in row(finding) }
                            }
                        } header: {
                            Button {
                                showNearMisses.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: showNearMisses ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Also turned up — probably not this person (\(nearMisses.count))")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Search hits that failed a check: not a person, a different name, a different era, or couldn't be checked. Kept in case one is useful; nothing here goes to Hallie unless you confirm it.")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ finding: ResearchFinding) -> some View {
        ResearchFindingRow(
            finding: finding,
            lore: Binding(
                get: { model.loreDrafts[finding.id] ?? finding.lore },
                set: { model.editLore($0, for: finding.id) }),
            onVerdict: { model.setVerdict($0, for: finding.id) },
            onCommitLore: { model.commitLore(for: finding.id) })
        .listRowSeparator(.visible)
    }

    private var footer: some View {
        HStack {
            Text("\(model.findings.count - model.nearMissFindings.count) findings"
                 + (model.nearMissFindings.isEmpty ? "" : " · \(model.nearMissFindings.count) also turned up")
                 + " · \(model.findings.filter { $0.verdict == .confirmed }.count) confirmed · \(model.toldCount) told")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Tell Hallie (\(model.confirmedUntoldCount) confirmed)") {
                model.tellHallie()
            }
            .masterOnly()
            .disabled(model.confirmedUntoldCount == 0)
            .help("Write the confirmed findings, with their citations, into the family knowledge file Hallie answers from")
        }
        .padding(14)
    }
}

private struct ResearchFindingRow: View {
    let finding: ResearchFinding
    @Binding var lore: String
    let onVerdict: (ResearchVerdict) -> Void
    let onCommitLore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(finding.source.label)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.25))
                    .clipShape(Capsule())
                if let screening = finding.screening {
                    // "Likely match" in green; a near-miss's plain reason
                    // ("a film", "surname only", …) in grey.
                    Text(screening.isNearMiss ? screening.reason : "Likely match")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((screening.isNearMiss ? Color.gray : Color.green).opacity(0.25))
                        .clipShape(Capsule())
                }
                Text(finding.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let date = finding.date {
                    Text(date).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: finding.url) {
                    Link("Open", destination: url).font(.system(size: 11))
                }
                if finding.toldItemID != nil {
                    Image(systemName: "checkmark.bubble").foregroundStyle(.green)
                        .help("Told to Hallie")
                }
            }
            Text(finding.excerpt)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { finding.verdict }, set: { onVerdict($0) })) {
                    ForEach(ResearchVerdict.allCases, id: \.self) { verdict in
                        Text(verdict.label).tag(verdict)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .masterOnly()
                .disabled(finding.toldItemID != nil)
                TextField("Lore (what the family knows about this)", text: $lore)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(onCommitLore)
                    .masterOnly()
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeColor: Color {
        switch finding.source {
        case .chroniclingAmerica: return .orange
        case .findAGrave: return .gray
        case .wikipedia, .wikidata: return .blue
        case .web: return .teal
        case .irishCensus: return .green
        case .tnaDiscovery: return .brown
        case .recordFinder: return .purple
        }
    }
}
