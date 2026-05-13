// ContentView.swift
//
// TestDriver UI — Group ▸ Module ▸ Test outline with counts, status
// badges, host picker, progress bar, brief / detailed view modes.

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
        VideoScanTests.registerAll()
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
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectAll(in group: TestGroup) {
        for entry in TestRegistry.shared.all() where entry.group == group {
            selected.insert(entry.id)
        }
    }

    func selectAll(in group: TestGroup, module: String?) {
        for entry in TestRegistry.shared.all() where entry.group == group && entry.module == module {
            selected.insert(entry.id)
        }
    }

    func clearAll() { selected.removeAll() }

    func runSelected() {
        guard runTask == nil else { return }
        let toRun = TestRegistry.shared.all().filter { selected.contains($0.id) }
        guard !toRun.isEmpty else {
            summaryText = "Nothing selected."
            return
        }
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
                if Task.isCancelled { break }
                await MainActor.run {
                    self.currentlyRunning = entry.id
                    self.status[entry.id] = .running
                    self.liveLog = "▶ \(entry.group.rawValue) / \(entry.module ?? "—") / \(entry.name)\n"
                }
                let logBuffer = LineBuffer()
                let result = await entry.run(selectedHost) { line in
                    Task { @MainActor in
                        self.liveLog += line + "\n"
                    }
                    logBuffer.append(line)
                }
                await MainActor.run {
                    self.status[entry.id] = result.status
                    let merged = logBuffer.snapshot() +
                                 (result.log.isEmpty ? "" : "\n--- result.log ---\n" + result.log)
                    self.logs[entry.id] = merged
                    switch result.status {
                    case .passed:  passed += 1
                    case .failed:  failed += 1
                    case .unclear: unclear += 1
                    case .skipped: skipped += 1
                    default: break
                    }
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
                self.runTask = nil
            }
        }
    }

    func cancel() { runTask?.cancel() }

    func runOne(_ id: String) {
        selected = [id]
        runSelected()
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
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 0) {
                Text(inspectedID.flatMap(TestRegistry.shared.entry(id:))?.name ?? "Live log")
                    .font(.headline)
                    .padding(8)
                Divider()
                if model.briefMode && model.currentlyRunning != nil {
                    briefProgressGrid
                        .padding(8)
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
            .frame(minWidth: 380)
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var displayedLog: String {
        if let inspected = inspectedID, let stored = model.logs[inspected], !stored.isEmpty {
            return stored
        }
        return model.liveLog
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: { model.runSelected() }) {
                    Label("Run Selected", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selected.isEmpty || model.currentlyRunning != nil)

                Button("Stop") { model.cancel() }
                    .disabled(model.currentlyRunning == nil)

                Divider().frame(height: 18)

                Button("Select All") {
                    let visibleIDs = model.hierarchy.flatMap { $0.1.flatMap { $0.1.map(\.id) } }
                    model.selected = Set(visibleIDs)
                }
                Button("Clear") { model.clearAll() }

                Spacer()

                Picker("Host", selection: $model.host) {
                    ForEach(TestHost.allCases) { h in
                        Text(h.isImplemented ? h.rawValue : "\(h.rawValue) — not wired")
                            .tag(h)
                    }
                }
                .frame(width: 240)
                .pickerStyle(.menu)

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

    private func groupSection(group: TestGroup, modules: [(String?, [TestEntry])]) -> some View {
        let total = modules.reduce(0) { $0 + $1.1.count }
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedGroups.contains(group) },
                set: { isOpen in
                    if isOpen { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                }
            ),
            content: {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(modules, id: \.0) { module, entries in
                        moduleSection(group: group, module: module, entries: entries)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 4)
            },
            label: {
                HStack {
                    Text(group.rawValue).font(.headline)
                    Text("(\(total))")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                    Button("Select group") { model.selectAll(in: group) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        )
        .padding(.vertical, 2)
    }

    private func moduleSection(group: TestGroup, module: String?, entries: [TestEntry]) -> some View {
        let visible = entries.filter { matchesFilter($0) }
        let moduleKey = "\(group.rawValue)/\(module ?? "_")"
        let label = module ?? "(no module)"
        return Group {
            if visible.isEmpty {
                EmptyView()
            } else {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedModules.contains(moduleKey) || !filterText.isEmpty },
                        set: { isOpen in
                            if isOpen { expandedModules.insert(moduleKey) } else { expandedModules.remove(moduleKey) }
                        }
                    ),
                    content: {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(visible) { entry in
                                rowFor(entry)
                            }
                        }
                        .padding(.leading, 22)
                        .padding(.top, 2)
                    },
                    label: {
                        HStack {
                            Text(label).font(.system(.body, design: .default).weight(.medium))
                            Text("(\(visible.count))")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Spacer()
                            Button("Select module") {
                                model.selectAll(in: group, module: module)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                )
                .padding(.vertical, 1)
            }
        }
    }

    private func matchesFilter(_ entry: TestEntry) -> Bool {
        if filterText.isEmpty { return true }
        let f = filterText.lowercased()
        return entry.name.lowercased().contains(f)
            || (entry.module?.lowercased().contains(f) ?? false)
            || entry.description.lowercased().contains(f)
    }

    private func rowFor(_ entry: TestEntry) -> some View {
        let isSelected = model.selected.contains(entry.id)
        let st = model.status[entry.id] ?? .notRun
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in model.toggle(entry.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(st.symbol)
                .font(.system(.body, design: .monospaced))
                .frame(width: 18)
                .foregroundStyle(statusColor(st))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(.body))
                Text(entry.description).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            durationLabel(st)

            Button("Run") { model.runOne(entry.id) }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.currentlyRunning != nil)
        }
        .contentShape(Rectangle())
        .onTapGesture { inspectedID = entry.id }
        .padding(.vertical, 2)
        .background(inspectedID == entry.id ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    @ViewBuilder
    private func durationLabel(_ st: TestStatus) -> some View {
        switch st {
        case .passed(let dur):
            Text(String(format: "%.1fs", dur))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        case .failed(_, let dur):
            Text(String(format: "%.1fs", dur))
                .font(.caption)
                .foregroundStyle(.red)
                .frame(width: 56, alignment: .trailing)
        case .unclear(_, let dur):
            Text(String(format: "%.1fs", dur))
                .font(.caption)
                .foregroundStyle(.yellow)
                .frame(width: 56, alignment: .trailing)
        default:
            Text(" ")
                .font(.caption)
                .frame(width: 56, alignment: .trailing)
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
