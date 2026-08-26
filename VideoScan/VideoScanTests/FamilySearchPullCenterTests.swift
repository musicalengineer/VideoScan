// FamilySearchPullCenterTests.swift
// LOGIC + SENSOR for the app-wide owner of an in-flight "Get Family Tree"
// download (2026-08-25).
//
// The escaped bug: the coordinator lived in the sheet's @State, so closing
// the sheet cancelled the file watcher and a two-hour Terminal pull finished
// unobserved. `centerKeepsTheCoordinatorAliveWhenTheSheetIsDismissed` is
// the regression sensor for exactly that path.
//
// Every test injects a silent launcher and a planted "tool" so nothing
// opens Terminal or goes anywhere near a real archive.

import XCTest
@testable import VideoScan

@MainActor
final class FamilySearchPullCenterTests: XCTestCase {

    private struct SilentLauncher: FamilySearchPullLauncher {
        func open(_ url: URL) {}
    }

    /// Temp sandbox: planted executable tool, GEDCOM install dir, and a
    /// staging dir the coordinator writes its script/output into.
    private struct Sandbox {
        let root: URL
        let toolURL: URL
        let gedcomDirectory: URL
        let outputURL: URL
        let scriptURL: URL
    }

    private var sandbox: Sandbox!
    private var notifications: [(title: String, body: String)] = []

    override func setUpWithError() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("fs-center-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let gedcom = root.appendingPathComponent("GEDCOM", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for dir in [bin, gedcom, staging] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tool = bin.appendingPathComponent("getmyancestors")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        sandbox = Sandbox(
            root: root, toolURL: tool, gedcomDirectory: gedcom,
            outputURL: staging.appendingPathComponent("familysearch-tree.ged"),
            scriptURL: staging.appendingPathComponent("get-family-tree.command"))
        notifications = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox.root)
    }

    // MARK: Helpers

    private func makeCenter() -> FamilySearchPullCenter {
        let sandbox = sandbox!
        return FamilySearchPullCenter(
            makeCoordinator: { directory in
                let coordinator = FamilySearchPullCoordinator(
                    gedcomDirectory: directory,
                    defaultUsername: "rick@example.com",
                    scriptURL: sandbox.scriptURL,
                    locator: FamilySearchToolLocator(overridePath: sandbox.toolURL.path),
                    launcher: SilentLauncher(),
                    pollInterval: .milliseconds(30))
                coordinator.request.outputURL = sandbox.outputURL
                return coordinator
            },
            notify: { [weak self] title, body in
                self?.notifications.append((title, body))
            })
    }

    /// begin() + launch(): the state the user is in after "Open in Terminal…".
    private func beginWaiting(_ center: FamilySearchPullCenter) -> FamilySearchPullCoordinator {
        let coordinator = center.begin(gedcomDirectory: sandbox.gedcomDirectory)
        coordinator.launch()
        guard case .waiting = coordinator.phase else {
            XCTFail("expected .waiting, got \(coordinator.phase)")
            return coordinator
        }
        return coordinator
    }

    private func waitForStatus(_ center: FamilySearchPullCenter,
                               _ predicate: (FamilySearchPullCenter.Status) -> Bool,
                               timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(center.status), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let completeGedcom = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Richard /Breen/
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 TRLR

    """

    // MARK: (a) SENSOR — the sheet-dismiss path must not kill the watcher

    func testCenterKeepsTheCoordinatorAliveWhenTheSheetIsDismissed() async throws {
        let center = makeCenter()
        let coordinator = beginWaiting(center)

        // What `.sheet(onDismiss:)` calls when the user closes the window.
        center.dismissIfSettled()

        XCTAssertTrue(center.coordinator === coordinator,
                      "dismissing the sheet while waiting must not drop the coordinator")
        if case .downloading = center.status {} else {
            XCTFail("expected .downloading after dismiss, got \(center.status)")
        }

        // And the watcher is genuinely still running: the file landing
        // after the dismiss is still noticed.
        try Self.completeGedcom.write(to: sandbox.outputURL, atomically: true, encoding: .utf8)
        await waitForStatus(center) { $0 == .readyToInstall }
        XCTAssertEqual(center.status, .readyToInstall)
    }

    func testDismissIfSettledDropsAnInstalledCoordinator() async throws {
        let center = makeCenter()
        let coordinator = beginWaiting(center)
        try Self.completeGedcom.write(to: sandbox.outputURL, atomically: true, encoding: .utf8)
        await waitForStatus(center) { $0 == .readyToInstall }
        coordinator.install()
        guard case .installed = coordinator.phase else {
            return XCTFail("expected .installed, got \(coordinator.phase)")
        }

        center.dismissIfSettled()
        XCTAssertNil(center.coordinator)
        XCTAssertEqual(center.status, .none)
    }

    // MARK: (b) status mirrors phase

    func testStatusMirrorsWaitingThenReadyThenInstalled() async throws {
        let center = makeCenter()
        XCTAssertEqual(center.status, .none)

        let coordinator = beginWaiting(center)
        guard case .downloading(let since) = center.status else {
            return XCTFail("expected .downloading, got \(center.status)")
        }
        XCTAssertEqual(since, coordinator.startedAt)
        XCTAssertLessThan(abs(since.timeIntervalSinceNow), 5)

        try Self.completeGedcom.write(to: sandbox.outputURL, atomically: true, encoding: .utf8)
        await waitForStatus(center) { $0 == .readyToInstall }
        XCTAssertEqual(center.status, .readyToInstall)

        coordinator.install()
        XCTAssertEqual(center.status, .none, "installed is a settled state")
    }

    func testStatusMirrorsFailure() {
        let center = makeCenter()
        let coordinator = center.begin(gedcomDirectory: sandbox.gedcomDirectory)
        coordinator.request.username = ""      // validation error on launch
        coordinator.launch()
        guard case .failed = coordinator.phase else {
            return XCTFail("expected .failed, got \(coordinator.phase)")
        }
        XCTAssertEqual(center.status, .failed)
        // A failure the user hasn't read yet survives a sheet dismiss too.
        center.dismissIfSettled()
        XCTAssertNotNil(center.coordinator)
    }

    // MARK: (c) forget() clears

    func testForgetCancelsAndClears() async throws {
        let center = makeCenter()
        let coordinator = beginWaiting(center)

        center.forget()

        XCTAssertNil(center.coordinator)
        XCTAssertEqual(center.status, .none)
        XCTAssertEqual(coordinator.phase, .idle, "forget cancels the watcher")

        // The dropped watcher must not resurrect the status when the file
        // shows up later.
        try Self.completeGedcom.write(to: sandbox.outputURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(center.status, .none)
    }

    // MARK: (d) begin() twice returns the in-flight coordinator

    func testBeginWhileWaitingReturnsTheSameCoordinator() {
        let center = makeCenter()
        let first = beginWaiting(center)
        let second = center.begin(gedcomDirectory: sandbox.gedcomDirectory)
        XCTAssertTrue(first === second)
        XCTAssertTrue(center.coordinator === first)
    }

    func testBeginAfterInstallStartsFresh() async throws {
        let center = makeCenter()
        let first = beginWaiting(center)
        try Self.completeGedcom.write(to: sandbox.outputURL, atomically: true, encoding: .utf8)
        await waitForStatus(center) { $0 == .readyToInstall }
        first.install()

        let second = center.begin(gedcomDirectory: sandbox.gedcomDirectory)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.phase, .idle)
    }

    // MARK: (e) timeout

    func testDefaultTimeoutCoversAnOvernightPull() {
        // A real 20-generation pull took 9.5 h (2026-08-25 → 26); the old
        // 90 min default gave up while Terminal was still working.
        XCTAssertGreaterThanOrEqual(FamilySearchPullCoordinator.defaultTimeout, .seconds(24 * 3600))
        let coordinator = FamilySearchPullCoordinator(
            gedcomDirectory: sandbox.gedcomDirectory, launcher: SilentLauncher())
        XCTAssertEqual(coordinator.timeout, FamilySearchPullCoordinator.defaultTimeout)
    }

    // MARK: (f) notification wording + one-shot delivery

    func testNotificationFormatterIsPure() {
        XCTAssertEqual(FamilySearchPullCenter.notificationTitle, "Family tree downloaded")
        XCTAssertEqual(
            FamilySearchPullCenter.notificationBody(people: 1234, generations: 20),
            "1234 people, 20 generations — open the Family Tree tab to install.")
    }

    func testNotificationIsPostedOnceWhenTheDownloadBecomesReady() async throws {
        let center = makeCenter()
        _ = beginWaiting(center)
        XCTAssertTrue(notifications.isEmpty)

        try Self.completeGedcom.write(to: sandbox.outputURL, atomically: true, encoding: .utf8)
        await waitForStatus(center) { $0 == .readyToInstall }

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.title, "Family tree downloaded")
        XCTAssertEqual(notifications.first?.body,
                       FamilySearchPullCenter.notificationBody(people: 2, generations: 2))
    }
}
