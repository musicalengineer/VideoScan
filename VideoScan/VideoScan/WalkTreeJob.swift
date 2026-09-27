// WalkTreeJob.swift
// "Walk Tree" as a Media File Operation — the BACKGROUND half of the Family
// Tree Walk (Rick 2026-09-27). The foreground half is the animated sheet;
// both run the same Core walker through FamilyTreeWalkCenter and both save
// decorations.json.
//
// Reads the loaded family tree only; touches no media and no catalog
// record. Stop cancels the walk at its next phase or generation boundary
// (a walk of Rick's 39k tree is about a second, so Stop is rarely needed);
// nothing is saved from a stopped walk.
//
// Progress: the walk's own phases mapped onto the bar — reading 5%, cycles
// 25%, walking 30–55% by people visited, counting 60%, checking 85%, done.
//
// (For Rick: the row observes this class; `@Published` ≈ a member whose
// setter tells the window to redraw the row.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class WalkTreeJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .walkTree
    let startedAt = Date()
    let graph: GedcomFamilyGraph
    let options: TreeWalk.Options
    let displayNames: [String]
    private let center: FamilyTreeWalkCenter

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Starting…"
    @Published private(set) var fractionValue: Double = 0
    /// The finished walk's summary (the row's detail view shows it).
    @Published private(set) var summary: TreeWalk.Summary?
    @Published private(set) var starts: [TreeWalk.Start] = []
    private(set) var task: Task<Void, Never>?

    var title: String {
        let who = displayNames.joined(separator: " + ")
        let depth = options.maxGenerations.map { ", \($0) generations" } ?? ""
        return "Walk Tree — from \(who)\(depth)"
    }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }

    init(graph: GedcomFamilyGraph, options: TreeWalk.Options, displayNames: [String],
         center: FamilyTreeWalkCenter = .shared) {
        self.graph = graph
        self.options = options
        self.displayNames = displayNames
        self.center = center
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Stopping — nothing from this walk will be saved…"
        task?.cancel()
    }

    private func run() async {
        let result = await center.run(graph: graph, options: options, mode: .background,
                                      displayNames: displayNames) { [weak self] event in
            self?.observe(event)
        }
        if let result {
            summary = result.summary
            starts = result.starts
            let s = result.summary
            // The walk's own checks (involving a walked person), not the
            // whole tree's — the MFO log line reads this (2026-09-27).
            let line = "\(s.peopleWalked.formatted()) people, \(s.checkCount.formatted()) checks "
                + "(\(s.warnCount.formatted()) warn) — decorations saved"
            state = .finished(summary: line)
            subtitleText = line
            fractionValue = 1
        } else if state.cancelWasRequested || Task.isCancelled {
            state = .cancelled
            subtitleText = "Stopped — nothing saved"
        } else if case .running = state {
            state = .failed(message: subtitleText)
        }
    }

    /// Phase → progress bar and subtitle.
    func observe(_ event: TreeWalk.Event) {
        switch event {
        case .started(let info):
            subtitleText = "Walking \(info.peopleInTree.formatted()) people…"
        case .phase(let name):
            subtitleText = name + "…"
            switch name {
            case "Reading the tree": fractionValue = 0.05
            case "Looking for cycles": fractionValue = 0.25
            case "Walking": fractionValue = 0.30
            case "Counting ancestors and descendants": fractionValue = 0.60
            case "Checking": fractionValue = 0.85
            default: break
            }
        case .progress(let p):
            fractionValue = 0.30 + 0.25 * Double(p.visited) / Double(max(1, p.reachable))
            subtitleText = "\(p.visited.formatted()) of \(p.reachable.formatted()) visited — generation \(p.generation)"
        case .failed(let why):
            if !state.cancelWasRequested { state = .failed(message: why) }
            subtitleText = why
        case .cancelled, .cycle, .warnCheck, .finished:
            break
        }
    }
}

// MARK: - Starting it

extension MediaFileOperationsCenter {
    /// Start a background tree walk; its row appears in the MFO window.
    @discardableResult
    func startWalkTree(graph: GedcomFamilyGraph, options: TreeWalk.Options, displayNames: [String]) -> WalkTreeJob {
        let job = WalkTreeJob(graph: graph, options: options, displayNames: displayNames)
        guard add(job) else { return job }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "reads the family tree only — no media, no catalog records"))
        return job
    }
}
