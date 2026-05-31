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
    @Published var coverageEnabled: Bool = false
    @Published var coverageIncludeAll: Bool = false
    @Published var lastCoveragePercent: Double? = nil
    @Published var host: TestHost = .local {
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
        TermLog.log("model", "refreshRepoInfo host=\(h.displayName)")
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
        TermLog.log("ui", "runSelected: \(toRun.count) tests on host=\(host.displayName) coverage=\(coverageEnabled)/\(coverageIncludeAll)")
        // Plumb the coverage toggles into the run path. Read here so a
        // mid-flight toggle change doesn't apply to a half-finished run.
        VideoScanTests.coverageContext = (enabled: coverageEnabled,
                                          includeAll: coverageIncludeAll)
        summaryText = "Running \(toRun.count) test(s) on \(host.displayName)..."
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
            var methodsPassed = 0
            var methodsFailed = 0
            var entriesSkipped = 0
            var coveredLinesTotal = 0
            var executableLinesTotal = 0
            // Without xccov's raw line counts at the call site we instead
            // average per-entry percentages weighted by 1; if multiple
            // coverage-collecting entries run we average their percents.
            var coverageSamples: [Double] = []
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
                // Roll-up rule: if the entry returned methodCounts, use those.
                // Otherwise count one-for-the-entry-itself: pass=1/0, fail=0/1.
                let symbol: String
                switch result.status {
                case .passed:
                    if let mc = result.methodCounts {
                        methodsPassed += mc.passed
                        methodsFailed += mc.failed
                    } else {
                        methodsPassed += 1
                    }
                    symbol = "✓ pass"
                case .failed:
                    if let mc = result.methodCounts {
                        methodsPassed += mc.passed
                        methodsFailed += mc.failed
                        // If the entry came back failed but had zero method
                        // failures recorded (e.g. infrastructure error before
                        // any test ran), still count one failure so the entry
                        // doesn't vanish from the totals.
                        if mc.passed == 0 && mc.failed == 0 {
                            methodsFailed += 1
                        }
                    } else {
                        methodsFailed += 1
                    }
                    symbol = "✗ fail"
                case .skipped:
                    entriesSkipped += 1
                    symbol = "↷ skip"
                default:
                    symbol = "?"
                }
                if let cov = result.coveragePercent {
                    coverageSamples.append(cov)
                    // Crude weighted average: re-derive line counts from
                    // the percentage. Not exact (xccov only gives us %),
                    // but consistent across reports.
                    coveredLinesTotal += Int(cov * 1000)
                    executableLinesTotal += 100000
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
                let total = methodsPassed + methodsFailed
                let entriesTotal = toRun.count
                var parts: [String] = []
                parts.append("\(total) executed")
                parts.append("\(methodsPassed) passed")
                parts.append("\(methodsFailed) failed")
                if entriesSkipped > 0 { parts.append("\(entriesSkipped) skipped") }
                self.summaryText = "Done — " + parts.joined(separator: ", ")
                let coveragePct: Double? = coverageSamples.isEmpty
                    ? nil
                    : coverageSamples.reduce(0, +) / Double(coverageSamples.count)
                self.lastCoveragePercent = coveragePct
                let summary = RunSummary(
                    methodsPassed: methodsPassed,
                    methodsFailed: methodsFailed,
                    entriesSkipped: entriesSkipped,
                    entriesTotal: entriesTotal,
                    elapsedSeconds: Date().timeIntervalSince(runStarted),
                    host: selectedHost,
                    repo: runRepo,
                    startedAt: runStarted,
                    coveragePercent: coveragePct
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
        TermLog.log("debug", "host=\(host.displayName)")
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

/// Final-result snapshot for the post-run banner. The numbers represent
/// XCTest *method* counts (rolled up from xcodebuild) for xcodebuild
/// entries, and one-per-entry for non-xcodebuild entries. That keeps the
/// banner's "Executed N" consistent with what the underlying tests report.
struct RunSummary {
    var methodsPassed: Int
    var methodsFailed: Int
    var entriesSkipped: Int
    var entriesTotal: Int
    var elapsedSeconds: Double
    var host: TestHost
    var repo: RepoInfo
    var startedAt: Date
    var coveragePercent: Double?

    var total: Int { methodsPassed + methodsFailed }
    var allPassed: Bool { methodsFailed == 0 && total > 0 }
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

// MARK: - Font helper (+2pt across the UI, Live Log excluded)

/// Replaces SwiftUI's default `.font(.headline)` etc. with sizes 2 points
/// larger across the board. The Live Log mono font is intentionally NOT
/// routed through here — that view stays at the system body size so a
/// wall of xcodebuild output doesn't blow up the readable area.
private extension Font {
    static func td(_ base: Font.TextStyle,
                   weight: Font.Weight? = nil,
                   design: Font.Design = .default) -> Font {
        let size: CGFloat = {
            switch base {
            case .largeTitle:  return 36
            case .title:       return 30
            case .title2:      return 24
            case .title3:      return 22
            case .headline:    return 19
            case .body:        return 17
            case .callout:     return 15
            case .subheadline: return 15
            case .footnote:    return 14
            case .caption:     return 13
            case .caption2:    return 12
            @unknown default:  return 17
            }
        }()
        var font = Font.system(size: size, design: design)
        if let w = weight { font = font.weight(w) }
        return font
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
            .frame(minWidth: 360, idealWidth: 700)

            VStack(alignment: .leading, spacing: 0) {
                Text(inspectedID.flatMap(TestRegistry.shared.entry(id:))?.name ?? "Live log")
                    .font(.td(.headline))
                    .padding(8)
                Divider()
                // Failures panel — only renders when there are failed entries.
                // Lists each by name + first line of failure message, with
                // click-to-inspect so the log below switches to that entry.
                // Without this the user has to scroll the entry tree hunting
                // for ✗ icons, which gets impractical past ~100 entries.
                failuresPanel
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
            .frame(minWidth: 280, idealWidth: 560)
        }
        // Window can shrink to here; user can drag larger freely.
        // idealWidth/idealHeight matter on first launch so the window opens
        // at a comfortable size; min* lets the user squeeze it down later.
        .frame(minWidth: 720, idealWidth: 1280,
               minHeight: 460, idealHeight: 820)
    }

    private var displayedLog: String {
        if let inspected = inspectedID, let stored = model.logs[inspected], !stored.isEmpty {
            return stored
        }
        return model.liveLog
    }

    /// Snapshot of entries currently in `.failed` status, in registry order.
    /// Recomputed on each render — small (typically <20 items) and reactive
    /// to `model.status` changes via SwiftUI's @Published observation.
    private var failedEntries: [(id: String, name: String, message: String)] {
        TestRegistry.shared.all().compactMap { entry in
            guard case let .failed(message, _) = model.status[entry.id] else { return nil }
            return (entry.id, entry.name, message)
        }
    }

    /// "Failures (N)" section that renders above the log when any entries
    /// are in .failed status. Each row jumps to that entry's stored log
    /// when clicked. Capped at 220pt tall so a run with many fails still
    /// leaves room for the log scrollview below.
    @ViewBuilder
    private var failuresPanel: some View {
        let failed = failedEntries
        if !failed.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Failures (\(failed.count))")
                        .font(.td(.headline))
                    Spacer()
                    Text("click a row to view its log")
                        .font(.td(.caption2))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(failed, id: \.id) { entry in
                            failureRow(id: entry.id, name: entry.name, message: entry.message)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 220)
                Divider()
            }
            .background(Color.red.opacity(0.06))
        }
    }

    private func failureRow(id: String, name: String, message: String) -> some View {
        let selected = (inspectedID == id)
        return Button {
            inspectedID = id
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text("✗").foregroundStyle(.red).bold().frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.td(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(message)
                        .font(.td(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }

    // MARK: - Repo / result banners

    /// Always-on top banner: shows what version of VideoScan is about to be
    /// tested on the currently selected host. Refresh button re-runs the
    /// inspector (use after manual git checkout).
    private var repoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "swift")
                .foregroundStyle(.orange)
                .font(.td(.title3))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Testing").font(.td(.caption)).foregroundStyle(.secondary)
                    Text(model.host.displayName).font(.td(.caption)).bold()
                    Text("·").foregroundStyle(.secondary)
                    Text(model.repoInfo.projectDir)
                        .font(.td(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(model.repoInfo.oneLine)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button {
                let visibleIDs = model.hierarchy.flatMap { $0.1.flatMap { $0.1.map(\.id) } }
                model.selected = Set(visibleIDs)
                TermLog.log("ui", "Run All: \(visibleIDs.count) visible tests")
                model.runSelected()
            } label: {
                Label("Run All", systemImage: "play.circle.fill")
                    .font(.td(.body, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.currentlyRunning != nil)
            .help("Run every visible test on the selected host")

            if model.repoInfo.dirty {
                Text("UNCOMMITTED")
                    .font(.td(.caption2)).bold()
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
                    .font(.td(.caption)).foregroundStyle(.secondary)
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
                .font(.td(.caption))
                .foregroundStyle(.green)
        case .skipped(let reason):
            Label("metrics skipped — \(reason)", systemImage: "chart.bar")
                .font(.td(.caption))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("metrics push FAILED — \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.td(.caption))
                .foregroundStyle(.orange)
        }
    }

    /// Big legible end-of-run banner. Stays at top until the next run starts.
    /// Three large stat numbers (Executed / Passed / Failed) replace the
    /// older pass/fail/unclear/skipped four-up — one consistent count.
    private func resultBanner(_ s: RunSummary) -> some View {
        let bg: Color = {
            if s.methodsFailed > 0  { return Color.red.opacity(0.18) }
            if s.allPassed          { return Color.green.opacity(0.18) }
            return Color.gray.opacity(0.15)
        }()
        let symbol: String = {
            if s.methodsFailed > 0  { return "✗" }
            if s.allPassed          { return "✓" }
            return "—"
        }()
        let symbolColor: Color = {
            if s.methodsFailed > 0  { return .red }
            if s.allPassed          { return .green }
            return .secondary
        }()
        let dateFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f
        }()

        return HStack(alignment: .top, spacing: 14) {
            Text(symbol)
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(symbolColor)
                .frame(width: 76)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 22) {
                    bigStat(number: s.total, label: "executed", color: .primary)
                    bigStat(number: s.methodsPassed, label: "passed", color: .green)
                    bigStat(number: s.methodsFailed,
                            label: "failed",
                            color: s.methodsFailed > 0 ? .red : .secondary)
                    if s.entriesSkipped > 0 {
                        Text("·  \(s.entriesSkipped) skipped")
                            .font(.td(.callout))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f s", s.elapsedSeconds))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let cov = s.coveragePercent {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .foregroundStyle(Color.accentColor)
                        Text(String(format: "Coverage: %.1f%%", cov))
                            .font(.td(.headline))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(s.host.displayName)  ·  \(s.repo.branch) @ \(s.repo.commit)\(s.repo.dirty ? " (dirty)" : "")  ·  v\(s.repo.appVersion)  ·  \(dateFmt.string(from: s.startedAt))")
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

    /// One of the three big stat numbers in the result banner — bold
    /// number on top, small uppercase label beneath, both colored.
    private func bigStat(number: Int, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(number)")
                .font(.system(size: 28, weight: .bold, design: .default).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.td(.caption))
                .foregroundStyle(color.opacity(0.85))
        }
    }

    // MARK: - Toolbar

    /// Four rows now. Vertical stacking guarantees nothing gets squeezed
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
            .font(.td(.body))

            HStack(spacing: 12) {
                Text("Run on").font(.td(.caption)).foregroundStyle(.secondary)
                Picker("", selection: $model.host) {
                    ForEach(TestHost.allCases) { h in
                        Text(h.isImplemented ? h.displayName : "\(h.displayName) — not wired")
                            .tag(h)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Toggle("Brief", isOn: $model.briefMode)
                    .toggleStyle(.checkbox)
                    .font(.td(.caption))
                Toggle("Stress", isOn: $model.allowStress)
                    .onChange(of: model.allowStress) { _, _ in model.rebuildHierarchy() }
                    .toggleStyle(.checkbox)
                    .font(.td(.caption))
                Toggle("Publish", isOn: $model.autoPublishMetrics)
                    .toggleStyle(.checkbox)
                    .font(.td(.caption))
                    .help("Push run metrics to origin/metrics when on clean main matching origin")
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tests by name or module…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.td(.body))
            }

            // Coverage toggles. When the report toggle is off, "Include All"
            // disables — there's nothing to include. The first toggle drives
            // -enableCodeCoverage; the second extends collection from the
            // two unit-suite entries to the regression entries as well.
            HStack(spacing: 14) {
                Toggle("Generate Coverage Report", isOn: $model.coverageEnabled)
                    .toggleStyle(.checkbox)
                    .font(.td(.caption))
                    .help("Pass -enableCodeCoverage YES to xcodebuild and parse xccov for the banner/metrics")
                Toggle("Include All Tests for Coverage", isOn: $model.coverageIncludeAll)
                    .toggleStyle(.checkbox)
                    .font(.td(.caption))
                    .disabled(!model.coverageEnabled)
                    .help("Also collect coverage on regression suites (slower, more representative)")
                Spacer()
                if let cov = model.lastCoveragePercent {
                    Text(String(format: "Last coverage: %.1f%%", cov))
                        .font(.td(.caption))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(8)
    }

    // MARK: - Progress / summary

    private var progressBar: some View {
        Group {
            if model.totalToRun > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    // Hand-rolled bar instead of the system ProgressView so we
                    // can guarantee a thicker hit-target — the default macOS
                    // progress style renders at ~4pt and Rick can't see it at
                    // a glance during a 25-min run. ~12pt tall is roughly 2x
                    // the system default; rounded corners match macOS feel.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                                .frame(width: max(0, geo.size.width * model.progressFraction))
                        }
                    }
                    .frame(height: 12)
                    HStack {
                        Text("\(model.completedCount) of \(model.totalToRun)")
                            .font(.td(.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let runningID = model.currentlyRunning,
                           let entry = TestRegistry.shared.entry(id: runningID) {
                            Text("⌛ \(entry.name)")
                                .font(.td(.caption))
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
                .font(.td(.callout))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(TestRegistry.shared.all().count) tests registered")
                .font(.td(.caption))
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
                        Text(group.rawValue)
                            .font(.td(.headline))
                            .foregroundStyle(group.color)
                        Text("(\(total))")
                            .foregroundStyle(.secondary)
                            .font(.td(.subheadline))
                    }
                }
                Spacer()
                Button("Select") { model.selectAll(in: group) }
                    .buttonStyle(.borderless)
                    .font(.td(.caption))
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
                            Text(label).font(.td(.body, weight: .medium))
                            Text("(\(visible.count))").foregroundStyle(.secondary).font(.td(.caption))
                        }
                    }
                    Spacer()
                    Button("Select") { model.selectAll(in: group, module: module) }
                        .buttonStyle(.borderless)
                        .font(.td(.caption))
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
            // 3pt colored bar pinned to the leading edge — quick visual
            // shorthand for which group this row belongs to (Unit=blue,
            // Regression=purple, Diagnostic=yellow, etc.).
            RoundedRectangle(cornerRadius: 1.5)
                .fill(entry.group.color)
                .frame(width: 3, height: 28)

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
                Text(entry.name).font(.td(.body))
                Text(entry.description).font(.td(.caption)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { inspectedID = entry.id }

            durationLabel(st)

            Button("Run") { model.runOne(entry.id) }
                .buttonStyle(.borderless)
                .font(.td(.caption))
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
                .font(.td(.caption)).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        case .failed(_, let dur):
            Text(String(format: "%.1fs", dur))
                .font(.td(.caption)).foregroundStyle(.red)
                .frame(width: 56, alignment: .trailing)
        default:
            Text(" ").font(.td(.caption)).frame(width: 56, alignment: .trailing)
        }
    }

    private func statusColor(_ s: TestStatus) -> Color {
        switch s {
        case .notRun:  return .secondary
        case .running: return .orange
        case .passed:  return .green
        case .failed:  return .red
        case .skipped: return Color(white: 0.6)
        }
    }

    private func symbolicStatus(_ s: TestStatus) -> String {
        switch s {
        case .notRun:  return "not run"
        case .running: return "running"
        case .passed:  return "passed"
        case .failed:  return "failed"
        case .skipped: return "skipped"
        }
    }
}
