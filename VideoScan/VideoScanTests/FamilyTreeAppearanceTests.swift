import Testing
import Foundation
import SwiftUI
@testable import VideoScan

// MARK: - FamilyTreeAppearanceTests
//
// The Family Tree canvas was pinned `.preferredColorScheme(.dark)` with
// nine hard-coded near-black surfaces. Donna asked for a light option
// (2026-08-30) so a line can be read under a lamp. These pin the parts
// that are pure logic: what gets persisted, what a fresh install sees, and
// how "Match System" resolves.
//
// Isolation: every case builds its own UserDefaults suite, per the
// settings-persistence rule — nothing here can see or write real prefs.

struct FamilyTreeAppearanceTests {

    private func suite(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    /// A fresh install must look exactly as it did before this feature.
    /// A preference that silently changes an existing user's view on
    /// upgrade is a bug.
    @Test func defaultIsDarkOnAFreshInstall() {
        #expect(FamilyTreeAppearancePreference.load(from: suite()) == .dark)
    }

    @Test func everyChoiceRoundTrips() {
        for choice in FamilyTreeAppearance.allCases {
            let defaults = suite()
            FamilyTreeAppearancePreference.save(choice, to: defaults)
            #expect(FamilyTreeAppearancePreference.load(from: defaults) == choice,
                    "\(choice.rawValue) did not survive a save/load")
        }
    }

    /// Garbage in the key — a hand-edited plist, or a value written by a
    /// newer build — must fall back rather than crash or blank the canvas.
    @Test func anUnknownStoredValueFallsBackToDark() {
        let defaults = suite()
        defaults.set("chartreuse", forKey: FamilyTreeAppearancePreference.key)
        #expect(FamilyTreeAppearancePreference.load(from: defaults) == .dark)
    }

    /// Only `.system` may consult the system appearance. If `.dark` or
    /// `.light` ever started following the system, the setting would look
    /// like it was being ignored.
    @Test func explicitChoicesIgnoreTheSystemAndSystemFollowsIt() {
        for systemIsDark in [true, false] {
            #expect(FamilyTreeAppearancePreference.resolve(.dark, systemIsDark: systemIsDark) == .dark)
            #expect(FamilyTreeAppearancePreference.resolve(.light, systemIsDark: systemIsDark) == .light)
            #expect(FamilyTreeAppearancePreference.resolve(.system, systemIsDark: systemIsDark)
                    == (systemIsDark ? .dark : .light))
        }
    }

    /// The dark palette must be byte-for-byte what the view drew before, so
    /// "Dark" is not a slightly-different dark.
    @Test func darkPaletteMatchesTheColoursTheViewUsedBefore() {
        let dark = FamilyTreePalette.dark
        #expect(dark.window == Color(red: 0.06, green: 0.07, blue: 0.08))
        #expect(dark.canvasTop == Color(red: 0.055, green: 0.065, blue: 0.075))
        #expect(dark.canvasBottom == Color(red: 0.075, green: 0.08, blue: 0.095))
        #expect(dark.controlBar == Color(red: 0.075, green: 0.08, blue: 0.09))
        #expect(dark.sidebar == Color(red: 0.085, green: 0.09, blue: 0.10))
        #expect(dark.panel == Color(red: 0.09, green: 0.10, blue: 0.11))
        #expect(dark.card == Color(red: 0.12, green: 0.13, blue: 0.145))
        #expect(dark.panelOverlay == Color.white.opacity(0.065))
        #expect(dark.overlayInk == Color.white)
    }

    /// The failure this guards against is a light mode whose overlays and
    /// connectors are still white — invisible panels and vanished lines.
    @Test func lightPaletteInvertsTheInkSoOverlaysAndConnectorsStayVisible() {
        #expect(FamilyTreePalette.light.overlayInk == Color.black)
        #expect(FamilyTreePalette.dark.overlayInk == Color.white)
        #expect(FamilyTreePalette.light.connector != FamilyTreePalette.dark.connector)
        #expect(FamilyTreePalette.light.card != FamilyTreePalette.dark.card)
    }

    @Test func paletteFollowsTheResolvedScheme() {
        #expect(FamilyTreePalette.palette(for: .dark).window == FamilyTreePalette.dark.window)
        #expect(FamilyTreePalette.palette(for: .light).window == FamilyTreePalette.light.window)
    }
}
