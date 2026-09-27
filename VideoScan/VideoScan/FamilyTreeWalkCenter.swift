// FamilyTreeWalkCenter.swift
// The app side of the Family Tree WALK (Rick 2026-09-27): runs the Core
// walker (TreeWalk) off the main actor, writes the audit lines through ONE
// sink, saves decorations.json, and serves decorations to the inspector.
//
// Who calls it:
//   • the Walk Tree sheet (foreground: run, then the animation replays the
//     walk's layers),
//   • the Family Tree model, whenever the installed tree changes (a load,
//     a FamilySearch refresh / re-pull / recompile, an identity ruling) —
//     `treeDidChange` → a SILENT re-walk if decorations.json is missing or
//     stale (see "Automatic refresh" below),
//   • the inspector's decoration panel (read-only lookup, O(1) per person).
//
// There is no background MFO walk any more (Rick 2026-09-27: "the whole
// walk takes ~50 ms, so a user-started background walk is pointless") —
// the automatic refresh keeps decorations current, the sheet is for
// watching.
//
// LOGGING — one sink, three destinations (Rick's standard):
//   console + catalog.log   via the catalog model's `log` (DashboardState)
//   videoscan.log           via `appLog`
//   unified log             Logger(subsystem: "Rick-Breen.VideoScan", category: "treeWalk")
// The lines themselves are composed in Core (TreeWalkLog) from the walk's
// event stream, so the per-person work never formats a string. A foreground
// walk logs START / PROGRESS / CHECKS (capped) / OUTCOME; an automatic
// refresh logs exactly ONE line.
//
// (For Rick: `@MainActor final class … ObservableObject` ≈ a UI-thread-only
// object whose `@Published` members notify SwiftUI views when set. The walk
// itself runs in `TreeWalk.events`, which is a detached task — a worker
// thread — so nothing here blocks the UI. `Task.sleep` in the debounce is a
// cancellable timer: a newer change cancels the pending one, like
// restarting a one-shot timer.)

import Combine
import Foundation
import OSLog
import VideoScanCore

private let walkLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "treeWalk")

@MainActor
final class FamilyTreeWalkCenter: ObservableObject {

    static let shared = FamilyTreeWalkCenter()

    /// The decorations for the tree now loaded, when current (nil when
    /// absent, stale or not yet read).
    @Published private(set) var stored: TreeWalkStored?
    /// One line for the inspector when there are no decorations to show
    /// ("The tree has changed since the last walk — walk again").
    @Published private(set) var status: String?
    /// A foreground walk (the sheet) is running.
    @Published private(set) var isRunning = false
    /// An automatic refresh is walking right now.
    @Published private(set) var isRefreshing = false
    /// How the inspector names the start people's lines ("Rick", "Donna").
    @Published private(set) var displayNames: [String] = []

    /// Where decorations.json lives. Injected by tests; production is App
    /// Support/VideoScan/family-tree/decorations.json.
    var storeURL: URL? = TreeWalkStore.defaultURL()
    /// Console + catalog.log writer (the catalog model's `log`). Set by the
    /// Family Tree view; nil in tests (then only videoscan.log is written).
    var consoleLog: ((String) -> Void)?
    /// Every line also lands here — tests read it.
    private(set) var recentLines: [String] = []
    static let recentLineLimit = 400

    /// Identity of the graph whose decorations were last looked up, so a
    /// tab switch does not re-hash the tree. The real staleness test is the
    /// source key (TreeWalkStore).
    private var loadedGraphIdentity: String?

    init() {}

    // MARK: Reading (inspector)

    func decoration(for personID: String) -> TreeWalk.Decoration? { stored?.people[personID] }
    func checks(for personID: String) -> [TreeWalk.Check] { stored?.checks(for: personID) ?? [] }

    /// Cheap identity: counts, roots and the source fingerprint. A change
    /// here triggers a (background) source-key check.
    nonisolated static func identity(of graph: GedcomFamilyGraph) -> String {
        "\(graph.people.count)|\(graph.familyCount)|\(graph.rootPersonIDs.joined(separator: ","))|"
            + "\(graph.sourceFingerprint ?? "-")|\(graph.suppressedPersonIDs.count)"
    }

    /// Read decorations.json for `graph` off the main actor, once per graph.
    func ensureLoaded(for graph: GedcomFamilyGraph?,
                      speakers: HallieTurnExecutor.Speakers = .fromDefaults()) async {
        guard let graph else { stored = nil; status = nil; return }
        let identity = Self.identity(of: graph)
        guard identity != loadedGraphIdentity, let url = storeURL else { return }
        loadedGraphIdentity = identity
        let outcome = await Self.loadOutcome(url: url, graph: graph)
        apply(outcome)
        if case .current(let s) = outcome {
            displayNames = Self.displayNames(for: s.starts.map(\.id), in: graph, speakers: speakers)
        }
    }

    /// The store's verdict for `graph`, computed off the main actor (the
    /// source key hashes the tree).
    nonisolated static func loadOutcome(url: URL, graph: GedcomFamilyGraph) async -> TreeWalkStore.LoadOutcome {
        await Task.detached(priority: .utility) {
            TreeWalkStore.load(from: url, expectedSourceKey: TreeWalkStore.sourceKey(of: graph))
        }.value
    }

    func apply(_ outcome: TreeWalkStore.LoadOutcome) {
        switch outcome {
        case .current(let s):
            stored = s
            status = nil
        case .absent:
            stored = nil
            status = "The tree has not been walked yet — it will be shortly (or use Walk Tree… to watch)."
        case .stale(let reason):
            stored = nil
            status = "The last walk is out of date (\(reason)) — refreshing."
            write("Walk Tree: decorations.json is stale — \(reason); will be rebuilt by the next walk")
        case .unreadable(let reason):
            stored = nil
            status = "The last walk could not be read — refreshing."
            write("Walk Tree: \(reason); will be rebuilt by the next walk")
        }
    }

    // MARK: Start people

    /// Rick + Donna by default: the tree's roots (a merged tree names both),
    /// the pinned owner first when he is one of them. A tree with no roots
    /// but a pinned owner starts from him. Empty = nothing to start from.
    nonisolated static func defaultStarts(in graph: GedcomFamilyGraph, ownerFamilySearchID: String?) -> [String] {
        var ids = graph.roots.map(\.id)
        if let owner = graph.person(familySearchID: ownerFamilySearchID) {
            ids.removeAll { $0 == owner.id }
            ids.insert(owner.id, at: 0)
        }
        return Array(ids.prefix(2))
    }

    /// How the log names each start: the owner's configured first name for
    /// the pinned owner ("Rick"), else the first given name ("Donna").
    nonisolated static func displayNames(for starts: [String], in graph: GedcomFamilyGraph,
                                         speakers: HallieTurnExecutor.Speakers) -> [String] {
        let owner = graph.person(familySearchID: speakers.ownerFamilySearchID)
        return starts.map { id in
            if id == owner?.id, let first = speakers.ownerName?.split(separator: " ").first {
                return String(first)
            }
            return graph.people[id].map(FamilyTreeLiveModel.firstGivenName) ?? id
        }
    }

    // MARK: Running (foreground)

    /// Run one walk. `onEvent` sees every event (the sheet drives its
    /// progress from it). Logs, saves, installs the result.
    /// Returns the result, or nil when cancelled / failed.
    @discardableResult
    func run(graph: GedcomFamilyGraph, options: TreeWalk.Options, mode: TreeWalkLog.Mode,
             displayNames: [String], onEvent: @escaping (TreeWalk.Event) -> Void = { _ in }) async -> TreeWalk.Result? {
        isRunning = true
        defer { isRunning = false }
        self.displayNames = displayNames
        loadedGraphIdentity = Self.identity(of: graph)
        var sink = TreeWalkLog.Sink(TreeWalkLog(mode: mode, displayNames: displayNames))
        var result: TreeWalk.Result?
        var sawTerminal = false
        for await event in TreeWalk.events(graph: graph, options: options) {
            onEvent(event)
            switch event {
            case .finished(let r):
                result = r
                sawTerminal = true
                let saved = await save(r)
                for line in sink.lines(for: event, savedNote: saved) { write(line) }
            case .failed, .cancelled:
                sawTerminal = true
                for line in sink.lines(for: event) { write(line) }
            default:
                for line in sink.lines(for: event) { write(line) }
            }
        }
        if !sawTerminal {
            // The stream ended without a verdict: the consumer was
            // cancelled (the task was stopped). Still one OUTCOME line.
            for line in sink.lines(for: .cancelled) { write(line) }
        }
        return result
    }

    // MARK: Automatic refresh (Rick 2026-09-27)
    //
    // The tree changed → after `refreshDebounce` of quiet (a burst of
    // changes = ONE walk), and never while a foreground walk runs (it waits
    // for it; that walk's own save usually makes the refresh unnecessary):
    //   decorations current for this tree → nothing (no log line);
    //   missing / stale / unreadable       → walk the whole ancestry of the
    //     default start people, silently, save, ONE log line.

    /// Quiet time after the last change before re-walking. Tests shorten it.
    var refreshDebounce: Duration = .seconds(2)
    /// The pinned owner (for the default start people). Tests inject.
    var ownerFamilySearchID: () -> String? = { HallieTurnExecutor.Speakers.fromDefaults().ownerFamilySearchID }
    var speakers: () -> HallieTurnExecutor.Speakers = { .fromDefaults() }
    /// Completed automatic walks (tests).
    private(set) var automaticWalkCount = 0
    private var refreshTask: Task<Void, Never>?
    private var pendingReasons: [String] = []

    /// The installed tree changed. `reason` goes in the log line ("tree
    /// loaded", "tree refreshed", "identity ruling"); reasons coalesce
    /// across a burst.
    func treeDidChange(_ graph: GedcomFamilyGraph?, reason: String) {
        refreshTask?.cancel()
        guard let graph else {
            pendingReasons = []
            refreshTask = nil
            return
        }
        if !pendingReasons.contains(reason) { pendingReasons.append(reason) }
        let debounce = refreshDebounce
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }   // superseded by a newer change
            await self?.refreshIfStale(graph)
        }
    }

    /// Await the pending refresh (tests; nil when none).
    func waitForRefresh() async { await refreshTask?.value }

    private func refreshIfStale(_ graph: GedcomFamilyGraph) async {
        // Never alongside a foreground walk: wait until it ends.
        if isRunning {
            for await running in $isRunning.values where !running { break }
        }
        guard !Task.isCancelled, let url = storeURL else { return }
        let reason = pendingReasons.joined(separator: ", ")
        pendingReasons = []
        let identity = Self.identity(of: graph)
        // The SOURCE KEY decides (it hashes every fact the walker reads,
        // rulings included — `identity` would miss a redirect-only ruling).
        // Compare with the installed copy first; read the file only if needed.
        let key = await Task.detached(priority: .utility) { TreeWalkStore.sourceKey(of: graph) }.value
        guard !Task.isCancelled else { return }
        if let stored, stored.sourceKey == key, stored.walkerVersion == TreeWalk.walkerVersion {
            loadedGraphIdentity = identity
            return
        }
        let outcome = await Task.detached(priority: .utility) {
            TreeWalkStore.load(from: url, expectedSourceKey: key)
        }.value
        guard !Task.isCancelled else { return }
        if case .current = outcome {
            loadedGraphIdentity = identity
            apply(outcome)
            return
        }
        let starts = Self.defaultStarts(in: graph, ownerFamilySearchID: ownerFamilySearchID())
        guard !starts.isEmpty else {
            write(TreeWalkLog.notRefreshedLine("this tree names no home people to walk from", reason: reason))
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var result: TreeWalk.Result?
        var failure = "the walk did not finish"
        for await event in TreeWalk.events(graph: graph, options: TreeWalk.Options(starts: starts)) {
            switch event {
            case .finished(let r): result = r
            case .failed(let why): failure = why
            case .cancelled: failure = "stopped before it finished"
            default: break
            }
        }
        guard let result else {
            write(TreeWalkLog.notRefreshedLine(failure, reason: reason))
            return
        }
        loadedGraphIdentity = identity
        displayNames = Self.displayNames(for: starts, in: graph, speakers: speakers())
        let saved = await save(result)
        automaticWalkCount += 1
        write(TreeWalkLog.refreshedLine(result, reason: reason, savedNote: saved))
    }

    // MARK: Saving

    /// Atomic write off the main actor; installs the result as current.
    /// Returns the OUTCOME's closing phrase.
    private func save(_ result: TreeWalk.Result) async -> String {
        let stored = TreeWalkStored(result)
        self.stored = stored
        self.status = nil
        guard let url = storeURL else { return "decorations not saved (no store location)" }
        let error: String? = await Task.detached(priority: .utility) {
            do { try TreeWalkStore.save(result, to: url); return nil } catch { return error.localizedDescription }
        }.value
        if let error { return "decorations NOT saved: \(error)" }
        return "decorations saved"
    }

    // MARK: The one sink

    func write(_ line: String) {
        consoleLog?(line)
        appLog.write(line)
        walkLog.info("\(line, privacy: .public)")
        recentLines.append(line)
        if recentLines.count > Self.recentLineLimit { recentLines.removeFirst(recentLines.count - Self.recentLineLimit) }
    }
}
