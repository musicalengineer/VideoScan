// VideoScanModel+DateInference.swift
// Inferred-date CATCH-UP and PROPAGATION across a content group
// (Rick 2026-09-12).
//
// THE BUG. /Converted_VHS_Tapes_2026/1991/NV12.mkv exists twice —
// MediaExpansion and the Projects _staging copy — same partialMD5, same
// size, same OCR burn-in "JUN.21 1991 PM11:29" on both. Only the
// Projects copy had inferredRecordDate 1991-06-21; the MediaExpansion
// copy's Date column fell through to the 2026 conversion date. Same
// bytes, same evidence, different answer.
//
// ROOT CAUSE. Dossier results reach a copy by THREE roads, and only
// one of them carries the conclusion:
//   1. `applyDossier` — the record's own VLM/Whisper pass. Writes the
//      channels AND triangulates `inferredRecordDate`. (One copy.)
//   2. `propagateBestDossier` (per-writeback + the load-time backfill)
//      — copies transcript / captions / OCR text / OCR DATE CANDIDATES
//      between partialMD5 siblings, but was written before the date
//      field mattered and never carries `inferredRecordDate`. Nothing
//      re-derives the date from the evidence it just delivered.
//   3. `applyEnrichmentInheritance` — the duplicate-delete keeper fold;
//      carries the date, but only when a copy is REMOVED.
// NV12's MediaExpansion row took road 2: it holds the OCR candidate
// with the Projects copy's model/date stamps, no dossierProcessedAt,
// no date.
//
// THE FIX — three rules, all here, all off the view path:
//   1. CATCH-UP. Any active record with date EVIDENCE (OCR candidates,
//      transcript / caption year mentions) but no inferred date gets one
//      re-derived from that stored evidence by the same `pfInferRecordDate`
//      the dossier pass uses — content tiers only (no mtime fallback:
//      that tier is a fact about one copy, not the footage).
//      Provenance: inferredDateSource = "catch-up".
//   2. PROPAGATION. Within a content group (duplicateGroupID →
//      contentHash → partialMD5+size, the CatalogSizeTotals precedence),
//      the best-confidence content-backed date is copied to every other
//      active member that has NO user date, NO inferred date of its own,
//      and no evidence that DISAGREES. Provenance: "propagated from
//      <donor id>". Mirrors applyHumanMetadataInheritance's fill-the-
//      hole rule for Rick's date / place, but for machine dates.
//   3. FOLDER-YEAR PRIOR (weak). A directory component that is a bare
//      year 1900–2030 ("/1991/") dates an otherwise evidence-less record
//      at year precision, confidence 0.30, provenance "folder-year".
//      Below RecordDateResolver's 0.6 floor by design: it flips the UI
//      from "undated" to "low-confidence guess" (hadRejectedSignal) and
//      makes the year searchable, but never files the archive. It is a
//      PLACEHOLDER — rules 1 and 2 and a real dossier pass all replace
//      it. (applyDossier's own path-year tier stays at 0.50: there a
//      VLM pass ran and found nothing better, which is itself evidence.)
//
// NEVER: overwrite a userDate (not touched at all), overwrite an
// existing own or propagated inference, propagate a copy-local mtime
// tier (< 0.50), write to purged / set-aside / superseded rows, or to
// ffprobe-failed / unanalyzable rows (the smear guard — same predicate
// as dossier propagation, both as donor and recipient).
//
// WHEN. Load (after the dossier backfill that delivers the evidence),
// the 30 s live-reload sweep (scoped to the rows the external merger
// just touched + their groups), and every applyDossier writeback
// (scoped to that record's group). Bounded (`limit` records examined
// for evidence) and logged in ONE line: "date inference: N records
// caught up …".
//
// NOTIFICATIONS. Each touched record gets `searchIndex.update` and a
// record-scoped `.videoScanCatalogMutated` post (the InspectorPlaceView
// shape) so the table and search see the date at once; a bulk pass
// (> perRecordNoticeCap rows) posts once, unscoped, after updating the
// index itself — one SwiftUI invalidation instead of thousands.
//
// COST. One O(records) pass to bucket the groups (a dictionary of
// arrays of references — no record is copied), one regex scan per
// evidence-bearing undated record (2,226 records / 3.6 MB of transcript
// on Rick's catalog: tens of milliseconds), one dictionary walk for
// propagation. Budgeted at 100k records / 5k groups by
// InferredDatePropagationTests.
//
// (For Rick: `static let` constants in an `enum` with no cases ≈ a
// namespace of constexpr strings; `@MainActor static func` predicates
// are free functions that read main-actor-owned objects.)

import Foundation
import Combine

extension VideoScanModel {

    // MARK: - Provenance vocabulary

    /// The `VideoRecord.inferredDateSource` values this file writes.
    /// nil remains "the record's own dossier pass".
    enum InferredDateSource {
        static let catchUp = "catch-up"
        static let folderYear = "folder-year"
        static let propagatedPrefix = "propagated from "
        static func propagated(from donor: VideoRecord) -> String {
            propagatedPrefix + donor.id.uuidString
        }
    }

    /// Year-precision folder prior — see rule 3 in the header.
    static let folderYearPriorConfidence: Float = 0.30
    /// Folder years outside this band are counters, not dates.
    static let folderYearPriorRange: ClosedRange<Int> = 1900...2030
    /// A date travels between copies only when it rests on evidence
    /// about the CONTENT (OCR / speech / captions ≥ 0.55, or the dossier
    /// pass's path-year tier 0.50). The mtime / container tier (0.30) is
    /// a fact about ONE copy — every copy resets it — and never travels.
    static let inferredDatePropagationFloor: Float = 0.50
    /// Above this many touched rows a pass posts ONE unscoped mutation
    /// notice instead of one per record.
    static let inferredDatePerRecordNoticeCap = 50

    // MARK: - Result

    struct InferredDateCatchUpResult: Equatable, Sendable {
        /// Undated, evidence-bearing records the pass ran inference on.
        var examined = 0
        /// Rule 1 — dated from the record's own stored evidence.
        var inferredFromEvidence = 0
        /// Rule 2 — dated from a same-content sibling.
        var propagated = 0
        /// Rule 3 — dated at 0.30 from a bare-year folder.
        var folderYear = 0
        /// `limit` stopped rule 1 early; the rest catch up next pass.
        var truncated = false
        var elapsed: TimeInterval = 0
        var total: Int { inferredFromEvidence + propagated + folderYear }
    }

    // MARK: - Predicates (pure; the tests pin each one)

    /// Rows this file may read from or write to: live in the catalog and
    /// readable. Same three lifecycle guards as the content-hash /
    /// embedded-date backfills, plus the dossier-propagation smear guard.
    @MainActor
    static func isEligibleForDateInference(_ rec: VideoRecord) -> Bool {
        rec.purgedAt == nil && !rec.isSetAside && !rec.isSuperseded
            && !isExcludedFromPropagation(rec)
    }

    /// True when the record holds a date that must not be replaced: its
    /// own dossier triangulation (source nil), a catch-up, or a
    /// propagated one. A folder-year placeholder does NOT count.
    @MainActor
    static func hasSettledInferredDate(_ rec: VideoRecord) -> Bool {
        rec.inferredRecordDate != nil
            && rec.inferredDateSource != InferredDateSource.folderYear
    }

    /// Any stored channel that `pfInferRecordDate` could read a date from.
    @MainActor
    static func hasDateEvidence(_ rec: VideoRecord) -> Bool {
        !rec.ocrDateCandidates.isEmpty
            || !(rec.audioTranscript ?? "").isEmpty
            || !rec.sceneCaptions.isEmpty
    }

    /// The record's content-group identity, in the CatalogSizeTotals
    /// precedence (duplicateGroupID → contentHash → partialMD5 + size).
    /// nil when the record carries no duplicate signal at all — a group
    /// of one has nobody to share with.
    @MainActor
    static func contentGroupKey(_ rec: VideoRecord) -> CatalogSizeTotals.GroupKey? {
        let key = CatalogSizeTotals.groupKey(for: CatalogSizeTotals.Entry(
            id: rec.id, sizeBytes: rec.sizeBytes,
            duplicateGroupID: rec.duplicateGroupID,
            contentHash: rec.contentHash, partialMD5: rec.partialMD5,
            isArchived: false))
        return key.isSolo ? nil : key
    }

    /// Rule 1 core: what the record's OWN stored evidence says. Content
    /// tiers only — no path hint, no mtime, no container time — so a nil
    /// result means "the evidence names no date", never "we guessed".
    @MainActor
    static func inferDateFromStoredEvidence(_ rec: VideoRecord) -> (date: Date, confidence: Float)? {
        let r = pfInferRecordDate(
            ocrDateCandidates: rec.ocrDateCandidates.map(\.text),
            audioTranscript: rec.audioTranscript,
            sceneCaptionTexts: rec.sceneCaptions.map(\.text),
            pathYearHints: [],
            fileMtime: nil,
            containerCreationTime: nil)
        guard let d = r.date else { return nil }
        return (d, r.confidence)
    }

    /// Rule 2 guard: may `rec` take `donor`'s date? Eligible, no user
    /// date, no settled inference, and its own evidence (if it names a
    /// year at all) agrees with the donor's year.
    @MainActor
    static func canReceivePropagatedDate(_ rec: VideoRecord, from donor: VideoRecord) -> Bool {
        guard rec.id != donor.id,
              isEligibleForDateInference(rec),
              rec.userDate == nil,
              !hasSettledInferredDate(rec),
              let donorDate = donor.inferredRecordDate else { return false }
        if let ownYear = pfContentEvidenceYear(
            ocrDateCandidates: rec.ocrDateCandidates.map(\.text),
            audioTranscript: rec.audioTranscript,
            sceneCaptionTexts: rec.sceneCaptions.map(\.text)) {
            let donorYear = pfGregorianCalendar.component(.year, from: donorDate)
            if ownYear != donorYear { return false }
        }
        return true
    }

    /// Rule 2 donor test: a settled, content-backed date on a readable,
    /// live row.
    @MainActor
    static func canDonateInferredDate(_ rec: VideoRecord) -> Bool {
        isEligibleForDateInference(rec)
            && hasSettledInferredDate(rec)
            && (rec.inferredDateConfidence ?? 0) >= inferredDatePropagationFloor
    }

    /// Rule 3 guard: nothing else says anything about the date.
    @MainActor
    static func qualifiesForFolderYearPrior(_ rec: VideoRecord) -> Bool {
        isEligibleForDateInference(rec)
            && rec.inferredRecordDate == nil
            && rec.userDate == nil
            && rec.embeddedCreationDate == nil
            && !hasDateEvidence(rec)
    }

    // MARK: - Single-record writes (the only three places a date is set here)

    /// Rule 2 write. Returns false (nothing mutated) when the guard fails.
    @MainActor
    @discardableResult
    static func propagateInferredDate(from donor: VideoRecord, to rec: VideoRecord) -> Bool {
        guard canDonateInferredDate(donor), canReceivePropagatedDate(rec, from: donor) else { return false }
        rec.inferredRecordDate = donor.inferredRecordDate
        rec.inferredDateConfidence = donor.inferredDateConfidence
        rec.inferredDateSource = InferredDateSource.propagated(from: donor)
        return true
    }

    @MainActor
    private static func applyCatchUp(_ rec: VideoRecord, date: Date, confidence: Float) {
        rec.inferredRecordDate = date
        rec.inferredDateConfidence = confidence
        rec.inferredDateSource = InferredDateSource.catchUp
    }

    @MainActor
    private static func applyFolderYear(_ rec: VideoRecord, year: Int) -> Bool {
        guard let d = pfJanuaryFirst(of: year) else { return false }
        rec.inferredRecordDate = d
        rec.inferredDateConfidence = folderYearPriorConfidence
        rec.inferredDateSource = InferredDateSource.folderYear
        return true
    }

    // MARK: - The pass

    /// Run rules 1–3. `scope == nil` walks the whole catalog; otherwise
    /// only the given records AND every member of their content groups
    /// (a sibling with its own evidence should get its own date rather
    /// than a propagated one). `limit` bounds rule 1's evidence scans.
    /// Never touches disk directly — one debounced save at the end.
    @MainActor
    @discardableResult
    func catchUpInferredDates(scope: [VideoRecord]? = nil,
                              limit: Int = 50_000,
                              trigger: String = "manual") -> InferredDateCatchUpResult {
        let started = Date()
        var result = InferredDateCatchUpResult()

        // One pass: bucket every eligible row by content group. References
        // only; the arrays hold pointers to records the model already owns.
        var groups: [CatalogSizeTotals.GroupKey: [VideoRecord]] = [:]
        for rec in records where Self.isEligibleForDateInference(rec) {
            if let key = Self.contentGroupKey(rec) {
                groups[key, default: []].append(rec)
            }
        }

        // The rows this pass may write to, and the groups it may share within.
        let (candidates, groupKeys) = Self.dateInferenceScope(scope, allRecords: records, groups: groups)

        var touched: [VideoRecord] = []

        // Rule 1 — own evidence.
        for rec in candidates where Self.isEligibleForDateInference(rec)
            && !Self.hasSettledInferredDate(rec)
            && Self.hasDateEvidence(rec) {
            if result.examined >= limit { result.truncated = true; break }
            result.examined += 1
            if let hit = Self.inferDateFromStoredEvidence(rec) {
                Self.applyCatchUp(rec, date: hit.date, confidence: hit.confidence)
                result.inferredFromEvidence += 1
                touched.append(rec)
            }
        }

        // Rule 2 — share within each group from its best-confidence donor.
        for key in groupKeys {
            guard let members = groups[key], members.count >= 2 else { continue }
            let donors = members.filter { Self.canDonateInferredDate($0) }
            guard let donor = donors.max(by: {
                ($0.inferredDateConfidence ?? 0) < ($1.inferredDateConfidence ?? 0)
            }) else { continue }
            for rec in members where Self.propagateInferredDate(from: donor, to: rec) {
                result.propagated += 1
                touched.append(rec)
            }
        }

        // Rule 3 — the weak folder prior, only where nothing else spoke.
        for rec in candidates where Self.qualifiesForFolderYearPrior(rec) {
            guard let year = pfBareYearFolderPrior(in: rec.fullPath),
                  Self.applyFolderYear(rec, year: year) else { continue }
            result.folderYear += 1
            touched.append(rec)
        }

        result.elapsed = Date().timeIntervalSince(started)
        if !touched.isEmpty {
            announceInferredDateChanges(touched)
        }
        if result.total > 0 || result.truncated {
            log(Self.dateInferenceLogLine(result, limit: limit, trigger: trigger))
        }
        return result
    }

    /// Which rows a pass may write to and which groups it may share within:
    /// the whole catalog, or the scoped rows plus every member of their
    /// content groups (a sibling with its own evidence should get its own
    /// date rather than a propagated one).
    @MainActor
    private static func dateInferenceScope(
        _ scope: [VideoRecord]?,
        allRecords: [VideoRecord],
        groups: [CatalogSizeTotals.GroupKey: [VideoRecord]]
    ) -> (candidates: [VideoRecord], groupKeys: [CatalogSizeTotals.GroupKey]) {
        guard let scope else { return (allRecords, Array(groups.keys)) }
        var seen = Set<UUID>()
        var rows: [VideoRecord] = []
        var keys: [CatalogSizeTotals.GroupKey] = []
        var seenKeys = Set<CatalogSizeTotals.GroupKey>()
        for rec in scope {
            if seen.insert(rec.id).inserted { rows.append(rec) }
            if let key = Self.contentGroupKey(rec), seenKeys.insert(key).inserted {
                keys.append(key)
                for member in groups[key] ?? [] where seen.insert(member.id).inserted {
                    rows.append(member)
                }
            }
        }
        return (rows, keys)
    }

    /// The one line a pass writes: "date inference: N records caught up (…)".
    static func dateInferenceLogLine(_ r: InferredDateCatchUpResult, limit: Int, trigger: String) -> String {
        "date inference: \(r.total) record\(r.total == 1 ? "" : "s") caught up "
            + "(\(r.inferredFromEvidence) from own evidence, \(r.propagated) propagated, "
            + "\(r.folderYear) folder-year prior; \(r.examined) examined"
            + (r.truncated ? ", limit \(limit) hit — more next pass" : "")
            + String(format: ", %.0f ms, ", r.elapsed * 1000) + trigger + ")"
    }

    /// applyDossier's hook: the record just gained (or refreshed) its own
    /// date — share it with its content group. Returns the number of
    /// siblings dated.
    @MainActor
    @discardableResult
    func propagateInferredDate(from donor: VideoRecord) -> Int {
        // Solo rows have nobody to share with; skip the group walk.
        guard Self.contentGroupKey(donor) != nil else { return 0 }
        return catchUpInferredDates(scope: [donor], trigger: "dossier").propagated
    }

    // MARK: - Publish

    /// Index + notify + save for a batch of dated rows. Record-scoped
    /// notices up to the cap (the Inspector shape: the listener refreshes
    /// that record's search entry and schedules the save); beyond it, the
    /// index is refreshed here and ONE unscoped notice goes out.
    @MainActor
    private func announceInferredDateChanges(_ touched: [VideoRecord]) {
        for rec in touched { searchIndex.update(rec) }
        if touched.count <= Self.inferredDatePerRecordNoticeCap {
            for rec in touched {
                NotificationCenter.default.post(name: .videoScanCatalogMutated, object: rec)
            }
        } else {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }
        // In-place writes the records didSet cannot see.
        noteCatalogChangedForDossierCounts()
        noteCatalogRecordsMutated()
        objectWillChange.send()
        saveCatalogDebounced()
    }
}

// MARK: - Bare-year folder prior (pure)

/// The deepest DIRECTORY component that is exactly a 4-digit year inside
/// `VideoScanModel.folderYearPriorRange` — "/…/1991/NV12.mkv" → 1991.
/// "Christmas2010" is NOT a bare year (that is applyDossier's 0.50 path
/// hint, which needs a dossier pass behind it); the filename is never
/// consulted (RecordDateResolver already reads filename dates at 0.5).
nonisolated func pfBareYearFolderPrior(in fullPath: String) -> Int? {
    let directory = (fullPath as NSString).deletingLastPathComponent
    let parts = (directory as NSString).pathComponents
    for component in parts.reversed() {
        guard component.count == 4, component.allSatisfy(\.isNumber),
              let y = Int(component),
              VideoScanModel.folderYearPriorRange.contains(y) else { continue }
        return y
    }
    return nil
}
