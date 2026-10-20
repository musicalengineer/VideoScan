// InspectorPanelRules.swift
// The inspector's decisions — which sections show, and the exact label
// text — as plain functions of the record, so they can be pinned by unit
// tests without building a view (refactor R4, GH #281). Lifted verbatim
// from `InspectorPanel.body`; the view now asks these instead of
// repeating the expressions inline. Behaviour-preserving: every function
// returns exactly what the old inline expression produced.
//
// (A Swift caseless `enum` ≈ a C++ namespace of free functions.)

import Foundation
import VideoScanCore

enum InspectorPanelRules {

    // MARK: - Header

    /// The stream-type chip under the filename: the playability verdict
    /// for files ffprobe could not read, else the stream type's raw text.
    static func streamBadgeText(_ rec: VideoRecord) -> String {
        rec.streamType == .ffprobeFailed ? rec.isPlayable : rec.streamTypeRaw
    }

    /// The orange "missing half" chip: an unpaired video-only file has no
    /// audio, an unpaired audio-only file has no video. nil = no chip.
    static func missingStreamBadge(_ rec: VideoRecord) -> String? {
        if rec.streamType == .videoOnly && rec.pairedWith == nil { return "NO AUDIO" }
        if rec.streamType == .audioOnly && rec.pairedWith == nil { return "NO VIDEO" }
        return nil
    }

    /// The cyan Avid tape/clip card under the volume name.
    static func showsAvidIdentity(_ rec: VideoRecord) -> Bool {
        rec.hasAvidMetadata && (!rec.avidTapeName.isEmpty || !rec.avidClipName.isEmpty)
    }

    // MARK: - Section visibility (sections not listed here always show)

    static func showsDossier(_ rec: VideoRecord) -> Bool {
        rec.dossierProcessedAt != nil
    }

    static func showsCorrelation(_ rec: VideoRecord) -> Bool {
        rec.pairedWith != nil || rec.pairConfidence != nil
    }

    static func showsTrim(_ rec: VideoRecord, hasDerivatives: Bool) -> Bool {
        rec.trimInSeconds != nil || hasDerivatives
    }

    static func showsMasterArchive(masterCopy: VideoRecord?, promotionSource: VideoRecord?) -> Bool {
        masterCopy != nil || promotionSource != nil
    }

    /// The Angel's assessment only shows on records that are NOT already
    /// on either side of a promotion — archived content is not a candidate.
    static func showsAngelAssessment(hasEvidence: Bool, masterCopy: VideoRecord?,
                                     promotionSource: VideoRecord?) -> Bool {
        hasEvidence && masterCopy == nil && promotionSource == nil
    }

    static func showsRepair(_ rec: VideoRecord) -> Bool {
        rec.isAwaitingConfirmation || rec.repairConfirmedDate != nil || rec.isSuperseded
    }

    static func showsDuplicates(_ rec: VideoRecord) -> Bool {
        rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty
    }

    static func showsAvidProject(_ rec: VideoRecord) -> Bool {
        rec.hasAvidMetadata
    }

    static func showsUserNotes(_ rec: VideoRecord) -> Bool {
        !rec.userNotes.isEmpty
    }

    static func showsNotes(_ rec: VideoRecord) -> Bool {
        !rec.notes.isEmpty
    }

    // MARK: - Row text

    /// Timestamps ▸ Embedded.
    @MainActor   // the formatter belongs to a SwiftUI view, so it is main-actor isolated
    static func embeddedDateText(_ date: Date) -> String {
        InspectorDateView.embeddedFormatter.string(from: date) + " UTC"
    }

    /// Trim ▸ Kept.
    static func trimKeptText(inSeconds: Double, outSeconds: Double) -> String {
        "\(TrimTimecode.format(inSeconds)) – \(TrimTimecode.format(outSeconds))"
    }

    /// Master Archive: the link label on a source that has an archive copy.
    /// A copy promoted FROM this record is its master; otherwise the archive
    /// holds an identical copy of it.
    static func masterCopyLabel(copy: VideoRecord, record: VideoRecord) -> String {
        copy.derivedFrom == record.id ? "Master copy ✓" : "Identical copy in archive ✓"
    }

    /// Master Archive ▸ Fixity, on the source's row for its archive copy.
    static func masterCopyFixityText(_ fixity: ArchiveFixity) -> String {
        "\(fixity.algorithm) \(fixity.digest.prefix(16))…"
    }

    /// Master Archive ▸ Fixity, on the archive copy itself (with when).
    static func archiveCopyFixityText(_ fixity: ArchiveFixity) -> String {
        "\(fixity.algorithm) \(fixity.digest.prefix(16))… · verified \(fixity.verifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Repair ▸ Status. The three states are checked in this order, so an
    /// awaiting copy never reads as confirmed or superseded.
    static func repairStatusText(_ rec: VideoRecord) -> String? {
        if rec.isAwaitingConfirmation {
            return "Waiting for your OK — play it, then confirm"
        } else if let confirmedAt = rec.repairConfirmedDate {
            return "Confirmed \(confirmedAt.formatted(date: .abbreviated, time: .shortened))"
        } else if rec.isSuperseded {
            return "Superseded — hidden from the everyday view, never deleted"
        }
        return nil
    }

    /// Purged / set-aside repair copies are not confirmable (QA M1) — the
    /// model refuses too; this keeps the button honest.
    static func showsConfirmRepair(_ rec: VideoRecord, hasRepairSource: Bool) -> Bool {
        rec.isAwaitingConfirmation && hasRepairSource && !rec.isPurged && !rec.isSetAside
    }

    /// Duplicates ▸ Status (also used by "Copy All Metadata").
    static func duplicateStatusText(_ rec: VideoRecord) -> String {
        rec.duplicateGroupCount >= 2
            ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
            : rec.duplicateDisposition.rawValue
    }

    /// Duplicates ▸ the group header; the group counts this record too.
    static func duplicateGroupHeader(otherMembers: Int) -> String {
        "Duplicate Group (\(otherMembers + 1) total)"
    }

    // MARK: Same footage, different file (2026-10-19)

    /// The members of `rec`'s footage group that are NOT byte copies of it
    /// (their whole-file digests differ, or one is unknown) — a re-encode,
    /// a rewrap, another codec or container. Byte copies are the duplicate
    /// group's business. Pure: the caller hands in the group's members
    /// (memoized, never computed in a view body).
    static func sameFootageOthers(of rec: VideoRecord, groupMembers: [VideoRecord]) -> [VideoRecord] {
        guard let g = rec.footage?.groupID else { return [] }
        let mine = VideoScanModel.storedFullDigest(rec)
        return groupMembers.filter { other in
            guard other.id != rec.id, other.footage?.groupID == g else { return false }
            guard let mine, let theirs = VideoScanModel.storedFullDigest(other) else { return true }
            return mine != theirs
        }
    }

    /// "Christmas 1990.mov (DV, MOV)" — the other file, its codec and its
    /// container, in the catalog's own words.
    static func sameFootageLine(_ other: VideoRecord) -> String {
        let codec = DuplicateLikeness.codecWords(other.videoCodec.isEmpty ? other.audioCodec : other.videoCodec)
        let container = (other.filename as NSString).pathExtension.uppercased()
        let facts = [codec, container].filter { !$0.isEmpty }.joined(separator: ", ")
        return facts.isEmpty ? other.filename : "\(other.filename) (\(facts))"
    }

    /// "Same footage as (possible)" (schema v1.11): for each WEAK likeness
    /// pair of `rec`'s content (footage_likeness), the other content's
    /// first live file — unless a person already answered the pair (any
    /// footage decision between a file of either content and a file of the
    /// other: "not the same" suppresses it, "same" makes it a footage link)
    /// or the file already shows as "Same footage". Pure: the caller hands
    /// in the live records of the contents involved (memoized, never in a
    /// view body). Evidence only — nothing here is delete eligibility.
    static func possibleSameFootage(of rec: VideoRecord, pairs: [FootageLikenessStore.Pair],
                                    recordsByDigest: [String: [VideoRecord]], shown: [VideoRecord]) -> [VideoRecord] {
        guard let mine = VideoScanModel.storedFullDigest(rec)?.lowercased() else { return [] }
        let copies = (recordsByDigest[mine] ?? []) + [rec]
        let shownIDs = Set(shown.map(\.id))
        var out: [VideoRecord] = []
        for pair in pairs where pair.isWeak {
            let others = (recordsByDigest[pair.otherDigest] ?? []).filter { $0.removal == nil }
                .sorted { $0.fullPath < $1.fullPath }
            guard let first = others.first, !others.contains(where: { shownIDs.contains($0.id) }) else { continue }
            guard !answered(copies, others) else { continue }
            out.append(first)
        }
        return out
    }

    /// Has a person answered "same" / "not the same" between any file of
    /// one side and any file of the other (either direction)?
    static func answered(_ side: [VideoRecord], _ other: [VideoRecord]) -> Bool {
        let otherIDs = Set(other.map(\.id)), sideIDs = Set(side.map(\.id))
        return side.contains { r in r.footageDecisions.contains { otherIDs.contains($0.otherID) } }
            || other.contains { r in r.footageDecisions.contains { sideIDs.contains($0.otherID) } }
    }

    /// The Duplicates section shows for a flagged copy OR for a file with
    /// same-footage partners (so the relationship is never hidden).
    static func showsDuplicatesOrSameFootage(_ rec: VideoRecord, sameFootage: [VideoRecord]) -> Bool {
        showsDuplicates(rec) || !sameFootage.isEmpty
    }

    /// Avid Project ▸ Edit Rate; empty (row hidden) when unknown.
    static func editRateText(_ rate: Double) -> String {
        rate > 0 ? String(format: "%.2f fps", rate) : ""
    }
}
