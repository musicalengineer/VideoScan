// AngelPolicyDefaults.swift
// The Archive Angel's DEFAULT recommendation rules, written as data
// (Consolidation S3b, 2026-09-22). Everything the scorer and the classifier
// used to hard-code as a recommendation criterion lives in one of these
// values, and ArchiveAngelPolicy.default.json is exactly their encoding
// (AngelRecommendationPolicyTests pins bundled == built-in):
//
//   floors     the ordered hard floors (first hit excludes; `starExempt`
//              lets a person's star override machine evidence;
//              `explicitPicks: false` = only the Angel's own proposals)
//   signals    the evidence lines that add up to the score (order = the
//              order printed; the download cap and fatigue come last
//              because they act on the total so far)
//   grades     the A/B/C/D score bands
//   tables     originality ranks, delivery codecs, family-origin folders,
//              app-cache folders + name pattern, the derivative index cap
//   recommend  the classes (Ready / Needs a date / Worth a look), vouches,
//              the date rule, the copy chooser
//
// The numbers each built-in kind uses (★★★ = 100, the 2-minute floor…) stay
// in `weights` (ArchiveAngelWeights) so a schema-1 policy.json still means
// what it meant.
//
// NOT in the policy, deliberately (the policy says WHAT to recommend, not
// how the machine paces itself): the sweep cadence (launch 90 s, 1 min after
// an edit, every 15 min, 500-record slices), evidence freshness (24 h) and
// the fresh-slot scan budget (200), the attention memory's per-record event
// cap (12), and the buffer rules. Those protect the Mac's memory and the
// user's attention and change only with a code review.

import Foundation
import VideoScanCore

// MARK: - Grade bands

/// Score → letter. A ≥ `a`, B ≥ `b`, C ≥ `c`, D ≥ `d`, else X.
struct AngelGradeBands: Codable, Sendable, Equatable {
    var a = 100
    var b = 60
    var c = 25
    var d = 1

    static let standard = AngelGradeBands()

    func grade(for score: Int) -> ArchiveAngelGrade {
        if score >= a { return .a }
        if score >= b { return .b }
        if score >= c { return .c }
        if score >= d { return .d }
        return .x
    }

    var problems: [String] {
        guard 1 <= d, d < c, c < b, b < a, a <= AngelRecommendationPolicy.pointRange.upperBound else {
            return ["grades must rise: 1 ≤ d < c < b < a ≤ \(AngelRecommendationPolicy.pointRange.upperBound) (got a \(a), b \(b), c \(c), d \(d))"]
        }
        return []
    }
}

// MARK: - Tables

/// The lookup tables the built-in floors, signals and the batch order read.
struct AngelPolicyTables: Codable, Sendable, Equatable {
    /// "Most original" rank of an ffprobe codec name, 0 = most original
    /// (T10 H2, Rick 2026-09-11) — a tie-break only, never points.
    var originality: [String: Int]
    /// The rank of a codec not in `originality` (empty = un-probed).
    var originalityUnknown: Int
    /// Codecs a download or rip arrives in (the download cap, T10 H1).
    var deliveryCodecs: [String]
    /// Folder names only a family's own editing leaves behind; a name
    /// starting with "." matches as a suffix (".imovielibrary").
    var familyOriginFolders: [String]
    /// Folder names an editing app writes for itself (whole components).
    var appCacheFolders: [String]
    /// A file stem that is a bare tool noun ("Cache-30", "render_7").
    var appCacheNamePattern: String
    /// T10 H3: originals indexed per key when relating exports to their
    /// originals — bounds the pass at 100k same-named clips.
    var maxOriginalsPerKey: Int

    // Derived once (lower-cased lookups, the compiled pattern). Not
    // encoded, not compared (`==` below reads only the fields above).
    private(set) var originalityLower: [String: Int] = [:]
    private(set) var deliveryCodecSet: Set<String> = []
    private(set) var appCacheFolderSet: Set<String> = []
    private(set) var familyOriginLower: [String] = []
    /// nil only for a pattern that does not compile (validation refuses
    /// such a policy). NSRegularExpression is immutable and Sendable.
    private(set) var appCacheRegex: NSRegularExpression?

    static func == (a: AngelPolicyTables, b: AngelPolicyTables) -> Bool {
        a.originality == b.originality && a.originalityUnknown == b.originalityUnknown
            && a.deliveryCodecs == b.deliveryCodecs && a.familyOriginFolders == b.familyOriginFolders
            && a.appCacheFolders == b.appCacheFolders && a.appCacheNamePattern == b.appCacheNamePattern
            && a.maxOriginalsPerKey == b.maxOriginalsPerKey
    }

    private enum CodingKeys: String, CodingKey {
        case originality, originalityUnknown, deliveryCodecs, familyOriginFolders, appCacheFolders
        case appCacheNamePattern, maxOriginalsPerKey
    }

    init(originality: [String: Int], originalityUnknown: Int, deliveryCodecs: [String],
         familyOriginFolders: [String], appCacheFolders: [String], appCacheNamePattern: String,
         maxOriginalsPerKey: Int) {
        self.originality = originality
        self.originalityUnknown = originalityUnknown
        self.deliveryCodecs = deliveryCodecs
        self.familyOriginFolders = familyOriginFolders
        self.appCacheFolders = appCacheFolders
        self.appCacheNamePattern = appCacheNamePattern
        self.maxOriginalsPerKey = maxOriginalsPerKey
        derive()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originality = try c.decode([String: Int].self, forKey: .originality)
        originalityUnknown = try c.decode(Int.self, forKey: .originalityUnknown)
        deliveryCodecs = try c.decode([String].self, forKey: .deliveryCodecs)
        familyOriginFolders = try c.decode([String].self, forKey: .familyOriginFolders)
        appCacheFolders = try c.decode([String].self, forKey: .appCacheFolders)
        appCacheNamePattern = try c.decode(String.self, forKey: .appCacheNamePattern)
        maxOriginalsPerKey = try c.decode(Int.self, forKey: .maxOriginalsPerKey)
        derive()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(originality, forKey: .originality)
        try c.encode(originalityUnknown, forKey: .originalityUnknown)
        try c.encode(deliveryCodecs, forKey: .deliveryCodecs)
        try c.encode(familyOriginFolders, forKey: .familyOriginFolders)
        try c.encode(appCacheFolders, forKey: .appCacheFolders)
        try c.encode(appCacheNamePattern, forKey: .appCacheNamePattern)
        try c.encode(maxOriginalsPerKey, forKey: .maxOriginalsPerKey)
    }

    private mutating func derive() {
        originalityLower = Dictionary(originality.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        deliveryCodecSet = Set(deliveryCodecs.map { $0.lowercased() })
        appCacheFolderSet = Set(appCacheFolders.map { $0.lowercased() })
        familyOriginLower = familyOriginFolders.map { $0.lowercased() }
        appCacheRegex = appCacheNamePattern.count <= Self.maxPatternLength
            ? try? NSRegularExpression(pattern: appCacheNamePattern, options: [.caseInsensitive]) : nil
    }

    static let maxEntries = 500
    static let maxPatternLength = 300

    var problems: [String] {
        var out: [String] = []
        for (name, n) in [("originality", originality.count), ("deliveryCodecs", deliveryCodecs.count),
                          ("familyOriginFolders", familyOriginFolders.count), ("appCacheFolders", appCacheFolders.count)]
        where n > Self.maxEntries {
            out.append("tables.\(name): more than \(Self.maxEntries) entries")
        }
        for (codec, rank) in originality where !(0...100).contains(rank) {
            out.append("tables.originality[\"\(codec)\"] = \(rank) — must be 0…100")
        }
        if !(0...100).contains(originalityUnknown) { out.append("tables.originalityUnknown = \(originalityUnknown) — must be 0…100") }
        if !(1...64).contains(maxOriginalsPerKey) { out.append("tables.maxOriginalsPerKey = \(maxOriginalsPerKey) — must be 1…64") }
        if appCacheNamePattern.count > Self.maxPatternLength {
            out.append("tables.appCacheNamePattern is longer than \(Self.maxPatternLength) characters")
        } else if (try? NSRegularExpression(pattern: appCacheNamePattern, options: [.caseInsensitive])) == nil {
            out.append("tables.appCacheNamePattern is not a valid regular expression")
        }
        return out
    }

    static let standard = AngelPolicyTables(
        originality: [
            "dvvideo": 0, "dv": 0,
            "mjpeg": 1,
            "mpeg2video": 2, "hdv": 3,
            "prores": 4,
            "ffv1": 5,
            "mpeg1video": 6,
            "svq3": 7,
            "h264": 8, "avc1": 8, "hevc": 8, "mpeg4": 8, "vp9": 8,
        ],
        originalityUnknown: 9,
        deliveryCodecs: [
            "h264", "avc1", "mpeg4", "xvid", "divx", "msmpeg4v3", "msmpeg4v2", "msmpeg4",
            "hevc", "h265", "vp8", "vp9", "av1", "wmv3", "wmv2", "vc1", "flv1", "theora",
        ],
        familyOriginFolders: [
            ".imovielibrary", ".imovieproject", "imovie events", "imovie projects", "family movies",
            "home movies", "home videos", "original media",
        ],
        appCacheFolders: [
            "imovie cache", "imovie movie cache", "imovie thumbnails", "imovie thumbnails.localized",
            "render files", "transcoded media", "proxy media", "analysis files", "thumbnail media",
            "cache", "caches", "renders", "proxies", "thumbnails", "temp", "tmp", ".cache", ".thumbnails",
        ],
        appCacheNamePattern: #"^(cache|render|proxy|proxies|preview|thumb|thumbnail|temp|tmp)([ _-]?\d+)?$"#,
        maxOriginalsPerKey: 8)
}

// MARK: - The default rules

enum AngelPolicyDefaults {

    /// The hard floors, in the order a person should hear the reason.
    static let floors: [AngelRule] = [
        AngelRule(id: "notVideo", kind: .notVideo, note: "Audio-only files, stills and un-probed files are not videos"),
        AngelRule(id: "onMasterArchive", kind: .onMasterArchive,
                  note: "The file is in the Master Archive or already has its copy there"),
        // Rick 2026-09-22 (decision 3): archiveStage is never "archived" —
        // but Relocate's terminal stages mean the FILE IS GONE. v10 caught
        // them by accident ("stage ≥ Master"); this names them. Live catalog
        // that day: 839 of v10's 1,132 "Already in the archive" were these.
        AngelRule(id: "fileGone", kind: .match,
                  note: "Relocate marked the file deleted or unsalvageable",
                  when: [.init(field: .archiveStage, op: .in, value: .strings(["manuallyDeleted", "salvageFailed"]))],
                  rejection: "fileGone"),
        AngelRule(id: "archivedCopy", kind: .archivedCopy,
                  note: "A copy of it, or the original this is a version of, is already archived"),
        AngelRule(id: "notPlayable", kind: .notPlayable),
        AngelRule(id: "pairedHalf", kind: .pairedHalf, note: "Combine the A/V pair first; the combined file is the candidate"),
        AngelRule(id: "livePhotoMotion", kind: .livePhotoMotion,
                  note: "Rick 2026-09-21: a Live Photo's motion half is part of a photo", explicitPicks: false),
        AngelRule(id: "recentPhoneClip", kind: .recentPhoneClip,
                  note: "Rick 2026-09-21: only phone clips older than weights.recentPhoneClipYears",
                  explicitPicks: false),
        AngelRule(id: "appCache", kind: .appCache, starExempt: true),
        AngelRule(id: "derivativeOfOriginal", kind: .derivativeOfOriginal, starExempt: true),
        AngelRule(id: "tooShort", kind: .tooShort,
                  note: "weights.minimumDurationSeconds (explicit picks: explicitPickMinimumDurationSeconds)"),
        AngelRule(id: "proxyStream", kind: .proxyStream, starExempt: true),
        AngelRule(id: "markedJunk", kind: .markedJunk),
        AngelRule(id: "suspectedJunk", kind: .suspectedJunk, starExempt: true),
        AngelRule(id: "junkScore", kind: .junkScore, note: "weights.junkFloor", starExempt: true),
        AngelRule(id: "volumeOffline", kind: .volumeOffline),
        AngelRule(id: "resting", kind: .resting, note: "Attention memory: passed on three times, back after weights.restDays"),
    ]

    /// The evidence lines, in print order. The cap and fatigue act on the
    /// total of the lines above them, so they stay last.
    static let signals: [AngelRule] = [
        AngelRule(id: "stars", kind: .stars),
        AngelRule(id: "confirmedPeople", kind: .confirmedPeople),
        AngelRule(id: "machinePeople", kind: .machinePeople),
        AngelRule(id: "playHistory", kind: .playHistory),
        AngelRule(id: "richness", kind: .richness),
        AngelRule(id: "date", kind: .date),
        AngelRule(id: "duration", kind: .duration),
        AngelRule(id: "formatAtRisk", kind: .formatAtRisk),
        AngelRule(id: "onlyCopy", kind: .onlyCopy),
        AngelRule(id: "unassignedVolume", kind: .unassignedVolume),
        AngelRule(id: "audioProblem", kind: .audioProblem),
        AngelRule(id: "downloadCap", kind: .downloadCap),
        AngelRule(id: "fatigue", kind: .fatigue),
    ]

    /// Who vouched (the same signals the nudge counted) — Rick 2026-09-22:
    /// stage Ready / Master is a VOTE to archive, never "already archived".
    static let vouch: [AngelRule] = [
        AngelRule(id: "important", kind: .match,
                  when: [.init(field: .mediaDisposition, op: .eq, value: .string("important"))],
                  points: 3, line: "marked Important"),
        AngelRule(id: "stars", kind: .stars,
                  when: [.init(field: .starRating, op: .ge, value: .number(2))],
                  points: 1),
        AngelRule(id: "stageReady", kind: .match,
                  when: [.init(field: .archiveStage, op: .eq, value: .string("readyForArchive"))],
                  points: 2, line: "stage: Ready"),
        AngelRule(id: "stageMaster", kind: .match,
                  when: [.init(field: .archiveStage, op: .eq, value: .string("masterAssigned"))],
                  points: 1, line: "stage: Master"),
        AngelRule(id: "keeper", kind: .match,
                  when: [.init(field: .duplicateDisposition, op: .eq, value: .string("keep"))],
                  line: "the copy to keep", vouches: false),
    ]

    /// "Vouched, or grade A".
    static let recommendedByPersonOrAngel = AngelCondition(any: [
        .init(field: .vouched, op: .eq, value: .bool(true)),
        .init(field: .grade, op: .eq, value: .string("A")),
    ])
}

extension AngelRecommendRules {

    /// The unified rules (Rick 2026-09-22, decisions 2 and 3):
    ///   Ready        passes the Angel's floors AND (vouched: Important or
    ///                ★★+ or stage Ready/Master, OR grade A) AND dated to
    ///                at least a year;
    ///   Needs a date the same, undated;
    ///   Worth a look grade B, nobody vouched;
    ///   Not now      C / D;   Excluded — a floor (grade X) or an extra copy.
    /// One per recording (duplicate group, else name + length): the Keep
    /// copy, else the best-ranked.
    static let standard = AngelRecommendRules(
        useAngelFloors: true,
        exclude: [
            AngelRule(id: "extraCopy", kind: .match,
                      when: [.init(field: .duplicateDisposition, op: .eq, value: .string("extraCopy"))],
                      line: "Marked an extra copy — its keeper is the one to archive"),
        ],
        vouch: AngelPolicyDefaults.vouch,
        date: AngelDateRule(minimum: "year"),
        classes: [
            AngelClassRule(.ready, when: [AngelPolicyDefaults.recommendedByPersonOrAngel,
                                          .init(field: .dated, op: .eq, value: .bool(true))]),
            AngelClassRule(.needsDate, when: [AngelPolicyDefaults.recommendedByPersonOrAngel]),
            AngelClassRule(.worthALook, when: [.init(field: .grade, op: .eq, value: .string("B"))]),
        ],
        copies: AngelCopyRules(collapseBy: ["duplicateGroup", "nameAndDuration"],
                               prefer: ["userKeeper", "best"],
                               classes: ["ready", "needsDate", "worthALook"],
                               noteCopies: true),
        order: "angelRank")
}
