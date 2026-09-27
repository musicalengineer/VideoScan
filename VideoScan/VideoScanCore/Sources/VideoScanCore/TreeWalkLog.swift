// TreeWalkLog.swift (VideoScanCore)
// The audit lines of a tree walk, composed from its EVENT STREAM (Rick
// 2026-09-27: START, PROGRESS, CHECKS, CYCLES, OUTCOME — one sink to the
// console, catalog.log and videoscan.log). Pure text: the app decides where
// the lines go; this decides what they say, so a test can pin the cadence
// ("exactly one START, one OUTCOME, one progress pair per 1,000 people")
// without a log file.
//
// Nothing here runs in the walk's hot loop: the walker emits a progress
// event every N people and the consumer turns events into lines.

import Foundation

public struct TreeWalkLog: Sendable {
    public enum Mode: String, Sendable { case foreground, background }

    public let mode: Mode
    /// How each start is named in prose ("Rick", "Donna"); defaults to the
    /// start's first given name.
    public var displayNames: [String]
    public static let prefix = "Walk Tree: "

    public init(mode: Mode, displayNames: [String] = []) {
        self.mode = mode
        self.displayNames = displayNames
    }

    private func label(_ i: Int, _ starts: [TreeWalk.Start]) -> String {
        if displayNames.indices.contains(i), !displayNames[i].isEmpty { return displayNames[i] }
        return starts.indices.contains(i) ? starts[i].shortName : (i == 0 ? "first" : "second")
    }

    public func lineWord(_ line: TreeWalk.Line, starts: [TreeWalk.Start]) -> String {
        switch line {
        case .first: return "\(label(0, starts))'s line"
        case .second: return "\(label(1, starts))'s line"
        case .both: return "both lines"
        case .none: return "on no start's line"
        }
    }

    /// Lines for one event. `starts` is known from `.started`; the caller
    /// keeps it (see `Sink`).
    public func lines(for event: TreeWalk.Event, starts: [TreeWalk.Start], savedNote: String? = nil) -> [String] {
        let p = Self.prefix
        switch event {
        case .started(let info):
            let who = info.starts.map(\.name).joined(separator: " + ")
            let depth = info.maxGenerations.map { "\($0) generation\($0 == 1 ? "" : "s")" } ?? "all"
            return [p + "starting from \(who), depth \(depth), \(info.peopleInTree.formatted()) people in the tree, walker v\(info.walkerVersion), \(mode.rawValue)"]
        case .phase:
            return []
        case .progress(let pr):
            guard let s = pr.sample else {
                return [p + "\(pr.visited.formatted()) visited — generation \(pr.generation)"]
            }
            let born = s.birthYear.map { "b. \($0), " } ?? ""
            var lines = [p + "\(pr.visited.formatted()) visited — generation \(pr.generation), now at \(s.name) (\(born)\(lineWord(s.line, starts: starts)))"]
            var facts: [String] = []
            if let age = s.ageAtDeath { facts.append("age at death \(age.spoken)") }
            facts.append(s.birthRegion == .unknown ? "birthplace unknown" : "born \(s.birthRegion.label)")
            facts.append("\(s.childCount) child\(s.childCount == 1 ? "" : "ren")")
            var gens: [String] = []
            if let g = s.generationFromFirst { gens.append("generation \(g) from \(label(0, starts))") }
            if let g = s.generationFromSecond { gens.append("generation \(g) from \(label(1, starts))") }
            facts.append(contentsOf: gens)
            lines.append(p + "decorated \(s.name) — " + facts.joined(separator: ", "))
            return lines
        case .cycle(let c):
            return [p + "cycle — " + c.reason + " [" + c.personIDs.joined(separator: ", ") + "]"]
        case .warnCheck(let c):
            return [p + "check — " + c.reason + " (\(c.kind.label.lowercased()))"]
        case .finished(let r):
            return [outcome(r, savedNote: savedNote)]
        case .failed(let reason):
            return [p + "FAILED — " + reason]
        case .cancelled:
            return [p + "CANCELLED — stopped before the walk finished; nothing was saved"]
        }
    }

    public func outcome(_ r: TreeWalk.Result, savedNote: String?) -> String {
        let s = r.summary
        var gens: [String] = []
        if !r.starts.isEmpty { gens.append("\(s.generationsFromFirst) generations from \(label(0, r.starts))") }
        if r.starts.count > 1 { gens.append("\(s.generationsFromSecond) from \(label(1, r.starts))") }
        var head = "visited \(s.peopleWalked.formatted()) people (" + gens.joined(separator: ", ")
        if r.starts.count > 1 { head += "; \((s.byLine[.both] ?? 0).formatted()) on both lines" }
        head += ")"
        let checks = "\(r.checks.count.formatted()) checks (\(s.warnCount.formatted()) warn)"
        let cov = s.coverageWalked
        func pct(_ field: String, _ label: String) -> String? {
            cov.first { $0.field == field }.map { "\(label) \($0.percent)" }
        }
        let coverage = "coverage: " + [pct("a birth year", "birth year"), pct("a birthplace", "birthplace")]
            .compactMap { $0 }.joined(separator: ", ")
        let timing = String(format: "%.1f ms walk + %.1f ms checks (%.0f ms total)",
                            s.walkMilliseconds, s.checksMilliseconds, s.totalMilliseconds)
        return Self.prefix + "analysis complete — \(head), \(checks), \(coverage); \(timing); "
            + (savedNote ?? "decorations not saved")
    }

    /// Stateful helper: remembers the starts from `.started` so later
    /// events can name the lines.
    public struct Sink: Sendable {
        public let log: TreeWalkLog
        public private(set) var starts: [TreeWalk.Start] = []
        public init(_ log: TreeWalkLog) { self.log = log }
        public mutating func lines(for event: TreeWalk.Event, savedNote: String? = nil) -> [String] {
            if case .started(let info) = event { starts = info.starts }
            return log.lines(for: event, starts: starts, savedNote: savedNote)
        }
    }
}
