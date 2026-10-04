// StewardCase.swift
// The content steward's vocabulary (trial UI, 2026-10-03; design §5.6 of
// docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md): a CASE
// is one thing that would tidy the catalog — what, why (evidence), payoff,
// do it / skip. Archive Angel's shape, second instance: the Angel's verb is
// "keep forever"; this one's are "let go" and "belong together".
//
// EVENTS LEAD (Rick 2026-10-03: "it should help find events … the deletion
// of dups is just to keep the database down"). An EVENT is an occasion the
// catalog can already name from what is on the records — a holiday, a
// family birthday, a word in a folder name (StewardEvents.swift, over
// VideoScanCore.EventLabeler). Events and unnamed days come first in the
// pane; same footage, reclaim space and junk follow as housekeeping.
//
// Everything here is a plain value type built off the main actor by
// StewardCaseBuilder and read O(1) by the views. No case carries a
// VideoRecord; record ids are carried so an action can look them up.
//
// (For Rick: `struct … : Sendable, Equatable` ≈ a C++ POD with operator==;
// `Identifiable` gives SwiftUI the stable key it diffs lists by.)

import Foundation

/// The card types of the trial (Reclaim space has two shapes; an occasion
/// is either named — an event — or a day nobody has named yet).
enum StewardCaseKind: String, Sendable, Equatable, CaseIterable {
    /// Clips of one occasion: a holiday, a birthday, a named trip.
    case event
    /// A day (or a few days running) with several clips and no name yet.
    case unlabelledDay
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
        case .event: return "Event"
        case .unlabelledDay: return "A day to name"
        case .reclaimDrive, .reclaimGroup: return "Reclaim space"
        case .sameFootage: return "Same footage"
        case .junk: return "Probably not worth keeping"
        }
    }

    /// The pane's order (Rick 2026-10-03): events are the point, so they
    /// lead; then the days nobody has named; then same footage; then the
    /// housekeeping — reclaim space (its two shapes as one lane) and junk.
    var lane: Int {
        switch self {
        case .event: return 0
        case .unlabelledDay: return 1
        case .sameFootage: return 2
        case .reclaimDrive, .reclaimGroup: return 3
        case .junk: return 4
        }
    }

    var systemImage: String {
        switch self {
        case .event: return "calendar"
        case .unlabelledDay: return "calendar.badge.plus"
        case .reclaimDrive: return "externaldrive"
        case .reclaimGroup: return "doc.on.doc"
        case .sameFootage: return "square.stack.3d.up"
        case .junk: return "questionmark.folder"
        }
    }
}

/// Why the steward will never propose letting a file go (rule 2 of §5.6:
/// one steward's cases are never another's loss).
///
/// ONE STRENGTH (GH #258, 2026-10-03). Every case here is something the
/// Delete planner itself leaves alone — `.archived` / `.archiveDrive` by
/// `bulkDeleteRefusal`, `.archiveCopy` / `.angel` by
/// `duplicateDeletionHoldRule` — so "never offered" is true of all of them
/// whatever button is pressed. A copy the Angel merely lists, or one
/// labelled Archived in Triage, is an ORDINARY copy: the run may take it
/// (Rick's ruling 2026-10-03), so it is not a case here.
enum StewardProtection: String, Sendable, Equatable {
    case none
    /// A file of the Master Archive.
    case archived
    /// Anywhere else on the Master Archive's drive, or a drive that cannot
    /// be told apart from it right now.
    case archiveDrive
    /// A promoted archive copy while no Master Archive is designated.
    case archiveCopy
    /// In use by the Archive Angel: in a prepared batch, in a batch being
    /// or just promoted, or picked for a Prepare that is still running.
    case angel
    /// On a drive the person marked Read only (2026-10-03).
    case readOnlyDrive

    /// The Delete planner leaves this file alone, and no card proposes it.
    var isProtected: Bool { self != .none }

    /// What it is, as the start of a sentence on the copy's row.
    var words: String {
        switch self {
        case .none: return ""
        case .archived: return "In the archive"
        case .archiveDrive: return "On the archive drive"
        case .archiveCopy: return "A promoted archive copy"
        case .angel: return "In use by the Archive Angel"
        case .readOnlyDrive: return "On a drive you marked Read only"
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
    /// The keeper is on another drive, "Also clean up working copies" is
    /// on — and the Delete planner's own cross-drive rule still would not
    /// take this copy (QA F6(a)): the keeper's drive is not connected,
    /// retired, unknown, or not ranked above this one.
    case workingCopyNotTaken(DuplicateKeeperPolicy.CrossVolumeVerdict)
    /// Not proposed, and the Delete duplicates flow leaves it alone too
    /// (the archive, its drive, a copy the Archive Angel is using).
    case protected(StewardProtection)
    /// Not a duplicate copy at all (a footage or junk row).
    case member
}

/// One copy a Delete duplicates run would decide: its record and drive.
struct StewardRunRow: Sendable, Equatable {
    var id: UUID
    var driveRoot: String
}

/// One file on a card's evidence list.
struct StewardCopy: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    /// "SanDisk"
    var drive: String
    /// "/Volumes/SanDisk"
    var driveRoot: String = ""
    /// The folder under the drive ("Tapes/2006"), "" at the top.
    var folder: String
    var sizeBytes: Int64
    var durationSeconds: Double
    var isOnline: Bool
    var standing: StewardCopyStanding
    /// Same footage: "likely original", "copy", "re-encode"…
    var roleLabel: String = ""
    /// Event: why this clip is in it, in the labeller's own words ("Dec 25
    /// — Christmas", "folder name says 'xmas'", "by matching footage").
    var reason: String = ""
    /// Event: the other occasions this clip also belongs to ("" = none).
    var alsoIn: String = ""
}

/// The numbers a skip remembers, so a skipped case can come back when the
/// facts under it move (StewardSkipStore).
struct StewardFacts: Sendable, Equatable {
    var bytes: Int64
    var count: Int
}

struct StewardCase: Sendable, Equatable, Identifiable {
    /// Stable across launches and re-checks:
    /// "event:<kind>:<subject>:<year>" (the labeller's own key parts:
    /// "event:christmas:-:1994", "event:birthday:alex:2006"),
    /// "day:<yyyy-mm-dd>" (an unnamed run's busiest day), "drive:<root>",
    /// "dup:<the keeper's record id>" (a duplicate check gives the set a
    /// new group id every time; its keeper is what stays),
    /// "footage:<group id>" (the smallest member's record id by design —
    /// FootageMembership.groupID), "junk:<reason>|<drive root>".
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
    /// Copies the Delete planner leaves alone (the archive, its drive, the
    /// copies the Archive Angel is using).
    var protectedCopies: Int = 0
    /// One line per Read-only drive holding copies of the set: "2 copies
    /// on SanDisk are never offered — it is Read only".
    var readOnlyNotes: [String] = []
    /// Every copy of the set a Delete duplicates run would decide, with its
    /// drive — the WHOLE set, not the capped evidence rows (the proof's
    /// "rows of the same run").
    var runRows: [StewardRunRow] = []

    // Same footage
    var footageGroupID: UUID?
    var likelyOriginalID: UUID?
    var likelyOriginalName: String = ""
    var originalInCatalog: Bool = true
    /// The group's reasons, in the grouping's own words.
    var evidenceLines: [String] = []
    /// Same footage: the occasion the group's members point to, shown as a
    /// question (StewardEvents.swift). Never stored, never logged.
    var occasionGuess: StewardOccasionGuess?
    /// "27 clips on 3 drives — likely the same footage · Dec 2006"
    var plainDescription: String = ""

    // Probably not worth keeping
    var junkReason: String = ""

    // Event / a day to name
    /// The labeller's canonical occasion ("christmas", "birthday", "cape");
    /// "" for an unnamed day. The ONLY event word a log line may carry.
    var eventKind: String = ""
    var eventYear: Int?
    /// The clips' lengths added up.
    var durationSeconds: Double = 0
    /// "9 by date · 5 by folder name 'xmas' · 2 by matching footage"
    var whyLine: String = ""
    /// What is inside, from knowledge the catalog already has ("6 of these
    /// are copies of each other (2 sets)", "3 are in the archive", …).
    var insideLines: [String] = []
    /// "5 of these are also in: Cape 1994 · Birthday 1994" ("" = none).
    var alsoInLine: String = ""
    /// The members that are copies of each other — "Review the copies in
    /// this event" (capped at StewardCaseBuilder.maxIDsPerCase).
    var copyReviewIDs: [UUID] = []
}

/// Everything the pane reads. Equality-gated by StewardSnapshot: an
/// unchanged queue publishes nothing.
struct StewardQueue: Sendable, Equatable {
    /// Presentation order: lane after lane (`StewardCaseKind.lane` —
    /// events, days to name, same footage, reclaim space, junk), each in
    /// its own order. The pane may narrow it or re-sort the events by year
    /// (StewardCaseBuilder.arrange).
    var cases: [StewardCase] = []
    /// Clips with a date good enough to place on a day (the Angel's
    /// trusted-day rule), and the clips that were looked at.
    var placedClips = 0
    var placeableClips = 0
    /// Newest duplicate check among the active records.
    var duplicatesLastChecked: Date?
    /// False until the first build lands.
    var isBuilt = false

    func count(of kind: StewardCaseKind) -> Int { cases.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }
}
