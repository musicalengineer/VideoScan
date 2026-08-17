import Foundation

// MARK: - Catalog Scope Policy (video-only catalog, 2026-07-15)
//
// Rick's directive: the VideoScan catalog contains ONLY video, plus audio
// with STRICT evidence of belonging to video. Everything else is cruft —
// stills leaked in (Canon .CR3 among them, via the unknown-extension
// sniff: CR3 is ISO-BMFF so it passes the magic-byte gate and probes as
// a video stream), and ~81k music-production audio files arrived through
// "Scan For Audio Files".
//
// This file is the PURE half of the feature: classification and the
// video-linked evidence test. Zero filesystem calls, zero actor state —
// same design contract as AnalysisScope. Scan integration (the pre-ffprobe
// walker skip + the post-scan evidence gate) and the set-aside migration
// build on these functions but live elsewhere.
//
// Classification rules:
//   * Stills / camera raw        → always excluded. Single source of
//     truth is AnalysisScope.stillImageExtensions (unified, not
//     duplicated — that list already carries the CR3 lesson).
//   * Music formats              → always excluded. Rick's explicit list
//     (mp3 m4a aac flac ogg wma opus). Other audio extensions the model
//     knows (mp2/alac/oga/au/amr/snd/ac3/…) deliberately fall through to
//     the AMBIGUOUS class instead: excluding on weak evidence is the
//     failure mode this project exists to avoid, and an unlinked oddball
//     is excluded by the evidence test anyway. Note .ogg is also in the
//     model's videoExtensions — the scope check runs FIRST, so Rick's
//     "ogg is music" verdict wins.
//   * Video                      → always included (any container whose
//     probe found a video stream, plus every extension on the video
//     allowlist).
//   * Extensionless              → ALWAYS included, and checked BEFORE
//     any stream-type rule (2026-07-15). Recovered Avid essence is often
//     extensionless with data-recovery names (file0001) — structural
//     evidence always fails for those, so even one that PROBES audio-only
//     must bypass the evidence gate; excluding what we cannot classify
//     would hide exactly the files this app rescues.
//   * Ambiguous audio            → included ONLY when video-linked:
//     production-audio containers (wav/aif/aiff/aifc/caf) and anything
//     WITH an extension that probed audio-only (notably audio-only MXF —
//     Avid orphan essence wears the same extension as its video partner).
//
// Video-linked evidence = the EXISTING correlator's pairing bar, not a
// new heuristic. See CatalogScopeEvidence below for the exact tiers.
//
// HARD INVARIANT (escalation-protected): a record that is already part
// of a recovered/correlated/combined MXF pair is NEVER classified as
// cruft — it is excluded from classification entirely, BEFORE any
// scoring. `classifyRecord` returns nil for such records so every
// caller inherits the invariant by construction. (Project escalation
// list: "anything affecting existing recovered MXF pair data".)

enum CatalogScopePolicy {

    // MARK: Classification

    /// How the video-only catalog scope sees one file/record.
    /// (Swift enum with cases ≈ a C++ scoped enum; `Equatable` gives ==.)
    enum Classification: Equatable {
        /// Video content — always in the catalog.
        case video
        /// No extension — always in (Avid recovery must stay eligible),
        /// even when the probe reported audio-only (recovery names carry
        /// no structural evidence, so the evidence gate would always
        /// exclude them — see classify()).
        case extensionless
        /// Still image / camera raw — never in.
        case still
        /// Music/consumer audio format — never in.
        case music
        /// Production audio that MAY be the audio half of a video
        /// (wav/aif/aiff/aifc/caf, or anything that probed audio-only).
        /// In the catalog ONLY with video-linked evidence.
        case ambiguousAudio
    }

    /// Persisted set-aside reason keys (machine keys — the UI maps these
    /// to friendly family language, e.g. "Photos" / "Music" / "Audio with
    /// no matching video").
    enum SetAsideReason: String, CaseIterable, Sendable {
        case stillImage    = "still-image"
        case musicFormat   = "music-format"
        case unlinkedAudio = "unlinked-audio"
        /// iPhone Live Photo movie halves exported by Photos as
        /// `jpegvideocomplement_<hex>.mov` beside `fullsizeoutput_<hex>.jpeg`
        /// (Rick 2026-08-17: 1,399 of them, ~3 s each; "how would I ever
        /// use them? they're associated with photos — untrack them").
        case livePhotoComplement = "live-photo-complement"
        /// "Remove from Catalog" on a selection (Rick 2026-08-17: "it was
        /// not clear what path to remove from catalog… not delete"). Same
        /// reversible set-aside as Tidy — files untouched.
        case removedByUser = "removed-by-user"

        /// Friendly label for UI (no jargon).
        var friendlyLabel: String {
            switch self {
            case .stillImage:    return "Photos and camera images"
            case .musicFormat:   return "Music files"
            case .unlinkedAudio: return "Audio with no matching video"
            case .livePhotoComplement: return "Live Photo movie halves (Photos owns them)"
            case .removedByUser: return "Removed from the catalog by you (files untouched)"
            }
        }
    }

    /// Photos' Live Photo export naming: the 3-second movie half.
    /// Matched on the FILENAME only (case-insensitive) — the pattern is
    /// specific enough that a sibling check adds nothing but I/O.
    static func isLivePhotoComplement(filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasPrefix("jpegvideocomplement_") && lower.hasSuffix(".mov")
    }

    /// Stills / camera raw — ONE source of truth, shared with the
    /// analysis scope gate (AnalysisScope carries the CR3/HEIC lesson).
    static var stillImageExtensions: Set<String> { AnalysisScope.stillImageExtensions }

    /// Music formats — Rick's explicit always-exclude list (2026-07-15).
    /// Deliberately narrow; see the header comment for why other audio
    /// extensions fall to the ambiguous class instead.
    static let musicExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "ogg", "wma", "opus",
    ]

    /// Production-audio containers that plausibly hold the audio half of
    /// a video (camera WAVs, Avid work audio, Core Audio captures).
    static let ambiguousAudioExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "caf",
    ]

    /// Classify from metadata only (lowercase-insensitive extension +
    /// probed stream type). Precedence mirrors AnalysisScope.classify:
    /// extension classes beat stream type (cover-art mp3s and camera
    /// raws probe as video streams), and the audio-only stream type
    /// catches audio-only MXF, which wears a video extension.
    ///
    /// EXTENSIONLESS IS CHECKED FIRST (QA fix 2026-07-15, Manager decision
    /// per Rick's standing "extensionless stays eligible — Avid recovery"
    /// rule): recovered extensionless essence carries data-recovery names
    /// (file0001) whose structural evidence ALWAYS fails, so routing an
    /// extensionless file that probed audio-only through the ambiguous-
    /// audio evidence test excluded exactly the files this app rescues.
    /// Extensionless → always included, regardless of probed stream type.
    static func classify(ext: String, streamTypeRaw: String) -> Classification {
        let e = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e.isEmpty { return .extensionless }
        if stillImageExtensions.contains(e) { return .still }
        if musicExtensions.contains(e) { return .music }
        if ambiguousAudioExtensions.contains(e)
            || streamTypeRaw == StreamType.audioOnly.rawValue {
            return .ambiguousAudio
        }
        return .video
    }

    /// Extension-only pre-I/O gate for the filesystem walker: true when a
    /// file can be skipped BEFORE any per-file disk I/O (no sniff, no
    /// hash, no ffprobe). This is the compute win — no more probing 25k
    /// AIFs' still/music neighbors. Ambiguous audio deliberately returns
    /// false here: it must be probed so the post-scan evidence test can
    /// judge it against the catalog's video records.
    static func extensionAlwaysExcluded(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return stillImageExtensions.contains(e) || musicExtensions.contains(e)
    }

    // MARK: Pair protection (the hard invariant)

    /// True when this record participates in existing recovered MXF pair
    /// data: it is correlated to a partner, carries a pair group, is
    /// still resolving a decoded pair reference, or is a Combine output.
    /// Such records are NEVER classified as cruft — they exit before any
    /// scoring. (`??`/optional checks ≈ C++ pointer-null tests.)
    nonisolated static func isPairProtected(_ rec: VideoRecord) -> Bool {
        rec.pairedWith != nil
            || rec.pendingPairedWithID != nil
            || rec.pairGroupID != nil
            || rec.combinedFromPairID != nil
    }

    /// Classify a live record under the hard invariant: pair-protected
    /// records are excluded from classification entirely (nil).
    nonisolated static func classifyRecord(_ rec: VideoRecord) -> Classification? {
        if isPairProtected(rec) { return nil }
        return classify(ext: rec.ext, streamTypeRaw: rec.streamTypeRaw)
    }

    /// The set-aside reason a record WOULD receive, or nil when the
    /// record stays in the catalog. `isVideoLinked` is a closure so the
    /// caller decides how the evidence test runs (indexed at scale via
    /// CatalogScopeEvidence, or a stub in tests).
    nonisolated static func setAsideReason(
        for rec: VideoRecord,
        isVideoLinked: (VideoRecord) -> Bool
    ) -> SetAsideReason? {
        guard let cls = classifyRecord(rec) else { return nil }  // pair-protected
        switch cls {
        case .video, .extensionless:
            return nil
        case .still:
            return .stillImage
        case .music:
            return .musicFormat
        case .ambiguousAudio:
            return isVideoLinked(rec) ? nil : .unlinkedAudio
        }
    }
}

// MARK: - Video-linked evidence (reuses the Correlate machinery)
//
// "Pre-correlate with existing Avid MXF and score it as >50% chance of
// being orphaned media belonging to video." — Rick, 2026-07-15.
//
// Rick's ">50%" maps to the correlator's EXISTING pairing bar — we do
// not invent a new heuristic:
//
//   * The rubric is CorrelationScorer.scoreParts, the ONE shared scoring
//     function (filename-key 4 / duration 3 / timestamp 3 / timecode 2 /
//     directory 1 / tape 1, floor = Correlator.minimumScore = 3).
//   * On top of the floor we require at least one STRUCTURAL signal
//     (filename / directory / timecode / tape) — the exact bar
//     CorrelationScorer.findBestPair applies for the user-facing
//     "Find A/V Pair" path (GH issue #101): in a 100k-record catalog,
//     duration + timestamp coincidence alone pairs unrelated files, so
//     it must never count as "evidence of belonging to video".
//   * Tiers that count as linked, concretely:
//       - Avid filename-correlation-key match (tape/clip-ID stems) —
//         score 4, structural: linked on its own.
//       - same-folder video sibling + duration match — score 4 with the
//         structural "directory" reason: linked (the correlator already
//         scores this combination; we add nothing).
//       - timecode and/or tape metadata matches combined with duration
//         or timestamp to reach the floor: linked.
//       - duration + timestamp ONLY (score 6, no structural reason):
//         NOT linked — the issue-#101 coincidence class.
//
// Scale: the catalog is ~103k records, so the evidence test must not be
// O(videos × audios). We index the video-only records by each structural
// signal once (O(V)) and each audio queries only the union of its four
// structural pools. That union is EXHAUSTIVE with respect to the bar: a
// pair that passes must share ≥1 structural signal, and every structural
// signal has an index. Worst-case memory: four dictionaries of Int
// indexes over the video snaps — a few MB at 100k records.
//
// "Find Missing Audio" seam: a future aggressive-search option can
// construct this same evidence engine with looser pools (or per-video
// candidate hunts) without touching the classification rules above.

struct CatalogScopeEvidence {

    /// Structural reasons — the SHARED GH #101 bar, hoisted next to
    /// CorrelationScorer.scoreParts (QA fix 2026-07-15: this was a
    /// duplicate literal that could drift from findBestPair's copy).
    static var structuralSignals: Set<String> { CorrelationScorer.structuralSignals }

    private let videos: [CorrelationScorer.Snap]
    private let videoKeys: [String]              // filenameCorrelationKey per video
    private var byKey: [String: [Int]] = [:]
    private var byDir: [String: [Int]] = [:]
    private var byTimecode: [String: [Int]] = [:]
    private var byTape: [String: [Int]] = [:]

    /// Build the structural indexes over the catalog's video-only records
    /// (as Sendable snaps — capture on the main actor, evaluate off it).
    init(videoSnaps: [CorrelationScorer.Snap]) {
        videos = videoSnaps
        videoKeys = videoSnaps.map { CorrelationScorer.filenameCorrelationKey($0.filename) }
        for (i, v) in videoSnaps.enumerated() {
            byKey[videoKeys[i], default: []].append(i)
            byDir[v.directory, default: []].append(i)
            if !v.timecode.isEmpty { byTimecode[v.timecode, default: []].append(i) }
            if !v.tapeName.isEmpty { byTape[v.tapeName, default: []].append(i) }
        }
    }

    /// True when the existing correlator would propose this audio as a
    /// pair candidate against the video pool AND the candidate carries at
    /// least one structural signal (the findBestPair bar, GH #101).
    func isVideoLinked(
        _ audio: CorrelationScorer.Snap,
        durationTolerance: Double = Correlator.durationTolerance,
        timestampTolerance: TimeInterval = Correlator.timestampTolerance
    ) -> Bool {
        let aKey = CorrelationScorer.filenameCorrelationKey(audio.filename)
        var seen = Set<Int>()
        var pool: [Int] = []
        for vi in byKey[aKey] ?? [] where seen.insert(vi).inserted { pool.append(vi) }
        for vi in byDir[audio.directory] ?? [] where seen.insert(vi).inserted { pool.append(vi) }
        if !audio.timecode.isEmpty {
            for vi in byTimecode[audio.timecode] ?? [] where seen.insert(vi).inserted { pool.append(vi) }
        }
        if !audio.tapeName.isEmpty {
            for vi in byTape[audio.tapeName] ?? [] where seen.insert(vi).inserted { pool.append(vi) }
        }

        for vi in pool {
            let v = videos[vi]
            if let (score, _, reasons) = CorrelationScorer.scoreParts(
                vKey: videoKeys[vi], audioFilename: audio.filename,
                vDuration: v.durationSeconds, aDuration: audio.durationSeconds,
                vDate: v.dateCreatedRaw, aDate: audio.dateCreatedRaw,
                vTimecode: v.timecode, aTimecode: audio.timecode,
                vDirectory: v.directory, aDirectory: audio.directory,
                vTape: v.tapeName, aTape: audio.tapeName,
                durationTolerance: durationTolerance,
                timestampTolerance: timestampTolerance
            ), score >= Correlator.minimumScore,
               !Set(reasons).isDisjoint(with: Self.structuralSignals) {
                return true
            }
        }
        return false
    }
}
