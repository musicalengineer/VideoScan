// VideoScanModel+DateInference.swift
// Inferred-date CATCH-UP and PROPAGATION across a content group
// (Rick 2026-09-12; identity + budget hardening after codex review
// #1413 / #1415 the same evening).
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
//   2. PROPAGATION. Within a VERIFIED content group, the best-confidence
//      content-backed date is copied to every other active member that
//      has NO user date, NO inferred date of its own, whose own evidence
//      was examined (rule 1) this pass or earlier, and whose evidence
//      does not DISAGREE at its own precision. Provenance: "propagated
//      from <donor id>". Mirrors applyHumanMetadataInheritance's fill-
//      the-hole rule for Rick's date / place, but for machine dates.
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
// IDENTITY (codex #1413). A date may only travel between rows that are
// VERIFIED to hold the same bytes: equal `contentHash` (the segmented /
// full signature), else equal `partialMD5` AND equal `sizeBytes`. A
// `duplicateGroupID` is NEVER sufficient — DuplicateDetector hands those
// out to heuristic low / medium groups (timecode, filename stem,
// duration) that can score high while the full hashes CONFLICT, and a
// strong OCR date persisted onto different footage would then be
// frozen by the settled-inference guard. Two rows whose content hashes
// conflict are rejected even when they share a group and a partialMD5.
//
// BUDGET (codex #1415). Rule 1 examines at most `limit` rows per pass.
// A row whose evidence was NOT examined (deferred) is never a rule-2
// recipient — its own OCR might say DEC 25 while a sibling says JUN 21,
// and rule 2 must not settle it before rule 1 has read it. Rows whose
// evidence was examined and named NO date are remembered on the model
// (`inferredDateNoDateEvidence`, fingerprint-validated) so the next
// bounded pass skips them for free and ADVANCES past them instead of
// re-reading the same noise prefix.
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
// arrays of references — no record is copied; a SCOPED pass computes
// every key but only buckets the scope's groups), one regex scan per
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
        /// GH #201 rule 2b: the date came from the footage group's
        /// strongest member. Re-derived every pass (never a donor).
        static let footageSharedPrefix = "footage-shared from "
        static func footageShared(from donor: VideoRecord) -> String {
            footageSharedPrefix + donor.id.uuidString
        }
    }

    /// GH #201: the People tab's birth years are re-read this often.
    static let dateInferencePeopleTTL: TimeInterval = 300

    /// The catch-up pass writes this reason when it clears a legacy
    /// filesystem-tier "inference" (the old 0.30 mtime fallback).
    static let clearedFilesystemReason = DateTriangulationResult.noEvidenceReason
        + " (a file's copy date is never an inferred date)"

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
        /// Undated, evidence-bearing records skipped for free because an
        /// earlier pass already classified the same evidence as naming
        /// no date (codex #1415 d).
        var alreadyClassified = 0
        /// Undated, evidence-bearing records `limit` left unexamined —
        /// neither dated nor allowed to receive a sibling's date this
        /// pass (codex #1415 a).
        var deferred = 0
        /// Rule 1 — dated from the record's own stored evidence.
        var inferredFromEvidence = 0
        /// Rule 2 — dated from a same-content sibling.
        var propagated = 0
        /// Rule 3 — dated at 0.30 from a bare-year folder.
        var folderYear = 0
        /// GH #201 rule 2b — took the footage group's strongest claim.
        var footageShared = 0
        /// GH #201 — a legacy own / catch-up date re-derived by the
        /// triangulator (now carries a written reason).
        var retriangulated = 0
        /// GH #201 — a legacy filesystem-tier date, or a stale
        /// footage-shared date, cleared to nil.
        var cleared = 0
        /// `limit` stopped rule 1 early; the rest catch up next pass.
        var truncated = false
        var elapsed: TimeInterval = 0
        var total: Int { inferredFromEvidence + propagated + folderYear + footageShared + retriangulated }
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

    /// GH #201: true when the row's date came from its footage group
    /// (rule 2b provenance) — re-derived every pass, never a donor.
    @MainActor
    static func isFootageSharedInferredDate(_ rec: VideoRecord) -> Bool {
        rec.inferredDateSource?.hasPrefix(InferredDateSource.footageSharedPrefix) == true
    }

    /// GH #201: a date the OLD triangulator wrote (no written reason) on a
    /// row that has evidence to re-read — its own dossier pass (source
    /// nil) or a catch-up. Re-derived ONCE by the scored triangulator so
    /// it gains a reason, a year span and the export-stamp / era-floor /
    /// now-cue rules (Clip 19's 1955 → 1996). Propagated, folder-year and
    /// footage-shared rows are recomputed by their own rules instead.
    @MainActor
    static func needsRetriangulation(_ rec: VideoRecord) -> Bool {
        rec.inferredRecordDate != nil
            && rec.inferredDateReason == nil
            && (rec.inferredDateSource == nil || rec.inferredDateSource == InferredDateSource.catchUp)
            && hasDateEvidence(rec)
    }

    /// GH #201: a legacy own-pass date with NO evidence behind it under
    /// 0.50 — the old mtime / container-time fallback (Rick's "filesystem
    /// fallback wearing the inferred label"). Cleared to nil with a reason.
    @MainActor
    static func isLegacyFilesystemInference(_ rec: VideoRecord) -> Bool {
        rec.inferredRecordDate != nil
            && rec.inferredDateReason == nil
            && rec.inferredDateSource == nil
            && !hasDateEvidence(rec)
            && (rec.inferredDateConfidence ?? 0) < inferredDatePropagationFloor
    }

    /// GH #201: the triangulator's view of one record. Folder hints ride
    /// along only when the row has some content evidence (a VLM / Whisper
    /// pass, or a burn-in) — an evidence-less row is rule 3's business.
    @MainActor
    static func triangulationInput(for rec: VideoRecord, people: [DateTriangulationPerson],
                                   includePathHints: Bool, now: Date = Date()) -> DateTriangulationInput {
        var input = DateTriangulationInput()
        input.ocrDateCandidates = rec.ocrDateCandidates.map(\.text)
        input.audioTranscript = rec.audioTranscript
        input.sceneCaptionTexts = rec.sceneCaptions.map(\.text)
        input.pathYearHints = includePathHints ? pfPathYearHints(in: rec.fullPath) : []
        input.embeddedCreationDate = rec.embeddedCreationDate
        input.originMake = rec.originMake
        input.originModel = rec.originModel
        input.originEncoder = rec.originEncoder
        input.videoCodec = rec.videoCodec
        input.container = rec.container
        input.fullPath = rec.fullPath
        input.peopleOnRecord = rec.confirmedByUserPeople.map(\.name) + rec.detectedPeople
        input.people = people
        input.now = now
        return input
    }

    /// GH #201: write a triangulation onto the record — date, confidence,
    /// span, reason, provenance. A nil date CLEARS the fields and keeps the
    /// reason ("no evidence…") so the inspector can say what was looked at.
    @MainActor
    static func applyTriangulation(_ r: DateTriangulationResult, to rec: VideoRecord, source: String?) {
        rec.inferredRecordDate = r.date
        rec.inferredDateConfidence = r.date == nil ? nil : r.confidence
        rec.inferredDateRange = r.date == nil ? nil : r.range
        rec.inferredDateReason = r.reason
        rec.inferredDateSource = r.date == nil ? nil : source
    }

    /// GH #201: the People tab's birth years, loaded once from the POI
    /// profiles (read-only — `HallieShellCLI.loadProfilesReadOnly` never
    /// migrates or writes) and refreshed every `dateInferencePeopleTTL`.
    /// Under a test host the real People store is never read: tests get
    /// `[]` unless they inject `dateInferencePeople` (isolation).
    @MainActor
    var dateInferencePeopleResolved: [DateTriangulationPerson] {
        if let people = dateInferencePeople,
           let at = dateInferencePeopleLoadedAt, Date().timeIntervalSince(at) < Self.dateInferencePeopleTTL {
            return people
        }
        if let people = dateInferencePeople, dateInferencePeopleLoadedAt == nil { return people }   // injected
        guard !TestEnvironment.isTestHost else { return dateInferencePeople ?? [] }
        let loaded = Self.loadDateInferencePeople()
        dateInferencePeople = loaded
        dateInferencePeopleLoadedAt = Date()
        return loaded
    }

    /// Profiles → (name, aliases, birth year). Profiles without a birth
    /// date are left out: they cannot corroborate an age.
    static func loadDateInferencePeople() -> [DateTriangulationPerson] {
        guard case .loaded(let profiles) = HallieShellCLI.loadProfilesReadOnly() else { return [] }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return profiles.compactMap { p in
            guard let birth = p.birthdate else { return nil }
            return DateTriangulationPerson(name: p.name, aliases: p.aliases,
                                           birthYear: utc.component(.year, from: birth))
        }
    }

    /// The record's VERIFIED content-group identity: partialMD5 + size
    /// (the DuplicateDetector "h|" bucket, the dossier-propagation key),
    /// else the segmented / full `contentHash` for a row that was never
    /// partially hashed. `duplicateGroupID` is deliberately NOT a key —
    /// see IDENTITY in the header. nil when the record carries no
    /// verifiable identity at all — a group of one has nobody to share
    /// with. (The `CatalogSizeTotals.GroupKey` enum is reused for its
    /// `.byteTwin` / `.contentHash` cases; `.duplicateGroup` is never
    /// produced here.)
    @MainActor
    static func contentGroupKey(_ rec: VideoRecord) -> CatalogSizeTotals.GroupKey? {
        if !rec.partialMD5.isEmpty, rec.sizeBytes > 0 {
            return .byteTwin(md5: rec.partialMD5, sizeBytes: rec.sizeBytes)
        }
        if !rec.contentHash.isEmpty {
            return .contentHash(rec.contentHash)
        }
        return nil
    }

    /// codex #1413: may a date travel between these two rows? Only when
    /// their bytes are VERIFIED the same — equal content hashes when
    /// both have one (a conflict rejects the pair outright, whatever
    /// else they share), else equal partialMD5 AND equal non-zero size.
    /// Never consults `duplicateGroupID` or `duplicateConfidence`.
    @MainActor
    static func haveVerifiedSameContent(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        if !a.contentHash.isEmpty, !b.contentHash.isEmpty {
            return a.contentHash == b.contentHash
        }
        return !a.partialMD5.isEmpty
            && a.partialMD5 == b.partialMD5
            && a.sizeBytes > 0
            && a.sizeBytes == b.sizeBytes
    }

    /// Rule 1 core: what the record's OWN stored evidence says. Content
    /// tiers only — no path hint, no mtime, no container time — so a nil
    /// result means "the evidence names no date", never "we guessed".
    @MainActor
    static func inferDateFromStoredEvidence(_ rec: VideoRecord,
                                            people: [DateTriangulationPerson] = []) -> (date: Date, confidence: Float)? {
        let r = triangulateStoredEvidence(rec, people: people)
        guard let d = r.date else { return nil }
        return (d, r.confidence)
    }

    /// GH #201: the scored triangulator over the record's stored evidence
    /// plus its own format / stamp / folder facts. Pure over the record.
    @MainActor
    static func triangulateStoredEvidence(_ rec: VideoRecord,
                                          people: [DateTriangulationPerson],
                                          now: Date = Date()) -> DateTriangulationResult {
        pfTriangulateRecordDate(triangulationInput(for: rec, people: people,
                                                   includePathHints: hasDateEvidence(rec), now: now))
    }

    /// What the record's own evidence CLAIMS, with the precision it can
    /// honestly claim it at: a parseable OCR burn-in is a day; a
    /// transcript / caption year mention is a year. nil when the
    /// evidence names nothing (or contradicts itself — pfInferRecordDate's
    /// ambiguity guard).
    @MainActor
    static func ownEvidenceClaim(_ rec: VideoRecord,
                                 people: [DateTriangulationPerson] = []) -> (date: Date, precision: RecordDateResolution.Precision)? {
        let r = triangulateStoredEvidence(rec, people: people)
        guard let d = r.date else { return nil }
        return (d, r.precision == .unknown ? .year : r.precision)
    }

    /// Rule 2 guard: may `rec` take `donor`'s date? Eligible, no user
    /// date, no settled inference, verified same content, and its own
    /// evidence (if it names a date at all) agrees with the donor's at
    /// the coarser of the two precisions (codex #1415 c — DEC 25 1991
    /// disagrees with JUN 21 1991; "Christmas 1991" does not). Own
    /// evidence FINER than the donor's is refused too: that row should
    /// get its own date from rule 1, not borrow a coarser one.
    @MainActor
    static func canReceivePropagatedDate(_ rec: VideoRecord, from donor: VideoRecord) -> Bool {
        guard rec.id != donor.id,
              isEligibleForDateInference(rec),
              rec.userDate == nil,
              !hasSettledInferredDate(rec),
              haveVerifiedSameContent(donor, rec),
              let donorDate = donor.inferredRecordDate else { return false }
        if let own = ownEvidenceClaim(rec) {
            let donorPrecision = pfInferredDatePrecision(confidence: donor.inferredDateConfidence ?? 0,
                                                         range: donor.inferredDateRange)
            if own.precision < donorPrecision { return false }
            let at = max(own.precision, donorPrecision)
            if !pfDatesAgree(own.date, donorDate, at: at) { return false }
        }
        return true
    }

    /// Rule 2 donor test: a settled, content-backed date on a readable,
    /// live row that the row EARNED from its own evidence (own dossier
    /// pass, source nil, or catch-up). A propagated date never donates
    /// again (codex #1433): A→B may be verified while A and C carry
    /// conflicting content hashes; if B (unhashed) could donate, a second
    /// pass would carry A's date to C through B, past the known conflict.
    /// Own-evidence rows are the only donors — the simpler, safer rule.
    @MainActor
    static func canDonateInferredDate(_ rec: VideoRecord) -> Bool {
        isEligibleForDateInference(rec)
            && hasSettledInferredDate(rec)
            && !isPropagatedInferredDate(rec)
            && !isFootageSharedInferredDate(rec)
            && (rec.inferredDateConfidence ?? 0) >= inferredDatePropagationFloor
    }

    /// True when the row's date came from a sibling (rule 2 provenance).
    @MainActor
    static func isPropagatedInferredDate(_ rec: VideoRecord) -> Bool {
        rec.inferredDateSource?.hasPrefix(InferredDateSource.propagatedPrefix) == true
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

    /// The memo key for `inferredDateNoDateEvidence`: every stored
    /// channel rule 1 reads, so any change re-opens the row. Hashing the
    /// transcript is the same order of cost as the regex scan it saves
    /// on every LATER pass; it is paid once per examined row per pass.
    @MainActor
    static func dateEvidenceFingerprint(_ rec: VideoRecord) -> Int {
        var h = Hasher()
        h.combine(rec.ocrDateCandidates.count)
        for c in rec.ocrDateCandidates { h.combine(c.text) }
        h.combine(rec.audioTranscript ?? "")
        h.combine(rec.sceneCaptions.count)
        for c in rec.sceneCaptions { h.combine(c.text) }
        return h.finalize()
    }

    // MARK: - Single-record writes (the only three places a date is set here)

    /// Rule 2 write. Returns false (nothing mutated) when the guard fails.
    @MainActor
    @discardableResult
    static func propagateInferredDate(from donor: VideoRecord, to rec: VideoRecord) -> Bool {
        guard canDonateInferredDate(donor), canReceivePropagatedDate(rec, from: donor) else { return false }
        rec.inferredRecordDate = donor.inferredRecordDate
        rec.inferredDateConfidence = donor.inferredDateConfidence
        rec.inferredDateRange = donor.inferredDateRange
        rec.inferredDateReason = "same bytes as \(donor.filename)"
            + (donor.inferredDateReason.map { ": \($0)" } ?? "")
        rec.inferredDateSource = InferredDateSource.propagated(from: donor)
        return true
    }

    @MainActor
    private static func applyFolderYear(_ rec: VideoRecord, year: Int) -> Bool {
        guard let d = pfJanuaryFirst(of: year) else { return false }
        rec.inferredRecordDate = d
        rec.inferredDateConfidence = folderYearPriorConfidence
        rec.inferredDateRange = InferredDateRange(year: year)
        rec.inferredDateReason = "bare-year folder '\(year)' — a placeholder any real evidence replaces"
        rec.inferredDateSource = InferredDateSource.folderYear
        return true
    }

    /// GH #201: clear every inferred field; `reason` (if any) stays so the
    /// inspector can say why there is no date.
    @MainActor
    static func clearInferredDate(_ rec: VideoRecord, reason: String?) {
        rec.inferredRecordDate = nil
        rec.inferredDateConfidence = nil
        rec.inferredDateRange = nil
        rec.inferredDateSource = nil
        rec.inferredDateReason = reason
    }

    // MARK: - GH #201 rule 2b: one footage group, one date

    /// A footage group shares dates only when the machine is at least
    /// `likely` sure it is one recording (byte-identical, Rick's word, or
    /// strong metadata). `possible` links (a camera-counter name + the
    /// same length) are one guess too many to date a file by.
    static let footageShareMinimumConfidence: FootageConfidence = .likely

    /// One member's date CLAIM for the group. A row whose own date is
    /// footage-shared claims WITHOUT it (it is derived, and is re-derived
    /// here), so a stale share never props itself up.
    @MainActor
    static func footageDateClaim(_ rec: VideoRecord, now: Date) -> (resolution: RecordDateResolution, claim: ArchiveAngelEvent.DateClaim)? {
        let derived = isFootageSharedInferredDate(rec)
        let r = RecordDateResolver.resolve(
            userDate: rec.userDate, userDateConfidence: rec.userDateConfidence,
            embeddedCreationDate: rec.embeddedCreationDate,
            originMake: rec.originMake, originModel: rec.originModel, originEncoder: rec.originEncoder,
            inferredRecordDate: derived ? nil : rec.inferredRecordDate,
            inferredDateConfidence: derived ? nil : rec.inferredDateConfidence,
            inferredDateRange: derived ? nil : rec.inferredDateRange,
            filename: rec.filename.isEmpty ? nil : rec.filename, now: now)
        guard let claim = ArchiveAngelEvent.DateClaim(r, demoteSoftwareStamps: true) else { return nil }
        return (r, claim)
    }

    /// Only a person's date, a camera's stamp or a dossier inference is a
    /// RECORDING date worth sharing; a filename year or a software stamp
    /// (an export's copy day) never travels.
    static func footageClaimIsShareable(_ r: RecordDateResolution) -> Bool {
        switch r.source {
        case .userDate, .inferred: return true
        // A user date refined by a stamp resolves as .embedded at the user's
        // confidence; applyFootageShare re-checks the donor names a device.
        case .embedded: return r.confidence >= RecordDateResolver.embeddedConfidenceDevice
        case .filename, .none: return false
        }
    }

    /// The group's date = its strongest member claim (`DateClaim`
    /// ordering: a person's date > a camera's stamp > the dossier > a name
    /// / export stamp; then confidence, precision, earliest year). Every
    /// other member with no user date whose own claim is weaker inherits
    /// it, with the reason "shared from <member> (same footage): …".
    /// Idempotent: an identical share writes nothing. Returns the rows
    /// written.
    @MainActor
    static func shareDateAcrossFootageGroup(_ members: [VideoRecord], now: Date) -> [VideoRecord] {
        guard members.count >= 2 else { return [] }
        var claims: [UUID: (resolution: RecordDateResolution, claim: ArchiveAngelEvent.DateClaim)] = [:]
        var best: (rec: VideoRecord, resolution: RecordDateResolution, claim: ArchiveAngelEvent.DateClaim)?
        for m in members {
            guard let c = footageDateClaim(m, now: now) else { continue }
            claims[m.id] = c
            if best.map({ c.claim < $0.claim }) ?? true { best = (m, c.resolution, c.claim) }
        }
        guard let best, footageClaimIsShareable(best.resolution) else { return [] }
        var written: [VideoRecord] = []
        for m in members where m.id != best.rec.id && m.userDate == nil {
            if let own = claims[m.id], !(best.claim < own.claim) { continue }   // as strong or stronger itself
            // Rick's "not the same" (either side) blocks the share (codex F2).
            if m.footageDecision(about: best.rec.id)?.verdict == .notSame
                || best.rec.footageDecision(about: m.id)?.verdict == .notSame { continue }
            if applyFootageShare(to: m, from: best.rec, resolution: best.resolution,
                                 ownYear: claims[m.id]?.resolution.year) {
                written.append(m)
            }
        }
        return written
    }

    /// What a share of `donor`'s claim `r` writes: the date, span and
    /// confidence (the stale check compares exactly these) and the words
    /// for the reason. nil when the claim may not travel.
    struct FootageShareValue: Equatable {
        var date: Date
        var range: InferredDateRange?
        var confidence: Float
        var what: String
    }

    @MainActor
    static func footageShareValue(from donor: VideoRecord, resolution r: RecordDateResolution) -> FootageShareValue? {
        guard let year = r.year else { return nil }
        let date: Date
        let range: InferredDateRange?
        let what: String
        switch r.source {
        case .userDate:
            guard let d = r.precision == .day ? r.date : pfJanuaryFirst(of: year) else { return nil }
            date = d
            range = r.precision == .day ? nil : InferredDateRange(year: year)
            what = "your date \(UserDateEntry.friendlyDisplay(r.isoString))"
        case .embedded:
            // Codex F1: a software stamp's day never travels, whatever the
            // resolution's confidence says (a user year once lifted it to 1.0).
            guard let d = donor.embeddedCreationDate,
                  RecordDateResolver.namesDevice(originMake: donor.originMake, originModel: donor.originModel)
            else { return nil }
            date = d; range = nil
            what = "camera stamp \(r.isoString) (\(donor.embeddedDateOriginLabel))"
        case .inferred:
            guard let d = donor.inferredRecordDate else { return nil }
            date = d; range = donor.inferredDateRange
            what = donor.inferredDateReason ?? "inferred \(r.isoString)"
        case .filename, .none:
            return nil
        }
        return FootageShareValue(date: date, range: range,
                                 confidence: min(DateTriangulationWeights.cap, r.confidence), what: what)
    }

    /// The tail a share appends when the recipient's own evidence disagreed.
    static let ownEvidenceMarker = "; own evidence said "

    @MainActor
    static func applyFootageShare(to rec: VideoRecord, from donor: VideoRecord,
                                  resolution r: RecordDateResolution, ownYear: Int?) -> Bool {
        guard let year = r.year, let v = footageShareValue(from: donor, resolution: r) else { return false }
        let source = InferredDateSource.footageShared(from: donor)
        var reason = "shared from \(donor.filename) (same footage): \(v.what)"
        if let ownYear, ownYear != year {
            reason += "; own evidence said \(ownYear)"
        } else if ownYear == nil, rec.inferredDateSource == source,
                  let old = rec.inferredDateReason, let r = old.range(of: Self.ownEvidenceMarker) {
            // Codex F3: once shared, the row's own inference is gone, so a
            // later pass cannot recompute the disagreement — keep what the
            // first share recorded (and so write nothing).
            reason += old[r.lowerBound...]
        }
        if rec.inferredRecordDate == v.date, rec.inferredDateConfidence == v.confidence,
           rec.inferredDateRange == v.range, rec.inferredDateSource == source, rec.inferredDateReason == reason {
            return false
        }
        rec.inferredRecordDate = v.date
        rec.inferredDateConfidence = v.confidence
        rec.inferredDateRange = v.range
        rec.inferredDateSource = source
        rec.inferredDateReason = reason
        return true
    }

    /// Codex F2: a footage-shared date is STALE unless all of these still
    /// hold — the donor exists in the same footage group; both memberships
    /// are ≥ `likely`; neither row carries Rick's "not the same" about the
    /// other; and the donor STILL holds a shareable claim that produces the
    /// very value this row carries (same kind ⇒ same date / span /
    /// confidence). A retracted user date, a downgraded group or a changed
    /// donor year all clear the share; rule 2b re-shares whatever is true now.
    @MainActor
    static func isStaleFootageShare(_ rec: VideoRecord, byID: [UUID: VideoRecord], now: Date = Date()) -> Bool {
        guard isFootageSharedInferredDate(rec), let source = rec.inferredDateSource else { return false }
        guard let membership = rec.footage, membership.confidence >= footageShareMinimumConfidence,
              let donorID = UUID(uuidString: String(source.dropFirst(InferredDateSource.footageSharedPrefix.count))),
              let donor = byID[donorID], let donorMembership = donor.footage,
              donorMembership.groupID == membership.groupID,
              donorMembership.confidence >= footageShareMinimumConfidence else { return true }
        if rec.footageDecision(about: donor.id)?.verdict == .notSame
            || donor.footageDecision(about: rec.id)?.verdict == .notSame { return true }
        guard let claim = footageDateClaim(donor, now: now), footageClaimIsShareable(claim.resolution),
              let v = footageShareValue(from: donor, resolution: claim.resolution) else { return true }
        return v.date != rec.inferredRecordDate || v.range != rec.inferredDateRange
            || v.confidence != rec.inferredDateConfidence
    }

    // MARK: - The pass

    /// Run rules 1–3. `scope == nil` walks the whole catalog; otherwise
    /// only the given records AND every member of their content groups
    /// (a sibling with its own evidence should get its own date rather
    /// than a propagated one). `limit` bounds rule 1's evidence scans;
    /// rows it leaves unexamined are deferred — never dated by a sibling
    /// this pass — and rows classified "no date" are skipped for free
    /// next time, so repeated bounded passes advance.
    /// Never touches disk directly — one debounced save at the end.
    @MainActor
    @discardableResult
    func catchUpInferredDates(scope: [VideoRecord]? = nil,
                              limit: Int = 50_000,
                              trigger: String = "manual",
                              refreshScope: Bool = false) -> InferredDateCatchUpResult {
        let started = Date()
        var result = InferredDateCatchUpResult()
        let people = dateInferencePeopleResolved

        // One pass: bucket every eligible row by VERIFIED content group,
        // and (GH #201) by footage group. References only; the arrays
        // hold pointers to records the model already owns. A scoped pass
        // still computes every key (cheap: two string tests) but only
        // buckets the scope's own groups, so no per-group array is
        // allocated for the rest of the catalog.
        let scopeKeys: Set<CatalogSizeTotals.GroupKey>? = scope.map { rows in
            Set(rows.compactMap { Self.contentGroupKey($0) })
        }
        let scopeFootage: Set<UUID>? = scope.map { rows in Set(rows.compactMap { $0.footage?.groupID }) }
        var groups: [CatalogSizeTotals.GroupKey: [VideoRecord]] = [:]
        var footageGroups: [UUID: [VideoRecord]] = [:]
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(records.count)
        for rec in records where Self.isEligibleForDateInference(rec) {
            byID[rec.id] = rec
            if let key = Self.contentGroupKey(rec), scopeKeys?.contains(key) ?? true {
                groups[key, default: []].append(rec)
            }
            if let f = rec.footage, f.confidence >= Self.footageShareMinimumConfidence,
               scopeFootage?.contains(f.groupID) ?? true {
                footageGroups[f.groupID, default: []].append(rec)
            }
        }

        // The rows this pass may write to, and the groups it may share within.
        let (candidates, groupKeys, footageKeys) = Self.dateInferenceScope(
            scope, allRecords: records, groups: groups, footageGroups: footageGroups)
        let refreshIDs: Set<UUID> = refreshScope ? Set((scope ?? []).map(\.id)) : []

        var touched: [VideoRecord] = []
        // codex #1415 (a): evidence-bearing rows the budget left unread.
        var deferred = Set<UUID>()

        // Rule 0 (GH #201) — housekeeping before anything is derived: a
        // legacy filesystem-tier "inference" is cleared (a copy date is
        // never an inferred date); a footage-shared date whose donor left
        // the group is cleared so rules 1 / 2b re-derive it honestly.
        for rec in candidates where Self.isEligibleForDateInference(rec) && rec.userDate == nil {
            if Self.isLegacyFilesystemInference(rec) {
                Self.clearInferredDate(rec, reason: Self.clearedFilesystemReason)
                result.cleared += 1
                touched.append(rec)
            } else if Self.isStaleFootageShare(rec, byID: byID, now: started) {
                Self.clearInferredDate(rec, reason: nil)
                result.cleared += 1
                touched.append(rec)
            }
        }

        // Rule 1 — own evidence: rows with no settled date, legacy rows the
        // old triangulator dated (re-derived once, so they gain a written
        // reason — GH #201), and rows a new channel just landed on
        // (`refreshScope`, from the transcript / caption writebacks).
        for rec in candidates where Self.isEligibleForDateInference(rec)
            && rec.userDate == nil
            && Self.hasDateEvidence(rec) {
            let legacy = Self.needsRetriangulation(rec)
            let refresh = refreshIDs.contains(rec.id)
                && !Self.isPropagatedInferredDate(rec) && !Self.isFootageSharedInferredDate(rec)
            guard !Self.hasSettledInferredDate(rec) || legacy || refresh else { continue }
            let fingerprint = Self.dateEvidenceFingerprint(rec)
            // (d) Classified "no date" by an earlier pass, evidence
            // unchanged: costs nothing and is NOT deferred — its
            // evidence was read; it can still receive a sibling's date.
            if !legacy, !refresh, inferredDateNoDateEvidence[rec.id] == fingerprint {
                result.alreadyClassified += 1
                continue
            }
            // (b) Over budget: defer, keep walking so every unread row is
            // recorded (no `break` — rule 2 needs the whole set).
            if result.examined >= limit {
                result.truncated = true
                result.deferred += 1
                deferred.insert(rec.id)
                continue
            }
            result.examined += 1
            let hadDate = rec.inferredRecordDate != nil
            let r = Self.triangulateStoredEvidence(rec, people: people, now: started)
            if r.date != nil {
                // A legacy row re-derived from its OWN dossier pass keeps
                // that provenance (nil); everything else — a new date, a
                // catch-up, or a folder-year placeholder that just gained
                // evidence (QA M1: it must SETTLE, not be re-examined every
                // launch) — becomes a catch-up.
                let keepOwnPass = hadDate && rec.inferredDateSource == nil
                Self.applyTriangulation(r, to: rec, source: keepOwnPass ? nil : InferredDateSource.catchUp)
                inferredDateNoDateEvidence[rec.id] = nil
                if hadDate { result.retriangulated += 1 } else { result.inferredFromEvidence += 1 }
                touched.append(rec)
            } else {
                inferredDateNoDateEvidence[rec.id] = fingerprint
                if hadDate {
                    // The old date rested on nothing the new rules accept
                    // (Clip 19's "1955" as a reference with no folder hint):
                    // clear it with the reason.
                    Self.applyTriangulation(r, to: rec, source: nil)
                    result.cleared += 1
                    touched.append(rec)
                } else if rec.inferredDateReason != r.reason {
                    rec.inferredDateReason = r.reason
                    touched.append(rec)
                }
            }
        }

        // Rule 2 — share within each group. Donors best-first; each
        // recipient takes the best donor whose bytes are VERIFIED its
        // own (a bucket can hold rows whose content hashes conflict —
        // same head, tail and length, different middle; they never
        // exchange dates). Deferred rows neither give nor take.
        for key in groupKeys {
            guard let members = groups[key], members.count >= 2 else { continue }
            let donors = members
                .filter { Self.canDonateInferredDate($0) && !deferred.contains($0.id) }
                .sorted { ($0.inferredDateConfidence ?? 0) > ($1.inferredDateConfidence ?? 0) }
            guard !donors.isEmpty else { continue }
            // codex #1434: settle the cheap per-recipient tests ONCE, before
            // the donor loop — an idempotent bucket of N dated copies must
            // cost N predicate reads, not N² guard calls (each of which
            // re-scans the recipient's evidence).
            let recipients = members.filter {
                !deferred.contains($0.id)
                    && $0.userDate == nil
                    && !Self.hasSettledInferredDate($0)
                    && Self.isEligibleForDateInference($0)
            }
            for rec in recipients {
                for donor in donors where Self.propagateInferredDate(from: donor, to: rec) {
                    result.propagated += 1
                    touched.append(rec)
                    break
                }
            }
        }

        // Rule 2b (GH #201) — one footage group, one date: the strongest
        // member claim; the others inherit with the reason. Deferred rows
        // are left alone (their own evidence is still unread).
        for key in footageKeys {
            guard let members = footageGroups[key], members.count >= 2 else { continue }
            let live = members.filter { !deferred.contains($0.id) }
            let written = Self.shareDateAcrossFootageGroup(live, now: started)
            result.footageShared += written.count
            touched.append(contentsOf: written)
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
        if result.footageShared + result.retriangulated + result.cleared > 0 {
            log(Self.dateTriangulationLogLine(result, trigger: trigger))
        }
        return result
    }

    /// GH #201's own line (the 2026-09-12 line above is unchanged):
    /// "date triangulation: 3 took their footage group's date, 12
    /// re-triangulated with a written reason, 2 cleared (load)".
    static func dateTriangulationLogLine(_ r: InferredDateCatchUpResult, trigger: String) -> String {
        "date triangulation: \(r.footageShared) took their footage group's date, "
            + "\(r.retriangulated) re-triangulated with a written reason, \(r.cleared) cleared (\(trigger))"
    }

    /// Which rows a pass may write to and which groups it may share within:
    /// the whole catalog, or the scoped rows plus every member of their
    /// content groups and footage groups (a sibling with its own evidence
    /// should get its own date rather than a propagated one).
    @MainActor
    private static func dateInferenceScope(
        _ scope: [VideoRecord]?,
        allRecords: [VideoRecord],
        groups: [CatalogSizeTotals.GroupKey: [VideoRecord]],
        footageGroups: [UUID: [VideoRecord]]
    ) -> (candidates: [VideoRecord], groupKeys: [CatalogSizeTotals.GroupKey], footageKeys: [UUID]) {
        guard let scope else { return (allRecords, Array(groups.keys), Array(footageGroups.keys)) }
        var seen = Set<UUID>()
        var rows: [VideoRecord] = []
        var keys: [CatalogSizeTotals.GroupKey] = []
        var seenKeys = Set<CatalogSizeTotals.GroupKey>()
        var footageKeys: [UUID] = []
        var seenFootage = Set<UUID>()
        for rec in scope {
            if seen.insert(rec.id).inserted { rows.append(rec) }
            if let key = Self.contentGroupKey(rec), seenKeys.insert(key).inserted {
                keys.append(key)
                for member in groups[key] ?? [] where seen.insert(member.id).inserted {
                    rows.append(member)
                }
            }
            if let f = rec.footage?.groupID, footageGroups[f] != nil, seenFootage.insert(f).inserted {
                footageKeys.append(f)
                for member in footageGroups[f] ?? [] where seen.insert(member.id).inserted {
                    rows.append(member)
                }
            }
        }
        return (rows, keys, footageKeys)
    }

    /// The one line a pass writes: "date inference: N records caught up (…)".
    /// Format unchanged since 2026-09-12 (log formats are a Rick decision).
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
        guard Self.contentGroupKey(donor) != nil || donor.footage != nil else { return 0 }
        let r = catchUpInferredDates(scope: [donor], trigger: "dossier")
        return r.propagated + r.footageShared
    }

    // MARK: - Repair (codex #1413) — one-shot, reversible, runs at load

    /// One row of the unwind sidecar: everything needed to put the date
    /// back exactly as it was. (For Rick: a POD struct, JSON-serialised.)
    struct UnwoundDateEntry: Codable, Equatable, Sendable {
        var recordID: UUID
        var fullPath: String
        var inferredRecordDate: Date
        var inferredDateConfidence: Float?
        var inferredDateSource: String
        /// GH #201 (QA minor): the span and reason ride the undo too.
        /// Optional — sidecars written before decode them as nil.
        var inferredDateRange: InferredDateRange? = nil
        var inferredDateReason: String? = nil
    }

    /// One retained row whose provenance was re-pointed from a cleared
    /// intermediate to the origin that earned the date (codex post-merge
    /// review 2026-09-13). `previousSource` is what to put back.
    struct ReanchoredProvenanceEntry: Codable, Equatable, Sendable {
        var recordID: UUID
        var fullPath: String
        var previousSource: String
        var newSource: String
    }

    /// The sidecar file. Written BEFORE any row is cleared; if it cannot
    /// be written, nothing is cleared.
    struct UnwoundDateSidecar: Codable, Equatable, Sendable {
        var savedAt: Date
        var reason: String
        var conflictingHashes: Int
        var entries: [UnwoundDateEntry]
        /// Additive (2026-09-13): sidecars written before it decode as [].
        var reanchored: [ReanchoredProvenanceEntry] = []
    }

    struct UnwindResult: Equatable, Sendable {
        var unwound = 0
        var reanchored = 0
        var conflictingHashes = 0
        var sidecar: URL?
    }

    /// Where the sidecars go: `<catalog directory>/date-inference/`. In
    /// production the catalog lives in App Support/VideoScan; a test that
    /// injects `CatalogStore(directory:)` gets its own scratch folder.
    @MainActor
    var dateInferenceSidecarDirectory: URL {
        URL(fileURLWithPath: catalogStore.fileLocation)
            .deletingLastPathComponent()
            .appendingPathComponent("date-inference", isDirectory: true)
    }

    /// True when writing there would touch Rick's real App Support from a
    /// test host — the shared CatalogStore still points at the real path
    /// under tests (it merely refuses to save).
    @MainActor
    static func sidecarDirectoryIsRealAppSupportUnderTests(_ dir: URL) -> Bool {
        guard TestEnvironment.isTestHost else { return false }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.standardizedFileURL.path ?? "/nonexistent"
        return dir.standardizedFileURL.path.hasPrefix(appSupport)
    }

    /// Clears every persisted "propagated from <id>" date whose donor is
    /// not VERIFIED the same bytes (or is gone from the catalog), so the
    /// row is honestly undated again and rule 1 / a dossier pass / a
    /// verified sibling can re-derive it. Exact, because the provenance
    /// string names the donor. Touches nothing else: userDate never
    /// (propagation never set one), own-evidence and folder-year rows
    /// never, verified propagated rows never.
    ///
    /// REVERSIBLE: before the first row is cleared the full prior state is
    /// written to `<dir>/unwound-<yyyyMMdd-HHmmss>.json`; a failed write
    /// aborts the unwind (an irreversible repair is worse than the bug).
    /// `reapplyUnwoundDates(from:to:)` restores it. IDEMPOTENT: a second
    /// call finds nothing, writes nothing, logs nothing.
    ///
    /// Why it exists: the 2026-09-12 20:18 load pass persisted 558 such
    /// dates on Rick's catalog (531 with conflicting content hashes)
    /// before the identity rule was tightened (codex #1413).
    @MainActor
    @discardableResult
    func unwindUnverifiedPropagatedDates(sidecarDirectory: URL? = nil,
                                         now: Date = Date(),
                                         trigger: String = "manual") -> UnwindResult {
        var result = UnwindResult()
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(records.count)
        for rec in records { byID[rec.id] = rec }

        var victims: [VideoRecord] = []
        var entries: [UnwoundDateEntry] = []
        for rec in records {
            guard Self.isPropagatedInferredDate(rec),
                  let source = rec.inferredDateSource,
                  let date = rec.inferredRecordDate else { continue }
            // codex #1439: validate against the ORIGIN of the provenance
            // chain, not the immediate donor — B (from A) may be verified
            // for C while B's own date is A's, and A/C conflict. A missing
            // link or a cycle is unverified by definition.
            let origin = Self.originDonor(of: rec, byID: byID)
            if let origin, Self.haveVerifiedSameContent(origin, rec) { continue }
            if let origin, !origin.contentHash.isEmpty, !rec.contentHash.isEmpty, origin.contentHash != rec.contentHash {
                result.conflictingHashes += 1
            }
            victims.append(rec)
            entries.append(UnwoundDateEntry(recordID: rec.id, fullPath: rec.fullPath,
                                            inferredRecordDate: date,
                                            inferredDateConfidence: rec.inferredDateConfidence,
                                            inferredDateSource: source,
                                            inferredDateRange: rec.inferredDateRange,
                                            inferredDateReason: rec.inferredDateReason))
        }
        guard !victims.isEmpty else { return result }

        // codex post-merge review 2026-09-13: a RETAINED row whose
        // provenance runs THROUGH a victim — A (aaaa, own) → B (bbbb, from
        // A) → C (aaaa, from B): B goes, C is verified against A and stays
        // — would lose its path to A the moment B is cleared, and the NEXT
        // cleanup would clear a correct date. Re-anchor it to the origin it
        // was verified against, in the same backed-up pass, directly (so a
        // repeated cleanup finds nothing to do) and recorded (so the
        // sidecar can put the previous provenance back).
        let victimIDs = Set(victims.map(\.id))
        var reanchors: [(rec: VideoRecord, entry: ReanchoredProvenanceEntry)] = []
        for rec in records where Self.isPropagatedInferredDate(rec) && !victimIDs.contains(rec.id) {
            let chain = Self.provenanceChain(of: rec, byID: byID)
            guard let origin = chain.origin, let previous = rec.inferredDateSource,
                  chain.via.contains(where: { victimIDs.contains($0) }) else { continue }
            let newSource = InferredDateSource.propagated(from: origin)
            guard newSource != previous else { continue }
            reanchors.append((rec, ReanchoredProvenanceEntry(recordID: rec.id, fullPath: rec.fullPath,
                                                             previousSource: previous, newSource: newSource)))
        }

        // Sidecar first. No sidecar, no repair.
        let dir = sidecarDirectory ?? dateInferenceSidecarDirectory
        if Self.sidecarDirectoryIsRealAppSupportUnderTests(dir) {
            log("date inference: unwind skipped — \(victims.count) candidate(s) but the sidecar would land in the real App Support from a test host (\(trigger))")
            return UnwindResult()
        }
        let payload = UnwoundDateSidecar(savedAt: now,
                                         reason: "propagated date whose origin donor is not verified same content (codex #1413/#1439)",
                                         conflictingHashes: result.conflictingHashes,
                                         entries: entries,
                                         reanchored: reanchors.map(\.entry))
        let url: URL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = try Self.writeUnwoundSidecar(payload, in: dir, now: now)
        } catch {
            log("date inference: unwind ABORTED — could not write sidecar under \(dir.path): \(error.localizedDescription) (\(trigger))")
            return UnwindResult()
        }
        result.sidecar = url

        for rec in victims {
            // All five inferred fields, so no "same bytes as …" reason or
            // span outlives the date it explained (GH #201 QA minor).
            Self.clearInferredDate(rec, reason: nil)
        }
        for (rec, entry) in reanchors {
            rec.inferredDateSource = entry.newSource
        }
        result.unwound = victims.count
        result.reanchored = reanchors.count
        announceInferredDateChanges(victims + reanchors.map(\.rec))
        let line = "date inference: unwound \(result.unwound) unverified propagated dates "
            + "(\(result.conflictingHashes) with conflicting hashes)"
            + (reanchors.isEmpty ? "" : ", re-anchored \(reanchors.count) retained descendant(s) to their earned origin")
            + " — sidecar \(url.path)"
        log(line)
        appLog.write(line)
        return result
    }

    /// Follow "propagated from <id>" links to the row that EARNED the
    /// date (own dossier pass or catch-up). nil when any link is missing
    /// from the catalog, unparseable, or the chain loops — a date with no
    /// traceable origin cannot be verified and is unwound.
    @MainActor
    static func originDonor(of rec: VideoRecord, byID: [UUID: VideoRecord]) -> VideoRecord? {
        provenanceChain(of: rec, byID: byID).origin
    }

    /// `originDonor` plus the ids walked to reach it (donors between `rec`
    /// and the origin, origin included) — the unwind needs to know whether
    /// a retained row's path to its origin runs through a cleared row.
    @MainActor
    static func provenanceChain(of rec: VideoRecord, byID: [UUID: VideoRecord]) -> (origin: VideoRecord?, via: [UUID]) {
        var visited: Set<UUID> = [rec.id]
        var via: [UUID] = []
        var current = rec
        while isPropagatedInferredDate(current) {
            guard let source = current.inferredDateSource,
                  let donorID = UUID(uuidString: String(source.dropFirst(InferredDateSource.propagatedPrefix.count))),
                  let donor = byID[donorID],
                  visited.insert(donorID).inserted else { return (nil, via) }
            via.append(donorID)
            current = donor
        }
        return (current.inferredRecordDate == nil ? nil : current, via)
    }

    /// `unwound-<yyyyMMdd-HHmmss>-<8 hex>.json`, opened create-exclusive
    /// (`.withoutOverwriting`): an undo file is never replaced. Two
    /// unwinds in the same second get two files; a name collision picks
    /// another suffix (codex #1439).
    static func writeUnwoundSidecar(_ payload: UnwoundDateSidecar, in dir: URL, now: Date) throws -> URL {
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd-HHmmss"
        stampFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let data = try unwoundSidecarEncoder().encode(payload)
        var lastError: Error?
        for _ in 0..<8 {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            let url = dir.appendingPathComponent("unwound-\(stampFmt.string(from: now))-\(suffix).json")
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch {
                lastError = error
                if (error as NSError).code != NSFileWriteFileExistsError { throw error }
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    static func unwoundSidecarEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    static func unwoundSidecarDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    /// Rick's undo: put the unwound dates back from a sidecar. Restores a
    /// row only when it currently holds NO settled inferred date (nil or
    /// the folder-year placeholder) and no userDate — a date a verified
    /// pass or a dossier run derived since is better-founded than the one
    /// unwound and is kept. Pure over its inputs (no model, no disk
    /// beyond reading the sidecar); returns the rows restored.
    @MainActor
    @discardableResult
    static func reapplyUnwoundDates(from sidecar: URL, to records: [VideoRecord]) throws -> [VideoRecord] {
        let payload = try unwoundSidecarDecoder().decode(UnwoundDateSidecar.self, from: Data(contentsOf: sidecar))
        return reapplyUnwoundDates(payload.entries, reanchored: payload.reanchored, to: records)
    }

    /// Returns every row touched: dates put back, and re-anchored
    /// provenance put back where the re-anchor is still in place (a row
    /// re-dated since keeps its newer provenance).
    @MainActor
    @discardableResult
    static func reapplyUnwoundDates(_ entries: [UnwoundDateEntry],
                                    reanchored: [ReanchoredProvenanceEntry] = [],
                                    to records: [VideoRecord]) -> [VideoRecord] {
        var byID: [UUID: VideoRecord] = [:]
        for rec in records { byID[rec.id] = rec }
        var restored: [VideoRecord] = []
        for e in entries {
            guard let rec = byID[e.recordID],
                  rec.userDate == nil,
                  !hasSettledInferredDate(rec) else { continue }
            rec.inferredRecordDate = e.inferredRecordDate
            rec.inferredDateConfidence = e.inferredDateConfidence
            rec.inferredDateSource = e.inferredDateSource
            rec.inferredDateRange = e.inferredDateRange
            rec.inferredDateReason = e.inferredDateReason
            restored.append(rec)
        }
        for e in reanchored {
            guard let rec = byID[e.recordID], rec.inferredDateSource == e.newSource else { continue }
            rec.inferredDateSource = e.previousSource
            if !restored.contains(where: { $0.id == rec.id }) { restored.append(rec) }
        }
        return restored
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

// `reanchored` was added 2026-09-13: a sidecar written before then has no
// such key and must still decode. (In an extension so the struct keeps its
// memberwise init.)
extension VideoScanModel.UnwoundDateSidecar {
    private enum CodingKeys: String, CodingKey {
        case savedAt, reason, conflictingHashes, entries, reanchored
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        reason = try c.decode(String.self, forKey: .reason)
        conflictingHashes = try c.decode(Int.self, forKey: .conflictingHashes)
        entries = try c.decode([VideoScanModel.UnwoundDateEntry].self, forKey: .entries)
        reanchored = try c.decodeIfPresent([VideoScanModel.ReanchoredProvenanceEntry].self, forKey: .reanchored) ?? []
    }
}

// MARK: - Precision of an inferred date (pure)

/// The precision an `inferredDateConfidence` value implies, read off
/// pfInferRecordDate's confidence table: the OCR tiers (0.75 / 0.85 /
/// 0.90 / 0.95) and the mtime tier (0.30) are day-precision dates; the
/// content-year (0.55 / 0.58) and path-year (0.50) tiers are Jan-1
/// placeholders that honestly know only the YEAR. (No "month" tier
/// exists today; the comparator below still handles one.)
nonisolated func pfInferredDatePrecision(confidence: Float) -> RecordDateResolution.Precision {
    (0.50...0.60).contains(confidence) ? .year : .day
}

/// GH #201: a triangulated date carries its span when it only knows the
/// year — that is the precision, whatever the confidence. Legacy rows
/// (no span) fall back to the confidence table above.
nonisolated func pfInferredDatePrecision(confidence: Float, range: InferredDateRange?) -> RecordDateResolution.Precision {
    range != nil ? .year : pfInferredDatePrecision(confidence: confidence)
}

/// Do two dates agree when read at `precision`? Day compares y/m/d,
/// month y/m, year y, decade y/10; `.unknown` never disagrees. UTC
/// calendar, because every inferred date is a noon-UTC construction.
nonisolated func pfDatesAgree(_ a: Date, _ b: Date, at precision: RecordDateResolution.Precision) -> Bool {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC") ?? .current
    let ca = cal.dateComponents([.year, .month, .day], from: a)
    let cb = cal.dateComponents([.year, .month, .day], from: b)
    switch precision {
    case .day:     return ca.year == cb.year && ca.month == cb.month && ca.day == cb.day
    case .month:   return ca.year == cb.year && ca.month == cb.month
    case .year:    return ca.year == cb.year
    case .decade:  return (ca.year ?? 0) / 10 == (cb.year ?? 0) / 10
    case .unknown: return true
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
