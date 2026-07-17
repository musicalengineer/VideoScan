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
    /// to catalog audio for Find Matching Audio / A-V correlation. See audioExtensions.
    var scanAudioFiles: Bool = false

    /// Polarity exception (additive "Scan X"): when ON, the scan ALSO admits
    /// files whose extension is in NO list — not a video extension, not an
    /// audio extension, not known-junk (.txt/.jpg/…). Recovers media saved
    /// with home-grown or mangled extensions. Cheap despite the wide net: a
    /// magic-byte sniff in the probe engine (MediaSignatures) gates every
    /// such candidate BEFORE ffprobe, so a volume of .dat blobs costs a
    /// 264-byte read each, not an ffprobe subprocess each. OFF by default.
    var scanUnknownExtensions: Bool = false

    /// Polarity exception (additive "Scan X"): when ON, the walker descends
    /// into PRO-VIDEO project bundles (.fcpbundle, .imovielibrary,
    /// .rcproject, …) even when "Skip Media Bundles" would skip them —
    /// project bundles are where FCP/iMovie hide the family's source clips.
    /// Photo/music libraries (.photoslibrary, .lrdata, …) are NEVER
    /// unlocked by this toggle; they stay governed by skipMediaBundles.
    /// Media found inside a bundle is tagged with the bundle path
    /// (ScanContext.bundleContainer). OFF by default.
    var scanVideoProjectBundles: Bool = false

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
        if d.object(forKey: "\(p)scanUnknownExtensions") != nil { s.scanUnknownExtensions = d.bool(forKey: "\(p)scanUnknownExtensions") }
        if d.object(forKey: "\(p)scanVideoProjectBundles") != nil { s.scanVideoProjectBundles = d.bool(forKey: "\(p)scanVideoProjectBundles") }
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
        d.set(scanUnknownExtensions, forKey: "\(p)scanUnknownExtensions")
        d.set(scanVideoProjectBundles, forKey: "\(p)scanVideoProjectBundles")
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
    /// `lrdata` (Lightroom previews/caches) added 2026-07-02 with the
    /// pro-video-bundle work: it rides with the photo-library class and is
    /// never unlocked by "Look Inside Video Project Bundles".
    static let mediaLibraryExtensions: Set<String> = [
        "photoslibrary", "imovielibrary", "fcpbundle", "musiclibrary",
        "tvlibrary", "aplibrary", "finalcutprojectlibrary", "lrdata"
    ]
    /// Pro-video PROJECT bundles — the subset of media libraries that
    /// "Look Inside Video Project Bundles" carves back OUT of the skip set.
    /// Canonical list lives in VideoScanCore (ProVideoBundles) so the
    /// walker's skip logic and ScanContext.bundleContainer tagging can
    /// never disagree.
    static var proVideoBundleExtensions: Set<String> { ProVideoBundles.bundleExtensions }
    /// Extensions that are definitively NOT media — documents, images,
    /// archives, code, fonts. "Scan Unrecognized File Types" consults this
    /// so it never wastes even a 264-byte sniff on a .txt or .jpg. An
    /// extension missing from this list is merely "unknown", which is the
    /// class that toggle exists to admit (the sniff arbitrates).
    static let knownNonMediaExtensions: Set<String> = [
        // documents / text
        "txt", "md", "rtf", "pdf", "doc", "docx", "xls", "xlsx", "ppt",
        "pptx", "pages", "numbers", "key", "csv", "log",
        // structured data / code / web. (No "ts" here — that's MPEG-TS vs
        // TypeScript, already arbitrated by the walker's isMpegTS sniff.)
        "json", "xml", "plist", "yml", "yaml", "html", "htm", "css", "js",
        "py", "sh", "c", "h", "cpp", "hpp", "swift", "java", "rb",
        "sql", "db", "sqlite", "sqlite3",
        // images (stills — Vision/Photos territory, not ffprobe's).
        // (No "raw" — a .raw file is plausibly a raw video/PCM dump, so it
        // stays "unknown" and the sniff arbitrates; camera-RAW stills will
        // sniff-fail and land in the audit, which is the correct fate. The
        // vendor-specific still extensions below are unambiguous and stay.)
        "jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp", "heic", "heif",
        "webp", "psd", "svg", "ico", "icns", "cr2", "nef", "arw", "dng",
        // archives / disk images / packages. (No "iso" — a DVD-video image
        // is plausibly media; leave it "unknown" so the sniff/ffprobe judge.)
        "zip", "gz", "bz2", "xz", "7z", "rar", "tar", "sit", "sitx", "dmg",
        "pkg",
        // binaries / fonts / misc
        "exe", "dll", "dylib", "so", "o", "a", "class", "jar",
        "ttf", "otf", "woff", "woff2", "nib", "strings", "ds_store"
    ]
}
