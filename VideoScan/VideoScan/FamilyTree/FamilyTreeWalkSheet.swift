// FamilyTreeWalkSheet.swift
// "Walk Tree…" (Rick 2026-09-27). One sheet, one state machine — never a
// sheet that opens another (the chained-sheet antipattern):
//
//   setup ──Walk──▶ walking ──▶ watching (the fan) ◀──▶ map ──▶ Done
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
// MAP (GH #227, Rick 2026-09-29): once the replay has finished, "Show on
// map" (beside Done, and from the Highlight panel's places) swaps the fan
// for the Family Map — the same walk, the same Highlight checks, shaded by
// birthplace. "Back to the fan" restores `.watching` with the SAME animator
// and highlighter: the walk is never re-run and the fan is exactly as it
// was. The map model is built once per walk (off-main) and kept, so the
// second "Show on map" is instant.
//
// ROLL CALL (Rick 2026-10-01): the FIRST "Show on map" of a walk also
// starts the Roll Call — end credits of the walked family drifting over the
// content area while the map assembles underneath (FamilyTreeRollCall). It
// is not a stage and not a sheet: an overlay on top of whatever stage is
// showing, so the map keeps building behind it and a click or Esc simply
// removes it. The map's "Roll Call" button replays it (default oldest →
// newest; its menu offers the other orders). The credits are prepared once
// per walk and order, off-main, and cached here — a replay is instant.
//
// SIZE (Rick 2026-09-27: "it doesn't fit"). A macOS sheet takes its
// content's size and is NOT clipped to the window it hangs from, so the
// old fixed 600-pt fan + counters + summary ran off both sides of the
// Family Tree window. Now, while walking, watching and on the map, the
// sheet is the host window's size less an inset (`watchingSize`), never
// smaller than 640 × 520 (fits a 13" laptop) nor larger than 1,800 × 1,200
// (Donna 2026-09-29: "a bigger window" — a big display should get a big
// fan). Inside it the fan scales to the space left of a fixed 320-pt side
// panel, and the highlight checks and summary scroll in that panel. The
// fan's canvas is laid out at the size it will be SHOWN (`fanSide`), so a
// big window gets crisp dots rather than a small bitmap scaled up.
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
        case map(TreeWalkAnimator, TreeWalkHighlighter, FamilyMapModel)
        case failed(String)
    }

    @State private var stage: Stage = .setup
    @State private var startChoice = "default"
    @State private var depth = 7          // 0 = all
    @State private var walkTask: Task<Void, Never>?
    /// The finished walk, kept for the map (built from it once).
    @State private var walkResult: TreeWalk.Result?
    @State private var mapModel: FamilyMapModel?
    @State private var mapTask: Task<Void, Never>?
    @State private var mapProblem: String?
    /// The Roll Call now showing (nil = none), the prepared credits per
    /// order for this walk, and the preparation in flight.
    @State private var rollCall: RollCallPlayback?
    @State private var rollCallCache: [RollCall.Order: RollCallPlayback] = [:]
    @State private var rollCallTask: Task<Void, Never>?
    /// Credits or Drifting names — chosen in the map's Roll Call menu.
    @AppStorage(RollCallStyle.storageKey) private var rollCallStyleRaw = RollCallStyle.credits.rawValue

    /// The order the Roll Call plays in unless asked otherwise.
    static let defaultRollCallOrder: RollCall.Order = .oldestFirst

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
        case .walking, .watching, .map: return true
        case .setup, .failed: return false
        }
    }

    var body: some View {
        let size = Self.watchingSize(host: hostSize)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: titleSymbol)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            stageContent
                .overlay {
                    if let rollCall {
                        RollCallOverlay(playback: rollCall,
                                        style: RollCallStyle(rawValue: rollCallStyleRaw) ?? .credits) {
                            // Only the showing that finished clears itself
                            // (a replay started meanwhile has a new id).
                            if self.rollCall?.id == rollCall.id { self.rollCall = nil }
                        }
                        .id(rollCall.id)
                        .transition(.opacity)
                    }
                }
            HStack {
                if let mapProblem {
                    Text(mapProblem).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch stage {
                case .setup:
                    Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
                    Button("Walk") { walkInForeground() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(starts.isEmpty)
                case .watching(let animator, let highlighter):
                    ShowOnMapButton(animator: animator, busy: mapTask != nil) { showMap(animator, highlighter) }
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                case .map(let animator, let highlighter, _):
                    Button("Back to the fan") { stage = .watching(animator, highlighter) }
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                case .walking, .failed:
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: isLarge ? size.width : 520, height: isLarge ? size.height : nil)
        .onDisappear { walkTask?.cancel(); mapTask?.cancel(); rollCallTask?.cancel() }
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .setup: setup
        case .walking(let phase):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(phase).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .watching(let animator, let highlighter):
            TreeWalkAnimationView(animator: animator, highlighter: highlighter,
                                  onShowMap: { showMap(animator, highlighter) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .map(let animator, let highlighter, let map):
            FamilyTreeMapView(model: map, highlighter: highlighter,
                              onBack: { stage = .watching(animator, highlighter) },
                              onRollCall: { order in playRollCall(highlighter, order: order) },
                              rollCallBusy: rollCallTask != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            Text(why).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        if case .map = stage { return "Where the Family Was Born" }
        return "Walk the Family Tree"
    }

    private var titleSymbol: String {
        if case .map = stage { return "map.circle" }
        return "figure.walk.circle"
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
            Text("Decorates everyone with their line, generations, age at death and birth region, and runs the consistency checks. Reads the tree only. The decorations (decorations.json) are kept up to date automatically; only an All-generations walk from the home people replaces them — a shorter walk, or one from someone else, is for watching only. The analysis itself takes moments; the fan then replays it at a pace you choose, so you can watch. When it finishes, Show on map shades the places they were born.")
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
        walkResult = nil
        mapModel = nil
        mapProblem = nil
        rollCallTask?.cancel()
        rollCallTask = nil
        rollCall = nil
        rollCallCache = [:]
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
            walkResult = result
            stage = .watching(animator, TreeWalkHighlighter(inputs: inputs))
            animator.start()
        }
    }

    // MARK: The map

    /// Build the map model once per walk (bundled borders once per process,
    /// the birthplaces resolved once off-main), then switch stages. A
    /// second call while the first is still building is ignored. The FIRST
    /// call of a walk also starts the Roll Call over the content while the
    /// map assembles.
    private func showMap(_ animator: TreeWalkAnimator, _ highlighter: TreeWalkHighlighter) {
        if let mapModel {
            stage = .map(animator, highlighter, mapModel)
            return
        }
        guard mapTask == nil, let result = walkResult, let graph else { return }
        mapProblem = nil
        let names = animator.displayNames
        // The family's own knowledge fills the tree's gaps (Rick 2026-09-29):
        // the CyberBrain the tree already loaded, read-only; nil = tree only.
        let familyKnowledge = model.walkFamilyKnowledge
        playRollCall(highlighter, order: Self.defaultRollCallOrder)
        mapTask = Task { @MainActor in
            defer { mapTask = nil }
            do {
                let units = try await FamilyMapUnitsCache.shared.units()
                let inputs = await FamilyMapModel.prepare(result: result, graph: graph, highlight: highlighter.inputs,
                                                          familyKnowledge: familyKnowledge)
                guard !Task.isCancelled else { return }
                let map = FamilyMapModel(inputs: inputs, units: units, displayNames: names)
                // bind replays the highlighter's current selection, so it IS
                // the first tally; a second `apply` here counted twice.
                map.bind(to: highlighter)
                mapModel = map
                stage = .map(animator, highlighter, map)
            } catch {
                mapProblem = "The map could not be shown: \(error)"
                // A decode / missing-resource error: no names in it.
                appLog.write("Family map: could not be shown — \(error)")
            }
        }
    }

    // MARK: Roll Call

    /// Show the Roll Call in `order`: from the cache when this walk already
    /// prepared it, else prepared off-main first (a fraction of a second;
    /// the overlay appears when it is ready). A request while one is being
    /// prepared is ignored.
    private func playRollCall(_ highlighter: TreeWalkHighlighter, order: RollCall.Order) {
        // Every 3rd play is a shuffled mix (Rick 2026-10-04) — prepared
        // fresh, never from or into the cache, so the usual picks stay put.
        let mixSeed: UInt64? = RollCallMix.advance() ? UInt64.random(in: .min ... .max) : nil
        if mixSeed == nil, let cached = rollCallCache[order] {
            rollCall = cached.replay()
            appLog.write("Roll Call: replay (\(cached.entries.count) names, \(order.rawValue))")
            return
        }
        guard rollCallTask == nil, let result = walkResult, let graph else { return }
        let knowledge = model.walkFamilyKnowledge
        let flags = model.birthCountries
        // The WALK's home people (the setup picker may have moved since).
        let names = FamilyTreeWalkCenter.displayNames(for: result.starts.map(\.id), in: graph, speakers: .fromDefaults())
        let visited = highlighter.inputs.visited
        // The inner circle is the TREE's home people, whoever this walk
        // started from (QA P2-A).
        let owner = HallieTurnExecutor.Speakers.fromDefaults().ownerFamilySearchID
        let assets: FamilyAssetConfiguration? = TestEnvironment.isTestHost
            ? nil : FamilyAssetConfigurationCenter.shared.snapshot()
        rollCallTask = Task { @MainActor in
            defer { rollCallTask = nil }
            let playback = await RollCallPlayback.prepare(result: result, graph: graph, visited: visited,
                                                          knowledge: knowledge, displayNames: names,
                                                          birthCountries: flags, assets: assets,
                                                          ownerFamilySearchID: owner, order: order,
                                                          shuffleSeed: mixSeed)
            guard !Task.isCancelled else { return }
            if mixSeed == nil { rollCallCache[order] = playback }
            guard !playback.entries.isEmpty else {
                appLog.write("Roll Call: nobody to show for this walk")
                return
            }
            rollCall = playback
            appLog.write("Roll Call: \(playback.entries.count) names of \(playback.walked.formatted()) walked, "
                + "\(playback.portraits.count) portraits, \(Int(playback.duration)) s, \(order.rawValue)"
                + (playback.isMix ? ", mix" : "") + ", \(rollCallStyleRaw)")
        }
    }

    private func close() {
        walkTask?.cancel()
        mapTask?.cancel()
        rollCallTask?.cancel()
        rollCall = nil
        switch stage {
        case .watching(let animator, _), .map(let animator, _, _): animator.stop()
        default: break
        }
        onClose()
    }
}

/// "Show on map", enabled once the replay has finished. Its own view so it
/// observes the animator's frame; the sheet holds the animator in an enum
/// payload and would not otherwise re-render when the replay ends.
struct ShowOnMapButton: View {
    @ObservedObject var animator: TreeWalkAnimator
    var busy = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Button("Show on map") { action() }
                .disabled(!animator.frame.finished || busy)
                .help(animator.frame.finished ? "Shade the places they were born" : "Available when the replay finishes")
        }
    }
}
