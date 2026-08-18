import Foundation

// MARK: - Duplicate keeper election policy (2026-08-18)
//
// WHY THIS EXISTS. Until today `DuplicateDetector` elected a duplicate
// group's keeper on TECHNICAL merit only (playability, streams, size,
// resolution, date). For byte-identical copies every one of those ties,
// so the keeper was whichever copy happened to sort first — arbitrary.
// Two real consequences:
//
//   * 8/14 finding — 2,027 high-confidence groups (2.1 TB) elected a
//     shelved, OFFLINE/retired drive as "Keep" with the live master as
//     "Extra copy". Byte-verify can't catch that; the election has to.
//   * 8/17 (Rick) — volumes carry facts the scorer never saw ("LaCie =
//     2009 Cheesegrater originals; Crucials = scratch"). A delete could
//     remove the metadata-bearing copy and keep a bare scratch twin —
//     star rating, confirmed people, notes, provenance stamp and
//     transcript all on the copy about to be removed. Rick's 8/18
//     decision: the list is ordered by ESTIMATED RELIABILITY (RAID ›
//     HDD › SSD working tier), see DuplicateKeeperSettings.
//
// THE POLICY. Keeper = lexicographic max of
//     (volume precedence, human-metadata score, technical keeperScore,
//      fullPath ascending as the deterministic tie-break)
// The grouping / threshold logic in DuplicateDetector is untouched; only
// the election changed.
//
// Volume precedence, highest first:
//   1. availability — ANY online volume outranks ANY offline one, and any
//      offline volume outranks a retired one (the 8/14 strand fix). This
//      dominates even a user-listed volume: a listed drive that is not
//      mounted still must not be elected Keep over a live copy.
//   2. within one availability band —
//        the Master Archive (excluded from bulk delete already, so it is
//        the natural top),
//        then the user-ordered precedence list (settings, seeded with
//        Rick's reliability order RAID › HDD › SSD),
//        then unlisted volumes by role: workspace › cloud › unassigned ›
//        system/home-folder › backup (VolumeRole doc: backup is "never
//        elected Keep over a live file").
//
// This type is a pure Sendable value: it is built ON the main actor from
// CatalogScanTarget (a @MainActor ObservableObject) and shipped to the
// off-main analyzer with the record clones. Nothing here touches disk,
// so it is unit-testable and cheap: an ElectionKey is O(#volume facts)
// per record, computed once per component member during election.

struct DuplicateKeeperPolicy: Sendable, Equatable {

    /// The facts the election needs about ONE scan target, snapshotted
    /// from `CatalogScanTarget` (which cannot leave the main actor).
    struct VolumeFacts: Sendable, Equatable {
        var role: VolumeRole = .unassigned
        var isReachable: Bool = true
        var isRetired: Bool = false
        var isMasterArchive: Bool = false
    }

    /// User-ordered volume names, highest precedence first. Entries are
    /// volume names ("LaCieWorkspace" ⇒ /Volumes/LaCieWorkspace) or, for
    /// home-folder targets, absolute paths ("/Users/rickb/Movies").
    var precedence: [String]

    /// Facts keyed by the scan target's normalized `searchPath`. A record
    /// matches the LONGEST key that contains it (a subfolder target can
    /// carry a different role than the volume root).
    var facts: [String: VolumeFacts]

    init(precedence: [String] = DuplicateKeeperSettings.defaultPrecedence,
         facts: [String: VolumeFacts] = [:]) {
        self.precedence = precedence
        // Normalize once so lookups can compare exact strings.
        var normalized: [String: VolumeFacts] = [:]
        for (path, f) in facts { normalized[PathScope.normalize(path)] = f }
        self.facts = normalized
    }

    /// No settings, no volume facts — every record is "online, unlisted,
    /// unassigned"; the election degrades to human-metadata › technical
    /// › path. This is what the existing DuplicateDetector unit tests run
    /// under, and what `analyze(records:)` uses when no policy is passed.
    static let unconfigured = DuplicateKeeperPolicy(precedence: [], facts: [:])

    // MARK: Election key

    /// Everything the keeper election compares, packed so that
    /// "greater == better keeper". `Comparable` conformance is
    /// lexicographic over the stored fields in declaration order — the
    /// Swift analogue of C++ `std::tie(a, b, c) < std::tie(...)`.
    struct ElectionKey: Comparable, Sendable, Equatable {
        /// 2 online, 1 offline (unmounted, not retired), 0 retired.
        let availability: Int
        /// Master Archive › listed (in list order) › unlisted by role.
        let precedence: Int
        /// `DuplicateKeeperPolicy.humanMetadataScore`.
        let humanMetadata: Int
        /// `DuplicateDetector.keeperScore` — the pre-2026-08-18 election.
        let technical: Int
        /// Deterministic last resort: the LEXICOGRAPHICALLY SMALLER path
        /// wins, so it is stored inverted (see `<`).
        let path: String

        static func < (lhs: ElectionKey, rhs: ElectionKey) -> Bool {
            if lhs.availability != rhs.availability { return lhs.availability < rhs.availability }
            if lhs.precedence != rhs.precedence { return lhs.precedence < rhs.precedence }
            if lhs.humanMetadata != rhs.humanMetadata { return lhs.humanMetadata < rhs.humanMetadata }
            if lhs.technical != rhs.technical { return lhs.technical < rhs.technical }
            // Smaller path is the BETTER keeper ⇒ lhs is "less" when its
            // path sorts AFTER rhs's. Byte-wise (not localized) so the
            // order is identical on every machine and locale.
            return lhs.path > rhs.path
        }
    }

    func electionKey(for record: VideoRecord, technicalScore: Int) -> ElectionKey {
        let path = record.fullPath
        let facts = facts(forPath: path)
        let availability: Int
        if facts?.isRetired == true {
            availability = 0
        } else if facts?.isReachable == false {
            availability = 1
        } else {
            availability = 2
        }
        return ElectionKey(
            availability: availability,
            precedence: precedenceScore(forPath: path, facts: facts),
            humanMetadata: Self.humanMetadataScore(record),
            technical: technicalScore,
            path: path
        )
    }

    // MARK: Volume precedence

    /// Precedence bands. Wide gaps so the list can hold thousands of
    /// entries without colliding with a band boundary.
    private static let masterArchiveScore = 1_000_000
    private static let listedBase = 100_000
    private static let unlistedRoleScore: [VolumeRole: Int] = [
        .archive:    60,   // a legacy non-master "Archive" role
        .workspace:  50,
        .cloud:      40,
        .unassigned: 30,
        .system:     20,   // boot volume / home folder
        .backup:     10,   // "never elected Keep over a live file"
    ]
    private static let homeFolderScore = 20

    func precedenceScore(forPath path: String, facts: VolumeFacts?) -> Int {
        if facts?.isMasterArchive == true { return Self.masterArchiveScore }
        if let index = listIndex(forPath: path) {
            return Self.listedBase - index
        }
        if let role = facts?.role, let score = Self.unlistedRoleScore[role] {
            return score
        }
        // No scan-target facts: a /Volumes/X path is an unlisted,
        // unassigned volume; anything under /Users is the home folder,
        // which Rick wants AFTER named volumes unless listed.
        if path.hasPrefix("/Users/") { return Self.homeFolderScore }
        return Self.unlistedRoleScore[.unassigned] ?? 0
    }

    /// Position of the record's volume in the precedence list, or nil.
    /// A list entry that starts with "/" is an absolute path prefix (home
    /// folder targets); anything else is a /Volumes name.
    func listIndex(forPath path: String) -> Int? {
        let name = Self.volumeName(forPath: path)
        for (i, entry) in precedence.enumerated() {
            if entry.hasPrefix("/") {
                if PathScope.contains(path, within: entry) { return i }
            } else if let name, name == entry {
                return i
            }
        }
        return nil
    }

    /// Longest-prefix scan-target match. Linear in the number of targets
    /// (tens), not records.
    func facts(forPath path: String) -> VolumeFacts? {
        var bestLen = -1
        var bestFacts: VolumeFacts?
        for (root, f) in facts where PathScope.contains(path, within: root) && root.count > bestLen {
            bestLen = root.count
            bestFacts = f
        }
        return bestFacts
    }

    /// "/Volumes/LaCieWorkspace/2009/x.mxf" → "LaCieWorkspace"; nil for
    /// anything not under /Volumes.
    static func volumeName(forPath path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let rest = path.dropFirst("/Volumes/".count)
        guard let slash = rest.firstIndex(of: "/") else {
            return rest.isEmpty ? nil : String(rest)
        }
        let name = rest[rest.startIndex..<slash]
        return name.isEmpty ? nil : String(name)
    }

    // MARK: Human-metadata score

    /// How much HUMAN work (or human-facing derived work) this record
    /// carries — the part a delete could lose. Higher = more to lose =
    /// better keeper. Weights: a star rating is Rick's explicit verdict
    /// (THE curation axis, 8/14) so it dominates; confirmed people and
    /// notes are hand-typed; a Migrate provenance stamp
    /// (`originalFullPath`) says "this copy is the one we moved on
    /// purpose"; transcript / captions / dossier are expensive machine
    /// products a human may already have searched by. Never counts
    /// machine probe fields — those are re-derivable and identical for a
    /// byte-identical twin anyway.
    static func humanMetadataScore(_ record: VideoRecord) -> Int {
        var score = 0
        if record.starRating > 0 { score += 100 }
        if !record.confirmedByUserPeople.isEmpty { score += 40 }
        if !record.rejectedPeople.isEmpty { score += 10 }
        if !record.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 30 }
        if !record.tags.isEmpty { score += 20 }
        if record.userDate != nil { score += 15 }
        if record.originalFullPath != nil { score += 25 }
        if let t = record.audioTranscript, !t.isEmpty { score += 8 }
        if !record.sceneCaptions.isEmpty { score += 8 }
        if record.dossierProcessedAt != nil { score += 4 }
        return score
    }
}

// MARK: - Settings (explicit-save pattern)

/// Persisted duplicate-keeper preferences. Same shape as
/// CatalogScopeSettings: `restored(from:)` at startup, `save(to:)` on
/// every user change, UserDefaults INJECTED so tests never touch the real
/// plist (settings-pollution class). @Published kills didSet — the model
/// owner calls `saveDuplicateKeeperSettings()` explicitly.
struct DuplicateKeeperSettings: Equatable, Sendable {

    /// Rick's seed order (decided 2026-08-18), editable in the Volumes
    /// window. The order is ESTIMATED RELIABILITY — not provenance, not
    /// speed:
    ///   RAID (FamilyArchive, Projects — redundant, most reliable)
    ///   › new respectable HDDs (LaCieWorkspace, MediaExpansion,
    ///     SanDiskWorkspace)
    ///   › SSDs (CrucialX10, CrucialX9 — the fast working/scratch tier;
    ///     media there is in flight to somewhere permanent and is never
    ///     the master copy).
    /// So when the same bytes sit on a RAID and an SSD, the RAID copy is
    /// Keep and the SSD copy is the extra we may clear. Names are
    /// /Volumes entries; the list may also hold absolute paths.
    static let defaultPrecedence: [String] = [
        "FamilyArchive",
        "Projects",
        "LaCieWorkspace",
        "MediaExpansion",
        "SanDiskWorkspace",
        "CrucialX10",
        "CrucialX9",
    ]

    var volumePrecedence: [String] = DuplicateKeeperSettings.defaultPrecedence

    static let precedenceKey = "dupKeep_volumePrecedence"

    static func restored(from defaults: UserDefaults) -> DuplicateKeeperSettings {
        var s = DuplicateKeeperSettings()
        // object(forKey:) nil-check: "never set" keeps the seed order; a
        // stored (even empty) array is the user's list.
        if let stored = defaults.object(forKey: precedenceKey) as? [String] {
            s.volumePrecedence = stored
        }
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(volumePrecedence, forKey: Self.precedenceKey)
    }
}
