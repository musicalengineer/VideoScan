// ContentView.swift
//
// The whole TestDriver UI in one file for now — DisclosureGroup outline
// of registered tests, per-row checkbox, status badge, "Run Selected"
// button, side pane with the live log of whatever's currently running.

import SwiftUI

@MainActor
final class TestDriverModel: ObservableObject {
    @Published var groups: [(TestGroup, [TestEntry])] = []
    @Published var selected: Set<String> = []                 // entry.id values
    @Published var status: [String: TestStatus] = [:]         // entry.id → status
    @Published var logs: [String: String] = [:]               // entry.id → full log
    @Published var liveLog: String = ""
    @Published var currentlyRunning: String?
    @Published var allowStress: Bool = false
    @Published var summaryText: String = ""

    private var runTask: Task<Void, Never>?

    init() {
        VideoScanTests.registerAll()
        rebuildGroups()
        for entry in TestRegistry.shared.all() {
            status[entry.id] = .notRun
            logs[entry.id] = ""
        }
    }

    func rebuildGroups() {
        let all = TestRegistry.shared.grouped()
        if allowStress {
            groups = all
        } else {
            groups = all.filter { !$0.0.requiresOptIn }
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

    func clearAll() { selected.removeAll() }

    /// Run the selected tests serially. We default to serial because some
    /// of the registry's tests (xcodebuild) collide on derived-data; later
    /// the model can grow a per-test "isParallelSafe" flag.
    func runSelected() {
        guard runTask == nil else { return }
        let toRun = TestRegistry.shared.all().filter { selected.contains($0.id) }
        guard !toRun.isEmpty else {
            summaryText = "Nothing selected."
            return
        }
        summaryText = "Running \(toRun.count) test(s)..."
        for entry in toRun {
            status[entry.id] = .notRun
            logs[entry.id] = ""
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            var passed = 0
            var failed = 0
            var skipped = 0
            for entry in toRun {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.currentlyRunning = entry.id
                    self.status[entry.id] = .running
                    self.liveLog = "▶ \(entry.group.rawValue) / \(entry.name)\n"
                }
                let logBuffer = LineBuffer()
                let result = await entry.run { line in
                    Task { @MainActor in
                        self.liveLog += line + "\n"
                    }
                    logBuffer.append(line)
                }
                await MainActor.run {
                    self.status[entry.id] = result.status
                    self.logs[entry.id] = logBuffer.snapshot() + (result.log.isEmpty ? "" : "\n--- result.log ---\n" + result.log)
                    switch result.status {
                    case .passed:  passed += 1
                    case .failed:  failed += 1
                    case .skipped: skipped += 1
                    default: break
                    }
                }
            }
            await MainActor.run {
                self.currentlyRunning = nil
                self.summaryText = "Done — \(passed) passed, \(failed) failed, \(skipped) skipped."
                self.runTask = nil
            }
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func runOne(_ id: String) {
        selected = [id]
        runSelected()
    }
}

/// Tiny thread-safe line buffer for streaming log capture.
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
    @State private var expanded: Set<TestGroup> = Set(TestGroup.allCases)
    @State private var inspectedID: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.groups, id: \.0) { group, entries in
                            groupSection(group: group, entries: entries)
                        }
                    }
                    .padding(8)
                }
                Divider()
                summaryBar
            }
            .frame(minWidth: 480)

            VStack(alignment: .leading, spacing: 0) {
                Text(inspectedID.flatMap(TestRegistry.shared.entry(id:))?.name ?? "Live log")
                    .font(.headline)
                    .padding(8)
                Divider()
                ScrollView {
                    Text(displayedLog)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            }
            .frame(minWidth: 380)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var displayedLog: String {
        if let inspected = inspectedID, let stored = model.logs[inspected], !stored.isEmpty {
            return stored
        }
        return model.liveLog
    }

    private var toolbar: some View {
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
                model.selected = Set(TestRegistry.shared.all().map(\.id))
            }
            Button("Clear") { model.clearAll() }

            Spacer()

            Toggle(isOn: $model.allowStress) {
                Text("Show stress tests").font(.caption)
            }
            .onChange(of: model.allowStress) { _, _ in model.rebuildGroups() }
            .toggleStyle(.checkbox)
        }
        .padding(8)
    }

    private var summaryBar: some View {
        HStack {
            Text(model.summaryText.isEmpty ? "Idle" : model.summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let running = model.currentlyRunning,
               let entry = TestRegistry.shared.entry(id: running) {
                Text("Running: \(entry.name)")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
        }
        .padding(8)
    }

    private func groupSection(group: TestGroup, entries: [TestEntry]) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(group) },
                set: { isOpen in
                    if isOpen { expanded.insert(group) } else { expanded.remove(group) }
                }
            ),
            content: {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        rowFor(entry)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 4)
            },
            label: {
                HStack {
                    Text(group.rawValue)
                        .font(.headline)
                    Text("(\(entries.count))")
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

            if case .passed(let dur) = st {
                Text(String(format: "%.1fs", dur))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            } else if case .failed(_, let dur) = st {
                Text(String(format: "%.1fs", dur))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 48, alignment: .trailing)
            }

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

    private func statusColor(_ s: TestStatus) -> Color {
        switch s {
        case .notRun:  return .secondary
        case .running: return .orange
        case .passed:  return .green
        case .failed:  return .red
        case .skipped: return .secondary
        }
    }
}
