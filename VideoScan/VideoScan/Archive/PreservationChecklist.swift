// PreservationChecklist.swift
// "Is this file safe yet?" — the journey, scored.
//
// Rick's idea, 2026-08-12: the File Journey sheet already tells a file's
// history, but history is passive. Turning the end of it into a row of
// checkmarks makes the sheet ask a question instead — *what is still
// missing before this video is actually safe?* — and an unchecked box
// is a nudge in a way a paragraph never is.
//
// THE ONE RULE THAT KEEPS IT HONEST: every unchecked box must represent
// REAL WORK TO DO. Rick's first sketch included "migrated" as a step,
// and it was the one to leave out — most files never need migrating, so
// that box would sit grey forever on perfectly safe media and teach the
// eye to ignore the whole widget. A checklist that cries wolf is worse
// than no checklist. Migrations, combines, and repairs still appear in
// the timeline below as history; they are simply not SCORED.
//
// So the four steps are the 3-2-1 spine (see [[project_archive_strategy]]),
// each one genuinely actionable:
//
//   Catalogued        we know the file exists
//   Signed            it has a content signature — the prerequisite for
//                     both duplicate detection and verified copying
//   Archived locally  a second copy on local archival media
//   Archived offsite  a third copy somewhere the house fire is not
//
// Signed sits second on purpose: it is the step that makes the two
// archive steps trustworthy. Copying a file you cannot verify afterwards
// is how silent corruption gets promoted to "backed up".
//
// THE SECOND RULE (integrity_first §2, codex 2026-10-16): a tick comes
// from evidence, never from a row field standing in for a check. The
// archived copy proves "Archived locally" only when it is ON DISK (the
// caller probes it) AND known by a whole-file SHA-256 — the same proof
// Signed demands. An MD5, an absent fixity, or a copy whose file is not
// at its path leaves the box open and names the next door.
//
// Pure over a VideoRecord plus the probe's answer, no I/O — so the sheet
// can render it and tests can pin the truth table.

import Foundation
import SwiftUI

/// One scored step in a file's preservation journey.
struct PreservationStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case catalogued, signed, archivedLocally, archivedOffsite
    }

    let kind: Kind
    let done: Bool
    /// When it happened, when we know. Absent is not failure — plenty of
    /// history predates our recording it — so the UI shows the tick
    /// without a date rather than implying the step is incomplete.
    let date: Date?
    /// What to do about it, shown when the step is NOT done. This is the
    /// difference between a scold and an instruction.
    let todo: String

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .catalogued:      return "Catalogued"
        case .signed:          return "Signed"
        case .archivedLocally: return "Archived locally"
        case .archivedOffsite: return "Archived offsite"
        }
    }

    var icon: String { done ? "checkmark.circle.fill" : "circle" }
    var color: Color { done ? .green : .secondary }
}

enum PreservationChecklist {

    /// One step's verdict with its evidence date and its next door.
    struct Verdict: Equatable {
        let done: Bool
        let date: Date?
        let todo: String
    }

    /// Score one record — for the CONTENT it stands for (Rick 2026-10-16).
    /// `archivedCopy` is the row's promoted archive copy when it has one
    /// (`VideoScanModel.archivedCopy(of:)`); `archivedCopyPresence` is what
    /// the disk said about that copy (`JourneyPresence.probe`) — nil means
    /// nobody looked, which is not the same as "there".
    static func steps(for rec: VideoRecord, archivedCopy: VideoRecord? = nil,
                      archivedCopyPresence: JourneyPresence? = nil) -> [PreservationStep] {
        // Cloud and offsite both satisfy "not in this building", which
        // is the only property that matters against fire and theft.
        let away = rec.backupDestinations.first {
            $0.kind == .cloud || $0.kind == .offsite
        }
        let signature = contentSignature(of: rec, archivedCopy: archivedCopy)
        let local = localArchive(of: rec, archivedCopy: archivedCopy, presence: archivedCopyPresence)

        return [
            PreservationStep(
                kind: .catalogued,
                done: true,   // holding the record is the proof
                date: rec.scanContext.scannedAt ?? rec.dateModifiedRaw,
                todo: ""),
            PreservationStep(
                kind: .signed,
                done: signature.done,
                date: signature.date,
                todo: "Compute a file signature so copies can be verified "
                    + "and duplicates found."),
            PreservationStep(
                kind: .archivedLocally,
                done: local.done,
                date: local.date,
                todo: local.todo),
            PreservationStep(
                kind: .archivedOffsite,
                done: away != nil,
                date: away?.date,
                todo: "Get a copy out of the building."),
        ]
    }

    /// Signed answers for the CONTENT: this row's own signature (the
    /// segmented content hash, or a whole-file SHA-256 fixity), else its
    /// archived copy's — the read-back digest Promote recorded, or the
    /// copy's whole-file fixity. Pure; no disk.
    static func contentSignature(of rec: VideoRecord, archivedCopy: VideoRecord?) -> (done: Bool, date: Date?) {
        if rec.hasContentSignature { return (true, rec.contentHashAt) }
        for holder in [rec, archivedCopy].compactMap({ $0 })
        where ArchivePromotionIndex.verifiedDigest(of: holder) != nil {
            return (true, holder.archiveFixity?.verifiedAt ?? holder.contentFixity?.computedAt)
        }
        return (false, nil)
    }

    /// "Archived locally" answers for a copy that is ON DISK and known by
    /// a whole-file SHA-256 (`ArchivePromotionIndex.verifiedDigest`). A
    /// recorded local BackupEntry or the archived stage still count —
    /// older bookkeeping, not a promise about a copy record. When the box
    /// stays open, the todo names why: the fixity, or the copy's absence.
    static func localArchive(of rec: VideoRecord, archivedCopy: VideoRecord?,
                             presence: JourneyPresence?) -> Verdict {
        if let local = rec.backupDestinations.first(where: { $0.kind == .local }) {
            return Verdict(done: true, date: local.date, todo: "")
        }
        if rec.archiveStage == .archived { return Verdict(done: true, date: nil, todo: "") }
        guard let archivedCopy else {
            return Verdict(done: false, date: nil, todo: "Copy to archival storage — the master RAID.")
        }
        guard let presence, presence.isPresent else {
            return Verdict(done: false, date: nil, todo: copyNotOnDiskTodo(presence))
        }
        guard ArchivePromotionIndex.verifiedDigest(of: archivedCopy) != nil else {
            return Verdict(done: false, date: nil, todo: "Verify Archive (record a SHA-256 fixity).")
        }
        return Verdict(done: true,
                       date: archivedCopy.archiveFixity?.verifiedAt ?? archivedCopy.contentFixity?.computedAt,
                       todo: "")
    }

    /// The next door when the copy record exists but its file was not
    /// seen: unplugged, unreadable, unchecked, or simply not there.
    private static func copyNotOnDiskTodo(_ presence: JourneyPresence?) -> String {
        switch presence {
        case .volumeOffline(let volume)?:
            return "Connect \(volume) — the archived copy could not be checked."
        case .unknown(let reason)?, .linkTargetUnknown(_, let reason)?:
            return "The archived copy could not be checked (\(reason)) — then run Verify Archive."
        case nil:
            return "Run Verify Archive — the archived copy has not been checked on disk."
        default:
            return "Run Verify Archive — the archived copy is not at its path."
        }
    }

    /// How far along, 0…1. Drives the summary line.
    static func completion(for rec: VideoRecord, archivedCopy: VideoRecord? = nil,
                           archivedCopyPresence: JourneyPresence? = nil) -> Double {
        let all = steps(for: rec, archivedCopy: archivedCopy, archivedCopyPresence: archivedCopyPresence)
        guard !all.isEmpty else { return 0 }
        return Double(all.filter(\.done).count) / Double(all.count)
    }

    /// The next thing worth doing, or nil when the file is safe.
    static func nextAction(for rec: VideoRecord, archivedCopy: VideoRecord? = nil,
                           archivedCopyPresence: JourneyPresence? = nil) -> String? {
        steps(for: rec, archivedCopy: archivedCopy, archivedCopyPresence: archivedCopyPresence)
            .first { !$0.done }?.todo
    }
}

// MARK: - View

/// The checklist strip shown at the top of the File Journey sheet.
///
/// Takes already-scored steps rather than a record: the sheet is a pure
/// function of one `FileJourney` value, and scoring at build time means
/// the checklist and the timeline below it can never describe different
/// states of the same file.
struct PreservationChecklistStrip: View {
    let steps: [PreservationStep]

    private var complete: Bool { steps.allSatisfy(\.done) }
    private var nextAction: String? { steps.first { !$0.done }?.todo }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("PRESERVATION")
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(0.6)
                    .foregroundColor(.secondary)
                Spacer()
                Text(complete
                     ? "safe"
                     : "\(steps.filter(\.done).count) of \(steps.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(complete ? .green : .secondary)
            }

            // Horizontal, because the steps are a sequence and reading
            // left-to-right makes the gap obvious at a glance — which is
            // the entire purpose of scoring them.
            HStack(alignment: .top, spacing: 14) {
                ForEach(steps) { step in
                    VStack(spacing: 3) {
                        Image(systemName: step.icon)
                            .font(.system(size: 15))
                            .foregroundColor(step.color)
                        Text(step.title)
                            .font(.system(size: 10))
                            .foregroundColor(step.done ? .primary : .secondary)
                            .multilineTextAlignment(.center)
                        if let date = step.date, step.done {
                            Text(Self.shortDate(date))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(minWidth: 74)
                    .help(step.done ? step.title : step.todo)
                }
                Spacer(minLength: 0)
            }

            // Say what to do next, not merely that something is missing.
            if let next = nextAction {
                Text("Next: \(next)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d ''yy"
        return f.string(from: date)
    }
}
