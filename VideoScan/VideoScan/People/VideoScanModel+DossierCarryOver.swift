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
//     A same-footage donor must also have the same stream type.
//   * a person's "not the same footage" decision wins over both — about
//     ANY member of the recipient's same-bytes OR same-footage group, and
//     about every hop of a carried donor's "from <uuid>" chain: text that
//     went A → B (carried) must not reach C when Rick said C ≠ A. A group
//     the person has split is ambiguous, so the file is analyzed instead.
//
// Donors: a live (not purged), readable (not `isExcludedFromPropagation`)
// row with a `dossierProcessedAt` stamp that COVERS the recipient's
// channels (QA 2026-10-10): video needs scene captions, audio needs a
// Whisper result (a transcript, or "" for no speech). An A/V-pair video
// half can therefore never stamp the muxed file done without its
// transcript. A row that was itself carried over is a donor of last
// resort — a direct analysis is preferred so provenance points at the
// origin when one is available.
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
    /// Resolves a carried donor's "from <uuid>" back to its origin: the
    /// model's O(1) id index in production, the bucketed records otherwise.
    private let lookup: (UUID) -> VideoRecord?

    /// Build over the whole catalog, keeping only the groups the batch's
    /// `candidates` belong to. `lookup` resolves provenance hops (pass
    /// `model.record(forID:)`); nil falls back to the bucketed records.
    init(records: [VideoRecord], candidates: [VideoRecord],
         lookup: ((UUID) -> VideoRecord?)? = nil) {
        let minimum = VideoScanModel.footageShareMinimumConfidence
        var contentKeys = Set<CatalogSizeTotals.GroupKey>()
        var footageKeys = Set<UUID>()
        for c in candidates {
            if let k = VideoScanModel.contentGroupKey(c) { contentKeys.insert(k) }
            if let f = c.footage, f.confidence >= minimum { footageKeys.insert(f.groupID) }
        }
        var content: [CatalogSizeTotals.GroupKey: [VideoRecord]] = [:]
        var footage: [UUID: [VideoRecord]] = [:]
        if !contentKeys.isEmpty || !footageKeys.isEmpty {
            for r in records {
                if let k = VideoScanModel.contentGroupKey(r), contentKeys.contains(k) {
                    content[k, default: []].append(r)
                }
                if let f = r.footage, f.confidence >= minimum, footageKeys.contains(f.groupID) {
                    footage[f.groupID, default: []].append(r)
                }
            }
        }
        byContent = content.filter { $0.value.count >= 2 }
        byFootage = footage.filter { $0.value.count >= 2 }
        if let lookup {
            self.lookup = lookup
        } else {
            var byID: [UUID: VideoRecord] = [:]
            for group in content.values { for r in group { byID[r.id] = r } }
            for group in footage.values { for r in group { byID[r.id] = r } }
            self.lookup = { byID[$0] }
        }
    }

    /// Number of buckets (tests / the scale sensor).
    var groupCount: Int { byContent.count + byFootage.count }

    /// The recipient's same-bytes and same-footage groups (each may be empty).
    private func groups(of rec: VideoRecord) -> (content: [VideoRecord], footage: [VideoRecord]) {
        let content = VideoScanModel.contentGroupKey(rec).flatMap { byContent[$0] } ?? []
        guard let f = rec.footage, f.confidence >= VideoScanModel.footageShareMinimumConfidence else {
            return (content, [])
        }
        return (content, byFootage[f.groupID] ?? [])
    }

    /// The best sibling to copy text from, or nil (analyze the file).
    /// Same bytes beats same footage; within a kind, a directly analyzed
    /// donor beats a carried one, then more captions, then a longer
    /// transcript; ties break on the id string (deterministic).
    ///
    /// QA 2026-10-10 — P2-b: a person's "not the same" decision between the
    /// recipient and ANY member of the union of its same-bytes and
    /// same-footage groups makes the question ambiguous, so the file is
    /// analyzed; and a carried donor's provenance is walked back to its
    /// origin, every hop free of such a decision, so text never crosses one
    /// through a same-bytes hop. P2-a: the donor must cover every channel
    /// the recipient has (`coversChannels`); a same-footage donor must also
    /// have the same stream type.
    func donor(for rec: VideoRecord) -> (record: VideoRecord, relation: DossierCarryRelation)? {
        guard !VideoScanModel.isExcludedFromPropagation(rec) else { return nil }
        let (content, footage) = groups(of: rec)
        guard !Self.personSplit(rec, from: content + footage) else { return nil }
        let twins = content.filter {
            $0 !== rec && VideoScanModel.haveVerifiedSameContent(rec, $0)
                && Self.mayDonate($0, to: rec) && provenanceIsClear($0, for: rec)
        }
        if let best = Self.best(twins) { return (best, .sameBytes) }
        let peers = footage.filter { other in
            other !== rec && rec.streamTypeRaw == other.streamTypeRaw
                && Self.sameLength(rec, other) && Self.mayDonate(other, to: rec)
                && provenanceIsClear(other, for: rec)
        }
        if let best = Self.best(peers) { return (best, .sameFootage) }
        return nil
    }

    /// Walk a carried donor's "from <uuid>" chain (≤ 16 hops, cycle-safe)
    /// and refuse when the person ruled the recipient and any hop "not the
    /// same". An unresolvable hop ends the walk (the immediate donor was
    /// already checked against the recipient's groups).
    private func provenanceIsClear(_ donor: VideoRecord, for rec: VideoRecord) -> Bool {
        var current = donor
        var seen: Set<UUID> = [donor.id]
        for _ in 0..<16 {
            guard let originID = Self.carriedFromID(current), !seen.contains(originID),
                  let origin = lookup(originID) else { return true }
            if Self.personSplit(rec, from: [origin]) { return false }
            seen.insert(originID)
            current = origin
        }
        return true
    }

    // MARK: Pure rules (static so tests can pin them)

    /// A donor is live, readable, stamped and covers the recipient's
    /// channels.
    static func mayDonate(_ donor: VideoRecord, to rec: VideoRecord) -> Bool {
        donor.purgedAt == nil && donor.dossierProcessedAt != nil
            && !VideoScanModel.isExcludedFromPropagation(donor) && coversChannels(donor, for: rec)
    }

    /// P2-a (QA 2026-10-10): a recipient with video needs a donor with
    /// scene captions; a recipient with audio (anything but video-only)
    /// needs a donor whose Whisper ran — a transcript, or "" for "no
    /// speech" — never a recognizer artifact. Otherwise carry-over would
    /// stamp the recipient done and no batch would ever fill the channel.
    static func coversChannels(_ donor: VideoRecord, for rec: VideoRecord) -> Bool {
        let stream = rec.streamType
        if stream == .videoAndAudio || stream == .videoOnly,
           CaptionTextQuality.usable(donor.sceneCaptions).isEmpty { return false }   // GH #402
        guard stream != .videoOnly else { return true }
        guard let transcript = donor.audioTranscript else { return false }
        return transcript.isEmpty || !CaptionTextQuality.verdict(transcript).isDegenerate
    }

    /// The donor id in a carried stamp "from <uuid> (…)", or nil.
    static func carriedFromID(_ r: VideoRecord) -> UUID? {
        guard let by = r.dossierProcessedBy,
              by.hasPrefix(VideoScanModel.dossierCarriedProvenancePrefix) else { return nil }
        let rest = by.dropFirst(VideoScanModel.dossierCarriedProvenancePrefix.count)
        return UUID(uuidString: String(rest.prefix { $0 != " " }))
    }

    /// True when the person said `rec` is NOT the same footage as any
    /// member of `group` (either side recorded it).
    static func personSplit(_ rec: VideoRecord, from group: [VideoRecord]) -> Bool {
        group.contains { other in
            other !== rec && (rec.footageDecision(about: other.id)?.verdict == .notSame
                              || other.footageDecision(about: rec.id)?.verdict == .notSame)
        }
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
        // GH #402: a carried copy is a fresh write stamped now — it gets the
        // donor's USABLE captions only, never its stored degenerate output.
        recipient.sceneCaptions = CaptionTextQuality.usable(donor.sceneCaptions)
        recipient.sceneCaptionModel = donor.sceneCaptionModel
        recipient.sceneCaptionDate = donor.sceneCaptionDate
        recipient.ocrText = CaptionTextQuality.usable(donor.ocrText)
        recipient.ocrDateCandidates = donor.usableOCRDates
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
