import Testing
import Combine
import Foundation
@testable import VideoScan

// MARK: - "Bring the MFO window forward when a job starts" (Rick 2026-09-21)
//
// Dimensions (feature-test checklist):
//   LOGIC     — user start raises; background/unknown never; setting off
//               never; several starts inside 2 s raise once; a job never
//               re-raises; the scope is exact (a child job registered after
//               the scope closes is background).
//   ISOLATION — a Center built under the test host gets the null presenter,
//               default setting, and never writes real UserDefaults.
//   SENSOR    — pins the decision for EVERY kind × origin, the default, the
//               prefs key, the debounce, and which source files mark their
//               starts as user-started (and which must not).
//
// No real windows: the AppKit side effect sits behind
// MediaFileOperationsWindowPresenting and a counting fake stands in.

// MARK: - Fakes

/// Counts raises and reports a canned "it worked" state synchronously.
@MainActor
private final class CountingPresenter: MediaFileOperationsWindowPresenting {
    var raises = 0
    static let canned = MediaFileOperationsForwardReport(
        was: .behind,
        diagnostics: MediaFileOperationsForwardDiagnostics(
            found: true, isVisible: true, miniaturized: false, frontmost: true,
            screen: "BenQ MA320U", mainWindowScreen: "BenQ MA320U", level: 0,
            occlusionVisible: true, onActiveSpace: true),
        raises: 1, standDown: nil)
    func bringForwardWithoutFocus(report: @escaping (MediaFileOperationsForwardReport) -> Void) {
        raises += 1
        report(Self.canned)
    }
}

private let cannedTail = " — visible: yes (found: yes, was: behind, front: yes, screen: BenQ MA320U, level: 0, occlusion: visible, space: active, raises: 1)"

/// Settable clock — the debounce is tested without sleeping.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

@MainActor
private final class ForwardFakeJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind
    let title: String
    var subtitle: String = ""
    var fraction: Double = 0
    var isIndeterminate = false
    let startedAt = Date()
    var finishedAt: Date?
    @Published var settableState: MediaFileOperationState = .running
    var state: MediaFileOperationState { settableState }

    init(kind: MediaFileOperationKind = .trim, title: String = "fake job") {
        self.kind = kind
        self.title = title
    }

    func cancel() { settableState = .cancelled }
}

@MainActor
private struct Rig {
    let center = MediaFileOperationsCenter()
    let presenter = CountingPresenter()
    let clock = TestClock()
    let logBox = LogBox()
    let forwarder: MediaFileOperationsWindowForwarder

    final class LogBox { var lines: [String] = [] }

    init(showOnJobStart: Bool = true) {
        let clock = self.clock, logBox = self.logBox
        forwarder = MediaFileOperationsWindowForwarder(
            setting: MediaFileOperationsForwardSetting(showOnJobStart: showOnJobStart),
            presenter: presenter,
            now: { clock.now },
            log: { logBox.lines.append($0) })
        center.windowForwarder = forwarder
    }
}

// MARK: - Logic

@MainActor
@Suite("MFO window forward — logic")
struct MediaFileOperationsWindowForwardLogicTests {

    @Test func userStartedJobRaisesOnceAndLogsOneLine() {
        let rig = Rig()
        rig.center.startedByUser { $0.add(ForwardFakeJob(title: "Trim tape 3")) }
        #expect(rig.presenter.raises == 1)
        #expect(rig.logBox.lines == ["[mfo] brought Media File Operations forward for Trim tape 3" + cannedTail])
    }

    @Test func backgroundJobNeverRaises() {
        let rig = Rig()
        rig.center.add(ForwardFakeJob(kind: .archiveAngel))   // no user scope ⇒ background
        #expect(rig.presenter.raises == 0)
        #expect(rig.logBox.lines.isEmpty)
    }

    @Test func settingOffNeverRaises() {
        let rig = Rig(showOnJobStart: false)
        rig.center.startedByUser { $0.add(ForwardFakeJob()) }
        #expect(rig.presenter.raises == 0)
        #expect(rig.logBox.lines.isEmpty)
    }

    @Test func togglingSettingOffAtRuntimeStopsRaises() {
        let rig = Rig()
        rig.forwarder.setShowOnJobStart(false)
        rig.center.startedByUser { $0.add(ForwardFakeJob()) }
        #expect(rig.presenter.raises == 0)
        rig.forwarder.setShowOnJobStart(true)
        rig.center.startedByUser { $0.add(ForwardFakeJob()) }
        #expect(rig.presenter.raises == 1)
    }

    @Test func startsInsideTwoSecondsRaiseOnce() {
        let rig = Rig()
        rig.center.startedByUser { $0.add(ForwardFakeJob(title: "a")) }
        rig.clock.advance(0.5)
        rig.center.startedByUser { $0.add(ForwardFakeJob(title: "b")) }
        rig.clock.advance(1.2)                     // 1.7 s after the raise
        rig.center.startedByUser { $0.add(ForwardFakeJob(title: "c")) }
        #expect(rig.presenter.raises == 1)
        #expect(rig.logBox.lines.count == 1)
    }

    @Test func aMultiSelectionInOneScopeRaisesOnce() {
        let rig = Rig()
        rig.center.startedByUser { center in
            for i in 0..<12 { center.add(ForwardFakeJob(kind: .verifyAudio, title: "v\(i)")) }
        }
        #expect(rig.presenter.raises == 1)
        #expect(rig.center.jobs.count == 12)
    }

    @Test func aStartAfterTheDebounceRaisesAgain() {
        let rig = Rig()
        rig.center.startedByUser { $0.add(ForwardFakeJob()) }
        rig.clock.advance(MediaFileOperationsWindowForwarder.debounceSeconds)
        rig.center.startedByUser { $0.add(ForwardFakeJob()) }
        #expect(rig.presenter.raises == 2)
    }

    @Test func aJobNeverReRaisesDuringItsLife() {
        let rig = Rig()
        let job = ForwardFakeJob()
        rig.center.startedByUser { $0.add(job) }
        rig.clock.advance(60)
        // Progress beats and state changes must not raise.
        job.fraction = 0.5
        job.objectWillChange.send()
        job.settableState = .finished(summary: "ok")
        #expect(rig.presenter.raises == 1)
        // Even a direct second report for the same id is refused.
        let again = rig.forwarder.jobStarted(id: job.id, title: job.title, origin: .user)
        #expect(again == .skipAlreadyRaisedForJob)
        #expect(rig.presenter.raises == 1)
    }

    @Test func aJobSuppressedByTheDebounceNeverRaisesLater() {
        let rig = Rig()
        rig.center.startedByUser { $0.add(ForwardFakeJob()) }
        let second = ForwardFakeJob()
        rig.center.startedByUser { $0.add(second) }
        rig.clock.advance(30)
        #expect(rig.forwarder.jobStarted(id: second.id, title: "x", origin: .user) == .skipAlreadyRaisedForJob)
        #expect(rig.presenter.raises == 1)
    }

    @Test func theScopeIsExactChildJobsAddedLaterAreBackground() {
        let rig = Rig()
        rig.center.startedByUser { $0.add(ForwardFakeJob(kind: .archiveAngel)) }
        #expect(rig.forwarder.userOriginDepth == 0, "scope closed")
        rig.clock.advance(10)
        // What ArchiveAngelJob does from its own Task: a child start.
        rig.center.add(ForwardFakeJob(kind: .transcode))
        #expect(rig.presenter.raises == 1)
    }

    @Test func nestedScopesStayUserAndUnwind() {
        let rig = Rig()
        rig.center.startedByUser { outer in
            outer.startedByUser { inner in
                #expect(rig.forwarder.currentOrigin == .user)
                _ = inner
            }
            #expect(rig.forwarder.currentOrigin == .user)
        }
        #expect(rig.forwarder.currentOrigin == .background)
    }

    @Test func scopeUnwindsWhenTheBodyThrows() {
        struct Boom: Error {}
        let rig = Rig()
        #expect(throws: Boom.self) {
            try rig.center.startedByUser { _ in throw Boom() }
        }
        #expect(rig.forwarder.userOriginDepth == 0)
    }

    @Test func startedByUserPassesTheReturnValueThrough() {
        let rig = Rig()
        let job = ForwardFakeJob()
        let returned = rig.center.startedByUser { center -> ForwardFakeJob in
            center.add(job)
            return job
        }
        #expect(returned === job)
    }

    @Test func combineOutsideTheCenterRaisesAndIsDebounced() {
        let rig = Rig()
        rig.center.noteUserStartedOutsideCenter(title: "Combine 3 pairs")
        rig.center.noteUserStartedOutsideCenter(title: "Combine 1 pair")
        #expect(rig.presenter.raises == 1)
        #expect(rig.logBox.lines == ["[mfo] brought Media File Operations forward for Combine 3 pairs" + cannedTail])
    }

    @Test func decideTable() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        typealias F = MediaFileOperationsWindowForwarder
        #expect(F.decide(origin: .user, enabled: true, alreadyRaisedForJob: false, lastRaiseAt: nil, now: t0) == .raise)
        #expect(F.decide(origin: .background, enabled: true, alreadyRaisedForJob: false, lastRaiseAt: nil, now: t0) == .skipBackground)
        #expect(F.decide(origin: .user, enabled: false, alreadyRaisedForJob: false, lastRaiseAt: nil, now: t0) == .skipSettingOff)
        #expect(F.decide(origin: .user, enabled: true, alreadyRaisedForJob: true, lastRaiseAt: nil, now: t0) == .skipAlreadyRaisedForJob)
        #expect(F.decide(origin: .user, enabled: true, alreadyRaisedForJob: false,
                         lastRaiseAt: t0, now: t0.addingTimeInterval(1.99)) == .skipDebounced)
        #expect(F.decide(origin: .user, enabled: true, alreadyRaisedForJob: false,
                         lastRaiseAt: t0, now: t0.addingTimeInterval(2.0)) == .raise)
    }

    @Test func legacyOpenBehindStandsDownOnlyRightAfterAForward() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
        typealias O = MediaFileOperationsWindowOpener
        #expect(!O.defersToForward(forwardedAt: nil, now: t0))
        #expect(O.defersToForward(forwardedAt: t0, now: t0))
        #expect(O.defersToForward(forwardedAt: t0, now: t0.addingTimeInterval(1.5)))
        #expect(!O.defersToForward(forwardedAt: t0, now: t0.addingTimeInterval(2.5)))
        #expect(!O.defersToForward(forwardedAt: t0.addingTimeInterval(10), now: t0), "a future stamp is ignored")
    }

    @Test func raisedMemoryIsBounded() {
        let rig = Rig()
        for _ in 0..<(MediaFileOperationsWindowForwarder.raisedMemoryCap + 50) {
            rig.clock.advance(5)
            rig.forwarder.jobStarted(id: UUID(), title: "x", origin: .user)
        }
        #expect(rig.presenter.raises == MediaFileOperationsWindowForwarder.raisedMemoryCap + 50)
    }
}

// MARK: - Isolation

@MainActor
@Suite("MFO window forward — test-host isolation")
struct MediaFileOperationsWindowForwardIsolationTests {

    @Test func centerUnderTestHostGetsNullPresenterAndDefaultSetting() {
        #expect(TestEnvironment.isTestHost)
        let forwarder = MediaFileOperationsWindowForwarder.makeDefault()
        #expect(forwarder.setting.showOnJobStart == true)
        let center = MediaFileOperationsCenter()
        #expect(center.windowForwarder.setting == MediaFileOperationsForwardSetting())
    }

    @Test func togglingUnderTestHostNeverWritesRealPrefs() {
        let key = MediaFileOperationsForwardSetting.key
        let before = UserDefaults.standard.object(forKey: key) as? Bool
        let forwarder = MediaFileOperationsWindowForwarder.makeDefault()
        forwarder.setShowOnJobStart(false)
        forwarder.setShowOnJobStart(true)
        forwarder.setShowOnJobStart(false)
        let after = UserDefaults.standard.object(forKey: key) as? Bool
        #expect(before == after, "real prefs untouched")
    }

    @Test func poisonedRealPrefsDoNotLeakIntoTheTestHost() throws {
        // Even if the developer's real prefs say OFF, a test-host Center
        // sees the default — no global state crosses into tests.
        let key = MediaFileOperationsForwardSetting.key
        let suite = "vs.test.mfo-forward.\(UUID().uuidString)"
        let scratch = try #require(UserDefaults(suiteName: suite))
        defer { scratch.removePersistentDomain(forName: suite) }
        scratch.set(false, forKey: key)
        #expect(MediaFileOperationsForwardSetting.restored(from: scratch).showOnJobStart == false)
        #expect(MediaFileOperationsWindowForwarder.makeDefault().setting.showOnJobStart == true)
    }

    @Test func settingRoundTripsThroughScratchDefaults() throws {
        let suite = "vs.test.mfo-forward.\(UUID().uuidString)"
        let scratch = try #require(UserDefaults(suiteName: suite))
        defer { scratch.removePersistentDomain(forName: suite) }
        #expect(MediaFileOperationsForwardSetting.restored(from: scratch).showOnJobStart == true, "absent ⇒ ON")
        MediaFileOperationsForwardSetting(showOnJobStart: false).save(to: scratch)
        #expect(MediaFileOperationsForwardSetting.restored(from: scratch).showOnJobStart == false)
        MediaFileOperationsForwardSetting(showOnJobStart: true).save(to: scratch)
        #expect(MediaFileOperationsForwardSetting.restored(from: scratch).showOnJobStart == true)
    }

    @Test func setterPersistsExactlyOncePerChange() {
        var saved: [Bool] = []
        let forwarder = MediaFileOperationsWindowForwarder(
            presenter: CountingPresenter(),
            persist: { saved.append($0.showOnJobStart) })
        forwarder.setShowOnJobStart(true)    // no change ⇒ no save
        forwarder.setShowOnJobStart(false)
        forwarder.setShowOnJobStart(false)   // no change ⇒ no save
        forwarder.setShowOnJobStart(true)
        #expect(saved == [false, true])
    }
}

// MARK: - Sensor

@MainActor
@Suite("MFO window forward — sensor")
struct MediaFileOperationsWindowForwardSensorTests {

    /// Every kind raises when (and only when) the user started it. A new
    /// kind added to the enum is covered automatically; a kind that must
    /// NOT raise even when user-started would have to change this table.
    @Test func everyKindRaisesOnlyForUserOrigin() {
        for kind in MediaFileOperationKind.allCases {
            for origin in MediaFileOperationOrigin.allCases {
                let rig = Rig()
                if origin == .user {
                    rig.center.startedByUser { $0.add(ForwardFakeJob(kind: kind)) }
                } else {
                    rig.center.add(ForwardFakeJob(kind: kind))
                }
                let expected = origin == .user ? 1 : 0
                #expect(rig.presenter.raises == expected, "\(kind.rawValue) / \(origin.rawValue)")
            }
        }
    }

    @Test func pinnedConstants() {
        #expect(MediaFileOperationsForwardSetting().showOnJobStart == true)
        #expect(MediaFileOperationsForwardSetting.key == "mfo.showWindowOnJobStart")
        #expect(MediaFileOperationsWindowForwarder.debounceSeconds == 2)
    }

    // Source sensor: which call sites claim user origin. Adding a new
    // user-facing start without `startedByUser` leaves the window hidden
    // (Rick's complaint); wrapping a background start makes it pop up
    // uninvited. Both directions are pinned.

    private var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // VideoScanTests
            .deletingLastPathComponent()      // VideoScan (project dir)
            .appendingPathComponent("VideoScan")
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSourceDir.appendingPathComponent(file), encoding: .utf8)
    }

    /// File → how many `startedByUser` scopes it must contain.
    static let userStartSites: [String: Int] = [
        "ArchiveAngelReadyDisclosure.swift": 1,   // Promote (Angel batch)
        "ArchiveAngelReviewSheet.swift": 1,       // Promote (Angel review)
        "ArchiveAngelStartSheet.swift": 1,        // Archive Angel… Start
        "ArchivedWhatNextSheet.swift": 1,         // Move N to Trash (prune apply)
        "ArchiveView+Table.swift": 1,             // Archive Helper from the nudge
        "ArchiveView.swift": 1,                   // Verify copies…
        "CatalogContent+AssessCopies.swift": 1,   // Archive Helper…
        "CatalogContent+Promote.swift": 1,        // Prepare with Archive Angel
        "CatalogContent+Table.swift": 8,          // compare, find, verify×2, analyze×2, reformat×2
        "CatalogHelpers.swift": 1,                // Extract Facial Frames
        "CleanupSheet.swift": 1,
        "ContentView.swift": 2,                   // Delete Duplicates + accepted Resume
        "MediaFileOperationsWindow.swift": 1,     // banner Resume
        "PromoteToArchiveSheet.swift": 1,
        "RipAllFramesSheet.swift": 1,
        "TranscodeSheet.swift": 1,
        "TrimSheet.swift": 1,
        "VerifyAudioSheet.swift": 2,              // Balance + Rebuild
    ]

    /// Starts that happen on the app's own initiative — must never claim
    /// user origin.
    static let backgroundStartFiles = [
        "ArchiveAngelJob.swift",        // Angel's child verify/balance/transcode
        "ArchiveAngelPromoter.swift",   // the promote the Angel hands off
        "HelperAudioRepair.swift",      // runs inside the already-visible MFO window
        "VideoScanModel+ArchiveAngelSweep.swift",
    ]

    @Test func userStartSitesAreMarked() throws {
        for (file, expected) in Self.userStartSites {
            let count = try source(file).components(separatedBy: ".startedByUser {").count - 1
            #expect(count == expected, "\(file): \(count) startedByUser scopes, expected \(expected)")
        }
    }

    @Test func backgroundStartsAreNotMarked() throws {
        for file in Self.backgroundStartFiles {
            #expect(!(try source(file)).contains("startedByUser"), "\(file) must stay background")
        }
    }

    @Test func combineSheetsRequestTheRaise() throws {
        let s = try source("CombineSheet.swift")
        #expect(s.components(separatedBy: "noteUserStartedOutsideCenter(").count - 1 == 2)
    }

    @Test func theCenterReportsEveryAddToTheForwarder() throws {
        let s = try source("MediaFileOperations.swift")
        #expect(s.contains("windowForwarder.jobStarted(id: job.id, title: job.title,"))
    }
}

// MARK: - 2026-09-22 fix: deferred, re-asserting, honest raise
//
// Rick (Release b334247b): "didn't seem like the MFO window jumped in front"
// although the log said it had. The raise ran synchronously inside the
// sheet button's action (before `dismiss()`), and the log line was written
// before anything checked the result. These suites drive the REAL presenter
// (AppKitMediaFileOperationsWindowPresenter) through its two seams — a fake
// window system and a manual clock — so the scheduling rules are tested
// without real windows. Real AppKit ordering (what a sheet's end does to
// its parent) cannot be exercised in a unit test; the honest log line is
// the field sensor for that.

/// A scripted window system. `obs` is what the next `observe()` returns;
/// `onPerform` lets a test model AppKit's reaction to an action.
@MainActor
private final class FakeWindowing: MediaFileOperationsForwardWindowing {
    typealias Obs = MediaFileOperationsForwardSession.Observation
    var obs = Obs()
    var own: Set<Int> = []
    var performed: [MediaFileOperationsForwardSession.Action] = []
    var opens = 0
    var begins = 0
    var ends = 0
    var diag = MediaFileOperationsForwardDiagnostics()
    var onPerform: ((MediaFileOperationsForwardSession.Action, FakeWindowing) -> Void)?

    func beginRaise() -> (observation: Obs, ownWindowNumbers: Set<Int>) {
        begins += 1
        return (obs, own)
    }
    func observe() -> Obs { obs }
    func perform(_ action: MediaFileOperationsForwardSession.Action) {
        performed.append(action)
        onPerform?(action, self)
    }
    func openJobWindow() { opens += 1 }
    func diagnostics() -> MediaFileOperationsForwardDiagnostics { diag }
    func endRaise() { ends += 1 }
}

/// Manual clock: `run(until:)` fires every scheduled item due by then, in
/// time order (stable for equal times, like the main queue).
@MainActor
private final class ManualScheduler: MediaFileOperationsForwardScheduling {
    private var items: [(at: TimeInterval, seq: Int, work: @MainActor () -> Void)] = []
    private var seq = 0
    private(set) var now: TimeInterval = 0
    var scheduledDelays: [TimeInterval] = []

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        seq += 1
        scheduledDelays.append(seconds)
        items.append((now + seconds, seq, work))
    }
    func run(until t: TimeInterval) {
        while let next = items.filter({ $0.at <= t }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            items.removeAll { $0.seq == next.seq }
            now = next.at
            next.work()
        }
        now = t
    }
    var pending: Int { items.count }
}

private let jobNo = 50, mainNo = 10, sheetNo = 11, otherNo = 77

@MainActor
private struct PresenterRig {
    let windowing = FakeWindowing()
    let scheduler = ManualScheduler()
    let stamps = Box()
    let reports = ReportBox()
    let presenter: AppKitMediaFileOperationsWindowPresenter

    final class Box { var count = 0 }
    final class ReportBox { var items: [MediaFileOperationsForwardReport] = [] }

    /// Default scene: Promote — Confirm clicked in a SHEET (11) on the main
    /// window (10); the job window (50) is open but behind.
    init() {
        let stamps = self.stamps
        presenter = AppKitMediaFileOperationsWindowPresenter(
            windowing: windowing, scheduler: scheduler, stampForward: { stamps.count += 1 })
        windowing.own = [sheetNo, mainNo]
        windowing.obs = .init(jobFound: true, jobVisible: true, jobMiniaturized: false,
                              jobIsFrontmost: false, jobIsKey: false,
                              jobWindowNumber: jobNo, keyWindowNumber: sheetNo,
                              anchorWindowNumber: sheetNo)
        // Model AppKit: orderFront puts the job window on top; makeKey on
        // the anchor moves the keyboard there.
        windowing.onPerform = { action, w in
            switch action {
            case .orderFront: w.obs.jobIsFrontmost = true
            case .restoreKeyToAnchor:
                w.obs.jobIsKey = false
                w.obs.keyWindowNumber = w.obs.anchorWindowNumber
            case .deminiaturize: w.obs.jobMiniaturized = false; w.obs.jobIsFrontmost = true
            }
        }
    }

    func raise() {
        let reports = self.reports
        presenter.bringForwardWithoutFocus { reports.items.append($0) }
    }

    /// What AppKit does when the sheet finishes dismissing: the sheet's
    /// parent takes the keyboard back and lands on top of the job window.
    func sheetEndsAndBuriesTheJobWindow() {
        windowing.obs.jobIsFrontmost = false
        windowing.obs.keyWindowNumber = mainNo
        windowing.obs.anchorWindowNumber = mainNo
    }
}

@MainActor
@Suite("MFO window forward — deferred presenter")
struct MediaFileOperationsWindowForwardPresenterTests {

    @Test func nothingMovesSynchronouslyInsideTheStartCall() {
        let rig = PresenterRig()
        rig.raise()
        #expect(rig.windowing.performed.isEmpty, "the sheet is still up — wait a turn")
        #expect(rig.stamps.count == 1, "legacy open-behind is told to stand down at once")
        #expect(rig.windowing.opens == 0, "an open window is never re-opened")
        #expect(rig.scheduler.scheduledDelays == [0, 0.3, 0.9, 1.15])
    }

    @Test func reassertsAfterTheSheetDismissBuriesIt() {
        let rig = PresenterRig()
        rig.raise()
        rig.scheduler.run(until: 0)
        #expect(rig.windowing.performed == [.orderFront])
        rig.sheetEndsAndBuriesTheJobWindow()     // Rick's symptom
        rig.scheduler.run(until: 0.3)
        #expect(rig.windowing.performed == [.orderFront, .orderFront], "sheet parent taking key is NOT the user moving focus")
        rig.scheduler.run(until: 0.9)
        #expect(rig.windowing.performed.count == 2, "already frontmost ⇒ no third orderFront")
        #expect(rig.reports.items.isEmpty, "no log line before the last attempt")
        rig.scheduler.run(until: 1.15)
        #expect(rig.reports.items.count == 1)
        #expect(rig.reports.items.first?.raises == 2)
        #expect(rig.reports.items.first?.was == .behind)
        #expect(rig.reports.items.first?.standDown == nil)
        #expect(rig.windowing.ends == 1)
        #expect(rig.scheduler.pending == 0)
    }

    @Test func aUserClickStopsEveryLaterReassert() {
        let rig = PresenterRig()
        rig.raise()
        rig.scheduler.run(until: 0)
        // The user clicks the main window on purpose; it comes front.
        rig.windowing.obs.userClickedSinceRaise = true
        rig.sheetEndsAndBuriesTheJobWindow()
        rig.scheduler.run(until: 1.15)
        #expect(rig.windowing.performed == [.orderFront], "never fight the user")
        #expect(rig.reports.items.first?.standDown == .userMovedFocus)
        #expect(rig.reports.items.first?.raises == 1)
    }

    @Test func keyboardMovedToAnUnrelatedWindowStandsDown() {
        let rig = PresenterRig()
        rig.raise()
        rig.scheduler.run(until: 0)
        rig.windowing.obs.jobIsFrontmost = false
        rig.windowing.obs.keyWindowNumber = otherNo    // ⌘` to Hallie, say
        rig.scheduler.run(until: 1.15)
        #expect(rig.windowing.performed == [.orderFront])
        #expect(rig.reports.items.first?.standDown == .userMovedFocus)
    }

    @Test func closedWindowIsOpenedThenKeyboardHandedBackOnce() {
        let rig = PresenterRig()
        rig.windowing.own = [mainNo]
        rig.windowing.obs = .init(jobFound: false, keyWindowNumber: mainNo, anchorWindowNumber: mainNo)
        rig.raise()
        #expect(rig.windowing.opens == 1, "closed ⇒ SwiftUI creates it right away")
        rig.scheduler.run(until: 0)
        #expect(rig.windowing.performed.isEmpty, "still being created")
        // SwiftUI created it in front AND made it key.
        rig.windowing.obs.jobFound = true
        rig.windowing.obs.jobVisible = true
        rig.windowing.obs.jobIsFrontmost = true
        rig.windowing.obs.jobIsKey = true
        rig.windowing.obs.jobWindowNumber = jobNo
        rig.windowing.obs.keyWindowNumber = jobNo
        rig.scheduler.run(until: 0.3)
        #expect(rig.windowing.performed == [.restoreKeyToAnchor, .orderFront])
        rig.scheduler.run(until: 1.15)
        #expect(rig.windowing.performed.count == 2)
        #expect(rig.reports.items.first?.was == .closed)
        #expect(rig.reports.items.first?.standDown == nil, "our own key hand-back is not the user moving focus")
    }

    @Test func alreadyFrontDoesNothingAndSaysSo() {
        let rig = PresenterRig()
        rig.windowing.obs.jobIsFrontmost = true   // e.g. Transcode sheet ON the MFO window
        rig.windowing.obs.keyWindowNumber = jobNo
        rig.raise()
        rig.scheduler.run(until: 1.15)
        #expect(rig.windowing.performed.isEmpty)
        #expect(rig.reports.items.first?.was == .front)
        #expect(rig.reports.items.first?.raises == 0)
    }

    @Test func minimizedIsDeminiaturizedOnce() {
        let rig = PresenterRig()
        rig.windowing.obs.jobVisible = false
        rig.windowing.obs.jobMiniaturized = true
        rig.windowing.onPerform = nil               // the Dock animation is slow
        rig.raise()
        #expect(rig.windowing.opens == 0, "minimized is not closed")
        rig.scheduler.run(until: 0.9)
        #expect(rig.windowing.performed == [.deminiaturize])
        rig.scheduler.run(until: 1.15)
        #expect(rig.reports.items.first?.was == .minimized)
    }

    @Test func aModalAlertSkipsTheTurnWithoutStandingDown() {
        let rig = PresenterRig()
        rig.windowing.obs.modalRunning = true
        rig.raise()
        rig.scheduler.run(until: 0.3)
        #expect(rig.windowing.performed.isEmpty)
        rig.windowing.obs.modalRunning = false
        rig.scheduler.run(until: 1.15)
        #expect(rig.windowing.performed == [.orderFront])
        #expect(rig.reports.items.first?.standDown == nil)
    }

    @Test func aNewerRaiseSupersedesTheOlderOnesTurns() {
        let rig = PresenterRig()
        rig.raise()
        rig.scheduler.run(until: 0.1)
        #expect(rig.windowing.performed == [.orderFront])
        rig.windowing.obs.jobIsFrontmost = false
        rig.raise()                                 // second raise at t = 0.1
        rig.scheduler.run(until: 2)
        #expect(rig.reports.items.count == 2, "each raise reports once")
        #expect(rig.reports.items.first?.standDown == .superseded)
        #expect(rig.reports.items.last?.standDown == nil)
        #expect(rig.windowing.ends == 1, "only the current raise stops the click watch")
        #expect(rig.windowing.begins == 2)
    }

    @Test func theReportCarriesTheFinalDiagnostics() throws {
        let rig = PresenterRig()
        rig.windowing.diag = .init(found: true, isVisible: true, frontmost: true,
                                   screen: "LG", mainWindowScreen: "BenQ", level: 0,
                                   occlusionVisible: true, onActiveSpace: false)
        rig.raise()
        rig.scheduler.run(until: 1.15)
        let r = try #require(rig.reports.items.first)
        #expect(r.diagnostics.screen == "LG")
        #expect(r.visible == false, "on another Space ⇒ Rick cannot see it")
    }
}

@Suite("MFO window forward — session state machine")
struct MediaFileOperationsWindowForwardSessionTests {
    typealias S = MediaFileOperationsForwardSession

    private func behind() -> S.Observation {
        .init(jobFound: true, jobVisible: true, jobIsFrontmost: false,
              jobWindowNumber: jobNo, keyWindowNumber: mainNo, anchorWindowNumber: mainNo)
    }

    @Test func behindOrdersFrontWithoutKey() {
        var s = S(ownWindowNumbers: [mainNo])
        #expect(s.step(behind()) == [.orderFront])
        #expect(s.raises == 1)
    }

    @Test func frontmostDoesNothing() {
        var s = S(ownWindowNumbers: [mainNo])
        var o = behind(); o.jobIsFrontmost = true
        #expect(s.step(o) == [])
        #expect(s.raises == 0)
    }

    @Test func notFoundOrNotYetVisibleWaits() {
        var s = S(ownWindowNumbers: [mainNo])
        var o = behind(); o.jobFound = false
        #expect(s.step(o) == [])
        o.jobFound = true; o.jobVisible = false
        #expect(s.step(o) == [])
        #expect(s.standDown == nil)
    }

    @Test func standDownIsPermanent() {
        var s = S(ownWindowNumbers: [mainNo])
        var o = behind(); o.userClickedSinceRaise = true
        #expect(s.step(o) == [])
        o.userClickedSinceRaise = false
        #expect(s.step(o) == [], "a click once is enough")
        #expect(s.standDown == .userMovedFocus)
    }

    @Test func keyOnTheJobWindowIsNotAForeignWindow() {
        var s = S(ownWindowNumbers: [mainNo])
        var o = behind(); o.keyWindowNumber = jobNo; o.jobIsKey = true
        #expect(s.step(o) == [.restoreKeyToAnchor, .orderFront])
        #expect(s.standDown == nil)
    }

    @Test func keyHandBackHappensOnceAndNeedsAnAnchor() {
        var s = S(ownWindowNumbers: [mainNo])
        var o = behind(); o.jobIsKey = true; o.keyWindowNumber = jobNo; o.jobIsFrontmost = true
        o.anchorWindowNumber = nil
        #expect(s.step(o) == [], "no visible anchor ⇒ leave the keyboard where it is")
        o.anchorWindowNumber = mainNo
        #expect(s.step(o) == [.restoreKeyToAnchor, .orderFront])
        #expect(s.step(o) == [], "only once")
    }

    @Test func supersedeStopsFurtherSteps() {
        var s = S(ownWindowNumbers: [mainNo])
        s.supersede()
        #expect(s.step(behind()) == [])
        #expect(s.standDown == .superseded)
    }

    @Test func pinnedTimings() {
        #expect(S.attemptDelays == [0, 0.3, 0.9])
        #expect(S.reportDelay > S.attemptDelays.last!)
        #expect(S.reportDelay < MediaFileOperationsWindowForwarder.debounceSeconds,
                "the legacy opener's stand-down (2 s) covers every attempt")
    }
}

@Suite("MFO window forward — honest log line")
struct MediaFileOperationsWindowForwardLogLineTests {
    typealias R = MediaFileOperationsForwardReport
    typealias D = MediaFileOperationsForwardDiagnostics

    private func report(_ d: D, was: R.Before = .behind, raises: Int = 2,
                        standDown: MediaFileOperationsForwardSession.StandDown? = nil) -> R {
        R(was: was, diagnostics: d, raises: raises, standDown: standDown)
    }

    private let seen = D(found: true, isVisible: true, miniaturized: false, frontmost: true,
                         screen: "BenQ MA320U", mainWindowScreen: "BenQ MA320U", level: 0,
                         occlusionVisible: true, onActiveSpace: true)

    @Test func visibleYes() {
        #expect(R.logLine(title: "promote x", report: report(seen))
                == "[mfo] brought Media File Operations forward for promote x — visible: yes (found: yes, was: behind, front: yes, screen: BenQ MA320U, level: 0, occlusion: visible, space: active, raises: 2)")
    }

    @Test func buriedBehindAnotherWindow() {
        var d = seen; d.frontmost = false; d.occlusionVisible = false
        #expect(R.logLine(title: "t", report: report(d))
                == "[mfo] brought Media File Operations forward for t — visible: no (found: yes, was: behind, front: no, screen: BenQ MA320U, level: 0, occlusion: hidden, space: active, raises: 2)")
    }

    @Test func otherScreenAndOtherSpaceAreNamed() {
        var d = seen; d.screen = "LG UltraFine"; d.onActiveSpace = false; d.level = 3
        let line = R.logLine(title: "t", report: report(d))
        #expect(line.contains("visible: no"))
        #expect(line.contains("screen: LG UltraFine, main window screen: BenQ MA320U, level: 3"))
        #expect(line.contains("space: other"))
    }

    @Test func notFound() {
        #expect(R.logLine(title: "t", report: report(D(), was: .closed, raises: 0))
                == "[mfo] brought Media File Operations forward for t — visible: no (found: no, was: closed, raises: 0)")
    }

    @Test func standDownIsNamed() {
        let line = R.logLine(title: "t", report: report(seen, raises: 1, standDown: .userMovedFocus))
        #expect(line.hasSuffix("raises: 1, stood down: user moved focus)"))
    }

    @Test func minimizedStaysInvisible() {
        var d = seen; d.miniaturized = true
        let line = R.logLine(title: "t", report: report(d, was: .minimized))
        #expect(line.contains("visible: no"))
        #expect(line.contains("minimized: yes"))
    }

    @Test func beforeClassification() {
        typealias O = MediaFileOperationsForwardSession.Observation
        #expect(R.before(O()) == .closed)
        #expect(R.before(O(jobFound: true, jobVisible: false)) == .closed)
        #expect(R.before(O(jobFound: true, jobVisible: false, jobMiniaturized: true)) == .minimized)
        #expect(R.before(O(jobFound: true, jobVisible: true, jobIsFrontmost: false)) == .behind)
        #expect(R.before(O(jobFound: true, jobVisible: true, jobIsFrontmost: true)) == .front)
    }
}

@MainActor
@Suite("MFO window forward — log timing + legacy opener sensor")
struct MediaFileOperationsWindowForwardTimingSensorTests {

    /// Holds the report callback instead of calling it — like the real
    /// presenter, which reports ~1.2 s later.
    @MainActor
    private final class DeferredPresenter: MediaFileOperationsWindowPresenting {
        var pending: [(MediaFileOperationsForwardReport) -> Void] = []
        func bringForwardWithoutFocus(report: @escaping (MediaFileOperationsForwardReport) -> Void) {
            pending.append(report)
        }
    }

    @Test func theLogLineWaitsForThePresentersReport() {
        let presenter = DeferredPresenter()
        var lines: [String] = []
        let f = MediaFileOperationsWindowForwarder(presenter: presenter, log: { lines.append($0) })
        f.jobStarted(id: UUID(), title: "Promote tape", origin: .user)
        #expect(lines.isEmpty, "the old bug: logging success before anything moved")
        presenter.pending.first?(CountingPresenter.canned)
        #expect(lines == ["[mfo] brought Media File Operations forward for Promote tape" + cannedTail])
    }

    @Test func legacyOpenBehindChecksTheForwardAtEntryAndOnEveryRetry() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/MediaFileOperationsWindow.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        #expect(s.components(separatedBy: "defersToForward(forwardedAt: forwardedAt, now: Date())").count - 1 == 2)
    }

    @Test func productionPresenterIsTheDeferredOne() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/MediaFileOperationsWindowForwarder.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        #expect(s.contains("presenter: AppKitMediaFileOperationsWindowPresenter()"))
        // The honest line is composed only from a report, never logged inline.
        #expect(s.components(separatedBy: "log(\"[mfo] brought").count - 1 == 0)
    }
}
