import Foundation
import Testing
@testable import VideoScan

// MARK: - Music-library scan-skip tests (GH #124 layer 3)
//
// Five-dimension coverage:
//   Logic     — skipDirs()/skipBundleExtensions() truth for the new
//               toggle, on and off, composed with the neighbors.
//   Isolation — persistence tests run against a throwaway
//               UserDefaults(suiteName:) via the injected-defaults
//               parameter added with this feature; the real plist is
//               never read or written.
//   Sensor    — (1) model-level snapshot parity pins the "delegate to
//               the pure ScanOptions builders" refactor (behavior of the
//               pre-existing categories unchanged); (2) the pro-video
//               carve-out can never unlock a music bundle; (3) walker
//               admission end-to-end: an "itunes" directory name is in
//               the default skip set the walker consults.
//   Scale     — N/A (set algebra over ~40 strings).
// Media matrix: N/A — no file I/O.

@Suite("Scan options — music-library skip (GH #124)")
struct ScanOptionsMusicSkipTests {

    // Default ON: music trees skip like system trees.
    @Test func defaultSkipsMusicLibraryDirs() {
        let opts = ScanOptions()
        #expect(opts.skipMusicLibraryTrees)
        let dirs = opts.skipDirs()
        #expect(dirs.contains("itunes"))
        #expect(dirs.contains("itunes media"))
        #expect(dirs.contains("itunes music"))
        #expect(dirs.contains("album artwork"))
        #expect(dirs.contains("ipod photo cache"))
        #expect(dirs.contains("automatically add to itunes.localized"))
        #expect(dirs.contains("automatically add to music.localized"))
        // Bare "music" must NOT be skipped — family folders like
        // Wedding/Music are legitimate scan territory.
        #expect(!dirs.contains("music"))
        // Bundles: the Music.app library, iTunes LP, iTunes Extras.
        let bundles = opts.skipBundleExtensions()
        #expect(bundles.contains("musiclibrary"))
        #expect(bundles.contains("itlp"))
        #expect(bundles.contains("ite"))
    }

    // Deliberate include: toggle OFF removes exactly the music sets.
    @Test func toggleOffScansMusicLibraries() {
        var opts = ScanOptions()
        opts.skipMusicLibraryTrees = false
        let dirs = opts.skipDirs()
        #expect(!dirs.contains("itunes"))
        #expect(!dirs.contains("itunes media"))
        // System trees unaffected by the music toggle.
        #expect(dirs.contains("system"))
        #expect(dirs.contains("node_modules"))
        let bundles = opts.skipBundleExtensions()
        #expect(!bundles.contains("itlp"))
        #expect(!bundles.contains("ite"))
        // musiclibrary can still arrive via Skip Media Bundles — the
        // toggles compose (union), neither owns the other.
        opts.skipMediaBundles = true
        #expect(opts.skipBundleExtensions().contains("musiclibrary"))
    }

    // SENSOR: "Look Inside Video Project Bundles" must never unlock
    // music bundles — the carve-out subtracts only pro-video extensions.
    @Test func proVideoCarveOutNeverUnlocksMusicBundles() {
        var opts = ScanOptions()
        opts.scanVideoProjectBundles = true
        let bundles = opts.skipBundleExtensions()
        #expect(bundles.contains("musiclibrary"))
        #expect(bundles.contains("itlp"))
        // And the canonical pro-video list doesn't contain music shapes.
        #expect(SkipCategories.proVideoBundleExtensions
                    .isDisjoint(with: SkipCategories.musicLibraryBundleExtensions))
    }

    // Presets: fast defaults skip music; "Scan Everything" includes it.
    @Test func presets() {
        #expect(ScanOptions.fastDefaults.skipMusicLibraryTrees)
        #expect(!ScanOptions.thorough.skipMusicLibraryTrees)
        #expect(!ScanOptions().isCustomized)
        var opts = ScanOptions()
        opts.skipMusicLibraryTrees = false
        #expect(opts.isCustomized, "deviating from the music skip must badge the menu")
    }

    // Walker integration: the names the walker's skipDirs check consults
    // are lowercased last path components — exactly what skipDirs() emits.
    @Test func walkerSkipMatchIsLastComponentLowercased() {
        let dirs = ScanOptions().skipDirs()
        let onDisk = "iTunes"                       // real-world casing
        #expect(dirs.contains(onDisk.lowercased()))
        let localized = "Automatically Add to iTunes.localized"
        #expect(dirs.contains(localized.lowercased()))
    }

    // MARK: Persistence (injected defaults — isolation)

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "vs-test-scanopts-\(name)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func roundTripThroughInjectedDefaults() {
        let d = scratchDefaults("roundtrip")
        var opts = ScanOptions()
        opts.skipMusicLibraryTrees = false
        opts.scanAudioFiles = true
        opts.save(to: d)
        let restored = ScanOptions.restored(from: d)
        #expect(restored == opts)
        #expect(!restored.skipMusicLibraryTrees)
        #expect(restored.scanAudioFiles)
    }

    // POISONED/ABSENT STATE: a plist written by a pre-#124 build has no
    // skipMusicLibraryTrees key — restore must keep the ON default
    // (prevention active on upgrade), while honoring the user's other
    // stored choices.
    @Test func absentKeyKeepsPreventionOn() {
        let d = scratchDefaults("legacy")
        // Simulate a legacy plist: only pre-existing keys present.
        d.set(false, forKey: "scanopts_skipSystemFiles")
        d.set(true, forKey: "scanopts_skipChecksums")
        let restored = ScanOptions.restored(from: d)
        #expect(restored.skipMusicLibraryTrees, "upgrade must default the music skip ON")
        #expect(!restored.skipSystemFiles)
        #expect(restored.skipChecksums)
    }

    // Stored FALSE (the user's deliberate escape hatch) survives restore
    // — "never set" and "set to false" are distinct states.
    @Test func storedFalseSurvivesRestore() {
        let d = scratchDefaults("escape")
        d.set(false, forKey: "scanopts_skipMusicLibraryTrees")
        #expect(!ScanOptions.restored(from: d).skipMusicLibraryTrees)
    }

    // MARK: Model parity sensor (refactor safety)

    // The model's snapshot methods now delegate to the pure builders —
    // pin that they can never drift apart again.
    @MainActor
    @Test func modelSnapshotParity() {
        let model = VideoScanModel()
        model.scanOptions = ScanOptions.thorough
        #expect(model.skipDirsSnapshot() == model.scanOptions.skipDirs())
        #expect(model.skipBundleExtensionsSnapshot()
                == model.scanOptions.skipBundleExtensions())
        model.scanOptions = ScanOptions()
        #expect(model.skipDirsSnapshot() == model.scanOptions.skipDirs())
        #expect(model.skipDirsSnapshot().contains("itunes"))
    }
}
