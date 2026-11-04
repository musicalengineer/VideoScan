// BackgroundMenuPresentation.swift — VideoScanCore/Background
//
// What VideoScan Background's menu bar item says (Rick 2026-11-03: "the Menu
// bar icon is appropriate" — Apple's place for a background agent, like
// Creative Cloud or Time Machine). Pure: a ServiceStatus in, words and an
// icon state out, so the menu is tested without AppKit. The helper's
// StatusMenuController draws exactly this and nothing else.
//
// The item exists only while the helper runs: the helper exits after 10 idle
// minutes (IdleExitPolicy) and launchd starts it again on the next message,
// so "icon in the menu bar" == "VideoScan Background is running".

import Foundation

public struct BackgroundMenuPresentation: Equatable, Sendable {
    /// The glyph: outline lens when idle, filled lens while a job runs,
    /// pause bars when every active job (or the whole service) is paused,
    /// and the outline lens with a dot ("idle, with a wait") when no unit is
    /// being worked but a job holds its place — waiting on Backoff, or
    /// queued — so nothing may look filled (checklist F3 and the reviewer's
    /// queued red, 2026-11-03). Filled = a unit is actually running.
    public enum Icon: Equatable, Sendable { case idle, working, paused, waiting }

    public struct JobLine: Equatable, Sendable {
        public var id: JobID
        /// "Machine era (8B) — 1,203 of 4,709 · running"
        public var words: String
        public var canPause: Bool
        public var canResume: Bool
    }

    public var icon: Icon
    /// The first, disabled line: "VideoScan Background — trickle (you're working)".
    public var headline: String
    public var jobs: [JobLine]
    /// The tooltip on the menu bar item.
    public var tooltip: String

    public static func from(_ s: ServiceStatus) -> Self {
        let active = s.jobs.filter { $0.state.isActive }
        let failures = lastFailures(s.jobs).map(jobLine)
        let lines = active.map(jobLine) + failures
        let moving = active.filter { ($0.state == .running || $0.state == .pausing) && !$0.isWaiting }
        let waiting = active.filter { $0.isWaiting || $0.state == .queued }
        let icon: Icon
        if s.backoff.isPaused || (!active.isEmpty && moving.isEmpty && waiting.isEmpty) { icon = .paused }
        else if !moving.isEmpty { icon = .working }
        else if !waiting.isEmpty { icon = .waiting }
        else { icon = .idle }
        let headline = "VideoScan Background — "
            + (icon == .waiting ? waitingHeadline(s.backoff) : backoffWords(s.backoff, jobs: active.count))
        let tooltip: String
        switch icon {
        case .idle: tooltip = "VideoScan Background — " + (failures.first?.words ?? "idle, nothing queued")
        case .working: tooltip = "VideoScan Background — " + (moving.first.map { jobLine($0).words } ?? "working")
        case .paused: tooltip = "VideoScan Background — paused"
        case .waiting: tooltip = "VideoScan Background — " + (waiting.first.map { jobLine($0).words } ?? "waiting")
        }
        return Self(icon: icon, headline: headline, jobs: lines, tooltip: tooltip)
    }

    /// Per kind, the newest job (by start, else finish) when it FAILED — a
    /// START refusal or a fail-fast stop (2026-11-03) — so the menu says why
    /// nothing runs instead of going quiet. A newer job of the kind, of any
    /// state, replaces it; an active one always does. O(jobs); the status list is bounded (≤ 50 finished).
    static func lastFailures(_ jobs: [JobProgressSnapshot]) -> [JobProgressSnapshot] {
        var newest: [JobKind: JobProgressSnapshot] = [:]
        var kinds: [JobKind] = []
        func when(_ j: JobProgressSnapshot) -> Date { j.startedAt ?? j.finishedAt ?? .distantPast }
        for job in jobs {
            if let seen = newest[job.kind] {
                if when(job) >= when(seen) { newest[job.kind] = job }
            } else {
                newest[job.kind] = job
                kinds.append(job.kind)
            }
        }
        // A kind with any active job (a queued one has no timestamps yet) shows
        // that job, never an older failure (Codex #232 F5).
        let busy = Set(jobs.filter { $0.state.isActive }.map(\.kind))
        return kinds.compactMap { kind in
            guard !busy.contains(kind), let job = newest[kind], case .failed = job.state else { return nil }
            return job
        }
    }

    /// "idle" · "working — full speed (you're away)" · "working — gently (you're at the Mac)" · "paused (thermal)"
    static func backoffWords(_ b: BackoffState, jobs: Int) -> String {
        if jobs == 0, !b.isPaused { return "idle" }
        switch b {
        case .full: return "full speed (you're away)"
        case .trickle: return "gently (you're at the Mac)"
        case .paused(let reason): return "paused (\(reason))"
        }
    }

    /// Every running job waits: say so, with the Mac's reason when it is
    /// the trickle (you are at the keyboard) — never "gently", which says work.
    static func waitingHeadline(_ b: BackoffState) -> String {
        b == .trickle ? "waiting (you're at the Mac)" : "waiting"
    }

    static func jobLine(_ j: JobProgressSnapshot) -> JobLine {
        let progress = j.totalUnits > 0
            ? "\(j.completedUnits.formatted()) of \(j.totalUnits.formatted())"
            : "\(j.completedUnits.formatted()) done"
        let paused: Bool
        if case .paused = j.state { paused = true } else { paused = false }
        return JobLine(id: j.id, words: "\(j.title) — \(progress) · \(j.stateWords)",
                       canPause: j.state == .running || j.state == .queued,
                       canResume: paused)
    }
}
