import SwiftUI
import AppKit
import os

// MARK: - Dossier ("Analyze") window open path
//
// Punch-list #4: the Analyze dashboard window sometimes does NOT appear
// when opened (⌘⇧O or the catalog toolbar chip). Both call sites used a
// bare `openWindow(id: "dossier")`. That has three known failure modes on
// a single-instance SwiftUI `Window` scene:
//
//   A. OFF-SCREEN restore. `.defaultPosition(.topTrailing)` only applies
//      on first-ever open; thereafter SwiftUI restores the *persisted*
//      frame. If that frame was saved on an external display that is no
//      longer attached (or got dragged off the visible area), the window
//      "opens" entirely off the visible frame and Rick never sees it. It
//      WOULD show in the Window menu.
//   B. Body crash (Release-mostly). Ruled-out-ish for Debug repro; the
//      body renders unconditionally and has no force-unwraps.
//   C. Reopen no-op / behind. `openWindow(id:)` can leave the window
//      behind other apps (or appear not to fire) when VideoScan isn't
//      frontmost, or when the single-instance window already exists hidden
//      behind the main window.
//
// `DossierWindowOpener` is the one funnel both call sites now use. It:
//   1. logs the request (source: menu|chip),
//   2. asks SwiftUI to create-or-surface the window,
//   3. activates the app (fixes "behind another app"),
//   4. one runloop later, finds the backing NSWindow, logs its frame +
//      whether it intersects a screen's visibleFrame (proves/refutes A),
//      clamps it back on-screen if it isn't, and makeKeyAndOrderFront's it.
//
// The geometry decision is factored into `WindowFrameClamp` (pure, no
// AppKit) so it is unit-tested. The AppKit raise itself isn't unit-
// testable; it is covered by the os.Logger trail instead.

let dossierWindowLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "windows")

@MainActor
enum DossierWindowOpener {

    /// Scene id from the `Window(id:)` declaration in VideoScanApp.swift.
    static let sceneID = "dossier"
    /// Scene title — SwiftUI sets the NSWindow.title to this, so it is a
    /// reliable way to find the backing window (more so than the
    /// identifier, whose raw value format varies across SwiftUI versions).
    static let windowTitle = "Analyze Dashboard"

    /// The single entry point both call sites use.
    /// - source: "menu" (⌘⇧O) or "chip" (toolbar) — for the log trail.
    static func open(using openWindow: OpenWindowAction, source: String) {
        dossierWindowLog.info("dossier dashboard open requested (source: \(source, privacy: .public))")

        // Create-or-surface the single-instance window.
        openWindow(id: sceneID)

        // Bring VideoScan to the front. A bare openWindow can leave the new
        // window behind other apps when we aren't frontmost (failure C).
        NSApp.activate(ignoringOtherApps: true)

        // The NSWindow backing a freshly-created Window scene is not in
        // NSApp.windows synchronously — defer so we can find / log / clamp /
        // raise it. Bounded retry (NOT an unbounded loop) for the
        // first-ever-create case where one tick isn't enough.
        surface(source: source, attemptsLeft: 3)
    }

    private static func surface(source: String, attemptsLeft: Int) {
        DispatchQueue.main.async {
            guard let w = findWindow() else {
                if attemptsLeft > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        surface(source: source, attemptsLeft: attemptsLeft - 1)
                    }
                } else {
                    dossierWindowLog.error(
                        "dossier window NOT found in NSApp.windows after openWindow(id: \(sceneID, privacy: .public)) — source: \(source, privacy: .public). Scene may have failed to instantiate (failure B) or the id/title drifted.")
                }
                return
            }

            let frame = w.frame
            let screens = NSScreen.screens.map(\.visibleFrame)
            let onScreen = WindowFrameClamp.maxVisibleFraction(of: frame, over: screens)
                >= WindowFrameClamp.minVisibleFraction
            dossierWindowLog.info(
                "dossier window found id=\(w.identifier?.rawValue ?? "nil", privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public) onScreen=\(onScreen)")

            if let corrected = WindowFrameClamp.correctedFrame(for: frame, screens: screens) {
                w.setFrame(corrected, display: true)
                dossierWindowLog.notice(
                    "dossier window was OFF-SCREEN/degenerate — clamped \(NSStringFromRect(frame), privacy: .public) -> \(NSStringFromRect(corrected), privacy: .public)")
            }

            w.makeKeyAndOrderFront(nil)

            let finalFrame = w.frame
            let finalOnScreen = WindowFrameClamp.maxVisibleFraction(of: finalFrame, over: screens)
                >= WindowFrameClamp.minVisibleFraction
            dossierWindowLog.info(
                "dossier window raised, frame=\(NSStringFromRect(finalFrame), privacy: .public) onScreen=\(finalOnScreen)")
        }
    }

    /// Find the backing NSWindow for the dossier scene. Title is the
    /// primary key (we set it in the scene); identifier substring is a
    /// belt-and-suspenders fallback.
    private static func findWindow() -> NSWindow? {
        NSApp.windows.first { w in
            w.title == windowTitle
            || (w.identifier?.rawValue.contains(sceneID) ?? false)
        }
    }
}

// MARK: - Pure on-screen geometry (unit-tested)

/// Decides whether a window frame needs to be moved back onto a visible
/// screen, and where to. Pure: takes Cocoa-space rects (bottom-left
/// origin) and returns a rect — no AppKit, no singletons — so it is
/// covered by `DossierWindowClampTests`.
enum WindowFrameClamp {

    /// A window counts as "on screen" when at least this fraction of its
    /// area falls within some screen's visibleFrame. Below this we re-home
    /// it. 0.5 = at least half visible (in particular guarantees the title
    /// bar / traffic lights are reachable).
    static let minVisibleFraction: CGFloat = 0.5

    /// Sane re-home size when the existing frame is degenerate (zero/tiny
    /// content size — failure A's "opens at zero size" variant). Mirrors
    /// DossierDashboardView's `.frame(minWidth: 700, minHeight: 760)`.
    static let fallbackSize = CGSize(width: 700, height: 760)

    /// Largest fraction of `frame` that any single screen makes visible.
    static func maxVisibleFraction(of frame: CGRect, over screens: [CGRect]) -> CGFloat {
        let area = frame.width * frame.height
        guard area > 0 else { return 0 }
        var best: CGFloat = 0
        for s in screens {
            let inter = s.intersection(frame)
            guard !inter.isNull else { continue }
            best = max(best, (inter.width * inter.height) / area)
        }
        return best
    }

    /// Returns a corrected, on-screen frame, or nil when `frame` is already
    /// adequately visible (or there are no screens to clamp onto).
    static func correctedFrame(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard let primary = screens.first else { return nil }

        let validSize = frame.width >= 100 && frame.height >= 100
        if validSize && maxVisibleFraction(of: frame, over: screens) >= minVisibleFraction {
            return nil  // already fine — leave the working case untouched
        }

        let target = bestOverlappingScreen(for: frame, screens: screens) ?? primary
        let size: CGSize = validSize
            ? CGSize(width: min(frame.width, target.width),
                     height: min(frame.height, target.height))
            : CGSize(width: min(fallbackSize.width, target.width),
                     height: min(fallbackSize.height, target.height))

        // Center the (possibly clamped) size on the target's visibleFrame.
        return CGRect(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The screen with the most overlap with `frame`, or nil if none
    /// overlap at all (fully off-screen).
    private static func bestOverlappingScreen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for s in screens {
            let inter = s.intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = s
            }
        }
        return best
    }
}
