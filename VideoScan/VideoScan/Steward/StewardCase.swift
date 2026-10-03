// StewardCase.swift
// The content steward's vocabulary (trial UI, 2026-10-03; design §5.6 of
// docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md): a CASE
// is one thing that would tidy the catalog — what, why (evidence), payoff,
// do it / skip. Archive Angel's shape, second instance: the Angel's verb is
// "keep forever"; this one's are "let go" and "belong together".
//
// Everything here is a plain value type built off the main actor by
// StewardCaseBuilder and read O(1) by the views. No case carries a
// VideoRecord; record ids are carried so an action can look them up.
//
// (For Rick: `struct … : Sendable, Equatable` ≈ a C++ POD with operator==;
// `Identifiable` gives SwiftUI the stable key it diffs lists by.)

import Foundation

/// The three card types of the trial (Reclaim space has two shapes).
enum StewardCaseKind: String, Sendable, Equatable, CaseIterable {
    /// A whole drive's duplicate copies.
    case reclaimDrive
    /// One set of duplicate copies.
    case reclaimGroup
    /// Clips that are the same footage.
    case sameFootage
    /// Clips that share a reason they are probably not worth keeping.
    case junk

    /// The chip on the card and on each "next up" row — words, not grades.
    var chip: String {
        switch self {
        case .reclaimDrive, .reclaimGroup: return "Reclaim space"
        case .sameFootage: return "Same footage"
        case .junk: return "Probably not worth keeping"
        }
    }

    /// The queue's lane: the two Reclaim shapes take turns as one.
    var lane: Int {
        switch self {
        case .reclaimDrive, .reclaimGroup: return 0
        case .sameFootage: return 1
        case .junk: return 2
        }
    }

    var systemImage: String {
        switch self {
        case .reclaimDrive: return "externaldrive"
        case .reclaimGroup: return "doc.on.doc"
        case .sameFootage: return "square.stack.3d.up"
        case .junk: return "questionmark.folder"
        }
    }
}

/// Why the steward will never propose letting a file go (rule 2 of §5.6:
/// one steward's cases are never another's loss).
enum StewardProtection: String, Sendable, Equatable {
    case none
    /// A promoted copy, a file inside the Master Archive, or a file filed
    /// as Archived in Triage.
    case archived
    /// Anywhere else on the Master Archive's drive (or a drive that cannot
    /// be told apart from it right now).
    case archiveDrive
    /// Archive Angel recommends it, or holds it in a prepared batch.
    case angel

    var isProtected: Bool { self != .none }

    /// The words on a copy's row.
    var words: String {
        switch self {
        case .none: return ""
        case .archived: return "in the archive — never offered"
        case .archiveDrive: return "on the archive drive — never offered"
        case .angel: return "Archive Angel has chosen it — never offered"
        }
    }
}

/// What the Delete duplicates flow would do with one copy of a set, as far
/// as the catalog can tell (the run itself decides from the disk).
enum StewardCopyStanding: Sendable, Equatable {
    case keeper
    /// The Delete duplicates flow on this copy's drive would check it.
    case wouldBeChecked
    /// The keeper is on another drive and "Also clean up working copies"
    /// is off — the flow leaves it alone.
    case keeperOnAnotherDrive
    case protected(StewardProtection)
    /// Not a duplicate copy at all (a footage or junk row).
    case member
}

/// One file on a card's evidence list.
struct StewardCopy: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    /// "SanDisk"
    var drive: String
    /// The folder under the drive ("Tapes/2006"), "" at the top.
    var folder: String
    var sizeBytes: Int64
    var durationSeconds: Double
    var isOnline: Bool
    var standing: StewardCopyStanding
    /// Same footage: "likely original", "copy", "re-encode"…
    var roleLabel: String = ""
}

/// The numbers a skip remembers, so a skipped case can come back when the
/// facts under it move (StewardSkipStore).
struct StewardFacts: Sendable, Equatable {
    var bytes: Int64
    var count: Int
}

struct StewardCase: Sendable, Equatable, Identifiable {
    /// Stable across launches: "drive:<root>", "dup:<group id>",
    /// "footage:<group id>", "junk:<reason>|<drive root>".
    var id: String
    var kind: StewardCaseKind
    /// The big line.
    var title: String
    /// The line under it ("" when there is nothing to add).
    var detail: String = ""
    /// What doing it would give back; 0 where the payoff is clarity.
    var payoffBytes: Int64 = 0
    /// Bytes the Delete duplicates flow would look at today (Reclaim).
    var actionableBytes: Int64 = 0
    /// Files in the case.
    var memberCount: Int = 0
    /// What a skip remembers.
    var facts: StewardFacts
    /// The drive an action would work on ("/Volumes/SanDisk"), if any.
    var driveRoot: String?
    var driveLabel: String = ""
    var driveConnected: Bool = true
    /// The records behind the case (capped at StewardCaseBuilder.maxIDsPerCase).
    var recordIDs: [UUID] = []
    /// The evidence rows (capped at StewardCaseBuilder.maxCopiesPerCase).
    var copies: [StewardCopy] = []

    // Reclaim — a drive
    var estimate: ReclaimableEstimate?

    // Reclaim — one set
    var duplicateGroupID: UUID?
    var keeperID: UUID?
    /// Copies the flow would leave alone because the keeper is elsewhere.
    var copiesNeedingWorkingCopyMode: Int = 0
    var protectedCopies: Int = 0

    // Same footage
    var footageGroupID: UUID?
    var likelyOriginalID: UUID?
    var likelyOriginalName: String = ""
    var originalInCatalog: Bool = true
    /// The group's reasons, in the grouping's own words.
    var evidenceLines: [String] = []
    var eventGuess: StewardEventGuess?
    /// "27 clips on 3 drives — likely the same footage · Dec 2006"
    var plainDescription: String = ""

    // Probably not worth keeping
    var junkReason: String = ""
}

/// Everything the pane reads. Equality-gated by StewardSnapshot: an
/// unchanged queue publishes nothing.
struct StewardQueue: Sendable, Equatable {
    /// Presentation order: the three lanes take turns, each in its own
    /// payoff order (StewardCaseBuilder.interleave).
    var cases: [StewardCase] = []
    /// Newest duplicate check among the active records.
    var duplicatesLastChecked: Date?
    /// False until the first build lands.
    var isBuilt = false

    func count(of kind: StewardCaseKind) -> Int { cases.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }
}
