// CleanupPane.swift
// Triage ▸ Cleanup — the page (docs/design/cleanup_kiss_2026_10_12.md).
// One question: "Which files are extra, and can go to the Trash?"
//
//   ☑ Copies           identical full SHA-256, one copy stays   n · GB selected · See files…
//   ☑ Junk you marked  files you marked Confirmed Junk           n · GB selected · See files…
//     Not checked yet  no full hash yet (information only)       n · GB
//   ☐ Include these N marked-junk files from FamilyArchive (only when there are any;
//     off by default, lists the files, resets after each run)
//   Left alone: N files — with each reason (compact, folded)
//   [ Move N files (X GB) to the Trash… ]   → confirm → ONE MFO job (CleanupTrashJob)
//
// PERF: the view reads ONLY `CleanupStore` — the plan (built off-main by
// `VideoScanModel.buildCleanupPlan`) and the cached selection numbers. No
// O(records) work in any body; the per-file lists are the plan's own arrays.
// (For Rick: `CleanupStore` ≈ a small observer-pattern holder; SwiftUI
// redraws the page when one of its @Published members is replaced.)

import Combine
import SwiftUI
import VideoScanCore

// MARK: - Store

@MainActor
final class CleanupStore: ObservableObject {
    /// The app's one store (one catalog, one Triage tab).
    static let shared = CleanupStore()

    /// What the page shows as selected, cached whenever the plan or a tick
    /// changes (never recomputed in a body).
    struct Numbers: Equatable {
        var copies = CleanupPlan.Tally()
        var junk = CleanupPlan.Tally()
        var archiveJunk = CleanupPlan.Tally()
        var bytesToRead: Int64 = 0
        var total: CleanupPlan.Tally {
            CleanupPlan.Tally(files: copies.files + junk.files + archiveJunk.files,
                              bytes: copies.bytes + junk.bytes + archiveJunk.bytes)
        }
    }

    @Published private(set) var plan: CleanupPlan?
    @Published private(set) var builtAt: Date?
    @Published private(set) var isBuilding = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: String?
    @Published private(set) var unticked: Set<UUID> = []
    @Published private(set) var numbers = Numbers()
    @Published var includeCopies = true { didSet { reselect() } }
    @Published var includeJunk = true { didSet { reselect() } }
    /// Rick's per-run tick box (option b): OFF by default, and back off the
    /// moment a run starts with it.
    @Published var includeArchiveJunk = false { didSet { reselect() } }

    /// The frozen set a run would take now.
    private(set) var selection: CleanupSelection?

    /// Rebuild the plan off the main actor; one build at a time. Returns the
    /// build's task (tests await it; the page does not).
    @discardableResult
    func refresh(model: VideoScanModel) -> Task<Void, Never>? {
        guard !isBuilding else { return nil }
        isBuilding = true
        return Task { [weak self] in
            let plan = await model.buildCleanupPlan()
            guard let self else { return }
            self.plan = plan
            self.builtAt = Date()
            let listed = Set(plan.copies.map(\.id) + plan.junk.map(\.id) + plan.archiveJunk.map(\.id))
            self.unticked.formIntersection(listed)
            self.isBuilding = false
            self.reselect()
        }
    }

    func isTicked(_ id: UUID) -> Bool { !unticked.contains(id) }

    func setTicked(_ id: UUID, _ on: Bool) {
        if on { unticked.remove(id) } else { unticked.insert(id) }
        reselect()
    }

    /// Start the one job over exactly what the page shows as selected.
    func start(model: VideoScanModel, center: MediaFileOperationsCenter) {
        guard let selection = beginRun() else { return }
        let job = center.startedByUser { $0.startCleanup(selection: selection, model: model) }
        watch(job, model: model)
    }

    private var jobWatch: AnyCancellable?

    /// Release the page when the job reaches ANY terminal state — refused
    /// before it started, failed early, stopped, or finished — by watching
    /// its state, never by trusting one callback on the happy path (QA
    /// P2-1). `$state` replays the current value on subscribe, so a job
    /// that is already terminal releases at once. The row's subtitle is the
    /// one-line summary in every terminal path.
    func watch(_ job: CleanupTrashJob, model: VideoScanModel) {
        jobWatch = job.$state.sink { [weak self, weak job] state in
            guard !state.isActive, let self, let job else { return }
            self.jobWatch = nil
            self.runFinished(job.subtitle, model: model)
        }
    }

    /// Freeze what runs now and turn the FamilyArchive box back off (Rick:
    /// "per run" — it never carries over to the next one). nil when there
    /// is nothing to run or a run is already going.
    func beginRun() -> CleanupSelection? {
        guard let selection, !selection.isEmpty, !isRunning else { return nil }
        isRunning = true
        includeArchiveJunk = false
        return selection
    }

    private func runFinished(_ line: String, model: VideoScanModel) {
        lastRun = line
        isRunning = false
        includeArchiveJunk = false
        refresh(model: model)
    }

    private func reselect() {
        guard let plan else {
            selection = nil
            numbers = Numbers()
            return
        }
        let s = CleanupSelection(plan: plan, unticked: unticked, includeArchiveJunk: includeArchiveJunk,
                                 includeCopies: includeCopies, includeJunk: includeJunk)
        selection = s
        var n = Numbers()
        for c in s.copies { n.copies.add(c.target.sizeBytes) }
        for j in s.junk { n.junk.add(j.sizeBytes) }
        for j in s.archiveJunk { n.archiveJunk.add(j.sizeBytes) }
        n.bytesToRead = s.bytesToRead
        numbers = n
    }
}

// MARK: - Words (pure — the tests pin them)

enum CleanupWords {
    static let question = "Which files are extra, and can go to the Trash?"

    static func actionTitle(_ total: CleanupPlan.Tally) -> String {
        "Move \(total.files.formatted()) file\(total.files == 1 ? "" : "s") (\(MediaBytes.display(total.bytes))) to the Trash…"
    }

    static func archiveJunkToggle(_ count: Int) -> String {
        count == 1 ? "Include this marked-junk file from FamilyArchive"
                   : "Include these \(count.formatted()) marked-junk files from FamilyArchive"
    }

    /// "about 1.5 hours" at a conservative 200 MB/s (the LaCie HDDs).
    static func readTime(_ bytes: Int64) -> String {
        let secs = Double(bytes) / 200_000_000
        if secs < 90 { return "about a minute" }
        if secs < 5_400 { return "about \(Int((secs / 60).rounded())) minutes" }
        return "about \(String(format: "%.1f", secs / 3600)) hours"
    }

    static func readNote(_ bytesToRead: Int64) -> String? {
        guard bytesToRead > 0 else { return nil }
        return "Before each copy moves, it and the copy that stays are both read in full and must match: "
            + "\(MediaBytes.display(bytesToRead)) to read, \(readTime(bytesToRead)). Run it while you're away."
    }

    static let trashNote = "Files go to their own drive's Trash — Put Back restores them. Nothing is freed until you empty the Trash yourself, and VideoScan never empties it."
}

// MARK: - The page

struct CleanupPane: View {
    let model: VideoScanModel
    @ObservedObject var store: CleanupStore
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenter
    @State private var filesSheet: CleanupFilesSheet.Lane?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            if let plan = store.plan {
                ScrollView { content(plan).padding(14) }
            } else {
                ProgressView("Looking for extra files…").padding(20)
                Spacer()
            }
        }
        .onAppear { if store.plan == nil { store.refresh(model: model) } }
        .sheet(item: $filesSheet) { lane in
            CleanupFilesSheet(lane: lane, store: store)
        }
        .sheet(isPresented: $confirming) {
            CleanupConfirmSheet(numbers: store.numbers, onCancel: { confirming = false }, onConfirm: {
                confirming = false
                start()
            })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleanup").font(.title3.weight(.semibold))
                Text(CleanupWords.question).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let at = store.builtAt {
                Text("Checked \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Refresh") { store.refresh(model: model) }
                .disabled(store.isBuilding)
                .accessibilityIdentifier("cleanup.refresh")
        }
    }

    @ViewBuilder
    private func content(_ plan: CleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Files").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("GB selected").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("")
                }
                laneRow(isOn: $store.includeCopies, title: "Copies", detail: "identical full SHA-256 — one copy stays",
                        tally: store.numbers.copies, listed: plan.copies.count, lane: .copies)
                laneRow(isOn: $store.includeJunk, title: "Junk you marked", detail: "files you marked Confirmed Junk",
                        tally: store.numbers.junk, listed: plan.junk.count, lane: .junk)
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not checked yet").font(.system(size: 13, weight: .medium))
                        Text("no full hash yet — information only (Catalog ▸ Fill In Full Hashes… reads them)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(plan.notChecked.files.formatted()).monospacedDigit()
                    Text(MediaBytes.display(plan.notChecked.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    Text("")
                }
            }
            if !plan.archiveJunk.isEmpty { archiveJunkBox(plan) }
            leftAlone(plan)
            footer
        }
    }

    private func laneRow(isOn: Binding<Bool>, title: String, detail: String, tally: CleanupPlan.Tally,
                         listed: Int, lane: CleanupFilesSheet.Lane) -> some View {
        GridRow {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Text(tally.files.formatted()).monospacedDigit()
            Text(MediaBytes.display(tally.bytes)).monospacedDigit()
            Button("See files…") { filesSheet = lane }
                .disabled(listed == 0)
                .accessibilityIdentifier("cleanup.seeFiles.\(lane.rawValue)")
        }
    }

    private func archiveJunkBox(_ plan: CleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(CleanupWords.archiveJunkToggle(plan.archiveJunk.count), isOn: $store.includeArchiveJunk)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("cleanup.includeArchiveJunk")
                Text(MediaBytes.display(plan.archiveJunkBytes)).monospacedDigit().foregroundStyle(.secondary)
                Button("See files…") { filesSheet = .archiveJunk }
            }
            Text("For this run only — it turns itself off afterwards. Copies on FamilyArchive are never trimmed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    @ViewBuilder
    private func leftAlone(_ plan: CleanupPlan) -> some View {
        let reasons = plan.leftAloneSorted
        if !reasons.isEmpty {
            let files = reasons.reduce(0) { $0 + $1.tally.files }
            let bytes = reasons.reduce(Int64(0)) { $0 + $1.tally.bytes }
            DisclosureGroup("Left alone: \(files.formatted()) files (\(MediaBytes.display(bytes)))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(reasons) { r in
                        Text("\(r.tally.files.formatted()) · \(MediaBytes.display(r.tally.bytes)) — \(r.reason.words)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
    }

    private var footer: some View {
        let total = store.numbers.total
        return VStack(alignment: .leading, spacing: 6) {
            if let note = CleanupWords.readNote(store.numbers.bytesToRead) {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(CleanupWords.trashNote).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(CleanupWords.actionTitle(total)) { confirming = true }
                    .disabled(total.files == 0 || model.isReadOnly || store.isBuilding || store.isRunning || fileOpsCenter == nil)
                    .accessibilityIdentifier("cleanup.moveToTrash")
                if store.isRunning {
                    Text("Running — see Media File Operations").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let last = store.lastRun {
                Text("Last run: \(last)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        guard let center = fileOpsCenter else {
            model.cleanupNote("could not start — the Media File Operations center is not available here. Nothing moved.")
            return
        }
        store.start(model: model, center: center)
    }
}

// MARK: - Sidebar row

/// Triage's sidebar row for the page. Observes only the store, so a plan
/// landing redraws this row, not TriageView.
struct CleanupSidebarRow: View {
    let isSelected: Bool
    let onSelect: () -> Void
    @ObservedObject private var store = CleanupStore.shared

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "trash").foregroundColor(.brown).frame(width: 18)
                Text("Cleanup").lineLimit(1)
                Spacer()
                Text(count).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(isSelected ? 0.16 : 0)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("triage.cleanup")
    }

    /// "N · X GB" selected, "" until the first plan lands.
    private var count: String {
        guard store.plan != nil else { return "" }
        let t = store.numbers.total
        return "\(t.files.formatted()) · \(MediaBytes.display(t.bytes))"
    }
}

// MARK: - See files… (untick to leave a file out of this run)

struct CleanupFilesSheet: View {
    enum Lane: String, Identifiable {
        case copies, junk, archiveJunk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .copies: return "Copies — one copy stays"
            case .junk: return "Junk you marked"
            case .archiveJunk: return "Junk you marked on FamilyArchive"
            }
        }
    }

    let lane: Lane
    @ObservedObject var store: CleanupStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lane.title).font(.title3.weight(.semibold))
            Text("Untick a file to leave it out of this run.").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    switch lane {
                    case .copies: ForEach(store.plan?.copies ?? []) { copyRow($0) }
                    case .junk: ForEach(store.plan?.junk ?? []) { fileRow($0) }
                    case .archiveJunk: ForEach(store.plan?.archiveJunk ?? []) { fileRow($0) }
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 480)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720)
    }

    private func tick(_ id: UUID) -> Binding<Bool> {
        Binding(get: { store.isTicked(id) }, set: { store.setTicked(id, $0) })
    }

    private func copyRow(_ c: CleanupPlan.Copy) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: tick(c.id)) {
                Text("\(c.target.filename) · \(c.target.volumeName) · \(MediaBytes.display(c.target.sizeBytes))")
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .help(c.target.path)
            Text("stays: \(c.keeper.path)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 20)
        }
    }

    private func fileRow(_ f: CleanupFile) -> some View {
        Toggle(isOn: tick(f.id)) {
            Text("\(f.filename) · \(f.volumeName) · \(MediaBytes.display(f.sizeBytes))")
                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        .help(f.path)
    }
}

// MARK: - Confirm

struct CleanupConfirmSheet: View {
    let numbers: CleanupStore.Numbers
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CleanupWords.actionTitle(numbers.total).replacingOccurrences(of: "…", with: "?"))
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                if numbers.copies.files > 0 {
                    Text("Copies: \(numbers.copies.files.formatted()) (\(MediaBytes.display(numbers.copies.bytes)))")
                }
                if numbers.junk.files > 0 {
                    Text("Junk you marked: \(numbers.junk.files.formatted()) (\(MediaBytes.display(numbers.junk.bytes)))")
                }
                if numbers.archiveJunk.files > 0 {
                    Text("Junk you marked on FamilyArchive: \(numbers.archiveJunk.files.formatted()) (\(MediaBytes.display(numbers.archiveJunk.bytes)))")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 13))
            if let note = CleanupWords.readNote(numbers.bytesToRead) {
                Text(note).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Any file that has changed, can't be read, or whose copy that stays isn't connected is left where it is, and named in the result.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(CleanupWords.trashNote).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)   // Cancel is the default (Return)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .accessibilityIdentifier("cleanup.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }
}
