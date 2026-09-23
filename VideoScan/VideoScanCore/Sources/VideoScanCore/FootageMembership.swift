// FootageMembership.swift
// Find Similar Footage, Phase 1 (Rick 2026-09-23, docs/find_original_design.md
// top section): the catalog fields that record "these files are probably
// the SAME footage" — copies, re-encodes, transcodes, exports, trims of one
// recording. Not "similar content" (that is Deep Analyze, later).
//
// Two kinds of data, deliberately kept apart:
//
//   * `FootageMembership` — the MACHINE's answer, rewritten by every run of
//     the "Find Similar Footage" MFO verb. Disposable: a run may regroup,
//     rename the group id or clear it.
//   * `FootageDecision`   — the PERSON's answer ("same footage" / "not the
//     same" about one other record). Never rewritten by the machine; every
//     later run reads it and obeys it (a "not the same" splits even
//     byte-identical files; a "same" joins files no rule would). Mirrored
//     into the Media Ledger when it is made.
//
// Both are additive optionals on VideoRecord (`footage`, `footageDecisions`):
// legacy catalogs decode nil / [] and round-trip byte-identical because the
// DTO writes the keys only when present / non-empty. Nothing is renamed or
// removed. Phase 1 writes NO dates.
//
// (For Rick: plain value structs ≈ C++ PODs with an explicit serializer.
// `Comparable` on the enum is the `operator<` the grouping uses to find the
// weakest link.)

import Foundation

// MARK: - Confidence

/// How sure the machine is that a group is one piece of footage. A group's
/// confidence is its WEAKEST link on the path that joined it (the grouping
/// takes strong links first, so that path is the strongest available).
public enum FootageConfidence: String, Codable, Sendable, CaseIterable, Comparable {
    /// Byte-identical (a full content hash or whole-file fixity matched).
    case identical
    /// The person said "same footage". Ranks between identical and likely:
    /// it never lowers a group below what the machine proved.
    case confirmed
    /// Strong metadata: recorded lineage, same name + length to ±2 frames,
    /// an FCP transcode of its Original Media, a sampled signature + size.
    case likely
    /// Weak metadata: a camera-counter name or a trailing "-3" plus the
    /// same length. Never chains more than one hop (see FootageGrouping).
    case possible

    /// Strength order: identical (strongest) … possible (weakest).
    public var strength: Int {
        switch self {
        case .identical: return 3
        case .confirmed: return 2
        case .likely:    return 1
        case .possible:  return 0
        }
    }

    /// `a < b` ⇔ a is WEAKER than b (so `min` finds the weakest link).
    public static func < (a: FootageConfidence, b: FootageConfidence) -> Bool { a.strength < b.strength }

    public var label: String {
        switch self {
        case .identical: return "Identical"
        case .confirmed: return "You confirmed"
        case .likely:    return "Likely"
        case .possible:  return "Possible"
        }
    }
}

// MARK: - Role

/// What a member is relative to the group's likely original.
public enum FootageRole: String, Codable, Sendable, CaseIterable {
    case original
    /// Same bytes as the likely original.
    case copy
    /// Re-encoded (HandBrake / ffmpeg / the Angel's .vs.* outputs, another codec).
    case reEncode
    /// An editing-app transcode (FCP Transcoded/Proxy Media, a ProRes render).
    case transcode
    /// An edit export (delivery codec, no camera tags) of footage whose
    /// camera original is somewhere else.
    case export
    /// A trimmed piece.
    case trim
    /// Audio balanced / cleaned / repaired.
    case restored
    /// The separate audio or video half of one recording (Avid MXF pairs).
    case avHalf
    /// In the group, but no rule says which kind of version it is.
    case related

    public var label: String {
        switch self {
        case .original:  return "likely original"
        case .copy:      return "copy"
        case .reEncode:  return "re-encode"
        case .transcode: return "transcode"
        case .export:    return "export"
        case .trim:      return "trim"
        case .restored:  return "restored"
        case .avHalf:    return "A/V half"
        case .related:   return "related"
        }
    }
}

// MARK: - Machine membership

/// The machine's current answer for one record. Rewritten by each run.
public struct FootageMembership: Codable, Equatable, Hashable, Sendable {
    /// Stable-ish group id: the smallest member record id (by uuidString),
    /// so a new member with a larger id keeps the group's id.
    public var groupID: UUID
    /// Members in the group, this record included (≥ 2).
    public var groupSize: Int
    /// The group's confidence — its weakest joining link.
    public var confidence: FootageConfidence
    /// This record's role relative to the likely original.
    public var role: FootageRole
    /// 0 = the likely original; 1… = the order the originality scorer ranks
    /// the rest. The "One per footage" view keeps the lowest VISIBLE rank.
    public var rank: Int
    /// The member the originality scorer picked.
    public var likelyOriginalID: UUID
    /// False when the likely original carries no camera evidence (no make /
    /// model, no camera format or filename) — "original not in catalog;
    /// best available is an export".
    public var originalInCatalog: Bool
    /// Short reasons for THIS record's membership ("same bytes as X", "same
    /// name + length (Δ1 frame) as Y"), capped (FootageGrouping.maxReasons).
    public var evidence: [String]
    /// When the run that wrote this ran.
    public var scannedAt: Date
    /// FootageGrouping.algorithmVersion of that run.
    public var algorithmVersion: Int

    public init(groupID: UUID, groupSize: Int, confidence: FootageConfidence, role: FootageRole,
                rank: Int, likelyOriginalID: UUID, originalInCatalog: Bool, evidence: [String],
                scannedAt: Date, algorithmVersion: Int) {
        self.groupID = groupID
        self.groupSize = groupSize
        self.confidence = confidence
        self.role = role
        self.rank = rank
        self.likelyOriginalID = likelyOriginalID
        self.originalInCatalog = originalInCatalog
        self.evidence = evidence
        self.scannedAt = scannedAt
        self.algorithmVersion = algorithmVersion
    }

    /// Everything but the run stamp — "did this run change the answer?"
    /// (the incremental apply writes only records whose answer changed).
    public func sameAnswer(as other: FootageMembership) -> Bool {
        groupID == other.groupID && groupSize == other.groupSize && confidence == other.confidence
            && role == other.role && rank == other.rank && likelyOriginalID == other.likelyOriginalID
            && originalInCatalog == other.originalInCatalog && evidence == other.evidence
            && algorithmVersion == other.algorithmVersion
    }
}

// MARK: - Human decision

/// The person's word about this record and ONE other record. Stored on
/// BOTH records (symmetric), latest answer per pair wins.
public struct FootageDecision: Codable, Equatable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case same
        case notSame
    }
    public var otherID: UUID
    public var verdict: Verdict
    public var decidedAt: Date

    public init(otherID: UUID, verdict: Verdict, decidedAt: Date = Date()) {
        self.otherID = otherID
        self.verdict = verdict
        self.decidedAt = decidedAt
    }
}

// MARK: - VideoRecord conveniences

extension VideoRecord {
    /// Machine group id (nil = not in any footage group).
    public var footageGroupID: UUID? { footage?.groupID }
    public var footageConfidence: FootageConfidence? { footage?.confidence }
    public var footageRole: FootageRole? { footage?.role }
    public var footageScannedAt: Date? { footage?.scannedAt }

    /// The person's latest answer about `otherID`, if any.
    public func footageDecision(about otherID: UUID) -> FootageDecision? {
        footageDecisions.last { $0.otherID == otherID }
    }

    /// Replace (or add) the answer about `decision.otherID`; `nil` verdict
    /// in the caller's hands means "forget" — see `forgetFootageDecision`.
    public func setFootageDecision(_ decision: FootageDecision) {
        footageDecisions.removeAll { $0.otherID == decision.otherID }
        footageDecisions.append(decision)
    }

    public func forgetFootageDecision(about otherID: UUID) {
        footageDecisions.removeAll { $0.otherID == otherID }
    }
}
