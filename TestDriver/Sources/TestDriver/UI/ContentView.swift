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
    @Published var host: TestHost = .macStudio

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
                TermLog.log("model", "run complete: \(self.summaryText)")
                self.runTask = nil
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
