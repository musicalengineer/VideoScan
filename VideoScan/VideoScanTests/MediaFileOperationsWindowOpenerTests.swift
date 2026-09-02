// MediaFileOperationsWindowOpenerTests.swift
// The job window must be found by scene identity first, title second —
// and nothing else may be mistaken for it (2026-09-02 window-ordering fix).
import XCTest
@testable import VideoScan

final class MediaFileOperationsWindowOpenerTests: XCTestCase {
    func testIdentifierPrefixWins() {
        XCTAssertTrue(MediaFileOperationsWindowOpener.isJobWindow(identifier: "combine-AppWindow-1", title: "Anything"))
        XCTAssertTrue(MediaFileOperationsWindowOpener.isJobWindow(identifier: "combine", title: ""))
    }

    func testTitleIsTheFallback() {
        XCTAssertTrue(MediaFileOperationsWindowOpener.isJobWindow(identifier: nil, title: "Media File Operations"))
        XCTAssertTrue(MediaFileOperationsWindowOpener.isJobWindow(identifier: "main-AppWindow-1", title: "Media File Operations"))
    }

    func testOtherWindowsAreNotTheJobWindow() {
        XCTAssertFalse(MediaFileOperationsWindowOpener.isJobWindow(identifier: "main-AppWindow-1", title: "VideoScan"))
        XCTAssertFalse(MediaFileOperationsWindowOpener.isJobWindow(identifier: nil, title: "Family Archivist"))
        XCTAssertFalse(MediaFileOperationsWindowOpener.isJobWindow(identifier: nil, title: "Media File Operations — Console"))
        XCTAssertFalse(MediaFileOperationsWindowOpener.isJobWindow(identifier: "compare-AppWindow-1", title: "Compare Volumes"))
    }

    // MARK: - Retry step (codex #964)

    func testModalAlertFreezesEverything() {
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: true, modalRunning: true, anchorVisible: true), .skip)
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: false, modalRunning: true, anchorVisible: true), .skip)
    }

    func testNoVisibleAnchorMeansNoAction() {
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: true, modalRunning: false, anchorVisible: false), .skip)
    }

    func testKeyIsRestoredWhenTheJobWindowIsKeyAtTheFirstActingRetry() {
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: true, modalRunning: false, anchorVisible: true), .reorderAndRestoreKey)
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: false, modalRunning: false, anchorVisible: true), .reorder)
    }

    // MARK: - Retry ledger (codex #969)

    func testFirstActingRetryRetiresTheRest() {
        var ledger = MediaFileOperationsWindowOpener.RetryLedger()
        XCTAssertEqual(ledger.apply(.skip), .skip, "window not created yet: nothing settles")
        XCTAssertFalse(ledger.settled)
        XCTAssertEqual(ledger.apply(.reorderAndRestoreKey), .reorderAndRestoreKey)
        XCTAssertTrue(ledger.settled)
        XCTAssertEqual(ledger.apply(.reorderAndRestoreKey), .skip,
                       "the user clicked the job window on purpose after the 0.15 s retry; the 0.5 s retry must not steal focus back")
        XCTAssertEqual(ledger.apply(.reorder), .skip)
    }

    func testAModalOnEveryRetryNeverSettles() {
        var ledger = MediaFileOperationsWindowOpener.RetryLedger()
        for _ in 0..<3 { XCTAssertEqual(ledger.apply(.skip), .skip) }
        XCTAssertFalse(ledger.settled, "the caller must schedule a post-modal open instead")
    }
}
