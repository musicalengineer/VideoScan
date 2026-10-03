// StewardWords.swift
// Every sentence the steward pane says that is decided by a rule rather
// than typed into a view (trial UI, 2026-10-03): the per-section freshness
// note, why an action is off, why a copy was chosen as the keeper, and the
// one-line log entries. Pure functions, so the words are unit-tested and
// the views only place them.
//
// Friendly language throughout — the family reads these.
//
// (For Rick: three small `enum` namespaces of static functions; nothing
// here holds state.)

import Foundation

// MARK: - How current is what the card rests on

enum StewardFreshness {

    /// "duplicates checked 2 h ago · 14 files not checked yet"
    /// `lastChecked`: the newest duplicate check on any record (the
    /// builder's); `counts`: the Analyze coverage snapshot's duplicates row.
    nonisolated static func duplicates(lastChecked: Date?, counts: AnalyzeCoverageCounts, now: Date) -> String {
        var parts: [String] = []
        if let lastChecked {
            parts.append("duplicates checked \(AnalyzeRowStateRule.relative(lastChecked, now: now))")
        } else {
            parts.append("duplicates not checked yet")
        }
        if counts.remaining > 0 {
            parts.append("\(counts.remaining.formatted()) file\(counts.remaining == 1 ? "" : "s") not checked yet")
        }
        if counts.offline > 0 {
            parts.append("\(counts.offline.formatted()) on drives not connected")
        }
        return parts.joined(separator: " · ")
    }

    /// "same footage looked for 3 h ago · 2,410 files grouped"
    /// `counts`: the snapshot's footage row (`secondary` = grouped files,
    /// `newestStamp` = the last run). Files in no group carry no mark, so
    /// the note never claims how many were NOT looked at.
    nonisolated static func footage(counts: AnalyzeCoverageCounts, now: Date) -> String {
        guard let last = counts.newestStamp else { return "same footage not looked for yet" }
        return "same footage looked for \(AnalyzeRowStateRule.relative(last, now: now))"
            + " · \(counts.secondary.formatted()) file\(counts.secondary == 1 ? "" : "s") grouped"
    }

    /// The junk score has no date of its own: it is whatever Triage's
    /// Analyze button last worked out.
    static let junk = "from the last time Analyze was run in this tab"

    nonisolated static func line(for kind: StewardCaseKind, duplicatesLastChecked: Date?,
                                 report: AnalyzeCoverageReport, now: Date) -> String {
        switch kind {
        case .reclaimDrive, .reclaimGroup:
            return duplicates(lastChecked: duplicatesLastChecked, counts: report.counts(.duplicates), now: now)
        case .sameFootage:
            return footage(counts: report.counts(.footage), now: now)
        case .junk:
            return junk
        }
    }
}

// MARK: - Why an action is on or off

/// An action button's state: on, or off with the reason in words.
struct StewardActionGate: Sendable, Equatable {
    var isEnabled: Bool
    /// The tooltip, and — when off — the line under the button.
    var reason: String

    static let perGroupDeleteGap = "Deleting just this set arrives later; for now this cleans the whole drive's duplicates."
    static let namingGap = "Naming a set of footage arrives later. For now the title is a description, or a guess from the date."

    /// "Delete duplicates on <drive>…" — the existing flow, this drive
    /// preselected. `offeredByDeleteFlow`: the drive is in the flow's own
    /// list (the model's cached `deletableDupVolumes`).
    nonisolated static func deleteDuplicates(isReadOnly: Bool, isDeleteRunning: Bool, driveLabel: String,
                                             driveConnected: Bool, offeredByDeleteFlow: Bool,
                                             needsWorkingCopyMode: Bool) -> StewardActionGate {
        if isReadOnly {
            return StewardActionGate(isEnabled: false, reason: "This Mac is a read-only viewer of the catalog.")
        }
        if driveLabel.isEmpty {
            return StewardActionGate(isEnabled: false, reason: "None of these copies is on a drive that can be cleaned.")
        }
        if !driveConnected {
            return StewardActionGate(isEnabled: false, reason: "\(driveLabel) is not connected — connect it first.")
        }
        if isDeleteRunning {
            return StewardActionGate(isEnabled: false,
                                     reason: "A Delete duplicates run is already going — see Media File Operations.")
        }
        if !offeredByDeleteFlow {
            return StewardActionGate(isEnabled: false, reason: needsWorkingCopyMode
                ? "The copy to keep is on another drive. Delete duplicates only cleans copies like these when “\(WorkingCopyCleanupText.toggleLabel)” is on (Storage tab)."
                : "No duplicate copies on \(driveLabel) can be deleted right now.")
        }
        return StewardActionGate(isEnabled: true,
                                 reason: "Opens Delete duplicates with \(driveLabel) chosen. The next step shows what would happen and asks again.")
    }

    /// Anything that changes the catalog or opens a sheet that can.
    nonisolated static func catalogAction(isReadOnly: Bool, help: String) -> StewardActionGate {
        isReadOnly ? StewardActionGate(isEnabled: false, reason: "This Mac is a read-only viewer of the catalog.")
                   : StewardActionGate(isEnabled: true, reason: help)
    }
}

// MARK: - What would happen to one copy

enum StewardStandingWords {

    /// The line under one copy on a Reclaim set card. "Never offered" is
    /// said of what the Delete planner itself leaves alone — which, since
    /// GH #258, is every protected copy: the archive, its drive, the
    /// Angel's picks and copies filed as Archived.
    nonisolated static func words(for copy: StewardCopy, proof: StewardCopyProof?) -> String? {
        switch copy.standing {
        case .keeper:
            return "The one to keep."
        case .wouldBeChecked:
            guard let proof else { return "Delete duplicates on \(copy.drive) would check this copy." }
            return (["If this copy goes, \(proof.remainLine).", proof.outcomeLine] + [proof.caveatLine].compactMap { $0 })
                .joined(separator: " ")
        case .keeperOnAnotherDrive:
            return "Left alone for now — the copy to keep is on another drive."
        case .protected(let why):
            return "\(why.words) — never offered."
        case .member:
            return nil
        }
    }
}

// MARK: - Why this copy is the one to keep

enum StewardKeeperReason {

    /// The keeper election compares, in order: is the drive connected and
    /// in use · the drive order · the person's own marks · quality · name
    /// (DuplicateKeeperPolicy.ElectionKey). The reason is the FIRST of
    /// those on which the keeper beats the best other copy.
    nonisolated static func words(keeper: DuplicateKeeperPolicy.ElectionKey,
                                  others: [DuplicateKeeperPolicy.ElectionKey],
                                  keeperDrive: String, keeperIsInArchive: Bool) -> String {
        guard let rival = others.max() else { return "It is the only copy in the set." }
        guard keeper > rival else {
            return "It was chosen at the last duplicate check. The drive order has changed since — the next duplicate check will choose again."
        }
        if keeper.availability != rival.availability {
            return "It is on a drive that is connected and in use; the others are on drives that are away or retired."
        }
        if keeper.precedence != rival.precedence {
            return keeperIsInArchive
                ? "It is the copy in the Master Archive."
                : "Its drive, \(keeperDrive), comes first in your drive order."
        }
        if keeper.humanMetadata != rival.humanMetadata {
            return "It carries more of your own marks — ratings, names, notes, dates."
        }
        if keeper.technical != rival.technical {
            return "It is the best-quality copy."
        }
        return "The copies are equal, so the first by name was chosen."
    }
}

// MARK: - Log lines (one per user action; never a name or a full path)

enum StewardLog {
    enum Verb: String, Sendable {
        case shown, skipped, broughtBack = "brought back", acted
    }

    /// "Tidy suggestions: skipped — Reclaim space [drive SanDisk] · 1,208 files · 412 GB".
    /// The subject is the drive for drive and junk cases and the group id
    /// for sets — never a filename, a title (an event guess can carry a
    /// person's name) or a folder.
    nonisolated static func line(_ verb: Verb, _ c: StewardCase, action: String? = nil) -> String {
        let subject: String
        switch c.kind {
        case .reclaimDrive: subject = "drive \(c.driveLabel)"
        case .reclaimGroup: subject = "set \(c.duplicateGroupID?.uuidString.prefix(8) ?? "?")"
        case .sameFootage: subject = "footage \(c.footageGroupID?.uuidString.prefix(8) ?? "?")"
        case .junk: subject = "\(c.junkReason) on \(c.driveLabel)"
        }
        let size = ByteCountFormatter.string(fromByteCount: c.facts.bytes, countStyle: .file)
        var text = "Tidy suggestions: \(verb.rawValue) — \(c.kind.chip) [\(subject)] · \(c.facts.count.formatted()) file\(c.facts.count == 1 ? "" : "s") · \(size)"
        if let action { text += " · \(action)" }
        return text
    }
}
