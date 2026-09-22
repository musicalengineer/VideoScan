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

@MainActor
private final class CountingPresenter: MediaFileOperationsWindowPresenting {
    var raises = 0
    func bringForwardWithoutFocus() { raises += 1 }
}

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
        #expect(rig.logBox.lines == ["[mfo] brought Media File Operations forward for Trim tape 3"])
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
        #expect(rig.logBox.lines == ["[mfo] brought Media File Operations forward for Combine 3 pairs"])
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

    @Test func poisonedRealPrefsDoNotLeakIntoTheTestHost() {
        // Even if the developer's real prefs say OFF, a test-host Center
        // sees the default — no global state crosses into tests.
        let key = MediaFileOperationsForwardSetting.key
        let scratch = UserDefaults(suiteName: "vs.test.mfo-forward.\(UUID().uuidString)")!
        scratch.set(false, forKey: key)
        #expect(MediaFileOperationsForwardSetting.restored(from: scratch).showOnJobStart == false)
        #expect(MediaFileOperationsWindowForwarder.makeDefault().setting.showOnJobStart == true)
    }

    @Test func settingRoundTripsThroughScratchDefaults() {
        let suite = "vs.test.mfo-forward.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suite)!
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
