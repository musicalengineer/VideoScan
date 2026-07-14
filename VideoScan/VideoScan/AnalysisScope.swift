import Foundation

// MARK: - Analysis Scope
//
// "What kinds of files should Analyze spend GPU time on?" — Rick,
// 2026-07-13. Live-catalog reality: of ~91,784 remaining unanalyzed
// eligible files, 81,213 were audio files (aif/caf/wav/m4a/mp3/…) from
// the music-production archive, not home video. Running VLM+Whisper
// over them is pure waste. Separately, a perf diagnosis (2026-07-14)
// caught the batch feeding mp3s AND Canon .CR3 raw photos into the
// frame-extraction pipeline — each one failed only AFTER a per-file
// AVAsset DRM probe + extraction attempt (1,097 failures ≈ 3.1 h of a
// nightly batch). Root cause: audio files with embedded cover art and
// camera raws both probe as having a "video" stream, so stream-type
// filtering alone can't catch them. Extension-aware, metadata-only
// gating can — and must run BEFORE any per-file disk I/O.
//
// Semantics (approved by Rick):
//   - Scope-skipped is NOT junk. Records are untouched — no
//     disposition change, no lifecycle change. Flipping the toggle
//     back re-includes them instantly.
//   - Still images / camera raw are never video-analysis candidates.
//     No toggle — they get their own "photos" tally on the dashboard.
//   - Audio-only files are excluded by DEFAULT, re-includable via the
//     master toggle plus per-extension checkboxes.
//   - Extensionless / unknown-probe files STAY eligible: recovered
//     Avid video-only essence is often extensionless (known catalog
//     gap), and excluding what we can't classify would hide exactly
//     the files this app exists to rescue.
//
// The scope decision is a PURE function of catalog metadata
// (streamTypeRaw + filename extension) — zero filesystem calls, so
// scope-excluded files never reach the orchestrator's per-file DRM
// probe or the frame extractor.
//
// (Swift `struct` here ≈ a C++ value type with all members public;
// Equatable/Hashable are compiler-synthesized memberwise ==/hash.)

struct AnalysisScope: Equatable, Hashable {

    /// Master toggle — DEFAULT OFF. When off, every audio-classified
    /// file is out of scope. When on, audio files are included except
    /// extensions the user unchecked below.
    var includeAudioOnly: Bool = false

    /// Per-extension opt-outs, honored only while `includeAudioOnly`
    /// is on. Stored as the EXCLUDED set so the default state
    /// ("include everything when the master toggle is on") needs no
    /// persisted data. Lowercased extensions, no leading dot.
    var excludedAudioExtensions: Set<String> = []

    // MARK: Extension sets

    /// Extensions that classify a record as audio regardless of what
    /// ffprobe said about its streams — mp3/m4a cover art registers as
    /// an "attached pic" video stream, which is how music files snuck
    /// into the frame-extraction pipeline.
    static let audioExtensions: Set<String> = [
        "aif", "aiff", "aifc", "caf", "wav", "m4a", "m4b", "m4p",
        "mp3", "mp2", "aac", "alac", "flac", "ogg", "oga", "opus",
        "wma", "au", "amr", "ac3", "dts", "mka",
    ]

    /// Still-image / camera-raw extensions — never video-analysis
    /// candidates. Camera raws (CR3 etc.) probe as a video stream,
    /// so this must be extension-based.
    static let stillImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "webp",
        "tif", "tiff", "psd", "exr", "tga",
        // camera raw
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "orf", "rw2", "dng", "srw", "pef", "raw", "3fr",
        "erf", "kdc", "mrw", "x3f",
    ]

    // MARK: Classification

    /// How the scope gate sees one record. Pure metadata — never
    /// touches the filesystem.
    enum Classification: Equatable {
        /// Has (or may have) video content worth analyzing — includes
        /// extensionless and unknown-probe records (recovered Avid
        /// essence must stay eligible).
        case analyzable
        /// Audio-classified — by extension OR by stream type. Carries
        /// the lowercased extension ("" when extensionless) for the
        /// per-extension checkbox tallies.
        case audio(ext: String)
        /// Still image / camera raw — never a video candidate.
        case photo
    }

    /// Lowercased filename extension, "" when none.
    static func fileExtension(of filename: String) -> String {
        (filename as NSString).pathExtension.lowercased()
    }

    /// Classify from catalog metadata only. Precedence:
    ///   1. still-image extension → .photo (even when ffprobe reported
    ///      a "video" stream — camera raws do)
    ///   2. audio extension OR streamTypeRaw == "Audio only" → .audio
    ///      (even when cover art registered a video stream)
    ///   3. everything else → .analyzable (video, extensionless,
    ///      unknown-probe, ffprobe-failed)
    static func classify(streamTypeRaw: String, filename: String) -> Classification {
        let ext = fileExtension(of: filename)
        if stillImageExtensions.contains(ext) { return .photo }
        if audioExtensions.contains(ext)
            || streamTypeRaw == StreamType.audioOnly.rawValue {
            return .audio(ext: ext)
        }
        return .analyzable
    }

    /// The scope gate: is this record in scope for Analyze?
    func includes(streamTypeRaw: String, filename: String) -> Bool {
        switch Self.classify(streamTypeRaw: streamTypeRaw, filename: filename) {
        case .analyzable:
            return true
        case .photo:
            return false
        case .audio(let ext):
            return includeAudioOnly && !excludedAudioExtensions.contains(ext)
        }
    }

    // MARK: Persistence (explicit-save pattern)
    //
    // Same shape as ScanPerformanceSettings: restored() at startup,
    // save() on every user change. No didSet magic — @Observable /
    // @Published owners must call save() explicitly.

    static let includeAudioKey = "analysisScope_includeAudioOnly"
    static let excludedExtensionsKey = "analysisScope_excludedAudioExtensions"

    static func restored(from defaults: UserDefaults) -> AnalysisScope {
        var s = AnalysisScope()
        if defaults.object(forKey: includeAudioKey) != nil {
            s.includeAudioOnly = defaults.bool(forKey: includeAudioKey)
        }
        if let excluded = defaults.stringArray(forKey: excludedExtensionsKey) {
            s.excludedAudioExtensions = Set(excluded.map { $0.lowercased() })
        }
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(includeAudioOnly, forKey: Self.includeAudioKey)
        defaults.set(excludedAudioExtensions.sorted(), forKey: Self.excludedExtensionsKey)
    }
}

// MARK: - Candidate filters (pure, catalog-metadata only)
//
// Free functions in the pfCatalogWide* family. NO filesystem calls —
// scope-excluded records must never reach the orchestrator's per-file
// AVAsset DRM probe (that probe on never-analyzable files is where
// the 2026-07-13 nightly lost ~3.1 h).

/// Subset of `candidates` inside the analysis scope.
nonisolated func pfAnalysisScopeCandidates(
    _ candidates: [VideoRecord],
    scope: AnalysisScope
) -> [VideoRecord] {
    candidates.filter {
        scope.includes(streamTypeRaw: $0.streamTypeRaw, filename: $0.filename)
    }
}

/// Per-reason exclusion counts for the batch-start log line —
/// "N audio, M photos" beats a silent shrink of the candidate list.
nonisolated func pfAnalysisScopeExclusionTally(
    _ candidates: [VideoRecord],
    scope: AnalysisScope
) -> (audio: Int, photos: Int) {
    var audio = 0, photos = 0
    for r in candidates where !scope.includes(streamTypeRaw: r.streamTypeRaw,
                                              filename: r.filename) {
        switch AnalysisScope.classify(streamTypeRaw: r.streamTypeRaw,
                                      filename: r.filename) {
        case .audio: audio += 1
        case .photo: photos += 1
        case .analyzable: break // unreachable: analyzable is always included
        }
    }
    return (audio, photos)
}
