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
    /// Lore drafts by finding id, committed on submit/blur.
    @Published var loreDrafts: [String: String] = [:]

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
         sources: @escaping (any ResearchFetcher) -> [any ResearchSource] = ResearchRunner.sources,
         log: @escaping @Sendable (String) -> Void = { appLog.write($0) },
         now: @escaping () -> Date = { Date() }) {
        self.subject = subject
        self.store = store
        self.fetcher = fetcher
        self.speakerName = speakerName
        self.record = record
        self.makeSources = sources
        self.log = log
        self.now = now
        self.plan = ResearchQueryPlan.build(subject: subject, now: now())
        self.dossier = ResearchDossier(subject: subject)
        self.dossier.plan = plan
    }

    var findings: [ResearchFinding] { dossier.findings }
    var confirmedUntoldCount: Int { dossier.untoldConfirmed.count }
    var toldCount: Int { dossier.findings.filter { $0.toldItemID != nil }.count }

    /// Load a saved dossier (verdicts, lore, last findings) for this key.
    func load() {
        do {
            if let saved = try store.loadDossier(key: subject.key) {
                dossier = saved
                if let savedPlan = saved.plan { plan = savedPlan }
                loreDrafts = Dictionary(uniqueKeysWithValues: saved.findings.map { ($0.id, $0.lore) })
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
        var updated = dossier
        updated.plan = plan
        let fresh = outcomes.flatMap(\.findings)
        updated.merge(fresh: fresh, at: now())
        for outcome in outcomes { updated.sourceStatus[outcome.kind.rawValue] = outcome.status }
        dossier = updated
        for finding in updated.findings where loreDrafts[finding.id] == nil {
            loreDrafts[finding.id] = finding.lore
        }
        isRunning = false
        runTask = nil
        let failed = outcomes.filter { $0.failure != nil }.count
        statusLine = "\(updated.findings.count) findings from \(outcomes.count - failed) of \(outcomes.count) sources"
        log("Research: run finished (\(updated.findings.count) findings, \(failed) sources failed)")
        save()
    }

    func setVerdict(_ verdict: ResearchVerdict, for id: String) {
        dossier.setVerdict(verdict, for: id)
        save()
    }

    /// Commit the draft for one finding (Return in the field / focus lost).
    func commitLore(for id: String) {
        let draft = loreDrafts[id] ?? ""
        guard dossier.findings.first(where: { $0.id == id })?.lore != draft else { return }
        dossier.setLore(draft, for: id)
        save()
    }

    /// Confirmed, not-yet-told findings → CyberBrain attestations. Each is
    /// written on its own so one failure does not lose the others.
    @discardableResult
    func tellHallie() -> Int {
        for id in dossier.findings.map(\.id) { commitLore(for: id) }
        var told = 0
        var failures: [String] = []
        for finding in dossier.untoldConfirmed {
            do {
                let testimony = try ResearchAttestation.testimony(
                    for: finding, subject: subject, speakerName: speakerName, date: now())
                let receipt = try record(testimony)
                dossier.markTold(id: finding.id, itemID: receipt.itemID)
                told += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        save()
        log("Research: told Hallie \(told) findings (\(failures.count) failed)")
        if failures.isEmpty {
            statusLine = told == 0 ? "Nothing confirmed to tell yet"
                : "Told Hallie \(told) confirmed \(told == 1 ? "finding" : "findings")"
        } else {
            errorMessage = "Told \(told); couldn't save \(failures.count): " + failures.joined(separator: "; ")
        }
        return told
    }

    private func save() {
        do {
            try store.saveDossier(dossier)
        } catch {
            errorMessage = error.localizedDescription
        }
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
            planLine("Sources", ResearchSourceKind.allCases
                .filter { $0 != .wikidata }
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
                List(model.findings) { finding in
                    ResearchFindingRow(
                        finding: finding,
                        lore: Binding(
                            get: { model.loreDrafts[finding.id] ?? finding.lore },
                            set: { model.loreDrafts[finding.id] = $0 }),
                        onVerdict: { model.setVerdict($0, for: finding.id) },
                        onCommitLore: { model.commitLore(for: finding.id) })
                    .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.findings.count) findings · \(model.findings.filter { $0.verdict == .confirmed }.count) confirmed · \(model.toldCount) told")
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
                .disabled(finding.toldItemID != nil || ViewerModeCenter.shared.isViewer)
                TextField("Lore (what the family knows about this)", text: $lore)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(onCommitLore)
                    .disabled(ViewerModeCenter.shared.isViewer)
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
        }
    }
}
