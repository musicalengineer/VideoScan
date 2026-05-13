// ContentView.swift
//
// TestDriver UI — Group ▸ Module ▸ Test outline with counts, status
// badges, host picker, progress bar, brief / detailed view modes.
//
// Every meaningful UI event is mirrored to stderr via TermLog so the
// shell that launched `swift run TestDriver` shows a live timeline —
// useful when the SwiftUI window is wedged or off-screen.

import SwiftUI

@MainActor
final class TestDriverModel: ObservableObject {
    @Published var hierarchy: [(TestGroup, [(String?, [TestEntry])])] = []
    @Published var selected: Set<String> = []
    @Published var status: [String: TestStatus] = [:]
    @Published var logs: [String: String] = [:]
    @Published var liveLog: String = ""
    @Published var currentlyRunning: String?
    @Published var allowStress: Bool = false
    @Published var summaryText: String = ""
    @Published var progressFraction: Double = 0
    @Published var totalToRun: Int = 0
    @Published var completedCount: Int = 0
    @Published var briefMode: Bool = false
    @Published var host: TestHost = .macStudio {
        didSet { Task { await refreshRepoInfo() } }
    }
    @Published var repoInfo: RepoInfo = .empty
    @Published var lastRunSummary: RunSummary? = nil
    @Published var availableBranches: [String] = []
    @Published var lastPublishOutcome: PublishOutcome? = nil
    @Published var autoPublishMetrics: Bool = true

    private var runTask: Task<Void, Never>?

    init() {
        TermLog.log("model", "TestDriverModel init")
        VideoScanTests.registerAll()
        TermLog.log("model", "registered \(TestRegistry.shared.all().count) tests")
        rebuildHierarchy()
        for entry in TestRegistry.shared.all() {
            status[entry.id] = .notRun
            logs[entry.id] = ""
        }
        // Kick off initial repo inspection — non-blocking; UI shows "—" until done.
        Task { await refreshRepoInfo() }
    }

    func refreshRepoInfo() async {
        let h = host
        TermLog.log("model", "refreshRepoInfo host=\(h.rawValue)")
        let info = await RepoInspector.inspect(host: h)
        let branches = await RepoInspector.listBranches(host: h)
        await MainActor.run {
            self.repoInfo = info
            self.availableBranches = branches
            TermLog.log("model", "repo: \(info.oneLine)")
        }
    }

    func rebuildHierarchy() {
        let full = TestRegistry.shared.hierarchy()
        if allowStress {
            hierarchy = full
        } else {
            hierarchy = full.filter { !$0.0.requiresOptIn }
        }
        let visibleCount = hierarchy.flatMap { $0.1.flatMap { $0.1 } }.count
        TermLog.log("model", "hierarchy rebuilt: \(visibleCount) visible tests, allowStress=\(allowStress)")
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        TermLog.log("ui", "toggle \(id) → \(selected.contains(id) ? "ON" : "OFF") (selected=\(selected.count))")
    }

    func selectAll(in group: TestGroup) {
        let ids = TestRegistry.shared.all().filter { $0.group == group }.map(\.id)
        selected.formUnion(ids)
        TermLog.log("ui", "select group \(group.rawValue): +\(ids.count) (selected=\(selected.count))")
    }

    func selectAll(in group: TestGroup, module: String?) {
        let ids = TestRegistry.shared.all().filter { $0.group == group && $0.module == module }.map(\.id)
        selected.formUnion(ids)
        TermLog.log("ui", "select module \(group.rawValue)/\(module ?? "_"): +\(ids.count) (selected=\(selected.count))")
    }

    func clearAll() {
        TermLog.log("ui", "clear all selection (was \(selected.count))")
        selected.removeAll()
    }

    func runSelected() {
        guard runTask == nil else {
            TermLog.log("ui", "runSelected ignored — already running")
            return
        }
        let toRun = TestRegistry.shared.all().filter { selected.contains($0.id) }
        guard !toRun.isEmpty else {
            summaryText = "Nothing selected."
            TermLog.log("ui", "runSelected called with empty selection")
            return
        }
        TermLog.log("ui", "runSelected: \(toRun.count) tests on host=\(host.rawValue)")
        summaryText = "Running \(toRun.count) test(s) on \(host.rawValue)..."
        totalToRun = toRun.count
        completedCount = 0
        progressFraction = 0
        lastRunSummary = nil
        let runStarted = Date()
        let runRepo = repoInfo
        for entry in toRun {
            status[entry.id] = .notRun
            logs[entry.id] = ""
        }
        let selectedHost = host
        runTask = Task { [weak self] in
            guard let self else { return }
            var passed = 0, failed = 0, unclear = 0, skipped = 0
            for entry in toRun {
                if Task.isCancelled {
                    TermLog.log("model", "runSelected cancelled before \(entry.name)")
                    break
                }
                TermLog.log("test", "▶ \(entry.id)")
                await MainActor.run {
                    self.currentlyRunning = entry.id
                    self.status[entry.id] = .running
                    self.liveLog = "▶ \(entry.group.rawValue) / \(entry.module ?? "—") / \(entry.name)\n"
                }
                let logBuffer = LineBuffer()
                let result = await entry.run(selectedHost) { line in
                    TermLog.log("subproc", line)
                    Task { @MainActor in
                        self.liveLog += line + "\n"
                    }
                    logBuffer.append(line)
                }
                let symbol: String
                switch result.status {
                case .passed:  passed += 1;  symbol = "✓ pass"
                case .failed:  failed += 1;  symbol = "✗ fail"
                case .unclear: unclear += 1; symbol = "⚠ unclear"
                case .skipped: skipped += 1; symbol = "↷ skip"
                default:                     symbol = "?"
                }
                TermLog.log("test", "\(symbol) \(entry.id)")
                await MainActor.run {
                    self.status[entry.id] = result.status
                    let merged = logBuffer.snapshot() +
                                 (result.log.isEmpty ? "" : "\n--- result.log ---\n" + result.log)
                    self.logs[entry.id] = merged
                    self.completedCount += 1
                    self.progressFraction = Double(self.completedCount) / Double(self.totalToRun)
                }
            }
            await MainActor.run {
                self.currentlyRunning = nil
                var parts: [String] = []
                if passed  > 0 { parts.append("\(passed) passed") }
                if failed  > 0 { parts.append("\(failed) failed") }
                if unclear > 0 { parts.append("\(unclear) unclear") }
                if skipped > 0 { parts.append("\(skipped) skipped") }
                self.summaryText = "Done — " + parts.joined(separator: ", ")
                let summary = RunSummary(
                    passed: passed, failed: failed, unclear: unclear, skipped: skipped,
                    elapsedSeconds: Date().timeIntervalSince(runStarted),
                    host: selectedHost, repo: runRepo, startedAt: runStarted
                )
                self.lastRunSummary = summary
                TermLog.log("model", "run complete: \(self.summaryText)")
                self.runTask = nil

                // Publish metrics (gated on branch/dirty/ahead inside).
                // Fire-and-forget: failure can't block the UI showing results.
                if self.autoPublishMetrics {
                    Task { [weak self] in
                        let outcome = await MetricsPublisher.publish(summary: summary)
                        await MainActor.run {
                            self?.lastPublishOutcome = outcome
                            switch outcome {
                            case .published(_, let sha):
                                TermLog.log("metrics", "✓ published @ \(sha)")
                            case .skipped(let reason):
                                TermLog.log("metrics", "↷ skipped: \(reason)")
                            case .failed(let msg):
                                TermLog.log("metrics", "✗ failed: \(msg)")
                            }
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        TermLog.log("ui", "cancel pressed")
        runTask?.cancel()
    }

    func runOne(_ id: String) {
        TermLog.log("ui", "runOne \(id)")
        selected = [id]
        runSelected()
    }

    /// Prints the entire current state to stderr — handy when the UI is
    /// wedged and Rick wants to know what TestDriver thinks is happening.
    func dumpState() {
        TermLog.log("debug", "=== state dump ===")
        TermLog.log("debug", "host=\(host.rawValue)")
        TermLog.log("debug", "selected=\(selected.count)")
        TermLog.log("debug", "currentlyRunning=\(currentlyRunning ?? "—")")
        TermLog.log("debug", "completed=\(completedCount)/\(totalToRun)")
        for entry in TestRegistry.shared.all() {
            let s = status[entry.id] ?? .notRun
            TermLog.log("debug", "  \(s.symbol) \(entry.id)")
        }
        TermLog.log("debug", "=== end state dump ===")
    }
}

/// Final-result snapshot for the post-run banner.
struct RunSummary {
    var passed: Int
    var failed: Int
    var unclear: Int
    var skipped: Int
    var elapsedSeconds: Double
    var host: TestHost
    var repo: RepoInfo
    var startedAt: Date

    var total: Int { passed + failed + unclear + skipped }
    var allPassed: Bool { failed == 0 && unclear == 0 && total > 0 }
}

final class LineBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

struct ContentView: View {
    @StateObject private var model = TestDriverModel()
    @State private var expandedGroups: Set<TestGroup> = Set(TestGroup.allCases)
    @State private var expandedModules: Set<String> = []
    @State private var inspectedID: String?
    @State private var filterText: String = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                repoBanner
                Divider()
                if let summary = model.lastRunSummary {
                    resultBanner(summary)
                    Divider()
                }
                toolbar
                Divider()
                progressBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.hierarchy, id: \.0) { group, modules in
                            groupSection(group: group, modules: modules)
                        }
                    }
                    .padding(8)
                }
                Divider()
                summaryBar
            }
            .frame(minWidth: 360, idealWidth: 600)

            VStack(alignment: .leading, spacing: 0) {
                Text(inspectedID.flatMap(TestRegistry.shared.entry(id:))?.name ?? "Live log")
                    .font(.headline)
                    .padding(8)
                Divider()
                if model.briefMode && model.totalToRun > 0 {
                    briefProgressGrid.padding(8)
                } else {
                    ScrollView {
                        Text(displayedLog)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 480)
        }
        // Window can shrink to here; user can drag larger freely.
        // Lowered from 980x640 because the toolbar got crowded enough to
        // hide chevrons at the old minimum.
        .frame(minWidth: 700, minHeight: 420)
    }

    private var displayedLog: String {
        if let inspected = inspectedID, let stored = model.logs[inspected], !stored.isEmpty {
            return stored
        }
        return model.liveLog
    }

    // MARK: - Repo / result banners

    /// Always-on top banner: shows what version of VideoScan is about to be
    /// tested on the currently selected host. Refresh button re-runs the
    /// inspector (use after manual git checkout).
    private var repoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "swift")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Testing").font(.caption).foregroundStyle(.secondary)
                    Text(model.host.rawValue).font(.caption).bold()
                    Text("·").foregroundStyle(.secondary)
                    Text(model.repoInfo.projectDir)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(model.repoInfo.oneLine)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if model.repoInfo.dirty {
                Text("UNCOMMITTED")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25))
                    .foregroundStyle(.orange)
                    .cornerRadius(4)
            }
            Button {
                Task { await model.refreshRepoInfo() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-inspect repo (use after switching branches manually)")

            Menu {
                ForEach(model.availableBranches, id: \.self) { branch in
                    Text(branch == model.repoInfo.branch
                         ? "✓ \(branch)" : branch)
                }
                Divider()
                Text("Branch switching is read-only — checkout from terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("Available branches on this host (informational; doesn't switch)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// One-line status under the result banner showing whether metrics
    /// published. Pre-approved push to origin/metrics under hard gates;
    /// any non-main / dirty / non-synced state shows a clear "skipped" line.
    @ViewBuilder
    private func publishOutcomeLine(_ outcome: PublishOutcome) -> some View {
        switch outcome {
        case .published(_, let sha):
            Label("metrics published to origin/metrics @ \(sha)", systemImage: "chart.bar.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .skipped(let reason):
            Label("metrics skipped — \(reason)", systemImage: "chart.bar")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("metrics push FAILED — \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Big legible end-of-run banner. Stays at top until the next run starts.
    /// Color: green if all passed, red if any failed, yellow if any unclear,
    /// gray-on-skipped-only.
    private func resultBanner(_ s: RunSummary) -> some View {
        let bg: Color = {
            if s.failed > 0  { return Color.red.opacity(0.18) }
            if s.unclear > 0 { return Color.yellow.opacity(0.22) }
            if s.allPassed   { return Color.green.opacity(0.18) }
            return Color.gray.opacity(0.15)
        }()
        let symbol: String = {
            if s.failed > 0  { return "✗" }
            if s.unclear > 0 { return "⚠" }
            if s.allPassed   { return "✓" }
            return "—"
        }()
        let symbolColor: Color = {
            if s.failed > 0  { return .red }
            if s.unclear > 0 { return .yellow }
            if s.allPassed   { return .green }
            return .secondary
        }()
        let dateFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f
        }()

        return HStack(alignment: .top, spacing: 14) {
            Text(symbol)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(symbolColor)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Text("\(s.passed) passed")
                        .foregroundStyle(.green).bold()
                    Text("\(s.failed) failed")
                        .foregroundStyle(s.failed > 0 ? .red : .secondary).bold()
                    Text("\(s.unclear) unclear")
                        .foregroundStyle(s.unclear > 0 ? .yellow : .secondary).bold()
                    Text("\(s.skipped) skipped")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f s", s.elapsedSeconds))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .font(.title2)
                Text("\(s.host.rawValue)  ·  \(s.repo.branch) @ \(s.repo.commit)\(s.repo.dirty ? " (dirty)" : "")  ·  v\(s.repo.appVersion)  ·  \(dateFmt.string(from: s.startedAt))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Publish outcome under the run banner. Only renders once
                // the async publish actually completed.
                if let outcome = model.lastPublishOutcome {
                    publishOutcomeLine(outcome)
                }
            }
            Spacer()
            Button {
                model.lastRunSummary = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss summary")
        }
        .padding(12)
        .background(bg)
    }

    // MARK: - Toolbar

    /// Three rows. Vertical stacking guarantees nothing gets squeezed
    /// off-screen at narrow widths — a regression V2 introduced when we
    /// stuffed everything onto one HStack.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    model.runSelected()
                } label: {
                    Label("Run Selected", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selected.isEmpty || model.currentlyRunning != nil)

                Button("Stop") { model.cancel() }
                    .disabled(model.currentlyRunning == nil)

                Divider().frame(height: 18)

                Button("Select Visible") {
                    let visibleIDs = model.hierarchy.flatMap { $0.1.flatMap { $0.1.map(\.id) } }
                    model.selected = Set(visibleIDs)
                    TermLog.log("ui", "select all visible: \(visibleIDs.count)")
                }
                Button("Clear") { model.clearAll() }

                Spacer()

                Button {
                    model.dumpState()
                } label: {
                    Label("Dump", systemImage: "doc.text.magnifyingglass")
                }
                .help("Print full state to stderr (terminal that launched TestDriver)")
            }

            HStack(spacing: 12) {
                Text("Run on").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.host) {
                    ForEach(TestHost.allCases) { h in
                        Text(h.isImplemented ? h.rawValue : "\(h.rawValue) — not wired")
                            .tag(h)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Toggle("Brief", isOn: $model.briefMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Stress", isOn: $model.allowStress)
                    .onChange(of: model.allowStress) { _, _ in model.rebuildHierarchy() }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Publish", isOn: $model.autoPublishMetrics)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Push run metrics to origin/metrics when on clean main matching origin")
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tests by name or module…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(8)
    }

    // MARK: - Progress / summary

    private var progressBar: some View {
        Group {
            if model.totalToRun > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: model.progressFraction)
                    HStack {
                        Text("\(model.completedCount) of \(model.totalToRun)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let runningID = model.currentlyRunning,
                           let entry = TestRegistry.shared.entry(id: runningID) {
                            Text("⌛ \(entry.name)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var summaryBar: some View {
        HStack {
            Text(model.summaryText.isEmpty ? "Idle" : model.summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(TestRegistry.shared.all().count) tests registered")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
    }

    private var briefProgressGrid: some View {
        let visible = model.hierarchy.flatMap { $0.1.flatMap { $0.1 } }
        let columns = [GridItem(.adaptive(minimum: 16, maximum: 16), spacing: 3)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(visible) { entry in
                    let s = model.status[entry.id] ?? .notRun
                    Rectangle()
                        .fill(statusColor(s))
                        .frame(width: 14, height: 14)
                        .cornerRadius(2)
                        .help("\(entry.name) — \(symbolicStatus(s))")
                        .onTapGesture { inspectedID = entry.id }
                }
            }
        }
    }

    // MARK: - Outline

    /// Group section. Header row: chevron + name + count + Select button.
    /// We deliberately do NOT put the "Select group" button INSIDE the
    /// DisclosureGroup label — in V2 that stole the tap area and the
    /// chevron stopped responding. Instead we render a thin row above
    /// the disclosure with our own controls.
    private func groupSection(group: TestGroup, modules: [(String?, [TestEntry])]) -> some View {
        let total = modules.reduce(0) { $0 + $1.1.count }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedGroups.contains(group) },
                        set: { isOpen in
                            if isOpen { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                        }
                    )
                ) {
                    EmptyView()    // Content rendered below; this disclosure is just the chevron + label
                } label: {
                    HStack(spacing: 4) {
                        Text(group.rawValue).font(.headline)
                        Text("(\(total))").foregroundStyle(.secondary).font(.subheadline)
                    }
                }
                Spacer()
                Button("Select") { model.selectAll(in: group) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if expandedGroups.contains(group) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(modules, id: \.0) { module, entries in
                        moduleSection(group: group, module: module, entries: entries)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }

    private func moduleSection(group: TestGroup, module: String?, entries: [TestEntry]) -> some View {
        let visible = entries.filter { matchesFilter($0) }
        let moduleKey = "\(group.rawValue)/\(module ?? "_")"
        let label = module ?? "(no module)"
        let isExpanded = expandedModules.contains(moduleKey) || !filterText.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            if !visible.isEmpty {
                HStack(spacing: 6) {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { isExpanded },
                            set: { isOpen in
                                if isOpen { expandedModules.insert(moduleKey) } else { expandedModules.remove(moduleKey) }
                            }
                        )
                    ) {
                        EmptyView()
                    } label: {
                        HStack(spacing: 4) {
                            Text(label).font(.system(.body, design: .default).weight(.medium))
                            Text("(\(visible.count))").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    Spacer()
                    Button("Select") { model.selectAll(in: group, module: module) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { entry in
                            rowFor(entry)
                        }
                    }
                    .padding(.leading, 22)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func matchesFilter(_ entry: TestEntry) -> Bool {
        if filterText.isEmpty { return true }
        let f = filterText.lowercased()
        return entry.name.lowercased().contains(f)
            || (entry.module?.lowercased().contains(f) ?? false)
            || entry.description.lowercased().contains(f)
    }

    /// Per-test row. We use an explicit Image-as-checkbox rather than a
    /// Toggle, because Toggle inside a row that ALSO has tap recognizers
    /// caused a hit-test conflict in V2 — taps on the box went to the
    /// row tap gesture and never toggled. An Image with its own onTapGesture
    /// is unambiguous.
    private func rowFor(_ entry: TestEntry) -> some View {
        let isSelected = model.selected.contains(entry.id)
        let st = model.status[entry.id] ?? .notRun
        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.system(size: 16))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(entry.id) }

            Text(st.symbol)
                .font(.system(.body, design: .monospaced))
                .frame(width: 18)
                .foregroundStyle(statusColor(st))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(.body))
                Text(entry.description).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { inspectedID = entry.id }

            durationLabel(st)

            Button("Run") { model.runOne(entry.id) }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.currentlyRunning != nil)
        }
        .padding(.vertical, 2)
        .background(inspectedID == entry.id ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    @ViewBuilder
    private func durationLabel(_ st: TestStatus) -> some View {
        switch st {
        case .passed(let dur):
            Text(String(format: "%.1fs", dur))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        case .failed(_, let dur):
            Text(String(format: "%.1fs", dur))
                .font(.caption).foregroundStyle(.red)
                .frame(width: 56, alignment: .trailing)
        case .unclear(_, let dur):
            Text(String(format: "%.1fs", dur))
                .font(.caption).foregroundStyle(.yellow)
                .frame(width: 56, alignment: .trailing)
        default:
            Text(" ").font(.caption).frame(width: 56, alignment: .trailing)
        }
    }

    private func statusColor(_ s: TestStatus) -> Color {
        switch s {
        case .notRun:  return .secondary
        case .running: return .orange
        case .passed:  return .green
        case .failed:  return .red
        case .unclear: return .yellow
        case .skipped: return Color(white: 0.6)
        }
    }

    private func symbolicStatus(_ s: TestStatus) -> String {
        switch s {
        case .notRun:  return "not run"
        case .running: return "running"
        case .passed:  return "passed"
        case .failed:  return "failed"
        case .unclear: return "unclear"
        case .skipped: return "skipped"
        }
    }
}
