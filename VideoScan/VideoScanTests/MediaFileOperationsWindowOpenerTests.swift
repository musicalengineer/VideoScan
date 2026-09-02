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

    func testKeyIsRestoredOnlyWhenTheOpenStoleIt() {
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: true, modalRunning: false, anchorVisible: true), .reorderAndRestoreKey)
        XCTAssertEqual(MediaFileOperationsWindowOpener.step(jobIsKey: false, modalRunning: false, anchorVisible: true), .reorder,
                       "a stale retry with the user already back in the main window must not re-key it")
    }
}
