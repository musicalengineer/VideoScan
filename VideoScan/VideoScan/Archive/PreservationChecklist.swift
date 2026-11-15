// PreservationChecklist.swift
// "Where does this footage stand?" — the ladder at the top of the File
// Journey sheet (Rick 2026-11-14, replacing the 2026-08-12 four: Catalogued
// / Signed / Archived locally / Archived offsite).
//
//   Catalogued   it is in the catalog — since when
//   Analyzed     the machine's passes that apply have all run
//   Reviewed     the person did something to it: a date, a note, a name
//   Archived     a copy is in the archive, on disk, checked bit for bit
//   Offsite      shown only once the person has answered the question
//
// THREE RULES KEEP IT HONEST.
//
// 1. A tick comes from evidence, never from a field standing in for a check
//    (hard rule 1). Archived needs the copy ON DISK (one stat, by the
//    caller) AND a whole-file SHA-256. A sampled signature, an MD5, a copy
//    record whose file is gone, the legacy stage stamp, a recorded
//    BackupEntry — none of them tick anything.
//
// 2. An open circle is real work for the person (the 2026-08-12 rule: a
//    checklist that cries wolf is worse than none). So the machine's own
//    backlog is not drawn as the person's to-do — Analyzed that is not
//    finished reads "in the queue" — and Offsite is absent until the person
//    has said yes or no.
//
// 3. The app cannot see a cloud or an off-site copy. Offsite is the person's
//    WORD (BackupAttestation), drawn apart from the green ticks and left out
//    of "N of M": the count is what the app can prove.
//
// The ladder answers for the FOOTAGE, not the row: FileJourneyBuilder reads
// the row, its archived copy and that copy's source together, and hands the
// result here as `PreservationEvidence`. Scoring is pure — no record, no
// disk — so the truth table is pinned by tests.
//
// (For Rick: `PreservationEvidence` is a plain struct of facts; `steps(from:)`
// is a pure function over it, like a C++ free function taking a const POD.)

import Foundation
import SwiftUI

// MARK: - Evidence (what the builder found)

/// When the footage came into the catalog. `isExact` is false when the first
/// day was never recorded and `date` is only the earliest date the catalog
/// holds for it — shown "by …", never as the day itself.
struct JourneyCatalogued: Equatable {
    var date: Date?
    var isExact: Bool = false
}

/// One machine pass that applies to this footage.
struct JourneyAnalysisItem: Equatable {
    let title: String
    let covered: Bool
    /// When its stamp was written, where the record carries one.
    let at: Date?
}

/// The content analyzers that apply to this footage, and which have run —
/// the same per-file rule Catalog Status counts.
struct JourneyAnalysis: Equatable {
    var items: [JourneyAnalysisItem] = []

    var done: Bool { !items.isEmpty && items.allSatisfy(\.covered) }
    var latest: Date? { items.compactMap(\.at).max() }
    var waiting: [String] { items.filter { !$0.covered }.map(\.title) }
    var coveredCount: Int { items.filter(\.covered).count }
}

/// What the person has done to this footage. `acts` are short nouns in the
/// order found ("date set", "2 people confirmed", "note").
struct JourneyReview: Equatable {
    var acts: [String] = []
    /// The latest of the acts that carry a date (several carry none).
    var latest: Date?

    var done: Bool { !acts.isEmpty }
}

/// Where the footage stands with the archive.
enum JourneyArchiveStanding: Equatable {
    /// No copy of it is in the archive.
    case notArchived
    /// A copy is in the archive, on disk now, known by a whole-file SHA-256.
    /// `checkedAt`: the latest full read-back that matched, when later.
    case archived(place: String, at: Date?, checkedAt: Date?)
    /// A copy record exists but the tick is not earned; `todo` names why.
    case unproven(todo: String)
}

/// The person's word about a copy out of the building.
struct JourneyOffsite: Equatable {
    /// true = "yes, there is one"; false = "no".
    let exists: Bool
    /// "iCloud", "Tim's house" — what the person typed, or the kind's word.
    let label: String
    let at: Date
}

/// Everything the ladder is scored from.
struct PreservationEvidence: Equatable {
    var catalogued = JourneyCatalogued()
    var analysis = JourneyAnalysis()
    var review = JourneyReview()
    var archive = JourneyArchiveStanding.notArchived
    /// nil = the person has not answered (or said "not applicable"): no step.
    var offsite: JourneyOffsite?
}

// MARK: - A step

/// One step of the ladder, already scored.
struct PreservationStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case catalogued, analyzed, reviewed, archived, offsite
    }

    enum State: Equatable {
        /// Proven: the green tick.
        case done
        /// Not done, and it is the person's move (`todo` says what).
        case open
        /// Not done, and it is the machine's move: nothing for the person.
        case waiting
        /// The person's word, which the app cannot check: drawn apart.
        case attested
    }

    let kind: Kind
    let state: State
    /// When it happened, when we know. Absent is not failure.
    var date: Date?
    /// "by " when `date` is a bound and not the day itself.
    var datePrefix: String = ""
    /// The small line under the title: where, how many, whose word.
    var detail: String = ""
    /// What to do about it — the person's move (`.open`), or what the
    /// machine still has to run (`.waiting`). Empty when done.
    var todo: String = ""

    var id: String { kind.rawValue }
    var done: Bool { state == .done }

    var title: String {
        switch kind {
        case .catalogued: return "Catalogued"
        case .analyzed:   return "Analyzed"
        case .reviewed:   return "Reviewed"
        case .archived:   return "Archived"
        case .offsite:    return "Offsite"
        }
    }

    var icon: String {
        switch state {
        case .done:     return "checkmark.circle.fill"
        case .open:     return "circle"
        case .waiting:  return "clock"
        case .attested: return "person.crop.circle.badge.checkmark"
        }
    }

    var color: Color {
        switch state {
        case .done:     return .green
        case .attested: return .blue
        case .open, .waiting: return .secondary
        }
    }
}

// MARK: - Scoring (pure)

enum PreservationChecklist {

    static let reviewTodo = "Open it and confirm its date, name who is in it, or write a note."
    static let archiveTodo = "Promote to Archive — copy it to the archive."
    static let offsiteTodo = "Get a copy out of the building."

    /// The ladder, in order. Offsite is present only when the person answered.
    static func steps(from e: PreservationEvidence) -> [PreservationStep] {
        var out = [catalogued(e.catalogued), analyzed(e.analysis), reviewed(e.review), archived(e.archive)]
        if let offsite = e.offsite { out.append(self.offsite(offsite)) }
        return out
    }

    /// Holding the record is the proof; the date is the day, or a bound.
    static func catalogued(_ c: JourneyCatalogued) -> PreservationStep {
        PreservationStep(kind: .catalogued, state: .done, date: c.date,
                         datePrefix: c.date != nil && !c.isExact ? "by " : "")
    }

    /// Ticked when every analyzer that applies has run. Otherwise it is the
    /// machine's queue — never an open circle for the person. A file nothing
    /// applies to (no bytes, retired) has nothing waiting and no tick.
    static func analyzed(_ a: JourneyAnalysis) -> PreservationStep {
        if a.done {
            return PreservationStep(kind: .analyzed, state: .done, date: a.latest,
                                    detail: "\(a.items.count) of \(a.items.count) passes")
        }
        guard !a.items.isEmpty else {
            return PreservationStep(kind: .analyzed, state: .waiting, detail: "nothing to analyze")
        }
        return PreservationStep(kind: .analyzed, state: .waiting,
                                detail: "\(a.coveredCount) of \(a.items.count) passes · in the queue",
                                todo: "Content Analysis still has to run: \(a.waiting.joined(separator: ", ")).")
    }

    static func reviewed(_ r: JourneyReview) -> PreservationStep {
        guard r.done else { return PreservationStep(kind: .reviewed, state: .open, todo: reviewTodo) }
        return PreservationStep(kind: .reviewed, state: .done, date: r.latest, detail: summary(r.acts))
    }

    /// "date set · note" — the first two acts, then how many more.
    static func summary(_ acts: [String]) -> String {
        let shown = acts.prefix(2).joined(separator: " · ")
        return acts.count > 2 ? shown + " · +\(acts.count - 2)" : shown
    }

    static func archived(_ s: JourneyArchiveStanding) -> PreservationStep {
        switch s {
        case .notArchived:
            return PreservationStep(kind: .archived, state: .open, todo: archiveTodo)
        case .unproven(let todo):
            return PreservationStep(kind: .archived, state: .open, todo: todo)
        case .archived(let place, let at, let checkedAt):
            var detail = place
            // A later full read-back is worth its own words; the promote's
            // own read-back is the archive date itself. With no archive day
            // on record, the check is all there is — said as a check, never
            // shown as the day it was archived.
            if let checkedAt, at.map({ checkedAt.timeIntervalSince($0) > 86_400 }) ?? true {
                detail += "\nchecked \(shortDate(checkedAt))"   // its own line: never wrapped mid-date
            }
            return PreservationStep(kind: .archived, state: .done, date: at, detail: detail)
        }
    }

    /// The person's word: "yes" is drawn apart (never the green tick), "no"
    /// is an open step with its door.
    static func offsite(_ o: JourneyOffsite) -> PreservationStep {
        guard o.exists else {
            return PreservationStep(kind: .offsite, state: .open, date: nil, detail: "you said: none", todo: offsiteTodo)
        }
        return PreservationStep(kind: .offsite, state: .attested, date: o.at, detail: "your word · \(o.label)")
    }

    // MARK: Summary

    /// "3 of 4" counts what the app can PROVE: the person's word is not in
    /// the numerator or the denominator.
    static func tally(_ steps: [PreservationStep]) -> (done: Int, of: Int) {
        let provable = steps.filter { $0.state != .attested }
        return (provable.filter(\.done).count, provable.count)
    }

    /// The next thing worth saying: the person's first open step; with none,
    /// what the machine still has to run; nil when nothing is left.
    static func nextAction(_ steps: [PreservationStep]) -> String? {
        if let open = steps.first(where: { $0.state == .open && !$0.todo.isEmpty }) { return open.todo }
        return steps.first { $0.state == .waiting && !$0.todo.isEmpty }?.todo
    }

    /// The line under the ladder. "Next:" is said only of the person's own
    /// move; the machine's queue is stated as it is, never as their to-do.
    static func nextLine(_ steps: [PreservationStep]) -> String? {
        guard let action = nextAction(steps) else { return nil }
        let isPersons = steps.contains { $0.state == .open && !$0.todo.isEmpty }
        return isPersons ? "Next: \(action)" : action
    }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d ''yy"
        return f.string(from: date)
    }
}

// MARK: - View

/// The ladder strip at the top of the File Journey sheet. Takes scored
/// steps, never a record: the sheet is a pure function of one `FileJourney`,
/// so the ladder and the timeline under it cannot describe different states.
struct PreservationChecklistStrip: View {
    let steps: [PreservationStep]

    var body: some View {
        let tally = PreservationChecklist.tally(steps)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("PRESERVATION")
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(0.8)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(tally.done) of \(tally.of)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tally.done == tally.of ? .green : .secondary)
                    .accessibilityIdentifier("fileJourney.ladder.tally")
            }

            // Left to right, because the steps are a sequence and the gap
            // shows at a glance. Each takes an equal share of the width.
            HStack(alignment: .top, spacing: 8) {
                ForEach(steps) { step in
                    stepColumn(step)
                }
            }

            if let next = PreservationChecklist.nextLine(steps) {
                Text(next)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fileJourney.ladder.next")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func stepColumn(_ step: PreservationStep) -> some View {
        VStack(spacing: 4) {
            Image(systemName: step.icon)
                .font(.system(size: 30))
                .foregroundColor(step.color)
            Text(step.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(step.state == .open || step.state == .waiting ? .secondary : .primary)
            if let date = step.date {
                Text(step.datePrefix + PreservationChecklist.shortDate(date))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(step.color)
            }
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .help(step.todo.isEmpty ? step.title : step.todo)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fileJourney.ladder.\(step.kind.rawValue)")
    }
}
