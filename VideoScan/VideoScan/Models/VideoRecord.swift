// VideoRecord.swift
// The persisted catalog record class — its declaration, ALL stored
// properties, and the designated initializer. Codable conformance,
// derived/computed properties, and snapshotClone() live in sibling
// VideoRecord+*.swift files; they were extracted verbatim from
// Models.swift in the 2026-06-26 model decomposition (step 1).
//
// A cross-file `extension` can't see `private` stored state, but every
// VideoRecord stored property here is already internal, so the splits
// see them without any access-level change. (Swift extension ≈ C++
// partial class via free member functions: no new stored state, methods
// share the same `self`.)

import Foundation

// MARK: - Video Record

class VideoRecord: Identifiable, Codable {
    var id: UUID = UUID()

    var filename: String = ""
    var ext: String = ""
    var streamTypeRaw: String = ""
    var size: String = ""
    var sizeBytes: Int64 = 0
    var duration: String = ""
    var durationSeconds: Double = 0
    var dateCreated: String = ""
    var dateModified: String = ""
    var dateCreatedRaw: Date?
    var dateModifiedRaw: Date?
    var container: String = ""
    var videoCodec: String = ""
    var resolution: String = ""
    var frameRate: String = ""
    var videoBitrate: String = ""
    var totalBitrate: String = ""
    var colorSpace: String = ""
    var bitDepth: String = ""
    var scanType: String = ""
    var audioCodec: String = ""
    var audioChannels: String = ""
    var audioSampleRate: String = ""
    var timecode: String = ""
    var tapeName: String = ""
    var isPlayable: String = ""
    var partialMD5: String = ""
    var fullPath: String = ""
    var directory: String = ""
    var notes: String = ""

    /// Provenance: where this record's file lived before the most recent
    /// Relocate. Set once at first migration, never overwritten — so even
    /// after multiple relocates, this still points at the *original* home.
    /// nil ⇒ never relocated. See docs/relocate_volume_plan.md §1.
    var originalFullPath: String?

    /// Friendly volume name at original location (the value of
    /// `volumeName` at the time of first migration). nil ⇒ never relocated.
    var originVolume: String?
    var wasCacheHit: Bool = false   // transient — not persisted to SQLite cache

    // Avid bin metadata (populated by cross-referencing .avb files)
    var avidClipName: String = ""
    var avidMobID: String = ""
    var avidMaterialUUID: String = ""
    var avidBinFile: String = ""
    var avidMobType: String = ""
    var avidMediaPath: String = ""     // original media path from Avid bin
    var avidTapeName: String = ""
    var avidEditRate: Double = 0
    var avidTracks: String = ""        // e.g. "V1, A1-A2"

    /// SMPTE UMID for the MaterialPackage inside the MXF file itself, as
    /// reported by ffprobe's `material_package_umid` format tag. Distinct
    /// from `avidMobID` (which comes from a sibling .avb bin file): this
    /// one is embedded in the MXF essence file and survives a byte-for-byte
    /// copy to another volume. Used to find substitute copies of offline
    /// media — if MacPro is unreachable but the same MXF was copied to
    /// MyBook3Tb, both records share this UMID and the resolver can swap
    /// the source path transparently.
    /// Empty for non-MXF files and for MXFs scanned before the field was
    /// added (re-scan picks it up).
    var materialPackageUMID: String = ""

    var pairedWith: VideoRecord?
    /// Set during decode; CatalogStore resolves it to a real `pairedWith`
    /// reference after the entire array has been decoded.
    var pendingPairedWithID: UUID?
    var pairGroupID: UUID?
    var pairConfidence: PairConfidence?
    var duplicateGroupID: UUID?
    var duplicateConfidence: DuplicateConfidence?
    var duplicateDisposition: DuplicateDisposition = .none
    var duplicateReasons: String = ""
    var duplicateBestMatchFilename: String = ""
    var duplicateGroupCount: Int = 0

    // Media lifecycle
    var lifecycleStage: LifecycleStage = .cataloged
    var mediaDisposition: MediaDisposition = .unreviewed
    var archiveStage: ArchiveStage = .none
    var masterLocation: String = ""           // e.g. "Mac Studio SSD"
    var backupDestinations: [BackupEntry] = []
    var junkScore: Int = 0
    var junkReasons: [String] = []
    var starRating: Int = 0                   // 0 = unrated, 1-3 stars
    var detectedPeople: [String] = []
    /// Borderline matches — face recognition score fell in the gray zone
    /// between strong-match and the threshold. Surfaced in the UI as
    /// "suspected: <name>" so the user knows the call is less certain.
    /// On re-scan, a strong hit moves the name from suspected → detected;
    /// a still-borderline hit keeps it here; a miss leaves both alone.
    var suspectedPeople: [String] = []
    /// User-confirmed person tags — Rick's ground truth, distinct from
    /// the algorithm's detectedPeople. See ConfirmedTag for shape.
    /// Empty until first manual confirmation. Search treats these the
    /// same as detectedPeople (a confirmed name matches the catalog
    /// search bar exactly like an auto-tagged name).
    var confirmedByUserPeople: [ConfirmedTag] = []
    /// Names Rick has explicitly rejected on this record — "no, that's
    /// not Anna". Suppresses future auto-tag of that name on this
    /// record AND feeds the eventual training loop as a hard negative
    /// ("classifier said Anna, ground truth says no"). NOT surfaced via
    /// catalog search — searching "anna" should never find a record
    /// where the user said "not anna".
    var rejectedPeople: [String] = []
    /// Scene captions generated by the vision-language model — sibling
    /// annotation to detectedPeople/suspectedPeople. Each entry pins a
    /// caption to a specific frame timestamp. Empty until "Caption
    /// Videos" runs. Re-captioning replaces the array wholesale; we
    /// don't merge captions from different models.
    var sceneCaptions: [SceneCaption] = []
    /// OCR date/time hits captured from VLM-targeted dossier prompt
    /// per-frame. Each entry pins a date-shaped string ("JUN.21 1991",
    /// "PM 11:30") to its source frame timestamp. The
    /// `inferredRecordDate` field below is the consensus output from
    /// these candidates plus other signals. PROVEN 2026-06-04 on
    /// Clip 03_converted.mov: 11/15 frames agreed on "JUN 21 1991".
    var ocrDateCandidates: [SceneCaption] = []
    /// Other on-screen text captured by the VLM dossier prompt —
    /// signs, captions, name tags, screen content. Searchable.
    var ocrText: [SceneCaption] = []
    /// Consensus / triangulated record date from
    /// `pfInferRecordDate` (OCR + audio + path + file metadata).
    /// nil ⇒ no dossier run or inconclusive. When set, this is the
    /// authoritative date — overrides file mtime when picking which
    /// year-bucket a record belongs in.
    var inferredRecordDate: Date?
    /// Confidence in `inferredRecordDate`, 0.0–1.0. OCR consensus
    /// across ≥3 frames is ~0.95; audio-only mentions ~0.85; path
    /// year only ~0.5; file mtime alone ~0.3. UI surfaces low-
    /// confidence dates with a "?" affordance.
    var inferredDateConfidence: Float?
    /// Wall-clock time the dossier pass ran. Lets the UI offer
    /// "re-run with newer model" actions and lets the catalog-wide
    /// orchestrator skip already-processed records idempotently.
    var dossierProcessedAt: Date?
    /// The model stack used for the dossier pass, e.g.
    /// "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4". Lets the UI
    /// distinguish freshly-processed records from older ones and
    /// trigger re-runs when the engine version changes.
    var dossierProcessedBy: String?
    /// Provenance: which VLM produced `sceneCaptions`. Lets the UI
    /// distinguish freshly-captioned rows from rows tagged by an older
    /// model and offer "re-caption with current model." nil when no
    /// captioning has been run yet.
    var sceneCaptionModel: String?
    /// Wall-clock time the captions were generated. Pair with
    /// `sceneCaptionModel` for the "captioned 2026-05-22 with qwen2.5-vl-3b-4bit"
    /// provenance string.
    var sceneCaptionDate: Date?

    // MARK: Audio transcript (Phase 1 — engine + data + search only)
    //
    // Single-line transcript field — Whisper produces a single text blob,
    // not per-frame entries (unlike VLM captioning). If we ever want
    // timestamped segments, that's a future schema change. The three
    // fields below mirror the sceneCaption* shape for the same reasons:
    // text + provenance model id + when. All optional / nil-by-default
    // so legacy catalogs round-trip cleanly (decodeIfPresent ?? nil).
    /// Full transcript of the audio track (audio-only files: entire
    /// content; video+audio files: just the audio). Empty string is a
    /// valid value meaning "ran transcription, found no speech" — that's
    /// distinct from nil ("never transcribed").
    var audioTranscript: String?
    /// Provenance: which engine + model produced the transcript.
    /// Suggested format e.g. "whisper-medium-mlx-q4", matches the
    /// modelID returned by the `AudioTranscriber` implementation.
    var audioTranscriptModel: String?
    /// Wall-clock time the transcript was generated. Pair with
    /// `audioTranscriptModel` for the "transcribed 2026-05-25 with
    /// whisper-medium-mlx-q4" provenance string.
    var audioTranscriptDate: Date?

    var combinedFromPairID: UUID?             // links back to source pair group

    /// Hostname of the machine that originally cataloged this record.
    /// Empty on records scanned locally; populated on import from another
    /// machine's exported catalog so the UI can show "from <host>".
    var sourceHost: String = ""

    /// Soft-delete marker. `nil` = active (visible in default catalog view);
    /// non-nil = "removed from catalog" — the file on disk is untouched but
    /// the row is hidden unless the user toggles "Show removed".
    ///
    /// Restore is just `purgedAt = nil`. There is no hard-delete path on the
    /// catalog — the trash never auto-empties (matches POI soft-delete UX).
    ///
    /// Codable note: encoded only when non-nil and decoded via decodeIfPresent
    /// so pre-feature catalog.json files (where the key is absent) come back
    /// as active records, not as decode failures.
    /// Swift's `Date?` ≈ C++ `std::optional<Date>` — nil/empty means "no value".
    var purgedAt: Date?

    /// True when the file is DRM-protected (e.g. iTunes FairPlay-encrypted
    /// m4v / m4p purchases from long-defunct user accounts). Detected via
    /// AVAsset.hasProtectedContent during ffprobe or during the orchestrator's
    /// per-file gate. Persisted so we don't repeatedly probe known-protected
    /// files. The candidate filter excludes these — we can't dossier audio
    /// we can't decrypt.
    ///
    /// Rick 2026-06-13: BT album files from a vintage iTunes Store account
    /// were eating Whisper time. Detection short-circuits that.
    ///
    /// Codable note: decoded via decodeIfPresent so legacy catalog.json
    /// files round-trip as false (unprotected, will be tested on next
    /// orchestrator pass).
    var drmProtected: Bool = false

    /// True when the analyzer pipeline determined this file's codec /
    /// container can't be decoded by AVFoundation (the path the in-app
    /// VLM uses). Set by the orchestrator when the VLM stage returns
    /// 0 scenes in under a second — the unmistakable "couldn't decode"
    /// signature. Also can be derived heuristically at read time via
    /// `hasUnplayableLegacyCodec` (see below) so already-cataloged
    /// records with codecs like svq3 / qdm2 / cinepak / indeo flag
    /// without re-running the VLM.
    ///
    /// Rick 2026-06-14: surfaces the dossier "0-scene .mov" files
    /// (Thanksgiving-Raw_Default.mov / Cache.mov / Timeline Movie.mov
    /// etc.) as red `!` in the catalog so the user can choose to
    /// reformat-and-analyze instead of leaving the file invisible to
    /// search.
    ///
    /// Codable note: encoded only when true (minimize delta), decoded
    /// via decodeIfPresent so legacy catalogs round-trip cleanly.
    var needsReformat: Bool = false

    /// When this record was produced by an MFO recipe from another
    /// catalog record, this is the parent record's id. nil for
    /// originals. Rick 2026-06-14: enables future lineage display
    /// (show derivatives grouped under their source). Auto-set by
    /// ReformatJob / future RecipeJobs when they catalog the
    /// derived output beside the source.
    ///
    /// Codable: encoded only when non-nil (minimize delta), decoded
    /// via decodeIfPresent so legacy catalogs round-trip cleanly.
    var derivedFrom: UUID?

    /// True when this record represents a file currently being actively
    /// worked on with external tools (transcode in another app, Topaz,
    /// FCP edit in progress). Independent of `lifecycleStage` — a file
    /// can be Cataloged AND workspace-active simultaneously. Cleared
    /// when the user sets a final disposition or explicitly takes the
    /// file out of triage. Surfaced as a turquoise row tint.
    /// Swift's `Bool = false` ≈ C++ in-class member initializer.
    var workspaceActive: Bool = false

    /// Provenance captured at scan time: which machine ran the scan, what
    /// kind of volume the file lived on (local/smb/nfs/afp), the volume's
    /// stable UUID if available, and the remote server name for network
    /// mounts. Populated automatically during file probing; refreshed
    /// on every rescan so old records backfill naturally.
    var scanContext: ScanContext = ScanContext()

    init() {}

    // MARK: Codable decode
    //
    // Swift requires a non-final class's `required init(from:)` to live in the
    // PRIMARY class declaration — it cannot be moved to an extension (unlike
    // CodingKeys and encode(to:), which are in VideoRecord+Codable.swift). So
    // the decoder stays here, but reads the `CodingKeys` defined alongside the
    // encoder. Body is verbatim from the original Models.swift.
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                          = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename                    = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        ext                         = try c.decodeIfPresent(String.self, forKey: .ext) ?? ""
        streamTypeRaw               = try c.decodeIfPresent(String.self, forKey: .streamTypeRaw) ?? ""
        size                        = try c.decodeIfPresent(String.self, forKey: .size) ?? ""
        sizeBytes                   = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        duration                    = try c.decodeIfPresent(String.self, forKey: .duration) ?? ""
        durationSeconds             = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        dateCreated                 = try c.decodeIfPresent(String.self, forKey: .dateCreated) ?? ""
        dateModified                = try c.decodeIfPresent(String.self, forKey: .dateModified) ?? ""
        dateCreatedRaw              = try c.decodeIfPresent(Date.self, forKey: .dateCreatedRaw)
        dateModifiedRaw             = try c.decodeIfPresent(Date.self, forKey: .dateModifiedRaw)
        container                   = try c.decodeIfPresent(String.self, forKey: .container) ?? ""
        videoCodec                  = try c.decodeIfPresent(String.self, forKey: .videoCodec) ?? ""
        resolution                  = try c.decodeIfPresent(String.self, forKey: .resolution) ?? ""
        frameRate                   = try c.decodeIfPresent(String.self, forKey: .frameRate) ?? ""
        videoBitrate                = try c.decodeIfPresent(String.self, forKey: .videoBitrate) ?? ""
        totalBitrate                = try c.decodeIfPresent(String.self, forKey: .totalBitrate) ?? ""
        colorSpace                  = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? ""
        bitDepth                    = try c.decodeIfPresent(String.self, forKey: .bitDepth) ?? ""
        scanType                    = try c.decodeIfPresent(String.self, forKey: .scanType) ?? ""
        audioCodec                  = try c.decodeIfPresent(String.self, forKey: .audioCodec) ?? ""
        audioChannels               = try c.decodeIfPresent(String.self, forKey: .audioChannels) ?? ""
        audioSampleRate             = try c.decodeIfPresent(String.self, forKey: .audioSampleRate) ?? ""
        timecode                    = try c.decodeIfPresent(String.self, forKey: .timecode) ?? ""
        tapeName                    = try c.decodeIfPresent(String.self, forKey: .tapeName) ?? ""
        isPlayable                  = try c.decodeIfPresent(String.self, forKey: .isPlayable) ?? ""
        partialMD5                  = try c.decodeIfPresent(String.self, forKey: .partialMD5) ?? ""
        fullPath                    = try c.decodeIfPresent(String.self, forKey: .fullPath) ?? ""
        directory                   = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
        notes                       = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        avidClipName                = try c.decodeIfPresent(String.self, forKey: .avidClipName) ?? ""
        avidMobID                   = try c.decodeIfPresent(String.self, forKey: .avidMobID) ?? ""
        avidMaterialUUID            = try c.decodeIfPresent(String.self, forKey: .avidMaterialUUID) ?? ""
        avidBinFile                 = try c.decodeIfPresent(String.self, forKey: .avidBinFile) ?? ""
        avidMobType                 = try c.decodeIfPresent(String.self, forKey: .avidMobType) ?? ""
        avidMediaPath               = try c.decodeIfPresent(String.self, forKey: .avidMediaPath) ?? ""
        avidTapeName                = try c.decodeIfPresent(String.self, forKey: .avidTapeName) ?? ""
        avidEditRate                = try c.decodeIfPresent(Double.self, forKey: .avidEditRate) ?? 0
        avidTracks                  = try c.decodeIfPresent(String.self, forKey: .avidTracks) ?? ""
        materialPackageUMID         = try c.decodeIfPresent(String.self, forKey: .materialPackageUMID) ?? ""
        pendingPairedWithID         = try c.decodeIfPresent(UUID.self, forKey: .pairedWithID)
        pairGroupID                 = try c.decodeIfPresent(UUID.self, forKey: .pairGroupID)
        pairConfidence              = try c.decodeIfPresent(PairConfidence.self, forKey: .pairConfidence)
        duplicateGroupID            = try c.decodeIfPresent(UUID.self, forKey: .duplicateGroupID)
        duplicateConfidence         = try c.decodeIfPresent(DuplicateConfidence.self, forKey: .duplicateConfidence)
        duplicateDisposition        = try c.decodeIfPresent(DuplicateDisposition.self, forKey: .duplicateDisposition) ?? .none
        duplicateReasons            = try c.decodeIfPresent(String.self, forKey: .duplicateReasons) ?? ""
        duplicateBestMatchFilename  = try c.decodeIfPresent(String.self, forKey: .duplicateBestMatchFilename) ?? ""
        duplicateGroupCount         = try c.decodeIfPresent(Int.self, forKey: .duplicateGroupCount) ?? 0
        sourceHost                  = try c.decodeIfPresent(String.self, forKey: .sourceHost) ?? ""
        lifecycleStage              = try c.decodeIfPresent(LifecycleStage.self, forKey: .lifecycleStage) ?? .cataloged
        mediaDisposition            = try c.decodeIfPresent(MediaDisposition.self, forKey: .mediaDisposition) ?? .unreviewed
        archiveStage                = try c.decodeIfPresent(ArchiveStage.self, forKey: .archiveStage) ?? .none
        masterLocation              = try c.decodeIfPresent(String.self, forKey: .masterLocation) ?? ""
        backupDestinations          = try c.decodeIfPresent([BackupEntry].self, forKey: .backupDestinations) ?? []
        junkScore                   = try c.decodeIfPresent(Int.self, forKey: .junkScore) ?? 0
        junkReasons                 = try c.decodeIfPresent([String].self, forKey: .junkReasons) ?? []
        starRating                  = try c.decodeIfPresent(Int.self, forKey: .starRating) ?? 0
        detectedPeople              = try c.decodeIfPresent([String].self, forKey: .detectedPeople) ?? []
        // decodeIfPresent ?? [] handles the v2 → v3 catalog migration: v2
        // catalog.json files have no `suspectedPeople` key, so old records
        // come back with an empty array (no false suspicion).
        suspectedPeople             = try c.decodeIfPresent([String].self, forKey: .suspectedPeople) ?? []
        // Additive optional, same migration pattern. Legacy catalogs
        // (no confirmedByUserPeople / rejectedPeople keys) decode as
        // empty. No catalog version bump required.
        confirmedByUserPeople       = try c.decodeIfPresent([ConfirmedTag].self, forKey: .confirmedByUserPeople) ?? []
        rejectedPeople              = try c.decodeIfPresent([String].self, forKey: .rejectedPeople) ?? []
        // v3 → v4 caption migration. Same pattern: v3 records have no
        // sceneCaptions / sceneCaptionModel / sceneCaptionDate keys so
        // they come back empty / nil; captioned records round-trip
        // unchanged.
        sceneCaptions               = try c.decodeIfPresent([SceneCaption].self, forKey: .sceneCaptions) ?? []
        sceneCaptionModel           = try c.decodeIfPresent(String.self, forKey: .sceneCaptionModel)
        sceneCaptionDate            = try c.decodeIfPresent(Date.self, forKey: .sceneCaptionDate)
        // Dossier fields — additive optional, same migration shape as
        // suspectedPeople / sceneCaptions: legacy catalogs come back
        // empty / nil; dossiered records round-trip unchanged.
        ocrDateCandidates           = try c.decodeIfPresent([SceneCaption].self, forKey: .ocrDateCandidates) ?? []
        ocrText                     = try c.decodeIfPresent([SceneCaption].self, forKey: .ocrText) ?? []
        inferredRecordDate          = try c.decodeIfPresent(Date.self, forKey: .inferredRecordDate)
        inferredDateConfidence      = try c.decodeIfPresent(Float.self, forKey: .inferredDateConfidence)
        dossierProcessedAt          = try c.decodeIfPresent(Date.self, forKey: .dossierProcessedAt)
        dossierProcessedBy          = try c.decodeIfPresent(String.self, forKey: .dossierProcessedBy)
        // Audio transcript fields — additive optional, same migration pattern
        // as scene captions. Legacy catalogs (no audioTranscript* keys) come
        // back with nil, transcribed records round-trip unchanged. No catalog
        // version bump required (additive optionals only).
        audioTranscript             = try c.decodeIfPresent(String.self, forKey: .audioTranscript)
        audioTranscriptModel        = try c.decodeIfPresent(String.self, forKey: .audioTranscriptModel)
        audioTranscriptDate         = try c.decodeIfPresent(Date.self, forKey: .audioTranscriptDate)
        combinedFromPairID          = try c.decodeIfPresent(UUID.self, forKey: .combinedFromPairID)
        scanContext                 = try c.decodeIfPresent(ScanContext.self, forKey: .scanContext) ?? ScanContext()
        // decodeIfPresent so legacy catalog.json files (no purgedAt key) round-
        // trip cleanly as active records rather than throwing. Regression
        // covered by CatalogPurgeTests.testDecodingLegacyCatalogJsonYieldsNilPurgedAt.
        purgedAt                    = try c.decodeIfPresent(Date.self, forKey: .purgedAt)
        // decodeIfPresent so legacy catalogs (no key) come back as false —
        // i.e. unknown DRM status. The orchestrator probes on first
        // encounter and persists the result, so this becomes a one-time
        // cost per legacy record.
        drmProtected                = try c.decodeIfPresent(Bool.self, forKey: .drmProtected) ?? false
        needsReformat               = try c.decodeIfPresent(Bool.self, forKey: .needsReformat) ?? false
        derivedFrom                 = try c.decodeIfPresent(UUID.self, forKey: .derivedFrom)
        // Workspace-active flag. decodeIfPresent so legacy catalogs (no key)
        // come back as false — i.e. "not in workspace." Import-to-workspace
        // (Pass B) is the only writer that sets this true.
        workspaceActive             = try c.decodeIfPresent(Bool.self, forKey: .workspaceActive) ?? false
        // Relocate provenance. Legacy catalogs (no keys) decode as nil and
        // remain treated as "never relocated." Once set on first migration
        // these keys are encoded on every subsequent write.
        originalFullPath            = try c.decodeIfPresent(String.self, forKey: .originalFullPath)
        originVolume                = try c.decodeIfPresent(String.self, forKey: .originVolume)
    }
}
