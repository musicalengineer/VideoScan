// MediaFileOperationsWindowForwarder.swift
//
// "Bring the Media File Operations window forward when a job starts"
// (Rick 2026-09-21): "Often this window is occluded or not even opened and
// the user doesn't see any progress… I don't want that window constantly in
// your face, but if there's a way to put it forward when a new MFO op
// launches."
//
// RULES (agreed with Rick 2026-09-21):
//   1. A job the USER started opens the window if it is closed, or orders
//      it front if it is open / occluded / minimized.
//   2. Background work never does (Archive Angel's child jobs, a verify's
//      chained rebuild, sweeps, launch-time reconciliation, resume offers
//      nobody accepted). Origin is EXPLICIT: the user-facing call sites wrap
//      their start call in `center.startedByUser { … }`. Unknown ⇒ no raise.
//   3. Forward but NOT key — the window the user is typing in keeps the
//      keyboard, and the app is never activated from the background.
//   4. Once per start; several starts inside `debounceSeconds` raise once;
//      a running job never re-raises.
//   5. Setting "Show Media File Operations when a job starts", default ON,
//      explicit save, test host never touches real prefs.
//   6. One log line per raise, written AFTER the last attempt and saying
//      what actually happened (2026-09-22 fix):
//      "[mfo] brought Media File Operations forward for <title> — visible:
//      yes|no (found: …, was: …, front: …, screen: …, level: …, occlusion:
//      …, space: …, raises: n[, stood down: …])".
//
// 2026-09-22 FIX (Rick, Release b334247b: "didn't seem like the MFO window
// jumped in front"). The raise used to run SYNCHRONOUSLY inside the start
// call — i.e. inside the sheet button's action, before that sheet's
// `dismiss()`. Promote is the clear case: the Archive Helper raises the main
// window, the Promote sheet opens on it, Confirm → `startPromote` →
// `orderFront(job window)` → `dismiss()`; the sheet then animates out and
// AppKit hands key/order back to the sheet's parent, which can land on top
// of the window we just raised. And the log line was written before
// anything checked the result. Now:
//   • the raise is DEFERRED to the next run-loop turn and RE-ASSERTED at
//     0.3 s and 0.9 s (after a sheet's dismiss animation), only while the
//     job window is not already the frontmost app window;
//   • it STANDS DOWN the moment the user clicks anywhere or moves the key
//     window somewhere of their own choosing — we never fight the user;
//   • the legacy "open behind main" retries also stand down inside the
//     forward window (MediaFileOperationsWindowOpener);
//   • the log line is composed after the last attempt from the window's
//     real state (occlusion, screen, level, Space), so the next report
//     says which of the four hypotheses was true.
//
// Shape: a PURE decision function (`decide`, table-tested), a small
// @MainActor object holding the debounce clock + setting, a PURE per-raise
// state machine (`MediaFileOperationsForwardSession`, table-tested), and
// the AppKit side effects behind two protocols (`…ForwardWindowing`,
// `…ForwardScheduling`) so tests drive the presenter with a fake window
// system and a manual clock. (A protocol here ≈ a C++ abstract base class
// with pure-virtual methods; tests plug in a fake.)
//
// Memory: a Date, a Bool, an Int depth counter and a FIFO set of at most
// `raisedMemoryCap` UUIDs (16 bytes each) — worst case ≈ 4 KB. One raise
// holds a handful of Ints for ~1.2 s.

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Origin + decision (pure)

/// Who started a Media File Operations job. Only `.user` may bring the
/// window forward; anything the code cannot prove was a click is
/// `.background` (rule 2's "default to NOT raising when unknown").
enum MediaFileOperationOrigin: String, Equatable, CaseIterable {
    case user
    case background
}

/// The outcome of one job start. The `skip…` cases name the rule that
/// suppressed the raise, so a test failure says WHY.
enum MediaFileOperationsForwardDecision: Equatable {
    case raise
    case skipBackground
    case skipSettingOff
    case skipAlreadyRaisedForJob
    case skipDebounced
}

// MARK: - Setting

/// "Show Media File Operations when a job starts" — default ON.
/// Persisted with the app's explicit-save pattern (no didSet: @Published /
/// @Observable swallow property observers, see project settings notes).
struct MediaFileOperationsForwardSetting: Equatable {
    var showOnJobStart: Bool = true

    static let key = "mfo.showWindowOnJobStart"

    /// Absent key ⇒ the default (ON) — a fresh install behaves as agreed.
    static func restored(from defaults: UserDefaults) -> MediaFileOperationsForwardSetting {
        var s = MediaFileOperationsForwardSetting()
        if defaults.object(forKey: key) != nil {
            s.showOnJobStart = defaults.bool(forKey: key)
        }
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(showOnJobStart, forKey: Self.key)
    }
}

// MARK: - Presenter seam

/// The one AppKit side effect: put the window in front of the user
/// without taking keyboard focus. `@MainActor` ≈ "UI thread only".
/// `report` is called ONCE, after the last attempt, with what really
/// happened — the forwarder turns it into the log line. A presenter that
/// never attempts anything (the test-host null) never calls it.
@MainActor
protocol MediaFileOperationsWindowPresenting: AnyObject {
    func bringForwardWithoutFocus(report: @escaping (MediaFileOperationsForwardReport) -> Void)
}

/// Does nothing — the test-host default, so a unit test that builds a
/// Center can never move a real window.
@MainActor
final class NullMediaFileOperationsWindowPresenter: MediaFileOperationsWindowPresenting {
    func bringForwardWithoutFocus(report: @escaping (MediaFileOperationsForwardReport) -> Void) {}
}

// MARK: - Forwarder

@MainActor
final class MediaFileOperationsWindowForwarder: ObservableObject {

    /// Starts closer together than this raise the window once (rule 4).
    nonisolated static let debounceSeconds: TimeInterval = 2

    /// How many job ids we remember as "already raised" (FIFO).
    static let raisedMemoryCap = 256

    /// The persisted setting. `@Published` ≈ a field that notifies
    /// observers (the Settings checkbox) when it changes; `private(set)`
    /// forces every write through `setShowOnJobStart` so the save can't be
    /// forgotten.
    @Published private(set) var setting: MediaFileOperationsForwardSetting

    private let presenter: MediaFileOperationsWindowPresenting
    private let persist: (MediaFileOperationsForwardSetting) -> Void
    private let now: () -> Date
    private let log: (String) -> Void

    /// When the window was last raised; the debounce clock.
    private(set) var lastRaiseAt: Date?
    private var raisedJobIDs: Set<UUID> = []
    private var raisedJobOrder: [UUID] = []

    /// > 0 while a `withUserOrigin` body runs. A counter, not a Bool, so
    /// nested wraps are harmless. Everything here is main-actor, and the
    /// `start…` methods call `add(job)` synchronously, so the scope is exact
    /// — ≈ a RAII guard object on the UI thread's stack. Child jobs a job
    /// spawns later from its own Task run outside the scope ⇒ background.
    private(set) var userOriginDepth = 0

    init(setting: MediaFileOperationsForwardSetting = MediaFileOperationsForwardSetting(),
         presenter: MediaFileOperationsWindowPresenting,
         persist: @escaping (MediaFileOperationsForwardSetting) -> Void = { _ in },
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { appLog.write($0) }) {
        self.setting = setting
        self.presenter = presenter
        self.persist = persist
        self.now = now
        self.log = log
    }

    /// Production wiring. Under a test host: default setting, no save, and
    /// the null presenter — a test can never write real prefs or move a
    /// real window by constructing a Center.
    static func makeDefault() -> MediaFileOperationsWindowForwarder {
        if TestEnvironment.isTestHost {
            return MediaFileOperationsWindowForwarder(presenter: NullMediaFileOperationsWindowPresenter())
        }
        return MediaFileOperationsWindowForwarder(
            setting: .restored(from: .standard),
            presenter: AppKitMediaFileOperationsWindowPresenter(),
            persist: { $0.save(to: .standard) })
    }

    // MARK: Setting

    /// The Settings checkbox's setter — assign + explicit save.
    func setShowOnJobStart(_ on: Bool) {
        guard setting.showOnJobStart != on else { return }
        setting.showOnJobStart = on
        persist(setting)
    }

    // MARK: Origin scope

    /// Run `body` with user origin: any job registered inside it counts as
    /// user-started. `rethrows` ≈ "throws only if body throws"; the generic
    /// `T` passes the start method's return value straight through.
    @discardableResult
    func withUserOrigin<T>(_ body: () throws -> T) rethrows -> T {
        userOriginDepth += 1
        defer { userOriginDepth -= 1 }   // `defer` ≈ a scope-exit destructor
        return try body()
    }

    var currentOrigin: MediaFileOperationOrigin {
        userOriginDepth > 0 ? .user : .background
    }

    // MARK: Decision

    /// Pure. Order matters only for which reason is reported; every skip
    /// means "no raise".
    nonisolated static func decide(origin: MediaFileOperationOrigin,
                                   enabled: Bool,
                                   alreadyRaisedForJob: Bool,
                                   lastRaiseAt: Date?,
                                   now: Date) -> MediaFileOperationsForwardDecision {
        guard origin == .user else { return .skipBackground }
        guard enabled else { return .skipSettingOff }
        guard !alreadyRaisedForJob else { return .skipAlreadyRaisedForJob }
        if let last = lastRaiseAt, now.timeIntervalSince(last) < debounceSeconds {
            return .skipDebounced
        }
        return .raise
    }

    /// The Center calls this once per registered job (and the Combine
    /// dialog once per batch). Returns the decision so tests can pin it.
    /// The log line is written when the presenter REPORTS (after its last
    /// attempt, ~1.2 s later in the app), never before.
    @discardableResult
    func jobStarted(id: UUID, title: String,
                    origin: MediaFileOperationOrigin) -> MediaFileOperationsForwardDecision {
        let t = now()
        let decision = Self.decide(origin: origin,
                                   enabled: setting.showOnJobStart,
                                   alreadyRaisedForJob: raisedJobIDs.contains(id),
                                   lastRaiseAt: lastRaiseAt,
                                   now: t)
        // A user start inside the debounce window still belongs to that
        // raise — remember it so it can never trigger one later.
        if decision == .raise || decision == .skipDebounced { rememberRaised(id) }
        guard decision == .raise else { return decision }
        lastRaiseAt = t
        let log = self.log   // capture the closure, not self (≈ copy a std::function)
        presenter.bringForwardWithoutFocus { report in
            log(MediaFileOperationsForwardReport.logLine(title: title, report: report))
        }
        return decision
    }

    private func rememberRaised(_ id: UUID) {
        guard raisedJobIDs.insert(id).inserted else { return }
        raisedJobOrder.append(id)
        if raisedJobOrder.count > Self.raisedMemoryCap {
            raisedJobIDs.remove(raisedJobOrder.removeFirst())
        }
    }
}

// MARK: - Center hooks

extension MediaFileOperationsCenter {

    /// Wrap a user-facing `start…` call (menu item, sheet button, banner
    /// button) so the job it registers brings the window forward:
    ///
    ///     fileOpsCenter.startedByUser { $0.startTrim(…) }
    ///
    /// `$0` is this Center — Swift's shorthand for the closure's first
    /// argument (≈ a lambda `[](auto& c){ … }`).
    @discardableResult
    func startedByUser<T>(_ body: (MediaFileOperationsCenter) throws -> T) rethrows -> T {
        try windowForwarder.withUserOrigin { try body(self) }
    }

    /// For user work that does NOT register through `add(_:)` — the
    /// Combine dialog's batch lives in the dashboard's combine queue.
    func noteUserStartedOutsideCenter(title: String) {
        windowForwarder.jobStarted(id: UUID(), title: title, origin: .user)
    }
}

// MARK: - One raise: pure state machine

/// Everything one raise decides, with no AppKit in it — so every rule is a
/// table test. The presenter feeds it an `Observation` (a snapshot of the
/// window system) on each scheduled turn and performs the `Action`s it
/// returns. A `struct` with `mutating` methods ≈ a C++ value class whose
/// non-const member functions update its own fields.
struct MediaFileOperationsForwardSession: Equatable {

    /// Attempt turns, seconds after the start call. 0 = "next run-loop
    /// turn" (after the button action and the `dismiss()` that follows it
    /// have returned); 0.3 s ≈ just after a sheet's dismiss animation;
    /// 0.9 s = a late re-assert for a slow SwiftUI open / deminiaturize.
    static let attemptDelays: [TimeInterval] = [0, 0.3, 0.9]

    /// When the honest log line is composed — a beat after the last
    /// attempt, so the window server has updated the occlusion state.
    static let reportDelay: TimeInterval = 1.15

    enum StandDown: String, Equatable {
        case userMovedFocus = "user moved focus"
        case superseded = "superseded by a newer raise"
    }

    enum Action: Equatable {
        case deminiaturize
        case restoreKeyToAnchor
        case orderFront
    }

    /// One snapshot of the window system. Window numbers are AppKit's
    /// per-window integers (`NSWindow.windowNumber`) — plain Ints so the
    /// state machine stays AppKit-free.
    struct Observation: Equatable {
        var jobFound = false
        var jobVisible = false
        var jobMiniaturized = false
        /// The job window is the frontmost visible normal-level window of
        /// this app.
        var jobIsFrontmost = false
        var jobIsKey = false
        var jobWindowNumber: Int?
        var keyWindowNumber: Int?
        /// The window the keyboard would go back to (the window key at the
        /// start, else the main window), if it is still visible.
        var anchorWindowNumber: Int?
        /// A mouse-down anywhere in the app since the raise began.
        var userClickedSinceRaise = false
        var modalRunning = false
    }

    /// The user's "own" windows at the start: the key window, its sheet
    /// parent and its attached sheet (Confirm is clicked in a SHEET, which
    /// then goes away and hands key to its parent — that is not the user
    /// moving focus). Grows by the anchor when we hand the keyboard back.
    private(set) var ownWindowNumbers: Set<Int>
    private(set) var standDown: StandDown?
    /// deminiaturize + orderFront calls made — the "raises: n" in the log.
    private(set) var raises = 0
    private(set) var keyRestored = false
    private(set) var deminiaturizeRequested = false

    init(ownWindowNumbers: Set<Int>) {
        self.ownWindowNumbers = ownWindowNumbers
    }

    /// A newer raise owns the window now; this one does nothing more.
    mutating func supersede() {
        if standDown == nil { standDown = .superseded }
    }

    /// One attempt turn. Returns the actions to perform, in order.
    mutating func step(_ o: Observation) -> [Action] {
        if standDown != nil { return [] }
        if o.modalRunning { return [] }            // never fight an alert; try next turn
        if o.userClickedSinceRaise {               // the user did something — leave them be
            standDown = .userMovedFocus
            return []
        }
        if let key = o.keyWindowNumber, key != o.jobWindowNumber, !ownWindowNumbers.contains(key) {
            standDown = .userMovedFocus            // e.g. ⌘` to another window
            return []
        }
        guard o.jobFound else { return [] }        // SwiftUI still creating it
        if o.jobMiniaturized {
            // deminiaturize animates and orders the window front itself;
            // ask once, let later turns check the result.
            guard !deminiaturizeRequested else { return [] }
            deminiaturizeRequested = true
            raises += 1
            return [.deminiaturize]
        }
        guard o.jobVisible else { return [] }      // opening; next turn
        var actions: [Action] = []
        // The open (or a deminiaturize) made the job window key: hand the
        // keyboard back once (rule 3), then put the job window on top again.
        let restore = o.jobIsKey && !keyRestored && o.anchorWindowNumber != nil
        if restore {
            keyRestored = true
            if let anchor = o.anchorWindowNumber { ownWindowNumbers.insert(anchor) }
            actions.append(.restoreKeyToAnchor)
        }
        if restore || !o.jobIsFrontmost {
            raises += 1
            actions.append(.orderFront)
        }
        return actions
    }
}

// MARK: - Report + the honest log line (pure)

/// The job window's real state after the last attempt.
struct MediaFileOperationsForwardDiagnostics: Equatable {
    var found = false
    var isVisible = false
    var miniaturized = false
    var frontmost = false
    var screen: String?
    var mainWindowScreen: String?
    var level: Int?
    /// `NSWindow.occlusionState.contains(.visible)` — any part on screen.
    var occlusionVisible: Bool?
    /// `NSWindow.isOnActiveSpace` — false ⇒ it is on another Space
    /// (e.g. the main window is full screen).
    var onActiveSpace: Bool?
}

struct MediaFileOperationsForwardReport: Equatable {

    /// The window's state BEFORE the raise.
    enum Before: String, Equatable {
        case closed, minimized, behind, front
    }

    var was: Before
    var diagnostics: MediaFileOperationsForwardDiagnostics
    var raises: Int
    var standDown: MediaFileOperationsForwardSession.StandDown?

    /// "Could Rick see it?" — present, shown, not in the Dock, some part
    /// not covered, and on the Space he is looking at.
    var visible: Bool {
        let d = diagnostics
        return d.found && d.isVisible && !d.miniaturized
            && d.occlusionVisible == true && d.onActiveSpace != false
    }

    static func before(_ o: MediaFileOperationsForwardSession.Observation) -> Before {
        if !o.jobFound { return .closed }
        if o.jobMiniaturized { return .minimized }
        if !o.jobVisible { return .closed }
        return o.jobIsFrontmost ? .front : .behind
    }

    /// Pure: the one log line per raise (rule 6).
    static func logLine(title: String, report r: MediaFileOperationsForwardReport) -> String {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        let d = r.diagnostics
        var parts = ["found: \(yn(d.found))", "was: \(r.was.rawValue)"]
        if d.found {
            parts.append("front: \(yn(d.frontmost))")
            parts.append("screen: \(d.screen ?? "none")")
            if let main = d.mainWindowScreen, main != d.screen {
                parts.append("main window screen: \(main)")
            }
            parts.append("level: \(d.level.map(String.init) ?? "?")")
            parts.append("occlusion: \(d.occlusionVisible.map { $0 ? "visible" : "hidden" } ?? "?")")
            parts.append("space: \(d.onActiveSpace.map { $0 ? "active" : "other" } ?? "?")")
            if d.miniaturized { parts.append("minimized: yes") }
        }
        parts.append("raises: \(r.raises)")
        if let s = r.standDown { parts.append("stood down: \(s.rawValue)") }
        return "[mfo] brought Media File Operations forward for \(title) — visible: \(yn(r.visible)) (\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Seams: window system + clock

/// The window system as the presenter sees it. The AppKit implementation
/// is below; tests plug in a fake.
@MainActor
protocol MediaFileOperationsForwardWindowing: AnyObject {
    /// Start watching for user clicks; return the first snapshot and the
    /// user's own window numbers (key window + its sheet parent/sheet).
    func beginRaise() -> (observation: MediaFileOperationsForwardSession.Observation, ownWindowNumbers: Set<Int>)
    func observe() -> MediaFileOperationsForwardSession.Observation
    func perform(_ action: MediaFileOperationsForwardSession.Action)
    /// Ask SwiftUI to create the window (it is closed).
    func openJobWindow()
    func diagnostics() -> MediaFileOperationsForwardDiagnostics
    /// Stop watching for user clicks.
    func endRaise()
}

/// "Run this on the main thread after N seconds." ≈ a timer queue.
@MainActor
protocol MediaFileOperationsForwardScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

@MainActor
final class MainQueueForwardScheduler: MediaFileOperationsForwardScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        // asyncAfter(.now()) still waits for the NEXT run-loop turn — the
        // point of the 0 s attempt: the button action + dismiss() return first.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { work() }
        }
    }
}

// MARK: - Presenter

/// Deferred, re-asserting, honest raise. Never calls `NSApp.activate` —
/// if VideoScan is in the background, the window moves within VideoScan's
/// own layer. Never moves the window to another screen or Space; it only
/// reports where it is.
@MainActor
final class AppKitMediaFileOperationsWindowPresenter: MediaFileOperationsWindowPresenting {

    private let windowing: MediaFileOperationsForwardWindowing
    private let scheduler: MediaFileOperationsForwardScheduling
    private let stampForward: () -> Void
    private var generation = 0

    /// Reference holder (≈ a heap-allocated struct shared by pointer) so
    /// the scheduled turns of ONE raise share one session.
    private final class SessionBox {
        var session: MediaFileOperationsForwardSession
        init(_ s: MediaFileOperationsForwardSession) { session = s }
    }

    init(windowing: MediaFileOperationsForwardWindowing? = nil,
         scheduler: MediaFileOperationsForwardScheduling? = nil,
         stampForward: (() -> Void)? = nil) {
        // Defaults built here, not in the parameter list, because default
        // arguments are evaluated outside the main actor.
        self.windowing = windowing ?? AppKitMediaFileOperationsForwardWindowing()
        self.scheduler = scheduler ?? MainQueueForwardScheduler()
        // Tell the legacy "open behind main" helper not to bury the window
        // we are about to raise (MediaFileOperationsWindowOpener).
        self.stampForward = stampForward ?? { MediaFileOperationsWindowOpener.forwardedAt = Date() }
    }

    func bringForwardWithoutFocus(report: @escaping (MediaFileOperationsForwardReport) -> Void) {
        stampForward()
        generation += 1
        let mine = generation
        let start = windowing.beginRaise()
        let was = MediaFileOperationsForwardReport.before(start.observation)
        let box = SessionBox(MediaFileOperationsForwardSession(ownWindowNumbers: start.ownWindowNumbers))

        // Closed → SwiftUI must create it now (asynchronously); the turns
        // below find it, hand the keyboard back and keep it on top.
        // Open → nothing synchronous: the sheet the user clicked in is
        // still up and about to dismiss.
        if was == .closed { windowing.openJobWindow() }

        for delay in MediaFileOperationsForwardSession.attemptDelays {
            scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                guard mine == self.generation else { box.session.supersede(); return }
                let actions = box.session.step(self.windowing.observe())
                for action in actions { self.windowing.perform(action) }
            }
        }
        scheduler.schedule(after: MediaFileOperationsForwardSession.reportDelay) { [weak self] in
            guard let self else { return }
            if mine == self.generation { self.windowing.endRaise() } else { box.session.supersede() }
            report(MediaFileOperationsForwardReport(was: was,
                                                    diagnostics: self.windowing.diagnostics(),
                                                    raises: box.session.raises,
                                                    standDown: box.session.standDown))
        }
    }
}

// MARK: - AppKit window system

@MainActor
final class AppKitMediaFileOperationsForwardWindowing: MediaFileOperationsForwardWindowing {

    /// `weak` ≈ a non-owning pointer that becomes nil when the window dies.
    private weak var previousKey: NSWindow?
    /// Opaque token from NSEvent's local monitor (≈ a subscription handle).
    private var clickMonitor: Any?
    private var userClicked = false

    func beginRaise() -> (observation: MediaFileOperationsForwardSession.Observation, ownWindowNumbers: Set<Int>) {
        endRaise()
        userClicked = false
        let key = NSApp.keyWindow
        previousKey = key
        var own = Set<Int>()
        if let key {
            own.insert(key.windowNumber)
            if let parent = key.sheetParent { own.insert(parent.windowNumber) }
            if let sheet = key.attachedSheet { own.insert(sheet.windowNumber) }
        }
        // A "local monitor" sees this app's events before they are
        // dispatched; we only note that a click happened and pass it on
        // untouched. The Start click itself already happened (buttons fire
        // on mouse-UP), so only a LATER click counts.
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.userClicked = true }
                return event
            }
        return (observe(), own)
    }

    func endRaise() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    func observe() -> MediaFileOperationsForwardSession.Observation {
        let job = Self.jobWindow()
        let key = NSApp.keyWindow
        var o = MediaFileOperationsForwardSession.Observation()
        o.jobFound = job != nil
        o.jobVisible = job?.isVisible ?? false
        o.jobMiniaturized = job?.isMiniaturized ?? false
        o.jobIsFrontmost = job.map(Self.isFrontmost) ?? false
        o.jobIsKey = job != nil && key === job
        o.jobWindowNumber = job?.windowNumber
        o.keyWindowNumber = key?.windowNumber
        o.anchorWindowNumber = anchor(excluding: job)?.windowNumber
        o.userClickedSinceRaise = userClicked
        o.modalRunning = NSApp.modalWindow != nil
        return o
    }

    func perform(_ action: MediaFileOperationsForwardSession.Action) {
        guard let job = Self.jobWindow() else { return }
        switch action {
        case .deminiaturize:
            job.deminiaturize(nil)
        case .restoreKeyToAnchor:
            anchor(excluding: job)?.makeKey()    // keyboard back; does not reorder
        case .orderFront:
            // In front of the other windows WITHOUT becoming key
            // (`makeKeyAndOrderFront` would take the keyboard — rule 3).
            job.orderFront(nil)
        }
    }

    func openJobWindow() {
        MainWindowHelper.shared.openWindowAction?(id: MediaFileOperationsWindowOpener.sceneID)
    }

    func diagnostics() -> MediaFileOperationsForwardDiagnostics {
        var d = MediaFileOperationsForwardDiagnostics()
        guard let job = Self.jobWindow() else { return d }
        d.found = true
        d.isVisible = job.isVisible
        d.miniaturized = job.isMiniaturized
        d.frontmost = Self.isFrontmost(job)
        d.screen = job.screen?.localizedName
        d.mainWindowScreen = MainWindowHelper.shared.findMainWindow()?.screen?.localizedName
        d.level = job.level.rawValue
        // occlusionState is an OptionSet (≈ a bitmask); `.visible` set ⇒
        // at least part of the window is on screen and uncovered.
        d.occlusionVisible = job.occlusionState.contains(.visible)
        d.onActiveSpace = job.isOnActiveSpace
        return d
    }

    // MARK: Helpers

    private static func jobWindow() -> NSWindow? {
        NSApp.windows.first {
            MediaFileOperationsWindowOpener.isJobWindow(identifier: $0.identifier?.rawValue,
                                                        title: $0.title)
        }
    }

    /// `NSApp.orderedWindows` is this app's windows front-to-back. Sheets
    /// travel with their parent and other-level windows (panels, floating)
    /// sit in their own band, so compare within the job window's level.
    private static func isFrontmost(_ job: NSWindow) -> Bool {
        NSApp.orderedWindows.first { $0.isVisible && !$0.isSheet && $0.level == job.level } === job
    }

    private func anchor(excluding job: NSWindow?) -> NSWindow? {
        if let p = previousKey, p.isVisible, p !== job { return p }
        if let m = MainWindowHelper.shared.findMainWindow(), m.isVisible, m !== job { return m }
        return nil
    }
}
