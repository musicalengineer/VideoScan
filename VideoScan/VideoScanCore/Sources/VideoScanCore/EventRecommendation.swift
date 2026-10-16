// EventRecommendation.swift
// The eight recommendations of the Event Analyzer — the verdict plus what the
// archive holds (docs/design/event_analyzer_compare_media_2026_10_15.md §4).
//
//   R1  identical copy; the other is archived      Master is archived. Remove this copy.
//   R2  clip of an archived master                 Master is archived. Remove the clip; cut a fresh one later.
//   R3  same recording, the archived one is better Remove this transfer so the newest codec survives.
//   R4  same recording, THIS one is better         Promote it, then retire the old master.
//   R5  same event, different capture              Keep both; group them under one event.
//   R6  same event, nothing archived yet           Promote the best capture as the master.
//   R7  different events                           Nothing to do.
//   R8  not enough evidence                        Fingerprint and hash these first.
//
// Rulings (Rick 2026-10-15): a DVD rip is a transfer like any other (the disc
// is the backup); for content before 2000, "promote the better transfer" is
// offered before any removal, and the only transfer of an unarchived recording
// is never removed (that is R6). Every recommendation is advice: the door it
// names proves things at the move; nothing here moves a file.

import Foundation

public enum EventRule: String, Sendable, Equatable, CaseIterable {
    case r1, r2, r3, r4, r5, r6, r7, r8
}

/// Where the recommendation's one button goes.
public enum EventDoor: Sendable, Equatable {
    case cleanupCopies, cleanupClips, cleanupTransfers, promote, groupAsEvent, recommendMaster, fingerprint, none
}

public struct EventRecommendation: Sendable, Equatable {
    public var rule: EventRule
    /// The sentence, bold verb first.
    public var words: String
    /// One line of why.
    public var why: String
    public var door: EventDoor
    /// The side the door acts on (the copy to remove, the transfer to promote).
    public var subject: PairSide?

    /// Rick's era rule: content before this year gets the upgrade offered first.
    public static let olderGenerationsBefore = 2000

    public static func recommend(_ verdict: RelatedVerdict, evidence e: RelatedEvidence) -> EventRecommendation {
        switch verdict.band {
        case .notEnoughEvidence where e.a.isOnDisk == false || e.b.isOnDisk == false:
            return .init(rule: .r8, words: "Rescan the drive: a catalog row points at a file that is not there.",
                         why: verdict.lines.first(where: { $0.kind == .missing })?.words ?? "The file is not at its path.",
                         door: .fingerprint, subject: e.a.isOnDisk == false ? .a : .b)
        case .notEnoughEvidence:
            return .init(rule: .r8, words: "Fingerprint and hash these first; the analyzer can't say yet.",
                         why: (verdict.lines.first(where: { $0.kind == .missing && $0.words.localizedCaseInsensitiveContains("fingerprint") })
                               ?? verdict.lines.first(where: { $0.kind == .missing }))?.words ?? "A fingerprint or a full hash is missing.",
                         door: .fingerprint, subject: nil)
        case .differentEvents:
            return .init(rule: .r7, words: "Nothing to do.", why: verdict.headline, door: .none, subject: nil)
        case .differentCapture:
            return .init(rule: .r5, words: "Keep both. Different footage of one event — group them under one event.",
                         why: "Nothing in either is covered by the other.", door: .groupAsEvent, subject: nil)
        case .clipFromSameEvent(let clip, let seconds, _):
            return clipRule(clip: clip, seconds: seconds, e)
        case .sameEvent:
            return sameEvent(verdict, e)
        }
    }


    /// Rung 5, one side cut from the other: R2 when the master is archived
    /// and the clip is not; R6 when nothing is; an archived clip is never a
    /// removal subject (round 1 F1) and, with an unarchived master, asks for
    /// the master to be promoted (round 2 F2).
    static func clipRule(clip: PairSide, seconds: Double, _ e: RelatedEvidence) -> EventRecommendation {
        let master = other(clip)
        let clipSide = side(e, clip), masterSide = side(e, master)
        if clipSide.isArchiveFile || clipSide.isArchived {
            if masterSide.isArchived {
                return .init(rule: .r7, words: "Both are in the archive. Nothing to do here.",
                             why: "The clip is an archive file (or its content is archived); the archive's own lanes decide.", door: .none, subject: nil)
            }
            return .init(rule: .r6, words: "The clip is archived but its master is not. Promote the master; the clip stays.",
                         why: "The longer recording holds \(RelatedLadder.mmss(seconds)) the archive has and \(RelatedLadder.mmss(masterSide.durationSeconds - seconds)) it does not.",
                         door: .recommendMaster, subject: master)
        }
        if masterSide.isArchived {
            return .init(rule: .r2, words: "Master is archived. Remove the clip; cut a fresh one from the master when you want it.",
                         why: "The \(RelatedLadder.mmss(seconds)) clip holds nothing the master lacks.", door: .cleanupClips, subject: clip)
        }
        return .init(rule: .r6, words: "Nothing is archived. Promote the master, then revisit the clip.",
                     why: "The longer recording is the one to keep; the clip is cut from it.", door: .recommendMaster, subject: master)
    }

    /// Rung 6 and rung 5 whole: which side is archived decides.
    static func sameEvent(_ verdict: RelatedVerdict, _ e: RelatedEvidence) -> EventRecommendation {
        let archivedSides = [PairSide.a, .b].filter { side(e, $0).isArchived || side(e, $0).isArchiveFile }
        if archivedSides.count == 2 {
            return .init(rule: .r7, words: "Both are in the archive. Nothing to do here.",
                         why: "Two archive files of one recording; the archive's own lanes decide.", door: .none, subject: nil)
        }
        if verdict.isIdenticalCopy {
            if let archived = archivedSides.first {
                return .init(rule: .r1, words: "Master is archived. Remove this copy.",
                             why: "Cleanup proves it against the archived file at the move.", door: .cleanupCopies, subject: other(archived))
            }
            return .init(rule: .r6, words: "Nothing is archived. Promote one as the master, then remove the other.",
                         why: "Byte for byte the same; either can be the master.", door: .recommendMaster, subject: .a)
        }
        // Two transfers of one recording.
        let better = verdict.better ?? .tie
        guard let archived = archivedSides.first else {
            let pick = better.side ?? .a
            return .init(rule: .r6, words: "Nothing is archived. Promote the \(better.side == nil ? "longer" : "better") transfer as the master, then revisit the other.",
                         why: why(better) ?? "Two transfers, neither archived.", door: .recommendMaster, subject: pick)
        }
        let theOther = other(archived)
        if better.side == theOther {
            return .init(rule: .r4, words: "This transfer is better than the archived one. Promote it, then retire the old master.",
                         why: why(better) ?? "", door: .promote, subject: theOther)
        }
        // The archived one is better, or it is a tie: the other transfer can go — unless the
        // era rule holds the upgrade question open: a tie on pre-2000 content is not a removal.
        if better.side == nil, isOlderGeneration(e) {
            return .init(rule: .r5, words: "Keep both for now. Two transfers of one pre-2000 recording and neither is clearly better.",
                         why: "Older generations first: the upgrade is offered before any removal.", door: .groupAsEvent, subject: nil)
        }
        return .init(rule: .r3, words: "Master is archived in the better transfer. Remove this transfer so the newest codec is what survives.",
                     why: why(better) ?? "The archived transfer is as good as this one.", door: .cleanupTransfers, subject: theOther)
    }

    /// Reliable years decide; when neither side has a reliable day, any
    /// year counts. An unreliable newer date (a 2006 rip of a 1988 tape)
    /// never defeats the protection (codex 10/15 F2).
    /// ANY pre-2000 reading protects (round 2 F1): reliable 1988 against
    /// reliable 2015 is a date conflict to resolve first, not a removal;
    /// unreliable 1988 against unreliable 2006 keeps both until a date is
    /// corrected, after which R3 can apply.
    static func isOlderGeneration(_ e: RelatedEvidence) -> Bool {
        let reliable = [e.a, e.b].filter { $0.dayIsReliable }.compactMap(\.year)
        let years = reliable.isEmpty ? [e.a.year, e.b.year].compactMap { $0 } : reliable
        return years.contains { $0 < olderGenerationsBefore }
    }
    static func side(_ e: RelatedEvidence, _ s: PairSide) -> RelatedEvidence.Side { s == .a ? e.a : e.b }
    static func other(_ s: PairSide) -> PairSide { s == .a ? .b : .a }
    static func why(_ b: BetterTransfer) -> String? {
        switch b {
        case .a(let why), .b(let why): return "The better one is \(why)."
        case .tie: return nil
        }
    }
}
