// DossierWindowClampTests.swift
// Pins the pure on-screen geometry used by the Analyze ("dossier") window
// open path (punch-list #4: the window sometimes opens off the visible
// frame and is never seen). `WindowFrameClamp` decides whether a restored
// window frame needs re-homing and where to. Cocoa rects: bottom-left
// origin, +y up.

import XCTest
import CoreGraphics
@testable import VideoScan

final class DossierWindowClampTests: XCTestCase {

    // A single 1920x1080 laptop screen with a 25pt menu bar reserved.
    private let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080 - 25)

    // MARK: maxVisibleFraction

    func testFullyVisibleFractionIsOne() {
        let f = CGRect(x: 100, y: 100, width: 700, height: 760)
        XCTAssertEqual(WindowFrameClamp.maxVisibleFraction(of: f, over: [mainScreen]), 1.0, accuracy: 0.001)
    }

    func testFullyOffScreenFractionIsZero() {
        let f = CGRect(x: 5000, y: 100, width: 700, height: 760)
        XCTAssertEqual(WindowFrameClamp.maxVisibleFraction(of: f, over: [mainScreen]), 0.0, accuracy: 0.001)
    }

    func testHalfOffRightEdge() {
        // Window straddles the right edge: half its width is off-screen.
        let f = CGRect(x: mainScreen.maxX - 350, y: 100, width: 700, height: 100)
        XCTAssertEqual(WindowFrameClamp.maxVisibleFraction(of: f, over: [mainScreen]), 0.5, accuracy: 0.01)
    }

    func testZeroSizeFractionIsZeroNotNaN() {
        let f = CGRect(x: 100, y: 100, width: 0, height: 0)
        XCTAssertEqual(WindowFrameClamp.maxVisibleFraction(of: f, over: [mainScreen]), 0.0)
    }

    // MARK: correctedFrame — the working case must be left alone

    func testOnScreenWindowIsNotCorrected() {
        let f = CGRect(x: 200, y: 80, width: 700, height: 760)
        XCTAssertNil(WindowFrameClamp.correctedFrame(for: f, screens: [mainScreen]))
    }

    func testMostlyVisibleWindowIsNotCorrected() {
        // ~75% visible (a quarter hangs off the right) — above the 0.5 bar.
        let f = CGRect(x: mainScreen.maxX - 525, y: 80, width: 700, height: 200)
        XCTAssertNil(WindowFrameClamp.correctedFrame(for: f, screens: [mainScreen]))
    }

    // MARK: correctedFrame — the broken cases get re-homed on-screen

    func testFullyOffScreenIsRecentered() throws {
        // Frame stranded on a disconnected external display (huge +x).
        let f = CGRect(x: 6000, y: 4000, width: 700, height: 760)
        let corrected = try XCTUnwrap(WindowFrameClamp.correctedFrame(for: f, screens: [mainScreen]))

        // Size preserved, and now substantially visible on the main screen.
        XCTAssertEqual(corrected.width, 700, accuracy: 0.001)
        XCTAssertEqual(corrected.height, 760, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            WindowFrameClamp.maxVisibleFraction(of: corrected, over: [mainScreen]),
            WindowFrameClamp.minVisibleFraction)
        // Centered on the visibleFrame.
        XCTAssertEqual(corrected.midX, mainScreen.midX, accuracy: 0.5)
        XCTAssertEqual(corrected.midY, mainScreen.midY, accuracy: 0.5)
    }

    func testBarelyVisibleWindowIsRecentered() throws {
        // Only a sliver on-screen (well under half) → re-home.
        let f = CGRect(x: mainScreen.maxX - 60, y: 80, width: 700, height: 200)
        let corrected = try XCTUnwrap(WindowFrameClamp.correctedFrame(for: f, screens: [mainScreen]))
        XCTAssertGreaterThanOrEqual(
            WindowFrameClamp.maxVisibleFraction(of: corrected, over: [mainScreen]),
            WindowFrameClamp.minVisibleFraction)
    }

    func testDegenerateZeroSizeGetsFallbackSize() throws {
        // "Opens at zero/tiny content size" variant of failure A.
        let f = CGRect(x: 0, y: 0, width: 0, height: 0)
        let corrected = try XCTUnwrap(WindowFrameClamp.correctedFrame(for: f, screens: [mainScreen]))
        XCTAssertEqual(corrected.width, WindowFrameClamp.fallbackSize.width, accuracy: 0.001)
        XCTAssertEqual(corrected.height, WindowFrameClamp.fallbackSize.height, accuracy: 0.001)
        XCTAssertEqual(corrected.midX, mainScreen.midX, accuracy: 0.5)
    }

    func testOversizeFrameIsClampedToScreen() throws {
        // Frame taller than the screen → height clamped so it fits.
        let f = CGRect(x: -100, y: -100, width: 3000, height: 3000)
        let corrected = try XCTUnwrap(WindowFrameClamp.correctedFrame(for: f, screens: [mainScreen]))
        XCTAssertLessThanOrEqual(corrected.width, mainScreen.width + 0.001)
        XCTAssertLessThanOrEqual(corrected.height, mainScreen.height + 0.001)
    }

    // MARK: multi-display

    func testPicksScreenWithMostOverlap() throws {
        // Two screens side by side; window sits mostly on the right one but
        // a sliver on the left. It is >50% visible overall on the right, so
        // it should be left alone.
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let f = CGRect(x: 1400, y: 100, width: 700, height: 400) // 40 on left, 660 on right
        XCTAssertNil(WindowFrameClamp.correctedFrame(for: f, screens: [left, right]))
    }

    func testNoScreensReturnsNil() {
        let f = CGRect(x: 5000, y: 5000, width: 700, height: 760)
        XCTAssertNil(WindowFrameClamp.correctedFrame(for: f, screens: []))
    }
}
