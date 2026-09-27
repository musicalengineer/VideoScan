// FamilyTreeWalkCenter.swift
// The app side of the Family Tree WALK (Rick 2026-09-27): runs the Core
// walker (TreeWalk) off the main actor, writes the audit lines through ONE
// sink, saves decorations.json, and serves decorations to the inspector.
//
// Who calls it:
//   • the Walk Tree sheet (foreground: run, then the animation replays the
//     walk's layers),
//   • the MFO "Walk Tree" job (background),
//   • the inspector's decoration panel (read-only lookup, O(1) per person).
//
// LOGGING — one sink, three destinations (Rick's standard):
//   console + catalog.log   via the catalog model's `log` (DashboardState)
//   videoscan.log           via `appLog`
//   unified log             Logger(subsystem: "Rick-Breen.VideoScan", category: "treeWalk")
// The lines themselves are composed in Core (TreeWalkLog) from the walk's
// event stream, so the per-person work never formats a string.
//
// (For Rick: `@MainActor final class … ObservableObject` ≈ a UI-thread-only
// object whose `@Published` members notify SwiftUI views when set. The walk
// itself runs in `TreeWalk.events`, which is a detached task — a worker
// thread — so nothing here blocks the UI.)

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
    @Published private(set) var isRunning = false
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
        let outcome = await Task.detached(priority: .utility) {
            TreeWalkStore.load(from: url, expectedSourceKey: TreeWalkStore.sourceKey(of: graph))
        }.value
        apply(outcome)
        if case .current(let s) = outcome {
            displayNames = Self.displayNames(for: s.starts.map(\.id), in: graph, speakers: speakers)
        }
    }

    func apply(_ outcome: TreeWalkStore.LoadOutcome) {
        switch outcome {
        case .current(let s):
            stored = s
            status = nil
        case .absent:
            stored = nil
            status = "The tree has not been walked yet — Walk Tree… decorates everyone."
        case .stale(let reason):
            stored = nil
            status = "The last walk is out of date (\(reason)) — walk again."
            write("Walk Tree: decorations.json is stale — \(reason); will be rebuilt by the next walk")
        case .unreadable(let reason):
            stored = nil
            status = "The last walk could not be read — walk again."
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

    // MARK: Running

    /// Run one walk. `onEvent` sees every event (the sheet and the MFO job
    /// drive their progress from it). Logs, saves, installs the result.
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
