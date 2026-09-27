// FamilyTreeWalkSheet.swift
// "Walk Tree…" (Rick 2026-09-27). One sheet, one state machine — never a
// sheet that opens another (the chained-sheet antipattern):
//
//   setup ──Walk in foreground──▶ walking ──▶ watching (the fan) ──▶ Done
//     └────Walk in background──▶ MFO row "Walk Tree", sheet closes
//
// Setup: start people (default Rick + Donna — the tree's home people, the
// pinned owner first; or the selected person; or a bookmarked person) and
// depth (All / 3 / 5 / 10 generations). A tree with no home people and
// nobody selected says so instead of guessing.
//
// SIZE (Rick 2026-09-27: "it doesn't fit"). A macOS sheet takes its
// content's size and is NOT clipped to the window it hangs from, so the
// old fixed 600-pt fan + counters + summary ran off both sides of the
// Family Tree window. Now, while walking and watching, the sheet is the
// host window's size less an inset (`watchingSize`), never smaller than
// 640 × 520 (fits a 13" laptop) nor larger than 1,100 × 860. Inside it the
// fan scales to the space left of a fixed 300-pt side panel, and the
// summary scrolls in that panel.
//
// (For Rick: `hostSize` is measured by the presenting view with
// `onGeometryChange` — think of it as a resize callback that stores the
// window's content size — and passed in like a constructor argument.)

import SwiftUI
import VideoScanCore

struct FamilyTreeWalkSheet: View {
    @ObservedObject var model: FamilyTreeLiveModel
    @ObservedObject var center: FamilyTreeWalkCenter = .shared
    let operations: MediaFileOperationsCenter?
    /// The presenting window's content size (zero = unknown).
    var hostSize: CGSize = .zero
    let onClose: () -> Void

    enum Stage {
        case setup
        case walking(String)
        case watching(TreeWalkAnimator)
        case failed(String)
    }

    @State private var stage: Stage = .setup
    @State private var startChoice = "default"
    @State private var depth = 0          // 0 = all
    @State private var walkTask: Task<Void, Never>?

    /// The fan's LOGICAL canvas (layout + trail bitmap). The view scales it
    /// to whatever room the sheet has.
    static let fanSize = CGSize(width: 600, height: 600)

    static let minimumWatchingSize = CGSize(width: 640, height: 520)
    static let maximumWatchingSize = CGSize(width: 1_100, height: 860)
    static let hostInset: CGFloat = 48

    /// The sheet's size while walking / watching, from the host window's.
    static func watchingSize(host: CGSize) -> CGSize {
        guard host.width > 0, host.height > 0 else { return CGSize(width: 900, height: 700) }
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        return CGSize(width: clamp(host.width - hostInset, minimumWatchingSize.width, maximumWatchingSize.width),
                      height: clamp(host.height - hostInset, minimumWatchingSize.height, maximumWatchingSize.height))
    }

    private var isLarge: Bool {
        switch stage {
        case .walking, .watching: return true
        case .setup, .failed: return false
        }
    }

    var body: some View {
        let size = Self.watchingSize(host: hostSize)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Walk the Family Tree", systemImage: "figure.walk.circle")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            switch stage {
            case .setup: setup
            case .walking(let phase):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(phase).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .watching(let animator):
                TreeWalkAnimationView(animator: animator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                Text(why).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .setup = stage {
                    Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
                    Button("Walk in background") { walkInBackground() }
                        .disabled(starts.isEmpty || operations == nil)
                        .help(operations == nil ? "The Media File Operations window is not available here." : "Run as a row in the Media File Operations window.")
                    Button("Walk in foreground") { walkInForeground() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(starts.isEmpty)
                } else {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: isLarge ? size.width : 520, height: isLarge ? size.height : nil)
        .onDisappear { walkTask?.cancel() }
    }

    // MARK: Setup

    private var graph: GedcomFamilyGraph? { model.walkGraph }

    private var defaultStarts: [String] {
        guard let graph else { return [] }
        return FamilyTreeWalkCenter.defaultStarts(
            in: graph, ownerFamilySearchID: HallieTurnExecutor.Speakers.fromDefaults().ownerFamilySearchID)
    }

    private var starts: [String] {
        switch startChoice {
        case "default": return defaultStarts
        case "selected": return model.selectedID.map { [$0] } ?? []
        default:
            return startChoice.hasPrefix("bm:") ? [String(startChoice.dropFirst(3))] : []
        }
    }

    private func name(_ id: String) -> String { graph?.people[id]?.name ?? id }

    @ViewBuilder private var setup: some View {
        let home = defaultStarts
        Form {
            Picker("Start from", selection: $startChoice) {
                Text(home.isEmpty ? "Home people (none in this tree)" : home.map(name).joined(separator: " + "))
                    .tag("default")
                if let selected = model.selectedPerson, !home.contains(selected.id) {
                    Text("Selected: \(selected.name)").tag("selected")
                }
                let bookmarks = model.walkBookmarkedPeople.prefix(12)
                if !bookmarks.isEmpty {
                    Divider()
                    ForEach(Array(bookmarks), id: \.id) { p in
                        Text("Bookmark: \(p.name)").tag("bm:" + p.id)
                    }
                }
            }
            Picker("Depth", selection: $depth) {
                Text("All").tag(0)
                Text("3 generations").tag(3)
                Text("5 generations").tag(5)
                Text("10 generations").tag(10)
            }
            .pickerStyle(.segmented)
        }
        if starts.isEmpty {
            Text(graph == nil
                 ? "No family tree is loaded — get a tree first."
                 : "This tree names no home people, so there is no one to start from. Select someone in the tree (or a bookmark) and walk from them.")
                .font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Decorates everyone with their line, generations, age at death and birth region, and runs the consistency checks. Reads the tree only; the results are saved beside it (decorations.json). The analysis itself takes moments; in the foreground the fan then replays it at a pace you choose, so you can watch.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: TreeWalk.Options {
        TreeWalk.Options(starts: starts, maxGenerations: depth == 0 ? nil : depth)
    }

    private var displayNames: [String] {
        guard let graph else { return [] }
        return FamilyTreeWalkCenter.displayNames(for: starts, in: graph, speakers: .fromDefaults())
    }

    // MARK: Running

    private func walkInForeground() {
        guard let graph else { return }
        let options = options, names = displayNames
        stage = .walking("Analysing \(graph.people.count.formatted()) people…")
        walkTask = Task { @MainActor in
            let result = await center.run(graph: graph, options: options, mode: .foreground,
                                          displayNames: names) { event in
                if case .phase(let phase) = event { stage = .walking(phase + "…") }
            }
            guard let result else {
                if !Task.isCancelled { stage = .failed(center.recentLines.last ?? "The walk did not finish.") }
                return
            }
            let layout = await TreeWalkAnimator.prepare(result, size: Self.fanSize)
            let animator = TreeWalkAnimator(layout: layout, summary: result.summary, displayNames: names)
            stage = .watching(animator)
            animator.start()
        }
    }

    private func walkInBackground() {
        guard let graph, let operations else { return }
        operations.startWalkTree(graph: graph, options: options, displayNames: displayNames)
        onClose()
    }

    private func close() {
        walkTask?.cancel()
        if case .watching(let animator) = stage { animator.stop() }
        onClose()
    }
}
