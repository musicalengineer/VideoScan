// ArchiveAngelScorer.swift
// Archive Angel — Stage 1 candidate selection (docs/archive_angel_design.md §3).
//
// PURE CORE. Takes Sendable inputs projected from VideoRecord, returns a
// verdict per candidate: eligible with a score AND the evidence lines that
// produced it, or rejected with the hard-floor reason. The number only
// orders the list; the lines are what the user reads in the review sheet.
// Machines write evidence, humans decide (project rule). No media I/O here,
// no main-actor access — table-testable and O(candidates).
//
// Rick 2026-09-09: candidates = important-but-unarchived; importance from
// stars, people, dates, play history ("a lot of play"), metadata richness
// ("a lot of metadata"); never junk ("transitions, weird teeny bits").

import Foundation
import VideoScanCore

// MARK: - Inputs

/// One catalog record as the scorer sees it. Built by
/// `ArchiveAngelCandidate.init(record:...)` on the main actor; everything
/// here is a value so the walk can run off-main.
struct ArchiveAngelCandidate: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var fullPath: String
    var sizeBytes: Int64
    var durationSeconds: Double
    var streamTypeRaw: String
    var isPlayable: String
    var starRating: Int
    var mediaDisposition: MediaDisposition
    var archiveStage: ArchiveStage
    var junkScore: Int
    var confirmedPeople: [String]
    var detectedPeople: [String]
    var suspectedPeople: [String]
    var hasUserNotes: Bool
    var tagCount: Int
    var hasCaptions: Bool
    var hasOCRText: Bool
    var hasEmbeddedDate: Bool
    var hasTapeOrClipName: Bool
    var userDate: String?
    var inferredRecordDate: Date?
    var inferredDateConfidence: Float?
    var formatAtRisk: Bool
    var audioProblem: String?
    /// True when this record is one half of a correlated MXF pair — the
    /// Combine output is the candidate, never the half.
    var isPairedHalf: Bool
    /// True when a duplicate of this file already sits in the archive.
    var hasArchivedDuplicate: Bool
    /// True when the file has no duplicate anywhere (single copy).
    var isOnlyCopy: Bool
    /// Volume role of the file's current home.
    var volumeRole: VolumeRole
    var volumeName: String
    var volumeOnline: Bool
    var isOnMasterArchive: Bool
    /// Spotlight `kMDItemUseCount` / in-app play count, whichever is larger.
    var useCount: Int
    var lastUsed: Date?
    /// ffprobe codec name ("dvvideo", "prores", "h264", "mpeg4"…) — T10 H1:
    /// delivery codecs at download rates are rips, preservation codecs never are.
    var videoCodec: String
    /// Catalog duplicate group — T10 H2: one member per group per batch.
    var duplicateGroupID: UUID?
    /// T10 H3: the filename of the ORIGINAL this file was exported from,
    /// when that original is in the catalog (set by `markDerivatives`);
    /// nil for an original, or for an export whose source is gone.
    var derivativeOfOriginal: String?
    /// The ledger's family key for this content ("h:…" / "p:…" / "");
    /// attention is looked up by record id AND content key.
    var contentKey: String
    /// Phase 1 attention memory (docs/archive_angel_curation_direction.md):
    /// what the Angel has already shown this person about this file.
    var attention: ArchiveAngelAttention
    /// Effective skips of the OTHER members of this file's event family
    /// (set by `applyFamilyAttention`, one O(n) pass); half of it counts
    /// against this file. 0 when the pass has not run.
    var familySkips: Double
    /// Device model from the container tags (`VideoRecord.originModel`:
    /// `model` / `com.apple.quicktime.model`, e.g. "iPhone 12"); "" when
    /// the file carries none. Read by the recent-phone-clip floor.
    var deviceModel: String
    /// The capture date stamped in the container
    /// (`VideoRecord.embeddedCreationDate` — QuickTime creationdate /
    /// creation_time, survives copies). NOT `dateCreated`, which on a
    /// Photos-library export is the COPY date. nil = no usable tag.
    var captureDate: Date?
    /// Consolidation S3 (2026-09-22) — the facts the recommendation
    /// classifier's rules read that the scorer never needed: the catalog's
    /// duplicate bookkeeping (how many members the group has, and the
    /// person's Keep / Extra copy choice) and the date provenance
    /// RecordDateResolver takes (ArchiveAngelRecommendations' date rule).
    /// Additive, defaulted — nothing here changes a score.
    var duplicateGroupCount: Int
    var duplicateDisposition: DuplicateDisposition
    var userDateConfidence: String?
    var originMake: String?
    var originEncoder: String?

    /// Rick 2026-09-21: a Live Photo's motion half
    /// (`jpegvideocomplement_*.mov`, ~3 s) is part of a photo, not a video.
    var isLivePhotoMotion: Bool {
        filename.lowercased().hasPrefix("jpegvideocomplement")
    }

    /// A clip shot on an iPhone/iPad: the device tag says so, or the file
    /// lives inside a Photos library bundle.
    var isPhoneClip: Bool {
        let model = deviceModel.lowercased()
        return model.contains("iphone") || model.contains("ipad")
            || fullPath.lowercased().contains(".photoslibrary/")
    }

    /// The event family this file belongs to (folder + base stem, share-out
    /// and derivative tokens stripped) — one member per batch. Filled by
    /// `applyFamilyAttention` (one regex pass per candidate); computed on
    /// demand when that pass has not run (the evidence path's few picks).
    var familyKey: String
    var resolvedFamilyKey: String {
        familyKey.isEmpty ? ArchiveAngelFamily.key(filename: filename, fullPath: fullPath) : familyKey
    }
    /// "Fresh eyes": never proposed, and no variant of it was passed on.
    var isFreshToPerson: Bool { attention.isNew && familySkips == 0 }

    /// A person's word on this file: a star, a confirmed person, a note they
    /// typed (machine text in userNotes is filtered by the projection) or a
    /// user date. Machine floors and caps yield to it.
    var isHumanMarked: Bool {
        starRating > 0 || !confirmedPeople.isEmpty || hasUserNotes || !(userDate ?? "").isEmpty
    }

    /// The year a person or the date consensus put on this file — the
    /// user's date first ("1992-07-15", "1992-07", "1992"), else the
    /// inferred record date (UTC). nil when neither is known. T10 H3 uses
    /// it to relate an export to an original in a sibling folder.
    var knownYear: Int? {
        if let u = userDate, u.count >= 4, let y = Int(u.prefix(4)), y > 1800 { return y }
        guard let d = inferredRecordDate else { return nil }
        return Self.utcCalendar.component(.year, from: d)
    }
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }()

    init(id: UUID = UUID(), filename: String = "clip.mov", fullPath: String = "/Volumes/X/clip.mov",
         sizeBytes: Int64 = 1_000_000_000, durationSeconds: Double = 120,
         streamTypeRaw: String = StreamType.videoAndAudio.rawValue, isPlayable: String = "Yes",
         starRating: Int = 0, mediaDisposition: MediaDisposition = .unreviewed,
         archiveStage: ArchiveStage = .none, junkScore: Int = 0,
         confirmedPeople: [String] = [], detectedPeople: [String] = [], suspectedPeople: [String] = [],
         hasUserNotes: Bool = false, tagCount: Int = 0, hasCaptions: Bool = false, hasOCRText: Bool = false,
         hasEmbeddedDate: Bool = false, hasTapeOrClipName: Bool = false,
         userDate: String? = nil, inferredRecordDate: Date? = nil, inferredDateConfidence: Float? = nil,
         formatAtRisk: Bool = false, audioProblem: String? = nil,
         isPairedHalf: Bool = false, hasArchivedDuplicate: Bool = false, isOnlyCopy: Bool = false,
         volumeRole: VolumeRole = .workspace, volumeName: String = "X", volumeOnline: Bool = true,
         isOnMasterArchive: Bool = false, useCount: Int = 0, lastUsed: Date? = nil,
         videoCodec: String = "", duplicateGroupID: UUID? = nil, derivativeOfOriginal: String? = nil,
         contentKey: String = "", attention: ArchiveAngelAttention = .none, familySkips: Double = 0,
         familyKey: String = "", deviceModel: String = "", captureDate: Date? = nil,
         duplicateGroupCount: Int = 0, duplicateDisposition: DuplicateDisposition = .none,
         userDateConfidence: String? = nil, originMake: String? = nil, originEncoder: String? = nil) {
        self.id = id; self.filename = filename; self.fullPath = fullPath; self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds; self.streamTypeRaw = streamTypeRaw; self.isPlayable = isPlayable
        self.starRating = starRating; self.mediaDisposition = mediaDisposition; self.archiveStage = archiveStage
        self.junkScore = junkScore; self.confirmedPeople = confirmedPeople; self.detectedPeople = detectedPeople
        self.suspectedPeople = suspectedPeople; self.hasUserNotes = hasUserNotes; self.tagCount = tagCount
        self.hasCaptions = hasCaptions; self.hasOCRText = hasOCRText; self.hasEmbeddedDate = hasEmbeddedDate
        self.hasTapeOrClipName = hasTapeOrClipName; self.userDate = userDate
        self.inferredRecordDate = inferredRecordDate; self.inferredDateConfidence = inferredDateConfidence
        self.formatAtRisk = formatAtRisk; self.audioProblem = audioProblem; self.isPairedHalf = isPairedHalf
        self.hasArchivedDuplicate = hasArchivedDuplicate; self.isOnlyCopy = isOnlyCopy
        self.volumeRole = volumeRole; self.volumeName = volumeName; self.volumeOnline = volumeOnline
        self.isOnMasterArchive = isOnMasterArchive; self.useCount = useCount; self.lastUsed = lastUsed
        self.videoCodec = videoCodec; self.duplicateGroupID = duplicateGroupID
        self.derivativeOfOriginal = derivativeOfOriginal
        self.contentKey = contentKey; self.attention = attention; self.familySkips = familySkips
        self.familyKey = familyKey
        self.deviceModel = deviceModel; self.captureDate = captureDate
        self.duplicateGroupCount = duplicateGroupCount; self.duplicateDisposition = duplicateDisposition
        self.userDateConfidence = userDateConfidence; self.originMake = originMake
        self.originEncoder = originEncoder
    }
}

// MARK: - Outputs

/// One printed reason. `points` is shown in the expanded view only.
struct ArchiveAngelEvidence: Sendable, Equatable, Codable {
    var points: Int
    var line: String
}

/// Why a record never made the list. Reported as counts per reason so the
/// user can see the floor working (design §3.2, §6).
enum ArchiveAngelRejection: String, Sendable, Codable, CaseIterable {
    case notVideo = "Not a video"
    case alreadyArchived = "Already in the archive"
    case duplicateArchived = "A copy is already in the archive"
    case volumeOffline = "Volume offline"
    case tooShort = "Too short (under 2 min — short clips are usually pieces of a longer original)"
    case livePhotoMotion = "Live Photo motion (part of a photo, not a video)"
    case recentPhoneClip = "Phone clip under 10 years old (Rick 2026-09-21: only older phone clips are worth archiving)"
    case junk = "Marked junk"
    case suspectedJunk = "Looks like junk (machine evidence, unrated)"
    case notPlayable = "Not playable / un-probeable"
    case pairedHalf = "Half of an A/V pair — combine first"
    /// Job-level, not a scorer floor: the record is already sitting in a
    /// batch that is preparing, ready or promoting (Rick 2026-09-10: "click
    /// Assess 10, come back 5 minutes later and click Assess 10" must
    /// bring the NEXT ten, not the same ten again).
    case inAnotherBatch = "Already in a prepared batch"
    /// Rick 2026-09-10: iMovie's "iMovie Cache/Cache.mov" and "iMovie Movie
    /// Cache/Cache-30.mov" scored 120 — 2 h 39 min "whole tapes" that are
    /// 5 MB thumbnail streams. Name/folder rule + a bytes-per-second sanity
    /// floor no real original can fail.
    /// T10 H2 (night of 2026-09-10): the live top 50 carried four duplicate
    /// pairs (the same tape under two names on two volumes) — both halves
    /// would have been promoted. One member per catalog duplicate group per
    /// batch: the best-ranked stays, the rest are counted here.
    case duplicateOfPick = "Same content as another pick (duplicate group) — one copy is enough"
    /// T10 H3: `_balanced`, `.vs.edit`, `_NV12`, `_trimmed`… beside its
    /// original. The Angel makes its own companions at Promote; the original
    /// is the archive candidate. Only when the original IS in the catalog.
    case derivativeOfOriginal = "A derivative export — its original is in the catalog"
    case appCache = "An app's cache / render file (name or folder), not an original"
    case proxyStream = "Too small for its length — a thumbnail or proxy stream, not the original"
    /// Phase 1 attention memory (2026-09-19): the person passed on this
    /// file three times (skips, half-weight clears, old skips at half) —
    /// it rests for 90 days from the last pass, then comes back. Explicit
    /// "Prepare with Archive Angel" picks ignore this.
    case resting = "Resting — you passed on it three times; it comes back 90 days after the last pass"
    /// One member of an event family per batch: the variants of a pick
    /// ("_fixedup", "_clip1", "part 2" beside it) wait for a later batch.
    case sameFamilyAsPick = "A variant of another pick (same event family) — one per batch"
    /// Consolidation S3b: a `match` floor Rick wrote in policy.json with no
    /// built-in reason named; the evidence carries the rule's own words
    /// (`ArchiveAngelEvidenceRecord.excludedBy`).
    case policyRule = "Excluded by a rule in your recommendation policy"
    /// Consolidation S3b: Relocate's terminal stages (Manually Deleted,
    /// Salvage Failed) — the file is gone. v10 excluded these only by
    /// accident (they sort after Master, and "stage ≥ Master" meant
    /// archived); the default policy now names them (floor `fileGone`).
    case fileGone = "The file was deleted or could not be salvaged (its stage says so)"
    /// QA on S3 (2026-09-22): the person marked this copy an Extra copy —
    /// the Keep copy of the same recording is the one to archive.
    case extraCopy = "Marked an extra copy — the Keep copy is the one to archive"
    /// QA on S3: Prepare takes only the classes the policy prepares
    /// (`recommend.prepare`: Ready, then Worth a look by default).
    case notRecommendedNow = "Not in a class the Angel prepares now (Not now, Needs a date, Another copy)"
}

extension ArchiveAngelRejection {
    /// The reasons a SAFETY floor gives (AngelPolicyDefaults.safetyFloorIDs):
    /// a file excluded for one of these is never recommended, whatever the
    /// class rules say — `useAngelFloors: false` included.
    static let safetyReasons: Set<ArchiveAngelRejection> = [
        .notVideo, .alreadyArchived, .duplicateArchived, .fileGone, .volumeOffline,
    ]
}

enum ArchiveAngelVerdict: Sendable, Equatable {
    case eligible(score: Int, evidence: [ArchiveAngelEvidence])
    case rejected(ArchiveAngelRejection)
}

struct ArchiveAngelPick: Sendable, Equatable, Identifiable {
    var candidate: ArchiveAngelCandidate
    var score: Int
    var evidence: [ArchiveAngelEvidence]
    var id: UUID { candidate.id }
}

struct ArchiveAngelSelection: Sendable, Equatable {
    var picks: [ArchiveAngelPick]
    /// Eligible but beyond `count` — reported as "N more would qualify".
    var overflow: Int
    var rejected: [ArchiveAngelRejection: Int]
    var rejectedTotal: Int { rejected.values.reduce(0, +) }
}

// MARK: - Weights (one table; tune here, never in the logic)
//
// Since S3b the numbers live in the recommendation policy
// (AngelRecommendationPolicy.weights, policy.json); `.standard` is the
// built-in value. WHICH floors and signals run, in what order, and any rule
// Rick adds, are the policy's `floors` / `signals` arrays.

struct ArchiveAngelWeights: Sendable, Equatable, Codable {
    var threeStars = 100
    var twoStars = 40
    var oneStar = 10
    var confirmedPersonEach = 25
    var confirmedPersonCap = 75
    var machinePersonEach = 8
    var machinePersonCap = 24
    var playHistoryCap = 40
    var playedRecentlyBonus = 5
    /// Play history points = this × log2(1 + plays), capped at
    /// `playHistoryCap` (S3b: was a literal 4).
    var playHistoryPerDoubling = 4.0
    /// A play within this many days earns `playedRecentlyBonus` (S3b: was
    /// a literal 365).
    var playedRecentlyDays = 365.0
    var richnessEach = 5
    var richnessCap = 40
    var dateKnown = 20
    var dateLowConfidence = 5
    var formatAtRisk = 15
    var onlyCopy = 15
    var riskyVolume = 10
    /// Duration tiers — Rick 2026-09-10: "usually there's a longer video of
    /// the whole scene … and a 60 s or less clip is just a small edit I made
    /// to send to someone. We need to archive the originals and/or the long
    /// versions, not these tiny segments." A whole DV tape is 60 min, a
    /// half tape 30; anything that long is almost certainly the capture,
    /// not an edit, so length is the strongest machine signal of
    /// "this is the whole thing".
    var durationWholeTape = 60        // ≥ 60 min
    var durationHalfTape = 45         // 30 – 60 min
    var durationLongScene = 25        // 15 – 30 min
    var durationScene = 10            // 5 – 15 min
    var wholeTapeSeconds = 3600.0
    var halfTapeSeconds = 1800.0
    var longSceneSeconds = 900.0
    var sceneSeconds = 300.0
    /// Hard floor for EVERY automatically proposed clip, marked or not.
    /// Rick 2026-09-10: "exclude short videos under 1 minute for now …
    /// we'll keep these short videos in the catalog". (Earlier: 60 s
    /// unmarked / 30 s marked; the marked exception let a starred 35 s
    /// Cape edit through, which is exactly the kind of clip whose long
    /// original should be picked instead.)
    /// Rick 2026-09-21 raised it to 2 min: "I am hitting a lot of short
    /// clips that won't be useful … 90% of the time these are partials
    /// from longer sequences (iMovie diced it up, I diced it up, or the
    /// boys did on the old Cheesegrater)." Catalog that day (unarchived
    /// video): 8,522 files under 5 min held only 51 h; 281 files of
    /// 20 min+ held 291 h of 417 h. Short clips stay in the catalog.
    var minimumDurationSeconds = 120.0
    /// The floor for an EXPLICIT pick ("Prepare with Archive Angel" on a
    /// catalog selection) — deliberately left at the pre-2026-09-21 value
    /// so raising the automatic floor does not change what Rick can hand
    /// the Angel himself. See `ArchiveAngelJob.explicitSelection`.
    var explicitPickMinimumDurationSeconds = 60.0
    /// Rick 2026-09-21: "ignore iphone clips unless > 10 years old". That
    /// day 3,159 of 9,404 catalog videos were Live Photo motion halves.
    /// Both rules govern AUTOMATIC proposals only; an explicit pick turns
    /// them off (`ArchiveAngelJob.explicitSelection`). A star does not
    /// exempt a file — same as the duration floor.
    var excludeLivePhotoMotion = true
    var excludeRecentPhoneClips = true
    /// A phone clip whose capture date is less than this many years
    /// before `now` is excluded; one with NO known capture date is treated
    /// as recent (the catalog cannot prove it is old).
    var recentPhoneClipYears = 10
    var junkFloor = 5
    var dateConfidenceKnown: Float = 0.8
    /// Average bitrate floor for anything a minute or longer. DV is
    /// 25 Mbit/s, a poor web clip 300 kbit/s, iMovie's thumbnail stream
    /// under 5 kbit/s — 100 kbit/s separates them by two orders either way.
    var minimumAverageKilobitsPerSecond = 100.0
    /// T10 H1 (night of 2026-09-10): the live top 50 held 15 commercial films
    /// and 6 downloads — h264/DivX at 0.6–3.5 Mbit/s over 1–3 h, scoring
    /// 103–113 on length alone. A family original is DV/ProRes/FFV1/MPEG-2/
    /// SVQ3 at any rate, or h264 at 20+ Mbit/s from a camera. An UNMARKED
    /// delivery-codec file under this rate and over this length is capped
    /// at grade C — never rejected, never applied to a starred file.
    var downloadMaxKilobitsPerSecond = 4000.0
    var downloadMinimumDurationSeconds = 1200.0
    var downloadCapScore = 59
    /// Phase 1 attention memory (docs/archive_angel_curation_direction.md,
    /// 2026-09-19). Starting guesses; ArchiveAngelCurationSimulationTests
    /// is the instrument that tunes them.
    /// score × fatigueFactor^effectiveSkips. 0.5: a 200-point favourite
    /// skipped once scores 100, twice 50 — real files get their turn.
    var fatigueFactor = 0.5
    /// Effective skips at which the file rests (excluded) …
    var restAfterSkips = 3.0
    /// … for this many days after the last pass.
    var restDays = 90.0
    /// A skip older than this counts `oldSkipWeight` instead of 1.
    var oldSkipAfterDays = 90.0
    var oldSkipWeight = 0.5
    /// A cleared (undecided) batch counts this much of a skip per row.
    var clearWeight = 0.5
    /// Members of one event family carry this share of each other's skips.
    var familySkipShare = 0.5
    /// Share of a batch reserved for never-proposed files that clear
    /// `freshMinimumScore` — 3 of 10.
    var freshShare = 0.3
    var freshMinimumScore = 25

    static let standard = ArchiveAngelWeights()
}

// MARK: - Scorer

enum ArchiveAngelScorer {

    /// Bump whenever the weights, the floor or the evidence lines change.
    /// The assessment sidecar is stamped with it; a mismatch on load means
    /// "assessed under old rules" and the sweep re-scores at once (Rick
    /// 2026-09-10: "this will require updated assessments as we refine
    /// selection criteria"). 2 = flat 60 s floor + duration tiers; 3 = app-cache
    /// and proxy-stream floors; 4 = download/rip cap (T10 H1); 6 = one per
    /// duplicate group + "most original" codec tie-break (T10 H2) and
    /// derivative exports yield to a RELATED original (T10 H3) — one bump
    /// for the pair, 5 was never shipped; 7 = the projection's
    /// `archivedCopyExists` follows provenance (a version of something
    /// archived is excluded, codex #1345) — v6 sidecars still grade such
    /// versions A/B, so they must rescore; 8 = attention memory (novelty,
    /// fatigue, resting, family share — Phase 1 of the curation plan);
    /// 9 = the evidence record carries `familySkips` and the file is
    /// stamped with the attention revision it was scored under (codex
    /// 2026-09-20 #5/#6) — a v8 sidecar lacks both, so it must rescore;
    /// 10 = 2-minute floor (Rick 2026-09-21), plus the Live Photo motion
    /// and recent-phone-clip exclusions (same day, same bump); 11 = the
    /// floors and signals are the policy's rule arrays, archiveStage
    /// Ready/Master is a VOTE (no longer "already archived" — Rick
    /// 2026-09-22), and every record carries its recommendation class
    /// (Consolidation S3b).
    static let rulesVersion = 11

    /// The verdict for one record under the built-in rules with these
    /// weights. Pure.
    static func verdict(_ c: ArchiveAngelCandidate,
                        weights w: ArchiveAngelWeights = .standard,
                        now: Date = Date()) -> ArchiveAngelVerdict {
        verdict(c, policy: AngelRecommendationPolicy.builtIn.with(weights: w), now: now)
    }

    /// The verdict for one record: the policy's floors in order (first hit
    /// rejects), then its signals in order — each an evidence line; the
    /// score is their sum. Pure.
    static func verdict(_ c: ArchiveAngelCandidate, policy p: AngelRecommendationPolicy,
                        now: Date = Date()) -> ArchiveAngelVerdict {
        if let hit = floorHit(c, policy: p, now: now) { return .rejected(hit.rejection) }
        var lines: [ArchiveAngelEvidence] = []
        p.signals.withUnsafeBufferPointer { buffer in
            guard let signals = buffer.baseAddress else { return }
            for i in 0..<buffer.count {
                guard signals[i].enabled, let kind = signals[i].resolvedKind else { continue }
                if !signals[i].when.isEmpty {
                    var ctx = AngelEvalContext(now: now)
                    guard AngelCondition.all(signals[i].when, c, &ctx) else { continue }
                }
                if let line = signal(kind, rule: signals[i], c, lines: lines, policy: p, now: now) { lines.append(line) }
            }
        }
        return .eligible(score: Self.total(lines), evidence: lines)
    }

    /// Phase 1: `score × fatigueFactor^effectiveSkips`, where the family's
    /// skips count `familySkipShare`. Printed as one negative line
    /// ("Skipped by you twice — score halved twice") so the person sees
    /// why a favourite fell. nil when nothing was ever passed on.
    static func fatigueLine(_ c: ArchiveAngelCandidate, lines: [ArchiveAngelEvidence],
                            weights w: ArchiveAngelWeights, now: Date) -> ArchiveAngelEvidence? {
        let own = c.attention.effectiveSkips(now: now, weights: w)
        let shared = w.familySkipShare * c.familySkips
        let effective = own + shared
        guard effective > 0 else { return nil }
        let total = Self.total(lines)
        guard total > 0 else { return nil }
        let factor = pow(w.fatigueFactor, effective)
        let points = Self.sum(Self.clampedInt((Double(total) * factor).rounded()), -total)
        guard points < 0 else { return nil }
        var line: String
        switch c.attention.timesSkipped {
        case 0: line = "You passed on it"
        case 1: line = "You skipped it once"
        case 2: line = "You skipped it twice"
        default: line = "You skipped it \(c.attention.timesSkipped) times"
        }
        if c.attention.timesCleared > 0 {
            line += c.attention.timesSkipped == 0
                ? " (a batch cleared \(c.attention.timesCleared == 1 ? "once" : "\(c.attention.timesCleared) times") undecided)"
                : " and cleared a batch \(c.attention.timesCleared == 1 ? "once" : "\(c.attention.timesCleared) times")"
        }
        if shared > 0 { line += own > 0 ? ", and passed on its variants" : "'s variants" }
        if let last = c.attention.lastSkippedAt { line += ", last on " + Self.dayFormatter.string(from: last) }
        line += String(format: " — score × %.2f", factor)
        return .init(points: points, line: line)
    }

    /// T10 H1: a download or rip can reach the top on length alone; cap it
    /// at candidate grade unless a human has marked it. A negative line, so
    /// the score is still the sum of its printed reasons. nil = no cap.
    static func downloadCapLine(_ c: ArchiveAngelCandidate, lines: [ArchiveAngelEvidence],
                                weights w: ArchiveAngelWeights) -> ArchiveAngelEvidence? {
        downloadCapLine(c, lines: lines, policy: AngelRecommendationPolicy.builtIn.with(weights: w))
    }

    static func downloadCapLine(_ c: ArchiveAngelCandidate, lines: [ArchiveAngelEvidence],
                                policy p: AngelRecommendationPolicy) -> ArchiveAngelEvidence? {
        let w = p.weights
        guard !c.isHumanMarked, looksLikeDownloadOrRip(c, policy: p) else { return nil }
        let total = Self.total(lines)
        guard total > w.downloadCapScore else { return nil }
        let kbps = Self.clampedInt((Double(c.sizeBytes) * 8 / c.durationSeconds / 1000).rounded())
        return .init(points: Self.sum(w.downloadCapScore, -total),
                     line: "Looks like a download or rip — \(c.videoCodec) at \(kbps) kbit/s for "
                        + durationText(c.durationSeconds) + ", no star, person or note; capped at candidate grade")
    }

    /// Hard floor (design §3.2) under the built-in floors with these weights.
    static func hardFloor(_ c: ArchiveAngelCandidate,
                          weights w: ArchiveAngelWeights = .standard,
                          now: Date = Date()) -> ArchiveAngelRejection? {
        floorHit(c, policy: AngelRecommendationPolicy.builtIn.with(weights: w), now: now)?.rejection
    }

    /// The reason a record is never a candidate under `p`, or nil.
    static func hardFloor(_ c: ArchiveAngelCandidate, policy p: AngelRecommendationPolicy,
                          now: Date = Date()) -> ArchiveAngelRejection? {
        floorHit(c, policy: p, now: now)?.rejection
    }

    /// True when `captureDate` is within `years` of `now`, or unknown
    /// (nil) — an undated phone clip cannot be shown to be old. Pure.
    static func isRecent(captureDate: Date?, years: Int, now: Date) -> Bool {
        guard let captured = captureDate else { return true }
        guard let cutoff = ArchiveAngelCandidate.utcCalendar.date(byAdding: .year, value: -years, to: now) else {
            return false
        }
        return captured > cutoff
    }

    /// Score every candidate, sort by `rank`, keep one member per duplicate
    /// group, take `count`.
    static func select(_ candidates: [ArchiveAngelCandidate], count: Int,
                       weights w: ArchiveAngelWeights = .standard,
                       now: Date = Date()) -> ArchiveAngelSelection {
        select(candidates, count: count, policy: AngelRecommendationPolicy.builtIn.with(weights: w), now: now)
    }

    /// `byClass` (Prepare Batch, QA on S3): classify the set with the
    /// policy's `recommend` rules and take only the classes it prepares,
    /// class first (Ready, then Worth a look…), then rank — so the batch
    /// agrees with the numbers the Archive tab shows. Off = score order
    /// over every eligible record (the pure scorer, and its pins).
    static func select(_ candidates: [ArchiveAngelCandidate], count: Int,
                       policy p: AngelRecommendationPolicy,
                       now: Date = Date(), byClass: Bool = false) -> ArchiveAngelSelection {
        let w = p.weights
        var picks: [ArchiveAngelPick] = []
        picks.reserveCapacity(candidates.count)
        var rejected: [ArchiveAngelRejection: Int] = [:]
        var evidence: [UUID: ArchiveAngelEvidenceRecord] = [:]
        for c in candidates {
            switch verdict(c, policy: p, now: now) {
            case .eligible(let score, let lines):
                picks.append(.init(candidate: c, score: score, evidence: lines))
                if byClass, !p.recommend.prepare.isEmpty {
                    evidence[c.id] = .init(score: score, lines: [], rejection: nil, useCount: 0, lastUsed: nil,
                                           computedAt: now, bands: p.grades)
                }
            case .rejected(let reason):
                rejected[reason, default: 0] += 1
                if byClass, !p.recommend.prepare.isEmpty {
                    evidence[c.id] = .init(score: 0, lines: [], rejection: reason, useCount: 0, lastUsed: nil, computedAt: now)
                }
            }
        }
        let tables = p.tables
        var order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = { rank($0, $1, tables: tables) }
        if byClass, !p.recommend.prepareClasses.isEmpty {
            let result = ArchiveAngelRecommendations.classify(candidates, evidence: evidence, rules: p.recommend, now: now)
            var tier: [UUID: Int] = [:]
            let prepare = p.recommend.prepareClasses
            for (i, v) in result.verdicts.enumerated() {
                if let t = prepare.firstIndex(of: v.kind) { tier[candidates[i].id] = t }
            }
            let before = picks.count
            picks = picks.filter { tier[$0.id] != nil }
            if before > picks.count { rejected[.notRecommendedNow, default: 0] += before - picks.count }
            order = { a, b in
                let ta = tier[a.id] ?? .max, tb = tier[b.id] ?? .max
                return ta != tb ? ta < tb : rank(a, b, tables: tables)
            }
        }
        picks.sort(by: order)
        picks = onePerDuplicateGroup(picks, rejected: &rejected)
        picks = onePerFamily(picks, rejected: &rejected)
        let kept = withFreshSlots(picks, count: max(0, count), weights: w, by: order)
        return .init(picks: kept, overflow: max(0, picks.count - kept.count), rejected: rejected)
    }

    /// Phase 1: one member per EVENT FAMILY per batch (the generalised
    /// duplicateOfPick — "one Thanksgiving variant per batch"). `picks`
    /// must be in `rank` order; the best member stays, the rest are
    /// counted under `.sameFamilyAsPick`. Pure.
    static func onePerFamily(_ picks: [ArchiveAngelPick],
                             rejected: inout [ArchiveAngelRejection: Int]) -> [ArchiveAngelPick] {
        var seen: Set<String> = []
        return picks.filter { pick in
            if seen.insert(pick.candidate.resolvedFamilyKey).inserted { return true }
            rejected[.sameFamilyAsPick, default: 0] += 1
            return false
        }
    }

    /// Phase 1's explore arm: of `count` slots, `ceil(count × freshShare)`
    /// go to never-proposed files scoring at least `freshMinimumScore`.
    /// The head of `ranked` (already in `rank` order, deduplicated) is
    /// taken; if it holds too few new files, the lowest-ranked ALREADY-
    /// PROPOSED picks in it make room for the best new files beyond it.
    /// When there are no such new files the head stands. The result is in
    /// `rank` order. Pure.
    static func withFreshSlots(_ ranked: [ArchiveAngelPick], count: Int,
                               weights w: ArchiveAngelWeights = .standard,
                               by order: (ArchiveAngelPick, ArchiveAngelPick) -> Bool = rank) -> [ArchiveAngelPick] {
        guard count > 0 else { return [] }
        var head = Array(ranked.prefix(count))
        let wanted = min(count, Int((Double(count) * w.freshShare).rounded(.up)))
        let newInHead = head.filter { $0.candidate.isFreshToPerson }.count
        if ranked.count > count, newInHead < wanted {
            let incoming = ranked.dropFirst(count)
                .filter { $0.candidate.isFreshToPerson && $0.score >= w.freshMinimumScore }
                .prefix(wanted - newInHead)
            if !incoming.isEmpty {
                var toRemove = incoming.count
                var i = head.count - 1
                while toRemove > 0, i >= 0 {
                    if !head[i].candidate.isFreshToPerson { head.remove(at: i); toRemove -= 1 }
                    i -= 1
                }
                head.append(contentsOf: incoming)
                head.sort(by: order)
            }
        }
        // The person reads why a file is here: a 0-point line, never a grade.
        for i in head.indices where head[i].candidate.isFreshToPerson
            && !head[i].evidence.contains(where: { $0.line == freshLine }) {
            head[i].evidence.append(.init(points: 0, line: freshLine))
        }
        return head
    }

    static let freshLine = "New to you — never proposed"


    /// Phase 1: one O(n) pass that gives every member of an event family
    /// the OTHER members' effective skips (`familySkips`), so a variant of
    /// a file the person passed on is not "new". Run after the projection
    /// and before scoring, like `markDerivatives`.
    static func applyFamilyAttention(_ candidates: inout [ArchiveAngelCandidate],
                                     weights w: ArchiveAngelWeights = .standard,
                                     now: Date = Date()) {
        var own: [Double] = []
        own.reserveCapacity(candidates.count)
        var keys: [String] = []
        keys.reserveCapacity(candidates.count)
        var totals: [String: Double] = [:]
        for c in candidates {
            let skips = c.attention.effectiveSkips(now: now, weights: w)
            let key = c.resolvedFamilyKey
            own.append(skips)
            keys.append(key)
            if skips > 0 { totals[key, default: 0] += skips }
        }
        for i in candidates.indices {
            candidates[i].familyKey = keys[i]
            let others = (totals[keys[i]] ?? 0) - own[i]
            candidates[i].familySkips = others > 0 ? others : 0
        }
    }

    // MARK: ranking (ONE comparator — the walk and the evidence pick both use it)

    /// The batch order. Score first; then Rick's "most original" preference
    /// (2026-09-11: "pick the best format or most original … if the codec
    /// is old, it is more original"); then older date (older tape is at
    /// more risk), longer (more likely the whole capture), larger file
    /// (more to lose), then name. Pure, strict weak ordering — safe for
    /// `sort`. Both selection paths MUST rank with this so an equal-score
    /// duplicate group keeps the same member whichever path ran.
    static func rank(_ a: ArchiveAngelPick, _ b: ArchiveAngelPick) -> Bool {
        rank(a.candidate, score: a.score, before: b.candidate, score: b.score)
    }

    /// The same order with the policy's originality table.
    static func rank(_ a: ArchiveAngelPick, _ b: ArchiveAngelPick, tables: AngelPolicyTables) -> Bool {
        rank(a.candidate, score: a.score, before: b.candidate, score: b.score, tables: tables)
    }

    /// The same comparator over (candidate, score) pairs — the
    /// recommendation classifier's "angelRank" order uses it, so the lists
    /// and the batch pick can never disagree about who goes first.
    static func rank(_ a: ArchiveAngelCandidate, score sa: Int,
                     before b: ArchiveAngelCandidate, score sb: Int,
                     tables: AngelPolicyTables = .standard) -> Bool {
        if sa != sb { return sa > sb }
        let ao = originalityRank(a.videoCodec, tables: tables), bo = originalityRank(b.videoCodec, tables: tables)
        if ao != bo { return ao < bo }
        let ad = a.inferredRecordDate ?? .distantFuture
        let bd = b.inferredRecordDate ?? .distantFuture
        if ad != bd { return ad < bd }
        if a.durationSeconds != b.durationSeconds { return a.durationSeconds > b.durationSeconds }
        if a.sizeBytes != b.sizeBytes { return a.sizeBytes > b.sizeBytes }
        return a.filename < b.filename
    }

    /// "Most original" order of ffprobe codec names, 0 = most original. A
    /// camera/tape codec (DV, MJPEG, MPEG-2/HDV) is the capture itself; a
    /// preservation codec (ProRes, FFV1) is a faithful transfer; MPEG-1 and
    /// SVQ3 are old exports; h264/hevc/mpeg4/vp9 are delivery re-encodes.
    /// Unknown (empty, un-probed) ranks last. Only a TIE-BREAK — never
    /// worth points — so it decides between copies of the same score.
    /// Views onto the built-in table (AngelPolicyTables.standard — the
    /// policy's `tables.originality` since S3b).
    static var originalityTable: [String: Int] { AngelPolicyTables.standard.originality }
    static var originalityUnknown: Int { AngelPolicyTables.standard.originalityUnknown }

    static func originalityRank(_ videoCodec: String) -> Int {
        originalityRank(videoCodec, tables: .standard)
    }

    static func originalityRank(_ videoCodec: String, tables: AngelPolicyTables) -> Int {
        tables.originalityLower[videoCodec.lowercased()] ?? tables.originalityUnknown
    }

    /// T10 H2: one member per duplicate group. `picks` must already be in
    /// `rank` order, so the first member seen is the best; later members
    /// are counted under `.duplicateOfPick`, never silently dropped. Rows
    /// with no group never collapse.
    static func onePerDuplicateGroup(_ picks: [ArchiveAngelPick],
                                     rejected: inout [ArchiveAngelRejection: Int]) -> [ArchiveAngelPick] {
        // The one copy seam (ArchiveAngelCopyChooser), keyed by duplicate
        // group only — the batch never collapses by name. QA on S3: the
        // copy the person marked KEEP wins its group wherever it ranks
        // (the rest of the group still yields to it); otherwise the
        // best-ranked member, as before.
        let key = { (p: ArchiveAngelPick) in ArchiveAngelCopyChooser.key(p.candidate, collapseBy: ["duplicateGroup"]) }
        var keepers: [String: UUID] = [:]
        for p in picks where p.candidate.duplicateDisposition == .keep {
            if let k = key(p), keepers[k] == nil { keepers[k] = p.id }
        }
        let preferred = keepers.isEmpty ? picks : picks.filter { p in
            guard let k = key(p), let keeper = keepers[k] else { return true }
            return p.id == keeper
        }
        let out = ArchiveAngelCopyChooser.firstPerKey(preferred, key: key)
        let dropped = out.dropped + (picks.count - preferred.count)
        if dropped > 0 { rejected[.duplicateOfPick, default: 0] += dropped }
        return out.kept
    }

    // MARK: helpers

    /// T10 H3. One pass over a candidate set: an export (a stem carrying a
    /// derivative token, `ArchiveAngelNaming.derivativeBaseStem`) is marked
    /// with its original's filename when a RELATED, USABLE original is in
    /// the set. Related = same folder; else same duplicate group; else same
    /// grandparent folder AND the same known year (inferred or user date).
    /// Usable = passes the hard floor (online, playable, a video, not junk,
    /// not too short, not a cache) and runs at least 0.9 × the export (an
    /// original is not shorter than its export). Otherwise the export is
    /// left alone — it is the best copy the family has. codex #1306: the
    /// earlier any-folder fallback let "Clip 01" in another tree displace
    /// an unrelated export.
    ///
    /// O(n): originals are indexed under exact keys (folder|stem,
    /// group|stem, grandparent|year|stem), at most `maxOriginalsPerKey`
    /// per key, so 5,000 same-named "Clip 01" originals cost 8 compares per
    /// export, never n².
    static var maxOriginalsPerKey: Int { AngelPolicyTables.standard.maxOriginalsPerKey }

    static func markDerivatives(_ candidates: inout [ArchiveAngelCandidate],
                                weights w: ArchiveAngelWeights = .standard) {
        markDerivatives(&candidates, policy: AngelRecommendationPolicy.builtIn.with(weights: w))
    }

    static func markDerivatives(_ candidates: inout [ArchiveAngelCandidate], policy p: AngelRecommendationPolicy) {
        let maxOriginalsPerKey = p.tables.maxOriginalsPerKey
        var byFolder: [String: [Int]] = [:]        // "folder|stem" → indices
        var byGroup: [String: [Int]] = [:]         // "group|stem"  → indices
        var byGrandparent: [String: [Int]] = [:]   // "grandparent|year|stem" → indices
        func add(_ table: inout [String: [Int]], _ key: String, _ i: Int) {
            var list = table[key, default: []]
            guard list.count < maxOriginalsPerKey else { return }
            list.append(i)
            table[key] = list
        }
        // The base stem once per candidate (one regex pass, not two).
        let bases: [String?] = candidates.map {
            ArchiveAngelNaming.derivativeBaseStem(($0.filename as NSString).deletingPathExtension)?.lowercased()
        }
        for (i, c) in candidates.enumerated() {
            var probe = c
            probe.attention = .none                                          // a resting original is still the original
            guard bases[i] == nil,                                           // an export is never an original
                  c.derivativeOfOriginal == nil,
                  hardFloor(probe, policy: p) == nil else { continue }      // usable NOW
            let stem = (c.filename as NSString).deletingPathExtension.lowercased()
            let folder = (c.fullPath as NSString).deletingLastPathComponent
            add(&byFolder, folder + "|" + stem, i)
            if let g = c.duplicateGroupID { add(&byGroup, g.uuidString + "|" + stem, i) }
            if let year = c.knownYear {
                let grandparent = (folder as NSString).deletingLastPathComponent
                add(&byGrandparent, grandparent + "|\(year)|" + stem, i)
            }
        }
        for i in candidates.indices {
            guard let base = bases[i] else { continue }
            let export = candidates[i]
            let folder = (export.fullPath as NSString).deletingLastPathComponent
            var related: [Int] = byFolder[folder + "|" + base] ?? []
            if related.isEmpty, let g = export.duplicateGroupID { related = byGroup[g.uuidString + "|" + base] ?? [] }
            if related.isEmpty, let year = export.knownYear {
                let grandparent = (folder as NSString).deletingLastPathComponent
                related = byGrandparent[grandparent + "|\(year)|" + base] ?? []
            }
            guard let original = related.first(where: { j in
                j != i && candidates[j].durationSeconds >= 0.9 * export.durationSeconds
            }) else { continue }
            candidates[i].derivativeOfOriginal = candidates[original].filename
        }
    }

    /// The "Has notes, 2 tags, people…" items. `notes` means a HUMAN note
    /// (the projection filters machine text out of userNotes, T10 H1).
    static func richnessItems(_ c: ArchiveAngelCandidate) -> [String] {
        var richness: [String] = []
        if c.hasUserNotes { richness.append("notes") }
        if c.tagCount > 0 { richness.append(c.tagCount == 1 ? "1 tag" : "\(c.tagCount) tags") }
        if !c.confirmedPeople.isEmpty { richness.append("people") }
        if c.hasCaptions { richness.append("captions") }
        if c.hasOCRText { richness.append("on-screen text") }
        if c.inferredRecordDate != nil || c.userDate != nil { richness.append("date") }
        if c.hasEmbeddedDate { richness.append("camera date") }
        if c.hasTapeOrClipName { richness.append("tape/clip name") }
        if c.starRating > 0 { richness.append("rating") }
        return richness
    }

    /// Codecs a rip or a download arrives in — the built-in table
    /// (policy `tables.deliveryCodecs` since S3b). Preservation and camera
    /// codecs (dvvideo, prores, ffv1, mpeg2video, svq3, mjpeg…) are
    /// deliberately NOT listed: only the rate separates a phone hevc clip
    /// from a rip, and the rate rule keeps a 20 Mbit/s camera file clear.
    static var deliveryCodecs: Set<String> { AngelPolicyTables.standard.deliveryCodecSet }

    /// Folder components only a family's own editing leaves behind — an
    /// iMovie library or project, the "Family Movies" tree (policy
    /// `tables.familyOriginFolders`). A low-bitrate h264 export found there
    /// (live: EP1.m4v, 3 Mbit/s, "Ellen & Paul 1997/Original Media") is a
    /// family export, not a download.
    static var familyOriginPathMarkers: [String] { AngelPolicyTables.standard.familyOriginFolders }

    /// Whole folder components only (codex #1306 advisory): a component
    /// IS a marker, or ends with a package suffix (".imovielibrary",
    /// ".imovieproject") — never a substring of an unrelated folder name.
    static func hasFamilyOriginPath(_ fullPath: String, tables: AngelPolicyTables = .standard) -> Bool {
        let components = (fullPath as NSString).deletingLastPathComponent
            .split(separator: "/").map { $0.lowercased() }
        let markers = tables.familyOriginLower
        return components.contains { component in
            markers.contains { marker in
                marker.hasPrefix(".") ? component.hasSuffix(marker) : component == marker
                    || component == marker + ".localized"
            }
        }
    }

    static func looksLikeDownloadOrRip(_ c: ArchiveAngelCandidate,
                                       weights w: ArchiveAngelWeights = .standard) -> Bool {
        looksLikeDownloadOrRip(c, policy: AngelRecommendationPolicy.builtIn.with(weights: w))
    }

    static func looksLikeDownloadOrRip(_ c: ArchiveAngelCandidate, policy p: AngelRecommendationPolicy) -> Bool {
        let w = p.weights
        guard c.durationSeconds >= w.downloadMinimumDurationSeconds, c.sizeBytes > 0 else { return false }
        guard p.tables.deliveryCodecSet.contains(c.videoCodec.lowercased()) else { return false }
        guard !hasFamilyOriginPath(c.fullPath, tables: p.tables) else { return false }
        let kbps = Double(c.sizeBytes) * 8 / c.durationSeconds / 1000
        return kbps < w.downloadMaxKilobitsPerSecond
    }

    /// Folder components an editing app writes for itself (policy
    /// `tables.appCacheFolders`). Matched as whole components
    /// (case-insensitive) so a family folder named "Cache Cod" or
    /// "Thumbnails of Grandma" is untouched.
    static var appCacheFolderNames: Set<String> { AngelPolicyTables.standard.appCacheFolderSet }

    /// `Cache.mov`, `Cache-30.mov`, `render-12.mov`, `proxy_007.mov`,
    /// `thumb.mov`… — a bare tool noun, optionally numbered (policy
    /// `tables.appCacheNamePattern`). A real clip named by a person ("Cache
    /// Cod 1998.mov") has more than the noun. Compiled once per pattern
    /// (AngelPolicyTables keeps it) — a per-call compile is most of a second at 100k.
    static func looksLikeAppCache(filename: String, fullPath: String, tables: AngelPolicyTables = .standard) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        if let re = tables.appCacheRegex,
           re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil { return true }
        // Lower-case the folder part ONCE, then look each component up
        // (was a lowercased() allocation per component).
        let folders = (fullPath as NSString).deletingLastPathComponent.lowercased()
        let names = tables.appCacheFolderSet
        return folders.split(separator: "/").contains { names.contains(String($0)) }
    }

    /// Points and the printed tier for a duration; nil under 5 min (a
    /// short clip earns nothing for its length — it must make the list on
    /// stars, people or dates alone, and the floor already removes < 2 min).
    static func durationTier(_ seconds: Double,
                             weights w: ArchiveAngelWeights = .standard) -> (points: Int, tier: String)? {
        switch seconds {
        case w.wholeTapeSeconds...: return (w.durationWholeTape, "likely a whole tape")
        case w.halfTapeSeconds..<w.wholeTapeSeconds: return (w.durationHalfTape, "likely a whole tape or half")
        case w.longSceneSeconds..<w.halfTapeSeconds: return (w.durationLongScene, "a long scene")
        case w.sceneSeconds..<w.longSceneSeconds: return (w.durationScene, "a full scene")
        default: return nil
        }
    }

    // MARK: Saturating arithmetic (QA 2026-09-22: a policy.json number near
    // Int.max must never trap the sweep). Identical results to `+` / `*` /
    // `Int(_:)` for every in-range value — the policy validator keeps
    // real rule sets far from the edges; this is defence in depth.

    /// a + b, pinned to Int.min / Int.max instead of trapping.
    static func sum(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? .max : .min) : r
    }

    /// a × b, pinned instead of trapping.
    static func product(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? (((a < 0) != (b < 0)) ? .min : .max) : r
    }

    /// The score: the saturating sum of the printed points.
    static func total(_ lines: [ArchiveAngelEvidence]) -> Int {
        lines.reduce(0) { sum($0, $1.points) }
    }

    /// `Int(d)` for a finite in-range double; pinned to the Int range (NaN → 0)
    /// instead of trapping.
    static func clampedInt(_ d: Double) -> Int {
        guard d.isFinite else { return d.isNaN ? 0 : (d > 0 ? .max : .min) }
        if d >= 9.2e18 { return .max }
        if d <= -9.2e18 { return .min }
        return Int(d)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func durationText(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(sec) s" }
        return "\(sec) s"
    }
}
