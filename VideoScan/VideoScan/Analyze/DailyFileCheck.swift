// DailyFileCheck.swift — Validate Catalog runs itself once a day (Rick
// 2026-11-07, DECISIONS "the file check runs itself daily in the away
// window"). The Files line went yellow every day only because nothing ran the
// check on Rick's real catalog: the 02:00 nightly is the TEST SUITE, not a
// Validate. This closes that gap with the app, not the helper — Validate's
// file check writes presence state through the commit door, and the app is
// the one committer.
//
// One sentence: in the away window (from 03:30, before Rick's 11:00 start;
// clear of the Ultra's 02:00 nightly) the app starts the SAME Validate
// Catalog job Catalog Status ▸ Check Now… starts (rule 4: one engine,
// `MediaFileOperationsCenter.startValidateCatalog`), and at launch or when
// Rick has been idle it catches up a check more than 24 h old.
//
// Shape:
//   * `DailyFileCheckPolicy` — pure: inputs (now, the last finished check,
//     what is busy, idle seconds, whether the launch look is still owed, the
//     last unattended start) → start / wait / skip. Every rule is a table
//     test (DailyFileCheckTests).
//   * `DailyFileCheckScheduler` — a small @MainActor feature store (rule 12:
//     no VideoScanModel extension) that owns the only state: when it last
//     started a run, whether the launch catch-up is still owed, and the last
//     "waiting" words it logged. Owned by VideoScanApp, attached on the master
//     only and never on a test host. Its `tick()` is the whole engine; a
//     Task loop calls it every 5 minutes.
//   * `DailyFileCheckEnvironment` — the closures `tick()` reads, so tests drive
//     it with fakes; `.live(model:center:)` reads the running app in O(1)
//     (the freshness snapshot's two rows, a few flags, the center's job list).
//
// Rules (rule 5, rule 8):
//   * the job IS the MFO job: its row has Pause / Stop, its START / OUTCOME go
//     through `validateCatalogNote` (the one sink); this file adds one
//     "daily check — starting …" line before it and one "daily check — due,
//     waiting: <why>" line each time the reason it waits changes. Never silent.
//   * never two at once: an active Validate / Audit / Verify job in the center
//     is "busy", and one unattended start per day slot (03:30 → 03:30) — a
//     run Rick stopped is not restarted until the next slot (or a relaunch).
//   * skipped while a catalog write hold is on, a scan runs, "Update everything
//     stale" runs (its last step IS the check), or the catalog is not this
//     Mac's to write (viewer / refused launch).
//   * "the last finished check" is evidence, not a field once written: the
//     freshness snapshot's File Presence and Integrity rows, read from
//     catalog-audit.json and integrity-latest.json. Either one not `.ok`
//     (stopped, failed, never ran) = no finished check — due.
//
// Cost: `tick()` is O(jobs) (the center's list, a handful) every 5 minutes;
// no file read, no record walk. Worst-case memory: three small values.
// The run itself is Validate's own budget (ValidateCatalogJob header).
//
// (For Rick: a struct of closures ≈ a C++ struct of std::function members —
// dependency injection without a protocol; `@MainActor final class` ≈ a
// UI-thread-only object, so its fields need no lock.)

import CoreGraphics
import Foundation
import VideoScanCore

// MARK: - The rule (pure)

enum DailyFileCheckPolicy {

    /// The day's slot: 03:30 local — after the Ultra's 02:00 nightly, long
    /// before Rick's ~11:00 start.
    static let slotHour = 3
    static let slotMinute = 30
    /// The away window closes at 11:00: a slot missed (the Mac asleep, the
    /// app not running) is taken up to then, never into Rick's day — after
    /// that only the launch / idle catch-up applies.
    static let awayEndHour = 11
    /// A check older than this is caught up at launch or when idle.
    static let catchUpAfter: TimeInterval = 24 * 3_600
    /// "Idle": no keyboard or mouse event for this long.
    static let idleFor: TimeInterval = 15 * 60
    /// How often the scheduler looks.
    static let tickEvery: TimeInterval = 5 * 60
    /// A finished check dated more than this after now is no proof.
    static let futureSlack: TimeInterval = CatalogRealityPolicy.futureSlack

    struct Inputs: Equatable {
        var now: Date
        /// The last check whose BOTH steps finished `.ok` (the older of the
        /// two dates); nil = none (never ran, stopped, failed).
        var lastFinished: Date?
        /// Why a run must not start now; nil = free.
        var busy: String?
        /// Seconds since the last keyboard / mouse event.
        var idleSeconds: TimeInterval
        /// The launch catch-up has not been decided yet this session.
        var launchLookOwed: Bool
        /// When this session last started an unattended run.
        var lastStarted: Date?
    }

    enum Why: String, Equatable {
        case slot = "the 03:30 daily check"
        case launch = "catching up at launch"
        case idle = "catching up while idle"
    }

    enum Decision: Equatable {
        case start(Why)
        /// Nothing due (or already tried this slot).
        case wait
        /// Due, but something is busy — the words say what.
        case skip(Why, String)
    }

    /// The most recent 03:30 at or before `now`.
    static func slot(atOrBefore now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: slotHour, minute: slotMinute, second: 0, of: now) ?? now
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// In the away window: 03:30 ≤ time of day < 11:00.
    static func inAwayWindow(_ now: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes >= slotHour * 60 + slotMinute && minutes < awayEndHour * 60
    }

    static func decide(_ i: Inputs, calendar: Calendar = .current) -> Decision {
        let slot = slot(atOrBefore: i.now, calendar: calendar)
        // One unattended start per slot: a run Rick stopped stays stopped.
        if let started = i.lastStarted, started >= slot { return .wait }
        guard let why = due(i, slot: slot, calendar: calendar) else { return .wait }
        if let busy = i.busy { return .skip(why, busy) }
        return .start(why)
    }

    /// Why a run is due now, or nil.
    static func due(_ i: Inputs, slot: Date, calendar: Calendar) -> Why? {
        // A finished check dated after now (a copied record, a clock that
        // stepped back) proves nothing: treated as no finished check.
        let last = i.lastFinished.flatMap { $0 <= i.now.addingTimeInterval(futureSlack) ? $0 : nil }
        let finishedThisSlot = last.map { $0 >= slot } ?? false
        if inAwayWindow(i.now, calendar: calendar), !finishedThisSlot { return .slot }
        let overdue = last.map { i.now.timeIntervalSince($0) > catchUpAfter } ?? true
        guard overdue else { return nil }
        if i.launchLookOwed { return .launch }
        if i.idleSeconds >= idleFor { return .idle }
        return nil
    }

    /// The last finished check from the two freshness rows (evidence read
    /// from catalog-audit.json and integrity-latest.json): the OLDER of the
    /// two dates when both steps finished `.ok`; nil otherwise. Either step
    /// dated in the future is no proof — judged per step BEFORE the older
    /// date is taken, so one future date cannot hide behind the other
    /// (Codex sweep 11/09 F1).
    static func lastFinished(files: FreshnessRow?, integrity: FreshnessRow?, now: Date) -> Date? {
        guard let files, let integrity, files.lastOutcome == .ok, integrity.lastOutcome == .ok,
              let a = files.lastCompleted, let b = integrity.lastCompleted else { return nil }
        guard CatalogRealityPolicy.age(of: a, now: now) != .future,
              CatalogRealityPolicy.age(of: b, now: now) != .future else { return nil }
        return min(a, b)
    }
}

// MARK: - What the scheduler reads

struct DailyFileCheckEnvironment {
    var now: () -> Date = { Date() }
    /// nil until the freshness snapshot's first pass has landed: the
    /// scheduler waits rather than judge "never ran" from nothing.
    var lastFinished: () -> Date?? = { .some(nil) }
    var busy: () -> String? = { nil }
    var idleSeconds: () -> TimeInterval = { 0 }
    /// Start THE Validate Catalog job; returns false when it was refused.
    var start: () -> Bool = { false }
    /// The one sink (Validate Catalog's).
    var note: (String) -> Void = { _ in }
    var calendar: Calendar = .current
}

extension DailyFileCheckEnvironment {

    /// Seconds since the last keyboard / mouse / trackpad event in this
    /// login session (CoreGraphics; no permission needed).
    static func systemIdleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// The running app. Every read is O(1) or O(jobs).
    @MainActor
    static func live(model: VideoScanModel, center: MediaFileOperationsCenter) -> DailyFileCheckEnvironment {
        var env = DailyFileCheckEnvironment()
        env.lastFinished = { [weak model] in
            guard let state = model?.catalogFreshness.state, state.isComputed else { return nil }
            return .some(DailyFileCheckPolicy.lastFinished(files: state.row(.filePresence), integrity: state.row(.integrity), now: Date()))
        }
        env.busy = { [weak model, weak center] in
            guard let model, let center else { return "the app is shutting down" }
            return DailyFileCheckScheduler.busyReason(
                readOnly: model.isReadOnly, unavailable: model.catalogUnavailableWords, writeHold: model.catalogStore.writeHold,
                scanning: model.isScanning, updating: model.catalogStatusUpdateQueue.isActive,
                checker: center.jobs.first { $0.state.isActive && ($0 is ValidateCatalogJob || $0 is CatalogAuditJob || $0 is VerifyCatalogJob) }?.title)
        }
        env.idleSeconds = { systemIdleSeconds() }
        env.start = { [weak model, weak center] in
            guard let model, let center else { return false }
            // Background origin (not `startedByUser`): the MFO window is not
            // brought forward at 03:30; the row is there with Pause / Stop.
            return !center.startValidateCatalog(model: model, marker: model.catalogAuditRunMarker).wasRefused
        }
        env.note = { [weak model] line in model?.validateCatalogNote("daily check — " + line) }
        return env
    }
}

// MARK: - The store

@MainActor
final class DailyFileCheckScheduler {

    private(set) var env: DailyFileCheckEnvironment
    /// When this session last started an unattended run.
    private(set) var lastStarted: Date?
    /// The launch catch-up has not been decided yet (true until the first
    /// look that was not blocked by something busy).
    private(set) var launchLookOwed = true
    /// The "waiting" words last logged — logged again only when they change.
    private var saidWaiting: String?
    private var loop: Task<Void, Never>?

    init(env: DailyFileCheckEnvironment = DailyFileCheckEnvironment()) {
        self.env = env
    }

    static let onWords = "on — runs Validate Catalog from 03:30 in the away window (until 11:00); "
        + "catches up at launch or after 15 min idle when the last finished check is over 24 h old; "
        + "never while a write hold, a scan, Update or another check is running"

    /// Live app wiring: log that it is on, then look every 5 minutes (the
    /// first look after `firstLookAfter`, so the launch restore has landed).
    /// Idempotent: a second main window's onAppear does not start a second loop.
    func attach(_ env: DailyFileCheckEnvironment, firstLookAfter: TimeInterval = 120) {
        guard loop == nil else { return }
        self.env = env
        env.note(Self.onWords)
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(firstLookAfter))
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(DailyFileCheckPolicy.tickEvery))
            }
        }
    }

    func detach() {
        loop?.cancel()
        loop = nil
    }

    /// One look. Returns what it decided (tests read it).
    @discardableResult
    func tick() -> DailyFileCheckPolicy.Decision {
        // The freshness snapshot has not landed: judge nothing yet.
        guard let lastFinished = env.lastFinished() else { return .wait }
        let now = env.now()
        let inputs = DailyFileCheckPolicy.Inputs(now: now, lastFinished: lastFinished, busy: env.busy(),
                                                 idleSeconds: env.idleSeconds(), launchLookOwed: launchLookOwed,
                                                 lastStarted: lastStarted)
        let decision = DailyFileCheckPolicy.decide(inputs, calendar: env.calendar)
        switch decision {
        case .wait:
            launchLookOwed = false
            saidWaiting = nil
        case .skip(let why, let busy):
            // The launch catch-up stays owed until it can run.
            let words = "due (\(why.rawValue)), waiting: \(busy)"
            if words != saidWaiting { env.note(words) }
            saidWaiting = words
        case .start(let why):
            launchLookOwed = false
            saidWaiting = nil
            lastStarted = now
            env.note("starting Validate Catalog — \(why.rawValue); last finished check: \(Self.words(lastFinished))")
            if !env.start() { env.note("Validate Catalog refused to start — see its row in Media File Operations") }
        }
        return decision
    }

    nonisolated static func words(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none (never, stopped or failed)"
    }

    /// Pure: why an unattended run must not start now; nil = free.
    nonisolated static func busyReason(readOnly: Bool, unavailable: String?, writeHold: String?, scanning: Bool,
                                       updating: Bool, checker: String?) -> String? {
        if readOnly { return "this Mac is a read-only viewer of the catalog" }
        if let unavailable { return unavailable }
        if let writeHold { return "a catalog write hold is on (\(writeHold))" }
        if scanning { return "a scan is running" }
        if updating { return "Update everything stale is running (its last step is this check)" }
        if let checker { return "\(checker) is already running" }
        return nil
    }
}
