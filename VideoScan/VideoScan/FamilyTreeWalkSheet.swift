// FamilyTreeWalkSheet.swift
// "Walk Tree…" (Rick 2026-09-27). One sheet, one state machine — never a
// sheet that opens another (the chained-sheet antipattern):
//
//   setup ──Walk──▶ walking ──▶ watching (the fan) ──▶ Done
//
// No background walk (Rick 2026-09-27): the analysis takes ~50 ms, and
// FamilyTreeWalkCenter re-walks silently whenever decorations go stale.
// This sheet is for WATCHING a walk (Instant / Skip to end for impatience).
//
// Setup: start people (default Rick + Donna — the tree's home people, the
// pinned owner first; or the selected person; or a bookmarked person) and
// depth (3 / 5 / 7 / 10 / All generations; default 7 — Donna 2026-09-29:
// "fewer generations" reads better on a first look, and All is one click
// away; the Highlight checks keep a deep walk readable). A tree with no
// home people and nobody selected says so instead of guessing.
//
// SIZE (Rick 2026-09-27: "it doesn't fit"). A macOS sheet takes its
// content's size and is NOT clipped to the window it hangs from, so the
// old fixed 600-pt fan + counters + summary ran off both sides of the
// Family Tree window. Now, while walking and watching, the sheet is the
// host window's size less an inset (`watchingSize`), never smaller than
// 640 × 520 (fits a 13" laptop) nor larger than 1,800 × 1,200 (Donna
// 2026-09-29: "a bigger window" — a big display should get a big fan).
// Inside it the fan scales to the space left of a fixed 320-pt side panel,
// and the highlight checks and summary scroll in that panel. The fan's
// canvas is laid out at the size it will be SHOWN (`fanSide`), so a big
// window gets crisp dots rather than a small bitmap scaled up.
//
// (For Rick: `hostSize` is measured by the presenting view with
// `onGeometryChange` — think of it as a resize callback that stores the
// window's content size — and passed in like a constructor argument.)

import SwiftUI
import VideoScanCore

struct FamilyTreeWalkSheet: View {
    @ObservedObject var model: FamilyTreeLiveModel
    @ObservedObject var center: FamilyTreeWalkCenter = .shared
    /// The presenting window's content size (zero = unknown).
    var hostSize: CGSize = .zero
    let onClose: () -> Void

    enum Stage {
        case setup
        case walking(String)
        case watching(TreeWalkAnimator, TreeWalkHighlighter)
        case failed(String)
    }

    @State private var stage: Stage = .setup
    @State private var startChoice = "default"
    @State private var depth = 7          // 0 = all
    @State private var walkTask: Task<Void, Never>?

    static let minimumWatchingSize = CGSize(width: 640, height: 520)
    static let maximumWatchingSize = CGSize(width: 1_800, height: 1_200)

    /// The fan's LOGICAL canvas side (layout + trail bitmap): the square the
    /// sheet will show it in — width left of the side panel, height below
    /// the title and above the buttons — never under 600 (the old fixed
    /// size). The view still scales it, so an estimate that is a little off
    /// only rescales slightly. Trail memory: side × 2 squared × 4 B ≈ 16 MB
    /// at the 1,100-pt maximum-window fan.
    static func fanSide(for sheet: CGSize) -> CGFloat {
        let w = sheet.width - 40 - TreeWalkAnimationView.sidePanelWidth - 16
        let h = sheet.height - 40 - 90
        return max(600, min(w, h).rounded(.down))
    }
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
            case .watching(let animator, let highlighter):
                TreeWalkAnimationView(animator: animator, highlighter: highlighter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                Text(why).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .setup = stage {
                    Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
                    Button("Walk") { walkInForeground() }
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
            Picker("Generations", selection: $depth) {
                Text("3").tag(3)
                Text("5").tag(5)
                Text("7").tag(7)
                Text("10").tag(10)
                Text("All").tag(0)
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
            Text("Decorates everyone with their line, generations, age at death and birth region, and runs the consistency checks. Reads the tree only. The decorations (decorations.json) are kept up to date automatically; only an All-generations walk from the home people replaces them — a shorter walk, or one from someone else, is for watching only. The analysis itself takes moments; the fan then replays it at a pace you choose, so you can watch.")
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
            let side = Self.fanSide(for: Self.watchingSize(host: hostSize))
            let layout = await TreeWalkAnimator.prepare(result, size: CGSize(width: side, height: side))
            let inputs = await TreeWalkHighlighter.prepare(result: result, graph: graph, layout: layout)
            let animator = TreeWalkAnimator(layout: layout, summary: result.summary, displayNames: names)
            stage = .watching(animator, TreeWalkHighlighter(inputs: inputs))
            animator.start()
        }
    }

    private func close() {
        walkTask?.cancel()
        if case .watching(let animator, _) = stage { animator.stop() }
        onClose()
    }
}
