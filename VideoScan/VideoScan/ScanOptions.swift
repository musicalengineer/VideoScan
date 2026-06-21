import Foundation

// MARK: - Scan Options
//
// Lives in its own file because (a) it's a standalone value type unrelated
// to VideoScanModel's identity, and (b) the walker code in FilesystemWalker
// consults SkipCategories without needing the model. Extracted from
// VideoScanModel.swift during the 2026-05 size-cap refactor.

/// User-toggleable scan policy. Every toggle reads "Skip X" — consistent
/// polarity, no double negatives. Defaults match the fast-path
/// recommendation (three out of four "Skip" toggles ON).
struct ScanOptions: Equatable {
    /// Skip macOS/Windows/BSD system trees, app bundles, dev caches,
    /// Windows recycle bins. ON by default — family videos don't live in
    /// /System, node_modules, or $RECYCLE.BIN.
    var skipSystemFiles: Bool = true
    /// Skip `.photoslibrary`, `.fcpbundle`, `.imovielibrary`, etc. OFF by
    /// default — these *are* where user-created family media lives. Flip
    /// ON for a faster filesystem-only pass that ignores library bundles.
    var skipMediaBundles: Bool = false
    /// Skip files < 1 MB (stubs, thumbnails, .DS_Store-ish junk). ON by
    /// default — 1 MB is well under any real family video.
    var skipSmallFiles: Bool = true
    /// Skip partial-MD5 checksum. OFF by default — hashing lets Analyze
    /// Duplicates find copies later. Flip ON for a faster SMB scan when
    /// you don't care about dup detection this pass.
    var skipChecksums: Bool = false

    /// Polarity exception (an additive "Scan X", not a "Skip X"): when ON, the
    /// scan ALSO examines files with NO extension and lets ffprobe decide if
    /// they're media. Recovers Avid/QuickTime video-only exports and other
    /// media written without an extension that the media-extension allowlist
    /// silently dropped. OFF by default; this is a targeted gap-recovery pass,
    /// not something to leave on for every scan. See FilesystemWalker.
    var probeExtensionless: Bool = false

    /// Polarity exception (additive "Scan X"): when ON, the scan ALSO admits
    /// standalone audio files (wav/aif/mp3/…). OFF by default — archives hold
    /// thousands of scratch/temp audio files, so this is an opt-in pass. Needed
    /// to catalog audio for Repair Audio / A-V correlation. See audioExtensions.
    var scanAudioFiles: Bool = false

    // MARK: Persistence
    // UserDefaults.standard is documented thread-safe (CFPreferences-backed
    // with internal locking). nonisolated(unsafe) tells strict concurrency
    // we know what we're doing.
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let prefix = "scanopts_"

    static func restored() -> ScanOptions {
        let d = defaults; let p = prefix
        var s = ScanOptions()
        if d.object(forKey: "\(p)skipSystemFiles") != nil { s.skipSystemFiles  = d.bool(forKey: "\(p)skipSystemFiles") }
        if d.object(forKey: "\(p)skipMediaBundles") != nil { s.skipMediaBundles = d.bool(forKey: "\(p)skipMediaBundles") }
        if d.object(forKey: "\(p)skipSmallFiles") != nil { s.skipSmallFiles   = d.bool(forKey: "\(p)skipSmallFiles") }
        if d.object(forKey: "\(p)skipChecksums") != nil { s.skipChecksums    = d.bool(forKey: "\(p)skipChecksums") }
        if d.object(forKey: "\(p)probeExtensionless") != nil { s.probeExtensionless = d.bool(forKey: "\(p)probeExtensionless") }
        if d.object(forKey: "\(p)scanAudioFiles") != nil { s.scanAudioFiles = d.bool(forKey: "\(p)scanAudioFiles") }
        return s
    }

    func save() {
        let d = Self.defaults; let p = Self.prefix
        d.set(skipSystemFiles, forKey: "\(p)skipSystemFiles")
        d.set(skipMediaBundles, forKey: "\(p)skipMediaBundles")
        d.set(skipSmallFiles, forKey: "\(p)skipSmallFiles")
        d.set(skipChecksums, forKey: "\(p)skipChecksums")
        d.set(probeExtensionless, forKey: "\(p)probeExtensionless")
        d.set(scanAudioFiles, forKey: "\(p)scanAudioFiles")
    }

    /// True when the user has deviated from the recommended fast-path
    /// defaults. Used to badge the menu icon so a non-default policy is
    /// visible at a glance.
    var isCustomized: Bool { self != ScanOptions() }

    /// The recommended fast-path preset — all three safe skips ON,
    /// checksums OFF. Same as default initializer.
    static let fastDefaults = ScanOptions()

    /// Scan everything, hash everything. Use when you suspect a rare find
    /// lives somewhere weird. Slower — walks system trees and hashes all.
    static let thorough = ScanOptions(
        skipSystemFiles: false,
        skipMediaBundles: false,
        skipSmallFiles: false,
        skipChecksums: false
    )
}

// MARK: - Skip List Categories (static — walkers consult ScanOptions to decide)

enum SkipCategories {
    /// Always-skipped: Finder metadata that never contains media and cannot
    /// be toggled on. These are filesystem plumbing, not content.
    static let finderMetaDirs: Set<String> = [
        ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
        ".documentrevisions-v100", ".vol", "automount"
    ]
    /// macOS + BSD system trees. `library` is here because ~/Library holds
    /// app containers, never home videos. Togglable via includeSystemTrees.
    static let systemDirs: Set<String> = [
        "system", "library", "applications", "usr", "bin", "sbin",
        "private", "network", "cores", "dev", "opt", "var", "tmp",
        "etc", "volumes",
        "home", "net", "lost+found"
    ]
    /// Windows-formatted-volume leftovers (seen on osx10.8). Togglable.
    static let windowsTrashDirs: Set<String> = [
        "$recycle.bin", "recycler", "system volume information"
    ]
    /// Dev / build caches. Togglable.
    static let devCacheDirs: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "__pycache__",
        ".venv", "venv", ".cache", ".npm", ".cocoapods"
    ]
    /// Opaque OS/app bundles. Togglable via includeAppBundles.
    static let appBundleExtensions: Set<String> = [
        "app", "bundle", "framework", "kext", "plugin", "component",
        "mdimporter", "osax", "xpc", "lproj", "pkg", "mpkg", "docset",
        "pluginkit", "systemextension", "appex"
    ]
    /// User-media libraries. IN by default (opt-out via skipMediaLibraries).
    static let mediaLibraryExtensions: Set<String> = [
        "photoslibrary", "imovielibrary", "fcpbundle", "musiclibrary",
        "tvlibrary", "aplibrary", "finalcutprojectlibrary"
    ]
}
