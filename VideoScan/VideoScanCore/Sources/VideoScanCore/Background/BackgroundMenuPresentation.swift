// BackgroundMenuPresentation.swift — VideoScanCore/Background
//
// What VideoScan Background's menu bar item says (Rick 2026-11-03: "the Menu
// bar icon is appropriate" — Apple's place for a background agent, like
// Creative Cloud or Time Machine). Pure: a ServiceStatus in, words and an
// icon state out, so the menu is tested without AppKit. The helper's
// StatusMenuController draws exactly this and nothing else.
//
// The item exists only while the helper runs; since 2026-11-04 the helper
// stays up while it is registered (launchd KeepAlive) and owns its schedule,
// so "icon in the menu bar" == "VideoScan Background is on". A kind held
// after a failure gets its own line with Resume (which releases the hold).

import Foundation

public struct BackgroundMenuPresentation: Equatable, Sendable {
    /// The glyph: outline lens when idle, filled lens while a job runs,
    /// pause bars when every active job (or the whole service) is paused,
    /// and the outline lens with a dot ("idle, with a wait") when no unit is
    /// being worked but a job holds its place — waiting on Backoff, or
    /// queued — so nothing may look filled (checklist F3 and the reviewer's
    /// queued red, 2026-11-03). Filled = a unit is actually running.
    public enum Icon: Equatable, Sendable {
        case idle, working, paused, waiting

        /// The glyph from counts (pure): paused when the service is, or when
        /// every active job is paused; filled only while a unit is worked;
        /// the dot while a job waits, is queued, or a kind is held.
        static func decide(servicePaused: Bool, active: Int, moving: Int, waiting: Int, held: Int) -> Icon {
            if servicePaused || (active > 0 && moving == 0 && waiting == 0) { return .paused }
            if moving > 0 { return .working }
            return waiting > 0 || held > 0 ? .waiting : .idle
        }
    }

    public struct JobLine: Equatable, Sendable {
        public var id: JobID
        /// "Machine era (8B) — 1,203 of 4,709 · running"
        public var words: String
        public var canPause: Bool
        public var canResume: Bool
    }

    public var icon: Icon
    /// The first, disabled line: "VideoScan Background — full speed".
    public var headline: String
    public var jobs: [JobLine]
    /// The tooltip on the menu bar item.
    public var tooltip: String

    public static func from(_ s: ServiceStatus) -> Self {
        let active = s.jobs.filter { $0.state.isActive }
        let holds = s.holds ?? []
        let heldKinds = Set(holds.map(\.kind))
        let failures = lastFailures(s.jobs).filter { !heldKinds.contains($0.kind) }.map(jobLine)
        let held = holds.map { holdLine($0, jobs: s.jobs) }
        let moving = active.filter { $0.state == .running || $0.state == .pausing }
        let waiting = active.filter { $0.state == .queued }
        let icon = Icon.decide(servicePaused: s.backoff.isPaused, active: active.count, moving: moving.count,
                               waiting: waiting.count, held: held.count)
        let headline = "VideoScan Background — "
            + (icon == .waiting ? (waiting.isEmpty ? "held after a failure" : "queued")
                                : backoffWords(s.backoff, jobs: active.count))
        let first: String?
        switch icon {
        case .idle: first = failures.first?.words ?? "idle, nothing queued"
        case .working: first = moving.first.map { jobLine($0).words } ?? "working"
        case .paused: first = "paused"
        case .waiting: first = waiting.first.map { jobLine($0).words } ?? held.first?.words ?? "waiting"
        }
        return Self(icon: icon, headline: headline, jobs: active.map(jobLine) + held + failures,
                    tooltip: "VideoScan Background — " + (first ?? ""))
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

    /// "idle" · "full speed" · "paused (thermal)". An older helper's
    /// `.trickle` decodes and reads "full speed" (no keyboard backoff since 2026-11-04).
    static func backoffWords(_ b: BackoffState, jobs: Int) -> String {
        if jobs == 0, !b.isPaused { return "idle" }
        switch b {
        case .full, .trickle: return "full speed"
        case .paused(let reason): return "paused (\(reason))"
        }
    }

    /// "Machine era (8B) — held after a failure: … — Resume, …" with Resume.
    static func holdLine(_ h: ScheduleHold, jobs: [JobProgressSnapshot]) -> JobLine {
        let title = jobs.last { $0.kind == h.kind }?.title ?? (h.kind == .era ? "Machine era (8B)" : h.kind.rawValue)
        return JobLine(id: h.jobID, words: "\(title) — \(h.words)", canPause: false, canResume: true)
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
