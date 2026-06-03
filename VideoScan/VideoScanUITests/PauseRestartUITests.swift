//
//  PauseRestartUITests.swift
//  VideoScanUITests
//
//  End-to-end canary for the user-reported pause-survives-restart contract
//  (fixed in 59c71f9 + 78939ac on main 2026-06-03).
//
//  Storyline:
//    1. App launches with --ui-test-fresh-storage. The override (see
//       UITestStorageOverride.swift) redirects POI/scan_jobs/catalog reads
//       to a per-process tmp dir keyed off VS_UITEST_STORAGE_ROOT so the
//       relaunch in step 4 lands on the SAME directory.
//    2. The override seeds a synthetic POI ("TestPerson") and the
//       PersonFinderModel seeds a single ScanJob into .scanning state so
//       the user-driven Pause button has a job to act on.
//    3. The test clicks Pause. pauseJob() transitions status to .paused
//       and persists the descriptor via Task.detached. We wait for the
//       descriptor to settle on disk by polling the override's scan_jobs
//       directory.
//    4. Terminate the app. Relaunch with the same env var.
//    5. PersonFinderModel.restoreSessionFromDisk() reads the persisted
//       descriptor. Pre-fix it would land as .done. Post-fix
//       (PersonFinderModel+JobLifecycle.makeJob) it lands as .paused.
//    6. Assertions:
//         - scanJob.status.<jobID> reads "Paused" (not "Done")
//         - scanJob.pauseResume.<jobID> button exists and is hittable
//    7. Click Resume. wasRestoredFromDisk → startJob → reachability guard
//       fires (we delete the synthetic search path before relaunch) →
//       status flips to .failed. The TEST contract isn't "did it succeed";
//       it's "did the Resume click do something" — which proves the post-
//       fix `job.status = .idle` workaround for startJob's `isActive`
//       guard is in place.
//
//  Why these assertions are coupled to the bug shape:
//    - Pre-fix makeJob hard-codes status = .done. Asserting "Paused" fails.
//    - Pre-fix resumeJob's restored-from-disk path falls into startJob,
//      whose first guard `!job.status.isActive` was true (.paused IS
//      active) and the function early-returned without doing anything.
//      The status stayed at .paused after click — failing the "moved
//      away from Paused" assertion.
//
//  The red→green→red→green cycle (per feedback_tdd_verification) is run
//  by-hand on M1 — temporarily revert the two fix lines, observe both
//  assertions fail, restore them, observe both pass. SHAs of each cycle
//  are captured in the PR description.

import XCTest

final class PauseRestartUITests: XCTestCase {

    /// Per-test sandbox root. Set in setUp, passed into the app's launch
    /// env so both the first launch AND the relaunch use the same dir
    /// for POI / scan_jobs / catalog. Cleared in tearDown.
    private var sandboxRoot: URL!

    /// XCUITest hook expected in the app binary. Mirrors
    /// UITestStorageOverride.launchFlag — duplicated here as a constant
    /// so the test fails with a clear name if Rick renames it.
    private let launchFlag = "--ui-test-fresh-storage"
    private let envOverrideKey = "VS_UITEST_STORAGE_ROOT"

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Per-test sandbox. Created fresh; both app launches point here.
        let shortID = UUID().uuidString.prefix(8)
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VideoScan-UITest-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        print("[UI-TEST] Sandbox root: \(sandboxRoot.path)")
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup; tmp will be purged at reboot regardless.
        if let root = sandboxRoot {
            try? FileManager.default.removeItem(at: root)
        }
        sandboxRoot = nil
    }

    // MARK: - The canary

    @MainActor
    func testPauseSurvivesAppRestart() throws {
        // ----- LAUNCH #1: clean state -----
        let app1 = launchApp(sandboxRoot: sandboxRoot)

        // People tab is the default (selectedTab=0); make sure the
        // UI is up by waiting on the People tab control.
        let peopleTab = app1.buttons["tab.People"]
        XCTAssertTrue(
            peopleTab.waitForExistence(timeout: 60),
            "People tab never appeared — main window failed to render."
        )
        if peopleTab.isHittable {
            peopleTab.click()
        }

        // The seeded ScanJob's UUID isn't predictable from the test side
        // — we just need to find the ONE pause button that's visible.
        // Match by ID-prefix predicate so we don't have to compute the
        // UUID in advance.
        let pausePredicate = NSPredicate(format: "identifier BEGINSWITH 'scanJob.pauseResume.'")
        let pauseButton = app1.buttons.matching(pausePredicate).firstMatch
        XCTAssertTrue(
            pauseButton.waitForExistence(timeout: 30),
            "Seeded scanning job's pause button never appeared. Check that --ui-test-fresh-storage seeded a ScanJob with status=.scanning."
        )

        // Capture the job's full accessibility ID so we can re-find it
        // by exact ID on the relaunched app (UUID must match across launches).
        let pauseID = pauseButton.identifier
        let jobIDSuffix = pauseID.replacingOccurrences(of: "scanJob.pauseResume.", with: "")
        print("[UI-TEST] Seeded job axID suffix: \(jobIDSuffix)")
        XCTAssertFalse(jobIDSuffix.isEmpty, "Could not extract job suffix from \(pauseID)")

        // Click Pause. pauseJob() transitions .scanning → .paused.
        pauseButton.click()

        // Wait for status to flip to Paused. The badge label reflects the
        // current status text — see ScanJobRow.statusBadge.
        let statusBadge = app1.descendants(matching: .any)
            .matching(identifier: "scanJob.status.\(jobIDSuffix)").firstMatch
        XCTAssertTrue(
            waitForLabel(element: statusBadge, equals: "Paused", timeout: 5),
            "Status badge never read 'Paused' after clicking Pause — got '\(statusBadge.label)'."
        )

        // Wait for the descriptor to land on disk. persistDescriptor is
        // Task.detached so it's not synchronous with the button click.
        let descriptorDir = sandboxRoot
            .appendingPathComponent("Application Support/VideoScan/scan_jobs", isDirectory: true)
        XCTAssertTrue(
            waitForDescriptorFile(in: descriptorDir, containing: jobIDSuffix, timeout: 10),
            "No persisted descriptor JSON containing '\(jobIDSuffix)' appeared in \(descriptorDir.path) within 10s."
        )

        // ----- TERMINATE -----
        app1.terminate()
        // Give the OS a beat to fully reap the process so the relaunch
        // creates a fresh one instead of attaching to the dying instance.
        Thread.sleep(forTimeInterval: 1.5)

        // ----- DELETE the fake search-path so resume's reachability
        // guard deterministically fires on click. -----
        let fakeVolume = sandboxRoot.appendingPathComponent("fake-test-volume", isDirectory: true)
        try? FileManager.default.removeItem(at: fakeVolume)

        // ----- LAUNCH #2: same sandbox; descriptor on disk should restore -----
        let app2 = launchApp(sandboxRoot: sandboxRoot)

        let peopleTab2 = app2.buttons["tab.People"]
        XCTAssertTrue(
            peopleTab2.waitForExistence(timeout: 60),
            "People tab never appeared on relaunch."
        )
        if peopleTab2.isHittable {
            peopleTab2.click()
        }

        // THE BUG SHAPE: pre-fix, the restored row showed status "Done"
        // and the row had no Pause button at all (only the Start button
        // for an idle job). Post-fix, status reads "Paused" and the
        // pauseResume button is present.
        let restoredStatusID = "scanJob.status.\(jobIDSuffix)"
        let restoredStatus = app2.descendants(matching: .any)
            .matching(identifier: restoredStatusID).firstMatch
        XCTAssertTrue(
            restoredStatus.waitForExistence(timeout: 30),
            "Restored job's status badge (id=\(restoredStatusID)) never appeared."
        )
        XCTAssertEqual(
            restoredStatus.label, "Paused",
            "PAUSE-SURVIVES-RESTART CONTRACT VIOLATED: restored job shows '\(restoredStatus.label)' instead of 'Paused'. Pre-fix bug: PersonFinderModel+JobLifecycle.makeJob hard-coded .done."
        )

        let restoredPauseID = "scanJob.pauseResume.\(jobIDSuffix)"
        let restoredResumeButton = app2.buttons[restoredPauseID]
        XCTAssertTrue(
            restoredResumeButton.waitForExistence(timeout: 5),
            "Restored job's pauseResume button (id=\(restoredPauseID)) is missing. Pre-fix bug: row rendered as .done with no pause/resume action."
        )
        XCTAssertTrue(
            restoredResumeButton.isHittable,
            "Restored pauseResume button exists but is not hittable."
        )

        // Click Resume. wasRestoredFromDisk routes to startJob → reachability
        // guard fires (volume deleted above) → status flips to .failed.
        // Pre-fix this click would have been a no-op because startJob's
        // `!job.status.isActive` guard treated .paused as active and bailed.
        restoredResumeButton.click()

        // Status must transition AWAY from Paused. .failed renders as
        // "Failed" by ScanJobRow.statusBadge.
        XCTAssertTrue(
            waitForLabelChange(element: restoredStatus, awayFrom: "Paused", timeout: 10),
            "RESUME-AFTER-RESTART CONTRACT VIOLATED: status stayed at 'Paused' \(restoredStatus.label) after clicking Resume. Pre-fix bug: startJob's isActive guard treated .paused as active and early-returned."
        )

        app2.terminate()
    }

    // MARK: - Helpers

    private func launchApp(sandboxRoot: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            launchFlag,
            // Force People tab on first launch — overrides any stale
            // selectedTab from a previous test. SwiftUI @AppStorage reads
            // -<key> <value> argv pairs as transient defaults.
            "-selectedTab", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment = [
            envOverrideKey: sandboxRoot.path,
            // Keep the app's appLog quiet during tests — the UITest
            // override doesn't redirect ~/Library/Logs/VideoScan/, so
            // we don't want noise from a UI test in Rick's real logs.
            // Setting it to a non-empty value in case future code reads
            // it to choose a log path. Not currently consumed but
            // documents intent.
            "VS_UI_TEST": "1"
        ]
        app.launch()
        return app
    }

    /// Poll an XCUIElement's `label` until it equals `target` or timeout.
    /// XCUIElement.label updates as the underlying SwiftUI Text changes,
    /// so this is a viable proxy for status-transition observability.
    private func waitForLabel(
        element: XCUIElement,
        equals target: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.label == target { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Inverse — poll until the label is something OTHER than `original`.
    /// Used to confirm a state transition without needing to predict the
    /// exact destination state.
    private func waitForLabelChange(
        element: XCUIElement,
        awayFrom original: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.label != original && !element.label.isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// True once a descriptor JSON whose filename contains the job's UUID
    /// suffix appears in the descriptor directory. Catches both the timestamp
    /// + UUID filename ScanJobsStorage uses.
    private func waitForDescriptorFile(
        in dir: URL,
        containing fragment: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let fm = FileManager.default
        while Date() < deadline {
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.lastPathComponent.lowercased().contains(fragment.lowercased()) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
