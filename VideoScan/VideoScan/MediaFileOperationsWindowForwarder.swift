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
//   6. One log line per raise: "[mfo] brought Media File Operations forward
//      for <job title>".
//
// Shape: a PURE decision function (`decide`, table-tested), a small
// @MainActor object holding the debounce clock + setting, and ONE AppKit
// side effect behind the `MediaFileOperationsWindowPresenting` protocol so
// tests assert the request without real windows. (A protocol here ≈ a C++
// abstract base class with pure-virtual methods; tests plug in a fake.)
//
// Memory: a Date, a Bool, an Int depth counter and a FIFO set of at most
// `raisedMemoryCap` UUIDs (16 bytes each) — worst case ≈ 4 KB.

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
@MainActor
protocol MediaFileOperationsWindowPresenting: AnyObject {
    func bringForwardWithoutFocus()
}

/// Does nothing — the test-host default, so a unit test that builds a
/// Center can never move a real window.
@MainActor
final class NullMediaFileOperationsWindowPresenter: MediaFileOperationsWindowPresenting {
    func bringForwardWithoutFocus() {}
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
        presenter.bringForwardWithoutFocus()
        log("[mfo] brought Media File Operations forward for \(title)")
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

// MARK: - AppKit presenter

/// The real window mover. Open window → deminiaturize if needed, then
/// `orderFront(nil)`: in front of the other windows WITHOUT becoming key
/// (`makeKeyAndOrderFront` would take the keyboard — rule 3). Closed
/// window → SwiftUI must create it (`openWindow`), which makes the new
/// window key, so the previous key window gets the keyboard back on the
/// next run-loop turns. Never calls `NSApp.activate` — if VideoScan is in
/// the background, the window moves within VideoScan's own layer.
@MainActor
final class AppKitMediaFileOperationsWindowPresenter: MediaFileOperationsWindowPresenting {

    private var generation = 0

    /// Reference holder (≈ a heap-allocated flag shared by pointer) so the
    /// retries of ONE raise see each other's "done".
    private final class SettledBox { var settled = false }

    func bringForwardWithoutFocus() {
        // Tell the legacy "open behind main" helper not to bury the window
        // we are about to raise (MediaFileOperationsWindowOpener).
        MediaFileOperationsWindowOpener.forwardedAt = Date()

        let previousKey = NSApp.keyWindow
        if let window = Self.jobWindow(), window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
            scheduleKeyRestore(previousKey)   // deminiaturize can take key
            return
        }
        guard let open = MainWindowHelper.shared.openWindowAction else { return }
        open(id: MediaFileOperationsWindowOpener.sceneID)
        scheduleKeyRestore(previousKey)
    }

    private static func jobWindow() -> NSWindow? {
        NSApp.windows.first {
            MediaFileOperationsWindowOpener.isJobWindow(identifier: $0.identifier?.rawValue,
                                                        title: $0.title)
        }
    }

    /// SwiftUI creates/animates windows asynchronously, so check on a few
    /// later turns; the first one that acts retires the rest, and a newer
    /// raise supersedes an older one's retries.
    private func scheduleKeyRestore(_ previousKey: NSWindow?) {
        generation += 1
        let mine = generation
        let ledger = SettledBox()   // shared by this raise's three retries
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, mine == self.generation, !ledger.settled else { return }
                guard let job = Self.jobWindow(), job.isVisible else { return }
                if NSApp.keyWindow !== job { return }        // focus never moved (or user moved it)
                if NSApp.modalWindow != nil { return }       // never fight an alert
                let anchor = (previousKey?.isVisible == true && previousKey !== job ? previousKey : nil)
                    ?? MainWindowHelper.shared.findMainWindow().flatMap { $0.isVisible && $0 !== job ? $0 : nil }
                guard let anchor else { return }
                ledger.settled = true
                anchor.makeKey()          // keyboard back, job window stays in front
                job.orderFront(nil)
            }
        }
    }
}
