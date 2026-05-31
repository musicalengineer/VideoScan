import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateSheetBrowseTests
//
// Coverage for the source-volume Browse button added to RelocateSheet.
// The button itself is a SwiftUI surface (NSOpenPanel modal — runs only
// under an event loop), so this file tests the pure helper that the
// completion handler delegates to: `normalizeSourcePath`.
//
// The motivating UX is Rick's report that typing `/Volumes/Foo` by hand
// was error-prone and inconsistent with the rest of the app (which uses
// NSOpenPanel for folder selection). The Browse button feeds the picked
// URL.path through normalizeSourcePath before storing it, so the value
// persisted in UserDefaults matches the typed-input convention (no
// trailing slash) and the next time the sheet opens it presents
// cleanly.

@Suite struct RelocateSheetBrowseTests {

    // Bare-bones happy path: no trailing slash, returned untouched.
    @Test
    func normalizeSourcePath_passesThroughCleanPath() {
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/Mini2TB") == "/Volumes/Mini2TB")
    }

    // NSOpenPanel.url.path on a directory pick can return a trailing
    // slash on some macOS versions; strip it so the stored value
    // matches the typed-input convention.
    @Test
    func normalizeSourcePath_stripsTrailingSlash() {
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/Mini2TB/") == "/Volumes/Mini2TB")
    }

    // Defensive: only one trailing slash is stripped. A doubled trailing
    // slash (theoretical, but cheap to defend against) keeps the inner
    // slash. recordsScoped is tolerant of either form, so this is just
    // about not silently mangling unexpected input.
    @Test
    func normalizeSourcePath_stripsOnlyOneTrailingSlash() {
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/Mini2TB//") == "/Volumes/Mini2TB/")
    }

    // Root path must be preserved — never collapse "/" to "".
    @Test
    func normalizeSourcePath_preservesRoot() {
        #expect(RelocateSheet.normalizeSourcePath("/") == "/")
    }

    // Nested mount points (Rick's offsite NAS, e.g.
    // /Volumes/Backups/2026) come through unchanged.
    @Test
    func normalizeSourcePath_handlesNestedPath() {
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/Backups/2026")
                == "/Volumes/Backups/2026")
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/Backups/2026/")
                == "/Volumes/Backups/2026")
    }

    // Paths with spaces (Rick's "MyBook 3 Terabytes") are common on
    // consumer drives. URL.path returns them un-percent-encoded; we
    // shouldn't touch them.
    @Test
    func normalizeSourcePath_preservesSpaces() {
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/MyBook 3 Terabytes")
                == "/Volumes/MyBook 3 Terabytes")
        #expect(RelocateSheet.normalizeSourcePath("/Volumes/MyBook 3 Terabytes/")
                == "/Volumes/MyBook 3 Terabytes")
    }

    // RelocateSheet itself still constructs cleanly — guard against a
    // future refactor breaking the View at compile-time. Doesn't render,
    // doesn't talk to AppKit; just exercises the initializer.
    @Test @MainActor
    func relocateSheet_constructsWithoutError() {
        _ = RelocateSheet()
    }
}
