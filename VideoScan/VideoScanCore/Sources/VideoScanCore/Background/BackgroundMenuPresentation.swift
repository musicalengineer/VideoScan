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
    /// pause bars when every active job (or the whole service) is paused.
    public enum Icon: Equatable, Sendable { case idle, working, paused }

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
        let lines = active.map(jobLine)
        let anyRunning = active.contains { $0.state == .running || $0.state == .pausing || $0.state == .queued }
        let icon: Icon
        if s.backoff.isPaused || (!active.isEmpty && !anyRunning) { icon = .paused }
        else if anyRunning { icon = .working }
        else { icon = .idle }
        let headline = "VideoScan Background — " + backoffWords(s.backoff, jobs: active.count)
        let tooltip: String
        switch icon {
        case .idle: tooltip = "VideoScan Background — idle, nothing queued"
        case .working: tooltip = "VideoScan Background — " + (lines.first?.words ?? "working")
        case .paused: tooltip = "VideoScan Background — paused"
        }
        return Self(icon: icon, headline: headline, jobs: lines, tooltip: tooltip)
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

    static func jobLine(_ j: JobProgressSnapshot) -> JobLine {
        let progress = j.totalUnits > 0
            ? "\(j.completedUnits.formatted()) of \(j.totalUnits.formatted())"
            : "\(j.completedUnits.formatted()) done"
        let paused: Bool
        if case .paused = j.state { paused = true } else { paused = false }
        return JobLine(id: j.id, words: "\(j.title) — \(progress) · \(j.state.words)",
                       canPause: j.state == .running || j.state == .queued,
                       canResume: paused)
    }
}
