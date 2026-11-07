// ObservationsWindow.swift — Content Analysis ▸ Observations…: what the
// machine found across many files, in the dossier's three chevrons
// (Technical · Patterns & events · Across the collection), one search across
// every observation, a filter in each chevron, and a hit list that opens the
// file or its dossier (docs/design/file_dossier_view.md Part II).
//
// Machine observations only (Rick 11/06): no catalog field is shown or
// searched; a file name appears only as the link a hit came from. Grey and
// blue, never yellow (DECISIONS 2026-11-03): a machine observation's source
// in blue, a missing reading in grey with the reason, a comparison with
// Rick's own facts in the primary colour and labelled as his.
//
// NO O(records) work in this body: every row and hit comes from the store's
// published report and search (built off the main actor by Core); the tier
// filters run over the rows already on screen (a few hundred).
//
// One door: `ObservationsWindowController.shared.show(model:scope:source:)`
// (the Content Analysis panel, the Realtime window's "See what we learned",
// the catalog row menu). Same NSWindow shape as the Realtime window.
//
// (For Rick: `@StateObject` ≈ the view owns its controller for its lifetime;
// `DisclosureGroup` is the chevron.)

import AppKit
import SwiftUI
import VideoScanCore

struct ObservationsContent: View {

    @ObservedObject var store: ObservationsStore
    @State private var query = ""
    @State private var expanded: Set<FileDossier.Layer>
    @State private var filters: [FileDossier.Layer: String] = [:]
    @State private var selection: ObservationsSearch.Hit.ID?
    @State private var dossierHit: ObservationsSearch.Hit?

    /// Mockup rendering (ImageRenderer draws AppKit-backed controls — TextField,
    /// Button, Table — as "unsupported" blocks): static stand-ins take their place.
    private let mockup: Bool

    /// Rick's call for the dossier (11/05): chevrons start collapsed; here the
    /// statistics open first so the window says something at once.
    init(store: ObservationsStore, expanded: Set<FileDossier.Layer> = [.collection], mockup: Bool = false) {
        self.store = store
        self.mockup = mockup
        _expanded = State(initialValue: expanded)
    }

    /// The tiers without the ScrollView (the mockups: a ScrollView renders blank through ImageRenderer).
    var tiersForMockup: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            if let report = store.report { ForEach(report.tiers) { tier in chevron(tier) } }
            footer
        }
        .padding(16)
    }

    /// The hits as plain rows (the mockups: a Table renders blank through ImageRenderer). Same columns, same words.
    var hitsForMockup: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            if let search = store.search {
                Text("\(search.hits.count.formatted()) hit\(search.hits.count == 1 ? "" : "s") for “\(search.query)”").font(.callout)
                ForEach(search.hits) { hit in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(hit.kind.title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        if let at = hit.at { Text(FileDossierLineView.time(at)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        Text(hit.text).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                        Text(hit.source).foregroundStyle(.blue).frame(width: 200, alignment: .leading).lineLimit(1)
                        Text(hit.filename).frame(width: 200, alignment: .leading).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 3)
                    Divider()
                }
            }
            footer
        }
        .padding(16)
    }

    static let title = "Observations"
    static let subtitle = "What the analyzers observed and concluded — the probe's readings, the models' eras, scenes, speech, "
        + "on-screen text and people, and the statistics over all of it. Read-only; machine observations only. A machine era is never a date."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField
            if let failure = store.failure {
                Text("The observations could not be read: \(failure)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if store.search != nil || store.searching || store.searchFailure != nil {
                hits
            } else if let report = store.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.tiers) { tier in chevron(tier) }
                    }
                    .padding(.trailing, 6)
                }
            } else {
                ProgressView("Reading the catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .task(id: store.scope) { if store.report == nil { await store.load() } }
        .sheet(item: $dossierHit) { hit in
            if let loader = store.loader.dossiers {
                FileDossierSheet(row: AnalysisResultsReport.FileRow(digest: hit.digest, recordID: hit.recordID, filename: hit.filename, path: hit.path,
                                                                     removed: hit.removed, value: hit.kind.title, reason: hit.text),
                                 loader: loader, onShowInCatalog: { store.reveal(hit) })
            }
        }
        .accessibilityIdentifier("observations.window")
    }

    // MARK: Header, search, footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title).font(.title2.weight(.semibold))
                Text("· \(store.scope.words)").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let report = store.report {
                    Text("\(ObservationsReport.files(report.files)) · \(ObservationsReport.files(report.analyzed)) analyzed by a machine")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(Self.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static let searchPrompt = "Search what the machine observed — a word in a caption or transcript, on-screen text, an era (\"early 1990s\"), a person, a format (\"ProRes\")"

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if mockup {
                Text(store.search?.query ?? Self.searchPrompt).foregroundStyle(store.search == nil ? .secondary : .primary).frame(maxWidth: .infinity, alignment: .leading)
                Text("Search").padding(.horizontal, 10).padding(.vertical, 3).background(Color.accentColor.opacity(0.8)).foregroundStyle(.white).cornerRadius(5)
            } else {
                TextField(Self.searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await store.search(query) } }
                    .accessibilityIdentifier("observations.search")
                if !query.isEmpty {
                    Button { query = ""; Task { await store.search("") } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                }
                Button("Search") { Task { await store.search(query) } }
                    .disabled(ObservationsSearch.normalized(query) == nil || store.searching)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(7)
    }

    private var footer: some View {
        HStack {
            if let report = store.report {
                Text("As of \(Date(timeIntervalSince1970: TimeInterval(report.builtAt)).formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = store.revealProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if mockup {
                Text("MOCKUP — rendered from the real view with synthetic names").font(.caption).foregroundStyle(.secondary)
            } else {
                if store.search != nil {
                    Button("Back to the tiers") { query = ""; Task { await store.search("") } }
                }
                Button("Refresh") { Task { await store.load() } }.disabled(store.loading)
                    .accessibilityIdentifier("observations.refresh")
            }
        }
    }

    // MARK: The tiers (chevrons)

    private func chevron(_ tier: ObservationsReport.Tier) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(tier.layer) },
            set: { open in if open { expanded.insert(tier.layer) } else { expanded.remove(tier.layer) } })) {
            VStack(alignment: .leading, spacing: 8) {
                if mockup {
                    Text("Filter this tier").foregroundStyle(.tertiary).font(.system(size: 12)).padding(4).frame(width: 320, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                } else {
                    TextField("Filter this tier", text: Binding(get: { filters[tier.layer] ?? "" }, set: { filters[tier.layer] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("observations.filter.\(tier.layer.rawValue)")
                }
                let needle = (filters[tier.layer] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                ForEach(tier.groups) { group in
                    let rows = needle.isEmpty ? group.rows : group.rows.filter { $0.searchText.contains(needle) }
                    if !rows.isEmpty { groupView(group.title, rows) }
                }
            }
            .padding(.leading, 6)
            .padding(.top, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tier.layer.title).font(.system(size: 13, weight: .semibold))
                Text("— " + tier.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(tier.summary)
            }
        }
        .accessibilityIdentifier("observations.tier.\(tier.layer.rawValue)")
    }

    private func groupView(_ title: String, _ rows: [ObservationsReport.Row]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(rows) { row in ObservationsRowView(row: row, mockup: mockup) }
        }
    }

    // MARK: The hits

    private var hitRows: [ObservationsSearch.Hit] { store.search?.hits ?? [] }

    private var hits: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let search = store.search {
                HStack(spacing: 6) {
                    Text("\(search.hits.count.formatted()) hit\(search.hits.count == 1 ? "" : "s") for “\(search.query)”" + (search.truncated ? " — capped; narrow the words or the scope" : ""))
                        .font(.callout)
                    ForEach(ObservationsSearch.Kind.allCases, id: \.self) { kind in
                        if let n = search.counts[kind], n > 0 {
                            Text("\(kind.title) \(n)").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.1)).cornerRadius(4)
                        }
                    }
                }
            }
            Table(hitRows, selection: $selection) {
                TableColumn("Kind") { hit in Text(hit.kind.title).foregroundStyle(.secondary) }.width(min: 90, ideal: 110)
                TableColumn("Observation") { hit in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let at = hit.at { Text(FileDossierLineView.time(at)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        Text(hit.text).help(hit.text)
                    }
                }.width(min: 260, ideal: 420)
                TableColumn("Said by") { hit in Text(hit.source).foregroundStyle(.blue).help(hit.source) }.width(min: 120, ideal: 180)
                TableColumn("File") { hit in Text(hit.filename).foregroundStyle(hit.removed ? .secondary : .primary).help(hit.path) }.width(min: 140, ideal: 220)
            }
            .contextMenu(forSelectionType: ObservationsSearch.Hit.ID.self) { ids in
                Button("Show in Catalog") { show(ids.first) }.disabled(ids.count != 1)
                if store.loader.dossiers != nil { Button("Show Dossier") { showDossier(ids.first) }.disabled(ids.count != 1) }
            } primaryAction: { ids in show(ids.first) }
            .overlay {
                if store.searching { ProgressView() } else if let failure = store.searchFailure {
                    Text("The search could not be read: \(failure)").foregroundStyle(.secondary).padding()
                } else if store.search != nil, hitRows.isEmpty {
                    Text("Nothing the machine observed in \(store.scope.words) contains those words.").foregroundStyle(.secondary).padding()
                }
            }
            .accessibilityIdentifier("observations.hits")
            HStack {
                Spacer()
                if store.loader.dossiers != nil {
                    Button("Show Dossier") { showDossier(selection) }.disabled(selection == nil)
                }
                Button("Show in Catalog") { show(selection) }.disabled(selection == nil)
            }
        }
    }

    private func show(_ id: ObservationsSearch.Hit.ID?) {
        guard let id, let hit = hitRows.first(where: { $0.id == id }) else { return }
        store.reveal(hit)
    }

    private func showDossier(_ id: ObservationsSearch.Hit.ID?) {
        guard let id, let hit = hitRows.first(where: { $0.id == id }) else { return }
        dossierHit = hit
    }
}

/// One row: label · value · source ⓘ — the dossier line's shape, for a count.
struct ObservationsRowView: View {
    let row: ObservationsReport.Row
    var mockup = false
    @State private var showEvidence = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 220, alignment: .leading).lineLimit(1).help(row.label)
            Text(row.value).font(.system(size: 12))
                .foregroundStyle(row.standing == .missing || row.standing == .nothingFound ? Color.secondary : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .help(row.value)
            Spacer(minLength: 6)
            Text(row.source).font(.system(size: 10)).foregroundStyle(row.standing == .observation ? Color.blue : Color.secondary)
                .lineLimit(1).truncationMode(.middle).help(row.source)
            if row.evidence != nil, mockup {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.blue)
            } else if let evidence = row.evidence {
                Button { showEvidence.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.blue) }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showEvidence, arrowEdge: .trailing) {
                        Text(evidence).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(width: 340, alignment: .leading).padding(12)
                    }
            }
        }
    }
}

// MARK: - Window controller (the one door)

@MainActor
final class ObservationsWindowController {
    static let shared = ObservationsWindowController()
    nonisolated static let windowTitle = "Observations"

    private var window: NSWindow?
    private var store: ObservationsStore?
    private var closeObserver: NSObjectProtocol?

    /// The one door: the Content Analysis panel's Observations…, the Realtime
    /// window's "See what we learned", the catalog row menu. A second call
    /// re-scopes the open window. `source` is logged once.
    func show(model: VideoScanModel, scope: ObservationsScope, source: String) {
        let loader = ObservationsLoader.production(model: model)
        if let w = window, w.isVisible, let store {
            loader.note("shown from \(source) for \(scope.words)")
            Task { await store.set(scope: scope) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()
        let store = ObservationsStore(scope: scope, loader: loader)
        self.store = store
        let hosting = NSHostingView(rootView: ObservationsContent(store: store))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false       // AppKit would double-release on close otherwise (CatalogScanWindowController).
        w.title = Self.windowTitle
        w.contentView = hosting
        w.setFrameAutosaveName("ObservationsWindowV1")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        loader.note("shown from \(source) for \(scope.words)")
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.store?.cancel()
                self.store = nil
                self.window = nil
                if let obs = self.closeObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.closeObserver = nil
                }
            }
        }
    }

    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        store?.cancel()
        store = nil
        window?.close()
        window = nil
    }
}
