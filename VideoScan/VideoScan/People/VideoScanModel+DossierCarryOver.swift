import Foundation
import Combine
import VideoScanCore

// MARK: - Dossier carry-over by content identity (Rick 2026-10-10)
//
// "Analyze one copy per footage group" (docs/design/
// segments_and_content_coverage_2026_10_10.md §2.4 item 2, §7.1): before a
// Dossier batch decodes a file, it asks whether a same-footage sibling
// already HAS dossier text. If so the text is copied — zero decode — and
// the record's provenance says where it came from:
//
//     dossierProcessedBy = "from <sibling uuid> (same bytes)"
//                          "from <sibling uuid> (same footage)"
//
// Who counts as the same footage:
//   * same bytes — VERIFIED content identity, the date lane's rule
//     (`haveVerifiedSameContent`: equal content hashes, else partialMD5 +
//     non-zero size). Never `duplicateGroupID`.
//   * same footage — both rows in one machine footage group at
//     `footageShareMinimumConfidence` (likely) or better, AND the same
//     length (±2 s / 1 %). Captions carry timestamps; without the §3.4
//     alignment (phase 2) only an equal-length copy can reuse them, so a
//     trim or an export of a different length is ANALYZED, not carried.
//   * a person's "not the same footage" decision wins over both — and
//     about ANY member of the group, not just the donor: text that went
//     A → B (carried) must not reach C when Rick said C ≠ A. A group the
//     person has split is ambiguous, so the file is analyzed instead.
//
// Donors: a live (not purged), readable (not `isExcludedFromPropagation`)
// row with a `dossierProcessedAt` stamp and real text (scene captions, or
// a non-degenerate transcript). A row that was itself carried over is a
// donor of last resort — a direct analysis is preferred so provenance
// points at the origin when one is available.
//
// What is written: ONLY the dossier channels (captions, OCR text, OCR
// date candidates, transcript, dossierProcessed*). No date, no name — the
// same rule that makes this safe on an archived row. The date lane
// (`catchUpInferredDates`) owns dates and already shares them across the
// same groups under its own archive guard.
//
// COST. The index is built once per batch: one pass over `records`
// computing two O(1) keys per row, bucketing only the keys the batch's
// candidates hold (≈ the date lane's scoped bucketing). Each donor lookup
// is O(group size). Nothing here touches the disk.
//
// (For Rick: `DossierCarryOverIndex` is a value type holding two hash maps
// of key → [record reference] — `std::unordered_map<Key,
// std::vector<Record*>>`. The records are class instances the model owns;
// the index only points at them, so it sees each sibling's CURRENT state
// when asked — a twin analyzed earlier in the same batch is a donor for
// the next one.)

/// How a donor relates to the recipient — part of the provenance string.
enum DossierCarryRelation: String, Sendable {
    case sameBytes = "same bytes"
    case sameFootage = "same footage"
}

@MainActor
struct DossierCarryOverIndex {

    /// Two copies are "the same length" within this many seconds, or 1 %
    /// of the longer one, whichever is larger.
    static let lengthToleranceSeconds = 2.0

    private var byContent: [CatalogSizeTotals.GroupKey: [VideoRecord]] = [:]
    private var byFootage: [UUID: [VideoRecord]] = [:]

    /// Build over the whole catalog, keeping only the groups the batch's
    /// `candidates` belong to.
    init(records: [VideoRecord], candidates: [VideoRecord]) {
        let minimum = VideoScanModel.footageShareMinimumConfidence
        var contentKeys = Set<CatalogSizeTotals.GroupKey>()
        var footageKeys = Set<UUID>()
        for c in candidates {
            if let k = VideoScanModel.contentGroupKey(c) { contentKeys.insert(k) }
            if let f = c.footage, f.confidence >= minimum { footageKeys.insert(f.groupID) }
        }
        guard !contentKeys.isEmpty || !footageKeys.isEmpty else { return }
        for r in records {
            if let k = VideoScanModel.contentGroupKey(r), contentKeys.contains(k) {
                byContent[k, default: []].append(r)
            }
            if let f = r.footage, f.confidence >= minimum, footageKeys.contains(f.groupID) {
                byFootage[f.groupID, default: []].append(r)
            }
        }
        byContent = byContent.filter { $0.value.count >= 2 }
        byFootage = byFootage.filter { $0.value.count >= 2 }
    }

    /// Number of buckets (tests / the scale sensor).
    var groupCount: Int { byContent.count + byFootage.count }

    /// The best sibling to copy text from, or nil (analyze the file).
    /// Same bytes beats same footage; within a kind, a directly analyzed
    /// donor beats a carried one, then more captions, then a longer
    /// transcript; ties break on the id string (deterministic).
    func donor(for rec: VideoRecord) -> (record: VideoRecord, relation: DossierCarryRelation)? {
        guard !VideoScanModel.isExcludedFromPropagation(rec) else { return nil }
        if let key = VideoScanModel.contentGroupKey(rec), let group = byContent[key],
           !Self.personSplit(rec, from: group) {
            let twins = group.filter {
                $0 !== rec && VideoScanModel.haveVerifiedSameContent(rec, $0) && Self.mayDonate($0, to: rec)
            }
            if let best = Self.best(twins) { return (best, .sameBytes) }
        }
        let minimum = VideoScanModel.footageShareMinimumConfidence
        if let f = rec.footage, f.confidence >= minimum, let group = byFootage[f.groupID],
           !Self.personSplit(rec, from: group) {
            let peers = group.filter { other in
                guard other !== rec, let of = other.footage, of.groupID == f.groupID,
                      of.confidence >= minimum else { return false }
                return Self.sameLength(rec, other) && Self.mayDonate(other, to: rec)
            }
            if let best = Self.best(peers) { return (best, .sameFootage) }
        }
        return nil
    }

    // MARK: Pure rules (static so tests can pin them)

    /// A donor is live, readable, stamped and carries real text.
    static func mayDonate(_ donor: VideoRecord, to rec: VideoRecord) -> Bool {
        donor.purgedAt == nil && donor.dossierProcessedAt != nil
            && !VideoScanModel.isExcludedFromPropagation(donor) && hasText(donor)
    }

    /// True when the person said `rec` is NOT the same footage as any
    /// member of `group` (either side recorded it).
    static func personSplit(_ rec: VideoRecord, from group: [VideoRecord]) -> Bool {
        group.contains { other in
            other !== rec && (rec.footageDecision(about: other.id)?.verdict == .notSame
                              || other.footageDecision(about: rec.id)?.verdict == .notSame)
        }
    }

    /// Scene captions, or a transcript that is not a recognizer artifact.
    static func hasText(_ r: VideoRecord) -> Bool {
        if !r.sceneCaptions.isEmpty { return true }
        guard let t = r.audioTranscript else { return false }
        return !VideoScanModel.isDegenerateDossierText(t)
    }

    /// Equal length within ±2 s or 1 % (both durations known).
    static func sameLength(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        let da = a.durationSeconds, db = b.durationSeconds
        guard da > 0, db > 0 else { return false }
        let tolerance = max(lengthToleranceSeconds, 0.01 * max(da, db))
        return abs(da - db) <= tolerance
    }

    /// True when the row's own dossier was carried over from a sibling.
    static func isCarried(_ r: VideoRecord) -> Bool {
        r.dossierProcessedBy?.hasPrefix(VideoScanModel.dossierCarriedProvenancePrefix) == true
    }

    private static func best(_ donors: [VideoRecord]) -> VideoRecord? {
        donors.min { a, b in
            let ka = (isCarried(a) ? 1 : 0, -a.sceneCaptions.count, -(a.audioTranscript?.count ?? 0), a.id.uuidString)
            let kb = (isCarried(b) ? 1 : 0, -b.sceneCaptions.count, -(b.audioTranscript?.count ?? 0), b.id.uuidString)
            return ka < kb
        }
    }
}

extension VideoScanModel {

    /// Leading text of a carried-over provenance stamp.
    nonisolated static let dossierCarriedProvenancePrefix = "from "

    /// "from <uuid> (same bytes)" — the provenance stamp Rick asked for.
    nonisolated static func dossierCarriedProvenance(from donorID: UUID, relation: DossierCarryRelation) -> String {
        "\(dossierCarriedProvenancePrefix)\(donorID.uuidString) (\(relation.rawValue))"
    }

    /// Copy `donor`'s dossier channels onto `recipient` and stamp the
    /// provenance. Writes ONLY the dossier channels — safe on an archived
    /// row by construction (no date, no name, no flags). One narrative log
    /// line, no transcript or caption text (log privacy).
    func carryOverDossierText(from donor: VideoRecord, to recipient: VideoRecord,
                              relation: DossierCarryRelation, now: Date = Date()) {
        recipient.sceneCaptions = donor.sceneCaptions
        recipient.sceneCaptionModel = donor.sceneCaptionModel
        recipient.sceneCaptionDate = donor.sceneCaptionDate
        recipient.ocrText = donor.ocrText
        recipient.ocrDateCandidates = donor.ocrDateCandidates
        if let transcript = donor.audioTranscript {
            recipient.audioTranscript = transcript
            recipient.audioTranscriptModel = donor.audioTranscriptModel
            recipient.audioTranscriptDate = donor.audioTranscriptDate
        }
        recipient.dossierProcessedAt = now
        recipient.dossierProcessedBy = Self.dossierCarriedProvenance(from: donor.id, relation: relation)

        objectWillChange.send()
        // In-place write — the records array didn't change.
        noteCatalogChangedForDossierCounts()
        saveCatalogDebounced()
        appLog.write("Catalog: dossier \(recipient.filename) — carried over from \(donor.filename) (\(relation.rawValue)), no decode [from \(donor.id.uuidString)]")
    }
}
