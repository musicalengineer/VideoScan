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

public class VideoRecord: Identifiable, Decodable {
    // `nonisolated let`: the identity is immutable and isolation-independent,
    // so it satisfies Identifiable without crossing the (future) MainActor
    // boundary. Injected at construction; decode sets it from JSON below.
    // `// In C++ terms: a `const` member set only in the constructor's
    // initializer list — never reassigned afterward.`
    public nonisolated let id: UUID

    public var filename: String = ""
    public var ext: String = ""
    public var streamTypeRaw: String = ""
    public var size: String = ""
    public var sizeBytes: Int64 = 0
    public var duration: String = ""
    public var durationSeconds: Double = 0
    public var dateCreated: String = ""
    public var dateModified: String = ""
    public var dateCreatedRaw: Date?
    public var dateModifiedRaw: Date?
    public var container: String = ""
    public var videoCodec: String = ""
    public var resolution: String = ""
    public var frameRate: String = ""
    public var videoBitrate: String = ""
    public var totalBitrate: String = ""
    public var colorSpace: String = ""
    public var bitDepth: String = ""
    public var scanType: String = ""
    public var audioCodec: String = ""
    public var audioChannels: String = ""
    public var audioSampleRate: String = ""
    public var timecode: String = ""
    public var tapeName: String = ""
    public var isPlayable: String = ""
    public var partialMD5: String = ""
    public var fullPath: String = ""
    public var directory: String = ""
    public var notes: String = ""

    /// Rick's own free-text note for this record (tags-and-usernotes
    /// split, 2026-07-23). Distinct from `notes`, which the pipeline
    /// machines write (ffprobe stderr, File Journey stamps): the
    /// "Notes…" editing UI reads/writes THIS field, it joins the
    /// plain-search haystack (human signal), and machine `notes` stays
    /// out of plain search. A one-time lazy migration at catalog load
    /// moves legacy human text out of `notes` into here (see
    /// UserNotesMigration). Additive — legacy catalogs decode as "",
    /// and the DTO encodes the key only when non-empty, so old
    /// catalog.json files round-trip byte-identical.
    public var userNotes: String = ""

    /// Workflow tags ("Follow Up", "Gold", custom free-form). Stored in
    /// canonical display form, matched case-insensitively everywhere —
    /// see WorkflowTags. Searchable via the `tag:` field token AND the
    /// plain-search haystack. Additive — legacy catalogs decode as [],
    /// and the DTO encodes the key only when non-empty, so old
    /// catalog.json files round-trip byte-identical.
    public var tags: [String] = []

    /// Provenance: where this record's file lived before the most recent
    /// Relocate. Set once at first migration, never overwritten — so even
    /// after multiple relocates, this still points at the *original* home.
    /// nil ⇒ never relocated. See docs/relocate_volume_plan.md §1.
    public var originalFullPath: String?

    /// Friendly volume name at original location (the value of
    /// `volumeName` at the time of first migration). nil ⇒ never relocated.
    public var originVolume: String?
    public var wasCacheHit: Bool = false   // transient — not persisted to SQLite cache

    // Avid bin metadata (populated by cross-referencing .avb files)
    public var avidClipName: String = ""
    public var avidMobID: String = ""
    public var avidMaterialUUID: String = ""
    public var avidBinFile: String = ""
    public var avidMobType: String = ""
    public var avidMediaPath: String = ""     // original media path from Avid bin
    public var avidTapeName: String = ""
    public var avidEditRate: Double = 0
    public var avidTracks: String = ""        // e.g. "V1, A1-A2"

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
    public var materialPackageUMID: String = ""

    public var pairedWith: VideoRecord?
    /// Set during decode; CatalogStore resolves it to a real `pairedWith`
    /// reference after the entire array has been decoded.
    public var pendingPairedWithID: UUID?
    public var pairGroupID: UUID?
    public var pairConfidence: PairConfidence?
    public var duplicateGroupID: UUID?
    public var duplicateConfidence: DuplicateConfidence?
    public var duplicateDisposition: DuplicateDisposition = .none
    public var duplicateReasons: String = ""
    public var duplicateBestMatchFilename: String = ""
    public var duplicateGroupCount: Int = 0
    /// Analysis-ledger stamp (2026-07-05): when this record last went
    /// through duplicate analysis. nil = pending — never analyzed, or
    /// invalidated by a content change (rescan refresh). "Checked and
    /// found unique" persists too: a loner is stamped, not re-examined
    /// on every Analyze click. Legacy catalogs decode as nil = pending —
    /// exactly the right migration.
    public var dupAnalyzedAt: Date?

    // Media lifecycle
    public var lifecycleStage: LifecycleStage = .cataloged
    public var mediaDisposition: MediaDisposition = .unreviewed
    public var archiveStage: ArchiveStage = .none
    public var masterLocation: String = ""           // e.g. "Mac Studio SSD"
    public var backupDestinations: [BackupEntry] = []
    public var junkScore: Int = 0
    public var junkReasons: [String] = []
    public var starRating: Int = 0                   // 0 = unrated, 1-3 stars
    public var detectedPeople: [String] = []
    /// Borderline matches — face recognition score fell in the gray zone
    /// between strong-match and the threshold. Surfaced in the UI as
    /// "suspected: <name>" so the user knows the call is less certain.
    /// On re-scan, a strong hit moves the name from suspected → detected;
    /// a still-borderline hit keeps it here; a miss leaves both alone.
    public var suspectedPeople: [String] = []
    /// User-confirmed person tags — Rick's ground truth, distinct from
    /// the algorithm's detectedPeople. See ConfirmedTag for shape.
    /// Empty until first manual confirmation. Search treats these the
    /// same as detectedPeople (a confirmed name matches the catalog
    /// search bar exactly like an auto-tagged name).
    public var confirmedByUserPeople: [ConfirmedTag] = []
    /// Names Rick has explicitly rejected on this record — "no, that's
    /// not Anna". Suppresses future auto-tag of that name on this
    /// record AND feeds the eventual training loop as a hard negative
    /// ("classifier said Anna, ground truth says no"). NOT surfaced via
    /// catalog search — searching "anna" should never find a record
    /// where the user said "not anna".
    public var rejectedPeople: [String] = []
    /// Scene captions generated by the vision-language model — sibling
    /// annotation to detectedPeople/suspectedPeople. Each entry pins a
    /// caption to a specific frame timestamp. Empty until "Caption
    /// Videos" runs. Re-captioning replaces the array wholesale; we
    /// don't merge captions from different models.
    public var sceneCaptions: [SceneCaption] = []
    /// OCR date/time hits captured from VLM-targeted dossier prompt
    /// per-frame. Each entry pins a date-shaped string ("JUN.21 1991",
    /// "PM 11:30") to its source frame timestamp. The
    /// `inferredRecordDate` field below is the consensus output from
    /// these candidates plus other signals. PROVEN 2026-06-04 on
    /// Clip 03_converted.mov: 11/15 frames agreed on "JUN 21 1991".
    public var ocrDateCandidates: [SceneCaption] = []
    /// Other on-screen text captured by the VLM dossier prompt —
    /// signs, captions, name tags, screen content. Searchable.
    public var ocrText: [SceneCaption] = []
    /// Consensus / triangulated record date from
    /// `pfInferRecordDate` (OCR + audio + path + file metadata).
    /// nil ⇒ no dossier run or inconclusive. When set, this is the
    /// authoritative date — overrides file mtime when picking which
    /// year-bucket a record belongs in.
    public var inferredRecordDate: Date?
    /// Confidence in `inferredRecordDate`, 0.0–1.0. OCR consensus
    /// across ≥3 frames is ~0.95; audio-only mentions ~0.85; path
    /// year only ~0.5; file mtime alone ~0.3. UI surfaces low-
    /// confidence dates with a "?" affordance.
    public var inferredDateConfidence: Float?
    /// Wall-clock time the dossier pass ran. Lets the UI offer
    /// "re-run with newer model" actions and lets the catalog-wide
    /// orchestrator skip already-processed records idempotently.
    public var dossierProcessedAt: Date?
    /// The model stack used for the dossier pass, e.g.
    /// "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4". Lets the UI
    /// distinguish freshly-processed records from older ones and
    /// trigger re-runs when the engine version changes.
    public var dossierProcessedBy: String?
    /// Provenance: which VLM produced `sceneCaptions`. Lets the UI
    /// distinguish freshly-captioned rows from rows tagged by an older
    /// model and offer "re-caption with current model." nil when no
    /// captioning has been run yet.
    public var sceneCaptionModel: String?
    /// Wall-clock time the captions were generated. Pair with
    /// `sceneCaptionModel` for the "captioned 2026-05-22 with qwen2.5-vl-3b-4bit"
    /// provenance string.
    public var sceneCaptionDate: Date?

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
    public var audioTranscript: String?
    /// Provenance: which engine + model produced the transcript.
    /// Suggested format e.g. "whisper-medium-mlx-q4", matches the
    /// modelID returned by the `AudioTranscriber` implementation.
    public var audioTranscriptModel: String?
    /// Wall-clock time the transcript was generated. Pair with
    /// `audioTranscriptModel` for the "transcribed 2026-05-25 with
    /// whisper-medium-mlx-q4" provenance string.
    public var audioTranscriptDate: Date?

    public var combinedFromPairID: UUID?             // links back to source pair group

    /// Hostname of the machine that originally cataloged this record.
    /// Empty on records scanned locally; populated on import from another
    /// machine's exported catalog so the UI can show "from <host>".
    public var sourceHost: String = ""

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
    public var purgedAt: Date?

    /// Catalog-scope set-aside marker (video-only catalog, 2026-07-15).
    /// nil = record is in scope (the normal state); non-nil = the record
    /// was set aside as outside the video-only catalog scope, carrying a
    /// machine reason key ("still-image" / "music-format" /
    /// "unlinked-audio" — CatalogScopePolicy.SetAsideReason). Set-aside
    /// rows are hidden from the default table, search, dup detection,
    /// correlate candidates, analysis coverage, and CSV export — but the
    /// record and its file are NEVER deleted, and restore is just
    /// `setAsideReason = nil` (same reversibility contract as purgedAt,
    /// kept as a SEPARATE field so "removed" and "set aside" stay
    /// distinct states with distinct toggles).
    ///
    /// Codable note: encoded only when non-nil and decoded via
    /// decodeIfPresent, so pre-feature catalog.json files round-trip
    /// byte-identical and legacy records come back in scope.
    /// (`String?` ≈ C++ `std::optional<std::string>`.)
    public var setAsideReason: String?

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
    public var drmProtected: Bool = false

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
    public var needsReformat: Bool = false

    /// When this record was produced by an MFO recipe from another
    /// catalog record, this is the parent record's id. nil for
    /// originals. Rick 2026-06-14: enables future lineage display
    /// (show derivatives grouped under their source). Auto-set by
    /// ReformatJob / future RecipeJobs when they catalog the
    /// derived output beside the source.
    ///
    /// Codable: encoded only when non-nil (minimize delta), decoded
    /// via decodeIfPresent so legacy catalogs round-trip cleanly.
    public var derivedFrom: UUID?

    /// Cleanup provenance (Clean Up Video, 2026-07-07): the stable id of
    /// the `CleanupRecipe` that produced this record's file, e.g.
    /// "vhs-quick-clean". nil for every record that is not a cleanup
    /// output. Pairs with `derivedFrom` (which carries the SOURCE
    /// record's id) so the catalog can answer "cleaned from what, with
    /// what". Additive optional — legacy catalogs decode as nil, and
    /// the DTO only encodes the key when present, so old catalog.json
    /// files round-trip byte-identical.
    public var cleanupRecipeID: String?

    /// Version of the recipe that produced this file (recipes bump their
    /// version whenever steps/parameters change). nil whenever
    /// `cleanupRecipeID` is nil.
    public var cleanupRecipeVersion: Int?

    /// Which MFO verb produced this record's file, for records created
    /// by derivation from another catalog record — "trim" (Trim Master,
    /// 2026-07-16) or "balanceAudio" (Balance Audio, GH #116). The
    /// universal derivation marker: pairs with `derivedFrom` (the SOURCE
    /// record's id) so provenance answers both "from what" and "by what
    /// operation". Verb-specific payload rides in its own fields (see
    /// `trimInSeconds`/`trimOutSeconds` for "trim"). nil for originals
    /// and for older derivation verbs that predate the field (their kind
    /// is implied by their own provenance fields, e.g.
    /// `cleanupRecipeID`). Additive optional — legacy catalogs decode as
    /// nil, and the DTO only encodes the key when present, so old
    /// catalog.json files round-trip byte-identical.
    public var derivationKind: String?

    /// Trim-specific payload (Trim Master, 2026-07-16): the source-file
    /// second the stream-copy trim kept FROM. Present only when
    /// `derivationKind == "trim"`; nil/absent for every other record —
    /// including all legacy records, same additive-optional migration as
    /// `derivationKind`. Pairs with `derivedFrom` so the catalog can
    /// answer "trimmed from what, keeping which range".
    public var trimInSeconds: Double?

    /// The source-file second the trim kept UNTIL. nil whenever
    /// `trimInSeconds` is nil.
    public var trimOutSeconds: Double?

    /// Rick's hand-entered date for the footage (Estimated Date, GH
    /// #117): REDUCED-PRECISION ISO — "1992", "1992-06", or
    /// "1992-06-14". The partial date IS the precision signal (year-only
    /// vs month vs day); there is no separate precision enum. Sorts
    /// lexically, reads cleanly in catalog.json. Old tapes often have no
    /// usable machine date, so this outranks every inferred/container
    /// date in "best date" resolution (VideoRecordUserDate.swift).
    /// nil = never dated by hand. Only ever written with
    /// `UserDateEntry.canonicalize` output. Additive optional — legacy
    /// catalogs decode as nil, the DTO encodes the key only when
    /// present, old catalog.json files round-trip byte-identical.
    /// Derivatives (trim / balanceAudio outputs) inherit it from their
    /// source record — same footage, same date.
    public var userDate: String?

    /// Confidence in `userDate`: "estimated" (Rick's best guess, the
    /// entry UI's default) or "known" — where "known" applies AT THE
    /// PRECISION ENTERED ("1992" + known means the YEAR is certain).
    /// Meaningless (nil) when `userDate` is nil. The known / estimated /
    /// unconfirmed status shown in the UI is DERIVED from these two
    /// fields (`userDateStatus`), never stored. Same additive-optional
    /// migration as `userDate`.
    public var userDateConfidence: String?

    /// True when this record represents a file currently being actively
    /// worked on with external tools (transcode in another app, Topaz,
    /// FCP edit in progress). Independent of `lifecycleStage` — a file
    /// can be Cataloged AND workspace-active simultaneously. Cleared
    /// when the user sets a final disposition or explicitly takes the
    /// file out of triage. Surfaced as a turquoise row tint.
    /// Swift's `Bool = false` ≈ C++ in-class member initializer.
    public var workspaceActive: Bool = false

    /// Provenance captured at scan time: which machine ran the scan, what
    /// kind of volume the file lived on (local/smb/nfs/afp), the volume's
    /// stable UUID if available, and the remote server name for network
    /// mounts. Populated automatically during file probing; refreshed
    /// on every rescan so old records backfill naturally.
    public var scanContext: ScanContext = ScanContext()

    public init(id: UUID = UUID()) {
        self.id = id
    }

    // MARK: Codable decode
    //
    // Swift requires a non-final class's `required init(from:)` to live in the
    // PRIMARY class declaration — it cannot be moved to an extension (unlike
    // CodingKeys and encode(to:), which are in VideoRecord+Codable.swift). So
    // the decoder stays here, but reads the `CodingKeys` defined alongside the
    // encoder. Body is verbatim from the original Models.swift.
    public required init(from decoder: Decoder) throws {
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
        // Tags + user notes (2026-07-23) — additive optional, same
        // migration pattern as suspectedPeople: legacy catalogs (no
        // keys) come back empty; tagged/noted records round-trip
        // unchanged. No catalog version bump required.
        userNotes                   = try c.decodeIfPresent(String.self, forKey: .userNotes) ?? ""
        tags                        = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
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
        dupAnalyzedAt               = try c.decodeIfPresent(Date.self, forKey: .dupAnalyzedAt)
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
        // decodeIfPresent so pre-feature catalogs (no setAsideReason key)
        // round-trip cleanly as in-scope records (same shape as purgedAt).
        setAsideReason              = try c.decodeIfPresent(String.self, forKey: .setAsideReason)
        // decodeIfPresent so legacy catalogs (no key) come back as false —
        // i.e. unknown DRM status. The orchestrator probes on first
        // encounter and persists the result, so this becomes a one-time
        // cost per legacy record.
        drmProtected                = try c.decodeIfPresent(Bool.self, forKey: .drmProtected) ?? false
        needsReformat               = try c.decodeIfPresent(Bool.self, forKey: .needsReformat) ?? false
        derivedFrom                 = try c.decodeIfPresent(UUID.self, forKey: .derivedFrom)
        // Cleanup provenance — additive optional, same migration pattern
        // as derivedFrom: legacy catalogs (no keys) decode as nil.
        cleanupRecipeID             = try c.decodeIfPresent(String.self, forKey: .cleanupRecipeID)
        cleanupRecipeVersion        = try c.decodeIfPresent(Int.self, forKey: .cleanupRecipeVersion)
        // Derivation provenance (kind + trim payload) — same
        // additive-optional migration pattern.
        derivationKind              = try c.decodeIfPresent(String.self, forKey: .derivationKind)
        trimInSeconds               = try c.decodeIfPresent(Double.self, forKey: .trimInSeconds)
        trimOutSeconds              = try c.decodeIfPresent(Double.self, forKey: .trimOutSeconds)
        // Estimated date (GH #117) — same additive-optional migration
        // pattern: legacy catalogs (no keys) decode as nil = unconfirmed.
        userDate                    = try c.decodeIfPresent(String.self, forKey: .userDate)
        userDateConfidence          = try c.decodeIfPresent(String.self, forKey: .userDateConfidence)
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
